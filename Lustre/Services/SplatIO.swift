//
//  SplatIO.swift
//  Lustre
//
//  Thin app-side wrapper over MetalSplatter's SplatIO. MetalSplatter does the
//  real format work; this exists so features import a Lustre type instead of
//  scattering `AutodetectSceneReader` calls across the app.
//

import Foundation
import UniformTypeIdentifiers
import SplatIO

/// Namespace for splat file loading. Named to match `Services/SplatIO` in the
/// roadmap; the underlying module is imported above and used here only.
enum SplatFileIO {

    /// Formats MetalSplatter can actually decode. These are exactly the
    /// extensions `SplatIO.SplatFileFormat` dispatches on, lowercased — keep
    /// the two in sync or the picker will offer files the reader rejects.
    static let readableExtensions = ["ply", "spz", "splat"]

    /// Compressed containers we recognize but cannot decode yet.
    ///
    /// MetalSplatter ships no reader for these at any version (checked through
    /// `main`, 2026-07-19). They're listed so the picker still offers them and
    /// the user gets a specific message naming the format, rather than a parse
    /// failure from a reader that was never going to work.
    static let recognizedButUnsupportedExtensions = ["sog", "sogs"]

    enum LoadError: LocalizedError {
        case unreadableFile(URL)
        case unsupportedFormat(URL)
        case notYetSupported(URL)
        case empty(URL)
        case truncated(URL)
        case malformed(URL)
        case stalled(URL)

        var errorDescription: String? {
            switch self {
            case .unreadableFile(let url):
                return "Couldn't open \(url.lastPathComponent)."
            case .unsupportedFormat(let url):
                return "\(url.lastPathComponent) isn't a splat format Lustre recognizes."
            case .notYetSupported(let url):
                let format = url.pathExtension.uppercased()
                return "Lustre can't read \(format) files yet. Export as PLY, SPZ, or .splat."
            case .empty(let url):
                return "\(url.lastPathComponent) contains no splats."
            case .truncated(let url):
                return "\(url.lastPathComponent) is incomplete. It may have been cut off while copying."
            case .malformed(let url):
                return "\(url.lastPathComponent) isn't a valid PLY file."
            case .stalled(let url):
                return "Lustre couldn't finish reading \(url.lastPathComponent). The file may be damaged."
            }
        }
    }

    /// File types the import picker offers.
    ///
    /// Only `ply` has a system-declared type (`public.polygon-file-format`);
    /// the rest resolve to dynamic `dyn.*` types synthesized from the
    /// extension, which still match files carrying it. Deliberately does NOT
    /// include `.data` — every regular file conforms to it, which would make
    /// the filter a no-op and let the user pick a JPEG.
    static var importableContentTypes: [UTType] {
        let types = (readableExtensions + recognizedButUnsupportedExtensions)
            .compactMap { UTType(filenameExtension: $0) }
        // An empty list would leave the picker unable to select anything.
        return types.isEmpty ? [.data] : types
    }

    /// Reads every point from a splat file.
    ///
    /// Runs off the main actor — a large PLY is tens of megabytes and parsing
    /// it on the main thread would stall the render loop.
    nonisolated static func loadPoints(from url: URL) async throws -> [SplatPoint] {
        // Security-scoped access is required for files handed over by the
        // document picker; it's a no-op for files we already own.
        let needsScopedAccess = url.startAccessingSecurityScopedResource()
        defer {
            if needsScopedAccess { url.stopAccessingSecurityScopedResource() }
        }

        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw LoadError.unreadableFile(url)
        }

        // Checked before the format probe so SOG gets its own message rather
        // than the generic "not a format Lustre recognizes".
        let fileExtension = url.pathExtension.lowercased()
        guard !recognizedButUnsupportedExtensions.contains(fileExtension) else {
            throw LoadError.notYetSupported(url)
        }
        guard SplatFileFormat(for: url) != nil else {
            throw LoadError.unsupportedFormat(url)
        }

        // MetalSplatter hangs, rather than throwing, on a binary PLY whose
        // body doesn't match its header. See PLYPreflight.swift.
        if fileExtension == "ply" {
            let verdict: PLYPreflight.Verdict
            do {
                verdict = try PLYPreflight.check(url)
            } catch {
                throw LoadError.unreadableFile(url)
            }
            switch verdict {
            case .proceed: break
            case .truncated: throw LoadError.truncated(url)
            case .trailingData, .malformedHeader: throw LoadError.malformed(url)
            }
        }

        let reader: SplatSceneReader
        do {
            reader = try AutodetectSceneReader(url)
        } catch {
            throw LoadError.unsupportedFormat(url)
        }

        let points: [SplatPoint]
        do {
            points = try await SplatStreamWatchdog.readAll(reader)
        } catch is SplatStreamWatchdog.Stalled {
            throw LoadError.stalled(url)
        }
        guard !points.isEmpty else { throw LoadError.empty(url) }
        return points
    }
}
