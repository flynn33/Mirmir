# Deterministic Engine v4 roadmap

Status: 1.3.0 implementation landed; M7 frozen-candidate qualification remains open

Scope: Mirmir deterministic CPU and Metal engines, media pipeline, and durable job workflow

Target release runtime: ASH P06, release-qualified

Baseline: the checked-in P05 CPU reference and Metal preview behavior before v4 work

Current checkpoint: pull request 44 merged the v4 engine, media, workflow, and
qualification tooling into `main` as version 1.3.0. Pull request 45 made the
identity workflow derive the production P06 manifest identity, source revision,
and builder hash from the bundled runtime manifest and pass them into the
runtime load check. The follow-on qualification branch contains hardened
exact-candidate observers, causal recovery evidence, the bounded temporal
parity route, media receipts, and deterministic canonical build tooling. The
5% quality and 20% processing-time gates remain release-blocking until every
lane is recaptured from one final candidate. External lane-contract locking,
causal P06 reproduction receipts, independent PQ/HLG pixel oracles, the final
frozen-candidate qualification rerun, Developer ID signing, Apple notarization,
stapling, and publication remain in progress or operator-owned.

## Executive decision

Version 4 should be built as a deterministic media system around the canonical
ASH algebra, not as another set of additions to the P05 preview paths. The
central architectural change is an immutable, hash-addressed execution plan
that is produced from a typed media description and consumed by both CPU and
Metal executors. The plan must make format, geometry, scaling, temporal,
metadata, recovery, and verification decisions explicit before pixels are
processed.

Version 4 is releasable only when the same candidate satisfies all of these
gates:

1. At least a **5% quality increase** over the frozen current-engine baseline
   on the locked, currently supported SDR corpus.
2. At least a **20% reduction in processing time** on the locked benchmark
   matrix, measured on the same hardware and software image.
3. Byte-identical CPU/Metal output pixels for every deterministic integer path,
   including NV12 and P010. Container bytes are not required to match when the
   system encoder legitimately writes different non-semantic data.
4. A verified P06 runtime bundle with no P05 preview identity or production
   dependency on an in-memory development artifact.
5. Passing format, geometry, track-preservation, checkpoint, restart, and crash
   recovery conformance gates described below.

The 5% and 20% objectives are release gates, not claims about the initial
foundational changes included with this roadmap.

## What the research establishes

The research sources agree on a valuable separation:

- ASH supplies a finite algebra, deterministic transformations, measurement
  projection, branch aggregation, scoring, and recovery vocabulary.
- The host application supplies typed observations, operational policy,
  temporal storage, media transformations, effects, verification, and durable
  recovery.
- A plan/effect boundary prevents an executor from silently inventing policy.
- A pinned document or fixture does not prove conformance; the actual engine
  must be run against independently derived fixtures.

They also expose defects that v4 must not inherit:

| Research project | Reusable result | Important warning for v4 |
| --- | --- | --- |
| ASH Model | Canonical finite mathematics, measurement/hysteresis contract, strict decoder, depth-four branch grammar, deterministic scoring and tie-breaking | In the reference image implementation, the computed source state anchors branch labels but does not affect reconstruction or ranking. Two message controls also cancel, leaving only 12 pixel-distinct operators for 16 messages. It is a mathematical/prototyping source, not a pixel-quality oracle. |
| ASH Pattern System | Typed immutable records, stable registries, exhaustive finite tests, plan/emitter split, explicit diagnostics and recovery classes | Its composition root does not wire the whole specified system. Default validity admits all 512 states, safe halt is a record rather than an enforced runtime mode, and its three selected branch codewords have rank two, reaching only four states while allocating an exponential ternary tree. |
| Aeostara | Observe → canonicalize → plan → policy → execute → verify → recover; protocol boundaries; injected time/IDs; audit causality | The platform apps implement deterministic JSON diff/repair, not the pinned ASH lifecycle. Some conformance checks are circular, policy can fail open, critical errors are suppressed, and durability is incomplete. Version pins and passing static fixtures must never substitute for executable conformance. |

