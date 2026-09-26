//
//  ThumbnailKey.swift
//  Lustre
//
//  Cache key for one splat's thumbnail. Anything that changes what the
//  thumbnail would show must change the key: the file's name, size, and
//  modification date stand in for its contents (hashing a multi-hundred-MB
//  splat to key a 30 KB JPEG isn't worth it), and the renderer version
//  invalidates every thumbnail when the framing or look changes.
//

import CryptoKit
import Foundation

nonisolated struct ThumbnailKey: Hashable, Sendable {

    /// Lowercase hex SHA-256, used as the cache file's stem.
    let hash: String

    init(fileName: String, fileSize: Int64, modificationDate: Date, rendererVersion: Int) {
        // `description` of a Double round-trips exactly, so sub-second mtime
        // changes still change the key. `|` can appear in a file name, but the
        // other fields are fixed-format numbers at the end, so two different
        // tuples can't produce the same string.
        let seconds = modificationDate.timeIntervalSince1970
        let source = "\(fileName)|\(fileSize)|\(seconds)|\(rendererVersion)"
        let digest = SHA256.hash(data: Data(source.utf8))
        hash = digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Reads name, size, and modification date from the file itself.
    init(fileURL: URL, rendererVersion: Int) throws {
        let values = try fileURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        self.init(fileName: fileURL.lastPathComponent,
                  fileSize: Int64(values.fileSize ?? 0),
                  modificationDate: values.contentModificationDate ?? .distantPast,
                  rendererVersion: rendererVersion)
    }
}
