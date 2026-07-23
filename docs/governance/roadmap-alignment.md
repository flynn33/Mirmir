# Roadmap Alignment Governance

The `Roadmap alignment` GitHub check keeps the repository's published product
direction synchronized with the canonical roadmap. It runs for every pull request
to `main`, every push to `main`, merge-queue validation, and manual dispatch. The
required check has read-only repository permission, uses only Python's standard
library, and performs no live network requests after checkout. A separate
informational `Roadmap metadata audit` runs weekly or by manual dispatch.

## What the check enforces

The verifier reads `.github/roadmap-alignment-policy.json` and rejects drift in:

- the canonical roadmap Markdown and JSON paths, SHA-256 digests, version, date,
  and revision date;
- roadmap schema, phase IDs and ordering, phase dependency references, Apple-method
  IDs, and authorization values;
- the phase-status vocabulary and prerequisite rule: a phase marked `next`,
  `in_progress`, `evidence_ready`, or `passed` requires every declared dependency
  to be `passed`, except the exact policy-scoped R03, R04, R05, R06, and R07
  `in_progress` local continuations from their recorded unpublished predecessor
  closures and the separate evidence-bound R02, R03, R07, R08, and R09 functional
  acceptance contracts;
- the complete canonical Markdown embedded between the stable README markers;
- the generated `Roadmap Progress` indicators in the README;
- required roadmap, evidence-status, and historical-status language in the aligned
  repository documentation;
- the current Forsetti dependency boundary across tracked package manifests,
  generated project declarations, active paths, and decorated Swift imports;
- the schema-closed, exact-commit R00 C01-C11 source inventory, its generated
  Markdown, its fail-closed evidence boundaries, and candidate drift across every
  accepted source path;
- status-sensitive phase-start contracts: R02, R03, R04, R05, R06, R07, R08,
  R09, and R10 `in_progress`, `evidence_ready`, and `passed` states require
  regular, non-symlink start-contract files. R10 additionally requires exact
  R07 and R09 predecessors plus its preregistration and deterministic fixture,
  evaluation, and policy catalogs;
- tracked Forsetti repository, framework, or vendored paths forbidden by policy;
- the GitHub repository description and topics recorded as exact policy; and
- workflow triggers or commands that could open legacy P06/P07/P08 or holdout
  execution, create a tag or release, or use `pull_request_target`.

Unit tests run before the repository and inventory checks. The stable required-check name is
`Roadmap alignment`; that job depends on the macOS `R02 functional acceptance`,
`R04 functional acceptance`, `R05 functional acceptance`, and
`R06 functional acceptance` jobs and always evaluates all four results
explicitly, so a failed, cancelled, or skipped
prerequisite makes the required check fail. It cannot pass unless each fresh raw
Xcode result, exact selected-test identities, build action, checkpoint-bound
build surface, and checked-in acceptance validate. Later roadmap source
evolution does not rewrite or invalidate any historical checkpoint. CI
materializes R02 source commit
`eeabc4224100bc8ed86ae1208189bee508844210` in a detached worktree and runs the
selected tests there. It likewise materializes R04 source commit
`ab77e97867d51168e90c0190f6430d4acd769e68` before running the exact R04
selection, and R05 source commit
`7e1ab67340e4d6d95a3d92e8a48bc6cd356005b8` before running the exact R05
selection. It also materializes R06 source commit
`6c4a6d3d5f8a59c553b10c23783c148ccb3388a5` before running the exact seven-suite
R06/R07 selection. The current checkout then validates each raw result and checked
acceptance. The separate weekly metadata audit
uses three bounded attempts so description or topic changes made outside a pull
request become visible without making the required check network-dependent.

## Updating progress

Change phase statuses only in the canonical roadmap JSON after the corresponding
operator decision and required start or closure evidence are recorded. Five narrow exceptions apply
when direct operator instruction authorizes local implementation from an exact,
recorded phase-specific local closure:

- At the recorded local-continuation checkpoint, R03 could be `in_progress`
  while R02 remained `in_progress` only when its regular
  preregistration exactly binds R02 closure commit
  `673b0582c0b4d6b4ad81de6b01ba9e3f35f4e3d4` and tree
  `a5e95d810abacbdb872ddc6e94125103831e6fba` as
  `local_unpublished_closure`.
