import EarmarkCore
import Foundation
import Testing

/// README — справочник CLI и ключей конфига, написанный руками (§9.1, §9.3), а таблица команд
/// и схема конфига живут в коде. Расхождение ловим здесь, а не жалобой пользователя.
@Suite("Документация не отстаёт от кода")
struct DocsTests {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    @Test(
        "README перечисляет каждую команду и каждый ключ конфига", arguments: ["README.md", "README.ru.md"])
    func readmeIsComplete(file: String) throws {
        let text = try String(contentsOf: Self.root.appendingPathComponent(file), encoding: .utf8)
        for spec in CommandTable.all {
            let command = "earmark " + spec.path.joined(separator: " ")
            #expect(text.contains(command), "\(file): нет \(command)")
        }
        for spec in ConfigSchema.all {
            // Шаблон calendar.*.x в README записан так, как его набирают: calendar.<id>.x.
            let key = spec.key.replacingOccurrences(of: "*", with: "<id>")
            #expect(text.contains("`\(key)`"), "\(file): нет ключа \(key)")
        }
        // Сторонние компоненты README не перечисляет, а отсылает к NOTICE — так они не разъедутся.
        #expect(text.contains("NOTICE"), "\(file): нет ссылки на NOTICE")
    }

    @Test("SKILL.md начинается с frontmatter name и description — без них установщики скилл пропускают")
    func skillFrontmatter() throws {
        let url = Self.root.appendingPathComponent("skills/earmark/SKILL.md")
        let text = try String(contentsOf: url, encoding: .utf8)
        let lines = text.components(separatedBy: "\n")
        #expect(lines.first == "---")
        let header = lines.dropFirst().prefix { $0 != "---" }
        #expect(header.contains("name: earmark"))
        #expect(header.contains { $0.hasPrefix("description:") })
        // Актуальную схему агент берёт из CLI, а не из копии в скилле (§9.5).
        #expect(text.contains("earmark help --json"))
    }
}
