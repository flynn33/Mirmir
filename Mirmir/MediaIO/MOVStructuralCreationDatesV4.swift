import Darwin
import Foundation

/// Captures and restores QuickTime/ISO movie, track, and media creation and
/// modification fields (`mvhd` / `tkhd` / `mdhd`). AVFoundation writers replace
/// these with export time; metadata assignment does not restore them.
enum MOVStructuralCreationDatesV4 {
    static let quickTimeEpochToUnix: UInt64 = 2_082_844_800

    struct HeaderDates: Equatable, Sendable {
        let creation: UInt64
        let modification: UInt64
    }

    struct TrackDates: Equatable, Sendable {
        let trackHeader: HeaderDates
        let mediaHeader: HeaderDates
        /// QuickTime `hdlr` handler type (`vide`, `soun`, …).
        let handlerType: String

        init(
            trackHeader: HeaderDates,
            mediaHeader: HeaderDates,
            handlerType: String = ""
        ) {
            self.trackHeader = trackHeader
            self.mediaHeader = mediaHeader
            self.handlerType = handlerType
        }
    }

    struct Snapshot: Equatable, Sendable {
        let movie: HeaderDates
        /// Source `trak` order.
        let tracks: [TrackDates]
    }

    enum Failure: Error, Equatable {
        case invalidFile
        case malformedAtom
        case missingMovieHeader
        case multipleMovieHeaders
        case unsupportedVersion
        case truncationRequired
        case trackInventoryMismatch
        case fileChanged
        case io(Int32)
    }

    /// Returns `nil` for containers without a QuickTime/ISO movie header
    /// (for example RIFF/AVI). Zero-valued dates are retained as ownership.
    static func capture(from url: URL) throws -> Snapshot? {
        let file = try MovieFile(url: url.resolvingSymlinksInPath(), writable: false)
        guard try admitsQuickTimeISO(file) else { return nil }
        let movie = try movieHeader(in: file)
        let children = try file.children(movie.body, movie.end)
        let movieDates = try dates(file, node: try unique("mvhd", in: children))
        var tracks: [TrackDates] = []
        for trak in children where trak.type == "trak" {
            let trackChildren = try file.children(trak.body, trak.end)
            let tkhd = try dates(file, node: try unique("tkhd", in: trackChildren))
            let mdia = try unique("mdia", in: trackChildren)
            let mediaChildren = try file.children(mdia.body, mdia.end)
            let mdhd = try dates(file, node: try unique("mdhd", in: mediaChildren))
            let handler = try handlerType(file, node: try unique("hdlr", in: mediaChildren))
            tracks.append(TrackDates(
                trackHeader: tkhd,
                mediaHeader: mdhd,
                handlerType: handler
            ))
        }
        guard !tracks.isEmpty else { throw Failure.invalidFile }
        try file.requireUnchangedExtent()
        return Snapshot(movie: movieDates, tracks: tracks)
    }

    /// Writes captured dates into an unpublished MOV/MP4. `outputToSourceTrack`
    /// maps output `trak` ordinals onto source track ordinals. When
    /// `requireCompleteTrackCoverage` is true every output track must be mapped.
    static func restore(
        _ snapshot: Snapshot,
        into url: URL,
        outputToSourceTrack: [Int: Int],
        requireCompleteTrackCoverage: Bool = true,
        cancellation: () throws -> Void = {}
    ) throws {
        let file = try MovieFile(url: url.resolvingSymlinksInPath(), writable: true)
        defer { _ = fsync(file.fd) }
        try cancellation()
        let movie = try movieHeader(in: file)
        let children = try file.children(movie.body, movie.end)
        try writeDates(snapshot.movie, file: file, node: try unique("mvhd", in: children))
        let outputTracks = children.filter { $0.type == "trak" }
        if requireCompleteTrackCoverage {
            guard Set(outputToSourceTrack.keys) == Set(outputTracks.indices) else {
                throw Failure.trackInventoryMismatch
            }
        } else {
            guard outputToSourceTrack.keys.allSatisfy({ outputTracks.indices.contains($0) }) else {
                throw Failure.trackInventoryMismatch
            }
        }
        for (ordinal, trak) in outputTracks.enumerated() {
            try cancellation()
            guard let sourceOrdinal = outputToSourceTrack[ordinal] else { continue }
            guard snapshot.tracks.indices.contains(sourceOrdinal) else {
                throw Failure.trackInventoryMismatch
            }
            let source = snapshot.tracks[sourceOrdinal]
            let trackChildren = try file.children(trak.body, trak.end)
            try writeDates(source.trackHeader, file: file, node: try unique("tkhd", in: trackChildren))
            let mdia = try unique("mdia", in: trackChildren)
            let mediaChildren = try file.children(mdia.body, mdia.end)
            try writeDates(source.mediaHeader, file: file, node: try unique("mdhd", in: mediaChildren))
        }
        try file.requireUnchangedExtent()
        guard fsync(file.fd) == 0 else { throw Failure.io(errno) }
    }

