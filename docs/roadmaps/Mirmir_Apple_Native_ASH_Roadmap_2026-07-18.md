# Mirmir Roadmap: Apple-Native Adaptive Video Enhancement

**Roadmap version:** 1.0.1  
**Publication date:** 2026-07-18  
**Revision date:** 2026-07-23  
**Product target:** Native macOS application built with Swift, SwiftUI, AVFoundation, CoreVideo, VideoToolbox, Metal, MetalFX, Metal Performance Shaders, Core Image, Accelerate, Core AI, and an app-owned Pattern B module runtime  
**Status:** Strategic replacement for the ASH-as-primary-upscaler direction and the failed monolithic P06 release-closure path

---

## 1. New Product Goal

Mirmir will become an **Apple-native adaptive video-enhancement and upscaling system**.

Apple-native frameworks will perform the numerical reconstruction, temporal super resolution, resampling, denoising, interpolation, and model inference. ASH will provide the deterministic control plane that decides:

- which eligible Apple processing path to use;
- where and when enhancement is appropriate;
- how long a decision should persist;
- when temporal history must reset;
- which areas need protection or additional correction;
- when an output exhibits ringing, ghosting, chroma displacement, flicker, or hallucinated detail;
- when the pipeline must fall back or stop; and
- how every material decision is explained and recorded.

Core AI will provide optional on-device learned perception and bounded residual intelligence. It will not initially carry the entire reconstruction workload.

### North-star hypothesis

> A deterministic ASH orchestration layer, operating over Apple’s native video-enhancement engines and optional Core AI analysis, can produce a temporally stable, artifact-aware, explainable, private, and hardware-efficient upscale while preserving explicit safety and fallback boundaries.

### Product differentiation

Mirmir's product design is defined by these functional differentiators:

1. **Multi-engine orchestration:** use the strongest eligible Apple engine for the current content and hardware rather than imposing one model on every frame.
2. **Temporal governance:** prevent rapid changes in backend, strength, denoise, sharpen, and correction policy.
3. **Artifact governance:** detect and correct edge ringing, halos, ghosting, temporal flicker, chroma displacement, false texture, and protected-region damage.
4. **Explainability:** preserve state, policy, backend, confidence, transition, fallback, and correction reason codes.
5. **Privacy and locality:** perform processing on-device with Apple-native frameworks.
6. **Quality per resource:** optimize quality together with throughput, memory, energy, model-download cost, and initialization latency.
7. **A deterministic mode:** preserve a fully native nonlearned mode for repeatability, unsupported hardware, and user choice.

---

## 2. Explicit Scope Boundaries

### 2.0 Operator observation override

The operator explicitly waived every roadmap gate that requires physical-hardware
execution, a simulator that is unavailable for the project, operator-observed
simulation, or operator-observed hardware operation. None of those conditions is
a blocker or a reason to stop roadmap work. When an observation is unavailable or
not performed, the evidence must say `not_observed`; it must not invent hardware,
API, runtime, model, performance, memory, repeatability, product-qualification,
backend-eligibility, or perceptual-quality results.

At this amendment, every Mirmir target is macOS-only and Xcode advertises only
macOS destinations for the app and R01 worker. Installed iOS/tvOS CoreSimulator
runtimes cannot establish macOS or Mac-hardware capability. A compatible
simulator may still be used automatically if one becomes available, but its
absence cannot block the plan.

Locally available static checks, deterministic doubles, unit and mutation tests,
project generation, builds, and hosted tests remain required when applicable.
Native host probes remain useful supplemental evidence, but they are not required
for R01-R07 phase progression. This override does not waive non-hardware
implementation, static-verification, deterministic-test, safety, privacy,
publication, holdout, or production-authorization gates. It controls over
conflicting hardware, unavailable-simulator, or operator-observation language
elsewhere in this roadmap.

### 2.0.1 Operator software-function acceptance override

Effective 2026-07-22, forward phase acceptance is based on whether the software
performs the task and honors the boundaries it claims. A/B, blinded, ablation,
baseline-superiority, and other comparative methods are outside the forward
roadmap. They are not work items, acceptance gates, or authorization inputs.

Deterministic fixture simulation may establish the software-function contract
when native framework, hardware, simulator, model, or toolchain execution is
unavailable. Such evidence must identify itself as simulation and record every
unavailable native observation as `not_observed`; it cannot manufacture native
execution, model quality, performance, memory, or perceptual claims. Historical
records that contain superseded comparative or negative results remain immutable,
non-authorizing evidence and create no forward work.

### 2.1 ASH responsibilities

ASH is responsible for:

- compact finite-state representation;
- integrity/parity validation of state and policy dispatch;
- temporal hysteresis and transition control;
- branch-based policy evaluation and deterministic tie-breaking;
- backend and pipeline-profile selection;
- confidence aggregation;
- scene-cut and history-reset decisions;
- artifact-risk state;
- per-plane protection and correction policy;
- deterministic fallback governance;
- telemetry and decision explanation.

ASH is **not** responsible for independently reconstructing all missing spatial frequencies or generating the majority of output pixels.

### 2.2 Core AI responsibilities

Core AI enters in three progressively authorized roles:

1. **Analysis-only:** semantic protection masks, artifact-risk maps, source-condition classification, motion reliability, and no-reference quality prediction.
2. **Parameter assistance:** bounded suggestions for backend suitability, denoise strength, sharpening limits, reactive/protection masks, and residual eligibility.
3. **Bounded residual correction:** optional localized residual output after an Apple-native scaler, subject to ASH gating, hard limits, source-consistency checks, and an immediate bypass path.

Core AI is not an unconditional dependency. The pipeline must remain functional when Core AI is unavailable, unsupported, not downloaded, disabled, or rejected by policy.

### 2.3 Apple-method coverage

“All Apple-native upscaling methods” means all public Apple framework families with a direct or supporting role in image/video enlargement, super resolution, resampling, temporal enhancement, and custom on-device model execution that are practical for Mirmir’s product boundary.

Not every backend must be active in every output. Each backend must be:

- compile-probed;
- runtime-probed;
- capability-described;
- software-function tested;
- assigned an explicit role;
- rejected when its input contract cannot be satisfied; and
- available to Auto mode only after its declared functional and reliability
  contracts pass and Auto receives separate authorization.

---

## 3. Repository Work Already Completed

The following inventory is based on the supplied current project documents and repository snapshot. The implementation agent must reconcile this inventory with the exact current Git HEAD before changing source.

### 3.1 Completed and retained as foundational infrastructure

| Completed capability | Current evidence | Roadmap disposition |
|---|---|---|
| Native Swift/SwiftUI macOS application using an app-owned Pattern B module runtime | `README.md`, `ARCHITECTURE.md` | Retain the five-module shape and replace the external package boundary in R00. This remains the composition and dependency-injection foundation. |
| Cohesive UI, Metal, model-assets, media-pipeline, and upscaler-engine modules | `ARCHITECTURE.md` | Retain and extend with capability, orchestration, and Core AI services. |
| AVFoundation ingest, frame sequencing, audio handling, output writing, reopen verification, and atomic publication | Current media-pipeline modules and project documents | Retain. This is the transaction boundary for every new backend. |
| CVPixelBuffer and Metal texture interoperability | Current media and Metal modules | Retain and generalize for VideoToolbox, MetalFX, MPS, Core Image, and Core AI zero-copy paths. |
| Asynchronous Metal command completion and corrected resource lifetime | `CHANGELOG.md`, V3 design | Retain. Reuse for every Metal-backed stage. |
| Three-slot reusable Metal resource ring | `README.md`, `ARCHITECTURE.md`, `CHANGELOG.md` | Retain. Generalize only where backend-specific resource contracts require it. |
| Packed ASH state, parity, code, strict decoder, LUT compiler/loaders, and conformance tests | ASH source, canonical specification, test inventory | Retain as the ASH control-plane core. |
| Plane-aware ASH V3 Metal analysis, dispatch, luma/chroma reconstruction, and fixed-size telemetry | `README.md`, `ARCHITECTURE.md`, `CHANGELOG.md` | Retain as a deterministic reference backend and a reusable analysis/telemetry substrate. Do not retain it as the presumptive best reconstruction engine. |
| Direct 2× and direct 3/2× route handling for 8-bit NV12 `420v`, BT.709, video range, left-sited chroma | Current locked spatial contract | Retain as the first supported contract. Expand later rather than rewriting it immediately. |
| Output identity metadata and post-encode reopen validation | `README.md`, V3 design | Retain and expand to record selected Apple backend, ASH decision identity, Core AI model identity, and fallback history. |
| Fail-closed exact-resource loading, canonical validation, hashes, CRCs, and exact build injection | `README.md`, `ARCHITECTURE.md`, V3 design | Retain for versioned policy tables and model assets. Simplify where the old release closure was specific to the failed V3 operator selection. |
| Extensive source tests, guardrails, lint, Debug/Release builds, and historical 280-test checkpoint | `README.md`, `CHANGELOG.md` | Retain. Fresh same-commit results remain required. |
| Offline quality metrics, calibration documents, immutable evidence concepts, and exact-app measurement infrastructure | `validation/`, P06/P08 documents | Repurpose for backend contract verification, bounded policy calibration, and release evidence. |
| Scandinavian macOS UI theme, workflow screens, application icon, and workspace controls | Current UI modules and assets | Retain. Add simple product modes rather than exposing framework internals by default. |

