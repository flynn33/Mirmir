# Mirmir R01-R13 Execution Handoff

- **Handoff version:** 2.0
- **Roadmap version:** 1.0.1
- **Publication date:** 2026-07-19
- **Revision date:** 2026-07-23
- **Repository:** `flynn33/Mirmir`
- **Current execution state:** `R00`-`R10: passed`; `R11: in_progress`;
  `R12`-`R13: planned`
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
- **R02 operator-defined functional acceptance source:**
  `eeabc4224100bc8ed86ae1208189bee508844210`; tree
  `ac402f993805cca499d2f688c6186c4684ce8dba`; 27 tests passed across six
  settled R02 suites with zero failures and zero skips; acceptance scope
  `declared_software_function_only`; R02 is `passed`
- **R03 local preregistration source:** R02 local unpublished closure above;
  `accepted_merge_commit: null`
- **R03 immutable v1 local blocked closure:**
  `947983a8414c60e4f5f4246e6cb658792fc7c357`; tree
  `d1a89e5b9edf8d42b1da9ba06a3b6a0c139f08f3`; acceptance not claimed
- **R03 A11 functional product-qualification source:**
  `dfdf1f12ecb22be1c6395d57017bf750fd76496f`; tree
  `c3558b90bf647febd900524e7afc40f8c2efbba4`; v2 decision `passed` for
  `r03.mps.lanczos` functional product eligibility; preserved as the narrower
  v2 decision
- **R03 operator-overridden functional acceptance source:**
  `b5c19c0040f845b7f32fe98bd5f01249c1b071f2`; tree
  `74e39285521fe31f9588cff5e43184c8f91f9180`; acceptance record `passed` for
  `functional_software_phase_acceptance`; R03 is `passed`
- **R04 local preregistration:**
  `2a729f9f641ef949681d81ebb3f98f68d7da29fc`; tree
  `59bfd516ebfa2260fedaf835d0a32a8f8f7cc6ee`
- **R04 implementation source:**
  `73d6f1df9d9b443209d55a6c9deea29923d49bc4`; tree
  `90c45e2c583defc7aa593f9199512719884de0d0`
- **R04 local diagnostic-only closure:**
  `88e26f5967f7eb35a54791017ca0c2b888f2fbf5`; tree
  `4a7cc588b6fa51c21f2293e56cf3dea389acd908`; acceptance not claimed
- **R04 declared-software-function acceptance source:**
  `ab77e97867d51168e90c0190f6430d4acd769e68`; tree
  `446f71bb584f5d1fffcd20a17ac5e5507d3222b6`; 42 tests passed across four
  settled R04 suites with zero failures and zero skips; acceptance scope
  `declared_software_function_only`; R04 is `passed`
- **R05 local preregistration:**
  `6a327428c88f32517bf5cf931e6f18a65a24b5c2`; tree
  `bfc53e9077fcb7bcab233ca79c4575ef1f69fda2`; R04 diagnostic-only closure
  above is the source and `accepted_merge_commit: null`
- **R05 implementation source:**
  `3e5188ece317d3ebc492c7a8e26345837836fc67`; tree
  `92b15f3948ffa38dc787136177551187bfb2fbbf`
- **R05 local diagnostic-only closure:**
  `b955fc9d0b02dd066c359dfcb99a9ad31aeb817a`; tree
  `10a97bd3df7f72834f7afcb7fa3b63c598fa4931`; acceptance not claimed
- **R05 declared-software-function acceptance source:**
  `7e1ab67340e4d6d95a3d92e8a48bc6cd356005b8`; tree
  `adce5b65fd3d752a1467925232847e086d0b3e7a`; 46 tests passed across five
  settled R05 suites with zero failures and zero skips; exit outcome
  `diagnostic_only`; acceptance scope `declared_software_function_only`; R05 is
  `passed`
- **R06 local preregistration source:** R05 diagnostic-only closure above;
  `accepted_merge_commit: null`
- **R06 implementation source for the local unpublished blocked closure:**
  `9246934c027e97f2b2ae3af35b0c4892154d761c`; tree
  `1235596387d4eabd2ecb4ea1a29221c44ec425fe`; acceptance not claimed
- **R06 local unpublished blocked closure:**
  `9ed01ea938a933f6406fd67e88edb74e7c84f5f4`; tree
  `32365e745dbf53d59213fe2294a6b63ba2642df7`; `predecessor_result: blocked`;
  acceptance not claimed
- **R06 declared-software-function acceptance source:**
  `6c4a6d3d5f8a59c553b10c23783c148ccb3388a5`; tree
  `beb0f8c666550c6c36dae5a2185cac58d2494132`; 42 tests passed across seven
  settled R06/R07 suites with zero failures and zero skips; acceptance scope
  `declared_software_function_only`; R06 is `passed`
- **R07 local preregistration source:** R06 blocked closure above;
  `accepted_merge_commit: null`
- **R07 deterministic implementation checkpoint:**
  `1b46ad469265a6ba837a8449d28b8850889f1d3f`; tree
  `09d3a48df01738bb26077aadfd83c08e389a1dc2`
- **R07 operator-defined functional acceptance:** 98 checkpoint-bound tests
  passed across 11 settled R07 test classes, with zero failures and zero skips;
  acceptance scope `functional_deterministic_software_phase_acceptance`;
  comparative requirement `superseded_not_required`; R07 is `passed`
- **R08 deterministic implementation checkpoint:**
  `368b9284883c189be6a1139df6208bf0e88139dd`; tree
  `f8e73d193b7b0c9df7005a7aa006de48ca48f77c`
- **R08 declared-software-function acceptance:** 42 checkpoint-bound tests
  passed across 10 settled R08 test suites, with zero failures and zero skips;
  acceptance scope `declared_software_function_only`; no comparative method was
  run or required; R08 is `passed`
- **R09 deterministic implementation checkpoint:**
  `3ba7b2b5fdbde3a3f90f011cb548b85d46b2ac8b`; tree
  `5f19024af0837d5efd54855bcf0fd705a50eadc9`
- **R09 declared-software-function acceptance:** 26 checkpoint-bound selected
  tests passed across four settled R09 suites, with zero failures and zero
  skips; exit outcome `qualified_local_residual`; acceptance scope
  `declared_software_function_only`; no comparative method was run or required;
  R09 is `passed`
- **R10 deterministic implementation checkpoint:**
  `3a76c6a03ea0f52f2a2395925badd5d5d1c03c6b`; tree
  `37951da694ab4fbca6f8c663bb2883e5084b861c`
