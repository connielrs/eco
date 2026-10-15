// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Eco",
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.0"),
    ],
    targets: [
        .executableTarget(
            name: "Eco",
            dependencies: [.product(name: "WhisperKit", package: "WhisperKit")],
            path: "Sources/Eco",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
