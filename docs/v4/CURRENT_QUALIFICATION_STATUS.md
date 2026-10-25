# Deterministic engine v4 current qualification status

Verified October 25, 2026.

**Release remains blocked.**
Current source candidate: **1.7.2 build 20**.

The frozen runtime8 native baseline passes 745 native Release, 750 Debug, 745
Rosetta and 745 macOS 15.4 non-UI tests, each with zero failures and 13 opt-in
skips. All 404 Python checks and a local universal archive audit pass. The
minimum-OS HDR repair passes strict metadata verification. The runtime7 fresh
90-minute AVI workflow retains every original frame ordinal at exact 24 fps and
all 259,200,000 PCM16 frames byte-for-byte; the PCM size table is 20 bytes.

That baseline includes native freeform metadata, single-audio AAC gapless
translation, H.264 wrapper and durable receipt repairs, with reproduced source
bindings. Additional targeted checks found Center chroma calibration failure,
Left chroma misalignment and a CoreMedia H.264 TopLeft interpretation mismatch.
Those repairs remain private and under qualification. Private broad-format
workflows do not establish packaged production support; depth/alpha, odd-raster
delivery and richer track handling remain unfinished. The reported error-11
cause remains unknown and requires investigation.

See [the October 25 continuation](../QA_FOLLOWUP_2026-10-25.md) and
[the full QA record](../FINAL_QA_2026-10-24.md). UI testing is excluded by the
owner. Fresh Apple model network acquisition passed on a separate macOS 26 VM;
subsequent native session creation failed with -19730 and zero processed frames.
Physical macOS 26 quality processing, physical Intel, Store-installed behavior,
feature-length 4K input/throughput and current sealed aggregate qualification
remain unverified. A fresh 90-minute UHD-output job is running from a 160×96
source. No publication or release is authorized.

Local follow-up repairs Apple model retry while native download is still active
and the movie-UTI selection filter. Real fresh-VM clear/retry and controlled
network-failure/retry pass; the selected catalog/probe regression passes 31
tests with two explicit fresh-model skips and zero compiler/runtime warnings.
The private progressive phase candidate passes 24 workflows each on host and
macOS 15.4. Field, vImage/MPS, source-preview, importer and fresh sealed-gate
qualification remain active. The old native counts above remain snapshot-bound.

## Historical October 16 window-lifecycle verification

The October 16 verification covered that source and window lifecycle checks.
Historical engine and full-movie evidence below retains its October 7 dates,
original versions, and artifact identities.

At that checkpoint, source identity was 1.7.1 build 19. Native main-window menu lifecycle,
version alignment, and the development-signed universal Release build passed.
Full native Debug passed 661 tests with zero failures and 13 skips; Release
passed 656 tests with zero failures and 13 skips. Both xcresults reported no
runtime warnings, and both build/test logs contained zero compiler warnings or
errors.
See [window lifecycle](../WINDOW_LIFECYCLE.md).
The engine results below retain
their original 1.7.0 (17) evidence identity and do not qualify a new engine run.

State-conditioned spatial reconstruction uses bounded parallel row stripes
with immutable original boundary rows,
the serial integer stencil, and joined completion. Independent motion blocks
retain bounded parallel execution and fixed-order assembly. Frames, history,
and durable commits remain sequential. Full-source authentication, exact
cadence, input/output verification, runtime admission, and quality checks remain
intact.

## Version 1.7.0 build-17 finish-stage repair

The installed 1.6.0 job completed all 148,176 deterministic Metal video frames
and 2,470 segments, then failed during final assembly. The reproduced failure
was an AVAssetReader-reported duration changing by one tick despite unchanged
stored decode cadence and payload. Final migration exposed equivalent chapter
clock representations, omitted individual audio DTS in grouped packets, AC3
container wrappers, and actual loss of raw ISO audio names. The production
assembler and migration adapter now handle these boundaries with exact,
narrowly scoped identity checks. Saved graph, plan, and runtime bindings remain
unchanged; genuine timing, data, and metadata mutations remain rejected.

The normal My Mac Debug suite passed **658 tests, zero failed, 12 explicit
opt-in skips**, with an empty runtime-warning list. The complete final migration
suite separately passed **102 of 102** with no skips. Full production
finalization of the original saved job passed in **266.697 seconds**. The
published 3840×1632 movie contains **148,176 video frames, both audio tracks and
their Stereo names, and 14 chapters**. Independent checks passed for every
encoded packet, exact stored clocks/edits, all chapter data, and complete
decoded audio PCM. Native frame extraction passed at beginning, middle, and
end; QuickTime opened and displayed a decoded scene after seeking.

