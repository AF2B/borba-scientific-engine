public import Vapor

/// Composition root: wires configuration, routes and (in later layers) adapters into a Vapor application.
public enum ApplicationFactory {
    /// Applies the configuration to an application and registers its routes.
    ///
    /// - Parameters:
    ///   - application: Freshly created application to configure.
    ///   - configuration: Validated runtime configuration.
    /// - Throws: Any error raised while registering routes.
    public static func configure(
        _ application: Application,
        with configuration: AppConfiguration
    ) throws {
        application.http.server.configuration.hostname = configuration.http.host
        application.http.server.configuration.port = configuration.http.port
        application.routes.defaultMaxBodySize = ByteCount(value: configuration.http.maximumBodySizeBytes)

        try application.register(collection: OperationalRoutes())
    }
}