### 3.2 Completed work to repurpose

| Existing work | New role |
|---|---|
| ASH V3 operator bank and reconstruction kernels | Deterministic reference, conservative fallback, analysis support, and localized correction kernels. |
| ASH immutable LUT infrastructure | Versioned policy dispatch from ASH state/context to pipeline profiles, not merely state-to-pixel operators. |
| P06 scheduler and checkpoint infrastructure | Bounded deterministic policy execution and evidence publication; not another broad 42-coordinate search. |
| G04/G05/P08 parity and performance concepts | Backend conformance, deterministic repeatability, exact-app performance, and resource qualification. |
| Model-assets service and VideoToolbox staging work | Real VideoToolbox super-resolution model readiness/download management and Core AI asset specialization/cache management. |
| Existing telemetry catalog | Unified Apple backend, ASH state, Core AI inference, artifact, timing, memory, and fallback telemetry. |

### 3.3 Premises and mechanisms to retire

- ASH must reconstruct the entire frame to justify its use.
- The packed ASH state must be the sole source of continuous reconstruction information.
- A broad adaptive search over the old operator space is the next step.
- A monolithic P06 process must complete calibration, validation, selection, release, and export in one transaction.
- A quality failure can be solved by making the same experiment merely resumable.
- A silent fallback is acceptable.
- A whole-frame opaque Apple backend can be switched independently for every tile.
- Treating source presence, tests, or fixture parity as sufficient to establish
  perceptual-quality claims.

---

## 4. Target Architecture

```text
AVFoundation decode and source normalization
        |
        v
AppleCapabilityRegistry
  - OS and hardware
  - supported APIs/revisions
  - supported scale factors
  - supported pixel formats
  - model readiness
  - memory and thermal budget
        |
        v
ContentAnalysisGraph
  - deterministic Metal/MPS analysis
  - ASH canonical feature/state analysis
  - optional Core AI perception/risk analysis
  - scene-cut and motion-confidence analysis
        |
        v
ASHOrchestrationEngine
  - current and previous state
  - continuous sidecar context
  - branch/policy candidates
  - hysteresis and minimum dwell
  - backend eligibility
  - protection/correction masks
  - explicit decision and fallback reason
        |
        v
EnhancementPipelinePlan
  - preprocessing stages
  - one primary whole-frame upscale backend
  - localized postprocessing stages
  - temporal stabilization policy
        |
        v
Apple-native processing graph
  - VideoToolbox / MetalFX / MPS / Core Image
  - vImage / VTPixelTransfer / custom Metal
  - optional Core AI residual stage
        |
        v
ASHPostflightQualityMonitor
  - ringing/halo
  - ghosting/flicker
  - chroma displacement
  - text/face/line protection
  - no-reference quality
  - fallback/correction decision for next frame
        |
        v
AVFoundation encode, metadata verification, reopen, atomic publish
```

### 4.1 Architectural rule: frame-level versus tile-level control

VideoToolbox super resolution and MetalFX scalers are session/texture-level engines. Mirmir must not pretend they can be freely mixed per tile unless the public API and measured implementation support that composition.

ASH therefore controls:

- the primary backend at shot, scene, or frame granularity;
- minimum dwell before switching;
- history reset at scene cuts;
- full-frame preprocessing;
- masks and strengths for localized postprocessing;
- selective Core AI residual correction; and
- fallback on backend failure or quality risk.

Custom Metal, MPS, and Core Image stages may operate on tiles or masks around the whole-frame primary result.

### 4.2 Core interfaces

The implementation should introduce modular object-oriented boundaries equivalent to:

```text
AppleUpscaleCapabilityRegistry
AppleUpscaleBackend
AppleUpscaleSession
EnhancementStage
EnhancementPipelinePlanner
ASHOrchestrationEngine
ASHDecisionContext
CoreAIAnalysisService
CoreAIResidualService
PostflightQualityMonitor
EnhancementTelemetryRecorder
```

The application composition chooses concrete implementations through Mirmir-owned module factories. Backends do not inspect application UI state, mutate global configuration, or silently construct substitutes.

---

## 5. Apple-Native Method Inventory and Assigned Roles

### 5.1 Dedicated VideoToolbox super-resolution and temporal processors

| Apple method | Intended Mirmir role | ASH relationship | Initial disposition |
|---|---|---|---|
| `VTSuperResolutionScalerConfiguration` + `VTSuperResolutionScalerParameters` through `VTFrameProcessor` | Primary offline **Quality** backend. Use ordered source frames, previous source, previous output, and optional optical flow. | ASH chooses eligibility per shot, resets history at cuts, governs pre/post stages, and monitors temporal artifacts. | Highest-priority production integration. |
| `VTLowLatencySuperResolutionScalerConfiguration` | Primary **Fast/Preview** backend and possible throughput-oriented export mode. Query supported scale factors and pixel formats at runtime. | ASH selects it when latency/resource pressure dominates and quality remains within policy. | High priority after quality SR. |
| `VTLowLatencyFrameInterpolationConfiguration` with spatial scale | Optional combined 2× spatial upscale plus one interpolated frame where supported. | ASH controls whether frame interpolation is appropriate and suppresses it around cuts, unreliable motion, text, and occlusions. | Optional product capability after spatial quality is stable. |
| `VTFrameRateConversionConfiguration` | Optional frame-rate enhancement independent of spatial upscale. | ASH controls scene-cut reset and motion-confidence admission. | Supporting capability, not part of the first upscale release. |
| `VTTemporalNoiseFilterConfiguration` | Precondition noisy/compressed footage before the primary scaler. | ASH controls activation and strength policy using noise, texture, and motion state. | High-value preprocessing experiment. |
| `VTOpticalFlow` / frame-processor optical-flow support | Motion and occlusion evidence for temporal SR, interpolation, and ASH confidence. | ASH consumes reliability and scene-transition evidence, not raw flow as a binary truth. | Required temporal research dependency. |
| `VTMotionBlurConfiguration` | Optional stylistic or cadence correction, not an upscale primitive. | ASH must keep it out of fidelity-oriented modes unless explicitly requested. | Excluded from Auto quality mode. |
| `VTPixelTransferSession` | Pixel-buffer scaling/conversion baseline, color/clean-aperture transfer, and conservative fallback. | ASH records it as a low-complexity fallback, not a super-resolution claim. | Implement as compatibility/reference backend. |

### 5.2 MetalFX

| Apple method | Intended Mirmir role | Material constraint | Initial disposition |
|---|---|---|---|
| `MTLFXSpatialScaler` / `MTL4FXSpatialScaler` | Fast GPU spatial upscale from a color texture; useful baseline and possible fast export backend. | Whole-frame texture scaler; quality and offline decoded-video behavior must be measured. | Implement after capability probe. |
| `MTLFXTemporalScaler` / `MTL4FXTemporalScaler` | Conditional temporal upscale research. | Requires renderer-style inputs including motion and depth, and correct exposure/jitter semantics. Decoded video does not naturally provide all required inputs. | Research-only until an evidence-backed input synthesis path exists. |
| `MTLFXTemporalDenoisedScaler` / Metal 4 variant | Combined neural denoise and upscale. | Designed around renderer auxiliary buffers such as albedo, depth, normals, roughness, motion, and masks. | Do not place on the critical path for ordinary decoded video. Probe only after auxiliary estimation research. |
| `MTLFXFrameInterpolator` | Optional smooth-output mode after a qualified temporal scaler. | Requires accurate motion/depth and presentation pacing. | Later optional feature. |

### 5.3 Metal Performance Shaders

| Apple method | Intended Mirmir role |
|---|---|
| `MPSImageLanczosScale` | Deterministic GPU quality reference and conservative fallback. |
| `MPSImageBilinearScale` | Very fast preview/reference path and diagnostic lower bound. |
| `MPSImageGuidedFilter` | Edge-aware mask, luma-guided chroma, and protection-map reconstruction. |
| `MPSImageLaplacian`, Laplacian pyramids, Sobel, convolution, median, and morphology kernels | Bounded sharpening, detail-band analysis, artifact masks, denoise, halo detection, and localized corrections. |
| MPS temporary images and command-buffer integration | Reduce transient memory and keep the processing graph on GPU. |

### 5.4 Core Image

| Apple method | Intended Mirmir role |
|---|---|
| `CILanczosScaleTransform` | Compatibility/reference scaler and still-frame diagnostic path. |
| `CIBicubicScaleTransform` | Tunable cubic reference and fallback. |
| `CIEdgePreserveUpsample` | Upsample low-resolution masks, chroma guidance, confidence maps, or segmentation outputs while respecting high-resolution luma edges. |
| Other Core Image filters | Color-space, tone, edge, and localized correction stages where CIContext/Metal interoperability is efficient and measurable. |

