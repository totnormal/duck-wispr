import Foundation

public struct VerificationIssue {
    public let message: String
    public let isFatal: Bool
    public let autoFixAttempted: Bool

    public init(message: String, isFatal: Bool, autoFixAttempted: Bool = false) {
        self.message = message
        self.isFatal = isFatal
        self.autoFixAttempted = autoFixAttempted
    }
}

public struct VerificationResult {
    public let whisperPath: String?
    public let modelPath: String?
    public let issues: [VerificationIssue]

    public var isReady: Bool {
        whisperPath != nil && modelPath != nil && issues.allSatisfy { !$0.isFatal }
    }

    public init(whisperPath: String? = nil, modelPath: String? = nil, issues: [VerificationIssue] = []) {
        self.whisperPath = whisperPath
        self.modelPath = modelPath
        self.issues = issues
    }
}

public class Verifier {

    public typealias FindBinary = () -> String?
    public typealias RunProcess = (String, [String]) -> (Int32, String, String)?
    public typealias FindModel = (String) -> String?
    public typealias AttemptAutoFix = (String) -> String?

    /// Verifies whisper-cli binary loads correctly and model exists.
    /// All dependencies injected for testability.
    public static func verify(
        modelSize: String,
        findBinary: FindBinary = Transcriber.findWhisperBinary,
        runProcess: RunProcess = Verifier.defaultRunProcess,
        findModel: FindModel = Transcriber.findModel,
        attemptAutoFix: AttemptAutoFix? = nil
    ) -> VerificationResult {
        var issues: [VerificationIssue] = []
        var resolvedWhisperPath: String? = nil
        var resolvedModelPath: String? = nil

        // 1. Find whisper binary
        let foundPath = findBinary()

        if let binaryPath = foundPath {
            // 2. Verify binary loads (run --version)
            let versionResult = runProcess(binaryPath, ["--version"])
            if let result = versionResult {
                if result.0 == 0 {
                    resolvedWhisperPath = binaryPath
                } else {
                    // Binary found but fails to load
                    let stderr = result.2
                    let detail = stderr.isEmpty ? "(no error output)" : stderr

                    // Try auto-fix: remove quarantine
                    if let autoFix = attemptAutoFix {
                        if let fixedPath = autoFix("quarantine") {
                            // Re-test
                            let recheckResult = runProcess(fixedPath, ["--version"])
                            if let recheck = recheckResult, recheck.0 == 0 {
                                resolvedWhisperPath = fixedPath
                                issues.append(VerificationIssue(
                                    message: "Fixed: removed macOS quarantine from whisper-cli",
                                    isFatal: false,
                                    autoFixAttempted: true
                                ))
                            } else {
                                issues.append(VerificationIssue(
                                    message: "whisper-cli failed to load: \(detail). Try: xattr -cr /Applications/DuckWispr.app",
                                    isFatal: true
                                ))
                            }
                        } else {
                            issues.append(VerificationIssue(
                                message: "whisper-cli failed to load: \(detail). Try: xattr -cr /Applications/DuckWispr.app",
                                isFatal: true
                            ))
                        }
                    } else {
                        issues.append(VerificationIssue(
                            message: "whisper-cli failed to load: \(detail). Try: xattr -cr /Applications/DuckWispr.app",
                            isFatal: true
                        ))
                    }
                }
            } else {
                issues.append(VerificationIssue(
                    message: "whisper-cli failed to execute. Try: xattr -cr /Applications/DuckWispr.app",
                    isFatal: true
                ))
            }
        } else {
            // No binary found — try auto-fix if available
            if let autoFix = attemptAutoFix {
                if autoFix("install") != nil {
                    // Re-check after auto-fix
                    if let recheck = findBinary() {
                        resolvedWhisperPath = recheck
                        issues.append(VerificationIssue(
                            message: "Auto-installed whisper-cpp to: \(recheck)",
                            isFatal: false,
                            autoFixAttempted: true
                        ))
                    } else {
                        issues.append(VerificationIssue(
                            message: "whisper-cpp not found. Install with: brew install whisper-cpp",
                            isFatal: true
                        ))
                    }
                } else {
                    issues.append(VerificationIssue(
                        message: "whisper-cpp not found. Install with: brew install whisper-cpp",
                        isFatal: true
                    ))
                }
            } else {
                issues.append(VerificationIssue(
                    message: "whisper-cpp not found. Install with: brew install whisper-cpp",
                    isFatal: true
                ))
            }
        }

        // 3. Check model exists
        let modelPath = findModel(modelSize)
        if let modelPath = modelPath {
            resolvedModelPath = modelPath
        } else {
            issues.append(VerificationIssue(
                message: "Model '\(modelSize)' not found. It will be downloaded on first launch.",
                isFatal: true
            ))
        }

        return VerificationResult(
            whisperPath: resolvedWhisperPath,
            modelPath: resolvedModelPath,
            issues: issues
        )
    }

    /// Attempts to auto-fix issues: removes quarantine, installs whisper-cpp via Homebrew.
    /// Returns the fixed path on success, nil on failure.
    public static func attemptAutoFix(_ action: String) -> String? {
        switch action {
        case "quarantine":
            // Remove macOS quarantine from the app bundle
            let bundlePath = Bundle.main.bundlePath
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
            task.arguments = ["-d", "com.apple.quarantine", bundlePath]
            task.standardOutput = Pipe()
            task.standardError = Pipe()
            do {
                try task.run()
                task.waitUntilExit()
                if task.terminationStatus == 0 {
                    let fwTask = Process()
                    fwTask.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
                    fwTask.arguments = ["-cr", "\(bundlePath)/Contents/Frameworks"]
                    fwTask.standardOutput = Pipe()
                    fwTask.standardError = Pipe()
                    try? fwTask.run()
                    fwTask.waitUntilExit()
                    return Transcriber.findWhisperBinary()
                }
            } catch { }
            return nil

        case "install":
            let candidates = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
            for brewPath in candidates {
                guard FileManager.default.fileExists(atPath: brewPath) else { continue }
                let task = Process()
                task.executableURL = URL(fileURLWithPath: brewPath)
                task.arguments = ["install", "whisper-cpp"]
                task.standardOutput = Pipe()
                task.standardError = Pipe()
                do {
                    try task.run()
                    task.waitUntilExit()
                    if task.terminationStatus == 0 {
                        return Transcriber.findWhisperBinary()
                    }
                } catch { }
            }
            return nil

        default:
            return nil
        }
    }

    /// Default process runner — actually executes the binary
    public static func defaultRunProcess(executable: String, args: [String]) -> (Int32, String, String)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
            let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            let stdout = String(data: stdoutData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let stderr = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            return (process.terminationStatus, stdout, stderr)
        } catch {
            return nil
        }
    }
}
