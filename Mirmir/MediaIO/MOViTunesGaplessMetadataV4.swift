import CryptoKit
import Darwin
import Foundation

/// Preserves iTunes freeform entries that AVFoundation's movie writers
/// omit. Callers retain the original metadata identity and verify the completed
/// unpublished output before publishing it.
enum MOViTunesGaplessMetadataV4 {
    static let keySpaceID = "itlk"
    static let identifier = "itlk/com.apple.iTunes.iTunSMPB"
    private static let maximumEntryBytes = 1_048_576
    private static let copyChunkBytes = 1_048_576

    struct Entry: Equatable, Sendable {
        fileprivate let bytes: Data
    }

    enum Failure: Error, Equatable {
        case invalidFile
        case malformedAtom
        case missingMovieHeader
        case multipleMovieHeaders
        case ambiguousMetadata
        case conflictingMetadata
        case metadataTooLarge
        case unsupportedAtomSize
        case fileChanged
        case io(Int32)
    }

    static func entry(utf8Value: String) throws -> Entry {
        let value = Data(utf8Value.utf8)
        guard value.count <= maximumEntryBytes - 128 else {
            throw Failure.metadataTooLarge
        }
        return Entry(bytes: atom("----",
            fullAtom("mean", Data("com.apple.iTunes".utf8))
                + fullAtom("name", Data("iTunSMPB".utf8))
                + fullAtom("data", be(UInt32(0)) + value, flags: 1)))
    }

    static func utf8Value(of entry: Entry) throws -> String {
        let (_, data) = try valueNodes(in: entry)
        let start = Int(data.body) + 8
        guard let value = String(data: entry.bytes[start..<Int(data.end)], encoding: .utf8) else {
            throw Failure.malformedAtom
        }
        return value
    }

    /// Retains the original entry's namespace, locale, flags and unknown child
    /// atoms while replacing only its explicitly UTF-8 data value.
    static func entry(replacingUTF8Value value: String, in original: Entry) throws -> Entry {
        let (root, data) = try valueNodes(in: original)
        let valueBytes = Data(value.utf8)
        guard valueBytes.count <= maximumEntryBytes - 128 else {
            throw Failure.metadataTooLarge
        }
        let old = original.bytes
        let body = Data(old[Int(data.body)..<(Int(data.body) + 8)]) + valueBytes
        let replacement = try resized(data, body: body, bytes: old)
        let rootBody = Data(old[Int(root.body)..<Int(data.start)]) + replacement
            + Data(old[Int(data.end)..<Int(root.end)])
        let result = try resized(root, body: rootBody, bytes: old)
        guard result.count <= maximumEntryBytes else { throw Failure.metadataTooLarge }
        return Entry(bytes: result)
    }

    static func encodedBytes(of entry: Entry) -> Data { entry.bytes }

    private static func valueNodes(in entry: Entry) throws -> (Node, Node) {
        guard entry.bytes.count <= maximumEntryBytes else { throw Failure.metadataTooLarge }
        let roots = try memoryChildren(entry.bytes, start: 0, end: entry.bytes.count)
        guard roots.count == 1, let root = roots.first, root.type == "----" else {
            throw Failure.malformedAtom
        }
        let children = try memoryChildren(entry.bytes, start: Int(root.body), end: Int(root.end))
        let values = children.filter { $0.type == "data" }
        guard values.count == 1, let data = values.first, data.end - data.body >= 8,
              entry.bytes[Int(data.body)..<(Int(data.body) + 4)] == Data([0, 0, 0, 1]) else {
            throw Failure.ambiguousMetadata
        }
        return (root, data)
    }

    private static func resized(_ node: Node, body: Data, bytes: Data) throws -> Data {
        var header = Data(bytes[Int(node.start)..<Int(node.body)])
        let newSize = body.count + node.headerBytes
        if node.sizeEncoding == 1 {
            header.replaceSubrange(8..<16, with: be(UInt64(newSize)))
        } else if node.sizeEncoding != 0 {
            guard newSize <= Int(UInt32.max) else { throw Failure.unsupportedAtomSize }
            header.replaceSubrange(0..<4, with: be(UInt32(newSize)))
        }
        return header + body
    }

