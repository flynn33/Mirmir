# Deterministic engine v4 current qualification status

Verified September 21, 2026.

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
| Product | Mirmir 1.3.1 (4) |
| Version authorities | `VERSION` = `1.3.1`; `BUILD_NUMBER` = `4` |
| Bundle identifier | `com.mirmir.app` |
| Minimum macOS | 15.4 |
| M0–M6 implementation | Complete |

The previous 1.3.0 build 3 universal Developer ID archive and its
notarization-oriented qualification tooling remain historical evidence. They
are not inputs or gates for the revised M7 simulator decision.

## Completed verification

The qualification implementation and control surface passed 205 focused tests.
Repository identity replay, semantic qualification self-tests, deterministic
trust-root regeneration, attribution scans, Xcode project parsing, and version
alignment also passed. A clean Debug scheme run completed 475 tests with zero
failures and three expected opt-in capture tests skipped. These results establish
the M0–M6 implementation baseline on which the simulator comparison operates.

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
