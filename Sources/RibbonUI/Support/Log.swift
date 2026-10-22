import os

/// Loggers for the UI target (subsystem `com.raff.ribbon`).
enum Log {
    static let subsystem = "com.raff.ribbon"

    static let settings = Logger(subsystem: subsystem, category: "UI.Settings")
    static let overlay = Logger(subsystem: subsystem, category: "UI.Overlay")
    static let menuBar = Logger(subsystem: subsystem, category: "UI.MenuBar")
    static let onboarding = Logger(subsystem: subsystem, category: "UI.Onboarding")
}
