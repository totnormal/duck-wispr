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

        if Transcriber.findWhisperBinary() == nil {
            print("Error: whisper-cpp not found. Install it with: brew install whisper-cpp")
            return
        }

        // Only reset accessibility on upgrade if the binary path changed
        // (e.g., moving from ~/Applications to /Applications)
        if Permissions.didUpgrade() {
            if Permissions.requiresAccessibilityReset() {
                print("Accessibility: path change detected, resetting permissions...")
                Permissions.resetAccessibility()
                Thread.sleep(forTimeInterval: 1)
            } else {
                print("Accessibility: upgrade detected but path unchanged, keeping permissions")
            }
        }

        if !AXIsProcessTrusted() {
            DispatchQueue.main.async {
                self.statusBar.state = .waitingForPermission
                self.statusBar.buildMenu()
            }
        }

        Permissions.ensureMicrophone()

        if !AXIsProcessTrusted() {
            print("Accessibility: not granted")

            // Show a clear dialog explaining what the user needs to do
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "Accessibility Access Required"
                alert.informativeText = "OpenWispr needs Accessibility access to paste transcribed text into other apps.\n\nIn the System Settings window that opens:\n1. Find OpenWispr in the list\n2. Toggle the switch ON\n3. You may need to unlock the padlock first"
                alert.alertStyle = .informational
                alert.addButton(withTitle: "Open Settings")
                alert.runModal()
                Permissions.openAccessibilitySettings()
            }

            print("Waiting for Accessibility permission...")
            let deadline = Date().addingTimeInterval(60)
            while !AXIsProcessTrusted() {
                if Date() > deadline {
                    let msg = "Accessibility permission not granted within 60s. Grant it in System Settings → Privacy & Security → Accessibility, then restart OpenWispr."
                    print("Error: \(msg)")
                    DispatchQueue.main.async {
                        self.statusBar.state = .error(msg)
                        self.statusBar.buildMenu()
                    }
                    return
                }
                Thread.sleep(forTimeInterval: 0.5)
            }
            print("Accessibility: granted")
        } else {
            print("Accessibility: granted")
        }

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
                let msg = "Model file is corrupted. Re-download with: open-wispr download-model \(config.modelSize)"
                print("Error: \(msg)")
                DispatchQueue.main.async {
                    self.statusBar.state = .error(msg)
                    self.statusBar.buildMenu()
                }
                return
            }
        }
        Transcriber.deleteOtherModels(keeping: config.modelSize)

        // NOTE: recorder is NOT prewarmed here.
        // The audio engine is started on first key press (about 600ms delay).
        // This prevents the orange mic indicator from appearing at all times,
        // which feels like the app is "spying" when it's just idle.

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
        print("open-wispr v\(OpenWispr.version)")
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
        window.title = "OpenWispr"
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
        title.stringValue = "OpenWispr is ready!"
        title.font = NSFont.boldSystemFont(ofSize: 16)
        title.isBezeled = false
        title.isEditable = false
        title.drawsBackground = false
        view.addSubview(title)

        let desc = NSTextField(frame: NSRect(x: 80, y: 55, width: 280, height: 48))
        let hotkeyDesc = KeyCodes.describe(keyCode: config.hotkey.keyCode, modifiers: config.hotkey.modifiers)
        desc.stringValue = "Look for the 🌊 icon in your menu bar.\nHold \(hotkeyDesc), speak, release — dictation appears."
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

            // Debug: check audio file size
            let fileSize = (try? FileManager.default.attributesOfItem(atPath: audioURL.path)[.size] as? Int64) ?? 0
            print("audio file: \(audioURL.path) (\(fileSize) bytes)")

            do {
                let raw = try self.transcriber.transcribe(audioURL: audioURL, prompt: Transcriber.sanitizedPrompt(self.lastTranscription))
                print("whisper raw (\(raw.count) chars): '\(raw)'")
                let mode = self.config.proofreadingMode ?? .standard
                let text = mode == .standard
                    ? TextPostProcessor.process(raw, language: self.config.language)
                    : raw
                print("post-processed (\(text.count) chars): '\(text)'")
                if maxRecordings > 0 {
                    RecordingStore.prune(maxCount: maxRecordings)
                }
                DispatchQueue.main.async {
                    if !text.isEmpty {
                        print("inserting text: '\(text)'")
                        self.inserter.insert(text: text)
                        self.lastTranscription = text
                    } else {
                        print("text empty — nothing to insert")
                        self.lastTranscription = nil
                    }
                    self.statusBar.state = .idle
                    self.statusBar.buildMenu()
                }
            } catch {
                if maxRecordings > 0 {
                    RecordingStore.prune(maxCount: maxRecordings)
                }
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
                let raw = try self.transcriber.transcribe(audioURL: audioURL, prompt: Transcriber.sanitizedPrompt(self.lastTranscription))
                let mode = self.config.proofreadingMode ?? .standard
                let text = mode == .standard
                    ? TextPostProcessor.process(raw, language: self.config.language)
                    : raw
                DispatchQueue.main.async {
                    if !text.isEmpty {
                        self.lastTranscription = text
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
        let label = "com.openwispr.dictation"
        let plistPath = NSHomeDirectory() + "/Library/LaunchAgents/\(label).plist"

        // Already installed — nothing to do
        guard !FileManager.default.fileExists(atPath: plistPath) else { return }

        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [Bundle.main.executablePath ?? "/Applications/OpenWispr.app/Contents/MacOS/open-wispr", "start"],
            "RunAtLoad": true,
            "KeepAlive": false,
            "ProcessType": "Interactive",
            "StandardOutPath": NSHomeDirectory() + "/Library/Logs/open-wispr.log",
            "StandardErrorPath": NSHomeDirectory() + "/Library/Logs/open-wispr.log",
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
