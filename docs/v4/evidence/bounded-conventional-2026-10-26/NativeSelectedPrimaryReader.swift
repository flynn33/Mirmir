import AVFoundation
import CoreMedia
import CoreVideo
import CryptoKit
import Foundation

@main enum AllSelectedPrimaryNativePresentationReader {
    static let fixture = URL(fileURLWithPath: "/Volumes/DockCase/GitHub/Mirmir/MirmirTests/Fixtures/ConventionalWholeAssetV4/disabled-first-bframes.mov")
    static let scratch = URL(fileURLWithPath: "/private/tmp/mirmir-primary-edit-reader-20261026", isDirectory: true)
    static let evidence = URL(fileURLWithPath: "/Volumes/DockCase/GitHub/Mirmir/output/resumed-qa-2026-10-25/conventional-preservation-bounded-01/sealed-native-selected-primary", isDirectory: true)
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func time(_ t: CMTime) -> [String: Any] {
        var result: [String: Any] = ["value": t.value, "timescale": t.timescale, "flags": t.flags.rawValue, "epoch": t.epoch, "isNumeric": t.isNumeric]
        if t.isNumeric { result["seconds"] = CMTimeGetSeconds(t) }
        return result
    }
    static func range(_ r: CMTimeRange) -> [String: Any] { ["start": time(r.start), "duration": time(r.duration)] }
    static func fraction(_ t: CMTime, _ numerator: Int64, _ denominator: Int32) -> CMTime {
        precondition(t.isNumeric && t.epoch == 0 && !t.flags.contains(.hasBeenRounded))
        return CMTime(value: t.value * numerator, timescale: t.timescale * denominator)
    }
    static func failure(_ message: String) -> NSError { NSError(domain: "PrimaryEditDecodedReader", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    static func graph(_ asset: AVAsset) async throws -> [[String: Any]] {
        var rows: [[String: Any]] = []
        for (index, track) in try await asset.load(.tracks).enumerated() {
            var row: [String: Any] = ["index": index, "trackID": track.trackID, "kind": track.mediaType.rawValue,
                "enabled": try await track.load(.isEnabled), "timeRange": range(try await track.load(.timeRange))]
            if track.mediaType == .video {
                row["nominalFrameRate"] = try await track.load(.nominalFrameRate)
                row["minFrameDuration"] = time(try await track.load(.minFrameDuration))
                row["naturalTimeScale"] = try await track.load(.naturalTimeScale)
                row["naturalSize"] = String(describing: try await track.load(.naturalSize))
                row["formatSubtypes"] = try await track.load(.formatDescriptions).map { CMFormatDescriptionGetMediaSubType($0) }
            }
            row["segments"] = try await track.load(.segments).map {
                ["empty": $0.isEmpty, "source": range($0.timeMapping.source), "target": range($0.timeMapping.target)] as [String: Any]
            }
            rows.append(row)
            guard rows.count <= 256 else { throw failure("bounded reader row limit exceeded") }
        }
        return rows
    }
    static func raster(_ pixelBuffer: CVPixelBuffer, path: URL) throws -> [String: Any] {
        let lock = CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        guard lock == kCVReturnSuccess else { throw failure("pixel lock failed: \(lock)") }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        guard pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange else { throw failure("unexpected pixel format \(pixelFormat)") }
        let planeCount = CVPixelBufferGetPlaneCount(pixelBuffer)
        guard planeCount == 2 else { throw failure("unexpected NV12 plane count") }
        var all = Data(), planes: [[String: Any]] = []
        for plane in 0..<planeCount {
            let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, plane)
            let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, plane)
            let stride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, plane)
            let rowBytes = width * (plane == 0 ? 1 : 2)
            guard let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, plane), rowBytes <= stride else { throw failure("invalid NV12 plane") }
            var bytes = Data()
            for y in 0..<height { bytes.append(base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self), count: rowBytes) }
            planes.append(["plane": plane, "width": width, "height": height, "stride": stride,
                "canonicalRowBytes": rowBytes, "canonicalBytes": bytes.count, "sha256": digest(bytes)])
            all.append(bytes)
        }
        try all.write(to: path, options: .atomic)
        return ["width": CVPixelBufferGetWidth(pixelBuffer), "height": CVPixelBufferGetHeight(pixelBuffer),
            "pixelFormat": pixelFormat, "pixelFormatName": "420v NV12 video range", "planes": planes,
            "canonicalBytes": all.count, "sha256": digest(all), "file": path.path,
            "storage": "active rows only; plane 0 Y then plane 1 interleaved CbCr; excludes row padding"]
    }
    static func read(_ asset: AVAsset, _ track: AVAssetTrack, label: String, restricted: Bool) async throws -> [String: Any] {
        let directory = evidence.appendingPathComponent("rasters/\(label)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let reader = try AVAssetReader(asset: asset)
        let selectedRange = try await track.load(.timeRange)
        if restricted { reader.timeRange = selectedRange }
        let output = AVAssetReaderTrackOutput(track: track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
        output.alwaysCopiesSampleData = true
        guard reader.canAdd(output) else { throw failure("reader rejects \(label)") }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? failure("start failed") }
        var rows: [[String: Any]] = [], real = 0, controls = 0, samples = 0
        var firstPTS: CMTime?, lastPTS: CMTime?, strictlyIncreasing = true
        while let sample = output.copyNextSampleBuffer() {
            let count = CMSampleBufferGetNumSamples(sample)
            let image = CMSampleBufferGetImageBuffer(sample)
            var row: [String: Any] = ["ordinal": rows.count, "numSamples": count,
                "totalSampleSize": CMSampleBufferGetTotalSampleSize(sample), "hasImageBuffer": image != nil,
                "pts": time(CMSampleBufferGetPresentationTimeStamp(sample)),
                "dts": time(CMSampleBufferGetDecodeTimeStamp(sample)), "duration": time(CMSampleBufferGetDuration(sample)),
                "outputPTS": time(CMSampleBufferGetOutputPresentationTimeStamp(sample)),
                "outputDTS": time(CMSampleBufferGetOutputDecodeTimeStamp(sample)),
                "outputDuration": time(CMSampleBufferGetOutputDuration(sample))]
            var needed = 0
            let queryStatus = CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: 0, arrayToFill: nil, entriesNeededOut: &needed)
            var entries = [CMSampleTimingInfo](repeating: .invalid, count: needed)
            let arrayStatus: OSStatus = needed > 0 ? entries.withUnsafeMutableBufferPointer {
                CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: needed, arrayToFill: $0.baseAddress, entriesNeededOut: nil)
            } : queryStatus
            row["sampleTimingQueryStatus"] = queryStatus
            row["sampleTimingArrayStatus"] = arrayStatus
            row["sampleTimingEntries"] = entries.map { ["pts": time($0.presentationTimeStamp), "dts": time($0.decodeTimeStamp), "duration": time($0.duration)] }
            let sampleAttachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
            row["sampleAttachmentsExposed"] = sampleAttachments != nil
            row["sampleAttachments"] = sampleAttachments?.map { dictionary in
                Dictionary(uniqueKeysWithValues: dictionary.map { (String(describing: $0.key), String(describing: $0.value)) })
            } ?? []
            row["doNotDisplayBySample"] = sampleAttachments?.map { dictionary in
                ["present": dictionary[kCMSampleAttachmentKey_DoNotDisplay] != nil,
                 "value": (dictionary[kCMSampleAttachmentKey_DoNotDisplay] as? Bool) ?? false]
            } ?? []
            var trims: [String: Any] = [:]
            for (name, key) in [("trimDurationAtStart", kCMSampleBufferAttachmentKey_TrimDurationAtStart),
                                ("trimDurationAtEnd", kCMSampleBufferAttachmentKey_TrimDurationAtEnd)] {
                var mode = kCMAttachmentMode_ShouldNotPropagate
                if let value = CMGetAttachment(sample, key: key, attachmentModeOut: &mode) {
                    var record: [String: Any] = ["present": true, "mode": mode, "description": String(describing: value)]
                    if CFGetTypeID(value) == CFDictionaryGetTypeID() { record["time"] = time(CMTimeMakeFromDictionary(value as! CFDictionary)) }
                    trims[name] = record
                } else { trims[name] = ["present": false] }
            }
            row["trimAttachments"] = trims
            for (name, mode) in [("propagatingBufferAttachments", kCMAttachmentMode_ShouldPropagate),
                                 ("nonpropagatingBufferAttachments", kCMAttachmentMode_ShouldNotPropagate)] {
                if let values = CMCopyDictionaryOfAttachments(allocator: kCFAllocatorDefault, target: sample, attachmentMode: mode) {
                    row[name] = String(describing: values)
                }
            }
            if let attachments = CMGetAttachment(sample, key: kCMSampleBufferAttachmentKey_EmptyMedia, attachmentModeOut: nil) { row["emptyMediaAttachment"] = String(describing: attachments) }
            if image != nil, count > 0 {
                row["kind"] = "real"
                row["rasterNotCollected"] = true
                let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                if let previous = lastPTS, CMTimeCompare(pts, previous) <= 0 { strictlyIncreasing = false }
                if firstPTS == nil { firstPTS = pts }
                lastPTS = pts
                real += 1; samples += count
            } else {
                row["kind"] = "control"
                controls += 1
            }
            rows.append(row)
            guard rows.count <= 256 else { throw failure("bounded reader row limit exceeded") }
        }
        var result: [String: Any] = ["label": label, "readerStatus": reader.status.rawValue,
            "completed": reader.status == .completed, "bufferCount": rows.count, "realBufferCount": real,
            "controlBufferCount": controls, "realSampleCount": samples, "strictlyIncreasingRealSamplePTS": strictlyIncreasing,
            "restrictedToSelectedTrackTimeRange": restricted, "selectedTrackTimeRange": range(selectedRange),
            "configuredReaderTimeRange": range(reader.timeRange), "buffers": rows]
        if let firstPTS { result["firstRealSamplePTS"] = time(firstPTS) }
        if let lastPTS { result["lastRealSamplePTS"] = time(lastPTS) }
        if let error = reader.error { result["readerError"] = String(describing: error) }
        return result
    }
    static func times(_ report: [String: Any], key: String) throws -> [CMTime] {
        let rows = (report["buffers"] as? [[String: Any]] ?? []).filter { $0["kind"] as? String == "real" }
        return try rows.map { row in
            guard let stamp = row[key] as? [String: Any], stamp["isNumeric"] as? Bool == true,
                  let value = stamp["value"] as? NSNumber, let scale = stamp["timescale"] as? NSNumber,
                  let epoch = stamp["epoch"] as? NSNumber, let flags = stamp["flags"] as? NSNumber else {
                throw failure("invalid real presentation timestamp")
            }
            return CMTime(value: value.int64Value, timescale: scale.int32Value,
                          flags: CMTimeFlags(rawValue: flags.uint32Value), epoch: epoch.int64Value)
        }
    }
    static func sameTimes(_ source: [CMTime], _ output: [CMTime]) -> Bool {
        source.count == output.count && zip(source, output).allSatisfy { CMTimeCompare($0, $1) == 0 }
    }
    static func main() async throws {
        let declarations: [(String, String, String, String)] = [
            ("ConventionalWholeAssetPreservationTests/testSelectedMovingPrimaryDiscontinuousEditPreservesFullMedia()", "selected-moving-discontinuous-audio-false", "/Volumes/DockCase/GitHub/Mirmir/output/resumed-qa-2026-10-25/conventional-preservation-bounded-01/sealed-media-attachments/17583C22-DA33-4F79-82F1-2910D1672055.mov", "/Volumes/DockCase/GitHub/Mirmir/output/resumed-qa-2026-10-25/conventional-preservation-bounded-01/sealed-media-attachments/32F26001-A399-42CA-B703-03E4B8F5000D.mov"),
            ("ConventionalWholeAssetPreservationTests/testSelectedMovingPrimaryDiscontinuousEditPreservesFullMedia()", "selected-moving-discontinuous-audio-true", "/Volumes/DockCase/GitHub/Mirmir/output/resumed-qa-2026-10-25/conventional-preservation-bounded-01/sealed-media-attachments/5DCF1269-EBC1-4B9B-AF50-DFD433D58F4C.mov", "/Volumes/DockCase/GitHub/Mirmir/output/resumed-qa-2026-10-25/conventional-preservation-bounded-01/sealed-media-attachments/0F2C1F78-C954-482B-89D4-C3F98A0E80FD.mov"),
            ("ConventionalWholeAssetPreservationTests/testSelectedMovingPrimaryInternalEditPreservesFullMedia()", "selected-moving-internal-audio-false", "/Volumes/DockCase/GitHub/Mirmir/output/resumed-qa-2026-10-25/conventional-preservation-bounded-01/sealed-media-attachments/1579E5FA-8BE3-432D-A76E-731141EDC54E.mov", "/Volumes/DockCase/GitHub/Mirmir/output/resumed-qa-2026-10-25/conventional-preservation-bounded-01/sealed-media-attachments/6C00C7F9-2BB0-4A9E-840C-EFE18A86A8F0.mov"),
            ("ConventionalWholeAssetPreservationTests/testSelectedMovingPrimaryInternalEditPreservesFullMedia()", "selected-moving-internal-audio-true", "/Volumes/DockCase/GitHub/Mirmir/output/resumed-qa-2026-10-25/conventional-preservation-bounded-01/sealed-media-attachments/FE7CE779-9543-40F7-A274-CE758FCD4FB9.mov", "/Volumes/DockCase/GitHub/Mirmir/output/resumed-qa-2026-10-25/conventional-preservation-bounded-01/sealed-media-attachments/8522CD7B-7A3F-44BF-8AFA-0912CCE3B7C3.mov"),
            ("ConventionalWholeAssetPreservationTests/testSelectedMovingPrimaryInternalEditPreservesWholeAsset()", "selected-moving-internal-audio-false", "/Volumes/DockCase/GitHub/Mirmir/output/resumed-qa-2026-10-25/conventional-preservation-bounded-01/sealed-media-attachments/620E3E00-7303-4B3F-96E1-EC1F7C00E5BC.mov", "/Volumes/DockCase/GitHub/Mirmir/output/resumed-qa-2026-10-25/conventional-preservation-bounded-01/sealed-media-attachments/BEEB3895-5978-4848-85CE-BB4A65065C34.mov"),
            ("ConventionalWholeAssetPreservationTests/testSelectedMovingPrimaryInternalEditPreservesWholeAsset()", "selected-moving-internal-audio-true", "/Volumes/DockCase/GitHub/Mirmir/output/resumed-qa-2026-10-25/conventional-preservation-bounded-01/sealed-media-attachments/97404373-A20C-4FA2-9D1A-2047F8BBB0AE.mov", "/Volumes/DockCase/GitHub/Mirmir/output/resumed-qa-2026-10-25/conventional-preservation-bounded-01/sealed-media-attachments/06C611B3-930E-4B67-8B8F-3DA76F70D7D8.mov"),
            ("ConventionalWholeAssetPreservationTests/testSelectedMovingPrimaryLeadingEditPreservesFullMedia()", "selected-moving-leading-audio-false", "/Volumes/DockCase/GitHub/Mirmir/output/resumed-qa-2026-10-25/conventional-preservation-bounded-01/sealed-media-attachments/B202F7BB-93EA-4825-B36C-A87D932A4D58.mov", "/Volumes/DockCase/GitHub/Mirmir/output/resumed-qa-2026-10-25/conventional-preservation-bounded-01/sealed-media-attachments/4B6D2B78-2134-4354-A48A-35EFE599C6BF.mov"),
            ("ConventionalWholeAssetPreservationTests/testSelectedMovingPrimaryLeadingEditPreservesFullMedia()", "selected-moving-leading-audio-true", "/Volumes/DockCase/GitHub/Mirmir/output/resumed-qa-2026-10-25/conventional-preservation-bounded-01/sealed-media-attachments/3406032D-3BD4-497F-9E12-A28CB2E716FF.mov", "/Volumes/DockCase/GitHub/Mirmir/output/resumed-qa-2026-10-25/conventional-preservation-bounded-01/sealed-media-attachments/25EB4862-A49F-42B4-B264-A36920D5A64F.mov"),
            ("ConventionalWholeAssetPreservationTests/testSelectedMovingPrimaryRepeatedEditPreservesFullMedia()", "selected-moving-repeated-audio-false", "/Volumes/DockCase/GitHub/Mirmir/output/resumed-qa-2026-10-25/conventional-preservation-bounded-01/sealed-media-attachments/2E5A9E04-94B5-4CB1-90CF-815D71EFA8D2.mov", "/Volumes/DockCase/GitHub/Mirmir/output/resumed-qa-2026-10-25/conventional-preservation-bounded-01/sealed-media-attachments/B4FBF492-CBC7-4C25-918B-FF9A47E1DBAF.mov"),
            ("ConventionalWholeAssetPreservationTests/testSelectedMovingPrimaryRepeatedEditPreservesFullMedia()", "selected-moving-repeated-audio-true", "/Volumes/DockCase/GitHub/Mirmir/output/resumed-qa-2026-10-25/conventional-preservation-bounded-01/sealed-media-attachments/F2820E27-92CE-4D6F-995F-2371D9EB7C00.mov", "/Volumes/DockCase/GitHub/Mirmir/output/resumed-qa-2026-10-25/conventional-preservation-bounded-01/sealed-media-attachments/BE1D62F7-9BC8-4FB8-BDDB-E378B015EE38.mov"),
            ("ConventionalWholeAssetPreservationTests/testSelectedMovingPrimaryScaledEditPreservesFullMedia()", "selected-moving-scaled-audio-false", "/Volumes/DockCase/GitHub/Mirmir/output/resumed-qa-2026-10-25/conventional-preservation-bounded-01/sealed-media-attachments/AB4DEE34-C4F0-435E-9552-74C441C8E53C.mov", "/Volumes/DockCase/GitHub/Mirmir/output/resumed-qa-2026-10-25/conventional-preservation-bounded-01/sealed-media-attachments/4E0C9F21-CCD9-4349-B287-0FB0411E0598.mov"),
            ("ConventionalWholeAssetPreservationTests/testSelectedMovingPrimaryScaledEditPreservesFullMedia()", "selected-moving-scaled-audio-true", "/Volumes/DockCase/GitHub/Mirmir/output/resumed-qa-2026-10-25/conventional-preservation-bounded-01/sealed-media-attachments/10449903-BCAF-49B8-9096-3B308BFC6696.mov", "/Volumes/DockCase/GitHub/Mirmir/output/resumed-qa-2026-10-25/conventional-preservation-bounded-01/sealed-media-attachments/33074998-E60F-4B27-963D-B312FD9256F3.mov"),
            ("ConventionalWholeAssetPreservationTests/testSelectedMovingPrimaryTrailingEditPreservesFullMedia()", "selected-moving-trailing-audio-false", "/Volumes/DockCase/GitHub/Mirmir/output/resumed-qa-2026-10-25/conventional-preservation-bounded-01/sealed-media-attachments/8F7655CD-B37B-4816-BA47-D41903E3C8F5.mov", "/Volumes/DockCase/GitHub/Mirmir/output/resumed-qa-2026-10-25/conventional-preservation-bounded-01/sealed-media-attachments/4C6E7497-4033-4E3F-9800-D4F582858D1D.mov"),
            ("ConventionalWholeAssetPreservationTests/testSelectedMovingPrimaryTrailingEditPreservesFullMedia()", "selected-moving-trailing-audio-true", "/Volumes/DockCase/GitHub/Mirmir/output/resumed-qa-2026-10-25/conventional-preservation-bounded-01/sealed-media-attachments/86C2554B-044B-4E9E-8D44-0AD0A91D059A.mov", "/Volumes/DockCase/GitHub/Mirmir/output/resumed-qa-2026-10-25/conventional-preservation-bounded-01/sealed-media-attachments/BBADA9C9-96C9-470A-BCE5-1B4FE0E1AD70.mov"),
            ("ConventionalWholeAssetPreservationTests/testSelectedMovingPrimaryTrimmedEditPreservesFullMedia()", "selected-moving-trimmed-audio-false", "/Volumes/DockCase/GitHub/Mirmir/output/resumed-qa-2026-10-25/conventional-preservation-bounded-01/sealed-media-attachments/61FE0CA3-E012-4C68-8F86-C07CE15D6085.mov", "/Volumes/DockCase/GitHub/Mirmir/output/resumed-qa-2026-10-25/conventional-preservation-bounded-01/sealed-media-attachments/7EEB026B-1D73-4622-BC1B-B8233761BAA4.mov"),
            ("ConventionalWholeAssetPreservationTests/testSelectedMovingPrimaryTrimmedEditPreservesFullMedia()", "selected-moving-trimmed-audio-true", "/Volumes/DockCase/GitHub/Mirmir/output/resumed-qa-2026-10-25/conventional-preservation-bounded-01/sealed-media-attachments/2C57D916-B279-4113-B622-0D4AFB852DDC.mov", "/Volumes/DockCase/GitHub/Mirmir/output/resumed-qa-2026-10-25/conventional-preservation-bounded-01/sealed-media-attachments/85ABC0C8-941E-49DF-BAD7-1E5CFF9C3C1F.mov"),
        ]
        var rows: [[String: Any]] = []
        for (index, declaration) in declarations.enumerated() {
            let (test, name, sourcePath, outputPath) = declaration
            let sourceURL = URL(fileURLWithPath: sourcePath), outputURL = URL(fileURLWithPath: outputPath)
            let sourceBefore = try Data(contentsOf: sourceURL), outputBefore = try Data(contentsOf: outputURL)
            let source = AVURLAsset(url: sourceURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            let output = AVURLAsset(url: outputURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            let sourceTracks = try await source.load(.tracks), outputTracks = try await output.load(.tracks)
            let sr = try await read(source, sourceTracks[0], label: "pair-\(index)-source", restricted: true)
            let or = try await read(output, outputTracks[0], label: "pair-\(index)-output", restricted: true)
            let sourceTimes = try times(sr, key: "pts"), outputTimes = try times(or, key: "pts")
            let sourceOutputTimes = try times(sr, key: "outputPTS"), outputOutputTimes = try times(or, key: "outputPTS")
            rows.append(["test": test, "case": name, "source": sourcePath, "output": outputPath,
                "sourceSHA256": digest(sourceBefore), "outputSHA256": digest(outputBefore),
                "sourceUnchanged": try Data(contentsOf: sourceURL) == sourceBefore,
                "outputUnchanged": try Data(contentsOf: outputURL) == outputBefore,
                "sourceInventory": try await graph(source), "outputInventory": try await graph(output),
                "sourceRead": sr, "outputRead": or,
                "realBufferCountsMatch": sr["realBufferCount"] as? Int == or["realBufferCount"] as? Int,
                "controlBufferCountsMatch": sr["controlBufferCount"] as? Int == or["controlBufferCount"] as? Int,
                "presentationTimeSequenceNumericMatch": sameTimes(sourceTimes, outputTimes),
                "outputPresentationTimeSequenceNumericMatch": sameTimes(sourceOutputTimes, outputOutputTimes)])
        }
        let report: [String: Any] = ["schema": "all-selected-primary-native-presentation-pairs-v1",
            "pairs": rows.count, "method": "AVURLAsset decoded NV12, selected first video, AVAssetReader.timeRange equals selected track.timeRange; numeric CMTimeCompare compares PTS in original order; no raster acceptance comparison.", "results": rows]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: evidence.appendingPathComponent("report.json"), options: .atomic)
        print("wrote all-native-pairs/report.json")
    }
}
