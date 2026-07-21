# Mirmir R01-R13 Execution Handoff

- **Handoff version:** 1.6
- **Roadmap version:** 1.0.1
- **Publication date:** 2026-07-19
- **Revision date:** 2026-07-20
- **Repository:** `flynn33/Mirmir`
- **Source checkpoint:** `79f458a09625389ae890bea63f712f4ff39a3c34`
- **Original starting state:** `R00: passed`; `R01: next`
- **R01 implementation checkpoint:** PR #16 merge
  `9747a032b24f3d2475f3cead9ebbf5bc87d19548`; implementation commit
  `4bce3438a0508c70fd4db845be7e4abc0cc1cf29`; implementation tree
  `848948c9c38a2d8a382113698fe88059a69e943c`
- **R01 assignment-export checkpoint:** PR #17 merge
  `5fce07140602b94d7fbea3e4219866292a4cd99f`; implementation commit
  `8d5a50bdb616a2973014648475b601c8a7437de6`; implementation tree
  `06a0cb580e15f2949f5ae8cb4f68791c1574c3f0`
- **R01 not-observed implementation:**
  `8a14afb8ff0ba24abbebb5c72c47d8e38adbeffe`
- **R01 completed evidence source:**
  `bd963fbd034734e92f488549c6e1c0cd8b246363`; tree
  `6009c40b775e252a05ff83d436d90f0422498245`
- **R01 local unpublished closure:**
  `555ae5a1afce1e492bdc89b6b14f2ba269edc524`; tree
  `2fbe72d85ace42cc925c45b17d53dd8866a8275b`; acceptance not claimed
- **R02 local preregistration source:** R01 local unpublished closure above;
  `accepted_merge_commit: null`
- **R02 local unpublished closure:**
  `673b0582c0b4d6b4ad81de6b01ba9e3f35f4e3d4`; tree
  `a5e95d810abacbdb872ddc6e94125103831e6fba`; acceptance not claimed
- **R03 local preregistration source:** R02 local unpublished closure above;
  `accepted_merge_commit: null`
- **Continuation state:** `R01: passed`; `R02: in_progress`; `R03: in_progress`

> This is non-canonical implementation guidance. The canonical roadmap Markdown,
> canonical roadmap JSON, accepted architecture decision, and roadmap-alignment
> governance documents control if this handoff conflicts with them. This document changes
> no phase status, authorization, evidence acceptance, product behavior,
> repository setting, release authority, or holdout authority.

### Operator observation override — 2026-07-20

The operator explicitly waived every requirement for physical-hardware testing,
an unavailable simulator, operator-observed simulation, and operator-observed
hardware operation. None of those conditions is a blocker or a reason to stop
work. If execution is unavailable or not performed, record the affected
anchor/capability as `not_observed` and continue through the dependency plan. Do
not synthesize host, simulator, API, model, performance, memory,
repeatability, product-qualification, backend-eligibility, or perceptual-quality
facts.

The current app, worker, and test targets are macOS-only; Xcode advertises no
Simulator destination for them. The installed iOS/tvOS CoreSimulator runtimes do
not establish macOS or Mac-hardware capability. Use a compatible simulator
automatically if one later becomes available, but do not stop when it is absent.

The canonical not-observed path is
`Scripts/r01_observation_waiver.py`; the existing native-host preregistration,
runner, raw-report, and aggregate path remains optional supplemental evidence.
This addendum controls over every conflicting physical-host,
unavailable-simulator, or operator-observation instruction later in this
handoff. Native live-run and model-freeze requirements remain applicable only to
the optional native supplemental path. Non-hardware implementation, deterministic
tests, safety, privacy, publication, pull-request, merge, holdout, production,
and release authority are unchanged.

### R02 closure and R03 start checkpoint — 2026-07-20

R02 deterministic software conformance is recorded in local unpublished closure
commit `673b0582c0b4d6b4ad81de6b01ba9e3f35f4e3d4`, tree
`a5e95d810abacbdb872ddc6e94125103831e6fba`. The record passes its frozen
software checks while keeping hardware, simulator, and operator observation
`not_observed`; it makes no performance, product-qualification, publication, or
acceptance claim.

R03 local implementation begins only from a frozen preregistration that binds
that exact commit and tree with `accepted_merge_commit: null`,
`acceptance_state: not_claimed`, and
`continuation_scope: local_implementation_only`. Its matrix contains eight whole-frame deterministic
paths and two support stages across exact 720p-to-1080p, 1080p-to-2160p,
analytic-artifact, temporal-repeatability, and media-transaction fixtures.
Unavailable execution receives `not_observed`; no production default,
performance claim, or product qualification is enabled.

## 1. Resume instructions

Before changing source:

1. Clone or open the repository and fetch the remote without rewriting history.
2. Read this handoff, the canonical roadmap sources, the accepted architecture
   decision, and the roadmap-alignment governance document completely.
3. Verify live remote `main`, inspect intervening commits after the source
   checkpoint, and fast-forward local `main` with `--ff-only`.
4. Confirm `R00: passed`, `R01: passed`, `R02: in_progress`, and
   `R03: in_progress` remain
   canonical for this local continuation. If any changed, reconcile the newer
   accepted roadmap before proceeding.
