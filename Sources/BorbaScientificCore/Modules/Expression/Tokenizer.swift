/// A lexical unit of an expression.
struct Token: Equatable, Sendable {
    /// What kind of unit it is.
    enum Kind: Equatable, Sendable {
        case number(Double)
        case identifier(String)
        case symbol(Symbol)
        case end
    }

    /// The single-character operators and delimiters.
    enum Symbol: Character, Sendable {
        case plus = "+"
        case minus = "-"
        case star = "*"
        case slash = "/"
        case percent = "%"
        case caret = "^"
        case leftParenthesis = "("
        case rightParenthesis = ")"
        case comma = ","
    }

    /// The kind and value of the token.
    let kind: Kind

    /// Zero-based character offset where the token starts.
    let position: Int

    /// The token as it should appear in an error message.
    let lexeme: String
}

/// Splits an expression into tokens.
enum Tokenizer {
    /// Longest accepted expression, in characters. It also bounds the evaluation depth of a flat chain of terms.
    static let maximumLength = 1_000

    private static let decimalPoint: Character = "."
    private static let underscore: Character = "_"
    private static let exponentMarkers: Set<Character> = ["e", "E"]
    private static let exponentSigns: Set<Character> = ["+", "-"]

    /// Tokenizes an expression.
    ///
    /// - Parameter source: The text of the expression.
    /// - Returns: The tokens, always ending with ``Token/Kind/end``.
    /// - Throws: ``InvalidExpressionError`` for an empty or overlong expression, an unknown character or a malformed
    ///   number.
    static func tokenize(_ source: String) throws(InvalidExpressionError) -> [Token] {
        let characters = Array(source)
        guard characters.contains(where: { !$0.isWhitespace }) else {
            throw InvalidExpressionError(reason: .empty, position: nil)
        }
        guard characters.count <= maximumLength else {
            throw InvalidExpressionError(reason: .tooLong(maximum: maximumLength), position: nil)
        }

        var tokens: [Token] = []
        var index = 0

        while index < characters.count {
            let character = characters[index]

            if character.isWhitespace {
                index += 1
            } else if isDigit(character) || character == decimalPoint {
                let token = try scanNumber(in: characters, from: index)
                tokens.append(token)
                index += token.lexeme.count
            } else if isIdentifierStart(character) {
                let token = scanIdentifier(in: characters, from: index)
                tokens.append(token)
                index += token.lexeme.count
            } else if let symbol = Token.Symbol(rawValue: character) {
                tokens.append(Token(kind: .symbol(symbol), position: index, lexeme: String(character)))
                index += 1
            } else {
                throw InvalidExpressionError(reason: .unexpectedCharacter(character), position: index)
            }
        }

        tokens.append(Token(kind: .end, position: characters.count, lexeme: ""))
        return tokens
    }

    fileprivate static func isDigit(_ character: Character) -> Bool {
        character.isASCII && character.isNumber
    }

    fileprivate static func isIdentifierStart(_ character: Character) -> Bool {
        character.isASCII && (character.isLetter || character == underscore)
    }

    fileprivate static func isIdentifierPart(_ character: Character) -> Bool {
        isIdentifierStart(character) || isDigit(character)
    }

    private static func scanIdentifier(
        in characters: [Character],
        from start: Int
    ) -> Token {
        var end = start
        while end < characters.count, isIdentifierPart(characters[end]) {
            end += 1
        }

        let name = String(characters[start..<end])
        return Token(kind: .identifier(name), position: start, lexeme: name)
    }

    /// Scans `digits[.digits][e[+|-]digits]` or `.digits[...]`.
    private static func scanNumber(
        in characters: [Character],
        from start: Int
    ) throws(InvalidExpressionError) -> Token {
        var end = start
        func skipDigits() {
            while end < characters.count, isDigit(characters[end]) {
                end += 1
            }
        }

        skipDigits()
        if end < characters.count, characters[end] == decimalPoint {
            end += 1
            skipDigits()
        }
        let mantissaEnd = end

        if end < characters.count, exponentMarkers.contains(characters[end]) {
            end += 1
            if end < characters.count, exponentSigns.contains(characters[end]) {
                end += 1
            }
            let exponentStart = end
            skipDigits()
            guard end > exponentStart else {
                throw InvalidExpressionError(
                    reason: .malformedNumber(String(characters[start..<end])),
                    position: start
                )
            }
        }

        let lexeme = String(characters[start..<end])
        guard mantissaEnd > start, let value = Double(lexeme), value.isFinite else {
            throw InvalidExpressionError(reason: .malformedNumber(lexeme), position: start)
        }
        return Token(kind: .number(value), position: start, lexeme: lexeme)
    }
}

extension Tokenizer {
    /// Whether a text is a valid identifier: an ASCII letter or underscore followed by letters, digits or
    /// underscores.
    ///
    /// - Parameter text: The text to check.
    /// - Returns: `true` when the tokenizer would read the whole text as one identifier.
    static func isIdentifier(_ text: String) -> Bool {
        guard let first = text.first, isIdentifierStart(first) else {
            return false
        }
        return text.allSatisfy(isIdentifierPart)
    }
}
