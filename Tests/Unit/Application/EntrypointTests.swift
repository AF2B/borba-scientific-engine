import Foundation
import Testing

@testable import BorbaScientificEngine

@Suite("Entrypoint")
struct EntrypointTests {
    @Test("exits with a failure status, before booting anything, when the configuration is invalid")
    func invalidConfiguration() async {
        let status = await Entrypoint.run(environment: [:], arguments: ["borba-scientific-engine"])

        #expect(status == EXIT_FAILURE)
    }
}
