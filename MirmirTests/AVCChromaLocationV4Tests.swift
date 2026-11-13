import CoreMedia
import CoreVideo
import Foundation
import XCTest
@testable import Mirmir

final class AVCChromaLocationV4Tests: XCTestCase {
    // Actual encoder SPS controls independently traced as AVC VUI types 0...5.
    private let golden = [
        "2764000bac56830de0879a80808081",
        "2764000bac56830de0879a808080d204",
        "2764000bac56830de0879a808080db04",
        "2764000bac56830de0879a808080c84040",
        "2764000bac56830de0879a808080ca5040",
        "2764000bac56830de0879a808080cc6040"
    ]

    func testReadsEveryPhysicalLocationAndNonzeroDataIndices() throws {
        for (location, fixture) in golden.enumerated() {
            let data = hex(fixture)
            let facts = try AVCChromaLocationV4.read(data)
            XCTAssertEqual(facts.top, UInt8(location))
            XCTAssertEqual(facts.bottom, UInt8(location))
            XCTAssertEqual(facts.chromaFormat, 1)
            XCTAssertEqual(facts.bitDepth, 8)
            XCTAssertTrue(facts.progressive)
            var prefixed = Data([0x99])
            prefixed.append(data)
            XCTAssertEqual(try AVCChromaLocationV4.read(prefixed.dropFirst()), facts)
        }
    }

    func testOmittedVUIAndExplicitZeroHaveTheSamePhysicalPhase() throws {
        let absent = try AVCChromaLocationV4.read(hex("67420028f4106c80"))
        let omitted = try AVCChromaLocationV4.read(hex("67420028f4106d0040"))
        let explicit = try AVCChromaLocationV4.read(hex("67420028f4106d1c10"))
        for facts in [absent, omitted, explicit] {
            XCTAssertEqual(facts.top, 0)
            XCTAssertEqual(facts.bottom, 0)
        }
        XCTAssertFalse(absent.explicitLocation)
        XCTAssertFalse(omitted.explicitLocation)
        XCTAssertTrue(explicit.explicitLocation)
    }

    func testScalingPOCTimingHRDAndHighChromaBranchesAreBounded() throws {
        let fixtures = [
            "67640028ad844074106ffff80008000fa808080db800000300080000030186802a9800002802a9800001da08846a",
            "67640028ad844050a623a4106ffff80008000fa808080db800000300080000030186802a9800002802a9800001da08846a",
            "67640028ad84405a0837fffc00040007d4040406dc000003000400000300c340154c0000140154c00000ed044235"
        ]
        for fixture in fixtures {
            let facts = try AVCChromaLocationV4.read(hex(fixture))
            XCTAssertEqual(facts.top, 2)
            XCTAssertEqual(facts.bottom, 2)
        }
        let high = try AVCChromaLocationV4.read(hex("67f4002890db08800e820da2d820"))
        XCTAssertEqual(high.chromaFormat, 3)
        XCTAssertEqual(high.bitDepth, 10)
    }

    func testRejectsTruncationMalformedRBSPAndConflictingSPS() throws {
        for fixture in golden {
            let data = hex(fixture)
            for length in 0..<data.count {
                XCTAssertThrowsError(try AVCChromaLocationV4.read(Data(data.prefix(length))))
            }
            XCTAssertThrowsError(try AVCChromaLocationV4.read(data + Data([0])))
        }
        for data in [Data(), Data(repeating: 0, count: 65_537),
                     hex("e764000bac56830de0879a808080db04"),
                     hex("0764000bac56830de0879a808080db04"),
                     hex("2764000bac56830de0879a808080db04000003"),
                     hex("2764000bac56830de0879a808080db0400000304")] {
            XCTAssertThrowsError(try AVCChromaLocationV4.read(data))
        }
        let left = hex(golden[0])
        let leftID1 = hex("674200285d041b4704")
        let centerID1 = hex("674200285d041b452040")
        XCTAssertNoThrow(try AVCChromaLocationV4.agreeing([left, left]))
        XCTAssertNoThrow(try AVCChromaLocationV4.agreeing([left, leftID1]))
        XCTAssertThrowsError(try AVCChromaLocationV4.agreeing([]))
        XCTAssertThrowsError(try AVCChromaLocationV4.agreeing([left, hex(golden[1])]))
        XCTAssertThrowsError(try AVCChromaLocationV4.agreeing([left, centerID1]))
        XCTAssertThrowsError(try AVCChromaLocationV4.agreeing([left, Data(left.dropLast())]))
    }

