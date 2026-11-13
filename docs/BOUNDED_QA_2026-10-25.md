# Bounded QA checkpoint — October 25, 2026

Mirmir **1.7.2 (20)**. The chroma, progressive JFIF MOV and native ProRes 422 working-format repairs are integrated on the local QA branch. **Release remains blocked. The all-feature goal is not complete.** This checkpoint does not include the private broad-format importer or the held export-preservation repairs. No UI/screen testing, push, notarization or Store operation occurred.

## Found and fixed

- Physical chroma sampling used a generic plane grid rather than its location relative to luma. The integrated CPU/Metal plans now bind source/output siting, field geometry, physical coordinates and checkpoint identity. H.264 SPS interpretation, writer calibration, affected Apple scaler bridges and native thumbnail conversion carry the corresponding facts. Earlier independent raw/temporal and host/minimum-OS workflow matrices are recorded in [the continuation](QA_FOLLOWUP_2026-10-25.md).
- The private phase-admission guard rejected progressive JFIF MOV because native extensions omitted its proven Center sampling. Read every compressed JPEG declaration, retain original facts separately from qualified native working facts, and complete only a missing decoded tag. Contradictory buffers and the unqualified OpenDML decoder stay rejected. Pixel bytes and unrelated attachment modes stay checked.
- ProRes 422 admission lacked a proven decoded working format. Native 4:2:0 controls also discarded field chroma. `ProRes422SourceFactsV4` proves packet/header ownership, raster, scan and color; `ProRes422WorkingConverterV4` reads native v216, averages adjacent progressive rows or rows within the same physical field, and performs one nearest-ties-even conversion to P010. Original encoded facts remain separate. Preparation, reader, writer and temporal restoration bind the delivery policy and OS/model/architecture decoder environment.
- Release-verifier source bindings had become stale during the private repairs. Current count/hash, builder, fixture and trust-envelope bindings now agree with the actual source. Thresholds, coverage, historical captures and frozen baselines were not changed.

Impact: probing/admission, CPU and Metal preparation, decoded-frame delivery, writer sampling declarations, thumbnail media conversion, qualification captures and temporal compatibility. Old checkpoints with a different processing/source-delivery identity are rejected. There is no silent engine substitution or new dependency. Automatic retains its documented spatial Apple-only selection.

Source owners: [physical geometry](../Mirmir/Modules/UpscalerEngine/SpatialScalePlanV4.swift), [ProRes source headers](../Mirmir/MediaIO/ProRes422SourceFactsV4.swift), [working conversion](../Mirmir/MediaIO/ProRes422WorkingFormatV4.swift), [whole-asset planning](../Mirmir/MediaIO/DeterministicV4WholeAssetPlanner.swift), and [permanent ProRes regression tests](../MirmirTests/ProRes422WorkingFormatV4Tests.swift).

## Verification

| Check | Observed result |
| --- | --- |
| Full non-UI optimized Release suite from this checkout | 815 passed, zero failures, 15 explicit opt-in skips (830 total); zero compiler/runtime warnings. Two owner-excluded window/composition tests were omitted. |
| Focused final private optimized ARM build | 13/13 passed, including the exact discovered helper-test roster. |
| Final optimized x86_64 execution through Rosetta | 38/38 passed. This does not establish physical Intel GPU behavior. |
| Actual macOS 15.4 (24E248), ARM64 | 16/16 selected methods passed; every application/test payload hash agrees before transfer and before/after execution. Includes common-codec exports, JPEG regression, progressive/TFF/BFF ProRes CPU/Metal fresh-owner recovery, checkpoint rejection and the full-ten-bit verifier control. |
| Independent ProRes conversion | All 48 full visible YUV frames across ARM, Rosetta and 15.4 match a separate Python Fraction oracle, including borders. Native v216 and converted P010 active bytes agree across the three measured environments. Wrong row-drop controls differ in every frame. |
| Independent final ProRes-source media | All 12 HEVC Main 10 movies decode completely. Progressive 72 frames at 24 fps and TFF/BFF 144 frames at 48 fps have exact PTS, every stored packet duration and 3-second ends. Each retains 144,000 source PCM16 audio frames exactly. CPU/Metal/uninterrupted/fresh-owner-resumed decoded 10-bit pictures are exact. |
| Verification-tool regressions | 72 current-context and 120 historical-context tests pass without skips. Closed-source identity checks pass 5/5; version synchronization checks pass 9/9. Historical evaluator bytes remain pinned separately. |
| Earlier bounded JFIF batch | 33 Debug, 27 Rosetta and 11 actual 15.4 methods passed; all 18 outputs pass independent complete decode, exact packet timing and PCM checks. |
| Source/runtime | 411 production sources; two runtime builds agree on all 13 files; source/root hashes verified after installation. Source identity cdb0ed8c765fba7fa0f4dddfb9045d4def6105b9ad62fddc5b6d3eb604feb0d7; canonical runtime db56804a443f767f383737661486d551859198a259e5a60dd0820079fcb6bf52.|
| Default Xcode Release application | Universal arm64/x86_64, deployment 15.4, local development signing; build and deep/strict signature verification pass with zero compiler warnings/errors. Runtime XCTest uses the separate optimized ENABLE_TESTABILITY=YES build. |

