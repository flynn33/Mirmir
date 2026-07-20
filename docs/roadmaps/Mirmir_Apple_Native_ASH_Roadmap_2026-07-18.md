# Mirmir Roadmap: Apple-Native Adaptive Video Enhancement

**Roadmap version:** 1.0.1  
**Publication date:** 2026-07-18  
**Revision date:** 2026-07-19  
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

> A deterministic ASH orchestration layer, operating over Apple’s native video-enhancement engines and optional Core AI analysis, can produce a more temporally stable, artifact-aware, explainable, private, and hardware-efficient upscale than any single Apple backend used alone.

### Product differentiation

Mirmir will not attempt to beat specialized commercial products merely by shipping another monolithic neural upscaler. Its defensible differentiators are:

1. **Multi-engine orchestration:** use the strongest eligible Apple engine for the current content and hardware rather than imposing one model on every frame.
2. **Temporal governance:** prevent rapid changes in backend, strength, denoise, sharpen, and correction policy.
3. **Artifact governance:** detect and correct edge ringing, halos, ghosting, temporal flicker, chroma displacement, false texture, and protected-region damage.
4. **Explainability:** preserve state, policy, backend, confidence, transition, fallback, and correction reason codes.
5. **Privacy and locality:** perform processing on-device with Apple-native frameworks.
6. **Quality per resource:** optimize quality together with throughput, memory, energy, model-download cost, and initialization latency.
7. **A deterministic mode:** preserve a fully native nonlearned mode for repeatability, comparison, unsupported hardware, and user choice.

---

## 2. Explicit Scope Boundaries

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
- benchmarked;
- assigned an explicit role;
- rejected when its input contract cannot be satisfied; and
- available to Auto mode only after its own quality and reliability gate passes.

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
| Offline quality metrics, calibration documents, immutable evidence concepts, and exact-app measurement infrastructure | `validation/`, P06/P08 documents | Repurpose for backend benchmarking, ablation, policy tuning, and release evidence. |
| Scandinavian macOS UI theme, workflow screens, application icon, and workspace controls | Current UI modules and assets | Retain. Add simple product modes rather than exposing framework internals by default. |

### 3.2 Completed work to repurpose

| Existing work | New role |
|---|---|
| ASH V3 operator bank and reconstruction kernels | Deterministic reference, conservative fallback, analysis comparison, and localized correction kernels. |
| ASH immutable LUT infrastructure | Versioned policy dispatch from ASH state/context to pipeline profiles, not merely state-to-pixel operators. |
| P06 scheduler and control-comparison infrastructure | Bounded backend/policy experiments and evidence publication; not another broad 42-coordinate search. |
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
- Source presence, tests, or fixture parity are equivalent to perceptual superiority.

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
| `MPSImageLanczosScale` | Deterministic GPU quality baseline, conservative fallback, and route comparator. |
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
| vImage high-quality Lanczos-5 | High-quality deterministic CPU comparator. |
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

### 6.4 ASH value test

ASH is retained in production only if an ablation shows that:

```text
Apple backend pool + ASH orchestration
```

outperforms or more efficiently matches:

```text
best fixed Apple backend or continuous non-ASH router
```

on at least one preregistered product dimension—temporal stability, artifact rate, protected-region integrity, quality, throughput, memory, energy, or explainability—without unacceptable regressions elsewhere.

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

After stage A proves value, add model outputs for:

- backend suitability scores;
- denoise-strength limits;
- sharpening/detail limits;
- protection/reactivity masks;
- temporal-history confidence; and
- residual-stage eligibility.

These values remain suggestions. ASH applies clamping, hysteresis, policy constraints, and fail-closed handling.

### 7.3 Core AI stage C: localized residual correction

Only after stages A and B pass ablation:

- run a small residual model after the primary Apple scaler;
- operate only on ASH-approved low-confidence regions;
- output a bounded zero-centered residual or correction map;
- clamp by plane, content class, and local edge confidence;
- prohibit direct unbounded replacement of protected areas;
- require source-consistency and temporal-consistency checks;
- preserve a bypassed Apple-only output for comparison; and
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

**Status:** `in_progress`

### Objective

Determine exactly which Apple APIs are available and practical on target Macs before production wiring.

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