- R04 may be `in_progress` while R03 remains `in_progress` only when its regular
  preregistration exactly binds R03 closure commit
  `947983a8414c60e4f5f4246e6cb658792fc7c357` and tree
  `d1a89e5b9edf8d42b1da9ba06a3b6a0c139f08f3`. The bound R03 result is
  fail-closed and `blocked`, with closure state
  `local_unpublished_blocked_closure` and `predecessor_result: blocked`; this
  exception does not interpret it as success. The later additive A11 decision
  does not mutate this predecessor binding. It did not by itself advance R03;
  the later operator-overridden functional acceptance does so separately.
- R05 may be `in_progress` while R04 remains `in_progress` only when its regular
  preregistration exactly binds R04 closure commit
  `88e26f5967f7eb35a54791017ca0c2b888f2fbf5` and tree
  `4a7cc588b6fa51c21f2293e56cf3dea389acd908`. The bound R04 result is
  `diagnostic_only`, with closure state
  `local_unpublished_diagnostic_only_closure` and
  `predecessor_result: diagnostic_only`; product qualification, a production
  default, and acceptance remain unclaimed.
- R06 may be `in_progress` while R05 remains `in_progress` only when its regular
  preregistration exactly binds R05 closure commit
  `b955fc9d0b02dd066c359dfcb99a9ad31aeb817a` and tree
  `10a97bd3df7f72834f7afcb7fa3b63c598fa4931`. The bound R05 result is
  `diagnostic_only`, with closure state
  `local_unpublished_diagnostic_only_closure` and
  `predecessor_result: diagnostic_only`; product qualification, a production
  default, and acceptance remain unclaimed. R06 depends directly on R05; R04
  remains only a transitive unresolved dependency through R05. Hardware,
  simulator, and operator observation availability is non-blocking; unavailable
  observations are recorded as `not_observed` and create no runtime, quality, or
  performance claim.
- R07 may be `in_progress` while R06 remains `in_progress` only when its regular
  preregistration exactly binds R06 closure commit
  `9ed01ea938a933f6406fd67e88edb74e7c84f5f4` and tree
  `32365e745dbf53d59213fe2294a6b63ba2642df7`. The bound R06 result is
  fail-closed and `blocked`, with closure state
  `local_unpublished_blocked_closure` and `predecessor_result: blocked`; this
  exception does not interpret it as success. R07 is limited to fixture-only
  local implementation. Its temporal, artifact, chroma, spatial, aggregation,
  fixed-point, history, and tuning contracts must remain frozen in the regular
  preregistration and deterministic fixture catalog. Its frozen product-gate
  result is `blocked` for `upstream_no_product_qualified_primary_backend`, with
  no eligible route, selected plan, or output. Product metrics and hardware,
  simulator, and operator observations remain `not_observed`; no quality,
  performance, product, production-default, acceptance, publication, or release
  claim is authorized. The later A11 decision removes the R03-level eligibility
  absence prospectively, but does not mutate R06 or R07, establish a route, or
  authorize successor product evidence without an additive versioned contract.
  R07's frozen source-authority bytes are verified from its exact bound R06
  closure commit rather than from the successor worktree; current source remains
  subject to the repository's active architecture, lint, build, and test checks.

All five preregistrations record `accepted_merge_commit: null`,
`acceptance_state: not_claimed`, and
`continuation_scope: local_implementation_only`; each closure must be an ancestor
of `HEAD`. The exceptions never apply to `next`, `evidence_ready`, or `passed`.
They do not authorize publication, phase closure, acceptance, production
enablement, or release.

R08 follows the normal accepted-dependency path rather than a sixth local
continuation exception. Its `in_progress` start contract binds accepted R07 merge
commit `3fd13e57ec95b1ed98df71f4c83ab165bdfbab6b`, tree
`eb1614dd2a93e1bc4e1911bcf74f41cf372a3304`, and requires regular
preregistration and fixture-catalog files. The R08 start does not claim phase
acceptance, native Core AI execution, product routing, residual authorization, or
release authority.

