# R01 Phase Evidence

- **Schema version:** `1.0`
- **Roadmap version:** `1.0.1`
- **Source commit:** `bd963fbd034734e92f488549c6e1c0cd8b246363`
- **Source tree:** `6009c40b775e252a05ff83d436d90f0422498245`
- **Result status:** `passed`
- **Result disposition:** `passed`
- **Phase status before:** `in_progress`
- **Phase status after:** `passed`

This summary is generated from `phase-evidence.json`; the JSON manifest is canonical.

## Hosts

| Host | Roles | Hardware classes | Model | Chip | Memory bytes | macOS | Build | Xcode | SDK |
| --- | --- | --- | --- | --- | ---: | --- | --- | --- | --- |
| `r01-verification-executor` | verification-executor | apple_silicon, pro_max_tier | `Mac16,7` | Apple M4 Pro | 51539607552 | `26.5.2` | `25F84` | `26.2` | `26.2` |

## Preregistration

- Record: `docs/roadmaps/evidence/r01/records/preregistration.json`
- Inputs: `1`
- Fixtures: `10`
- Parameters: `0`
- Metrics: `1`
- Floors: `1`
- Stop rules: `1`
- Disposition subjects: `18`

## Commands

| ID | Host | Result | Exit | Invocation |
| --- | --- | --- | ---: | --- |
| `capability-waiver-check` | `r01-verification-executor` | `passed` | 0 | `python3 Scripts/r01_observation_waiver.py --check` |
| `guardrail` | `r01-verification-executor` | `passed` | 0 | `Scripts/verify-mirmir-guardrails.sh` |
| `swiftlint` | `r01-verification-executor` | `passed` | 0 | `swiftlint lint --strict --config .swiftlint.yml` |
| `roadmap-evidence-unit-tests` | `r01-verification-executor` | `passed` | 0 | `python3 -m unittest Scripts/tests/test_roadmap_alignment.py Scripts/tests/test_r00_inventory.py Scripts/tests/test_json_schema_validator.py Scripts/tests/test_phase_evidence.py Scripts/tests/test_r01_preregistration.py Scripts/tests/test_r01_capabilities.py Scripts/tests/test_r01_observation_waiver.py` |
| `diff-check` | `r01-verification-executor` | `passed` | 0 | `git diff --check` |
| `project-generation-1` | `r01-verification-executor` | `passed` | 0 | `xcodegen generate` |
| `project-generation-2` | `r01-verification-executor` | `passed` | 0 | `xcodegen generate` |
| `project-generation-diff` | `r01-verification-executor` | `passed` | 0 | `git diff --exit-code -- Mirmir.xcodeproj/project.pbxproj` |
| `debug-build` | `r01-verification-executor` | `passed` | 0 | `xcodebuild -project Mirmir.xcodeproj -scheme Mirmir -configuration Debug -destination platform=macOS -derivedDataPath /tmp/mirmir-r01-evidence-deriveddata -disableAutomaticPackageResolution build` |
| `release-build` | `r01-verification-executor` | `passed` | 0 | `xcodebuild -project Mirmir.xcodeproj -scheme Mirmir -configuration Release -destination platform=macOS -derivedDataPath /tmp/mirmir-r01-evidence-deriveddata -disableAutomaticPackageResolution build` |
| `preclosure-phase-evidence-check` | `r01-verification-executor` | `passed` | 0 | `python3 Scripts/phase_evidence.py --phase R01 --check` |

## Outputs

| ID | Kind | Path | Bytes | SHA-256 |
| --- | --- | --- | ---: | --- |
| `capability-json` | `report` | `project-notes/apple-upscale-capabilities.json` | 55520 | `c2a2882dd4c696f34f8d8c9a269ed9f502f14261d4484e90d412ccfa47eb1a1e` |
| `capability-report` | `report` | `project-notes/apple-upscale-capability-report.md` | 13284 | `1cfa6b3f151e6e4313f8176b2b00bb90b7d21924967b3babf6d5f0a21d781c7c` |
| `json-result` | `command_log` | `project-notes/verification/r01/json-result.json` | 273 | `2042b34bae3827e1a51390fc2fbedbf58fef7143397bc6c901695628d58b79b3` |
| `lint-result` | `command_log` | `project-notes/verification/r01/lint-result.json` | 230 | `cb4f13f5d1a73a387163adff34e708cd733231a7193241ab01ff3e100aac5fd3` |
| `unit-test-result` | `test_result` | `project-notes/verification/r01/unit_test-result.json` | 315 | `c25b1dfb0241fbb0da4b2e5dfc630500c73cdf19f127737a811f4eddb7079abb` |
| `mutation-test-result` | `test_result` | `project-notes/verification/r01/mutation_test-result.json` | 310 | `c0e22b765d8a32ff9fed974411fb91ab2cda020ba8e56bace1ad3ad019d3c72d` |
| `repository-result` | `command_log` | `project-notes/verification/r01/repository-result.json` | 244 | `1ccc4d6b3027784d7a40794d3e79049c80e2700d4dfc13cf7df51c0fea05cdec` |
| `dependency-scan-result` | `command_log` | `project-notes/verification/r01/dependency_scan-result.json` | 317 | `e61a2396e7b2f25a5f9a7a2804daeabba87c6bce2c28daa9b14c3cf652ff076f` |
| `project-generation-result` | `command_log` | `project-notes/verification/r01/project_generation-result.json` | 376 | `5fd4d11e9ba00d7c5e52d79701e19140813514738aaf0eac168776921a500e87` |
| `build-result` | `build_result` | `project-notes/verification/r01/build-result.json` | 293 | `05d532a6e572559d0eaf8dab6fb320f293e53a99e47bd7d96aadf3fdc6488d75` |
| `hosted-test-result` | `test_result` | `project-notes/verification/r01/hosted_test-result.json` | 288 | `36c6f08bb1bf5b74f1b13a3b4fd0d319e7fc62d26031f403ceeef59428c03479` |
| `evidence-integrity-result` | `command_log` | `project-notes/verification/r01/evidence_integrity-result.json` | 349 | `b6b00efbb7e9f1b08d06a406cf5ba6aeacba3f772e6f40ad1290914363a157f4` |

