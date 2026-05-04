import Foundation
import CoreAudio
import AppKit

/// Pauses background media (Music.app, Spotify) while dictation is recording,
/// and resumes when recording stops. Falls back to system volume ducking
/// if the media apps can't be controlled.
class MediaManager {
    
    // Which strategy to use
    enum PauseStrategy: String, Codable {
        case pause       // pause/resume the media player
        case duck        // reduce system output volume
    }
    
    // Track what we paused so we only resume what we started
    private var didPauseMusic = false
    private var didPauseSpotify = false
    private var savedSystemVolume: Float? = nil
    
    /// Called when recording starts. Pauses media or ducks volume.
    func pauseMedia(strategy: PauseStrategy) {
        switch strategy {
        case .pause:
            pausePlayers()
        case .duck:
            duckVolume()
        }
    }
    
    /// Called when recording stops. Restores media or volume.
    func resumeMedia(strategy: PauseStrategy) {
        switch strategy {
        case .pause:
            resumePlayers()
        case .duck:
            restoreVolume()
        }
    }
    
    // MARK: - Pause/Resume strategy
    
    private func pausePlayers() {
        didPauseMusic = false
        didPauseSpotify = false
        
        // Try Music.app (macOS native)
        if isMusicPlaying(app: "Music") {
            if runAppleScript("tell application \"Music\" to pause") {
                didPauseMusic = true
                print("MediaManager: paused Music.app")
            }
        }
        
        // Try Spotify
        if isMusicPlaying(app: "Spotify") {
            if runAppleScript("tell application \"Spotify\" to pause") {
                didPauseSpotify = true
                print("MediaManager: paused Spotify")
            }
        }
    }
    
    private func resumePlayers() {
        if didPauseMusic {
            if runAppleScript("tell application \"Music\" to play") {
                print("MediaManager: resumed Music.app")
            }
            didPauseMusic = false
        }
        
        if didPauseSpotify {
            if runAppleScript("tell application \"Spotify\" to play") {
                print("MediaManager: resumed Spotify")
            }
            didPauseSpotify = false
        }
    }
    
    // MARK: - Volume ducking strategy
    
    private func duckVolume() {
        let defaultOutputID = getDefaultOutputDeviceID()
        guard defaultOutputID != 0 else { return }
        
        savedSystemVolume = getDeviceVolume(deviceID: defaultOutputID)
        guard let current = savedSystemVolume, current > 0.05 else {
            // Already silent or muted — nothing to duck
            savedSystemVolume = nil
            return
        }
        
        // Duck to ~10% of current volume
        let duckedVolume = max(0.03, current * 0.1)
        setDeviceVolume(deviceID: defaultOutputID, volume: duckedVolume)
        print("MediaManager: ducked volume from \(String(format: "%.2f", current)) to \(String(format: "%.2f", duckedVolume))")
    }
    
    private func restoreVolume() {
        guard let saved = savedSystemVolume else { return }
        let defaultOutputID = getDefaultOutputDeviceID()
        guard defaultOutputID != 0 else { return }
        
        setDeviceVolume(deviceID: defaultOutputID, volume: saved)
        print("MediaManager: restored volume to \(String(format: "%.2f", saved))")
        savedSystemVolume = nil
    }
    
    // MARK: - AppleScript helpers
    
    @discardableResult
    private func runAppleScript(_ source: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        
        let pipe = Pipe()
        process.standardError = pipe
        
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            print("MediaManager: AppleScript error: \(error.localizedDescription)")
            return false
        }
    }
    
    private func isMusicPlaying(app: String) -> Bool {
        // Check if the app is running first
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: app == "Music" ? "com.apple.Music" : "com.spotify.client")
        guard !running.isEmpty else { return false }
        
        // Check player state
        let script = "tell application \"\(app)\" to get player state"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return false }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return output == "playing"
        } catch {
            return false
        }
    }
    
    // MARK: - CoreAudio helpers
    
    private func getDefaultOutputDeviceID() -> AudioDeviceID {
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        guard status == noErr else {
            print("MediaManager: failed to get default output device (\(status))")
            return 0
        }
        return deviceID
    }
    
    private func getDeviceVolume(deviceID: AudioDeviceID) -> Float {
        var volume: Float = 0
        var size = UInt32(MemoryLayout<Float>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        
        // Check if the device supports volume control on the main element
        var isSettable: DarwinBoolean = false
        let setStatus = AudioObjectIsPropertySettable(deviceID, &address, &isSettable)
        guard setStatus == noErr && isSettable.boolValue else {
            // Try stereo pan/volume per channel (some devices only support per-channel)
            return getDeviceVolumeStereo(deviceID: deviceID)
        }
        
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &volume)
        guard status == noErr else {
            return getDeviceVolumeStereo(deviceID: deviceID)
        }
        return volume
    }
    
    private func getDeviceVolumeStereo(deviceID: AudioDeviceID) -> Float {
        // Average left + right channel volumes
        let defaultVolume: Float = 0
        var size = UInt32(MemoryLayout<Float>.size)
        var leftAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: 1
        )
        var rightAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: 2
        )
        
        var leftVol: Float = 0
        var rightVol: Float = 0
        
        if AudioObjectGetPropertyData(deviceID, &leftAddr, 0, nil, &size, &leftVol) == noErr,
           AudioObjectGetPropertyData(deviceID, &rightAddr, 0, nil, &size, &rightVol) == noErr {
            return (leftVol + rightVol) / 2.0
        }
        
        return defaultVolume
    }
    
    private func setDeviceVolume(deviceID: AudioDeviceID, volume: Float) {
        let size = UInt32(MemoryLayout<Float>.size)
        
        // Try main element first
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var isSettable: DarwinBoolean = false
        if AudioObjectIsPropertySettable(deviceID, &address, &isSettable) == noErr && isSettable.boolValue {
            var vol = volume
            let status = AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &vol)
            if status == noErr { return }
        }
        
        // Fallback: set per-channel
        for element: UInt32 in [1, 2] {
            var elemAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: element
            )
            if AudioObjectIsPropertySettable(deviceID, &elemAddr, &isSettable) == noErr && isSettable.boolValue {
                var vol = volume
                AudioObjectSetPropertyData(deviceID, &elemAddr, 0, nil, size, &vol)
            }
        }
    }
}