    func testNativeAliasRequiresPhysicalTopLeftAndKeepsOtherMetadata() throws {
        let aliasFormat = try format(sps: hex(golden[2]), top: "Center", bottom: "Center")
        let declaration = try XCTUnwrap(AVCChromaLocationV4.declaration(from: aliasFormat))
        XCTAssertEqual(declaration.location, .topLeft)
        XCTAssertTrue(declaration.correctsNativeTopLeftAlias)
        let buffer = try pixelBuffer()
        CVBufferSetAttachment(buffer, kCVImageBufferChromaLocationTopFieldKey,
            kCVImageBufferChromaLocation_Center, .shouldNotPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferChromaLocationBottomFieldKey,
            kCVImageBufferChromaLocation_Center, .shouldNotPropagate)
        CVBufferSetAttachment(buffer, "com.mirmir.qa.unknown" as CFString,
            Data([1, 2, 3]) as CFData, .shouldNotPropagate)
        let bytes = try visibleBytes(buffer)
        try AVCChromaLocationV4.normalizeDecodedBuffer(buffer, source: declaration)
        XCTAssertEqual(try visibleBytes(buffer), bytes)
        XCTAssertEqual(CVBufferCopyAttachment(buffer,
            kCVImageBufferChromaLocationTopFieldKey, nil) as? String, "TopLeft")
        XCTAssertEqual(CVBufferCopyAttachment(buffer,
            kCVImageBufferChromaLocationBottomFieldKey, nil) as? String, "TopLeft")
        XCTAssertEqual(CVBufferCopyAttachment(buffer, "com.mirmir.qa.unknown" as CFString,
            nil) as? Data, Data([1, 2, 3]))
        let first = attachments(buffer)
        try AVCChromaLocationV4.normalizeDecodedBuffer(buffer, source: declaration)
        XCTAssertEqual(attachments(buffer), first)
        XCTAssertThrowsError(try AVCChromaLocationV4.declaration(
            from: format(sps: hex(golden[2]), top: "Left", bottom: "Left")))
        XCTAssertThrowsError(try AVCChromaLocationV4.declaration(
            from: format(sps: hex(golden[1]), top: "TopLeft", bottom: "TopLeft")))
        XCTAssertThrowsError(try AVCChromaLocationV4.declaration(from: [
            format(sps: hex(golden[0])), format(sps: hex(golden[1]))
        ]))
    }

    func testDecodedContradictionsRejectBeforeMutationAndNilProofDoesNothing() throws {
        let declaration = try XCTUnwrap(AVCChromaLocationV4.declaration(
            from: format(sps: hex(golden[2]), top: "Center", bottom: "Center")))
        let buffer = try pixelBuffer()
        for (top, bottom) in [
            ("Left" as NSString, "Left" as NSString),
            ("Center" as NSString, "Left" as NSString),
            (NSNumber(value: 1), "Center" as NSString),
            ("Unspecified" as NSString, "Center" as NSString)
        ] {
            CVBufferRemoveAllAttachments(buffer)
            CVBufferSetAttachment(buffer, kCVImageBufferChromaLocationTopFieldKey,
                top, .shouldPropagate)
            CVBufferSetAttachment(buffer, kCVImageBufferChromaLocationBottomFieldKey,
                bottom, .shouldPropagate)
            let bytes = try visibleBytes(buffer), metadata = attachments(buffer)
            XCTAssertThrowsError(try AVCChromaLocationV4.normalizeDecodedBuffer(
                buffer, source: declaration))
            XCTAssertEqual(try visibleBytes(buffer), bytes)
            XCTAssertEqual(attachments(buffer), metadata)
        }
        CVBufferRemoveAllAttachments(buffer)
        let missing = try visibleBytes(buffer)
        try AVCChromaLocationV4.normalizeDecodedBuffer(buffer, source: declaration)
        XCTAssertEqual(try visibleBytes(buffer), missing)
        XCTAssertEqual(CVBufferCopyAttachment(buffer,
            kCVImageBufferChromaLocationTopFieldKey, nil) as? String, "TopLeft")
        CVBufferRemoveAllAttachments(buffer)
        let withoutProof = attachments(buffer)
        try AVCChromaLocationV4.normalizeDecodedBuffer(buffer, source: nil)
        XCTAssertEqual(attachments(buffer), withoutProof)
    }

