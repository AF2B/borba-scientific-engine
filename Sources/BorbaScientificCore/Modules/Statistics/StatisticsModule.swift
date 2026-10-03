// Worked examples document an operation with concrete numbers; those literals are the data being documented.
// swiftlint:disable no_magic_numbers

extension ModuleName {
    /// Descriptive statistics, correlation and regression.
    public static let statistics = ModuleName("statistics")
}

/// Wire names of the statistics operations.
enum StatisticsOperation: String, CaseIterable {
    case mean
    case median
    case mode
    case variance
    case standardDeviation = "standard_deviation"
    case minimum
    case maximum
    case range
    case percentile
    case quartiles
    case covariance
    case correlation
    case linearRegression = "linear_regression"
    case summary
}

/// Parameters of the statistics operations. Each name is spelled once, here.
enum StatisticsParameters {
    static let values = ParameterSpec.numberList("values", summary: "The observations.")
    static let x = ParameterSpec.numberList("x", summary: "Observations of the independent variable.")
    static let y = ParameterSpec.numberList("y", summary: "Observations of the dependent variable; one per x.")
    static let kind = ParameterSpec<VarianceKind>.choice(
        "kind",
        summary: "Whether the observations are a whole population (divide by n) or a sample (divide by n - 1).",
        default: .sample
    )
    static let percentile = ParameterSpec.number(
        "percentile",
        summary: "The percentage of observations that fall below the result, from 0 to 100.",
        bounds: .between(0, Percentage.wholeInPercent)
    )
}

/// Descriptive statistics for samples of numbers, plus correlation and linear regression for paired samples.
public struct StatisticsModule: CalculationModule {
    /// Name of the module on the wire.
    public let name = ModuleName.statistics

    /// One-sentence description of what the module covers.
    public let summary = "Descriptive statistics, correlation and linear regression."

    /// The operations the module offers, one per case of its operation enumeration.
    public let operations: [OperationDefinition]

    /// Creates the module.
    public init() {
        operations = StatisticsOperation.allCases.map(Self.definition(for:))
    }

    private typealias P = StatisticsParameters

    /// Maps every operation to its definition. The switch is exhaustive, so adding an operation without a
    /// definition does not compile.
    private static func definition(for operation: StatisticsOperation) -> OperationDefinition {
        switch operation {
        case .mean: mean
        case .median: median
        case .mode: mode
        case .variance: variance
        case .standardDeviation: standardDeviation
        case .minimum: minimum
        case .maximum: maximum
        case .range: range
        case .percentile: percentile
        case .quartiles: quartiles
        case .covariance: covariance
        case .correlation: correlation
        case .linearRegression: linearRegression
        case .summary: summary
        }
    }

    private static let referenceSample: CalculationValue = [2, 4, 4, 4, 5, 5, 7, 9]

    private static let mean = OperationDefinition(
        name: StatisticsOperation.mean,
        summary: "Computes the arithmetic mean of a sample.",
        parameters: [P.values],
        result: .number,
        examples: [OperationExample("Mean of eight observations.", with: [(P.values, referenceSample)], yields: 5)],
        compute: { arguments in
            .number(try Sample(arguments[P.values]).mean)
        }
    )

    private static let median = OperationDefinition(
        name: StatisticsOperation.median,
        summary: "Computes the median: the middle observation, or the midpoint of the two middle ones.",
        parameters: [P.values],
        result: .number,
        examples: [
            OperationExample("Odd count.", with: [(P.values, [1, 3, 2])], yields: 2),
            OperationExample("Even count.", with: [(P.values, [1, 2, 3, 4])], yields: 2.5),
        ],
        compute: { arguments in
            .number(try Sample(arguments[P.values]).median)
        }
    )

    private static let mode = OperationDefinition(
        name: StatisticsOperation.mode,
        summary: "Finds the most frequent observations. The list is empty when no value occurs more than once.",
        parameters: [P.values],
        result: .list(of: .number),
        examples: [
            OperationExample("A single mode.", with: [(P.values, [1, 2, 2, 3, 3, 3])], yields: [3]),
            OperationExample("A tie yields every mode.", with: [(P.values, [1, 1, 2, 2, 3])], yields: [1, 2]),
            OperationExample("No repeated value, no mode.", with: [(P.values, [1, 2, 3])], yields: []),
        ],
        compute: { arguments in
            .numbers(try Sample(arguments[P.values]).modes)
        }
    )

