/// Parses expressions written in infix notation into a syntax tree.
///
/// The grammar, from the loosest to the tightest binding operator:
///
/// ```text
/// expression := term (('+' | '-') term)*
/// term       := unary (('*' | '/' | '%') unary)*
/// unary      := ('+' | '-') unary | power
/// power      := primary ('^' unary)?
/// primary    := NUMBER | IDENTIFIER | IDENTIFIER '(' [expression (',' expression)*] ')' | '(' expression ')'
/// ```
///
/// Power is right-associative and binds tighter than a unary minus on its left, so `-2^2` is `-4` and `2^3^2` is
/// `512`, matching mathematical convention. Implicit multiplication is not supported: `2x` is an error, `2 * x` is
/// not.
struct ExpressionParser {
    /// How deeply parentheses, call arguments and chained unary operators may nest. This bounds the recursion of both
    /// the parser and the evaluator regardless of what a caller sends.
    static let maximumNesting = 64

    private let tokens: [Token]
    private var cursor = 0
    private var nesting = 0

    private init(tokens: [Token]) {
        self.tokens = tokens
    }

    /// Parses an expression.
    ///
    /// - Parameter source: The text of the expression.
    /// - Returns: The root of the syntax tree.
    /// - Throws: ``InvalidExpressionError`` locating the first problem.
    static func parse(_ source: String) throws(InvalidExpressionError) -> ExpressionNode {
        var parser = ExpressionParser(tokens: try Tokenizer.tokenize(source))
        let root = try parser.parseExpression()

        let trailing = parser.current
        guard trailing.kind == .end else {
            throw InvalidExpressionError(reason: .unexpectedToken(trailing.lexeme), position: trailing.position)
        }
        return root
    }

    // MARK: - Token access

    private var current: Token {
        tokens[cursor]
    }

    private mutating func advance() {
        if cursor < tokens.count - 1 {
            cursor += 1
        }
    }

    /// Consumes the current token when it is the given symbol.
    private mutating func consume(_ symbol: Token.Symbol) -> Bool {
        guard current.kind == .symbol(symbol) else {
            return false
        }
        advance()
        return true
    }

    private mutating func descend() throws(InvalidExpressionError) {
        nesting += 1
        guard nesting <= Self.maximumNesting else {
            throw InvalidExpressionError(
                reason: .tooDeeplyNested(maximum: Self.maximumNesting),
                position: current.position
            )
        }
    }

    // MARK: - Grammar

    private mutating func parseExpression() throws(InvalidExpressionError) -> ExpressionNode {
        try descend()
        defer { nesting -= 1 }

        var node = try parseTerm()
        while let additive = additiveOperator {
            advance()
            node = .binary(additive, node, try parseTerm())
        }
        return node
    }

    private var additiveOperator: BinaryOperator? {
        switch current.kind {
        case .symbol(.plus): .add
        case .symbol(.minus): .subtract
        default: nil
        }
    }

    private mutating func parseTerm() throws(InvalidExpressionError) -> ExpressionNode {
        var node = try parseUnary()
        while let multiplicative = multiplicativeOperator {
            advance()
            node = .binary(multiplicative, node, try parseUnary())
        }
        return node
    }

    private var multiplicativeOperator: BinaryOperator? {
        switch current.kind {
        case .symbol(.star): .multiply
        case .symbol(.slash): .divide
        case .symbol(.percent): .remainder
        default: nil
        }
    }

    private mutating func parseUnary() throws(InvalidExpressionError) -> ExpressionNode {
        if consume(.minus) {
            try descend()
            defer { nesting -= 1 }
            return .negate(try parseUnary())
        }
        if consume(.plus) {
            try descend()
            defer { nesting -= 1 }
            return try parseUnary()
        }
        return try parsePower()
    }

    private mutating func parsePower() throws(InvalidExpressionError) -> ExpressionNode {
        let base = try parsePrimary()
        guard consume(.caret) else {
            return base
        }

        try descend()
        defer { nesting -= 1 }
        return .binary(.power, base, try parseUnary())
    }

    private mutating func parsePrimary() throws(InvalidExpressionError) -> ExpressionNode {
        let token = current

        switch token.kind {
        case .number(let value):
            advance()
            return .number(value)
        case .identifier(let name):
            advance()
            return try parseIdentifier(name, at: token.position)
        case .symbol(.leftParenthesis):
            advance()
            let inner = try parseExpression()
            guard consume(.rightParenthesis) else {
                throw InvalidExpressionError(reason: .unbalancedParenthesis, position: token.position)
            }
            return inner
        case .end:
            throw InvalidExpressionError(reason: .unexpectedEnd, position: token.position)
        case .symbol:
            throw InvalidExpressionError(reason: .unexpectedToken(token.lexeme), position: token.position)
        }
    }

    private mutating func parseIdentifier(
        _ name: String,
        at position: Int
    ) throws(InvalidExpressionError) -> ExpressionNode {
        let parenthesis = current
        guard consume(.leftParenthesis) else {
            return .variable(name: name, position: position)
        }

        guard let function = ExpressionFunction(rawValue: name) else {
            throw InvalidExpressionError(reason: .unknownFunction(name), position: position)
        }

        var arguments: [ExpressionNode] = []
        if current.kind != .symbol(.rightParenthesis) {
            repeat {
                arguments.append(try parseExpression())
            } while consume(.comma)
        }
        guard consume(.rightParenthesis) else {
            throw InvalidExpressionError(reason: .unbalancedParenthesis, position: parenthesis.position)
        }
        guard function.arity.accepts(arguments.count) else {
            throw InvalidExpressionError(
                reason: .wrongArgumentCount(
                    function: name,
                    expected: function.arity.description,
                    actual: arguments.count
                ),
                position: position
            )
        }
        return .call(function, arguments)
    }
}
