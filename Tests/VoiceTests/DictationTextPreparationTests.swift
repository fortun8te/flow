import XCTest
@testable import Voice

final class DictationTextPreparationTests: XCTestCase {
    @MainActor func testCleanupPreservesExactFilenameCase() {
        XCTAssertEqual(DictationTextPreparation.finalize(polished: "Open the archive-2.txt file.", formatted: "open the Archive-2.TXT file"),
                       "Open the Archive-2.TXT file.")
        XCTAssertEqual(DictationTextPreparation.preservingFilenameCase("Use a.Pdf and b.Pdf.", original: "Use A.pdf, a.pdf and b.pdf."),
                       "Use a.Pdf and b.pdf.")
    }

    func testExactDictionarySpellingsProtectSimilarWordsAndLiterals() {
        let input = "acmekit and demo board can wait. Don't change acmekits, https://acmekit.example, or `acmekit`."
        let expected = input.replacingOccurrences(of: "acmekit and demo board", with: "AcmeKit and Demo Board")
        XCTAssertEqual(ProperNounVocabulary.applyPreferredSpelling(input, terms: ["AcmeKit", "acmekit", "Demo Board"]), expected)
    }

    @MainActor func testEmptyAndUnsupportedScriptDoNotCreatePasteText() {
        let formatter = TextFormatter(config: TextFormatterConfig())
        XCTAssertEqual(DictationTextPreparation.prepare(segments: [], formatter: formatter, pressEnterEnabled: true, autoPaste: true).rejection, .empty)
        XCTAssertTrue(DictationTextPreparation.predominantlyNonLatin("Привет мир"))
        XCTAssertFalse(DictationTextPreparation.predominantlyNonLatin("Please send the notes tomorrow"))
    }
    @MainActor func testDeliveryNeverSubmitsWhenAutoPasteIsDisabled() {
        let parsed = TrailingPressEnter.Parsed(text: "Send this.", shouldSubmit: true)
        let intent = DictationTextPreparation.delivery(autoCopy: false, autoPaste: false, skipPolish: false,
            formatted: "send this", final: "Send this.", fieldContextProvided: true, command: parsed)
        XCTAssertFalse(intent.shouldPaste)
        XCTAssertFalse(intent.shouldSubmit)
        XCTAssertTrue(intent.restoreClipboard)
        XCTAssertFalse(intent.requireCapturedTarget)
    }
    @MainActor func testEmptyModelOutputKeepsFormattedText() {
        XCTAssertEqual(DictationTextPreparation.finalize(polished: "   ", formatted: "A synthetic line."), "A synthetic line.")
    }

    @MainActor func testLayoutCommandSurvivesFinalizeAndDeliveryWithoutPolish() {
        for source in ["\n", "\n\n", "\nNext line.\n"] {
            XCTAssertEqual(DictationTextPreparation.finalize(polished: source.trimmingCharacters(in: .whitespacesAndNewlines),
                                                            formatted: source), source)
            let intent = DictationTextPreparation.delivery(autoCopy: false, autoPaste: true, skipPolish: true,
                formatted: source, final: source, fieldContextProvided: false,
                command: .init(text: source, shouldSubmit: false))
            XCTAssertTrue(intent.shouldPaste)
            XCTAssertTrue(intent.preFormatted)
            XCTAssertFalse(intent.shouldSubmit)
        }
    }

    func testDelayedPasteRefusesToFollowTheUserToAnotherApp() {
        XCTAssertTrue(CursorPaster.canPasteInApp(captured: "com.example.editor", current: "com.example.editor"))
        XCTAssertFalse(CursorPaster.canPasteInApp(captured: "com.example.editor", current: "com.example.chat"))
        XCTAssertFalse(CursorPaster.canPasteInApp(captured: "com.example.editor", current: nil))
        XCTAssertTrue(CursorPaster.canPasteInApp(captured: nil, current: "com.example.editor"))
    }

