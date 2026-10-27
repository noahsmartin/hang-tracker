import Foundation
import Synchronization

struct Block {
    let start: UInt64
    let end: UInt64
}

struct Activity {
    /// Also identifies the stretch of work that follows the transition.
    let uptime: UInt64
    /// The stretch can become a hitch: the run loop is awake and in a reported mode.
    let isMonitored: Bool
}

/// Hand-off from the main thread (the only producer) to the monitor thread (the only consumer).
final class ActivityChannel: Sendable {
    private typealias Slots = InlineArray<64, Atomic<UInt64>>

    /// `(uptime << 1) | isMonitored`, packed so both are read and written together.
    private let activity = Atomic<UInt64>(0)

    private let closed = Atomic<Bool>(false)

    private let wakeup = DispatchSemaphore(value: 0)

    /// Single-producer, single-consumer ring buffer. The indices order slot accesses, so those can
    /// be relaxed.
    private let writeIndex = Atomic<Int>(0)
    private let readIndex = Atomic<Int>(0)
    private let starts = Slots { _ in Atomic(0) }
    private let ends = Slots { _ in Atomic(0) }

    // MARK: Producer

    func publish(_ activity: Activity) {
        self.activity.store((activity.uptime << 1) | (activity.isMonitored ? 1 : 0), ordering: .releasing)
    }

    func wake() {
        wakeup.signal()
    }

    func push(_ block: Block) {
        let write = writeIndex.load(ordering: .relaxed)
        let read = readIndex.load(ordering: .acquiring)
        guard write - read < starts.count else { return }
        let slot = write % starts.count
        starts[slot].store(block.start, ordering: .relaxed)
        ends[slot].store(block.end, ordering: .relaxed)
        writeIndex.store(write + 1, ordering: .releasing)
    }

    // MARK: Consumer

    func loadActivity() -> Activity {
        let packed = activity.load(ordering: .acquiring)
        return Activity(uptime: packed >> 1, isMonitored: packed & 1 != 0)
    }

    func pop() -> Block? {
        let read = readIndex.load(ordering: .relaxed)
        let write = writeIndex.load(ordering: .acquiring)
        guard read != write else { return nil }
        let slot = read % starts.count
        let block = Block(start: starts[slot].load(ordering: .relaxed), end: ends[slot].load(ordering: .relaxed))
        readIndex.store(read + 1, ordering: .releasing)
        return block
    }

    /// `deadline` is in uptime nanoseconds; `nil` waits until woken.
    func wait(until deadline: UInt64?) {
        _ = wakeup.wait(timeout: deadline.map(DispatchTime.init(uptimeNanoseconds:)) ?? .distantFuture)
    }

    func close() {
        closed.store(true, ordering: .releasing)
        wakeup.signal()
    }

    var isClosed: Bool {
        closed.load(ordering: .acquiring)
    }
}

/// Nanoseconds. Does not advance while the device sleeps.
func uptime() -> UInt64 {
    DispatchTime.now().uptimeNanoseconds
}

func elapsed(from start: UInt64, to end: UInt64) -> UInt64 {
    end > start ? end - start : 0
}
