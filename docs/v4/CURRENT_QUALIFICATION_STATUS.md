# Deterministic engine v4 current qualification status

Verified September 28, 2026.

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
| Product | Mirmir 1.3.4 (8) |
| Version authorities | `VERSION` = `1.3.4`; `BUILD_NUMBER` = `8` |
| Bundle identifier | `com.mirmir.app` |
| Minimum macOS | 15.4 |
| M0–M6 implementation | Complete |
| P06 runtime manifest identity | `e4cc2394ff7454447d11a37fccf99f8e6c66ca6e68f5302a734e999cd815b5b4` |
| P06 production-source revision | `070556595835048d0112e8de2399be7067ec931079802c906aa8400f51e62f00` |

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
TestFlight handoff archive exists at
`/Users/jimdaley/Desktop/Mirmir-Beta-1.3.3-7.xcarchive`; it is excluded from
Git and upload remains an owner action. It is historical build-7 evidence, not
a build-8 archive.

Version 1.3.4 adds authenticated resume from a failed job's last verified
nonterminal checkpoint, closes deterministic segment writer sessions at the
verified encoded boundary, and separates live Upscale progress from the
independent completed-video Compare player. A visible production
Deterministic v4 Metal run of the original 1:43 Ferris source at 7680 × 3264
with audio preservation enabled committed through frame 8,760 without error
16, then failed when the internal volume reached ENOSPC. No complete output
movie was published; DV4-001 remains open.

The build 8 macOS Debug scheme completed 510 tests: 507 passed, zero failed,
and three expected opt-in capture tests skipped.

## Version 1.3.3 rollback qualification

Version 1.3.3 is based on source checkpoint
`5addbee99674c08869ab010dec3d4c6988c40549`, immediately before the deferred
resource-allocation control. That control is not included in this release.
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
original 1:43 beta asset has not been rerun, so its reported Deterministic v4
large-file failure remains open. The long-lattice regression is not evidence
that the original failure is closed.

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

The P06 builder reproduced the current 12-artifact bundle byte-for-byte across
two independent builds. Ten artifact files, including the Metal library and
operator data, remain unchanged; the metric and verification contracts now
bind the stabilized quality evaluator already used by the repository. The
canonical manifest binds production-source revision
`070556595835048d0112e8de2399be7067ec931079802c906aa8400f51e62f00`, and
the code-owned manifest trust root resolves to
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