    func testPasteSpacingUsesBothSidesOfTheLiveSelection() {
        let chrome = "com.google.Chrome"
        func paste(_ text: String, into field: String, at location: Int, replacing length: Int = 0,
                   preFormatted: Bool = true) -> String {
            let selection = NSRange(location: location, length: length)
            let insertion = CursorPaster.resolvedInsertion(text, field: field, selection: selection,
                                                          preFormatted: preFormatted, bundleID: chrome)
            return (field as NSString).replacingCharacters(in: selection, with: insertion)
        }

        XCTAssertEqual(paste(" there ", into: "Hello ", at: 6, preFormatted: false), "Hello there")
        XCTAssertEqual(paste("there", into: "Hello", at: 5), "Hello there")
        XCTAssertEqual(paste(" there ", into: "Hello, friend", at: 5, preFormatted: false), "Hello there, friend")
        XCTAssertEqual(paste("a ", into: "HelloBRIDGEworld", at: 5, replacing: 6, preFormatted: false), "Helloaworld")
        XCTAssertEqual(paste("there", into: "Hello old world", at: 5, replacing: 5), "Hello there world")
        XCTAssertEqual(paste(" detail ", into: "Read () now", at: 6, preFormatted: false), "Read (detail) now")
        XCTAssertEqual(paste(" 🎉 ", into: "Done ", at: 5, preFormatted: false), "Done 🎉")
        XCTAssertEqual(paste("one", into: "👩🏽‍💻 two", at: "👩🏽‍💻 ".utf16.count), "👩🏽‍💻 one two")
        XCTAssertEqual(paste("World.", into: "Hello .", at: 6), "Hello World.")
        XCTAssertEqual(paste(", then leave.", into: "Take it", at: 7), "Take it, then leave.")
        XCTAssertEqual(paste("\nNext line", into: "One line", at: 8), "One line\nNext line")
    }

    // MARK: - Back-to-back dictations: a space after text Flow cannot read (22 Nov 2026 glue bug)

    func testSpaceAfterSentencePunctuationOrALetter() {
        XCTAssertEqual(CursorPaster.boundarySpaced("I've also noticed", after: "!"), " I've also noticed")
        XCTAssertEqual(CursorPaster.boundarySpaced("The term", after: "."), " The term")
        XCTAssertEqual(CursorPaster.boundarySpaced("Also, the sound", after: "k"), " Also, the sound")
        XCTAssertEqual(CursorPaster.boundarySpaced("Next", after: ":"), " Next")
        XCTAssertEqual(CursorPaster.boundarySpaced("Next", after: ";"), " Next")
        XCTAssertEqual(CursorPaster.boundarySpaced("2 things", after: "9"), " 2 things")
    }

    func testNoSpaceWhenTheFieldEndsWithSpaceOrNewline() {
        XCTAssertEqual(CursorPaster.boundarySpaced("Next", after: " "), "Next")
        XCTAssertEqual(CursorPaster.boundarySpaced("Next", after: "\n"), "Next")
    }

    func testNoSpaceWhenTheNewTextStartsWithPunctuation() {
        XCTAssertEqual(CursorPaster.boundarySpaced(", then leave", after: "k"), ", then leave")
        XCTAssertEqual(CursorPaster.boundarySpaced("(see below)", after: "!"), "(see below)")
        XCTAssertEqual(CursorPaster.boundarySpaced("...and so", after: "."), "...and so")
        XCTAssertEqual(CursorPaster.boundarySpaced("\"Quoted\"", after: "."), "\"Quoted\"")
    }

    func testNoSpaceWhenNothingIsRemembered() {
        XCTAssertEqual(CursorPaster.boundarySpaced("Next", after: nil), "Next")
    }

    func testUnreadableFieldUsesTheRememberedPasteEnd() {
        // Field and caret unreadable (no readback): the previous paste ended with "!".
        XCTAssertEqual(CursorPaster.resolvedInsertion("I've also noticed", field: nil, selection: nil,
                                                      preFormatted: true, bundleID: "com.t3tools.t3code",
                                                      rememberedEnd: "!"), " I've also noticed")
        // Readable field but no caret: same rule.
        XCTAssertEqual(CursorPaster.resolvedInsertion("The term", field: "Just work it out!", selection: nil,
                                                      preFormatted: true, bundleID: "com.t3tools.t3code",
                                                      rememberedEnd: "!"), " The term")
        // Without a remembered paste, the payload is unchanged.
        XCTAssertEqual(CursorPaster.resolvedInsertion("The term", field: nil, selection: nil,
                                                      preFormatted: true, bundleID: "com.t3tools.t3code"), "The term")
    }