The signed universal **1.7.0 (17)** repair was installed and launched on October
7. Its executable matched the repaired Release build exactly, strict signature
verification passed, and native UI readback confirmed the version/build and
idle Metal route. The original source, checkpoint, request, cache, and app
backups are preserved. The historical queue entry remains contained.

Recovery used the completed GPU cache. It does not establish a fresh full GPU
render, matched whole-movie throughput, continuous playback, or audible speaker
playback. The independent Release decoded-parity incident and runtime source
closure remain open. See [repair mechanisms and regression coverage](../DETERMINISTIC_FINALIZATION_REPAIR.md)
and [portable repair evidence](evidence/end-finalization-repair-2026-10-07/README.md).

## Historical October 7 publication Xcode and Release readback

The final repository project built in Xcode with the `Mirmir` scheme and
**Any Mac (arm64, x86_64)** destination: **Build Succeeded at 5:55 PM on October
7**, with **No Issues** in the Issue Navigator, an empty text filter, and both
Only Errors and Only Latest Issues disabled. Swift and C warnings are treated
as errors in both Debug and Release project configurations.

A fresh signed universal production Release CLI build also passed with zero
compiler warnings/errors. Its executable is identical to the installed repair.
The fresh native Release suite passed **653 tests, zero failed, 13 explicit
opt-in skips** (666 total), with no reported runtime warnings. It ran in an
isolated signed test host with the project warnings-as-errors settings. This
passing parity repeat does not identify or close the earlier intermittent
decoded H.264 parity cause.
The source/project hashes and original-receipt digests are retained in
[publication-verification.json](evidence/end-finalization-repair-2026-10-07/publication-verification.json).
These build and UI results do not close the separate provenance or parity
gates. The repair test results above retain their own original run identity.

## Earlier version 1.7.0 build-17 spatial publication verification

Fresh native Debug and Release build-for-testing commands and the universal
production Release build succeeded with zero compiler warning/error lines.
The signed production app identifies as 1.7.0 (17), retains `com.mirmir.app`,
contains arm64 and x86_64, and passes strict/deep code-signature verification.
The actual `/Users/jimdaley/GitHub/Mirmir/Mirmir.xcodeproj` also built with the
Mirmir scheme and **Any Mac (arm64, x86_64)** destination in Xcode: **Build
Succeeded** at 2:04 PM on October 7, with the unfiltered Issue Navigator empty.
No archive, installed-app replacement, distribution, or Intel execution follows
from these build results. Full native suite evidence and the open gates below
remain separate.

Build logs, source-at-build hashes, signature/version receipt, and Xcode UI
receipt are retained in `output/publication-1.7.0-17-2026-10-07/`.
That earlier October 7 readback confirmed the then-installed app as
**1.6.0 (16)**, with the original job process present and its head readable.
The output-only `ferris-preservation.json` receipt records that dated
observation. The later finish-stage repair and installed 1.7.0 (17) readback
above supersede the current installation status.

The fresh default Debug suite passed 635 tests with zero failures and six
opt-in skips (641 total). Fresh default Release passed 630 tests with zero
failures and six opt-in skips (636 total). Both have empty `runtimeWarnings`
lists. These passing runs do not identify or repair the earlier decoded H.264
parity incident. A separate
explicit run of
`DeterministicMetalBackendTests.testCanonical8KEndToEndAllocationGateWhenRequested`
passed one test with zero failures and zero skips, also with no reported runtime
warnings. Despite its test-class name, this gate processes one progressive NV12
frame from 4096×2160 to 8192×4320 with the CPU backend and checks the existing
Debug allocation contract. It does not qualify 8K Metal, a movie, or throughput.
The portable publication summary is
[`publication-verification.json`](evidence/spatial-parallelism-2026-10-07/publication-verification.json).

## Retained pre-version spatial-candidate evidence

