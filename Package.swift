// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "Deltavee",
  platforms: [.macOS(.v26)],
  products: [
    .library(name: "DeltaveeCore", targets: ["DeltaveeCore"]),
    .executable(name: "Deltavee", targets: ["Deltavee"]),
    .executable(name: "deltavee-probe", targets: ["deltavee-probe"]),
  ],
  targets: [
    .target(name: "DeltaveeCore"),
    .executableTarget(
      name: "Deltavee", dependencies: ["DeltaveeCore"], resources: [.copy("Resources")]),
    .executableTarget(name: "deltavee-probe", dependencies: ["DeltaveeCore"]),
    .testTarget(
      name: "DeltaveeCoreTests", dependencies: ["DeltaveeCore"], resources: [.copy("Fixtures")]),
    .testTarget(name: "DeltaveeTests", dependencies: ["Deltavee"]),
  ]
)
