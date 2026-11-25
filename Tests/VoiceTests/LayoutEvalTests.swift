import Foundation
import XCTest
@testable import Voice

/// Layout replay (22 Nov 2026): ~40 dictation-style cases and a dozen Opt+1 drafts, with the cleanup
/// model's real replies cached in Tests/fixtures/layout-eval.json (from the live T4/v3c and ExampleModel servers).
/// Each case is scored on its layout only: one line, paragraphs, list items, command line breaks. A case
/// also fails when the layout passes dropped a word the model kept (only list markers may go).
///
/// FLOW_LAYOUT_DUMP=<path>: write the sections each case sends to the model, for the fetch script.
/// FLOW_LAYOUT_REPORT=<path>: write every case's output and verdict.
@MainActor
final class LayoutEvalTests: XCTestCase {
    struct Case: Codable {
        let id: String
        let kind: String
        let raw: String
        let expect: String
        var model: [String]?
        var opt1: Bool?
    }

    static var fixtureURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/layout-eval.json")
    }

    static func loadCases() -> [Case]? {
        guard let data = try? Data(contentsOf: fixtureURL) else { return nil }
        return try? JSONDecoder().decode([Case].self, from: data)
    }

    // MARK: Dictation path (as in AppDelegate's finish task, model reply given)

    static func formatted(_ raw: String) -> String {
        let segment = TranscriptSegment(text: raw, startTime: 0, endTime: max(1, Double(raw.split(separator: " ").count) / 2.5))
        return DictationTextPreparation.prepare(segments: [segment], formatter: TextFormatter(),
                                                pressEnterEnabled: false, autoPaste: false).command.text
    }

    /// The model's input sections: the whole text, or each line when it already has line breaks.
    static func sections(_ formatted: String) -> [String] {
        let longProse = formatted.split(whereSeparator: \.isWhitespace).count >= 120
        guard longProse || formatted.contains(where: \.isNewline) else { return [formatted] }
        return DictationTextPreparation.cleanupSections(in: formatted).map { String(formatted[$0]) }
    }

    static func cleaned(section: String, reply: String?) async -> String {
        let decision = await WhisperNowCleanupDecision.decide(
            source: section, reply: reply.map { .success(.text($0)) } ?? .failure(.notReady)) { nil }
        return Qwen3Polisher.applyMinimalPostprocessor(decision.text, userVocabulary: nil, personalityStyle: "excited")
    }

    /// Returns the text before the layout passes and the final text.
    static func dictation(_ c: Case) async -> (beforeLayout: String, final: String) {
        let formatted = formatted(c.raw)
        var polished: String
        let parts = sections(formatted)
        if parts.count == 1 {
            polished = await cleaned(section: parts[0], reply: c.model?.first)
        } else {
            let ranges = DictationTextPreparation.cleanupSections(in: formatted)
            var out = ""
            var cursor = formatted.startIndex
            for (i, range) in ranges.enumerated() {
                out += formatted[cursor..<range.lowerBound]
                let section = String(formatted[range])
                let reply = c.model.flatMap { $0.indices.contains(i) ? $0[i] : nil }
                let edited = await cleaned(section: section, reply: reply).trimmingCharacters(in: .whitespacesAndNewlines)
                out += edited.isEmpty || WhisperNowContentGuard.trip(source: section, output: edited) != nil ? section : edited
                cursor = range.upperBound
            }
            out += formatted[cursor...]
            polished = out
        }
        var text = DictationTextPreparation.finalize(polished: polished, formatted: formatted)
        text = DictationFinalPass.apply(text)
        text = ProperNounVocabulary.applyPreferredSpelling(text, terms: [])
        let before = text
        text = DictationParagraphs.formatDictation(text, isEmail: false)
        return (before, text)
    }

    // MARK: Opt+1 path (TypoFixModel reply given)

    static func opt1(_ c: Case) -> (beforeLayout: String, final: String) {
        let model = c.model?.first
        let judged = model.map { OptOneReferee.finish(source: c.raw, model: $0, protectedTerms: [], wait: true).text }
            ?? OptOneReferee.deterministic(c.raw, protectedTerms: [], wait: true)
        let snapped = TypoRepair.shared.snapVocabulary(judged, protectedTerms: [])
        let laidOut = OptOneLayout.apply(source: c.raw, edited: snapped)
        return (snapped, laidOut)
    }

    // MARK: Scoring

    enum Line: Character { case text = "T", blank = "_", bullet = "-", number = "N" }

    static func skeleton(_ text: String) -> [Line] {
        text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n").map { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { return .blank }
            if t.hasPrefix("- ") || t.hasPrefix("• ") { return .bullet }
            if t.range(of: #"^\d{1,2}[.)] "#, options: .regularExpression) != nil { return .number }
            return .text
        }
    }

    /// Prose blocks between blank lines, and list runs, in order: "P", "N3", "B4".
    static func blocks(_ text: String) -> [String] {
        var out: [String] = []
        var prose = false
        var list: (Line, Int)?
        func flushList() { if let l = list { out.append((l.0 == .number ? "N" : "B") + String(l.1)); list = nil } }
        for line in skeleton(text) {
            switch line {
            case .blank: flushList(); prose = false
            case .text:
                flushList()
                if !prose { out.append("P"); prose = true }
            case .bullet, .number:
                prose = false
                if let l = list, l.0 == line { list = (line, l.1 + 1) } else { flushList(); list = (line, 1) }
            }
        }
        flushList()
        return out
    }

    static func layoutMatches(_ text: String, expect: String) -> Bool {
        let lines = skeleton(text)
        if expect == "L" { return !text.trimmingCharacters(in: .whitespacesAndNewlines).contains("\n") }
        if expect.contains("|") {
            return String(lines.map(\.rawValue)) == expect.replacingOccurrences(of: "|", with: "")
        }
        let b = blocks(text)
        if expect.hasPrefix("P") {
            guard b.allSatisfy({ $0 == "P" }) else { return false }
            let range = expect.dropFirst().split(separator: "-").compactMap { Int($0) }
            guard let low = range.first else { return false }
            return b.count >= low && b.count <= (range.last ?? low)
        }
        // "lead+N3", "lead+B4+P1", "N3"
        var want: [String] = []
        for part in expect.split(separator: "+") {
            if part == "lead" { want.append("P") }
            else if part.hasPrefix("P"), let n = Int(part.dropFirst()) { want += Array(repeating: "P", count: n) }
            else { want.append(part.replacingOccurrences(of: "B", with: "B")) }
        }
        return b == want
    }

    static func words(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" && $0 != "’" })
            .map { $0.replacingOccurrences(of: "’", with: "'") }
    }

    /// Words the layout pass dropped that are not spoken list markers.
    static func droppedWords(before: String, after: String) -> [String] {
        let markers: Set<String> = ["first", "firstly", "second", "secondly", "third", "thirdly", "fourth", "fifth",
                                    "lastly", "finally", "number", "one", "two", "three", "four", "five", "step", "and", "or", "of", "all"]
        var have = Dictionary(words(after).map { ($0, 1) }, uniquingKeysWith: +)
        var dropped: [String] = []
        for w in words(before) {
            if let n = have[w], n > 0 { have[w] = n - 1 } else if !markers.contains(w) { dropped.append(w) }
        }
        return dropped
    }

    struct Report: Codable { let id: String; let kind: String; let expect: String; let pass: Bool; let output: String; let dropped: [String] }

    static func score(_ cases: [Case]) async -> (passed: Int, total: Int, reports: [Report]) {
        var reports: [Report] = []
        for c in cases {
            let result = c.opt1 == true ? opt1(c) : await dictation(c)
            let dropped = droppedWords(before: result.beforeLayout, after: result.final)
            let pass = layoutMatches(result.final, expect: c.expect) && dropped.isEmpty
            reports.append(Report(id: c.id, kind: c.kind, expect: c.expect, pass: pass, output: result.final, dropped: dropped))
        }
        return (reports.filter(\.pass).count, reports.count, reports)
    }

    func testDumpModelSections() throws {
        guard let path = ProcessInfo.processInfo.environment["FLOW_LAYOUT_DUMP"] else { throw XCTSkip("dump only") }
        guard let cases = Self.loadCases() else { throw XCTSkip("no fixture") }
        var out: [String: [String]] = [:]
        for c in cases { out[c.id] = c.opt1 == true ? [c.raw] : Self.sections(Self.formatted(c.raw)) }
        try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path))
    }

    /// 22 Nov 2026, model reply absent (the guard's fallback text): before the layout pass dictation 34/42,
    /// Opt+1 9/12; after it 42/42 and 12/12.
    func testLayoutReplay() async throws {
        guard let cases = Self.loadCases() else { throw XCTSkip("Private layout fixture is not on this machine") }
        let dictation = await Self.score(cases.filter { $0.opt1 != true })
        let opt1 = await Self.score(cases.filter { $0.opt1 == true })
        print("[LAYOUT] dictation \(dictation.passed)/\(dictation.total)  opt1 \(opt1.passed)/\(opt1.total)")
        for r in dictation.reports + opt1.reports where !r.pass {
            print("[LAYOUT] FAIL \(r.id) want \(r.expect) dropped \(r.dropped): \(r.output.replacingOccurrences(of: "\n", with: "⏎"))")
        }
        if let path = ProcessInfo.processInfo.environment["FLOW_LAYOUT_REPORT"] {
            let data = try JSONEncoder().encode(dictation.reports + opt1.reports)
            try data.write(to: URL(fileURLWithPath: path))
        }
        XCTAssertGreaterThanOrEqual(dictation.passed, Self.dictationFloor)
        XCTAssertGreaterThanOrEqual(opt1.passed, Self.opt1Floor)
    }

    /// FLOW_REAL_REPLAY=<in.json> FLOW_REAL_OUT=<out.json>: the layout pass over real pasted dictations
    /// ([{"id","pasted"}]) and Opt+1 results ([{"id","source","edited"}]); private data, never in the repo.
    func testRealReplay() throws {
        let env = ProcessInfo.processInfo.environment
        guard let input = env["FLOW_REAL_REPLAY"], let output = env["FLOW_REAL_OUT"] else { throw XCTSkip("replay only") }
        let rows = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: input))) as? [[String: String]] ?? []
        var out: [[String: String]] = []
        for row in rows {
            var r = row
            if let source = row["source"], let edited = row["edited"] {
                r["after"] = OptOneLayout.apply(source: source, edited: edited)
            } else if let pasted = row["pasted"] {
                r["after"] = DictationParagraphs.formatDictation(pasted)
            }
            out.append(r)
        }
        try JSONSerialization.data(withJSONObject: out, options: .prettyPrinted).write(to: URL(fileURLWithPath: output))
    }

    static let dictationFloor = 40
    static let opt1Floor = 11
}
