// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TossCore",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [.library(name: "TossCore", targets: ["TossCore"])],
    targets: [
        .target(name: "TossCore", linkerSettings: [.linkedFramework("MultipeerConnectivity"), .linkedFramework("CloudKit"), .linkedFramework("Security")]),
        .testTarget(name: "TossCoreTests", dependencies: ["TossCore"])
    ],
    swiftLanguageModes: [.v5]
)
