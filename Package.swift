// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BulkGitHub",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "BulkGitHubKit", targets: ["BulkGitHubKit"]),
        .executable(name: "BulkGitHub", targets: ["BulkGitHub"]),
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.0"),
        .package(url: "https://github.com/ZeeZide/CodeEditor.git", from: "1.2.0"),
    ],
    targets: [
        .target(
            name: "BulkGitHubKit",
            dependencies: ["Yams"],
            resources: [.copy("Resources")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "BulkGitHub",
            dependencies: [
                "BulkGitHubKit",
                .product(name: "CodeEditor", package: "CodeEditor"),
            ],
            exclude: ["Assets.xcassets"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "BulkGitHubKitTests",
            dependencies: ["BulkGitHubKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
