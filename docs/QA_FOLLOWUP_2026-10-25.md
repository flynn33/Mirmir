# Non-UI QA continuation — October 25, 2026

Candidate: **1.7.2 (20)**. **Release remains blocked; the all-features goal is
active.** This supplements [the prior QA report](FINAL_QA_2026-10-24.md).
The earlier local checkpoint is `052c95ea682d92efe260ba4e2e9e59868f9410c3`;
the source identities below bind the subsequent native repairs.
The completed runtime7 snapshot includes the PCM and minimum-OS HDR repairs.
The frozen runtime8 native baseline includes newer metadata, H.264 verification
and receipt repairs and has completed combined qualification below. Additional
targeted chroma and broad-format findings remain under repair. No push, upload
or release occurred. Visual UI acceptance is excluded by the owner's instruction.

## Findings and repair status

| Finding | Verified mechanism | Repair and verification |
| --- | --- | --- |
| Feature-length PCM creates an oversized MOV header | Runtime6 writes 259,200,000 identical explicit size entries, expanding `stsz` to 1,036,800,020 bytes. FFmpeg rejects the header with default allocation limits. Writer controls isolate the explicit per-frame size representation. | `UniformPCMSampleBufferV4` expresses the same sizes once, preserving payload, format, timings and attachments. The fresh runtime7 90-minute production workflow and complete independent picture/audio decode pass. Its `stsz` is 20 bytes. Five focused regressions, adjacent checks and complete runtime7 suites pass. |
| The source-audio test falsely reports missing frames | AVI global duration is 5399.9136 seconds, while its audio track ends at 5400. The default reader truncates the source inventory. | Select the exact audio track range. A permanent shortened-header regression detects the original reader truncation. This oracle repair is separate from the real MOV-header defect. |
| macOS 15.4 encodes incorrect HDR ambient metadata | PQ loses requested ambient metadata; HLG invents/replaces it. Cross-reading, physical `amve`, HEVC configuration and sample SEI checks isolate incorrect output bytes. Thirty-six setting controls do not retain the requested values. | Disable automatic insertion and correct only the format header. Encoded samples, decoded P010 pixels, timings and other metadata remain checked. Focused 43/43 tests pass on host and guest. Complete runtime7 Release, Debug, Rosetta and macOS 15.4 non-UI suites pass. Audio-first/two-HDR-track, cancellation and idempotence controls also pass. |
| Native iTunes freeform metadata exports fail | MOV/MP4/M4V controls lose `iTunSMPB`, then reject with `assetMetadataMismatch` (NSError 14). On macOS 15.4 the writer also loses a custom UserNote. Canonical metadata comparisons isolate each missing item. | Exact raw freeform restoration and bounded AAC translation pass 24 focused checks on the host and macOS 15.4, with zero failures/skips; the complete runtime8 suites also pass. AAC transcode requires newly derived gapless values: blindly copying the source values changes independently decoded audio. Typed execution 4.4 and queue 2 receipts bind the actual packets, edits, metadata and immutable plan; unchanged routes retain execution 4.3/queue 1. This does not establish the cause of customer error 11. |
| Native H.264 MP4/M4V passthrough fails stream verification | Five real source/writer pairs retain every encoded payload and sample clock; only verified ISO/QuickTime sample-description wrappers differ. | Normalize only the sample-stream descriptor's verified wrapper fields. Durable graph fingerprints remain unchanged; unknown/malformed/different fields remain bound. Seven regression tests pass on arm64 and Rosetta, and the focused host/minimum-OS migration checks pass. The complete runtime8 suites also pass. |
| Runtime rebuild checks current App bytes against a historical capture lock | The added strict packaged-receipt check changes `MirmirApp.swift`, while the historical natural-quality capture identity still requires its original bytes. The old generator rejects before building. | Resolve only the original immutable capture revision, verify its exact existing size/hash and regular Git blob mode, and retain current App bytes in the production source manifest. Four self-contained regressions pass; actual generator payloads remain byte-identical. Final source rebinding and complete runtime8 tests pass. Standalone no-history source with a changed App still fails closed. |
| Qualification contract omits a required lock | The aggregate evaluator requires a source-manifest hash missing from the checked-in contract. Synthetic fixtures supplied it and hid the omission. The source count was also stale. | Eager validation and three permanent regressions check the actual closed inventory. Eight affected Python modules pass 202 tests at runtime7. Runtime8 refreshes the final current-source bindings and passes all 404 Python checks. Historical identities and thresholds remain locked. |
| Broad-format production integration remains incomplete | The committed fourteen-input/two-backend gate passes 16/28 workflows. A private importer completes seven additional input types on CPU and Metal plus audio omission (15 workflows), with independent video, timing, audio and player checks. | The private result is not packaged product support. Dependency embedding/provenance, broader formats and current-source integration remain unfinished. A boundary audit exposed planar RGB being interpreted as YUV. Correct RGB8 conversion now has private independent-oracle and workflow evidence; depth/alpha/odd delivery and coherent root integration remain unfinished. |

