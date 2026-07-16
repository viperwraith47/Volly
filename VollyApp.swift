//
//  VollyApp.swift
//  Volly
//
//  Created for Arena.ai on 2026-07-15.
//  SwiftUI Main Application Entry Point - Installs Volly in the Menu Bar as a Window popup
//

import SwiftUI

@main
struct VollyApp: App {
    // Keep the AudioEngine alive across the app's entire lifespan
    @StateObject private var engine = AudioEngine()
    
    var body: some Scene {
        MenuBarExtra {
            ContentView(engine: engine)
        } label: {
            Image(systemName: "speaker.wave.2.bubble")
                .font(.system(size: 14, weight: .medium))
        }
        .menuBarExtraStyle(.window) // Places a beautiful SwiftUI View in a floating panel under the icon
    }
}
