import Darwin
import Foundation

struct ASFObjectFact: Codable, Equatable { let guid: String; let offset: Int; let size: Int; let parent: String }
struct ASFStreamFact: Codable, Equatable { let number: UInt16; let flags: UInt16; let typeGUID: String; let timeOffset100ns: String; let embedded: Bool; let objectOffset: Int }
struct ASFOriginalHeader: Codable, Equatable {
 let bytes: Data; let objects: [ASFObjectFact]; let streams: [ASFStreamFact]
 let hasSelectionRelationships: Bool; let hasEncryption: Bool; let hasUnknownSelectionSemantics: Bool
 var permitsIndependentActivationPolicy: Bool { !hasSelectionRelationships && !hasEncryption && !hasUnknownSelectionSemantics && streams.allSatisfy { !$0.embedded } }
 static func read(fd: Int32, expectedBytes: Int64) throws -> ASFOriginalHeader {
  func preadBytes(_ offset: Int, _ count: Int) throws -> Data {
   guard offset >= 0, count >= 0, count <= 4 * 1024 * 1024, Int64(offset) <= expectedBytes, Int64(count) <= expectedBytes - Int64(offset) else { throw ProbeFailure("ASF bounded original header read exceeds source") }
   var data = Data(count: count); var done = 0
   try data.withUnsafeMutableBytes { raw in while done < count { let n = Darwin.pread(fd, raw.baseAddress!.advanced(by: done), count - done, off_t(offset + done)); if n < 0 && errno == EINTR { continue }; guard n > 0 else { throw ProbeFailure("ASF header pread failed") }; done += n } }; return data
  }
  func le(_ data: Data, _ at: Int, _ count: Int) throws -> UInt64 { guard at >= 0, count > 0, count <= 8, at <= data.count, count <= data.count - at else { throw ProbeFailure("ASF integer outside object") }; return (0..<count).reduce(UInt64(0)) { $0 | UInt64(data[at + $1]) << ($1 * 8) } }
  func guid(_ data: Data, _ at: Int) throws -> String { guard at >= 0, at <= data.count, 16 <= data.count - at else { throw ProbeFailure("ASF GUID outside object") }; return data[at..<at+16].map { String(format: "%02x", $0) }.joined() }
  let prefix = try preadBytes(0, 30)
  guard try guid(prefix, 0) == "3026b2758e66cf11a6d900aa0062ce6c", prefix[28] == 1, prefix[29] == 2 else { throw ProbeFailure("invalid ASF header identity/reserved bytes") }
  let length = try le(prefix, 16, 8); guard length >= 30, length <= 4 * 1024 * 1024, length <= UInt64(expectedBytes) else { throw ProbeFailure("ASF Header Object exceeds four MiB metadata bound") }
  let bytes = try preadBytes(0, Int(length)); var objects: [ASFObjectFact] = [], streams: [ASFStreamFact] = []; var selection = false, encryption = false, unknown = false
  let streamGUID = "9107dcb7b7a9cf118ee600c00c205365", extensionGUID = "b503bf5f2ea9cf118ee300c00c205365", extendedStreamGUID = "cba5e61472c632438399a96952065b5a"
  let selections: Set<String> = ["dc29e2d6da35d111903400a0c90349be", "cf4986a0754770468a166e35357566cd", "405a46d1795a3843b71be36b8fd6c249", "5bd1fed4d3884f4581f0ed5c45999e24", "e60996a67b51d211b6af00c04fd908e9"]
  let encryptions: Set<String> = ["fbb3112223bdd211b4b700a0c955fc6e", "14e68a292226174cb935dae07ee9289c", "338505438169e6499b74ad12cb86d58c"]
  let inert: Set<String> = ["a1dcab8c47a9cf118ee400c00c205365", "4052d1861d31d011a3a400a0c90348f6", "3326b2758e66cf11a6d900aa0062ce6c", "40a4d0d207e3d21197f000a0c95ea850", "74d40618dfca0945a4ba9aabcb96aae8", "ce75f87b8d46d1118d82006097c9a2b2", "a946437ce0effc4bb229393ede415c85", "eacbf8c5af5b77488467aa8c44fa4cca", "941c23449894d149a1411d134e457054"]
  func parseStream(_ at: Int, _ end: Int, embedded: Bool) throws {
   guard end - at >= 78 else { throw ProbeFailure("truncated original ASF Stream Properties") }
   let flags = UInt16(try le(bytes, at + 72, 2)); let number = flags & 0x7f
   guard number > 0, flags & 0x7f80 == 0, try le(bytes, at + 74, 4) == 0 else { throw ProbeFailure("invalid ASF stream number/reserved flags") }
   let typeLength = try le(bytes, at + 64, 4), errorLength = try le(bytes, at + 68, 4)
   guard typeLength <= UInt64(end - at - 78), errorLength <= UInt64(end - at - 78) - typeLength else { throw ProbeFailure("ASF stream payload lengths exceed object") }
   guard !streams.contains(where: { $0.number == number }) else { throw ProbeFailure("duplicate original ASF stream number") }
   streams.append(ASFStreamFact(number: number, flags: flags, typeGUID: try guid(bytes, at + 24), timeOffset100ns: String(try le(bytes, at + 56, 8)), embedded: embedded, objectOffset: at)); encryption = encryption || flags & 0x8000 != 0
  }
  func parseObjects(_ begin: Int, _ end: Int, parent: String, depth: Int) throws -> Int {
   guard depth <= 2 else { throw ProbeFailure("ASF header nesting depth") }; var at = begin, count = 0
   while at < end {
    guard end - at >= 24, objects.count < 4096 else { throw ProbeFailure("ASF object header/count bound") }
    let id = try guid(bytes, at); let size = try le(bytes, at + 16, 8); guard size >= 24, size <= UInt64(end - at) else { throw ProbeFailure("ASF object size exceeds parent") }; let finish = at + Int(size)
    objects.append(ASFObjectFact(guid: id, offset: at, size: Int(size), parent: parent)); count += 1
    if id == streamGUID { try parseStream(at, finish, embedded: false) }
    else if id == extensionGUID {
     guard finish - at >= 46 else { throw ProbeFailure("truncated ASF Header Extension") }; guard try guid(bytes, at + 24) == "11d2d3abbaa9cf118ee600c00c205365", try le(bytes, at + 40, 2) == 6 else { throw ProbeFailure("ASF Header Extension reserved fields conflict") }; let extra = try le(bytes, at + 42, 4); guard extra == UInt64(finish - at - 46) else { throw ProbeFailure("ASF Header Extension length conflict") }; _ = try parseObjects(at + 46, finish, parent: "header-extension", depth: depth + 1)
    } else if id == extendedStreamGUID {
     guard finish - at >= 88 else { throw ProbeFailure("truncated Extended Stream Properties") }
     let flags = try le(bytes, at + 68, 4); guard flags & ~UInt64(15) == 0 else { throw ProbeFailure("unknown ASF Extended Stream reserved flags") }
     var child = at + 88; let names = try le(bytes, at + 84, 2), payloads = try le(bytes, at + 86, 2); guard names <= 1024, payloads <= 1024 else { throw ProbeFailure("ASF extension counts exceed bound") }
     for _ in 0..<names { guard finish - child >= 4 else { throw ProbeFailure("ASF stream name truncated") }; let n = try le(bytes, child + 2, 2); guard n <= UInt64(finish - child - 4) else { throw ProbeFailure("ASF name exceeds object") }; child += 4 + Int(n) }
     for _ in 0..<payloads { guard finish - child >= 22 else { throw ProbeFailure("ASF payload extension truncated") }; let n = try le(bytes, child + 18, 4); guard n <= UInt64(finish - child - 22) else { throw ProbeFailure("ASF payload extension exceeds object") }; child += 22 + Int(n) }
     if child != finish { guard try guid(bytes, child) == streamGUID, try le(bytes, child + 16, 8) == UInt64(finish - child) else { throw ProbeFailure("ASF embedded stream object conflict") }; try parseStream(child, finish, embedded: true) }
    } else if selections.contains(id) { selection = true }
    else if encryptions.contains(id) { encryption = true }
    else if !inert.contains(id) { unknown = true }
    at = finish
   }; return count
  }
  let count = try parseObjects(30, bytes.count, parent: "header", depth: 0); guard try le(bytes, 24, 4) == UInt64(count), !streams.isEmpty else { throw ProbeFailure("ASF header count/inventory conflict") }
  return ASFOriginalHeader(bytes: bytes, objects: objects, streams: streams, hasSelectionRelationships: selection, hasEncryption: encryption, hasUnknownSelectionSemantics: unknown)
 }
}
