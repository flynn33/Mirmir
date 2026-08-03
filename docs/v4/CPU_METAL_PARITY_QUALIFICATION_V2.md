# Deterministic engine v4 CPU/Metal parity qualification v2

`script/v4/run_cpu_metal_parity_v4.sh` is the fail-closed M7 gate for exact
CPU/Metal equivalence. It archives one committed candidate, injects the locked
capture only into an ephemeral checkout, builds Release tests, and captures the
same matrix in two independent test processes. The dirty working tree is never
treated as the candidate.

The evaluator-owned matrix contains 28 non-waivable coverage labels. It covers
NV12 video/full range; P010 video/full range; PQ/HLG static and dynamic HDR
attachments; straight BGRA8 and premultiplied big-endian ARGB16 alpha; odd and
padded layouts; arbitrary rational phases; progressive temporal history,
resets, and scene cuts; TFF/BFF double-rate reconstruction; combing, telecine,
cadence and dominance transitions; interlaced scene cuts; exact timing and
recursive attachment semantics; progressive field-attachment normalization;
raw checkpoint/restore; repeat execution; two processes; and three real
execution schedules (`row_major`, `reverse`, and `even_then_odd`).

Each CPU and Metal run emits four separately sealed artifacts:

- tightly packed visible-plane bytes with deterministic layout headers;
- canonical, recursively typed attachment and exact CMTime semantics;
- every raw canonical `ash.prepared-temporal-checkpoint.v4.5` state; and
- uninterrupted/resumed suffix pixels, semantics, and final checkpoint bytes.

Canonical, repeat, and all schedule runs use distinct paths and must contain
identical bytes. CPU and Metal must match for all four artifact classes, and
capture A must match capture B. The evaluator parses checkpoint internals and
recomputes input/output ordinals, history generation, cadence, dominance,
field order, timing, attachment normalization, and checkpoint-resume identity.
No tolerance or unverified pass boolean can satisfy the gate.

## Fixture smoke

```sh
script/v4/run_cpu_metal_parity_v4.sh \
  --output /path/to/new-parity-smoke-evidence \
  --smoke
```

Fixture reports always set `releaseEligible` and `byteParityGatePass` to
`false`, even when every comparison succeeds.

## Final qualification

Run after the P06 bundle, code trust root, candidate identity, and all four
parity tools are committed together:

```sh
script/v4/run_cpu_metal_parity_v4.sh \
  --candidate-revision <full-commit> \
  --candidate-identity /path/to/candidate-identity.json \
  --output /path/to/new-m7-parity-evidence
```

The output contains `capture-a/`, `capture-b/`, `sealed-tools/`, Release build
logs, `candidate-identity.json`, `cpu-metal-parity-report.json`, and the
recursive `artifact-manifest.json`. The report schema is
`mirmir-ash-v4-cpu-metal-parity-report-v2`.

M7 release qualification requires the exact v2 contract hash and capture,
evaluator, and runner hashes. It replays the recursive manifest and invokes the
repository-locked parity evaluator over both raw captures; a handcrafted or
resealed report cannot substitute for the underlying evidence.

Run the evaluator and M7 tamper suites with:

```sh
python3 script/v4/test_cpu_metal_parity_v4.py
python3 script/v4/test_release_qualification_v4.py
```