    private static func memoryChildren(_ bytes: Data, start: Int, end: Int) throws -> [Node] {
        guard start >= 0, start <= end, end <= bytes.count else { throw Failure.malformedAtom }
        var result: [Node] = []
        var offset = start
        while offset < end {
            guard end - offset >= 8 else { throw Failure.malformedAtom }
            let size32 = bytes[offset..<(offset + 4)].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            let header: Int
            let size: UInt64
            if size32 == 1 {
                guard end - offset >= 16 else { throw Failure.malformedAtom }
                header = 16
                size = bytes[(offset + 8)..<(offset + 16)].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            } else if size32 == 0 {
                header = 8; size = UInt64(end - offset)
            } else { header = 8; size = UInt64(size32) }
            guard size >= UInt64(header), size <= UInt64(end - offset),
                  let type = String(data: bytes[(offset + 4)..<(offset + 8)], encoding: .isoLatin1) else {
                throw Failure.malformedAtom
            }
            result.append(Node(start: Int64(offset), size: Int64(size), headerBytes: header,
                sizeEncoding: size32, type: type))
            offset += Int(size)
        }
        return result
    }

    static func originalEntries(in url: URL) throws -> [Entry] {
        let file = try MovieFile(url: url.resolvingSymlinksInPath(), writable: false)
        return try entries(in: file, locations: locations(in: file), onlyGapless: true)
    }

    static func originalFreeformEntries(in url: URL) throws -> [Entry] {
        let file = try MovieFile(url: url.resolvingSymlinksInPath(), writable: false)
        return try entries(in: file, locations: locations(in: file))
    }

    static func metadataIdentifier(of entry: Entry) throws -> String {
        let roots = try memoryChildren(entry.bytes, start: 0, end: entry.bytes.count)
        guard roots.count == 1, let root = roots.first, root.type == "----" else {
            throw Failure.malformedAtom
        }
        let children = try memoryChildren(entry.bytes, start: Int(root.body), end: Int(root.end))
        let mean = try unique("mean", in: children)
        let name = try unique("name", in: children)
        guard mean.end - mean.body > 4, name.end - name.body > 4,
              let namespace = String(data: entry.bytes[(Int(mean.body) + 4)..<Int(mean.end)], encoding: .utf8),
              let key = String(data: entry.bytes[(Int(name.body) + 4)..<Int(name.end)], encoding: .utf8) else {
            throw Failure.malformedAtom
        }
        return keySpaceID + "/" + namespace + "." + key
    }

