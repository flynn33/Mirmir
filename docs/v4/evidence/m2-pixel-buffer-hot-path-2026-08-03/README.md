# M2 production pixel-buffer hot-path evidence

Captured 2026-08-03 on an Apple M4 Pro MacBook Pro (`Mac16,7`, arm64,
48 GiB), macOS 26.6 (25G72), Xcode 26.2 (17C52), and Apple Swift 6.2.3.
Both captures began and ended on AC power with nominal thermal state and low
power mode disabled. The harness also rejected a non-nominal thermal state or
enabled low-power mode before or after every warmup and measured iteration.

## Result

This report qualifies an incremental scaler-only optimization of the production
`FixedPointPixelBufferScalerV4.process` path. It does not close the full M2
milestone: fused ASH analysis/selection/reconstruction and the whole-engine
bounded pipeline remain subject to their own implementation and release gates.
Within this deliberately narrow identical scope, candidate median and p95 are
at most 80% of baseline on both CPU and Metal:

| Executor | Baseline median / p95 | Candidate median / p95 | Candidate / baseline |
|---|---:|---:|---:|
| CPU | 6.355292 / 9.275554 ms | 3.970084 / 5.343258 ms | 62.47% / 57.61% |
| Metal | 5.264563 / 6.598040 ms | 2.317125 / 2.698772 ms | 44.01% / 40.90% |

This is a 37.53% CPU-median, 42.39% CPU-p95, 55.99% Metal-median, and
59.10% Metal-p95 reduction. Every individual format/geometry case also passed
all four budgets. Across four independent baseline/candidate capture pairs,
the worst aggregate ratios were 62.47%, 62.38%, 44.01%, and 40.93%; the worst
individual-case ratios were 76.37%, 75.58%, 59.91%, and 60.58% for CPU median,
CPU p95, Metal median, and Metal p95, respectively.

CPU and Metal produced the same ordered SHA-256 digest of every visible stored
pixel byte on every warmup and measured frame:

- NV12 full range, arbitrary 512x288 -> 853x481:
  `2343ba64fa01b4dc50aaf72ab0718ea47d7e3ac399b8efaf375970c4bba7ba93`
- P010 video range, exact 3:2 512x288 -> 768x432:
  `3a04af52933190bd5ce47af8e5ffe69c36d52a7dfc67fe1485ac351eb917e61a`

## Identical-scope and fail-closed contract

The baseline is revision `54d97e3`, immediately before the prepared/direct
production-path integration. Both binaries were compiled by the checked-in
runner with `-O -whole-module-optimization`, warnings as errors, complete
strict concurrency, and a real `-O3` Metal library. Each route performs five
warmups and 15 measured frames per executor.

The timed boundary includes the entire production scaler `process` call and
the ordered cryptographic digest. It therefore includes pixel-layout and
stored-code validation, CVPixelBuffer locking, direct spatial execution,
attachment/HDR migration, and reading every visible output byte. It excludes
only scaler construction and preparation, reusable CPU/Metal allocation,
pixel-buffer allocation, and deterministic source fill.

The evaluator locks the exact scope, timing boundary, two ordered route IDs,
storage formats, dimensions, reflect-101 border rule, input seed, warmup and
sample counts, and canonical output digests. It also fails closed unless both
captures have the same machine, OS, Metal device, power envelope, compiler,
flags, benchmark source, runner source, and Metal library. It validates the
complete ordered nine-file engine manifest and recomputes it authoritatively:
baseline bytes come from `git show 54d97e3:<path>` and candidate bytes come
from the current repository files. It requires different
baseline/candidate engine and executable identities, checks every raw timing is
finite and positive, recomputes all case and aggregate percentiles from raw
samples, and applies the 0.80 gate to every case and aggregate metric.

Locked identities for the representative pair are:

- benchmark harness:
  `6686abe82b7cb32bdca81010aca31ed1a28a866e94c260cd4d0364e94aeb2e1c`
- benchmark runner:
  `f22f1efbd58dd111a3af74b5c43d2265122d2ac5c0534b5ad2db86498a8e1754`
- evaluator:
  `ffa24010d7589cfd0ea1680a1955d73f345552317f58edb67d04393f7cdec888`
- four-pair verifier:
  `766ca8e2e2887cb5d4b971e84ff49c04363f6e1f8c3b9b506c1f625d7f304f7e`
- baseline engine manifest aggregate:
  `620c6b50ba6abc86dc6ae4b3305b38231909b06050ff24de77fe1d5985687f6d`
- candidate engine manifest aggregate:
  `cb40fa450fcf4de02a9a37fc165019adc7521d77ab6f3a788f24c74c51c77d9e`
- baseline executable:
  `c571eca19031dd042119a9073ed9c9fad88c449ad5a58e2469c9eb347ec701bd`
- candidate executable:
  `be1e77e67f28b9ef012cc1f0455902349b6f2f47d12415ca079919aa12659519`
