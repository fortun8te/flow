import Foundation
import Testing
@testable import Voice

@Suite("Dictation entity preservation")
struct RebuildQAEntityPreservationTests {
    @Test("Protects contact details and code while preserving Dutch and English context")
    func multilingualRoundTrip() {
        let original = "Stuur een mail naar alex@example.com en check `git status` op https://example.org/test."
        let frozen = EntityFreezer.freeze(original, mode: .minimal)
        #expect(!frozen.entities.isEmpty)
        #expect(!frozen.text.contains("alex@example.com"))
        #expect(!frozen.text.contains("`git status`"))
        #expect(EntityFreezer.unfreeze(frozen.text, entities: frozen.entities) == original)
    }

    @Test("Repeated protected values retain each occurrence")
    func repeatedEntities() {
        let original = "Compare https://example.org/a to https://example.org/a before sending."
        let frozen = EntityFreezer.freeze(original)
        #expect(frozen.entities.count == 2)
        #expect(EntityFreezer.unfreeze(frozen.text, entities: frozen.entities) == original)
    }

    @Test("Skip mode leaves the input unchanged")
    func skippedProtection() {
        let original = "Don't send it to alex@example.com."
        let frozen = EntityFreezer.freeze(original, mode: .skip)
        #expect(frozen.text == original)
        #expect(frozen.entities.isEmpty)
    }

    @Test("A dropped protected value falls back to the original dictation")
    func droppedMarkerFallsBack() async {
        let original = "Send the note to alex@example.com."
        let result = await EntityFreezer.roundTrip(original) { frozen in
            let marker = EntityFreezer.freeze(original).entities.keys.first!
            return frozen.replacingOccurrences(of: marker, with: "")
        }
        #expect(result == original)
    }

    @Test("A duplicated protected value falls back to the original dictation")
    func duplicatedMarkerFallsBack() async {
        let original = "Send the note to alex@example.com."
        let result = await EntityFreezer.roundTrip(original) { frozen in
            let marker = EntityFreezer.freeze(original).entities.keys.first!
            return frozen + " " + marker
        }
        #expect(result == original)
    }

    @Test("Replacing one marker with a second marker cannot pass validation")
    func substitutedMarkerIsRejected() {
        let original = "Email alex@example.com and open https://example.org/page"
        let frozen = EntityFreezer.freeze(original, mode: .minimal)
        let keys = frozen.entities.keys.sorted()
        #expect(keys.count == 2)
        guard keys.count == 2 else { return }
        let mangled = frozen.text.replacingOccurrences(of: keys[0], with: keys[1])
        #expect(!EntityFreezer.hasIntactEntities(mangled, frozen: frozen))
    }
}
