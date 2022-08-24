// swift-tools-version: 5.7

import PackageDescription

var globalSwiftSettings: [SwiftSetting] = []
var targets: [Target] = [
    .target(
        name: "LocalNetworkActorSystem",
        dependencies: [
                    .product(name: "NIO", package: "swift-nio"),
                    .product(name: "NIOHTTP1", package: "swift-nio"),
                    .product(name: "NIOWebSocket", package: "swift-nio"),
                    .product(name: "NIOTransportServices", package: "swift-nio-transport-services")
        ]),
    .testTarget(
        name: "LocalNetworkActorSystemTests",
        dependencies: ["LocalNetworkActorSystem"])
    ]

let package = Package(
    name: "LocalNetworkActorSystem",
    platforms: [
        .macOS(.v13),
        .iOS(.v16)
    ],
    products: [
        // Products define the executables and libraries a package produces, and make them visible to other packages.
        .library(
            name: "LocalNetworkActorSystem",
            targets: ["LocalNetworkActorSystem"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.12.0"),
        .package(url: "https://github.com/apple/swift-nio-transport-services.git", from: "1.0.0")
    ],
    targets: targets.map { target in
        var swiftSettings = target.swiftSettings ?? []
        if target.type != .plugin {
            swiftSettings.append(contentsOf: globalSwiftSettings)
        }
        if !swiftSettings.isEmpty {
            target.swiftSettings = swiftSettings
        }
        return target
    }
)



