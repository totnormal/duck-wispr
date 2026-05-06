import Foundation

public class Transcriber {
    private static let maxPromptCharacters = 200

    /// Sample phrases in each language to bias whisper-cpp's auto-detection toward favorite languages.
    private static let languageBiasSamples: [String: String] = [
        "en": "The quick brown fox jumps over the lazy dog",
        "zh": "这是一个中文语音识别测试",
        "de": "Der schnelle braune Fuchs springt über den faulen Hund",
        "es": "El rápido zorro marrón salta sobre el perro perezoso",
        "ru": "Привет, это проверка распознавания русской речи",
        "ko": "안녕하세요 이것은 한국어 음성 인식 테스트입니다",
        "fr": "Le rapide renard brun saute par dessus le chien paresseux",
        "ja": "こんにちは、これは日本語の音声認識テストです",
        "pt": "A rápida raposa marrom pula sobre o cão preguiçoso",
        "tr": "Merhaba bu bir Türkçe ses tanıma testidir",
        "pl": "Szybki brązowy lis przeskakuje nad leniwym psem",
        "nl": "De snelle bruine vos springt over de luie hond",
        "ar": "مرحبا هذا اختبار للتعرف على الكلام العربي",
        "sv": "Den snabba bruna räven hoppar över den lata hunden",
        "it": "La rapida volpe marrone salta sopra il cane pigro",
        "hi": "नमस्ते यह हिंदी भाषण पहचान परीक्षण है",
        "fi": "Nopea ruskea kettu hyppää laiskan koiran yli",
        "vi": "Con cáo nâu nhanh nhẹn nhảy qua con chó lười biếng",
        "uk": "Привіт це тест розпізнавання української мови",
        "el": "Η γρήγορη καφέ αλεπού πηδάει πάνω από τον τεμπέλη σκύλο",
        "cs": "Rychlá hnědá liška skáče přes líného psa",
        "ro": "Vulpea brună rapidă sare peste câinele leneș",
        "hu": "A gyors barna róka átugrik a lusta kutyán",
        "no": "Den raske brune reven hopper over den late hunden",
        "th": "สวัสดีนี่คือการทดสอบการรู้ภาษาไทย",
        "da": "Den hurtige brune ræv springer over den dovne hund",
        "bg": "Бързата кафява лисица скача над мързеливото куче",
        "hr": "Brza smeđa lisica skače preko lijenog psa",
        "he": "השועל החום המהיר קופץ מעל הכלב העצלן",
        "id": "Rubah coklat yang cepat melompati anjing pemalas",
    ]

