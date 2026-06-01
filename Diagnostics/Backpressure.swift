import Foundation
import OSLog

public actor BackpressureLimiter {
    private let log = Logger(subsystem: "com.SSHSwiftUIDemo", category: "Backpressure")

    private let limit: Int
    private var inFlight: Int = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(limit: Int) { self.limit = max(1, limit) }

    public func acquire(_ tag: String) async {
        if inFlight < limit {
            inFlight += 1
            log.debug("[BP] acquire OK tag=\(tag, privacy: .public) inFlight=\(self.inFlight, privacy: .public)/\(self.limit, privacy: .public)")
            return
        }

        log.debug("[BP] acquire WAIT tag=\(tag, privacy: .public) inFlight=\(self.inFlight, privacy: .public)/\(self.limit, privacy: .public) waiters=\(self.waiters.count, privacy: .public)")
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            waiters.append(cont)
        }

        inFlight += 1
        log.debug("[BP] acquire RESUME tag=\(tag, privacy: .public) inFlight=\(self.inFlight, privacy: .public)/\(self.limit, privacy: .public)")
    }

    public func release(_ tag: String) {
        precondition(inFlight > 0, "BackpressureLimiter.release called with inFlight=0")
        inFlight -= 1

        if !waiters.isEmpty {
            let cont = waiters.removeFirst()
            cont.resume()
        }

        log.debug("[BP] release tag=\(tag, privacy: .public) inFlight=\(self.inFlight, privacy: .public)/\(self.limit, privacy: .public) waiters=\(self.waiters.count, privacy: .public)")
    }

    public func withPermit<T>(_ tag: String, _ op: () async throws -> T) async rethrows -> T {
        await acquire(tag)
        defer { release(tag) }
        return try await op()
    }
}

public enum Backpressure {
    /// Tune to taste. 2–4 is usually “feels snappy, won’t explode RAM”.
    public static let heavy = BackpressureLimiter(limit: 3)
}
