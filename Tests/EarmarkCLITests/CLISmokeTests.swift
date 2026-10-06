import EarmarkCLI
import Testing

struct CLISmokeTests {
    /// Код выхода — контракт для агентов (§9.3): 0 — успех, 64 — неверный вызов.
    @Test(arguments: [([], 0), (["help"], 0), (["no-such-command"], 64)] as [([String], Int32)])
    func exitCode(argv: [String], expected: Int32) async {
        #expect(await EarmarkCLI.run(argv) == expected)
    }
}