5. Continue the frozen R03 implementation contract. Except for the narrow
   operator-directed local-continuation path in Section 3.1, later phases become
   actionable only through their accepted dependencies, evidence, roadmap
   state, and operator controls.

The source checkpoint records the accepted R00 state. A receiving environment
must record its own exact starting commit rather than claiming that its working
tree is still identical to this checkpoint.

## 2. Immutable operator controls

These controls apply to every phase and override any workflow text that implies
otherwise:

- Never force-push.
- Never approve a pull request.
- Never merge a pull request.
- Commit locally before requesting publication.
- Push or open a pull request only after a direct operator instruction for that
  publication action. This handoff and the roadmap are not authorization.
- Require another direct operator instruction before every later push to an open
  pull request.
- Use additive commits after a branch is published. Do not amend, rebase, or
  otherwise rewrite its published history.
- If published history cannot be repaired additively, stop and ask the operator
  to close or supersede the pull request. Prepare a replacement branch from
  current `main` only after direction; publication still requires a separate
  direct operator instruction.
- Never mutate repository rulesets without separate express operator authority.
- Never enable auto-merge, create a tag or release, open holdout data, or publish
  a product or market claim by implication.

The operator alone reviews, approves, and merges. A plan, phase status, test
result, or green check never substitutes for that decision.

## 3. Delivery and evidence protocol

### 3.1 One pull request per phase

Execute phases in strict numeric order. R04 and R05, R08 and R10, and R12 and
R13 have partially independent canonical dependencies, but this handoff fixes
the practical sequence as:

```text
R01 -> R02 -> R03 -> R04 -> R05 -> R06 -> R07 -> R08
  -> R09 only when authorized and evidence-positive
  -> R10 -> R11 -> R12 -> R13
```

Use one branch and one pull request for each phase, with additive local commits
in this order:

1. preregistration, schemas, fixtures, metrics, stop conditions, and the proposed
   transition from `next` to `in_progress`;
2. interfaces, implementation, deterministic tests, and migration work;
3. runtime evidence from every required environment;
4. a closure manifest that binds the preceding implementation/evidence commit
   and tree, avoiding a self-referential hash; and
5. the proposed transition to `passed`, with only the next dependency-satisfied
   phase changing to `next`.

Operator merge is acceptance of the proposed phase closure. The following phase
must record the actual preceding merge commit before implementation begins.
Every other phase status and authorization remains unchanged unless the same
pull request contains the evidence and explicit roadmap decision needed to
change it.

#### Operator-directed local continuation from an unpublished closure

The operator's direct instruction to continue locally through R07 creates one
narrow exception to the preceding implementation-start rule. A dependent phase
may begin local implementation only after a preregistration binds the exact
preceding policy-frozen local closure commit and tree, records the exact closure
state and predecessor result required for that phase,
`accepted_merge_commit: null`, and states that acceptance is not claimed. This
exception does not accept the preceding phase and does not authorize a push,
pull request, approval, merge, tag, release, holdout access, production enablement,
or product/performance claim.

The frozen preregistration remains immutable. If the preceding phase is later
merged, record the actual operator-created merge commit and tree additively in a
separate predecessor-acceptance receipt before claiming an accepted predecessor
or publishing/closing the dependent phase. Never rewrite the preregistration or
infer merge acceptance from a local branch or remote-tracking ref.

The R04 local-continuation preregistration must bind R03 closure commit
`947983a8414c60e4f5f4246e6cb658792fc7c357` and tree
`d1a89e5b9edf8d42b1da9ba06a3b6a0c139f08f3`. That closure records a fail-closed
`blocked` R03 result as `local_unpublished_blocked_closure`. The R04 exception
permits only `in_progress` local implementation while R03 remains `in_progress`;
it records
`predecessor_result: blocked`, `accepted_merge_commit: null`,
`acceptance_state: not_claimed`, and
`continuation_scope: local_implementation_only`. It does not reinterpret R03
evidence as success or authorize R04 evidence readiness, passing status,
publication, production enablement, or a quality/performance claim.

Phase pull requests require the operator to use GitHub's merge-commit method.
Squash and rebase merges do not preserve the preregistration, implementation,
evidence, and closure commits as reachable history and therefore do not satisfy
phase acceptance. The merge commit and all bound commits/trees remain reachable
from `main`, including for R13. This is a review requirement, not permission for
the implementation task to perform the merge.

#### Fail-closed recovery from an incomplete phase merge

If a phase pull request is merged before it contains runtime evidence, its closure
manifest, and its proposed `passed` transition, the merge does not override the
canonical roadmap or manufacture phase acceptance. Treat the merge as a reachable
implementation checkpoint, keep the current phase `in_progress`, keep its dependent
phases unchanged, and do not begin later-phase implementation.

Record the pull request, implementation commit/tree, merge commit, and missing
closure items in the roadmap progress history. After direct operator direction,
continue the same phase on one additive recovery branch from that merge commit.
The recovery pull request is the narrow exception to the one-pull-request-per-phase
rule: it must carry the remaining frozen execution assignments, runtime evidence,
closure manifest, and evidence-supported roadmap transition. Every evidence host
must use the same exact published recovery checkpoint. The operator's merge of the
recovery pull request is phase acceptance, and the following phase records that
recovery merge commit as the accepted preceding-phase merge. Do not revert or
rewrite the reachable implementation history to simulate the original sequence.

