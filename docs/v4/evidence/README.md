# Deterministic engine v4 evidence

For the current 1.3.0 (3) implementation and completed M7 simulator selection,
see
[`../CURRENT_QUALIFICATION_STATUS.md`](../CURRENT_QUALIFICATION_STATUS.md).

The `m7-simulation-selection-2026-09-21` directory is the current, sealed M7
decision from source commit
`ce780af87107d90142d860f328dca4a72fea3047`. Its independently replayed report
selects `candidate_v4` after all five candidates clear the locked 5% quality
and 20% processing-time thresholds. Its README contains the complete ranking;
`artifact-manifest.json` seals every raw plane, log, contract, binding, and
report used by the decision.

The other checked directories below are historical milestone evidence and
must not be mistaken for the fresh M7 simulator decision.

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
| Engine median | 8.393 ms | 2.045 ms |
| Engine p95 | 11.088 ms | 6.775 ms |
| End-to-end wall median | 292.161 ms | 75.228 ms |
| End-to-end wall p95 | 301.344 ms | 84.692 ms |
| Weighted quality error | 0.1125275033 | 0.1125881065 |
| Normalized baseline quality index | 100 | 100 |

The end-to-end fixture is a three-frame H.264 asset scaled from 64×48 to
128×96. Its stage samples cover reader delivery, destination allocation,
backend processing, writer backpressure and append, writer finalization,
output validation, and atomic publication. CPU backend processing accounts for
a median 269.405 ms of the 292.161 ms wall time; Metal backend processing
accounts for 14.086 ms of the 75.228 ms wall time.

These values document M0. The revised M7 decision uses the separately captured
and sealed P05/reference/candidate planes in
`m7-simulation-selection-2026-09-21`.

## Allocation evidence

`allocation-profile.json` records `malloc_zone_statistics` and
`proc_pid_rusage` deltas outside each timed frame interval. Steady-state median
resident and physical-footprint deltas are zero for both backends. The largest
measured CPU deltas are 78,944 bytes in use, 81,920 resident bytes, and 65,536
physical-footprint bytes; the largest measured Metal deltas are 4,192, 16,384,
and 16,384 bytes respectively.

`time-profiler.trace.json` is an exhaustive, privacy-safe symbolic export from
an `xctrace` Time Profiler recording attached to the exact frozen Release test
host. It contains 5,597 one-millisecond samples, 2,158 deduplicated frames, and
1,241 deduplicated stacks. Stack-attributed categories identify 5,234 ASH or
kernel samples, 472 copy/buffer samples, 122 decode samples, 777 encode samples,
and 5,240 samples with an allocation frame; categories overlap by design. The
largest self-time observations are luma sampling (1,024 ms), boundary indexing
(714 ms), Swift bridge-object release (420 ms), luma normalization (379 ms),
and chroma normalization (180 ms). The captured call stacks include the reader,
destination allocation, CPU reconstruction, writer append/finalization, and
atomic publication boundaries.

`allocations.trace.txt` is a live `malloc_history` high-water call tree from a
second execution of the same two selected tests. A sealed derived launch scheme
enables stack logging for that hosted process. At capture it records a 41.5 MB
heap-plus-VM high-water mark, 621.7 MB cumulative allocation traffic, 6,339,152
operations, and a 177.6 MB peak physical footprint. Its call tree identifies
the 2.50 MB source-dispatch construction and 1.25 MB source-site packing
allocations alongside Metal runtime preparation and video-session allocations.

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
Python, NumPy, Git, tar, Xcode build, `xcrun`, `xctrace`, `malloc_history`, and
`ps` tools. `corpus-manifest.json` binds all 81
source/reference/end-to-end corpus artifacts. `profiler-manifest.json` binds
both profiler commands, their successful runner and target exits, the derived
allocation launch scheme, all five profiler artifacts, and the same frozen
source, executable, and host-tool identities.

`capture-manifest.json` hashes the 303 pre-seal artifacts and binds the source,
build, tool, corpus, and profiler identities. `evidence-manifest.json`
recursively closes the final 304-file evidence set. The verifier rejects
symbolic links, path escapes, missing or extra files, altered artifact bytes,
dirty-source claims, substituted source/build/tool/profiler identities,
nonzero profiled-target exits, incomplete selected-test transcripts, and any
identity mismatch. Hardware reports and build logs exclude serial numbers,
UUIDs, UDIDs, and destination device IDs; profiler exports omit raw addresses,
PIDs, device identifiers, absolute work paths, and volatile timestamps.

The ordinary Debug suite leaves both legacy capture tests skipped. Its
exhaustive ASH checks certify all 512 states, strict counts 16/144/352, 36,864
affine one-bit corrections, and all canonical two-bit rejections.
