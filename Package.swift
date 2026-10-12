// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "VolBoost",
    platforms: [.macOS("14.2")],
    targets: [
        // Realtime-safe EQ + limiter. No Core Audio, so it can be checked offline.
        .target(name: "VolBoostDSP"),
        .executableTarget(name: "VolBoost", dependencies: ["VolBoostDSP"]),
        // `swift run -c release DSPCheck` — signal-level checks of the DSP.
        // A plain executable rather than a test target so it also runs with
        // only the Command Line Tools (no XCTest / Swift Testing there).
        .executableTarget(name: "DSPCheck", dependencies: ["VolBoostDSP"]),
    ]
)
