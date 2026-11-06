// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "dirconproxy",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "dirconproxy", targets: ["dirconproxy"]),
        .library(name: "DirConCore", targets: ["DirConCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
    ],
    targets: [
        .target(name: "DirConCore"),
        .executableTarget(
            name: "dirconproxy",
            dependencies: [
                "DirConCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            linkerSettings: [.unsafeFlags([
                "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT",
                "-Xlinker", "__info_plist", "-Xlinker", "Info.plist",
            ])]
        ),
        .testTarget(name: "DirConCoreTests", dependencies: ["DirConCore"]),
    ]
)
