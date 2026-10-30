import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct HTTPResponse: Sendable {
    public var status: Int
    /// Header names lower-cased.
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    /// `Retry-After` as seconds (delta-seconds or HTTP-date). `0`/absent → nil.
    public var retryAfter: TimeInterval? {
        guard let raw = headers["retry-after"]?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        if let secs = TimeInterval(raw) { return secs > 0 ? secs : nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let date = f.date(from: raw) {
            let delta = date.timeIntervalSinceNow
            return delta > 0 ? delta : nil
        }
        return nil
    }

    public var bodyText: String { String(decoding: body, as: UTF8.self) }
    public var looksLikeHTML: Bool {
        let head = bodyText.prefix(512).lowercased()
        return head.contains("<!doctype html") || head.contains("<html")
    }
}

public protocol HTTPClient: Sendable {
    func get(_ url: URL, headers: [String: String], timeout: TimeInterval) async throws -> HTTPResponse
}

/// Ephemeral URLSession: no cookie jar, no disk cache (authenticated responses must never land in Cache.db).
public struct URLSessionHTTPClient: HTTPClient {
    private let session: URLSession

    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.waitsForConnectivity = false
        session = URLSession(configuration: config)
    }

    public func get(_ url: URL, headers: [String: String], timeout: TimeInterval) async throws -> HTTPResponse {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: timeout)
        request.httpMethod = "GET"
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { return HTTPResponse(status: 0, body: data) }
        var hdrs: [String: String] = [:]
        for (k, v) in http.allHeaderFields {
            if let ks = k as? String, let vs = v as? String { hdrs[ks.lowercased()] = vs }
        }
        return HTTPResponse(status: http.statusCode, headers: hdrs, body: data)
    }
}

/// Test double keyed by URL (host+path) or "*".
public final class FakeHTTPClient: HTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [String: HTTPResponse] = [:]
    public private(set) var requests: [(URL, [String: String])] = []
    public var error: Error?

    public init() {}

    public func script(_ urlOrPattern: String, _ response: HTTPResponse) {
        lock.lock(); defer { lock.unlock() }
        responses[urlOrPattern] = response
    }

    public func get(_ url: URL, headers: [String: String], timeout: TimeInterval) async throws -> HTTPResponse {
        lock.lock(); defer { lock.unlock() }
        requests.append((url, headers))
        if let error { throw error }
        if let r = responses[url.absoluteString] { return r }
        if let host = url.host, let r = responses[host + url.path] { return r }
        if let r = responses["*"] { return r }
        return HTTPResponse(status: 404)
    }
}