Multi-host phases use this fixed transport sequence:

1. commit preregistration and implementation locally;
2. after direct operator instruction, push the implementation commit and open
   the single phase pull request;
3. make every required host check out that exact published implementation commit
   and verify its commit and tree before running;
4. write sanitized per-host evidence using the prescribed runner and transfer
   the files through an operator-controlled local transfer into the primary
   checkout; temporary transport is not an authorizing evidence store;
5. verify every transferred file hash, aggregate the reports, and commit evidence
   and closure additively on the same branch; and
6. obtain another direct operator instruction before pushing those additional
   commits to the open pull request.

No secondary host pushes to the phase branch. If operator-controlled transfer is
unavailable, use a hash-verified Git bundle delivered directly to the primary
checkout; do not substitute an external evidence service.

### 3.2 Closed evidence format

R01 introduces phase-evidence schema version `1.0` at
`docs/roadmaps/evidence/schema/phase-evidence-manifest-v1.json`. Each phase uses
`docs/roadmaps/evidence/rNN/phase-evidence.json` as its canonical manifest,
`phase-evidence.md` as the generated summary, and `records/` for compact
supporting records. `python3 Scripts/phase_evidence.py --phase RNN --check`
verifies it; `--write-summary` regenerates only its Markdown summary.

Each manifest has only these top-level keys: `schema_version`,
`roadmap_version`, `phase_id`, `source`, `hosts`, `preregistration`, `commands`,
`outputs`, `verification`, `result`, `authorizations`, and `limitations`.
`result.status` is exactly `passed`, `diagnostic_only`, `rejected`, or `blocked`;
`result.disposition` must use the closed phase-specific vocabulary in this
handoff or the canonical roadmap. Each authorizing manifest must record:

- schema, roadmap, phase, and evidence-format versions;
- exact source commit and source tree;
- sanitized host/toolchain profiles;
- preregistered inputs, fixtures, parameters, metrics, floors, and stop rules;
- commands and exit status;
- output paths, sizes, hashes, and generated summaries;
- test/build results and any skips with exact reasons;
- capability or experimental dispositions;
- authorization state before and after the proposed decision; and
- limitations, unavailable inputs, and negative results without concealment.

The canonical representation is JSON with a generated Markdown summary. Verify
all referenced paths and Git object identities from the repository. Ordinary
implementation source may change in later phases; only explicitly preserved or
checkpoint-bound identities remain immutable.

All authorizing evidence representations are repository-owned:

- maximum 25 MiB for one evidence file;
- maximum 100 MiB of new evidence for one phase;
- no Git LFS and no external-storage exception;
- if evidence cannot fit, stop and redesign the evidence representation;
- downloaded framework/model system assets are never committed; record their
  public identity, readiness, revision, and observed properties instead;
- raw licensed media, holdout pixels, system assets, and nonredistributable
  commercial outputs remain outside Git and are never represented as repository
  contents; commit only legally redistributable compact fixtures/outputs,
  sanitized measurements, summaries, hashes, access receipts, and manifests;
- external or ephemeral raw data cannot be the sole authorizing evidence. Any
  required exact-output reopening must use compact, legally redistributable
  repository fixtures within the limits above, or the phase stops for evidence
  redesign;
- never claim possession or byte reopening of unavailable historical bulk data;
  preserve and cite its committed receipts honestly; and
- holdout evidence remains no-pixel until the separately authorized R11 opening.

### 3.3 Common repository gate

Every phase must pass, as applicable:

- `git diff --check` and JSON validation;
- strict SwiftLint;
- roadmap and phase-evidence unit, mutation, and repository verifiers;
- dependency and prohibited-path scans;
- XcodeGen regeneration followed by a no-diff second generation when project
  declarations change;
- clean Debug and Release builds with automatic package resolution disabled;
- the complete ordinary hosted test suite;
- production and developer launch smoke tests when application behavior changes;
- exact evidence path/hash/source validation; and
- a final clean working tree.

The evidence-only P08 scheme remains dormant unless its exact authorized inputs
and a separate execution decision exist. A hosted-suite failure blocks closure
until it is fixed or shown to be unrelated and explicitly accepted by the
operator.

At the source checkpoint, the deterministic `Roadmap alignment` workflow and
informational network-backed metadata audit exist, but the live ruleset does not
require the alignment check. Treat a green alignment result as a procedural gate,
verify live repository metadata before every publication, report ruleset drift,
and do not mutate the ruleset without separate operator authority.

## 4. Architecture and compatibility contract

Apple frameworks own numerical reconstruction. ASH owns deterministic
orchestration, temporal governance, fallback, protection, correction policy,
and explanation. ASH V3 remains a directly testable reference and analysis
substrate, not the presumptive production reconstruction engine. Core AI is
optional, initially analysis-only, and never an unconditional product dependency.

Preserve the app-owned Pattern B runtime and its exact five-module composition:

1. Metal rendering;
2. model assets;
3. media pipeline;
4. upscaler engine; and
5. UI, activated last.