### Normative ASH mathematics

The v4 core must preserve these invariants exactly:

1. The state space is

   \[
   V=\mathbb{F}_2^9
   \]

   with coordinate 1 represented by the most-significant of the nine packed
   bits.

2. The integrity hyperplane is

   \[
   E=\{x\in V:x_9=x_1\oplus x_2\oplus\cdots\oplus x_8\},
   \]

   containing 256 states.

3. The canonical generator is

   \[
   G=\begin{bmatrix}
   1&1&1&1&0&0&0&0&0\\
   1&1&0&0&1&1&0&0&0\\
   1&0&1&0&1&0&1&0&0\\
   1&0&0&1&1&0&0&0&1
   \end{bmatrix}.
   \]

   The code \(C=\{mG:m\in\mathbb{F}_2^4\}\) is the fixed 16-member
   \([9,4,4]\) subgroup, lies in \(E\), and keeps coordinate 8 invariant.

4. A strict decode accepts only a unique codeword at distance zero or one. It
   never guesses at distance two. Across all 512 states, the canonical outcome
   counts are 16 exact, 144 corrected, and 352 rejected.

5. The action is full-state XOR, \(x\mapsto x\oplus c\). Its 32 orbits are the
   16-member cosets \(x+C\).

6. The orbit-averaging operator is

   \[
   Tf(x)=\frac{1}{16}\sum_{c\in C}f(x\oplus c),
   \]

   so it is linear, orbit-invariant, and idempotent: \(T^2=T\).

7. The canonical image projection measures eight declared signals—mean,
   contrast, edge, texture, chroma, horizontal change, vertical change, and
   temporal evidence—then derives coordinate 9 from integrity. Thresholds,
   hysteresis, measurement windows, boundary behavior, and reset rules are
   versioned parts of the runtime, not incidental constants.

8. The canonical depth-four branch grammar uses actions `0`, `+`, and `−` with
   probabilities 1/2, 1/4, and 1/4. Its 81 leaves aggregate into 16 message
   classes before reconstruction and deterministic scoring/tie-breaking.

The canonical codeword table is sorted by numeric codeword, while final ranking
ties are sorted by numeric message. P06 therefore carries explicit
message-to-codeword and codeword-to-message tables; neither ordering may be
inferred from a CSV row number.

The fixed ASH9 state must not be stretched into a generic container for HDR,
alpha, field order, scale, metadata, or queue status. Those belong in typed
media and execution-plan records. Arbitrary scale is an input to the operator
and sampling plan; temporal history is evidence used by the ASH projector and
reconstructor. Neither changes the canonical codeword set.

### Evidence in the current repository

The 1.3.0 landing closed the shipping-target gaps recorded when this roadmap
was proposed. Remaining work is frozen-candidate proof, not missing engine
surface:

| Area | 1.3.0 evidence | Remaining release work |
| --- | --- | --- |
| Runtime identity | Bundled ASH P06 runtime with a hashed manifest and fail-closed loader. Product support no longer labels the deterministic routes as P05 previews. CI derives the manifest identity, source revision, and builder hash from that bundle and passes them into the production load check. | Bind the exact archived executable and sealed candidate identities through the final M7 rerun. |
| Scale | Shared fixed-point CPU and Metal execution accepts independent rational scale factors and arbitrary integral target dimensions within the documented limit. | Keep the arbitrary-geometry corpus on the frozen candidate, including odd legal dimensions. |
| Temporal state | Bounded, motion-compensated temporal history with scene/reset policy, tiled schedules, and checkpoint/resume payload identity. | Recapture the packaged seek-reset and repeated-pattern rows on the frozen candidate. |
| Backend parity | One fixed-point kernel IR, coefficient set, and rounding contract feed both executors. Qualification tooling requires visible-plane equality. | Replay packaged parity on the frozen candidate, including the forced multi-tile temporal case. |
| Runtime artifacts | A generated P06 bundle is checked in, hashed, and loaded by the shipping target. | Bind both clean builds to the sealed candidate source tree, exact commands/transcripts, and runtime outputs, then replay them on the final commit. |
| Media formats | Native NV12, P010/HDR, field-aware deinterlacing, rational SAR/aperture geometry, and ProRes 4444 alpha are implemented without an implicit 8-bit bridge. | Lock independent absolute PQ/HLG and deinterlace pixel oracles, then recapture the archived executable. |
| Tracks | The whole-asset planner assigns every enabled track an explicit process, transcode, pass-through, or consent-bound drop action. | Preserve that plan through packaged media qualification and the notarized smoke lane. |
| Atomic output | Work artifacts are registered, validated, and published atomically. Launch recovery reconciles registered partials. | Recapture the two-process exact-binary recovery matrix on the frozen candidate. |
| Job workflow | Durable bookmark-backed queue, pause/resume, segment checkpoints, assembly, and crash containment are wired into the application. | Operator signing, notarization, stapling, and publication remain outside repository automation. |

