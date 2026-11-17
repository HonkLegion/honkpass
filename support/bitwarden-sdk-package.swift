// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "BitwardenSdk",
    platforms: [.macOS("26.4")],
    products: [.library(name: "BitwardenSdk", targets: ["BitwardenSdk"])],
    targets: [
        .binaryTarget(name: "BitwardenFFI", path: "BitwardenFFI.xcframework"),
        .target(name: "BitwardenSdkSupport"),
        .target(name: "BitwardenSdk", dependencies: ["BitwardenFFI", "BitwardenSdkSupport"],
                swiftSettings: [.swiftLanguageMode(.v5), .unsafeFlags(["-suppress-warnings"])],
                linkerSettings: [.linkedFramework("Security"), .linkedFramework("SystemConfiguration"), .linkedLibrary("resolv"), .linkedLibrary("c++")])
    ]
)
