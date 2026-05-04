import Foundation
import NaturalLanguage

public struct TextPostProcessor {
    private static let fillerPatterns: [String] = [
        "(?i)(^|[\\s,;:—\\-\\(])(?:um|uh|er|you know|i mean|sort of|kind of)\\b(?=(?:[\\s,;:—\\-\\)]|$))",
        "(?i)(^|[\\s,;:—\\-\\(])like\\b(?=(?:\\s*[,;:—\\-])|(?:\\s+[A-Za-z]+\\s*[,;:—\\-])|$)"
    ]

    private static let spokenPunctuationRules: [(phrase: String, punctuation: String)] = [
        ("question mark", "?"),
        ("exclamation mark", "!"),
        ("exclamation point", "!"),
        ("full stop", "."),
        ("period", "."),
        ("comma", ","),
        ("colon", ":"),
        ("semicolon", ";"),
        ("semi colon", ";"),
        ("ellipsis", "..."),
        ("dash", " —"),
        ("hyphen", "-"),
        ("open quote", "\""),
        ("close quote", "\""),
        ("open paren", "("),
        ("close paren", ")"),
        ("new line", "\n"),
        ("newline", "\n"),
        ("new paragraph", "\n\n")
    ]

    public static func process(_ text: String, language: String = "en") -> String {
        let stripped = Transcriber.stripWhisperMarkers(text)
        guard !stripped.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }

