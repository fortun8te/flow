import Foundation

/// Boundary-only dictation edits. No field text is rewritten and every space
/// travels with the payload in the same undoable paste.
enum SmartInsertion {
    static func resolve(_ text: String, field: String?, selection: NSRange?,
                        preFormatted: Bool, code: Bool, messaging: Bool,
                        rememberedEnd: Character? = nil) -> String {
        let edit: Range<String.Index>? = field.flatMap { value in
            guard let selection else { return value.isEmpty ? value.startIndex..<value.endIndex : nil }
            let length = value.utf16.count
            guard selection.location != NSNotFound, selection.location >= 0, selection.length >= 0,
                  selection.location <= length, selection.length <= length - selection.location else { return nil }
            return Range(selection, in: value)
        }
        guard let field, let edit else {
            let base = !preFormatted && (code || messaging) ? withoutFinalPeriod(text) : text
            return boundarySpaced(base, after: rememberedEnd, allowBlocks: !code)
        }

        let before = field[..<edit.lowerBound]
        let after = field[edit.upperBound...]
        let selected = field[edit]
        let left = before.last
        let right = after.first
        let connector = "-_@/\\"
        let sentenceEnd = ".!?…"

        // Preformatted whitespace can be code indentation or a Markdown hard
        // break. Only plain dictation may discard stale model padding.
        var body = text
        if !preFormatted {
            let leadingTrimmed = text.drop(while: isHorizontalSpace)
            body = String(leadingTrimmed.reversed().drop(while: isHorizontalSpace).reversed())
        }
        guard !body.isEmpty else { return body }

        func tokenCharacter(_ character: Character?) -> Bool {
            character.map { $0.isLetter || $0.isNumber || $0 == "_" } ?? false
        }
        // A partial selection inside a word must remain a partial replacement.
        let joinsLeft = tokenCharacter(left) && tokenCharacter(selected.first ?? right)
        let joinsRight = tokenCharacter(right) && tokenCharacter(selected.last ?? left)
        func apostrophe(_ character: Character?) -> Bool { character == "'" || character == "’" }
        let insideContraction = (apostrophe(left) && tokenCharacter(before.dropLast().last) && tokenCharacter(selected.first ?? right))
            || (apostrophe(right) && tokenCharacter(after.dropFirst().first) && tokenCharacter(selected.last ?? left))
        // A URL/email split at punctuation is still one token, even in a prose app.
        let token = String(before.suffix(256).reversed().prefix(while: { !$0.isWhitespace }).reversed())
            + String(selected.prefix(256)) + String(after.prefix(256).prefix(while: { !$0.isWhitespace }))
        let insideLiteral = left.map { !$0.isWhitespace } == true
            && right.map { !$0.isWhitespace } == true
            && (token.contains("://") || token.contains("@"))

        let lastMeaningful = before.reversed()
            .drop(while: { isHorizontalSpace($0) || isClosingDelimiter($0) || $0 == "\"" || $0 == "'" }).first
        let continuesSentence = lastMeaningful.map { !$0.isNewline && !sentenceEnd.contains($0) } ?? false
        if !preFormatted && !insideLiteral && !insideContraction {
            if messaging || code || (continuesSentence && !body.contains(where: \.isNewline) && !isBlockLine(body)) { body = withoutFinalPeriod(body) }
            if edit.isEmpty && !joinsLeft && !insideLiteral && !body.contains(where: \.isNewline) && !isBlockLine(body) && (continuesSentence || (code && lastMeaningful != nil)),
               let first = body.first, first.isUppercase {
                let word = String(body.prefix(while: { $0.isLetter }))
                // Title case alone does not tell us whether this is a name.
                // Only familiar sentence starters are safe to decapitalize.
                if lowercaseStarters.contains(word) { body = first.lowercased() + body.dropFirst() }
            }
        }

        let startsBlock = !code && !insideLiteral && !insideContraction
            && isBlockLine(body.prefix(while: { !$0.isNewline }))
        let lastLine = String(body.reversed().prefix(while: { !$0.isNewline }).reversed())
        let continuationIndent = lastLine.prefix(while: { $0 == " " || $0 == "\t" })
        let blockContinuation = startsBlock && body.contains(where: \.isNewline)
            && (continuationIndent.count >= 2 || continuationIndent.contains("\t"))
        let rightContent = after.drop(while: isHorizontalSpace).first
        // Existing sentence/quote punctuation belongs to the replacement's
        // last line; moving it onto an empty line would orphan it.
        let adjacentClosing = rightContent.map { isClosingPunctuation($0) || isQuotationMark($0) } ?? false
        let endsBlock = !code && !insideLiteral && !insideContraction && !adjacentClosing
            && (isBlockLine(lastLine) || blockContinuation)

        // Keep punctuation already outside the replacement. Overlapping runs
        // retain the longer run, so an ellipsis stays three dots, not four.
        if !endsBlock, let last = body.last, let right, ".,!?;:…".contains(right) {
            if right == last {
                let overlap = min(body.reversed().prefix(while: { $0 == last }).count,
                                  after.prefix(while: { $0 == last }).count)
                if overlap < body.count { body.removeLast(overlap) }
            } else if last == ".", ",;:".contains(right), !body.hasSuffix(".."), !hasAbbreviationEnding(body) {
                body.removeLast()
            }
        }
        guard let first = body.first, let last = body.last else { return body }

        let beforeQuote = before.dropLast().last
        let afterQuote = after.dropFirst().first
        let leftOpensQuote = left.map(isQuotationMark) == true
            && (left.map(isOpeningDelimiter) == true || beforeQuote == nil || beforeQuote!.isWhitespace || isOpeningDelimiter(beforeQuote!))
        let rightClosesQuote = right.map(isQuotationMark) == true
            && (right.map(isClosingDelimiter) == true || afterQuote == nil || afterQuote!.isWhitespace || isClosingPunctuation(afterQuote!))
        let prefix = left.map {
            !$0.isWhitespace && !first.isWhitespace && !isOpeningDelimiter($0) && !isClosingPunctuation(first)
                && !connector.contains($0) && !connector.contains(first) && !joinsLeft && !insideLiteral && !insideContraction
                && !leftOpensQuote && !(code && $0 == ".")
        } ?? false
        let suffix = right.map {
            !$0.isWhitespace && !last.isWhitespace && !isOpeningDelimiter(last) && !isClosingPunctuation($0)
                && !connector.contains(last) && !connector.contains($0) && !joinsRight && !insideLiteral && !insideContraction
                && !rightClosesQuote
        } ?? false
        // A list/heading/fence needs its own line. Spaces cannot separate a
        // pasted '- item' from 'Tasks:' or from text after the selection. Only
        // the payload changes; the existing field remains one undoable edit.
        guard startsBlock || endsBlock else {
            return (prefix ? " " : "") + body + (suffix ? " " : "")
        }
        let lineBreak = field.last(where: \.isNewline).map(String.init) ?? "\n"
        let leftHasText = before.reversed().prefix(while: { !$0.isNewline }).contains { !$0.isWhitespace }
        let rightHasText = after.prefix(while: { !$0.isNewline }).contains { !$0.isWhitespace }
        let leading = startsBlock && leftHasText && !leftOpensQuote ? lineBreak : (prefix ? " " : "")
        let trailing = endsBlock && rightHasText && !rightClosesQuote ? lineBreak : (suffix ? " " : "")
        return leading + body + trailing
    }

