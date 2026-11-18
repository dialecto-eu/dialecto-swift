// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DialectoLive",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "DialectoLive", targets: ["DialectoLive"]),
        // Live editing for debug builds: every source is inside `#if DEBUG`, so a release build carries none of it.
        .library(name: "DialectoLiveEditing", targets: ["DialectoLiveEditing"]),
    ],
    targets: [
        .target(name: "DialectoLive"),
        .target(name: "DialectoLiveEditing", dependencies: ["DialectoLive"]),
        // Builds and signs releases with the test-only key, for the tests. Not a product, so a package that
        // depends on this one never compiles it. The demos in Demo/ share these sources.
        .target(name: "DialectoLiveFixtures", path: "Tests/DialectoLiveFixtures"),
        .testTarget(
            name: "DialectoLiveTests",
            dependencies: ["DialectoLive", "DialectoLiveFixtures"]
        ),
        .testTarget(
            name: "DialectoLiveEditingTests",
            dependencies: ["DialectoLive", "DialectoLiveEditing"]
        ),
    ]
)
