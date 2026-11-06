//  FocusReticle.swift
//  Thin white focus square with mid-side ticks. Animates 1.3 -> 1.0 and fades.

import SwiftUI

struct FocusReticle: View {
    let position: CGPoint
    let visible: Bool

    private let side: CGFloat = 72
    private let tick: CGFloat = 6

    @State private var scale: CGFloat = 1.3

    var body: some View {
        ZStack {
            Rectangle().stroke(Color.white, lineWidth: 1)
            // Tick marks pointing inward from the middle of each side.
            Path { p in
                let h = side / 2
                p.move(to: CGPoint(x: h, y: 0)); p.addLine(to: CGPoint(x: h, y: tick))
                p.move(to: CGPoint(x: h, y: side)); p.addLine(to: CGPoint(x: h, y: side - tick))
                p.move(to: CGPoint(x: 0, y: h)); p.addLine(to: CGPoint(x: tick, y: h))
                p.move(to: CGPoint(x: side, y: h)); p.addLine(to: CGPoint(x: side - tick, y: h))
            }
            .stroke(Color.white, lineWidth: 1)
        }
        .frame(width: side, height: side)
        .scaleEffect(scale)
        .opacity(visible ? 1 : 0)
        .position(position)
        .allowsHitTesting(false)
        .onChange(of: visible) { _, isVisible in
            if isVisible {
                scale = 1.3
                withAnimation(.easeOut(duration: 0.25)) { scale = 1.0 }
            }
        }
        .animation(.easeInOut(duration: 0.3), value: visible)
    }
}