- shared Metal library:
  `d3c5871d7858c801ab91aa41f51404974f691e87a702bccc47adc1ab17406d90`

## Implementation boundary

- Each luma/chroma plan, Q14 coefficient IR, border-resolved prepared scale,
  and CPU four-row workspace is created before the first frame. CPU
  intermediate storage is bounded to `4 * targetPlaneWidth` Int64 samples per
  plane and retains the same allocation identity across frames.
- CPU validates source codes once and then reads/writes the caller-locked
  interleaved NV12/P010 planes directly. It creates no source, destination, or
  full-height intermediate Swift array and preserves the canonical ordered
  Q14 then Q28 ties-to-even reduction. Direct transfers reject any code range
  and stored-code shift that cannot fit the component's one- or two-byte
  representation before reading or mutating either plane.
- Metal creates its command queue, pipeline, immutable plan/coefficient
  buffers, uniforms, and three source/output buffer pairs once. Luma/U/V are
  transferred directly, encoded in one command buffer and one completion
  wait, and written directly back. The 21 retained buffer identities and one
  pipeline identity remain stable across frames; retained planar storage is
  bounded to the prepared source/output geometry. Every component descriptor
  is validated in a complete first pass before a second pass uploads any
  retained input, so a malformed later descriptor leaves every prepared input
  and caller destination unchanged.
- Before CPU mutation or Metal upload, the scaler compares every source-plane
  span with every destination-plane span. It therefore rejects same-plane and
  cross-plane shared backing even when distinct CVPixelBuffer wrappers expose
  it. Raw transfers repeat the same-plane check defensively. Row-span
  multiplication and address addition are overflow checked before conversion
  or pointer arithmetic.
- The scaler serializes reusable state, checks cancellation again after
  acquiring its execution lock, validates all source codes before the first
  destination write, touches visible samples only, and retains existing
  attachment/HDR migration. Cancellation is frame-boundary deterministic:
  once visible mutation starts, that frame completes; cancellation is
  observed before a following frame begins. The diagnostics report prepared
  buffer topology and absence of full-plane Swift-array staging; they are not a
  process-wide malloc trace for command objects or attachment dictionaries.

The 24 focused kernel, Metal-executor, and pixel-buffer-scaler tests passed.
They cover exact scalar-oracle pixels, arbitrary dimensions, both NV12 and
P010 ranges, CPU/Metal byte parity, stable preparation/allocation identities,
zero full-plane Swift-array staging, bounded Metal retention, untouched row
padding, all-plane shared-backing overlap/span-overflow rejection,
unrepresentable stored-code rejection, transactional Metal batch validation,
and fail-before-mutation malformed P010 input. Selected integration suites for
alpha/64ARGB, ASH measurement,
temporal reconstruction/checkpointing, interlaced resume, and deterministic
CPU/Metal P06 routes also passed; the opt-in baseline-capture test remained
skipped as designed.

This evidence qualifies the incremental fixed-point pixel-buffer scaler hot
path. It does not close M2. The separate whole-engine gate remains authoritative
for decode, measurement, state-conditioned reconstruction, temporal processing,
bounded fusion, and encode timing.

## Reproduction

Run the current candidate capture from the repository root:

```sh
script/v4/run_pixel_buffer_scaler_hot_path_benchmark.sh > /tmp/candidate.json
```

Recreate the identical-scope baseline and evaluate every 0.80 gate:

```sh
baseline_root="$(mktemp -d /tmp/mirmir-m2-baseline.XXXXXX)"
git archive --format=tar 54d97e3 | tar -xf - -C "$baseline_root"
script/v4/run_pixel_buffer_scaler_hot_path_benchmark.sh "$baseline_root" \
  > /tmp/baseline.json
script/v4/evaluate_pixel_buffer_scaler_hot_path.py \
  /tmp/baseline.json /tmp/candidate.json
```

Replay all four checked-in raw pairs, byte-compare every stored evaluation,
validate every raw/evaluation hash, and recompute the worst ratios:

```sh
script/v4/verify_pixel_buffer_scaler_hot_path_repeatability.py
```

Run the evaluator's adversarial contract tests:

```sh
script/v4/test_pixel_buffer_scaler_hot_path.py
```

Run correctness and reuse validation:

```sh
xcodebuild test -project Mirmir.xcodeproj -scheme Mirmir \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/mirmir-m2-hot-path-tests \
  -only-testing:MirmirTests/FixedPointKernelV4Tests \
  -only-testing:MirmirTests/FixedPointMetalExecutorV4Tests \
  -only-testing:MirmirTests/FixedPointPixelBufferScalerV4Tests \
  CODE_SIGNING_ALLOWED=NO
```

All four raw baseline/candidate pairs and all four evaluations are checked in.
Pair 1 uses `baseline-54d97e3.json`, `prepared-direct-after.json`, and
`evaluation.json`; pairs 2 through 4 use the corresponding `-pair-02` through
`-pair-04` names. `repeatability.json` identifies and hashes every artifact and
is accepted only when the verifier reproduces it exactly.