## Measurable v4 release contract

### Freeze the baseline first

Milestone 0 must record a reproducible current-engine baseline before algorithm
calibration starts:

- exact source commit and uncommitted-diff status;
- macOS, Xcode, Swift, Metal compiler, GPU, CPU, memory, codec, and power mode;
- input hashes, track manifests, target dimensions, runtime identity, and output
  hashes;
- Release builds with logging and diagnostic serialization excluded from timed
  pixel loops;
- five untimed warmups followed by at least ten measured runs;
- engine-only time, decode/encode time, end-to-end wall time, peak resident
  memory, frame latency, and GPU counters where available;
- median, p95, dispersion, and thermal-state rejection criteria.

The first clean Debug suite run for this roadmap succeeded. Its short-clip tests
took approximately 7.20 seconds through the CPU reference and 1.38 seconds
through Metal. These numbers are diagnostic evidence only; they are not the
Release baseline used by the v4 gate.

### Quality gate: at least 5%

The primary comparison uses only media accepted by both the current engine and
v4, so adding support for previously rejected inputs cannot inflate the score.
The paired corpus starts with native high-resolution progressive SDR sources,
creates locked low-resolution inputs with one declared downsampling procedure,
and keeps content families separate: natural detail, text/graphics, animation,
faces, low light/noise, high motion, and scene cuts.

Define a preregistered weighted error `E` from normalized lower-is-better
components:

| Component | Weight |
| --- | ---: |
| Luma multiscale structural error | 0.35 |
| Chroma multiscale structural error | 0.15 |
| Perceptual feature distance | 0.20 |
| Motion-compensated temporal/flicker error | 0.20 |
| Edge displacement, ringing, and overshoot error | 0.10 |

Each component is normalized to the frozen current-engine result on the same
clip/cohort, making the baseline aggregate `E = 1`. Report the quality index as

\[
Q_{ASH}=100\left(2-E_{candidate}\right).
\]

The baseline is therefore 100 and the v4 release gate is at least 105. The
lower bound of a paired 95% bootstrap confidence interval must also be at least
105. In addition:

- no content cohort may regress more than 1% on luma structural quality;
- temporal error may not regress on any motion/scene-cut cohort;
- geometry, alpha, range, and required metadata are exact conformance checks,
  not weighted quality points;
- HDR/P010, interlaced, alpha, and other newly supported classes receive their
  own absolute correctness and quality thresholds because v3 has no comparison
  output;
- the scored output must come from the declared deterministic backend with no
  hidden Apple-backend substitution.

Matched ablations are reported beside the score: uniform versus
state-conditioned priors, real versus randomized ASH state/message assignment,
temporal hysteresis on/off, and motion/history policy on/off. This separates the
quality contribution of ASH policy from improvements made only by a stronger
operator bank.

Metric implementations, model versions, corpus hashes, crop/border rules, and
normalization constants are themselves locked release artifacts.

