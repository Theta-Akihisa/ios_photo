//  ScaleDial.swift
//  Drag-scrubbable tick ruler (like a lens ring) with haptic detents.

import SwiftUI
import UIKit

struct ScaleDial: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    /// Distance between two ticks in value units.
    let tickStep: Double
    /// Every n-th tick is drawn taller.
    var majorEvery: Int = 5
    /// Snap the value to ticks while dragging (discrete controls).
    var snapsToTicks: Bool = true
    /// Highlights the AUTO button when true.
    var isAuto: Bool = false
    /// Shows an AUTO button when set.
    var onAuto: (() -> Void)? = nil
    let label: (Double) -> String

    private let tickSpacing: CGFloat = 12
    @State private var dragStartValue: Double?
    @State private var lastDetent: Int = 0
    @State private var haptic = UISelectionFeedbackGenerator()

    private var pointsPerUnit: CGFloat { tickSpacing / CGFloat(tickStep) }

    var body: some View {
        VStack(spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(label(value))
                    .font(Theme.mono(20, .medium))
                    .foregroundStyle(isAuto ? Theme.dim : Theme.text)
                    .monospacedDigit()
                Spacer()
                if let onAuto {
                    Button(action: onAuto) {
                        Text("AUTO")
                            .luxCaps(10, weight: .semibold, color: isAuto ? Theme.red : Theme.dim)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .overlay(Capsule().stroke(isAuto ? Theme.red : Theme.hairline, lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                }
            }
            ruler.frame(height: 40)
        }
    }

    // MARK: Ruler

    private var ruler: some View {
        Canvas { ctx, size in
            let ppu = tickSpacing / CGFloat(tickStep)
            let cx = size.width / 2
            let count = max(0, Int(((range.upperBound - range.lowerBound) / tickStep).rounded()))
            for i in 0...count {
                let tickValue = range.lowerBound + Double(i) * tickStep
                let x = cx + CGFloat(tickValue - value) * ppu
                if x < -2 || x > size.width + 2 { continue }
                let major = i % max(majorEvery, 1) == 0
                let h: CGFloat = major ? 22 : 12
                let rect = CGRect(x: x - 0.5, y: size.height - h, width: 1, height: h)
                ctx.fill(Path(rect), with: .color(major ? Theme.text.opacity(0.85) : Theme.dim.opacity(0.6)))
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.red).frame(width: 1.5, height: 32)
        }
        .mask(
            LinearGradient(stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: 0.15),
                .init(color: .black, location: 0.85),
                .init(color: .clear, location: 1)
            ], startPoint: .leading, endPoint: .trailing)
        )
        .contentShape(Rectangle())
        .gesture(dragGesture)
    }

    private func detent(for v: Double) -> Int {
        Int(((v - range.lowerBound) / tickStep).rounded())
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { g in
                if dragStartValue == nil {
                    dragStartValue = value
                    lastDetent = detent(for: value)
                    haptic.prepare()
                }
                guard let start = dragStartValue else { return }
                // Content follows the finger: dragging left increases the value.
                var v = start - Double(g.translation.width / pointsPerUnit)
                v = min(max(v, range.lowerBound), range.upperBound)
                let d = detent(for: v)
                if snapsToTicks { v = min(max(range.lowerBound + Double(d) * tickStep, range.lowerBound), range.upperBound) }
                if d != lastDetent {
                    lastDetent = d
                    haptic.selectionChanged()
                    haptic.prepare()
                }
                if v != value { value = v }
            }
            .onEnded { _ in dragStartValue = nil }
    }
}

// MARK: - Preview

private struct DialPreview: View {
    @State private var v: Double = 0.4
    @State private var s: Double = 5
    var body: some View {
        VStack(spacing: 24) {
            ScaleDial(value: $v, range: 0...1, tickStep: 0.02, snapsToTicks: false,
                      isAuto: false, onAuto: {}, label: { String(format: "%.2f", $0) })
            ScaleDial(value: $s, range: 0...12, tickStep: 1, majorEvery: 1,
                      label: { "1/\(Int(pow(2, $0)))" })
        }
        .padding(20)
        .background(Theme.black)
    }
}

#Preview { DialPreview() }