## Verification

- `build-check` (`build`, required): `passed`
- `dependency-scan-check` (`dependency_scan`, required): `passed`
- `hosted-test-check` (`hosted_test`, required): `passed`
- `json-check` (`json`, required): `passed`
- `lint-check` (`lint`, required): `passed`
- `mutation-test-check` (`mutation_test`, required): `passed`
- `project-generation-check` (`project_generation`, required): `passed`
- `repository-check` (`repository`, required): `passed`
- `unit-test-check` (`unit_test`, required): `passed`
- `evidence-integrity-check` (`evidence_integrity`, required): `passed`

## Capability or Experimental Dispositions

| Subject | Disposition | Reason |
| --- | --- | --- |
| `A01` | `diagnostic_only` | Operation was not observed under the explicit operator waiver; diagnostic inventory only. |
| `A02` | `diagnostic_only` | Operation was not observed under the explicit operator waiver; diagnostic inventory only. |
| `A03` | `diagnostic_only` | Operation was not observed under the explicit operator waiver; diagnostic inventory only. |
| `A04` | `diagnostic_only` | Operation was not observed under the explicit operator waiver; diagnostic inventory only. |
| `A05` | `diagnostic_only` | Operation was not observed under the explicit operator waiver; diagnostic inventory only. |
| `A06` | `diagnostic_only` | Operation was not observed under the explicit operator waiver; diagnostic inventory only. |
| `A07` | `diagnostic_only` | Operation was not observed under the explicit operator waiver; diagnostic inventory only. |
| `A08` | `diagnostic_only` | Operation was not observed under the explicit operator waiver; diagnostic inventory only. |
| `A09` | `diagnostic_only` | Operation was not observed under the explicit operator waiver; diagnostic inventory only. |
| `A10` | `diagnostic_only` | Operation was not observed under the explicit operator waiver; diagnostic inventory only. |
| `A11` | `diagnostic_only` | Operation was not observed under the explicit operator waiver; diagnostic inventory only. |
| `A12` | `diagnostic_only` | Operation was not observed under the explicit operator waiver; diagnostic inventory only. |
| `A13` | `diagnostic_only` | Operation was not observed under the explicit operator waiver; diagnostic inventory only. |
| `A14` | `diagnostic_only` | Operation was not observed under the explicit operator waiver; diagnostic inventory only. |
| `A15` | `diagnostic_only` | Operation was not observed under the explicit operator waiver; diagnostic inventory only. |
| `A16` | `diagnostic_only` | Operation was not observed under the explicit operator waiver; diagnostic inventory only. |
| `A17` | `diagnostic_only` | Operation was not observed under the explicit operator waiver; diagnostic inventory only. |
| `A18` | `diagnostic_only` | Operation was not observed under the explicit operator waiver; diagnostic inventory only. |

## Result

R01 inventory closure records A01-A18 across all four logical anchors as not_observed and diagnostic_only without capability or qualification claims.

## Authorization State

### Before

- `capability_lab`: `authorized_after_current_source_inventory`
- `core_ai_pixel_residual`: `blocked_until_analysis_ablation_passes`
- `holdout`: `blocked`
- `market_leading_claim`: `blocked`
- `observation_gates`: `hardware_unavailable_simulator_and_operator_observation_waived_not_a_blocker`
- `production_auto_mode`: `blocked`
- `strategic_reset`: `authorized`
- `unified_backend_architecture`: `authorized_after_capability_contracts`

### After

- `capability_lab`: `authorized_after_current_source_inventory`
- `core_ai_pixel_residual`: `blocked_until_analysis_ablation_passes`
- `holdout`: `blocked`
- `market_leading_claim`: `blocked`
- `observation_gates`: `hardware_unavailable_simulator_and_operator_observation_waived_not_a_blocker`
- `production_auto_mode`: `blocked`
- `strategic_reset`: `authorized`
- `unified_backend_architecture`: `authorized_after_capability_contracts`

### Proposed decisions

- None

## Limitations

- Physical-hardware execution, simulator availability, simulator execution, and operator-observed operation were waived as blockers; no hardware, API, runtime, model, performance, memory, repeatability, product-qualification, backend-eligibility, or perceptual-quality observation is claimed.