### 5.5 Accelerate and CPU references

| Apple method | Intended Mirmir role |
|---|---|
| vImage scale with default Lanczos-3 | CPU reference and cross-check for GPU output. |
| vImage high-quality Lanczos-5 | High-quality deterministic CPU reference. |
| vImage custom resampling filters | Ringing-reduction research and exact reference for custom Metal kernels. |
| BNNS/MPSGraph where applicable | Compatibility research for compact custom models; not the primary Core AI runtime once Core AI is available. |

### 5.6 Custom Metal

The existing custom Metal runtime remains important for:

- ASH feature analysis and state packing;
- integrity/parity validation;
- policy-table dispatch;
- artifact and protection mask generation;
- chroma stabilization;
- bounded residual/detail correction;
- per-tile postprocessing;
- telemetry reduction; and
- zero-copy composition around Apple’s whole-frame engines.

It is no longer required to produce the complete upscale by itself.

### 5.7 Core AI and compatibility model runtimes

| Runtime | Intended role |
|---|---|
| Core AI on macOS 27+ | Preferred custom on-device model runtime: analysis, confidence, segmentation/protection, quality prediction, and later bounded residual correction. |
| Core ML compatibility adapter | Optional compatibility path for supported pre-macOS-27 systems if one model can be maintained without compromising architecture or evidence. |
| Metal 4 ML command encoder / tensor operations | Advanced research path for tiny specialized networks that must run inline with Metal processing. Not required for the first Core AI milestone. |

---

## 6. ASH Orchestration Model

### 6.1 Preserve the canonical state; add a sidecar

Do not silently redefine the canonical nine-bit ASH computational specification.

Retain the canonical packed state and its integrity relationship. Add a versioned, immutable `ASHDecisionContext` sidecar containing continuous and categorical data that should not be compressed into nine bits:

```text
frame and shot identity
route and scale factor
plane and chroma siting
continuous canonical feature values
current and previous packed ASH state
state transition and dwell duration
scene-cut confidence
motion and occlusion confidence
noise, blur, compression, and aliasing estimates
face, text, line-art, animation, and UI protection occupancy
backend availability and model readiness
backend-specific quality confidence
memory, thermal, and throughput pressure
current and previous backend
preprocess and postprocess strengths
artifact risk and postflight findings
fallback reason and retry eligibility
```

### 6.2 Branch/message reinterpretation

ASH branch messages should select or rank **pipeline policy profiles**, not directly claim to recover pixels.

A policy profile can encode bounded choices such as:

- denoise off / low / medium / high;
- primary backend family;
- conservative / balanced / detail-oriented postprocessing;
- chroma protection level;
- temporal history retention/reset policy;
- Core AI analysis cadence;
- residual-correction eligibility; and
- fallback preference.

The branch tree can evaluate plausible policy transitions, aggregate duplicate messages, and deterministically select among candidates using quality confidence, artifact risk, temporal transition cost, and resource cost.

### 6.3 State transition rules

- Backend switching requires confidence beyond a hysteresis boundary.
- Each backend has a minimum dwell measured in frames or shot duration.
- Scene cuts reset temporal history and permit immediate reevaluation.
- Fatal backend errors permit immediate failover, but the fallback and reason are recorded.
- Repeated fallback or postflight artifact detection lowers future eligibility for that backend/content class.
- Core AI suggestions never directly bypass ASH limits.
- Whole-frame backend changes cannot occur independently per tile.

### 6.4 ASH software-function test

ASH satisfies its forward functional contract when deterministic tests prove
that it causally controls only the policy decisions it claims, preserves locked
safety and media boundaries, applies transitions and fallback visibly, and emits
complete decision identity.

---

## 7. Core AI Integration Strategy

Core AI is a new OS-integrated, Apple-silicon-focused framework. It supports on-device Swift inference, device specialization, ahead-of-time compilation, zero-copy data paths, stateful execution, model optimization, and dedicated debugging/profiling tools. The roadmap treats it as a macOS 27+ capability tier while preserving a complete non-Core-AI path.

### 7.1 Core AI stage A: analysis-only model

Build or adapt one compact multi-head vision model that operates on a proxy resolution or sparse keyframes and outputs:

- face/skin protection mask;
- text and line-art protection mask;
- animation/UI-content likelihood;
- noise and compression severity map;
- blur and motion-blur estimate;
- aliasing/ringing risk map;
- texture/detail confidence;
- motion reliability/occlusion risk; and
- no-reference quality estimate.

This model does not produce the output frame.

ASH consumes the maps and maintains stable policy decisions over time.

### 7.2 Core AI stage B: bounded parameter assistance

After stage A's software-function contract is accepted, later authorized work may
add model outputs for:

- backend suitability scores;
- denoise-strength limits;
- sharpening/detail limits;
- protection/reactivity masks;
- temporal-history confidence; and
- residual-stage eligibility.

These values remain suggestions. ASH applies clamping, hysteresis, policy constraints, and fail-closed handling.

### 7.3 Core AI stage C: localized residual correction

Only after the prerequisite software-function contracts are accepted and the
operator separately authorizes residual work:

- run a small residual model after the primary Apple scaler;
- operate only on ASH-approved low-confidence regions;
- output a bounded zero-centered residual or correction map;
- clamp by plane, content class, and local edge confidence;
- prohibit direct unbounded replacement of protected areas;
- require source-consistency and temporal-consistency checks;
- preserve an immediate Apple-only diagnostic and rollback path; and
- disable the stage when confidence or resource limits fail.

### 7.4 Core AI model lifecycle

The model pipeline must include:

- reproducible training/evaluation data manifests;
- PyTorch export and Core AI conversion;
- quantization/palettization experiments;
- target-aware model re-authoring where justified;
- `.aimodel` source assets and optional ahead-of-time compiled assets;
- specialization and cache management;
- model hash/version in every output identity;
- Core AI Debugger validation against reference tensors;
- Xcode debug gauge and Instruments profiling;
- zero-copy CVPixelBuffer or tensor paths where supported; and
- deterministic non-Core-AI fallback.

Foundation Models are not part of the pixel pipeline. They may assist development tooling or metadata workflows, but they are not an upscale backend.

---

## 8. Product Modes

The user-facing product should expose simple intent, not framework names.

| Mode | Behavior |
|---|---|
| **Auto** | ASH selects among qualified Apple backends and supporting stages based on content, capability, history, and resource policy. |
| **Quality** | Prefer VideoToolbox quality super resolution and quality-oriented corrections; tolerate higher latency. |
| **Fast** | Prefer low-latency VideoToolbox SR, MetalFX Spatial, or MPS depending on capability and quality floor. |
| **Deterministic** | No Core AI and no opaque learned SR requirement; use MPS/vImage/custom Metal reference paths with repeatability policy. |
| **Smooth Motion** | Optional spatial upscale plus qualified frame interpolation; explicit because it changes cadence. |

Developer diagnostics may expose individual backends, but the main UI should not ask ordinary users to understand Apple framework internals.

---

## 9. Sequential Roadmap

## R00 — Strategic reset and evidence preservation

**Status:** `passed`

No new production calibration is authorized.

### Work

- Publish the new product goal and architecture decision.
- Mark the old ASH-primary-reconstruction release plan as superseded.
- Preserve all failed and partial P06 evidence.
- Classify current code as retain, repurpose, or retire using Section 3.
- Reconcile the supplied inventory with exact current Git HEAD.
- Freeze holdout data until the new pipeline is preregistered.

### Exit gate

- One accepted architecture decision record.
- One current-source inventory with exact paths and commit.
- No active old P06 process and no claim that its incomplete release is authoritative.

---

## R01 — Apple capability laboratory

**Status:** `passed`

### Objective

Close the A01-A18 capability inventory before production wiring. Record observed
facts when available and explicit `not_observed` diagnostic dispositions when
hardware, simulator, or operator observation is unavailable or not performed.

### Work

Create compile and runtime probes for:

- VideoToolbox quality super resolution;
- VideoToolbox low-latency super resolution;
- VideoToolbox temporal noise filter;
- VideoToolbox optical flow and frame interpolation;
- VTPixelTransfer scaling;
- MetalFX spatial, temporal, temporal-denoised, and frame interpolation;
- MPS Lanczos and bilinear scale;
- MPS guided/detail/artifact kernels;
- Core Image Lanczos, bicubic, and edge-preserve upsample;
- vImage Lanczos-3, Lanczos-5, and custom resampling;
- Core AI model loading, specialization, zero-copy input, stateful execution, and profiling; and
- optional Core ML compatibility.

For every observed capability record:

- OS and SDK requirement;
- hardware support;
- `isSupported` or equivalent result;
- supported scale factors;
- input/output dimensions;
- supported pixel formats;
- color-space expectations;
- model-download requirements;
- state/history requirements;
- offline-video suitability;
- determinism/repeatability observation;
- initialization latency;
- warm throughput;
- memory footprint;
- public API status; and
- reason for rejection or restriction.

