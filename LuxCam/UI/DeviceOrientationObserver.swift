//  DeviceOrientationObserver.swift
//  Physical device orientation from CoreMotion gravity (works with the rotation lock on).

import SwiftUI
import CoreMotion

enum PhysicalOrientation: Hashable {
    case portrait
    /// Gravity x > 0: the phone's right side points down (phone turned clockwise, Dynamic Island on
    /// the user's right). The user's "up" is screen -x; the overlay canvas is rotated -90°.
    case landscapeRightSideDown
    /// Gravity x < 0: the phone's left side points down (phone turned counter-clockwise, Dynamic Island
    /// on the user's left). The user's "up" is screen +x; the overlay canvas is rotated +90°.
    case landscapeLeftSideDown
}

final class DeviceOrientationObserver: ObservableObject {
    @Published private(set) var orientation: PhysicalOrientation = .portrait

    private let motion = CMMotionManager()

    func start() {
        if motion.isDeviceMotionAvailable {
            guard !motion.isDeviceMotionActive else { return }
            motion.deviceMotionUpdateInterval = 0.1
            motion.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
                guard let g = data?.gravity else { return }
                self?.update(gx: g.x, gy: g.y)
            }
        } else if motion.isAccelerometerAvailable {
            guard !motion.isAccelerometerActive else { return }
            motion.accelerometerUpdateInterval = 0.1
            motion.startAccelerometerUpdates(to: .main) { [weak self] data, _ in
                guard let a = data?.acceleration else { return }
                self?.update(gx: a.x, gy: a.y)
            }
        }
    }

    func stop() {
        motion.stopDeviceMotionUpdates()
        motion.stopAccelerometerUpdates()
    }

    /// Classifies the in-plane angle of gravity, so landscape is still detected when the camera is
    /// pitched down at a table or up at the sky. Hysteresis: enter landscape beyond ±60°, return to
    /// portrait within ±30°. Too flat (face up/down) or upside down keeps the last value.
    private func update(gx: Double, gy: Double) {
        let planar = (gx * gx + gy * gy).squareRoot()
        guard planar > 0.35 else { return }                  // nearly flat: keep last
        let deg = atan2(gx, -gy) * 180 / Double.pi           // 0 = upright, +90 = right side down
        var next = orientation
        if deg > 60 && deg < 150 {
            next = .landscapeRightSideDown
        } else if deg < -60 && deg > -150 {
            next = .landscapeLeftSideDown
        } else if abs(deg) < 30 {
            next = .portrait
        }
        if next != orientation { orientation = next }
    }

    deinit { stop() }
}

/// Maps a rect given in rotated-canvas coordinates to screen coordinates. The canvas is rotated by
/// `degrees` (SwiftUI rotationEffect: positive = clockwise, y down) about the screen centre.
/// Screen point = screenCentre + R(degrees) * (canvasPoint - canvasCentre); width/height swap for ±90.
func canvasRectToScreen(_ r: CGRect, canvas: CGSize, screen: CGSize, degrees: Double) -> CGRect {
    let rad = degrees * Double.pi / 180
    let c = CGFloat(cos(rad)), s = CGFloat(sin(rad))
    let dx = r.midX - canvas.width / 2
    let dy = r.midY - canvas.height / 2
    let cx = screen.width / 2 + dx * c - dy * s
    let cy = screen.height / 2 + dx * s + dy * c
    let swapped = abs(s) > 0.5
    let w = swapped ? r.height : r.width
    let h = swapped ? r.width : r.height
    return CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
}
