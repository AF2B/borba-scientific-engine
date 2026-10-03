/// An expression that has been parsed once and can be evaluated many times.
struct CompiledExpression: Sendable, Equatable {
    /// The syntax tree.
    let root: ExpressionNode

    /// The variables the expression reads, excluding built-in constants.
    let variableNames: Set<String>

    /// Evaluates the expression.
    ///
    /// - Parameter context: The values of the variables and the angle unit.
    /// - Returns: The numeric result.
    /// - Throws: ``CalculationError`` for a division by zero, a value outside a function's domain or an undefined
    ///   variable.
    func evaluate(in context: EvaluationContext) throws(CalculationError) -> Double {
        try root.evaluate(in: context)
    }
}

/// Turns expression text into a ``CompiledExpression``.
///
/// This is a protocol because there are two real implementations — one that always parses and one that remembers
/// recent results — and because modules and tests receive their compiler through injection.
protocol ExpressionCompiling: Sendable {
    /// Compiles an expression.
    ///
    /// - Parameter source: The text of the expression.
    /// - Returns: The compiled expression.
    /// - Throws: ``InvalidExpressionError`` locating the first problem.
    func compile(_ source: String) async throws(InvalidExpressionError) -> CompiledExpression
}

/// Compiles an expression from scratch on every call.
struct ParsingExpressionCompiler: ExpressionCompiling {
    /// Parses the text and records the variables it uses.
    ///
    /// - Parameter source: The text of the expression.
    /// - Returns: The compiled expression.
    /// - Throws: ``InvalidExpressionError`` locating the first problem.
    func compile(_ source: String) async throws(InvalidExpressionError) -> CompiledExpression {
        let root = try ExpressionParser.parse(source)
        return CompiledExpression(root: root, variableNames: root.variableNames)
    }
}

/// Remembers the most recently compiled expressions so that repeated requests skip parsing.
///
/// Caching is justified here because the same formula is often evaluated again and again with different variables,
/// and because it is safe: compilation is a pure function of the source text.
///
/// - **Key:** the exact expression text.
/// - **Capacity:** ``defaultCapacity`` entries, evicting the least recently used.
/// - **TTL and invalidation:** none are needed; a compiled expression never goes stale.
/// - **Consistency:** a hit returns exactly what a miss would have computed.
/// - **Failure behavior:** invalid expressions are not cached and fail again the same way; the cache never makes a
///   request fail.
///
/// The cache is an actor because lookups and evictions mutate shared state from concurrent requests.
actor CachingExpressionCompiler: ExpressionCompiling {
    /// Expressions kept by default. A few hundred formulas cost well under a megabyte.
    static let defaultCapacity = 256

    private struct Entry {
        let expression: CompiledExpression
        var lastUse: UInt64
    }

    private let compiler: any ExpressionCompiling
    private let capacity: Int
    private var entries: [String: Entry] = [:]
    private var useCounter: UInt64 = 0
    private(set) var hitCount = 0
    private(set) var missCount = 0

    /// Creates a cache in front of another compiler.
    ///
    /// - Parameters:
    ///   - compiler: The compiler consulted on a miss.
    ///   - capacity: The number of expressions to keep.
    init(
        wrapping compiler: any ExpressionCompiling = ParsingExpressionCompiler(),
        capacity: Int = CachingExpressionCompiler.defaultCapacity
    ) {
        self.compiler = compiler
        self.capacity = max(capacity, 1)
    }

    /// Number of expressions currently remembered.
    var entryCount: Int {
        entries.count
    }

    /// Returns the compiled expression, from memory when possible.
    ///
    /// - Parameter source: The text of the expression.
    /// - Returns: The compiled expression.
    /// - Throws: ``InvalidExpressionError`` locating the first problem.
    func compile(_ source: String) async throws(InvalidExpressionError) -> CompiledExpression {
        useCounter += 1

        if var entry = entries[source] {
            entry.lastUse = useCounter
            entries[source] = entry
            hitCount += 1
            return entry.expression
        }

        missCount += 1
        let expression = try await compiler.compile(source)
        remember(expression, for: source)
        return expression
    }

    private func remember(
        _ expression: CompiledExpression,
        for source: String
    ) {
        if entries.count >= capacity, entries[source] == nil {
            evictLeastRecentlyUsed()
        }
        useCounter += 1
        entries[source] = Entry(expression: expression, lastUse: useCounter)
    }

    private func evictLeastRecentlyUsed() {
        guard let oldest = entries.min(by: { $0.value.lastUse < $1.value.lastUse })?.key else {
            return
        }
        entries.removeValue(forKey: oldest)
    }
}
