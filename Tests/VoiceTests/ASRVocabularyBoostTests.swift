import Foundation
import Testing
@testable import Voice

/// The trusted-term filter for acoustic vocabulary boosting.
struct ASRVocabularyBoostTests {
    @Test func keepsNameLikeTermsAndDropsSnippets() {
        let terms = ASRVocabularyBoost.trustedTerms(
            properNouns: ["Jordan Example", "jordan@example.com", "Wispr Flow", "Jordan", "tiktok",
                          "on.r", "tldr", "I don't know", "grokbot", "Hydo", "ac", "AcmeX",
                          "1080 x 1440 frames", "lfm"],
            dictionary: ["Hydo", "by the way", "Felix",
                         "Hey, use my referral link to get 1 month off Wispr Flow! https://wisprflow.ai/r?EXAMPLE12345"])
        #expect(terms == ["Wispr Flow", "Jordan", "tiktok", "tldr", "grokbot", "Hydo", "AcmeX", "Felix"])
    }

    @Test func dropsLongerTermThatExtendsAListedOne() {
        // "Jordan Example" after "Jordan" turned "Jordan, so" into "Jordan Example".
        let terms = ASRVocabularyBoost.trustedTerms(properNouns: ["Jordan Example", "Jordan"], dictionary: [])
        #expect(terms == ["Jordan"])
        #expect(ASRVocabularyBoost.trustedTerms(properNouns: ["Jordan Example"], dictionary: []) == ["Jordan Example"])
    }

    @Test func multiWordTermsGetRunTogetherAlias() {
        #expect(ASRVocabularyBoost.vocabularyTerm("Wispr Flow").aliases == ["WisprFlow"])
        #expect(ASRVocabularyBoost.vocabularyTerm("AcmeX").aliases == nil)
    }

    @Test func guardKeepsRealRecoveriesAndSpacingFixes() {
        let known: Set<String> = ["codec", "xcode", "tiktok"]
        #expect(ASRVocabularyBoost.keepsReplacement(original: ["Rockbot"], replacement: ["Grokbot"], knownOther: known))
        #expect(ASRVocabularyBoost.keepsReplacement(original: ["nano", "X"], replacement: ["AcmeX"], knownOther: known))
        #expect(ASRVocabularyBoost.keepsReplacement(original: ["TLD"], replacement: ["Tldr"], knownOther: known))
        #expect(ASRVocabularyBoost.keepsReplacement(original: ["Whisperflow."], replacement: ["Wispr", "Flow."],
                                                    knownOther: known))
    }

    @Test func guardRejectsMeasuredFalseInsertions() {
        let known: Set<String> = ["codec", "xcode"]
        // Edge-letter edits: a different real word.
        #expect(!ASRVocabularyBoost.keepsReplacement(original: ["codex"], replacement: ["ocodex"], knownOther: known))
        #expect(!ASRVocabularyBoost.keepsReplacement(original: ["TikToks"], replacement: ["Tiktok"], knownOther: known))
        #expect(!ASRVocabularyBoost.keepsReplacement(original: ["tone"], replacement: ["toner"], knownOther: known))
        // One edit from another known name.
        #expect(!ASRVocabularyBoost.keepsReplacement(original: ["Xcode"], replacement: ["Ocodex"], knownOther: known))
        #expect(!ASRVocabularyBoost.keepsReplacement(original: ["coded"], replacement: ["ocodex"], knownOther: known))
    }

    @Test func guardedTextRevertsOnlyRejectedHunks() {
        let result = ASRVocabularyBoost.guardedText(
            unboosted: "ask Rockbot to open the codex session",
            boosted: "ask Grokbot to open the ocodex session",
            knownOther: ["codec"])
        #expect(result.text == "ask Grokbot to open the codex session")
        #expect(result.rejected == ["codex → ocodex"])
    }

    @Test func onByDefaultWithMeasuredSimilarityFloor() {
        #expect(ASRVocabularyBoost.enabledByDefault == true)
        let defaults = UserDefaults(suiteName: "ASRVocabularyBoostTests-\(UUID().uuidString)")!
        #expect(ASRVocabularyBoost.thresholds(defaults: defaults).minSimilarity == 0.6)
        #expect(ASRVocabularyBoost.thresholds(defaults: defaults).cbw == nil)
    }
}
