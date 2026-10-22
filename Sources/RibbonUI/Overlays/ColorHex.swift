import AppKit

/// `#RRGGBB` / `#RRGGBBAA` colour strings (sRGB), as stored in `AppearanceSettings`.
enum ColorHex {
    struct RGBA: Equatable {
        var red: Double
        var green: Double
        var blue: Double
        var alpha: Double
    }

    /// Parses `#RRGGBB` or `#RRGGBBAA` (the `#` is optional, case-insensitive).
    /// Returns nil for anything else.
    static func parse(_ string: String) -> RGBA? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        let hex = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        guard hex.count == 6 || hex.count == 8, hex.allSatisfy(\.isHexDigit),
              let value = UInt64(hex, radix: 16) else { return nil }
        let hasAlpha = hex.count == 8
        let rgb = hasAlpha ? value >> 8 : value
        func channel(_ shift: UInt64, of v: UInt64) -> Double { Double((v >> shift) & 0xFF) / 255 }
        return RGBA(
            red: channel(16, of: rgb),
            green: channel(8, of: rgb),
            blue: channel(0, of: rgb),
            alpha: hasAlpha ? channel(0, of: value) : 1
        )
    }

    /// Formats as `#RRGGBB`, or `#RRGGBBAA` when the colour isn't opaque.
    static func format(_ rgba: RGBA) -> String {
        func byte(_ v: Double) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        let rgb = String(format: "#%02X%02X%02X", byte(rgba.red), byte(rgba.green), byte(rgba.blue))
        return byte(rgba.alpha) == 255 ? rgb : rgb + String(format: "%02X", byte(rgba.alpha))
    }
}

extension NSColor {
    /// sRGB colour from a hex string; nil when the string isn't valid.
    convenience init?(hexString: String) {
        guard let rgba = ColorHex.parse(hexString) else { return nil }
        self.init(srgbRed: rgba.red, green: rgba.green, blue: rgba.blue, alpha: rgba.alpha)
    }

    /// The colour as `#RRGGBB[AA]` in sRGB; nil for colours that can't be converted
    /// (patterns, some catalogue colours).
    var hexString: String? {
        guard let srgb = usingColorSpace(.sRGB) else { return nil }
        return ColorHex.format(ColorHex.RGBA(
            red: Double(srgb.redComponent), green: Double(srgb.greenComponent),
            blue: Double(srgb.blueComponent), alpha: Double(srgb.alphaComponent)
        ))
    }
}
