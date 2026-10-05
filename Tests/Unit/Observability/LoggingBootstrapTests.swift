import Logging
import Testing

@testable import BorbaScientificEngine

@Suite("LoggingBootstrap")
struct LoggingBootstrapTests {
    private static let label = "test"

    @Test("builds a JSON handler at the configured level")
    func jsonHandler() {
        let settings = LoggingSettings(level: .warning, format: .json)

        let handler = LoggingBootstrap.makeHandler(label: Self.label, metadataProvider: nil, settings: settings)

        #expect(handler is StructuredLogHandler)
        #expect(handler.logLevel == .warning)
    }

    @Test("builds a console handler at the configured level")
    func consoleHandler() {
        let settings = LoggingSettings(level: .debug, format: .console)

        let handler = LoggingBootstrap.makeHandler(label: Self.label, metadataProvider: nil, settings: settings)

        #expect(handler is StreamLogHandler)
        #expect(handler.logLevel == .debug)
    }
}
