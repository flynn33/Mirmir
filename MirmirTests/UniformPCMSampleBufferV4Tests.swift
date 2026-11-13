import AVFoundation
import AudioToolbox
import CoreMedia
import CryptoKit
import XCTest
@testable import Mirmir

final class UniformPCMSampleBufferV4Tests: XCTestCase {
    func testCompactionRetainsPayloadFormatEveryTimingAndAttachmentMode() throws {
        for separateTimings in [false, true] {
            let source = try sample(count: 32, separateTimings: separateTimings)
            CMSetAttachment(source, key: "propagated" as CFString,
                            value: Data([0, 255, 31]) as CFData,
                            attachmentMode: kCMAttachmentMode_ShouldPropagate)
            CMSetAttachment(source, key: "private" as CFString,
                            value: ["nested": [1, 3, 5]] as CFDictionary,
                            attachmentMode: kCMAttachmentMode_ShouldNotPropagate)
            CMSetAttachment(source, key: kCMSampleBufferAttachmentKey_TrimDurationAtStart,
                            value: CMTimeCopyAsDictionary(CMTime(value: 1, timescale: 48_000),
                                                          allocator: kCFAllocatorDefault),
                            attachmentMode: kCMAttachmentMode_ShouldPropagate)
            let sampleAttachments = try XCTUnwrap(CMSampleBufferGetSampleAttachmentsArray(
                source, createIfNecessary: true
            ) as? [NSMutableDictionary])
            for (index, attachment) in sampleAttachments.enumerated() {
                attachment["ordinal"] = index
                attachment[kCMSampleAttachmentKey_NotSync as String] = index % 2 == 0
                attachment["payload"] = Data([UInt8(index), 255])
            }
            let outputPTS = CMTime(value: 19, timescale: 48_000, flags: .valid, epoch: 3)
            XCTAssertEqual(CMSampleBufferSetOutputPresentationTimeStamp(source, newValue: outputPTS), noErr)
            let result = try UniformPCMSampleBufferV4.compactingSizes(in: source)
            XCTAssertFalse(result === source)
            XCTAssertTrue(CMSampleBufferGetDataBuffer(result) === CMSampleBufferGetDataBuffer(source))
            XCTAssertTrue(CMSampleBufferGetFormatDescription(result) === CMSampleBufferGetFormatDescription(source))
            XCTAssertTrue(CMSampleBufferIsValid(result))
            XCTAssertTrue(CMSampleBufferDataIsReady(result))
            XCTAssertEqual(CMSampleBufferGetNumSamples(result), 32)
            XCTAssertEqual(try sizeEntries(source), [Int](repeating: 2, count: 32))
            XCTAssertEqual(try sizeEntries(result), [2])
            XCTAssertEqual(try payload(result), try payload(source))
            let sourceTiming = try timingEntries(source)
            let resultTiming = try timingEntries(result)
            XCTAssertEqual(resultTiming.count, sourceTiming.count)
            for (actual, expected) in zip(resultTiming, sourceTiming) {
                assertTime(actual.duration, expected.duration)
                assertTime(actual.presentationTimeStamp, expected.presentationTimeStamp)
                assertTime(actual.decodeTimeStamp, expected.decodeTimeStamp)
            }
            assertTime(CMSampleBufferGetOutputPresentationTimeStamp(result), outputPTS)
            assertTime(CMSampleBufferGetOutputDecodeTimeStamp(result),
                       CMSampleBufferGetOutputDecodeTimeStamp(source))
            assertTime(CMSampleBufferGetOutputDuration(result), CMSampleBufferGetOutputDuration(source))
            for mode in [kCMAttachmentMode_ShouldPropagate, kCMAttachmentMode_ShouldNotPropagate] {
                let actual = CMCopyDictionaryOfAttachments(allocator: kCFAllocatorDefault,
                                                          target: result, attachmentMode: mode)
                let expected = CMCopyDictionaryOfAttachments(allocator: kCFAllocatorDefault,
                                                            target: source, attachmentMode: mode)
                XCTAssertTrue(CFEqual(actual, expected))
            }
            XCTAssertTrue(CFEqual(CMSampleBufferGetSampleAttachmentsArray(result, createIfNecessary: false),
                                 CMSampleBufferGetSampleAttachmentsArray(source, createIfNecessary: false)))
            var originalIdentity = SampleStreamAccumulatorV4()
            var compactedIdentity = SampleStreamAccumulatorV4()
            try originalIdentity.append(source)
            try compactedIdentity.append(result)
            XCTAssertEqual(originalIdentity.digest, compactedIdentity.digest)
            XCTAssertTrue(try UniformPCMSampleBufferV4.compactingSizes(in: result) === result)
        }
    }

