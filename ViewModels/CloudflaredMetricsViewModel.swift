import Foundation
import OSLog

@MainActor
public final class CloudflaredMetricsViewModel: ObservableObject {
    private let log = Logger(subsystem: "com.SSHSwiftUIDemo", category: "CloudflaredMetricsVM")

    // UI state
    @Published public private(set) var isLoading: Bool = false
    @Published public private(set) var lastUpdated: Date?
    @Published public private(set) var lastError: String?
    @Published public private(set) var lastRawBody: String = ""

    // Decoded flags
    @Published public private(set) var hasByteCounters: Bool? = nil
    @Published public private(set) var hasCloudflaredMetrics: Bool? = nil

    // Totals
    @Published public private(set) var totalRequests: Int = 0
    @Published public private(set) var totalErrors: Int = 0

    // Rates (computed client-side)
    @Published public private(set) var requestsPerSec: Double = 0
    @Published public private(set) var errorsPerSec: Double = 0

    public var isHealthy: Bool { lastError == nil }

    private let cgi: CloudflaredCGI
    private var pollTask: Task<Void, Never>?
    private var prevSample: (date: Date, req: Int, err: Int)?

    public init(baseCGIURL: URL) {
        self.cgi = CloudflaredCGI(baseCGIURL: baseCGIURL)
    }

    public func start(interval: TimeInterval = 1.0) {
        guard pollTask == nil else { return }
        log.info("start polling interval=\(interval, privacy: .public)s")

        pollTask = Task {
            while !Task.isCancelled {
                await tickOnce()
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    public func stop() {
        log.info("⏹ stop polling")
        pollTask?.cancel()
        pollTask = nil
    }

    public func tickOnce() async {
        log.error("METRICS URL = \(self.cgi.baseCGIURL.absoluteString, privacy: .public)")
        isLoading = true
        defer { isLoading = false }

        do {
            let (m, raw) = try await cgi.fetchMetrics()
            lastRawBody = raw
            lastUpdated = Date()

            guard m.ok else {
                lastError = "Metrics returned ok=false"
                return
            }

            hasByteCounters = m.hasByteCounters
            hasCloudflaredMetrics = m.hasCloudflaredMetrics

            let now = Date()
            let req = m.totalRequests ?? 0
            let err = m.totalRequestErrors ?? 0

            totalRequests = req
            totalErrors = err
            lastError = nil

            if let prev = prevSample {
                let dt = now.timeIntervalSince(prev.date)
                if dt > 0 {
                    let dReq = max(0, req - prev.req)
                    let dErr = max(0, err - prev.err)
                    requestsPerSec = Double(dReq) / dt
                    errorsPerSec = Double(dErr) / dt
                }
            }
            prevSample = (now, req, err)

            log.info("req=\(req) err=\(err) rps=\(self.requestsPerSec, privacy: .public) eps=\(self.errorsPerSec, privacy: .public)")
        } catch {
            lastError = error.localizedDescription
            log.error("tick error: \(error.localizedDescription, privacy: .public)")
        }
    }
}
