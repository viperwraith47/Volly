//
//  AudioEngine.swift
//  Volly
//
//  Created for Arena.ai on 2026-07-15.
//  CoreAudio Process Taps-based Individual App Volume Controller & Audio Router for macOS 14.2+
//

import Foundation
import CoreAudio
import Combine
import Cocoa
import Darwin

/// Repesents a physical playback device (e.g., Speakers, Headphones, AirPods).
struct AudioDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let name: String
    let uid: String
}

/// Manages a single process audio tap, its aggregate device, and the real-time audio scaling IOProc.
class ProcessTapController: Identifiable, ObservableObject {
    let pid: pid_t
    let name: String
    let bundleID: String
    let processObjectID: AudioObjectID
    
    @Published var volume: Double = 1.0
    @Published var isMuted: Bool = false
    
    @Published var customName: String {
        didSet {
            if !customName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                UserDefaults.standard.set(customName, forKey: "VollyName-\(bundleID)")
            } else {
                UserDefaults.standard.removeObject(forKey: "VollyName-\(bundleID)")
            }
        }
    }
    
    @Published var outputDeviceUID: String {
        didSet {
            if oldValue != outputDeviceUID {
                UserDefaults.standard.set(outputDeviceUID, forKey: "VollyRoute-\(bundleID)")
                rebuildTap(with: outputDeviceUID)
            }
        }
    }
    
    let id = UUID()
    
    private var tapObjectID: AudioObjectID = kAudioObjectUnknown
    private var aggregateDeviceID: AudioObjectID = kAudioObjectUnknown
    private var ioProcID: AudioDeviceIOProcID? = nil
    private var isRunning: Bool = false
    
    private let ioQueue: DispatchQueue
    
    init(pid: pid_t, name: String, bundleID: String, processObjectID: AudioObjectID, outputDeviceUID: String) {
        self.pid = pid
        self.name = name
        self.bundleID = bundleID
        self.processObjectID = processObjectID
        self.ioQueue = DispatchQueue(label: "com.volly.tap-io-\(pid)", qos: .userInteractive)
        
        // Load custom user-defined name from UserDefaults or fallback to standard name
        let savedNameKey = "VollyName-\(bundleID)"
        if let savedName = UserDefaults.standard.string(forKey: savedNameKey), !savedName.isEmpty {
            self.customName = savedName
        } else {
            self.customName = name
        }
        
        // Load custom output device routing or fallback to standard default device
        let savedRouteKey = "VollyRoute-\(bundleID)"
        if let savedUID = UserDefaults.standard.string(forKey: savedRouteKey), !savedUID.isEmpty {
            self.outputDeviceUID = savedUID
        } else {
            self.outputDeviceUID = outputDeviceUID
        }
        
        setupTap(processObjectID: processObjectID, outputDeviceUID: self.outputDeviceUID)
    }
    
    deinit {
        stop()
    }
    
    private func setupTap(processObjectID: AudioObjectID, outputDeviceUID: String) {
        // 1. Create a CATapDescription
        // In macOS 14.2+, we can initialize a tap with target processes and a device UID.
        // To intercept ONLY our target process, we use init(stereoGlobalTapButExcludeProcesses:) 
        // with the processObjectID, and set exclusive = false (or isExclusive = false)
        let tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: [processObjectID])
        tapDescription.uuid = UUID()
        tapDescription.muteBehavior = .muted // Mute the original output stream so we play back our scaled stream
        tapDescription.isPrivate = true
        tapDescription.name = "VollyTap-\(pid)"
        tapDescription.isExclusive = false // Crucial: Inverts the tap from "everything except" to "only these listed processes"
        
        // 2. Create the CoreAudio process tap
        var tempTapID = AudioObjectID(kAudioObjectUnknown)
        let tapErr = AudioHardwareCreateProcessTap(tapDescription, &tempTapID)
        guard tapErr == noErr else {
            print("❌ Error creating process tap for \(customName) (PID \(pid)): OSStatus \(tapErr)")
            return
        }
        self.tapObjectID = tempTapID
        let tapUID = tapDescription.uuid.uuidString
        
        // 3. Configure the virtual aggregate device.
        // It couples the physical output device with the process tap.
        // By playing through this aggregate, the scaled audio reaches the physical speaker.
        let aggregateDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "VollyAggregate-\(pid)",
            kAudioAggregateDeviceUIDKey: "com.volly.aggregate.\(pid).\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputDeviceUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputDeviceUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapUID,
                    kAudioSubTapDriftCompensationKey: true
                ]
            ]
        ]
        
        // 4. Create the aggregate device
        var tempAggregateID = AudioObjectID(kAudioObjectUnknown)
        let aggErr = AudioHardwareCreateAggregateDevice(aggregateDesc as CFDictionary, &tempAggregateID)
        guard aggErr == noErr else {
            print("❌ Error creating aggregate device for \(customName): OSStatus \(aggErr)")
            AudioHardwareDestroyProcessTap(tempTapID)
            return
        }
        self.aggregateDeviceID = tempAggregateID
        
        // 5. Register the Real-Time IO Callback on the aggregate device
        var tempIoProcID: AudioDeviceIOProcID? = nil
        let ioErr = AudioDeviceCreateIOProcIDWithBlock(&tempIoProcID, tempAggregateID, ioQueue) { [weak self] (inNow, inInputData, inInputTime, outOutputData, inOutputTime) in
            guard let self = self else { return }
            self.processAudio(inInputData: inInputData, outOutputData: outOutputData)
        }
        
        guard ioErr == noErr, let ioProc = tempIoProcID else {
            print("❌ Error registering IOProc for \(customName): OSStatus \(ioErr)")
            AudioHardwareDestroyAggregateDevice(tempAggregateID)
            AudioHardwareDestroyProcessTap(tempTapID)
            return
        }
        self.ioProcID = ioProc
        
        // 6. Start the device stream
        let startErr = AudioDeviceStart(tempAggregateID, ioProc)
        guard startErr == noErr else {
            print("❌ Error starting AudioDevice stream for \(customName): OSStatus \(startErr)")
            AudioDeviceDestroyIOProcID(tempAggregateID, ioProc)
            AudioHardwareDestroyAggregateDevice(tempAggregateID)
            AudioHardwareDestroyProcessTap(tempTapID)
            return
        }
        
        self.isRunning = true
        print("✅ Active tap started for: \(customName) [PID: \(pid)] -> Routed to: \(outputDeviceUID)")
    }
    
    /// Real-time safe audio processing block. Applies volume gain and mute toggles directly to PCM float frames.
    private func processAudio(inInputData: UnsafePointer<AudioBufferList>?, outOutputData: UnsafeMutablePointer<AudioBufferList>?) {
        let vol = Float(self.volume)
        let muted = self.isMuted
        let scaleFactor = muted ? 0.0 : vol
        
        guard let input = inInputData, let output = outOutputData else { return }
        
        // Convert to UnsafeMutableAudioBufferListPointer to allow clean multi-buffer indexing in Swift.
        // We mutate only the output buffer list; the input remains read-only.
        let inputBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outputBuffers = UnsafeMutableAudioBufferListPointer(output)
        
        for i in 0..<outputBuffers.count {
            let outBuffer = outputBuffers[i]
            guard let outData = outBuffer.mData else { continue }
            
            if i < inputBuffers.count {
                let inBuffer = inputBuffers[i]
                guard let inData = inBuffer.mData else { continue }
                
                let sampleCount = Int(outBuffer.mDataByteSize) / MemoryLayout<Float32>.size
                let outPtr = outData.assumingMemoryBound(to: Float32.self)
                let inPtr = inData.assumingMemoryBound(to: Float32.self)
                
                // Real-time gain scaling!
                for j in 0..<sampleCount {
                    outPtr[j] = inPtr[j] * scaleFactor
                }
            } else {
                // If there's no matching input stream buffer, silence the output buffer
                memset(outData, 0, Int(outBuffer.mDataByteSize))
            }
        }
    }
    
    /// Dynamic rebuilding of the tap aggregate when output routing changes
    func rebuildTap(with newOutputDeviceUID: String) {
        DispatchQueue.main.async {
            print("🔄 Re-routing \(self.customName) (PID \(self.pid)) ➜ \(newOutputDeviceUID)...")
            self.stop()
            self.setupTap(processObjectID: self.processObjectID, outputDeviceUID: newOutputDeviceUID)
        }
    }
    
    /// Stops and destroys all CoreAudio allocations and taps.
    func stop() {
        guard isRunning else { return }
        isRunning = false
        
        if let ioProc = ioProcID {
            AudioDeviceStop(aggregateDeviceID, ioProc)
            AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProc)
            ioProcID = nil
        }
        
        if aggregateDeviceID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = kAudioObjectUnknown
        }
        
        if tapObjectID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapObjectID)
            tapObjectID = kAudioObjectUnknown
        }
        
        print("🛑 Tap released for: \(customName) [PID: \(pid)]")
    }
}