For every capability record:

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

No backend enters Auto mode without an authoritative capability record from the actual target environment.

---

## R02 — Unified backend and stage architecture

**Status:** `planned`

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

---

## R03 — Deterministic Apple-native baseline suite

**Status:** `planned`

### Objective

Establish trustworthy reference paths before learned super resolution.

### Implement

- MPS Lanczos backend.
- MPS bilinear backend.
- Core Image Lanczos backend.
- Core Image bicubic backend.
- vImage Lanczos-3 and Lanczos-5 references.
- VTPixelTransfer scaling/conversion reference.
- Existing ASH V3/custom Metal deterministic backend as a comparator.
- Core Image edge-preserve and MPS guided-filter support stages for masks/chroma.

### Evidence

- pixel and frame repeatability;
- CPU/GPU parity where applicable;
- ringing, edge, chroma, and performance comparison;
- exact same media transaction behavior; and
- no quality claim beyond measured evidence.

### Exit gate

One baseline matrix establishes the quality/performance/resource envelope of every deterministic Apple path.

---

## R04 — VideoToolbox super-resolution production integration

**Status:** `planned`

### Objective

Use Apple’s native video-oriented ML super-resolution engine as the primary Quality path.

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

### Exit gate

- Both direct 2× and supported 3/2×/1.5× routes are handled through runtime capability, not assumptions.
- Outputs reopen and preserve media identity.
- Quality SR materially exceeds deterministic baselines on preregistered content without unacceptable temporal or protected-region regressions.
- Low-latency SR satisfies its own quality floor and throughput target.

---

## R05 — MetalFX integration and suitability decision

**Status:** `planned`

### Objective

Use MetalFX where its public contract fits decoded video, and reject it where required renderer inputs cannot be supplied honestly.

### Work

1. Implement MetalFX Spatial first.
2. Compare it against VideoToolbox low-latency SR and MPS Lanczos.
3. Probe MetalFX Temporal using only evidence-backed motion, depth, exposure, and jitter inputs.
4. Do not fabricate depth or renderer semantics merely to make the API run.
5. Probe temporal-denoised scaling only after auxiliary-buffer estimation has independent quality evidence.
6. Treat MetalFX frame interpolation as a separate cadence feature.

### Exit outcomes

- `qualified_spatial`
- `qualified_temporal`
- `qualified_temporal_denoised`
- `diagnostic_only`
- `rejected_for_decoded_video`

A rejection is a valid successful result.

---

## R06 — ASH orchestration engine v1

**Status:** `planned`

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

### Required ablations

- best fixed eligible Apple backend;
- simple continuous router without ASH;
- ASH state-only router;
- ASH plus continuous sidecar;
- ASH without hysteresis;
- ASH without postflight feedback.

### Exit gate

ASH orchestration must improve at least one primary product dimension over the best fixed or continuous router without violating locked quality floors.

---

## R07 — Temporal stability and artifact governance

**Status:** `planned`

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

### Exit gate

ASH Auto must reduce preregistered temporal artifact and chroma-displacement measures relative to each underlying backend used alone, with no material loss in spatial quality.

---

## R08 — Core AI analysis-only integration

**Status:** `planned`

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

### Exit gate

Core AI analysis must improve backend selection, protection, artifact rate, or resource efficiency over the deterministic analyzer in a blinded ablation. If it does not, it remains optional diagnostic research.

---

## R09 — Core AI bounded residual experiment

**Status:** `blocked`

### Objective

Determine whether a small localized model can improve difficult regions without taking over the entire pipeline.

### Work

- Train or adapt a small residual correction model.
- Run only after an Apple-native primary scaler.
- Restrict it to ASH-approved regions.
- Enforce per-plane residual limits and source/temporal consistency.
- Preserve the Apple-only output for direct A/B comparison.
- Add hallucination, text integrity, face identity, and temporal consistency tests.

### Exit outcomes

- `qualified_local_residual`
- `qualified_for_specific_content_class`
- `no_incremental_value`
- `rejected_hallucination_risk`
- `rejected_resource_cost`

The model is not required to ship.

---

## R10 — Auto-policy optimization and bounded calibration

**Status:** `planned`

### Objective