    /// Adds only missing entries. An exact existing entry is an idempotent
    /// no-op; conflicting existing freeform metadata is never overwritten.
    @discardableResult
    static func insertIfMissing(
        _ desired: [Entry],
        into url: URL,
        cancellation: () throws -> Void = {}
    ) throws -> Bool {
        guard !desired.isEmpty else { return false }
        try cancellation()
        let file = try MovieFile(url: url, writable: true)
        guard flock(file.fd, LOCK_EX | LOCK_NB) == 0 else {
            throw Failure.io(errno)
        }
        defer { _ = flock(file.fd, LOCK_UN) }
        let movie = try movieHeader(in: file)
        guard try file.children(0, file.extent).allSatisfy({
            $0.sizeEncoding != 0 || $0.start == movie.start
        }) else { throw Failure.unsupportedAtomSize }
        let foundLocations = try locations(in: file, movie: movie)
        let existing = try entries(in: file, locations: foundLocations)
        let desiredIDs = try desired.map(metadataIdentifier)
        guard Set(desiredIDs).count == desired.count else { throw Failure.ambiguousMetadata }
        let existingIDs = try existing.map(metadataIdentifier)
        var missing: [Entry] = []
        for (index, id) in desiredIDs.enumerated() {
            let matching = existing.indices.filter { existingIDs[$0] == id }
            guard matching.count <= 1 else { throw Failure.ambiguousMetadata }
            if let match = matching.first {
                guard existing[match] == desired[index] else { throw Failure.conflictingMetadata }
            } else { missing.append(desired[index]) }
        }
        guard !missing.isEmpty else { return false }
        guard foundLocations.count <= 1 else { throw Failure.ambiguousMetadata }
        let rawEntries = missing.reduce(into: Data()) { $0.append($1.bytes) }
        let insertion: Int64
        let added: Data
        let ancestors: [Node]
        if let location = foundLocations.first {
            if let list = location.list {
                insertion = list.end
                added = rawEntries
                ancestors = location.parents + [list]
            } else {
                insertion = location.parents.last!.end
                added = atom("ilst", rawEntries)
                ancestors = location.parents
            }
        } else if let userdata = try file.children(movie.body, movie.end)
            .first(where: { $0.type == "udta" }) {
            insertion = userdata.end
            added = metadataAtom(rawEntries)
            ancestors = [movie, userdata]
        } else {
            insertion = movie.end
            added = atom("udta", metadataAtom(rawEntries))
            ancestors = [movie]
        }
        var replacements: [(offset: Int64, bytes: Data)] = []
        for node in ancestors {
            let (expanded, overflow) = node.size.addingReportingOverflow(Int64(added.count))
            guard !overflow else { throw Failure.unsupportedAtomSize }
            if node.sizeEncoding == 1 {
                replacements.append((node.start + 8, be(UInt64(expanded))))
            } else if node.sizeEncoding == 0 {
                // A zero child size continues to extend to its parent's end.
                // The new top-level movie must have an explicit size because
                // it is appended after the original complete file.
                if node.start == movie.start {
                    guard expanded <= Int64(UInt32.max) else {
                        throw Failure.unsupportedAtomSize
                    }
                    replacements.append((node.start, be(UInt32(expanded))))
                }
            } else {
                guard expanded <= Int64(UInt32.max) else {
                    throw Failure.unsupportedAtomSize
                }
                replacements.append((node.start, be(UInt32(expanded))))
            }
        }
        replacements.sort { $0.offset < $1.offset }
        let retirementOffset = movie.sizeEncoding == 0 ? movie.start : movie.start + 4
        let oldRetirementBytes = try file.read(retirementOffset, movie.sizeEncoding == 0 ? 8 : 4)
        let retirementBytes = movie.sizeEncoding == 0
            ? be(UInt32(movie.size)) + Data("free".utf8)
            : Data("free".utf8)
        let (copiedExtent, firstOverflow) = file.extent.addingReportingOverflow(movie.size)
        let (finalExtent, secondOverflow) = copiedExtent.addingReportingOverflow(Int64(added.count))
        guard !firstOverflow, !secondOverflow else { throw Failure.unsupportedAtomSize }
        try file.requireUnchangedExtent()
        try cancellation()
        var wrote = false
        var typeMayHaveChanged = false
        do {
            var sourceOffset = movie.start
            var destinationOffset = file.extent
            func copy(until end: Int64) throws {
                guard sourceOffset <= end else { throw Failure.malformedAtom }
                while sourceOffset < end {
                    try cancellation()
                    let count = Int(min(Int64(copyChunkBytes), end - sourceOffset))
                    let bytes = try file.read(sourceOffset, count)
                    wrote = true
                    try file.write(destinationOffset, bytes)
                    sourceOffset += Int64(count)
                    destinationOffset += Int64(count)
                }
            }
            for replacement in replacements {
                try copy(until: replacement.offset)
                try cancellation()
                wrote = true
                try file.write(destinationOffset, replacement.bytes)
                sourceOffset += Int64(replacement.bytes.count)
                destinationOffset += Int64(replacement.bytes.count)
            }
            try copy(until: insertion)
            try cancellation()
            wrote = true
            try file.write(destinationOffset, added)
            destinationOffset += Int64(added.count)
            try copy(until: movie.end)
            guard destinationOffset == finalExtent else {
                throw Failure.malformedAtom
            }
            guard fsync(file.fd) == 0 else { throw Failure.io(errno) }
            try cancellation()
            // The old media bytes and sample offsets remain in place. Only
            // after the complete new header is durable do we retire the old.
            typeMayHaveChanged = true
            try file.write(retirementOffset, retirementBytes)
            guard fsync(file.fd) == 0 else { throw Failure.io(errno) }
            try cancellation()
            return true
        } catch {
            if typeMayHaveChanged { try? file.write(retirementOffset, oldRetirementBytes) }
            if wrote { _ = ftruncate(file.fd, off_t(file.extent)) }
            _ = fsync(file.fd)
            throw error
        }
    }