A separate R02 functional acceptance contract permits canonical R02 to be
`passed` only when the policy-bound
`docs/roadmaps/evidence/r02/records/functional-phase-acceptance.json`, its
schema, Xcode log, and result summary are exact and
`Scripts/r02_phase_acceptance.py` rechecks source commit
`eeabc4224100bc8ed86ae1208189bee508844210`, tree
`ac402f993805cca499d2f688c6186c4684ce8dba`, the immutable passing conformance,
and all 27 selected tests across the six settled R02 suites. The two added direct
tests bind production bootstrap to `UnavailableUpscalerEngineService` and prove
its typed fail-closed `backendUnavailable(reason:)` rejection. This is the
intentional R02 production-unavailable boundary, not project completion or
production enablement. The accepted scope is
`declared_software_function_only`. The frozen preregistration, conformance, local
closure, and contemporaneous `phase_acceptance: not_claimed` state remain
unchanged historical evidence. This contract does not authorize production
upscaling, a production default, Auto, holdout, quality or performance claims,
product publication, or release.

The R04 functional acceptance contract permits canonical R04 to be `passed`
only when the policy-bound schema, record, Xcode log, and result summary are
regular exact files and `Scripts/r04_phase_acceptance.py` rechecks source commit
`ab77e97867d51168e90c0190f6430d4acd769e68`, tree
`446f71bb584f5d1fffcd20a17ac5e5507d3222b6`, and all 42 selected tests across
the four settled R04 suites. Deterministic simulation through the real R04
quality and low-latency backends and production FIFO verifies complete 2× media
transactions, exact-dimension 1.5× admission, active cancellation, identity,
reopen-before-publication, resource release, atomic publication, and no silent
fallback. The accepted scope is `declared_software_function_only`. The frozen
preregistration and diagnostic-only conformance remain unchanged historical
evidence. Native VideoToolbox model execution and readiness, hardware, simulator,
and operator observation remain `not_observed`; this contract does not authorize
a production default, Auto, native-framework or product qualification, quality,
performance, publication, or release.

The separate R03-only functional acceptance override formerly permitted
canonical R03 to be `passed` while R02 remained canonical `in_progress`. It
applies only when the policy-bound `functional-phase-acceptance.json` bytes and
identity are exact, the bound R02 common-session conformance passed, and the
dedicated `r03_phase_acceptance.py` validator rechecks the complete R03 v2
evidence. The accepted function is genuine A11 execution on both canonical
routes with repeatability, complete session/media preservation, reopen, atomic
publication, lifecycle/resource release, processing identity, no fallback, and
all applicable functional metrics passing. The override did not itself mark R02
passed, rewrite any historical record, or select a production default. The later
additive R02 acceptance is independent. Neither decision authorizes Auto,
holdout, quality/performance claims, product publication, or release.

A distinct R07-only functional acceptance override permitted canonical R07 to be
`passed` while R06 remained canonical `in_progress`. It applied only when the
policy-bound `functional-phase-acceptance.json` bytes and identity are exact, the
frozen R06 evidence bindings remain byte-exact and unaccepted, and the dedicated
`r07_phase_acceptance.py` validator rechecks the checkpoint-bound 98-test
deterministic software-function receipt. The operator superseded the comparative
backend requirement, so it is not an R07 acceptance gate. The override did not
mark R06 passed, rewrite frozen evidence, claim native or product execution,
select a production default, or authorize Auto, quality/performance claims,
product publication, or release. R06's later additive functional acceptance is
separate and leaves those frozen bytes unchanged.

The R08 functional acceptance contract permits canonical R08 to be `passed`
only when the policy-bound functional receipt and phase-acceptance bytes are
exact and `r08_phase_acceptance.py` rechecks implementation commit
`368b9284883c189be6a1139df6208bf0e88139dd`, tree
`f8e73d193b7b0c9df7005a7aa006de48ca48f77c`, and all 42 selected tests across
the 10 settled R08 suites. The accepted scope is
`declared_software_function_only` under deterministic fixture simulation.
Comparison-based testing is outside the roadmap and supplies no acceptance
dependency. Native Core AI, Xcode 27, model, hardware, simulator, and
operator-observed execution remain `not_observed`. This contract does not
authorize product qualification, a production default, Auto, pixel authority,
R09 progression or residual execution by itself, claims, publication, or release.

