import Foundation

/// Layout belongs to the dictation, including a command whose entire payload is
/// a line break. Cleanup models edit the contents of lines, not their separators.
enum DictationLayout {
    /// Original separators stay outside every range. Fenced and indented code
    /// is copied verbatim, never submitted as isolated prose without its fence.
    static func cleanupSections(in text: String, limit: Int) -> [Range<String.Index>] {
        guard limit > 0 else { return [] }
        let fences = DictationFinalPass.fencedCodeRanges(in: text)
        var fenceIndex = 0
        var ranges: [Range<String.Index>] = []
        for line in text.split(whereSeparator: \.isNewline) {
            while fenceIndex < fences.count && fences[fenceIndex].upperBound <= line.startIndex {
                fenceIndex += 1
            }
            if fenceIndex < fences.count && fences[fenceIndex].overlaps(line.startIndex..<line.endIndex) { continue }
            let indent = line.prefix(while: { $0 == " " || $0 == "\t" })
            if indent.count >= 4 || indent.contains("\t") { continue }
            var start = line.startIndex
            while start < line.endIndex {
                while start < line.endIndex && text[start].isWhitespace { text.formIndex(after: &start) }
                guard start < line.endIndex else { break }
                let limitIndex = text.index(start, offsetBy: limit, limitedBy: line.endIndex) ?? line.endIndex
                var end = limitIndex
                if limitIndex < line.endIndex {
                    let prefix = text[start...limitIndex]
                    let mid = text.index(start, offsetBy: limit / 2)
                    let sentenceEnd = prefix.indices.reversed().first { index in
                        index > mid && text[index].isWhitespace && ".!?".contains(text[text.index(before: index)])
                    }
                    if let boundary = sentenceEnd ?? prefix.lastIndex(where: \.isWhitespace) {
                        end = boundary
                    } else {
                        // Long unbroken identifiers/URLs are copied, not split.
                        start = text[limitIndex..<line.endIndex].firstIndex(where: \.isWhitespace) ?? line.endIndex
                        continue
                    }
                }
                var contentEnd = end
                while contentEnd > start && text[text.index(before: contentEnd)].isWhitespace {
                    text.formIndex(before: &contentEnd)
                }
                if start < contentEnd { ranges.append(start..<contentEnd) }
                start = end
            }
        }
        return ranges
    }

    static func isBreakOnly(_ text: String) -> Bool {
        text.contains(where: \.isNewline) && text.allSatisfy(\.isWhitespace)
    }

    /// A whole-document cleanup (for example in a code editor) must not erase
    /// existing lines. When the model returns the same line structure, retain
    /// its word edits while restoring the source's exact separators, indentation
    /// and hard-break spaces. A changed structure falls back to the source;
    /// intentional new layout is added later by the deterministic layout pass.
    static func preservingLineBreaks(in edited: String, from source: String) -> String {
        guard source.contains(where: \.isNewline) else { return edited }
        let candidate = restoringBoundaryBreaks(in: edited, from: source)
        let originalLines = source.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        let editedLines = candidate.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        guard originalLines.count == editedLines.count else { return source }
        for (original, replacement) in zip(originalLines, editedLines) {
            if original.allSatisfy(\.isWhitespace) != replacement.allSatisfy(\.isWhitespace) { return source }
        }
        var result = ""
        result.reserveCapacity(candidate.utf8.count)
        var cursor = source.startIndex
        for (original, replacement) in zip(originalLines, editedLines) {
            result += source[cursor..<original.startIndex]
            if original.allSatisfy(\.isWhitespace) {
                result += original
            } else {
                let lead = original.prefix(while: \.isWhitespace)
                let tail = original.reversed().prefix(while: \.isWhitespace).reversed()
                result += String(lead) + replacement.trimmingCharacters(in: .whitespaces) + String(tail)
            }
            cursor = original.endIndex
        }
        result += source[cursor...]
        return result
    }

    private static let structuredLine = try! NSRegularExpression(
        pattern: #"^[ \t]*(?:(?:[-+*•>]|#{1,6}|[0-9]{1,3}[.)])[ \t]+|`{3,}|~{3,}|(?:let|var|const|func|def|class|struct|import|return)[ \t]+.*[;=()])"#)

    /// Model padding may be discarded. Rejoin plain prose that a model or its
    /// postprocessor split inside a section, retaining its useful word edits.
    /// Lists/code cannot be flattened safely and are rejected. The final layout
    /// pass runs after the original source separators have been reassembled.
    static func singleLineReply(_ text: String) -> String? {
        let content = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return nil }
        guard content.contains(where: \.isNewline) else { return content }
        guard !content.contains(where: { "`{}".contains($0) }), !content.contains("</") else { return nil }
        let lines = content.split(whereSeparator: \.isNewline)
        guard lines.allSatisfy({ line in
            structuredLine.firstMatch(in: String(line), range: NSRange(line.startIndex..., in: line)) == nil
        }) else { return nil }
        return lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Models commonly trim outer whitespace. Restore a deliberate leading or
    /// trailing break (and its indentation) without changing the edited words.
    /// Keep CRLF and Unicode separators exactly as supplied by the source.
    static func restoringBoundaryBreaks(in edited: String, from source: String) -> String {
        guard source.contains(where: \.isNewline) else { return edited }
        if isBreakOnly(source) { return source }
        let leading = source.prefix(while: \.isWhitespace)
        let trailing = source.reversed().prefix(while: \.isWhitespace).reversed()
        var result = edited
        if leading.contains(where: \.isNewline) {
            result = String(leading) + result.drop(while: \.isWhitespace)
        }
        if trailing.contains(where: \.isNewline) {
            result = String(result.reversed().drop(while: \.isWhitespace).reversed()) + String(trailing)
        }
        return result
    }
}
