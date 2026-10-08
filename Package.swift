// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "MDLite",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MDLite", targets: ["MDLite"]),
        .executable(name: "MDLiteQuickLook", targets: ["MDLiteQuickLook"])
    ],
    dependencies: [.package(url: "https://github.com/swiftlang/swift-markdown.git", from: "0.5.0")],
    targets: [
        .executableTarget(name: "MDLite", dependencies: [.product(name: "Markdown", package: "swift-markdown")]),
        // Finder's Quick Look preview. An app extension starts in NSExtensionMain, not in main.swift.
        .executableTarget(
            name: "MDLiteQuickLook",
            dependencies: [.product(name: "Markdown", package: "swift-markdown")],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-e", "-Xlinker", "_NSExtensionMain", "-Xlinker", "-application_extension"])]
        ),
        .testTarget(name: "MDLiteTests", dependencies: ["MDLite"])
    ]
)