- **R10 declared-software-function acceptance:** 39 checkpoint-bound optimizer
  and persistence tests passed with zero failures and zero skips; nine
  candidates evaluated, three scored, six rejected, ten checkpoints published,
  `fixture-valid-alpha` selected, and typed reopen passed; acceptance scope
  `declared_software_function_only`; no comparative method was run or required;
  R10 is `passed`
- **R11 phase start:** the regular preregistration and deterministic fixture
  catalog bind accepted-R10 closure commit
  `8d4283d2f3fbb104ef589f002de2fd6ccadad0f8`, tree
  `ee0461cff1fea9461f619ce904376ebdb128a2f5`, accepted implementation commit
  `3a76c6a03ea0f52f2a2395925badd5d5d1c03c6b`, tree
  `37951da694ab4fbca6f8c663bb2883e5084b861c`, and the exact R10 functional
  execution and phase-acceptance records; `python3 Scripts/r11_contracts.py
  --all` passes; R11 is `in_progress` and acceptance is not claimed
- **Continuation state:** `R01: passed`; `R02: passed`; `R03: passed`;
  `R04: passed`; `R05: passed`; `R06: passed`;
  `R07: passed`; `R08: passed`; `R09: passed`; `R10: passed`;
  `R11: in_progress`

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

### R02 operator-defined functional acceptance — 2026-07-23

The additive
`docs/roadmaps/evidence/r02/records/functional-phase-acceptance.json` record
binds source commit `eeabc4224100bc8ed86ae1208189bee508844210`, tree
`ac402f993805cca499d2f688c6186c4684ce8dba`, the immutable passing R02
conformance, and a fresh six-suite Xcode run with 27 tests passed, zero failed,
and zero skipped. The run verifies the declared registry, common
backend/session, stage, planner, typed-outcome, FIFO lifecycle, identity,
fallback, media, reopen, resource-lifetime, and atomic-publication software
contracts. Two direct tests additionally bind production bootstrap to
`UnavailableUpscalerEngineService` and prove its typed fail-closed
`backendUnavailable(reason:)` rejection. This is the intentional R02
production-unavailable boundary, not project completion or production
enablement.

The frozen preregistration, conformance, and local closure continue to record the
truthful historical `phase_acceptance: not_claimed` state. The additive decision
does not rewrite those bytes. R02 is `passed` only for
`declared_software_function_only`; production upscaling, a production default,
Auto, holdout, quality or performance claims, product publication, and release
remain unauthorized.

R03 local implementation begins only from a frozen preregistration that binds
that exact commit and tree with `accepted_merge_commit: null`,
`acceptance_state: not_claimed`, and
`continuation_scope: local_implementation_only`. Its matrix contains eight whole-frame deterministic
paths and two support stages across exact 720p-to-1080p, 1080p-to-2160p,
analytic-artifact, temporal-repeatability, and media-transaction fixtures.
Unavailable execution receives `not_observed`; no production default,
performance claim, or product qualification is enabled.

### R03 blocked closure and R04 implementation checkpoint — 2026-07-20

R03's frozen media route and bound R02 member are incompatible. The local
fail-closed record is therefore `blocked` in commit
`947983a8414c60e4f5f4246e6cb658792fc7c357`, tree
`d1a89e5b9edf8d42b1da9ba06a3b6a0c139f08f3`. R03 remains canonical
`in_progress`, all runtime subjects and metrics remain `not_observed`, and no
acceptance or product claim follows.

R04 preregistration commit `2a729f9f641ef949681d81ebb3f98f68d7da29fc`
binds that exact negative predecessor. R04 implementation commit
`73d6f1df9d9b443209d55a6c9deea29923d49bc4`, tree
`90c45e2c583defc7aa593f9199512719884de0d0`, replaces the VideoToolbox
placeholder with guarded macOS 26 quality and low-latency `VTFrameProcessor`
sessions, exact route admission, model lifecycle handling, declared buffer
attributes, retained presentation-order history, reset/submission/cancellation
semantics, and optional optical-flow support.

The commit-bound R04 conformance result is `diagnostic_only`. All 39 focused
macOS Xcode tests pass, Swift source/test typechecks pass, and strict SwiftLint
is clean. The focused Xcode run excluded Metal shader compilation because the
optional Metal Toolchain was unavailable; R04 adds no Metal shader. Actual
model-backed processing, model readiness, quality, performance, hardware,
simulator, and operator-observed operation are `not_observed`. Quality 1.5× is
the frozen typed `public_contract_unrepresentable` rejection. R04 remains
`in_progress`, local unpublished, disabled as a production default, and
unaccepted.

### R04 declared-software-function acceptance — 2026-07-23

The additive R04 functional acceptance binds source commit
`ab77e97867d51168e90c0190f6430d4acd769e68`, tree
`446f71bb584f5d1fffcd20a17ac5e5507d3222b6`, and a fresh macOS arm64 run of 42
tests across the contracts, session adapter, availability, and functional
phase-acceptance suites, with zero failures and zero skips. Deterministic
simulation drives source-derived frames through the real R04 quality and
low-latency backends and production FIFO. It verifies complete 2× media
transactions, exact-dimension 1.5× admission, active cancellation, identity,
reopen-before-publication, resource release, atomic publication, and no silent
fallback.

R04 is `passed` only for `declared_software_function_only`. The frozen
preregistration and diagnostic-only conformance bytes remain unchanged
historical evidence. The run excluded Metal shader compilation because the
optional Metal Toolchain was unavailable; R04 adds no Metal shader. Native
VideoToolbox model execution and readiness, hardware, simulator, and operator
observation remain `not_observed`. No production default, Auto, native-framework,
product-qualification, quality, performance, publication, or release claim
follows.

### R05 local implementation start — 2026-07-20

R05 preregistration binds exact R04 diagnostic-only closure commit
`88e26f5967f7eb35a54791017ca0c2b888f2fbf5`, tree
`4a7cc588b6fa51c21f2293e56cf3dea389acd908`, as
`local_unpublished_diagnostic_only_closure` with
`predecessor_result: diagnostic_only`, `accepted_merge_commit: null`, and
`continuation_scope: local_implementation_only`. At that historical checkpoint,
R04 remained canonical `in_progress` and unaccepted; the later additive
functional acceptance above does not rewrite the frozen R05 predecessor binding.

