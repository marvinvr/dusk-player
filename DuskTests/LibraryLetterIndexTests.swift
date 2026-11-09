import Foundation
import Testing
@testable import Dusk

/// The A–Z jump bar's labels: Plex's numbers-and-symbols keys fold into "#".
@Suite("Library letter index")
struct LibraryLetterIndexTests {
    private func row(_ key: String, _ size: Int) -> PlexFirstCharacter {
        PlexFirstCharacter(key: key, size: size)
    }

    @Test("Percent-encoded and symbol keys become a single leading #")
    func symbolKeysBecomeHash() {
        let index = LibraryLetterIndex(
            characters: [row("%23", 3), row("…", 2), row("A", 4), row("B", 1)],
            descending: false
        )
        #expect(index.entries.first?.label == "#")
        #expect(index.entries.filter { $0.label == "#" }.count == 1)
        #expect(index.entries.first?.offset == 0)
        #expect(index.entries.first { $0.label == "A" }?.offset == 5)
        #expect(index.entries.count == 27)
    }

    @Test("Descending order puts # last and still jumps to the symbols")
    func descendingHashJump() {
        let index = LibraryLetterIndex(
            characters: [row("%23", 3), row("A", 4), row("B", 1)],
            descending: true
        )
        let hash = index.entries.last
        #expect(hash?.label == "#")
        #expect(hash.flatMap(index.targetOffset(for:)) == 5)
    }
}
