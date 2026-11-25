import Foundation
import Testing
@testable import Voice

struct LocalASREvaluationHarnessTests {
    @Test func agreementIsNormalizedEditDistanceNotAccuracy() {
        #expect(LocalASREvaluationHarness.agreement(reference: "Hello, TEAM!", actual: "hello team") == .init(editDistance: 0, referenceWords: 2))
        #expect(LocalASREvaluationHarness.agreement(reference: "one two three", actual: "one four") == .init(editDistance: 2, referenceWords: 3))
        #expect(LocalASREvaluationHarness.agreement(reference: "", actual: "hello") == nil)
        #expect(LocalASREvaluationHarness.agreement(reference: "a", actual: "a b c")?.rate == 2)
    }

    @Test func quantilesIncludeAllSuppliedObservations() {
        #expect(LocalASREvaluationHarness.median([]) == nil)
        #expect(LocalASREvaluationHarness.p95([]) == nil)
        #expect(LocalASREvaluationHarness.median([7, 1, 3, 5]) == 4)
        #expect(LocalASREvaluationHarness.p95([7, 1, 3, 5]) == 7)
        #expect(LocalASREvaluationHarness.p95(Array(1...20).map(Double.init)) == 19)
    }

    @Test func audioPathsStayInsideManifestDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("clip.wav")
        try Data([0]).write(to: file)
        let accepted = try LocalASREvaluationHarness.audioURL(relative: "clip.wav", directory: root)
        #expect(accepted.path == file.resolvingSymlinksInPath().path)
        for path in ["/absolute.wav", "../clip.wav", "nested/../../clip.wav", "missing.wav"] {
            #expect(throws: LocalASREvaluationHarness.Failure.self) {
                try LocalASREvaluationHarness.audioURL(relative: path, directory: root)
            }
        }
        let alias = root.appendingPathComponent("alias.wav")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: file)
        #expect(throws: LocalASREvaluationHarness.Failure.self) {
            try LocalASREvaluationHarness.audioURL(relative: "alias.wav", directory: root)
        }
    }
}
