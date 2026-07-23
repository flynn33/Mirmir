# ADR 0001: Apple-Native Adaptive Architecture

- **Status:** Accepted
- **Decision date:** 2026-07-19
- **Roadmap phase:** R00 — Strategic reset and evidence preservation
- **Supersedes:** The ASH-primary reconstruction and monolithic P06/P07 release path

## Context

The preserved ASH V3 implementation is a substantial deterministic spatial
reference, telemetry source, and evidence substrate. Its failed and partial P06
evidence does not qualify it as the production reconstruction engine, and the
incomplete monolithic P06 release path is not authoritative.

Mirmir's forward roadmap instead requires Apple-native reconstruction engines,
deterministic orchestration, explicit capability qualification, and evidence-led
phase promotion. The application also needs to retain its five-module Pattern B
shape without depending on the external Forsetti package or copying its source.

## Decision

1. Apple frameworks own numerical reconstruction, resampling, temporal
   enhancement, denoising, and model execution. Candidate frameworks are
   qualified through roadmap phases before they enter normal product
   composition.
2. ASH owns deterministic orchestration, temporal governance, fallback policy,
   artifact-risk handling, telemetry, and explanation. ASH V3 remains compiled
   as a deterministic reference and analysis substrate, not as the presumptive
   production reconstruction engine.
3. Core AI is optional. Its first authorized role is analysis-only. Pixel
   residual processing remains separately blocked pending explicit operator
   authorization after R08 functional acceptance. Comparison-based testing is
   outside the forward roadmap and does not authorize residual work.
4. The application retains one UI module, four cohesive service modules,
   constructor injection, deterministic lifecycle, and one composition root.
   These are implemented by a small app-owned Pattern B runtime using
   Mirmir-prefixed internal types.
5. The Forsetti repository, package, framework, submodule, vendored source, and
   runtime dependency are prohibited. No Forsetti source is copied into Mirmir.
6. The monolithic P06/P07 authorization path is retired. Historical scripts,
   schemas, schedulers, validators, receipts, analyses, and artifact trees remain
   preserved where useful for evidence or later repurposing, but the legacy
   production and holdout entry points fail closed.
7. R01, the Apple capability laboratory, is the only next authorized product
   phase after R00 passes.

## Required Architecture Invariants

- The fixed module activation order is Metal rendering, model assets, media
  pipeline, upscaler engine, then UI. Startup failure rolls back started modules
  in reverse order.
- Exactly the five declared modules are activated once, exactly one module is a
  UI module, and the UI module activates last.
- Normal product composition exposes no reconstruction backend until roadmap R03
  qualifies one. The application launches and explains that unavailability.
- There is no silent reconstruction fallback and no product call site for the
  simulated VideoToolbox staging path in R00.
- Holdout pixels remain unopened. R00 may verify only committed no-pixel records.
- Historical evidence remains immutable and cannot authorize a current release.

## Consequences

### Positive

- Product claims follow measured Apple capability and baseline evidence.
- The module boundary remains deterministic and testable without a network
  package dependency.
- Retained ASH work remains useful without carrying an unsupported production
  quality claim.
- Backend unavailability is explicit in both the service contract and UI.

### Costs and limitations

- Product upscaling is intentionally unavailable during R00 through R02.
- Generic framework host controls and dynamic JSON manifest discovery are
  removed; the closed five-module application uses static descriptors.
- Later roadmap phases must define and qualify the common backend contract before
  adding production reconstruction.

### R08 analysis-only acceptance — 2026-07-22

R08 implementation commit `368b9284883c189be6a1139df6208bf0e88139dd`,
tree `f8e73d193b7b0c9df7005a7aa006de48ca48f77c`, preserves this decision's
analysis-only boundary inside the existing model-assets module. All 42 selected
deterministic tests across 10 suites passed with zero failures and zero skips,
covering the declared analysis outputs, identity, scheduling, lifecycle,
cancellation, cache, budgets, deterministic bypass, bounded ASH-context
integration, and rejection of pixel and backend-selection authority.

The accepted scope is `declared_software_function_only` under deterministic
fixture simulation. Comparison-based testing supplied no acceptance authority.
Native Core AI, Xcode 27, model, hardware, simulator, and
operator-observed execution remain `not_observed`; the acceptance creates no
native, product, quality, performance, production-default, Auto, publication,
or release claim. That R08 acceptance did not itself authorize Core AI pixel
residual work. A later 2026-07-22 operator directive separately authorized only
the bounded R09 experiment, which remains `in_progress` pending its own
checkpoint-bound functional acceptance.

## Authorization Boundary

This decision authorizes R00 implementation and, after R00 acceptance, R01
capability work. It does not authorize production Auto mode, Core AI pixel
residual output, holdout access, G08, a tag, a release, a quality claim, or a
market-position claim.
