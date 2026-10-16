// swift-tools-version:6.0
import PackageDescription

let package = Package(
  name: "EdgeCompanion",
  platforms: [.macOS(.v14)],
  products: [
    .executable(name: "EdgeCompanion", targets: ["EdgeCompanion"]),
  ],
  dependencies: [
    .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.2.0"),
  ],
  targets: [
    // Pure logic with no AppKit/IOKit side effects, so it can be unit tested.
    .target(
      name: "EdgeCore",
      swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    .executableTarget(
      name: "EdgeCompanion",
      dependencies: [
        "EdgeCore",
        .product(name: "SwiftTerm", package: "SwiftTerm"),
      ],
      swiftSettings: [.swiftLanguageMode(.v5)],
      linkerSettings: [
        .linkedFramework("IOKit"),
        .linkedFramework("CoreGraphics"),
        .linkedFramework("AppKit"),
        .linkedFramework("ApplicationServices"),
        .linkedFramework("ServiceManagement"),
      ]
    ),
    .testTarget(
      name: "EdgeCoreTests",
      dependencies: ["EdgeCore"],
      swiftSettings: [.swiftLanguageMode(.v5)]
    ),
  ]
)
