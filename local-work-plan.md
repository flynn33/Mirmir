# Preserved Mirmir ASH V3 Local Work Plan

> This plan is preserved as implementation and failure-evidence history. It is
> superseded as the forward product plan by the
> [Mirmir Apple-Native Adaptive Video Enhancement Roadmap 1.0.1](docs/roadmaps/Mirmir_Apple_Native_ASH_Roadmap_2026-07-18.md).
> Unchecked P04-P12 items below are not authorized merely because this historical
> plan remains in the repository. No tag or release is authorized.

## Current Roadmap Execution State

- Roadmap phase `R00`: `in_progress`. The accepted architecture decision and
  baseline current-source inventory are under implementation.
- Roadmap phase `R01`: `planned`. Capability work remains unauthorized until R00
  passes.
- R02 unified backend architecture: planned after R01 capability contracts.
- R03 deterministic Apple-native baselines: planned after R02.
- Production Auto, Core AI residual output, holdout access, market claims, and
  release publication: blocked by their roadmap gates.

## Historical ASH V3 Record

Baseline commit: `20dc1a9e8057d25b0430bfcd4c09e7806dc22d0a`

Merged V3 wiring: `47e9cef9d574ab03e7729c5f7125ec32e1484f6e`
through PR #7, merge commit
`85b5d4637797ca84ab2ca2721a3165f7a2f21e0c`

Release-closure branch: `ash-v3-release-closure`

Release-closure starting commit:
`25d4394da46595e3965c49edafe4cce8174df7f2`

The final clean source checkpoint is assigned only after all current code,
schemas, tests, project metadata, documentation, and quality-harness locks are
committed. Gate evidence must name that later exact commit; the starting commit
above is not a substitute.

## Platform Boundary

The product remains Apple-native Swift/SwiftUI/AVFoundation/CoreVideo/Metal/
VideoToolbox. Python is offline validation, calibration, evidence, and test
tooling only; it is not linked into `Mirmir.app`.

No tag or GitHub release is authorized by this plan. Gate artifacts are written
under `Artifacts/ASH/` and remain distinct from tracked source.

## Phase Checklist

- [x] P00 — Environment, scope, and baseline lock; historical G00 complete.
- [x] P01 — Production call graph and telemetry; historical G01 complete.
- [x] P02 — Metal completion, transactional cleanup, and route correctness;
  historical G02 complete.
- [x] P03 — Canonical ASH packed-core conformance; historical G03 complete.
- [ ] P04 — Execute fresh current-source quality closure and G04.
- [ ] P05 — Execute fresh current-source spatial CPU closure and G05.
- [ ] P06 — Use the sole authorizing
  `run_p06_production_calibration_v2.py` command to execute schema-2
  calibration/control selection, native runtime correction, G06, publish one
  immutable 23-artifact V3 release, and publish/reopen the exact-six export and
  receipt.
- [ ] Exact app — inject the authorized six files into an ordinary Release
  `Mirmir.app`, then reopen app/executable/metallib/resource identity and run
  exact-release integration.
- [ ] P08 pre-G07 — run native parity/performance/resource/profile/capture
  producers and publish the self-hashed pre-G07 seal with no holdout access or
  G08 claim.
- [ ] P07 — execute the locked holdout once through schema-2 authority and
  publish G07 over the exact P06 bytes.
- [ ] G08 — reopen the unchanged pre-G07 app/native/raw closure, bind the exact
  G07 publication, and derive/publish the Metal gate.
- [ ] P09 — Geometry, color, chroma, audio, provenance, and route capability;
  pass G09.
- [ ] P10 — Deterministic motion-aligned temporal ASH; pass G10.
- [ ] P11 — Xcode/CLI, soak, failure, profiling, and telemetry evidence; pass
  G11.
- [ ] P12 — Final audit, artifact manifest, commits, and handoff; pass G12.

Unchecked items are pending execution. Source implementation and focused unit
tests do not advance their gate state.

## Current Source Scope

The release-closure source includes:

- the production `ASHMetalUpscaleBackendV3` call graph;
- six cached Metal pipelines and the three-slot lease-through-append resource
  transaction;
