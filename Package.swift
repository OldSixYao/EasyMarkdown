// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "EasyMarkdown",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "EasyMarkdown", targets: ["EasyMarkdown"])],
    targets: [
        .target(name: "EasyMarkdownCore"),
        .executableTarget(name: "EasyMarkdown", dependencies: ["EasyMarkdownCore"],
                          resources: [.copy("Resources")]),
        .testTarget(name: "EasyMarkdownCoreTests", dependencies: ["EasyMarkdownCore"])
    ]
)