Core AI belongs inside the existing model-assets boundary as a cohesive
subservice; it is not a sixth module. Preserve stable module IDs, entry points,
view ID, service protocols, file workflow, bundle identifier, deployment target,
constructor injection, deterministic lifecycle, and single composition root
unless a later accepted phase explicitly changes one of those contracts. Do not
reintroduce the removed external framework/package boundary.

All new roadmap interfaces remain internal to the application target. The
principal planned types are:

- R01: `AppleCapabilityID`, `AppleCapabilityRecord`, `AppleHostProfile`, a
  closed capability disposition, and typed probe results;
- R02: `AppleUpscaleCapabilityRegistry`, `AppleUpscaleBackend`,
  `AppleUpscaleSession`, preprocessing/primary/postprocessing/temporal/analysis
  stage protocols, immutable `EnhancementPipelinePlan`,
  `EnhancementPipelinePlanner`, typed unavailable/rejected/failed/fallback
  outcomes, and structured processing identity;
- R06: immutable `ASHDecisionContext`, versioned policy and decision records,
  transition/reason types, and explicit fallback identity; and
- R08-R09: optional analysis and residual services within the existing module
  composition.

Silent fallback is prohibited. Every produced output must bind the selected
backend, revision, model/assets, configuration, policy, fallback history, and
material ASH decisions.

## 5. Verified implementation baseline

At the source checkpoint:

- the production bootstrap injects an unavailable upscaler service and launches
  normally while explaining that no roadmap-qualified backend exists;
- production upscaling remains unavailable through R02;
- AVFoundation ingest, ordered frames, timestamps/durations, audio, metadata,
  reopen validation, cancellation, and atomic publication are reusable;
- Metal lifetime management, the reusable resource ring, NV12 texture bridging,
  telemetry, and retained ASH reference tests are reusable;
- the current VideoToolbox driver performs placeholder CPU copy/letterbox work
  and is not super-resolution evidence;
- the current VideoToolbox model stager is synthetic and is not readiness or
  download evidence;
- the current custom Metal Lanczos pass is not `MPSImageLanczosScale`; and
- the checkpoint toolchain does not contain Core AI, so A18 requires an exact
  unavailable record there rather than simulated support.

Do not turn any scaffold or retained reference call site into a product fallback
merely to make a capability appear available.

## 6. Phase plan

### R01 - Apple capability laboratory

Probe A01-A18 using isolated compile and runtime tests. Cover VideoToolbox quality
and low-latency super resolution, frame interpolation, temporal noise filtering,
optical flow and pixel transfer; MetalFX spatial, temporal, temporal-denoised and
frame interpolation; MPS Lanczos, bilinear and support filters; Core Image
Lanczos, bicubic and edge-preserve upsample; vImage Lanczos/custom resampling;
custom Metal; Core AI; and optional Core ML compatibility.

PR #16 and PR #17 remain reachable implementation checkpoints. The current
closure uses the explicit operator observation override rather than inventing
native anchor reports: implementation commit
`8a14afb8ff0ba24abbebb5c72c47d8e38adbeffe` generates the closed waiver matrix,
and evidence commit `bd963fbd034734e92f488549c6e1c0cd8b246363`
binds ten passing verification categories. Every A01-A18 anchor cell remains
`not_observed`/`diagnostic_only`; no runtime support, performance, product
qualification, backend eligibility, or perceptual-quality result is claimed.
The native assignment/model/live-run path remains optional supplemental
evidence. R01 is `passed`, and R02 is `in_progress`; publication and merge authority
remain unchanged.

Collect an aggregate matrix from four anchor environments:

1. oldest-supported Apple Silicon on macOS 15.4;
2. the current M3 MacBook Air class on macOS 26;
3. a current Pro/Max performance tier; and
4. a macOS/Xcode 27 host capable of probing Core AI.

One physical host may satisfy more than one anchor only when its hardware,
operating-system, SDK, and toolchain record satisfies each contract independently.
Host reports may contain model identifier, chip, memory, OS/build, Xcode, SDK,
and source commit. Exclude serial numbers, hardware UUIDs, account data, and
other stable personal identifiers.

For every capability record compile availability separately from runtime support,
public API status, hardware eligibility, scales, dimensions, formats, color
expectations, state/history, model readiness, offline suitability, repeatability,
initialization latency, warm throughput, memory, and exact rejection/restriction
reason. The accepted R01 execution choice permits model acquisition in principle
during these probes, subject to consent on the host performing the
network/download action. The current runner remains fail-closed and rejects the
acquisition flag until an additive reviewed implementation defines the closed
consent-receipt contract and acquisition path. Acquisition must be explicit,
isolated from ordinary app boot, and excluded from Git. This document does not
grant publication authority or later product use.

Before the first live run, assign one actual host/toolchain combination to every
anchor and freeze the assignment in preregistration. A stronger machine does not
automatically satisfy the macOS 15.4, M3 Air, or macOS/Xcode 27 anchors. If an
assigned host changes, invalidate its prior report and preregister the replacement
before rerunning.

Each candidate host exports its allowlisted assignment record without changing
repository state or starting a live probe:

```sh
python3 Scripts/r01_preregistration.py \
  --emit-host-assignment \
  --anchor <anchor> \
  --host-id <r01-host-NN>
```

