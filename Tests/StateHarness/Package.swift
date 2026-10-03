// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "YomiState",
    platforms: [.iOS(.v17)],
    products: [.library(name: "YomiState", targets: ["YomiState"])],
    dependencies: [.package(url: "https://github.com/nmdias/FeedKit", from: "9.1.2")],
    targets: [
        .target(name: "YomiState", dependencies: [.product(name: "FeedKit", package: "FeedKit")]),
        .testTarget(name: "YomiStateTests", dependencies: ["YomiState"])
    ]
)
