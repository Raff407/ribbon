import ApplicationServices
import CoreGraphics
import Darwin
import RibbonCore

// Private APIs. Everything here is fail-safe: a missing symbol degrades to "unknown"
// (0 / empty) instead of crashing.

/// Private HIServices call that maps an AX window element to its window-server id.
/// Exported by ApplicationServices on every macOS version Ribbon supports.
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

/// SkyLight / CoreGraphics Spaces functions, resolved at runtime with `dlsym`.
///
/// The `CGS*` names are re-exported by CoreGraphics (already loaded with AppKit); the
/// `SLS*` names live in SkyLight and are the fallback on systems that drop the aliases.
struct SkyLight {
    typealias MainConnectionFn = @convention(c) () -> Int32
    /// Returns a +1 `CFArray` (or NULL).
    typealias CopyManagedDisplaySpacesFn = @convention(c) (Int32) -> UnsafeMutableRawPointer?
    /// `(cid, mask, windowIDs)`; returns a +1 `CFArray` of Space ids (or NULL).
    typealias CopySpacesForWindowsFn = @convention(c) (Int32, Int32, CFArray) -> UnsafeMutableRawPointer?

    /// `kCGSAllSpacesMask`: current | other | user Spaces.
    static let allSpacesMask: Int32 = 0x7

    let mainConnection: MainConnectionFn?
    let copyManagedDisplaySpaces: CopyManagedDisplaySpacesFn?
    let copySpacesForWindows: CopySpacesForWindowsFn?

    /// Resolved once per process; `dlopen` handles are intentionally never closed.
    static let shared = SkyLight.load()

    var isAvailable: Bool {
        mainConnection != nil && copyManagedDisplaySpaces != nil
    }

    /// The process's window-server connection id (0 when unavailable).
    func connectionID() -> Int32 {
        mainConnection?() ?? 0
    }

    /// Raw `CGSCopyManagedDisplaySpaces` result as Foundation dictionaries (empty on failure).
    func managedDisplaySpaces() -> [[String: Any]] {
        guard let copy = copyManagedDisplaySpaces else { return [] }
        let cid = connectionID()
        guard cid != 0, let raw = copy(cid) else { return [] }
        let array = Unmanaged<CFArray>.fromOpaque(raw).takeRetainedValue()
        return (array as NSArray) as? [[String: Any]] ?? []
    }

    /// Space ids the window is on (`CGSCopySpacesForWindows(cid, 0x7, [wid])`), empty when
    /// unknown.
    func spaces(forWindow id: WindowID) -> [UInt64] {
        guard let copy = copySpacesForWindows else { return [] }
        let cid = connectionID()
        guard cid != 0 else { return [] }
        let windows = [NSNumber(value: id)] as CFArray
        guard let raw = copy(cid, SkyLight.allSpacesMask, windows) else { return [] }
        let array = Unmanaged<CFArray>.fromOpaque(raw).takeRetainedValue()
        return SpaceParsing.spaceIDs(from: array as NSArray)
    }

    // MARK: Loading

    private static let skyLightPath = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
    /// `RTLD_DEFAULT` (`(void *)-2` on Darwin); the macro isn't imported into Swift.
    private static let defaultHandle = UnsafeMutableRawPointer(bitPattern: -2)

    private static func load() -> SkyLight {
        let handle = dlopen(skyLightPath, RTLD_LAZY)
        if handle == nil {
            AXLog.spaces.error("SkyLight could not be opened; Spaces support degraded")
        }
        let lookup = { (names: [String]) in symbol(names, skyLight: handle) }
        let loaded = SkyLight(
            mainConnection: lookup(["CGSMainConnectionID", "SLSMainConnectionID"])
                .map { unsafeBitCast($0, to: MainConnectionFn.self) },
            copyManagedDisplaySpaces: lookup(["CGSCopyManagedDisplaySpaces", "SLSCopyManagedDisplaySpaces"])
                .map { unsafeBitCast($0, to: CopyManagedDisplaySpacesFn.self) },
            copySpacesForWindows: lookup(["CGSCopySpacesForWindows", "SLSCopySpacesForWindows"])
                .map { unsafeBitCast($0, to: CopySpacesForWindowsFn.self) }
        )
        if !loaded.isAvailable {
            AXLog.spaces.error("CGS Spaces symbols missing; every Space id will be 0")
        }
        return loaded
    }

    private static func symbol(_ names: [String], skyLight: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer? {
        for name in names {
            if let found = dlsym(defaultHandle, name) { return found }
            if let skyLight, let found = dlsym(skyLight, name) { return found }
        }
        return nil
    }
}