### Processing-time gate: at least 20%

For every mandatory benchmark class, compute

\[
R_T=\frac{T_{v4}}{T_{baseline}}.
\]

The aggregate corpus wall time and the median engine-only frame time must both
satisfy `R_T ≤ 0.80`. The p95 frame time must also be no greater than 0.80 of
baseline. Measurements use identical inputs, target sizes, codec settings,
hardware, OS/toolchain image, warmup rules, and thermal envelope. A run that
drops tracks, precision, temporal work, verification, or output quality is not
comparable.

Peak memory must remain within the baseline plus a separately approved bounded
temporal-history budget. Queue journaling and metadata copying are measured
end-to-end but are kept outside per-pixel kernel timing.

## Target architecture

```mermaid
flowchart LR
    A["Media probe + user request"] --> B["CanonicalMediaState"]
    B --> C["Pure v4 planner"]
    R["P06 RuntimeManifest + locked assets"] --> C
    C --> P["Hashed ASHExecutionPlan"]
    P --> J["Durable job reducer"]
    J --> X{"Declared executor"}
    K["Shared fixed-point ASH kernel IR"] --> X
    H["Temporal history + motion state"] <--> X
    X --> V["Pixel + semantic verifier"]
    V --> O["Atomic segment assembly + commit"]
    J <--> D["Append-only events + checkpoints + artifact manifest"]
    D --> H
    V -->|"failure"| J
```

### 1. `CanonicalMediaState`

Probe once and construct one immutable, typed record containing:

- ordered track identities and enabled states;
- encoded and presentation raster, preferred transform, clean aperture, and
  rational pixel aspect ratio;
- pixel format, bit depth, range, chroma subsampling/siting, alpha model, and
  premultiplication state;
- color primaries, transfer function, matrix, mastering-display and
  content-light metadata, and dynamic HDR metadata when present;
- field count, dominance, cadence, rational timebase, edit lists, and duration;
- audio, subtitle, caption, chapter, timecode, and auxiliary metadata tracks;
- stable input hashes and a security-scoped bookmark reference.

Malformed, contradictory, unknown, and unsupported observations remain typed
diagnostics. They are not converted to `nil`, generic dictionary keys, or a
silent default.

### 2. Pure `ASHCoreV4`

Keep the finite core synchronous, immutable, and independent of AVFoundation:

- packed `ASHState9` and `ASHMessage4` values;
- the exact fixed generator/codeword constants;
- precomputed strict decode, orbit, representative, and 512×16 transition
  tables;
- orbit averaging implemented once per orbit;
- exhaustive algebraic fixtures and independently generated certificates;
- separate types for algebraic well-formedness, operational admission, runtime
  health, and recovery state.

Strict affine decoding is used when a state/codeword crosses a transport,
checkpoint, or other validation boundary. A hot path that already owns the
canonical message should not decode its own known branch label merely to match
an architectural diagram.

The 1.3.0 landing includes the immutable 512-entry strict-decode table and
the remainder of the pure core: packed states, fixed generator and codeword
constants, exhaustive certificates, and separate algebraic, admission, health,
and recovery types.

### 3. Versioned measurement and policy projection

`ASHMeasurementContract` maps typed, normalized image evidence to the canonical
nine bits. It freezes windows, border extension, fixed-point precision,
thresholds, hysteresis, color-domain conversions, temporal evidence, reset
conditions, and tie-breaking.

The plan stores the contract ID and hash. CPU and Metal do not maintain separate
threshold implementations. State must materially condition candidate weights,
operator choice, or scoring; tests must fail if feature/state changes leave all
rankings and pixels invariant.

The plan also declares the final output rule—fixed top-1 selection or a
specified fixed-point blend. Returning an ordered top-k candidate list without
defining which pixels are emitted is not a complete engine contract.

The depth-four grammar should be compiled offline into a rank-checked,
hash-consed DAG or directly into aggregated message weights. Runtime code must
not allocate an exponential tree per tile. All 16 messages must either have a
declared distinct effect or be intentionally coalesced in the locked operator
manifest.

