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

    // MARK: - Single-instance enforcement

    /// Kills any other running DuckWispr process (by bundle ID or binary name).
    /// Called at launch to prevent stale old-version processes from running
    /// alongside the new version — which causes permission state confusion.
    @discardableResult
    static func killStaleInstances() -> Bool {
        let myPID = ProcessInfo.processInfo.processIdentifier
        let bundleID = Bundle.main.bundleIdentifier ?? "com.human37.duck-wispr"
        let binaryName = "duck-wispr"

        var killed = false

        // Method 1: NSWorkspace running apps (finds .app bundle processes)
        let runningApps = NSWorkspace.shared.runningApplications
        for app in runningApps {
            guard app.bundleIdentifier == bundleID,
                  app.processIdentifier != myPID,
                  app.processIdentifier > 0 else { continue }
            print("Single-instance: killing stale process PID \(app.processIdentifier)")
            app.terminate()
            killed = true
        }

        // Method 2: pgrep for bare binary name (finds CLI/launch-agent runs)
        let pgrep = Process()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-x", binaryName]
        let pipe = Pipe()
        pgrep.standardOutput = pipe
        try? pgrep.run()
        pgrep.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        for line in output.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n") {
            guard let pid = pid_t(line.trimmingCharacters(in: .whitespacesAndNewlines)),
                  pid != myPID, pid > 0 else { continue }
            print("Single-instance: killing stale CLI process PID \(pid)")
            kill(pid, SIGTERM)
            killed = true
        }

        if killed {
            // Give processes time to clean up
            Thread.sleep(forTimeInterval: 0.5)
        }
        return killed
    }

    /// Verifies accessibility is actually usable by attempting a real API call.
    /// AXIsProcessTrusted() can return true on macOS Sequoia even when the
    /// permission isn't effective in the current process until relaunch.
    static func isAccessibilityActuallyUsable() -> Bool {
        // If AXIsProcessTrusted() itself is false, no point checking further
        guard AXIsProcessTrusted() else { return false }

        // Try to create a real AXUIElement — this will fail silently
        // if the TCC grant hasn't propagated to the current process.
        // We verify by checking if we can list the system-wide AX element.
        let systemWide = AXUIElementCreateSystemWide()
        var focusedApp: AnyObject?
        let err = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedApplicationAttribute as CFString,
            &focusedApp
        )
        // .success or .apiDisabled (no focused app but AX is enabled) = AX is working
        // .cannotComplete or .notImplemented = TCC grant not effective yet
        return err == .success || err == .apiDisabled
    }

    /// Relaunches the app by opening the bundle (or binary) and terminating.
    static func relaunchApp() {
        let bundlePath = Bundle.main.bundlePath
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [bundlePath]
        try? process.run()

        // Give open a moment to register, then exit
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NSApplication.shared.terminate(nil)
        }
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