    func testUnchangedBuffersRetainReadinessControlAndUnsupportedRepresentations() throws {
        let empty = try sample(count: 0)
        let single = try sample(count: 1)
        let compact = try sample(count: 32, explicitSizes: false)
        let notReady = try sample(count: 32, ready: false)
        let variable = try sample(count: 3, sizes: [2, 4, 2])
        let balancedVariable = try sample(count: 3, sizes: [1, 3, 2])
        let compressed = try sample(count: 32, formatID: kAudioFormatULaw)
        let invalid = try sample(count: 32)
        XCTAssertEqual(CMSampleBufferInvalidate(invalid), noErr)
        for source in [empty, single, compact, notReady, variable, balancedVariable, compressed, invalid] {
            XCTAssertTrue(try UniformPCMSampleBufferV4.compactingSizes(in: source) === source)
        }
        XCTAssertFalse(CMSampleBufferDataIsReady(notReady))
        XCTAssertNil(CMSampleBufferGetSampleAttachmentsArray(compact, createIfNecessary: false))
    }

    func testStereo24BitAndFloat32RetainNumericDTSClocksAndOutputTiming() throws {
        let formats = [
            AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
                mBytesPerPacket: 6, mFramesPerPacket: 1, mBytesPerFrame: 6,
                mChannelsPerFrame: 2, mBitsPerChannel: 24, mReserved: 0),
            AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
                mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        ]
        for format in formats {
            for separateTimings in [false, true] {
                let flags: CMTimeFlags = separateTimings ? [.valid, .hasBeenRounded] : .valid
                let timings = (0..<(separateTimings ? 8 : 1)).map { index in
                    CMSampleTimingInfo(
                        duration: CMTime(value: 1_001, timescale: 48_048_000, flags: flags, epoch: 0),
                        presentationTimeStamp: CMTime(value: 17 + Int64(index), timescale: 48_000,
                                                      flags: flags, epoch: 4),
                        decodeTimeStamp: CMTime(value: 15 + Int64(index), timescale: 48_000,
                                               flags: flags, epoch: 4)
                    )
                }
                let source = try sample(count: 8, customStream: format, customTimings: timings)
                for (key, value) in [
                    (kCMSampleBufferAttachmentKey_TrimDurationAtStart, CMTime(value: 1, timescale: 48_000)),
                    (kCMSampleBufferAttachmentKey_TrimDurationAtEnd, CMTime(value: 2, timescale: 48_000))
                ] {
                    CMSetAttachment(source, key: key,
                        value: CMTimeCopyAsDictionary(value, allocator: kCFAllocatorDefault),
                        attachmentMode: kCMAttachmentMode_ShouldPropagate)
                }
                CMSetAttachment(source, key: kCMSampleBufferAttachmentKey_SpeedMultiplier,
                                value: NSNumber(value: 2),
                                attachmentMode: kCMAttachmentMode_ShouldPropagate)
                let shifted = CMTime(value: 39, timescale: 96_000, flags: flags, epoch: 4)
                XCTAssertEqual(CMSampleBufferSetOutputPresentationTimeStamp(source, newValue: shifted), noErr)
                let result = try UniformPCMSampleBufferV4.compactingSizes(in: source)
                XCTAssertFalse(source === result)
                XCTAssertEqual(try sizeEntries(result), [Int(format.mBytesPerFrame)])
                XCTAssertEqual(try payload(result), try payload(source))
                XCTAssertTrue(CMSampleBufferGetFormatDescription(result) === CMSampleBufferGetFormatDescription(source))
                let actualTimings = try timingEntries(result)
                XCTAssertEqual(actualTimings.count, timings.count)
                for (actual, expected) in zip(actualTimings, timings) {
                    assertTime(actual.duration, expected.duration)
                    assertTime(actual.presentationTimeStamp, expected.presentationTimeStamp)
                    assertTime(actual.decodeTimeStamp, expected.decodeTimeStamp)
                }
                assertTime(CMSampleBufferGetOutputPresentationTimeStamp(result),
                           CMSampleBufferGetOutputPresentationTimeStamp(source))
                assertTime(CMSampleBufferGetOutputDecodeTimeStamp(result),
                           CMSampleBufferGetOutputDecodeTimeStamp(source))
                assertTime(CMSampleBufferGetOutputDuration(result), CMSampleBufferGetOutputDuration(source))
                var original = SampleStreamAccumulatorV4()
                var compacted = SampleStreamAccumulatorV4()
                try original.append(source)
                try compacted.append(result)
                XCTAssertEqual(compacted.digest, original.digest)
            }
        }
    }

    func testPassthroughMOVUsesConstantSizeTableAndPreservesAllPCM() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("uniform-pcm-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let frameCount = 12_000
        var expected = Data()
        for compact in [false, true] {
            let url = directory.appendingPathComponent(compact ? "compact.mov" : "explicit.mov")
            let first = try sample(count: 1_024)
            let format = try XCTUnwrap(CMSampleBufferGetFormatDescription(first))
            let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: format)
            writer.add(input)
            XCTAssertTrue(writer.startWriting())
            writer.startSession(atSourceTime: .zero)
            var ordinal = 0
            while ordinal < frameCount {
                let buffer = try sample(count: min(1_024, frameCount - ordinal), start: ordinal)
                if !compact { expected.append(try payload(buffer)) }
                let written = compact ? try UniformPCMSampleBufferV4.compactingSizes(in: buffer) : buffer
                while !input.isReadyForMoreMediaData {
                    guard writer.status == .writing else { throw try XCTUnwrap(writer.error) }
                    await Task.yield()
                }
                XCTAssertTrue(input.append(written), String(describing: writer.error))
                ordinal += CMSampleBufferGetNumSamples(buffer)
            }
            input.markAsFinished()
            writer.endSession(atSourceTime: CMTime(value: Int64(frameCount), timescale: 48_000))
            await writer.finishWriting()
            XCTAssertEqual(writer.status, .completed, String(describing: writer.error))
            let table = try pcmSizeTable(Data(contentsOf: url))
            XCTAssertEqual(table.sampleCount, frameCount)
            XCTAssertEqual(table.sampleSize, compact ? 2 : 0)
            XCTAssertEqual(table.bytes, compact ? 20 : frameCount * 4 + 20)
            let asset = AVURLAsset(url: url)
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            let track = try XCTUnwrap(tracks.first)
            let reader = try AVAssetReader(asset: asset)
            reader.timeRange = try await track.load(.timeRange)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            reader.add(output)
            XCTAssertTrue(reader.startReading())
            var actual = Data()
            var frames = 0
            while let buffer = output.copyNextSampleBuffer() {
                let count = CMSampleBufferGetNumSamples(buffer)
                guard count > 0 else { continue }
                actual.append(try payload(buffer))
                frames += count
            }
            XCTAssertEqual(reader.status, .completed, String(describing: reader.error))
            XCTAssertEqual(frames, frameCount)
            XCTAssertEqual(actual, expected)
        }
    }

    private func sample(count: Int, start: Int = 0, explicitSizes: Bool = true,
                        separateTimings: Bool = false, ready: Bool = true,
                        sizes: [Int]? = nil, formatID: AudioFormatID = kAudioFormatLinearPCM,
                        customStream: AudioStreamBasicDescription? = nil,
                        customTimings: [CMSampleTimingInfo]? = nil)
        throws -> CMSampleBuffer {
        var stream = customStream ?? AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: formatID,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2,
            mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0
        )
        var format: CMAudioFormatDescription?
        XCTAssertEqual(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault,
            asbd: &stream, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
            extensions: nil, formatDescriptionOut: &format), noErr)
        let frameSize = Int(stream.mBytesPerFrame)
        let sizeEntries = sizes ?? (count == 0 ? [] : [Int](repeating: frameSize,
                                                          count: explicitSizes ? count : 1))
        let length = sizes?.reduce(0, +) ?? count * frameSize
        var block: CMBlockBuffer?
        if length > 0 {
            XCTAssertEqual(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault,
                memoryBlock: nil, blockLength: length, blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil, offsetToData: 0, dataLength: length, flags: 0,
                blockBufferOut: &block), noErr)
            let data = (0..<length).map { UInt8(truncatingIfNeeded: $0 + start * frameSize) }
            XCTAssertEqual(data.withUnsafeBytes {
                CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block!,
                                               offsetIntoDestination: 0, dataLength: length)
            }, noErr)
        }
        let timingCount = customTimings?.count ?? (count == 0 ? 0 : (separateTimings ? count : 1))
        let timings = customTimings ?? (0..<timingCount).map { index in
            CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000),
                presentationTimeStamp: CMTime(value: Int64(start + index), timescale: 48_000),
                decodeTimeStamp: .invalid)
        }
        var result: CMSampleBuffer?
        let status = timings.withUnsafeBufferPointer { timingPointer in
            sizeEntries.withUnsafeBufferPointer { sizePointer in
                CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: block,
                    dataReady: ready, makeDataReadyCallback: nil, refcon: nil,
                    formatDescription: format, sampleCount: count,
                    sampleTimingEntryCount: timingCount, sampleTimingArray: timingPointer.baseAddress,
                    sampleSizeEntryCount: sizeEntries.count, sampleSizeArray: sizePointer.baseAddress,
                    sampleBufferOut: &result)
            }
        }
        XCTAssertEqual(status, noErr)
        return try XCTUnwrap(result)
    }

    private func sizeEntries(_ sample: CMSampleBuffer) throws -> [Int] {
        var count = 0
        XCTAssertEqual(CMSampleBufferGetSampleSizeArray(sample, entryCount: 0,
            arrayToFill: nil, entriesNeededOut: &count), noErr)
        var entries = [Int](repeating: 0, count: count)
        XCTAssertEqual(CMSampleBufferGetSampleSizeArray(sample, entryCount: count,
            arrayToFill: &entries, entriesNeededOut: nil), noErr)
        return entries
    }

    private func timingEntries(_ sample: CMSampleBuffer) throws -> [CMSampleTimingInfo] {
        var count = 0
        XCTAssertEqual(CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: 0,
            arrayToFill: nil, entriesNeededOut: &count), noErr)
        var entries = [CMSampleTimingInfo](repeating: .invalid, count: count)
        XCTAssertEqual(CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: count,
            arrayToFill: &entries, entriesNeededOut: nil), noErr)
        return entries
    }

    private func assertTime(_ actual: CMTime, _ expected: CMTime,
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.value, expected.value, file: file, line: line)
        XCTAssertEqual(actual.timescale, expected.timescale, file: file, line: line)
        XCTAssertEqual(actual.flags, expected.flags, file: file, line: line)
        XCTAssertEqual(actual.epoch, expected.epoch, file: file, line: line)
    }

    private func payload(_ sample: CMSampleBuffer) throws -> Data {
        let block = try XCTUnwrap(CMSampleBufferGetDataBuffer(sample))
        let length = CMBlockBufferGetDataLength(block)
        var data = Data(count: length)
        XCTAssertEqual(data.withUnsafeMutableBytes {
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length,
                                      destination: $0.baseAddress!)
        }, noErr)
        return data
    }

    private func pcmSizeTable(_ data: Data) throws -> (bytes: Int, sampleSize: Int, sampleCount: Int) {
        func word(_ offset: Int) -> Int {
            data[offset..<(offset + 4)].reduce(0) { ($0 << 8) | Int($1) }
        }
        func descend(_ range: Range<Int>, path: ArraySlice<String>) throws -> Range<Int> {
            let type = try XCTUnwrap(path.first)
            var offset = range.lowerBound
            while offset + 8 <= range.upperBound {
                let size = word(offset)
                guard size >= 8, size <= range.upperBound - offset else {
                    throw NSError(domain: "UniformPCMTest", code: 1)
                }
                let actualType = String(decoding: data[(offset + 4)..<(offset + 8)], as: UTF8.self)
                if actualType == type {
                    let box = offset..<(offset + size)
                    return path.count == 1 ? box
                        : try descend((offset + 8)..<(offset + size), path: path.dropFirst())
                }
                offset += size
            }
            throw NSError(domain: "UniformPCMTest", code: 2)
        }
        let box = try descend(data.startIndex..<data.endIndex,
                              path: ["moov", "trak", "mdia", "minf", "stbl", "stsz"][...])
        XCTAssertGreaterThanOrEqual(box.count, 20)
        return (box.count, word(box.lowerBound + 12), word(box.lowerBound + 16))
    }
}