### Deliverables

```text
project-notes/apple-upscale-capability-report.md
project-notes/apple-upscale-capabilities.json
MirmirTests/AppleUpscaleCapabilityProbeTests.swift
```

### Exit gate

Every A01-A18 capability has a closed disposition. A `not_observed` record closes
inventory coverage under the operator override but never qualifies a backend,
asserts runtime support, or supplies a performance claim. No backend enters Auto
mode without later evidence that separately satisfies its production gate.

---

## R02 — Unified backend and stage architecture

**Status:** `passed`

### Objective

Make every Apple method interchangeable at a controlled object-oriented boundary without coupling application orchestration to a framework.

### Work

- Add `AppleUpscaleCapabilityRegistry`.
- Add `AppleUpscaleBackend` and `AppleUpscaleSession` protocols.
- Add separate preprocessing, primary scaling, postprocessing, temporal, and analysis stage protocols.
- Add `EnhancementPipelinePlanner` and immutable `EnhancementPipelinePlan`.
- Add explicit `BackendUnavailable`, `BackendRejected`, `BackendFailed`, and `FallbackApplied` outcomes.
- Prohibit silent fallback.
- Bind every output to backend/revision/model/configuration identity.
- Keep existing AVFoundation output transaction and Metal lifetime boundaries.

### Exit gate

A deterministic fixture can run through multiple backends under one common session contract while preserving dimensions, frame order, PTS, duration, audio, metadata, and atomic publication.

### Operator-defined functional acceptance — 2026-07-23

The additive functional phase-acceptance record binds source commit
`eeabc4224100bc8ed86ae1208189bee508844210`, tree
`ac402f993805cca499d2f688c6186c4684ce8dba`, and a fresh six-suite Xcode
run with 27 tests passed, zero failed, and zero skipped. The accepted software
function covers the immutable capability registry, common backend/session
boundary, distinct stage roles, deterministic single-primary planning, typed
outcomes, FIFO lifecycle, complete processing identity, visible fallback,
media-identity preservation, reopen verification, resource lifetime, and atomic
publication. Two direct tests additionally bind production bootstrap to
`UnavailableUpscalerEngineService` and prove its typed fail-closed
`backendUnavailable(reason:)` rejection. That unavailable bootstrap is the
intentional R02 production boundary; it is not project completion or production
enablement.

The frozen R02 preregistration, conformance record, and local unpublished closure
remain immutable historical evidence. Their contemporaneous
`phase_acceptance: not_claimed` state is preserved; this later additive decision
does not rewrite it. R02 is `passed` only for
`declared_software_function_only`. Production upscaling, a production default,
Auto, holdout access, quality or performance claims, product publication, and
release remain unauthorized.

---

## R03 — Deterministic Apple-native baseline suite

**Status:** `passed`

### Objective

Establish trustworthy reference paths before learned super resolution.

### Implement

- MPS Lanczos backend.
- MPS bilinear backend.
- Core Image Lanczos backend.
- Core Image bicubic backend.
- vImage Lanczos-3 and Lanczos-5 references.
- VTPixelTransfer scaling/conversion reference.
- Existing ASH V3/custom Metal deterministic reference backend.
- Core Image edge-preserve and MPS guided-filter support stages for masks/chroma.

### Evidence

- pixel and frame repeatability;
- CPU/GPU parity where applicable;
- ringing, edge, chroma, and resource-bound behavior checks;
- exact same media transaction behavior; and
- no quality claim beyond measured evidence.

### Progress update — 2026-07-20

The frozen R03 contract and catalog were preregistered locally in commit
`21596ebc520ec9bfe604dafa588d16d066f7f492`. The ten-subject implementation is
bound to commit `767cbc4673678a699c3f98903b6c7801a87e91d4` and tree
`9c40a216c21eba77a92d5d1240d4b6475ce5fb48`. The focused macOS Xcode suites for
the shared session, vImage, MPS, Core Image, VideoToolbox pixel transfer,
guided/edge support stages, and ASH comparator pass; SwiftLint reports zero
violations.

R03 remains `in_progress` and is not accepted. Contract preflight found that the
frozen `media-transaction-2x` scenario assigns a 16×8-to-16×8 exact R02 member to
the 1920×1080-to-3840×2160 R03 route. Those contracts cannot be executed together
without changing frozen evidence. The fail-closed conformance record is therefore
`blocked`, the affected media checks fail, and every subject and metric is
`not_observed`. Hardware, simulator, and operator observation were not performed
and are not blockers under the operator override. No 2× media coverage, runtime
support, product qualification, default selection, performance, acceptance,
publication, or release claim is made.

### Product-qualification correction authorization — 2026-07-21

The operator has directed R03 to correct the incompatible media-fixture
composition and establish one qualified primary backend. The frozen v1
preregistration, fixture catalog, and blocked conformance record remain immutable
historical evidence. The correction must be an additive, versioned contract with
an R03-owned 1920×1080-to-3840×2160 media transaction that preserves the R02
audio, timed-metadata, reopen-before-publication, and atomic-publication
semantics.

Only `r03.mps.lanczos` (`A11`) is eligible for this correction because it is the
sole frozen whole-frame subject classified as a candidate after observed
qualification. Product qualification requires the genuine
`MPSImageLanczosScale` implementation to create and process both canonical
routes, deterministic repeatability, exact session/media contracts, and the
versioned qualification checks. Simulated execution may exercise admission,
error, lifecycle, and media seams, but it may not impersonate native MPS
execution. Hardware, simulator, and operator-observed operation remain optional
and truthfully `not_observed` when unused.

This authorization permitted an explicit `product_qualified` capability and
product-scope session admission for the passing A11 implementation only. By
itself, that narrower authorization did not select or enable a production
default, Auto mode, holdout access, phase acceptance, a product quality or
performance claim, publication, release, or any other backend's product
admission.

### A11 functional product-qualification checkpoint — 2026-07-21

The additive [v2 execution receipt](evidence/r03/records/product-qualification-execution-receipt-v2.json)
and mechanically derived [v2 decision](evidence/r03/records/product-qualification-decision-v2.json)
pass for source commit `dfdf1f12ecb22be1c6395d57017bf750fd76496f`, tree
`c3558b90bf647febd900524e7afc40f8c2efbba4`. All 14 preregistered macOS
tests passed with zero failures or skips. The bound run observed genuine
`MPSImageLanczosScale` execution on both canonical routes, three-repeat
determinism, the exact 1920×1080-to-3840×2160 H.264/AAC media transaction,
timing, metadata, reopen verification, resource lifetime, atomic publication,
and an empty fallback history.

Only `r03.mps.lanczos` (`A11`) is `product_qualified`, and only for
`functional_product_eligibility`. The frozen v1 blocked record remains immutable
historical evidence. The v2 decision itself left R03 `in_progress` and did not
claim product runtime support or authorize a production default, Auto, holdout,
phase acceptance, perceptual-quality or performance claims, publication, or
release. It removed the absence of a qualified primary backend as a prospective
cause for a new additive R06 or R07 product-gate run without retroactively
altering either phase's frozen blocked evidence.

### Operator-overridden functional phase acceptance — 2026-07-21

The operator removed the original cross-backend requirement from the roadmap
because it did not determine whether the R03 software performs its intended
task. Frozen records that contain that requirement remain immutable historical
evidence and provide no forward authorization.

The additive [functional phase-acceptance record](evidence/r03/records/functional-phase-acceptance.json)
is bound to qualification publication commit
`b5c19c0040f845b7f32fe98bd5f01249c1b071f2`, tree
`74e39285521fe31f9588cff5e43184c8f91f9180`. Its fail-closed validator rechecks
the passing R02 common-session conformance and the exact R03 v2 receipt and
decision. It accepts R03 only because genuine `MPSImageLanczosScale` processed
both canonical routes repeatably while preserving dimensions, color, frame
order, PTS, duration, audio, metadata, reopen-before-publication, resource
lifetime, complete processing identity, atomic publication, and an empty
fallback history. Every applicable functional metric passed.

R03 is therefore `passed` for `functional_software_phase_acceptance`. The frozen
v1 blocked evidence and narrower v2 decision remain unchanged. This acceptance
does not select a production default or authorize Auto, holdout,
perceptual-quality, performance, product-publication, or release claims.

### Exit gate

One genuine Apple-native primary backend must execute the canonical 3/2× and 2×
routes under the common session contract, repeatably, while preserving
dimensions, color, frame order, PTS, duration, audio, metadata,
reopen-before-publication, resource lifetime, complete processing identity,
atomic publication, and an empty fallback history.

---

## R04 — VideoToolbox super-resolution integration

**Status:** `passed`

### Objective

Implement honest, separately identified quality and low-latency VideoToolbox
super-resolution paths whose runtime, media, lifecycle, identity, and failure
boundaries are explicit and verifiable.

### Work

