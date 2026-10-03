import Logging
import Testing

@testable import BorbaScientificEngine

/// Builds environment dictionaries for configuration tests.
enum ConfigurationFixture {
    static let databaseURL = "postgres://engine:fixture-password@localhost:5432/engine"
    static let databasePassword = "fixture-password"

    /// Smallest environment that loads successfully.
    static let minimal = environment([.databaseURL: databaseURL])

    /// Converts typed variable names into the raw dictionary the loader consumes.
    static func environment(_ variables: [EnvironmentVariable: String]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: variables.map { ($0.key.rawValue, $0.value) })
    }
}

@Suite("ConfigurationLoader")
struct ConfigurationLoaderTests {
    @Test("applies development defaults when only the database URL is set")
    func developmentDefaults() throws {
        let configuration = try ConfigurationLoader.load(from: ConfigurationFixture.minimal)

        #expect(configuration.environment == .development)
        #expect(configuration.http.host == ConfigurationDefaults.loopbackHost)
        #expect(configuration.http.port == ConfigurationDefaults.httpPort)
        #expect(configuration.http.maximumBodySizeBytes == ConfigurationDefaults.maximumBodySizeBytes)
        #expect(configuration.http.shutdownTimeout == .seconds(ConfigurationDefaults.shutdownTimeoutSeconds))
        #expect(configuration.logging.level == .debug)
        #expect(configuration.logging.format == .console)
        #expect(configuration.version.number == ConfigurationDefaults.applicationVersion)
        #expect(configuration.sentry.isEnabled == false)
    }

    @Test("applies calculation and statement limits by default")
    func calculationDefaults() throws {
        let configuration = try ConfigurationLoader.load(from: ConfigurationFixture.minimal)

        let expectedStatementTimeout = Duration.milliseconds(ConfigurationDefaults.databaseStatementTimeoutMilliseconds)
        let expectedCalculationTimeout = Duration.milliseconds(ConfigurationDefaults.calculationTimeoutMilliseconds)
        #expect(configuration.database.statementTimeout == expectedStatementTimeout)
        #expect(configuration.calculation.timeout == expectedCalculationTimeout)
        #expect(configuration.calculation.maximumBatchSize == ConfigurationDefaults.batchMaximumSize)
        #expect(configuration.calculation.batchConcurrency == ConfigurationDefaults.batchConcurrency)
    }

    @Test(
        "applies deployment defaults in deployed environments",
        arguments: [AppEnvironment.staging, AppEnvironment.production]
    )
    func deployedDefaults(environment: AppEnvironment) throws {
        let variables = ConfigurationFixture.environment([
            .databaseURL: ConfigurationFixture.databaseURL,
            .applicationEnvironment: environment.rawValue,
        ])

        let configuration = try ConfigurationLoader.load(from: variables)

        #expect(configuration.environment == environment)
        #expect(configuration.environment.isDeployed)
        #expect(configuration.http.host == ConfigurationDefaults.anyInterfaceHost)
        #expect(configuration.logging.level == .info)
        #expect(configuration.logging.format == .json)
    }

    @Test("honours explicit overrides")
    func explicitOverrides() throws {
        let variables = ConfigurationFixture.environment([
            .databaseURL: ConfigurationFixture.databaseURL,
            .applicationEnvironment: "TEST",
            .applicationVersion: "1.2.3",
            .applicationCommit: "abc123",
            .httpHost: "10.0.0.5",
            .httpPort: "9090",
            .httpMaximumBodySizeBytes: "2048",
            .shutdownTimeoutSeconds: "30",
            .logLevel: "error",
            .logFormat: "json",
            .databaseMaximumConnectionsPerEventLoop: "4",
            .databasePoolTimeoutMilliseconds: "750",
            .databaseStatementTimeoutMilliseconds: "1500",
            .calculationTimeoutMilliseconds: "250",
            .batchMaximumSize: "20",
            .batchConcurrency: "3",
            .sentryDSN: "https://public@sentry.example.com/1",
            .sentrySampleRate: "0.25",
        ])

        let configuration = try ConfigurationLoader.load(from: variables)

        #expect(configuration.environment == .test)
        #expect(configuration.version.number == "1.2.3")
        #expect(configuration.version.commit == "abc123")
        #expect(configuration.http.host == "10.0.0.5")
        #expect(configuration.http.port == 9_090)
        #expect(configuration.http.maximumBodySizeBytes == 2_048)
        #expect(configuration.http.shutdownTimeout == .seconds(30))
        #expect(configuration.logging.level == .error)
        #expect(configuration.logging.format == .json)
        #expect(configuration.database.maximumConnectionsPerEventLoop == 4)
        #expect(configuration.database.connectionPoolTimeout == .milliseconds(750))
        #expect(configuration.database.statementTimeout == .milliseconds(1_500))
        #expect(configuration.calculation.timeout == .milliseconds(250))
        #expect(configuration.calculation.maximumBatchSize == 20)
        #expect(configuration.calculation.batchConcurrency == 3)
        #expect(configuration.sentry.isEnabled)
        #expect(configuration.sentry.sampleRate == 0.25)
    }

