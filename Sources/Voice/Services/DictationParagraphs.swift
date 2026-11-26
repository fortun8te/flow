import Foundation
import NaturalLanguage

/// Layout passes run after cleanup. Paragraphs preserve the text, and lists
/// replace only explicit enumeration and separator tokens.
enum DictationParagraphs {
    private static let minimumDocumentWords = 120
    private static let minimumParagraphWords = 32
    private static let targetParagraphWords = 90
    private static let minimumTopicSwitchWords = 30
    private static let minimumWordsBeforeTopicSwitch = 16
    private static let transitions = [
        "also ", "another thing", "and one more", "as for ", "finally ",
        "moving on", "on another note", "separately "
    ]
    private static let explicitTopicChanges = [
        "on another note", "one more thing", "separately", "different topic",
        "los daarvan", "ander onderwerp", "nog iets anders"
    ]
    private static let continuationOpeners = [
        "and", "but", "so", "because", "or", "which", "then", "cause", "like", "en", "maar", "dus", "want", "omdat"
    ]
    private static let ordinalWords = [
        "first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth"
    ]
    private static let cardinalWords = [
        "one", "two", "three", "four", "five", "six", "seven", "eight", "nine"
    ]
    private static let dutchOrdinals = [
        "eerste", "tweede", "derde", "vierde", "vijfde", "zesde", "zevende", "achtste", "negende"
    ]
    private static let enumerationMarker: NSRegularExpression = {
        let ordinals = (ordinalWords + dutchOrdinals).joined(separator: "|")
        let cardinals = cardinalWords.joined(separator: "|")
        let boundary = #"(?:\A[\t ]*|(?<=[.!?,:;])[\t ]+)"#
        let punctuated = #"(?:(?<digit>[1-9])[.)]|(?<word>"# + ordinals + "|" + cardinals + #")[,.:])[\t ]+"#
        let numberWord = #"\bnumber[\t ]+(?<named>"# + cardinals + #")\b[,.:]?[\t ]+"#
        // "First we need milk. Secondly, call Noor. Finally, ..." at a sentence start, without a comma.
        let sentenceStart = #"(?:\A[\t ]*|(?<=[.!?:;])[\t ]+)"#
        let bare = sentenceStart + #"(?:(?:and|en|ten)[\t ]+)?(?<bare>"# + (ordinalWords + dutchOrdinals).joined(separator: "|")
            + #")(?:ly)?(?:[\t ]+of[\t ]+all)?,?[\t ]+"#
        let last = sentenceStart + #"(?:and[\t ]+)?(?<last>finally|lastly)[,:][\t ]+"#
        return try! NSRegularExpression(pattern: "(?i)" + boundary + punctuated + "|" + numberWord + "|" + bare + "|" + last)
    }()
    private static let dutchCardinals = ["een", "twee", "drie", "vier", "vijf", "zes", "zeven", "acht", "negen"]
    private static let spokenHeading = try! NSRegularExpression(pattern:
        #"(?i)\A[ \t]*(?:here (?:are|is) |ik heb )?(two|three|four|five|six|seven|eight|nine|twee|drie|vier|vijf|zes|zeven|acht|negen|[2-9]) +(?:things|items|points|steps|tasks|options|ideas|dingen|punten|stappen|taken|opties|ideeën)(?: to do)?[.:][ \t]+"#)
    private static let bareOrdinals = try! NSRegularExpression(pattern:
        #"(?i)\b(?:ten[ \t]+)?("# + (ordinalWords + dutchOrdinals).joined(separator: "|") + #")[,.:]?[ \t]+"#)
    private static let countedListHeading = try! NSRegularExpression(
        pattern: #"(?i)\b(two|three|four|five|six|seven|eight|nine|twee|drie|vier|vijf|zes|zeven|acht|negen|[2-9]) +(?:things|items|points|steps|tasks|options|ideas|dingen|punten|stappen|taken|opties|ideeën)\b"#
    )
    private static let existingStructure = try! NSRegularExpression(
        pattern: #"\A(?:[-+*•>]|[0-9]{1,3}[.)]|#{1,6})[\t ]+"#
    )
    private static let finalConjunction = try! NSRegularExpression(pattern: #"(?i)[\t ]+(?:and|en)[\t ]+"#)
    private static let emailGreeting = try! NSRegularExpression(
        pattern: #"\A(?:Hi|Hey|Hello|Dear|Hoi|Hallo|Beste)(?: +[\p{Lu}][\p{L}'’\-]*){0,3}[,!][\t ]+"#
    )
    private static let emailSignoff = try! NSRegularExpression(
        pattern: #"(?<=[.!?])[\t ]+(?=(?:Thanks|Thank you|Best regards|Groeten|Dank je)[.!]?\z)"#
    )

    static func formatDictation(_ input: String, isEmail: Bool = false) -> String {
        guard input.contains(where: \.isNewline) else { return formatLine(input, isEmail: isEmail) }
        var result = ""
        var cursor = input.startIndex
        var fence: String?
        for span in input.split(whereSeparator: \.isNewline) {
            result += input[cursor..<span.startIndex]
            let line = String(span)
            let trimmed = line.drop(while: \.isWhitespace)
            if let marker = ["```", "~~~"].first(where: trimmed.hasPrefix) {
                if fence == nil { fence = marker }
                else if fence == marker { fence = nil }
                result += line
            } else if fence != nil || line.first?.isWhitespace == true ||
                        existingStructure.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil {
                result += line
            } else {
                result += formatLine(line, isEmail: isEmail && span.startIndex == input.startIndex)
            }
            cursor = span.endIndex
        }
        result += input[cursor...]
        return result
    }

    private static func formatLine(_ input: String, isEmail: Bool = false) -> String {
        let trimmed = input.drop(while: \.isWhitespace)
        if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { return input }
        // Preserve already formatted bullet/heading lines, including a single
        // list item. Inline numbered enumerations still go through detection.
        if existingStructure.firstMatch(in: input, range: NSRange(input.startIndex..., in: input)) != nil,
           input.first?.isNumber != true { return input }
        if isEmail, let email = formatEmail(input) { return email }
        if let list = explicitList(input) { return list }
        if let list = countedSpokenList(input) { return list }
        if let list = countedList(input) { return list }
        if let list = colonEnumeration(input) { return list }
        return readableParagraphs(input)
    }

    static func format(_ input: String) -> String {
        paragraphs(input, allowShortTopicBreaks: false)
    }

    /// Replace consecutive spoken list markers and leave the item text intact.
    private static func explicitList(_ input: String) -> String? {
        let matches = enumerationMarker.matches(in: input, range: NSRange(input.startIndex..., in: input))
        guard matches.count >= 2 else { return nil }
        var markers: [Range<String.Index>] = []
        for match in matches {
            guard let marker = Range(match.range, in: input) else { return nil }
            var position: Int?
            for group in ["digit", "word", "named", "bare"] {
                guard let range = Range(match.range(withName: group), in: input) else { continue }
                let value = input[range].lowercased()
                let index = ordinalWords.firstIndex(of: value) ?? cardinalWords.firstIndex(of: value)
                    ?? dutchOrdinals.firstIndex(of: value)
                position = Int(value) ?? index.map { $0 + 1 }
            }
            // "Finally," / "Lastly," closes a list of at least two.
            if Range(match.range(withName: "last"), in: input) != nil {
                guard markers.count >= 2, match == matches.last else { return nil }
                position = markers.count + 1
            }
            guard let position else { continue }
            if position != markers.count + 1 {
                // A later stray ordinal ("the first one") after a complete run ends the list there.
                if markers.count >= 2 { break }
                return nil
            }
            markers.append(marker)
        }
        guard let first = markers.first else { return nil }
        let lead = input[..<first.lowerBound].trimmingCharacters(in: .whitespaces)
        // A numbered reference in the middle of a sentence is not a list heading.
        guard lead.isEmpty || lead.last.map({ ".!?:;".contains($0) }) == true else { return nil }
        var items: [String] = []
        for (offset, marker) in markers.enumerated() {
            let next = offset + 1
            let end = markers.indices.contains(next) ? markers[next].lowerBound : input.endIndex
            let item = input[marker.upperBound..<end].trimmingCharacters(in: .whitespaces)
            guard !item.isEmpty else { return nil }
            items.append("\(offset + 1). \(capitalizedItem(item))")
        }
        return (lead.isEmpty ? "" : lead + "\n\n") + items.joined(separator: "\n")
    }

    /// Recognize a spoken list with a declared count and every ordinal in order.
    private static func countedSpokenList(_ input: String) -> String? {
        let whole = NSRange(input.startIndex..., in: input)
        guard let header = spokenHeading.firstMatch(in: input, range: whole),
              let heading = Range(header.range, in: input), let countToken = Range(header.range(at: 1), in: input) else {
            return nil
        }
        let countWord = input[countToken].lowercased()
        let count = Int(countWord) ?? (cardinalWords.firstIndex(of: countWord) ?? dutchCardinals.firstIndex(of: countWord))
            .map { $0 + 1 }
        let matches = bareOrdinals.matches(in: input, range: NSRange(heading.upperBound..<input.endIndex, in: input))
        guard count == matches.count, matches.count >= 2 else { return nil }
        var markers: [Range<String.Index>] = []
        for (index, match) in matches.enumerated() {
            guard let marker = Range(match.range, in: input), let value = Range(match.range(at: 1), in: input) else { return nil }
            let word = input[value].lowercased()
            guard ordinalWords.firstIndex(of: word) == index || dutchOrdinals.firstIndex(of: word) == index else {
                return nil
            }
            markers.append(marker)
        }
        guard markers[0].lowerBound == heading.upperBound else { return nil }
        var items: [String] = []
        for (index, marker) in markers.enumerated() {
            let end = index + 1 < markers.count ? markers[index + 1].lowerBound : input.endIndex
            let item = input[marker.upperBound..<end].trimmingCharacters(in: .whitespaces)
            guard !item.isEmpty else { return nil }
            items.append("\(index + 1). \(capitalizedItem(item))")
        }
        return input[heading].trimmingCharacters(in: .whitespaces) + "\n\n" + items.joined(separator: "\n")
    }

    /// A count in the heading and the same number of comma-delimited items
    /// give enough evidence to lay out a list without inferring its contents.
    private static func countedList(_ input: String) -> String? {
        guard let colon = input.firstIndex(of: ":") else { return nil }
        let heading = input[..<colon]
        guard heading.count <= 150,
              let namedCount = countedListHeading.firstMatch(in: input, range: NSRange(input.startIndex..<colon, in: input)),
              let range = Range(namedCount.range(at: 1), in: input) else { return nil }
        let countWord = input[range].lowercased()
        guard let count = Int(countWord) ?? (cardinalWords.firstIndex(of: countWord) ?? dutchCardinals.firstIndex(of: countWord))
            .map({ $0 + 1 }) else { return nil }
        let body = input[input.index(after: colon)...]
        var items = body.components(separatedBy: ", ").map { $0.trimmingCharacters(in: .whitespaces) }
        guard items.count >= 2, !items.contains(where: \.isEmpty),
              !body.contains(where: { "\"“”".contains($0) }) else { return nil }
        let last = items.count - 1
        let conjunctions = ["and", "or", "en", "of"]
        if count == items.count,
           let conjunction = conjunctions.first(where: { items[last].lowercased().hasPrefix($0 + " ") }) {
            items[last] = String(items[last].dropFirst(conjunction.count + 1)).trimmingCharacters(in: .whitespaces)
            guard !items[last].isEmpty else { return nil }
        } else if count == items.count + 1 {
            // At least one comma and exactly one possible final conjunction
            // are needed before we infer a non-Oxford list boundary.
            let tail = items[last]
            let lower = tail.lowercased()
            guard !conjunctions.contains(where: { lower.hasPrefix($0 + " ") }) else { return nil }
            let matches = finalConjunction.matches(in: tail, range: NSRange(tail.startIndex..., in: tail))
            guard matches.count == 1, let match = Range(matches[0].range, in: tail) else { return nil }
            items[last] = String(tail[..<match.lowerBound])
            items.append(String(tail[match.upperBound...]))
        } else {
            return nil
        }
        let list = items.enumerated().map { "\($0.offset + 1). \(capitalizedItem($0.element))" }.joined(separator: "\n")
        return heading + ":\n\n" + list
    }

    /// "we have: overview, sleep, recovery, strain, health and walking. I think ..." becomes a bullet
    /// list, as Wispr lays it out: a colon, then at least four short comma items ending the sentence.
    private static func colonEnumeration(_ input: String) -> String? {
        guard let colon = input.firstIndex(of: ":") else { return nil }
        let heading = input[...colon]
        guard heading.count <= 150, !heading.contains(where: \.isNumber) || heading.count > 3 else { return nil }
        let afterColon = input[input.index(after: colon)...]
        guard let stop = afterColon.firstIndex(where: { ".!?".contains($0) }) else { return nil }
        let body = afterColon[..<stop].trimmingCharacters(in: .whitespaces)
        let rest = afterColon[afterColon.index(after: stop)...].trimmingCharacters(in: .whitespaces)
        // Numbers, quotes or brackets mean prose or settings ("25, 1 on spacing, 0.8 scale"), not a list.
        guard !body.contains(where: { "\"“”;:()".contains($0) || $0.isNumber }) else { return nil }
        var items = body.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard items.count >= 3, let lastRaw = items.last else { return nil }
        // Final "and"/"or"/"en": "health and walking" or ", and walking".
        let lower = lastRaw.lowercased()
        if let conj = ["and ", "or ", "en ", "of "].first(where: lower.hasPrefix) {
            items[items.count - 1] = String(lastRaw.dropFirst(conj.count))
        } else if let match = finalConjunction.firstMatch(in: lastRaw, range: NSRange(lastRaw.startIndex..., in: lastRaw)),
                  let range = Range(match.range, in: lastRaw) {
            items[items.count - 1] = String(lastRaw[..<range.lowerBound])
            items.append(String(lastRaw[range.upperBound...]))
        }
        items = items.map { $0.trimmingCharacters(in: .whitespaces) }
        guard items.count >= 4,
              items.allSatisfy({ !$0.isEmpty && $0.split(separator: " ").count <= 4 }) else { return nil }
        // "every screen, every tab, every element": rhetoric, not a list.
        let multiWord = items.filter { $0.contains(" ") }
        let leads = Dictionary(grouping: multiWord, by: { $0.split(separator: " ").first.map { $0.lowercased() } ?? "" })
        guard (leads.values.map(\.count).max() ?? 0) < max(2, items.count - 1) else { return nil }
        let list = items.map { "- " + capitalizedItem($0) }.joined(separator: "\n")
        let tail = rest.isEmpty ? "" : "\n\n" + readableParagraphs(String(rest))
        return heading.trimmingCharacters(in: .whitespaces) + "\n\n" + list + tail
    }

    /// List items start with a capital, as Wispr writes them. A lowercase identifier
    /// ("v2.1", "iPhone", "https://...") is left as spoken.
    static func capitalizedItem<S: StringProtocol>(_ item: S) -> String {
        let text = String(item)
        guard let first = text.first, first.isLowercase else { return text }
        let firstWord = text.prefix { !$0.isWhitespace }
        if firstWord.contains(where: { $0.isUppercase || $0.isNumber || "./:@_".contains($0) }) { return text }
        return first.uppercased() + text.dropFirst()
    }

    private static func formatEmail(_ input: String) -> String? {
        let whole = NSRange(input.startIndex..., in: input)
        guard let match = emailGreeting.firstMatch(in: input, range: whole),
              let greetingRange = Range(match.range, in: input) else { return nil }
        let greeting = input[greetingRange].trimmingCharacters(in: .whitespaces)
        let body = String(input[greetingRange.upperBound...])
        guard !body.isEmpty else { return nil }
        if let match = emailSignoff.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)),
           let gap = Range(match.range, in: body) {
            return greeting + "\n\n" + formatDictation(String(body[..<gap.lowerBound]))
                + "\n\n" + body[gap.upperBound...]
        }
        return greeting + "\n\n" + formatDictation(body)
    }

    // MARK: Readable paragraphs (dictation)

    /// From this many words a dictation is laid out in short paragraphs. Below it, only a spoken topic change
    /// ("on another note", "separately") can split it, and under `oneLineWords` it always stays one line.
    static let readableMinimumWords = 40
    static let oneLineWords = 25
    private static let readableTargetWords = 26
    private static let readableShortestParagraph = 10
    /// Sentence openers that start a new thought: a break before one is preferred.
    private static let topicOpeners = [
        "also", "and also", "oh and", "oh, and", "another thing", "one more thing", "the other thing", "on another note",
        "separately", "anyway", "anyways", "by the way", "btw", "plus", "moving on", "different topic", "next",
        "then also", "okay so", "ok so", "okay, so", "alright", "secondly", "thirdly", "finally", "lastly",
        "right now", "currently", "meanwhile", "verder", "ook", "los daarvan"
    ]
    /// Short sentences that close a thought ("I don't know."): a break after one is preferred.
    private static let closers = [
        "i don't know", "i dont know", "i'm not sure", "im not sure", "not sure", "i'm not really sure", "whatever",
        "if that makes sense", "you know", "that's it", "yeah", "but yeah", "idk", "ik weet het niet"
    ]

    private static func opening(_ sentence: Substring) -> String {
        sentence.drop(while: \.isWhitespace).lowercased().replacingOccurrences(of: "’", with: "'")
    }

    private static func startsWithAny(_ opening: String, _ phrases: [String]) -> Bool {
        phrases.contains { opening.hasPrefix($0 + " ") || opening.hasPrefix($0 + ",") || opening.hasPrefix($0 + ":") }
    }

    /// Splits one line of dictation into short paragraphs at sentence ends (22 Nov 2026: 15 of his last 20
    /// dictations of 40-110 words pasted as one block). Lowest-cost split: paragraphs of about 26-36 words, never
    /// under 10, a break preferred before "Also, ..." and after "I don't know.", avoided before "And/But/So".
    /// Only line breaks are added; every word and mark stays as it was.
    static func readableParagraphs(_ input: String) -> String {
        guard !input.contains(where: \.isNewline) else { return input }
        let total = input.split(whereSeparator: \.isWhitespace).count
        guard total >= oneLineWords else { return input }
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = input
        let ranges = tokenizer.tokens(for: input.startIndex..<input.endIndex)
        guard ranges.count > 1 else { return input }
        let counts = ranges.map { input[$0].split(whereSeparator: \.isWhitespace).count }
        let n = ranges.count
        // Cost of a break before sentence i (1..<n); nil = not allowed.
        func breakCost(_ i: Int) -> Double? {
            let range = ranges[i]
            guard range.lowerBound > input.startIndex,
                  input[input.index(before: range.lowerBound)].isWhitespace || input[range.lowerBound].isWhitespace else { return nil }
            let open = opening(input[range])
            let explicit = startsWithAny(open, explicitTopicChanges)
            // Below the readable length only a spoken topic change splits, and then always.
            if total < readableMinimumWords { return explicit ? -20 : nil }
            var cost = 0.0
            if explicit || startsWithAny(open, topicOpeners) { cost -= 1.6 }
            else if startsWithAny(open, continuationOpeners) { cost += 2.0 }
            let previous = opening(input[ranges[i - 1]]).trimmingCharacters(in: CharacterSet(charactersIn: ".!?… "))
            if counts[i - 1] <= 7, closers.contains(where: { previous == $0 || previous.hasSuffix(", " + $0) }) { cost -= 0.8 }
            return cost
        }
        // These depend only on the input, not on a DP transition. Compute
        // them once instead of re-tokenizing every sentence for each candidate.
        let breakCosts: [Double?] = (0..<n).map { $0 == 0 ? 0 : breakCost($0) }
        let target = Double(readableTargetWords) + min(10, max(0, Double(total - readableMinimumWords) / 12))
        func paragraphCost(_ words: Int) -> Double {
            if words < readableShortestParagraph { return 8 }
            let w = Double(words)
            let off = w < target ? (target - w) / 12 : (w - target) / 18
            return off * off + 0.3
        }
        // best[j]: cheapest layout of sentences 0..<j; from[j]: where its last paragraph starts.
        var best = [Double](repeating: .infinity, count: n + 1)
        var from = [Int](repeating: 0, count: n + 1)
        best[0] = 0
        var prefix = [0]
        for c in counts { prefix.append(prefix.last! + c) }
        for j in 1...n {
            for i in 0..<j {
                guard best[i].isFinite else { continue }
                var cost = best[i] + paragraphCost(prefix[j] - prefix[i])
                if i > 0 {
                    guard let b = breakCosts[i] else { continue }
                    cost += b
                }
                // Below the readable length a topic break still needs 10+ words on each side.
                if total < readableMinimumWords, i > 0, prefix[j] - prefix[i] < readableShortestParagraph { continue }
                if cost < best[j] { best[j] = cost; from[j] = i }
            }
        }
        var starts: [Int] = []
        var j = n
        while j > 0 { let i = from[j]; if i > 0 { starts.append(i) }; j = i }
        guard !starts.isEmpty else { return input }
        var output: [String] = []
        var start = input.startIndex
        for i in starts.reversed() + [n] {
            let end = i < n ? ranges[i].lowerBound : input.endIndex
            output.append(input[start..<end].trimmingCharacters(in: .whitespaces))
            start = end
        }
        return output.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    private static func paragraphs(_ input: String, allowShortTopicBreaks: Bool) -> String {
        // Keep deliberate formatting from a command, the model or the user.
        guard !input.contains(where: \.isNewline) else { return input }
        let wordCount = input.split(whereSeparator: \.isWhitespace).count
        let longForm = wordCount >= minimumDocumentWords
        guard longForm || (allowShortTopicBreaks && wordCount >= minimumTopicSwitchWords) else { return input }

        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = input
        let sentences = tokenizer.tokens(for: input.startIndex..<input.endIndex)
        guard sentences.count > 1 else { return input }

        var breaks: [String.Index] = []
        var paragraphWords = 0
        for range in sentences {
            let sentence = input[range]
            let words = sentence.split(whereSeparator: \.isWhitespace).count
            guard words > 0 else { continue }
            let opening = sentence.drop(while: \.isWhitespace).lowercased()
            let explicitSwitch = explicitTopicChanges.contains {
                opening.hasPrefix($0 + " ") || opening.hasPrefix($0 + ",") || opening.hasPrefix($0 + ":")
            }
            let startsTopic = (allowShortTopicBreaks && explicitSwitch)
                || (longForm && transitions.contains { opening.hasPrefix($0) })
            // A sentence that carries on the last one ("And because ...", "So it's ...") never opens a
            // paragraph on length alone; the break waits for the next fresh sentence.
            let continues = continuationOpeners.contains { opening.hasPrefix($0 + " ") || opening.hasPrefix($0 + ",") }
            let exceedsTarget = longForm && paragraphWords + words > targetParagraphWords && !continues
            let minimumWords = longForm ? minimumParagraphWords : minimumWordsBeforeTopicSwitch
            if paragraphWords >= minimumWords, startsTopic || exceedsTarget,
               range.lowerBound > input.startIndex,
               input[input.index(before: range.lowerBound)].isWhitespace || input[range.lowerBound].isWhitespace {
                breaks.append(range.lowerBound)
                paragraphWords = 0
            }
            paragraphWords += words
        }
        guard !breaks.isEmpty else { return input }

        var output: [String] = []
        var start = input.startIndex
        for end in breaks + [input.endIndex] {
            output.append(input[start..<end].trimmingCharacters(in: .whitespaces))
            start = end
        }
        return output.joined(separator: "\n\n")
    }
}