R09 may be `in_progress` only when the canonical authorization is
`authorized_for_r09_bounded_experiment`, the repository-owned operator record
binds accepted-R08 raw SHA-256
`0d81917a93cf56cae867c11b7c65fb3c85e53b7596929cf9eec2ef09c24634b0`
and its implementation commit/tree, and the frozen R09 preregistration and
fixture catalog validate. This permits deterministic bounded software
implementation only. Comparison methods are excluded and non-authorizing;
native observations may remain `not_observed`. Production, Auto, holdout,
claims, publication, and release remain unauthorized.

The R09 functional acceptance contract permits canonical R09 to be `passed`
only when all eight policy-frozen evidence paths are regular, non-symlink files
and `r09_phase_acceptance.py` rechecks implementation commit
`3ba7b2b5fdbde3a3f90f011cb548b85d46b2ac8b`, tree
`5f19024af0837d5efd54855bcf0fd705a50eadc9`, and all 26 selected tests across
the four R09 suites. The accepted scope is `declared_software_function_only`
under deterministic fixture simulation, with roadmap exit outcome
`qualified_local_residual`. The provider SHA-256 remains a semantic contract
identity whose source provenance is the checkpoint commit, tree, and named
bindings; fixture-catalog semantics are mapped to the selected tests, but the
catalog JSON is not directly executed by the Swift suite. Native Core AI,
model, hardware, simulator, operator-observed execution, and product
qualification remain `not_observed` or `not_claimed`. This contract does not
authorize production, Auto, holdout, claims, publication, or release. The R09
acceptance did not itself authorize R10 progression; the operator's later
continuation instruction separately authorizes R10 implementation.

R10 is `in_progress` only because both exact canonical predecessors, R07 and
R09, are `passed` and the operator separately authorized continuation. Its
policy-frozen start requirement binds four regular, non-symlink records:
`preregistration.json`, `fixture-catalog.json`, `evaluation-catalog.json`, and
`policy-catalog.json` under `docs/roadmaps/evidence/r10/records/`. The alignment
check rejects a missing or symlinked record, a changed path set, or canonical
predecessors other than exact `["R07", "R09"]`.

This is a start contract only. R10 functional acceptance files are not required
while the phase is `in_progress`; that requirement becomes active only if R10
is proposed as `passed`. Production Auto, holdout access, native execution,
product qualification, quality/performance claims, publication, and release
remain blocked, unauthorized, or unclaimed. Comparative methods remain outside
the forward roadmap and non-authorizing.

The dormant `passed` requirement names only stable evidence paths: the R10
phase-acceptance validator and tests; calibration-run, functional-receipt, and
functional-acceptance schemas; functional execution and acceptance records; the
unit-test log; and the checked-in calibration `run-receipt.json`. Final
checkpoint and frozen-policy artifacts use content-addressed filenames, so
policy does not fabricate their future leaf names. The later acceptance
validator must resolve and verify those dynamic bindings from the run receipt
before R10 can pass.

The R05 functional acceptance contract permits canonical R05 to be `passed`
only when the policy-bound schema, record, Xcode log, and result summary are
regular exact files and `Scripts/r05_phase_acceptance.py` rechecks source commit
`7e1ab67340e4d6d95a3d92e8a48bc6cd356005b8`, tree
`adce5b65fd3d752a1467925232847e086d0b3e7a`, and all 46 selected tests across
the five settled R05 suites. Deterministic simulation through the real spatial
backend and production FIFO verifies source-derived A07 1.5× and 2× output and a
reopened H.264/AAC/timed-metadata transaction before atomic publication. The
real driver contracts verify support-before-construction, the explicit color
bridge, ordering, cancellation, and typed failures. A08-A10 retain successful
`rejected_for_decoded_video` dispositions. The accepted exit outcome is
`diagnostic_only`, limited to `declared_software_function_only`; comparison is
not required. The frozen preregistration and suitability record remain
historical. Native MetalFX execution, hardware, simulator, operator observation,
product qualification, quality, and performance remain `not_observed` or
`not_claimed`; this contract does not authorize a production default, Auto,
publication, or release.

