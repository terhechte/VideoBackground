// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "VideoBackground",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "VideoBackground",
            targets: ["VideoBackground"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/VincentGourbin/RMBG2Swift", branch: "main")
    ],
    targets: [
        .executableTarget(
            name: "VideoBackground",
            dependencies: [
                .product(name: "RMBG2Swift", package: "RMBG2Swift")
            ]
        ),
    ]
)
