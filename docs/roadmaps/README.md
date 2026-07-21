# Mirmir Roadmaps

The current product direction is **Mirmir Apple-Native Adaptive Video Enhancement Roadmap 1.0.1**, published 2026-07-18 and revised 2026-07-21.

Current phase state: `R00: passed`; `R01: passed`; `R02: in_progress`;
`R03: in_progress`; `R04: in_progress`; `R05: in_progress`;
`R06: in_progress` under the exact
local-continuation exceptions. R03's bound result remains fail-closed and
`blocked`; R04 is local
implementation only with a commit-bound `diagnostic_only` checkpoint. R04
runtime, hardware, simulator, and operator observations remain `not_observed`;
R05 has a local unpublished commit-bound `diagnostic_only` checkpoint. Native
MetalFX execution, hardware, simulator, operator observation, media reopen,
quality, performance, and phase acceptance remain unclaimed. R06 is
preregistered for deterministic fixture-only orchestration; the implementation
source for its local unpublished blocked checkpoint is commit
`9246934c027e97f2b2ae3af35b0c4892154d761c`, tree
`1235596387d4eabd2ecb4ea1a29221c44ec425fe`. Its deterministic software
conformance passed, but its product gate remains fail-closed for
`no_product_qualified_primary_backend`. Product, hardware, simulator, and
operator observations remain `not_observed`; quality, performance, product,
production-default, acceptance, publication, and release claims remain unmade.

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
- [R01-R13 Execution Handoff](Mirmir_R01-R13_Execution_Handoff_2026-07-19.md) — non-canonical implementation guidance
- [Roadmap Alignment Governance](../governance/roadmap-alignment.md)

Verified source hashes:

- Markdown: `e55495523117cdc1659a3118ffba498e62e5e3c4b540dab08ec088b45376c561`
- JSON: `cbdb6448193e18dd9cde2779feec093b3b05de716a23e65a26c11de7e1782d8f`

The complete Markdown roadmap is also published in the root README between stable canonical-roadmap markers. The ASH V3 branch and its testing, partial, failure, and diagnostic evidence are preserved as historical engineering evidence, not as a release.