- Replace any placeholder/fallback-only VideoToolbox super-resolution driver with a real `VTFrameProcessor` session.
- Implement `VTSuperResolutionScalerConfiguration` discovery, revision selection, quality prioritization, model readiness/download, and lifecycle.
- Allocate source/destination buffers from the configuration’s declared attributes.
- Provide previous frame and previous output in presentation order.
- Add optional precomputed optical-flow path and Apple-computed-flow path.
- Implement first-frame and scene-cut history reset.
- Implement explicit sequential/random submission semantics.
- Implement low-latency SR as a separate backend, not a flag hidden inside Quality.
- Record configuration revision, scale, quality priority, supported formats, model status, and processing mode.

### Local implementation start — 2026-07-20

R04 begins only under the operator-directed local-continuation boundary. Its
frozen preregistration binds the exact unpublished R03 closure commit
`947983a8414c60e4f5f4246e6cb658792fc7c357` and tree
`d1a89e5b9edf8d42b1da9ba06a3b6a0c139f08f3`, records
`closure_state: local_unpublished_blocked_closure`, `predecessor_result: blocked`,
`accepted_merge_commit: null`, `acceptance_state: not_claimed`, and limits the
continuation to local implementation.

The bound R03 record is fail-closed and `blocked`; R03 remains `in_progress` and
unaccepted. Starting R04 neither repairs nor accepts that negative evidence.
Hardware, simulator, and operator observation remain non-blocking under the
operator override, while any unavailable runtime result must be recorded as
`not_observed`. No runtime support, quality, performance, product qualification,
production enablement, publication, or release claim follows from this local
start.

### Local implementation and conformance checkpoint — 2026-07-20

The frozen R04 contract was preregistered in local commit
`2a729f9f641ef949681d81ebb3f98f68d7da29fc`, tree
`59bfd516ebfa2260fedaf835d0a32a8f8f7cc6ee`. The implementation source is local
commit `73d6f1df9d9b443209d55a6c9deea29923d49bc4`, tree
`90c45e2c583defc7aa593f9199512719884de0d0`.

That implementation replaces the copy/letterbox placeholder with guarded
macOS 26 `VTFrameProcessor` quality and low-latency sessions. It implements the
quality 2× route, the typed `public_contract_unrepresentable` quality 1.5×
rejection, exact-dimension low-latency admission, configuration-specific model
status, declared-buffer attribute resolution, ordered retained history,
discontinuity reset, explicit submission mode, cancellation/drain behavior, and
optional optical-flow support without promoting it to a primary route. Production
bootstrap behavior remains unchanged and unavailable.

All 39 focused macOS Xcode tests passed, the Swift 6 source and test typechecks
passed, and strict SwiftLint reported zero violations. The focused Xcode run
excluded Metal shader compilation because the optional Metal Toolchain was
unavailable; R04 adds no Metal shader. The commit-bound
`evidence/r04/records/integration-conformance.json` result is
`diagnostic_only`: the quality 2×, both low-latency, and optional optical-flow
runtime subjects are `not_observed`, while quality 1.5× is the frozen typed
contract rejection. Model-backed processing, model readiness, hardware,
simulator, operator-observed operation, quality, and performance were not
observed.

This checkpoint remains immutable historical evidence. Its `diagnostic_only`
result and `not_observed` native runtime subjects are not rewritten by the
later additive functional acceptance.

### Functional software acceptance — 2026-07-23

The additive functional acceptance binds source commit
`ab77e97867d51168e90c0190f6430d4acd769e68`, tree
`446f71bb584f5d1fffcd20a17ac5e5507d3222b6`, and a fresh macOS arm64 Xcode run
of 42 tests across the R04 contracts, session adapter, availability, and
functional phase-acceptance suites. All 42 tests passed with zero failures and
zero skips.

The deterministic simulated runtime processes source-derived frames through the
real R04 quality and low-latency backends and the production FIFO. Both direct
2× routes complete verified 2160p H.264/AAC media transactions with preserved
color, frame order, timestamps, duration, audio, metadata, processing identity,
reopen-before-publication, resource release, atomic publication, and no silent
fallback. The low-latency 1.5× route executes only after the exact dimensions
pass the runtime support query. Active cancellation propagates through both
backend identities without processing or fallback.

R04 is therefore `passed` only for `declared_software_function_only`. The
focused Xcode run excluded Metal shader compilation because the optional Metal
Toolchain was unavailable; R04 adds no Metal shader. Native VideoToolbox model
execution, model readiness/download, hardware, simulator, and operator-observed
operation remain `not_observed`. No backend is selected as a production
default, and no Auto, native-framework, product-qualification, quality,
performance, publication, or release claim follows.

### Satisfied operator-defined exit gate

- Both direct 2× and supported 3/2×/1.5× routes are handled through runtime capability, not assumptions.
- Outputs reopen and preserve media identity.
- Quality and low-latency sessions enforce their declared input, history,
  lifecycle, cancellation, identity, and failure contracts without silent
  fallback.

Unobserved quality or performance values authorize no quality or performance
claim.

---

## R05 — MetalFX integration and suitability decision

**Status:** `passed`

### Objective

Use MetalFX where its public contract fits decoded video, and reject it where required renderer inputs cannot be supplied honestly.

### Work

1. Implement MetalFX Spatial first.
2. Verify its route, media, identity, resource, lifecycle, and failure contracts.
3. Probe MetalFX Temporal using only evidence-backed motion, depth, exposure, and jitter inputs.
4. Do not fabricate depth or renderer semantics merely to make the API run.
5. Probe temporal-denoised scaling only when every required auxiliary-buffer
   input can be represented honestly.
6. Treat MetalFX frame interpolation as a separate cadence feature.

### Local implementation start — 2026-07-20

R05 starts only under the operator-directed local-continuation boundary. Its
frozen preregistration binds the exact local R04 diagnostic-only closure commit
`88e26f5967f7eb35a54791017ca0c2b888f2fbf5` and tree
`4a7cc588b6fa51c21f2293e56cf3dea389acd908`, with
`accepted_merge_commit: null`, `acceptance_state: not_claimed`, and
`continuation_scope: local_implementation_only`. R04 remains canonical
`in_progress`, local unpublished, unaccepted, and unqualified.

The frozen R05 matrix implements only exact A07 spatial 1.5× and 2× routes. It
requires a device-support query before construction and an explicit
left-sited, video-range BT.709 NV12-to-linear-RGBA16Float-to-NV12 bridge; NV12
planes cannot be passed directly to MetalFX and nonlinear RGB cannot be labeled
linear. A08 temporal, A09 temporal-denoised, and A10 frame interpolation are
typed `rejected_for_decoded_video` routes because decoded frames do not provide
the required renderer-semantic motion, depth, jitter, G-buffer, camera, UI, and
output-timing inputs. No such inputs may be fabricated.

Hardware, simulator, and operator observation remain non-blocking under the
operator override. Any unavailable native execution, quality, performance,
baseline comparison, or reopen result must remain `not_observed`. This local
start makes no product-qualification, production-default, quality, performance,
acceptance, publication, or release claim.

### Local implementation and diagnostic-only checkpoint — 2026-07-21

The frozen R05 contract was preregistered in local commit
`6a327428c88f32517bf5cf931e6f18a65a24b5c2`, tree
`bfc53e9077fcb7bcab233ca79c4575ef1f69fda2`. The implementation source is local
commit `3e5188ece317d3ebc492c7a8e26345837836fc67`, tree
`92b15f3948ffa38dc787136177551187bfb2fbbf`.

That implementation provides exact A07 spatial 1.5× and 2× fixture routes, a
left-sited video-range BT.709 NV12/linear RGBA16Float bridge, support-before-
construction guards, shared staging around private MetalFX textures, ordered
completion and publication, retained FIFO ownership, cancellation, typed
failure outcomes, and no silent fallback. A08, A09, and A10 reject decoded-video
admission before any native factory call because their renderer-semantic inputs
are not evidence-backed. Production bootstrap behavior remains unchanged and
unavailable.

All 44 focused macOS Xcode tests passed, the Swift source and test targets
compiled with strict concurrency enabled, and strict SwiftLint reported zero
violations. Metal shader compilation was excluded because the optional Metal
Toolchain was unavailable; R05 adds no Metal shader. The commit-bound
`evidence/r05/records/suitability-conformance.json` result is
`diagnostic_only`: both A07 native runtime subjects are `not_observed`, while
all A08 through A10 subjects carry their frozen
`rejected_for_decoded_video` dispositions. Native MetalFX execution, hardware,
simulator, operator-observed operation, end-to-end media reopen, baseline
comparison, quality, and performance were not observed.

This checkpoint remains immutable historical evidence. Its `diagnostic_only`
result, `not_observed` native runtime subjects, and unclaimed acceptance state
are not rewritten by the later additive functional acceptance.

### Functional software acceptance — 2026-07-23

