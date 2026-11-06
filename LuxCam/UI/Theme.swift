//  Theme.swift
//  Leica-style minimalism: pure black, one red accent, off-white text, monospaced numerals, hairlines.

import SwiftUI

enum Theme {
    static let black = Color.black
    /// Leica red, used sparingly (dot, selection underline, recording).
    static let red = Color(red: 0.89, green: 0.05, blue: 0.08)
    static let text = Color(red: 0.93, green: 0.92, blue: 0.89)
    static let dim = Color(white: 0.55)
    static let faint = Color(white: 0.28)
    static let hairline = Color.white.opacity(0.18)
    static let panel = Color(white: 0.07)

    static let gutter: CGFloat = 20

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

/// 0.5pt separator line.
struct Hairline: View {
    var body: some View {
        Rectangle().fill(Theme.hairline).frame(height: 0.5)
    }
}

/// The red dot of the logo mark.
struct RedDot: View {
    var size: CGFloat = 8
    var body: some View {
        Circle().fill(Theme.red).frame(width: size, height: size)
    }
}

extension Text {
    /// Small uppercase label with wide tracking.
    func luxCaps(_ size: CGFloat = 10, weight: Font.Weight = .medium, color: Color = Theme.text) -> some View {
        self.font(Theme.mono(size, weight))
            .tracking(size * 0.18)
            .foregroundStyle(color)
    }
}

// MARK: - Formatting helpers

enum Fmt {
    /// 1/250 style for fast shutters, seconds for slow ones.
    static func shutter(_ s: Double) -> String {
        guard s > 0 else { return "—" }
        if s <= 0.5 { return "1/\(Int((1.0 / s).rounded()))" }
        return String(format: "%.1fs", s)
    }

    static func iso(_ v: Float) -> String {
        v > 0 ? "\(Int(v.rounded()))" : "—"
    }

    static func ev(_ v: Double) -> String {
        let x = abs(v) < 0.05 ? 0.0 : v
        return String(format: "%+.1f", x)
    }

    static func lens(_ v: Float) -> String {
        String(format: "%.2f", v)
    }

    static func mmss(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        return String(format: "%02ld:%02ld", s / 60, s % 60)
    }

    static func aperture(_ f: Float) -> String {
        let text: String
        if f < 1 { text = String(format: "%.2f", f) }
        else { text = f == f.rounded() ? String(format: "%.0f", f) : String(format: "%.1f", f) }
        return "ƒ/\(text)"
    }
}

extension VideoFormatSettings {
    /// Short badge for the top bar, e.g. "4K·30·ProRes RAW·LOG".
    var badgeText: String {
        var parts = [resolution4K ? "4K" : "HD", "\(frameRate)", codec.title]
        if color != .standard { parts.append(color.title) }
        return parts.joined(separator: "·")
    }
}