The frozen R05 matrix contains exact A07 spatial 1.5× and 2× routes through an
explicit left-sited BT.709 video-range NV12 to linear RGBA16Float bridge. A08,
A09, and A10 are typed `rejected_for_decoded_video` contracts because the
decoded-video boundary lacks evidence-backed renderer motion, depth, jitter,
G-buffer, camera, UI, and output-timing semantics. The implementation must not
fabricate those inputs. Native execution, quality, performance, comparison, and
media-reopen evidence remain `not_observed` until actually observed; their
absence is non-blocking under the operator override and makes no qualification,
default, acceptance, publication, or release claim.

### R05 diagnostic-only implementation checkpoint — 2026-07-21

R05 implementation commit `3e5188ece317d3ebc492c7a8e26345837836fc67`,
tree `92b15f3948ffa38dc787136177551187bfb2fbbf`, implements the two frozen A07
fixture routes, the exact NV12/linear bridge, support-before-construction,
private-texture staging, ordered completion and publication, retained FIFO
ownership, cancellation, typed failures, and no silent fallback. A08-A10 reject
decoded-video admission before any native factory call.

All 44 focused macOS Xcode tests pass and strict SwiftLint is clean. Metal
shader compilation was excluded because the optional Metal Toolchain was
unavailable; R05 adds no Metal shader. The commit-bound R05 conformance result
is `diagnostic_only`: both A07 runtime subjects are `not_observed`, and all
A08-A10 subjects retain their exact `rejected_for_decoded_video` dispositions.
Native MetalFX execution, hardware, simulator, operator observation, media
reopen, quality, performance, and baseline comparison remain `not_observed`.
R05 remains canonical `in_progress`, local unpublished, disabled as a
production default, and unaccepted.

### R05 declared-software-function acceptance — 2026-07-23

The additive R05 functional acceptance binds source commit
`7e1ab67340e4d6d95a3d92e8a48bc6cd356005b8`, tree
`adce5b65fd3d752a1467925232847e086d0b3e7a`, and a fresh macOS arm64 run of 46
tests across the contracts, color bridge, spatial driver, spatial backend, and
functional phase-acceptance suites, with zero failures and zero skips.
Deterministic simulation produces source-derived A07 1.5× and 2× output through
the real backend and production FIFO, and the 2× route completes a reopened
2160p H.264/AAC/timed-metadata transaction before atomic publication. The
frozen suites verify the real driver's support query, explicit color bridge,
ordering, cancellation, and typed failures. A08-A10 retain successful
`rejected_for_decoded_video` dispositions.

R05 is `passed` with exit outcome `diagnostic_only`, limited to
`declared_software_function_only`. The frozen preregistration and suitability
bytes remain unchanged historical evidence, and comparison was not run or
required. The run excluded Metal shader compilation because the optional Metal
Toolchain was unavailable; R05 adds no Metal shader. Native MetalFX execution,
hardware, simulator, operator observation, product qualification, quality, and
performance remain `not_observed` or `not_claimed`. No production default, Auto,
publication, or release authority follows.

### R06 local implementation start — 2026-07-21

R06 preregistration binds exact R05 diagnostic-only closure commit
`b955fc9d0b02dd066c359dfcb99a9ad31aeb817a`, tree
`10a97bd3df7f72834f7afcb7fa3b63c598fa4931`, as
`local_unpublished_diagnostic_only_closure` with
`predecessor_result: diagnostic_only`, `accepted_merge_commit: null`, and
`continuation_scope: local_implementation_only`. At that historical checkpoint,
R05 remained canonical `in_progress` and unaccepted, and R04 remained
transitively unresolved. The later additive R04/R05 acceptances do not rewrite
the frozen R06 predecessor binding or blocked result.

The frozen R06 slice is fixture-only and preserves the existing nine-bit
`ASHState`. It adds immutable continuous context, all sixteen versioned
four-bit message profiles, integer scoring with stable lexical ties, exact
eligibility filtering, one whole-frame route, typed hysteresis/dwell/cut/fatal-
failover transitions, bounded luma/chroma/postprocess masks, and the six frozen
ablation configurations.

At this frozen R06 checkpoint, the R03-R05 pool contained no product-qualified
primary backend. Product admission therefore stopped before scoring and route
construction with exact
reason `no_product_qualified_primary_backend`, eligible count zero, and no
route, plan, or output. All six product ablations remain `not_observed`; the
preregistered local result is fail-closed `blocked` because of that eligibility
boundary. Hardware, simulator, and operator observation remain non-blocking
`not_observed` and are not the cause. No product, quality, performance,
acceptance, publication, or release claim follows.

### R06 declared-software-function acceptance — 2026-07-23

The additive functional acceptance binds source commit
`6c4a6d3d5f8a59c553b10c23783c148ccb3388a5`, tree
`beb0f8c666550c6c36dae5a2185cac58d2494132`, and a fresh macOS arm64 Xcode run
of 42 tests across seven settled R06/R07 suites. All 42 tests passed with zero
failures and zero skips.

The selected tests prove deterministic context/profile mapping, eligibility
filtering, integer scoring and stable tie-breaking, one traceable whole-frame
plan, reason identity, transitions, bounded masks, and configuration controls.
The additive test proves higher-scoring fixture-ineligible and non-whole-frame
candidates cannot enter the plan, candidate ordering cannot change the result,
and value inputs remain unchanged. The real R07 coordinator suites prove state
commit after a complete transaction and rollback on failure around the real R06
orchestrator.

R06 is `passed` only for `declared_software_function_only` under deterministic
fixture integration. The frozen blocked conformance remains immutable historical
evidence. R06 v1 still rejects product-scope orchestration; no product routing,
product qualification, production default, Auto, native-framework, hardware,
simulator, operator-observed operation, quality, performance, publication, or
release claim follows.

### R07 local implementation start — 2026-07-21

R07 preregistration binds exact R06 blocked closure commit
`9ed01ea938a933f6406fd67e88edb74e7c84f5f4`, tree
`32365e745dbf53d59213fe2294a6b63ba2642df7`, as
`local_unpublished_blocked_closure` with `predecessor_result: blocked`,
`accepted_merge_commit: null`, `acceptance_state: not_claimed`, and
`continuation_scope: local_implementation_only`. At that historical start
checkpoint, R06 was canonical `in_progress`, local unpublished, and unaccepted.
R07 depended directly on R06; R05 and earlier unresolved phases were transitive
dependencies. R08 was `planned` and was not authorized to start.

