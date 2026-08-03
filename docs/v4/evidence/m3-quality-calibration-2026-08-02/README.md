# M3 quality-calibration evidence — 2026-08-02

This bundle is a reproducible calibration run for the deterministic engine v4
quality gate. It is deliberately **not** release-qualification evidence. The
corpus is deterministic synthetic imagery at 64×48, and the candidate uses a
test-built, manifest-verified P06 runtime because the production runtime is not
yet release-locked. The report therefore fails closed even though its aggregate
quality point estimate and confidence interval exceed the v4 target.

## Reproduce

From the repository root:

```sh
python3 script/v4/test_quality_gate_v4.py
script/v4/run_quality_gate_v4.sh \
  --output /tmp/mirmir-m3-quality-calibration
python3 script/v4/quality_gate_v4.py verify \
  --report /tmp/mirmir-m3-quality-calibration/quality-gate-report.json
```

The runner generates the corpus, creates an isolated source snapshot, injects
the capture test into that snapshot only, builds the real P05 and v4 CPU
backends in Release mode, captures the baseline/candidate/ablation outputs,
evaluates the preregistered metrics, and verifies the report. It does not alter
the repository project file.

## Preregistered gate

The contract covers seven equally weighted cohorts: natural detail,
text/graphics, animation, faces, low light/noise, high motion, and scene cuts.
Each cohort has four clips of six frames in this diagnostic corpus, alternating
NV12 video-range and full-range inputs.

The normalized error is the weighted sum of exactly five components:

| Component | Weight |
| --- | ---: |
| Luma multiscale structural error | 0.35 |
| Chroma multiscale structural error | 0.15 |
| Analytic perceptual-feature distance | 0.20 |
| Motion-compensated temporal/flicker error | 0.20 |
| Edge displacement/ringing/overshoot error | 0.10 |

The quality index is `100 × (2 − normalized error)`, with P05 fixed at 100.
Release requires both the candidate point estimate and the deterministic,
clip-paired 95% bootstrap lower bound to be at least 105. It also requires no
cohort's luma error ratio to exceed 1.01, and no temporal-error regression in
the high-motion or scene-cut cohorts. The bootstrap uses 10,000 stratified
replicates and the contract-locked SplitMix64 rejection sampler.

## Result

| Measure | Result | Gate |
| --- | ---: | --- |
| Candidate quality index | 121.2272 | Pass (≥105) |
| Paired-bootstrap 95% interval | [120.7453, 121.7211] | Pass (lower ≥105) |
| Weighted normalized error | 0.787728 | Diagnostic |
| All-cohort luma non-regression | Worst ratio 0.832157 | Pass (≤1.01) |
| Scene-cut temporal ratio | 0.847520 | Pass (≤1.00) |
| High-motion temporal ratio | 1.053718 | **Fail** (≤1.00) |
| Production P06 runtime locked | No | **Fail** |
| Native-HR natural corpus | No | **Fail** |
| Overall release quality gate | False | **Fail closed** |

The aggregate normalized components are:

| Component | Candidate/P05 error ratio |
| --- | ---: |
| Luma multiscale structural | 0.644007 |
| Chroma multiscale structural | 0.590760 |
| Perceptual feature | 0.931434 |
| Motion-compensated temporal/flicker | 0.921535 |
| Edge displacement/ringing/overshoot | 1.031183 |

All seven luma cohort constraints pass. The hard failure is the high-motion
temporal cohort, where the candidate regresses 5.3718%. The aggregate edge
component also regresses 3.1183%; it is represented in the weighted score and
is not a separate preregistered hard constraint.

The matched ablation quality indices are:

| Variant | Quality index |
| --- | ---: |
| Full v4 candidate | 121.2272 |
| Uniform priors | 121.1677 |
| Randomized state/message | 121.1635 |
| Temporal hysteresis off | 121.1148 |
| Motion/history off | 121.1597 |

The small deltas show that the current policy/history additions contribute
measurably on this corpus, but much less than the spatial reconstruction
change. Motion/history improves the aggregate score by 0.0674 points while
still worsening the high-motion hard constraint. That result directs the next
calibration toward motion confidence, occlusion/repetition rejection, and
history admission at large motion—not toward declaring M3 complete.

## Timing diagnostic

The v4 engine-call median was 0.487229 ms versus 32.043542 ms for P05, and its
p95 was 0.546611 ms versus 40.891250 ms. These correspond to diagnostic
reductions of 98.48% and 98.66%, respectively. They are intentionally marked
performance-ineligible because the corpus is tiny and the capture excludes
decode, encode, writer backpressure, and end-to-end wall time. They do not
replace the v4 release performance gate.

## Integrity and artifacts

The capture used source commit
`ec141c0e99155f47b00f675144fa70eb07459ecb` and source-tree identity
`fe0a03af4ff5bcdba35bdf8beb31965aff7993caf244420f1a319bc46f98de4d`.
The contract SHA-256 is
`08aac234c7507172d5db8b398d3d65dfdf4d0e68d03a9d270386405b139f0fa1`;
the generated corpus artifact-set SHA-256 is
`b2ae781b4902fbc4db98280576dcaadd0461924ec3821ff51a364f5f8c256231`.
The full identity set, including metric/model/crop/runtime and every output
variant, is recorded in `quality-gate-report.json`.

- `quality-gate-contract-v1.json` is the exact gate contract used by the run.
- `corpus-manifest.json` inventories and hashes all generated source/reference
  frames without checking the raw frame payloads into Git.
- `capture-manifest.json` contains per-case output paths and timings for the P05
  baseline, v4 candidate, and four required ablations; the report records each
  output set's aggregate identity.
- `quality-gate-report.json` contains the per-clip metrics, aggregates,
  confidence interval, identities, and fail-closed gate decisions.
- `xcodebuild.log` records the successful Release test capture (one test, zero
  failures).
- `artifact-manifest.json` hashes the machine-generated evidence files.

To qualify M3 for release, rerun the unchanged contract against a locked,
camera-native high-resolution SDR corpus representing all seven cohorts and the
production-locked P06 runtime after eliminating the high-motion temporal
regression. End-to-end performance evidence remains a separate required gate.
