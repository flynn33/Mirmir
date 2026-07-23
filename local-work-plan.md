# Preserved Mirmir ASH V3 Local Work Plan

> This plan is preserved as implementation and failure-evidence history. It is
> superseded as the forward product plan by the
> [Mirmir Apple-Native Adaptive Video Enhancement Roadmap 1.0.1](docs/roadmaps/Mirmir_Apple_Native_ASH_Roadmap_2026-07-18.md).
> Unchecked P04-P12 items below are not authorized merely because this historical
> plan remains in the repository. No tag or release is authorized.

## Current Roadmap Execution State

- Roadmap phase `R00`: `passed`. The architecture decision, app-owned runtime,
  retired legacy authority, and exact PR #13 source checkpoint are preserved in
  the accepted current-source inventory.
- Roadmap phase `R01`: `passed`. The source-bound closure manifest records every
  A01-A18 capability across all four logical anchors as `not_observed` and
  `diagnostic_only`, with performance and qualification claims forbidden. The
  completed evidence commit is
  `bd963fbd034734e92f488549c6e1c0cd8b246363`; required anchor hardware and a
  compatible simulator destination were unavailable for capability observation,
  and operator-observed execution was waived as a blocker.
- The earlier PR #16 implementation and PR #17 assignment-export merges remain
  reachable historical checkpoints. Their native assignment, model-freeze, and
  live-run path remains optional supplemental evidence and does not alter the
  recorded local not-observed inventory disposition.
- Roadmap phase `R02`: `in_progress`. Its frozen preregistration binds local R01
  closure commit `555ae5a1afce1e492bdc89b6b14f2ba269edc524` and tree
  `2fbe72d85ace42cc925c45b17d53dd8866a8275b` as an unpublished predecessor,
  with `accepted_merge_commit: null` and no acceptance claim. The operator's
  continuation instruction permits local implementation through R07 but does
  not authorize publication or production enablement.
- Roadmap phase `R03`: `passed`. Its frozen v1 blocked record and narrower v2
  qualification remain historical evidence. The operator-overridden functional
  acceptance record binds the passing R02 common-session conformance and genuine
  A11 software execution, both canonical routes, repeatability, media/session
  preservation, lifecycle, identity, and no fallback. Production remains
  unavailable; default, Auto, holdout, performance, product-quality,
  product-publication, and release claims remain unauthorized.
- Roadmap phase `R06`: `in_progress` and unaccepted. Its frozen blocked closure
  remains truthful historical evidence and is not changed by the later R07
  acceptance.
- Roadmap phase `R07`: `passed` under the operator-defined deterministic
  software-function gate. The additive receipt and acceptance record bind
  implementation commit `1b46ad469265a6ba837a8449d28b8850889f1d3f`, tree
  `09d3a48df01738bb26077aadfd83c08e389a1dc2`, and 98 passing tests across the 11
  settled R07 test classes, with zero failures and zero skips. The frozen
  comparison requirement is outside the forward roadmap and carries no acceptance
  authority. Acceptance is limited to deterministic fixture simulation and claims no
  native hardware/framework execution, product routing, production default,
  Auto, quality, performance, publication, or release.
- Roadmap phase `R08`: `passed`. Its start binds accepted R07 merge commit
  `3fd13e57ec95b1ed98df71f4c83ab165bdfbab6b`, tree
  `eb1614dd2a93e1bc4e1911bcf74f41cf372a3304`. Its acceptance binds
  implementation commit `368b9284883c189be6a1139df6208bf0e88139dd`, tree
  `f8e73d193b7b0c9df7005a7aa006de48ca48f77c`, and 42 passing deterministic
  tests across 10 suites, with zero failures and zero skips. The accepted scope
  is `declared_software_function_only`. Comparison-based testing supplied no
  acceptance evidence or authority. Native Core AI, Xcode 27, model,
  hardware, simulator, and operator-observed execution remain `not_observed`.
- Roadmap phase `R09`: `in_progress`. The operator's separate `resume work`
  directive authorizes only the bounded experiment. Its authorization and frozen
  start contract bind accepted-R08 raw SHA-256
  `0d81917a93cf56cae867c11b7c65fb3c85e53b7596929cf9eec2ef09c24634b0`,
  implementation commit `368b9284883c189be6a1139df6208bf0e88139dd`, and tree
  `f8e73d193b7b0c9df7005a7aa006de48ca48f77c`. Acceptance is deterministic
  declared-software-function behavior only; comparison methods are excluded.
  Native/model/hardware/simulator/operator observations remain `not_observed`.
  Production default, Auto, holdout, claims, publication, and release remain
  unauthorized.
- Future R10 acceptance requires deterministic bounded optimizer/calibration
  software behavior. Future R11 acceptance requires traceable evidence and
  claim-scope machinery that rejects unsupported claims and emits an honest
  no-claim disposition by default. Any production Auto, holdout, or
  market-claim action retains its separate authorization boundary.
- Production Auto, production Core AI residual routing, holdout access, market
  claims, and release publication: blocked by their roadmap gates.

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
