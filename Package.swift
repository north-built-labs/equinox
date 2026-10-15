// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Equinox",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "Equinox", targets: ["Equinox"])],
    targets: [
        .target(name: "EquinoxDSP"),
        .target(name: "EquinoxAudio", dependencies: ["EquinoxDSP"]),
        .target(name: "EquinoxCore", dependencies: ["EquinoxDSP", "EquinoxAudio"]),
        .executableTarget(name: "Equinox", dependencies: ["EquinoxCore", "EquinoxDSP", "EquinoxAudio"]),
        .testTarget(name: "EquinoxDSPTests", dependencies: ["EquinoxDSP"]),
        .testTarget(name: "EquinoxAudioTests", dependencies: ["EquinoxAudio"]),
        .testTarget(name: "EquinoxCoreTests", dependencies: ["EquinoxCore", "EquinoxDSP", "EquinoxAudio"]),
    ],
    swiftLanguageModes: [.v5]
)
