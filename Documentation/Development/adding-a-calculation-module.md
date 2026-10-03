# Adding a calculation module

A module is a folder under `Sources/BorbaScientificCore/Modules/`. The structure and the reasons behind it are in
[ADR-002](../ADR/ADR-002-domain-oriented-module-structure.md); this is the practical recipe. The running example is a
hypothetical `geometry` module with a `circle_area` operation.

## 1. Model the domain first

Write the pure, typed domain code with its own error type. It knows nothing about JSON, parameters or HTTP:

```swift
// Modules/Geometry/Geometry.swift
enum GeometryError: Error, Sendable, Equatable {
    case negativeRadius
}

enum Geometry {
    /// Computes the area of a circle.
    ///
    /// - Parameter radius: The radius, which must not be negative.
    /// - Returns: The area.
    /// - Throws: ``GeometryError/negativeRadius`` for a negative radius.
    static func circleArea(radius: Double) throws(GeometryError) -> Double {
        guard radius >= 0 else { throw .negativeRadius }
        return .pi * radius * radius
    }
}

extension GeometryError: CalculationFailure {
    var calculationError: CalculationError {
        switch self {
        case .negativeRadius: .invalidParameter("radius", reason: "must not be negative")
        }
    }
}
```

Prefer constraints in the parameter declaration (step 2) for plain range checks; keep domain errors for conditions that
depend on several values or on the computation itself.

## 2. Write the catalog

```swift
// Modules/Geometry/GeometryModule.swift
extension ModuleName {
    public static let geometry = ModuleName("geometry")
}

enum GeometryOperation: String, CaseIterable {
    case circleArea = "circle_area"
}

enum GeometryParameters {
    static let radius = ParameterSpec.number("radius", summary: "The radius of the circle.", bounds: .nonNegative)
}

public struct GeometryModule: CalculationModule {
    public let name = ModuleName.geometry
    public let summary = "Plane geometry."
    public let operations: [OperationDefinition]

    public init() { operations = GeometryOperation.allCases.map(Self.definition(for:)) }

    private typealias P = GeometryParameters

    private static func definition(for operation: GeometryOperation) -> OperationDefinition {
        switch operation {          // exhaustive: a new case without a definition does not compile
        case .circleArea: circleArea
        }
    }

    private static let circleArea = OperationDefinition(
        name: GeometryOperation.circleArea,
        summary: "Computes the area of a circle.",
        parameters: [P.radius],
        result: .number,
        examples: [OperationExample("A unit circle.", with: [(P.radius, 1)], yields: 3.141592653589793)],
        compute: { arguments in .number(try Geometry.circleArea(radius: arguments[P.radius])) }
    )
}
```

Rules that tests enforce: wire names are `snake_case`; every summary is a sentence ending in a period; every operation
has at least one example; every example runs and reproduces its documented result and result shape.

## 3. Register it

Add one line to `ModuleRegistry.standard()` in `Modules/StandardModules.swift`:

```swift
GeometryModule(),
```

## 4. Test it

- Parameterized tests over tables of inputs for the domain functions, including every error case.
- A test through the engine for the error mapping and parameter validation (`CalculationEngine.standard()` and
  `engine.calculate(.geometry, GeometryOperation.circleArea, [...])`).
- Nothing else: the examples are already executed by `ModuleContractTests`, and the API, the metadata endpoints and the
  OpenAPI document pick the module up automatically.

## 5. Document it

Add a line to the module table of the README and an entry to `CHANGELOG.md`. If the module introduces a new failure
code, document it in the API error reference.

## Conventions

- No magic numbers or strings: give every literal a name, or declare it once in an enum or a `ParameterSpec`.
- Long-running loops must call `Cooperation.checkpoint(iteration:)` so the time budget can stop them.
- Bound every input that grows the work (list sizes, matrix dimensions, iteration counts) with a named constant.
- Results must be finite; the engine turns infinities and NaN into errors, but name the failure yourself when you can.
