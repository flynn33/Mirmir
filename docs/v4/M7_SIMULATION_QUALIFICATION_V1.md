# Deterministic engine v4 M7 simulation qualification

M7 is a deterministic, simulator-only candidate comparison. It does not require
an Apple Simulator destination, an external device, a signed archive,
notarization, stapling, shipping, distribution, or a physical-machine support
matrix. Mirmir is a macOS application, so “simulator” here means the headless
XCTest frame simulator that feeds reproducible pixel buffers through the real
Swift engine implementations.

## Candidate set

The locked comparison evaluates the production v4 policy and four deterministic
test-harness policy ablations against the frozen P05 baseline:

1. `candidate_v4` — complete production policy;
2. `uniform_priors`;
3. `randomized_state_message` with its locked deterministic seed;
4. `temporal_hysteresis_off`;
5. `motion_history_off`.

The P05 result is a baseline, not a selectable candidate.
The four ablations are controlled model-selection policies, not packaged product
artifacts. Packaging is outside M7.

## Eligibility and selection

A candidate is eligible only when the same simulation run establishes:

- quality index at least 105;
- paired-bootstrap 95% quality lower bound at least 105;
- total, median, and p95 processing-time ratios no greater than 0.80 of P05.

Eligible candidates are ordered by the conservative quality lower bound, then
quality point estimate, total processing time, p95 time, median time, and stable
candidate identifier. This makes “best” deterministic and prioritizes proven
quality after every candidate has already cleared the processing-time target.

The machine-readable authority is
`script/v4/m7-simulation-selection-contract-v1.json`. The selector independently
replays the sealed quality evidence before computing every candidate’s
confidence interval, ratios, eligibility, rank, and winner.

## Execution

Run from a clean committed checkout:

```sh
script/v4/run_m7_simulation_v4.sh \
  --output /path/to/new-m7-simulation-evidence
```

The frozen P05 source revision, source tree, manifest, and capture source remain
immutable. Before the scored run, the runner builds that source once to discover
the active toolchain’s application and test-executable hashes, derives a
run-specific contract that changes only those two hashes, then rebuilds P05 and
requires exact reproduction. This prevents compiler or build-path differences
from changing the algorithmic baseline silently. The `M7 simulator
qualification` GitHub workflow offers Xcode 26.2 (17C52); local runs may use a
different recorded toolchain under the same source-identity rule.

Every policy receives five warm-up frames. Measured policy order is a locked
left rotation by sorted-case ordinal, distributing each policy across timing
positions instead of always running one policy first. The evidence records the
toolchain, OS, architecture, canonical capture-source hash, injected-source
hash, deterministic injection values, and both canonical and run-specific P05
contract identities.

The output is refused if it already exists, and a caller-provided DerivedData
directory must be absent or empty. The runner generates the synthetic
corpus, builds and executes the frozen P05 baseline separately, exercises the
five current candidates through the real Swift implementation in Release mode,
replays the quality report, selects the winner, and seals the evidence tree.

Even a no-winner result is sealed with every candidate’s metrics and failure
reason before the runner returns nonzero. M7 is satisfied when the independently reproduced selection report has
`m7Satisfied: true` and names exactly one selected candidate. Packaging and
shipment remain separate owner decisions and are not implied by this result.
