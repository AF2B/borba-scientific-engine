# ADR-002 — Domain-Oriented Module Structure

- **Status:** Accepted
- **Date:** 2026-10-03

## Context

The engine is a platform: new kinds of calculation must be addable without editing a growing `switch` over operation
names, and without a layer cake of `Models/`, `Services/` and `Helpers/` folders that scatters one capability across
the tree. At the same time, an HTTP API cannot expose a hundred bespoke endpoints; it needs one uniform way to ask for
"this operation with these parameters" and one uniform way to document it.

## Decision

### Vertical slices

Each capability is a folder under `BorbaScientificCore/Modules/` that owns everything it needs:

```text
Modules/Statistics/
  StatisticsModule.swift   catalog: wire names, parameter declarations, operation definitions
  Sample.swift             domain model and algorithms: pure, strongly typed, no knowledge of JSON
  StatisticsError.swift    the module's typed failures and their mapping to stable error codes
```

A test enforces that every folder has its `<Name>Module.swift` and that nothing is called `Utils` or `Helpers`.

### A generic boundary around typed domains

- **Inside a module** values are domain types (`Sample`, `Matrix`, `LoanTerms`) and functions use typed throws.
- **At the boundary** values are `CalculationValue`, a JSON-shaped enum. The catalog converts between the two.

The engine, the HTTP layer and the history therefore never need to know what an operation computes, which is what lets
one endpoint serve every module.

### Typed parameter declarations

An operation declares parameters as `ParameterSpec<Value>` constants. One declaration serves three purposes: it
validates raw input (types, ranges, sizes, defaults), it produces the documentation and OpenAPI metadata, and it is the
key used to read the validated value back:

```swift
static let values = ParameterSpec.numberList("values", summary: "The observations.")
// …
compute: { arguments in .number(try Sample(arguments[P.values]).mean) }
```

`arguments[P.values]` has type `[Double]`, checked by the compiler. The wire name `"values"` is written once.

### Exhaustive registration of operations

Every module has an operation enumeration (`StatisticsOperation: String, CaseIterable`) and one exhaustive `switch`
that maps each case to its definition. Adding a case without a definition does not compile. Modules are listed once, in
`ModuleRegistry.standard()`; the registry validates names at startup.

### Examples are executable

Every operation carries worked examples. A contract test runs every example of every module through the engine and
checks both the documented result and the declared result shape, so documentation cannot drift from behavior.

### Dependencies between modules

A module may use another module's *domain code* (the evaluator uses `Arithmetic.power`; statistics uses the percent
scale), never its catalog, and the graph must stay acyclic:

```text
Percentage ← Statistics, Financial          Arithmetic, Scientific ← Expression ← Numerical
```

## Consequences

- Adding a module is additive: a folder, one line in the registry, tests. See
  `Documentation/Development/adding-a-calculation-module.md`.
- Each module is testable in isolation and exhaustively, with parameterized tests over tables of inputs.
- The generic boundary costs a conversion per operation; that is small next to the benefit of one uniform API.
- Operation and parameter names are strings on the wire but are declared once as constants or enum cases, never
  repeated as literals.

## Alternatives considered

- **One protocol per operation with associated `Input`/`Output` types.** Maximally typed, but the registry needs type
  erasure for every operation, and metadata (parameter descriptions, constraints) must be duplicated next to the types.
- **A dictionary of closures keyed by operation name, with a `switch` in the handler.** The monolith of conditionals this
  decision exists to avoid.
- **Dynamically loaded plugins.** Real extensibility is not a requirement, and Swift has no stable plugin ABI.
