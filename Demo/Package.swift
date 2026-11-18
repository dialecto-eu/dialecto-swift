// swift-tools-version: 6.0
import PackageDescription

// The demos live in their own package so that a package depending on DialectoLive never builds them.
// Run from this folder: `swift run dialecto-live-demo`.
let package = Package(
    name: "DialectoLiveDemo",
    platforms: [.macOS(.v14), .iOS(.v17)],
    dependencies: [.package(name: "DialectoLive", path: "..")],
    targets: [
        // Signs releases with the test-only key. A symlink to ../Tests/DialectoLiveFixtures, shared with the tests.
        .target(name: "DialectoLiveFixtures"),
        .executableTarget(
            name: "dialecto-live-demo",
            dependencies: [
                .product(name: "DialectoLive", package: "DialectoLive"),
                .product(name: "DialectoLiveEditing", package: "DialectoLive"),
                "DialectoLiveFixtures",
            ]
        ),
        // A minimal iOS host for live editing, run in the simulator. On a Mac it only prints where it runs.
        .executableTarget(
            name: "dialecto-live-ios-demo",
            dependencies: [
                .product(name: "DialectoLive", package: "DialectoLive"),
                .product(name: "DialectoLiveEditing", package: "DialectoLive"),
            ]
        ),
    ]
)
