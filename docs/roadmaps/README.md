# Mirmir Roadmaps

The current product direction is **Mirmir Apple-Native Adaptive Video Enhancement Roadmap 1.0.1**, published 2026-07-18 and revised 2026-07-23.

Current phase state: `R00: passed`; `R01: passed`; `R02: passed`;
`R03: passed`; `R04: passed`; `R05: passed`;
`R06: passed`; `R07: passed` under the operator-defined deterministic
software-function gate; `R08: passed` under the declared-software-function
gate; `R09: passed` under the bounded-residual software-function gate;
`R10: passed` under the deterministic bounded optimizer/calibration
software-function gate; `R11: passed` under its exact-source traceability and
claim-boundary software-function gate; `R12: passed` under its exact-source
declared-software-function gate; `R13: passed` under its exact-source
release-hardening software-function gate. The roadmap is complete for its
accepted declared-software-function scope; the R13 outcome is
`release_ready_candidate`, not a publication or release. R03's
frozen v1 result remains fail-closed and `blocked`; R04's frozen
`diagnostic_only` checkpoint remains historical while its later additive
declared-software-function acceptance passes. Native VideoToolbox model
execution, model readiness, hardware, simulator, and operator observations
remain `not_observed`. R05's local unpublished `diagnostic_only` checkpoint
remains historical while its later additive declared-software-function
acceptance passes with the same `diagnostic_only` exit outcome. Native MetalFX
execution, hardware, simulator, operator observation, product qualification,
quality, and performance remain `not_observed` or `not_claimed`. R06 is
preregistered for deterministic fixture-only orchestration; the implementation
source for its local unpublished blocked checkpoint is commit
`9246934c027e97f2b2ae3af35b0c4892154d761c`, tree
`1235596387d4eabd2ecb4ea1a29221c44ec425fe`. Its deterministic software
conformance passed, but its frozen product-gate result is fail-closed for
`no_product_qualified_primary_backend`. At that frozen checkpoint, product,
hardware, simulator, and operator observations were `not_observed`; quality,
performance, product, production-default, acceptance, publication, and release
claims were unmade.
R06's policy-frozen local unpublished blocked closure is commit
`9ed01ea938a933f6406fd67e88edb74e7c84f5f4`, tree
`32365e745dbf53d59213fe2294a6b63ba2642df7`; its contemporaneous acceptance
remains unclaimed historical evidence.

R02's additive functional phase acceptance binds source
`eeabc4224100bc8ed86ae1208189bee508844210`, tree
`ac402f993805cca499d2f688c6186c4684ce8dba`, the immutable passing conformance,
and a fresh six-suite Xcode run with 27 tests passed, zero failed, and zero
skipped. Two direct tests bind production bootstrap to
`UnavailableUpscalerEngineService` and prove its typed fail-closed
`backendUnavailable(reason:)` rejection. This is the intentional R02
production-unavailable boundary, not project completion or production
enablement. R02 is `passed` only for `declared_software_function_only`. The
frozen preregistration, conformance, local unpublished closure, and
contemporaneous `phase_acceptance: not_claimed` state remain unchanged
historical evidence. Production upscaling, a production default, Auto, holdout,
quality or performance claims, product publication, and release remain
unauthorized.

R04's additive functional phase acceptance binds source
`ab77e97867d51168e90c0190f6430d4acd769e68`, tree
`446f71bb584f5d1fffcd20a17ac5e5507d3222b6`, and a fresh four-suite macOS arm64
Xcode run with 42 tests passed, zero failed, and zero skipped. Deterministic
simulation through the real R04 backends and production FIFO verifies complete
quality and low-latency 2× media transactions, exact-dimension 1.5× admission,
active cancellation, preserved media identity, reopen-before-publication,
resource release, atomic publication, and no silent fallback. R04 is `passed`
only for `declared_software_function_only`. The frozen preregistration and
`diagnostic_only` conformance record remain unchanged historical evidence.
Native VideoToolbox model execution, model readiness, hardware, simulator, and
operator observation remain `not_observed`; no production default, Auto,
native-framework, product-qualification, quality, performance, publication, or
release claim follows.

