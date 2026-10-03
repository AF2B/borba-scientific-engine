extension ModuleRegistry {
    /// The registry with every calculation module that ships with the engine.
    ///
    /// This list is the single place where a new module is registered. A registry that fails validation is a
    /// programming error, so startup stops immediately instead of serving a half-working engine.
    ///
    /// The modules that parse expressions share one compiler with a cache, so a formula that is evaluated repeatedly
    /// is parsed once.
    ///
    /// - Returns: A registry containing all built-in modules.
    public static func standard() -> ModuleRegistry {
        let compiler = CachingExpressionCompiler()

        do {
            return try ModuleRegistry(modules: [
                ArithmeticModule(),
                PercentageModule(),
                StatisticsModule(),
                FinancialModule(),
                ScientificModule(),
                ConversionModule(),
                ExpressionModule(compiler: compiler),
            ])
        } catch {
            preconditionFailure("The built-in calculation modules are inconsistent: \(error)")
        }
    }
}