The R07 slice is fixture-only local temporal and artifact-governance
implementation. Its immutable preregistration and fixture catalog freeze all
temporal, chroma, artifact, churn, protected-region, spatial-noninferiority,
history, fixed-point, threshold, and aggregation contracts before implementation
or tuning. No numeric formula or threshold is inferred from this handoff.

The frozen product-evaluation result is fail-closed `blocked` solely for
`upstream_no_product_qualified_primary_backend`, with zero eligible routes and
null selected route, plan, and output. Product temporal, artifact, chroma, and
spatial-quality measurements remain `not_observed`. Hardware, simulator, and
operator-observed operation also remain non-blocking `not_observed` and are not
the blocked cause. No quality, performance, product, production-default,
acceptance, publication, or release claim follows.

### R07 operator-defined deterministic software-function acceptance — 2026-07-21

The operator explicitly superseded the comparison against each underlying
backend as an R07 acceptance requirement. Its disposition is
`superseded_not_required`: it remains historical, non-authorizing context and
does not participate in phase acceptance.

R07 implementation commit `1b46ad469265a6ba837a8449d28b8850889f1d3f`, tree
`09d3a48df01738bb26077aadfd83c08e389a1dc2`, integrates deterministic temporal,
support-stage, artifact, protected-region, postflight, and failure-transaction
governance. The checkpoint-bound execution receipt records 98 passing tests
across the 11 settled R07 test classes, with zero failures and zero skips. The
functional phase-acceptance record therefore marks R07 `passed` for
`functional_deterministic_software_phase_acceptance`.

This acceptance is deterministic fixture simulation only. It does not claim
native framework or physical-hardware execution, product routing, a production
default, Auto, media quality, performance, publication, or release. It does not
rewrite R06's frozen record. R06's later additive functional acceptance is
recorded above. At this R07 checkpoint R08 remained `planned`; it later passed
under its separate functional acceptance.

### R03 A11 functional product-qualification checkpoint — 2026-07-21

The additive R03 v2 qualification is bound to source commit
`dfdf1f12ecb22be1c6395d57017bf750fd76496f`, tree
`c3558b90bf647febd900524e7afc40f8c2efbba4`. Its 14-test macOS run passed with
zero failures or skips and emitted one invocation-bound route record plus three
ordered media-transaction records. The mechanically derived receipt and decision
validate genuine `MPSImageLanczosScale` execution on both routes, deterministic
repeatability, exact timing/audio/metadata/reopen/atomic-publication behavior,
resource lifetime, and no fallback.

Only `r03.mps.lanczos` (`A11`) is `product_qualified`, and only for
`functional_product_eligibility`. The v2 record itself left R03 `in_progress`
and did not authorize a production default, Auto, holdout, acceptance,
quality/performance claims, publication, or release. The earlier R03 v1, R06,
and R07 blocked records remain historical evidence. Their
no-qualified-backend cause is cleared prospectively, but any R06 or R07
product-gate rerun must be additive and separately bound.

### R03 operator-overridden functional acceptance — 2026-07-21

The operator superseded the original all-backend quality/performance/resource
comparison as an R03 acceptance prerequisite and directed that acceptance be
based on whether the software performs its intended task. The additive
`functional-phase-acceptance.json` record binds publication commit
`b5c19c0040f845b7f32fe98bd5f01249c1b071f2`, tree
`74e39285521fe31f9588cff5e43184c8f91f9180`, the passing R02 common-session
conformance, and the exact R03 v2 receipt and decision.

The new validator accepts R03 only when genuine A11 processing passes both
canonical routes, three-repeat determinism, complete session/media preservation,
reopen and atomic publication, lifecycle/resource release, processing identity,
no fallback, and every applicable functional metric. Those requirements pass,
so R03 is `passed`. The frozen comparison matrix remains historical evidence and
creates no forward roadmap work. Production
default, Auto, holdout, quality/performance claims, product publication, and
release remain unauthorized.

### Forward software-function acceptance and R08 start — 2026-07-22

The operator directed that forward phase acceptance be based on whether the
software performs the task and honors the boundaries it claims. Comparison-based
testing is outside the forward roadmap and carries no acceptance or authorization
authority. This decision is prospective and does not rewrite any frozen
historical result.

For R10, the required function is deterministic bounded optimizer/calibration
behavior. For R11, the required function is traceable evidence and claim-scope
machinery that rejects unsupported claims and emits `no_market_claim`
unconditionally. `production_auto_mode` and `market_leading_claim` remain
blocked.

R08 begins from accepted R07 merge commit
`3fd13e57ec95b1ed98df71f4c83ab165bdfbab6b`, tree
`eb1614dd2a93e1bc4e1911bcf74f41cf372a3304`. Its start contract binds that exact
accepted predecessor. The implementation remains an
optional cohesive analysis subservice inside the existing model-assets module,
never a sixth module and never a producer of final pixels.

An Xcode 27/Core AI environment is required only for truthful native supplemental
observation. Its absence does not block framework-neutral implementation,
deterministic fixture simulation, lifecycle and decision-context integration,
deterministic bypass, or software-function acceptance. Native Core AI execution,
specialization, AOT, zero-copy, model quality, performance, and memory remain
`not_observed` unless actually measured. R08 supplied no residual authority by
itself. The later operator `resume work` directive separately starts R09 and is
bound to the exact accepted-R08 record; no comparison or ablation grants that
authority.

R08 implementation commit `368b9284883c189be6a1139df6208bf0e88139dd`, tree
`f8e73d193b7b0c9df7005a7aa006de48ca48f77c`, passed all 42 checkpoint-bound
tests across 10 settled suites, with zero failures and zero skips. The accepted
scope is `declared_software_function_only` under deterministic fixture
simulation. It verifies the declared analysis contracts, identity, scheduling,
state, cancellation, cache, budgets, bounded ASH-context integration,
deterministic bypass, and no-pixel-authority boundary. No A/B, blind, ablation,
comparative, or superiority test was run or required. R08 is `passed`; every
native-only observation remains `not_observed`. At its separately authorized
start checkpoint, R09 was `in_progress` only for the bounded experiment.

R09 implementation commit `3ba7b2b5fdbde3a3f90f011cb548b85d46b2ac8b`, tree
`5f19024af0837d5efd54855bcf0fd705a50eadc9`, then passed all 26 selected tests
across four settled suites with zero failures and zero skips. R09 is `passed`
with exit outcome `qualified_local_residual`, limited to deterministic
`declared_software_function_only`. Native Core AI/framework/model, hardware,
simulator, and operator observations remain `not_observed`; no product
qualification, production/default/Auto, holdout, claim, publication, release,
or R10 progression authority followed from that acceptance alone. The
operator's later continuation instruction separately authorizes R10
implementation under the forward software-function gate.

