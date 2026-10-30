// swift-tools-version:5.9
import PackageDescription

// LorisListKit holds everything that is not UI: the API client, models, token
// storage and list logic. It builds and tests on macOS and Linux, so
// `swift test` works without Xcode or a simulator. The app target in
// project.yml (XcodeGen) depends on it.
let package = Package(
    name: "LorisListKit",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [
        .library(name: "LorisListKit", targets: ["LorisListKit"])
    ],
    targets: [
        .target(
            name: "LorisListKit",
            path: "Sources/LorisListKit"
        ),
        .testTarget(
            name: "LorisListKitTests",
            dependencies: ["LorisListKit"],
            path: "Tests/LorisListKitTests",
            resources: [.copy("Fixtures")]
        )
    ]
)
