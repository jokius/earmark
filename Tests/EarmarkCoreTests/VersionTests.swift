import EarmarkCore
import Foundation
import Testing

struct VersionTests {
    /// Версию бандла задаёт project.yml, а `meta.app_version` и `status` берут EarmarkVersion.
    /// Разъедутся — записи будут врать, какой сборкой сделаны.
    @Test func matchesMarketingVersionInProjectYml() throws {
        let repoRoot = URL(filePath: #filePath)
            .deletingLastPathComponent()  // EarmarkCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()
        let projectYml = try String(contentsOf: repoRoot.appending(path: "project.yml"), encoding: .utf8)
        #expect(projectYml.contains(#"MARKETING_VERSION: "\#(EarmarkVersion.current)""#))
    }
}
