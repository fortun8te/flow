import Foundation
import XCTest
@testable import Voice

final class EntityFreezerTests: XCTestCase {
    func testLiteralMarkersCannotBeOverwrittenDuringRestore() {
        let source = "Keep ⟦E0⟧ and ⟦E1⟧; email alex@example.com twice: alex@example.com."
        let frozen = EntityFreezer.freeze(source, mode: .minimal)
        XCTAssertNil(frozen.entities["⟦E0⟧"])
        XCTAssertNil(frozen.entities["⟦E1⟧"])
        XCTAssertEqual(frozen.entities.count, 2)
        XCTAssertEqual(EntityFreezer.unfreeze(frozen.text, entities: frozen.entities), source)
    }

    func testEnclosingCodeIsProtectedAsOneSpan() {
        let source = "Run `curl https://example.com/api --user alex@example.org` now."
        let frozen = EntityFreezer.freeze(source, mode: .minimal)
        XCTAssertEqual(Array(frozen.entities.values), ["`curl https://example.com/api --user alex@example.org`"])
        XCTAssertFalse(frozen.text.contains("curl"))
        XCTAssertFalse(frozen.text.contains("--user"))
        XCTAssertEqual(EntityFreezer.unfreeze(frozen.text, entities: frozen.entities), source)
    }

    func testLiteralMarkerInsideCodeDoesNotPreventProtection() {
        let source = "Keep `print(\"⟦E0⟧\", \"alex@example.com\")` and ⟦E1⟧."
        let frozen = EntityFreezer.freeze(source)
        XCTAssertEqual(frozen.entities.count, 1)
        XCTAssertNil(frozen.entities["⟦E0⟧"])
        XCTAssertNil(frozen.entities["⟦E1⟧"])
        XCTAssertFalse(frozen.text.contains("print"))
        XCTAssertEqual(EntityFreezer.unfreeze(frozen.text, entities: frozen.entities), source)
    }

    func testOverlappingEmailDomainAndPathMatchesPreserveUnicodeAndSpacing() {
        let source = "🙂 Stuur alex@api.example.com en https://example.com/a/b naar /tmp/my_file.txt.\nCafé isn't code."
        let frozen = EntityFreezer.freeze(source, mode: .minimal)
        XCTAssertEqual(frozen.entities.count, 3)
        XCTAssertTrue(frozen.text.contains("Café isn't code."))
        XCTAssertEqual(EntityFreezer.unfreeze(frozen.text, entities: frozen.entities), source)
    }

    func testAggressiveAndSkipModesRetainTheirContract() {
        let source = "Don't change github.com or `git status`."
        XCTAssertEqual(EntityFreezer.freeze(source, mode: .minimal).entities.count, 2)
        XCTAssertEqual(EntityFreezer.freeze(source, mode: .aggressive).entities.count, 3)
        let skipped = EntityFreezer.freeze(source, mode: .skip)
        XCTAssertTrue(skipped.entities.isEmpty)
        XCTAssertEqual(skipped.text, source)
    }

    func testDroppedOrDuplicatedEntityRejectsTheTransform() async {
        let source = "Send it to alex@example.com."
        let key = EntityFreezer.freeze(source).entities.keys.first!
        let dropped = await EntityFreezer.roundTrip(source) { $0.replacingOccurrences(of: key, with: "") }
        let duplicated = await EntityFreezer.roundTrip(source) { $0 + key }
        XCTAssertEqual(dropped, source)
        XCTAssertEqual(duplicated, source)
    }

    func testUnprotectedTextCanChangeWithoutTouchingNestedCode() async {
        let source = "please run `curl https://example.com --verbose`"
        let result = await EntityFreezer.roundTrip(source, mode: .minimal) {
            $0.replacingOccurrences(of: "please run", with: "Run")
        }
        XCTAssertEqual(result, "Run `curl https://example.com --verbose`")
    }
}