    struct TimingRun: Codable, Equatable, Hashable, Sendable {
        let packetCount: UInt32
        let duration: UInt32
    }

    struct Edit: Codable, Equatable, Hashable, Sendable {
        let movieDuration: UInt64
        let mediaTime: Int64
        let mediaRate: Int32
    }

    struct PacketTable: Codable, Equatable, Hashable, Sendable {
        let trackOrdinal: Int
        let movieTimescale: UInt32
        let mediaTimescale: UInt32
        let mediaDuration: UInt64
        let packetCount: UInt64
        let timingRuns: [TimingRun]
        let edits: [Edit]
    }

    /// Reads the actual sample count, media clock and edit map directly from
    /// the header. This does not interpret iTunSMPB or decoder skip attachments.
    static func audioPacketTable(in url: URL, trackOrdinal: Int) throws -> PacketTable {
        let file = try MovieFile(url: url.resolvingSymlinksInPath(), writable: false)
        let movie = try movieHeader(in: file)
        let movieChildren = try file.children(movie.body, movie.end)
        let movieClock = try clock(file, node: unique("mvhd", in: movieChildren))
        let tracks = movieChildren.filter { $0.type == "trak" }
        guard tracks.indices.contains(trackOrdinal) else { throw Failure.invalidFile }
        let track = tracks[trackOrdinal]
        let trackChildren = try file.children(track.body, track.end)
        let media = try unique("mdia", in: trackChildren)
        let mediaChildren = try file.children(media.body, media.end)
        let handler = try unique("hdlr", in: mediaChildren)
        guard handler.end - handler.body >= 12,
              try file.read(handler.body + 8, 4) == Data("soun".utf8) else {
            throw Failure.invalidFile
        }
        let mediaClock = try clock(file, node: unique("mdhd", in: mediaChildren))
        let info = try unique("minf", in: mediaChildren)
        let sampleTable = try unique("stbl", in: file.children(info.body, info.end))
        let tables = try file.children(sampleTable.body, sampleTable.end)
        let sizes = try unique("stsz", in: tables)
        guard sizes.end - sizes.body >= 12,
              try file.read(sizes.body, 4) == Data(repeating: 0, count: 4) else {
            throw Failure.malformedAtom
        }
        let sizeHeader = try file.read(sizes.body + 4, 8)
        let constantSize = uint(sizeHeader, 0, 4)
        let packetCount = uint(sizeHeader, 4, 4)
        guard sizes.end - sizes.body == 12 + (constantSize == 0 ? Int64(packetCount) * 4 : 0) else {
            throw Failure.malformedAtom
        }
        let times = try unique("stts", in: tables)
        guard times.end - times.body >= 8,
              try file.read(times.body, 4) == Data(repeating: 0, count: 4) else {
            throw Failure.malformedAtom
        }
        let count = uint(try file.read(times.body + 4, 4), 0, 4)
        guard count <= 65_536, times.end - times.body == 8 + Int64(count) * 8 else {
            throw Failure.metadataTooLarge
        }
        var runs: [TimingRun] = []
        var totalPackets: UInt64 = 0
        var totalTicks: UInt64 = 0
        for index in 0..<Int(count) {
            let bytes = try file.read(times.body + 8 + Int64(index) * 8, 8)
            let packets = uint(bytes, 0, 4), duration = uint(bytes, 4, 4)
            guard packets > 0, duration > 0 else { throw Failure.malformedAtom }
            let (packetsSum, packetsOverflow) = totalPackets.addingReportingOverflow(packets)
            let (ticksSum, ticksOverflow) = totalTicks.addingReportingOverflow(packets * duration)
            guard !packetsOverflow, !ticksOverflow else { throw Failure.malformedAtom }
            totalPackets = packetsSum; totalTicks = ticksSum
            runs.append(TimingRun(packetCount: UInt32(packets), duration: UInt32(duration)))
        }
        guard totalPackets == packetCount, totalTicks == mediaClock.duration else {
            throw Failure.malformedAtom
        }
        var edits: [Edit] = []
        let editContainers = trackChildren.filter { $0.type == "edts" }
        guard editContainers.count <= 1 else { throw Failure.ambiguousMetadata }
        if let container = editContainers.first {
            let editList = try unique("elst", in: file.children(container.body, container.end))
            guard editList.end - editList.body >= 8 else { throw Failure.malformedAtom }
            let header = try file.read(editList.body, 8)
            guard header[0] <= 1, header[1..<4] == Data(repeating: 0, count: 3) else {
                throw Failure.malformedAtom
            }
            let width = header[0] == 0 ? 4 : 8
            let recordSize = width * 2 + 4
            let count = uint(header, 4, 4)
            guard count <= 65_536,
                  editList.end - editList.body == 8 + Int64(count) * Int64(recordSize) else {
                throw Failure.metadataTooLarge
            }
            for index in 0..<Int(count) {
                let bytes = try file.read(editList.body + 8 + Int64(index * recordSize), recordSize)
                let rawTime = uint(bytes, width, width)
                let mediaTime = width == 4 ? Int64(Int32(bitPattern: UInt32(rawTime))) : Int64(bitPattern: rawTime)
                edits.append(Edit(movieDuration: uint(bytes, 0, width), mediaTime: mediaTime,
                    mediaRate: Int32(bitPattern: UInt32(uint(bytes, width * 2, 4)))))
            }
        }
        return PacketTable(trackOrdinal: trackOrdinal, movieTimescale: movieClock.scale,
            mediaTimescale: mediaClock.scale, mediaDuration: mediaClock.duration,
            packetCount: packetCount, timingRuns: runs, edits: edits)
    }