R05's additive functional phase acceptance binds source
`7e1ab67340e4d6d95a3d92e8a48bc6cd356005b8`, tree
`adce5b65fd3d752a1467925232847e086d0b3e7a`, and a fresh five-suite macOS arm64
Xcode run with 46 tests passed, zero failed, and zero skipped. Deterministic
simulation through the real spatial backend and production FIFO verifies
source-derived A07 1.5× and 2× output, complete identity/lifecycle behavior, and
a reopened 2160p H.264/AAC/timed-metadata transaction before atomic
publication. The real spatial-driver suite verifies support-before-construction,
the explicit color bridge, ordering, cancellation, and typed failures. A08-A10
retain successful `rejected_for_decoded_video` dispositions. R05 is `passed`
with exit outcome `diagnostic_only`, limited to
`declared_software_function_only`; comparison was not required. The frozen
preregistration and suitability record remain unchanged historical evidence.
Native MetalFX execution, hardware, simulator, operator observation, product
qualification, quality, and performance remain `not_observed` or `not_claimed`;
no production default, Auto, publication, or release authority follows.

R06's additive functional phase acceptance binds source
`6c4a6d3d5f8a59c553b10c23783c148ccb3388a5`, tree
`beb0f8c666550c6c36dae5a2185cac58d2494132`, and a fresh seven-suite macOS arm64
Xcode run with 42 tests passed, zero failed, and zero skipped. The selection
verifies the frozen deterministic orchestration contracts, directly proves
higher-scoring ineligible candidates cannot enter the selected plan, and uses
the real R07 coordinator suites to prove transactional state commit and
rollback around the real R06 orchestrator. R06 is `passed` only for
`declared_software_function_only` under deterministic fixture integration. The
frozen blocked conformance and phase evidence remain unchanged history. R06 v1
still rejects product-scope orchestration; no product routing, qualification,
default, Auto, native/hardware observation, quality, performance, publication,
or release claim follows.

R07 began fixture-only local implementation from the exact R06 blocked closure
identified above. Its
preregistration and deterministic fixture catalog freeze the temporal,
artifact, chroma, spatial, aggregation, fixed-point, history, and tuning
contracts before implementation. Its frozen historical product-gate result is
blocked for
`upstream_no_product_qualified_primary_backend`, with no eligible route,
selected plan, or output. Product metrics and hardware, simulator, and operator
observations remain `not_observed`; no quality, performance, product,
production-default, publication, or release claim follows from that record.

The additive R07 functional receipt and phase-acceptance record bind
implementation commit `1b46ad469265a6ba837a8449d28b8850889f1d3f`, tree
`09d3a48df01738bb26077aadfd83c08e389a1dc2`, and a checkpoint-bound run of 98
passing tests across the 11 settled R07 test classes, with zero failures and zero
skips. R07 is `passed` because the deterministic fixture simulation verifies the
intended temporal, support-stage, artifact, protected-region, N+1 postflight,
coordinator, and transaction behavior. The frozen comparison requirement is
outside the forward roadmap and carries no acceptance authority. This scope
does not claim native framework or hardware execution, product routing, a
production default, Auto, media quality, performance, publication, or release.
R06 later passed under its additive functional acceptance record. R08 is
`passed` under its separate functional acceptance record. Neither acceptance
rewrites the frozen R06/R07 product-gate records.

R08 starts from accepted R07 merge commit
`3fd13e57ec95b1ed98df71f4c83ab165bdfbab6b`, tree
`eb1614dd2a93e1bc4e1911bcf74f41cf372a3304`. Under the operator's 2026-07-22
decision, forward acceptance asks whether the software performs the task and
honors the boundaries it claims. Comparison-based testing is outside the forward
roadmap and carries no acceptance authority. Unavailable Xcode 27/Core AI
native execution is supplemental `not_observed` evidence rather than a blocker
to deterministic software-function implementation. The later operator `resume
work` directive separately authorizes the bounded R09 experiment.

