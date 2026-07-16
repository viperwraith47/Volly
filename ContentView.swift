//
//  ContentView.swift
//  Volly
//
//  Created for Arena.ai on 2026-07-15.
//  Beautiful modern Glassmorphic UI with Inline Renaming, Output Routing, and Deletion/Ignore Lists
//

import SwiftUI
import AppKit

struct ContentView: View {
    @ObservedObject var engine: AudioEngine
    
    var body: some View {
        VStack(spacing: 0) {
            headerView
            
            Divider()
                .background(Color.white.opacity(0.12))
            
            if engine.activeApps.isEmpty {
                emptyStateView
            } else {
                appsListView
            }
            
            Divider()
                .background(Color.white.opacity(0.12))
            
            footerView
        }
        .frame(width: 320, height: 420)
        .background(
            VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
                .edgesIgnoringSafeArea(.all)
        )
    }
    
    private var headerView: some View {
        HStack {
            Image(systemName: "speaker.wave.2.bubble.fill")
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(.accentColor)
            
            Text("Volly")
                .font(.system(size: 14, weight: .black))
                .foregroundColor(.primary)
            
            Spacer()
            
            HStack(spacing: 4) {
                Circle()
                    .fill(Color.green)
                    .frame(width: 6, height: 6)
                Text("Live")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.green.opacity(0.15))
            .cornerRadius(4)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
    
    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Spacer()
            
            Image(systemName: "waveform")
                .font(.system(size: 38))
                .foregroundColor(.accentColor.opacity(0.8))
            
            Text("No Active Sound Streams")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.primary)
            
            Text("Play sound in any application (like Spotify, Safari, YouTube, or Apple Music) and it will instantly appear here with its own volume slider.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
                .lineSpacing(3)
            
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private var appsListView: some View {
        ScrollView {
            VStack(spacing: 10) {
                ForEach(engine.activeApps) { app in
                    AppVolumeRow(app: app, engine: engine)
                }
            }
            .padding(.all, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private var footerView: some View {
        HStack {
            HStack(spacing: 6) {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 11))
                Text(engine.defaultOutputDeviceUID.isEmpty ? "No active device" : "Device: \(engine.defaultOutputDeviceUID.components(separatedBy: ":").last ?? "System Speakers")")
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundColor(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: 160, alignment: .leading)
            
            Spacer()
            
            // Settings menu dropdown containing Slider Reset, Restore Hidden, Factory Reset, Author Credit, and Quit action
            Menu {
                Button(action: {
                    engine.resetAllSliders()
                }) {
                    Label("Reset All Sliders", systemImage: "arrow.counterclockwise")
                }
                
                if !engine.ignoredBundleIDs.isEmpty {
                    Button(action: {
                        engine.resetIgnoredApps()
                    }) {
                        Label("Restore Hidden Apps (\(engine.ignoredBundleIDs.count))", systemImage: "eye.fill")
                    }
                }
                
                Button(action: {
                    engine.resetEverything()
                }) {
                    Label("Reset Everything to Default", systemImage: "trash.fill")
                }
                
                Divider()
                
                Link(destination: URL(string: "https://github.com/viperwraith47")!) {
                    Label("by: viperwraith47", systemImage: "link")
                }
                
                Divider()
                
                Button(action: {
                    NSApplication.shared.terminate(nil)
                }) {
                    Label("Quit Volly", systemImage: "power")
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 10, weight: .bold))
                    Text("Settings")
                        .font(.system(size: 10, weight: .bold))
                }
                .foregroundColor(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.white.opacity(0.06))
                .cornerRadius(4)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden) // Cleaner macOS menu styling without the default indicator arrow
            .onHover { hovering in
                if hovering {
                    NSCursor.pointingHand.set()
                } else {
                    NSCursor.arrow.set()
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.2))
    }
}

struct AppVolumeRow: View {
    @ObservedObject var app: ProcessTapController
    var engine: AudioEngine
    @State private var isHovered = false
    
    var body: some View {
        VStack(spacing: 8) {
            HStack {
                AppIconView(bundleID: app.bundleID, pid: app.pid)
                    .frame(width: 24, height: 24)
                    .cornerRadius(5)
                    .shadow(color: .black.opacity(0.2), radius: 1, x: 0, y: 1)
                
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        // Editable App Name TextField
                        EditableAppNameView(app: app)
                        
                        // Delete / Ignore close button
                        if isHovered {
                            Button(action: {
                                withAnimation {
                                    engine.ignoreApp(bundleID: app.bundleID)
                                }
                            }) {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary.opacity(0.8))
                            }
                            .buttonStyle(.plain)
                            .help("Hide/Delete this app from mixer")
                            .onHover { hovering in
                                if hovering { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
                            }
                        }
                    }
                    
                    Text("PID: \(app.pid)")
                        .font(.system(size: 8))
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                Text("\(Int(app.volume * 100))%")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(app.volume > 1.0 ? .orange : .accentColor)
            }
            
            HStack(spacing: 8) {
                Button(action: {
                    app.isMuted.toggle()
                }) {
                    Image(systemName: app.isMuted || app.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 10))
                        .foregroundColor(app.isMuted ? .red : .primary)
                        .frame(width: 20, height: 20)
                        .background(app.isMuted ? Color.red.opacity(0.15) : Color.white.opacity(0.05))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    if hovering { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
                }
                
                Slider(value: $app.volume, in: 0.0...2.0)
                    .accentColor(app.volume > 1.0 ? .orange : .accentColor)
                
                if app.volume > 1.0 {
                    Text("Boost")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(Color.orange)
                        .cornerRadius(3)
                        .transition(.scale)
                }
            }
            
            // Per-App Output Device Selector Row
            HStack {
                Spacer()
                
                Menu {
                    Button(action: {
                        // Re-route to system default output
                        app.outputDeviceUID = engine.defaultOutputDeviceUID
                    }) {
                        HStack {
                            Text("Follow System Default")
                            if app.outputDeviceUID == engine.defaultOutputDeviceUID {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                    
                    Divider()
                    
                    ForEach(engine.availableOutputDevices) { device in
                        Button(action: {
                            app.outputDeviceUID = device.uid
                        }) {
                            HStack {
                                Text(device.name)
                                if app.outputDeviceUID == device.uid {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 8))
                        Text(getCurrentDeviceName())
                            .font(.system(size: 8, weight: .semibold))
                            .lineLimit(1)
                    }
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.white.opacity(0.06))
                    .cornerRadius(4)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .onHover { hovering in
                    if hovering { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
                }
            }
            .padding(.top, 2)
        }
        .padding(.all, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isHovered ? Color.white.opacity(0.08) : Color.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isHovered ? Color.white.opacity(0.15) : Color.clear, lineWidth: 1)
                )
        )
        .onHover { hovering in
            isHovered = hovering
        }
    }
    
    private func getCurrentDeviceName() -> String {
        if app.outputDeviceUID == engine.defaultOutputDeviceUID {
            return "Follow System Default"
        }
        if let match = engine.availableOutputDevices.first(where: { $0.uid == app.outputDeviceUID }) {
            return match.name
        }
        return "Unknown Output Device"
    }
}

struct EditableAppNameView: View {
    @ObservedObject var app: ProcessTapController
    @State private var isEditing = false
    @State private var tempName = ""
    @State private var isHovered = false
    
    var body: some View {
        HStack(spacing: 6) {
            if isEditing {
                TextField("App Custom Name", text: $tempName, onCommit: {
                    let cleaned = tempName.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !cleaned.isEmpty {
                        app.customName = cleaned
                    } else {
                        app.customName = app.name
                    }
                    isEditing = false
                })
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 140)
                .onAppear {
                    tempName = app.customName
                }
            } else {
                Text(app.customName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                
                if isHovered {
                    Button(action: {
                        tempName = app.customName
                        isEditing = true
                    }) {
                        Image(systemName: "pencil")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering in
                        if hovering { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
                    }
                }
            }
        }
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

struct AppIconView: View {
    let bundleID: String
    let pid: pid_t
    
    var body: some View {
        if let icon = getIcon(for: bundleID, pid: pid) {
            Image(nsImage: icon)
                .resizable()
                .scaledToFit()
        } else {
            Image(systemName: "music.note")
                .resizable()
                .scaledToFit()
                .foregroundColor(.secondary)
        }
    }
    
    private func getIcon(for bundleID: String, pid: pid_t) -> NSImage? {
        // Try to get the official app bundle icon via workspace by its bundle identifier
        if !bundleID.isEmpty {
            if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                return NSWorkspace.shared.icon(forFile: appURL.path)
            }
        }
        
        // Fallback: Try reading direct process icon if running application matches
        if let app = NSRunningApplication(processIdentifier: pid) {
            return app.icon
        }
        
        return nil
    }
}

struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode
    
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }
    
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}