    static func verify(
        _ snapshot: Snapshot,
        in url: URL,
        outputToSourceTrack: [Int: Int],
        requireCompleteTrackCoverage: Bool = true
    ) throws {
        guard let actual = try capture(from: url) else { throw Failure.invalidFile }
        guard actual.movie == snapshot.movie else { throw Failure.trackInventoryMismatch }
        if requireCompleteTrackCoverage {
            guard Set(outputToSourceTrack.keys) == Set(actual.tracks.indices) else {
                throw Failure.trackInventoryMismatch
            }
        } else {
            guard outputToSourceTrack.keys.allSatisfy({ actual.tracks.indices.contains($0) }) else {
                throw Failure.trackInventoryMismatch
            }
        }
        for (ordinal, sourceOrdinal) in outputToSourceTrack {
            guard snapshot.tracks.indices.contains(sourceOrdinal),
                  actual.tracks.indices.contains(ordinal),
                  datesMatch(actual.tracks[ordinal], snapshot.tracks[sourceOrdinal]) else {
                throw Failure.trackInventoryMismatch
            }
        }
    }

    /// Restores source structural dates onto a finished MOV/MP4 after an
    /// AVFoundation header rewrite. Matching inventories use identity mapping.
    /// Divergent inventories align by `hdlr` handler type order so retained
    /// video/audio/etc. lanes keep source track/media dates; unmapped output
    /// tracks (for example newly authored metadata) keep export-time stamps.
    @discardableResult
    static func restoreFromSource(
        sourceURL: URL,
        into outputURL: URL,
        cancellation: () throws -> Void = {}
    ) throws -> Snapshot? {
        guard let snapshot = try capture(from: sourceURL) else { return nil }
        guard let output = try capture(from: outputURL) else { throw Failure.invalidFile }
        let mapping: [Int: Int]
        if snapshot.tracks.count == output.tracks.count {
            mapping = Dictionary(uniqueKeysWithValues: snapshot.tracks.indices.map { ($0, $0) })
        } else {
            mapping = mediaTypeAlignedMapping(source: snapshot, output: output)
        }
        let complete = mapping.count == output.tracks.count
        try restore(
            snapshot,
            into: outputURL,
            outputToSourceTrack: mapping,
            requireCompleteTrackCoverage: complete,
            cancellation: cancellation
        )
        try verify(
            snapshot,
            in: outputURL,
            outputToSourceTrack: mapping,
            requireCompleteTrackCoverage: complete
        )
        return snapshot
    }

    /// First-unclaimed source track of each matching `hdlr` type.
    static func mediaTypeAlignedMapping(
        source: Snapshot,
        output: Snapshot
    ) -> [Int: Int] {
        var usedSources = Set<Int>()
        var mapping: [Int: Int] = [:]
        for (outputOrdinal, outputTrack) in output.tracks.enumerated() {
            guard !outputTrack.handlerType.isEmpty else { continue }
            guard let sourceOrdinal = source.tracks.indices.first(where: {
                !usedSources.contains($0)
                    && source.tracks[$0].handlerType == outputTrack.handlerType
            }) else { continue }
            mapping[outputOrdinal] = sourceOrdinal
            usedSources.insert(sourceOrdinal)
        }
        return mapping
    }

