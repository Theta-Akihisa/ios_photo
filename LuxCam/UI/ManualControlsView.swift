//  ManualControlsView.swift
//  Chip row [AF/MF] [S] [ISO] [EV] [LOOK] [APERTURE] [FORMAT] and the dial / picker shown for the selected chip.

import SwiftUI

enum ManualChip: String, Identifiable {
    case focus, shutter, iso, ev, look, aperture, format, photoFormat
    var id: String { rawValue }
}

struct ManualControlsView: View {
    @ObservedObject var camera: CameraService
    @State private var selected: ManualChip?
    @State private var showFormat = false

    private var state: CameraState { camera.state }
    private var isExposureAuto: Bool { state.manual.exposure == .auto }

    // MARK: Tables

    private static let shutterTable: [Double] = [8000, 4000, 2000, 1000, 500, 250, 125, 60, 30, 15, 8, 4, 2].map { 1.0 / $0 }
    private static let isoTable: [Float] = [25, 32, 40, 50, 64, 80, 100, 125, 160, 200, 250, 320, 400, 500,
                                            640, 800, 1000, 1250, 1600, 2000, 2500, 3200, 4000, 5000, 6400]
    private static let apertureTable: [Float] = [1.4, 1.6, 1.8, 2.0, 2.2, 2.5, 2.8, 3.2, 3.5, 4.0, 4.5, 5.6,
                                                 6.3, 7.1, 8.0, 9.0, 11.0, 13.0, 16.0]

    private var shutterStops: [Double] {
        let r = state.capabilities.exposureRange
        let list = Self.shutterTable.filter { $0 >= r.lowerBound * 0.999 && $0 <= r.upperBound * 1.001 }
        return list.isEmpty ? [min(max(1.0 / 60.0, r.lowerBound), r.upperBound)] : list
    }

    private var isoStops: [Float] {
        let r = state.capabilities.isoRange
        let list = Self.isoTable.filter { $0 >= r.lowerBound * 0.999 && $0 <= r.upperBound * 1.001 }
        return list.isEmpty ? [r.lowerBound] : list
    }

    private static func nearestIndex(_ values: [Double], to target: Double) -> Int {
        guard !values.isEmpty, target > 0 else { return 0 }
        var best = 0
        var bestDistance = Double.infinity
        for (i, v) in values.enumerated() {
            let d = abs(log(v / target))
            if d < bestDistance { bestDistance = d; best = i }
        }
        return best
    }

    // MARK: Available chips

    private var chips: [ManualChip] {
        var list: [ManualChip] = [.focus, .shutter, .iso]
        if isExposureAuto { list.append(.ev) }
        list.append(.look)
        if state.mode == .portrait || state.mode == .cinematic { list.append(.aperture) }
        if state.mode.isVideo { list.append(.format) }
        if state.mode == .photo { list.append(.photoFormat) }
        return list
    }

    var body: some View {
        VStack(spacing: 10) {
            chipRow
            if let selected, chips.contains(selected) {
                detail(for: selected)
                    .padding(.horizontal, Theme.gutter)
                    .transition(.opacity)
                    .id(selected)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: selected)
        .sheet(isPresented: $showFormat) { VideoFormatView(camera: camera) }
    }

    // MARK: Chips

    private var chipRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(chips) { chip in
                    Button {
                        if chip == .format {
                            showFormat = true
                        } else {
                            selected = (selected == chip) ? nil : chip
                        }
                    } label: {
                        chipLabel(chip)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Theme.gutter)
        }
        .sensoryFeedback(.selection, trigger: selected)
    }

    private func chipTitle(_ chip: ManualChip) -> String {
        switch chip {
        case .focus: return state.manual.focus == .auto ? "AF" : "MF"
        case .shutter: return "S"
        case .iso: return "ISO"
        case .ev: return "EV"
        case .look: return "LOOK"
        case .aperture: return "APERTURE"
        case .format: return "FORMAT"
        case .photoFormat: return "PHOTO"
        }
    }

    private func chipValue(_ chip: ManualChip) -> String {
        switch chip {
        case .focus:
            if case .manual(let p) = state.manual.focus { return Fmt.lens(p) }
            return "AUTO"
        case .shutter:
            if case .manual(let d, _) = state.manual.exposure { return Fmt.shutter(d) }
            return "AUTO"
        case .iso:
            if case .manual(_, let iso) = state.manual.exposure { return Fmt.iso(iso) }
            return "AUTO"
        case .ev: return Fmt.ev(Double(state.manual.exposureBias))
        case .look: return state.look.title
        case .aperture: return Fmt.aperture(state.simulatedAperture)
        case .format: return state.video.resolution4K ? "4K" : "HD"
        case .photoFormat: return state.photoFormat.title
        }
    }

    private func chipLabel(_ chip: ManualChip) -> some View {
        let isSelected = selected == chip
        return VStack(spacing: 3) {
            Text(chipTitle(chip)).luxCaps(9, color: isSelected ? Theme.red : Theme.dim)
            Text(chipValue(chip))
                .font(Theme.mono(12, .medium))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
        }
        .frame(minWidth: 54)
        .padding(.horizontal, 10).padding(.vertical, 7)
        .overlay(Rectangle().stroke(isSelected ? Theme.red : Theme.hairline, lineWidth: 0.5))
        .contentShape(Rectangle())
    }

    // MARK: Detail

    @ViewBuilder
    private func detail(for chip: ManualChip) -> some View {
        switch chip {
        case .focus: focusDial
        case .shutter: shutterDial
        case .iso: isoDial
        case .ev: evDial
        case .look: LookPickerView(camera: camera)
        case .aperture: apertureDial
        case .format: EmptyView()
        case .photoFormat: photoFormatPicker
        }
    }