On October 7, before version alignment, the native **My Mac** Debug suite
passed 635 tests with zero failures and six opt-in skips. Release passed 630
tests with one failure and five opt-in skips. The failure is the retained strict
decoded H.264 CPU/Metal parity test: all 156 pre-encoder frames match, while
decoded ordinals 125–148 and 154 differ. Four traced repeat runs match. This
evidence does not identify the cause or establish a repair; no parity assertion
was changed. Spatial timing capture was enabled in that Release suite; its
five skips are separate from the fresh default version-17 run above with that
capture disabled. The earlier incident remains open and unexplained.

Forced-worker spatial tests compare every output pixel and control with an
independent reference across all 256 ASH states, uneven stripes, boundary
impulses, full code extrema, rounding ties, one-row/one-column geometry,
invalid input, cancellation before mutation, scratch reuse, copied-workspace
concurrency, and 1920×816/3840×1632 planes. The optimized Release fixture retains
the original serial implementation for paired timings. At 3840×1632 with 14
workers, five alternating pairs after warmup reduced the spatial-call median
from 91.325 to 10.248 ms, **8.91×**, with exact pixels and controls. Full input
validation, halo staging, worker dispatch, and joined completion are timed;
input reset/copy and equality checking are outside the timer. This is a spatial
stage measurement, not whole-engine or feature-length throughput.

An independent comparison used actual pre-change/current optimized binaries
with ten alternating pairs after five warmups. Median spatial-call time was
99.776 → 12.518 ms (**7.971×**) at 3840×1632 and 21.922 → 3.175 ms (**6.905×**)
at 1920×816. All output pixels and controls match, as do cross-binary output
digests. Ferris remained active and no builds or tests overlapped the paired
measurements. This is independent confirmation of the stage improvement, with
separate timings from the original five-pair 8.91× observation; neither is a
guaranteed multiplier or a whole-movie qualification. See
[`INDEPENDENT_VALIDATION.md`](evidence/spatial-parallelism-2026-10-07/INDEPENDENT_VALIDATION.md)
and [`independent-validation.json`](evidence/spatial-parallelism-2026-10-07/independent-validation.json).

An independently identified **development-unsealed** capture reproduced all
840 baseline candidate/ablation artifacts (168 cases × five variants), and two
independent evaluations reproduced the baseline quality section. The quality
index is 122.79205232469828 with paired bootstrap 95% lower bound
122.31276109657409. Its 64×48 planes remain below the 262,144-sample automatic
parallel threshold, so the capture does not exercise the parallel spatial path.
The evaluator retains `releaseQualityGatePass=false`; packaged/natural eligibility
is absent. The capture does not establish a new sealed M7 selection, committed
runtime binding, or current performance qualification. Historical P05 timing
inputs were reused and are not a fresh movie timing baseline.

At the October 7 checkpoint the runtime source-identity gate exited 2. An attempted runtime-production
run stopped at stale frozen `MirmirApp` capture-observer source/size locks, with
16 of 17 checks passing. Runtime assets, trust constants, capture checks, and
historical seals were retained unchanged. Repairing that failure required a legitimate
new runtime/source binding and its full validation; changing a frozen lock to
accept the current file would not supply that evidence.

Portable source-bound receipts and the raw paired benchmark are in
[`evidence/spatial-parallelism-2026-10-07/`](evidence/spatial-parallelism-2026-10-07/README.md).
Implementation details and test names are in
[`../DETERMINISTIC_SPATIAL_PARALLELISM.md`](../DETERMINISTIC_SPATIAL_PARALLELISM.md).
Original builds, traces, independent captures, and result bundles remain local
under `output/spatial-parallelism-2026-10-07/`. Version 1.7.0 build-17 publication
checks are recorded separately from this pre-version-alignment candidate.

## Historical 1.6.0 verification — October 6, 2026

Native Xcode 27.0 tests on macOS 27.0.1, arm64, **My Mac**, passed in both
configurations: Debug 628 passed, zero failed, five opt-in skips; Release 623
passed, zero failed, five opt-in skips. Both commands treated Swift and C
warnings as errors and emitted zero compiler warnings or errors. Release tests
enabled testability; the production Release configuration remains unchanged.
The universal production Release build also passed with zero compiler warnings
or errors, contains arm64 and x86_64 slices, identifies as 1.6.0 (16), and passes
strict code-signature verification. Mirmir has no iOS Simulator destination.
The Mac was locked during the final GUI check, so a fresh visible Xcode Issue
Navigator result was not obtained.