/// Dynamic manager that monitors active sound-producing processes, handles output device changes, and publishes list of tracked apps and output devices.
class AudioEngine: ObservableObject {
    @Published var activeApps: [ProcessTapController] = []
    @Published var defaultOutputDeviceUID: String = ""
    @Published var availableOutputDevices: [AudioDevice] = []
    @Published var ignoredBundleIDs: Set<String> = []
    
    private var timer: Timer? = nil
    private var defaultOutputDeviceID: AudioDeviceID = 0
    private var isMonitoring = false
    
    init() {
        // Load the persistently ignored bundle IDs from UserDefaults
        if let savedIgnored = UserDefaults.standard.stringArray(forKey: "VollyIgnoredBundleIDs") {
            self.ignoredBundleIDs = Set(savedIgnored)
        }
        
        setupDefaultOutputDevice()
        setupDefaultDeviceListener()
        setupDevicesListListener()
        refreshAvailableDevices()
        startMonitoring()
    }
    
    deinit {
        stopMonitoring()
    }
    
    /// Adds a bundle identifier to the persistent ignore list and immediately stops its tap controller.
    func ignoreApp(bundleID: String) {
        ignoredBundleIDs.insert(bundleID)
        UserDefaults.standard.set(Array(ignoredBundleIDs), forKey: "VollyIgnoredBundleIDs")
        
        // Clean up and release its tap immediately
        if let index = activeApps.firstIndex(where: { $0.bundleID == bundleID }) {
            activeApps[index].stop()
            activeApps.remove(at: index)
        }
    }
    
