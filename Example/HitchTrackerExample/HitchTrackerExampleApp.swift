import HitchTracker
import HitchTrackerBacktraceC
import os
import Sentry
import SwiftUI

private let logger = Logger(subsystem: "io.sentry.HitchTrackerExample", category: "hitches")

@main
struct HitchTrackerExampleApp: App {
    private let hitchTracker = HitchTracker(
        minDuration: 50,
        interval: 5000,
        modes: [.tracking],
        stacktraceProvider: { mainThread, frames in
            ht_backtrace_thread(mainThread, frames.baseAddress!, frames.count)
        }
    )

    init() {
        SentrySDK.start { options in
            options.dsn = "https://0f2446036849f61739185da4cb288a67@o4509351260061696.ingest.us.sentry.io/4510326176874496"
            // The SDK's own hang tracking would report the same blocks.
            options.enableAppHangTracking = false
        }

        hitchTracker.start { hitches in
            HitchReporter.report(hitches)
            logger.notice("Detected \(hitches.count) hitch(es)")
            for hitch in hitches {
                logger.notice("Hitch at \(hitch.startDate) lasting \(hitch.duration) ms")
                for (index, address) in (hitch.stacktrace?.frames ?? []).prefix(15).enumerated() {
                    logger.notice("  \(index) \(symbolicate(address))")
                }
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

/// Best effort: only finds symbols the dynamic linker can see.
private func symbolicate(_ address: UInt) -> String {
    let hex = "0x" + String(address, radix: 16)
    var info = Dl_info()
    guard let pointer = UnsafeRawPointer(bitPattern: address), dladdr(pointer, &info) != 0 else {
        return hex
    }
    let image = info.dli_fname.map { URL(fileURLWithPath: String(cString: $0)).lastPathComponent } ?? "?"
    let symbol = info.dli_sname.map { String(cString: $0) } ?? "?"
    return "\(hex) \(image) \(symbol)"
}
