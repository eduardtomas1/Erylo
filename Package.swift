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
        .library(name: "EryloAppIntents", targets: ["EryloAppIntents"]),
        .library(name: "EryloCore", targets: ["EryloCore"]),
        .library(name: "EryloFileHold", targets: ["EryloFileHold"]),
        .library(name: "EryloGlance", targets: ["EryloGlance"]),
        .library(name: "EryloIntegrations", targets: ["EryloIntegrations"]),
        .library(name: "EryloSettingsUI", targets: ["EryloSettingsUI"]),
        .library(name: "EryloLocalIntegrations", targets: ["EryloLocalIntegrations"]),
        .library(name: "EryloSurface", targets: ["EryloSurface"]),
        .library(name: "EryloTrust", targets: ["EryloTrust"]),
        .library(name: "EryloWindowing", targets: ["EryloWindowing"]),
        .executable(name: "EryloActivityTests", targets: ["EryloActivityTests"]),
        .executable(name: "EryloFileHoldTests", targets: ["EryloFileHoldTests"]),
        .executable(name: "EryloFoundationTests", targets: ["EryloFoundationTests"]),
        .executable(name: "EryloGlanceTests", targets: ["EryloGlanceTests"]),
        .executable(name: "EryloMediaTests", targets: ["EryloMediaTests"]),
        .executable(name: "EryloTrustTests", targets: ["EryloTrustTests"]),
        .executable(name: "EryloIntegrationTests", targets: ["EryloIntegrationTests"]),
    ],
    targets: [
        .target(name: "EryloActivity"),
        .target(
            name: "EryloAppIntents",
            dependencies: ["EryloLocalIntegrations"]
        ),
        .target(name: "EryloCore"),
        .target(name: "EryloFileHold"),
        .target(
            name: "EryloGlance",
            dependencies: ["EryloActivity"]
        ),
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
            name: "EryloTrust",
            dependencies: ["EryloCore"]
        ),
        .target(
            name: "EryloSettingsUI",
            dependencies: [
                "EryloCore",
                "EryloTrust",
            ]
        ),
        .target(
            name: "EryloLocalIntegrations",
            dependencies: ["EryloActivity"]
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
                "EryloSurface",
                "EryloWindowing",
            ],
            path: "Tests/FoundationHarness"
        ),
        .executableTarget(
            name: "EryloFileHoldTests",
            dependencies: ["EryloFileHold"],
            path: "Tests/FileHoldHarness"
        ),
        .executableTarget(
            name: "EryloGlanceTests",
            dependencies: [
                "EryloActivity",
                "EryloGlance",
            ],
            path: "Tests/GlanceHarness"
        ),
        .executableTarget(
            name: "EryloMediaTests",
            dependencies: [
                "EryloCore",
                "EryloIntegrations",
            ],
            path: "Tests/MediaHarness"
        ),
        .executableTarget(
            name: "EryloTrustTests",
            dependencies: [
                "EryloCore",
                "EryloSettingsUI",
                "EryloTrust",
            ],
            path: "Tests/TrustHarness"
        ),
        .executableTarget(
            name: "EryloIntegrationTests",
            dependencies: [
                "EryloActivity",
                "EryloLocalIntegrations",
            ],
            path: "Tests/IntegrationHarness"
        ),
    ],
    swiftLanguageModes: [.v6]
)
