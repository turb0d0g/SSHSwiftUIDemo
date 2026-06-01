//
//  FanService.swift
//  SSHSwiftUIDemo
//

//
//  FanService.swift
//  SSHSwiftUIDemo
//
//  Polls FanCGI and emits FanStatus via Combine without fabricating values.
//  - Output: FanStatus (never nil)
//  - On error: log + skip emission
//  - No Future promises to forget
//

import Foundation
import Combine
import OSLog

public final class FanService {
    private let fan: FanCGI
    private let logger = Logger(subsystem: "com.SSHSwiftUIDemo", category: "FanService")

    private let subject = PassthroughSubject<FanStatus, Never>()
    private var timerCancellable: AnyCancellable?
    private var pollTask: Task<Void, Never>?

    public init(fan: FanCGI) {
        self.fan = fan
        logger.log("[FanService] init")
    }

    deinit {
        logger.log("[FanService] deinit → cancel")
        stop()
    }

    /// Start polling and return a publisher of real FanStatus values.
    /// Call `stop()` when the screen disappears to avoid duplicate poll loops.
    func statusPublisher(interval: TimeInterval = 2.0) -> AnyPublisher<FanStatus, Never> {
        start(interval: interval)
        return subject.eraseToAnyPublisher()
    }

    public func start(interval: TimeInterval = 2.0) {
        logger.debug("[FanService] start(interval=\(interval, privacy: .public))")

        // Prevent duplicate timers/tasks.
        stop()

        timerCancellable = Timer
            .publish(every: interval, on: .main, in: .default)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self else { return }

                // If a poll is in-flight, skip this tick (prevents pileups).
                if self.pollTask != nil { return }

                self.pollTask = Task.detached(priority: .utility) { [weak self] in
                    guard let self else { return }
                    defer { Task { @MainActor in self.pollTask = nil } }

                    do {
                        let s = try await self.fan.status()
                        self.subject.send(s)
                    } catch {
                        self.logger.error("[FanService] status error: \(String(describing: error), privacy: .public)")
                        // Drop on error: emit nothing.
                    }
                }
            }
    }

    public func stop() {
        timerCancellable?.cancel()
        timerCancellable = nil

        pollTask?.cancel()
        pollTask = nil
    }
}
