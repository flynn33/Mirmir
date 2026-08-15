# Deterministic engine v4 performance qualification

`script/v4/run_performance_gate_v4.sh` is the fail-closed qualification for
the version 4 processing-time target. It compares the frozen P05 source at
`d3a4de55c08391ea8a08c00beb766b5650dc9f58` with one committed P06 candidate.
Both lanes use the same locked three-frame input, output request, Release build,
machine, power state, semantic verification, five warmups, and ten ordered
measurements per mandatory backend and scale class.

The measured matrix is CPU and Metal at exact 2x and 3/2 scaling. The
end-to-end timer includes probe, verified runtime preparation, decode, frame
processing, encode, writer finalization, application validation, independent
track verification, and decoded visible-pixel hashing. Raw engine-frame and
end-to-end arrays remain in the sealed evidence so the release aggregator can
recompute every statistic.

A release passes only when all three paired metrics meet the target:

- candidate aggregate-corpus wall median / P05 median is at most `0.80`;
- candidate engine-frame median / P05 median is at most `0.80`;
- candidate engine-frame p95 / P05 p95 is at most `0.80`; and
- the deterministic 95% paired-bootstrap upper bound is at most `0.80` for
  each metric.

The candidate must also use the release-qualified
`ash-p06-deterministic-v4` bundle with code-owned trust roots, preserve all
required output semantics on every run, remain within the declared temporal
history memory allowance, and hold hardware, software, power, and thermal
conditions constant. Missing or unsealed files, altered identities, fallback,
unstable pixels, and incomplete samples are rejected.

Run the final qualification only against the committed P06 release candidate:

```sh
script/v4/run_performance_gate_v4.sh \
  --output /path/to/release-evidence/same_scope_performance \
  --candidate /path/to/candidate-identity.json \
  --application-archive /path/to/Mirmir-sealed.zip \
  --runtime <repository>/Mirmir/Resources/ASH-P06.bundle \
  --release-configuration \
    <repository>/script/v4/release-candidate-v4.xcconfig \
  --warmups 5 \
  --samples 10
```

The runner writes `baseline/` and `candidate/` raw captures, the locked
contract, `performance-gate-report.json`, nested artifact seals, and a recursive
root evidence seal. It never benchmarks the dirty working tree.

## Frozen-lane execution proof

An exact-revision P05 diagnostic capture completed on 2026-08-02 with all four
cases, five warmups, ten measured end-to-end runs per case, thirty timed engine
frames per case, stable decoded-pixel and semantic-track hashes, and every
semantic check passing. Its aggregate four-case wall median was `838.649 ms`;
the flattened engine-frame median was `52.916 ms` and p95 was `95.216 ms`.
Peak resident memory was `132.36 MiB`.

These numbers establish executable baseline behavior but are not a release
decision. The sealed paired run must be repeated on the final P06 commit so the
candidate and baseline share the exact recorded environment.
