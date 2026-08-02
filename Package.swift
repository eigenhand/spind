// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Spind",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "SpindCore", targets: ["SpindCore"]),
        .executable(name: "spind", targets: ["spind"]),
        .executable(name: "SpindApp", targets: ["SpindApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/orlandos-nl/Citadel.git", from: "0.7.0"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.29.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
    ],
    targets: [
        .target(
            name: "SpindCore",
            dependencies: [
                .product(name: "Citadel", package: "Citadel"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .executableTarget(
            name: "spind",
            dependencies: [
                "SpindCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .executableTarget(
            name: "SpindApp",
            dependencies: ["SpindCore"]
        ),
        .testTarget(
            name: "SpindCoreTests",
            dependencies: ["SpindCore"]
        ),
    ]
)