### 4. Arbitrary rational scale

Scale is represented per axis as a reduced rational derived from source and
target rasters. For destination center `j`, the source-center coordinate is
computed exactly as

\[
p(j)=\frac{(2j+1)S-T}{2T},
\]

where `S` and `T` are the source and target extents. The planner stores the
integer base sample and reduced phase remainder, avoiding backend-dependent
floating coordinate drift.

Offline tooling generates or validates a bounded polyphase/operator bank.
Unseen rational phases are generated deterministically from the locked P06
coefficient procedure during planning, then hashed into the execution plan.
Both axes may differ. The product remains an upscaler by policy, but the ASH
kernel is no longer limited to 2× or 3:2.

### 5. Shared fixed-point kernel IR and backend parity

CPU and Metal consume the same ordered operations, coefficients, normalization,
clamp points, and round-to-nearest/tie rule. Integer accumulators are sized from
proved bounds. The Metal compiler uses the locked settings recorded in the
runtime manifest.

Parity is checked before encoding:

- exact visible bytes for every plane;
- exact attachment semantics;
- stride/padding adversaries and odd legal dimensions;
- NV12 full/video range, P010, alpha planes, every rational phase, temporal
  resets, and scene cuts;
- repeated runs, cross-process runs, and deterministic tile scheduling.

If a stage cannot meet byte parity, it is not part of the deterministic v4
route until it is converted to the shared integer contract. A floating-point
tolerance is useful for exploratory comparison but is not the final v4 claim.

### 6. Temporal ASH reconstruction

Temporal state is an ordered external record, not extra canonical ASH bits. A
bounded tile history stores frame identity, rational PTS, normalized samples,
motion vectors, confidence, prior ASH state, and scene/cadence status.

The first implementation should use deterministic fixed-point block matching
with a fixed search window and a total tie order such as `(cost, |dx| + |dy|,
dy, dx)`. Motion-compensated residual and confidence feed the canonical
temporal measurement; aligned history contributes to candidate scoring and
reconstruction. Scene cuts, seeks, gaps, format changes, field discontinuities,
and checkpoint incompatibility reset history and use the spatial fallback.

Tests must prove that:

- history changes decisions on declared temporal fixtures;
- a reset produces exactly the declared spatial result;
- no future frame is observed;
- CPU and Metal use identical motion/tie decisions;
- resumed processing restores the same bounded history and pixels as an
  uninterrupted run.

### 7. Durable job reducer

Use a single enforced transition reducer, not independent UI booleans:

```text
queued → probing → planned → running ↔ pausing → paused
       → verifying → committing → completed
       → recovering → contained → failed / safe-halt
```

Every accepted transition appends an ordered event carrying job/attempt ID,
event ordinal, previous-event hash, plan hash, runtime hash, input/output hashes,
diagnostic parents, and checkpoint/artifact references. Illegal transitions,
especially after a terminal state, fail closed.

Pause/resume operates at independently decodable segment boundaries. A
monolithic in-progress `.mov` is not treated as safely resumable. Each
checkpoint atomically commits:

- last completed input and output timestamp/frame;
- segment hashes and codec settings;
- temporal history and ASH hysteresis state;
- track/metadata progress;
- plan/runtime identity and security bookmark references.

At launch, the job store activates the relevant bookmarks and reconciles every
registered partial artifact. A compatible job resumes from its last committed
segment; an invalid or obsolete artifact is quarantined or removed according to
explicit policy and recorded as an event. No `.partial.mov` is left as an
unowned hidden file.

## Limitation-to-delivery matrix

