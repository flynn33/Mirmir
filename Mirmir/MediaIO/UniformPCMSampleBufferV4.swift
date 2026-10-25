import AudioToolbox
import CoreMedia
import Foundation

/// Retains PCM frames verbatim while expressing their equal sizes once.
/// AVAssetReader can supply one size entry per frame; passthrough writing then
/// expands those entries into a MOV stsz table even though every size is equal.
enum UniformPCMSampleBufferV4 {
    struct Failure: Error {
        let status: OSStatus
    }

    static func compactingSizes(in source: CMSampleBuffer) throws -> CMSampleBuffer {
        let count = CMSampleBufferGetNumSamples(source)
        guard count > 1, CMSampleBufferIsValid(source),
              CMSampleBufferDataIsReady(source),
              let format = CMSampleBufferGetFormatDescription(source),
              CMFormatDescriptionGetMediaType(format) == kCMMediaType_Audio,
              let stream = CMAudioFormatDescriptionGetStreamBasicDescription(format),
              stream.pointee.mFormatID == kAudioFormatLinearPCM,
              stream.pointee.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0,
              stream.pointee.mBytesPerFrame > 0,
              let block = CMSampleBufferGetDataBuffer(source) else {
            return source
        }
        var sizeCount = 0
        let sizeStatus = CMSampleBufferGetSampleSizeArray(
            source, entryCount: 0, arrayToFill: nil, entriesNeededOut: &sizeCount
        )
        guard sizeStatus == noErr, sizeCount == count else { return source }
        let frameSize = Int(stream.pointee.mBytesPerFrame)
        let total = count.multipliedReportingOverflow(by: frameSize)
        guard !total.overflow,
              total.partialValue == CMBlockBufferGetDataLength(block),
              total.partialValue == CMSampleBufferGetTotalSampleSize(source) else {
            return source
        }
        for index in 0..<count {
            guard CMSampleBufferGetSampleSize(source, at: index) == frameSize else {
                return source
            }
        }
        var timingCount = 0
        let timingStatus = CMSampleBufferGetSampleTimingInfoArray(
            source, entryCount: 0, arrayToFill: nil, entriesNeededOut: &timingCount
        )
        guard timingStatus == noErr,
              timingCount == 1 || timingCount == count else { return source }
        var timings = [CMSampleTimingInfo](repeating: .invalid, count: timingCount)
        try check(CMSampleBufferGetSampleTimingInfoArray(
            source, entryCount: timingCount, arrayToFill: &timings,
            entriesNeededOut: nil
        ))
        var size = frameSize
        var result: CMSampleBuffer?
        try check(timings.withUnsafeBufferPointer { pointer in
            CMSampleBufferCreateReady(
                allocator: kCFAllocatorDefault, dataBuffer: block,
                formatDescription: format, sampleCount: count,
                sampleTimingEntryCount: timingCount,
                sampleTimingArray: pointer.baseAddress,
                sampleSizeEntryCount: 1, sampleSizeArray: &size,
                sampleBufferOut: &result
            )
        })
        guard let result else {
            throw Failure(status: kCMSampleBufferError_AllocationFailed)
        }
        for mode in [kCMAttachmentMode_ShouldPropagate,
                     kCMAttachmentMode_ShouldNotPropagate] {
            if let attachments = CMCopyDictionaryOfAttachments(
                allocator: kCFAllocatorDefault, target: source, attachmentMode: mode
            ) {
                CMSetAttachments(result, attachments: attachments, attachmentMode: mode)
            }
        }
        if let originals = CMSampleBufferGetSampleAttachmentsArray(
            source, createIfNecessary: false
        ) {
            guard CFArrayGetCount(originals) == count,
                  let copies = CMSampleBufferGetSampleAttachmentsArray(
                    result, createIfNecessary: true
                  ), CFArrayGetCount(copies) == count else {
                throw Failure(status: kCMSampleBufferError_RequiredParameterMissing)
            }
            // Core Media documents each element as a mutable dictionary.
            for index in 0..<count {
                let original = unsafeBitCast(
                    CFArrayGetValueAtIndex(originals, index), to: CFDictionary.self
                )
                let copy = unsafeBitCast(
                    CFArrayGetValueAtIndex(copies, index), to: CFMutableDictionary.self
                )
                CFDictionaryApplyFunction(original, { key, value, context in
                    guard let context else { return }
                    let destination = Unmanaged<CFMutableDictionary>
                        .fromOpaque(context).takeUnretainedValue()
                    CFDictionarySetValue(destination, key, value)
                }, Unmanaged.passUnretained(copy).toOpaque())
            }
        }
        try check(CMSampleBufferSetOutputPresentationTimeStamp(
            result, newValue: CMSampleBufferGetOutputPresentationTimeStamp(source)
        ))
        return result
    }

    private static func check(_ status: OSStatus) throws {
        guard status == noErr else { throw Failure(status: status) }
    }
}