## Completed runtime7 qualification

The frozen source snapshot is `/private/tmp/Mirmir-combined-qa-source-20261025`.
Its manifest is retained under `output/resumed-qa-2026-10-25/combined-runtime7/`.
Two builds after installing the final trust pins reproduce all 13 bundle files
and all three provenance files byte-for-byte. The 12 runtime payloads are
unchanged; the source-bound manifest is new. The production loader, tamper
rejection, canonical self-test and 304 historical repository references pass.

- Runtime identity: `6575fdee98d2a6677472588bb33142d02dbf7663586effb7cc167a85c26c4230`.
- Normalized source identity: `b5c66a77dcc4592fac556e9543d1957b6477c3cdb6945680b19f4a88d2e9efbc`.
- Raw source-manifest SHA-256: `a12953e103f2449718dc2ada93246f945e88bab8361601fac0deaed40b6239eb` (404 production sources).

| Complete non-UI selection | Passed | Failed | Opt-in skips | Total |
| --- | ---: | ---: | ---: | ---: |
| Native Release | 720 | 0 | 13 | 733 |
| Native Debug | 725 | 0 | 13 | 738 |
| x86_64 Release under Rosetta | 720 | 0 | 13 | 733 |
| macOS 15.4 (24E248), headless Apple Silicon VM | 720 | 0 | 13 | 733 |

Xcode enumeration is compared with the explicit selected test set before each
host run. The two UI tests are absent from execution logs. All 59 Swift
Testing diagnostics/activity tests are included. The same signed app/test
binary and all 2379 source snapshot files are hash-verified in the guest.
Rosetta evidence includes the x86_64-only executable/test binary and sampled
Rosetta JIT/runtime frames. A first header-label heuristic failed and is retained
alongside the corrected evidence analysis; physical Intel is still unverified.

The earlier runtime6 macOS 15.4 result (710 pass, 13 skip, two HDR failures)
remains retained as before-repair evidence. Earlier missing-source transfer and
zero-Swift-test selection attempts are harness failures, not passing coverage.
Runtime7 supersedes those failures for its exact snapshot, not for later edits.

The original error-11 writer-admission probe was also executed on macOS 15.4:
all 60 H.264/HEVC/ProRes 422 configuration controls match the host and pass both
`canApply` and `canAdd`. This does not reproduce the reported incident or
establish its cause. Evidence: `error11-minimum-os-writer/summary.json` under the
October 25 output folder.

## Frozen runtime8 native baseline — complete suites

The new source-bound runtime reproduces all 13 bundle files and three provenance
files across two post-pin builds. Identity:
`33ef468066be2aac90a48aec6a8f9a41656d58a0c294c47a4bc2b5822e8d82c2`;
normalized source:
`3b48a4c3f60526cbbb6ba66b4ab2238ffd8b77679eda4673acb09ffb35143dfb`;
raw source-manifest SHA-256:
`18f22004725fbc549990554e013778568e4e5ba0515301ba2e1b269e28817e81`
(406 production sources).

The first combined runs passed 741 Release, 746 Debug and 741 Rosetta tests,
with 13 skips and **four failures each**. All four failures occurred during the
new historical-Git test fixture setup: `xcrun` refuses execution inside the App
Sandbox. Passing the actual developer Git executable fixes all four in the same
signed sandboxed host, retaining every negative assertion. The final runtime
above includes that repair. Evidence:
`combined-runtime8/locked-input-apphost-followup/` under the October 25 output.

