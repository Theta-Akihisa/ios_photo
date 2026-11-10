//  LuxCamApp.swift
//  App entry point. Always dark, status bar and home indicator hidden for an uncluttered viewfinder.

import SwiftUI

@main
struct LuxCamApp: App {
    init() {
        DispatchQueue.global(qos: .utility).async {
            LookRenderer.shared.prewarm()
        }
        ShareStorage.sweep()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
                .statusBarHidden(true)
                .persistentSystemOverlays(.hidden)
        }
    }
}
