import Foundation
import Testing
@testable import Voice

@Suite("Opt+1 is a safe transaction: outcomes, Undo guard, length cap (A4)")
struct PolishTransactionTests {
    @Test("A changed answer is a change; the same text is no changes needed")
    func classifiesChangeAndNoChange() {
        #expect(PolishTransaction.classify(original: "i dont no", candidate: "I don't know.", rejection: nil) == .changed)
        #expect(PolishTransaction.classify(original: "We can meet.", candidate: "We can meet.\n", rejection: nil) == .noChangesNeeded)
    }

    @Test("An older review cannot undo or retry the active edit")
    func anOlderReviewCannotUndoANewerEdit() {
        let active = UUID()
        let old = UUID()
        #expect(!PolishTransaction.matchesUndo(requested: old, active: active))
        #expect(PolishTransaction.matchesUndo(requested: active, active: active))
        #expect(PolishTransaction.matchesUndo(requested: nil, active: active))
    }

    @Test("Further polish checks the original even when the first draft already lost an instruction")
    @MainActor
    func furtherReviewChecksOriginalAndCurrentDraft() {
        let original = "Save report.pdf. Do not email Frank."
        let draft = "Save report.pdf."
        #expect(Qwen3Polisher.checkedFurtherDraft("Please save report.pdf.", draft: draft, original: original) == nil)
        #expect(Qwen3Polisher.checkedFurtherDraft(original, draft: original, original: original) == nil)
    }