The optimized motion benchmark used five alternating pairs with identical
fields. Median analysis time improved 6.46× at 1920×816 and 6.48× at 3840×1632.
A live deterministic Metal job completed 66 frames from 1920×1080 to
3840×2160 through two durable segments and final publication. Independent
ffprobe/ffmpeg verification passed 35 of 35 checks, including every video
frame, exact admitted NTSC timing, dimensions, color metadata, and all 132,132
PCM audio samples with an identical payload digest. These short-job and
motion-only results do not establish full-length movie throughput.

An earlier untraced Release 157-frame CPU/Metal comparison differed at 34
decoded H.264 frame ordinals. Its pre-encoder output was not captured, so the
cause remains unknown. Subsequent traced CPU, Metal, and same-backend repeats
matched all input, pre-encoder output, timing, and decoded-frame records; both
final full suites also passed. Instrumentation changes timing and cannot
attribute the earlier failure. All strict parity assertions remain in place.

Portable receipts, frozen source hashes, and scope are retained in
[`evidence/motion-parallelism-2026-10-06/`](evidence/motion-parallelism-2026-10-06/README.md).
Original build logs, result bundles, source/output movies, and trace attachments
are retained locally in
`/Users/jimdaley/Desktop/Mirmir-1.6.0-Build16-Evidence/`.

## Historical source identity failure (repaired October 24)

At that checkpoint, `repository_identity_v4.verify_runtime_bundle` rejected both the source
and the unchanged 1.4.5 commit `3a1b3481a19106d895306c2f20b0833d27fabc9e` with
`runtime source revision does not match production source closure`. The
baseline check used all 398 tracked production Swift/Metal sources, the exact
baseline provenance contract and tools, and the packaged ASH-P06 assets copied
from Git into an isolated directory.

The baseline closure computes
`2bc8793b21a1b0429fe7e080d199e0ecfa12e41b15c1fb945c6a8f2addffabaf`, while
the packaged runtime binds
`070556595835048d0112e8de2399be7067ec931079802c906aa8400f51e62f00`. The
working closure also differed from the packaged revision. This was unresolved
at that checkpoint. The October 24 rebuild and current source-identity check
are recorded separately in the final QA report; historical evidence was not resealed.
The comparison and both complete source manifests are retained at
`/tmp/mirmir-p06-baseline-provenance-audit-xwls4uw0/`.

The October 7 publication Python audit also reproduced the unchanged helper
failure `test_v2_contract_pins_current_capture_tools`: the reproduction
contract expects source-provenance SHA-256
`42cffb91247db7d4634894d79a81b00c7e169df0703860f42b575d677d868d2c`,
while the actual unchanged provenance file is
`bc6d85a8b4068d06b6134dabde792fb33503cdf0665a9d8a381a1f982790cd09`.
The contract, provenance, and assertion match the preceding committed tree.
This failed helper and the live closure check remain visible; no locked hashes
or assertions were changed to make them pass.

## October 4 efficiency measurements

Both isolated Swift harnesses used optimized production sources on the same
Mac. The persistent-store harness seeded 7,999 actual exported records in a
14,485,728-byte canonical journal and timed three complete durable appends per
version. Initialization, seed encoding, and verification were outside the append
timing. The real descriptor-relative filesystem, power-loss durability, and
privacy validator were used.

| Measurement | Released 1.4.5 source | Efficiency candidate |
| --- | --- | --- |
| Mean persistent append wall time | 5.23475 seconds | 5.23086 milliseconds |
| Mean persistent append CPU time | 5.22720 seconds | 1.21633 milliseconds |
| 1920×816 → 2880×1224 NV12 CPU scaler median | 20.137 milliseconds | 17.516 milliseconds |
| 1920×816 → 2880×1224 NV12 Metal scaler median | 15.761 milliseconds | 12.563 milliseconds |

The candidate performed one history load at initialization and no additional
loads through the three appends or snapshot. Before and after journals were
byte-identical, with all 8,002 records, sequences, fields, history bytes, and
counters verified. The scaler harness verified equal visible output bytes
before and after, including CPU/Metal equality on the reported geometry and the
standard NV12/P010 cases. These are append and scaler measurements, not a
whole-engine or full-movie throughput qualification. The first earlier scaler
baseline run had higher latency; the table uses the final paired run.

Source hashes, commands, results, and scope are retained locally in:

- `/tmp/mirmir-diagnostic-store-benchmark-nnxvf4tm/comparison.json`
- `/tmp/mirmir-diagnostic-store-benchmark-nnxvf4tm/manifest.json`
- `/tmp/mirmir-scaler-validation-benchmark-nwg5kq_g/comparison.json`

The full-source SHA-256 read still occurs at every deterministic segment. The
original one-hour run and reported 18-hour run have not been reproduced as a
matched before/after full-length comparison. DV4-002 remains open.

## Historical 1.4.5 qualification

Version 1.4.5 removed the obsolete split-position test from `MirmirTests.swift`;
its diagnostic tests and other mixed code files were unchanged. The 1.4.4
restoration of the 36 specified baseline paths remained intact.

The unsigned Debug test build succeeded. The named
`testRavenForgeSite057ExactRepresentableEndIgnoresDistinctContainerBoundary`
passed: one test, zero failures. Version tests passed 9 of 9. Logs and result
bundles are retained in
`/Users/jimdaley/Desktop/Mirmir-1.4.5-Build14-Evidence/`.

Benchmark tests passed 12 of 13. The historical replay still reports:
`repeatability pair 1 failed evaluation: candidate engine source manifest differs from authoritative source: docs/v4/evidence/m2-pixel-buffer-hot-path-2026-08-03/prepared-direct-after.json`.
No ASH reseal or benchmark/evidence changes were made. The full Swift suite
was not run in this pass.

The remaining verification narrative below belongs to 1.4.3 and earlier
commits; it does not establish qualification of the current 1.7.2 source.

Historical qualification receipts retain their original dates and source
identities.

The GitHub-facing tracker in `roadmap-status.svg` is generated from this
document, `DETERMINISTIC_ENGINE_V4_ROADMAP.md`, `VERSION`, and `BUILD_NUMBER`.
The `Verify roadmap tracker` workflow recomputes and byte-compares the graphic
on every push and pull request.

## M7 scope

M7 is now a deterministic simulator-only candidate comparison. Mirmir is a
macOS application and has no Apple Simulator destination, so “simulator” means
the headless XCTest frame simulator that supplies reproducible pixel buffers to
the real Swift engine implementations.

M7 does not require an external device, a physical-machine support matrix, a
signed application archive, notarization, stapling, publication, shipping, or
distribution. Those activities are outside this roadmap and remain owner
decisions.

## Product and source identity

| Field | Verified value |
| --- | --- |
| Current source product | Mirmir 1.7.2 (20) |
| Version authorities | `VERSION` = `1.7.2`; `BUILD_NUMBER` = `20` |
| Historical October 7 installed-application check | Signed 1.7.0 (17), installed and launched October 7; exact repaired executable, strict signature, native About version/build, and idle Metal route verified |
| Historical installed-application check | `/Applications/Mirmir.app` 1.5.0 (15), checked October 6; source publication does not establish current installation |
| Bundle identifier | `com.mirmir.app` |
| Minimum macOS | 15.4 |
| M0–M6 implementation | Complete |
| P06 semantic runtime-manifest identity | `544e3c36ac3324d67a3e66713dd7331e29462b6c99601981a17e589d497e995f` |
| P06 runtime-manifest file SHA-256 | `b863309bf12b375e21e5d0978ddded377781d39eaa5457bc891bd043581d29fc` |
| P06 packaged production-source revision | `f794943d08796b96861aa3880273c07f06946febd94119c31835a8a48b85008e` |
| P06 builder-source SHA-256 | `40aad241a07eda3f63919eed2b126eb7dc62777be9bd6520cf2b5a3c824c6dc9` |

The previous 1.3.0 build 3 universal Developer ID archive and its
notarization-oriented qualification tooling remain historical evidence. They
are not inputs or gates for the revised M7 simulator decision.

## Completed verification

The qualification implementation and control surface passed 205 focused tests.
Repository identity replay, semantic qualification self-tests, deterministic
trust-root regeneration, attribution scans, Xcode project parsing, and version
alignment also passed. The 1.3.2 conformance tree completed 493 Debug scheme
tests: 490 passed, zero failed, and three expected opt-in capture tests skipped.
An unsigned universal Release build also passed. These results establish the
M0–M6 implementation baseline on which the simulator comparison operates.

