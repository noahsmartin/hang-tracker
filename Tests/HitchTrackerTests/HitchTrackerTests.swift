import Foundation
import Synchronization
import XCTest
import HitchTracker
import HitchTrackerBacktraceC

/// Tests run on the main thread, so blocking a test blocks the main run loop, and waiting on an
/// expectation spins it.
@MainActor
final class HitchTrackerTests: XCTestCase {
    func testInitStoresConfiguration() {
        let tracker = HitchTracker(minDuration: 1000, interval: 5000)
        XCTAssertEqual(tracker.minDuration, 1000)
        XCTAssertEqual(tracker.interval, 5000)
    }

    func testDetectsHitchWithStacktrace() throws {
        let reports = Reports()
        let reported = expectation(description: "hitches reported")
        start(minDuration: 100, interval: 200, stacktraceProvider: framePointerStacktrace) { hitches in
            reports.append(hitches)
            reported.fulfill()
        }

        blockMainThread(milliseconds: 300)
        wait(for: [reported], timeout: 5)

        let hitches = reports.all
        XCTAssertEqual(hitches.count, 1)
        let hitch = try XCTUnwrap(hitches.first)
        XCTAssertGreaterThanOrEqual(hitch.duration, 300)
        XCTAssertLessThan(abs(hitch.startDate.timeIntervalSinceNow), 5)

        let symbols = try XCTUnwrap(hitch.stacktrace).frames.compactMap(symbolName)
        XCTAssertTrue(
            symbols.contains { $0.contains("blockMainThread") },
            "Expected blockMainThread in stack: \(symbols)"
        )
    }

    func testHasNoStacktraceWithoutProvider() throws {
        let reports = Reports()
        let reported = expectation(description: "hitches reported")
        start(minDuration: 100, interval: 200) { hitches in
            reports.append(hitches)
            reported.fulfill()
        }

        blockMainThread(milliseconds: 200)
        wait(for: [reported], timeout: 5)

        XCTAssertEqual(reports.all.count, 1)
        XCTAssertNil(try XCTUnwrap(reports.all.first).stacktrace)
    }

    func testUsesInjectedStacktraceProvider() throws {
        let reports = Reports()
        let reported = expectation(description: "hitches reported")
        let captures = Captures()
        start(minDuration: 100, interval: 200, stacktraceProvider: captures.provider(writing: [1, 2, 3])) { hitches in
            reports.append(hitches)
            reported.fulfill()
        }

        blockMainThread(milliseconds: 300)
        wait(for: [reported], timeout: 5)

        XCTAssertEqual(try XCTUnwrap(reports.all.first).stacktrace?.frames, [1, 2, 3])
        let mainThread = pthread_mach_thread_np(pthread_self())
        XCTAssertEqual(captures.count, 1)
        XCTAssertEqual(
            captures.last,
            Capture(onMainThread: false, thread: mainThread, threadSuspended: true),
            "Expected a capture of the suspended main thread, from another thread"
        )
    }

