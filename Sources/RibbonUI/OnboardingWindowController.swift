import AppKit
import ApplicationServices
import SwiftUI

/// First-run walkthrough for the Accessibility permission. Polls until it's granted,
/// then closes and calls `onGranted` exactly once. Main thread only.
public final class OnboardingWindowController {
    private var window: NSWindow?
    private var timer: Timer?
    private var onGranted: (() -> Void)?

    public init() {}

    deinit {
        timer?.invalidate()
    }

    /// Shows the Accessibility permission walkthrough; calls `onGranted` once (on main)
    /// as soon as the permission is detected, then closes itself.
    public func show(onGranted: @escaping () -> Void) {
        if AXIsProcessTrusted() {
            onGranted()
            return
        }
        self.onGranted = onGranted
        let window = self.window ?? makeWindow()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        startPolling()
    }

    private func makeWindow() -> NSWindow {
        let view = OnboardingView(openSettings: { [weak self] in self?.requestPermission() })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 470),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Welcome to Ribbon"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        window.center()
        self.window = window
        return window
    }

    private func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        SystemSettingsLink.accessibility.open()
    }

    private func startPolling() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func poll() {
        guard AXIsProcessTrusted() else { return }
        timer?.invalidate()
        timer = nil
        window?.close()
        let callback = onGranted
        onGranted = nil
        Log.onboarding.info("Accessibility permission granted")
        callback?()
    }
}

private struct OnboardingView: View {
    let openSettings: () -> Void

    private let shortcuts: [(String, String)] = [
        ("⌥ H  ⌥ L", "Move focus left / right along the strip"),
        ("⌥⇧ H  ⌥⇧ L", "Move the window left / right"),
        ("⌥ R", "Cycle through preset widths"),
        ("⌥ F", "Full width"),
        ("⌥ [  ⌥ ]", "Stack into the neighbouring column"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "rectangle.split.3x1.fill").font(.system(size: 36)).foregroundColor(.accentColor)
                VStack(alignment: .leading) {
                    Text("Ribbon").font(.title.weight(.semibold))
                    Text("Your windows on one endless, scrolling strip.").foregroundStyle(.secondary)
                }
            }
            Text("Ribbon needs the Accessibility permission to move and resize windows — it's how macOS lets any window manager work. Nothing leaves your Mac.")
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Accessibility Settings", action: openSettings)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            Text("Turn on Ribbon in the list. This window closes by itself once it's allowed.")
                .font(.callout).foregroundStyle(.secondary)
            Divider()
            Text("The five shortcuts to learn").font(.headline)
            ForEach(shortcuts, id: \.0) { keys, text in
                HStack {
                    Text(keys).font(.system(.body, design: .rounded)).frame(width: 110, alignment: .leading)
                    Text(text).foregroundStyle(.secondary)
                }
            }
        }
        .padding(28)
        .frame(width: 520)
    }
}