The build 7 macOS Debug suite completed 500 tests: 497 passed, zero failed,
and three expected opt-in capture tests skipped. It includes conventional and
Deterministic v4 second-audio-track retention plus a legal 90 kHz NTSC cadence
lattice through approximately the original 1:43 source's frame range. A local
archive prepared for owner handoff only exists at
`/Users/jimdaley/Desktop/Mirmir-Beta-1.3.3-7.xcarchive`; it is excluded from
Git and was not uploaded, submitted, distributed, released, or installed. It
is historical build-7 evidence, not a build-8 archive.

Version 1.3.4 adds authenticated resume from a failed job's last verified
nonterminal checkpoint, closes deterministic segment writer sessions at the
verified encoded boundary, and separates live Upscale progress from the
independent completed-video Compare player. A visible production
Deterministic v4 Metal run of the original 1:43 Ferris source at 7680 × 3264
with audio preservation enabled committed through frame 8,760 without the
earlier site-054 error, then failed when the internal volume reached ENOSPC. No
complete output movie was published, so that historical run does not establish
terminal timing or current-candidate completion.

Version 1.4.0 adds user-selectable bookmark-backed workflow-cache storage,
return to internal Application Support, individual and bulk inactive-job
deletion, and owned temporary-cache cleanup. Location changes are blocked until
the current queue is empty, unavailable custom roots can recover to internal
storage, active jobs fail closed, and completed destination movies are outside
the deletion namespaces.

Version 1.4.2 fixes the cache confirmation path in Settings and Queue. One
workspace alert presents all cache confirmations, and the confirmed operation
awaits deletion and reads back the durable queue. Three isolated-store tests
seeded completed, failed, cancelled, paused, and contained jobs; finished,
unfinished, row, and
Clear Cache operations removed journal records and owned files, left a
completed output intact, and enabled the location gate at zero jobs. After this
fixture proof, the owner authorized removal of 18 finished and four unfinished
jobs through the view-model deletion path. Clear Cache removed remaining owned
artifacts; the installed 1.4.1 app reopened the same root with zero jobs and an
enabled location chooser. Its binary was not replaced.
The full 1.4.2 build-11 macOS Debug result bundle reports 543 total tests:
540 passed, zero failed, and three expected opt-in capture tests skipped.

Version 1.4.3 changes the shared clock conversion so every exactly
representable rational returns directly; only an incommensurate value consults
an independently admitted adjacent boundary. Its named source-asset regression
derives 241 decoded frames, `123392/12288` exact nominal end, and the distinct
`123396/12288` track end from the reported short MP4. A separate durable
coordinator invariant inventories encoded primary-video samples and rejects a
terminal decoded ordinal that accounts for only 240 of 241 samples before
finalization or publication recovery. The named 1.4.3 asset regression
passed 1 of 1 on October 3.

The historical 1.4.3 build-12 full Debug scheme completed 590 tests: 586 passed,
zero failed, and four explicit opt-in tests skipped. Repository Python contracts
passed 388 of 388 tests across 27 of 27 commands. Release analysis with
`ARCHS=arm64 x86_64`, `ONLY_ACTIVE_ARCH=NO`, and signing disabled succeeded and
emitted an `x86_64 arm64` binary.

The production durable-workflow test used
`/Users/jimdaley/Mirmir/Mirmir-In/raven-forge-app-splash-2.mp4` and passed.
Independent postvalidation passed 66 of 66 checks, matched 241 source and output
video frames, matched 470 source and output audio packets, and matched the
one-member audible selection group. Its published output is
`/Users/jimdaley/Desktop/Mirmir-1.4.3-Build12-Evidence/83-final-real-source-production-1024-green/durable-workflow-run/durable-workflow-output.mov`.

The built 1.4.3 (12) application's visible Diagnostics controls and native save
panels created and validated these export files:

- `/Users/jimdaley/Desktop/Mirmir-1.4.3-Build12-Evidence/Mirmir-Compare-Build12-Diagnostics.json`
- `/Users/jimdaley/Desktop/Mirmir-1.4.3-Build12-Evidence/Mirmir-Compare-Build12-Diagnostics.md`
- `/Users/jimdaley/Desktop/Mirmir-1.4.3-Build12-Evidence/Mirmir-Compare-Build12-App-Logs.json`

These are historical 1.4.3 source, build, media, and export-control results. They
do not qualify the current source or installed application or complete DV4-002
large-media qualification. Application archiving and distribution were outside
that source qualification. The 1.4.2 and 1.4.1 archives below remain historical.

