import Foundation
import SwiftUI
import OSLog

@MainActor
final class FanRPMViewModel: ObservableObject {

    // MARK: Published
    @Published private(set) var tach: FanCGI.FanRPMStatus?
    @Published var lastError: String?

    // MARK: Private
    private let cgi: FanCGI
    private let logger = Logger(subsystem: "com.SSHSwiftUIDemo", category: "FanRPMViewModel")

    /// Stored in a way we can cancel from deinit without tripping MainActor isolation rules.
    nonisolated(unsafe) private var pollTask: Task<Void, Never>?

    init(baseURL: URL) {
        self.cgi = FanCGI(baseURL: baseURL)
        logger.info("[FanRPMVM] init baseURL=\(baseURL.absoluteString, privacy: .public)")
    }

    deinit {
        print("[DEINIT] \(String(describing: Self.self))")
        // cancellation is thread-safe; don’t touch @Published here.
        pollTask?.cancel()
    }

    // MARK: Polling

    func startPolling(interval: Duration = .seconds(1)) {
        stopPolling()

        pollTask = Task { [weak self] in
            guard let self else { return }
            self.logger.info("[FanRPMVM] startPolling interval=\(String(describing: interval), privacy: .public)")

            while !Task.isCancelled {
                await self.refreshOnce()
                try? await Task.sleep(for: interval)
            }

            self.logger.info("[FanRPMVM] polling task exit cancelled=\(Task.isCancelled, privacy: .public)")
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
        logger.info("[FanRPMVM] stopPolling")
    }

    func refreshOnce() async {
        do {
            let s = try await cgi.tachStatus()
            tach = s
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            logger.error("[FanRPMVM] refreshOnce error=\(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: UI Formatting

    var healthText: String {
        (tach?.health ?? "unknown")
    }

    var healthColor: Color {
        switch healthText.lowercased() {
        case "ok": return .green
        case "stalled": return .red
        case "no_signal": return .orange
        default: return .gray
        }
    }

    var fanStalledString: String {
        if let stalled = tach?.fanStalled {
            return stalled ? "true" : "false"
        }
        return "nil"
    }

    var fanStalledColor: Color {
        if tach?.fanStalled == true { return .red }
        if tach?.fanStalled == false { return .secondary }
        return .gray
    }

    var lastEdgeAgeString: String {
        guard let age = tach?.lastEdgeAgeSec else { return "nil" }
        return String(format: "%.2f", age)
    }

    var lastEdgeAgeColor: Color {
        guard let age = tach?.lastEdgeAgeSec else { return .gray }
        // Keep this aligned with daemon STALL_AFTER_SEC (you used 1.5s)
        return (age > 1.5) ? .red : .secondary
    }

    var rpmString: String {
        "\(tach?.rpm ?? 0)"
    }

    var rpmRawString: String {
        if let raw = tach?.rpmRaw { return "\(raw)" }
        return "nil"
    }

    var tachPinString: String {
        // FanRPMStatus includes tach_pin? In our struct: not currently.
        // If your endpoint includes it, add fields to FanRPMStatus and this will light up.
        return "—"
    }

    var pprString: String {
        return "2"
    }

    var timestampLine: String {
        tach?.timestamp ?? "—"
    }
}
