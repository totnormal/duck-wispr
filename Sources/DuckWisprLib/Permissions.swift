import AppKit
import AVFoundation
import ApplicationServices
import Foundation

struct Permissions {
    static func ensureMicrophone() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            print("Microphone: granted")
        case .notDetermined:
            print("Microphone: requesting...")
            let semaphore = DispatchSemaphore(value: 0)
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                print("Microphone: \(granted ? "granted" : "denied")")
                semaphore.signal()
            }
            semaphore.wait()
        default:
            print("Microphone: denied — grant in System Settings → Privacy & Security → Microphone")
        }
    }

    /// Opens the macOS accessibility permission dialog using the native API.
    /// This is more reliable than manually opening System Settings,
    /// especially on macOS Sequoia where AXIsProcessTrusted() caching
    /// can cause the poll loop to miss grants.
    static func promptAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - Timer-based accessibility polling

    /// Polls AXIsProcessTrusted() on the main thread every second.
    /// Calls `onGranted` once when permission is detected, then stops.
    /// Returns the timer so the caller can invalidate it if needed.
    @discardableResult
    static func startAccessibilityPolling(onGranted: @escaping () -> Void) -> Timer {
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { timer in
            if AXIsProcessTrusted() {
                timer.invalidate()
                print("Accessibility: granted (detected by poll)")
                onGranted()
            }
        }
        // Fire immediately to check current state
        timer.fire()
        return timer
    }

    // MARK: - Version & path tracking

    static func didUpgrade() -> Bool {
        let configDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/duck-wispr")
        let versionFile = configDir.appendingPathComponent(".last-version")
        let current = DuckWispr.version
        let previous = try? String(contentsOf: versionFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if previous == current {
            return false
        }

        try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        try? current.write(to: versionFile, atomically: true, encoding: .utf8)
        return true
    }

    /// Records the current binary path. Returns true if it changed since last launch.
    /// Used to decide whether to show a heads-up about needing to re-grant accessibility.
    static func didBinaryPathChange() -> Bool {
        let configDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/duck-wispr")
        let pathFile = configDir.appendingPathComponent(".last-binary-path")
        let currentPath = Bundle.main.bundlePath
        let previousPath = try? String(contentsOf: pathFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let changed = previousPath != nil && previousPath != currentPath
        try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        try? currentPath.write(to: pathFile, atomically: true, encoding: .utf8)
        return changed
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