    func testInterlacedSPSRetainsIndependentKnownFieldLocations() throws {
        let sps = hex("67420028f410668d82")
        let declaration = try XCTUnwrap(AVCChromaLocationV4.declaration(
            from: format(sps: sps, top: "Left", bottom: "TopLeft")))
        XCTAssertFalse(declaration.facts.progressive)
        XCTAssertEqual(declaration.location, .left)
        XCTAssertEqual(declaration.bottomLocation, .topLeft)
        XCTAssertFalse(declaration.correctsNativeTopLeftAlias)
        XCTAssertThrowsError(try AVCChromaLocationV4.declaration(
            from: format(sps: sps, top: "Left", bottom: "Center")))
        XCTAssertThrowsError(try AVCChromaLocationV4.declaration(from: [
            format(sps: sps, top: "Left", bottom: "TopLeft"), format(sps: hex(golden[0]))
        ]))
    }

    func testExplicitCanonicalFieldPairUsesVersion42AndRejectsForgedCommonShape() throws {
        let pair = CanonicalFieldChromaSitingV4(top: .left, bottom: .center)
        let state = try canonicalState(pair: pair)
        XCTAssertEqual(state.schemaID, "ash.canonical-media-state.v4.2")
        XCTAssertEqual(state.tracks[0].video?.pixel.chromaSiting, .unknown)
        let data = try ASHCanonicalJSONV4.encode(state)
        let decoded = try JSONDecoder().decode(CanonicalMediaStateV4.self, from: data)
        try decoded.validate()
        XCTAssertEqual(try decoded.canonicalSHA256, try state.canonicalSHA256)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        func altered(_ change: (inout [String: Any]) -> Void) throws -> CanonicalMediaStateV4 {
            var changed = object; change(&changed)
            return try JSONDecoder().decode(CanonicalMediaStateV4.self,
                from: JSONSerialization.data(withJSONObject: changed))
        }
        XCTAssertThrowsError(try altered { $0["schemaID"] = "ash.canonical-media-state.v4.1" }.validate())
        for invalid in [CanonicalFieldChromaSitingV4(top: .left, bottom: .left),
                        CanonicalFieldChromaSitingV4(top: .unknown, bottom: .left),
                        CanonicalFieldChromaSitingV4(top: .notApplicable, bottom: .left)] {
            XCTAssertThrowsError(try canonicalState(pair: invalid))
        }
        XCTAssertThrowsError(try canonicalState(pair: pair, count: 1))
        XCTAssertThrowsError(try canonicalState(pair: pair, subsampling: .yuv422))
        XCTAssertThrowsError(try canonicalState(pair: pair, aggregate: .left))
        for mutation in 0..<4 {
            XCTAssertThrowsError(try altered { document in
                var tracks = document["tracks"] as! [[String: Any]]
                var video = tracks[0]["video"] as! [String: Any]
                var pixel = video["pixel"] as! [String: Any]
                if mutation == 0 { pixel["fieldChromaSiting"] = NSNull() }
                if mutation == 1 { pixel["extra"] = 1 }
                if mutation == 2 {
                    var fields = pixel["fieldChromaSiting"] as! [String: Any]
                    fields["schemaID"] = "foreign"; pixel["fieldChromaSiting"] = fields
                }
                if mutation == 3 {
                    var fields = pixel["fieldChromaSiting"] as! [String: Any]
                    fields["extra"] = 1; pixel["fieldChromaSiting"] = fields
                }
                video["pixel"] = pixel; tracks[0]["video"] = video; document["tracks"] = tracks
            }.validate())
        }
    }

