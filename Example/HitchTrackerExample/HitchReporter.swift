import Foundation
import HitchTracker
import Sentry

enum HitchReporter {
    static func report(_ hitches: [Hitch]) {
        for hitch in hitches {
            SentrySDK.capture(event: makeEvent(for: hitch))
        }
    }

    private static func makeEvent(for hitch: Hitch) -> Event {
        let event = Event(level: .error)
        event.timestamp = hitch.startDate
        let title = title(for: hitch)

        // Sentry titles the issue with the type and shows the value as the event's description.
        let exception = Exception(value: "Main thread blocked for \(hitch.duration) ms", type: title)
        let mechanism = Mechanism(type: "hitch")
        mechanism.handled = true
        exception.mechanism = mechanism

        if let stacktrace = hitch.stacktrace {
            // Sentry expects the outermost frame first.
            let sentryStacktrace = SentryStacktrace(frames: stacktrace.frames.reversed().map(makeFrame), registers: [:])
            exception.stacktrace = sentryStacktrace
            exception.threadId = 0

            // The SDK only attaches debug images for frames on the event's threads.
            let thread = SentryThread(threadId: 0)
            thread.name = "main"
            thread.isMain = true
            thread.stacktrace = sentryStacktrace
            event.threads = [thread]

            // Sentry groups by stack alone, so add the size to keep each issue's title stable.
            event.fingerprint = ["{{ default }}", title]
        } else {
            // Without a stack the default grouping uses the value, which would split by duration.
            event.fingerprint = [title]
        }

        event.exceptions = [exception]
        return event
    }

    private static func title(for hitch: Hitch) -> String {
        switch hitch.duration {
        case ..<200: "Small Hitch"
        case ...600: "Medium Hitch"
        default: "Long Hitch"
        }
    }

    /// The SDK only attaches debug images for frames with an `imageAddress`, and Sentry can't
    /// symbolicate a frame without its image.
    private static func makeFrame(_ address: UInt) -> Frame {
        let frame = Frame()
        frame.instructionAddress = hex(address)
        var info = Dl_info()
        if let pointer = UnsafeRawPointer(bitPattern: address), dladdr(pointer, &info) != 0 {
            frame.imageAddress = hex(UInt(bitPattern: info.dli_fbase))
            frame.package = info.dli_fname.map { String(cString: $0) }
        }
        return frame
    }

    private static func hex(_ address: UInt) -> String {
        String(format: "0x%016lx", address)
    }
}
