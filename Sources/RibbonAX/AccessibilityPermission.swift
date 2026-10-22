import ApplicationServices

/// The one permission Ribbon needs: Accessibility (System Settings → Privacy & Security →
/// Accessibility).
public enum AccessibilityPermission {
    /// `AXIsProcessTrustedWithOptions`, optionally showing the system prompt.
    public static func isTrusted(prompt: Bool) -> Bool {
        // The C global is imported as an unaudited `Unmanaged<CFString>`; it is a constant
        // owned by HIServices, so it is borrowed, not consumed.
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
}
