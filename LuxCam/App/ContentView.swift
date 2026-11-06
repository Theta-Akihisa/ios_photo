//  ContentView.swift
//  Owns the CameraService and ties its lifetime to the scene phase.

import SwiftUI

struct ContentView: View {
    @StateObject private var camera = CameraService(lookRenderer: LookRenderer.shared)
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            Theme.black.ignoresSafeArea()
            CameraScreen(camera: camera)
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            switch phase {
            case .active: camera.start()
            case .background: camera.stop()
            default: break      // .inactive is transient (Control Center, alerts)
            }
        }
    }
}
