import BorbaScientificCore
import Logging
import Vapor

extension ErrorClassification {
    /// Expected failures are routine and must not raise alarms; infrastructure and programming errors must.
    var logLevel: Logger.Level {
        switch self {
        case .expectedDomain, .application:
            .info
        case .infrastructure:
            .error
        case .unexpected:
            .critical
        }
    }
}

extension ErrorDescription {
    private static let logMessage = "Request failed"

    /// Writes the failure to a logger at the level its classification deserves.
    ///
    /// The line carries the stable code and the technical diagnostic, which responses never do. The request and
    /// correlation identifiers come from the logger's metadata and from the task-local trace context.
    ///
    /// - Parameter logger: The logger of the request that failed.
    func log(to logger: Logger) {
        var metadata: Logger.Metadata = [
            "error_code": "\(code.rawValue)",
            "status": "\(status.code)",
            "classification": "\(classification)",
        ]
        if let diagnostic {
            metadata["diagnostic"] = "\(diagnostic)"
        }

        logger.log(level: classification.logLevel, "\(Self.logMessage)", metadata: metadata)
    }
}