    private static let variance = OperationDefinition(
        name: StatisticsOperation.variance,
        summary: "Computes the variance of a sample or of a whole population.",
        parameters: [P.values, P.kind],
        result: .number,
        examples: [
            OperationExample(
                "Population variance.",
                with: [(P.values, referenceSample), (P.kind, "population")],
                yields: 4
            ),
            OperationExample(
                "Sample variance.",
                with: [(P.values, referenceSample), (P.kind, "sample")],
                yields: 4.571428571428571
            ),
        ],
        compute: { arguments in
            .number(try Sample(arguments[P.values]).variance(kind: arguments[P.kind]))
        }
    )

    private static let standardDeviation = OperationDefinition(
        name: StatisticsOperation.standardDeviation,
        summary: "Computes the standard deviation of a sample or of a whole population.",
        parameters: [P.values, P.kind],
        result: .number,
        examples: [
            OperationExample(
                "Population standard deviation.",
                with: [(P.values, referenceSample), (P.kind, "population")],
                yields: 2
            )
        ],
        compute: { arguments in
            .number(try Sample(arguments[P.values]).standardDeviation(kind: arguments[P.kind]))
        }
    )

    private static let minimum = OperationDefinition(
        name: StatisticsOperation.minimum,
        summary: "Finds the smallest observation.",
        parameters: [P.values],
        result: .number,
        examples: [OperationExample("Smallest of four.", with: [(P.values, [3, 1, 4, 2])], yields: 1)],
        compute: { arguments in
            .number(try Sample(arguments[P.values]).minimum)
        }
    )

    private static let maximum = OperationDefinition(
        name: StatisticsOperation.maximum,
        summary: "Finds the largest observation.",
        parameters: [P.values],
        result: .number,
        examples: [OperationExample("Largest of four.", with: [(P.values, [3, 1, 4, 2])], yields: 4)],
        compute: { arguments in
            .number(try Sample(arguments[P.values]).maximum)
        }
    )

    private static let range = OperationDefinition(
        name: StatisticsOperation.range,
        summary: "Computes the distance between the largest and the smallest observation.",
        parameters: [P.values],
        result: .number,
        examples: [OperationExample("Range of four.", with: [(P.values, [3, 1, 4, 2])], yields: 3)],
        compute: { arguments in
            .number(try Sample(arguments[P.values]).range)
        }
    )

    private static let percentile = OperationDefinition(
        name: StatisticsOperation.percentile,
        summary: "Computes a percentile, interpolating linearly between the nearest ranks.",
        parameters: [P.values, P.percentile],
        result: .number,
        examples: [
            OperationExample(
                "The 40th percentile of five observations.",
                with: [(P.values, [15, 20, 35, 40, 50]), (P.percentile, 40)],
                yields: 29
            )
        ],
        compute: { arguments in
            .number(try Sample(arguments[P.values]).percentile(arguments[P.percentile]))
        }
    )

    private static let quartiles = OperationDefinition(
        name: StatisticsOperation.quartiles,
        summary: "Computes the three quartiles and the interquartile range.",
        parameters: [P.values],
        result: .object([
            FieldShape("first_quartile", .number, "The 25th percentile."),
            FieldShape("median", .number, "The 50th percentile."),
            FieldShape("third_quartile", .number, "The 75th percentile."),
            FieldShape("interquartile_range", .number, "The third quartile minus the first."),
        ]),
        examples: [
            OperationExample(
                "Quartiles of nine consecutive integers.",
                with: [(P.values, [1, 2, 3, 4, 5, 6, 7, 8, 9])],
                yields: [
                    "first_quartile": 3,
                    "median": 5,
                    "third_quartile": 7,
                    "interquartile_range": 4,
                ]
            )
        ],
        compute: { arguments in
            let quartiles = try Sample(arguments[P.values]).quartiles
            return .fields([
                "first_quartile": .number(quartiles.first),
                "median": .number(quartiles.median),
                "third_quartile": .number(quartiles.third),
                "interquartile_range": .number(quartiles.interquartileRange),
            ])
        }
    )

