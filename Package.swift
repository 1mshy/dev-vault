// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SecretsVault",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/jedisct1/swift-sodium.git", branch: "master")
    ],
    targets: [
        .executableTarget(
            name: "SecretsVault",
            dependencies: [
                .product(name: "Sodium", package: "swift-sodium")
            ],
            path: "Sources/SecretsVault"
        )
    ]
)
