import AsyncKit
import BorbaScientificCore
import Foundation
import NIOCore
import PostgresNIO

/// Translates whatever the database stack throws into the application's own ``RepositoryError``, so no caller ever
/// depends on PostgresNIO, AsyncKit or NIO types.
enum RepositoryErrorMapping {
    /// SQLSTATE codes and classes, from the PostgreSQL error code appendix.
    private enum SQLState {
        static let connectionExceptionClass = "08"
        static let integrityViolationClass = "23"
        static let insufficientResourcesClass = "53"
        static let operatorInterventionClass = "57"
        static let queryCanceled = "57014"
        static let serializationFailure = "40001"
        static let deadlockDetected = "40P01"
    }

    /// Classifies a failure of a database call.
    ///
    /// - Parameter error: Whatever was thrown.
    /// - Returns: The matching repository error.
    static func map(_ error: any Error) -> RepositoryError {
        switch error {
        case let repositoryError as RepositoryError:
            return repositoryError
        case let postgres as PSQLError:
            return map(postgres)
        case ConnectionPoolTimeoutError.connectionRequestTimeout:
            return .timeout
        case is AsyncKit.ConnectionPoolError:
            return .unavailable(reason: "the connection pool has shut down")
        case is IOError, is ChannelError:
            return .unavailable(reason: "network failure: \(type(of: error))")
        case let decoding as DecodingError:
            return .corrupted(reason: "stored data could not be decoded: \(decoding)")
        case is CancellationError:
            return .unavailable(reason: "the operation was cancelled")
        default:
            return .unexpected(reason: "\(type(of: error))")
        }
    }

    private static func map(_ error: PSQLError) -> RepositoryError {
        switch error.code {
        case .server:
            return map(serverError: error)
        case .connectionError, .clientClosedConnection, .serverClosedConnection, .poolClosed, .uncleanShutdown,
            .queryCancelled, .sslUnsupported, .failedToAddSSLHandler:
            return .unavailable(reason: "connection failure: \(error.code)")
        default:
            return .unexpected(reason: "PostgresNIO \(error.code)")
        }
    }

    private static func map(serverError error: PSQLError) -> RepositoryError {
        let state = error.serverInfo?[.sqlState] ?? ""
        let message = error.serverInfo?[.message] ?? "no message"
        let reason = "SQLSTATE \(state): \(message)"

        if state == SQLState.queryCanceled {
            return .timeout
        }
        if state.hasPrefix(SQLState.integrityViolationClass) {
            return .integrity(reason: reason)
        }
        let isTransient =
            state.hasPrefix(SQLState.connectionExceptionClass)
            || state.hasPrefix(SQLState.insufficientResourcesClass)
            || state.hasPrefix(SQLState.operatorInterventionClass)
            || state == SQLState.serializationFailure
            || state == SQLState.deadlockDetected
        return isTransient ? .unavailable(reason: reason) : .unexpected(reason: reason)
    }
}
