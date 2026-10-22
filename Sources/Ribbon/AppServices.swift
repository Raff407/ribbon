import RibbonAX
import RibbonCore
import RibbonEngine
import RibbonInput
import RibbonUI

/// The real platform services, kept alive for the app's lifetime.
final class AppServices {
    let windows = AXWindowSource()
    lazy var applier = AXFrameApplier(source: windows)
    let screens = SystemScreenProvider()
    let spaces = SystemSpaceProvider()
    let input = SystemInputState()
    let hotkeys = EventTapHotkeyManager()
    let gestures = TrackpadGestureMonitor()
    let overlays = OverlayController()
    let scheduler = MainQueueScheduler()
    let sessionStore = FileSessionStore()

    var engineServices: EngineServices {
        EngineServices(windows: windows, screens: screens, spaces: spaces, applier: applier, hotkeys: hotkeys,
                       gestures: gestures, overlays: overlays, input: input, scheduler: scheduler, sessionStore: sessionStore)
    }
}