| Required limitation | v4 implementation | Release evidence |
| --- | --- | --- |
| P010 / 10-bit HDR | Native bi-planar 10-bit ingest, fixed-point processing at retained precision, 10-bit-capable encode, and full static/dynamic HDR attachment migration. Preserve HDR by default; tone mapping is a separately named optional route, never silent. | Code-value fixtures, PQ/HLG ramps, BT.2020 matrix cases, mastering/CLL round trips, no 8-bit intermediate, readable output. |
| Interlaced video | Field-aware normalization before spatial/temporal ASH; explicit dominance and cadence; deterministic motion-adaptive deinterlacing to progressive output. | TFF/BFF, cadence change, combing, field timestamp, scene-cut, and CPU/Metal fixtures. |
| Non-square pixels | Rational presentation geometry in the plan; scale raster and sample aspect ratio deliberately, preserving display aspect exactly. | SAR round trips and display-geometry equality across portrait/rotation cases. |
| Clean aperture | Compose clean-aperture, preferred-transform, SAR, and scale matrices with rational arithmetic; update aperture metadata or explicitly bake the crop. | Edge/crop fiducials and exact output aperture checks. |
| Alpha video | Typed straight/premultiplied alpha; 4:4:4:4 working/output formats; color reconstruction separated from declared alpha preservation/enhancement; compatible codec such as ProRes 4444. | Transparent-edge, zero-alpha color, premultiplication, alpha byte/parity, and codec fixtures. |
| Multiple enabled video tracks | Ordered per-track plan. Each enabled track receives an explicit process, transcode, pass-through, or user-approved drop action; the default is preservation, not first-track-only selection. | Multi-angle/alternate-video fixtures, ordering, timing/edit-list, and no-unplanned-drop checks. |
| Full metadata and auxiliary tracks | Build a track graph and migrate all audio, subtitle, caption, chapter, timecode, timed metadata, and auxiliary tracks. Transcoding is explicit when pass-through is impossible. | Track-count/type/order/language/role, sample timing, chapter, timecode, caption, and metadata semantic comparisons. |
| Arbitrary ASH scale | Exact rational coordinate/phase plan and deterministic coefficient generation for arbitrary target width/height within codec/hardware limits. | Coprime, fractional, anisotropic, odd-dimension, 1.5×, 2× compatibility, border, and parity corpus. |
| Temporal reconstruction | Motion-compensated bounded history, canonical temporal evidence, scene/reset policy, temporal scoring/reconstruction, spatial fallback. | Motion, occlusion, repeated pattern, scene-cut, cadence, seek, and resume-identity corpus; ≥5% quality gate. |
| CPU/Metal pixel parity | Shared fixed-point kernel IR, coefficients, rounding, clamps, scheduling-independent reductions. | Byte equality for visible planes across the full conformance matrix and repeated/cross-process runs. |
| P06 release lock | Reproducible signed/hashed runtime manifest containing measurement schema, operator bank, LUTs, code certificates, Metal library/compiler identity, and corpus IDs; verified at load. | Clean-build reproduction, tamper/failure tests, artifact hash match, no shipping P05/development identity. |
| Persistent batch queue | Durable ordered jobs with canonical request/plan/runtime data, security bookmarks, attempts, priorities, and terminal history. | Kill/relaunch ordering, schema migration, corrupt-ledger containment, bookmark denial, and multi-job tests. |
| Pause and resume | Segment checkpoints including temporal/hysteresis state and exact track progress; deterministic final assembly. | Pause at every boundary and compare final pixels/tracks/hashes semantically with uninterrupted output. |
| Crash recovery | Registered artifact manifest and launch reconciliation; resume compatible work, quarantine/report invalid work, remove confirmed orphans. | Forced termination before/after every event/checkpoint/commit, disk-full, partial-write, and stale-artifact tests. |

## Delivery sequence

The milestones are ordered by dependency rather than calendar date. Media and
workflow lanes can proceed in parallel after the plan schema is frozen.

### M0 — Baseline and executable evidence

Status: landed in 1.3.0

Deliver:

- locked input corpus and independently versioned metric tools;
- Release benchmark harness and baseline manifest;
- current CPU/Metal output corpus and difference maps;
- full ASH algebra certificate tests;
- profiler traces identifying hot kernels, copies, allocations, and
  decode/encode boundaries.