    func testRememberedPasteAppliesOnlyWithinSixtySecondsInTheSameApp() {
        XCTAssertTrue(CursorPaster.rememberedPasteApplies(recordedBundle: "a", currentBundle: "a", age: 5,
                                                          sameField: true, sameWindowTitle: nil, interactionSincePaste: false))
        XCTAssertFalse(CursorPaster.rememberedPasteApplies(recordedBundle: "a", currentBundle: "a", age: 61,
                                                           sameField: true, sameWindowTitle: nil, interactionSincePaste: false))
        XCTAssertFalse(CursorPaster.rememberedPasteApplies(recordedBundle: "a", currentBundle: "b", age: 5,
                                                           sameField: true, sameWindowTitle: nil, interactionSincePaste: false))
        XCTAssertFalse(CursorPaster.rememberedPasteApplies(recordedBundle: "a", currentBundle: "a", age: -1,
                                                           sameField: true, sameWindowTitle: nil, interactionSincePaste: false))
        XCTAssertFalse(CursorPaster.rememberedPasteApplies(recordedBundle: nil, currentBundle: nil, age: 5,
                                                           sameField: nil, sameWindowTitle: nil, interactionSincePaste: false))
    }

    func testElectronFieldIdentityFallsBackToWindowTitleWithoutAClickOrAppSwitch() {
        // T3 Code re-wraps the editor: the field differs, but the same window and no click means the same spot.
        XCTAssertTrue(CursorPaster.rememberedPasteApplies(recordedBundle: "com.t3tools.t3code", currentBundle: "com.t3tools.t3code",
                                                          age: 20, sameField: false, sameWindowTitle: true,
                                                          interactionSincePaste: false))
        XCTAssertTrue(CursorPaster.rememberedPasteApplies(recordedBundle: "com.t3tools.t3code", currentBundle: "com.t3tools.t3code",
                                                          age: 20, sameField: nil, sameWindowTitle: true,
                                                          interactionSincePaste: false))
    }

    func testAClickOrAppSwitchSincePasteBreaksTheElectronMatch() {
        XCTAssertFalse(CursorPaster.rememberedPasteApplies(recordedBundle: "com.t3tools.t3code", currentBundle: "com.t3tools.t3code",
                                                           age: 20, sameField: false, sameWindowTitle: true,
                                                           interactionSincePaste: true))
        XCTAssertFalse(CursorPaster.rememberedPasteApplies(recordedBundle: "com.example.editor", currentBundle: "com.example.editor",
                                                           age: 20, sameField: true, sameWindowTitle: true,
                                                           interactionSincePaste: true), "An identical field can have a different caret after a click or key")
    }

    func testADifferentOrUnknownWindowTitleBreaksTheElectronMatch() {
        XCTAssertFalse(CursorPaster.rememberedPasteApplies(recordedBundle: "a", currentBundle: "a", age: 20,
                                                           sameField: false, sameWindowTitle: false, interactionSincePaste: false))
        XCTAssertFalse(CursorPaster.rememberedPasteApplies(recordedBundle: "a", currentBundle: "a", age: 20,
                                                           sameField: false, sameWindowTitle: nil, interactionSincePaste: false))
    }

    func testUnknownCaretKeepsTheDictatedPayload() {
        XCTAssertEqual(CursorPaster.resolvedInsertion("New text", field: "Existing.", selection: nil,
                                                      preFormatted: true, bundleID: "com.google.Chrome"), "New text")
        XCTAssertEqual(CursorPaster.resolvedInsertion(" New text ", field: "", selection: nil,
                                                      preFormatted: true, bundleID: "com.apple.TextEdit"), " New text ")
    }
    func testLiteralLinksAndNamesSurvivePresentationPasses() {
        let input = "send Jane Smith the notes at https://example.com/brief"
        for output in [Qwen3Polisher.applyPostprocessor(input, userVocabulary: nil, cleanupLevel: "light"),
                       Qwen3Polisher.applyMinimalPostprocessor(input, userVocabulary: nil)] {
            XCTAssertTrue(output.contains("https://example.com/brief"), output)
            XCTAssertTrue(output.contains("Jane Smith"), output)
            XCTAssertFalse(output.contains("example. Com"), output)
        }
    }

