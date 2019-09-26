// swift-tools-version:5.0.0
import PackageDescription

let package = Package(
    name: "swift-basic-http",
    products: [
        .library(name: "SwiftBasicHTTP", targets: ["SwiftBasicHTTP"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio-ssl.git", .upToNextMinor(from: "1.4.0")),
        .package(url: "https://github.com/apple/swift-nio.git", from: "1.12.0")
    ],
    targets: [
        .target(
            name: "SwiftBasicHTTP",
            dependencies: [
                "NIOOpenSSL",
                "NIOHTTP1",
                "NIOFoundationCompat"
            ]
        ),
        .testTarget(
            name: "SwiftBasicHTTPTests",
            dependencies: [
                "SwiftBasicHTTP"
            ]
        )
    ]
)