The R06 functional acceptance contract permits canonical R06 to be `passed`
only when the policy-bound schema, record, Xcode log, and result summary are
regular exact files and `Scripts/r06_phase_acceptance.py` rechecks source commit
`6c4a6d3d5f8a59c553b10c23783c148ccb3388a5`, tree
`beb0f8c666550c6c36dae5a2185cac58d2494132`, and all 42 selected tests across
the seven settled R06/R07 suites. The deterministic selection proves exact
context/profile mapping, eligibility filtering, scoring, stable tie-breaking,
transitions, one traceable whole-frame plan, bounded masks, reason identity,
configuration behavior, and R07 transaction commit/rollback around the real R06
orchestrator. The accepted scope is `declared_software_function_only` under
deterministic fixture integration. The frozen blocked product-gate evidence
remains immutable history, and R06 v1 still rejects product-scope orchestration.
This contract does not claim product routing or qualification, native-framework
or hardware execution, a production default, Auto, quality, performance,
publication, or release.

The operator's software-function acceptance decision applies to R02, R04, R06,
R08, R09, and later phases. Acceptance asks whether checkpoint-bound
tests prove that the software performs the task and honors the boundaries it
claims. Comparison-based testing is outside the forward roadmap and cannot supply
or withhold phase progression. Historical evidence and negative records remain
unchanged.

Unavailable hardware, simulator, Xcode 27/Core AI framework, model, or operator
observation is recorded as `not_observed` and does not block a separately
identified deterministic software-function run. Such a run cannot claim native
execution, model quality, performance, memory, specialization, AOT, or zero-copy
facts. The operator's later `resume work` directive supplies the separate R09
implementation authorization bound to accepted R08 functional evidence; no
comparison grants that authority.

R10 is `in_progress`; acceptance still requires checkpoint-bound proof that its optimizer/calibration
software is deterministic, finitely bounded, constraint-preserving, resumable,
transactional, and identity-complete. R11 acceptance requires traceable evidence
and claim-scope machinery that rejects invalid inputs and unsupported claims and
emits `no_market_claim` by default.
`market_leading_claim` remains blocked without exact supporting evidence and a
separate operator authorization.

Update the digest for every changed canonical source and
affected contract fields in the alignment policy in the same change.
Then regenerate the clearly labeled README progress section and verify the
repository:

```sh
python3 Scripts/roadmap_alignment.py --write-readme
python3 Scripts/r00_inventory.py --write-markdown
python3 -m unittest Scripts/tests/test_roadmap_alignment.py Scripts/tests/test_r00_inventory.py Scripts/tests/test_r01_observation_waiver.py Scripts/tests/test_r02_contracts.py Scripts/tests/test_r02_phase_acceptance.py Scripts/tests/test_r03_contracts.py Scripts/tests/test_r03_product_qualification.py Scripts/tests/test_r03_phase_acceptance.py Scripts/tests/test_r04_contracts.py Scripts/tests/test_r04_phase_acceptance.py Scripts/tests/test_r05_contracts.py Scripts/tests/test_r05_phase_acceptance.py Scripts/tests/test_r06_contracts.py Scripts/tests/test_r06_phase_acceptance.py Scripts/tests/test_r07_contracts.py Scripts/tests/test_r07_phase_acceptance.py Scripts/tests/test_r08_contracts.py Scripts/tests/test_r08_phase_acceptance.py Scripts/tests/test_r09_contracts.py Scripts/tests/test_r09_phase_acceptance.py
python3 Scripts/roadmap_alignment.py --check
python3 Scripts/r00_inventory.py --check
python3 Scripts/r02_contracts.py --check-preregistration
python3 Scripts/r02_contracts.py --check-fixtures
test ! -f docs/roadmaps/evidence/r02/records/conformance.json || python3 Scripts/r02_contracts.py --check-conformance
python3 Scripts/r02_phase_acceptance.py --check
python3 Scripts/r03_contracts.py --check-preregistration
python3 Scripts/r03_contracts.py --check-fixtures
test ! -f docs/roadmaps/evidence/r03/records/baseline-conformance.json || python3 Scripts/r03_contracts.py --check-conformance
python3 Scripts/r03_product_qualification.py --check-preregistration
python3 Scripts/r03_product_qualification.py --check-fixtures
python3 Scripts/r03_product_qualification.py --check-receipt
python3 Scripts/r03_product_qualification.py --check-decision
python3 Scripts/r03_phase_acceptance.py --check
python3 Scripts/r04_contracts.py --check-preregistration
python3 Scripts/r04_contracts.py --check-fixtures
test ! -f docs/roadmaps/evidence/r04/records/integration-conformance.json || python3 Scripts/r04_contracts.py --check-conformance
python3 Scripts/r04_phase_acceptance.py --check
python3 Scripts/r05_contracts.py --check-preregistration
python3 Scripts/r05_contracts.py --check-fixtures
test ! -f docs/roadmaps/evidence/r05/records/suitability-conformance.json || python3 Scripts/r05_contracts.py --check-conformance
python3 Scripts/r05_phase_acceptance.py --check
python3 Scripts/r06_contracts.py --check-preregistration
python3 Scripts/r06_contracts.py --check-fixtures
test ! -f docs/roadmaps/evidence/r06/records/orchestration-conformance.json || python3 Scripts/r06_contracts.py --check-conformance
python3 Scripts/r06_phase_acceptance.py --check
python3 Scripts/r07_contracts.py --check-preregistration
python3 Scripts/r07_contracts.py --check-fixtures
test ! -f docs/roadmaps/evidence/r07/records/temporal-artifact-conformance.json || python3 Scripts/r07_contracts.py --check-conformance
python3 Scripts/r07_phase_acceptance.py --check
python3 Scripts/r08_contracts.py --check-preregistration
python3 Scripts/r08_contracts.py --check-fixtures
python3 Scripts/r08_phase_acceptance.py --check
python3 Scripts/r09_contracts.py --all
python3 Scripts/r09_phase_acceptance.py --check
GITHUB_TOKEN="..." python3 Scripts/roadmap_alignment.py --check-github-metadata --metadata-attempts 3
```

