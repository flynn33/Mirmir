# Deterministic engine v4 CPU/Metal parity qualification

> Superseded by `CPU_METAL_PARITY_QUALIFICATION_V2.md`. This file describes
> the original visible-plane/attachment gate and is retained for history.

`script/v4/run_cpu_metal_parity_v4.sh` is the fail-closed M7 qualification for
byte-identical CPU and Metal output. It archives one committed candidate,
injects the locked capture test only into that ephemeral checkout, builds and
tests it in Release twice in independent processes, and evaluates the resulting
raw artifacts. The dirty working tree is never the candidate.

The locked matrix covers:

- NV12 video-range and full-range output;
- P010 video-range 10-bit HDR output;
- straight BGRA8 and premultiplied big-endian ARGB16 alpha;
- odd legal dimensions, padded source and destination strides, and arbitrary
  rational horizontal and vertical phases;
- multi-frame temporal history, reset, scene-cut behavior, and canonical
  temporal checkpoints; and
- repeat execution, independent-process execution, and row-major, reverse, and
  even/odd tile assembly schedules.

The capture runs the production `PreparedDeterministicV4Upscaler` CPU and Metal
paths for native NV12/P010 buffers and the production alpha scaler with the
same runtime-bound Metal library. Visible artifacts contain only tightly packed
active plane bytes plus deterministic layout headers, so allocator padding
cannot hide a mismatch. Source and destination padding counts and sentinel
preservation are recorded separately. Attachment artifacts are canonical JSON
for propagated Core Video metadata. Every capture has a complete nested file
seal, and the final evidence directory has a second recursive seal.

No tolerance, image metric, or precomputed pass boolean can satisfy this gate.
The evaluator reloads every declared artifact, rejects duplicate or non-finite
JSON, unsafe paths and symbolic links, recomputes all hashes and byte counts,
checks complete artifact sets, and directly compares primary, repeat, tiled,
CPU, Metal, and cross-process bytes. It also recomputes temporal generations
and history counts, reset and scene-cut relationships, rational phase counts,
and padding evidence.

## Fixture smoke

The fixture lane proves the harness and evaluator without making a release
claim:

```sh
script/v4/run_cpu_metal_parity_v4.sh \
  --output /path/to/new-parity-smoke-evidence \
  --smoke
```

Fixture reports always contain `releaseEligible: false` and
`byteParityGatePass: false`, even when every byte comparison succeeds.

## Final qualification

Run the final lane only after the release-qualified P06 bundle, code trust root,
parity harness, and candidate identity are committed together:

```sh
script/v4/run_cpu_metal_parity_v4.sh \
  --candidate-revision <full-P06-commit> \
  --candidate-identity /path/to/candidate-identity.json \
  --output /path/to/new-m7-parity-evidence
```

The candidate identity binds the source commit and tree, semantic and raw P06
manifest identities, runtime artifact set and source revision, Release
configuration, application bundle, bundle identifier, and product
version/build. Final execution fails before capture if the revision omits any
locked parity tool, differs from the executing tool bytes, omits the checked-in
P06 bundle, or retains an unconfigured code trust root. Production capture then
requires a release-qualified `ash-p06-deterministic-v4` runtime with a verified
binding and configured trust root.

The output includes `capture-a/`, `capture-b/`, Release build transcripts,
`sealed-tools/`, `candidate-identity.json`,
`cpu-metal-parity-report.json`, and `artifact-manifest.json`. The report schema
is `mirmir-ash-v4-cpu-metal-parity-report-v1`; its
`captureSourceSHA256`, `evaluatorSHA256`, and `runnerSHA256` identities and raw
case descriptors are the parity bindings consumed by the final release
aggregator. The runner refuses to overwrite a nonempty output directory.

Run the evaluator tamper suite independently with:

```sh
python3 script/v4/test_cpu_metal_parity_v4.py
```
