// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "ForsettiFramework",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "ForsettiCore", targets: ["ForsettiCore"]),
        .library(name: "ForsettiPlatform", targets: ["ForsettiPlatform"]),
        .library(name: "ForsettiHostTemplate", targets: ["ForsettiHostTemplate"])
    ],
    targets: [
        .target(
            name: "ForsettiCore",
            dependencies: []
        ),
        .target(
            name: "ForsettiPlatform",
            dependencies: ["ForsettiCore"]
        ),
        .target(
            name: "ForsettiModulesExample",
            dependencies: ["ForsettiCore"],
            resources: [
                .process("Resources")
            ]
        ),
        .target(
            name: "ForsettiHostTemplate",
            dependencies: ["ForsettiCore", "ForsettiPlatform"]
        ),
        .testTarget(
            name: "ForsettiCoreTests",
            dependencies: ["ForsettiCore", "ForsettiModulesExample"]
        ),
        .testTarget(
            name: "ForsettiPlatformTests",
            dependencies: ["ForsettiCore", "ForsettiPlatform"]
        ),
        .testTarget(
            name: "ForsettiHostTemplateTests",
            dependencies: ["ForsettiCore", "ForsettiPlatform", "ForsettiModulesExample", "ForsettiHostTemplate"]
        ),
        .testTarget(
            name: "ForsettiArchitectureTests",
            dependencies: []
        )
    ]
)
