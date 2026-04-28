import XCTest
@testable import OpenWisprLib

final class TranscriberTests: XCTestCase {

    func testBlankAudioMarker() {
        XCTAssertEqual(Transcriber.stripWhisperMarkers("[BLANK_AUDIO]"), "")
    }

    func testBlankAudioWithWhitespace() {
        XCTAssertEqual(Transcriber.stripWhisperMarkers("  [BLANK_AUDIO]  "), "")
    }

    func testMultipleMarkers() {
        XCTAssertEqual(Transcriber.stripWhisperMarkers("[BLANK_AUDIO] [silence]"), "")
    }

    func testParenthesizedMarker() {
        XCTAssertEqual(Transcriber.stripWhisperMarkers("(BLANK_AUDIO)"), "")
    }

    func testNonSpeechEventMarkers() {
        XCTAssertEqual(Transcriber.stripWhisperMarkers("[Music] [Applause]"), "")
    }

    func testMarkerMixedWithText() {
        XCTAssertEqual(Transcriber.stripWhisperMarkers("hello [BLANK_AUDIO] world"), "hello world")
    }

    func testMarkerAtStartOfText() {
        XCTAssertEqual(Transcriber.stripWhisperMarkers("[BLANK_AUDIO] hello"), "hello")
    }

    func testMarkerAtEndOfText() {
        XCTAssertEqual(Transcriber.stripWhisperMarkers("hello [BLANK_AUDIO]"), "hello")
    }

    func testNormalTextUnchanged() {
        XCTAssertEqual(Transcriber.stripWhisperMarkers("hello world"), "hello world")
    }

    func testEmptyString() {
        XCTAssertEqual(Transcriber.stripWhisperMarkers(""), "")
    }

    func testUnknownBracketsPreserved() {
        XCTAssertEqual(Transcriber.stripWhisperMarkers("see [1] and (later)"), "see [1] and (later)")
    }

    func testKnownMarkerStrippedUnknownPreserved() {
        XCTAssertEqual(Transcriber.stripWhisperMarkers("[BLANK_AUDIO] see [1]"), "see [1]")
    }

    func testSanitizedPromptTrimsAndBoundsPrompt() {
        let prompt = String(repeating: "a", count: 250)
        let sanitized = Transcriber.sanitizedPrompt(prompt)
        XCTAssertEqual(sanitized?.count, 200)
        XCTAssertEqual(sanitized, String(repeating: "a", count: 200))
    }

    func testSanitizedPromptReturnsNilForMarkersOnly() {
        XCTAssertNil(Transcriber.sanitizedPrompt(" [BLANK_AUDIO] "))
    }

    // MARK: - deleteOtherModels

    func testDeleteOtherModelsKeepsOnlyTarget() {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("wispr-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Create three "models"
        let files = ["ggml-base.en.bin", "ggml-base.bin", "ggml-small.bin"]
        for f in files {
            FileManager.default.createFile(atPath: tmp.appendingPathComponent(f).path, contents: Data(), attributes: nil)
        }

        Transcriber.deleteOtherModels(keeping: "small", in: tmp.path)

        let remaining = (try? FileManager.default.contentsOfDirectory(atPath: tmp.path)) ?? []
        XCTAssertEqual(remaining.sorted(), ["ggml-small.bin"])
    }

    func testDeleteOtherModelsIgnoresNonGGMLFiles() {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("wispr-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        FileManager.default.createFile(atPath: tmp.appendingPathComponent("config.json").path, contents: Data(), attributes: nil)
        FileManager.default.createFile(atPath: tmp.appendingPathComponent("ggml-base.en.bin").path, contents: Data(), attributes: nil)

        Transcriber.deleteOtherModels(keeping: "base.en", in: tmp.path)

        let remaining = (try? FileManager.default.contentsOfDirectory(atPath: tmp.path)) ?? []
        XCTAssertEqual(remaining.sorted(), ["config.json", "ggml-base.en.bin"])
    }

    func testDeleteOtherModelsEmptyDir() {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("wispr-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        Transcriber.deleteOtherModels(keeping: "tiny", in: tmp.path)

        let remaining = (try? FileManager.default.contentsOfDirectory(atPath: tmp.path)) ?? []
        XCTAssertEqual(remaining, [])
    }
}
