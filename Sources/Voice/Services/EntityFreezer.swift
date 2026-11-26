// EntityFreezer.swift
//
// Protects fragile spans (emails, URLs, code, contractions, domains) from
// LLM polishing by replacing them with sentinel tokens BEFORE the model
// sees the text, then restoring them verbatim AFTER the model returns.
//
// Solves a class of bugs where the polisher:
//   - splits "jordan@example.com" → "jordan@gmail. Com" (sees `.com` as a
//     sentence boundary)
//   - mangles "let's say" → "let'say" (apostrophe handling drift)
//   - capitalizes "github.com" → "GitHub.com" mid-paragraph
//   - drops or rewrites already-correct identifiers
//
// Sentinel format: ⟦E0⟧, ⟦E1⟧, ⟦E2⟧… using mathematical white square
// brackets (U+27E6 / U+27E7). Literal markers already present in the input
// are reserved so restoring a protected span cannot overwrite user text.
//
// Phase 1 of the multi-agent polish pipeline plan. Subsequent phases
// (ensemble drafts, critic) build on top of this — every draft polishes
// the SAME frozen text so unfreezing produces identical entity content
// across drafts.

import Foundation

public enum EntityFreezer {

    /// How aggressively to freeze fragile spans.
    ///
    /// `.aggressive` (legacy): freezes everything we have a pattern for —
    /// emails, URLs, domains, backtick spans, file paths, AND contractions.
    /// Designed for small local models (Qwen3 1.7B, Apple FM) that mangle
    /// these spans during polish.
    ///
    /// `.minimal` (cloud path): freezes ONLY the truly fragile spans the
    /// cloud model gains nothing from re-formatting — emails, URLs, domains,
    /// backtick code, and file paths. Contractions are left in the open
    /// text because the cloud model handles them fine AND benefits from
    /// seeing them in context (it can decide "let's" vs "lets" from
    /// surrounding tense). Names, dates, times, money, percentages, and
    /// numbers in general were never frozen by this class but the docstring
    /// here is the authoritative place to record that intent: in `.minimal`
    /// mode we keep that hands-off stance.
    public enum Mode {
        case aggressive
        case minimal
        /// Don't freeze anything. Used by the raw cloud path — the cloud
        /// model is trusted to handle emails, URLs, code, contractions, and
        /// every other fragile span natively. Returns an empty entity map,
        /// so the corresponding `unfreeze` is a no-op.
        case skip
    }

    /// Result of freezing: the modified text plus the map needed to restore
    /// the original spans.
    public struct Frozen {
        public let text: String
        public let entities: [String: String]
        public var isEmpty: Bool { entities.isEmpty }
    }

