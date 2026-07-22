# Mirmir Roadmaps

The current product direction is **Mirmir Apple-Native Adaptive Video Enhancement Roadmap 1.0.1**, published 2026-07-18 and revised 2026-07-21.

Current phase state: `R00: passed`; `R01: passed`; `R02: in_progress`;
`R03: passed`; `R04: in_progress`; `R05: in_progress`;
`R06: in_progress`; `R07: passed` under the operator-defined deterministic
software-function gate; `R08: planned`. R03's frozen v1
result remains fail-closed and `blocked`; R04 is local implementation only with
a commit-bound `diagnostic_only` checkpoint. R04
runtime, hardware, simulator, and operator observations remain `not_observed`;
R05 has a local unpublished commit-bound `diagnostic_only` checkpoint. Native
MetalFX execution, hardware, simulator, operator observation, media reopen,
quality, performance, and phase acceptance remain unclaimed. R06 is
preregistered for deterministic fixture-only orchestration; the implementation
source for its local unpublished blocked checkpoint is commit
`9246934c027e97f2b2ae3af35b0c4892154d761c`, tree
`1235596387d4eabd2ecb4ea1a29221c44ec425fe`. Its deterministic software
conformance passed, but its frozen product-gate result is fail-closed for
`no_product_qualified_primary_backend`. Product, hardware, simulator, and
operator observations remain `not_observed`; quality, performance, product,
production-default, acceptance, publication, and release claims remain unmade.
R06's policy-frozen local unpublished blocked closure is commit
`9ed01ea938a933f6406fd67e88edb74e7c84f5f4`, tree
`32365e745dbf53d59213fe2294a6b63ba2642df7`; its acceptance remains unclaimed.
R07 began fixture-only local implementation from that exact blocked closure. Its
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
coordinator, and transaction behavior. The comparative backend requirement is
explicitly `superseded_not_required`; it is not an acceptance gate. This scope
does not claim native framework or hardware execution, product routing, a
production default, Auto, media quality, performance, publication, or release.
R06 remains `in_progress` and unaccepted. R08 remains `planned`.

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
all-backend quality/performance/resource comparison is optional comparative
evidence rather than a phase-acceptance prerequisite. Production default, Auto,
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
- [R05 Preregistration](evidence/r05/records/preregistration.json)
- [R05 Deterministic Fixture Catalog](evidence/r05/records/fixtures/fixture-catalog.json)
- [R05 MetalFX Suitability Conformance](evidence/r05/records/suitability-conformance.json) — local unpublished diagnostic-only evidence; native runtime not observed; phase acceptance not claimed
- [R06 Preregistration](evidence/r06/records/preregistration.json)
- [R06 Deterministic Fixture Catalog](evidence/r06/records/fixtures/fixture-catalog.json)
- [R06 ASH Orchestration Conformance](evidence/r06/records/orchestration-conformance.json) — local unpublished blocked evidence; product and runtime observations not observed; phase acceptance not claimed
- [R06 Phase Evidence Manifest](evidence/r06/phase-evidence.json)
- [R06 Phase Evidence Summary](evidence/r06/phase-evidence.md)
- [R07 Preregistration](evidence/r07/records/preregistration.json)
- [R07 Deterministic Fixture Catalog](evidence/r07/records/fixtures/fixture-catalog.json)
- [R07 Functional Execution Receipt](evidence/r07/records/functional-execution-receipt.json) — checkpoint-bound deterministic fixture simulation; 98 passed, 0 failed, 0 skipped
- [R07 Functional Phase Acceptance](evidence/r07/records/functional-phase-acceptance.json) — operator-defined software-function gate passed; comparative requirement superseded and not required
- [R01-R13 Execution Handoff](Mirmir_R01-R13_Execution_Handoff_2026-07-19.md) — non-canonical implementation guidance
- [Roadmap Alignment Governance](../governance/roadmap-alignment.md)

Verified source hashes:

- Markdown: `a6f7197f00eb5ba3e0aac657568357f3535b4424c3f7fb6922be6498f7479cfb`
- JSON: `6ab465e2f144d958bca3d85f902af5791ee2ef64fd733048bd5259f1e34d7186`

The complete Markdown roadmap is also published in the root README between stable canonical-roadmap markers. The ASH V3 branch and its testing, partial, failure, and diagnostic evidence are preserved as historical engineering evidence, not as a release.
