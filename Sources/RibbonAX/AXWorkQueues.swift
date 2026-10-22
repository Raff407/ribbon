import Foundation

/// One serial queue per app for Accessibility writes. AX calls are synchronous IPC into
/// the target app, so doing them on the main thread lets one slow app stall every
/// animation frame; per-app queues let each app go at its own pace while the main thread
/// only computes springs. Per-app (not global) so a hung app only delays its own windows.
final class AXWorkQueues {
    static let shared = AXWorkQueues()

    private let lock = NSLock()
    private var queues: [pid_t: DispatchQueue] = [:]

    func queue(for pid: pid_t) -> DispatchQueue {
        lock.lock()
        defer { lock.unlock() }
        if let queue = queues[pid] { return queue }
        let queue = DispatchQueue(label: "com.raff.ribbon.ax.\(pid)", qos: .userInteractive)
        queues[pid] = queue
        return queue
    }

    func forget(_ pid: pid_t) {
        lock.lock()
        queues[pid] = nil
        lock.unlock()
    }

    /// Blocks until every write queued so far has run (or `timeout` passes). Used before
    /// quitting so un-parked windows really land on screen.
    func drain(timeout: TimeInterval) {
        lock.lock()
        let all = Array(queues.values)
        lock.unlock()
        let group = DispatchGroup()
        for queue in all {
            group.enter()
            queue.async { group.leave() }
        }
        _ = group.wait(timeout: .now() + timeout)
    }
}
