import os

/// Loggers for the RibbonAX module. Every OS / AX failure is logged here and degraded
/// gracefully; nothing in this module crashes on an API error.
enum AXLog {
    static let subsystem = "com.raff.ribbon"

    static let windows = Logger(subsystem: subsystem, category: "ax.windows")
    static let observer = Logger(subsystem: subsystem, category: "ax.observer")
    static let applier = Logger(subsystem: subsystem, category: "ax.applier")
    static let screens = Logger(subsystem: subsystem, category: "ax.screens")
    static let spaces = Logger(subsystem: subsystem, category: "ax.spaces")
    static let input = Logger(subsystem: subsystem, category: "ax.input")
}