        var result = stripped
        result = removeFillerWords(result)
        result = fixRepeatedWords(result)
        result = fixBrokenContractions(result)
        result = applySpokenPunctuationFallback(result)
        result = fixSpacingAroundPunctuation(result)
        result = ensureSpaceAfterPunctuation(result)
        result = capitalizeSentences(result, language: language)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func removeFillerWords(_ text: String) -> String {
        var result = text
        for pattern in fillerPatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: "$1"
            )
        }
        result = result.replacingOccurrences(of: "\\s+,", with: ",", options: .regularExpression)
        result = result.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: "(^|\\n)\\s+", with: "$1", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func fixRepeatedWords(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "(?iu)(\\b[\\p{L}\\p{N}_]+\\b)(?:\\s+\\1)+") else { return text }
        return regex.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: "$1"
        )
    }

    private static func fixBrokenContractions(_ text: String) -> String {
        let replacements: [(String, String)] = [
            ("\\b[Dd]o n['’]t\\b", "don't"),
            ("\\b[Ww]o n['’]t\\b", "won't"),
            ("\\b[Cc]a n['’]t\\b", "can't"),
            ("\\b[Ii]s n['’]t\\b", "isn't"),
            ("\\b[Aa]re n['’]t\\b", "aren't"),
            ("\\b[Dd]id n['’]t\\b", "didn't"),
            ("\\b[Dd]oes n['’]t\\b", "doesn't"),
            ("\\b[Ww]as n['’]t\\b", "wasn't"),
            ("\\b[Cc]ould n['’]t\\b", "couldn't"),
            ("\\b[Ww]ould n['’]t\\b", "wouldn't"),
            ("\\b[Ss]hould n['’]t\\b", "shouldn't")
        ]

        var result = text
        for (pattern, replacement) in replacements {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: replacement
            )
        }
        return result
    }

    private static func applySpokenPunctuationFallback(_ text: String) -> String {
        var result = text
        for rule in spokenPunctuationRules {
            result = replaceSpokenPunctuation(rule.phrase, with: rule.punctuation, in: result)
        }
        return result
    }

    private static func replaceSpokenPunctuation(_ phrase: String, with punctuation: String, in text: String) -> String {
        let pattern = "(?i)\\b" + NSRegularExpression.escapedPattern(for: phrase).replacingOccurrences(of: "\\ ", with: "\\s+") + "\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }

        var result = text
        let fullRange = NSRange(result.startIndex..., in: result)
        let matches = regex.matches(in: result, range: fullRange)

        for match in matches.reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            let prefix = result[..<range.lowerBound]
            let suffix = result[range.upperBound...]
            let previousCharacter = prefix.reversed().first(where: { !$0.isWhitespace })
            let nextCharacter = suffix.first(where: { !$0.isWhitespace })
            let trimmedPunctuation = punctuation.trimmingCharacters(in: .whitespacesAndNewlines)
            let shouldReplace: Bool

            switch trimmedPunctuation {
            case "...":
                shouldReplace = !prefix.hasSuffix("...")
            case ",", ".", "?", "!", ":", ";":
                let isAlreadyPresent = previousCharacter.map { String($0) == trimmedPunctuation } ?? false
                shouldReplace = !isAlreadyPresent
            case "\"":
                let adjacentQuote = previousCharacter == "\"" || nextCharacter == "\""
                shouldReplace = !adjacentQuote
            case "(":
                shouldReplace = previousCharacter != "("
            case ")":
                shouldReplace = nextCharacter != ")"
            case "-":
                shouldReplace = !(previousCharacter == "-" || nextCharacter == "-")
            default:
                shouldReplace = true
            }

            if shouldReplace {
                result.replaceSubrange(range, with: punctuation)
            }
        }
        return result
    }

    private static func fixSpacingAroundPunctuation(_ text: String) -> String {
        var result = text
        let replacements: [(pattern: String, template: String)] = [
            ("\\s+([.,?!:;)\\]\\}])", "$1"),
            ("([\\(\\[\\{])\\s+", "$1"),
            ("\\s*\\n\\s*", "\n"),
            ("\\s*\\n\\s*\\n\\s*", "\n\n")
        ]

        for (pattern, template) in replacements {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: template
            )
        }

        if let regex = try? NSRegularExpression(pattern: "(?<=\\w)\\s*—\\s*(?=\\w)") {
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: " — "
            )
        }

        if let regex = try? NSRegularExpression(pattern: "(?<=\\w)\\s*-\\s*(?=\\w)") {
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: "-"
            )
        }

        if let regex = try? NSRegularExpression(pattern: "\\.\\s+\\.") {
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: ".."
            )
        }

        return result
    }

    private static func ensureSpaceAfterPunctuation(_ text: String) -> String {
        var result = text
        let replacements: [(pattern: String, template: String)] = [
            ("([.,?!:;])([^\\s\"')\\]\\}])", "$1 $2"),
            ("([)\\]\\}])([^\\s.,?!:;\"'])", "$1 $2"),
            ("([A-Za-z])\"", "$1 \"")
        ]

        for (pattern, template) in replacements {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: template
            )
        }
        return result
    }

    private static func capitalizeSentences(_ text: String, language: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = trimmed
        if language != "auto", let nlLanguage = supportedNLLanguage(for: language) {
            tagger.setLanguage(nlLanguage, range: trimmed.startIndex..<trimmed.endIndex)
        }

        var result = trimmed
        let sentenceStarts = sentenceStartIndices(in: trimmed)
        for index in sentenceStarts.reversed() {
            let uppercased = String(result[index]).uppercased()
            result.replaceSubrange(index...index, with: uppercased)
        }
        return result
    }

    private static func sentenceStartIndices(in text: String) -> [String.Index] {
        var starts: [String.Index] = []
        var shouldStartSentence = true
        var index = text.startIndex

        while index < text.endIndex {
            let character = text[index]
            if shouldStartSentence, character.isLetter {
                starts.append(index)
                shouldStartSentence = false
            }

            if ".!?\n".contains(character) {
                shouldStartSentence = true
            }

            index = text.index(after: index)
        }

        return starts
    }

    private static func supportedNLLanguage(for language: String) -> NLLanguage? {
        let supportedLanguages = Set(Config.supportedLanguages.map(\.code))
        guard supportedLanguages.contains(language), language != "auto" else { return nil }
        return NLLanguage(rawValue: language)
    }
}
