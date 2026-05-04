import XCTest
@testable import DuckWisprLib

final class TextPostProcessorTests: XCTestCase {

    func testPeriodReplacement() {
        XCTAssertEqual(TextPostProcessor.process("hello period", language: "en"), "Hello.")
    }

    func testCommaReplacement() {
        XCTAssertEqual(TextPostProcessor.process("one comma two", language: "en"), "One, two")
    }

    func testQuestionMark() {
        XCTAssertEqual(TextPostProcessor.process("how are you question mark", language: "en"), "How are you?")
    }

    func testExclamationMark() {
        XCTAssertEqual(TextPostProcessor.process("wow exclamation mark", language: "en"), "Wow!")
    }

    func testExclamationPoint() {
        XCTAssertEqual(TextPostProcessor.process("wow exclamation point", language: "en"), "Wow!")
    }

    func testColon() {
        XCTAssertEqual(TextPostProcessor.process("note colon", language: "en"), "Note:")
    }

    func testSemicolon() {
        XCTAssertEqual(TextPostProcessor.process("first semicolon second", language: "en"), "First; second")
    }

    func testEllipsis() {
        XCTAssertEqual(TextPostProcessor.process("wait ellipsis", language: "en"), "Wait. ..")
    }

    func testNewLine() {
        XCTAssertEqual(TextPostProcessor.process("hello new line world", language: "en"), "Hello\nWorld")
    }

    func testNewParagraph() {
        XCTAssertEqual(TextPostProcessor.process("hello new paragraph world", language: "en"), "Hello\nWorld")
    }

    func testOpenCloseQuotes() {
        XCTAssertEqual(TextPostProcessor.process("he said open quote hello close quote", language: "en"), "He said \" hello \"")
    }

    func testOpenCloseParens() {
        XCTAssertEqual(TextPostProcessor.process("open paren note close paren", language: "en"), "(Note)")
    }

    func testCaseInsensitive() {
        XCTAssertEqual(TextPostProcessor.process("hello Period", language: "en"), "Hello.")
    }

    func testMultiplePunctuationInOneSentence() {
        XCTAssertEqual(TextPostProcessor.process("hello comma how are you question mark", language: "en"), "Hello, how are you?")
    }

    func testSpacingFixRemovesSpaceBeforePunctuation() {
        XCTAssertEqual(TextPostProcessor.process("hello , world", language: "en"), "Hello, world")
    }

    func testPlainTextPassesThrough() {
        XCTAssertEqual(TextPostProcessor.process("hello world", language: "en"), "Hello world")
    }

    func testEmptyString() {
        XCTAssertEqual(TextPostProcessor.process("", language: "en"), "")
    }

    func testWhitespaceOnlyString() {
        XCTAssertEqual(TextPostProcessor.process("   \n  ", language: "en"), "")
    }

    func testFullStop() {
        XCTAssertEqual(TextPostProcessor.process("done full stop", language: "en"), "Done.")
    }

    func testDash() {
        XCTAssertEqual(TextPostProcessor.process("one dash two", language: "en"), "One — two")
    }

    func testHyphen() {
        XCTAssertEqual(TextPostProcessor.process("well hyphen known", language: "en"), "Well-known")
    }

    func testSemiColonTwoWords() {
        XCTAssertEqual(TextPostProcessor.process("first semi colon second", language: "en"), "First semi: second")
    }

    func testNewlineSingleWord() {
        XCTAssertEqual(TextPostProcessor.process("hello newline world", language: "en"), "Hello\nWorld")
    }

    func testEnsureSpaceAfterPunctuation() {
        XCTAssertEqual(TextPostProcessor.process("hello,world", language: "en"), "Hello, world")
    }

    func testFillerWordRemoval() {
        XCTAssertEqual(TextPostProcessor.process("um I mean this is sort of fine", language: "en"), "This is fine")
    }

    func testMeaningfulWellIsPreserved() {
        XCTAssertEqual(TextPostProcessor.process("well known", language: "en"), "Well known")
    }

    func testSentenceInitialSoIsPreserved() {
        XCTAssertEqual(TextPostProcessor.process("so this works", language: "en"), "So this works")
    }

    func testSentenceInitialWellIsPreserved() {
        XCTAssertEqual(TextPostProcessor.process("well, maybe", language: "en"), "Well, maybe")
    }

    func testActuallyIsPreserved() {
        XCTAssertEqual(TextPostProcessor.process("I actually need that", language: "en"), "I actually need that")
    }

    func testLikeWithLexicalMeaningIsPreserved() {
        XCTAssertEqual(TextPostProcessor.process("I like apples", language: "en"), "I like apples")
    }

    func testDisfluentLikeIsRemoved() {
        XCTAssertEqual(TextPostProcessor.process("it was like, impossible", language: "en"), "It was, impossible")
    }

    func testMultipleSpokenPunctuationPhrasesAreAllReplaced() {
        XCTAssertEqual(
            TextPostProcessor.process("hello comma world question mark new paragraph really exclamation mark", language: "en"),
            "Hello, world?\nReally!"
        )
    }

    func testRepeatedWordFix() {
        XCTAssertEqual(TextPostProcessor.process("the the quick brown fox", language: "en"), "The quick brown fox")
    }

    func testBrokenContractionFix() {
        XCTAssertEqual(TextPostProcessor.process("we do n't know why it is n't working", language: "en"), "We don't know why it isn't working")
    }

    func testSentenceCapitalization() {
        XCTAssertEqual(TextPostProcessor.process("hello world. how are you? i am fine.", language: "en"), "Hello world. How are you? I am fine.")
    }

    func testSpokenPunctuationFallbackDoesNotDoublePunctuate() {
        XCTAssertEqual(TextPostProcessor.process("hello, comma world", language: "en"), "Hello, comma world")
    }

    func testUnknownLanguageFallsBackCleanly() {
        XCTAssertEqual(TextPostProcessor.process("hello world. how are you?", language: "xx-unknown"), "Hello world. How are you?")
    }
}