    func testLongDictationLaysOutTopicsWithoutLosingWords() {
        let topic = "Please check the brightness setting before changing it. Keep the regular level when boost is disabled."
        let other = "Also check the microphone list and keep the selected device. If it disconnects, use the saved preference when it returns."
        let original = Array(repeating: topic + " " + other, count: 4).joined(separator: " ")
        let formatted = DictationParagraphs.format(original)
        XCTAssertTrue(formatted.contains("\n\nAlso check"))
        XCTAssertEqual(formatted.split(whereSeparator: \.isWhitespace), original.split(whereSeparator: \.isWhitespace))
    }

    func testShortAndStructuredInputStayUnchanged() {
        let short = "One short thought. Also another one."
        let list = Array(repeating: "- An existing item with a label and some more words.", count: 20).joined(separator: "\n")
        XCTAssertEqual(DictationParagraphs.format(short), short)
        XCTAssertEqual(DictationParagraphs.format(list), list)
    }

    func testAdjoiningWindowsOnlyDeduplicateWhenTheyShareAudio() {
        let left = "Keep the backup."
        let right = "Keep the backup. Then write the summary."
        XCTAssertEqual(TranscriptionService.mergeChunkBoundary(left: left, right: right, leftConf: 0.9,
            rightConf: 0.9, maxWords: 10, sharesAudio: false).0, left + " " + right)
        XCTAssertEqual(TranscriptionService.mergeChunkBoundary(left: left, right: right, leftConf: 0.9,
            rightConf: 0.9, maxWords: 10, sharesAudio: true).0, right)
    }

    func testOnlyExactDigitalSilenceSkipsADecodeWindow() {
        XCTAssertFalse(TranscriptionService.hasAcousticSignal([Float](repeating: 0, count: 232_000)[...]))
        XCTAssertTrue(TranscriptionService.hasAcousticSignal([0, 0, Float(0.00001), 0][...]))
    }

    @MainActor func testSectionBudgetIncludesSelectedModelAndNeverExceedsDeadline() {
        XCTAssertEqual(DictationTextPreparation.sectionRequestSeconds(tuned: 4, general: 10, remaining: 20), 14)
        XCTAssertEqual(DictationTextPreparation.sectionRequestSeconds(tuned: 4, general: 10, remaining: 5), 5)
        XCTAssertEqual(DictationTextPreparation.sectionRequestSeconds(tuned: 4, general: 0, remaining: 20), 4)
        XCTAssertEqual(DictationTextPreparation.sectionRequestSeconds(tuned: 4, general: 0, remaining: -1), 0)
    }

    @MainActor func testCleanupSectionsPreferSentenceEndsAndLeaveBreaksOutside() {
        let source = "Read the report. Mark page 15. Save it.\n\n  Next section."
        let ranges = DictationTextPreparation.cleanupSections(in: source, limit: 30)
        XCTAssertEqual(ranges.map { String(source[$0]) },
                       ["Read the report. Mark page 15.", "Save it.", "Next section."])
        XCTAssertEqual(String(source[ranges[1].upperBound..<ranges[2].lowerBound]), "\n\n  ")
        let token = "https://example.com/" + String(repeating: "x", count: 70)
        let withLiteral = token + "\n   See it."
        let safeSections = DictationTextPreparation.cleanupSections(in: withLiteral, limit: 30)
        XCTAssertEqual(safeSections.map { String(withLiteral[$0]) }, ["See it."])
    }