Tune the orchestration policy without recreating the failed broad P06 search.

### Work

- Use a fixed screening design over only causal variables.
- Measure backend/content-class interactions.
- Construct a Pareto frontier over quality, temporal stability, protected-region integrity, throughput, memory, and energy.
- Remove dominated policies.
- Perform bounded local refinement only around passing policies.
- Publish resumable per-experiment evidence.
- Keep development, validation, and holdout separated.

### Prohibitions

- no unbounded 42-coordinate neighborhood search;
- no single opaque scalar that hides route or plane failure;
- no post-hoc threshold relaxation;
- no monolithic process that withholds all durable progress; and
- no holdout-driven policy change.

### Exit gate

One frozen Auto policy and a small number of explicit mode policies pass development and validation before one holdout opening.

---

## R11 — Competitive benchmark and market-position decision

**Status:** `planned`

### Objective

Establish whether Mirmir is actually better on defined product dimensions.

### Comparator set

- every qualified Apple-native backend alone;
- ASH Auto without Core AI;
- ASH Auto with Core AI analysis;
- optional ASH Auto with bounded residual;
- current Topaz Video representative local models;
- current DaVinci Resolve Studio Super Scale and associated restoration/sharpening path; and
- ordinary deterministic scalers.

### Corpus classes

- clean 720p and 1080p;
- compressed streaming video;
- film grain;
- animation and line art;
- faces and skin;
- small text, subtitles, and UI capture;
- sports and fast motion;
- low light and noise;
- chroma stress;
- scene cuts, flashes, and occlusion;
- archival SD and deinterlaced material; and
- synthetic ground-truth downsample pairs.

### Metrics

- PSNR, SSIM/MS-SSIM, and perceptual metrics where ground truth exists;
- temporal warping error, flicker, state/backend churn, and ghosting;
- edge overshoot, ringing, halo, aliasing, and chroma displacement;
- face/text/line-art integrity;
- hallucinated-detail and source-consistency review;
- blind pairwise human preference;
- frames per second and wall time;
- peak/resident memory;
- energy and thermal behavior;
- first-run model acquisition/specialization cost;
- repeatability; and
- offline privacy and network dependency.

### Claim rule

Mirmir makes no “market-leading” claim until blind evaluation and reproducible evidence support the exact claim. The likely target is a Pareto advantage: better temporal stability, protection, privacy, explainability, and Apple-silicon efficiency at competitive spatial quality.

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

Stop an experiment when:

- the public API input contract cannot be satisfied;
- a backend is dominated on every primary dimension;
- temporal or protected-region failures are near-universal;
- Core AI adds no incremental value;
- ASH orchestration does not beat or efficiently match the non-ASH router;
- resource cost exceeds the approved envelope;
- source or policy identity changes during an authorizing run; or
- holdout information would be required to continue tuning.

---

## 11. Recommended First Execution Package

The first coding sprint under this roadmap should not attempt the entire product. It should cover only:

```text
R00  strategic reset and current-source inventory
R01  Apple capability laboratory
R02  unified backend/stage interfaces
R03  deterministic Apple-native baseline suite
```

It must produce real compile/runtime evidence for the current target Macs and leave production Auto, Core AI, temporal MetalFX, holdout, and release claims blocked.

The second sprint should implement VideoToolbox quality and low-latency super resolution under the unified architecture. The third should implement ASH orchestration over already-qualified backends. Core AI begins only after those baselines are measured.

---

## 12. Completion Definition

The roadmap succeeds when all of the following are true:

1. Every Apple-native method in Section 5 has a qualified, restricted, diagnostic-only, or rejected disposition supported by evidence.
2. At least one strong Apple-native primary SR backend is production-qualified.
3. ASH causally controls backend/policy decisions and improves a preregistered product dimension.
4. Temporal stability and artifact governance provide measurable value over the underlying backend alone.
5. Core AI analysis either demonstrates incremental value or is cleanly excluded from the shipping critical path.
6. Any residual model is bounded, optional, and evidence-qualified.
7. Deterministic mode remains functional and reproducible.
8. Auto mode is explainable, has no silent fallback, and binds every output to exact decisions and assets.
9. Competitive claims are supported by reproducible benchmark and blind-evaluation evidence.
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
