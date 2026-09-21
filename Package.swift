// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CorresCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "CorresCore", targets: ["CorresCore"])],
    targets: [
        .target(name: "CorresCore", path: "Core"),
        .testTarget(name: "CorresCoreTests", dependencies: ["CorresCore"], path: "Tests/Core")
    ]
)
