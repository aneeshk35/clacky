// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Clacky",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Clacky", targets: ["Clacky"]),
        .executable(name: "clacky-check", targets: ["ClackyCheck"]),
    ],
    targets: [
        // Catches the Objective-C exceptions AVFoundation raises for audio device problems.
        .target(name: "ClackyObjC"),
        // Key capture, sound synthesis and playback — everything except the UI.
        .target(name: "ClackyCore", dependencies: ["ClackyObjC"]),
        // The app (window + Dock icon).
        .executableTarget(name: "Clacky", dependencies: ["ClackyCore"]),
        // Self-checks and demo rendering (the Command Line Tools ship without XCTest).
        .executableTarget(name: "ClackyCheck", dependencies: ["ClackyCore", "ClackyObjC"]),
    ]
)
