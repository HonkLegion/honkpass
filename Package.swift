// swift-tools-version: 6.1
import PackageDescription

// Module rules are in AGENTS.md. Only EngineLive may depend on the Bitwarden SDK.
let package = Package(
    name: "PassVault",
    platforms: [.macOS("26.4")],
    products: [
        .library(name: "VaultModel", targets: ["VaultModel"]),
        .library(name: "Engine", targets: ["Engine"]),
        .library(name: "EngineFakes", targets: ["EngineFakes"]),
        .library(name: "EngineLive", targets: ["EngineLive"]),
        .library(name: "DesignKit", targets: ["DesignKit"]),
        .library(name: "AutoFillBridge", targets: ["AutoFillBridge"]),
        .library(name: "ProviderUI", targets: ["ProviderUI"]),
        .executable(name: "passvault-seed", targets: ["SeedTool"]),
    ],
    dependencies: [
        // Built by `make prepare-sdk`.
        .package(path: ".local-dependencies/BitwardenSdk"),
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.6"),
    ],
    targets: [
        // Resources/ comes from support/generate-public-suffixes.py.
        .target(name: "VaultModel", resources: [.copy("Resources")]),
        .target(name: "Engine", dependencies: ["VaultModel"]),
        .target(name: "EngineFakes", dependencies: ["Engine"]),
        .target(name: "EngineLive", dependencies: ["Engine", .product(name: "BitwardenSdk", package: "BitwardenSdk"), .product(name: "Sparkle", package: "Sparkle")]),
        // Attributed resources come from the generator. Symbols.swift maps native macOS icons.
        .target(name: "DesignKit", resources: [.copy("Resources")]),
        // The connection between the app, the AutoFill extension and the launch agent.
        .target(name: "AutoFillBridge", dependencies: ["VaultModel"]),
        // The model and the screens of the AutoFill extension. The app links them too, for its pictures.
        .target(name: "ProviderUI", dependencies: ["AutoFillBridge", "DesignKit", "VaultModel"]),
        .executableTarget(name: "SeedTool", dependencies: ["EngineLive"]),
        .testTarget(name: "VaultModelTests", dependencies: ["VaultModel"]),
        .testTarget(name: "EngineTests", dependencies: ["Engine", "EngineFakes"]),
        .testTarget(name: "EngineLiveTests", dependencies: ["EngineLive", "EngineFakes"]),
        .testTarget(name: "DesignKitTests", dependencies: ["DesignKit"]),
        .testTarget(name: "AutoFillBridgeTests", dependencies: ["AutoFillBridge"]),
        .testTarget(name: "ProviderUITests", dependencies: ["ProviderUI", "Engine", "EngineFakes"]),
    ],
    swiftLanguageModes: [.v6]
)
