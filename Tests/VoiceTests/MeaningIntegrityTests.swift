import Testing
@testable import Voice

@Suite("Meaning integrity")
struct MeaningIntegrityTests {
    @Test func rejectsNegationAndNumberLoss() {
        #expect(!MeaningIntegrity.preservesMeaning(original: "Neem niet 5 mg", candidate: "Neem 5 g"))
        #expect(!MeaningIntegrity.preservesMeaning(original: "Take 5 mg", candidate: "Take 5 g"))
        #expect(!MeaningIntegrity.preservesMeaning(original: "Send 7 items", candidate: "Send items"))
        #expect(!MeaningIntegrity.preservesMeaning(original: "Send 42 items", candidate: "Send items"))
        #expect(!MeaningIntegrity.preservesMeaning(original: "Niet nu", candidate: "Nu"))
        #expect(!MeaningIntegrity.preservesMeaning(original: "No, never", candidate: "Never"))
    }

    @Test func acceptsCommonEquivalentFormatting() {
        #expect(MeaningIntegrity.preservesMeaning(original: "Neem vijf milligram", candidate: "Neem 5 mg."))
        #expect(MeaningIntegrity.preservesMeaning(original: "Do not take 2.50 kg", candidate: "Don't take 2,5 kilograms."))
        #expect(MeaningIntegrity.preservesMeaning(original: "Ik heb een idee", candidate: "Ik heb een idee."))
    }

    @Test func repairsTypedNegativesWithoutReversingTheirMeaning() {
        #expect(MeaningIntegrity.selectedNegationsKept(
            original: "it coesnt do the misspellling good", candidate: "It doesn’t fix the misspellings well."))
        #expect(!MeaningIntegrity.selectedNegationsKept(
            original: "it coesnt do the misspellling good", candidate: "It fixes the misspellings well."))
        #expect(MeaningIntegrity.selectedNegationsKept(
            original: "i want no lantern we can wait", candidate: "I don't want a lantern. We can wait."))
        #expect(!MeaningIntegrity.selectedNegationsKept(
            original: "I don't, no.", candidate: "I don't know."))
        #expect(MeaningIntegrity.selectedNegationsKept(
            original: "Ik weet het neit.", candidate: "Ik weet het niet."))
        #expect(!MeaningIntegrity.selectedNegationsKept(
            original: "Ik weet het neit.", candidate: "Ik weet het."))
    }

    @Test func uncertainShorthandDoesNotAllowAnUnrelatedNegation() {
        #expect(MeaningIntegrity.selectedNegationsKept(
            original: "idk if they can. Email Lee.", candidate: "I don't know if they can. Email Lee."))
        #expect(MeaningIntegrity.selectedNegationsKept(
            original: "idk if they can. Email Lee.", candidate: "I’m not sure if they can. Email Lee."))
        #expect(!MeaningIntegrity.selectedNegationsKept(
            original: "idk if they can. Email Lee.", candidate: "They can. Don't email Lee."))
        #expect(!MeaningIntegrity.selectedNegationsKept(
            original: "idk if they can. Email Lee.", candidate: "They can. Email Lee."))
    }

    @Test func selectedNegationAliasesLeaveIdentifiersAndNamesAlone() {
        let literalText = "Ask Wout and Neit about `it coesnt`, https://example.test/?mode=idk and /tmp/nie."
        #expect(MeaningIntegrity.canonicalSelectedNegations(literalText) == literalText)
        #expect(!MeaningIntegrity.selectedNegationsKept(
            original: "Ask Wout and Neit for https://example.test/?mode=idk.",
            candidate: "Don't ask Wout and Neit for https://example.test/?mode=idk."))
    }

    @Test func preservesAmbiguousNumberSeparators() {
        #expect(!MeaningIntegrity.preservesMeaning(original: "€2.300", candidate: "€2,300"))
        #expect(!MeaningIntegrity.preservesMeaning(original: "€12.345.000", candidate: "€12,345,000"))
        #expect(MeaningIntegrity.preservesMeaning(original: "2,5 mg", candidate: "2.5 milligrams"))
        #expect(!MeaningIntegrity.preservesMeaning(original: "5 mg", candidate: "5 g"))
    }

    @Test func finalProcessingKeepsSpokenNumbersAndUnits() {
        // The number-word pass still exists in isolation, but the polish path turns it off:
        // "twenty five percent" is the speaker's wording and stays as said. Only casing changes.
        let input = "twenty five percent"
        #expect(PolishPostprocessor.numberSpelloutPass(input) == "25%")
        let result = PolishPostprocessor.validateAndProcess(polish: input, originalForFallback: input, mode: .relaxed)
        #expect(result.cleaned.lowercased() == input)
        #expect(!result.cleaned.contains("25"))
    }

    @Test func sanitizerUsesTheGuard() {
        #expect(Sanitizer.run(polish: "Neem 5 g", original: "Neem niet 5 mg", mode: .relaxed) == nil)
    }
}
