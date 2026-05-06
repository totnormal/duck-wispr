import XCTest
@testable import DuckWisprLib

final class PromptCooldownTests: XCTestCase {

    // MARK: - Bug 1: Prompt contamination via stale lastTranscription

    func testSanitizedPromptReturnsNilWhenInputIsNil() {
        let result = Transcriber.sanitizedPrompt(nil)
        XCTAssertNil(result, "sanitizedPrompt(nil) should return nil")
    }

    func testSanitizedPromptTrimsWhitespace() {
        let result = Transcriber.sanitizedPrompt("   hello world   ")
        XCTAssertEqual(result, "hello world")
    }

    func testSanitizedPromptReturnsNilForWhitespaceOnly() {
        let result = Transcriber.sanitizedPrompt("     ")
        XCTAssertNil(result, "sanitizedPrompt should return nil for whitespace-only strings")
    }

    // MARK: - Bug 2: lastTranscription not cleared on error

    func testTranscriberErrorHasLocalizedDescription() {
        let error = TranscriberError.transcriptionFailed("test stderr message")
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription?.contains("test stderr message") ?? false)
    }

    func testTranscriberErrorWhisperNotFound() {
        let error = TranscriberError.whisperNotFound
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription?.contains("brew install") ?? false)
    }

    func testTranscriberErrorModelNotFound() {
        let error = TranscriberError.modelNotFound("base.en")
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription?.contains("base.en") ?? false)
    }
}
