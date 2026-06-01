import Foundation
import OSLog
import Combine

public enum CloudflaredCGIError: Error, LocalizedError {
    case httpStatus(Int, String)
    case emptyBody
    case decodeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .httpStatus(let code, let head):
            return "HTTP \(code). Body starts: \(head)"
        case .emptyBody:
            return "Empty response body"
        case .decodeFailed(let head):
            return "Decode failed. Body starts: \(head)"
        }
    }
}

public struct CloudflaredCGI {
    private let log = Logger(subsystem: "com.SSHSwiftUIDemo", category: "CloudflaredCGI")

    public let baseCGIURL: URL
    public var session: URLSession = .shared

    public init(baseCGIURL: URL, session: URLSession = .shared) {
        self.baseCGIURL = baseCGIURL
        self.session = session
    }

    /// Fetches /cgi-bin/cloudflared_metrics.cgi
    /// Returns decoded model + full raw body (utf8 best-effort).
    public func fetchMetrics() async throws -> (CloudflaredMetricsResponse, String) {
        let url = baseCGIURL.appendingPathComponent("cloudflared_metrics.cgi")
        log.info("➡️ GET \(url.absoluteString, privacy: .public)")

        var req = URLRequest(url: url)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.timeoutInterval = 6

        let (data, resp) = try await session.data(for: req)
        let raw = String(data: data, encoding: .utf8) ?? "<non-utf8>"
        let head = String(raw.prefix(300))

        guard let http = resp as? HTTPURLResponse else {
            throw CloudflaredCGIError.httpStatus(-1, head)
        }

        log.info("⬅️ HTTP \(http.statusCode) bytes=\(data.count)")

        guard (200...299).contains(http.statusCode) else {
            throw CloudflaredCGIError.httpStatus(http.statusCode, head)
        }

        guard !data.isEmpty else {
            throw CloudflaredCGIError.emptyBody
        }

        do {
            let decoded = try JSONDecoder().decode(CloudflaredMetricsResponse.self, from: data)
            return (decoded, raw)
        } catch {
            log.error("❌ decode failed. head=\(head, privacy: .public)")
            throw CloudflaredCGIError.decodeFailed(head)
        }
    }
}
