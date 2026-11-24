import UIKit
import XCTest
@testable import Longevity_Compass

@MainActor
final class AIDataConsentTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "AIDataConsentTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        StubURLProtocol.reset()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        StubURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - Consent store

    func testStartsWithoutConsent() {
        let consent = AIDataConsent(defaults: defaults)
        XCTAssertFalse(consent.isGranted)
        XCTAssertFalse(consent.needsRenewal)
        XCTAssertNil(consent.grantedAt)
    }

    func testGrantPersistsAcrossInstances() {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        AIDataConsent(defaults: defaults).grant(at: date)

        let reloaded = AIDataConsent(defaults: defaults)
        XCTAssertTrue(reloaded.isGranted)
        XCTAssertEqual(reloaded.grantedVersion, AIDataConsent.latestVersion)
        XCTAssertEqual(reloaded.grantedAt, date)
    }

    func testNewerVersionAsksAgain() {
        AIDataConsent(defaults: defaults, requiredVersion: 1).grant()

        let v2 = AIDataConsent(defaults: defaults, requiredVersion: 2)
        XCTAssertFalse(v2.isGranted)
        XCTAssertTrue(v2.needsRenewal)

        v2.grant()
        XCTAssertTrue(v2.isGranted)
        XCTAssertFalse(v2.needsRenewal)
        XCTAssertTrue(AIDataConsent(defaults: defaults, requiredVersion: 2).isGranted)
        // Allowing a newer version also covers the older one.
        XCTAssertTrue(AIDataConsent(defaults: defaults, requiredVersion: 1).isGranted)
    }

    func testWithdrawClearsConsent() {
        let consent = AIDataConsent(defaults: defaults)
        consent.grant()
        consent.withdraw()

        XCTAssertFalse(consent.isGranted)
        XCTAssertFalse(consent.needsRenewal)
        XCTAssertNil(consent.grantedAt)
        XCTAssertFalse(AIDataConsent(defaults: defaults).isGranted)
    }

    // MARK: - OpenRouterClient gate

    func testClientRefusesEveryRequestWithoutConsent() async {
        let client = makeClient(consent: AIDataConsent(defaults: defaults))

        await assertThrows(.consentRequired) {
            _ = try await client.analyzeMealFingerprint(imageJPEG: Data([0xFF, 0xD8, 0xFF]))
        }
        await assertThrows(.consentRequired) {
            _ = try await client.generateExerciseImage(exerciseName: "Squat")
        }
        await assertThrows(.consentRequired) {
            _ = try await client.classifyExerciseMuscles(exerciseName: "Squat")
        }
        XCTAssertEqual(StubURLProtocol.requestCount, 0, "No request may reach the network without consent")
    }

    func testClientRefusesAfterConsentIsWithdrawn() async {
        let consent = AIDataConsent(defaults: defaults)
        consent.grant()
        consent.withdraw()
        let client = makeClient(consent: consent)

        await assertThrows(.consentRequired) {
            _ = try await client.classifyExerciseMuscles(exerciseName: "Squat")
        }
        XCTAssertEqual(StubURLProtocol.requestCount, 0)
    }

    func testClientRefusesOlderConsentVersion() async {
        AIDataConsent(defaults: defaults, requiredVersion: 1).grant()
        let client = makeClient(consent: AIDataConsent(defaults: defaults, requiredVersion: 2))

        await assertThrows(.consentRequired) {
            _ = try await client.classifyExerciseMuscles(exerciseName: "Squat")
        }
        XCTAssertEqual(StubURLProtocol.requestCount, 0)
    }

    func testMissingKeyIsReportedBeforeConsent() async {
        let client = makeClient(consent: AIDataConsent(defaults: defaults), apiKey: nil)

        await assertThrows(.missingAPIKey) {
            _ = try await client.classifyExerciseMuscles(exerciseName: "Squat")
        }
        XCTAssertEqual(StubURLProtocol.requestCount, 0)
    }

    func testClientSendsOnceConsentIsGranted() async throws {
        let consent = AIDataConsent(defaults: defaults)
        consent.grant()
        let client = makeClient(consent: consent)
        StubURLProtocol.respond(content: #"{"primary": ["quads"], "secondary": ["glutes", "quads"]}"#)

        let result = try await client.classifyExerciseMuscles(exerciseName: "Squat")

        XCTAssertEqual(StubURLProtocol.requestCount, 1)
        XCTAssertEqual(StubURLProtocol.lastRequest?.url, HealthThresholds.OpenRouter.endpoint)
        XCTAssertEqual(StubURLProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
        XCTAssertEqual(result.primary, [.quads])
        XCTAssertEqual(result.secondary, [.glutes])
    }

    // MARK: - Pending meal queue

    func testQueuedMealIsNotUploadedWithoutConsent() async throws {
        let client = makeClient(consent: AIDataConsent(defaults: defaults))
        let queue = PendingMealQueue(openRouter: client) { _ in
            XCTFail("Nothing should be logged without consent")
        }
        let before = Set(queue.pending.map(\.id))

        queue.enqueue(image: Self.tinyImage(), capturedAt: .now)
        let meal = try XCTUnwrap(queue.pending.first { !before.contains($0.id) })
        defer { queue.discard(meal) }

        await queue.processQueue(includeExhausted: true)

        XCTAssertFalse(queue.isAISharingAllowed)
        XCTAssertEqual(StubURLProtocol.requestCount, 0)
        let stillQueued = try XCTUnwrap(queue.pending.first { $0.id == meal.id }, "The photo must be kept")
        XCTAssertEqual(stillQueued.attempts, 0)
        XCTAssertNil(stillQueued.lastError)
    }

    // MARK: - Helpers

    private func makeClient(consent: AIDataConsent, apiKey: String? = "test-key") -> OpenRouterClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return OpenRouterClient(
            consent: consent,
            session: URLSession(configuration: config),
            apiKeyProvider: { apiKey }
        )
    }

    private func assertThrows(
        _ expected: ExpectedError,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () async throws -> Void
    ) async {
        do {
            try await body()
            XCTFail("Expected \(expected) to be thrown", file: file, line: line)
        } catch let error as OpenRouterError {
            switch (expected, error) {
            case (.consentRequired, .consentRequired), (.missingAPIKey, .missingAPIKey):
                break
            default:
                XCTFail("Expected \(expected), got \(error)", file: file, line: line)
            }
        } catch {
            XCTFail("Expected \(expected), got \(error)", file: file, line: line)
        }
    }

    private enum ExpectedError {
        case consentRequired
        case missingAPIKey
    }

    private static func tinyImage() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { context in
            UIColor.green.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
    }
}

/// Records every request the client makes and answers with a canned chat response.
private final class StubURLProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var requests: [URLRequest] = []
    nonisolated(unsafe) private static var responseContent = "{}"

    static var requestCount: Int { lock.withLock { requests.count } }
    static var lastRequest: URLRequest? { lock.withLock { requests.last } }

    static func reset() {
        lock.withLock {
            requests = []
            responseContent = "{}"
        }
    }

    static func respond(content: String) {
        lock.withLock { responseContent = content }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let content = Self.lock.withLock {
            Self.requests.append(request)
            return Self.responseContent
        }
        let body: [String: Any] = [
            "model": "stub/model",
            "choices": [["message": ["role": "assistant", "content": content]]],
            "usage": ["prompt_tokens": 1, "completion_tokens": 1, "cost": 0],
        ]
        let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
