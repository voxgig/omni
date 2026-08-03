// swift-tools-version:5.9
import PackageDescription

let package = Package(
  name: "VoxgigOmni",
  products: [
    .library(name: "Omni", targets: ["Omni"]),
    .executable(name: "omnitest", targets: ["OmniTest"]),
  ],
  targets: [
    .target(name: "Omni", path: "Sources/Omni"),
    .executableTarget(name: "OmniTest", dependencies: ["Omni"], path: "Sources/OmniTest"),
  ]
)
