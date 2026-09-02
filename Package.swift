// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SecretsVault",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/jedisct1/swift-sodium.git", branch: "master")
    ],
    targets: [
        // UI-free core: crypto and vault file format, document model and its
        // folder/delete/restore operations, markdown block parser, version and
        // naming helpers. Everything here is unit-tested.
        .target(
            name: "SecretsVaultCore",
            dependencies: [
                .product(name: "Sodium", package: "swift-sodium")
            ],
            path: "Sources/SecretsVaultCore"
        ),
        // The macOS app: SwiftUI views, VaultStore, Keychain/Touch ID,
        // clipboard hygiene and the in-app updater.
        .executableTarget(
            name: "SecretsVault",
            dependencies: ["SecretsVaultCore"],
            path: "Sources/SecretsVault"
        ),
        .testTarget(
            name: "SecretsVaultCoreTests",
            dependencies: ["SecretsVaultCore"],
            path: "Tests/SecretsVaultCoreTests"
        )
    ]
)
