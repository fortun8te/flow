import Testing
@testable import Voice

struct PathPreservationTests {
    @Test @MainActor func keepsTheFullRelativePath() {
        let original = "Send plans/report-r12.md to Mira."
        #expect(Qwen3Polisher.reviewIdentifiersPreserved("Please send plans/report-r12.md to Mira.", original: original))
        #expect(!Qwen3Polisher.reviewIdentifiersPreserved("Send drafts/report-r12.md to Mira.", original: original))
        #expect(!Qwen3Polisher.reviewIdentifiersPreserved("Send report-r12.md to Mira.", original: original))
        #expect(!Qwen3Polisher.canApplyQuickEdit("Send drafts/report-r12.md to Mira.", original: original))
        #expect(Qwen3Polisher.checkedPolishDraft("Send drafts/report-r12.md to Mira.", source: original,
                                                 body: original, preset: "smooth", review: true) == nil)
    }

    @Test func keepsWindowsPathsWithoutTreatingEverySlashAsAPath() {
        let original = #"Open C:\Work\report-r12.md."#
        #expect(!Qwen3Polisher.reviewIdentifiersPreserved(#"Open C:\Other\report-r12.md."#, original: original))
        #expect(Qwen3Polisher.reviewIdentifiersPreserved("Either option is fine.", original: "Either option and/or choice is fine."))
    }

    @Test func keepsAudioFilenamesAndTheirFolders() {
        let original = "Keep audio/recording-p71.wav."
        #expect(!Qwen3Polisher.reviewIdentifiersPreserved("Keep archive/recording-p71.wav.", original: original))
        #expect(!Qwen3Polisher.reviewIdentifiersPreserved("Keep the recording.", original: original))
        #expect(Qwen3Polisher.reviewIdentifiersPreserved("Please keep audio/recording-p71.wav.", original: original))
    }

    @Test func keepsSpacesInsideAbsoluteAndQuotedPaths() {
        let absolute = "Open /Users/example/My Project/report-r12.md."
        #expect(!Qwen3Polisher.reviewIdentifiersPreserved("Open /Users/example/Other Project/report-r12.md.", original: absolute))
        let quoted = #"Open "My Project/report-r12.md"."#
        #expect(!Qwen3Polisher.reviewIdentifiersPreserved(#"Open "Other Project/report-r12.md"."#, original: quoted))
        #expect(Qwen3Polisher.reviewIdentifiersPreserved("Open 'My Project/report-r12.md'.", original: quoted))
    }

    @Test func keepsExplicitPathsWithoutExtensions() {
        let original = "Use /Users/example/Archive and continue."
        #expect(!Qwen3Polisher.reviewIdentifiersPreserved("Use /Users/example/Other and continue.", original: original))
        #expect(!Qwen3Polisher.reviewIdentifiersPreserved("Use ./other/current.", original: "Use ./assets/current."))
    }

    @Test func keepsCreativeFilesAndTheirFolders() {
        let original = "Keep design/label-c20.ai and design/mockup-a4.psd."
        #expect(!Qwen3Polisher.reviewIdentifiersPreserved("Keep archive/label-c20.ai and design/mockup-a4.psd.", original: original))
        #expect(!Qwen3Polisher.reviewIdentifiersPreserved("Keep the artwork.", original: original))
        #expect(Qwen3Polisher.reviewIdentifiersPreserved("Please keep design/label-c20.ai and design/mockup-a4.psd.", original: original))
    }

    @Test @MainActor func rejectsObservedSelfCorrectionThatDropsBothFiles() {
        let original = "Give Yara either notes/moss-u68.txt or notes/moss-u69.txt, whichever passes review. Actually no, send neither until she asks."
        let dropped = "Send neither until Yara asks."
        #expect(!Qwen3Polisher.reviewIdentifiersPreserved(dropped, original: original))
        #expect(!Qwen3Polisher.canApplyQuickEdit(dropped, original: original))
        #expect(Qwen3Polisher.checkedPolishDraft(dropped, source: original, body: original,
                                                 preset: "smooth", review: true) == nil)
    }

    @Test @MainActor func rejectsDroppedReviewConditionEvenWhenFilesRemain() {
        let original = "Give Yara either notes/moss-u68.txt or notes/moss-u69.txt, whichever passes review. Send neither until she asks."
        let dropped = "Give Yara either notes/moss-u68.txt or notes/moss-u69.txt. Send neither until she asks."
        #expect(!Qwen3Polisher.canApplyQuickEdit(dropped, original: original))
        #expect(Qwen3Polisher.checkedPolishDraft(dropped, source: original, body: original,
                                                 preset: "smooth", review: true) == nil)
    }

    @Test @MainActor func acceptsAnEquivalentReviewChoiceWording() {
        let original = "Use whichever passes review."
        #expect(Qwen3Polisher.reviewChoiceConditionPreserved("Use the one that passes review.", original: original))
        #expect(Qwen3Polisher.reviewChoiceConditionPreserved("Use whichever passes review.", original: original))
        #expect(!Qwen3Polisher.reviewChoiceConditionPreserved("Use the one that passed review.", original: original))
        let twoConditions = "For the first set use whichever passes review; for the second use whichever passes review."
        #expect(!Qwen3Polisher.reviewChoiceConditionPreserved("Use whichever passes review.", original: twoConditions))
        #expect(Qwen3Polisher.reviewChoiceConditionPreserved("Use this version.", original: "Use this version."))
        let longer = "Give Yara either notes/moss-u68.txt or notes/moss-u69.txt, whichever passes review. Send neither until she asks."
        let equivalent = "Give Yara either notes/moss-u68.txt or notes/moss-u69.txt, whichever passes the review. Send neither until she asks."
        #expect(Qwen3Polisher.checkedPolishDraft(equivalent, source: longer, body: longer,
                                                 preset: "smooth", review: true) != nil)
        let choice = "Give Yara either notes/moss-u68.txt or notes/moss-u69.txt, the one that passes review. Send neither until she asks."
        #expect(Qwen3Polisher.checkedPolishDraft(choice, source: longer, body: longer,
                                                 preset: "smooth", review: true) != nil)
        let addedQuantity = choice + " Send one copy."
        #expect(Qwen3Polisher.checkedPolishDraft(addedQuantity, source: longer, body: longer,
                                                 preset: "smooth", review: true) == nil)
        let numbered = "Send two copies of whichever passes review."
        let sameNumber = "Send two copies of the one that passes review."
        #expect(Qwen3Polisher.checkedPolishDraft(sameNumber, source: numbered, body: numbered,
                                                 preset: "smooth", review: true) != nil)
        let changedNumber = "Send one copy of the one that passes review."
        #expect(Qwen3Polisher.checkedPolishDraft(changedNumber, source: numbered, body: numbered,
                                                 preset: "smooth", review: true) == nil)
        let changedTense = "Give Yara either notes/moss-u68.txt or notes/moss-u69.txt, the one that passed review. Send neither until she asks."
        #expect(Qwen3Polisher.checkedPolishDraft(changedTense, source: longer, body: longer,
                                                 preset: "smooth", review: true) == nil)
        #expect(Qwen3Polisher.checkedPolishDraft(changedTense, source: longer, body: longer,
                                                 preset: "smooth", review: false) == nil)
    }
}
