// swift-tools-version: 6.2
import PackageDescription

// TranscriptCore holds all app logic that does not need Apple-only frameworks:
// the data model, formatting/export, storage, the recording coordinator and the
// engine protocol. It builds and tests on Linux as well as macOS/iOS, so it can be
// verified without Xcode.
let package = Package(
    name: "TranscriptCore",
    platforms: [.iOS("26.0"), .macOS("15.0")],
    products: [
        .library(name: "TranscriptCore", targets: ["TranscriptCore"]),
    ],
    targets: [
        .target(name: "TranscriptCore"),
        .testTarget(name: "TranscriptCoreTests", dependencies: ["TranscriptCore"]),
    ]
)
