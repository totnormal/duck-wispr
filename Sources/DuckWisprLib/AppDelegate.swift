import AppKit

public class AppDelegate: NSObject, NSApplicationDelegate {
    var statusBar: StatusBarController!
    var hotkeyManager: HotkeyManager?
    var recorder: AudioRecorder!
    var transcriber: Transcriber!
    var inserter: TextInserter!
    var config: Config!
    var isPressed = false
    var isReady = false
    public var lastTranscription: String?
    private var lastTranscriptionTimestamp: Date?
    var mediaManager: MediaManager?
    private var accessibilityTimer: Timer?

    public func applicationDidFinishLaunching(_ notification: Notification) {
        statusBar = StatusBarController()
        recorder = AudioRecorder()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.setup()
        }
    }

    private func setup() {
        // Check first-run before setup
        let firstRunFile = Config.configDir.appendingPathComponent(".first-run-done")
        isFirstRun = !FileManager.default.fileExists(atPath: firstRunFile.path)

        do {
            try setupInner()
        } catch {
            let msg = error.localizedDescription
            print("Fatal setup error: \(msg)")
            DispatchQueue.main.async { [weak self] in
                self?.statusBar.state = .error(msg)
                self?.statusBar.buildMenu()
            }
        }
    }

    private var isFirstRun = false

    private func setupInner() throws {
        config = Config.load()
        inserter = TextInserter()
        recorder.preferredDeviceID = config.audioInputDeviceID
        if Config.effectiveMaxRecordings(config.maxRecordings) == 0 {
            RecordingStore.deleteAllRecordings()
        }
        transcriber = Transcriber(modelSize: config.modelSize, language: config.language)

        DispatchQueue.main.async {
            self.statusBar.reprocessHandler = { [weak self] url in
                self?.reprocess(audioURL: url)
            }
            self.statusBar.onConfigChange = { [weak self] newConfig in
                self?.applyConfigChange(newConfig)
            }
            self.statusBar.buildMenu()
        }

        // Verify whisper-cli binary loads correctly and model is ready
        let verifyResult = Verifier.verify(
            modelSize: config.modelSize,
            attemptAutoFix: Verifier.attemptAutoFix
        )
        if !verifyResult.isReady {
            let msgs = verifyResult.issues.filter { $0.isFatal }.map { $0.message }
            let msg = msgs.joined(separator: "; ")
            print("Error: \(msg)")
            DispatchQueue.main.async {
                self.statusBar.state = .error(msg)
                self.statusBar.buildMenu()
            }
            return
        }
        for issue in verifyResult.issues where !issue.isFatal && issue.autoFixAttempted {
            print("Verifier: \(issue.message)")
        }

        // Track version and binary path for diagnostics (no tccutil reset)
        // Previous code called tccutil reset on path change, which removed permissions
        // the user had just granted via System Settings — causing the stuck lock icon.
        // macOS already invalidates TCC entries when the code signature changes on reinstall.
        if Permissions.didUpgrade() {
            let pathChanged = Permissions.didBinaryPathChange()
            if pathChanged {
                print("Accessibility: binary path changed on upgrade — permissions may need re-granting")
            } else {
                print("Accessibility: upgrade detected, path unchanged")
            }
        }

        Permissions.ensureMicrophone()

        if AXIsProcessTrusted() {
            print("Accessibility: granted")
            finishSetup()
        } else {
            print("Accessibility: not granted — entering non-blocking wait")
            DispatchQueue.main.async {
                self.statusBar.state = .waitingForPermission
                self.statusBar.recheckPermissionHandler = { [weak self] in
                    self?.triggerAccessibilityRecheck()
                }
                self.statusBar.buildMenu()

                // Show the native macOS accessibility prompt
                // (more reliable than manually opening System Settings on Sequoia)
                Permissions.promptAccessibility()

                // Also open System Settings as a fallback for users who miss the system dialog
                Permissions.openAccessibilitySettings()

                // Start timer-based polling (main thread, 1s interval)
                // This replaces the old blocking busy-wait that ran on a background thread
                // and could miss grants due to TCC cache staleness.
                self.accessibilityTimer = Permissions.startAccessibilityPolling { [weak self] in
                    self?.onAccessibilityGranted()
                }
            }
        }
    }

    // MARK: - Accessibility permission recovery

    /// Called by the accessibility poll timer when permission is detected.
    private func onAccessibilityGranted() {
        accessibilityTimer?.invalidate()
        accessibilityTimer = nil
        statusBar.recheckPermissionHandler = nil
        finishSetup()
    }

    /// Called when user clicks "Recheck Permission" in the menu.
    private func triggerAccessibilityRecheck() {
        if AXIsProcessTrusted() {
            onAccessibilityGranted()
        } else {
            // Re-trigger the native prompt in case the user missed it
            Permissions.promptAccessibility()
        }
    }

    /// Continues setup after accessibility is granted.
    /// Extracted from setupInner() so it can be called either immediately
    /// (if already trusted) or deferred (after permission grant).
    private func finishSetup() {
        // This runs on main thread (called from timer callback or recheck)
        // Switch to background for the remaining heavy setup
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            do {
                try self.finishSetupInner()
            } catch {
                let msg = error.localizedDescription
                print("Setup error after permission grant: \(msg)")
                DispatchQueue.main.async {
                    self.statusBar.state = .error(msg)
                    self.statusBar.buildMenu()
                }
            }
        }
    }

    private func finishSetupInner() throws {
        if !Transcriber.modelExists(modelSize: config.modelSize) {
            DispatchQueue.main.async {
                self.statusBar.state = .downloading
                self.statusBar.updateDownloadProgress("Downloading \(self.config.modelSize) model...")
            }
            print("Downloading \(config.modelSize) model...")
            try ModelDownloader.download(modelSize: config.modelSize) { [weak self] percent in
                DispatchQueue.main.async {
                    let pct = Int(percent)
                    self?.statusBar.updateDownloadProgress("Downloading \(self?.config.modelSize ?? "") model... \(pct)%", percent: percent)
                }
            }
            DispatchQueue.main.async {
                self.statusBar.updateDownloadProgress(nil)
            }
            Transcriber.deleteOtherModels(keeping: config.modelSize)
        }

        installLaunchAgentIfNeeded()

        if let modelPath = Transcriber.findModel(modelSize: config.modelSize) {
            let modelURL = URL(fileURLWithPath: modelPath)
            if !ModelDownloader.isValidGGMLFile(at: modelURL) {
                let msg = "Model file is corrupted. Re-download with: duck-wispr download-model \(config.modelSize)"
                print("Error: \(msg)")
                DispatchQueue.main.async {
                    self.statusBar.state = .error(msg)
                    self.statusBar.buildMenu()
                }
                return
            }
        }
        Transcriber.deleteOtherModels(keeping: config.modelSize)

        DispatchQueue.main.async { [weak self] in
            self?.startListening()
        }
    }

    private func startListening() {
        hotkeyManager = HotkeyManager(
            keyCode: config.hotkey.keyCode,
            modifiers: config.hotkey.modifierFlags
        )

        hotkeyManager?.start(
            onKeyDown: { [weak self] in
                self?.handleKeyDown()
            },
            onKeyUp: { [weak self] in
                self?.handleKeyUp()
            }
        )

        isReady = true
        statusBar.state = .idle
        statusBar.buildMenu()

        let hotkeyDesc = KeyCodes.describe(keyCode: config.hotkey.keyCode, modifiers: config.hotkey.modifiers)
        print("duck-wispr v\(DuckWispr.version)")
        print("Hotkey: \(hotkeyDesc)")
        print("Model: \(config.modelSize)")
        print("Ready.")

        if isFirstRun {
            showOnboarding()
        }
    }

    private func showOnboarding() {
        // Mark first run done so we don't onboard again
        let firstRunFile = Config.configDir.appendingPathComponent(".first-run-done")
        try? "done".write(to: firstRunFile, atomically: true, encoding: .utf8)

        // Show a small floating window pointing to the menu bar
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 160),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "DuckWispr"
        window.center()
        window.level = .floating

        let view = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 160))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        let icon = NSImageView(frame: NSRect(x: 20, y: 80, width: 48, height: 48))
        icon.image = NSImage(named: "AppIcon") ?? NSImage(named: NSImage.applicationIconName)
        icon.imageScaling = .scaleProportionallyUpOrDown
        view.addSubview(icon)

        let title = NSTextField(frame: NSRect(x: 80, y: 110, width: 280, height: 24))
        title.stringValue = "DuckWispr is ready!"
        title.font = NSFont.boldSystemFont(ofSize: 16)
        title.isBezeled = false
        title.isEditable = false
        title.drawsBackground = false
        view.addSubview(title)

        let desc = NSTextField(frame: NSRect(x: 80, y: 55, width: 280, height: 48))
        let hotkeyDesc = KeyCodes.describe(keyCode: config.hotkey.keyCode, modifiers: config.hotkey.modifiers)
        desc.stringValue = "Look for the 🦆 icon in your menu bar.\nHold \(hotkeyDesc), speak, release — dictation appears."
        desc.font = NSFont.systemFont(ofSize: 12)
        desc.isBezeled = false
        desc.isEditable = false
        desc.drawsBackground = false
        desc.lineBreakMode = .byWordWrapping
        view.addSubview(desc)

        let btn = NSButton(frame: NSRect(x: 80, y: 15, width: 140, height: 28))
        btn.title = "Got it"
        btn.bezelStyle = .rounded
        btn.keyEquivalent = "\r"
        btn.target = self
        btn.action = #selector(dismissOnboarding)
        view.addSubview(btn)

        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Auto-dismiss after 8 seconds
        onboardingWindow = window
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            self?.dismissOnboarding()
        }
    }

    @objc private func dismissOnboarding() {
        onboardingWindow?.close()
        onboardingWindow = nil
    }

    private var onboardingWindow: NSWindow?

    public func reloadConfig() {
        let newConfig = Config.load()
        applyConfigChange(newConfig)
    }

    func applyConfigChange(_ newConfig: Config) {
        guard isReady else { return }
        let wasDownloading: Bool
        if case .downloading = statusBar.state { wasDownloading = true } else { wasDownloading = false }
        let deviceChanged = recorder.preferredDeviceID != newConfig.audioInputDeviceID
        let oldModelSize = config.modelSize
        let oldLanguage = config.language
        config = newConfig
        recorder.preferredDeviceID = config.audioInputDeviceID
        if deviceChanged {
            recorder.reload()
        }
        transcriber = Transcriber(modelSize: config.modelSize, language: config.language)
        inserter = TextInserter()

        hotkeyManager?.stop()
        hotkeyManager = HotkeyManager(
            keyCode: config.hotkey.keyCode,
            modifiers: config.hotkey.modifierFlags
        )
        hotkeyManager?.start(
            onKeyDown: { [weak self] in self?.handleKeyDown() },
            onKeyUp: { [weak self] in self?.handleKeyUp() }
        )

        if !wasDownloading && !Transcriber.modelExists(modelSize: config.modelSize) {
            statusBar.state = .downloading
            statusBar.updateDownloadProgress("Downloading \(config.modelSize) model...")
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                do {
                    try ModelDownloader.download(modelSize: newConfig.modelSize) { percent in
                        DispatchQueue.main.async {
                            let pct = Int(percent)
                            self?.statusBar.updateDownloadProgress("Downloading \(newConfig.modelSize) model... \(pct)%", percent: percent)
                        }
                    }
                    DispatchQueue.main.async {
                        self?.statusBar.state = .idle
                        self?.statusBar.updateDownloadProgress(nil)
                        Transcriber.deleteOtherModels(keeping: newConfig.modelSize)
                    }
                } catch {
                    DispatchQueue.main.async {
                        print("Error downloading model: \(error.localizedDescription)")
                        // Revert to the old model that we know works
                        self?.config.modelSize = oldModelSize
                        self?.config.language = oldLanguage
                        try? self?.config.save()
                        self?.transcriber = Transcriber(modelSize: oldModelSize, language: oldLanguage)
                        self?.statusBar.state = .error("Failed to download \(newConfig.modelSize) — reverted to \(oldModelSize)")
                        self?.statusBar.updateDownloadProgress(nil)
                        self?.statusBar.buildMenu()
                    }
                }
            }
        } else if oldModelSize != config.modelSize {
            Transcriber.deleteOtherModels(keeping: config.modelSize)
        }

        statusBar.buildMenu()

        let hotkeyDesc = KeyCodes.describe(keyCode: config.hotkey.keyCode, modifiers: config.hotkey.modifiers)
        print("Config updated: lang=\(config.language) model=\(config.modelSize) hotkey=\(hotkeyDesc)")
    }

    private func handleKeyDown() {
        guard isReady else { return }

        let isToggle = config.toggleMode?.value ?? false

        if isToggle {
            if isPressed {
                handleRecordingStop()
            } else {
                handleRecordingStart()
            }
        } else {
            guard !isPressed else { return }
            handleRecordingStart()
        }
    }

    private func handleKeyUp() {
        let isToggle = config.toggleMode?.value ?? false
        if isToggle { return }

        handleRecordingStop()
    }

    private func handleRecordingStart() {
        guard !isPressed else { return }
        isPressed = true

        // Pause/duck media if configured
        if config.pauseMediaWhileRecording?.value == true {
            mediaManager = MediaManager()
            let strategy: MediaManager.PauseStrategy = (config.mediaStrategy == "duck") ? .duck : .pause
            mediaManager?.pauseMedia(strategy: strategy)
        }

        statusBar.state = .recording
        do {
            let outputURL: URL
            if Config.effectiveMaxRecordings(config.maxRecordings) == 0 {
                outputURL = RecordingStore.tempRecordingURL()
            } else {
                outputURL = RecordingStore.newRecordingURL()
            }
            try recorder.startRecording(to: outputURL)
        } catch {
            print("Error: \(error.localizedDescription)")
            isPressed = false
            statusBar.state = .idle
        }
    }

    private func handleRecordingStop() {
        guard isPressed else { return }
        isPressed = false

        // Resume media if we paused/ducked it
        if let mm = mediaManager {
            let strategy: MediaManager.PauseStrategy = (config.mediaStrategy == "duck") ? .duck : .pause
            mm.resumeMedia(strategy: strategy)
            mediaManager = nil
        }

        guard let audioURL = recorder.stopRecording() else {
            statusBar.state = .idle
            return
        }

        statusBar.state = .transcribing

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let maxRecordings = Config.effectiveMaxRecordings(self.config.maxRecordings)
            defer {
                if maxRecordings == 0 {
                    try? FileManager.default.removeItem(at: audioURL)
                }
            }

#if DEBUG
            // Debug: check audio file size
            let fileSize = (try? FileManager.default.attributesOfItem(atPath: audioURL.path)[.size] as? Int64) ?? 0
            print("audio file: \(audioURL.path) (\(fileSize) bytes)")
#endif

            do {
                // Only use last transcription as prompt if recent (<30s); stale prompts bias the decoder
                let prompt: String? = {
                    if let ts = self.lastTranscriptionTimestamp, Date().timeIntervalSince(ts) < 30 {
                        return self.lastTranscription
                    }
                    return nil
                }()
                let raw = try self.transcriber.transcribe(audioURL: audioURL, prompt: Transcriber.sanitizedPrompt(prompt))
#if DEBUG
                print("whisper raw (\(raw.count) chars): '\(raw)'")
#endif
                let mode = self.config.proofreadingMode ?? .standard
                let text = mode == .standard
                    ? TextPostProcessor.process(raw, language: self.config.language)
                    : raw
#if DEBUG
                print("post-processed (\(text.count) chars): '\(text)'")
#endif
                if maxRecordings > 0 {
                    RecordingStore.prune(maxCount: maxRecordings)
                }
                DispatchQueue.main.async {
                    if !text.isEmpty {
#if DEBUG
                        print("inserting text: '\(text)'")
#endif
                        self.inserter.insert(text: text)
                        self.lastTranscription = text
                        self.lastTranscriptionTimestamp = Date()
                    } else {
                        print("text empty — nothing to insert")
                        self.lastTranscription = nil
                        self.lastTranscriptionTimestamp = nil
                    }
                    self.statusBar.state = .idle
                    self.statusBar.buildMenu()
                }
            } catch {
                if maxRecordings > 0 {
                    RecordingStore.prune(maxCount: maxRecordings)
                }
                self.lastTranscription = nil
                self.lastTranscriptionTimestamp = nil
                DispatchQueue.main.async {
                    print("Error: \(error.localizedDescription)")
                    self.statusBar.state = .error(error.localizedDescription)
                    self.statusBar.buildMenu()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                        if case .error = self.statusBar.state {
                            self.statusBar.state = .idle
                            self.statusBar.buildMenu()
                        }
                    }
                }
            }
        }
    }

    public func reprocess(audioURL: URL) {
        guard case .idle = statusBar.state else { return }

        statusBar.state = .transcribing

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            do {
                // Apply same prompt cooldown as main transcription path
                let prompt: String? = {
                    if let ts = self.lastTranscriptionTimestamp, Date().timeIntervalSince(ts) < 30 {
                        return self.lastTranscription
                    }
                    return nil
                }()
                let raw = try self.transcriber.transcribe(audioURL: audioURL, prompt: Transcriber.sanitizedPrompt(prompt))
                let mode = self.config.proofreadingMode ?? .standard
                let text = mode == .standard
                    ? TextPostProcessor.process(raw, language: self.config.language)
                    : raw
                DispatchQueue.main.async {
                    if !text.isEmpty {
                        self.lastTranscription = text
                        self.lastTranscriptionTimestamp = Date()
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                        self.statusBar.state = .copiedToClipboard
                        self.statusBar.buildMenu()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            self.statusBar.state = .idle
                            self.statusBar.buildMenu()
                        }
                    } else {
                        self.lastTranscription = nil
                        self.lastTranscriptionTimestamp = nil
                        self.statusBar.state = .idle
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    print("Reprocess error: \(error.localizedDescription)")
                    self.statusBar.state = .idle
                }
            }
        }
    }

    // ── Launch agent (auto-start on login) ───────────────────────────

    private func installLaunchAgentIfNeeded() {
        let label = "com.duckwispr.dictation"
        let plistPath = NSHomeDirectory() + "/Library/LaunchAgents/\(label).plist"

        // Already installed — nothing to do
        guard !FileManager.default.fileExists(atPath: plistPath) else { return }

        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [Bundle.main.executablePath ?? "/Applications/DuckWispr.app/Contents/MacOS/duck-wispr", "start"],
            "RunAtLoad": true,
            "KeepAlive": false,
            "ProcessType": "Interactive",
            "StandardOutPath": NSHomeDirectory() + "/Library/Logs/duck-wispr.log",
            "StandardErrorPath": NSHomeDirectory() + "/Library/Logs/duck-wispr.log",
        ]

        guard let dir = (plistPath as NSString).deletingLastPathComponent as String?,
              FileManager.default.fileExists(atPath: dir) || ((try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)) != nil)
        else { return }

        guard let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) else { return }
        try? data.write(to: URL(fileURLWithPath: plistPath))

        // Just write the plist — do NOT call launchctl.
        // The plist will be picked up automatically on next login.
        // Calling launchctl here would start a duplicate instance (restart loop).
    }
}