    /// Builds a bias prompt from favorite language codes.
    /// Returns nil if no favorites or no matching samples.
    private static func buildFavoriteBias(_ favorites: [String]) -> String? {
        let parts = favorites.compactMap { languageBiasSamples[$0] }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: ". ")
    }

    private let modelSize: String
    private let language: String

    public init(modelSize: String = "base.en", language: String = "en") {
        self.modelSize = modelSize
        self.language = language
    }

    public func transcribe(audioURL: URL, prompt: String? = nil) throws -> String {
        guard let whisperPath = Transcriber.findWhisperBinary() else {
            throw TranscriberError.whisperNotFound
        }

        guard let modelPath = Transcriber.findModel(modelSize: modelSize) else {
            throw TranscriberError.modelNotFound(modelSize)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: whisperPath)
        var args = [
            "-m", modelPath,
            "-f", audioURL.path,
            "-l", language,
            "--no-timestamps",
            "-nt",
        ]
        // When auto-detect with favorite languages, prepend bias text
        // Bias is trimmed first if needed so the continuity prompt is preserved
        let combinedPrompt: String?
        if language == "auto" {
            let config = Config.load()
            if let favorites = config.favoriteLanguages, !favorites.isEmpty,
               let bias = Transcriber.buildFavoriteBias(favorites) {
                let existingPrompt = Transcriber.sanitizedPrompt(prompt)
                let existingCount = existingPrompt?.count ?? 0
                if existingCount >= Transcriber.maxPromptCharacters {
                    combinedPrompt = existingPrompt
                } else {
                    let budget = Transcriber.maxPromptCharacters - existingCount - 2
                    let trimmedBias: String
                    if budget > 0 && bias.count > budget {
                        let start = bias.index(bias.endIndex, offsetBy: -budget)
                        trimmedBias = String(bias[start...]).trimmingCharacters(in: .whitespacesAndNewlines)
                    } else if budget > 0 {
                        trimmedBias = bias
                    } else {
                        trimmedBias = ""
                    }
                    if let existing = existingPrompt, !trimmedBias.isEmpty {
                        combinedPrompt = Transcriber.sanitizedPrompt(trimmedBias + ". " + existing)
                    } else if !trimmedBias.isEmpty {
                        combinedPrompt = Transcriber.sanitizedPrompt(trimmedBias)
                    } else {
                        combinedPrompt = existingPrompt
                    }
                }
            } else {
                combinedPrompt = Transcriber.sanitizedPrompt(prompt)
            }
        } else {
            combinedPrompt = Transcriber.sanitizedPrompt(prompt)
        }
        if let promptArg = combinedPrompt, !promptArg.isEmpty {
            args += ["--prompt", promptArg]
        }
        process.arguments = args

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        var stderrData = Data()
        let stderrThread = Thread {
            stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        }
        stderrThread.start()

        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        while !stderrThread.isFinished { Thread.sleep(forTimeInterval: 0.01) }
        process.waitUntilExit()

        let output = Transcriber.stripWhisperMarkers(
            String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        )

        if process.terminationStatus != 0 {
            let stderr = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !stderr.isEmpty { fputs("whisper-cpp: \(stderr)\n", Foundation.stderr) }
            throw TranscriberError.transcriptionFailed
        }

        return output
    }

    private static let knownMarkers: Set<String> = [
        "BLANK_AUDIO", "blank_audio",
        "Music", "MUSIC", "music",
        "Applause", "APPLAUSE", "applause",
        "Laughter", "LAUGHTER", "laughter",
        "silence", "Silence", "SILENCE",
        "SOUND", "Sound", "sound",
        "NOISE", "Noise", "noise",
        "INAUDIBLE", "inaudible",
    ]

    private static let markerRegex = try! NSRegularExpression(
        pattern: "[\\[\\(]\\s*([^\\]\\)]+?)\\s*[\\]\\)]"
    )

    public static func stripWhisperMarkers(_ text: String) -> String {
        let nsText = text as NSString
        let matches = markerRegex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        var result = text
        for match in matches.reversed() {
            let innerRange = match.range(at: 1)
            let inner = nsText.substring(with: innerRange)
            if knownMarkers.contains(inner), let fullRange = Range(match.range, in: result) {
                result.replaceSubrange(fullRange, with: "")
            }
        }
        return result
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func sanitizedPrompt(_ prompt: String?) -> String? {
        guard let prompt else { return nil }
        let cleaned = stripWhisperMarkers(prompt)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        if cleaned.count <= maxPromptCharacters {
            return cleaned
        }
        let start = cleaned.index(cleaned.endIndex, offsetBy: -maxPromptCharacters)
        return String(cleaned[start...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func findWhisperBinary() -> String? {
        // Check bundled binary first (self-contained DMG)
        if let bundlePath = Bundle.main.executablePath {
            let bundledDir = (bundlePath as NSString).deletingLastPathComponent
            let bundled = "\(bundledDir)/whisper-cli"
            if FileManager.default.fileExists(atPath: bundled) { return bundled }
        }

        let candidates = [
            "/opt/homebrew/bin/whisper-cli",
            "/usr/local/bin/whisper-cli",
            "/opt/homebrew/bin/whisper-cpp",
            "/usr/local/bin/whisper-cpp",
        ]

        for path in candidates {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }

        for name in ["whisper-cli", "whisper-cpp"] {
            let which = Process()
            which.executableURL = URL(fileURLWithPath: "/usr/bin/which")
            which.arguments = [name]
            let pipe = Pipe()
            which.standardOutput = pipe
            which.standardError = Pipe()
            try? which.run()
            which.waitUntilExit()

            let result = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if let result = result, !result.isEmpty {
                return result
            }
        }

        return nil
    }

    public static func modelExists(modelSize: String) -> Bool {
        return findModel(modelSize: modelSize) != nil
    }

    static func findModel(modelSize: String) -> String? {
        let modelFileName = "ggml-\(modelSize).bin"

        let candidates = [
            "\(Config.configDir.path)/models/\(modelFileName)",
            "/opt/homebrew/share/whisper-cpp/models/\(modelFileName)",
            "/usr/local/share/whisper-cpp/models/\(modelFileName)",
            "\(FileManager.default.homeDirectoryForCurrentUser.path)/.cache/whisper/\(modelFileName)",
        ]

        for path in candidates {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }

        return nil
    }

    /// Deletes all downloaded models except the one being kept.
    /// Only cleans the given directory (default: ~/.config/duck-wispr/models/).
    public static func deleteOtherModels(keeping modelSize: String, in directory: String? = nil) {
        let dir = directory ?? "\(Config.configDir.path)/models"
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return }
        let keepFile = "ggml-\(modelSize).bin"
        for file in files {
            guard file.hasPrefix("ggml-") && file.hasSuffix(".bin") else { continue }
            if file == keepFile { continue }
            let path = "\(dir)/\(file)"
            do {
                try FileManager.default.removeItem(atPath: path)
                print("Removed old model: \(file)")
            } catch {
                print("Could not remove old model \(file): \(error.localizedDescription)")
            }
        }
    }
}

enum TranscriberError: LocalizedError {
    case whisperNotFound
    case modelNotFound(String)
    case transcriptionFailed

    var errorDescription: String? {
        switch self {
        case .whisperNotFound:
            return "whisper-cpp not found. Install it with: brew install whisper-cpp"
        case .modelNotFound(let size):
            return "Whisper model '\(size)' not found. Download it with: duck-wispr download-model \(size)"
        case .transcriptionFailed:
            return "Transcription failed"
        }
    }
}
