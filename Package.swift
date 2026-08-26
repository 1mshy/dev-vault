// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SecretsVault",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "SecretsVault",
            path: "Sources/SecretsVault"
        )
    ]
)
