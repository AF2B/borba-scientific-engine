import Foundation
import Testing

@testable import BorbaScientificEngine

@Suite("Environment example")
struct EnvironmentExampleTests {
    private static let exampleFileName = ".env.example"
    private static let commentMarker: Character = "#"
    private static let assignmentSeparator: Character = "="
    private static let repositoryDepthFromThisFile = 4

    /// Locates the repository root relative to this source file.
    private static var exampleURL: URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<repositoryDepthFromThisFile {
            url.deleteLastPathComponent()
        }
        return url.appendingPathComponent(exampleFileName)
    }

    @Test("documents every environment variable the engine reads")
    func documentsEveryVariable() throws {
        let contents = try String(contentsOf: Self.exampleURL, encoding: .utf8)

        let documented = Set(
            contents
                .split(separator: "\n")
                .compactMap { line in Self.variableName(inLine: line) }
        )

        let undocumented = EnvironmentVariable.allCases.map(\.rawValue).filter { !documented.contains($0) }
        #expect(undocumented.isEmpty, "Add these variables to .env.example: \(undocumented)")
    }

    @Test("provides a configuration that loads as-is")
    func exampleLoads() throws {
        let contents = try String(contentsOf: Self.exampleURL, encoding: .utf8)

        let assignments =
            contents
            .split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix(String(Self.commentMarker)) }
            .compactMap { line -> (String, String)? in
                guard let separator = line.firstIndex(of: Self.assignmentSeparator) else {
                    return nil
                }
                return (String(line[..<separator]), String(line[line.index(after: separator)...]))
            }

        let configuration = try ConfigurationLoader.load(from: Dictionary(uniqueKeysWithValues: assignments))

        #expect(configuration.environment == .development)
    }

    /// Extracts `NAME` from `NAME=value` and `# NAME=value` lines.
    private static func variableName(inLine line: Substring) -> String? {
        let uncommented = line.drop { $0 == commentMarker || $0 == " " }
        guard let separator = uncommented.firstIndex(of: assignmentSeparator) else {
            return nil
        }

        let name = uncommented[..<separator]
        let isVariableName = !name.isEmpty && name.allSatisfy { $0.isUppercase || $0.isNumber || $0 == "_" }
        return isVariableName ? String(name) : nil
    }
}
