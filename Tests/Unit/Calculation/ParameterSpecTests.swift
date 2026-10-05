import Foundation
import Testing

@testable import BorbaScientificCore

@Suite("ParameterSpec")
struct ParameterSpecTests {
    private enum Color: String, CaseIterable, Sendable {
        case red
        case green
    }

    /// Binds a raw value and returns the rejection reason, or `nil` when the value is accepted.
    private func rejection(
        of declaration: some ParameterDeclaration,
        _ raw: CalculationValue?
    ) -> String? {
        do {
            _ = try declaration.bind(raw)
            return nil
        } catch {
            return error.reason
        }
    }

    @Test("accepts numbers within bounds and reports the violated bound")
    func numberBounds() throws {
        let rate = ParameterSpec.number("rate", summary: "A rate.", bounds: .between(0, 1))

        #expect(rejection(of: rate, 0.5) == nil)
        #expect(rejection(of: rate, 0) == nil)
        #expect(rejection(of: rate, 1.5) == "must be at most 1")
        #expect(rejection(of: rate, -0.1) == "must be at least 0")
        #expect(rejection(of: rate, "0.5") == "must be a number")
        #expect(rejection(of: rate, .number(.infinity)) == "must be a finite number")
    }

    @Test("distinguishes inclusive and exclusive bounds")
    func exclusiveBounds() {
        let positive = ParameterSpec.number("amount", summary: "An amount.", bounds: .positive)

        #expect(rejection(of: positive, 0) == "must be greater than 0")
        #expect(rejection(of: positive, 0.000_1) == nil)
        #expect(rejection(of: ParameterSpec.number("m", summary: "", bounds: .lessThan(5)), 5) == "must be less than 5")
    }

    @Test("accepts a value equal to an inclusive upper limit and rejects the next one")
    func inclusiveUpperBound() {
        let limit = ParameterSpec.number("limit", summary: "A limit.", bounds: .atMost(5))

        #expect(rejection(of: limit, 5) == nil)
        #expect(rejection(of: limit, 5.000_1) == "must be at most 5")
    }

    @Test("accepts only whole numbers within the range for integers")
    func integers() {
        let count = ParameterSpec.integer("count", summary: "A count.", range: 1...10)

        #expect(rejection(of: count, 5) == nil)
        #expect(rejection(of: count, 5.5) == "must be a whole number")
        #expect(rejection(of: count, 11) == "must be between 1 and 10")
        #expect(rejection(of: count, "5") == "must be a number")
    }

    @Test("reads decimals from numbers and from numeric text without binary rounding")
    func decimals() throws {
        let amount = ParameterSpec.decimal("amount", summary: "An amount.", bounds: .nonNegative)

        let fromText = try #require(try amount.bind("1234.56") as? Decimal)
        let fromNumber = try #require(try amount.bind(0.1) as? Decimal)

        #expect(fromText == Decimal(string: "1234.56"))
        #expect(fromNumber == Decimal(string: "0.1"))
        #expect(rejection(of: amount, "twelve") == "must be a number or numeric text")
        #expect(rejection(of: amount, -1) == "must be at least 0")
    }

    @Test("limits text length and enforces choices")
    func textAndChoices() {
        let label = ParameterSpec.text("label", summary: "A label.", maximumLength: 3)
        let color = ParameterSpec<Color>.choice("color", summary: "A color.")

        #expect(rejection(of: label, "abc") == nil)
        #expect(rejection(of: label, "abcd") == "must be at most 3 characters long")
        #expect(rejection(of: label, 1) == "must be text")
        #expect(rejection(of: color, "red") == nil)
        #expect(rejection(of: color, "blue") == "must be one of: red, green")
    }

    @Test("validates lists element by element and names the failing index")
    func lists() {
        let values = ParameterSpec.numberList("values", summary: "Values.", size: 2...3, elements: .nonNegative)

        #expect(rejection(of: values, [1, 2]) == nil)
        #expect(rejection(of: values, [1]) == "must contain between 2 and 3 elements")
        #expect(rejection(of: values, [1, -2]) == "element 1 must be at least 0")
        #expect(rejection(of: values, [1, "x"]) == "element 1 must be a number")
        #expect(rejection(of: values, 7) == "must be a list")
    }

    @Test("requires matrices to be rectangular")
    func matrices() {
        let matrix = ParameterSpec.numberMatrix("m", summary: "A matrix.", rows: 1...3, columns: 1...3)

        #expect(rejection(of: matrix, [[1, 2], [3, 4]]) == nil)
        #expect(rejection(of: matrix, [[1, 2], [3]]) == "must be a list of equally long lists of numbers")
        #expect(rejection(of: matrix, [[1, 2, 3, 4]]) == "element 0 must contain between 1 and 3 elements")
    }

    @Test("validates maps of numbers")
    func maps() {
        let variables = ParameterSpec.numberMap("variables", summary: "Variables.", size: 0...2)

        #expect(rejection(of: variables, ["x": 1]) == nil)
        #expect(rejection(of: variables, ["a": 1, "b": 2, "c": 3]) == "must contain between 0 and 2 entries")
        #expect(rejection(of: variables, ["x": "one"]) == "entry 'x' must be a number")
        #expect(rejection(of: variables, [1]) == "must be an object whose values are numbers")
    }

    @Test("treats omitted and null values alike")
    func omittedValues() throws {
        let required = ParameterSpec.number("a", summary: "A.")
        let optional = ParameterSpec.number("b", summary: "B.", default: 7)

        #expect(rejection(of: required, nil) == "is required")
        #expect(rejection(of: required, .null) == "is required")
        #expect(try optional.bind(nil) as? Double == 7)
        #expect(try optional.bind(.null) as? Double == 7)
        #expect(optional.descriptor.requirement == .optional(defaultValue: 7))
        #expect(required.descriptor.requirement == .required)
    }

    @Test("describes the accepted shape for documentation")
    func descriptors() {
        let color = ParameterSpec<Color>.choice("color", summary: "A color.", default: .green)

        #expect(color.descriptor.kind == .choice(["red", "green"]))
        #expect(color.descriptor.requirement == .optional(defaultValue: "green"))
    }
}
