import XCTest
@testable import DuckWisprLib

final class TranscriberErrorTests: XCTestCase {

    func testTranscriptionFailedIncludesStderr() {
        let error = TranscriberError.transcriptionFailed("dylib not found: libwhisper.1.dylib")
        let description = error.errorDescription ?? ""
        XCTAssertTrue(description.contains("dylib not found"),
            "Expected error description to contain the stderr output, got: \(description)")
    }

    func testTranscriptionFailedIncludesHelpfulHintWhenEmpty() {
        let error = TranscriberError.transcriptionFailed("")
        let description = error.errorDescription ?? ""
        XCTAssertTrue(description.contains("whisper"),
            "Expected fallback hint when stderr is empty, got: \(description)")
    }
}
