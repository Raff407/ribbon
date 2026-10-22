import Foundation
import RibbonCore

extension WindowManager {
    /// Multi-line dump of displays, strips, floating windows and hints (Copy Debug Info).
    public func debugDescription() -> String {
        var lines = ["Ribbon — enabled: \(isEnabled), focused: \(focusedWindowID.map(String.init) ?? "none")"]
        for display in displays {
            let disabled = settings.disabledDisplays.contains(display.uuid) ? " (disabled)" : ""
            lines.append("Display \(display.name) \(display.uuid)\(disabled) frame \(display.frame) visible \(display.visibleFrame)"
                + " active \(activeKey(for: display))")
        }
        for key in world.strips.keys.sorted() {
            let strip = world.strip(key)
            lines.append("Strip \(key) offset \(Int(strip.viewportOffset)) focus \(strip.focusedColumnIndex.map(String.init) ?? "-")")
            for (i, column) in strip.columns.enumerated() {
                let windows = column.windows.map { id in "\(id) \(infos[id]?.appName ?? "?") “\(infos[id]?.title ?? "")”" }
                let flags = [column.isFullWidth ? "full" : nil, column.mode == .tabbed ? "tabbed" : nil,
                             column.pin.map { "pin-\($0.rawValue)" }].compactMap { $0 }.joined(separator: ",")
                lines.append("  [\(i)] w=\(String(format: "%.2f", column.widthFraction)) \(flags) active=\(column.activeIndex) \(windows)")
            }
        }
        lines.append("Floating: \(world.floating.sorted())")
        lines.append("Parked (minimized/hidden/fullscreen): \(restoreHints.keys.sorted())")
        lines.append("Tab groups: \(Set(tabGroups.values).map { $0.sorted() })")
        lines.append("Failed bindings: \(failedBindings.map(\.command.id))")
        return lines.joined(separator: "\n")
    }
}
