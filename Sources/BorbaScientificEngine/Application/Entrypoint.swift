import Foundation
import Logging
import Vapor

/// Process entry point of the engine.
public enum Entrypoint {
    /// Loads the configuration, boots the application and blocks until it is asked to stop.
    ///
    /// The Vapor command to execute (`serve`, `routes`, ...) is taken from the command-line arguments and
    /// defaults to `serve`.
    ///
    /// - Parameters:
    ///   - variables: Environment variables the configuration is read from.
    ///   - arguments: Command-line arguments, starting with the executable name.
    /// - Returns: `EXIT_SUCCESS` after a clean shutdown and `EXIT_FAILURE` when startup or shutdown failed.
    public static func run(
        environment variables: [String: String],
        arguments: [String]
    ) async -> Int32 {
        do {
            let configuration = try ConfigurationLoader.load(from: variables)
            LoggingBootstrap.bootstrap(configuration.logging)

            let environment = Environment(name: configuration.environment.rawValue, arguments: arguments)
            let application = try await Application.make(environment)

            return await serve(application, with: configuration)
        } catch {
            reportStartupFailure(error)
            return EXIT_FAILURE
        }
    }

    /// Runs the application to completion and shuts it down, whatever the outcome.
    ///
    /// - Parameters:
    ///   - application: Application created for this process.
    ///   - configuration: Validated runtime configuration.
    /// - Returns: `EXIT_SUCCESS` when the application ran and shut down cleanly, `EXIT_FAILURE` otherwise.
    private static func serve(
        _ application: Application,
        with configuration: AppConfiguration
    ) async -> Int32 {
        var exitCode = EXIT_SUCCESS

        do {
            try ApplicationFactory.configure(application, with: configuration)
            try await application.execute()
        } catch {
            application.logger.critical("Engine terminated with an error", metadata: ["error": "\(error)"])
            exitCode = EXIT_FAILURE
        }

        do {
            try await application.asyncShutdown()
        } catch {
            application.logger.error("Engine shutdown failed", metadata: ["error": "\(error)"])
            exitCode = EXIT_FAILURE
        }

        return exitCode
    }

    /// Writes a startup failure to standard error, the only channel available before logging is configured.
    ///
    /// - Parameter error: The failure to report.
    private static func reportStartupFailure(_ error: any Error) {
        let message = "Engine failed to start: \(error)\n"
        FileHandle.standardError.write(Data(message.utf8))
    }
}