    static func boundarySpaced(_ text: String, after previousEnd: Character?, allowBlocks: Bool = true) -> String {
        guard let previousEnd, let first = text.first else { return text }
        let endsWordOrSentence = previousEnd.isLetter || previousEnd.isNumber || ".!?:;…\"".contains(previousEnd)
            || isClosingDelimiter(previousEnd)
        if allowBlocks, endsWordOrSentence, !isQuotationMark(previousEnd),
           isBlockLine(text.prefix(while: { !$0.isNewline })) { return "\n" + text }
        guard endsWordOrSentence, !previousEnd.isWhitespace, !first.isWhitespace,
              !first.isPunctuation, !first.isSymbol else { return text }
        return " " + text
    }

    /// A bounded AX read for editors exposing StringForRange but not AXValue.
    /// Validation uses subtraction so malformed Accessibility offsets cannot overflow.
    static func contextRange(selection: NSRange, fieldLength: Int, radius: Int = 128) -> NSRange? {
        guard fieldLength >= 0, radius >= 0, selection.location != NSNotFound,
              selection.location >= 0, selection.length >= 0,
              selection.location <= fieldLength, selection.length <= fieldLength - selection.location,
              selection.length <= 1_024 else { return nil }
        let leftCount = min(radius, selection.location)
        let rightCount = min(radius, fieldLength - selection.location - selection.length)
        return NSRange(location: selection.location - leftCount, length: leftCount + selection.length + rightCount)
    }

