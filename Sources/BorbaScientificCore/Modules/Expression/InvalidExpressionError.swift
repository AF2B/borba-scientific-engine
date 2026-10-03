extension ErrorCode {
    /// The mathematical expression cannot be parsed or evaluated.
    public static let invalidExpression = ErrorCode("INVALID_EXPRESSION")
}

/// Why an expression was rejected, and where.
struct InvalidExpressionError: Error, Sendable, Equatable {
    /// The reason an expression is invalid.
    enum Reason: Sendable, Equatable {
        case empty
        case tooLong(maximum: Int)
        case tooDeeplyNested(maximum: Int)
        case unexpectedCharacter(Character)
        case malformedNumber(String)
        case unexpectedToken(String)
        case unexpectedEnd
        case unbalancedParenthesis
        case unknownFunction(String)
        case wrongArgumentCount(function: String, expected: String, actual: Int)
    }

    /// What is wrong.
    let reason: Reason

    /// Zero-based character offset of the problem, when it has a location.
    let position: Int?

    /// A short explanation phrased for the caller, including the position.
    var explanation: String {
        let description =
            switch reason {
            case .empty:
                "the expression is empty"
            case .tooLong(let maximum):
                "the expression is longer than \(maximum) characters"
            case .tooDeeplyNested(let maximum):
                "the expression nests parentheses or operators more than \(maximum) levels deep"
            case .unexpectedCharacter(let character):
                "unexpected character '\(character)'"
            case .malformedNumber(let text):
                "malformed number '\(text)'"
            case .unexpectedToken(let text):
                "unexpected '\(text)'"
            case .unexpectedEnd:
                "the expression ends unexpectedly"
            case .unbalancedParenthesis:
                "parenthesis is never closed"
            case .unknownFunction(let name):
                "unknown function '\(name)'"
            case .wrongArgumentCount(let function, let expected, let actual):
                "'\(function)' expects \(expected) but \(actual) were given"
            }

        guard let position else {
            return description
        }
        return "\(description) at position \(position)"
    }
}

extension InvalidExpressionError: CalculationFailure {
    /// Maps the failure to the stable `INVALID_EXPRESSION` error with a located explanation.
    var calculationError: CalculationError {
        .domain(
            DomainFailure(
                code: .invalidExpression,
                message: "The provided expression is invalid.",
                details: [ErrorDetail(field: ExpressionParameters.expression.name, reason: explanation)]
            )
        )
    }
}