Exit: the baseline can be recreated from a clean checkout on the reference
machine, and CI rejects missing corpus/runtime identities.

### M1 — Semantic spine and P06 artifact pipeline

Status: landed in 1.3.0

Deliver:

- `CanonicalMediaState`, `RuntimeManifest`, `ASHExecutionPlan`, verification
  plan, canonical JSON encoding, and SHA-256 plan identity;
- pure `ASHCoreV4` with fixed constants and exhaustive certificates;
- one P06 build tool that produces all runtime artifacts and provenance;
- loader that verifies every schema/hash and fails closed;
- one canonical diagnostic/event envelope with stable ordering.

Exit: a request produces the same plan hash across processes; tampered or
incomplete runtime assets cannot prepare an engine.

### M2 — Spatial v4, arbitrary scale, parity, and hot-path efficiency

Status: implementation landed in 1.3.0; frozen-candidate performance proof remains part of M7

Deliver:

- exact rational geometry and phase planner;
- shared fixed-point kernel IR and CPU reference executor;
- Metal executor consuming the same IR/artifacts;
- offline branch aggregation/rank checks and distinct-operator audit;
- fused analysis/selection/reconstruction kernels, reusable buffers, bounded
  tile pipeline, cached Metal state, and ordered deterministic reduction.

Exit: arbitrary-scale conformance and byte parity pass; engine-only median and
p95 time are at most 80% of baseline on the spatial benchmark subset.

### M3 — Temporal quality

Status: implementation landed in 1.3.0; the 5% quality gate remains a release blocker

Deliver:

- deterministic motion analysis, confidence, scene/cadence detection, and
  history reset contract;
- temporal measurement, state-conditioned scoring, reconstruction, and spatial
  fallback;
- bounded history serialization for checkpoints;
- quality calibration tools that never enter the release runtime.

Exit: the lower confidence bound of `Q_ASH` is at least 105, temporal cohorts do
not regress, resume identity passes, and the performance gate remains green.

### M4 — Pixel formats and presentation geometry

Status: landed in 1.3.0

Deliver:

- P010/HDR path and HDR metadata migration;
- deterministic field-aware deinterlacing;
- rational SAR/clean-aperture/transform composition;
- straight/premultiplied alpha and alpha-capable output path;
- format-specialized buffer pools without unconditional full-frame bridges.

Exit: all format/geometry rows in the delivery matrix pass pairwise and
mandatory combined fixtures with no silent tone map, crop, alpha loss, or
precision reduction.

### M5 — Track graph and metadata preservation

Status: landed in 1.3.0

Deliver:

- ordered multi-video-track processing plan;
- alternate audio, subtitles, captions, chapters, timecode, timed metadata, and
  auxiliary-track migration;
- explicit compatibility/transcode/drop policy and semantic output verifier.

Exit: the verifier accounts for every enabled input track and metadata group;
any loss requires an explicit plan action and user consent.

### M6 — Durable queue, pause/resume, and crash recovery

Status: implementation landed in 1.3.0; exact-binary fault injection remains part of M7

Deliver:

- append-only job/event store with atomic snapshots and migrations;
- security bookmark lifecycle and input TOCTOU revalidation;
- segment/checkpoint writer and deterministic final assembly;
- launch reconciliation, quarantine, orphan cleanup, and recovery UI;
- fault injection at every durable boundary.

Exit: forced termination at every injected point produces either an identical
resumed output or an explicit contained failure with no unowned artifacts.

### M7 — Release qualification

Status: qualification tooling landed in 1.3.0; the frozen-candidate rerun is still open

Deliver:

- full matrix on reference and supported machine classes;
- clean-build P06 reproduction and notarized-app smoke tests;
- quality/performance reports with confidence intervals;
- CPU/Metal parity certificate, media preservation report, and recovery report;
- updated product support contract and removal of preview labels.

