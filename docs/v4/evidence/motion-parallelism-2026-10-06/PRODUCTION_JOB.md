# Native production 1080p to 4K job — 2026-10-06

The native macOS Release XCTest `WorkflowApplicationQueueV4Tests.testExternalSourceCompletesProductionDurableWorkflowWhenRequested` completed with one test and zero failures in 21.999 seconds. It used the live deterministic Metal catalog and completed a real 1920 × 1080 to 3840 × 2160 H264 job, including two durable segments, final publication, preserved audio, and terminal checkpoint validation. The engine reported 14.198642015457153 seconds of processing time; that value and the XCTest wall time measure different scopes.

[production-job-run.json](production-job-run.json) is the kept XCTest job receipt. [production-job-validation.json](production-job-validation.json) records the independent ffprobe/ffmpeg verification: all 35 checks passed. Only host-specific paths were replaced with relative paths or basenames in these repository copies; other receipt and validation fields remain unchanged. The source, finalized output, original receipts, raw ffprobe inventories, and decoded PCM remain in the local build evidence directory, outside Git.

| Verified property | Source | Final output |
| --- | --- | --- |
| Actual decoded video frames | 66 | 66 |
| Decoded raster | 1920 × 1080 | 3840 × 2160 |
| Video timeline | 1001/24000-second NTSC lattice, 90 kHz media clock | Same ordinal lattice and clock |
| Video track end | 61937/22500 seconds | 61937/22500 seconds |
| Color metadata | BT.709 matrix, transfer and primaries; limited range | Preserved |
| PCM format | 48 kHz mono signed 16-bit | Preserved |
| Decoded PCM count | 132,132 samples / 264,264 bytes | Identical |
| PCM payload SHA-256 | `51841ca58dfc2421a9c92b1c8c46af90e04c9dfb6f7952f609185569a511d871` | Identical |

Both streams start at zero and have strictly increasing video timestamps. Each observed frame timestamp independently equals the integer floor or ceiling of its exact NTSC ordinal on the declared media clock. The raw source/output PTS match exactly for 62 frames; ordinals 14, 18, 22 and 26 differ by −1/90000 second while satisfying those same immediate clock boundaries. The report retains every difference. It does not rewrite observed timestamps or admit a general timing tolerance.

The source and output each contain one video and one audio track. Nil-settings AVAssetReader returns 70 video buffers, including four empty edit/control markers, while the actual encoded sample count and independently decoded frame count are both 66. The receipt records these different quantities separately. PCM packet timestamps and durations are continuous and exact on the 48 kHz sample clock. Source and output PCM bytes hash identically, including the final sample.

The exported input attachment matches the original native source file SHA-256 exactly: `9a73ef499046b32367462d17c0e5b01270400506a94f59babd87d833eede031b`. The finalized output SHA-256 is `2a9d2971af2cfda42c61bab3bdb7245bbf9afbb0cf78e385cb1be6ebf1d04149`. These file hashes identify the retained artifacts; they are not a video-quality comparison because H264 encoding is lossy.

## Repeat the independent verification

[verify-production-job.py](verify-production-job.py) requires Python 3, ffprobe and ffmpeg, plus explicit paths. It checks this 66-frame fixture and preserves its raw inventories, decoded PCM and full report in the requested output directory:

```sh
python3 docs/v4/evidence/motion-parallelism-2026-10-06/verify-production-job.py \
  --source /path/to/source-native-1080p-66-ntsc.mov \
  --output /path/to/finalized-4k-output.mov \
  --evidence-dir /path/to/independent-validation
```

For the original native XCTest, `MIRMIR_REAL_SOURCE_PATH` selected the source, `MIRMIR_REAL_SOURCE_EVIDENCE_DIR` selected a fresh sandbox-writable run directory, and `MIRMIR_REAL_SOURCE_TARGET_WIDTH=3840` / `MIRMIR_REAL_SOURCE_TARGET_HEIGHT=2160` selected 4K. The test used `-destination 'platform=macOS,arch=arm64'` and retained input, output, diagnostics and job JSON as `.keepAlways` XCTest attachments. This is native macOS evidence; it does not establish iOS Simulator or physical-device acceptance.

The verifier also rejected two negative controls: source-as-output fails the required 4K geometry, and a same-clock control with ordinal 2 shifted by two ticks fails NTSC timing. This verifies the retained short production job. It does not measure a full-length movie speedup or establish the original roughly one-hour job's completion. Serial/parallel motion-field identity and CPU/Metal video parity are covered by separate Xcode tests.