The 15 opt-in skips are two performance captures, two fresh-model network cases, the physical 8K allocation gate, two baseline captures, the external-source durable workflow and seven saved-media/checkpoint replays. They are excluded from the pass count; the exact names/reasons are retained in root-opt-in-skips.json alongside the test result. These scenarios remain unverified for this exact integrated snapshot.

Recovery above recreates queue/engine/reader owners within a test process. It is not a fresh-process ProRes/JPEG recovery acceptance claim. Small generated fixtures do not qualify feature-length or larger-raster performance.

Retained failures: the initial VM verifier wrongly required the six unused P010 bits to be zero. CoreVideo's installed CVPixelBuffer.h defines samples in the ten MSBs; production reads them by shifting six. The corrected verifier compares all ten significant bits exactly. The converter's owned output still has a separate zero-unused-bits assertion. The initial Automatic test contradicted PRODUCT_SUPPORT.md and existing selector tests; it was corrected without changing selection. A helper test in a private extension was undiscovered; subsequent relocation compile errors were fixed, and the final ARM/Rosetta/guest rosters prove it executed. The first integrated full run was interrupted after a test helper stalled reading its shader source from the external checkout. Sampling found the wait in Foundation file-open; no TCC denial log was captured. That test helper now loads the shader already compiled into the app bundle. Focused alpha and the subsequent full suite verify this test-only repair. Original failed/interrupted results and build logs remain preserved. Historical fixed-pixel tests retain their expected bytes and now explicitly declare the Center fixture geometry they measure.

## Not fixed or fully verified

| Feature or case | Status and why it remains open |
| --- | --- |
| Reported customer error 11 | Still a release blocker. Error numbers have multiple domains; the retained protected-input control does not establish the customer's cause or a SIGSEGV. No causal repair is certified. |
| Normal broad-format deterministic input | MKV, WebM/VP9, ASF/WMV, MPEG2 transport streams, MPEG4 ASP B/S pictures and the broader JPEG families still need coherent production decoder admission and complete-output checks. The private software importer is not selected by normal production routing. |
| OpenDML Motion JPEG AVI | Reproduced zero-frame native decode on 15.4 and differing host Huffman interpretation. Header ownership alone cannot repair the native decoder. Its candidate routing proof is held. |
| JFIF beyond the bounded case | JPEG422/444, paired/interlaced JPEG, odd rasters, long movies and JPEG-to-HEVC/ProRes were not qualified by the MOV-to-H264 batch. |
| ProRes beyond the bounded cases | HQ/LT/Proxy, larger/HDR real sources, feature-length performance, interlaced heights not divisible by 4, and ProRes-source H264/ProRes output remain unverified. Working conversion is explicitly lossy 4:2:2 to 4:2:0, 10-bit; source precision is not rewritten as a fictional encoded bit-depth field. |
| PAL DV420 fields | Packed 4:2:2 counterfactuals retain samples lost by native 4:2:0. A production component-lattice policy and end-to-end validation remain unfinished. |
| Conventional alternate video/subtitles/title | Reproduced silent track/title loss in the committed route. The common-migration prototype passes four focused tests, but wider metadata/timeline/recovery interactions are not qualified or integrated. |
| Export creation date | The shared executor replaces source stored creation dates with export time. No date-ownership repair is integrated. |
| Edited/B-frame passthrough timing | Terminal empty-marker handling changes a stored final decode duration. A private patch leaves six edited-source controls red and changes four digests; it remains held. No tolerance or digest waiver was applied. |
| Multiple-audio gapless technical metadata | Conflicting global hint/track clocks remain unresolved; existing single-audio qualification does not cover them. |
| VideoToolbox quality processing | Fresh model acquisition/retry passes, but real session initialization previously returned -19730/zero frames. Actual production quality processing remains unqualified. |
| Latest pixel-transfer repair | A separately measured repair has 12 workflow/864-frame host/15.4/Rosetta evidence and measured memory/cost; it is outside this integrated candidate. |
| New UHD feature-length job | A retained job returned terminal status 0; complete independent 129,600-frame/PCM verification for that newer snapshot has not run. Older runtime7 full-media evidence remains historical. |
| Fresh-process JPEG/ProRes recovery | Only fresh-owner same-process recovery is established in these new cases. |
| Current aggregate quality/parity/performance/media-preservation gates | Tool regressions and bounded source-bound media checks do not replace fresh complete gates on the final coherent source. |
| Physical Intel and exact default Release runtime | Rosetta is available; physical Intel GPU execution is not measured. The default non-testable app builds/signs, but the runtime tests use the optimized testable image. |
| Store/notarized distribution | Outside the owner's requested delivery boundary. Jim handles these operations; no Store or notarization acceptance is claimed. |

[Portable receipts](v4/evidence/bounded-working-format-2026-10-25/README.md) are committed with this report. Machine-readable results, original failures, raw captures, independent oracles, exact source/runtime inventories, backup manifest and applied-file receipt are retained in `output/resumed-qa-2026-10-25/prores-working-boundary-02/`. The original root files were backed up under `/private/tmp/mirmir-bounded-integration-root-backup-20261025/`; the 107-file integration excludes the owner's Xcode user-state file. The prerequisite phase/JPEG changes and ProRes repair were integrated together because admission, processing, writer and checkpoint identities must agree. This is a local QA checkpoint, not a release certificate.
