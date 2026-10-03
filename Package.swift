// swift-tools-version: 5.9
import PackageDescription

// Test the app's actual parser and model sources without requiring an iOS simulator.
let package = Package(
    name: "YomiParsing",
    platforms: [.macOS(.v14)],
    dependencies: [.package(url: "https://github.com/nmdias/FeedKit", from: "9.1.2")],
    targets: [
        .target(
            name: "YomiParsing",
            dependencies: [.product(name: "FeedKit", package: "FeedKit")],
            path: "Yomi",
            exclude: ["Assets.xcassets", "AppIcon.icon", "BackgroundRefresh", "Views",
                      "ContentView.swift", "YomiApp.swift", "Info.plist", "PrivacyInfo.xcprivacy",
                      "Yomi.entitlements", "Services/FeedDiscoveryService.swift",
                      "Services/FeedService.swift", "Services/OGImageFetcher.swift"],
            sources: ["Models", "Services/RSSFetcher.swift", "Services/OPMLManager.swift"]
        ),
        .testTarget(name: "YomiParsingTests", dependencies: ["YomiParsing", "FeedKit"])
    ]
)
