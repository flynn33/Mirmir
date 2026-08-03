# Deterministic engine v4 evidence

The `v3-p05-baseline-2026-08-02` directory is the locked pre-v4 M0 reference
for quality, engine time, end-to-end time, and allocation pressure. The checked
evidence was recaptured in optimized Release mode from a clean `git archive` of
commit `d3a4de55c08391ea8a08c00beb766b5650dc9f58`; no candidate-tree source was
present in the build root.

Recreate the baseline from the repository root. Both output paths must be
absent before the command starts:

```sh
python3 script/v4/capture_baseline.py \
  --repository "$PWD" \
  --output /tmp/mirmir-v3-p05-baseline \
  --derived-data /tmp/mirmir-v3-p05-derived \
  --warmups 5 \
  --samples 10
```

Verify the checked evidence and all nested seals with:

```sh
python3 script/v4/capture_baseline.py \
  --verify-existing docs/v4/evidence/v3-p05-baseline-2026-08-02
```

## Locked reference values

The engine corpus contains 40 cases spanning both supported NV12 ranges, both
P05 routes, and ten procedural spatial/temporal patterns. It includes source,
ideal reference, CPU, and Metal visible-plane bytes plus 120 signed difference
maps. Each timing route uses five warmups and ten measured samples.

| Observation | CPU | Metal |
| --- | ---: | ---: |
| Engine median | 9.663 ms | 2.653 ms |
| Engine p95 | 12.300 ms | 6.737 ms |
| End-to-end wall median | 308.948 ms | 81.265 ms |
| End-to-end wall p95 | 311.208 ms | 82.715 ms |
| Weighted quality error | 0.1125275033 | 0.1125881065 |
| Normalized baseline quality index | 100 | 100 |

The end-to-end fixture is a three-frame H.264 asset scaled from 64×48 to
128×96. Its stage samples cover reader delivery, destination allocation,
backend processing, writer backpressure and append, writer finalization,
output validation, and atomic publication. CPU backend processing accounts for
a median 283.815 ms of the 308.948 ms wall time; Metal backend processing
accounts for 17.237 ms of the 81.265 ms wall time.

These values document M0. Release qualification uses the separately captured
and sealed P05/reference/candidate planes defined by the v4 quality and
performance contracts.

## Allocation evidence

`allocation-profile.json` records `malloc_zone_statistics` and
`proc_pid_rusage` deltas outside each timed frame interval. Steady-state median
resident and physical-footprint deltas are zero for both backends. The largest
measured CPU deltas are 81,392 bytes in use, 98,304 resident bytes, and 49,176
physical-footprint bytes; the largest measured Metal deltas are 480,
16,384, and 0 bytes respectively.

The prior profiler summary was removed from this baseline. It was produced
outside the clean-archive capture and had no closed source/build/tool binding,
so it is not admissible evidence for the locked M0 identity.

## Integrity and scope

`source-manifest.json` binds all 397 files in the frozen tree. Its canonical
source-tree identity is
`d9b89f1ca31c0d076826651b250459773bea0de11d7b0ffd12ac40451af7b69c`,
and its manifest SHA-256 is
`880609bc2b4460814c63f2963042bee4fdb562eaa0b6376f84eb6aeb6a73ee69`.
`environment.json` records `clean-git-archive` and an empty working-tree status.

`build-identity.json` seals the exact Release command template and the captured
application and XCTest executable identities. `tool-identities.json` binds
self-contained copies of the capture and source-identity tools plus the host
Python, NumPy, Git, tar, and Xcode build tools. `corpus-manifest.json` binds all
81 source/reference/end-to-end corpus artifacts.

`capture-manifest.json` hashes the 297 pre-seal artifacts and binds the source,
build, tool, and corpus identities. `evidence-manifest.json` recursively closes
the final 298-file evidence set. The verifier rejects symbolic links, path
escapes, missing or extra files, altered artifact bytes, dirty-source claims,
and any identity mismatch. Hardware reports and build logs exclude serial
numbers, UUIDs, UDIDs, and destination device IDs.

The ordinary Debug suite leaves both legacy capture tests skipped. Its
exhaustive ASH checks certify all 512 states, strict counts 16/144/352, 36,864
affine one-bit corrections, and all canonical two-bit rejections.
