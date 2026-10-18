// swift-tools-version: 6.0
import PackageDescription

// Corres's IMAP and SMTP engine: iCloud Mail first, then any IMAP account.
// Kept as its own package so it builds and tests on the Mac in seconds,
// without the app. Pinned to swift-nio-imap 0.4.x, the last release that
// still supports iOS 17 (later ones need iOS 18).
let package = Package(
    name: "MailEngine",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "MailEngine", targets: ["MailEngine"])],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio-imap", .upToNextMinor(from: "0.4.0")),
        .package(url: "https://github.com/apple/swift-nio", from: "2.64.0"),
        .package(url: "https://github.com/apple/swift-nio-transport-services", from: "1.20.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl", from: "2.27.0"),
    ],
    targets: [
        .target(
            name: "MailEngine",
            dependencies: [
                .product(name: "NIOIMAP", package: "swift-nio-imap"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOTransportServices", package: "swift-nio-transport-services"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
            ]
        ),
        .testTarget(
            name: "MailEngineTests",
            dependencies: [
                "MailEngine",
                .product(name: "NIOIMAP", package: "swift-nio-imap"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ],
            resources: [.copy("Transcripts")]
        ),
    ]
)
