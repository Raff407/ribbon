// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Ribbon",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Ribbon", targets: ["Ribbon"]),
    ],
    targets: [
        // Pure model + layout + settings + platform protocols. Foundation/CoreGraphics only.
        .target(name: "RibbonCore"),
        // The window-manager brain. Talks to the OS only through RibbonCore protocols.
        .target(name: "RibbonEngine", dependencies: ["RibbonCore"]),
        // Accessibility API, screens, Spaces, frame animation.
        .target(name: "RibbonAX", dependencies: ["RibbonCore"]),
        // Global hotkeys, key names, trackpad gestures.
        .target(name: "RibbonInput", dependencies: ["RibbonCore"]),
        // Menu bar, settings window, overlays, onboarding.
        .target(name: "RibbonUI", dependencies: ["RibbonCore", "RibbonInput"]),
        // The app: wiring, lifecycle, URL scheme.
        .executableTarget(
            name: "Ribbon",
            dependencies: ["RibbonCore", "RibbonEngine", "RibbonAX", "RibbonInput", "RibbonUI"]
        ),
        .testTarget(name: "RibbonCoreTests", dependencies: ["RibbonCore"]),
        .testTarget(name: "RibbonEngineTests", dependencies: ["RibbonCore", "RibbonEngine"]),
    ]
)
