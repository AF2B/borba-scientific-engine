import Foundation
import Testing

@testable import BorbaScientificCore

@Suite("CalculationValue")
struct CalculationValueTests {
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    @Test("builds nested values from literals")
    func literals() {
        let value: CalculationValue = ["list": [1, 2.5, "three", true, nil], "nested": ["k": 4]]

        #expect(
            value
                == .object([
                    "list": .list([.number(1), .number(2.5), .text("three"), .boolean(true), .null]),
                    "nested": .object(["k": .number(4)]),
                ])
        )
    }

    @Test("round-trips through JSON without changing shape")
    func jsonRoundTrip() throws {
        let original: CalculationValue = [
            "numbers": [1, 2.5, -3],
            "text": "hello",
            "flag": false,
            "nothing": nil,
            "object": ["inner": [[1, 2], [3, 4]]],
        ]

        let data = try encoder.encode(original)
        let decoded = try JSONDecoder().decode(CalculationValue.self, from: data)

        #expect(decoded == original)
    }

    @Test("decodes JSON integers as numbers and keeps booleans distinct")
    func decodesScalars() throws {
        let decoded = try JSONDecoder().decode(CalculationValue.self, from: Data(#"[1, true, "1", null]"#.utf8))

        #expect(decoded == [1, true, "1", nil])
    }

    private static let shapes: [(String, CalculationValue)] = [
        ("[]", CalculationValue.list([])),
        ("{}", CalculationValue.object([:])),
        ("[1, 2.5, -3]", [1, 2.5, -3]),
        (#"[1, "a", true]"#, [1, "a", true]),
        ("[[1, 2], [3, 4]]", [[1, 2], [3, 4]]),
        ("[[], [1]]", [[], [1]]),
        (#"[{"a": [1, 2]}, null]"#, [["a": [1, 2]], nil]),
        ("[true, false]", [true, false]),
        (#"["1", "2"]"#, ["1", "2"]),
        ("1e3", 1_000),
        ("-0.5", -0.5),
        (#""café 🙂""#, "café 🙂"),
        (#"{"flag": true, "count": 0}"#, ["flag": true, "count": 0]),
    ]

    @Test(
        "decodes each JSON shape to the same value whichever way it is read",
        arguments: shapes
    )
    func decodesShapes(json: String, expected: CalculationValue) throws {
        #expect(try JSONDecoder().decode(CalculationValue.self, from: Data(json.utf8)) == expected)
    }

    @Test("does not mistake a number for a boolean or a boolean for a number")
    func booleansAreNotNumbers() throws {
        let decoded = try JSONDecoder().decode(CalculationValue.self, from: Data("[0, 1, false, true]".utf8))

        #expect(decoded == [0, 1, false, true])
    }

    @Test("rejects what is not JSON of a supported shape")
    func rejectsInvalid() {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(CalculationValue.self, from: Data("[1, 2".utf8))
        }
    }

    @Test(
        "refuses a NUL in text or in the name of a field, wherever it is, because no store of text can keep it",
        arguments: [
            #""a\u0000b""#,
            #"["a", "b\u0000"]"#,
            #"{"field": "value\u0000"}"#,
            #"{"field\u0000": 1}"#,
            #"[[{"field": ["x\u0000"]}]]"#,
        ]
    )
    func refusesNUL(json: String) {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(CalculationValue.self, from: Data(json.utf8))
        }
    }

    @Test("keeps every other control character, which JSON can carry and a store can keep")
    func keepsOtherControlCharacters() throws {
        let decoded = try JSONDecoder().decode(CalculationValue.self, from: Data(#""a\u0001\tb\n\u001f""#.utf8))

        #expect(decoded == .text("a\u{1}\tb\n\u{1F}"))
    }

    @Test("still reads a list as a list and an object as an object, however deep they nest")
    func readsNestedStructures() throws {
        let decoded = try JSONDecoder().decode(
            CalculationValue.self,
            from: Data(#"[{"a": [1, "x", {"b": []}]}, [2, [3]]]"#.utf8)
        )

        let expected: CalculationValue = [
            ["a": [1, "x", ["b": []]]],
            [2, [3]],
        ]
        #expect(decoded == expected)
    }

    @Test("encodes whole numbers without a fractional part")
    func encodesWholeNumbers() throws {
        let data = try encoder.encode(CalculationValue.numbers([5, 0.25]))

        #expect(String(bytes: data, encoding: .utf8) == "[5,0.25]")
    }

    @Test("finds non-finite numbers anywhere in a value")
    func findsNonFiniteNumbers() {
        #expect(CalculationValue.number(1).firstNonFiniteNumber == nil)
        #expect(CalculationValue.number(.infinity).firstNonFiniteNumber == .infinity)
        #expect(CalculationValue.list([1, .object(["deep": .number(.nan)])]).firstNonFiniteNumber?.isNaN == true)
        #expect(CalculationValue.text("inf").firstNonFiniteNumber == nil)
    }

    @Test("exposes typed accessors")
    func accessors() {
        #expect(CalculationValue.number(3).number == 3)
        #expect(CalculationValue.text("a").text == "a")
        #expect(CalculationValue.list([1]).elements == [.number(1)])
        #expect(CalculationValue.object(["k": 1]).fields == ["k": .number(1)])
        #expect(CalculationValue.text("a").number == nil)
    }
}