    static func foundationDate(fromQuickTimeSeconds value: UInt64) -> Date? {
        guard value != 0 else { return nil }
        guard value >= quickTimeEpochToUnix else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(value - quickTimeEpochToUnix))
    }

    private static func datesMatch(_ lhs: TrackDates, _ rhs: TrackDates) -> Bool {
        lhs.trackHeader == rhs.trackHeader && lhs.mediaHeader == rhs.mediaHeader
    }

    private static func admitsQuickTimeISO(_ file: MovieFile) throws -> Bool {
        guard file.extent >= 8 else { return false }
        let header = try file.read(0, Int(min(12, file.extent)))
        if header.count >= 12, header[0..<4] == Data("RIFF".utf8) { return false }
        let roots = try file.children(0, file.extent)
        return roots.contains { $0.type == "moov" || $0.type == "ftyp" }
    }

    private static func movieHeader(in file: MovieFile) throws -> Node {
        let movies = try file.children(0, file.extent).filter { $0.type == "moov" }
        guard !movies.isEmpty else { throw Failure.missingMovieHeader }
        guard movies.count == 1 else { throw Failure.multipleMovieHeaders }
        return movies[0]
    }

    private static func unique(_ type: String, in children: [Node]) throws -> Node {
        let matches = children.filter { $0.type == type }
        guard matches.count == 1 else { throw Failure.malformedAtom }
        return matches[0]
    }

    private static func dates(_ file: MovieFile, node: Node) throws -> HeaderDates {
        guard node.end - node.body >= 4 else { throw Failure.malformedAtom }
        let version = try file.read(node.body, 1)[0]
        guard version <= 1 else { throw Failure.unsupportedVersion }
        let width = version == 0 ? 4 : 8
        guard node.end - node.body >= 4 + Int64(width * 2) else { throw Failure.malformedAtom }
        let bytes = try file.read(node.body + 4, width * 2)
        return HeaderDates(
            creation: uint(bytes, 0, width),
            modification: uint(bytes, width, width)
        )
    }

    private static func handlerType(_ file: MovieFile, node: Node) throws -> String {
        // version(1) + flags(3) + pre_defined(4) + handler_type(4)
        guard node.end - node.body >= 12 else { throw Failure.malformedAtom }
        let bytes = try file.read(node.body + 8, 4)
        guard let type = String(data: bytes, encoding: .isoLatin1), type.count == 4 else {
            throw Failure.malformedAtom
        }
        return type
    }

    private static func writeDates(
        _ dates: HeaderDates, file: MovieFile, node: Node
    ) throws {
        guard node.end - node.body >= 4 else { throw Failure.malformedAtom }
        let version = try file.read(node.body, 1)[0]
        guard version <= 1 else { throw Failure.unsupportedVersion }
        let width = version == 0 ? 4 : 8
        guard node.end - node.body >= 4 + Int64(width * 2) else { throw Failure.malformedAtom }
        let payload: Data
        if width == 8 {
            payload = be(dates.creation) + be(dates.modification)
        } else {
            guard dates.creation <= UInt64(UInt32.max),
                  dates.modification <= UInt64(UInt32.max) else {
                throw Failure.truncationRequired
            }
            payload = be(UInt32(dates.creation)) + be(UInt32(dates.modification))
        }
        try file.write(node.body + 4, payload)
    }

    private static func uint(_ bytes: Data, _ offset: Int, _ width: Int) -> UInt64 {
        bytes[offset..<(offset + width)].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
    }

    private static func be<T: FixedWidthInteger>(_ value: T) -> Data {
        var value = value.bigEndian
        return withUnsafeBytes(of: &value) { Data($0) }
    }

    private struct Node {
        let start: Int64
        let size: Int64
        let headerBytes: Int
        let type: String
        var body: Int64 { start + Int64(headerBytes) }
        var end: Int64 { start + size }
    }

    private final class MovieFile {
        let fd: Int32
        let extent: Int64

        init(url: URL, writable: Bool) throws {
            fd = Darwin.open(url.path, (writable ? O_RDWR : O_RDONLY) | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw Failure.io(errno) }
            var status = stat()
            guard fstat(fd, &status) == 0,
                  status.st_mode & S_IFMT == S_IFREG,
                  status.st_size >= 8,
                  !writable || status.st_nlink == 1 else {
                Darwin.close(fd)
                throw Failure.invalidFile
            }
            extent = Int64(status.st_size)
        }

        deinit { Darwin.close(fd) }

        func requireUnchangedExtent() throws {
            var status = stat()
            guard fstat(fd, &status) == 0, Int64(status.st_size) == extent else {
                throw Failure.fileChanged
            }
        }

        func read(_ offset: Int64, _ count: Int) throws -> Data {
            guard offset >= 0, count >= 0, Int64(count) <= extent,
                  offset <= extent - Int64(count) else { throw Failure.malformedAtom }
            var data = Data(count: count)
            try data.withUnsafeMutableBytes { raw in
                var copied = 0
                while copied < count {
                    let size = pread(fd, raw.baseAddress!.advanced(by: copied), count - copied,
                        off_t(offset + Int64(copied)))
                    if size < 0, errno == EINTR { continue }
                    guard size > 0 else { throw Failure.io(size < 0 ? errno : EIO) }
                    copied += size
                }
            }
            return data
        }

        func write(_ offset: Int64, _ data: Data) throws {
            try data.withUnsafeBytes { raw in
                var written = 0
                while written < data.count {
                    let size = pwrite(fd, raw.baseAddress!.advanced(by: written), data.count - written,
                        off_t(offset + Int64(written)))
                    if size < 0, errno == EINTR { continue }
                    guard size > 0 else { throw Failure.io(size < 0 ? errno : EIO) }
                    written += size
                }
            }
        }

        func children(_ start: Int64, _ end: Int64) throws -> [Node] {
            guard start >= 0, start <= end, end <= extent else { throw Failure.malformedAtom }
            var result: [Node] = []
            var offset = start
            while offset < end {
                guard end - offset >= 8 else { throw Failure.malformedAtom }
                let header = try read(offset, Int(min(16, end - offset)))
                let size32 = UInt32(header[0]) << 24 | UInt32(header[1]) << 16
                    | UInt32(header[2]) << 8 | UInt32(header[3])
                let bytes: Int
                let size: UInt64
                if size32 == 1 {
                    guard header.count >= 16 else { throw Failure.malformedAtom }
                    bytes = 16
                    size = header[8..<16].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
                } else if size32 == 0 {
                    bytes = 8
                    size = UInt64(end - offset)
                } else {
                    bytes = 8
                    size = UInt64(size32)
                }
                guard size >= UInt64(bytes), size <= UInt64(end - offset),
                      let type = String(data: Data(header[4..<8]), encoding: .isoLatin1) else {
                    throw Failure.malformedAtom
                }
                result.append(Node(start: offset, size: Int64(size), headerBytes: bytes, type: type))
                offset += Int64(size)
            }
            return result
        }
    }
}
