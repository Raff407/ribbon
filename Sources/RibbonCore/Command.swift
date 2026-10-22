import Foundation

public enum CommandCategory: String, CaseIterable, Sendable {
    case navigate = "Navigate"
    case size = "Size"
    case stacks = "Stacks"
    case general = "General"
}

/// Every user-invokable action. Commands are bound to hotkeys, sent over the
/// `ribbon://` URL scheme and the CLI, and shown in Settings → Shortcuts.
///
/// `id` is the stable string form used for persistence and automation
/// (e.g. `focus-left`, `focus-column-3`). Never change an existing id.
public enum Command: Hashable, Sendable {
    // Navigate
    case focus(Direction)
    case focusFirst
    case focusLast
    /// 1-based column number, 1...9.
    case focusColumn(Int)
    case move(Direction)
    case moveFirst
    case moveLast
    case sendToNextDisplay
    // Size
    case cycleWidth
    case cycleWidthBackward
    case toggleFullWidth
    case centreColumn
    case wider
    case narrower
    case taller
    case shorter
    case equalizeHeights
    case pinLeft
    case pinRight
    // Stacks
    case stackIntoLeft
    case stackIntoRight
    case popOutLeft
    case popOutRight
    case toggleTabbed
    case toggleFloat
    // General
    case toggleEnabled
    case gatherWindows
    case showIndicator
    case openSettings

    public static let allCases: [Command] = {
        var all: [Command] = Direction.allCases.map { .focus($0) }
        all += [.focusFirst, .focusLast]
        all += (1...9).map { .focusColumn($0) }
        all += Direction.allCases.map { .move($0) }
        all += [.moveFirst, .moveLast, .sendToNextDisplay]
        all += [.cycleWidth, .cycleWidthBackward, .toggleFullWidth, .centreColumn,
                .wider, .narrower, .taller, .shorter, .equalizeHeights, .pinLeft, .pinRight]
        all += [.stackIntoLeft, .stackIntoRight, .popOutLeft, .popOutRight, .toggleTabbed, .toggleFloat]
        all += [.toggleEnabled, .gatherWindows, .showIndicator, .openSettings]
        return all
    }()

    public var id: String {
        switch self {
        case .focus(let d): return "focus-\(d.rawValue)"
        case .focusFirst: return "focus-first"
        case .focusLast: return "focus-last"
        case .focusColumn(let n): return "focus-column-\(n)"
        case .move(let d): return "move-\(d.rawValue)"
        case .moveFirst: return "move-first"
        case .moveLast: return "move-last"
        case .sendToNextDisplay: return "send-to-next-display"
        case .cycleWidth: return "cycle-width"
        case .cycleWidthBackward: return "cycle-width-backward"
        case .toggleFullWidth: return "toggle-full-width"
        case .centreColumn: return "centre-column"
        case .wider: return "wider"
        case .narrower: return "narrower"
        case .taller: return "taller"
        case .shorter: return "shorter"
        case .equalizeHeights: return "equalize-heights"
        case .pinLeft: return "pin-left"
        case .pinRight: return "pin-right"
        case .stackIntoLeft: return "stack-into-left"
        case .stackIntoRight: return "stack-into-right"
        case .popOutLeft: return "pop-out-left"
        case .popOutRight: return "pop-out-right"
        case .toggleTabbed: return "toggle-tabbed"
        case .toggleFloat: return "toggle-float"
        case .toggleEnabled: return "toggle-enabled"
        case .gatherWindows: return "gather-windows"
        case .showIndicator: return "show-indicator"
        case .openSettings: return "open-settings"
        }
    }

    public init?(id: String) {
        guard let match = Command.allCases.first(where: { $0.id == id }) else { return nil }
        self = match
    }

    public var title: String {
        switch self {
        case .focus(let d): return "Focus \(d.rawValue)"
        case .focusFirst: return "Focus first window"
        case .focusLast: return "Focus last window"
        case .focusColumn(let n): return "Focus window \(n)"
        case .move(let d): return "Move \(d.rawValue)"
        case .moveFirst: return "Move to start"
        case .moveLast: return "Move to end"
        case .sendToNextDisplay: return "Send to next display"
        case .cycleWidth: return "Cycle width"
        case .cycleWidthBackward: return "Cycle width backward"
        case .toggleFullWidth: return "Full width"
        case .centreColumn: return "Centre the column"
        case .wider: return "Wider"
        case .narrower: return "Narrower"
        case .taller: return "Taller"
        case .shorter: return "Shorter"
        case .equalizeHeights: return "Equalize heights"
        case .pinLeft: return "Pin to the left edge"
        case .pinRight: return "Pin to the right edge"
        case .stackIntoLeft: return "Stack into left column"
        case .stackIntoRight: return "Stack into right column"
        case .popOutLeft: return "Pop out to the left"
        case .popOutRight: return "Pop out to the right"
        case .toggleTabbed: return "Tabbed column"
        case .toggleFloat: return "Float / unfloat"
        case .toggleEnabled: return "Stop / start Ribbon"
        case .gatherWindows: return "Gather all windows"
        case .showIndicator: return "Show strip indicator"
        case .openSettings: return "Open Settings"
        }
    }

    public var category: CommandCategory {
        switch self {
        case .focus, .focusFirst, .focusLast, .focusColumn, .move, .moveFirst, .moveLast, .sendToNextDisplay:
            return .navigate
        case .cycleWidth, .cycleWidthBackward, .toggleFullWidth, .centreColumn, .wider, .narrower,
             .taller, .shorter, .equalizeHeights, .pinLeft, .pinRight:
            return .size
        case .stackIntoLeft, .stackIntoRight, .popOutLeft, .popOutRight, .toggleTabbed, .toggleFloat:
            return .stacks
        case .toggleEnabled, .gatherWindows, .showIndicator, .openSettings:
            return .general
        }
    }

    /// True for commands that only change one strip's structure/focus/viewport and are
    /// handled by `Strip.applying(_:area:config:)`. The rest are handled by the engine.
    public var isStripCommand: Bool {
        switch self {
        case .toggleFloat, .sendToNextDisplay, .toggleEnabled, .gatherWindows, .showIndicator, .openSettings:
            return false
        default:
            return true
        }
    }
}

extension Command: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let command = Command(id: raw) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown command id \(raw)")
        }
        self = command
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(id)
    }
}