    @MainActor func testSectionCleanupRetainsGrammarFixesAndVerbatimUnsafeSections() async {
        let source = "They is ready tomorrow.\n\n  Do not send archive-2.txt.\n\nKeep page 15."
        let ranges = DictationTextPreparation.cleanupSections(in: source)
        let result = await DictationTextPreparation.cleanSections(in: source, ranges: ranges, deadline: .now + .seconds(1)) {
            switch $0 {
            case "They is ready tomorrow.": return "They are ready tomorrow."
            case "Do not send archive-2.txt.": return "Send archive-3.txt."
            default: return nil
            }
        }
        XCTAssertFalse(result.timedOut)
        XCTAssertEqual(result.text, "They are ready tomorrow.\n\n  Do not send archive-2.txt.\n\nKeep page 15.")
    }

    @MainActor func testSectionCleanupCannotSplitAnItemAndKeepsExactSeparators() async {
        let source = "\r\n1. Keep the backup.  \r\n\r\n  They is ready.\r\n"
        let result = await DictationTextPreparation.cleanSections(
            in: source, ranges: DictationTextPreparation.cleanupSections(in: source), deadline: .now + .seconds(1)) {
                $0.hasPrefix("1.") ? "1. Keep\nthe backup." : "They are ready."
            }
        XCTAssertEqual(result.text, "\r\n1. Keep the backup.  \r\n\r\n  They are ready.\r\n")
    }

    @MainActor func testSectionReviewOverlapsNextCleanupAndKeepsItsOwnOriginal() async {
        let first = "The blue kettles is cold."
        let second = "The green shelves is empty."
        let source = first + "\n\n" + second
        let (started, signalStarted) = AsyncStream<Void>.makeStream()
        let (next, signalNext) = AsyncStream<Void>.makeStream()
        let result = await DictationTextPreparation.cleanSections(
            in: source, ranges: DictationTextPreparation.cleanupSections(in: source),
            deadline: .now + .seconds(2), review: { original, _ in
                guard original == first else { return false }
                signalStarted.yield(())
                signalStarted.finish()
                var iterator = next.makeAsyncIterator()
                return await iterator.next() != nil
            }) { original in
                if original == first { return "The blue kettles are cold." }
                var iterator = started.makeAsyncIterator()
                _ = await iterator.next()
                signalNext.yield(())
                signalNext.finish()
                return "The green shelves are empty."
            }
        XCTAssertFalse(result.timedOut)
        XCTAssertEqual(result.text, first + "\n\nThe green shelves are empty.")
    }

    @MainActor func testSectionTimeoutRetainsEarlierFixAndAllRemainingText() async {
        let source = "They is ready tomorrow.\n\nDo not send it.\n\nKeep page 15."
        let ranges = DictationTextPreparation.cleanupSections(in: source)
        let result = await DictationTextPreparation.cleanSections(in: source, ranges: ranges, deadline: .now + .milliseconds(200)) {
            if $0 == "They is ready tomorrow." { return "They are ready tomorrow." }
            try? await Task.sleep(for: .seconds(1))
            return "Late edit."
        }
        XCTAssertTrue(result.timedOut)
        XCTAssertEqual(result.text, "They are ready tomorrow.\n\nDo not send it.\n\nKeep page 15.")
    }

    /// 22 Nov 2026 replay under load: a 160-word section took just over 4 s, and the old flat 4 s cap
    /// pasted the whole dictation uncleaned. A long section now gets the model's own request time.
    @MainActor func testSlowLongSectionStillCountsInsideTheDeadline() async {
        let long = Array(repeating: "they is ready", count: 34).joined(separator: " ") + "."
        let source = long + "\n\nKeep page 15."
        let ranges = DictationTextPreparation.cleanupSections(in: source)
        let result = await DictationTextPreparation.cleanSections(in: source, ranges: ranges, deadline: .now + .seconds(10)) {
            guard $0 == long else { return nil }
            try? await Task.sleep(for: .milliseconds(4_300))
            return long.replacingOccurrences(of: "they is", with: "they are")
        }
        XCTAssertFalse(result.timedOut)
        XCTAssertTrue(result.text.hasPrefix("they are ready they are ready"))
        XCTAssertTrue(result.text.hasSuffix("\n\nKeep page 15."))
    }
}
