//  LuxCamApp.swift
//  App entry point. Always dark, status bar and home indicator hidden for an uncluttered viewfinder.

import SwiftUI

@main
struct LuxCamApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
                .statusBarHidden(true)
                .persistentSystemOverlays(.hidden)
        }
    }
}
