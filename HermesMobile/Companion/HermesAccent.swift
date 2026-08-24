import SwiftUI

// ============================================================================
//  Cor de acento de cada bot (hex do ui_meta, com paleta estável de fallback).
// ============================================================================

extension Color {
    init?(hermesHex raw: String?) {
        guard let raw else { return nil }
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 {
            s = s.map { "\($0)\($0)" }.joined()
        }
        guard s.count == 6, let n = UInt32(s, radix: 16) else { return nil }
        self.init(
            red: Double((n >> 16) & 0xFF) / 255,
            green: Double((n >> 8) & 0xFF) / 255,
            blue: Double(n & 0xFF) / 255
        )
    }

    static func hermesAccent(hex: String?, fallbackKey: String) -> Color {
        if let color = Color(hermesHex: hex) { return color }
        let palette: [Color] = [
            Color(red: 0.36, green: 0.68, blue: 0.89),
            Color(red: 0.95, green: 0.61, blue: 0.33),
            Color(red: 0.62, green: 0.55, blue: 0.90),
            Color(red: 0.40, green: 0.76, blue: 0.58),
            Color(red: 0.95, green: 0.45, blue: 0.55),
            Color(red: 0.30, green: 0.74, blue: 0.78),
        ]
        let hash = abs(fallbackKey.lowercased().unicodeScalars.reduce(0) { $0 &+ Int($1.value) })
        return palette[hash % palette.count]
    }
}

enum HermesAccentHex {
    static func fallback(for key: String) -> String {
        let palette = ["5BADE3", "F29B54", "9E8CE6", "66C294", "F2738C", "4DBCC7"]
        let hash = abs(key.lowercased().unicodeScalars.reduce(0) { $0 &+ Int($1.value) })
        return palette[hash % palette.count]
    }
}