## 1. Resume instructions

Before changing source:

1. Clone or open the repository and fetch the remote without rewriting history.
2. Read this handoff, the canonical roadmap sources, the accepted architecture
   decision, and the roadmap-alignment governance document completely.
3. Verify live remote `main`, inspect intervening commits after the source
   checkpoint, and fast-forward local `main` with `--ff-only`.
4. Confirm `R00: passed`, `R01: passed`, `R02: passed`,
   `R03: passed`, `R04: passed`, `R05: passed`,
   `R06: passed`, `R07: passed`, `R08: passed`, `R09: passed`, and
   `R10: passed` remain canonical, with `R11: in_progress`. If any changed,
   reconcile the newer
   accepted roadmap before proceeding.
5. Preserve the exact frozen R06 and R07 blocked records as historical negative
   evidence. The additive R03 functional acceptance does not alter those
   records. The additive R07 functional acceptance passes only R07 under
   the operator-defined deterministic software-function gate. The later
   additive R06 functional acceptance passes R06 without rewriting either
   frozen record. Any new R06 or R07 product evaluation requires additive,
   versioned evidence bound to the exact A11 identity. Except
   for the narrow
   local-continuation path in Section 3.1, later phases become actionable only
   through accepted dependencies, evidence, roadmap state, and operator controls.

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
  -> R09 only after R08 functional acceptance and separate operator authorization
  -> R10 -> R11 -> R12 -> R13
