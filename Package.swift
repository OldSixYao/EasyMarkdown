// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "EasyMarkdown",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "EasyMarkdown", targets: ["EasyMarkdown"])],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1")
    ],
    targets: [
        .target(name: "EasyMarkdownCore"),
        .executableTarget(name: "EasyMarkdown", dependencies: [
            "EasyMarkdownCore", .product(name: "Sparkle", package: "Sparkle")
        ], resources: [.copy("Resources")], linkerSettings: [
            .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
        ]),
        .testTarget(name: "EasyMarkdownCoreTests", dependencies: ["EasyMarkdownCore"])
    ]
)
