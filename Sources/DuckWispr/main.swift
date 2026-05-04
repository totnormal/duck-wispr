import AppKit
import Foundation
import DuckWisprLib

setvbuf(stdout, nil, _IOLBF, 0)
setvbuf(stderr, nil, _IOLBF, 0)

let version = DuckWispr.version

func printUsage() {
    print("""
    duck-wispr v\(version) — Push-to-talk voice dictation for macOS

    USAGE:
        duck-wispr start              Start the dictation daemon
        duck-wispr set-hotkey <key>   Set the push-to-talk hotkey
        duck-wispr get-hotkey         Show current hotkey
        duck-wispr set-model <size>   Set the Whisper model
        duck-wispr set-language <code>  Set the language (e.g. en, fr, auto)
        duck-wispr download-model [size]  Download a Whisper model
        duck-wispr status             Show configuration and status
        duck-wispr --help             Show this help message

    HOTKEY EXAMPLES:
        duck-wispr set-hotkey globe             Globe/fn key (default)
        duck-wispr set-hotkey rightoption        Right Option key
        duck-wispr set-hotkey f5                 F5 key
        duck-wispr set-hotkey ctrl+space         Ctrl + Space

    AVAILABLE MODELS:
        \(Config.supportedModels.joined(separator: ", "))
    """)
}

func cmdStart() {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    let delegate = AppDelegate()
    app.delegate = delegate

    signal(SIGINT) { _ in
        print("\nStopping duck-wispr...")
        exit(0)
    }

    app.run()
}

func cmdSetHotkey(_ keyString: String) {
    guard let parsed = KeyCodes.parse(keyString) else {
        print("Error: Unknown key '\(keyString)'")
        print("Run 'duck-wispr --help' for examples")
        exit(1)
    }

    var config = Config.load()
    config.hotkey = HotkeyConfig(keyCode: parsed.keyCode, modifiers: parsed.modifiers)

    do {
        try config.save()
        let desc = KeyCodes.describe(keyCode: parsed.keyCode, modifiers: parsed.modifiers)
        print("Hotkey set to: \(desc)")
    } catch {
        print("Error saving config: \(error.localizedDescription)")
        exit(1)
    }
}

func cmdSetModel(_ size: String) {
    guard Config.supportedModels.contains(size) else {
        print("Error: Unknown model '\(size)'")
        print("Available: \(Config.supportedModels.joined(separator: ", "))")
        exit(1)
    }

    var config = Config.load()
    config.modelSize = size

    do {
        try config.save()
        print("Model set to: \(size)")
        if !Transcriber.modelExists(modelSize: size) {
            print("Model will be downloaded on next start.")
        }
    } catch {
        print("Error saving config: \(error.localizedDescription)")
        exit(1)
    }
}

func cmdSetLanguage(_ lang: String) {
    let validCodes = Config.supportedLanguages.map { $0.code }
    guard validCodes.contains(lang) else {
        print("Error: Unknown language '\(lang)'")
        print("Available: auto, en, fr, de, es, zh, ja, ko, pt, it, nl, ru, ...")
        print("See full list: https://github.com/human37/duck-wispr")
        exit(1)
    }

    var config = Config.load()
    config.language = lang

    do {
        try config.save()
        let name = Config.supportedLanguages.first(where: { $0.code == lang })?.name ?? lang
        print("Language set to: \(name) (\(lang))")
    } catch {
        print("Error saving config: \(error.localizedDescription)")
        exit(1)
    }
}

func cmdGetHotkey() {
    let config = Config.load()
    let desc = KeyCodes.describe(keyCode: config.hotkey.keyCode, modifiers: config.hotkey.modifiers)
    print("Current hotkey: \(desc)")
}

func cmdDownloadModel(_ size: String) {
    do {
        try ModelDownloader.download(modelSize: size)
    } catch {
        print("Error: \(error.localizedDescription)")
        exit(1)
    }
}

func cmdStatus() {
    let config = Config.load()
    let hotkeyDesc = KeyCodes.describe(keyCode: config.hotkey.keyCode, modifiers: config.hotkey.modifiers)

    print("duck-wispr v\(version)")
    print("Config:      \(Config.configFile.path)")
    print("Hotkey:      \(hotkeyDesc)")
    print("Model:       \(config.modelSize)")
    print("Model ready: \(Transcriber.modelExists(modelSize: config.modelSize) ? "yes" : "no")")
    print("whisper-cpp: \(Transcriber.findWhisperBinary() != nil ? "yes" : "no")")
    let langName = Config.supportedLanguages.first(where: { $0.code == config.language })?.name ?? config.language
    print("Language:    \(langName) (\(config.language))")
    let toggleMode = config.toggleMode?.value ?? false
    print("Toggle:      \(toggleMode ? "on (press to start/stop)" : "off (hold to talk)")")
}

let args = CommandLine.arguments
let command = args.count > 1 ? args[1] : nil

switch command {
case "start":
    cmdStart()
case "set-hotkey":
    guard args.count > 2 else {
        print("Usage: duck-wispr set-hotkey <key>")
        exit(1)
    }
    cmdSetHotkey(args[2])
case "set-model":
    guard args.count > 2 else {
        print("Usage: duck-wispr set-model <size>")
        exit(1)
    }
    cmdSetModel(args[2])
case "set-language":
    guard args.count > 2 else {
        print("Usage: duck-wispr set-language <code>")
        print("Examples: en, fr, auto")
        exit(1)
    }
    cmdSetLanguage(args[2])
case "get-hotkey":
    cmdGetHotkey()
case "download-model":
    let size = args.count > 2 ? args[2] : "base.en"
    cmdDownloadModel(size)
case "status":
    cmdStatus()
case "--help", "-h", "help":
    printUsage()
case nil:
    // Launched via Finder / open / double-click — start the dictation daemon
    cmdStart()
default:
    print("Unknown command: \(command!)")
    printUsage()
    exit(1)
}