The additive functional acceptance binds source commit
`7e1ab67340e4d6d95a3d92e8a48bc6cd356005b8`, tree
`adce5b65fd3d752a1467925232847e086d0b3e7a`, and a fresh macOS arm64 Xcode run
of 46 tests across the R05 contracts, color bridge, spatial driver, spatial
backend, and functional phase-acceptance suites. All 46 tests passed with zero
failures and zero skips.

The deterministic simulated driver produces source-derived output through the
real R05 spatial backend and production FIFO for both A07 1.5× and 2× routes.
The 2× route also completes a reopened 2160p H.264/AAC media transaction with
preserved color, frame order, timestamps, duration, audio, timed metadata,
processing identity, resource release, verification-before-publication, atomic
publication, and no silent fallback. The frozen suites separately verify the
real spatial driver's support-before-construction, explicit BT.709 video-range
NV12/linear-RGBA16Float bridge, ordered completion, cancellation, and typed
failure behavior. A08, A09, and A10 retain their honest
`rejected_for_decoded_video` outcomes; those rejections are successful
dispositions for R05.

R05 is therefore `passed` with exit outcome `diagnostic_only`, limited to
`declared_software_function_only`. Comparison-based testing was not run or
required. The focused Xcode run excluded Metal shader compilation because the
optional Metal Toolchain was unavailable; R05 adds no Metal shader. Native
MetalFX execution, hardware, simulator, operator-observed operation, product
qualification, quality, and performance remain `not_observed` or `not_claimed`.
No backend is selected as a production default, and no Auto, publication, or
release authority follows.

### Exit outcomes

- `qualified_spatial`
- `qualified_temporal`
- `qualified_temporal_denoised`
- `diagnostic_only`
- `rejected_for_decoded_video`

A rejection is a valid successful result.

---

## R06 — ASH orchestration engine v1

**Status:** `passed`

### Objective

Move ASH from pixel reconstruction to deterministic pipeline control.

### Work

- Introduce `ASHDecisionContext` sidecar.
- Map branch messages to versioned pipeline-policy profiles.
- Use current/previous state, continuous features, capability, and resource context.
- Select one primary whole-frame backend per decision interval.
- Add hysteresis, minimum dwell, scene-cut reset, failure failover, and reason codes.
- Generate luma/chroma protection and postprocess masks.
- Record candidate policies, selected policy, score components, and transition cost.
- Ensure state and branch perturbations causally alter policy only where the policy contract says they should.

### Functional verification

Deterministic fixtures verify eligible-backend filtering, scoring, stable
tie-breaking, declared state/context influence, hysteresis, dwell, scene-cut
reset, typed failover, bounded masks, identity, and transactional behavior.

### Local implementation start — 2026-07-21

R06 starts only under the operator-directed local-continuation boundary. Its
preregistration binds the exact local R05 diagnostic-only closure commit
`b955fc9d0b02dd066c359dfcb99a9ad31aeb817a` and tree
`10a97bd3df7f72834f7afcb7fa3b63c598fa4931`, with
`accepted_merge_commit: null`, `acceptance_state: not_claimed`, and
`continuation_scope: local_implementation_only`. R06 depends directly on R05;
R04 remains a transitive unresolved dependency through R05. At this frozen R06
start checkpoint, R03, R04, and R05 remained canonical `in_progress`, local
unpublished, unaccepted, and unqualified.

The frozen R06 software slice is fixture-only. It preserves the existing
nine-bit `ASHState`, maps all sixteen four-bit `ASHMessage` values to versioned
policy profiles, uses immutable continuous context, integer score components,
stable lexical tie-breaking, one whole-frame route, typed transition reasons,
hysteresis, minimum dwell, scene-cut reset, fatal failover, and bounded luma,
chroma, and postprocess masks. The six frozen configuration fixtures may be
exercised only as deterministic software checks.

At this frozen R06 checkpoint, no R03-R05 backend was product-qualified. Product
admission therefore stopped before scoring or route construction with
`reason: no_product_qualified_primary_backend`,
`eligible_backend_count: 0`, and null selected route, plan, and output. All six
product configuration subjects remain `not_observed`, and the preregistered
local result is
fail-closed `blocked`. That block is caused by the absence of a product-qualified
primary backend, not by hardware, simulator, or operator observation. Those
observations remain non-blocking `not_observed`. This start makes no product,
quality, performance, default, acceptance, publication, or release claim.

### Local implementation and blocked conformance checkpoint — 2026-07-21

The R06 implementation source is local commit
`9246934c027e97f2b2ae3af35b0c4892154d761c`, tree
`1235596387d4eabd2ecb4ea1a29221c44ec425fe`. It implements the frozen
fixture-only decision context, policy catalog, deterministic whole-frame
orchestration, transition handling, bounded masks, and configuration controls
without enabling a production route.

All 32 focused Xcode tests passed, strict SwiftLint passed across 275 files, all
529 Python governance tests passed, and deterministic software conformance
passed. The frozen product-admission result nevertheless remains fail-closed
`blocked` for
`reason: no_product_qualified_primary_backend`, with
`eligible_backend_count: 0` and null selected route, plan, and output. All
product, hardware, simulator, and operator observations remain `not_observed`.

This is an immutable local unpublished blocked closure, not phase acceptance.
No quality, performance, product, production-default, acceptance, publication,
or release claim follows from this checkpoint.

### Qualified-backend follow-up — 2026-07-21

The later R03 v2 decision product-qualified A11 for functional product
eligibility. The earlier R06 `no_product_qualified_primary_backend` result
remains truthful historical evidence from its bound source and is not rewritten.
Its cause is now cleared prospectively for a separately preregistered additive
R06 product-gate rerun. No product-gate rerun is recorded here, and the later
functional acceptance does not claim product routing or rewrite this history.

### Functional software acceptance — 2026-07-23

The additive functional acceptance binds source commit
`6c4a6d3d5f8a59c553b10c23783c148ccb3388a5`, tree
`beb0f8c666550c6c36dae5a2185cac58d2494132`, and a fresh macOS arm64 Xcode run
of 42 tests across the four frozen R06 suites, the additive functional suite,
and the R07 coordinator and transaction suites. All 42 tests passed with zero
failures and zero skips.

The tests prove deterministic context/profile mapping, eligibility filtering,
integer scoring and stable tie-breaking, one whole-frame plan, reason identity,
hysteresis, dwell, scene-cut reset, fatal failover, bounded masks, and
configuration controls. The additive test supplies higher-scoring
fixture-ineligible and non-whole-frame candidates and proves they cannot enter
the selected plan, candidate ordering cannot change the result, and value inputs
remain unchanged. The real R07 coordinator tests prove state commits only after
the full transaction succeeds and rolls back on failure.

R06 is therefore `passed` only for `declared_software_function_only` under
deterministic fixture integration. It is control-plane software and produces a
plan rather than pixels or a media container, so media reopen is outside its
declared responsibility. The focused Xcode run excluded Metal shader
compilation because the optional Metal Toolchain was unavailable; R06 adds no
Metal shader. The frozen blocked conformance remains unchanged historical
evidence. R06 v1 continues to reject product-scope orchestration; no product
routing, product qualification, production default, Auto, native-framework,
hardware, simulator, operator-observed operation, quality, performance,
publication, or release claim follows.

### Satisfied operator-defined exit gate

ASH orchestration passes its forward software-function gate when deterministic
tests prove eligible-backend filtering, scoring and stable tie-breaking,
hysteresis and dwell, scene-cut reset, typed failover, bounded masks, complete
reason identity, and transactional behavior.

---

## R07 — Temporal stability and artifact governance

**Status:** `passed`

### Objective

Make temporal consistency and artifact avoidance the first major Mirmir differentiator.

### Work

- Add scene-cut detection and history reset.
- Add motion/occlusion confidence.
- Add VideoToolbox temporal noise filtering where qualified.
- Track backend, strength, and artifact states over time.
- Detect ringing, halos, ghosting, flicker, false texture, and chroma displacement.
- Use luma-guided chroma reconstruction and edge-preserving mask upsampling.
- Add protected-region policies for faces, text, line art, animation, subtitles, and UI captures.
- Add postflight feedback that influences the next decision without rewriting completed frames.

### Local implementation start — 2026-07-21

R07 starts only under the operator-directed local-continuation boundary. Its
preregistration binds the exact local R06 blocked closure commit
`9ed01ea938a933f6406fd67e88edb74e7c84f5f4` and tree
`32365e745dbf53d59213fe2294a6b63ba2642df7` as
`local_unpublished_blocked_closure`, with `predecessor_result: blocked`,
`accepted_merge_commit: null`, `acceptance_state: not_claimed`, and
`continuation_scope: local_implementation_only`. At that historical start
checkpoint, R06 was canonical `in_progress`, local unpublished, and unaccepted;
R08 was `planned`.

The R07 local slice is fixture-only temporal and artifact-governance
implementation. Exact temporal, chroma, artifact, churn, protected-region,
spatial-noninferiority, history, fixed-point, threshold, and aggregation
contracts are frozen in the immutable preregistration and fixture catalog before
their implementation or tuning. Deterministic software fixtures and locally
available static, unit, mutation, project, build, and hosted checks remain
required where applicable.

