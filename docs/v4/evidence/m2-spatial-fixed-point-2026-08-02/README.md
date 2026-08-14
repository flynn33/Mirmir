# M2 prepared fixed-point spatial kernel evidence

Captured 2026-08-02 on Apple silicon (`arm64`), macOS 26.6 (25G72),
Xcode 26.2 (17C52), and Apple Swift 6.2.3.

## Result

The prepared CPU and batched Metal paths preserve every locked output checksum
and are byte-identical across all measured frames. The final representative run
measured:

| Path | Committed before median / p95 | Prepared after median / p95 | After / before |
|---|---:|---:|---:|
| CPU | 0.029958 / 0.0385048 ms | 0.0046045 / 0.00660685 ms | 15.37% / 17.16% |
| Metal | 0.62025 / 1.3072274 ms | 0.2119795 / 0.2243208 ms | 34.18% / 17.16% |

That is an 84.63% CPU-median, 82.84% CPU-p95, 65.82% Metal-median,
and 82.84% Metal-p95 reduction against the committed fixed-kernel path.
Across four clean runs of the release-locked source, the worst observed
after/before ratios were 15.58%, 19.04%, 34.89%, and 17.96%, respectively.
These are same-scope prepared-kernel improvements; they do not close the
roadmap's complete-engine M2 exit gate.

For budget orientation only, dividing by the locked P05 whole-engine spatial
numbers yields 0.055% / 0.052% for CPU and 10.25% / 3.31% for Metal. That is a
non-comparable cross-scope reference: it cannot establish the complete-engine
target or replace an identical-condition engine integration benchmark covering
analysis, selection, reconstruction, decode, and encode.

## Locked workload

- Input: the 288-byte `radial_detail` NV12 fixture from the P05 baseline.
- Input SHA-256:
  `87dc513caa392105a02425704e15b9fbd0fa81f92c1a552daa37550822225024`.
- Routes: 420f and 420v at exact 2x and exact 3/2.
- Work per frame: luma plus deinterleaved U and V planes.
- Sampling: five warmups and ten measured frames for each route.
- Build: `swiftc -O -whole-module-optimization -warnings-as-errors
  -strict-concurrency=complete`; Metal uses `-O3` and Metal 3.2.
- Timed work includes every per-frame source upload, CPU execution, Metal
  dispatch/completion wait, output copy, and checksum. It excludes one-time
  scale/IR preparation, immutable coefficient upload, and reusable allocation.

The committed-before capture was taken from `bd2db59` immediately before the
hot-path changes, with the same fixture, planes, routes, warmups, sample count,
compiler optimization, real Metal shader, and percentile calculation. That
path had no reusable preparation API, so its per-call validation, coefficient
table construction, intermediate allocation, and Metal plan/buffer setup are
part of the steady-state frame cost.

## Implementation boundary

- CPU resolves kernel selection and border indices once, writes directly into
  caller storage, and reuses a flat four-row separable cache bounded to
  `4 * targetWidth` samples. Ordered Q14 then Q28 reductions retain the original
  single ties-to-even rounding and clamp.
- Metal retains immutable plan buffers and source/output buffers, accepts
  caller-owned planes, and batches luma/U/V into one command buffer and one
  completion wait. Batch and individual prepared execution are serialized to
  make buffer reuse race-free.
- Compatibility entry points remain available and delegate through the same
  canonical prepared representation.
- The P06 phase/coefficient artifact locks the exact CPU kernel, Metal shader,
  and prepared Metal executor source identities; semantic self-test plan SHA-256
  is `32b6a21c59f126db7bacbeac1775d8ba9924bce507d7466c8fe8a4d8978ed08d`.

No image-quality algorithm was changed in this slice: the four output checksums
remain `153143`, `86154`, `153145`, and `86175`; CPU and Metal matched on every
warmup and measured frame. The broader v4 quality-improvement target must be
measured at the complete ASH reconstruction boundary.

## Reproduction and validation

Run from the repository root:

```sh
script/v4/run_fixed_point_spatial_benchmark.sh
```

The runner fails closed if the fixture hash changes and emits the complete JSON
document to standard output. The captured artifacts are:

- `committed-before.json`: exact pre-edit raw samples.
- `prepared-after.json`: representative prepared/batched run and all ratios.
- `repeatability.json`: aggregate measurements from four clean runs.

Correctness validation:

```sh
xcodebuild test -project Mirmir.xcodeproj -scheme Mirmir \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/mirmir-m2-derived \
  -only-testing:MirmirTests/FixedPointKernelV4Tests \
  -only-testing:MirmirTests/FixedPointMetalExecutorV4Tests \
  CODE_SIGNING_ALLOWED=NO
```

Twelve tests passed: independent scalar-oracle and adversarial CPU cases,
destination overlap/layout rejection, arbitrary-scale CPU/Metal parity,
prepared repeatability, concurrent-source serialization, direct destination
preservation, and three-plane batched dispatch parity.
