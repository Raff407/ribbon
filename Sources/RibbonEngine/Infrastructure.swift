import Foundation
import os
import RibbonCore

let engineLog = Logger(subsystem: "com.raff.ribbon", category: "Engine")

/// Every platform service the engine talks to.
public struct EngineServices {
    public var windows: WindowSource
    public var screens: ScreenProviding
    public var spaces: SpaceProviding
    public var applier: FrameApplying
    public var hotkeys: HotkeyRegistering
    public var gestures: GestureSource
    public var overlays: OverlayPresenting
    public var input: InputStateProviding
    public var scheduler: Scheduler
    public var sessionStore: SessionStoring

    public init(
        windows: WindowSource, screens: ScreenProviding, spaces: SpaceProviding,
        applier: FrameApplying, hotkeys: HotkeyRegistering, gestures: GestureSource,
        overlays: OverlayPresenting, input: InputStateProviding, scheduler: Scheduler,
        sessionStore: SessionStoring
    ) {
        self.windows = windows
        self.screens = screens
        self.spaces = spaces
        self.applier = applier
        self.hotkeys = hotkeys
        self.gestures = gestures
        self.overlays = overlays
        self.input = input
        self.scheduler = scheduler
        self.sessionStore = sessionStore
    }
}

/// `Scheduler` on the main dispatch queue.
public final class MainQueueScheduler: Scheduler {
    private final class Token: Cancellable {
        private(set) var isCancelled = false
        func cancel() { isCancelled = true }
    }

    public init() {}

    @discardableResult
    public func schedule(after delay: TimeInterval, _ block: @escaping () -> Void) -> Cancellable {
        let token = Token()
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, delay)) {
            if !token.isCancelled { block() }
        }
        return token
    }

    public func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
}

/// JSON file in ~/Library/Application Support/Ribbon/session.json by default.
public final class FileSessionStore: SessionStoring {
    private let url: URL

    public init(url: URL? = nil) {
        self.url = url ?? FileSessionStore.defaultURL()
    }

    static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Ribbon", isDirectory: true).appendingPathComponent("session.json")
    }

    public func load() -> SessionSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONDecoder().decode(SessionSnapshot.self, from: data)
        } catch {
            engineLog.error("Ignoring unreadable session file: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    public func save(_ snapshot: SessionSnapshot) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: url, options: .atomic)
        } catch {
            engineLog.error("Couldn't save session: \(error.localizedDescription, privacy: .public)")
        }
    }
}