Transfer the four records through the operator-controlled path in section 3.1,
review them together, then freeze all four assignments atomically in the
preregistration. The exporter rejects private identifiers, extra fields, malformed
facts, and hosts that do not satisfy the selected anchor; it does not itself assign
a host or authorize a live run.

Only the primary checkout freezes the reviewed records. Supply each transferred
file explicitly; input order does not change the canonical anchor order:

```sh
python3 Scripts/r01_preregistration.py \
  --freeze-host-assignments \
  --assignment-file <anchor-oldest-supported-assignment.json> \
  --assignment-file <anchor-m3-air-assignment.json> \
  --assignment-file <anchor-pro-max-assignment.json> \
  --assignment-file <anchor-core-ai-assignment.json>
```

The freeze command accepts exactly one valid record for every anchor, validates
privacy and role contracts together, rejects inconsistent pseudonym reuse, and
atomically replaces only the canonical preregistration. It refuses partial,
duplicate, malformed, symbolic-link, or different already-frozen input and never
starts a probe. Cooperative freeze invocations are serialized, and canonical
state drift detected before replacement aborts the write. An exact replay
succeeds without rewriting the frozen record. Commit the resulting
preregistration before requesting publication of the common live evidence-source
checkpoint.

Use these closed probe controls:

- `Scripts/run-r01-capability-probe.sh --anchor <anchor> --output <path>` is the
  only live runner;
- valid anchors are `oldest-supported`, `m3-air`, `pro-max`, and `core-ai`;
- live probes require `MIRMIR_R01_LIVE_PROBES=1`;
- every live anchor requires one frozen `analysis-probe-model` identity/hash so
  all four reports bind the same probe contract; absent local model bytes remain
  valid for a negative/unavailable result, but an unassigned identity does not;
- a future acquisition path additionally requires
  `MIRMIR_R01_ALLOW_MODEL_ACQUISITION=1`, but the current runner rejects that
  flag until the closed consent-receipt contract is implemented and reviewed;
- ordinary app boot and ordinary hosted tests set neither variable and perform
  no downloads or live capability mutation;
- `AppleUpscaleCapabilityProbeTests` always runs side-effect-free schema and
  deterministic-double tests, while its live test skips unless explicitly
  enabled; and
- `python3 Scripts/r01_capabilities.py --aggregate` generates the canonical
  report/JSON, while `--check` verifies schema closure, anchor completeness,
  hashes, privacy, and generated Markdown.

Store the four raw reports at:

```text
project-notes/evidence/r01/hosts/anchor-oldest-supported.json
project-notes/evidence/r01/hosts/anchor-m3-air.json
project-notes/evidence/r01/hosts/anchor-pro-max.json
project-notes/evidence/r01/hosts/anchor-core-ai.json
```

The aggregate JSON has closed top-level keys for schema/roadmap/phase versions,
source commit/tree, generation time, anchor records, and capability records.
Compile state is exactly `available`, `conditional`, or `unavailable`. Runtime
disposition is exactly `runnable`, `restricted`, `diagnostic_only`,
`unsupported`, `unavailable`, or `rejected`. A non-runnable result requires one
of these reason codes: `api_absent`, `os_too_old`, `sdk_too_old`,
`hardware_unsupported`, `model_unavailable`, `model_acquisition_failed`,
`input_contract_unsatisfied`, `runtime_probe_failed`, `resource_limit`,
`not_public_api`, or `not_applicable`; runnable results use `none`. The verifier
must reject any R01 record or product-composition change that interprets
`runnable` as product qualification or backend eligibility; those decisions
belong exclusively to R03-R05.

Assign every capability one closed probe class:

- `primary_scaler`: A01, A02, A06-A09, A11, A12, A14, and A16;
- `support_filter`: A04, A13, A15, and A17;
- `temporal_analyzer`: A05;
- `cadence_transform`: A03 and A10; and
- `analysis_runtime`: A18.

Freeze two deterministic SDR BT.709 video-range, left-sited 8-bit NV12 scaler
fixtures: 1280x720 to 1920x1080 and 1920x1080 to 3840x2160. Support filters use
the same-size 1920x1080 fixture plus canonical guidance/history inputs required
by the public contract. The temporal analyzer uses two ordered 1920x1080 frames.
Cadence transforms use an ordered 1920x1080 frame pair with fixed PTS/duration.
The analysis runtime uses a deterministic 512x288 BGRA proxy and a preregistered
probe-model identity/hash; an incompatible public contract receives a restricted
or unsupported disposition rather than an altered fixture.

For every runnable class, perform three independent sessions, each with five
warm-up units and thirty measured units. All classes record monotonic-clock
initialization, acquisition separately, median/p95 wall time, throughput, peak
resident-memory delta, and a three-repeat hash or tolerance observation.
`primary_scaler` additionally records scale, output dimensions/format, and frame
rate; `support_filter` records preserved dimensions/format and required guidance;
`temporal_analyzer` records flow dimensions/format and confidence availability;
`cadence_transform` records generated-frame count, output cadence, and timestamp
contract; `analysis_runtime` records load/specialization/inference time,
zero-copy disposition, and stateful-execution disposition. Every nonapplicable
metric remains present with `not_applicable` and a class-derived reason. Apply a
120-second timeout per session and classify timeout, unsupported contract, setup
failure, processing failure, and resource failure separately. R01 measures
capability and repeatability, not perceptual superiority.