The additive R08 functional receipt and phase-acceptance record bind
implementation commit `368b9284883c189be6a1139df6208bf0e88139dd`, tree
`f8e73d193b7b0c9df7005a7aa006de48ca48f77c`, and a checkpoint-bound run of 42
passing tests across 10 settled R08 test suites, with zero failures and zero
skips. R08 is `passed` because deterministic fixture simulation verifies its
declared analysis-only outputs, identity, scheduling, lifecycle, cancellation,
cache, resource-budget, deterministic-bypass, ASH-context, protected-mask, and
no-pixel-authority behavior. Comparison-based testing supplied no acceptance
evidence or authority. Native Core AI, Xcode 27, model, hardware,
simulator, and operator-observed execution remain `not_observed`; no native,
product, quality, performance, production-default, Auto, publication, or release
claim follows. The later separate operator authorization and exact accepted-R08
evidence binding advanced R09 to `in_progress` at its start checkpoint.

R09's repository-owned authorization binds accepted-R08 raw SHA-256
`0d81917a93cf56cae867c11b7c65fb3c85e53b7596929cf9eec2ef09c24634b0`,
implementation commit `368b9284883c189be6a1139df6208bf0e88139dd`, and tree
`f8e73d193b7b0c9df7005a7aa006de48ca48f77c`. Its preregistration permits only
bounded post-scaler, ASH-authorized deterministic software behavior. Comparison
methods are excluded and non-authorizing; native/model/hardware/simulator/
operator observations remain `not_observed`. Production default, Auto, holdout,
claims, publication, and release remain unauthorized.

The additive R09 functional receipt and phase-acceptance record bind
implementation commit `3ba7b2b5fdbde3a3f90f011cb548b85d46b2ac8b`, tree
`5f19024af0837d5efd54855bcf0fd705a50eadc9`, and a checkpoint-bound run of 26
passing selected tests across four settled suites, with zero failures and zero
skips. R09 is `passed` with exit outcome `qualified_local_residual`, limited to
`declared_software_function_only` under deterministic fixture simulation.
Native Core AI/framework/model, hardware, simulator, and operator observations
remain `not_observed`; no product qualification, production default, Auto,
holdout, quality, performance, publication, or release authority follows. The
R09 acceptance did not itself authorize R10 progression; the operator's later
continuation instruction separately authorizes R10 implementation under the
forward software-function gate.

The additive R10 functional receipt and phase-acceptance record bind
implementation commit `3a76c6a03ea0f52f2a2395925badd5d5d1c03c6b`, tree
`37951da694ab4fbca6f8c663bb2883e5084b861c`, and a checkpoint-bound run of 39
passing optimizer and persistence tests with zero failures and zero skips. The
accepted calibration evaluated nine candidates, scored three, rejected six,
published ten content-addressed checkpoints, selected `fixture-valid-alpha`,
and passed typed reopen against the exact evaluation catalog. R10 is `passed`
only for `declared_software_function_only` under deterministic fixture
simulation.

Comparison, A/B, and superiority testing were not run and are not required.
Hardware, simulator, and operator-observed execution remain `not_observed`.
Fixture-policy evidence publication is authorized. Production Auto, holdout
access, native execution, product qualification, product publication,
quality/performance claims, and release remain unauthorized.

The additive R11 functional execution receipt and phase-acceptance record bind
exact source commit `75479b9f30511330f2a18b656151dc551292cb1e`, tree
`0dd42ec30b212456223ee582b549de30a0e3416f`, and 76 passing selected tests
with zero failures and zero skips. The deterministic traceability run produced
one record for each of `observed`, `not_applicable`, `not_observed`, `failed`,
and `absent`; validated the exact seven-component identities and mixed
aggregate; rejected unsupported evidence and claims; and emitted
`no_market_claim` unconditionally.

The canonical and sealed traceability receipts are byte-identical at SHA-256
`22714b672ee6f5090cf7c02faeecfbe0a1c805d385ea10e680225fa38596190d`.
The functional execution receipt has SHA-256
`e1446876fde099bc172159087aceb77545c1b9bd5f081dde19d1e0cb60238bcb`,
and the phase-acceptance record has SHA-256
`66cca6e35780fa9ebb73c8667b3d744df9599601dccf5e95ddacc000adebe618`.
R11 is `passed` only for `declared_software_function_only` under deterministic
fixture simulation.

