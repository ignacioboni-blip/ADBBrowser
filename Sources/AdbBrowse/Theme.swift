import SwiftUI

// MARK: - Live device status (battery, storage, theme seed)

struct DeviceStatus: Equatable {
    var batteryLevel: Int?
    var isCharging = false
    var freeBytes: Int64?
    var totalBytes: Int64?
    var seedHex: String?

    static let empty = DeviceStatus()

    var storageText: String? {
        guard let f = freeBytes else { return nil }
        return ByteCountFormatter.string(fromByteCount: f, countStyle: .file) + " free"
    }

    var usedFraction: Double? {
        guard let f = freeBytes, let t = totalBytes, t > 0 else { return nil }
        return 1 - Double(f) / Double(t)
    }

    var batteryIcon: String {
        guard let l = batteryLevel else { return "battery.0" }
        switch l {
        case 88...: return "battery.100"
        case 63...: return "battery.75"
        case 38...: return "battery.50"
        case 13...: return "battery.25"
        default: return "battery.0"
        }
    }
}

// MARK: - Material You → Mac theme

/// Palette derived from the phone's wallpaper/theme seed color
/// (settings get secure theme_customization_overlay_packages).
struct DeviceTheme: Equatable {
    let accent: Color
    let stops: [Color]   // dark → light, for the palette dots

    static func from(hex: String?) -> DeviceTheme? {
        guard let hex, let seed = Color(androidHex: hex) else { return nil }
        return DeviceTheme(
            accent: seed.adjusted(saturation: 1.1, brightness: 0.92),
            stops: [
                seed.adjusted(saturation: 1.2, brightness: 0.4),
                seed.adjusted(saturation: 1.1, brightness: 0.7),
                seed,
                seed.adjusted(saturation: 0.45, brightness: 1.35),
            ]
        )
    }
}

extension Color {
    /// Android setting colors come as "6F9BFF", "#FF6F9BFF" (ARGB) or "FF6F9BFF".
    init?(androidHex: String) {
        var h = androidHex.trimmingCharacters(in: .whitespacesAndNewlines)
        if h.hasPrefix("#") { h.removeFirst() }
        if h.count == 8 { h.removeFirst(2) }   // drop alpha
        guard h.count == 6, let v = UInt64(h, radix: 16) else { return nil }
        self.init(
            red: Double((v >> 16) & 0xFF) / 255,
            green: Double((v >> 8) & 0xFF) / 255,
            blue: Double(v & 0xFF) / 255
        )
    }

    /// Black or white, whichever reads better on top of this color.
    var contrastingText: Color {
        guard let ns = NSColor(self).usingColorSpace(.deviceRGB) else { return .white }
        let luminance = 0.299 * ns.redComponent + 0.587 * ns.greenComponent + 0.114 * ns.blueComponent
        return luminance > 0.62 ? .black : .white
    }

    func adjusted(saturation satScale: CGFloat = 1, brightness brightScale: CGFloat = 1) -> Color {
        guard let ns = NSColor(self).usingColorSpace(.deviceRGB) else { return self }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ns.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return Color(hue: h,
                     saturation: max(0, min(1, s * satScale)),
                     brightness: max(0, min(1, b * brightScale)),
                     opacity: a)
    }
}

// MARK: - Transfer progress

struct TransferProgress: Equatable {
    var name: String
    var isUpload: Bool
    var fraction: Double?    // nil → size unknown (folders), show indeterminate
    var speed: String
    var counter: String?     // "2 of 5"
}

// MARK: - Breadcrumbs

struct PathSegment: Identifiable, Hashable {
    let name: String
    let path: String
    var id: String { path }
}