Deliver exactly:

```text
project-notes/apple-upscale-capability-report.md
project-notes/apple-upscale-capabilities.json
MirmirTests/AppleUpscaleCapabilityProbeTests.swift
```

Also add the reusable phase-evidence governance described above and correct
current governance text that implies either future ordinary source files remain
permanently hash-frozen or a published branch may be repaired by force-pushing.
Do not change live rulesets. Keep product upscaling unavailable. R01 passes with
an explicit disposition for every A01-A18 capability. Under the operator
observation override, the canonical matrix may close all four logical anchors as
`not_observed`/`diagnostic_only` with performance claims forbidden; the four
native reports are then supplemental rather than required.

### R02 - Unified backend and stage architecture

Implement the internal contracts in Section 4. Run multiple deterministic
fixtures through one common session boundary and preserve output dimensions,
frame order, PTS, duration, audio, metadata, cancellation, reopen verification,
and atomic publication. Adapt retained ASH code as a comparator rather than
forcing Apple frameworks through an ASH-named interface. Require explicit typed
failure and fallback results and exact output identity. Production remains
unavailable after R02.

Freeze this lifecycle contract before implementation:

- `AppleUpscaleBackend` is `Sendable`, exposes immutable structured identity and
  explicit capability lookup, and asynchronously creates a session from
  validated configuration and context;
- `AppleUpscaleSession` is actor-isolated and serializes `submit`, `reset`,
  `finish`, and `cancel` through one FIFO operation boundary despite actor
  reentrancy;
- every admitted frame retains the complete frozen frame contract until a typed
  outcome transfers or releases ownership;
- every output is exactly processed, unavailable, rejected, failed, or
  fallback-applied and carries complete structured processing identity;
- reset drains earlier work, clears temporal history, advances history
  generation, and preserves clip-global sequence numbering;
- cancellation is idempotent, closes admission, rejects queued work, waits for
  active work to quiesce, and releases resources exactly once;
- finish installs an admission fence, drains ordered work, finalizes once,
  caches its result, and rejects later mutation; and
- fallback is selected only by the planner or orchestrator and visibly links
  the failed route to the selected route.

### R03 - Deterministic Apple-native baseline suite

Implement genuine MPS Lanczos and bilinear, Core Image Lanczos and bicubic,
vImage Lanczos-3 and Lanczos-5, VTPixelTransfer, qualified guided/edge-preserve
support stages, and the retained ASH/custom-Metal comparator. Initial
qualification remains 8-bit NV12, SDR BT.709, 720p-to-1080p and 1080p-to-4K;
R12 owns format expansion.

Local implementation progress as of 2026-07-20: preregistration commit
`21596ebc520ec9bfe604dafa588d16d066f7f492` freezes the ten-subject matrix, and
implementation commit `767cbc4673678a699c3f98903b6c7801a87e91d4` (tree
`9c40a216c21eba77a92d5d1240d4b6475ce5fb48`) implements the genuine framework
adapters and focused contract tests. The complete focused R03 Xcode selection
passes and SwiftLint is clean.

The frozen evidence preflight is fail-closed: `media-transaction-2x` is assigned
to the 1920×1080-to-3840×2160 route, but its exact bound R02 member is
16×8-to-16×8. The phase record is `blocked` with deterministic software
conformance failed, the affected media checks failed, and all subject executions
and metrics `not_observed`. R03 remains canonical `in_progress`; no 2× media,
runtime support, product qualification, default, performance, acceptance,
publication, or release claim follows. Hardware, simulator, and operator
observation remain `not_observed` and non-blocking under the explicit override.
The operator-directed local R02-through-R07 continuation remains implementation
authority only and does not convert this negative R03 evidence into success.

Preregister correctness, ringing, edge, chroma, temporal, throughput, memory,
and resource floors. Eliminate nonqualifying and dominated candidates. Among
remaining qualifying candidates, choose the normal deterministic product default
only from candidates classified and qualified as whole-frame primary
deterministic upscalers. Within that pool choose by lowest measured wall time,
then lowest memory, then stable backend ID. Support filters, conversion paths,
and reference-only comparators remain in their accepted roles regardless of
speed. Enable the selected default only after R03 is accepted. Keep Auto blocked.

### R04 - VideoToolbox super-resolution integration

Replace placeholder behavior with real `VTFrameProcessor` sessions. Treat quality
and low-latency super resolution as separate backend identities. Discover
configuration/revision/scale and declared buffer attributes at runtime; implement
model readiness, ordered prior-frame/prior-output history, scene-cut reset,
submission semantics, optical-flow choices, lifecycle, cancellation, and exact
identity. Qualify direct 2x and runtime-supported 1.5x routes without assuming
support. Quality and low-latency paths must independently pass correctness,
quality, protected-region, temporal, throughput, memory, and reopen gates.

### R05 - MetalFX suitability decision

