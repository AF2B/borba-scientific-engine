import BorbaScientificCore
import Foundation
import Testing

@testable import BorbaScientificEngine

@Suite("RequestFingerprinter")
struct RequestFingerprinterTests {
    private let fingerprinter = RequestFingerprinter()

    private func request(
        _ module: String = "arithmetic",
        _ operation: String = "add",
        json parameters: String
    ) throws -> CalculationRequest {
        CalculationRequest(
            type: CalculationType(module: ModuleName(module), operation: OperationName(operation)),
            parameters: try JSONDecoder().decode([String: CalculationValue].self, from: Data(parameters.utf8))
        )
    }

    @Test("digests the canonical form of the request, which makes the value stable across releases")
    func goldenValue() throws {
        let fingerprint = try fingerprinter.fingerprint(of: try request(json: #"{"a": 2, "b": 3}"#))

        #expect(fingerprint.rawValue == "sha256:f7bdde44d794ca8f6e504b03e916f7e87206c59c1a457fe71e6df24e6f5cda4a")
    }

    @Test("ignores key order, whitespace and how a number is spelt")
    func ignoresSpelling() throws {
        let reference = try fingerprinter.fingerprint(of: try request(json: #"{"a": 2, "b": 3}"#))

        #expect(try fingerprinter.fingerprint(of: try request(json: #"{"b":3,"a":2}"#)) == reference)
        #expect(try fingerprinter.fingerprint(of: try request(json: #"{ "a" : 2.0, "b" : 3e0 }"#)) == reference)
    }

    @Test("tells requests apart when anything that matters differs")
    func detectsDifferences() throws {
        let reference = try fingerprinter.fingerprint(of: try request(json: #"{"a": 2, "b": 3}"#))

        #expect(try fingerprinter.fingerprint(of: try request(json: #"{"a": 2, "b": 4}"#)) != reference)
        #expect(
            try fingerprinter.fingerprint(of: try request("arithmetic", "subtract", json: #"{"a": 2, "b": 3}"#))
                != reference
        )
        #expect(
            try fingerprinter.fingerprint(of: try request("percentage", "add", json: #"{"a": 2, "b": 3}"#)) != reference
        )
        #expect(try fingerprinter.fingerprint(of: try request(json: #"{"a": 2, "b": 3, "c": 1}"#)) != reference)
    }

    @Test("digests nested values")
    func nestedValues() throws {
        let one = try fingerprinter.fingerprint(
            of: try request("linear_algebra", "determinant", json: #"{"matrix": [[1, 2], [3, 4]]}"#)
        )
        let other = try fingerprinter.fingerprint(
            of: try request("linear_algebra", "determinant", json: #"{"matrix": [[1, 2], [4, 3]]}"#)
        )

        #expect(one != other)
    }
}

@Suite("Hexadecimal")
struct HexadecimalTests {
    @Test("writes two lowercase digits per byte")
    func encode() {
        #expect(Hexadecimal.encode([0x00, 0x0F, 0xA5, 0xFF]) == "000fa5ff")
        #expect(Hexadecimal.encode([UInt8]()).isEmpty)
    }
}