    static func audioPayloadSHA256(
        in url: URL, trackOrdinal: Int, cancellation: () throws -> Void = {}
    ) throws -> String {
        try cancellation()
        let file = try MovieFile(url: url.resolvingSymlinksInPath(), writable: false)
        let movie = try movieHeader(in: file)
        let tracks = try file.children(movie.body, movie.end).filter { $0.type == "trak" }
        guard tracks.indices.contains(trackOrdinal) else { throw Failure.invalidFile }
        let track = tracks[trackOrdinal]
        let media = try unique("mdia", in: file.children(track.body, track.end))
        let mediaChildren = try file.children(media.body, media.end)
        let handler = try unique("hdlr", in: mediaChildren)
        guard handler.end - handler.body >= 12,
              try file.read(handler.body + 8, 4) == Data("soun".utf8) else { throw Failure.invalidFile }
        let info = try unique("minf", in: mediaChildren)
        let table = try unique("stbl", in: file.children(info.body, info.end))
        let children = try file.children(table.body, table.end)
        let sizeTable = try unique("stsz", in: children)
        guard sizeTable.end - sizeTable.body >= 12,
              try file.read(sizeTable.body, 4) == Data(repeating: 0, count: 4) else {
            throw Failure.malformedAtom
        }
        let sizeHeader = try file.read(sizeTable.body + 4, 8)
        let fixedSize = uint(sizeHeader, 0, 4), packetCount = uint(sizeHeader, 4, 4)
        guard sizeTable.end - sizeTable.body == 12 + (fixedSize == 0 ? Int64(packetCount) * 4 : 0) else {
            throw Failure.malformedAtom
        }
        let offsetTables = children.filter { $0.type == "stco" || $0.type == "co64" }
        guard offsetTables.count == 1, let offsets = offsetTables.first,
              offsets.end - offsets.body >= 8,
              try file.read(offsets.body, 4) == Data(repeating: 0, count: 4) else {
            throw Failure.malformedAtom
        }
        let offsetWidth = offsets.type == "stco" ? 4 : 8
        let chunkCount = uint(try file.read(offsets.body + 4, 4), 0, 4)
        guard offsets.end - offsets.body == 8 + Int64(chunkCount) * Int64(offsetWidth) else {
            throw Failure.malformedAtom
        }
        let mappings = try unique("stsc", in: children)
        guard mappings.end - mappings.body >= 8,
              try file.read(mappings.body, 4) == Data(repeating: 0, count: 4) else {
            throw Failure.malformedAtom
        }
        let mappingCount = uint(try file.read(mappings.body + 4, 4), 0, 4)
        guard mappingCount > 0, mappingCount <= 65_536,
              mappings.end - mappings.body == 8 + Int64(mappingCount) * 12 else {
            throw Failure.malformedAtom
        }
        var mapping: [(first: UInt64, packets: UInt64)] = []
        for index in 0..<Int(mappingCount) {
            let bytes = try file.read(mappings.body + 8 + Int64(index) * 12, 12)
            let first = uint(bytes, 0, 4), count = uint(bytes, 4, 4), description = uint(bytes, 8, 4)
            guard first > (mapping.last?.first ?? 0), first <= chunkCount,
                  count > 0, description == 1 else { throw Failure.malformedAtom }
            mapping.append((first, count))
        }
        guard mapping[0].first == 1 else { throw Failure.malformedAtom }
        let mediaRanges = try file.children(0, file.extent).filter { $0.type == "mdat" }
        var digest = SHA256()
        digest.update(data: Data("Mirmir.AACEncodedPackets.v1\0".utf8))
        var packet: UInt64 = 0
        var mappingIndex = 0
        for chunk in 0..<chunkCount {
            try cancellation()
            if mappingIndex + 1 < mapping.count, mapping[mappingIndex + 1].first == chunk + 1 {
                mappingIndex += 1
            }
            let rawOffset = uint(try file.read(offsets.body + 8 + Int64(chunk) * Int64(offsetWidth), offsetWidth), 0, offsetWidth)
            guard rawOffset <= UInt64(Int64.max) else { throw Failure.malformedAtom }
            var offset = Int64(rawOffset)
            for _ in 0..<mapping[mappingIndex].packets {
                guard packet < packetCount else { throw Failure.malformedAtom }
                let size = fixedSize == 0
                    ? uint(try file.read(sizeTable.body + 12 + Int64(packet) * 4, 4), 0, 4)
                    : fixedSize
                guard size > 0, mediaRanges.contains(where: {
                    offset >= $0.body && offset <= $0.end && size <= UInt64($0.end - offset)
                }) else { throw Failure.malformedAtom }
                digest.update(data: be(size))
                var remaining = Int64(size)
                while remaining > 0 {
                    try cancellation()
                    let count = Int(min(Int64(copyChunkBytes), remaining))
                    digest.update(data: try file.read(offset, count))
                    offset += Int64(count); remaining -= Int64(count)
                }
                packet += 1
            }
        }
        guard packet == packetCount else { throw Failure.malformedAtom }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func unique(_ type: String, in children: [Node]) throws -> Node {
        let matches = children.filter { $0.type == type }
        guard matches.count == 1 else { throw Failure.malformedAtom }
        return matches[0]
    }

    private static func clock(_ file: MovieFile, node: Node) throws -> (scale: UInt32, duration: UInt64) {
        guard node.end - node.body >= 4 else { throw Failure.malformedAtom }
        let version = try file.read(node.body, 1)[0]
        guard version <= 1 else { throw Failure.malformedAtom }
        let offset: Int64 = version == 0 ? 12 : 20
        let durationWidth = version == 0 ? 4 : 8
        guard node.end - node.body >= offset + Int64(4 + durationWidth) else {
            throw Failure.malformedAtom
        }
        let bytes = try file.read(node.body + offset, 4 + durationWidth)
        let scale = UInt32(uint(bytes, 0, 4))
        guard scale > 0 else { throw Failure.malformedAtom }
        return (scale, uint(bytes, 4, durationWidth))
    }

    private static func uint(_ bytes: Data, _ offset: Int, _ width: Int) -> UInt64 {
        bytes[offset..<(offset + width)].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
    }

    private struct Node {
        let start: Int64
        let size: Int64
        let headerBytes: Int
        let sizeEncoding: UInt32
        let type: String
        var body: Int64 { start + Int64(headerBytes) }
        var end: Int64 { start + size }
    }

    private struct Location {
        let parents: [Node]
        let list: Node?
    }

    private static func movieHeader(in file: MovieFile) throws -> Node {
        let movies = try file.children(0, file.extent).filter { $0.type == "moov" }
        guard !movies.isEmpty else { throw Failure.missingMovieHeader }
        guard movies.count == 1 else { throw Failure.multipleMovieHeaders }
        return movies[0]
    }

    private static func locations(in file: MovieFile, movie: Node? = nil) throws -> [Location] {
        let movie = try movie ?? movieHeader(in: file)
        var result: [Location] = []
        for child in try file.children(movie.body, movie.end) {
            let metadata: [(Node, [Node])]
            if child.type == "udta" {
                metadata = try file.children(child.body, child.end)
                    .filter { $0.type == "meta" }.map { ($0, [movie, child, $0]) }
            } else if child.type == "meta" {
                metadata = [(child, [movie, child])]
            } else { continue }
            for (meta, parents) in metadata {
                guard meta.end - meta.body >= 4 else { throw Failure.malformedAtom }
                let children = try file.children(meta.body + 4, meta.end)
                let handlers = children.filter { $0.type == "hdlr" }
                guard handlers.count <= 1 else { throw Failure.ambiguousMetadata }
                guard let handler = handlers.first, handler.end - handler.body >= 12,
                      try file.read(handler.body + 8, 4) == Data("mdir".utf8) else {
                    continue
                }
                let lists = children.filter { $0.type == "ilst" }
                guard lists.count <= 1 else { throw Failure.ambiguousMetadata }
                result.append(Location(parents: parents, list: lists.first))
            }
        }
        return result
    }

    private static func entries(in file: MovieFile, locations: [Location], onlyGapless: Bool = false) throws -> [Entry] {
        var result: [Entry] = []
        for location in locations {
            guard let list = location.list else { continue }
            for entry in try file.children(list.body, list.end) where entry.type == "----" {
                let children = try file.children(entry.body, entry.end)
                let means = children.filter { $0.type == "mean" }
                let names = children.filter { $0.type == "name" }
                guard means.count == 1, names.count == 1,
                      means[0].end - means[0].body > 4,
                      names[0].end - names[0].body > 4 else { continue }
                if onlyGapless {
                    guard means[0].end - means[0].body == 20,
                          names[0].end - names[0].body == 12,
                          try file.read(means[0].body + 4, 16) == Data("com.apple.iTunes".utf8),
                          try file.read(names[0].body + 4, 8) == Data("iTunSMPB".utf8) else { continue }
                }
                guard !onlyGapless || entry.size <= Int64(maximumEntryBytes) else {
                    throw Failure.metadataTooLarge
                }
                result.append(Entry(bytes: try file.read(entry.start, Int(entry.size))))
            }
        }
        return result
    }

    private static func metadataAtom(_ entries: Data) -> Data {
        let handler = fullAtom("hdlr", be(UInt32(0)) + Data("mdirappl".utf8)
            + Data(repeating: 0, count: 9))
        return fullAtom("meta", handler + atom("ilst", entries))
    }

    private static func be<T: FixedWidthInteger>(_ value: T) -> Data {
        var value = value.bigEndian
        return withUnsafeBytes(of: &value) { Data($0) }
    }

    private static func atom(_ type: String, _ body: Data) -> Data {
        be(UInt32(body.count + 8)) + Data(type.utf8) + body
    }

    private static func fullAtom(_ type: String, _ body: Data, flags: UInt32 = 0) -> Data {
        atom(type, be(flags) + body)
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
                } else { bytes = 8; size = UInt64(size32) }
                guard size >= UInt64(bytes), size <= UInt64(end - offset),
                      let type = String(data: Data(header[4..<8]), encoding: .isoLatin1) else {
                    throw Failure.malformedAtom
                }
                result.append(Node(start: offset, size: Int64(size), headerBytes: bytes,
                    sizeEncoding: size32, type: type))
                offset += Int64(size)
            }
            return result
        }
    }
}