    @Test("treats blank values as unset")
    func blankValuesAreUnset() throws {
        let variables = ConfigurationFixture.environment([
            .databaseURL: ConfigurationFixture.databaseURL,
            .httpPort: "   ",
            .sentryDSN: "",
        ])

        let configuration = try ConfigurationLoader.load(from: variables)

        #expect(configuration.http.port == ConfigurationDefaults.httpPort)
        #expect(configuration.sentry.isEnabled == false)
    }

    @Test("requires the database URL in every environment", arguments: AppEnvironment.allCases)
    func databaseURLIsRequired(environment: AppEnvironment) {
        let variables = ConfigurationFixture.environment([.applicationEnvironment: environment.rawValue])

        #expect(throws: ConfigurationError.self) {
            try ConfigurationLoader.load(from: variables)
        }
    }

    @Test(
        "rejects malformed values and names the offending variable",
        arguments: [
            (EnvironmentVariable.applicationEnvironment, "qa"),
            (.httpPort, "0"),
            (.httpPort, "65536"),
            (.httpPort, "eighty"),
            (.httpMaximumBodySizeBytes, "10"),
            (.shutdownTimeoutSeconds, "-1"),
            (.logLevel, "verbose"),
            (.logFormat, "xml"),
            (.databaseURL, "mysql://localhost/engine"),
            (.databaseURL, "postgres://localhost"),
            (.databaseURL, "not a url"),
            (.databaseMaximumConnectionsPerEventLoop, "0"),
            (.databasePoolTimeoutMilliseconds, "5"),
            (.databaseStatementTimeoutMilliseconds, "5"),
            (.calculationTimeoutMilliseconds, "5"),
            (.calculationTimeoutMilliseconds, "slow"),
            (.batchMaximumSize, "0"),
            (.batchMaximumSize, "1001"),
            (.batchConcurrency, "0"),
            (.batchConcurrency, "65"),
            (.sentrySampleRate, "1.5"),
        ]
    )
    func rejectsMalformedValues(variable: EnvironmentVariable, value: String) {
        var variables = ConfigurationFixture.minimal
        variables[variable.rawValue] = value

        let error = #expect(throws: ConfigurationError.self) {
            try ConfigurationLoader.load(from: variables)
        }

        guard case .invalid(let issues)? = error else {
            Issue.record("Expected an invalid-configuration error")
            return
        }
        #expect(issues.map(\.variable) == [variable.rawValue])
    }

    @Test("reports every problem at once")
    func aggregatesIssues() {
        let variables = ConfigurationFixture.environment([
            .httpPort: "0",
            .logLevel: "verbose",
        ])

        let error = #expect(throws: ConfigurationError.self) {
            try ConfigurationLoader.load(from: variables)
        }

        guard case .invalid(let issues)? = error else {
            Issue.record("Expected an invalid-configuration error")
            return
        }
        let reported = Set(issues.map(\.variable))
        #expect(
            reported == [
                EnvironmentVariable.httpPort.rawValue,
                EnvironmentVariable.logLevel.rawValue,
                EnvironmentVariable.databaseURL.rawValue,
            ]
        )
    }

    @Test("never echoes secrets in errors or descriptions")
    func keepsSecretsOut() throws {
        var invalid = ConfigurationFixture.minimal
        invalid[EnvironmentVariable.httpPort.rawValue] = "0"
        invalid[EnvironmentVariable.databaseURL.rawValue] = "mysql://user:\(ConfigurationFixture.databasePassword)@h/db"

        let error = #expect(throws: ConfigurationError.self) {
            try ConfigurationLoader.load(from: invalid)
        }
        let loaded = try ConfigurationLoader.load(from: ConfigurationFixture.minimal)

        #expect(error.map { "\($0)" }?.contains(ConfigurationFixture.databasePassword) == false)
        #expect("\(loaded)".contains(ConfigurationFixture.databasePassword) == false)
        #expect("\(loaded.database.url)" == "<redacted>")
        #expect(loaded.database.url.reveal() == ConfigurationFixture.databaseURL)
    }
}