The historical build 9 serial macOS Debug scheme completed 532 tests: 529
passed, zero failed, and three expected opt-in capture tests skipped. The prior
accepted tree contained 522 tests; all ten additional tests passed.

The historical 1.4.1 build 10 full serial macOS Debug scheme completed 540 tests:
537 passed, zero failed, and three expected opt-in capture tests skipped. The
focused timing and conventional-media run passed 23 of 23 tests. A fresh
published-tree run of the seven named production-path timing declarations plus
the three initially failing full-suite cases passed 10 of 10 tests. These are
source-level regression results, not installed-product or completed-media proof.

A historical local universal archive prepared for owner handoff only exists at
`/Users/jimdaley/Library/Developer/Xcode/Archives/2026-09-30/Mirmir-1.4.1-10-TestFlight.xcarchive`.
Its packaged application is `com.mirmir.app` version 1.4.1 build 10, contains
`arm64` and `x86_64` slices, is signed by Apple Distribution for team
`9AQ2C2838M`, and passes strict code-signature verification with the sandbox,
app-scoped bookmark, and user-selected read/write entitlements. The archive was
not uploaded, submitted, distributed, released, notarized, or installed over
`/Volumes/DockCase/Apps/Mirmir.app`. The previously
documented Desktop path was not present. The DockCase application was observed
as 1.3.4 build 8 during that historical check.

A historical universal 1.4.2 build-11 Apple Distribution archive prepared for
owner handoff only exists at
`/Users/jimdaley/Library/Developer/Xcode/Archives/2026-10-01/Mirmir-1.4.2-11-TestFlight.xcarchive`.
Its 1.4.2/11 identity, arm64 and x86_64 executable/dSYM UUID pairs, embedded
Mac Team Store provisioning profile, sandbox entitlements, secure timestamp,
and strict signature were verified. It was not uploaded, submitted,
distributed, released, or installed.

Before the October 1 owner-authorized cache clear, the Ferris job was parked at
authenticated checkpoint ordinal
2,468, video `nextInputSampleIndex` 148,140, and 2,469 committed segment files,
leaving 36 source frames. It was not resumed or finalized. Its cached
checkpoint, segments, and recovery lock were removed with the live store
cleanup; the historical observation is not treated as completion.

## Version 1.3.3 rollback qualification

Version 1.3.3 is based on source checkpoint
`5addbee99674c08869ab010dec3d4c6988c40549`, immediately before the
resource-allocation control. That control is not a first-release target and is
not included in version 1.4.0.
Two post-rollback corrections remain:

- user-selected regular sources may have multiple hard links, while the
  queue-owned private snapshot retains its single-link invariant; and
- VideoToolbox Smooth Motion + Spatial Upscale is marked unavailable when the
  Mac's reported 2× source-frame maximum dimension or pixel-count limit rejects
  the input. These processor limits are independent of display resolution.

The retained 960 × 960 opaque H.264 fixture completed deterministic CPU and
Metal 1920 × 1920 HEVC jobs with 241 frames, audio, attached picture, and
identical decoded frames. A fresh Metal job paused after durable boundary zero,
resumed from its persisted checkpoint, and completed a playable output.
Cancellation left no destination movie and did not prevent a later enqueue of
the same source. Automatic retained its existing opaque-input policy and did
not select deterministic v4. Attached-picture preservation remains specific to
the deterministic v4 whole-asset path; conventional backends do not preserve
attached pictures.

Build 7 additionally keeps every source audio track when preservation is
enabled in conventional and Deterministic v4 jobs, validates audio topology,
accepts legal 90 kHz NTSC timestamp quantization, and includes a distinct
stable site identifier on every error-16 (`invalidSampleTiming`) throw. The
original 1:43 beta asset had not been rerun at the build-7 boundary, so the
reported failure was still open at that point. The later version 1.3.4
production run passed the corrected timing path through frame 8,760; DV4-001 is
now resolved while DV4-002 retains broader large-media qualification.

## Version 1.3.2 conformance remediation

Real-file validation after M7 exposed defects at implementation boundaries
that the simulator candidate-selection contract intentionally does not measure.
Version 1.3.2 corrects and tests:

- processed-video replacement media origins, exact movie edit-map timescales,
  and writer-session starts;
