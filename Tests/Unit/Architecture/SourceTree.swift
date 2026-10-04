import Foundation

/// Reads the repository's own files, for the tests that guard conventions of the source tree.
enum SourceTree {
    private static let repositoryDepthFromThisFile = 4
    private static let swiftFileExtension = "swift"

    /// The root of the repository, found relative to this file.
    static var root: URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<repositoryDepthFromThisFile {
            url.deleteLastPathComponent()
        }
        return url
    }

    /// Every Swift file below a directory.
    ///
    /// - Parameter relativePath: The directory, relative to the repository root.
    /// - Returns: The files, in no particular order.
    static func swiftFiles(under relativePath: String) -> [URL] {
        let directory = root.appendingPathComponent(relativePath)
        let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)

        return (enumerator?.allObjects as? [URL] ?? []).filter { $0.pathExtension == swiftFileExtension }
    }

    /// The text of a file.
    ///
    /// - Parameter relativePath: The file, relative to the repository root.
    /// - Returns: Its contents.
    /// - Throws: An error when the file cannot be read.
    static func contents(of relativePath: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