At this frozen R07 start checkpoint, no upstream phase had a product-qualified
primary backend. Product evaluation was therefore fail-closed `blocked` solely for
`upstream_no_product_qualified_primary_backend`, with zero eligible routes and
null selected route, plan, and output. Product temporal, artifact, chroma, and
spatial-quality measurements remain `not_observed`. Hardware, simulator, and
operator-observed operation also remain non-blocking `not_observed` and are not
the blocked cause. This start makes no quality, performance, product,
production-default, acceptance, publication, or release claim.

### Qualified-backend follow-up — 2026-07-21

The later R03 v2 decision product-qualified A11 for functional product
eligibility. The earlier R07 `upstream_no_product_qualified_primary_backend`
result remains truthful historical evidence from its bound source and is not
rewritten. Its cause is now cleared prospectively for a separately preregistered
additive R07 product-gate rerun after the required upstream orchestration path is
available. At that checkpoint, no rerun or product metric had been recorded and
R07 remained `in_progress`, unaccepted, and without a quality, performance,
production-default, publication, or release claim.

### Operator-overridden deterministic software-function acceptance — 2026-07-21

The operator explicitly superseded the comparative R07 acceptance requirement
and directed that phase acceptance be based only on whether the software performs
the temporal and artifact-governance task it was designed to perform. The
comparison against each underlying backend is `superseded_not_required`; it is
historical, non-authorizing context and is not an R07 phase-acceptance gate.

The additive `functional-execution-receipt.json` and
`functional-phase-acceptance.json` records bind implementation commit
`1b46ad469265a6ba837a8449d28b8850889f1d3f`, tree
`09d3a48df01738bb26077aadfd83c08e389a1dc2`. The checkpoint-bound run passed all
98 tests across the 11 settled R07 test classes, with zero failures and zero
skips. The accepted deterministic software function includes temporal
scene-cut, discontinuity, motion-validity, and history behavior; A04 temporal
filtering; distinct-plane A13 luma-guided chroma reconstruction; A15
edge-preserving protection-mask upsampling; artifact and not-applicable
dispositions; protected-region composition; exact N+1 postflight feedback; an
end-to-end coordinator; truthful fixture-simulation identity; and rollback on
failure.

This passes R07 only for
`functional_deterministic_software_phase_acceptance`. Execution is deterministic
fixture simulation. Native framework execution, physical hardware, product
routing, a production default, Auto, media-quality or performance measurement,
product publication, and release are not claimed or authorized. This R07
acceptance did not rewrite R06's frozen evidence. R06's later additive
functional acceptance is recorded above, and R08 later passed under its separate
functional acceptance.

### Superseded historical gate

Frozen R07 evidence preserves an earlier comparative gate as immutable history.
That gate is out of scope, non-authorizing, and creates no forward roadmap work.

### Current operator-defined exit gate

R07 passes when checkpoint-bound deterministic tests verify that its temporal,
artifact, protected-region, support-stage, postflight, and failure-transaction
software performs the contracted task. Unavailable native, hardware, simulator,
or operator-observed execution is recorded as a limitation and is not a blocker.

---

## R08 — Core AI analysis-only integration

**Status:** `passed`

### Objective

Add learned perception where deterministic analysis is weakest, without granting the model control of the final pixels.

### Work

- Add an app-owned `CoreAIAnalysisServiceModule` or cohesive model-assets subservice.
- Define model and pre/postprocessing contracts.
- Run the model on proxy frames, keyframes, or ASH-requested intervals.
- Produce calibrated masks and confidence maps from Section 7.1.
- Feed results into `ASHDecisionContext`.
- Implement specialization cache, AOT compilation option, model identity, zero-copy input, stateful sequence, cancellation, and memory budgets.
- Add deterministic fallback for unsupported macOS/hardware or absent assets.

### Implementation start — 2026-07-22

R08 starts from accepted R07 merge commit
`3fd13e57ec95b1ed98df71f4c83ab165bdfbab6b`, tree
`eb1614dd2a93e1bc4e1911bcf74f41cf372a3304`. Its preregistered slice is an
optional cohesive analysis subservice inside the existing model-assets module;
it does not create a sixth application module or enable Core AI pixel output.

The installed Xcode/Core AI availability affects only native supplemental
observation. Framework-neutral contracts, deterministic simulation, lifecycle,
integration, bypass, and failure behavior proceed without it. Unavailable native
Core AI execution, specialization, AOT, zero-copy, performance, memory, and model
quality remain `not_observed` and unclaimed.

### Functional software acceptance — 2026-07-22

The checkpoint-bound functional receipt and phase-acceptance record bind
implementation commit `368b9284883c189be6a1139df6208bf0e88139dd`, tree
`f8e73d193b7b0c9df7005a7aa006de48ca48f77c`. All 42 selected tests across the
10 settled R08 test suites passed, with zero failures and zero skips. The tested
deterministic fixture simulation verifies the exact nine-head unsigned-Q15
analysis contract, fail-closed output decoding, schedule and identity binding,
bounded specialization caching, behaviorally equivalent simulated AOT paths,
owned-copy input fallback, transactional state and cancellation, single-inflight
execution, fixed memory and latency budgets, bounded `ASHDecisionContext`
integration, protected-mask composition, deterministic bypass, and rejection of
pixel or backend-selection authority.

R08 therefore passes for `declared_software_function_only`. Comparison-based
testing is outside the roadmap and supplied no acceptance or authorization.
Xcode 27, the Core AI
framework, a model asset, native Core AI execution, physical hardware, Apple
simulator execution, and operator-observed operation remain `not_observed`.
This acceptance makes no native Core AI execution or native model-quality,
performance, memory, specialization, AOT, or zero-copy claim, and no
product-qualification, production-default, Auto, pixel-output, publication, or
release claim. That R08 record did not itself authorize R09. The operator's
later 2026-07-22 `resume work` directive separately authorizes only the bounded
R09 experiment described below.

### Satisfied operator-defined exit gate

R08 passes because checkpoint-bound deterministic software-function tests prove
that the optional service validates its input and output contracts; produces the
declared protection, artifact-risk, source-classification, motion-reliability,
and no-reference-quality analysis values; binds model and processing identity;
honors cadence, state, cancellation, cache, and resource-budget behavior; feeds
bounded results into `ASHDecisionContext`; never produces final pixels; and
bypasses deterministically when unavailable or disabled.

Deterministic simulation may satisfy this functional gate while native
observations remain truthfully `not_observed`.

---

## R09 — Core AI bounded residual experiment

**Status:** `passed`

### Objective

Determine whether a small localized model can improve difficult regions without taking over the entire pipeline.

### Work

- Train or adapt a small residual correction model.
- Run only after an Apple-native primary scaler.
- Restrict it to ASH-approved regions.
- Enforce per-plane residual limits and source/temporal consistency.
- Preserve an immediate Apple-only diagnostic and rollback path.
- Add hallucination, text integrity, face identity, and temporal consistency tests.

### Exit outcomes

- `qualified_local_residual`
- `qualified_for_specific_content_class`
- `rejected_no_safe_residual_path`
- `rejected_hallucination_risk`
- `rejected_resource_cost`

The model is not required to ship.

### Operator-authorized implementation start — 2026-07-22

The operator's explicit `resume work` directive supplies the separate R09
implementation authorization required by this roadmap. The repository-owned
authorization record binds the exact raw SHA-256
`0d81917a93cf56cae867c11b7c65fb3c85e53b7596929cf9eec2ef09c24634b0` of
the accepted R08 `functional-phase-acceptance.json`, including its implementation
commit `368b9284883c189be6a1139df6208bf0e88139dd` and tree
`f8e73d193b7b0c9df7005a7aa006de48ca48f77c`. Canonical authorization is now
`core_ai_pixel_residual: authorized_for_r09_bounded_experiment`, and advanced
R09 to `in_progress` at that start checkpoint.

The frozen start contract permits only a post-Apple-scaler, ASH-authorized,
localized signed-Q16 residual proposal and application path. It requires exact
frame, shot, stream-generation, primary-route, model, processing, and contract
identity; all three planes; plan-supplied plane, content, edge, source,
temporal, confidence, and resource bounds; protected face and text exclusion;
an immutable Apple-only diagnostic output; and transactional typed bypass on
every mismatch, safety failure, cancellation, or budget failure. Exact fixture
values are software-test inputs, not product or quality thresholds.

R09 acceptance asks only whether the bounded residual software performs that
declared task. Comparative, A/B, blinded, ablation, and superiority methods are
excluded, non-authorizing, and not required. Truthful deterministic fixture
simulation is permitted; native Core AI, model-asset, hardware, simulator, and
operator-observed execution remain `not_observed` and non-blocking. This start
does not authorize production default, Auto, holdout access, quality or
performance claims, publication, or release.

### Operator-defined functional acceptance — 2026-07-22

