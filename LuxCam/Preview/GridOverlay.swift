//  GridOverlay.swift
//  Rule-of-thirds grid and Leica-style corner frame lines.

import SwiftUI

/// Rule-of-thirds grid, thin lines at 25% white.
struct GridOverlay: View {
    var body: some View {
        GeometryReader { geo in
            Path { p in
                let w = geo.size.width, h = geo.size.height
                for i in 1...2 {
                    let x = w * CGFloat(i) / 3
                    let y = h * CGFloat(i) / 3
                    p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: h))
                    p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: w, y: y))
                }
            }
            .stroke(Color.white.opacity(0.25), lineWidth: 0.5)
        }
        .allowsHitTesting(false)
    }
}

/// Rangefinder-style corner brackets inset 8% from each edge.
struct FrameLinesOverlay: View {
    var body: some View {
        GeometryReader { geo in
            Path { p in
                let w = geo.size.width, h = geo.size.height
                let ix = w * 0.08, iy = h * 0.08
                let len = min(w, h) * 0.08
                let l = ix, r = w - ix, t = iy, b = h - iy
                // Top-left
                p.move(to: CGPoint(x: l, y: t + len)); p.addLine(to: CGPoint(x: l, y: t)); p.addLine(to: CGPoint(x: l + len, y: t))
                // Top-right
                p.move(to: CGPoint(x: r - len, y: t)); p.addLine(to: CGPoint(x: r, y: t)); p.addLine(to: CGPoint(x: r, y: t + len))
                // Bottom-right
                p.move(to: CGPoint(x: r, y: b - len)); p.addLine(to: CGPoint(x: r, y: b)); p.addLine(to: CGPoint(x: r - len, y: b))
                // Bottom-left
                p.move(to: CGPoint(x: l + len, y: b)); p.addLine(to: CGPoint(x: l, y: b)); p.addLine(to: CGPoint(x: l, y: b - len))
            }
            .stroke(Color.white.opacity(0.8), lineWidth: 1)
        }
        .allowsHitTesting(false)
    }
}