The additive R12 functional execution receipt and phase-acceptance record bind
exact source commit `2f5e2987fe6a0e88d39790f177c717b62d29d6e4`, tree
`4971b4d38f92ea5edffe925e507f058e9ffc13d8`, and evidence commit
`3f31f7aa5bfc9e01eb1124f0f9db7b8ea6e17ff6`. All 85 selected tests passed
with zero failures and zero skips: 15 format, 25 route/backend, and 45
resumability/checkpoint tests. Strict SwiftLint covered 340 files with zero
violations.

The R12 functional execution receipt has SHA-256
`09c6e370dcba37e39141477b254005a40aedc9e79a9d9e83c7667b7b7bf1af27`,
and its phase-acceptance record has SHA-256
`67a175f14ab43688022ca72f84b956cd7081ed1972e3fb52bf9cef57af831080`.
R12 is `passed` only for `declared_software_function_only`. Comparison and A/B
methods were absent, not required, and non-authorizing. Hardware, simulator,
and operator observation remain `not_observed` and nonblocking.

R12 acceptance proves the declared format, route, capability, fallback,
preservation, backend, and resumability contracts. It does not claim production
decode, upscale, encode, or preservation support for the expanded formats, and
it grants no product qualification, production Auto, market claim, product
publication, tag, or release authority.

R13 is `passed` for `declared_software_function_only` under the
`software_does_what_it_says_it_does` basis. Exact-source evidence binds commit
`6c72e865e7622c11dcf1681f04ccc5cc240d8119`, tree
`14852f416aef5d3156185a4b50767b531915cd82`, and evidence commit
`5c8ae09251955d8274d391e93215b346db25bada`. Its 183 selected tests passed
with zero failures and zero skips; strict lint covered 403 Swift files with
zero violations. The genuine A11 MPS Lanczos and AVFoundation shipping path
produced and reopened the retained QuickTime MOV, and the separately built
Release app was archived and reopened with exact identity. Quality, Fast, and
Deterministic are available; Auto remains `unavailable` and `not_authorized`.
The outcome is `release_ready_candidate`, but the candidate was not published
or released. Hardware, simulator, operator observation, Release-app execution,
signing, notarization, Gatekeeper, and launch smoke remain `not_observed` and
nonblocking. No publication, distribution, tag, release, Auto, or market claim
is authorized.

The operator-authorized additive R03 v2 correction passed as of 2026-07-21 for
source `dfdf1f12ecb22be1c6395d57017bf750fd76496f`, tree
`c3558b90bf647febd900524e7afc40f8c2efbba4`. All 14 bound tests passed, and only
genuine `r03.mps.lanczos` (`A11`) is now `product_qualified` for
`functional_product_eligibility`. This prospectively clears the qualified-backend
cause recorded by the frozen R06/R07 blocks but does not rewrite those historical
results or record a rerun.

The later operator-overridden functional acceptance record rechecks that exact
software evidence and the passing R02 common-session conformance. R03 is now
`passed` because genuine A11 processing performs both canonical routes
repeatably while preserving the complete session and media contract, resource
lifetime, processing identity, atomic publication, and no fallback. The original
all-backend quality/performance/resource requirement has been removed from the
forward roadmap; its historical records remain unchanged. Production default, Auto,
holdout, quality/performance claims, product publication, and release remain
disabled.

