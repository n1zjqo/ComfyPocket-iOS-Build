// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ComfyCore",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [.library(name: "ComfyCore", targets: ["ComfyCore"])],
    targets: [
        .target(name: "ComfyCore"),
        .testTarget(name: "ComfyCoreTests", dependencies: ["ComfyCore"], resources: [.process("Fixtures")])
    ]
)
