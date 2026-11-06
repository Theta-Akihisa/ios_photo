//  GridOverlay.swift
//  Rule-of-thirds grid and Leica-style corner frame lines.

import SwiftUI

/// Rule-of-thirds grid over the visible preview.
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
            .stroke(Color.white.opacity(0.55), lineWidth: 0.75)
            // Subtle dark halo keeps the lines visible over bright subjects.
            .shadow(color: .black.opacity(0.45), radius: 0.8)
        }
        .allowsHitTesting(false)
    }
}

/// Rangefinder-style corner brackets marking the captured frame (inset 3% from each edge;
/// the whole preview is what gets recorded).
struct FrameLinesOverlay: View {
    var body: some View {
        GeometryReader { geo in
            Path { p in
                let w = geo.size.width, h = geo.size.height
                let inset = min(w, h) * 0.03
                let ix = inset, iy = inset
                let len = min(w, h) * 0.07
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
            .stroke(Color.white.opacity(0.85), lineWidth: 1)
            .shadow(color: .black.opacity(0.45), radius: 0.8)
        }
        .allowsHitTesting(false)
    }
}
