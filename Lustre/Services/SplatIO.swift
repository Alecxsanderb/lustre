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
    nonisolated static let readableExtensions = ["ply", "spz", "splat"]

    /// Compressed containers we recognize but cannot decode yet.
    ///
    /// MetalSplatter ships no reader for these at any version (checked through
    /// `main`, 2026-07-19). They're listed so the picker still offers them and
    /// the user gets a specific message naming the format, rather than a parse
    /// failure from a reader that was never going to work.
    nonisolated static let recognizedButUnsupportedExtensions = ["sog", "sogs"]

    /// SPZ files above this size get no thumbnail. The SPZ reader decompresses
    /// and unpacks every point, full SH included, before yielding its first
    /// batch, so decimation can't bound its peak the way it does for PLY and
    /// `.splat`. A 50 MB SPZ could peak at 0.5-1 GB that way, so the limit
    /// is kept well below that.
    nonisolated static let maximumThumbnailSPZBytes: Int64 = 20 * 1024 * 1024

    nonisolated enum LoadError: LocalizedError {
        case unreadableFile(URL)
        case unsupportedFormat(URL)
        case notYetSupported(URL)
        case empty(URL)
        case truncated(URL)
        case malformed(URL)
        case stalled(URL)
        /// Readable, but too expensive to thumbnail. Not a damaged file.
        case tooLargeForThumbnail(URL)

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
            case .tooLargeForThumbnail(let url):
                return "\(url.lastPathComponent) is too large to preview."
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

        let reader = try validatedReader(for: url)
        let points: [SplatPoint]
        do {
            points = try await SplatStreamWatchdog.readAll(reader)
        } catch is SplatStreamWatchdog.Stalled {
            throw LoadError.stalled(url)
        }
        guard !points.isEmpty else { throw LoadError.empty(url) }
        return points
    }

    /// Reads an evenly spread subsample of at most `cap` points, with
    /// spherical harmonics stripped to degree 0, for rendering a thumbnail.
    ///
    /// Streams through `SplatDecimator`, so a PLY or `.splat` never holds more
    /// than the cap plus one batch. `@concurrent` so the preflight and read
    /// stay off the caller's actor even when that's the main actor. Throws
    /// `tooLargeForThumbnail` for an SPZ over `maximumThumbnailSPZBytes`.
    @concurrent
    nonisolated static func loadThumbnailPoints(from url: URL,
                                                cap: Int = SplatDecimator.defaultCap) async throws -> [SplatPoint] {
        let needsScopedAccess = url.startAccessingSecurityScopedResource()
        defer {
            if needsScopedAccess { url.stopAccessingSecurityScopedResource() }
        }

        let reader = try validatedReader(for: url)
        if url.pathExtension.lowercased() == "spz" {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }
            if let size, Int64(size) > maximumThumbnailSPZBytes {
                throw LoadError.tooLargeForThumbnail(url)
            }
        }

        let decimator: StrideDecimator<SplatPoint>
        do {
            decimator = try await SplatStreamWatchdog.drain(reader, into: SplatDecimator.make(cap: cap)) {
                decimator, batch in
                decimator.add(batch)
            }
        } catch is SplatStreamWatchdog.Stalled {
            throw LoadError.stalled(url)
        }
        guard !decimator.kept.isEmpty else { throw LoadError.empty(url) }
        return decimator.kept
    }

    /// Every check that runs before MetalSplatter sees a file, shared by the
    /// Viewer and thumbnail paths so they accept and reject exactly the same
    /// files with the same messages. The caller holds security-scoped access.
    nonisolated static func validatedReader(for url: URL) throws -> SplatSceneReader {
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
        // body doesn't match its header, and on any PLY declaring zero
        // vertices. See PLYPreflight.swift.
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
            case .empty: throw LoadError.empty(url)
            }
        }

        do {
            return try AutodetectSceneReader(url)
        } catch {
            throw LoadError.unsupportedFormat(url)
        }
    }
}