Exit: every release gate at the top of this document passes on the exact
candidate. A waiver cannot convert a failed determinism, preservation, P06,
quality, or processing-time gate into a release.

Open M7 items after pull request 44:

- finish external contract/tool/corpus locks for every qualification lane;
- finish causal P06 source/build receipts and independent PQ/HLG pixel oracles;
- commit the integrated source and repeat canonical build equality;
- recapture quality, performance, P06, parity, media, and recovery from that
  one candidate;
- capture the operator-signed support matrix and notarized smoke evidence;
- Developer ID signing, Apple notarization, stapling, and release publication.

## Implementation status

Pull request 43 established the algebraic foundation and this roadmap. Pull
request 44 landed the v4 engine, media pipeline, durable workflow, and
qualification tooling as version 1.3.0:

- strict ASH decoding uses one immutable 512-entry lookup table, with exhaustive
  16/144/352, two-bit rejection, and affine single-bit recovery proofs;
- the prepared CPU adapter actor-isolates lifecycle state, supports idempotent
  finish, and rejects later frames just as the Metal adapter does;
- `CanonicalMediaState`, `ASHExecutionPlan`, and the hashed P06 runtime
  manifest are produced before pixels are processed;
- CPU and Metal consume one shared fixed-point contract for arbitrary integral
  geometry, temporal reconstruction, NV12, P010/HDR, interlacing, and alpha;
- the application queue is durable, bookmark-backed, pauseable, and recoverable;
- product support and the README describe the P06 contract rather than the P05
  preview routes.

Pull request 45 then bound the identity workflow to the committed P06 bundle:
the load check now receives the domain-separated manifest identity, source
revision, and builder hash instead of invoking the helper with no trust roots.

These changes close M0 through M6 in source. They do not by themselves satisfy
the 5% quality, 20% processing-time, or frozen-candidate M7 gates.

## Risks and decisions that must remain explicit

- **Calibration boundary:** offline corpus, metric, and tuning tools never enter
  the P06 execution runtime or mutate release assets at runtime. Dormant
  exact-candidate qualification observers may ship so matched ablations execute
  inside the candidate binary, but they remain isolated from normal UI and job
  policy.
- **Quality metric gaming:** corpus, metrics, weights, borders, and exclusions
  are frozen before calibration. Per-cohort non-regression gates remain visible.
- **Deterministic concurrency:** jobs, frames, and tiles may run concurrently,
  but task completion order never chooses IDs, output order, reductions, or
  diagnostic order.
- **Codec resumability:** checkpoints use independently committed segments.
  They do not claim that an arbitrary interrupted AVAssetWriter movie can be
  reopened safely.
- **Security scope:** recovery requires durable bookmarks and explicit access
  failure handling. Startup code must not scan arbitrary user directories.
- **Media preservation:** unsupported pass-through or transcoding is surfaced
  during planning. There is no silent track drop, HDR tone map, alpha removal,
  deinterlace, or backend fallback.
- **Canonical boundary:** ASH mathematics, media semantics, operational policy,
  and workflow state have separate types and versions. Similar vocabulary does
  not make them the same state machine.

## Research provenance

Primary research material reviewed:

- `mirmir-research/ASH-Model-main/docs/canonical-computational-specification.md`
- `mirmir-research/ASH-Model-main/docs/mirmir-integration.md`
- `mirmir-research/ASH-Model-main/ash_model/`
- `mirmir-research/ASH-Pattern-System-Mac-iOS-main/specs/`
- `mirmir-research/ASH-Pattern-System-Mac-iOS-main/MaciOS/Sources/`
- `mirmir-research/ASH-Pattern-System-Mac-iOS-main/MaciOS/Tests/`
- `mirmir-research/Aeostara-Mac-iOS-main/`, including its pinned v1.0.0 base
  and isolated `platform/macos` and `platform/ios` histories

The roadmap treats the canonical ASH specification as mathematical authority,
uses the other projects as software-architecture evidence, and explicitly does
not inherit contradictions or incomplete implementations from any one project.