    private static let covariance = OperationDefinition(
        name: StatisticsOperation.covariance,
        summary: "Computes how two variables vary together.",
        parameters: [P.x, P.y, P.kind],
        result: .number,
        examples: [
            OperationExample(
                "Perfectly aligned variables, population covariance.",
                with: [(P.x, [1, 2, 3, 4, 5]), (P.y, [2, 4, 6, 8, 10]), (P.kind, "population")],
                yields: 4
            )
        ],
        compute: { arguments in
            .number(try PairedSample(x: arguments[P.x], y: arguments[P.y]).covariance(kind: arguments[P.kind]))
        }
    )

    private static let correlation = OperationDefinition(
        name: StatisticsOperation.correlation,
        summary: "Computes Pearson's correlation coefficient between two variables.",
        parameters: [P.x, P.y],
        result: .number,
        examples: [
            OperationExample(
                "A perfect linear relationship.",
                with: [(P.x, [1, 2, 3, 4, 5]), (P.y, [2, 4, 6, 8, 10])],
                yields: 1
            ),
            OperationExample(
                "A perfect inverse relationship.",
                with: [(P.x, [1, 2, 3]), (P.y, [3, 2, 1])],
                yields: -1
            ),
        ],
        compute: { arguments in
            .number(try PairedSample(x: arguments[P.x], y: arguments[P.y]).correlation())
        }
    )

    private static let linearRegression = OperationDefinition(
        name: StatisticsOperation.linearRegression,
        summary: "Fits a straight line y = slope * x + intercept by least squares.",
        parameters: [P.x, P.y],
        result: .object([
            FieldShape("slope", .number, "Change in y per unit of x."),
            FieldShape("intercept", .number, "Value of y where the line crosses x = 0."),
            FieldShape("r_squared", .number, "Share of the variance of y explained by the line, from 0 to 1."),
        ]),
        examples: [
            OperationExample(
                "Points on the line y = 2x.",
                with: [(P.x, [1, 2, 3, 4, 5]), (P.y, [2, 4, 6, 8, 10])],
                yields: ["slope": 2, "intercept": 0, "r_squared": 1]
            )
        ],
        compute: { arguments in
            let fit = try PairedSample(x: arguments[P.x], y: arguments[P.y]).linearRegression()
            return .fields([
                "slope": .number(fit.slope),
                "intercept": .number(fit.intercept),
                "r_squared": .number(fit.rSquared),
            ])
        }
    )

    private static let summary = OperationDefinition(
        name: StatisticsOperation.summary,
        summary: "Summarizes a sample: size, total, centre, extremes and spread.",
        parameters: [P.values],
        result: .object([
            FieldShape("count", .number, "Number of observations."),
            FieldShape("sum", .number, "Sum of the observations."),
            FieldShape("mean", .number, "Arithmetic mean."),
            FieldShape("median", .number, "Median."),
            FieldShape("minimum", .number, "Smallest observation."),
            FieldShape("maximum", .number, "Largest observation."),
            FieldShape("range", .number, "Largest minus smallest."),
            FieldShape("population_variance", .number, "Variance treating the sample as the whole population."),
            FieldShape(
                "population_standard_deviation",
                .number,
                "Standard deviation treating the sample as the whole population."
            ),
        ]),
        examples: [
            OperationExample(
                "Summary of five consecutive integers.",
                with: [(P.values, [1, 2, 3, 4, 5])],
                yields: [
                    "count": 5,
                    "sum": 15,
                    "mean": 3,
                    "median": 3,
                    "minimum": 1,
                    "maximum": 5,
                    "range": 4,
                    "population_variance": 2,
                    "population_standard_deviation": 1.4142135623730951,
                ]
            )
        ],
        compute: { arguments in
            let sample = try Sample(arguments[P.values])
            return .fields([
                "count": .number(Double(sample.count)),
                "sum": .number(sample.sum),
                "mean": .number(sample.mean),
                "median": .number(sample.median),
                "minimum": .number(sample.minimum),
                "maximum": .number(sample.maximum),
                "range": .number(sample.range),
                "population_variance": .number(try sample.variance(kind: .population)),
                "population_standard_deviation": .number(try sample.standardDeviation(kind: .population)),
            ])
        }
    )
}

// swiftlint:enable no_magic_numbers
