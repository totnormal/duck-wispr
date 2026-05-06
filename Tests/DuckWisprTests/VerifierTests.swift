import XCTest
@testable import DuckWisprLib

final class VerifierTests: XCTestCase {

    /// Process runner that always returns nil (simulates binary not found)
    private static let runProcessNil: (String, [String]) -> (Int32, String, String)? = { _, _ in nil }

    /// Process runner that returns exit code 1 (simulates binary fails to load)
    private static let runProcessFail: (String, [String]) -> (Int32, String, String)? = { _, _ in
        return (1, "", "dylib not found: libwhisper.1.dylib")
    }

    /// Process runner that returns exit code 0 (simulates binary works)
    private static let runProcessOk: (String, [String]) -> (Int32, String, String)? = { _, args in
        // Check if this is the model check
        if args.contains("--version") {
            return (0, "whisper.cpp 1.7.5", "")
        }
        return (0, "", "")
    }

    // Override findWhisperBinary and findModel for testing via injection

    func testVerifyReturnsErrorWhenWhisperBinaryNotFound() {
        let result = Verifier.verify(
            modelSize: "small",
            findBinary: { nil },
            runProcess: VerifierTests.runProcessNil,
            findModel: { _ in nil },
            attemptAutoFix: { _ in nil }
        )
        XCTAssertFalse(result.isReady, "Should not be ready when binary not found")
        XCTAssertTrue(result.whisperPath == nil, "whisperPath should be nil")
        let hasNotFoundIssue = result.issues.contains { $0.message.contains("whisper") }
        XCTAssertTrue(hasNotFoundIssue, "Should report whisper binary not found issue, got: \(result.issues.map { $0.message })")
    }

    func testVerifyReturnsErrorWhenWhisperBinaryFailsToLoad() {
        let result = Verifier.verify(
            modelSize: "small",
            findBinary: { "/fake/path/whisper-cli" },
            runProcess: VerifierTests.runProcessFail,
            findModel: { _ in nil },
            attemptAutoFix: { _ in nil }
        )
        XCTAssertFalse(result.isReady)
        let hasLoadIssue = result.issues.contains { $0.message.contains("dylib") || $0.message.contains("failed to load") }
        XCTAssertTrue(hasLoadIssue, "Should report binary load failure, got: \(result.issues.map { $0.message })")
    }

    func testVerifyReturnsErrorWhenModelNotFound() {
        let result = Verifier.verify(
            modelSize: "small",
            findBinary: { "/fake/path/whisper-cli" },
            runProcess: VerifierTests.runProcessOk,
            findModel: { _ in nil },
            attemptAutoFix: { _ in nil }
        )
        XCTAssertFalse(result.isReady)
        XCTAssertNotNil(result.whisperPath, "whisperPath should be set since binary loads")
        let hasModelIssue = result.issues.contains { $0.message.contains("model") || $0.message.contains("Model") }
        XCTAssertTrue(hasModelIssue, "Should report model not found, got: \(result.issues.map { $0.message })")
    }

    func testVerifyReturnsReadyWhenAllOk() {
        let result = Verifier.verify(
            modelSize: "small",
            findBinary: { "/fake/path/whisper-cli" },
            runProcess: VerifierTests.runProcessOk,
            findModel: { _ in "/fake/path/ggml-small.bin" },
            attemptAutoFix: { _ in nil }
        )
        XCTAssertTrue(result.isReady, "Should be ready when binary and model exist")
        XCTAssertEqual(result.whisperPath, "/fake/path/whisper-cli")
        XCTAssertEqual(result.modelPath, "/fake/path/ggml-small.bin")
        XCTAssertTrue(result.issues.isEmpty, "Should have no issues, got: \(result.issues.map { $0.message })")
    }
}
