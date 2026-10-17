// swift-tools-version:5.9
//
// HomylonKit: the Homylon network layer for apps, tools and agents.
// MIT licence. See README.md.
//
// The transport is Network.framework on Apple platforms and SwiftNIO on Linux. SwiftNIO is only
// declared where it is used, so Apple apps neither download nor carry it. To test the SwiftNIO
// transport on a Mac:
//
//   HOMYLON_NIO=1 swift test

import PackageDescription
import Foundation

#if os(Linux)
let useNIO = true
#else
let useNIO = ProcessInfo.processInfo.environment["HOMYLON_NIO"] == "1"
#endif

let package = Package(
    name: "HomylonKit",
    platforms: [.iOS(.v12), .macOS("11.7"), .tvOS(.v12)],
    products: [
        .library(name: "HomylonKit", targets: ["HomylonKit"]),
    ],
    // Same range as the Homylon Engine: 2.32.0 is the oldest the transport builds against,
    // 2.86.x the last release for Swift 5.10 (Xcode 15.4).
    dependencies: useNIO
        ? [.package(url: "https://github.com/apple/swift-nio.git", "2.32.0"..<"2.87.0")]
        : [],
    targets: [
        .target(
            name: "HomylonKit",
            dependencies: useNIO
                ? [.product(name: "NIOCore", package: "swift-nio"),
                   .product(name: "NIOPosix", package: "swift-nio")]
                : [],
            swiftSettings: useNIO ? [.define("HOMYLON_NIO")] : []
        ),
        .testTarget(name: "HomylonKitTests", dependencies: ["HomylonKit"]),
    ]
)
