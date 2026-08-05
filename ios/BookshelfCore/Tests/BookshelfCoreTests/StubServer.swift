import Foundation
import Testing
@testable import BookshelfCore

/// A canned sync Worker, wired in via `URLProtocol`.
///
/// Tests the whole client stack — URL building, headers, status-code handling,
/// decoding — rather than a hand-rolled fake that would agree with whatever the
/// client happens to do. The status codes here are the ones the real Worker
/// returns, and the 409 body shape matches `putData()` in `worker.ts`.
/// Parent suite for everything that drives `StubServer`.
///
/// `StubServer`'s routes are process-wide — `URLProtocol` is registered by class,
/// so there is one set of them. `.serialized` only orders tests *within* a suite,
/// which left the sync and community suites overwriting each other's routes when
/// the whole file ran. Nesting both under one serialized parent is what actually
/// makes them take turns.
@Suite(.serialized)
struct StubbedNetwork {}

final class StubServer: URLProtocol, @unchecked Sendable {

    struct Response {
        var status: Int
        var json: String
        init(_ status: Int, _ json: String) { self.status = status; self.json = json }
    }

    struct Request: Sendable {
        var method: String
        var path: String
        var body: JSONValue?
        var authorization: String?
    }

    /// `"METHOD /path"` → the response to give. A missing entry is a 404, which
    /// is a louder failure than silently returning success.
    nonisolated(unsafe) static var routes: [String: Response] = [:]
    /// Every request that arrived, so a test can assert on what was actually sent
    /// — `baseUpdatedAt` and `force` are the two fields that decide whether the
    /// server accepts or rejects a write.
    nonisolated(unsafe) static private(set) var received: [Request] = []
    nonisolated(unsafe) static var failWithOffline = false
    /// A URLError to fail every request with, for telling "no network" apart
    /// from "the server didn't answer".
    nonisolated(unsafe) static var failWith: URLError.Code?

    private static let lock = NSLock()

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        routes = [:]
        received = []
        failWithOffline = false
        failWith = nil
    }

    static func record(_ request: Request) {
        lock.lock(); defer { lock.unlock() }
        received.append(request)
    }

    static var lastAuthorization: String? {
        lock.lock(); defer { lock.unlock() }
        return received.last?.authorization
    }

    static var lastRequest: Request? {
        lock.lock(); defer { lock.unlock() }
        return received.last
    }

    static func requests(_ path: String) -> [Request] {
        lock.lock(); defer { lock.unlock() }
        return received.filter { $0.path == path }
    }

    /// A session that routes everything through this stub.
    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubServer.self]
        return URLSession(configuration: config)
    }

    // MARK: - URLProtocol

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let method = request.httpMethod ?? "GET"
        let path = request.url?.path ?? ""
        // URLProtocol strips httpBody for some methods; httpBodyStream survives.
        let body = Self.readBody(from: request).flatMap { try? JSONValue.parse($0) }
        Self.record(Request(
            method: method, path: path, body: body,
            authorization: request.value(forHTTPHeaderField: "Authorization")
        ))

        if let code = Self.failWith {
            client?.urlProtocol(self, didFailWithError: URLError(code))
            return
        }
        if Self.failWithOffline {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }

        let response = Self.routes["\(method) \(path)"] ?? Response(404, #"{"error":"Not found"}"#)
        let http = HTTPURLResponse(
            url: request.url!,
            statusCode: response.status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(response.json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func readBody(from request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let size = 4096
        var buffer = [UInt8](repeating: 0, count: size)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: size)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
