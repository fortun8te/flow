import Foundation
import XCTest
@testable import Voice

final class Opt1EvidenceTests: XCTestCase {
    func testPrivateRowsPreserveExactTextWithoutTreatingDeliveryAsApproval() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: parent) }
        let directory = parent.appendingPathComponent("opt1-evidence")
        let log = directory.appendingPathComponent("attempts.jsonl")
        let id = UUID()
        let input = "  An exact selection.\n "
        let draft = "An edited selection.\n"
        try Opt1EvidenceLog.append(.init(operationID: id, recordedAt: .now, outcome: .applied,
                                         input: input, proposedOutput: draft), in: directory)
        try Opt1EvidenceLog.append(.init(operationID: id, recordedAt: .now, outcome: .undone), in: directory)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let rows = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map {
            try decoder.decode(Opt1Evidence.self, from: Data($0.utf8))
        }
        XCTAssertEqual(rows.map(\.operationID), [id, id])
        XCTAssertEqual(rows.map(\.outcome), [.applied, .undone])
        XCTAssertEqual(rows[0].input, input)
        XCTAssertEqual(rows[0].proposedOutput, draft)
        XCTAssertNil(rows[1].input)
        XCTAssertTrue(rows.allSatisfy { !$0.verifiedTrainingTarget })
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int, 0o700)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: log.path)[.posixPermissions] as? Int, 0o600)
    }

    func testEvidenceWriterRefusesSymlinkWithoutWritingTheDraft() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: parent) }
        let directory = parent.appendingPathComponent("opt1-evidence")
        let destination = parent.appendingPathComponent("other.jsonl")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("untouched".utf8).write(to: destination)
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("attempts.jsonl"),
                                                    withDestinationURL: destination)

        XCTAssertThrowsError(try Opt1EvidenceLog.append(.init(operationID: UUID(), recordedAt: .now,
                                                             outcome: .rejected, input: "private"), in: directory))
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "untouched")
    }
}
