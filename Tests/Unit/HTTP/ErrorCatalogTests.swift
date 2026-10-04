import BorbaScientificCore
import Foundation
import Testing
import Vapor

@testable import BorbaScientificEngine

@Suite("ErrorCatalog")
struct ErrorCatalogTests {
    private static var codeDeclaration: Regex<(Substring, Substring)> {
        #/ErrorCode\("([A-Z_]+)"\)/#
    }

    @Test("lists every code once and says what it means")
    func entriesAreUniqueAndDocumented() {
        let codes = ErrorCatalog.entries.map(\.code)

        #expect(Set(codes).count == codes.count)
        #expect(ErrorCatalog.entries.allSatisfy { !$0.meaning.isEmpty })
    }

    @Test("covers every error code declared in the sources, and nothing else")
    func matchesTheDeclaredCodes() throws {
        var declared: Set<String> = []
        for file in SourceTree.swiftFiles(under: "Sources") {
            let text = try String(contentsOf: file, encoding: .utf8)
            declared.formUnion(text.matches(of: Self.codeDeclaration).map { String($0.output.1) })
        }
        let catalogued = Set(ErrorCatalog.entries.map(\.code.rawValue))
        let eventOnly = Set(ErrorCatalog.eventOnlyCodes.map(\.rawValue))

        #expect(
            declared.subtracting(catalogued).subtracting(eventOnly).isEmpty,
            "codes missing from the catalog: \(declared.subtracting(catalogued).subtracting(eventOnly).sorted())"
        )
        #expect(
            catalogued.subtracting(declared).isEmpty,
            "catalog entries that no code declares: \(catalogued.subtracting(declared).sorted())"
        )
    }

    @Test(
        "maps codes to the documented statuses",
        arguments: [
            (ErrorCode.invalidRequest, HTTPResponseStatus.badRequest),
            (.unsupportedMediaType, .unsupportedMediaType),
            (.payloadTooLarge, .payloadTooLarge),
            (.notFound, .notFound),
            (.validationFailed, .unprocessableEntity),
            (.unsupportedOperation, .notFound),
            (.calculationNotFound, .notFound),
            (.idempotencyKeyReused, .unprocessableEntity),
            (.divisionByZero, .unprocessableEntity),
            (.calculationTimeout, .unprocessableEntity),
            (.calculationCancelled, .serviceUnavailable),
            (.storageUnavailable, .serviceUnavailable),
            (.storageFailure, .internalServerError),
            (.internalError, .internalServerError),
        ]
    )
    func statuses(code: ErrorCode, expected: HTTPResponseStatus) {
        #expect(ErrorCatalog.status(for: code) == expected)
    }

    @Test("treats a code that is not listed as a domain failure")
    func unlistedCodesAreDomainFailures() {
        #expect(ErrorCatalog.status(for: ErrorCode("SOMETHING_NEW")) == ErrorCatalog.domainFailureStatus)
    }
}
