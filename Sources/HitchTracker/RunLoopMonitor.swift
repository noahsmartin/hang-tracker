import Foundation

@MainActor
final class RunLoopMonitor {
    private let minDurationNs: UInt64
    private let intervalNs: UInt64
    private let stacktraceProvider: StacktraceProvider?
    private let modes: [RunLoop.Mode]
    private let observesAllModes: Bool

    private var observers: [CFRunLoopObserver] = []
    private var channel: ActivityChannel?
    private var lastActivity = Activity(uptime: 0, isMonitored: false)

    init(minDuration: Int, interval: Int, modes: [RunLoop.Mode], stacktraceProvider: StacktraceProvider?) {
        self.stacktraceProvider = stacktraceProvider
        self.modes = modes
        observesAllModes = modes.contains(.common)
        minDurationNs = UInt64(max(minDuration, 1)) * 1_000_000
        intervalNs = UInt64(max(interval, 0)) * 1_000_000
    }

    func start(_ callback: @escaping @Sendable ([Hitch]) -> Void) {
        guard channel == nil else { return }

        let channel = ActivityChannel()
        self.channel = channel
        let mainThread = pthread_mach_thread_np(pthread_self())
        // Called from the main thread, so it is busy now. The current mode is unknown until the
        // next transition.
        lastActivity = Activity(uptime: uptime(), isMonitored: observesAllModes)
        channel.publish(lastActivity)

        // Busy transitions run before every other observer and sleep runs after them, so work in
        // other observers (such as Core Animation's commit) counts as blocking.
        observers = [
            makeObserver(activities: [.entry, .beforeTimers, .beforeSources, .afterWaiting, .exit], order: CFIndex.min),
            makeObserver(activities: .beforeWaiting, order: CFIndex.max),
        ]
        for observer in observers {
            for mode in modes {
                CFRunLoopAddObserver(CFRunLoopGetMain(), observer, CFRunLoopMode(mode.rawValue as CFString))
            }
        }

        // Without `@Sendable` the closure inherits main actor isolation and traps off the main thread.
        let thread = Thread { @Sendable [minDurationNs, intervalNs, stacktraceProvider] in
            HitchCollector(
                channel: channel,
                mainThread: mainThread,
                minDurationNs: minDurationNs,
                intervalNs: intervalNs,
                stacktraceProvider: stacktraceProvider,
                callback: callback
            ).run()
        }
        thread.name = "io.sentry.HitchTracker"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    func stop() {
        for observer in observers {
            CFRunLoopObserverInvalidate(observer)
        }
        observers = []
        channel?.close()
        channel = nil
    }

    private func makeObserver(activities: CFRunLoopActivity, order: CFIndex) -> CFRunLoopObserver {
        CFRunLoopObserverCreateWithHandler(nil, activities.rawValue, true, order) { [weak self] _, activity in
            // Main run loop observers always fire on the main thread.
            MainActor.assumeIsolated {
                self?.record(activity)
            }
        }
    }

    /// Any transition ends the current stretch of work.
    private func record(_ activity: CFRunLoopActivity) {
        guard let channel else { return }
        let now = uptime()
        let previous = lastActivity
        let hitchEnded = previous.isMonitored && elapsed(from: previous.uptime, to: now) >= minDurationNs
        if hitchEnded {
            channel.push(Block(start: previous.uptime, end: now))
        }
        let isMonitored = switch activity {
        case .beforeWaiting: false
        // Unless every mode is observed, the run loop may be returning to a mode whose activity
        // won't be seen, so its work would look like one long block.
        case .exit: observesAllModes
        default: true
        }
        lastActivity = Activity(uptime: now, isMonitored: isMonitored)
        channel.publish(lastActivity)
        // The collector waits with no deadline while no monitored stretch is running or a hitch is
        // ongoing.
        if hitchEnded || (!previous.isMonitored && isMonitored) {
            channel.wake()
        }
    }
}