- [Canonical Markdown](Mirmir_Apple_Native_ASH_Roadmap_2026-07-18.md)
- [Canonical JSON](Mirmir_Apple_Native_ASH_Roadmap_2026-07-18.json)
- [Roadmap Progress](../../README.md#roadmap-progress)
- [Accepted Architecture Decision](../decisions/0001-apple-native-adaptive-architecture.md)
- [R00 Current-Source Inventory](evidence/r00-current-source-inventory.md)
- [R01 Phase Evidence](evidence/r01/phase-evidence.md)
- [R02 Preregistration](evidence/r02/records/preregistration.json)
- [R02 Deterministic Fixture Catalog](evidence/r02/records/fixtures/fixture-catalog.json)
- [R02 Deterministic Software Conformance](evidence/r02/records/conformance.json) — local unpublished evidence; phase acceptance not claimed
- [R02 Functional Phase Acceptance](evidence/r02/records/functional-phase-acceptance.json) — additive declared-software-function-only acceptance; 27 passed, 0 failed, 0 skipped across six suites, including direct production-bootstrap and typed unavailable-service rejection proof
- [R03 Preregistration](evidence/r03/records/preregistration.json)
- [R03 Deterministic Fixture Catalog](evidence/r03/records/fixtures/fixture-catalog.json)
- [R03 Fail-Closed Baseline Conformance](evidence/r03/records/baseline-conformance.json) — local unpublished evidence; blocked result; phase acceptance not claimed
- [R03 v2 Product-Qualification Preregistration](evidence/r03/records/product-qualification-preregistration-v2.json)
- [R03 v2 Product-Qualification Fixture Catalog](evidence/r03/records/fixtures/product-qualification-fixture-catalog-v2.json)
- [R03 v2 Product-Qualification Execution Receipt](evidence/r03/records/product-qualification-execution-receipt-v2.json)
- [R03 v2 Product-Qualification Decision](evidence/r03/records/product-qualification-decision-v2.json) — passed for A11 functional product eligibility; preserved as the narrower v2 record
- [R03 Functional Phase Acceptance](evidence/r03/records/functional-phase-acceptance.json) — operator-overridden software-function gate passed; R03 accepted
- [R04 Preregistration](evidence/r04/records/preregistration.json)
- [R04 Deterministic Fixture Catalog](evidence/r04/records/fixtures/fixture-catalog.json)
- [R04 VideoToolbox Integration Conformance](evidence/r04/records/integration-conformance.json) — local unpublished diagnostic-only evidence; runtime not observed; phase acceptance not claimed
- [R04 Functional Phase Acceptance](evidence/r04/records/functional-phase-acceptance.json) — additive declared-software-function-only acceptance; 42 passed, 0 failed, 0 skipped across four suites
- [R05 Preregistration](evidence/r05/records/preregistration.json)
- [R05 Deterministic Fixture Catalog](evidence/r05/records/fixtures/fixture-catalog.json)
- [R05 MetalFX Suitability Conformance](evidence/r05/records/suitability-conformance.json) — local unpublished diagnostic-only evidence; native runtime not observed; phase acceptance not claimed
- [R05 Functional Phase Acceptance](evidence/r05/records/functional-phase-acceptance.json) — additive declared-software-function-only acceptance with `diagnostic_only` exit outcome; 46 passed, 0 failed, 0 skipped across five suites
- [R06 Preregistration](evidence/r06/records/preregistration.json)
- [R06 Deterministic Fixture Catalog](evidence/r06/records/fixtures/fixture-catalog.json)
- [R06 ASH Orchestration Conformance](evidence/r06/records/orchestration-conformance.json) — local unpublished blocked evidence; product and runtime observations not observed; phase acceptance not claimed
- [R06 Phase Evidence Manifest](evidence/r06/phase-evidence.json)
- [R06 Phase Evidence Summary](evidence/r06/phase-evidence.md)
- [R06 Functional Phase Acceptance](evidence/r06/records/functional-phase-acceptance.json) — additive declared-software-function-only acceptance; 42 passed, 0 failed, 0 skipped across seven suites
- [R07 Preregistration](evidence/r07/records/preregistration.json)
- [R07 Deterministic Fixture Catalog](evidence/r07/records/fixtures/fixture-catalog.json)
- [R07 Functional Execution Receipt](evidence/r07/records/functional-execution-receipt.json) — checkpoint-bound deterministic fixture simulation; 98 passed, 0 failed, 0 skipped
- [R07 Functional Phase Acceptance](evidence/r07/records/functional-phase-acceptance.json) — operator-defined software-function gate passed; comparative requirement superseded and not required
- [R08 Preregistration](evidence/r08/records/preregistration.json)
- [R08 Deterministic Fixture Catalog](evidence/r08/records/fixtures/fixture-catalog.json)
- [R08 Functional Execution Receipt](evidence/r08/records/functional-execution-receipt.json) — checkpoint-bound deterministic fixture simulation; 42 passed, 0 failed, 0 skipped
- [R08 Functional Phase Acceptance](evidence/r08/records/functional-phase-acceptance.json) — declared-software-function-only gate passed; comparative methods absent and non-gating
- [R09 Operator Authorization](evidence/r09/records/operator-authorization.json) — bounded experiment authorization bound to accepted R08 evidence
- [R09 Preregistration](evidence/r09/records/preregistration.json)
- [R09 Deterministic Fixture Catalog](evidence/r09/records/fixtures/fixture-catalog.json)
- [R09 Functional Execution Receipt](evidence/r09/records/functional-execution-receipt.json) — checkpoint-bound deterministic fixture simulation; 26 passed, 0 failed, 0 skipped
- [R09 Functional Phase Acceptance](evidence/r09/records/functional-phase-acceptance.json) — declared-software-function-only gate passed with `qualified_local_residual`; comparative methods absent and non-gating
- [R10 Preregistration](evidence/r10/records/preregistration.json) — preserved phase-start contract
- [R10 Deterministic Fixture Catalog](evidence/r10/records/fixtures/fixture-catalog.json)
- [R10 Deterministic Evaluation Catalog](evidence/r10/records/fixtures/evaluation-catalog.json)
- [R10 Deterministic Policy Catalog](evidence/r10/records/fixtures/policy-catalog.json)
- [R10 Functional Execution Receipt](evidence/r10/records/functional-execution-receipt.json) — checkpoint-bound deterministic fixture simulation; 39 passed, 0 failed, 0 skipped
- [R10 Functional Phase Acceptance](evidence/r10/records/functional-phase-acceptance.json) — declared-software-function-only gate passed; comparison, A/B, and superiority methods absent and non-gating
- [R11 Preregistration](evidence/r11/records/preregistration.json) — preserved phase-start contract bound to exact accepted R10 evidence
- [R11 Deterministic Fixture Catalog](evidence/r11/records/fixtures/fixture-catalog.json) — five observation states, exact identities, deterministic aggregation, rejection cases, and unconditional `no_market_claim`
- [R11 Traceability Run Receipt](evidence/r11/records/traceability-run-receipt.json) — exact-source deterministic five-state run with unconditional `no_market_claim`
- [R11 Functional Execution Receipt](evidence/r11/records/functional-execution-receipt.json) — exact-source deterministic fixture simulation; 76 passed, 0 failed, 0 skipped
- [R11 Functional Phase Acceptance](evidence/r11/records/functional-phase-acceptance.json) — declared-software-function-only gate passed; comparison methods absent and non-gating
- [R12 Functional Execution Receipt](evidence/r12/records/functional-execution-receipt.json) — exact-source contract execution; 85 passed, 0 failed, 0 skipped; strict lint covered 340 files with zero violations
- [R12 Functional Phase Acceptance](evidence/r12/records/functional-phase-acceptance.json) — declared-software-function-only gate passed; comparison and A/B methods absent and non-gating
- [R13 Release Candidate Receipt](evidence/r13/records/release-candidate-receipt.json) — exact Release app/archive identity and release-ready-candidate boundary
- [R13 Output Reopen Receipt](evidence/r13/records/output-reopen-receipt.json) — retained QuickTime MOV reopen and controlled metadata verification
- [R13 Functional Execution Receipt](evidence/r13/records/functional-execution-receipt.json) — exact-source execution; 183 passed, 0 failed, 0 skipped; strict lint covered 403 files with zero violations
- [R13 Functional Phase Acceptance](evidence/r13/records/functional-phase-acceptance.json) — operator-defined software-function gate passed; comparison and A/B methods absent and non-gating
- [R01-R13 Execution Handoff](Mirmir_R01-R13_Execution_Handoff_2026-07-19.md) — non-canonical implementation guidance
- [Roadmap Alignment Governance](../governance/roadmap-alignment.md)

Verified source hashes:

- Markdown: `93a99f92a18b1a88a9130e0916e318f8e5249fe0a63768b1bb46550536c39531`
- JSON: `e5264ab1009d568932614d3cf0f9985cdb5ef9d8c144d843c71e56bc77201178`

The complete Markdown roadmap is also published in the root README between stable canonical-roadmap markers. The ASH V3 branch and its testing, partial, failure, and diagnostic evidence are preserved as historical engineering evidence, not as a release.
