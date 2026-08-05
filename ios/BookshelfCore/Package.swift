// swift-tools-version: 6.0
import PackageDescription

// The data model, the normalizer and (later) the sync client live here rather
// than in the app target, for one practical reason: `swift test` runs this on
// macOS with no simulator, no scheme and no Xcode. The rules that must match the
// web app exactly are the ones worth testing on every save, so they belong
// somewhere a test run costs a second.
let package = Package(
    name: "BookshelfCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "BookshelfCore", targets: ["BookshelfCore"]),
    ],
    targets: [
        .target(name: "BookshelfCore"),
        .testTarget(
            name: "BookshelfCoreTests",
            dependencies: ["BookshelfCore"],
            resources: [.copy("Golden")]
        ),
    ]
)
