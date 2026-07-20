# R01 Phase Evidence

- **Schema version:** `1.0`
- **Roadmap version:** `1.0.1`
- **Source commit:** `986c8785f0aaae71b0ad9b4e380ad47008729882`
- **Source tree:** `9b404ee4b77fc31adceef59bfe8e2f3af6168132`
- **Result status:** `blocked`
- **Result disposition:** `blocked`
- **Phase status before:** `in_progress`
- **Phase status after:** `in_progress`

This summary is generated from `phase-evidence.json`; the JSON manifest is canonical.

## Hosts

| Host | Roles | Hardware classes | Model | Chip | Memory bytes | macOS | Build | Xcode | SDK |
| --- | --- | --- | --- | --- | ---: | --- | --- | --- | --- |

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

## Outputs

| ID | Kind | Path | Bytes | SHA-256 |
| --- | --- | --- | ---: | --- |

## Verification

- `source-bound-verification` (`hosted_test`, required): `skipped` — Source-bound closure verification artifacts have not yet been recorded.

## Capability or Experimental Dispositions

| Subject | Disposition | Reason |
| --- | --- | --- |

## Result

R01 remains in progress while source-bound closure verification is collected.

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

- This is a preclosure bootstrap manifest; it records no hardware, simulator, API, runtime, model, performance, memory, repeatability, qualification, eligibility, or perceptual-quality observation.