    func testReportsOnlyBlocksInGivenModes() throws {
        let testMode = RunLoop.Mode("HitchTrackerTestMode")
        let reports = Reports()
        let reported = expectation(description: "hitches reported")
        let captures = Captures()
        start(
            minDuration: 100,
            interval: 200,
            modes: [testMode],
            stacktraceProvider: captures.provider(writing: [1])
        ) { hitches in
            reports.append(hitches)
            reported.fulfill()
        }

        blockMainThread(milliseconds: 200)
        RunLoop.main.perform(inModes: [testMode]) {
            Thread.sleep(forTimeInterval: 0.3)
        }
        RunLoop.current.run(mode: testMode, before: Date(timeIntervalSinceNow: 1))
        wait(for: [reported], timeout: 5)

        XCTAssertEqual(reports.all.count, 1)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(reports.all.first).duration, 300)
        XCTAssertEqual(captures.count, 1, "Expected a stack only for the block in the reported mode")
    }

    func testIgnoresBlocksShorterThanMinDuration() {
        let reports = Reports()
        start(minDuration: 300, interval: 100) { reports.append($0) }

        blockMainThread(milliseconds: 100)
        spinRunLoop(seconds: 0.6)

        XCTAssertTrue(reports.batches.isEmpty)
    }

    func testBatchesHitchesWithinInterval() {
        let reports = Reports()
        let reported = expectation(description: "hitches reported")
        start(minDuration: 100, interval: 500) { hitches in
            reports.append(hitches)
            reported.fulfill()
        }

        blockMainThread(milliseconds: 200)
        spinRunLoop(seconds: 0.1)
        blockMainThread(milliseconds: 200)
        wait(for: [reported], timeout: 5)
        spinRunLoop(seconds: 0.7)

        XCTAssertEqual(reports.batches.map(\.count), [2])
    }

    func testReportsSeparateBatchesAfterInterval() {
        let reports = Reports()
        let reported = expectation(description: "hitches reported")
        reported.expectedFulfillmentCount = 2
        start(minDuration: 100, interval: 200) { hitches in
            reports.append(hitches)
            reported.fulfill()
        }

        blockMainThread(milliseconds: 150)
        spinRunLoop(seconds: 0.5)
        blockMainThread(milliseconds: 150)
        wait(for: [reported], timeout: 5)

        XCTAssertEqual(reports.batches.map(\.count), [1, 1])
    }

    func testStopPreventsReports() {
        let reports = Reports()
        let tracker = start(minDuration: 100, interval: 100) { reports.append($0) }

        blockMainThread(milliseconds: 200)
        tracker.stop()
        spinRunLoop(seconds: 0.5)

        XCTAssertTrue(reports.batches.isEmpty)
    }

    @discardableResult
    private func start(
        minDuration: Int,
        interval: Int,
        modes: [RunLoop.Mode] = [.common],
        stacktraceProvider: StacktraceProvider? = nil,
        callback: @escaping @Sendable ([Hitch]) -> Void
    ) -> HitchTracker {
        let tracker = HitchTracker(
            minDuration: minDuration,
            interval: interval,
            modes: modes,
            stacktraceProvider: stacktraceProvider
        )
        tracker.start(callback)
        addTeardownBlock { tracker.stop() }
        // Let the run loop reach a known state before the test blocks it.
        spinRunLoop(seconds: 0.05)
        return tracker
    }
}

@MainActor
@inline(never)
func blockMainThread(milliseconds: Int) {
    Thread.sleep(forTimeInterval: Double(milliseconds) / 1000)
}

@MainActor
private func spinRunLoop(seconds: TimeInterval) {
    RunLoop.current.run(until: Date(timeIntervalSinceNow: seconds))
}

private func symbolName(_ address: UInt) -> String? {
    var info = Dl_info()
    guard let pointer = UnsafeRawPointer(bitPattern: address),
          dladdr(pointer, &info) != 0,
          let name = info.dli_sname
    else { return nil }
    return String(cString: name)
}

private final class Reports: Sendable {
    private let storage = Mutex<[[Hitch]]>([])

    func append(_ hitches: [Hitch]) {
        storage.withLock { $0.append(hitches) }
    }

    var batches: [[Hitch]] { storage.withLock { $0 } }

    var all: [Hitch] { batches.flatMap { $0 } }
}

private let framePointerStacktrace: StacktraceProvider = { thread, frames in
    ht_backtrace_thread(thread, frames.baseAddress!, frames.count)
}

private struct Capture: Equatable {
    let onMainThread: Bool
    let thread: thread_t
    let threadSuspended: Bool
}

/// Records without allocating, since the provider runs while the main thread is suspended.
private final class Captures: Sendable {
    private let storage = Mutex<(count: Int, last: Capture?)>((0, nil))

    func provider(writing frames: [UInt]) -> StacktraceProvider {
        { thread, buffer in
            let capture = Capture(
                onMainThread: Thread.isMainThread,
                thread: thread,
                threadSuspended: suspendCount(of: thread) > 0
            )
            self.storage.withLock { $0 = ($0.count + 1, capture) }
            return buffer.initialize(fromContentsOf: frames)
        }
    }

    var count: Int { storage.withLock { $0.count } }
    var last: Capture? { storage.withLock { $0.last } }
}

private func suspendCount(of thread: thread_t) -> Int32 {
    var info = thread_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            thread_info(thread, thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? info.suspend_count : -1
}
