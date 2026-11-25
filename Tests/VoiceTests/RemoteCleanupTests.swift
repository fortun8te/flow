import Foundation
import XCTest
@testable import Voice

/// Fake PC server for RemoteCleanup: answers /health and /v1/cleanup from static settings and records each request.
final class FakePCServer: URLProtocol {
    struct Hit {
        let path: String
        let token: String?
        let body: [String: Any]
    }

    nonisolated(unsafe) static var hits: [Hit] = []
    nonisolated(unsafe) static var healthOK = true
    nonisolated(unsafe) static var cleanupStatus = 200
    nonisolated(unsafe) static var cleanupText = ""
    nonisolated(unsafe) static var hangCleanup = false

    static func reset() {
        hits = []
        healthOK = true
        cleanupStatus = 200
        cleanupText = ""
        hangCleanup = false
    }

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FakePCServer.self]
        config.timeoutIntervalForRequest = 5
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        var raw = request.httpBody
        if raw == nil, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 65536)
            var data = Data()
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            stream.close()
            raw = data
        }
        let body = (raw.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) ?? [:]
        Self.hits.append(Hit(path: path, token: request.value(forHTTPHeaderField: "X-Flow-Token"), body: body))
        if path == "/v1/cleanup" && Self.hangCleanup { return }  // never answers: the client's timeout must fire

        let status: Int
        let object: [String: Any]
        if path == "/health" {
            status = 200
            object = ["ok": Self.healthOK, "model": "T4-step918", "gpu": true]
        } else {
            status = Self.cleanupStatus
            object = ["text": Self.cleanupText, "ms": 12]
        }
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class RemoteCleanupTests: XCTestCase {
    private let base = URL(string: "http://pc.test:8765")!
    private let token = "test-token"
    private let longDictation = "um so i was thinking we should push the meeting to thursday because the client said they can only do after lunch and i think its easier for everyone you know so can you send the invite and also let finance know that the budget review moves too and ill need the deck by wednesday night okay thanks"
    private let goodCleanup = "I was thinking we should push the meeting to Thursday because the client said they can only do after lunch, and I think it's easier for everyone. Can you send the invite and also let Finance know that the budget review moves too? I'll need the deck by Wednesday night. Okay, thanks!"

    override func setUp() {
        super.setUp()
        FakePCServer.reset()
    }

    override func tearDown() {
        FakePCServer.reset()
        super.tearDown()
    }

    private func clean(_ input: String, client: RemoteCleanup.Client, timeout: TimeInterval = 2) async -> String? {
        await RemoteCleanup.guardedCleanup(input, client: client, base: base, token: token, timeout: timeout,
                                           userVocabulary: nil, personalityStyle: "neutral", appContextLabel: nil)
    }

    func testHealthIsCachedForThirtySecondsAndSendsToken() async {
        let client = RemoteCleanup.Client(session: FakePCServer.session())
        FakePCServer.cleanupText = goodCleanup
        let first = await client.isHealthy(base: base, token: token)
        let second = await client.isHealthy(base: base, token: token)
        XCTAssertTrue(first)
        XCTAssertTrue(second)
        XCTAssertEqual(FakePCServer.hits.filter { $0.path == "/health" }.count, 1, "health must be cached")
        XCTAssertEqual(FakePCServer.hits.first?.token, token)
    }

    func testUnhealthyServerIsReportedAndCached() async {
        FakePCServer.healthOK = false
        let client = RemoteCleanup.Client(session: FakePCServer.session())
        let healthy = await client.isHealthy(base: base, token: token)
        XCTAssertFalse(healthy)
        // A cached negative answer means no second request, so a sleeping PC costs one short wait.
        let again = await client.isHealthy(base: base, token: token)
        XCTAssertFalse(again)
        XCTAssertEqual(FakePCServer.hits.count, 1)
    }

    func testLongDictationUsesPCAnswerAfterGuards() async {
        FakePCServer.cleanupText = goodCleanup
        let result = await clean(longDictation, client: RemoteCleanup.Client(session: FakePCServer.session()))
        XCTAssertNotNil(result)
        XCTAssertFalse(result?.contains("um so") ?? true)
        XCTAssertEqual(FakePCServer.hits.last?.path, "/v1/cleanup")
        let content = FakePCServer.hits.last?.body["content"] as? String ?? ""
        XCTAssertTrue(content.hasPrefix("[Cleanup: light] [Styling: excited] [Structure: lists] [Context: general]\n"),
                      "the PC must get the same T4 control line as the local server")
    }

    func testCutReplyIsRejectedSoLocalPathRuns() async {
        // Drops most of the speaker's content: the content guard must refuse it.
        FakePCServer.cleanupText = "I was thinking we should push the meeting to Thursday."
        let result = await clean(longDictation, client: RemoteCleanup.Client(session: FakePCServer.session()))
        XCTAssertNil(result)
    }

    func testNegationAddedIsRejected() async {
        FakePCServer.cleanupText = "We should push the meeting to Thursday."
        let result = await clean("um we should not push the meeting to thursday because the client is busy that day", client: RemoteCleanup.Client(session: FakePCServer.session()))
        XCTAssertNil(result)
    }

    func testEmptyAndTemplateLeaksAreRejected() async {
        FakePCServer.cleanupText = "EMPTY"
        let answer1 = await clean(longDictation, client: RemoteCleanup.Client(session: FakePCServer.session()))
        XCTAssertNil(answer1)
        FakePCServer.cleanupText = "<|im_start|>assistant\nSomething"
        let answer2 = await clean(longDictation, client: RemoteCleanup.Client(session: FakePCServer.session()))
        XCTAssertNil(answer2)
    }

    func testServerErrorFallsBackAndMarksPCUnavailable() async {
        FakePCServer.cleanupStatus = 503
        let client = RemoteCleanup.Client(session: FakePCServer.session())
        let answer3 = await clean(longDictation, client: client)
        XCTAssertNil(answer3)
        // The failure is cached as unavailable: the next dictation does not even ask.
        let before = FakePCServer.hits.count
        let answer4 = await clean(longDictation, client: client)
        XCTAssertNil(answer4)
        XCTAssertEqual(FakePCServer.hits.count, before)
    }

    func testSlowPCIsCutOffAtTheTimeout() async {
        FakePCServer.cleanupText = goodCleanup
        FakePCServer.hangCleanup = true
        let started = Date()
        let result = await clean(longDictation, client: RemoteCleanup.Client(session: FakePCServer.session()), timeout: 0.3)
        XCTAssertNil(result)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "dictation must not wait past the budget for the PC")
    }

    func testNonEnglishIsNeverSentToPC() async {
        FakePCServer.cleanupText = goodCleanup
        let dutch = "Ik denk dat we de vergadering naar donderdag moeten verplaatsen omdat de klant alleen na de lunch kan en het is makkelijker voor iedereen dus kun je de uitnodiging sturen"
        let answer5 = await clean(dutch, client: RemoteCleanup.Client(session: FakePCServer.session()))
        XCTAssertNil(answer5)
        XCTAssertTrue(FakePCServer.hits.isEmpty)
    }

    @MainActor func testSettingOffKeepsPCOut() async {
        let key = RemoteCleanup.settingKey
        let previous = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(false, forKey: key)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        }
        XCTAssertFalse(RemoteCleanup.isEnabled)
        let result = await RemoteCleanup.cleanedText(longDictation, cleanupLevel: "medium", userVocabulary: nil,
                                                     personalityStyle: "neutral", appContextLabel: nil,
                                                     longProse: false, timeout: 2, client: RemoteCleanup.Client(session: FakePCServer.session()))
        XCTAssertNil(result)
        XCTAssertTrue(FakePCServer.hits.isEmpty)
    }

    func testSettingDefaultsToOff() {
        let key = RemoteCleanup.settingKey
        let previous = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.removeObject(forKey: key)
        defer { if let previous { UserDefaults.standard.set(previous, forKey: key) } }
        XCTAssertFalse(RemoteCleanup.isEnabled)  // Jordan: dictations stay on the Mac
    }
}