    /// Clears the ignore list so all previously hidden/deleted apps are fully restored.
    func resetIgnoredApps() {
        ignoredBundleIDs.removeAll()
        UserDefaults.standard.removeObject(forKey: "VollyIgnoredBundleIDs")
        
        // Immediately scan and load them back
        updateActiveProcesses()
    }
    
    /// Resets all active application volumes to 1.0 and unmutes them.
    func resetAllSliders() {
        DispatchQueue.main.async {
            for controller in self.activeApps {
                controller.volume = 1.0
                controller.isMuted = false
            }
        }
    }
    
    /// Resets all application volumes, custom app names, custom hardware routes, and ignore lists back to factory defaults.
    func resetEverything() {
        print("🧹 Factory resetting Volly...")
        
        // 1. Wipe all persistent keys starting with "Volly" in UserDefaults
        let defaults = UserDefaults.standard
        let allKeys = defaults.dictionaryRepresentation().keys
        for key in allKeys {
            if key.hasPrefix("Volly") {
                defaults.removeObject(forKey: key)
            }
        }
        
        // 2. Clear state variables on the main thread
        DispatchQueue.main.async {
            self.ignoredBundleIDs.removeAll()
            
            // Revert each active app's custom settings immediately in-memory
            for controller in self.activeApps {
                controller.volume = 1.0
                controller.isMuted = false
                controller.customName = controller.name
                
                // Re-route back to default system device if customized
                if controller.outputDeviceUID != self.defaultOutputDeviceUID {
                    controller.outputDeviceUID = self.defaultOutputDeviceUID
                }
            }
            
            // 3. Immediately scan active audio-producing processes to load back any deleted apps
            self.updateActiveProcesses()
        }
    }
    
