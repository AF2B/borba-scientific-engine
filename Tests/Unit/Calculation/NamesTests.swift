import Testing

@testable import BorbaScientificCore

@Suite("Names")
struct NamesTests {
    @Test("accepts the form every name has", arguments: ["statistics", "compound_interest", "log10", "a", "x_1"])
    func accepts(text: String) {
        #expect(NameSyntax.isValid(text))
        #expect(ModuleName(validating: text)?.rawValue == text)
    }

    @Test(
        "refuses everything else, including what no store of text can keep",
        arguments: [
            "",
            "Statistics",
            "9lives",
            "two words",
            "dash-ed",
            "caf\u{E9}",
            "a\u{0}b",
            "\u{0}",
            "_leading",
            String(repeating: "a", count: NameSyntax.maximumLength + 1),
        ]
    )
    func refuses(text: String) {
        #expect(!NameSyntax.isValid(text))
        #expect(OperationName(validating: text) == nil)
    }

    @Test("accepts a name of the longest length")
    func longest() {
        #expect(NameSyntax.isValid(String(repeating: "a", count: NameSyntax.maximumLength)))
    }

    @Test("is the form of every module and every operation the engine has")
    func everyRegisteredNameIsValid() {
        for module in ModuleRegistry.standard().modules {
            #expect(NameSyntax.isValid(module.name.rawValue), "the module \(module.name)")

            for operation in module.operations {
                #expect(NameSyntax.isValid(operation.type.operation.rawValue), "the operation \(operation.type)")
            }
        }
    }
}