The additive functional execution receipt and phase-acceptance record bind
implementation commit `3ba7b2b5fdbde3a3f90f011cb548b85d46b2ac8b` and tree
`5f19024af0837d5efd54855bcf0fd705a50eadc9`. All 26 selected tests across the
four settled R09 suites passed with zero failures and zero skips. They verify
the declared numeric, geometry, identity, authorization, bounded-proposal,
protected-region, consistency, resource, lifecycle, rollback, NV12, and
fail-closed behavior under deterministic fixture simulation.

R09 is `passed` with roadmap exit outcome `qualified_local_residual`, limited to
`declared_software_function_only`. Comparative, A/B, blinded, ablation, and
superiority methods were not run, were not required, and supplied no acceptance
authority. Native Core AI and its framework, a model asset, hardware, simulator,
and operator-observed execution remain `not_observed`. This acceptance makes no
native Core AI, model-quality, product-qualification, production-default, Auto,
holdout, quality, performance, publication, or release claim, and it did not
itself authorize R10 progression. The operator's later continuation instruction
separately authorizes R10 implementation under the forward software-function
gate.

---

## R10 — Auto-policy optimization and bounded calibration

**Status:** `planned`

### Objective

Implement deterministic, bounded optimizer and calibration software that proves
its declared limits, decisions, and publication behavior.

### Work

- Define typed candidate, constraint, score, selection, and frozen-policy
  contracts with exact processing identity.
- Use a finite screening design over only declared causal variables.
- Enforce route, plane, temporal, protected-region, resource, and safety bounds
  independently rather than hiding failures in one scalar.
- Make candidate ordering, rejection, ranking, tie-breaking, checkpointing,
  resume, cancellation, and publication deterministic.
- Publish durable per-run and frozen fixture-policy evidence.

### Prohibitions

- no unbounded 42-coordinate neighborhood search;
- no single opaque scalar that hides route or plane failure;
- no post-hoc threshold relaxation;
- no monolithic process that withholds all durable progress; and
- no unreviewed policy change after a fixture contract is frozen.

### Exit gate

Checkpoint-bound deterministic tests prove that the optimizer/calibration
software accepts and rejects inputs according to its declared schema, terminates
within its finite search bounds, enforces every independent constraint, produces
repeatable ordering and tie-breaking, resumes from exact checkpoints, handles
failure and cancellation transactionally, and publishes a frozen fixture-policy
artifact with complete identity. Production Auto remains separately blocked.

---

## R11 — Evidence traceability and claim boundary

**Status:** `planned`

### Objective

Implement traceable evidence and claim-scope machinery that reports exactly what
the software did and prevents unsupported product claims.

### Required functional work

- Define typed execution-receipt, subject, input, observation, aggregate,
  claim-scope, and disposition contracts.
- Bind every accepted observation and aggregate to exact source, software,
  subject, input, preprocessing, toolchain, and execution identity.
- Reject missing, duplicate, mismatched, out-of-scope, or unauthorized evidence
  and any claim broader than the evidence supports.
- Produce deterministic aggregates from supplied observations and preserve the
  distinction between `not_applicable`, `not_observed`, failed, and absent data.
- Emit an explicit `no_market_claim` disposition unless a claim has exact,
  in-scope evidence and separate operator authorization.

### Claim rule

Comparative testing and market-position work are outside this roadmap. R11
accepts when its machinery accurately reports observed software behavior,
rejects unsupported inputs and claims, and emits `no_market_claim` by default.
`market_leading_claim` remains blocked unless the operator separately authorizes
a future claim process outside this roadmap.

---

## R12 — Format, route, and product expansion

**Status:** `planned`

### Work

- 10-bit YCbCr/P010-style internal paths where supported;
- HDR transfer functions and BT.2020 color management;
- wider input/output resolutions and arbitrary runtime-supported scale factors;
- 4:2:2 and 4:4:4 evaluation;
- interlaced/deinterlaced workflows;
- subtitles, alpha, and metadata preservation;
- long-form job resume and chunk-level checkpointing; and
- hardware-tier-specific capability profiles.

### Exit gate

Every newly supported format has an explicit color, range, chroma-siting, metadata, quality, and backend capability contract.

---

## R13 — Release hardening

**Status:** `planned`

### Work

- Simplify release evidence around the new backend/policy architecture.
- Preserve exact model, policy, binary, framework revision, and app identity.
- Make long jobs resumable at safe media boundaries.
- Add model-download and specialization UI.
- Add Auto, Quality, Fast, Deterministic, and optional Smooth Motion modes.
- Add concise user-facing explanations and detailed developer telemetry.
- Run Xcode tests, CLI tests, SwiftLint, Instruments, GPU capture, soak, cancellation, disk-full, low-memory, thermal, and mutation tests.
- Publish only after exact app, exact policy/model assets, and measured output evidence reopen successfully.

---

## 10. Measurement and Decision Rules

### 10.1 No single metric is sufficient

The decision objective must preserve separate route, plane, temporal, protected-region, and performance constraints. A weighted score can rank candidates only after all hard constraints pass.

### 10.2 Required backend telemetry

```text
backend family and exact revision
scale factor and route
input/output pixel formats
model status and model hash
initialization/specialization time
per-frame wall/GPU/CPU time
memory and ring occupancy
previous-frame/output usage
optical-flow source and confidence
ASH current/previous state
policy candidates and selected policy
state dwell and transition reason
pre/post stages and strengths
Core AI invocation and output confidence
artifact detections and corrections
fallback reason
output metadata identity
```

### 10.3 Required stop conditions

Stop an authorizing software-function run when source, fixture, policy, model, or
toolchain identity changes; a claimed public-API contract cannot be represented
truthfully; a safety, temporal, protected-region, lifecycle, or resource boundary
fails; or continuing would require holdout information. An unavailable native
path is recorded as `not_observed` and bypassed; it does not stop a separately
identified deterministic functional run.

---

## 11. Recommended First Execution Package

The first coding sprint under this roadmap should not attempt the entire product. It should cover only:

```text
R00  strategic reset and current-source inventory
R01  Apple capability laboratory
R02  unified backend/stage interfaces
R03  deterministic Apple-native baseline suite
```

It must produce a closed capability disposition matrix. Real compile/runtime
evidence may be added when available; absent hardware, simulator, or observed
operation is recorded as `not_observed` and does not block continuation.
Production Auto, Core AI, temporal MetalFX, holdout, and release claims remain
blocked unless their separate authorization gates are satisfied.

The second sprint should implement VideoToolbox quality and low-latency super
resolution under the unified architecture. The third should implement ASH
orchestration over eligible backends. R08 Core AI analysis has since passed its
separate deterministic software-function gate; native observations remain
supplemental and `not_observed` where unavailable.

---

## 12. Completion Definition

The roadmap succeeds when all of the following are true:

1. Every Apple-native method in Section 5 has a qualified, restricted,
   diagnostic-only, rejected, or `not_observed` disposition. `not_observed`
   supplies inventory closure only and carries no availability or quality claim.
2. At least one strong Apple-native primary SR backend is production-qualified.
3. ASH causally controls backend/policy decisions exactly within its accepted software contract.
4. Temporal stability and artifact governance perform their declared bounded, transactional software function.
5. Core AI analysis performs its declared optional analysis and deterministic-bypass software function or is cleanly excluded from the shipping critical path.
6. Any residual model is bounded, optional, and functionally verified.
7. Deterministic mode remains functional and reproducible.
8. Auto optimizer and calibration machinery is bounded, deterministic,
   explainable, resumable, and binds every selected output to exact decisions and
   assets; production Auto remains a separate authorization decision.
9. Evidence and claim-scope machinery is traceable, rejects unsupported claims,
   and produces an honest `no_market_claim` disposition by default.
10. The application remains Apple-native at runtime; offline Python remains development, model-conversion, validation, and evidence tooling only.

---

## 13. Evidence Basis

### Project evidence

- `README.md`
- `ARCHITECTURE.md`
- `CHANGELOG.md`
- `ash-v3-production-wiring-design.md`
- `canonical-computational-specification.md`
- `Mirmir_Sprint_Evidence_Audit_2026-07-16.md`
- `Mirmir_P06_Revised_Plan_Assessment_2026-07-17.md`
- `mirmir-concept-exploration.md`
- supplied `Mirmir071626.zip` repository snapshot

### Official Apple evidence consulted

- Core AI overview and Core AI framework documentation
- Core AI integration, model authoring, optimization, debugger, and Instruments documentation
- MetalFX framework, spatial scaler, temporal scaler, temporal-denoised scaler, and frame interpolator documentation
- VideoToolbox `VTFrameProcessor`, super-resolution, low-latency super-resolution, frame interpolation, optical flow, temporal noise filtering, and pixel-transfer documentation
- Metal Performance Shaders Lanczos, bilinear, guided-filter, convolution, and pyramid documentation
- Core Image Lanczos, bicubic, and edge-preserve upsample documentation
- Accelerate/vImage scaling and resampling documentation
- WWDC25 and WWDC26 sessions covering VideoToolbox ML video effects, MetalFX, Metal 4 neural rendering, and Core AI
