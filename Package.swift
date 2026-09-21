// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "MDLite",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "MDLite", targets: ["MDLite"])],
    dependencies: [.package(url: "https://github.com/swiftlang/swift-markdown.git", from: "0.5.0")],
    targets: [
        .executableTarget(name: "MDLite", dependencies: [.product(name: "Markdown", package: "swift-markdown")]),
        .testTarget(name: "MDLiteTests", dependencies: ["MDLite"])
    ]
)
