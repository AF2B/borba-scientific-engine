import Foundation
import Testing

/// Fitness tests: rules of the architecture that the compiler cannot enforce on its own.
///
/// The target graph already prevents `BorbaScientificCore` from importing Vapor, because the target does not depend
/// on it. These tests make the rule explicit and fail with a readable message, and they guard conventions of the
/// source tree that keep it navigable.
@Suite("Architecture")
struct ArchitectureTests {
    private static let repositoryDepthFromThisFile = 4
    private static let swiftFileExtension = "swift"
    private static let moduleCatalogSuffix = "Module.swift"

    /// The only frameworks the domain may use: the standard library and Foundation (for `Date`, `UUID`, `Decimal`).
    private static let allowedCoreImports: Set<String> = ["Foundation"]

    private static var repositoryRoot: URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<repositoryDepthFromThisFile {
            url.deleteLastPathComponent()
        }
        return url
    }

    private static func swiftFiles(under relativePath: String) throws -> [URL] {
        let directory = repositoryRoot.appendingPathComponent(relativePath)
        let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)

        return (enumerator?.allObjects as? [URL] ?? []).filter { $0.pathExtension == swiftFileExtension }
    }

    /// The modules a file imports, whatever access modifier or attribute precedes the import.
    private static func importedModules(in file: URL) throws -> Set<String> {
        let contents = try String(contentsOf: file, encoding: .utf8)
        let pattern =
            #/
            ^\s*
            (?:@\w+\s+)*                                                       # attributes such as @testable
            (?:(?:public|package|internal|fileprivate|private)\s+)?            # access modifier
            import\s+
            (?:(?:struct|class|enum|protocol|func|var|let|typealias)\s+)?      # scoped import
            (\w+)                                                              # the module
            /#

        return Set(
            contents.split(separator: "\n").compactMap { line in
                line.firstMatch(of: pattern).map { String($0.output.1) }
            }
        )
    }

    @Test("the core domain imports nothing but Foundation")
    func coreHasNoFrameworkDependencies() throws {
        for file in try Self.swiftFiles(under: "Sources/BorbaScientificCore") {
            let forbidden = try Self.importedModules(in: file).subtracting(Self.allowedCoreImports)

            #expect(
                forbidden.isEmpty,
                "\(file.lastPathComponent) imports \(forbidden.sorted()); the domain must stay free of frameworks"
            )
        }
    }

    @Test("every calculation module folder has its catalog file")
    func moduleFoldersAreComplete() throws {
        let modules = Self.repositoryRoot.appendingPathComponent("Sources/BorbaScientificCore/Modules")
        let entries = try FileManager.default.contentsOfDirectory(
            at: modules,
            includingPropertiesForKeys: [URLResourceKey.isDirectoryKey]
        )
        let folders = entries.filter { entry in
            let resourceValues = try? entry.resourceValues(forKeys: [URLResourceKey.isDirectoryKey])
            return resourceValues?.isDirectory == true
        }

        #expect(folders.count >= 9)
        for folder in folders {
            let catalog = folder.appendingPathComponent(folder.lastPathComponent + Self.moduleCatalogSuffix)

            #expect(
                FileManager.default.fileExists(atPath: catalog.path),
                "\(folder.lastPathComponent) needs \(catalog.lastPathComponent)"
            )
        }
    }

    @Test("the domain has no catch-all helper files")
    func noDumpingGrounds() throws {
        let forbiddenNames: Set<String> = [
            "Utils.swift", "Helpers.swift", "Manager.swift", "Common.swift", "Misc.swift",
        ]

        for file in try Self.swiftFiles(under: "Sources") {
            #expect(!forbiddenNames.contains(file.lastPathComponent), "\(file.path) is a dumping ground")
        }
    }
}