Qualify MetalFX Spatial first against the accepted deterministic and low-latency
baselines. Probe temporal, temporal-denoised, and frame-interpolation paths only
when motion, depth, exposure, jitter, and other required inputs can be supplied
honestly. Never fabricate renderer semantics. Record exactly one supported
disposition per path: `qualified_spatial`, `qualified_temporal`,
`qualified_temporal_denoised`, `diagnostic_only`, or
`rejected_for_decoded_video`. A documented rejection is successful phase
completion.

The canonical disposition list has no qualified frame-interpolation outcome.
Therefore A10 may be `diagnostic_only` or `rejected_for_decoded_video` in R05;
qualifying it for product cadence requires a later explicit canonical roadmap
amendment, targeted no earlier than R12.

### R06 - ASH orchestration engine v1

Preserve the canonical nine-bit state while adding immutable continuous context.
Map branch outputs to versioned policy profiles, select one whole-frame backend
per decision interval, and implement deterministic scoring, tie-breaking,
hysteresis, minimum dwell, scene-cut reset, resource policy, typed failover,
protection/correction masks, and reason codes. Only R03-R05-qualified backends are
eligible.

Preregister and run fixed-backend, continuous-router, state-only, sidecar,
no-hysteresis, and no-postflight ablations. Perturbations must causally affect
only contracted policy decisions. R06 requires improvement in at least one
primary product dimension over the best eligible fixed or continuous router
without breaking any locked floor.

### R07 - Temporal stability and artifact governance

Preregister temporal, chroma, artifact, churn, and protected-region metrics before
tuning. Add scene-cut reset, motion/occlusion confidence, qualified temporal noise
filtering, backend/strength/artifact history, ringing/halo/ghosting/flicker/false-
texture/chroma detection, luma-guided chroma reconstruction, edge-preserving mask
upsampling, and policies for faces, text, line art, animation, subtitles, and UI
captures. Postflight feedback may affect later decisions but never rewrite a
completed frame. Pass only with measured improvement over each used backend alone
without material spatial-quality loss.

### R08 - Core AI analysis-only integration

Execute only on an accepted macOS/Xcode 27 environment with the public framework
available. Implement a cohesive optional model-assets subservice producing
calibrated protection masks, artifact risk, source classification, motion
reliability, and no-reference quality estimates on proxy/key/requested frames.
Bind model/preprocessing/postprocessing identity and add specialization cache,
optional AOT compilation, zero-copy input, state handling, cancellation, memory
and latency budgets, and deterministic bypass.

Run blinded deterministic-analyzer versus learned-analysis ablations. A positive
result may pass R08 and make R09 eligible for a separate authorization decision.
A negative result passes R08 with `diagnostic_only`, leaves R09 blocked, and sends
execution directly to R10.

If R08 is positive but the operator delays or declines the residual-authorization
change, leave R09 blocked and proceed to R10. Positive evidence alone does not
authorize R09.

### R09 - Core AI bounded residual experiment

Do not start from dependency completion alone. Require both a positive R08
analysis ablation and an operator-accepted roadmap authorization change. Run a
small post-scaler residual only in ASH-approved regions with hard per-plane,
source-consistency, temporal, identity, face, and text protections. Preserve the
Apple-only output for exact A/B comparison. Qualification for a narrow use or an
explicit no-value, hallucination-risk, or resource-cost rejection are valid
outcomes. The residual is never required to ship.

The exact canonical change is
`core_ai_pixel_residual: authorized_for_r09_bounded_experiment`, bound in policy
to the accepted positive R08 evidence-manifest SHA-256. R09 cannot start until
that change is operator-reviewed and merged and the operator separately directs
the applicable implementation or publication action.

### R10 - Auto-policy optimization and bounded calibration

Reuse preserved schedulers, schemas, validators, and evidence libraries through
new R10 commands; the retired P06/P07 entry points remain fail-closed. Use a fixed
screening design over causal variables, keep route/plane/temporal/protection
constraints separate, construct a quality/resource Pareto frontier, remove
dominated policies, and refine only near passing candidates. Publish durable
per-experiment evidence and keep development, validation, and holdout isolated.

Freeze the validated Auto and explicit mode policies before holdout. The R10
closure must include the frozen R11 holdout protocol and may propose changing the
canonical authorization from `holdout: blocked` to
`holdout: authorized_once_for_r11`. Bind the authorization in policy to the
SHA-256 of that protocol manifest and add verifier tests that reject a different
manifest, a second opening, or an unbound authorization. It takes effect only
after operator review and merge and does not itself authorize opening the
holdout. Production Auto remains blocked.

### R11 - Competitive benchmark and market-position decision

Before preregistration, verify current comparator versions, licensing, permitted
automation, and evidence redistribution. Include every qualified Apple backend,
ASH Auto without learned analysis, ASH Auto with accepted analysis, an R09
residual only if qualified, current Topaz Video representative local models,
current DaVinci Resolve Studio Super Scale and its restoration/sharpening path,
and ordinary deterministic scalers. Every named comparator requires either an
executed result or an explicit preregistered `not_applicable` disposition with
license, availability, or contract reason.

