# Deterministic engine v4 evidence

The `v3-p05-baseline-2026-08-02` directory is the locked pre-v4 reference for
quality, engine time, end-to-end time, allocation pressure, and profiler hot
paths. It was captured in optimized Release mode on an Apple M4 Pro with no
recorded thermal or performance warning.

Recreate the baseline from the repository root with:

```sh
python3 script/v4/capture_baseline.py \
  --output /tmp/mirmir-v3-p05-baseline \
  --derived-data /tmp/mirmir-v3-p05-derived \
  --warmups 5 \
  --samples 10
```

Seal a completed evidence directory with:

```sh
python3 script/v4/finalize_evidence.py \
  --directory /tmp/mirmir-v3-p05-baseline
```

## Locked reference values

The engine corpus contains 40 cases spanning both supported NV12 ranges, both
P05 routes, and ten procedural spatial/temporal patterns. It includes source,
ideal reference, CPU, and Metal visible-plane bytes plus 120 signed difference
maps. Each timing route uses five warmups and ten measured samples.

| Gate | CPU | Metal |
| --- | ---: | ---: |
| Engine median | 8.339 ms | 2.068 ms |
| Engine p95 | 12.664 ms | 6.769 ms |
| End-to-end wall median | 282.350 ms | 79.184 ms |
| End-to-end wall p95 | 285.260 ms | 87.905 ms |
| Weighted quality error | 0.1125275033 | 0.1125881065 |
| Normalized baseline quality index | 100 | 100 |

The v4 release gate is therefore at most 80% of the matching median and p95
times, while the lower 95% paired-bootstrap confidence bound for quality must
be at least 105.

The end-to-end fixture is a locked three-frame H.264 asset scaled from 64×48 to
128×96. Its stage samples cover reader delivery, destination allocation,
backend processing, writer backpressure and append, writer finalization, output
validation, and atomic publication. CPU backend processing accounts for a
median 260.699 ms of the 282.350 ms wall time; Metal backend processing accounts
for 18.820 ms of the 79.184 ms wall time.

## Profiler and allocation evidence

`time-profiler-summary.json` is a privacy-safe export of 9,724 Mirmir CPU
samples. The raw system-wide Instruments bundle is deliberately retained only
locally because it contains device and unrelated-process identifiers; its tree
SHA-256 and byte count are recorded in the summary. The dominant P05 CPU work
is luma sampling and boundary resolution, structure-tensor analysis, and
floating spatial reconstruction. Selection/LUT decoding and copy/allocation
paths are separately aggregated.

`allocation-profile.json` records `malloc_zone_statistics` and
`proc_pid_rusage` deltas outside each timed frame interval. It establishes the
current allocation-pressure baseline without requiring privileged process
attachment. The first measured CPU growth event reserves 4 MiB and reaches a
770,048-byte resident/physical-footprint delta; steady-state medians are zero.

## Integrity and scope

`capture-manifest.json` hashes the capture tool and every generated baseline
artifact. `evidence-manifest.json` recursively hashes the complete evidence
set, including this documentation and the profiler summary. Hardware reports
and build logs exclude serial numbers, UUIDs, UDIDs, and destination device IDs.

The environment manifest records the complete working-tree status. The capture
commit is `d3a4de55c08391ea8a08c00beb766b5650dc9f58`; unrelated user-owned project
settings and `output/`, plus untracked v4 work not in target membership, made
the checkout dirty but did not replace the locked P05 runtime identities:
`ash-p05-cpu-reference-preview` and `ash-p05-metal-v3-preview`.

The ordinary Debug suite leaves both capture tests skipped. Its exhaustive ASH
checks certify all 512 states, strict counts 16/144/352, 36,864 affine one-bit
corrections, and all canonical two-bit rejections.
