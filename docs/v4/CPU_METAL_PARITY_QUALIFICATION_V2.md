# Deterministic engine v4 CPU/Metal parity qualification v2

> This packaged parity lane is retained as optional release evidence. It is not
> an M7 gate under the simulator-only scope adopted September 21, 2026.

`script/v4/run_cpu_metal_parity_v4.sh` is a fail-closed release gate for exact
CPU/Metal equivalence. The final lane launches the exact packaged application
archive twice with independent requests, binds both captures to the candidate
identity and P06 runtime, and then recomputes the complete evidence tree. Test
injection and a dirty working tree are not accepted as release evidence.

The evaluator owns 34 non-waivable coverage labels. In addition to NV12,
P010, HDR attachments, alpha, odd and padded layouts, arbitrary rational
phases, temporal reconstruction, interlacing, cadence, timing, attachments,
checkpoint/restore, repeats, and independent processes, the matrix contains a
dedicated bounded-tile temporal case and a separate periodic ambiguous-texture
case:

- source raster: 16x12;
- target raster: 32x24;
- tile policy: 8x8 active tile, halo 5, maximum raster 64x64;
- source grid: 2x2, four tiles;
- target grid: 4x3, twelve tiles; and
- declared seek reset: input ordinal 3 of a five-frame temporal sequence; and
- checkpoint boundaries: input ordinals 1 and 3, proving uninterrupted and
  resumed identity both before and after the seek.

The 8x6 to 15x11 periodic case alternates two phase-shifted two-dimensional
stripe patterns over four frames. It prevents a matrix that covers only unique
motion edges from standing in for the roadmap's repeated-pattern temporal row.
Its uninterrupted and resumed outputs must retain one history generation with
no seek reset.

The forced case cannot fall back to the contiguous path. Its prepared engine
must report `usesBoundedTiledTemporalPath`, the exact policy, both multi-tile
grids, and this immutable allocation contract:

- source full-frame sample count 192 and source tile count 4;
- target full-frame sample count 768 and target tile count 12;
- maximum retained tile allocation 324 samples;
- maximum output tile allocation 64 samples; and
- full-frame Swift sample-array allocation cap 0.

Every CPU and Metal run emits five separately sealed artifacts:

- tightly packed visible-plane bytes with deterministic layout headers;
- canonical, recursively typed attachment and exact CMTime semantics;
- every raw canonical temporal checkpoint;
- uninterrupted/resumed suffix pixels, semantics, and final checkpoints; and
- execution evidence binding backend, spatial schedule, temporal schedule,
  checkpoint identities, tile grids, policy, and allocation diagnostics.

The forced case emits only
`ash.prepared-tiled-temporal-checkpoint.v4.1`. The evaluator parses the raw
checkpoint rather than trusting the execution label. It reconstructs every
tile descriptor and retained rectangle, checks retained sample counts, source
and target grid geometry, history generation, measurement state, policy,
schema, and final resumed checkpoint. The checkpoint hashes in the execution
artifact are recomputed from the raw checkpoint-set bytes.

The seek input is passed through the production `FrameTiming` boundary and its
typed `seek` reset is serialized in the canonical semantic artifact. The
evaluator requires that declared reset, rejects an undeclared seek, and checks
the resulting generation transition in the raw tiled checkpoint. This makes
seek behavior release-observable rather than relying on a debug-only hook.

Canonical and repeat runs use spatial `production_full_frame` with temporal
`raster`. Qualification schedules are paired exactly:

| Spatial schedule | Temporal tile schedule |
| --- | --- |
| `row_major` | `raster` |
| `reverse` | `reverse_raster` |
| `even_then_odd` | `even_then_odd` |

Visible bytes, semantics, raw checkpoints, and resume artifacts must be
byte-identical across CPU and Metal, repeat execution, all three schedule
pairs, and both packaged processes. Execution artifacts are separately
validated against their expected backend and schedule and must repeat exactly
across processes. No tolerance or self-authored pass boolean can satisfy the
gate.

## Final qualification

Run only after the archive, P06 bundle, release configuration, candidate
identity, packaged observer, contract, evaluator, and runner are committed
together:

```sh
script/v4/run_cpu_metal_parity_v4.sh \
  --output /path/to/new-m7-parity-evidence \
  --candidate-identity /path/to/candidate-identity.json \
  --application-archive /path/to/Mirmir.zip \
  --runtime /path/to/ASH-P06.bundle \
  --release-configuration /path/to/Release.xcconfig
```

The output contains two packaged-process directories, sealed tools,
`candidate-identity.json`, `cpu-metal-parity-report.json`, and the recursive
`artifact-manifest.json`. The report schema is
`mirmir-ash-v4-cpu-metal-parity-report-v2`.

The gate verifies candidate membership for every executable lane component,
the exact tool hashes in the v2 contract, independent packaged request IDs,
the raw captures, and both recursive manifests. A handcrafted or fully
rehashed report cannot replace the underlying evidence.

## Focused verification

The Release capture harness is
`script/v4/ParityQualificationCaptureTests.swift`. It exercises the same
production prepared-engine route in an isolated test build; it is useful for
implementation qualification but does not replace packaged-candidate
evidence. Run evaluator and release tamper suites with:

```sh
python3 script/v4/test_cpu_metal_parity_v4.py
python3 script/v4/test_release_qualification_v4.py
```