| Complete non-UI selection | Passed | Failed | Opt-in skips | Total |
| --- | ---: | ---: | ---: | ---: |
| Native Release | 745 | 0 | 13 | 758 |
| Native Debug | 750 | 0 | 13 | 763 |
| x86_64 Release under Rosetta | 745 | 0 | 13 | 758 |
| macOS 15.4 (24E248), headless Apple Silicon VM | 745 | 0 | 13 | 758 |

The exact final snapshot contains 2394 verified files. The guest's same signed
app/test binaries and source hashes are checked before execution. All 59 Swift
Testing tests are included and both owner-excluded UI tests are absent.
The 23 v4 Python commands pass 387 tests; version and independent-media-oracle
commands add 9 and 8, respectively: **404 tests across 25 commands**. The
production runtime loader, tamper rejection, canonical self-test and 304
historical references pass. Two post-pin rebuilds reproduce all bundle and
provenance files. Release, Debug and x86_64-only builds have zero compiler
warnings/errors. The local development-signed universal archive passes strict
signature, sandbox, minimum-OS, embedded-runtime and matching dSYM UUID checks.
A local Store export also passes: Apple Distribution app signature, sandbox
entitlements without debugging, matching profile and all 13 runtime files. Its
unsigned executable is byte-identical to the tested archive. The first export
used manual signing with an Xcode-managed profile and failed; selecting the
cached managed assets correctly resolves that harness error. No provisioning
update, upload, installation or release was performed. Evidence:
`store-export-native-baseline-02/audit.json`.

This is a native baseline, not release acceptance: the additional targeted
chroma failures below remain real defects outside these selections.

The private RGB repair completes actual CPU/Metal workflows with all 72 frames,
exact timestamps, all 142 original AAC packets and complete decoded audio.
The original 15-workflow matrix also passes on that RGB source8. Private phase
build01 then passes 17 workflows with independent media, 14 native-audio checks
and final siting declarations; a subsequent phase API build02 has only its
separate 16 writer checks and two RGB workflows. These snapshots are not
interchangeable. Separate strict-scalar packaging passes ten workflows and
loads five embedded libraries on host, Rosetta and minimum OS, including a
library-replacement control. Current RGB/depth/raw-delivery changes are newer
than that packaging candidate and still need coherent integration.

## Additional chroma and raw-delivery defects

These findings were reproduced after the full native baseline selections:

- **Center calibration:** actual H.264/HEVC CPU/Metal workflows process 72 frames
  and three segments, then fail migration code 39. Synthetic calibration has no
  siting tag and produces Left; real engine frames retain Center. A private
  calibration fix passes 16 host/minimum-OS workflows, but cannot be merged
  alone because the TopLeft counterfactual exposes a new silent error.
- **H.264 TopLeft interpretation:** physical SPS declares TopLeft (location 2),
  while reopened CoreMedia format and decoded buffers report Center. The
  encoder's physical TopLeft output is correct in the isolated endpoint
  control. A bitstream-only source counterfactual retains all coded pictures,
  but the private Center patch completes with physical Center (location 1)
  output. Authenticated SPS interpretation and decoder-boundary correction are
  under development; no root fix is claimed.
- **Left geometry:** `FixedPointPixelBufferScalerV4.init` builds the same
  half-pixel plan for each plane without siting. Independent physical-coordinate
  impulse/edge oracles show a horizontal 0.5 output-luma-pixel shift at 2× and
  1.5 at 4×. CPU and the verified P06 Metal library agree on the incorrect
  result. Phase-aware UV plans are being developed privately. Backend identity
  remains required alongside the independent geometry oracle.
- **Odd raw-carrier edges:** requested 31×19, 31×20 and 32×19 surfaces duplicate
  the previous last luma row/column and truncate chroma. Actual even-raster
  controls remain exact. A private bounded raw-sample unpacker is under test;
  correct dimensions alone do not establish retained edge samples.

Evidence: `native-chroma-phase/`,
`chroma-geometry-independent-01/QA-NOTE.md` and
`software-workflow-continuation/` under the October 25 output folder.

## Fresh Apple model acquisition and native initialization failure

