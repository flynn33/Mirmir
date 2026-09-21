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
| Product | Mirmir 1.3.0 (3) |
| Version authorities | `VERSION` = `1.3.0`; `BUILD_NUMBER` = `3` |
| Bundle identifier | `com.mirmir.app` |
| Minimum macOS | 15.4 |
| M0–M6 implementation | Complete |

The previous universal Developer ID archive and its notarization-oriented
qualification tooling remain historical evidence. They are not inputs or gates
for the revised M7 simulator decision.

## Completed verification

The qualification implementation and control surface passed 205 focused tests.
Repository identity replay, semantic qualification self-tests, deterministic
trust-root regeneration, attribution scans, Xcode project parsing, and version
alignment also passed. A clean Debug scheme run completed 472 tests with zero
failures and three expected opt-in capture tests skipped. These results establish
the M0–M6 implementation baseline on which the simulator comparison operates.

## M7 simulation contract

The candidate set is the production v4 policy plus the four existing
deterministic test-harness policy ablations: uniform priors, randomized state/message assignment with its stable
seed, temporal hysteresis disabled, and motion/history disabled. Frozen P05 is
the comparison baseline and cannot be selected.

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
| M7 simulation status | Pending |
| Simulation source commit | Pending |
| Selected candidate | Pending |
| Quality target | Pending |
| Processing-time target | Pending |
| Selection evidence | Pending |

## Open M7 simulator steps

1. run all five candidates against the source-frozen P05 baseline under one
   recorded toolchain;
2. independently reproduce the quality metrics, timing ratios, ranking, and
   selection;
3. record the selected candidate and sealed evidence receipt.

M7 is complete when the reproduced selection report has `m7Satisfied: true`
and names exactly one eligible winner. No notarized-app or shipping action is
part of that decision.

## Historical evidence boundary

Earlier calibration evidence is useful for implementation history but does not
complete the revised M7 run. It used an older source revision and cannot replace
the fresh simulator comparison from the committed selection harness.