    private static func isHorizontalSpace(_ character: Character) -> Bool {
        character.isWhitespace && !character.isNewline && character != "\t"
    }

    // Unicode categories include fullwidth/corner brackets and quotation
    // marks. Fixed ASCII-oriented lists added padding inside those delimiters
    // and mistook a quoted '- literal' for a new paragraph or list.
    private static func isOpeningDelimiter(_ character: Character) -> Bool {
        let category = character.unicodeScalars.first?.properties.generalCategory
        return category == .openPunctuation || category == .initialPunctuation
    }

    private static func isClosingDelimiter(_ character: Character) -> Bool {
        let category = character.unicodeScalars.first?.properties.generalCategory
        return category == .closePunctuation || category == .finalPunctuation
    }

    private static func isQuotationMark(_ character: Character) -> Bool {
        character.unicodeScalars.first?.properties.isQuotationMark == true
    }

    private static func isClosingPunctuation(_ character: Character) -> Bool {
        ".,!?;:%".contains(character) || isClosingDelimiter(character)
    }

    private static let blockStart = try! NSRegularExpression(
        pattern: #"^[ \t]*(?:(?:[-+*•>]|#{1,6}|[0-9]{1,3}[.)])[ \t]+|`{3,}|~{3,})"#)

    private static func isBlockLine<S: Sequence>(_ line: S) -> Bool where S.Element == Character {
        let text = String(line)
        return blockStart.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static let lowercaseStarters: Set<String> = [
        "A", "An", "The", "This", "That", "These", "Those", "There", "Here", "It",
        "They", "We", "You", "He", "She", "And", "But", "Or", "So", "Then", "Also",
        "Please", "Can", "Could", "Would", "Will", "Should", "Have", "Has", "Had",
        "Do", "Does", "Did", "Is", "Are", "Was", "Were", "Be", "Just"
    ]

    private static func withoutFinalPeriod(_ text: String) -> String {
        text.hasSuffix(".") && !text.hasSuffix("..") && !hasAbbreviationEnding(text) ? String(text.dropLast()) : text
    }

    private static func hasAbbreviationEnding(_ text: String) -> Bool {
        guard let token = text.split(whereSeparator: \.isWhitespace).last else { return false }
        let pieces = token.split(separator: ".", omittingEmptySubsequences: false)
        if pieces.count >= 3, pieces.last?.isEmpty == true,
           pieces.dropLast().allSatisfy({ $0.count == 1 && $0.first?.isLetter == true }) { return true }
        if pieces.count == 2, pieces.last?.isEmpty == true,
           pieces.first?.count == 1, pieces.first?.first?.isUppercase == true { return true }
        return ["mr.", "mrs.", "ms.", "dr.", "prof.", "sr.", "jr.", "etc.", "vs."].contains(token.lowercased())
    }
}