A new macOS 26.6.2 (25G83) VM starts with the quality model Download Required.
The actual production download completes with 36 progress callbacks and
42,695,996 network bytes recorded by Apple's asset service. Original and new
configurations become Ready; the already-ready call also passes. The subsequent
production `prepare` fails at `VTFrameProcessor.startSession` with
`VTFrameProcessorErrorDomain` -19730, the SDK's UnknownError, and zero processed
frames. The combined test remains failed. The identical standalone native
probe fails there without the app or XCTest and succeeds on the physical M4 Pro
host. OS version and physical/virtual device differ, so the underlying cause is
unknown. No GPU override or model-cache removal was applied. Physical macOS 26
processing and forced real-network failure/cancellation remain unverified.
Evidence: `apple-model-fresh-vm-01/QA-NOTE.md` under the October 25 output.

## Fresh 90-minute production export

The runtime7 production workflow passes using a fresh job and cache:
**129,600 frames, 2,160 segments, 5400 seconds**, 160×96 to 320×192, Metal/HEVC.
Independent full decoding verifies every original frame-counter ordinal in
order and exact 24 fps output timestamps. All **259,200,000 PCM16 frames**
(518,400,000 bytes) match the source byte-for-byte; SHA-256:
`3036566c36c7a334d0a51231f9fd7bedbe26729f8662b820618a0cd1101e6f6d`.
The output is 531,347,770 bytes with a 2,031,922-byte `moov` and a **20-byte
constant-size `stsz`**. FFmpeg opens and decodes it with ordinary allocation
limits. Evidence: `output/resumed-qa-2026-10-25/avi-feature-length-90m-runtime7/`.

This is a fresh production render, distinct from the earlier diagnostic table
rewrite and PCM-only writer control. It is a small-raster duration and
finalization test. It does not establish feature-length 4K throughput or isolated
performance. The separate Debug 8K allocation check passes one actual CPU
4096×2160 to 8192×4320 temporal frame; it is not an 8K video export.

A new runtime8 90-minute workflow is running with a 160×96 input and 3840×2160
output. It is UHD-output duration/finalization coverage, not 4K-input decoding
or an isolated performance comparison. No completion is claimed while it runs.

## Specifically still failed or unverified

- Full packaged production support for the additional MKV, WebM, ASF, MPEG2
  transport-stream, MJPEG 4:2:2/4:4:4 and MPEG4 ASP AVI cases. The private 15
  workflows pass, but integration, dependency packaging and provenance remain.
- Production integration of the private RGB, additional 10/12-bit and odd-raster
  work, plus alpha and richer audio/metadata track graphs in that importer.
- Center calibration, physical Left chroma alignment and H.264 TopLeft
  interpretation, including one coherent CPU/Metal source with independent
  pixel/physical-bitstream oracles and renewed source bindings/suites/archive.
- ProRes physical chroma siting. On the host the encoder ignores supplied Left
  and Center tags; this is not covered by H.264/HEVC calibration passes.
- Multiple source audio tracks combined with global `iTunSMPB` and AAC transcode.
  Current typed translation binds exactly one audio track; real consumer
  ownership must be established before extending it. Unchanged and audio-drop
  metadata paths have separate passing controls.
- The exact triggering path for the owner's/customer's error-11 incident.
  Reproduced code-14 and stream-verification failures are separate findings;
  diagnostic improvements alone do not establish a causal repair.
- Physical Intel execution; translated Intel tests do not exercise Intel hardware.
- An actual Store-installed candidate and its sandbox/distribution behavior.
- Physical macOS 26 Apple quality processing, forced cancellation during a real
  fresh download, network failure/retry and distribution model acquisition.
- Feature-length 4K-input processing/throughput and isolated whole-movie
  performance. The current long job uses a low-resolution source.
- Historical complete-checkpoint replay requiring its original intact source
  snapshot. Fresh resume and assembly tests provide separate coverage.
- Current-candidate sealed aggregate qualification, including source-bound
  quality, performance, support and packaging evidence. Tooling unit tests and
  historical captures do not certify that aggregate.

Raw failures, repaired outputs and machine-readable scope remain in the evidence
folders and [the continuation receipt](qa-followup-2026-10-25-results.json).