- exact release identity telemetry and reopened AVFoundation timed metadata;
- exact six-file P06 build injection with stale-output removal;
- schema-2 coordinator, native candidate provider, and verified control
  authorization;
- V3 release-lock/G06 closure support, the sole authorizing V2 production CLI,
  and exact-six recovery from an already authoritative release;
- unhosted ordinary-app P08 execution with no `Contents/PlugIns`;
- exact fixture/app/executable/metallib/release-resource bindings;
- P08 parity, performance, resource, Instruments, and GPU-capture contracts;
  and
- pre-G07 sealing, preservation of the seal/native envelope during post-G07
  promotion, objective both-route checks, and derived atomic G08 finalization.

This list is an implementation inventory, not a gate report.

## Clean-Checkpoint Rule

Before G04:

1. complete all tracked source and documentation edits;
2. regenerate the Xcode project from `project.yml` when required;
3. run source-level tests, builds, lint, schema/meta-schema checks, path hygiene,
   and `git diff --check`;
4. refresh only the source-bound quality lock required by the implemented
   changes;
5. commit the complete source transaction; and
6. require a clean working tree outside ignored evidence paths.

After that commit, no tracked source edit is allowed through G08. A source
change invalidates dependent evidence and requires a new checkpoint plus rerun.

## Dependency-Ordered Execution

```text
clean committed source checkpoint
-> fresh G04
-> fresh G05
-> native runtime correction evidence
-> fresh G06
-> immutable P06 V3 release
-> inject exact six files into ordinary Release Mirmir.app
-> exact-release integration and P08 preflight
-> native P08 slices and pre-G07 seal
-> authorized one-time P07 execution and G07
-> reopen unchanged P08 seal, bind G07, and finalize G08
```

The source identity, P06 manifest hash, selected-evaluation identity, app tree,
executable, `default.metallib`, all six bundled resources, device, fixture
hashes, result bundles, traces, and captures must agree everywhere they are
bound.

## Gate Discipline

- Preserve strict development/validation/holdout separation.
- Do not open the holdout before the P06 release and pre-G07 P08 seal are
  complete and verified.
- Open P07 only through the exact schema-2 production authority and only once.
- Do not use historical V1 evaluation or P07 contracts as fallback.
- Do not use `run_p06_production_calibration.py` for production; it is a
  non-authorizing historical diagnostic that exits with status `2`.
- Do not use generated fixtures or root ASH assets as authorized release bytes.
- Do not use a hosted/testability-rebuilt app for P08; the measured app must be
  the ordinary Release bundle with no `Contents/PlugIns`.
- Do not treat synthetic exhaustive descriptor capture as natural-frame
  exhaustive coverage.
- Publish G08 pass or failure from measured evidence; never supply a decision to
  the finalizer.
- Preserve failed and partial evidence under distinct names.
- Commit only source; do not edit tracked documentation after a gate merely to
  record its outcome.

## Evidence Roots

Each gate run uses a unique direct descendant of `Artifacts/ASH/`. Producers
stage through deterministic hidden siblings and publish with atomic rename.
Published manifests bind their exact file/tree closures and are reopened after
publication.

Historical evidence remains historical. In particular, the earlier P04/P05
trees and the failed G06 tree cannot authorize the current source. Their paths
remain useful only for diagnosis and provenance:

- `Artifacts/ASH/20260711-p04-quality-63c9b988-7523-4578-a798-a5c3bfc734da/`
- `Artifacts/ASH/20260711-p05-spatial-6c1cb01f-e25e-4c06-ae7f-4fc76bc6aa71/`
- `Artifacts/ASH/20260713-p06-postrepair-8f0de437-3230-421e-8b25-464e2dbbe16e/g06/g06-postrepair-r1.failed/`

## Completion Rule

The ASH V3 production release closure is complete only when the exact clean
source commit has fresh passing G04, G05, runtime correction, G06, immutable
P06, exact ordinary-app integration, one passing G07, and a passing derived G08
over unchanged pre-G07 app/native/raw bytes. Until those immutable artifacts
exist and reopen, completion is not claimed.
