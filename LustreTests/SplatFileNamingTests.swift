//
//  SplatFileNamingTests.swift
//  LustreTests
//

import Foundation
import Testing
@testable import Lustre

struct SplatFileNamingTests {

    @Test("Valid names come back trimmed", arguments: [
        ("Kitchen", "Kitchen"),
        ("  Kitchen  ", "Kitchen"),
        ("\n\tGarden shed\n", "Garden shed"),
        ("v1.2 final", "v1.2 final"),
        ("Café – 2026", "Café – 2026"),
    ])
    func validNames(proposed: String, expected: String) throws {
        #expect(try SplatFileNaming.validatedName(proposed) == expected)
    }

    @Test("Blank names are rejected", arguments: ["", "   ", "\n\t "])
    func blankNames(proposed: String) {
        #expect(throws: SplatFileNaming.RenameError.empty) {
            try SplatFileNaming.validatedName(proposed)
        }
    }

    @Test("Separators and hidden names are rejected", arguments: [
        "a/b", "a:b", ".hidden", "  .hidden", "/", ":",
    ])
    func invalidNames(proposed: String) {
        #expect(throws: SplatFileNaming.RenameError.invalidCharacters) {
            try SplatFileNaming.validatedName(proposed)
        }
    }

    @Test func freeNameIsUsedAsIs() {
        let name = SplatFileNaming.uniqueFileName(base: "Room", fileExtension: "ply") { _ in false }
        #expect(name == "Room.ply")
    }

    @Test func collisionsCountUpFromTwo() {
        let taken: Set = ["Room.ply", "Room 2.ply", "Room 3.ply"]
        let name = SplatFileNaming.uniqueFileName(base: "Room", fileExtension: "ply", isTaken: taken.contains)
        #expect(name == "Room 4.ply")
    }

    @Test func gapsAreNotFilled() {
        // Mirrors Files: the first free candidate in sequence, not the lowest
        // free number overall. "Room 3" is free, but "Room 2" is checked first.
        let taken: Set = ["Room.ply", "Room 3.ply"]
        let name = SplatFileNaming.uniqueFileName(base: "Room", fileExtension: "ply", isTaken: taken.contains)
        #expect(name == "Room 2.ply")
    }

    @Test func emptyExtensionAddsNoDot() {
        let taken: Set = ["Room"]
        let name = SplatFileNaming.uniqueFileName(base: "Room", fileExtension: "", isTaken: taken.contains)
        #expect(name == "Room 2")
    }
}
