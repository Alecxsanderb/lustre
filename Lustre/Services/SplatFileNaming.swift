//
//  SplatFileNaming.swift
//  Lustre
//
//  Pure name rules for library files, kept apart from the store so they can
//  be unit tested without touching the file system.
//

import Foundation

nonisolated enum SplatFileNaming {

    enum RenameError: LocalizedError, Equatable {
        case empty
        case invalidCharacters
        case alreadyExists(String)

        var errorDescription: String? {
            switch self {
            case .empty:
                return "A name can't be empty."
            case .invalidCharacters:
                return "Names can't contain “/” or “:”, or start with a period."
            case .alreadyExists(let name):
                return "A splat named “\(name)” already exists."
            }
        }
    }

    /// Trims and checks a user-typed name. Returns the name to use.
    static func validatedName(_ proposed: String) throws(RenameError) -> String {
        let name = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw .empty }
        // "/" is the path separator and ":" is how Files displays it; a
        // leading period would hide the file from Files entirely.
        guard !name.contains("/"), !name.contains(":"), !name.hasPrefix(".") else {
            throw .invalidCharacters
        }
        return name
    }

    /// `base.ext`, or `base 2.ext`, `base 3.ext`… — the first one `isTaken`
    /// rejects. Mirrors how Files names duplicates.
    static func uniqueFileName(base: String,
                               fileExtension: String,
                               isTaken: (String) -> Bool) -> String {
        let suffix = fileExtension.isEmpty ? "" : ".\(fileExtension)"
        var candidate = base + suffix
        var counter = 2
        while isTaken(candidate) {
            candidate = "\(base) \(counter)\(suffix)"
            counter += 1
        }
        return candidate
    }
}