The corpus must cover clean 720p/1080p, compressed streaming video, film grain,
animation/line art, faces/skin, small text/subtitles/UI capture, sports/fast
motion, low light/noise, chroma stress, scene cuts/flashes/occlusion, archival SD
and deinterlaced material, and synthetic ground-truth downsample pairs. The
measurement contract must include spatial ground-truth metrics where available,
temporal warping/flicker/churn/ghosting, edge/ringing/halo/aliasing/chroma,
face/text/line-art integrity, hallucination/source consistency, blind pairwise
preference, throughput/wall time, memory, energy/thermal behavior, first-run
acquisition/specialization cost, repeatability, privacy, and network dependency.
Every canonical item is measured or receives a preregistered `not_applicable`
reason; do not silently narrow the benchmark.

Freeze corpus classes, exact inputs, preprocessing, metrics, blind pairwise
protocol, resource collection, stop rules, and claims before execution. Open the
holdout exactly once only after the canonical authorization is
`authorized_once_for_r11`, its manifest hash verifies, and the operator gives a
separate direct command. Record access before reading pixels, run the frozen
protocol, and do not retune afterward. The R11 closure changes the canonical
authorization to `holdout: consumed`, binds it to the access-ledger SHA-256, and
adds verifier coverage preventing reuse.

`Scripts/run-r11-locked-holdout.sh` is the only holdout entry point. It requires
`MIRMIR_R11_HOLDOUT_OPEN=1`, the designated host recorded in the authorization
manifest, the exact source/protocol hashes, and an initially unmounted holdout.
Before any holdout mount, path lookup, or pixel access, it creates
`docs/roadmaps/evidence/r11/records/holdout-access-ledger.json` with exclusive
create semantics, writes the authorization/source/protocol identities, and
fsyncs both the file and parent directory. An existing ledger always refuses a
second run, including after failure. The runner then mounts/opens only the
preregistered inputs, records access count and hashes, and atomically updates and
fsyncs the permanent ledger with terminal unmount/closure state. A crash leaves
the created ledger in place and consumes the one-time authorization. The R11
closure commits and binds this ledger without reopening the holdout.

R11 may propose production Auto authorization and a narrowly worded market claim
only when the exact evidence supports them. The exact canonical values are
`production_auto_mode: authorized` and
`market_leading_claim: authorized_exact_claim`. The policy must bind the former
to the accepted R11 evidence-manifest SHA-256 and the latter to both that hash and
the exact permitted claim text. If either proposal lacks support or operator
acceptance, retain its existing `blocked` value. A negative competitive result
must be reported as such.

### R12 - Format, route, and product expansion

After R11, expand through explicit contracts for 10-bit/P010, HDR transfer and
BT.2020 color, wider routes and runtime-supported scales, 4:2:2 and 4:4:4,
interlace/deinterlace, subtitles, alpha, metadata, long-form resume, chunk
checkpoints, and hardware tiers. Every addition must define color, range, chroma
siting, metadata, capability, fallback, quality, and test behavior. Complete R12
before R13 even though the canonical dependency graph permits overlap.

### R13 - Release hardening

Add the accepted user modes, asset-acquisition/specialization UI, resumability,
concise explanations, detailed diagnostics, exact binary/model/policy/framework
identity, and fault/resource hardening. Run unit and CLI tests, strict lint,
instrumentation, GPU capture, soak, cancellation, disk-full, low-memory, thermal,
mutation, and exact-app reopen evidence across supported tiers and formats.

R13 produces a release-ready candidate only. It does not authorize a tag,
release, publication, production Auto, or claim. Each requires its own accepted
roadmap state and direct operator action.

## 7. Mandatory blockers and negative-result rules

Stop the active phase when any of these conditions applies:

- a required R01 anchor environment is unavailable;
- a required public API contract cannot be satisfied;
- evidence exceeds repository limits and cannot be represented compactly;
- source, fixture, policy, model, or toolchain identity changes during an
  authorizing run;
- a required positive gate fails;
- a commercial run or evidence publication is attempted without the required
  license or redistribution rights;
- an attempted holdout, residual, Auto, claim, tag, release, ruleset, push, or
  pull-request action lacks its required authority; or
- completion would require force-pushing, approving, or merging a pull request.

The intentional absence of production Auto, claim, tag, release, or holdout
authority does not block research, diagnostics, implementation, or hardening
that preserves those boundaries.
Unavailable commercial rights produce a preregistered `not_applicable` result
and block only claims that require that missing comparator; they do not by
themselves block completion of R11.

Do not reinterpret negative evidence as success except where the roadmap defines
an explicit diagnostic or rejection outcome. R05 rejection, R08 diagnostic-only,
and R09 rejection can be valid phase outcomes. A negative R08 keeps R09 blocked.
A failed positive R06 or R07 gate blocks dependent product work and requires an
explicitly reviewed roadmap revision rather than relaxed thresholds.

## 8. R01 kickoff boundary

The receiving implementation task begins by verifying current `main`, creating
an R01 branch, preregistering the four-host capability experiment, and
implementing only R01. It may collect authorized capability/model-readiness
evidence and commit locally. It must stop with a validated local publication
candidate unless the operator directly instructs the next push and pull-request
action. The explicit operator-directed local-continuation exception above now
authorizes local R02-through-R07 implementation only. It does not authorize
holdout access, production Auto, a claim, a tag, a release, push, pull request,
approval, merge, force-push, or repository-setting mutation.
