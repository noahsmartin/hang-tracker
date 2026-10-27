import Foundation

/// Created and used only on the monitor thread. Sleeps until the current stretch of work would
/// become a hitch or pending hitches are due; otherwise until the main thread wakes it.
final class HitchCollector {
    private static let maxFrames = 128

    private let channel: ActivityChannel
    private let mainThread: thread_t
    private let minDurationNs: UInt64
    private let intervalNs: UInt64
    private let stacktraceProvider: StacktraceProvider?
    private let callback: @Sendable ([Hitch]) -> Void

    private var pendingHitches: [Hitch] = []
    private var lastHitchEnd: UInt64 = 0
    /// Keyed by the uptime the block started at.
    private var ongoingStacktrace: (start: UInt64, stacktrace: Stacktrace?)?

    init(
        channel: ActivityChannel,
        mainThread: thread_t,
        minDurationNs: UInt64,
        intervalNs: UInt64,
        stacktraceProvider: StacktraceProvider?,
        callback: @escaping @Sendable ([Hitch]) -> Void
    ) {
        self.channel = channel
        self.mainThread = mainThread
        self.minDurationNs = minDurationNs
        self.intervalNs = intervalNs
        self.stacktraceProvider = stacktraceProvider
        self.callback = callback
    }

    func run() {
        while !channel.isClosed {
            channel.wait(until: step())
        }
    }

    /// Returns when to run next, or `nil` to wait for the main thread.
    private func step() -> UInt64? {
        // Snapshot before draining, so every block that ended before the snapshot is drained now.
        let activity = channel.loadActivity()
        let now = uptime()

        while let block = channel.pop() {
            let stacktrace = ongoingStacktrace?.start == block.start ? ongoingStacktrace?.stacktrace : nil
            pendingHitches.append(Hitch(
                startDate: Date(timeIntervalSinceNow: -Double(elapsed(from: block.start, to: now)) / 1e9),
                duration: Int(elapsed(from: block.start, to: block.end) / 1_000_000),
                stacktrace: stacktrace
            ))
            lastHitchEnd = max(lastHitchEnd, block.end)
        }

        var deadline: UInt64?
        let isBlocked = activity.isMonitored && elapsed(from: activity.uptime, to: now) >= minDurationNs
        if isBlocked {
            if ongoingStacktrace?.start != activity.uptime {
                let stacktrace = captureMainThreadStacktrace()
                // Drop it if the hitch ended before the main thread was suspended.
                let stillBlocked = channel.loadActivity().uptime == activity.uptime
                ongoingStacktrace = (activity.uptime, stillBlocked ? stacktrace : nil)
            }
        } else {
            ongoingStacktrace = nil
            if activity.isMonitored {
                deadline = activity.uptime + minDurationNs
            }
            if !pendingHitches.isEmpty {
                let flushTime = lastHitchEnd + intervalNs
                if now >= flushTime {
                    let hitches = pendingHitches
                    pendingHitches = []
                    callback(hitches)
                } else {
                    deadline = min(deadline ?? flushTime, flushTime)
                }
            }
        }
        return deadline
    }

    private func captureMainThreadStacktrace() -> Stacktrace? {
        guard let stacktraceProvider else { return nil }
        // The array's storage is allocated before the main thread is suspended.
        let frames = [UInt](unsafeUninitializedCapacity: Self.maxFrames) { buffer, count in
            guard thread_suspend(mainThread) == KERN_SUCCESS else { return }
            count = min(max(stacktraceProvider(mainThread, buffer), 0), buffer.count)
            thread_resume(mainThread)
        }
        return frames.isEmpty ? nil : Stacktrace(frames: frames)
    }
}
