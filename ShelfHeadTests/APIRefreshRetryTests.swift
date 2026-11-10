import XCTest
@testable import ShelfHead

/// Review test gap: the 401 refresh-and-retry in `AudiobookshelfAPI.send`. `URLSession.shared`
/// is hard-coded there, so these tests register a global `URLProtocol` stub (which
/// `URLSession.shared` honours) and drive an isolated client: its own `AuthStore` and
/// `persistsCredentials: false`, so no Keychain or shared state is touched.
/// [device check] not run in the authoring environment; if the stub isn't picked up, the fix is
/// the injectable-session seam described in the batch report.
private nonisolated let refreshOKBody = #"{"user":{"id":"u","username":"x","accessToken":"new","refreshToken":"refresh2"}}"#

final class APIRefreshRetryTests: XCTestCase {
    private var store: AuthStore!
    private var api: AudiobookshelfAPI!

    override func setUp() {
        super.setUp()
        StubProtocol.reset()
        URLProtocol.registerClass(StubProtocol.self)
        store = AuthStore()
        store.set(serverURL: "https://abs.test", accessToken: "old", refreshToken: "refresh1")
        api = AudiobookshelfAPI(store: store, persistsCredentials: false)
    }

    override func tearDown() {
        URLProtocol.unregisterClass(StubProtocol.self)
        StubProtocol.reset()
        super.tearDown()
    }

    func testA401RefreshesOnceAndRetriesOnce() async throws {
        StubProtocol.handler = { req in
            let path = req.url?.path ?? ""
            if path == "/auth/refresh" { return (200, Data(refreshOKBody.utf8)) }
            return req.value(forHTTPHeaderField: "Authorization") == "Bearer new" ? (200, Data("ok".utf8)) : (401, Data())
        }
        let data = try await api.send(path: "/api/me", method: "GET")
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "ok")
        XCTAssertEqual(StubProtocol.paths, ["/api/me", "/auth/refresh", "/api/me"])
        XCTAssertEqual(store.accessToken, "new")
        XCTAssertEqual(store.refreshToken, "refresh2")
    }

    func testASecondA401DoesNotLoop() async {
        StubProtocol.handler = { req in
            (req.url?.path == "/auth/refresh") ? (200, Data(refreshOKBody.utf8)) : (401, Data())
        }
        do {
            _ = try await api.send(path: "/api/me", method: "GET")
            XCTFail("expected unauthorized")
        } catch APIError.unauthorized {
        } catch { XCTFail("wrong error \(error)") }
        XCTAssertEqual(StubProtocol.paths, ["/api/me", "/auth/refresh", "/api/me"])
    }

    func testRejectedRefreshSurfacesUnauthorized() async {
        StubProtocol.handler = { _ in (401, Data()) }
        do {
            _ = try await api.send(path: "/api/me", method: "GET")
            XCTFail("expected unauthorized")
        } catch APIError.unauthorized {
        } catch { XCTFail("wrong error \(error)") }
        XCTAssertEqual(StubProtocol.paths, ["/api/me", "/auth/refresh"])
        XCTAssertEqual(store.refreshToken, "refresh1", "a rejected refresh leaves stored tokens alone")
    }

    func testA5xxOnRefreshIsATransportErrorNotUnauthorized() async {
        StubProtocol.handler = { req in
            (req.url?.path == "/auth/refresh") ? (503, Data()) : (401, Data())
        }
        do {
            _ = try await api.send(path: "/api/me", method: "GET")
            XCTFail("expected an error")
        } catch APIError.unauthorized {
            XCTFail("a flaky refresh must not read as a rejected session (review High 6)")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .networkConnectionLost)
        }
        XCTAssertEqual(StubProtocol.paths, ["/api/me", "/auth/refresh"])
        XCTAssertEqual(store.accessToken, "old")
        XCTAssertEqual(store.refreshToken, "refresh1")
    }

    func testNon401FailureDoesNotRefresh() async {
        StubProtocol.handler = { _ in (500, Data()) }
        do {
            _ = try await api.send(path: "/api/me", method: "GET")
            XCTFail("expected serverError")
        } catch APIError.serverError(let code) {
            XCTAssertEqual(code, 500)
        } catch { XCTFail("wrong error \(error)") }
        XCTAssertEqual(StubProtocol.paths, ["/api/me"])
    }
}

/// Global request stub; records the path of every request it sees for `abs.test`.
nonisolated final class StubProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _handler: (@Sendable (URLRequest) -> (Int, Data))?
    nonisolated(unsafe) private static var _paths: [String] = []

    static var handler: (@Sendable (URLRequest) -> (Int, Data))? {
        get { lock.withLock { _handler } }
        set { lock.withLock { _handler = newValue } }
    }
    static var paths: [String] { lock.withLock { _paths } }
    static func reset() { lock.withLock { _handler = nil; _paths = [] } }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "abs.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.withLock { Self._paths.append(request.url?.path ?? "") }
        let (status, body) = Self.handler?(request) ?? (500, Data())
        let resp = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