    private var photoFormatPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 0) {
                ForEach(PhotoFormat.allCases) { f in
                    let ok = f == .heif || state.capabilities.proRAW
                    let isOn = state.photoFormat == f
                    Button {
                        camera.set(photoFormat: f)
                    } label: {
                        VStack(spacing: 4) {
                            Text(f.title).font(Theme.mono(14, isOn ? .semibold : .regular))
                            Text(ok ? " " : "非対応").font(.system(size: 9))
                            Rectangle().fill(isOn ? Theme.red : Color.clear).frame(height: 2)
                        }
                        .foregroundStyle(ok ? (isOn ? Theme.text : Theme.dim) : Theme.faint)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!ok)
                }
            }
            if state.photoFormat == .proRAW {
                Text("ProRAW: DNG を同時保存（ルックはHEIFのみに適用）")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.dim)
            }
        }
    }

    private var focusDial: some View {
        Group {
            if state.capabilities.manualFocus {
                ScaleDial(
                    value: Binding(
                        get: {
                            if case .manual(let p) = state.manual.focus { return Double(p) }
                            return Double(state.liveLensPosition)
                        },
                        set: { v in
                            var m = state.manual
                            m.focus = .manual(lensPosition: Float(min(max(v, 0), 1)))
                            camera.set(manual: m)
                        }),
                    range: 0...1, tickStep: 0.02, majorEvery: 5, snapsToTicks: false,
                    isAuto: state.manual.focus == .auto,
                    onAuto: {
                        var m = state.manual
                        m.focus = .auto
                        camera.set(manual: m)
                    },
                    label: { v in v < 0.02 ? "近 NEAR" : (v > 0.98 ? "∞" : Fmt.lens(Float(v))) })
            } else {
                Text("この端末はマニュアルフォーカスに対応していません")
                    .font(.system(size: 12)).foregroundStyle(Theme.dim)
            }
        }
    }

    /// Values used to fill in the "other" parameter when switching from auto to manual exposure.
    private var baseISO: Float {
        if case .manual(_, let iso) = state.manual.exposure { return iso }
        let r = state.capabilities.isoRange
        return state.liveISO > 0 ? min(max(state.liveISO, r.lowerBound), r.upperBound) : r.lowerBound
    }

    private var baseDuration: Double {
        if case .manual(let d, _) = state.manual.exposure { return d }
        let r = state.capabilities.exposureRange
        return state.liveShutterSeconds > 0 ? min(max(state.liveShutterSeconds, r.lowerBound), r.upperBound) : 1.0 / 60.0
    }

    private func setAutoExposure() {
        var m = state.manual
        m.exposure = .auto
        camera.set(manual: m)
    }

    private var shutterDial: some View {
        let stops = shutterStops
        return ScaleDial(
            value: Binding(
                get: { Double(Self.nearestIndex(stops, to: baseDuration)) },
                set: { v in
                    let i = min(max(Int(v.rounded()), 0), stops.count - 1)
                    var m = state.manual
                    m.exposure = .manual(durationSeconds: stops[i], iso: baseISO)
                    camera.set(manual: m)
                }),
            range: 0...Double(max(stops.count - 1, 1)), tickStep: 1, majorEvery: 1,
            isAuto: isExposureAuto, onAuto: setAutoExposure,
            label: { v in Fmt.shutter(stops[min(max(Int(v.rounded()), 0), stops.count - 1)]) })
    }

    private var isoDial: some View {
        let stops = isoStops
        let asDouble = stops.map { Double($0) }
        return ScaleDial(
            value: Binding(
                get: { Double(Self.nearestIndex(asDouble, to: Double(baseISO))) },
                set: { v in
                    let i = min(max(Int(v.rounded()), 0), stops.count - 1)
                    var m = state.manual
                    m.exposure = .manual(durationSeconds: baseDuration, iso: stops[i])
                    camera.set(manual: m)
                }),
            range: 0...Double(max(stops.count - 1, 1)), tickStep: 1, majorEvery: 1,
            isAuto: isExposureAuto, onAuto: setAutoExposure,
            label: { v in Fmt.iso(stops[min(max(Int(v.rounded()), 0), stops.count - 1)]) })
    }

    private var evDial: some View {
        let lo = max(-2.0, Double(state.capabilities.exposureBiasRange.lowerBound))
        let hi = min(2.0, Double(state.capabilities.exposureBiasRange.upperBound))
        return ScaleDial(
            value: Binding(
                get: { Double(state.manual.exposureBias) },
                set: { v in
                    var m = state.manual
                    m.exposureBias = Float(min(max(v, lo), hi))
                    camera.set(manual: m)
                }),
            range: lo...max(hi, lo + 1.0 / 3.0), tickStep: 1.0 / 3.0, majorEvery: 3,
            isAuto: state.manual.exposureBias == 0,
            onAuto: {
                var m = state.manual
                m.exposureBias = 0
                camera.set(manual: m)
            },
            label: { v in Fmt.ev(v) + " EV" })
    }

    private var apertureDial: some View {
        let stops = Self.apertureTable
        let asDouble = stops.map { Double($0) }
        return ScaleDial(
            value: Binding(
                get: { Double(Self.nearestIndex(asDouble, to: Double(state.simulatedAperture))) },
                set: { v in
                    let i = min(max(Int(v.rounded()), 0), stops.count - 1)
                    camera.set(simulatedAperture: stops[i])
                }),
            range: 0...Double(stops.count - 1), tickStep: 1, majorEvery: 1,
            label: { v in Fmt.aperture(stops[min(max(Int(v.rounded()), 0), stops.count - 1)]) })
    }
}
