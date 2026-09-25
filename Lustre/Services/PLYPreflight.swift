//
//  PLYPreflight.swift
//  Lustre
//
//  Size check for binary PLYs, run before MetalSplatter sees the file.
//
//  Why this exists: in MetalSplatter 1.0.1, `SplatPLYSceneReader.read()`
//  iterates the PLYIO body stream inside an unstructured `Task` whose `for try
//  await` has no catch. When PLYIO throws (`unexpectedEndOfFile` for a
//  truncated body, `unexpectedContentAtEndOfBody` for trailing bytes) the error
//  escapes the Task and is dropped, the outer stream never finishes, and
//  `readAll()` awaits forever. A binary body's length is fully determined by
//  the header, so both cases can be caught here from the file size alone.
//
//  The header is untrusted input: its length is bounded, every count is range
//  checked, and the size arithmetic can't overflow. Anything this parser
//  doesn't fully understand is passed through to MetalSplatter rather than
//  rejected, so it can never refuse a file the library would have read.
//

import Foundation

nonisolated enum PLYPreflight {

    enum Verdict: Equatable {
        /// Sizes are consistent, or the file isn't something this check
        /// covers (ASCII body, header it can't parse). Hand it to the library.
        case proceed
        /// Body is shorter than the header says.
        case truncated
        /// Bytes follow the declared body. The library rejects these too, but
        /// by hanging rather than throwing.
        case trailingData
        /// Header declares something the library would crash on.
        case malformedHeader
    }

    /// Matches PLYIO's `PLYReader.Constants.headerMaxLen`. The library rejects
    /// a longer header itself (by throwing), so there's no need to read further.
    static let headerMaxLength = 256 * 1024

    private static let startToken = Data("ply\n".utf8)
    private static let endToken = Data("end_header\n".utf8)

    static func check(_ url: URL) throws -> Verdict {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let fileSize = try handle.seekToEnd()
        try handle.seek(toOffset: 0)
        let prefix = try handle.read(upToCount: headerMaxLength + endToken.count) ?? Data()
        return check(prefix: prefix, fileSize: fileSize)
    }

    /// `prefix` is the first bytes of the file; it holds the whole header
    /// whenever the file has one within the bound.
    static func check(prefix: Data, fileSize: UInt64) -> Verdict {
        // PLYIO requires exactly "ply\n" at offset 0 and throws otherwise.
        guard prefix.starts(with: startToken),
              let endRange = prefix.range(of: endToken) else { return .proceed }

        let headerBytes = prefix[prefix.startIndex..<endRange.lowerBound]
        guard let header = String(data: headerBytes, encoding: .utf8),
              let layout = parseLayout(header) else { return .proceed }

        switch layout {
        case .malformed:
            return .malformedHeader
        case .notBinary:
            return .proceed
        case .binary(let elements):
            let headerLength = UInt64(endRange.upperBound - prefix.startIndex)
            guard let body = minimumBodySize(elements) else {
                // Doesn't fit in 64 bits, so no real file is that long.
                return .truncated
            }
            let (expected, overflow) = headerLength.addingReportingOverflow(body.bytes)
            if overflow || fileSize < expected { return .truncated }
            // A list's true length depends on its per-row counts, so only a
            // file of fixed-size rows has an exact expected size.
            if body.isExact && fileSize > expected { return .trailingData }
            return .proceed
        }
    }

    // MARK: - Header parsing

    private struct ElementLayout {
        var count: UInt64
        /// Bytes per row, counting each list as its count field only.
        var minimumRowSize: UInt64 = 0
        var hasLists = false
    }

    private enum Layout {
        case binary([ElementLayout])
        case notBinary
        case malformed
    }

    /// Nil means "not understood": defer to the library's own parser. Token
    /// counts mirror the library's whole-line regexes.
    private static func parseLayout(_ header: String) -> Layout? {
        var format: Substring?
        var elements: [ElementLayout] = []

        for line in header.split(whereSeparator: \.isNewline) {
            let tokens = line.split(whereSeparator: \.isWhitespace)
            guard let keyword = tokens.first else { continue }
            switch keyword {
            case "ply", "comment", "obj_info":
                continue
            case "format":
                guard tokens.count == 3 else { return nil }
                format = tokens[1]
            case "element":
                guard tokens.count == 3, let count = UInt64(tokens[2]) else { return nil }
                // PLYIO force-unwraps `UInt32(count)`, so a larger count is a
                // crash, not a parse error.
                guard count <= UInt64(UInt32.max) else { return .malformed }
                elements.append(ElementLayout(count: count))
            case "property":
                guard !elements.isEmpty else { return nil }
                let width: UInt64
                if tokens.count == 5, tokens[1] == "list" {
                    guard let countWidth = byteWidth(of: tokens[2]),
                          byteWidth(of: tokens[3]) != nil else { return nil }
                    width = countWidth
                    elements[elements.count - 1].hasLists = true
                } else if tokens.count == 3, let primitive = byteWidth(of: tokens[1]) {
                    width = primitive
                } else {
                    return nil
                }
                // The bounded header holds at most ~100k properties of at most
                // 8 bytes each, so this sum can't overflow.
                elements[elements.count - 1].minimumRowSize += width
            default:
                return nil
            }
        }

        switch format {
        case "binary_little_endian", "binary_big_endian": return .binary(elements)
        case "ascii": return .notBinary
        default: return nil
        }
    }

    private static func minimumBodySize(_ elements: [ElementLayout]) -> (bytes: UInt64, isExact: Bool)? {
        var total: UInt64 = 0
        var isExact = true
        for element in elements {
            let (bytes, productOverflow) = element.count.multipliedReportingOverflow(by: element.minimumRowSize)
            let (sum, sumOverflow) = total.addingReportingOverflow(bytes)
            guard !productOverflow, !sumOverflow else { return nil }
            total = sum
            // An element with no rows contributes nothing, lists or not.
            if element.hasLists && element.count > 0 { isExact = false }
        }
        return (total, isExact)
    }

    private static func byteWidth(of type: Substring) -> UInt64? {
        switch type {
        case "int8", "char", "uint8", "uchar": 1
        case "int16", "short", "uint16", "ushort": 2
        case "int32", "int", "uint32", "uint", "float32", "float": 4
        case "float64", "double": 8
        default: nil
        }
    }
}