- semantic AAC identity across MP4 and MOV wrapper representations;
- dynamic-HDR-absent decoded cadence without relying on rounded track ends;
- legal NV12/P010 video-range footroom and headroom while rejecting malformed
  packed storage;
- destination-directory identity checks for atomic temporary output;
- durable original-basename binding plus fail-before-dispatch migration for
  legacy generic source snapshots; and
- immediate paused-job resume without idle queue-drain slot contention.

The retained reported MP4 fixture then remuxed with all 241 H.264 samples and
470 AAC samples accounted for. The repository regression fixtures independently
recreate the timing, wrapper, range, alias, and migration cases. The recorded
qualification receipt is in
`docs/v4/evidence/1.3.2-conformance-remediation-2026-09-23/`.

At the 1.3.2 checkpoint, the P06 builder reproduced that 12-artifact bundle
byte-for-byte across two independent builds. Ten artifact files, including the
Metal library and operator data, remained unchanged; the metric and verification
contracts bound the stabilized quality evaluator used by that repository
revision. That historical canonical manifest binds production-source revision
`070556595835048d0112e8de2399be7067ec931079802c906aa8400f51e62f00`, and
the code-owned manifest trust root resolved to
`e4cc2394ff7454447d11a37fccf99f8e6c66ca6e68f5302a734e999cd815b5b4`.
The production loader accepted that binding and rejected a same-length
artifact mutation.

## M7 simulation contract

The candidate set is the production v4 policy plus the four existing
deterministic test-harness policy ablations: uniform priors, randomized
state/message assignment with its stable seed, temporal hysteresis disabled,
and motion/history disabled. Frozen P05 is the comparison baseline and cannot
be selected.

A candidate is eligible only when the same simulation run proves both of the
roadmap’s numerical targets:

- quality index and paired-bootstrap 95% lower bound are at least 105;
- total, median, and p95 processing-time ratios are each no greater than 0.80
  of P05.

Eligible candidates are ranked by quality lower bound, quality point estimate,
total processing time, p95 time, median time, and stable identifier. The exact
machine-readable rules are in
`script/v4/m7-simulation-selection-contract-v1.json`; the human-readable
procedure is in `docs/v4/M7_SIMULATION_QUALIFICATION_V1.md`.

## Current M7 decision

| Field | Value |
| --- | --- |
| M7 simulation status | Complete |
| Simulation source commit | `ce780af87107d90142d860f328dca4a72fea3047` |
| Selected candidate | `candidate_v4` |
| Quality target | Passed — index 122.792052; paired-bootstrap 95% lower bound 122.312761 |
| Processing-time target | Passed — total 0.025213× P05 (97.478689% reduction); median 0.026859×; p95 0.030117× |
| Selection evidence | `docs/v4/evidence/m7-simulation-selection-2026-09-21/m7-simulation-selection-report.json` |

## Completed M7 simulator result

The clean Release simulation used 168 cases from 28 clips across seven
procedural cohorts, with five warm-up executions per policy path and 10,000
paired-bootstrap replicates. It ran on macOS 27.0 (26A428), Xcode 27.0
(27A266a), arm64, on the recorded Apple M4 Pro host. Those host details are
measurement context, not a physical-device support qualification.

All five candidates cleared every numerical threshold. `candidate_v4` ranked
first because its conservative quality lower bound, 122.312761, was the highest
under the locked ordering. Its quality index was 122.792052, a 22.792052%
increase over P05. Its total, median, and p95 processing-time ratios were
0.025213, 0.026859, and 0.030117 respectively; total measured engine time fell
97.478689% versus P05.

The quality evaluator replayed all sealed output planes. The selector then
replayed raw per-case timings, all candidate confidence intervals, P05
toolchain derivation, canonical and injected capture-source identities,
eligibility, ranking, and winner. A separate manifest pass verified all 1,372
sealed artifacts by path, byte count, and SHA-256.

The legacy quality report deliberately retains `releaseEligible: false` and
`releasePerformanceGateEligible: false` because this is a procedural,
engine-call simulator corpus rather than camera-native or end-to-end release
evidence. The revised M7 selection contract explicitly admits that bounded
scope. No notarized-app, hardware-support, shipping, or distribution claim is
made.

## Historical evidence boundary

Earlier calibration evidence remains useful for implementation history but did
not complete M7. The decision above comes only from the fresh committed-source
simulation and its reproducible selection report.