    @Test("Review keeps a separate request even when it contains no numbers or names")
    @MainActor
    func longReviewKeepsSeparateRequests() {
        let first = "please ask the design team to bring the current sketches to the workshop and make sure they leave enough time to compare the layout options that came out of the session."
        let second = "also archive the invoices and update the ledger before closing the accounting workspace."
        let original = first + "\n\n" + second
        let cleanFirst = "Ask the design team to bring the current sketches to the workshop and leave time to compare the layout options from the session."

        #expect(Qwen3Polisher.checkedPolishDraft(cleanFirst, source: original, body: original,
                                                preset: "smooth", review: true) == nil)
        let combined = cleanFirst + "\n\nArchive the invoices and update the ledger before closing the accounting workspace."
        #expect(Qwen3Polisher.checkedPolishDraft(combined, source: original, body: original,
                                                preset: "smooth", review: true) == combined)
    }

    @Test("Very long paragraphs split at sentence boundaries and preserve every source byte")
    func longPolishSplitsAtSentenceBoundaries() {
        let sentence = "Please keep the draft about café reservations and send it to June before the end of the day."
        let first = Array(repeating: sentence, count: 13).joined(separator: " ")
        let body = first + "\r\n\r\n  Ask Alex to keep the build number 12.4 in the notes."
        let passages = Qwen3Polisher.largeReviewPassages(in: body)
        #expect(passages.count >= 2)
        #expect(passages.allSatisfy { body[$0].split(whereSeparator: \.isWhitespace).count <= 160 })
        var recovered = ""
        var cursor = body.startIndex
        for passage in passages {
            recovered += body[cursor..<passage.lowerBound]
            recovered += body[passage]
            cursor = passage.upperBound
        }
        recovered += body[cursor...]
        #expect(recovered.utf8.elementsEqual(body.utf8))
        #expect(passages.contains { body[$0].contains("build number 12.4") })
    }

    @Test("A refused answer says it could not improve the text, with the check's reason")
    func refusedAnswerIsCouldNotImprove() {
        let outcome = PolishTransaction.classify(original: "a", candidate: nil, rejection: "it would drop a negation")
        #expect(outcome == .couldNotImprove(reason: "it would drop a negation"))
        #expect(outcome.message.hasPrefix("Couldn't improve this text."))
    }

    @Test("No answer at all is unavailable, not a refusal")
    func noAnswerIsUnavailable() {
        let outcome = PolishTransaction.classify(original: "a", candidate: nil, rejection: nil)
        if case .unavailable = outcome {} else { Issue.record("expected unavailable, got \(outcome)") }
    }

    @Test("Every outcome has a plain message, and no outcome says 'Already looks great'")
    func messagesArePlain() {
        let all: [PolishOutcome] = [.changed, .noChangesNeeded, .couldNotImprove(reason: "x"),
                                    .unavailable(reason: "x"), .textChangedWhilePolishing]
        for outcome in all {
            #expect(!outcome.message.isEmpty)
            #expect(!outcome.message.localizedCaseInsensitiveContains("looks great"))
        }
        #expect(PolishOutcome.textChangedWhilePolishing.message == "Text changed while polishing. Nothing was replaced.")
    }

    @Test("Undo may write back only when the field holds exactly what Flow wrote")
    func undoGuard() {
        let full = "Hi, i dont no if we can meet. Thanks."
        let range = NSRange(location: 4, length: 25)
        let expected = PolishTransaction.expectedFullText(before: full, range: range, replacement: "I don't know if we can meet.")
        #expect(expected == "Hi, I don't know if we can meet. Thanks.")
        #expect(PolishTransaction.mayUndo(currentFullText: expected ?? "", expectedAfterPolish: expected ?? ""))
        #expect(!PolishTransaction.mayUndo(currentFullText: "Hi, I don't know if we can meet. Thanks!", expectedAfterPolish: expected ?? ""))
    }

    @Test("Long selections can choose a different model without forcing a window")
    func reviewsLongDrafts() {
        let short = Array(repeating: "word", count: 41).joined(separator: " ")
        #expect(!PolishTransaction.prefersReviewModel(short))
        #expect(PolishTransaction.prefersReviewModel(short + "\ndone"))
    }

    @Test("Inline polish lays out a clear list and preserves every item")
    @MainActor
    func inlineLayoutMatchesSafeCandidate() {
        let original = "Three things. First, check v2.1. Second, keep https://example.com/brief. Third, ask Noor."
        #expect(Qwen3Polisher.inlinePolishCandidate(original, original: original)
                == "Three things.\n\n1. Check v2.1.\n2. Keep https://example.com/brief.\n3. Ask Noor.")
    }

    @Test("Inline polish allows simple pronoun agreement without changing actions or conditions")
    @MainActor
    func inlineGrammarKeepsMeaning() {
        let original = "They was at the front desk yesterday. Don't wait if the kitchen closes. Keep draft-v2.1.pdf."
        let corrected = "They were at the front desk yesterday. Don't wait if the kitchen closes. Keep draft-v2.1.pdf."
        #expect(Qwen3Polisher.inlinePolishCandidate(corrected, original: original) == corrected)
        #expect(Qwen3Polisher.inlinePolishCandidate("They were at the front desk yesterday. Keep draft-v2.1.pdf.",
                                                  original: original) == nil)
        #expect(Qwen3Polisher.inlinePolishCandidate(corrected.replacingOccurrences(of: "v2.1", with: "v2.2"),
                                                  original: original) == nil)
    }

    @Test("Review permits spacing a compact title without accepting a new number")
    @MainActor
    func compactTitlesKeepTheirNumbers() {
        let original = "lets play gta6 with dinner"
        #expect(Qwen3Polisher.checkedPolishDraft("Let's play GTA 6 with dinner.", source: original, body: original,
                                                preset: "smooth", review: true) == "Let's play GTA6 with dinner.")
        #expect(Qwen3Polisher.checkedPolishDraft("Let's play GTA 7 with dinner.", source: original, body: original,
                                                preset: "smooth", review: true) == nil)
    }

    @Test("Review rejects translated drafts and altered filenames")
    @MainActor
    func keepsLanguagesAndFiles() {
        let original = "Ik kan donderdag wel na 16:00. Could you check with Eva first?"
        let translated = "Ik kan donderdag wel na 16:00. Kun je eerst bij Eva navragen?"
        #expect(Qwen3Polisher.checkedPolishDraft(translated, source: original, body: original,
                                                preset: "smooth", review: true) == nil)
        #expect(!Qwen3Polisher.reviewIdentifiersPreserved("Check other.zip and use --live.",
                                                         original: "Check export.zip and use --dry-run."))
    }

    @Test("Mixed draft fallback sees lowercase sentences and keeps punctuation inside identifiers")
    func lowercaseSentenceBoundaries() {
        let source = "we kunnen morgen na 17:30. don't open config.json before I say yes. laat het even liggen."
        let ranges = Qwen3Polisher.reviewSentenceRanges(in: source)
        #expect(ranges.map { String(source[$0]) } == [
            "we kunnen morgen na 17:30.", "don't open config.json before I say yes.", "laat het even liggen."
        ])
    }

    @Test("Review protects a first-person draft and permits a grounded acronym repair")
    @MainActor
    func reviewKeepsSpeakerAndAcronyms() {
        #expect(!Qwen3Polisher.reviewPerspectivePreserved("Identify your goals. You have a deadline.",
                                                         original: "Tell me my goals. I have a deadline."))
        #expect(Qwen3Polisher.reviewPerspectivePreserved("What do I have to do?",
                                                        original: "What are my tasks?"))
        #expect(Qwen3Polisher.reviewAcronymsGrounded("Keep my ADHD in mind.", original: "keep my addhd in mind"))
        #expect(!Qwen3Polisher.reviewAcronymsGrounded("Set up an AI planner.", original: "set up a planner"))
    }

    @Test("Review accepts an equivalent uncertainty without dropping the condition")
    @MainActor
    func reviewRecognizesEquivalentUncertainty() {
        let original = "If you arent sure about the name Lea dont change it."
        let equivalent = "If you're unsure about the name Lea, don't change it."
        let reversed = "If you're sure about the name Lea, don't change it."
        #expect(Qwen3Polisher.checkedPolishDraft(equivalent, source: original, body: original,
                                                preset: "smooth", review: true) == equivalent)
        #expect(Qwen3Polisher.checkedPolishDraft(reversed, source: original, body: original,
                                                preset: "smooth", review: true) == nil)
    }

    @Test("The larger editor is reserved for long drafts with repeated disfluencies")
    func detailedReviewNeedsDensity() {
        let long = String(repeating: "Please keep the details. ", count: 25)
        #expect(!Qwen3Polisher.needsDetailedReview(long))
        #expect(!Qwen3Polisher.needsDetailedReview("um um etc etc idk"))
        #expect(Qwen3Polisher.needsDetailedReview(long + "um um etc etc idk"))
    }

    @Test("Review can restate a possibility while retaining its uncertainty")
    @MainActor
    func reviewRetainsPossibility() {
        let original = "Maybe colors would help."
        let equivalent = "Colors might help."
        #expect(Qwen3Polisher.checkedPolishDraft(equivalent, source: original, body: original,
                                                preset: "smooth", review: true) == equivalent)
        #expect(Qwen3Polisher.checkedPolishDraft("Colors will help.", source: original, body: original,
                                                preset: "smooth", review: true) == nil)
    }

    @Test("Quick edits paste punctuation and clear typing repairs and preview changed requests")
    @MainActor
    func quickEditsPreserveWording() {
        #expect(Qwen3Polisher.canApplyQuickEdit("Can you send the draft by Friday?",
                                               original: "can u send the draft by friday"))
        #expect(Qwen3Polisher.canApplyQuickEdit("Please send the draft by Friday.",
                                               original: "Please send the draf by Friday."))
        #expect(Qwen3Polisher.canApplyQuickEdit("Can you send the draft by Friday, but don't promise Thursday?",
                                               original: "can u snd teh draft by friday but dont promise thursday"))
        #expect(!Qwen3Polisher.canApplyQuickEdit("Use the send module.",
                                                original: "Use the snd module."))
        #expect(!Qwen3Polisher.canApplyQuickEdit("Send the other draft.",
                                                original: "Send the older draft."))
        #expect(!Qwen3Polisher.canApplyQuickEdit("Just work till you're all out, thanks.",
                                                original: "just fulyl work ti all out htanks"))
        #expect(!Qwen3Polisher.canApplyQuickEdit("Store it as export.csv.",
                                                original: "Store it as export.tsv."))
    }

    @Test("Inline polish fixes typing errors and verb agreement without losing meaning")
    @MainActor
    func repairsSpellingAndAgreement() {
        let raw = "Make sure wehvae room. It coesnt have to be a big pscae. The batteries was in the drawer."
        let edit = "Make sure we have room. It doesn't have to be a big space. The batteries were in the drawer."
        #expect(Qwen3Polisher.checkedPolishDraft(edit, source: raw, body: raw, preset: "fix") == edit)
        #expect(Qwen3Polisher.inlinePolishCandidate(edit, original: raw) == edit)
        #expect(Qwen3Polisher.checkedPolishDraft(edit.replacingOccurrences(of: "doesn't", with: "does"),
                                                source: raw, body: raw, preset: "fix") == nil)
        #expect(!Qwen3Polisher.canApplyQuickEdit("The news are on later.", original: "The news is on later."))
    }

    @Test("A rejected model rewrite keeps repairs from independent sentences")
    @MainActor
    func salvagesIndependentEditsWithoutTakingUnsafeChanges() {
        let source = "they was at the desk.\n\nDon't send notes-v2.pdf to Noor today."
        let unsafe = "They were at the desk. Send notes-v3.pdf to Nora tomorrow."
        #expect(Qwen3Polisher.checkedPolishDraft(unsafe, source: source, body: source, preset: "fix") == nil)
        #expect(Qwen3Polisher.checkedInlineDraft(unsafe, source: source, body: source, preset: "fix")
                == "They were at the desk.\n\nDon't send notes-v2.pdf to Noor today.")
        let missing = "They were at the desk."
        #expect(Qwen3Polisher.checkedInlineDraft(missing, source: source, body: source, preset: "fix") == nil)
    }

    @Test("Anchored spelling repairs survive a rejected draft with different sentence boundaries")
    @MainActor
    func salvagesSpellingAcrossSentenceBoundaryChanges() {
        let source = "Please check the bduget before Friday. Don't send it to Noor. Keep docs-v2.pdf."
        let rewritten = "Please check the budget before Friday and send it to Kai. Keep docs-v3.pdf."
        var partial = false
        #expect(Qwen3Polisher.checkedInlineDraft(rewritten, source: source, body: source, preset: "fix", onPartial: { partial = true })
                == "Please check the budget before Friday. Don't send it to Noor. Keep docs-v2.pdf.")
        #expect(partial)
    }

    @Test("Anchored recovery can split a jammed phrase without carrying over the unsafe rewrite")
    @MainActor
    func salvagesJammedWords() {
        let source = "Make sure wehvae room by Friday.\n\nDon't send notes-v2.pdf to Noor. Keep `wehvae`."
        let unsafe = "Make sure we have room by Friday and send notes-v3.pdf to Kai. Keep everything."
        let result = Qwen3Polisher.checkedInlineDraft(unsafe, source: source, body: source, preset: "fix")
        #expect(result == "Make sure we have room by Friday.\n\nDon't send notes-v2.pdf to Noor. Keep `wehvae`.")
    }

    @Test("An anchored split cannot replace a valid word or invent different letters")
    @MainActor
    func rejectsUnsafeAnchoredSplits() {
        let source = "Please keep your therapist informed about the appointment."
        let proposed = "Please keep your the rapist informed about the appointment."
        #expect(Qwen3Polisher.recoverAnchoredSpelling(original: source, proposed: proposed) == nil)

        let ambiguous = "Can you rewieve the brief today? Don't send notes-v3.pdf."
        let invented = "Can you re live the brief today and send notes-v4.pdf?"
        #expect(Qwen3Polisher.recoverAnchoredSpelling(original: ambiguous, proposed: invented) == nil)
    }

    @Test("The short route can detect that a partial correction still needs work")
    @MainActor
    func remainingTranspositionsKeepReviewAvailable() {
        #expect(Qwen3Polisher.hasOutstandingTypingSlip("I checked the bduget for the new draft.", deadline: .now + .seconds(1)))
        #expect(!Qwen3Polisher.hasOutstandingTypingSlip("I checked the budget for the new draft.", deadline: .now + .seconds(1)))
        #expect(Qwen3Polisher.hasOutstandingTypingSlip("I will revieew the draft.", deadline: .now + .seconds(1)))
        #expect(!Qwen3Polisher.hasOutstandingTypingSlip("I will revieew the draft.", deadline: .now, inconclusive: false))
    }

    @Test("Anchored spelling recovery preserves literals and ambiguous repeated phrases")
    @MainActor
    func anchoredRepairsKeepLiteralsAndRepeatedPhrases() {
        let source = "Check the bduget before Friday. Check the bduget before Monday. Keep `the bduget before` unchanged."
        let rewritten = "Check the budget before Friday. Check the budgets before Monday. Keep `the budget before` unchanged."
        #expect(Qwen3Polisher.recoverAnchoredSpelling(original: source, proposed: rewritten) == nil)
    }

    @Test("Recovery preserves the language and all conditions in a mixed draft")
    @MainActor
    func preservesMixedDraftWhenOneSentenceWasTranslated() {
        let source = "ik zou het laten staan. they was at the desk. Don't send it today."
        let unsafe = "I would leave it alone. They were at the desk. Send it tomorrow."
        #expect(Qwen3Polisher.checkedInlineDraft(unsafe, source: source, body: source, preset: "smooth", review: true)
                == "ik zou het laten staan. They were at the desk. Don't send it today.")
    }

    @Test("A rejected rewrite can still repair local typos without losing the rest of the draft")
    @MainActor
    func safeSpellingRecovery() {
        let source = "The calnedar lists the rehearsal at noon."
        let repaired = Qwen3Polisher.shared.recoverTypedSpelling(source, deadline: .now + .seconds(1))
        #expect(repaired == "The calendar lists the rehearsal at noon.")
    }

    @Test("Recovery can expand a clear request while leaving an unclear word and exact literals alone")
    @MainActor
    func shortRequestRecovery() {
        let draft = "rewieve the brief pls. Don't send notes-v3.pdf unless Mira says yes."
        #expect(Qwen3Polisher.shared.recoverTypedSpelling(draft, deadline: .now + .seconds(1)) ==
                "rewieve the brief please. Don't send notes-v3.pdf unless Mira says yes.")
        let source = "rewieve the brief pls. Don't send notes-v3.pdf unless Mira says yes. Keep `call pls`."
        let repaired = Qwen3Polisher.shared.recoverTypedSpelling(source, deadline: .now + .seconds(1))
        #expect(repaired == "rewieve the brief please. Don't send notes-v3.pdf unless Mira says yes. Keep `call pls`.")
    }

    @Test("Spelling recovery leaves valid English words alone in a predominantly Dutch draft")
    @MainActor
    func spellingRecoveryKeepsForeignWords() {
        let source = "kan je me laten weten of de verise met het adres al klaar is. please send it only after the review."
        let changed = source.replacingOccurrences(of: "send", with: "eend")
        #expect(!Qwen3Polisher.canApplyQuickEdit(changed, original: source))
        let repaired = Qwen3Polisher.shared.recoverTypedSpelling(source, deadline: .now + .seconds(1))
        #expect(repaired.contains("please send it only after the review"))
    }

    @Test("Common word-boundary slips are repaired only in their context")
    @MainActor
    func repairsContextualTyping() {
        #expect(Qwen3Polisher.repairCommonTypingErrors("Could twe somehwo test a deciiosn model int his app?")
                == "Could we somehow test a decision model in this app?")
        #expect(Qwen3Polisher.repairCommonTypingErrors("Make sur ewea're gonn se save all teh adata tooo and train ap rpoepr model.")
                == "Make sure we're gonna save all the data too and train a proper model.")
        #expect(Qwen3Polisher.repairCommonTypingErrors("Use `int his thing` and ask Twe about ADATA.")
                == "Use `int his thing` and ask Twe about ADATA.")
        #expect(Qwen3Polisher.repairCommonTypingErrors("We can snd the proof.") == "We can send the proof.")
        #expect(Qwen3Polisher.repairCommonTypingErrors("Please use `can snd it` as written; I can snd to MIDI.")
                == "Please use `can snd it` as written; I can snd to MIDI.")
        #expect(!Qwen3Polisher.canApplyQuickEdit("can the check it after lunch", original: "can twe check it after lunch"))
    }

    @Test("Standalone model labels are removed without changing a heading from the original")
    @MainActor
    func stripAdapterLabelOnly() {
        let source = "send it please"
        #expect(Qwen3Polisher.checkedPolishDraft("Light.\n\nSend it, please.", source: source,
                                                body: source, preset: "fix") == "Send it, please.")
        let originalHeading = "Light.\n\nsend it please"
        let editedHeading = "Light.\n\nSend it, please."
        #expect(Qwen3Polisher.checkedPolishDraft(editedHeading, source: originalHeading,
                                                body: originalHeading, preset: "fix") == editedHeading)
    }

    @Test("Selected edits preserve abbreviated restrictions")
    func abbreviatedRestrictionsSurvive() {
        #expect(MeaningIntegrity.selectedNegationsKept(original: "do it w/out alerts", candidate: "Do it without alerts."))
        #expect(MeaningIntegrity.selectedNegationsKept(original: "do it w/o alerts", candidate: "Do it without alerts."))
        #expect(!MeaningIntegrity.selectedNegationsKept(original: "do it wout alerts", candidate: "Do it with alerts."))
        #expect(MeaningIntegrity.selectedNegationsKept(original: "ask Wout about alerts", candidate: "Ask Wout about alerts."))
    }

    @Test("A range outside the text gives no expected text")
    func badRangeGivesNothing() {
        #expect(PolishTransaction.expectedFullText(before: "abc", range: NSRange(location: 2, length: 5), replacement: "x") == nil)
    }

    @Test("Selections over 6,000 characters are refused; 6,000 exactly is allowed")
    func lengthCap() {
        #expect(!PolishTransaction.isTooLong(String(repeating: "a", count: 6_000)))
        #expect(PolishTransaction.isTooLong(String(repeating: "a", count: 6_001)))
    }
}