`--write-readme` synchronizes only the canonical-roadmap and progress blocks;
it does not change roadmap policy, phase authorization, or canonical evidence.
`r00_inventory.py --write-markdown` regenerates only the human-readable summary
from the canonical inventory JSON.
The metadata command compares GitHub's current description and topic set with the
exact values in policy; it requires a token with read access to repository
metadata and does not modify GitHub.

## Current external-runtime boundary

Established at `R00: evidence_ready` and retained at `R00: passed`, the app-owned
runtime has replaced the former package boundary. The Forsetti repository is
reference-only: no repository coordinate,
package product, Swift import, framework, submodule, vendored source, generated
project reference, or active source/resource path is permitted. Normal builds
therefore require no network package resolution.

The verifier keeps status-sensitive rules so inconsistent or partially removed
states fail deterministically:

- `planned`, `next`, or `blocked`: both tracked project declarations must retain
  the exact approved legacy URL, revision, and three products;
- `in_progress`: the dependency must be either exact and unchanged or completely
  removed; partial or unpinned migration fails; and
- `evidence_ready` or `passed`: repository coordinates, package products,
  package imports, and Forsetti-named active source/resource paths must be absent.

## Non-release boundaries

This check does not run legacy P06/P07/P08 scripts, open holdout data, build the
application, execute product tests, create tags, or publish releases. Passing it
does not authorize production Auto mode, G08, a product-quality claim, a
market-position claim, or a release. It establishes repository alignment only.

## Amending the policy

A policy amendment requires an explicit roadmap decision and a reviewed pull
request. Update the canonical roadmap sources first, then update the policy's
digests and affected contract fields, regenerate README progress, update aligned
documentation, and add or revise verifier tests for the new rule. The pull request
must identify affected phase IDs, authorization changes, accepted evidence, and
the Forsetti-boundary impact.

Policy changes are visible in the same pull request as the material they govern;
they do not provide independent authorization. Reviewers must compare the change
with the accepted roadmap decision and evidence before merging it.

## Limitations

The verifier checks committed repository state. It does not determine whether
evidence is scientifically sufficient, whether a phase's implementation works,
or whether a PR description is truthful. PR-template metadata is reviewer guidance
in this initial slice and is not parsed by the workflow. Branch-protection rules
must separately require the `Roadmap alignment` check before merging to `main`.
