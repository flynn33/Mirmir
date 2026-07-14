# Mirmir ASH Local Work Plan

Baseline commit: `20dc1a9e8057d25b0430bfcd4c09e7806dc22d0a`

Remote boundary: local implementation and local commits only. No fetch, push, pull request, tag, release, history rewrite, remote edit, or Forsetti source edit.

## Phase checklist

- [x] P00 — Environment, scope, and baseline lock; pass G00.
- [x] P01 — Production call graph and telemetry; pass G01.
- [x] P02 — Metal completion, transactional cleanup, and route correctness; pass G02.
- [x] P03 — Canonical ASH packed-core conformance; pass G03.
- [ ] P04 — Native-HR benchmark, degradations, metrics, and corpus lock; fresh current-source G04 rerun required. Historical evidence: `Artifacts/ASH/20260711-p04-quality-63c9b988-7523-4578-a798-a5c3bfc734da/`.
- [ ] P05 — Spatial ASH v2 CPU mapping and direct reconstruction; fresh current-source G05 rerun required. Historical evidence: `Artifacts/ASH/20260711-p05-spatial-6c1cb01f-e25e-4c06-ae7f-4fc76bc6aa71/`.
- [ ] P06 — Calibration, branch compiler, route LUTs, and configuration lock; pass G06. The latest immutable G06 run failed because isolated pytest reported one skip: `Artifacts/ASH/20260713-p06-postrepair-8f0de437-3230-421e-8b25-464e2dbbe16e/g06/g06-postrepair-r1.failed/`.
- [ ] P07 — Locked holdout and causal ablations; pass G07.
- [ ] P08 — Metal production path, parity, performance, and memory; pass G08.
- [ ] P09 — Geometry, color, chroma, audio, provenance, and route capability; pass G09.
- [ ] P10 — Deterministic motion-aligned temporal ASH; pass G10.
- [ ] P11 — Xcode/CLI, soak, failure, profiling, and telemetry evidence; pass G11.
- [ ] P12 — Final audit, artifact manifest, local commits, and handoff; pass G12.

## Gate discipline

- Work in dependency order.
- Declare the owning module, files, contract, tests, and evidence before each edit.
- Preserve failed evidence; never relabel a failure as a pass.
- Re-run dependent gates after upstream contract changes.
- Commit only after the associated phase gate is green.
- Do not open the holdout before the configuration lock is complete.
- Do not claim completion unless every mandatory gate passes with hashed evidence.

## Evidence root

Each run is recorded under `Artifacts/ASH/` in a unique directory. Run directories are finalized atomically and never overwritten.

## Current-source execution sequence

```text
clean source checkpoint
→ fresh G04
→ fresh G05
→ fresh runtime artifact
→ fresh G06 plus enclosing immutable closure
→ P06 release
→ P07 preflight
```

G06 evidence requires a committed clean repository, while the phase discipline normally commits only after a green gate. The clean source checkpoint is therefore a prerequisite transaction boundary, not a G06 pass claim. Fresh evidence remains authoritative only for the exact committed source state it records.

## Recorded package conflict rule

The master directive and macOS/Xcode project scope control where lower-level platform labels conflict. See the P00 conflict record for exact discrepancies and their resolution.
