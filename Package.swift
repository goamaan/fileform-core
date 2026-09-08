// swift-tools-version: 6.0
// SPDX-License-Identifier: Apache-2.0
import PackageDescription

let package = Package(
    name: "FileformCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "FileformDomain", targets: ["FileformDomain"]),
        .library(name: "FileformCore", targets: ["FileformCore"]),
        .executable(name: "fileform", targets: ["FileformCLI"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", exact: "1.8.2")
    ],
    targets: [
        .target(name: "FileformDomain"),
        .target(name: "FileformCore", dependencies: ["FileformDomain"]),
        .executableTarget(name: "FileformCLI", dependencies: [
            "FileformCore", "FileformDomain",
            .product(name: "ArgumentParser", package: "swift-argument-parser")
        ]),
        .testTarget(name: "FileformCoreTests", dependencies: ["FileformCore", "FileformDomain"])
    ]
)
