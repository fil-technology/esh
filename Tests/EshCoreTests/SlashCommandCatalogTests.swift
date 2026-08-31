import Foundation
import Testing
@testable import EshCore

@Suite
struct SlashCommandCatalogTests {
    @Test
    func loneSlashSuggestsCommands() {
        let s = SlashCommandCatalog.suggestions(for: "/")
        #expect(s.isEmpty == false)
    }
    @Test
    func prefixFilters() {
        let s = SlashCommandCatalog.suggestions(for: "/mo")
        #expect(s.allSatisfy { $0.command.hasPrefix("/mo") })
        #expect(s.contains { $0.command == "/model" })
        #expect(s.contains { $0.command == "/models" })
    }
    @Test
    func completeCommandWithSpaceStopsSuggesting() {
        #expect(SlashCommandCatalog.suggestions(for: "/model qwen").isEmpty)   // arg started → done
    }
    @Test
    func nonSlashInputSuggestsNothing() {
        #expect(SlashCommandCatalog.suggestions(for: "hello").isEmpty)
    }
    @Test
    func caseInsensitivePrefix() {
        #expect(SlashCommandCatalog.suggestions(for: "/THI").contains { $0.command == "/think" })
    }
}