```

Use one branch and one pull request for each phase, with additive local commits
in this order:

1. preregistration, schemas, fixtures, metrics, stop conditions, and the proposed
   transition from `next` to `in_progress`;
2. interfaces, implementation, deterministic tests, and migration work;
3. runtime evidence from available required environments, with unavailable native
   execution recorded as `not_observed` and deterministic software-function
   evidence still required;
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

The R07-only functional acceptance was a separate operator-defined exception. At
that checkpoint it permitted R07 to be `passed` while R06 remained
`in_progress`, because additive evidence bound the exact R07 implementation
checkpoint and proved the deterministic software function. The comparative
backend requirement is `superseded_not_required`. That exception did not itself
pass R06 or authorize native/product/default/Auto, quality, performance,
publication, or release claims. R06's later additive functional acceptance is
separate and does not rewrite the frozen predecessor record.

The frozen R04 local-continuation preregistration binds R03 closure commit
`947983a8414c60e4f5f4246e6cb658792fc7c357` and tree
`d1a89e5b9edf8d42b1da9ba06a3b6a0c139f08f3`. That closure records a fail-closed
`blocked` R03 result as `local_unpublished_blocked_closure`. At that historical
start checkpoint, the R04 exception permitted only `in_progress` local
implementation while R03 remained `in_progress`; it records
`predecessor_result: blocked`, `accepted_merge_commit: null`,
`acceptance_state: not_claimed`, and
`continuation_scope: local_implementation_only`. It does not reinterpret R03
evidence as success or authorize R04 evidence readiness, passing status,
publication, production enablement, or a quality/performance claim. The later
operator-overridden R03 acceptance is additive and does not rewrite this frozen
R04 predecessor binding.

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
- holdout evidence remains no-pixel and blocked; any future access would require
  a new operator-authorized roadmap change outside the current plan.

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

At the original source checkpoint:

- the production bootstrap injects an unavailable upscaler service and launches
  normally while explaining that no production-default backend is enabled;
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

The later R04 implementation source `73d6f1df9d9b443209d55a6c9deea29923d49bc4`
supersedes the two VideoToolbox placeholder bullets above with guarded genuine
sessions and configuration-specific status-only model staging. It does not
establish model-backed runtime support, quality, performance, product
qualification, or a production default; those observations remain
`not_observed` or unclaimed as recorded in the R04 conformance evidence.

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
evidence. R01 and R02 are `passed`; publication and merge authority remain
unchanged.

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
and atomic publication. Retain ASH code as a deterministic diagnostic reference
rather than forcing Apple frameworks through an ASH-named interface. Require explicit typed
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

Accepted additive checkpoint: source
`eeabc4224100bc8ed86ae1208189bee508844210`, tree
`ac402f993805cca499d2f688c6186c4684ce8dba`, passed all 27 selected tests across
the six settled R02 suites with zero failures and zero skips. The two added
direct tests bind production bootstrap to `UnavailableUpscalerEngineService` and
prove its typed fail-closed `backendUnavailable(reason:)` rejection. This
intentional production-unavailable boundary is not project completion or
production enablement. R02 is `passed` for `declared_software_function_only`.
Its frozen local conformance and `phase_acceptance: not_claimed` state remain
historical; no production/default, Auto, holdout, quality, performance,
publication, or release authority follows.

### R03 - Deterministic Apple-native baseline suite

Implement genuine MPS Lanczos and bilinear, Core Image Lanczos and bicubic,
vImage Lanczos-3 and Lanczos-5, VTPixelTransfer, qualified guided/edge-preserve
support stages, and the retained ASH/custom-Metal deterministic reference. Initial
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

Operator correction authorization on 2026-07-21 supersedes the earlier
no-product-qualification boundary only for a new additive R03 qualification
contract. Preserve the frozen v1 negative evidence. Replace the incompatible
16×8 identity member with an R03-owned 1920×1080-to-3840×2160 media transaction,
and qualify only `r03.mps.lanczos` (`A11`) after genuine MPS execution and all
versioned functional, repeatability, lifecycle, and media checks pass. Simulation
is permitted for deterministic control paths but cannot be recorded as native
MPS execution. Keep production default, Auto, holdout, acceptance, quality and
performance claims, publication, and release disabled.

Achieved additive checkpoint: source
`dfdf1f12ecb22be1c6395d57017bf750fd76496f`, tree
`c3558b90bf647febd900524e7afc40f8c2efbba4`, passed the v2 decision. Only A11 is
`product_qualified` for `functional_product_eligibility`. The later functional
acceptance record revalidates this software evidence and marks R03 `passed` under
the operator-overridden gate. Production-default, Auto, holdout, quality,
performance, product-publication, and release boundaries remain unchanged.

R03 acceptance is limited to the directly verified backend/session behavior. No
production default is selected by the functional acceptance record. Keep Auto
blocked.

### R04 - VideoToolbox super-resolution integration

Replace placeholder behavior with real `VTFrameProcessor` sessions. Treat quality
and low-latency super resolution as separate backend identities. Discover
configuration/revision/scale and declared buffer attributes at runtime; implement
model readiness, ordered prior-frame/prior-output history, scene-cut reset,
submission semantics, optical-flow choices, lifecycle, cancellation, and exact
identity. Qualify direct 2x and runtime-supported 1.5x routes without assuming
support. Forward acceptance requires the declared route, history, lifecycle,
cancellation, identity, failure, and media-reopen software contracts to work.
No unobserved quality, temporal, throughput, or memory value authorizes a claim.

Local checkpoint: commit `73d6f1df9d9b443209d55a6c9deea29923d49bc4`,
tree `90c45e2c583defc7aa593f9199512719884de0d0`, implements the frozen software
contract. Its 39 focused Xcode tests, Swift typechecks, and strict lint pass.
That frozen result remains `diagnostic_only`: model-backed runtime subjects are
`not_observed`, quality 1.5× is rejected by the public contract, production
bootstrap remains unavailable, and no quality, performance, qualification,
acceptance, publication, or release claim was made by that checkpoint.

Additive acceptance: source commit
`ab77e97867d51168e90c0190f6430d4acd769e68`, tree
`446f71bb584f5d1fffcd20a17ac5e5507d3222b6`, passed 42 tests across four R04
suites with zero failures and zero skips. The deterministic runtime verifies
complete quality/low-latency 2× media transactions, capability-gated 1.5×,
cancellation, media identity, reopen, resource release, atomic publication, and
no fallback through the real R04 backends and production FIFO. R04 is `passed`
only for `declared_software_function_only`; native/model/hardware observations
and all production/default/quality/performance/publication/release claims remain
outside that acceptance.

### R05 - MetalFX suitability decision

Qualify MetalFX Spatial first under the common backend contract. Probe temporal,
temporal-denoised, and frame-interpolation paths only
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

Local start: the R05 preregistration binds R04 closure
`88e26f5967f7eb35a54791017ca0c2b888f2fbf5`, tree
`4a7cc588b6fa51c21f2293e56cf3dea389acd908`. Only A07 spatial 1.5× and 2× are
implementation candidates, behind an explicit NV12/linear-color bridge and
support query. A08-A10 are deterministic decoded-video contract rejections.
At that historical start, R05 remained `in_progress`, local unpublished, and
unaccepted; no runtime, quality, performance, qualification, default,
publication, or release claim was made.

Local checkpoint: implementation commit
`3e5188ece317d3ebc492c7a8e26345837836fc67`, tree
`92b15f3948ffa38dc787136177551187bfb2fbbf`, passes 44 focused macOS Xcode
tests and strict lint. Its commit-bound result is `diagnostic_only`: A07 native
execution and media-reopen evidence are `not_observed`, A08-A10 retain their
typed decoded-video rejections, and no product, quality, performance,
acceptance, publication, or release claim follows.

Additive acceptance: source commit
`7e1ab67340e4d6d95a3d92e8a48bc6cd356005b8`, tree
`adce5b65fd3d752a1467925232847e086d0b3e7a`, passed 46 tests across five R05
suites with zero failures and zero skips. The deterministic driver verifies
source-derived A07 1.5× and 2× output through the real backend and production
FIFO plus a complete reopened 2× H.264/AAC/timed-metadata transaction before
atomic publication. The real driver contracts cover the support query, explicit
color bridge, ordering, cancellation, and failures. A08-A10 remain successful
typed rejections. R05 is `passed` with exit outcome `diagnostic_only`, limited
to `declared_software_function_only`; native MetalFX, hardware, product,
quality, performance, default, Auto, publication, and release claims remain
outside that acceptance.

### R06 - ASH orchestration engine v1

Preserve the canonical nine-bit state while adding immutable continuous context.
Map branch outputs to versioned policy profiles, select one whole-frame backend
per decision interval, and implement deterministic scoring, tie-breaking,
hysteresis, minimum dwell, scene-cut reset, resource policy, typed failover,
protection/correction masks, and reason codes. Only R03-R05-qualified backends are
eligible.

Preregister deterministic fixtures for eligible-backend filtering, scoring,
stable tie-breaking, state/context influence, hysteresis, dwell, scene-cut reset,
typed failover, bounded masks, identity, and transactional behavior.
Perturbations must causally affect only contracted policy decisions.

Local start: the R06 preregistration binds R05 closure
`b955fc9d0b02dd066c359dfcb99a9ad31aeb817a`, tree
`10a97bd3df7f72834f7afcb7fa3b63c598fa4931`. Deterministic fixture policy work
may proceed, but the frozen product-admission result is
`no_product_qualified_primary_backend` with zero eligible backends and no
selected route, plan, or output. All six frozen product configuration subjects remain
`not_observed`; at that historical checkpoint R06 remained `in_progress`, local
unpublished, and unaccepted.

Local blocked checkpoint: implementation commit
`9246934c027e97f2b2ae3af35b0c4892154d761c`, tree
`1235596387d4eabd2ecb4ea1a29221c44ec425fe`, passed all 32 focused Xcode tests,
strict SwiftLint across 275 files, all 529 Python governance tests, and
deterministic software conformance. The frozen product gate is fail-closed
`blocked` in that historical record for
`no_product_qualified_primary_backend`, with zero eligible
backends and null selected route, plan, and output. All product, hardware,
simulator, and operator observations remain `not_observed`. This is a local
unpublished blocked closure; at that historical checkpoint canonical R06 stayed
`in_progress`, and no quality, performance, product, production-default,
acceptance, publication, or release claim followed.

The later R03 v2 decision qualifies A11 for functional product eligibility and
removes that reason as a valid cause for a new R06 run. It does not rewrite or
change the status of the frozen R06 record. Additive, versioned product-admission
evidence remains required before any new product route, plan, output, default,
quality, performance, publication, or release claim.

Additive functional acceptance: source commit
`6c4a6d3d5f8a59c553b10c23783c148ccb3388a5`, tree
`beb0f8c666550c6c36dae5a2185cac58d2494132`, passed all 42 selected tests across
seven R06/R07 suites with zero failures and zero skips. The tests prove the
declared deterministic control-plane behavior, including exact eligibility
filtering and transaction commit/rollback around the real orchestrator. R06 is
`passed` only for `declared_software_function_only`. R06 v1 still rejects
product-scope orchestration, and the frozen blocked product evidence remains
unchanged history.

### R07 - Temporal stability and artifact governance

Preregister temporal, chroma, artifact, churn, and protected-region metrics before
tuning. Add scene-cut reset, motion/occlusion confidence, qualified temporal noise
filtering, backend/strength/artifact history, ringing/halo/ghosting/flicker/false-
texture/chroma detection, luma-guided chroma reconstruction, edge-preserving mask
upsampling, and policies for faces, text, line art, animation, subtitles, and UI
captures. Postflight feedback may affect later decisions but never rewrite a
completed frame. The original plan required measured improvement over each used
backend alone without material spatial-quality loss. The operator explicitly
superseded that comparison requirement; it is not required for R07 acceptance.

Local start: the R07 preregistration binds R06 blocked closure
`9ed01ea938a933f6406fd67e88edb74e7c84f5f4`, tree
`32365e745dbf53d59213fe2294a6b63ba2642df7`, with
`predecessor_result: blocked`, `accepted_merge_commit: null`, and local-only
continuation. The implementation is fixture-only. Exact formulas, thresholds,
history bounds, aggregation rules, and spatial-noninferiority criteria are frozen
in the preregistration and fixture catalog before implementation or tuning.

The frozen product-gate record is `blocked` for
`upstream_no_product_qualified_primary_backend`, with zero eligible routes and
null route, plan, and output. Product temporal, artifact, chroma, and
spatial-quality measurements, plus hardware, simulator, and operator-observed
operation, remain `not_observed`. At that checkpoint R06 and R07 remained
`in_progress`, while R08 remained `planned`. No quality, performance, product,
production-default, acceptance, publication, or release claim follows from that
record.

The later R03 v2 decision removes the R03-level eligibility absence
prospectively, but it does not establish an eligible R06 route, alter the frozen
R07 record, or make R07 product metrics observed. A successor evaluation requires
additive R06 admission evidence and additive R07 evidence. Before the later
operator-defined functional acceptance, R07 remained `in_progress` with no
production-default, Auto, holdout, acceptance, quality, performance,
publication, or release claim.

Operator-defined functional acceptance: implementation commit
`1b46ad469265a6ba837a8449d28b8850889f1d3f`, tree
`09d3a48df01738bb26077aadfd83c08e389a1dc2`, passed 98 checkpoint-bound tests
across the 11 settled R07 test classes with zero failures and zero skips. The
tests verify the deterministic temporal/support-stage/artifact/protection/
postflight/coordinator transaction as a complete software function. The
functional receipt and acceptance record mark R07 `passed`; comparison is
`superseded_not_required` and contributes no acceptance authority.

The accepted execution scope is deterministic fixture simulation only. Native
framework execution, physical hardware, product/default/Auto routing, media
quality, performance, publication, and release remain unclaimed and
unauthorized. R06 later passed under its additive functional acceptance. At this
R07 checkpoint R08 remained `planned`; it later passed under separate functional
acceptance.

### R08 - Core AI analysis-only integration

The accepted implementation is a cohesive optional model-assets subservice
producing calibrated
protection masks, artifact risk, source classification, motion reliability, and
no-reference quality estimates on proxy/key/requested frames. It binds
model/preprocessing/postprocessing identity and includes a specialization cache,
optional AOT compilation, zero-copy input, state handling, cancellation, memory
and latency budgets, and deterministic bypass. The service never produces or
replace final pixels.

The checkpoint-bound deterministic acceptance run proves the declared
input/output, identity, cadence, state, cache, cancellation, budget,
decision-context, no-final-pixel, and bypass behavior. Comparison-based testing
is outside the roadmap and supplied no R08 acceptance authority.

Use an accepted macOS/Xcode 27 environment with the public framework when it is
available for native supplemental observation. Its absence does not block the
framework-neutral implementation or deterministic software-function gate. Record
unavailable native execution and native-only metrics as `not_observed`; do not
infer native, model-quality, performance, memory, AOT, specialization, or
zero-copy facts from simulation.

Acceptance binds implementation commit
`368b9284883c189be6a1139df6208bf0e88139dd`, tree
`f8e73d193b7b0c9df7005a7aa006de48ca48f77c`. All 42 selected tests across 10
settled suites passed with zero failures and zero skips. The scope is
`declared_software_function_only` under truthful deterministic fixture
simulation. Xcode 27, Core AI framework and model availability, native Core AI,
hardware, simulator, and operator-observed execution remain `not_observed` and
nonblocking. R08 is `passed`; no product/default/Auto, residual, claim,
publication, or release authority follows.

### R09 - Core AI bounded residual experiment

Do not start from dependency completion alone. Require accepted R08
software-function evidence and a separate operator-accepted roadmap authorization
change. Run a small post-scaler residual only in ASH-approved regions with hard
per-plane, source-consistency, temporal, identity, face, and text protections.
Preserve the Apple-only output for diagnosis and immediate rollback.
Qualification for a narrow use or an explicit safety, hallucination-risk, or
resource-cost rejection are valid outcomes. The residual is never required to
ship.

The operator's 2026-07-22 `resume work` directive supplies the separate
implementation authorization. The exact canonical value is now
`core_ai_pixel_residual: authorized_for_r09_bounded_experiment`. The policy and
repository-owned authorization record bind raw accepted-R08 SHA-256
`0d81917a93cf56cae867c11b7c65fb3c85e53b7596929cf9eec2ef09c24634b0`,
implementation commit `368b9284883c189be6a1139df6208bf0e88139dd`, and tree
`f8e73d193b7b0c9df7005a7aa006de48ca48f77c`. This advanced R09 to
`in_progress` at its start checkpoint.

Freeze exact software contracts and fixtures before implementation. Acceptance
is based only on deterministic declared-software-function behavior. Exclude A/B,
comparative, blinded, ablation, and superiority gates. Deterministic simulation
is permitted and must identify itself truthfully. Keep native Core AI, model,
hardware, simulator, and operator observations `not_observed` when unavailable.
Fixture numeric values are software-test inputs, not product thresholds or
quality evidence. Production default, Auto, holdout, claims, publication, and
release remain unauthorized.

The additive functional execution receipt and phase-acceptance record bind R09
implementation commit `3ba7b2b5fdbde3a3f90f011cb548b85d46b2ac8b`, tree
`5f19024af0837d5efd54855bcf0fd705a50eadc9`, and 26 passing selected tests
across four settled suites, with zero failures and zero skips. The exit outcome
is `qualified_local_residual`; R09 is `passed` only for
`declared_software_function_only` under deterministic fixture simulation.
Native Core AI/framework/model, hardware, simulator, and operator observations
remain `not_observed`. No product qualification, production/default/Auto,
holdout, quality, performance, publication, or release authority follows. The
R09 acceptance did not itself authorize R10 progression; the operator's later
continuation instruction separately authorizes R10 implementation.

### R10 - Auto-policy optimization and bounded calibration

R10 is `passed` after both exact canonical predecessors, R07 and R09, passed
and the operator separately authorized continuation. Its preserved phase-start
contract binds these four records:

- `docs/roadmaps/evidence/r10/records/preregistration.json`
- `docs/roadmaps/evidence/r10/records/fixtures/fixture-catalog.json`
- `docs/roadmaps/evidence/r10/records/fixtures/evaluation-catalog.json`
- `docs/roadmaps/evidence/r10/records/fixtures/policy-catalog.json`

The functional execution receipt and phase-acceptance record bind implementation
commit `3a76c6a03ea0f52f2a2395925badd5d5d1c03c6b`, tree
`37951da694ab4fbca6f8c663bb2883e5084b861c`, and 39 passing optimizer and
persistence tests with zero failures and zero skips. The accepted deterministic
fixture run evaluated nine candidates, scored three, rejected six, published
ten content-addressed checkpoints, selected `fixture-valid-alpha`, and passed
typed reopen against the exact evaluation catalog.

R10 passes only for `declared_software_function_only` under deterministic
fixture simulation. Comparison, A/B, and superiority testing were not run and
are not required. Hardware, simulator, and operator-observed execution remain
`not_observed`. Fixture-policy evidence publication is authorized. Production
Auto, holdout, product publication, quality or performance claims, and release
remain unauthorized.

### R11 - Evidence traceability and claim boundary

R11 is `in_progress` after exact predecessor R10 passed. Its start contract
requires these regular, non-symlink records:

- `docs/roadmaps/evidence/r11/records/preregistration.json`
- `docs/roadmaps/evidence/r11/records/fixtures/fixture-catalog.json`

The preregistration binds accepted-R10 closure commit
`8d4283d2f3fbb104ef589f002de2fd6ccadad0f8`, tree
`ee0461cff1fea9461f619ce904376ebdb128a2f5`, accepted implementation commit
`3a76c6a03ea0f52f2a2395925badd5d5d1c03c6b`, tree
`37951da694ab4fbca6f8c663bb2883e5084b861c`, and the exact R10 functional
execution and phase-acceptance records. Validate the start with
`python3 Scripts/r11_contracts.py --all`.

This phase start authorizes deterministic traceability and claim-boundary
implementation and fixture testing only. It does not claim R11 acceptance;
future functional execution and phase-acceptance evidence remains dormant until
R11 is proposed as `passed`.

Implement typed execution-receipt, subject, input, observation, aggregate,
claim-scope, and disposition contracts. Bind every accepted observation and
aggregate to exact source, software, subject, input, preprocessing, toolchain,
and execution identity. Reject missing, duplicate, mismatched, out-of-scope, or
unauthorized evidence and every claim broader than its evidence. Preserve
`observed`, `not_applicable`, `not_observed`, failed, and absent as distinct
states, and emit `no_market_claim` unconditionally.

Comparison-based testing and market-position work are outside the roadmap. R11
accepts when checkpoint-bound tests prove its traceability, validation,
aggregation, claim-scope, rejection, and unconditional no-claim behavior.
`production_auto_mode` and `market_leading_claim` remain blocked, and no R11
artifact can authorize either. Comparative and A/B methods are absent, not
required, and non-authorizing. Product publication and release remain
unauthorized.

### R12 - Format, route, and product expansion

After R11 functional acceptance, expand through explicit contracts for
10-bit/P010, HDR transfer and
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

- an authorizing native observation or claim lacks its required environment;
- a public API contract claimed by an authorizing native run cannot be satisfied;
- evidence exceeds repository limits and cannot be represented compactly;
- source, fixture, policy, model, or toolchain identity changes during an
  authorizing run;
- a required software-function gate fails;
- a commercial run or evidence publication is attempted without the required
  license or redistribution rights;
- an attempted holdout, residual, Auto, claim, tag, release, ruleset, push, or
  pull-request action lacks its required authority; or
- completion would require force-pushing, approving, or merging a pull request.

The intentional absence of production Auto, claim, tag, release, or holdout
authority does not block research, diagnostics, implementation, or hardening
that preserves those boundaries.
Unavailable hardware, simulator, Core AI SDK/runtime, or operator observation is
recorded as `not_observed` and does not block a separately identified
deterministic software-function run. Comparison-based testing is outside the
forward roadmap and never supplies or withholds phase-acceptance authority.

Do not reinterpret negative evidence as success except where the roadmap defines
an explicit diagnostic or rejection outcome. R05 and R09 rejections can be valid
phase outcomes. R08 requires its deterministic software-function gate to pass;
comparative results contribute no acceptance authority. R09 is `passed` with
exit outcome `qualified_local_residual` under the separately authorized,
accepted-R08-bound deterministic software-function gate.
R10 requires deterministic bounded optimizer/calibration behavior. R11 requires
traceable evidence and claim-scope behavior with `no_market_claim`
unconditionally. `production_auto_mode` and `market_leading_claim` remain
blocked.
A failed R06 or R07 product gate blocks dependent product work and requires an
explicitly reviewed roadmap revision rather than relaxed thresholds. The R07
functional acceptance is the operator-defined software gate and does not
reinterpret the frozen product-gate result.

## 8. Current local-continuation boundary

R07 was accepted and merged at
`3fd13e57ec95b1ed98df71f4c83ab165bdfbab6b`, tree
`eb1614dd2a93e1bc4e1911bcf74f41cf372a3304`. R08 passed under the normal
accepted-dependency path; it was not another unpublished local-continuation
exception. R06 later passed under its additive functional acceptance, and the
frozen R06/R07 negative product records remain unchanged.

R10 passed its deterministic bounded optimizer/calibration software-function
gate at implementation commit `3a76c6a03ea0f52f2a2395925badd5d5d1c03c6b`,
tree `37951da694ab4fbca6f8c663bb2883e5084b861c`. Hardware, simulator, and
operator observations remain `not_observed`; comparison supplied no acceptance
authority. R11 is now `in_progress` under its exact passed-R10 start contract;
acceptance is not claimed. Product qualification, production Auto, holdout
access, claims, tags, releases, pushes, pull requests, approvals, merges,
force-pushes, and repository-setting mutation retain their separate authority
requirements.
