// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Erylo",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "Erylo", targets: ["EryloApp"]),
        .library(name: "EryloActivity", targets: ["EryloActivity"]),
        .library(name: "EryloCore", targets: ["EryloCore"]),
        .library(name: "EryloIntegrations", targets: ["EryloIntegrations"]),
        .library(name: "EryloSurface", targets: ["EryloSurface"]),
        .library(name: "EryloWindowing", targets: ["EryloWindowing"]),
        .executable(name: "EryloActivityTests", targets: ["EryloActivityTests"]),
        .executable(name: "EryloFoundationTests", targets: ["EryloFoundationTests"]),
    ],
    targets: [
        .target(name: "EryloActivity"),
        .target(name: "EryloCore"),
        .target(
            name: "EryloIntegrations",
            dependencies: [
                "EryloActivity",
                "EryloCore",
            ]
        ),
        .target(
            name: "EryloSurface",
            dependencies: ["EryloCore"]
        ),
        .target(
            name: "EryloWindowing",
            dependencies: [
                "EryloCore",
                "EryloIntegrations",
                "EryloSurface",
            ]
        ),
        .executableTarget(
            name: "EryloApp",
            dependencies: ["EryloWindowing"]
        ),
        .executableTarget(
            name: "EryloActivityTests",
            dependencies: ["EryloActivity"],
            path: "Tests/ActivityHarness"
        ),
        .executableTarget(
            name: "EryloFoundationTests",
            dependencies: [
                "EryloCore",
                "EryloIntegrations",
            ],
            path: "Tests/FoundationHarness"
        ),
    ],
    swiftLanguageModes: [.v6]
)
