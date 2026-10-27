// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "HitchTracker",
    platforms: [
        .iOS(.v26),
        .macOS(.v26),
    ],
    products: [
        .library(name: "HitchTracker", targets: ["HitchTracker"]),
        .library(name: "HitchTrackerBacktraceC", targets: ["HitchTrackerBacktraceC"]),
    ],
    targets: [
        .target(name: "HitchTracker"),
        .target(name: "HitchTrackerBacktraceC"),
        .testTarget(name: "HitchTrackerTests", dependencies: ["HitchTracker", "HitchTrackerBacktraceC"]),
    ]
)