    /// Queries the current default output audio device and its UID.
    private func setupDefaultOutputDevice() {
        var outputDevice = AudioDeviceID(0)
        var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &propertySize,
            &outputDevice
        )
        
        guard status == noErr else {
            print("❌ Failed to query default output device. OSStatus \(status)")
            return
        }
        
        self.defaultOutputDeviceID = outputDevice
        
        var uidString: CFString? = nil
        var size = UInt32(MemoryLayout<CFString?>.size)
        var uidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        let err = AudioObjectGetPropertyData(outputDevice, &uidAddress, 0, nil, &size, &uidString)
        if err == noErr, let uid = uidString as String? {
            DispatchQueue.main.async {
                self.defaultOutputDeviceUID = uid
            }
            print("🔈 Default output device UID: \(uid)")
        } else {
            print("❌ Failed to resolve output device UID. OSStatus \(err)")
        }
    }
    
    /// Registers a CoreAudio property listener to detect output device hot-plugs (e.g. AirPods, USB speakers)
    private func setupDefaultDeviceListener() {
        var defaultDeviceAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        let listener: AudioObjectPropertyListenerProc = { (inObjectID, inNumberAddresses, inAddresses, inClientData) -> OSStatus in
            guard let clientData = inClientData else { return noErr }
            let engine = Unmanaged<AudioEngine>.fromOpaque(clientData).takeUnretainedValue()
            
            DispatchQueue.main.async {
                engine.handleDefaultDeviceChanged()
            }
            return noErr
        }
        
        AudioObjectAddPropertyListener(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultDeviceAddress,
            listener,
            Unmanaged.passUnretained(self).toOpaque()
        )
    }
    
    /// Registers a listener on kAudioHardwarePropertyDevices to dynamically update our dropdown menus in real-time when audio accessories are plugged in/out.
    private func setupDevicesListListener() {
        var devicesAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        let listener: AudioObjectPropertyListenerProc = { (inObjectID, inNumberAddresses, inAddresses, inClientData) -> OSStatus in
            guard let clientData = inClientData else { return noErr }
            let engine = Unmanaged<AudioEngine>.fromOpaque(clientData).takeUnretainedValue()
            
            DispatchQueue.main.async {
                engine.refreshAvailableDevices()
            }
            return noErr
        }
        
        AudioObjectAddPropertyListener(
            AudioObjectID(kAudioObjectSystemObject),
            &devicesAddress,
            listener,
            Unmanaged.passUnretained(self).toOpaque()
        )
    }
    
    /// Queries and updates the list of physical, available output devices.
    func refreshAvailableDevices() {
        let list = getOutputDevices()
        DispatchQueue.main.async {
            self.availableOutputDevices = list
        }
    }
    
    /// Handles physical output device switches gracefully by teardown of current taps and re-binding to the new physical output.
    private func handleDefaultDeviceChanged() {
        print("🔄 Default output device changed! Dynamic re-routing active...")
        
        // Save current user settings to restore them after rebuild
        var savedVolumes: [pid_t: Double] = [:]
        var savedMutes: [pid_t: Bool] = [:]
        
        for controller in activeApps {
            savedVolumes[controller.pid] = controller.volume
            savedMutes[controller.pid] = controller.isMuted
            controller.stop()
        }
        activeApps.removeAll()
        
        // Re-resolve the output device, UIDs and available output hardware devices list
        setupDefaultOutputDevice()
        refreshAvailableDevices()
        
        // Rebuild active taps immediately bound to new output device
        updateActiveProcesses(restoringVolumes: savedVolumes, mutes: savedMutes)
    }
    
    func startMonitoring() {
        guard !isMonitoring else { return }
        isMonitoring = true
        
        // Poll CoreAudio process object lists every 1.5 seconds
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.updateActiveProcesses()
        }
        
        updateActiveProcesses()
    }
    
    func stopMonitoring() {
        isMonitoring = false
        timer?.invalidate()
        timer = nil
        
        for controller in activeApps {
            controller.stop()
        }
        activeApps.removeAll()
    }
    
    /// Checks CoreAudio for any running processes actively outputting audio, registers new taps or cleans up dead processes.
    private func updateActiveProcesses(restoringVolumes: [pid_t: Double] = [:], mutes: [pid_t: Bool] = [:]) {
        guard !defaultOutputDeviceUID.isEmpty else { return }
        
        do {
            let processObjectIDs = try readProcessObjectList()
            var currentPIDs = Set<pid_t>()
            let ownPID = getpid()
            
            for procID in processObjectIDs {
                guard let pid = getPID(of: procID) else { continue }
                
                // Exclude ourselves and dead processes
                guard pid != ownPID && isProcessRunning(pid: pid) else { continue }
                
                // Try to find the user-facing parent application. If none, it's a system process - ignore it!
                guard let appInfo = getAppDetails(pid: pid) else { continue }
                
                // Exclude if this application bundle is in the user's ignored list!
                guard !ignoredBundleIDs.contains(appInfo.bundleID) else { continue }
                
                currentPIDs.insert(pid)
                
                // If this is a new audio process, start a ProcessTapController for it
                if !activeApps.contains(where: { $0.pid == pid }) {
                    let controller = ProcessTapController(
                        pid: pid,
                        name: appInfo.name,
                        bundleID: appInfo.bundleID,
                        processObjectID: procID,
                        outputDeviceUID: defaultOutputDeviceUID
                    )
                    
                    // Apply restored settings or defaults
                    controller.volume = restoringVolumes[pid] ?? 1.0
                    controller.isMuted = mutes[pid] ?? false
                    
                    activeApps.append(controller)
                }
            }
            
            // Clean up taps for applications that have stopped outputting audio or closed
            activeApps.removeAll { controller in
                let shouldRemove = !currentPIDs.contains(controller.pid)
                if shouldRemove {
                    controller.stop()
                }
                return shouldRemove
            }
            
        } catch {
            print("⚠️ Error listing active CoreAudio processes: \(error.localizedDescription)")
        }
    }
    
    /// Queries the kAudioHardwarePropertyProcessObjectList property on the system object
    private func readProcessObjectList() throws -> [AudioObjectID] {
        var listAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var listBytes: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &listAddr,
            0,
            nil,
            &listBytes
        )
        
        guard sizeStatus == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(sizeStatus), userInfo: [NSLocalizedDescriptionKey: "Error reading process list size"])
        }
        
        guard listBytes > 0 else { return [] }
        
        let count = Int(listBytes) / MemoryLayout<AudioObjectID>.stride
        var procIDs = Array(repeating: AudioObjectID(0), count: count)
        var tmpBytes = listBytes
        
        let dataStatus = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &listAddr,
            0,
            nil,
            &tmpBytes,
            &procIDs
        )
        
        guard dataStatus == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(dataStatus), userInfo: [NSLocalizedDescriptionKey: "Error reading process IDs"])
        }
        
        return procIDs
    }
    
    /// Reads the PID from a CoreAudio process object ID
    private func getPID(of processObjectID: AudioObjectID) -> pid_t? {
        var pidAddr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var pid: pid_t = 0
        var pidSize = UInt32(MemoryLayout<pid_t>.size)
        
        let err = AudioObjectGetPropertyData(processObjectID, &pidAddr, 0, nil, &pidSize, &pid)
        guard err == noErr else { return nil }
        return pid
    }
    
    private func isProcessRunning(pid: pid_t) -> Bool {
        if let app = NSRunningApplication(processIdentifier: pid) {
            return !app.isTerminated
        }
        return kill(pid, 0) == 0
    }
    
    /// Traces up the parent process tree using BSD sysctl to find the user-facing parent application.
    /// This resolves helper processes (like Safari's WebContent or Chrome Helper renderers) to their user-facing parent application.
    private func findUserFacingApp(for pid: pid_t) -> NSRunningApplication? {
        var currentPID = pid
        var visitedPIDs = Set<pid_t>()
        
        while currentPID > 1 && !visitedPIDs.contains(currentPID) {
            visitedPIDs.insert(currentPID)
            
            if let app = NSRunningApplication(processIdentifier: currentPID) {
                // If it is a user-facing regular application or a menu bar accessory app
                if app.activationPolicy == .regular || app.activationPolicy == .accessory {
                    return app
                }
            }
            
            // Resolve parent PID
            guard let parentPID = getParentPID(of: currentPID) else { break }
            currentPID = parentPID
        }
        
        return nil
    }
    
    /// Queries the BSD sysctl interface to get the parent process ID of a given PID.
    private func getParentPID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var length = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, Int32(pid)]
        
        let status = sysctl(&mib, 4, &info, &length, nil, 0)
        guard status >= 0 && length > 0 else { return nil }
        
        return pid_t(info.kp_eproc.e_ppid)
    }
    
    private func getAppDetails(pid: pid_t) -> (name: String, bundleID: String)? {
        if let app = findUserFacingApp(for: pid) {
            let name = app.localizedName ?? "Unknown Application"
            let bundleID = app.bundleIdentifier ?? "com.volly.app.\(pid)"
            return (name, bundleID)
        }
        return nil
    }
    
    /// Performs direct query to CoreAudio to pull down names and UIDs of all active physical output channels.
    private func getOutputDevices() -> [AudioDevice] {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var devicesBufferSize: UInt32 = 0
        let status1 = AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &devicesBufferSize)
        guard status1 == noErr && devicesBufferSize > 0 else { return [] }
        
        let devicesCount = Int(devicesBufferSize) / MemoryLayout<AudioDeviceID>.stride
        var deviceIDs = [AudioDeviceID](repeating: 0, count: devicesCount)
        var tempSize = devicesBufferSize
        let status2 = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &tempSize, &deviceIDs)
        guard status2 == noErr else { return [] }
        
        var outputDevices: [AudioDevice] = []
        
        for deviceID in deviceIDs {
            // Check if device has output streams
            var streamsBufferSize: UInt32 = 0
            var streamsAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            let streamsStatus = AudioObjectGetPropertyDataSize(deviceID, &streamsAddress, 0, nil, &streamsBufferSize)
            guard streamsStatus == noErr && streamsBufferSize > 0 else { continue }
            
            // Get device name
            var nameAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceNameCFString,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var nameCF: CFString? = nil
            var nameSize = UInt32(MemoryLayout<CFString?>.size)
            let nameStatus = AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &nameSize, &nameCF)
            let name = (nameStatus == noErr && nameCF != nil) ? (nameCF! as String) : "Unknown Device"
            
            // Get device UID
            var uidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var uidCF: CFString? = nil
            var uidSize = UInt32(MemoryLayout<CFString?>.size)
            let uidStatus = AudioObjectGetPropertyData(deviceID, &uidAddress, 0, nil, &uidSize, &uidCF)
            guard uidStatus == noErr, let uid = uidCF as String? else { continue }
            
            // Ignore private virtual aggregates created by Volly to avoid infinite recursive lists
            if uid.contains("com.volly") { continue }
            
            outputDevices.append(AudioDevice(id: deviceID, name: name, uid: uid))
        }
        
        return outputDevices
    }
}