    /// Matches are collected against the original input, then longer enclosing
    /// spans win. Otherwise freezing an email inside code first leaves the rest
    /// of that code exposed to editing.
    private static let patterns: [(name: String, regex: String)] = [
        // Emails — full RFC-ish, but pragmatic.
        ("email", #"\b[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}\b"#),

        // Full URLs with scheme.
        ("url", #"https?://[^\s)\]\}>,`]+"#),

        // Bare domains with TLD — matches "github.com/user", "example.io",
        // "api.example.co.uk/v2". Requires at least one alphanumeric label
        // before the TLD to avoid matching ". com" or "the .net".
        ("domain", #"\b[A-Za-z0-9][A-Za-z0-9\-]*(?:\.[A-Za-z0-9\-]+)*\.(?:com|io|net|org|dev|app|ai|co|us|uk|gov|edu|me|tv|fm|so|sh|xyz|tech|cloud)(?:/[^\s)\]\}>,`]*)?\b"#),

        // Backtick-protected spans (already explicitly user-marked).
        ("backtick", #"`[^`\n]+`"#),

        // File paths (POSIX-style absolute paths).
        ("path", #"(?:^|\s)(/(?:[A-Za-z0-9._\-]+/?)+)(?=\s|$|[,;.])"#),

        // Contractions and possessives — the "let's", "don't", "it's" class.
        // Word boundary on both sides keeps us out of code/identifier
        // spans (which are already frozen by backtick/path passes above).
        ("contraction", #"\b[A-Za-z]+'[A-Za-z]+\b"#),
    ]

    /// Pattern names that are SAFE to freeze even on the cloud path.
    /// Anything not in this set is skipped when mode is `.minimal`.
    private static let minimalModePatterns: Set<String> = [
        "email", "url", "domain", "backtick", "path"
    ]

    private static let compiledPatterns: [(name: String, regex: NSRegularExpression)] = patterns.compactMap {
        guard let regex = try? NSRegularExpression(pattern: $0.regex) else { return nil }
        return ($0.name, regex)
    }
    private static let markerPattern = try! NSRegularExpression(pattern: #"⟦E[0-9]+⟧"#)

    /// Freeze fragile spans. Returns the frozen text and a map for
    /// unfreezing. Each protected range is replaced exactly once; nested
    /// entities remain inside their enclosing code, URL or email span.
    ///
    /// `mode` controls how much we freeze. Cloud callers should pass
    /// `.minimal` so the model sees natural contractions in context.
    public static func freeze(_ input: String, mode: Mode = .aggressive) -> Frozen {
        // .skip short-circuits: no freezing, no entity map. The cloud path
        // uses this so the model sees emails/URLs/code/contractions in their
        // natural surrounding context, and reasons about them as a smart
        // editor would, rather than ingesting opaque sentinel tokens.
        if mode == .skip {
            return Frozen(text: input, entities: [:])
        }
        let original = input as NSString
        let fullRange = NSRange(location: 0, length: original.length)
        var ranges: [NSRange] = []
        for (name, regex) in compiledPatterns {
            if mode == .minimal, !minimalModePatterns.contains(name) { continue }
            for match in regex.matches(in: input, range: fullRange) {
                let range = match.numberOfRanges > 1 ? match.range(at: 1) : match.range
                if range.location != NSNotFound, range.length > 0 { ranges.append(range) }
            }
        }
        ranges.sort { $0.length != $1.length ? $0.length > $1.length : $0.location < $1.location }
        var occupied = IndexSet()
        let selected = ranges.filter { range in
            let indices = range.location..<NSMaxRange(range)
            guard !occupied.intersects(integersIn: indices) else { return false }
            occupied.insert(integersIn: indices)
            return true
        }.sorted { $0.location < $1.location }
        guard !selected.isEmpty else { return Frozen(text: input, entities: [:]) }

        let reserved = Set(markerPattern.matches(in: input, range: fullRange).map {
            original.substring(with: $0.range)
        })
        var entities: [String: String] = [:]
        var replacements: [(NSRange, String)] = []
        var counter = 0
        for range in selected {
            while reserved.contains("⟦E\(counter)⟧") { counter += 1 }
            let sentinel = "⟦E\(counter)⟧"
            counter += 1
            entities[sentinel] = original.substring(with: range)
            replacements.append((range, sentinel))
        }
        let working = NSMutableString(string: input)
        for (range, sentinel) in replacements.reversed() { working.replaceCharacters(in: range, with: sentinel) }
        return Frozen(text: working as String, entities: entities)
    }

    /// Restore frozen spans. Iterates sentinels in reverse-numeric order
    /// so longer keys substitute before shorter ones (defensive — sentinels
    /// don't share prefixes in our format, but if the format ever changes,
    /// this ordering avoids a class of bugs).
    public static func unfreeze(_ text: String, entities: [String: String]) -> String {
        guard !entities.isEmpty else { return text }
        var output = text
        let sortedKeys = entities.keys.sorted { lhs, rhs in
            // Sort by length desc, then lexical desc.
            if lhs.count != rhs.count { return lhs.count > rhs.count }
            return lhs > rhs
        }
        for key in sortedKeys {
            guard let original = entities[key] else { continue }
            output = output.replacingOccurrences(of: key, with: original)
        }
        return output
    }

    /// Reject missing, duplicated or substituted placeholders before restoring.
    public static func hasIntactEntities(_ text: String, frozen: Frozen) -> Bool {
        for key in frozen.entities.keys {
            let expected = frozen.text.components(separatedBy: key).count - 1
            let actual = text.components(separatedBy: key).count - 1
            if expected != actual { return false }
        }
        return true
    }

    /// One-shot helper for the common case: freeze → transform → unfreeze.
    /// The transform closure receives the frozen text and returns the
    /// polished version (which should preserve sentinel tokens verbatim).
    public static func roundTrip(
        _ input: String,
        mode: Mode = .aggressive,
        transform: (String) async -> String
    ) async -> String {
        let frozen = freeze(input, mode: mode)
        if frozen.isEmpty {
            return await transform(input)
        }
        let transformed = await transform(frozen.text)
        guard hasIntactEntities(transformed, frozen: frozen) else { return input }
        return unfreeze(transformed, entities: frozen.entities)
    }
}
