// swift-tools-version: 6.0
import PackageDescription

// Postwright, the mail engine under Corres: IMAP, SMTP and MIME for iCloud
// Mail and any other IMAP account.
// Kept as its own package so it builds and tests on the Mac in seconds,
// without the app. Pinned to swift-nio-imap 0.4.x, the last release that
// still supports iOS 17 (later ones need iOS 18).
let package = Package(
    name: "Postwright",
    platforms: [.iOS(.v17), .macOS(.v14), .macCatalyst(.v17)],
    products: [.library(name: "Postwright", targets: ["Postwright"])],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio-imap", .upToNextMinor(from: "0.4.0")),
        .package(url: "https://github.com/apple/swift-nio", from: "2.64.0"),
        .package(url: "https://github.com/apple/swift-nio-transport-services", from: "1.20.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl", from: "2.27.0"),
    ],
    targets: [
        .target(
            name: "Postwright",
            dependencies: [
                .product(name: "NIOIMAP", package: "swift-nio-imap"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOTransportServices", package: "swift-nio-transport-services"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
            ]
        ),
        .testTarget(
            name: "PostwrightTests",
            dependencies: [
                "Postwright",
                .product(name: "NIOIMAP", package: "swift-nio-imap"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ],
            resources: [.copy("Transcripts")]
        ),
    ]
)