    func testCanonicalCommonPhaseRetainsLegacyKeysAndVersion41() throws {
        let common = try canonicalState(pair: nil, aggregate: .left)
        XCTAssertEqual(common.schemaID, "ash.canonical-media-state.v4.1")
        XCTAssertEqual(try common.canonicalSHA256.rawValue,
            "eea53f6b54895d5782336c091438f4e3ff58a1c96aa46a435543ae8cc1e7c47a")
        let bytes = try ASHCanonicalJSONV4.encode(common)
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("fieldChromaSiting"))
        let decoded = try JSONDecoder().decode(CanonicalMediaStateV4.self, from: bytes)
        XCTAssertEqual(try ASHCanonicalJSONV4.encode(decoded), bytes)
        XCTAssertEqual(try decoded.canonicalSHA256, try common.canonicalSHA256)
    }

    private func canonicalState(pair: CanonicalFieldChromaSitingV4?,
        count: UInt8 = 2, subsampling: CanonicalChromaSubsamplingV4 = .yuv420,
        aggregate: CanonicalChromaSitingV4 = .unknown) throws -> CanonicalMediaStateV4 {
        let hash = ASHSHA256V4(rawData: Data("field-chroma-fixture".utf8))
        return try CanonicalMediaStateV4(input: CanonicalInputIdentityV4(
            contentSHA256: hash, byteCount: 1, fileName: "source.mov",
            bookmarkReference: "field-chroma-fixture", bookmarkDocumentSHA256: hash),
            tracks: [CanonicalMediaTrackV4(identity: .init(ordinal: 0, persistentID: "video-0"),
                enabled: true, kind: .video, languageTag: nil, roleIDs: [], codecID: "h264",
                timebase: try ExactRationalV4(1, 24), duration: .one, edits: [], metadata: [],
                video: CanonicalVideoStateV4(encodedRaster: .init(width: 128, height: 96),
                    presentationRaster: .init(width: 128, height: 96), preferredTransform: .identity,
                    cleanAperture: nil, pixelAspectRatio: .one,
                    pixel: .init(formatID: "encoded-fourcc-61766331", bitDepth: 8, range: .video,
                        chromaSubsampling: subsampling, chromaSiting: aggregate, alphaModel: .none,
                        fieldChromaSiting: pair),
                    color: .init(primaries: "bt709", transferFunction: "bt709", matrix: "bt709",
                        masteringDisplay: nil, contentLightLevel: nil, dynamicHDRMetadata: []),
                    scan: .init(fieldCount: count, dominance: count == 1 ? .none : .topFieldFirst,
                        cadence: count == 1 ? .progressive : .interlaced)))], observations: [])
    }

    func testAuthenticatedMBAFFFieldDeclarationRepairsOnlyQualifiedDecoderOmission() throws {
        let source = try XCTUnwrap(AVCChromaLocationV4.declaration(from: format(
            sps: hex("67420028f410668d82"), top: "Left", bottom: "TopLeft",
            fieldCount: 2, fieldDetail: "TemporalTopFirst")))
        XCTAssertTrue(source.facts.macroblockAdaptiveField)
        XCTAssertEqual(source.sourceInterlacedFieldDetail, "TemporalTopFirst")
        let buffer = try pixelBuffer()
        CVBufferSetAttachment(buffer, kCVImageBufferFieldCountKey, NSNumber(value: 1), .shouldNotPropagate)
        CVBufferSetAttachment(buffer, "com.mirmir.qa.unknown" as CFString,
            Data([4, 5]) as CFData, .shouldNotPropagate)
        let bytes = try visibleBytes(buffer)
        try AVCChromaLocationV4.normalizeDecodedInterlacedFieldDeclaration(buffer, source: source)
        XCTAssertEqual(try visibleBytes(buffer), bytes)
        XCTAssertEqual((CVBufferCopyAttachment(buffer, kCVImageBufferFieldCountKey, nil) as? NSNumber)?.intValue, 2)
        XCTAssertEqual(CVBufferCopyAttachment(buffer, kCVImageBufferFieldDetailKey, nil) as? String, "TemporalTopFirst")
        XCTAssertEqual(CVBufferCopyAttachment(buffer, "com.mirmir.qa.unknown" as CFString, nil) as? Data, Data([4, 5]))
        let corrected = attachments(buffer)
        try AVCChromaLocationV4.normalizeDecodedInterlacedFieldDeclaration(buffer, source: source)
        XCTAssertEqual(attachments(buffer), corrected)
        for invalid in [NSNumber(value: 0), NSNumber(value: 3), NSNumber(value: true), NSNumber(value: 1.5), "1" as NSString] {
            CVBufferRemoveAllAttachments(buffer)
            CVBufferSetAttachment(buffer, kCVImageBufferFieldCountKey, invalid, .shouldPropagate)
            let before = attachments(buffer)
            XCTAssertThrowsError(try AVCChromaLocationV4.normalizeDecodedInterlacedFieldDeclaration(buffer, source: source))
            XCTAssertEqual(attachments(buffer), before)
            XCTAssertEqual(try visibleBytes(buffer), bytes)
        }
        CVBufferRemoveAllAttachments(buffer)
        CVBufferSetAttachment(buffer, kCVImageBufferFieldCountKey, NSNumber(value: 1), .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferFieldDetailKey, "TemporalBottomFirst" as CFString, .shouldPropagate)
        let contradiction = attachments(buffer)
        XCTAssertThrowsError(try AVCChromaLocationV4.normalizeDecodedInterlacedFieldDeclaration(buffer, source: source))
        XCTAssertEqual(attachments(buffer), contradiction)
        CVBufferRemoveAllAttachments(buffer)
        let withoutProof = attachments(buffer)
        try AVCChromaLocationV4.normalizeDecodedInterlacedFieldDeclaration(buffer, source: nil)
        XCTAssertEqual(attachments(buffer), withoutProof)
        let progressive = try XCTUnwrap(AVCChromaLocationV4.declaration(from: format(sps: hex(golden[0]))))
        CVBufferSetAttachment(buffer, kCVImageBufferFieldCountKey, NSNumber(value: 1), .shouldPropagate)
        let untouched = attachments(buffer)
        try AVCChromaLocationV4.normalizeDecodedInterlacedFieldDeclaration(buffer, source: progressive)
        XCTAssertEqual(attachments(buffer), untouched)
    }

    private func format(sps: Data, top: String? = nil, bottom: String? = nil,
        fieldCount: Int? = nil, fieldDetail: String? = nil)
        throws -> CMVideoFormatDescription {
        let pps = hex("28ee3cb0")
        var result: CMFormatDescription?
        let status = sps.withUnsafeBytes { s in pps.withUnsafeBytes { p in
            let pointers = [s.baseAddress!.assumingMemoryBound(to: UInt8.self),
                            p.baseAddress!.assumingMemoryBound(to: UInt8.self)]
            let sizes = [sps.count, pps.count]
            return pointers.withUnsafeBufferPointer { pointers in
                sizes.withUnsafeBufferPointer { sizes in
                    CMVideoFormatDescriptionCreateFromH264ParameterSets(
                        allocator: kCFAllocatorDefault, parameterSetCount: 2,
                        parameterSetPointers: pointers.baseAddress!,
                        parameterSetSizes: sizes.baseAddress!, nalUnitHeaderLength: 4,
                        formatDescriptionOut: &result)
                }
            }
        }}
        XCTAssertEqual(status, noErr)
        let base = try XCTUnwrap(result)
        if top == nil, bottom == nil, fieldCount == nil, fieldDetail == nil { return base }
        let extensions = NSMutableDictionary(dictionary:
            CMFormatDescriptionGetExtensions(base) as NSDictionary? as? [AnyHashable: Any] ?? [:])
        if let top { extensions[kCMFormatDescriptionExtension_ChromaLocationTopField] = top }
        if let bottom { extensions[kCMFormatDescriptionExtension_ChromaLocationBottomField] = bottom }
        if let fieldCount { extensions[kCMFormatDescriptionExtension_FieldCount] = NSNumber(value: fieldCount) }
        if let fieldDetail { extensions[kCMFormatDescriptionExtension_FieldDetail] = fieldDetail }
        var forced: CMFormatDescription?
        XCTAssertEqual(CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault,
            codecType: kCMVideoCodecType_H264, width: 128, height: 96,
            extensions: extensions, formatDescriptionOut: &forced), noErr)
        return try XCTUnwrap(forced)
    }

    private func pixelBuffer() throws -> CVPixelBuffer {
        var result: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 128, 96,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil, &result), kCVReturnSuccess)
        let value = try XCTUnwrap(result)
        XCTAssertEqual(CVPixelBufferLockBaseAddress(value, []), kCVReturnSuccess)
        for plane in 0..<2 {
            memset(CVPixelBufferGetBaseAddressOfPlane(value, plane), 128,
                CVPixelBufferGetBytesPerRowOfPlane(value, plane)
                    * CVPixelBufferGetHeightOfPlane(value, plane))
        }
        CVPixelBufferUnlockBaseAddress(value, [])
        return value
    }

    private func visibleBytes(_ buffer: CVPixelBuffer) throws -> Data {
        XCTAssertEqual(CVPixelBufferLockBaseAddress(buffer, .readOnly), kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        var result = Data()
        for plane in 0..<2 {
            let base = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(buffer, plane))
            let rowBytes = CVPixelBufferGetWidthOfPlane(buffer, plane) * (plane == 0 ? 1 : 2)
            for row in 0..<CVPixelBufferGetHeightOfPlane(buffer, plane) {
                result.append(base.advanced(by: row * CVPixelBufferGetBytesPerRowOfPlane(buffer, plane))
                    .assumingMemoryBound(to: UInt8.self), count: rowBytes)
            }
        }
        return result
    }

    private func attachments(_ buffer: CVPixelBuffer) -> NSDictionary {
        ["propagate": CVBufferCopyAttachments(buffer, .shouldPropagate) as NSDictionary? ?? [:],
         "noPropagate": CVBufferCopyAttachments(buffer, .shouldNotPropagate) as NSDictionary? ?? [:]]
    }
    private func hex(_ text: String) -> Data {
        Data(stride(from: 0, to: text.count, by: 2).map {
            let start = text.index(text.startIndex, offsetBy: $0)
            return UInt8(text[start..<text.index(start, offsetBy: 2)], radix: 16)!
        })
    }
}
