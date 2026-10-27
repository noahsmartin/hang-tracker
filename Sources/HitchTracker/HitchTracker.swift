import Foundation

/// A period during which the main run loop was blocked.
public struct Hitch: Sendable, Equatable {
    public let startDate: Date

    /// In milliseconds.
    public let duration: Int

    /// The main thread's stack during the hitch, if a provider was given and capture succeeded.
    public let stacktrace: Stacktrace?
}

/// Return addresses, innermost frame first.
public struct Stacktrace: Sendable, Equatable {
    public let frames: [UInt]
}

/// Called on a background thread while the main thread is suspended. Writes the main thread's
/// return addresses, innermost frame first, into `frames` and returns how many it wrote. Must not
/// allocate or take locks, since the main thread may hold them.
public typealias StacktraceProvider = @Sendable (_ mainThread: thread_t, _ frames: UnsafeMutableBufferPointer<UInt>) -> Int

/// Reports times the main run loop is blocked for at least `minDuration`, batched until it has gone
/// `interval` without a hitch.
@MainActor
public final class HitchTracker {
    /// In milliseconds.
    public let minDuration: Int

    /// In milliseconds.
    public let interval: Int

    private let monitor: RunLoopMonitor

    /// - Parameters:
    ///   - modes: Only blocks while the main run loop is in one of these modes are reported, such
    ///     as `.tracking` for scrolling. `.common` reports blocks in every common mode.
    ///   - stacktraceProvider: Without one, hitches have no `stacktrace`.
    public init(
        minDuration: Int,
        interval: Int,
        modes: [RunLoop.Mode] = [.common],
        stacktraceProvider: StacktraceProvider? = nil
    ) {
        self.minDuration = minDuration
        self.interval = interval
        monitor = RunLoopMonitor(
            minDuration: minDuration,
            interval: interval,
            modes: modes,
            stacktraceProvider: stacktraceProvider
        )
    }

    isolated deinit {
        monitor.stop()
    }

    /// Has no effect if already started.
    ///
    /// - Parameter callback: Called on a background thread with each batch. Never called with an
    ///   empty array.
    public func start(_ callback: @escaping @Sendable ([Hitch]) -> Void) {
        monitor.start(callback)
    }

    /// Discards hitches that have not been reported yet.
    public func stop() {
        monitor.stop()
    }
}
