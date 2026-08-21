// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "NodalongKit",
    platforms: [
        .iOS(.v16)
    ],
    products: [
        .library(name: "NodalongKit", targets: ["NodalongKit"])
    ],
    targets: [
        .target(
            name: "NodalongKit",
            path: "Sources/NodalongKit"
        ),
        .testTarget(
            name: "NodalongKitTests",
            dependencies: ["NodalongKit"],
            path: "Tests/NodalongKitTests"
        )
    ]
)
