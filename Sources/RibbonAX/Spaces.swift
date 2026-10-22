import AppKit
import RibbonCore

/// The current Space of every display, parsed from `CGSCopyManagedDisplaySpaces`.
struct ManagedSpaces: Equatable {
    /// Current Space id per display identifier (display UUID, uppercased).
    var currentByDisplay: [String: UInt64]
    /// Set when the displays share one set of Spaces (identifier `"Main"`): every display
    /// is on this Space.
    var shared: UInt64?

    static let empty = ManagedSpaces(currentByDisplay: [:], shared: nil)

    /// 0 when unknown.
    func currentSpace(forDisplayUUID uuid: String) -> UInt64 {
        if let shared { return shared }
        return currentByDisplay[uuid.uppercased()] ?? 0
    }
}

/// Pure parsing of the private CGS Spaces dictionaries (kept free of SkyLight calls so it
/// can be exercised with plain Foundation values).
enum SpaceParsing {
    static let displayIdentifierKey = "Display Identifier"
    static let currentSpaceKey = "Current Space"
    static let managedSpaceIDKey = "ManagedSpaceID"
    static let id64Key = "id64"
    /// Identifier used when "Displays have separate Spaces" is off.
    static let sharedDisplayIdentifier = "Main"

    /// Parses the array returned by `CGSCopyManagedDisplaySpaces`. Entries without an
    /// identifier or a current Space are skipped.
    static func managedSpaces(from displays: [[String: Any]]) -> ManagedSpaces {
        var current: [String: UInt64] = [:]
        var shared: UInt64?
        for display in displays {
            guard let identifier = display[displayIdentifierKey] as? String,
                  let space = display[currentSpaceKey] as? [String: Any],
                  let id = spaceID(from: space)
            else { continue }
            if identifier == sharedDisplayIdentifier {
                shared = shared ?? id
            } else {
                current[identifier.uppercased()] = id
            }
        }
        return ManagedSpaces(currentByDisplay: current, shared: shared)
    }

    /// A Space dictionary's id: `"ManagedSpaceID"`, else `"id64"`; nil when missing or 0.
    static func spaceID(from space: [String: Any]) -> UInt64? {
        uint64(space[managedSpaceIDKey]) ?? uint64(space[id64Key])
    }

    /// Space ids from a `CGSCopySpacesForWindows` result (an array of numbers).
    static func spaceIDs(from array: NSArray) -> [UInt64] {
        array.compactMap { uint64($0) }
    }

    /// Positive integers only; anything else (missing, wrong type, ≤ 0) is nil.
    static func uint64(_ value: Any?) -> UInt64? {
        guard let number = value as? NSNumber, number.int64Value > 0 else { return nil }
        return number.uint64Value
    }
}

/// `SpaceProviding` backed by the private SkyLight Spaces API (see `SkyLight`). Every
/// failure degrades to Space id 0 ("unknown"), which makes Ribbon behave as if Spaces
/// didn't exist rather than misplacing windows.
public final class SystemSpaceProvider: SpaceProviding {
    public var changeHandler: (() -> Void)?

    private let skyLight: SkyLight
    private var spaceObserver: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?
    /// The engine asks for the current Space many times per layout pass (every gesture
    /// step); each uncached answer is a window-server round trip. Invalidated on Space and
    /// display changes, and after `cacheLifetime` as a safety net.
    private var cache: (spaces: ManagedSpaces, at: TimeInterval)?
    private static let cacheLifetime: TimeInterval = 1

    public init() {
        skyLight = SkyLight.shared
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.cache = nil
            self?.changeHandler?()
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.cache = nil
        }
    }

    deinit {
        if let spaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver)
        }
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
    }

    public func currentSpace(forDisplayUUID uuid: String) -> UInt64 {
        let now = ProcessInfo.processInfo.systemUptime
        if let cache, now - cache.at < Self.cacheLifetime {
            return cache.spaces.currentSpace(forDisplayUUID: uuid)
        }
        let fresh = managedSpaces()
        cache = (fresh, now)
        return fresh.currentSpace(forDisplayUUID: uuid)
    }

    public func spaces(for windows: [WindowID]) -> [WindowID: UInt64] {
        guard skyLight.copySpacesForWindows != nil else { return [:] }
        var result: [WindowID: UInt64] = [:]
        for id in windows {
            if let first = skyLight.spaces(forWindow: id).first {
                result[id] = first
            }
        }
        return result
    }

    /// Fresh snapshot of every display's current Space (one window-server round trip).
    func managedSpaces() -> ManagedSpaces {
        guard skyLight.isAvailable else { return .empty }
        return SpaceParsing.managedSpaces(from: skyLight.managedDisplaySpaces())
    }
}
