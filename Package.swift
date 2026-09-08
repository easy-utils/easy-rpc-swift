// swift-tools-version: 5.9
import PackageDescription
import Foundation

let package = Package(
    name: "easy-rpc-swift",
    platforms: [.macOS(.v12), .iOS(.v15)],
    products: [.library(name: "easyRpc", targets: ["easyRpc"])],
    dependencies: [
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.28.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
    ],
    targets: [
        .target(name: "easyRpc", dependencies: [
            .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            .product(name: "NIO", package: "swift-nio"),
            .product(name: "NIOHTTP1", package: "swift-nio"),
        ], path: "Sources/easyRpc"),
        .testTarget(name: "easyRpcTests", dependencies: ["easyRpc"], path: "Tests/easyRpcTests"),
    ]
)
