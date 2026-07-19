# R00 Current-Source Inventory

- **Inventory status:** `baseline`
- **Roadmap version:** `1.0.1`
- **Recorded date:** `2026-07-19`
- **Git object format:** `sha1`
- **Baseline checkpoint:** `d8eb29d9e75fa163e14fc4ca3dec3f7696b388c9`
- **Baseline tree:** `a032c6a19a7aa72a805bc4c3dcd6dec8f81dedec`
- **Source checkpoint:** `d8eb29d9e75fa163e14fc4ca3dec3f7696b388c9`
- **Source tree:** `a032c6a19a7aa72a805bc4c3dcd6dec8f81dedec`
- **Checkpoint role:** pre-R00 implementation baseline

This summary is generated from `r00-current-source-inventory.json`. Git object IDs identify the exact file or tree at the source checkpoint.

## C01-C11 Classification

| ID | Capability | Disposition | Retained role | Future phase |
| --- | --- | --- | --- | --- |
| `C01` | Five-module application composition | `retain_and_replace_dependency_boundary` | One UI module, four service modules, stable identities, constructor injection, and one composition root | `R00` |
| `C02` | AVFoundation media transaction | `retain` | Ingest, sequencing, audio, output, reopen verification, and atomic publication | `R02` |
| `C03` | Metal service and completion boundary | `retain` | Metal device, queue, texture cache, asynchronous completion, and resource lifetime | `R02` |
| `C04` | Reusable Metal frame resource ring | `retain` | Three-slot cancellable lease and GPU-to-append lifetime boundary | `R02` |
| `C05` | Canonical packed ASH core | `retain_as_control_plane` | State, code, strict decoding, parity, and conformance reference | `R06` |
| `C06` | ASH V3 Metal runtime and telemetry | `retain_as_reference_and_analysis_substrate` | Plane-aware deterministic analysis, dispatch, reconstruction reference, and bounded telemetry | `R03` |
| `C07` | Direct 2x and 3-over-2x NV12 route contracts | `retain_first_contract` | Initial locked route, format, range, matrix, and chroma-siting contract | `R03` |
| `C08` | Output identity and atomic verification | `retain_and_extend` | Output identity, post-encode reopen verification, and atomic publication | `R02` |
| `C09` | Exact resource validation and legacy build injection | `retain_validation_retire_p06_injection` | Fail-closed asset validation remains reusable; P06-specific build injection is retired in R00 | `R00` |
| `C10` | Offline calibration and exact-app evidence infrastructure | `repurpose` | Schedulers, schemas, validators, metrics, and exact-app measurement infrastructure | `R03` |
| `C11` | ASH V3 operator bank and LUT assets | `repurpose_as_reference_fallback_and_policy_dispatch` | Deterministic operator reference, policy dispatch research, and immutable resource examples | `R06` |

### C01 — Five-module application composition

| Exact path | Git object type | Git object ID |
| --- | --- | --- |
| `project.yml` | `blob` | `53e4a6889c3cd737d7879c91121ed6b6784003cc` |
| `Mirmir/App` | `tree` | `a0dc06173299e287b35e1f25ccb17d2fce055983` |
| `Mirmir/Modules/UI` | `tree` | `3d011c146cdd61a21d1913e16772c160435d15cc` |
| `Mirmir/Modules/MediaPipeline/MediaPipelineServiceModule.swift` | `blob` | `f762fd7ce397362526bd9d93edb265c27221d50a` |
| `Mirmir/Modules/MetalRendering/MetalRenderingServiceModule.swift` | `blob` | `274037db5269e24a05f79584b646bc6bcd888be3` |
| `Mirmir/Modules/ModelAssets/ModelAssetsServiceModule.swift` | `blob` | `852b5e689a6714da3e40099ce4cea0737e0ffc35` |
| `Mirmir/Modules/UpscalerEngine/UpscalerEngineServiceModule.swift` | `blob` | `0952f65228fd72a0c5b06fd54add802859798471` |
| `Mirmir/Modules/UI/MirmirUIModule.swift` | `blob` | `94f19e45941f92a15b0941f322d7958934c1c263` |
| `Mirmir/Resources/ForsettiManifests` | `tree` | `98cf3c3613c5af615421ce1a8daa7196b0539ab0` |

### C02 — AVFoundation media transaction

| Exact path | Git object type | Git object ID |
| --- | --- | --- |
| `Mirmir/Modules/MediaPipeline` | `tree` | `9b22e970815878d089845892f872d97daa42412d` |

### C03 — Metal service and completion boundary

| Exact path | Git object type | Git object ID |
| --- | --- | --- |
| `Mirmir/Modules/MetalRendering` | `tree` | `8b6989c7a39a02237c4c90c54e522ca74da6af4e` |
| `Mirmir/Modules/UpscalerEngine/ASH/ASHMetalSpatialFrameEncoderV3.swift` | `blob` | `becf5ac2766e960180055ab50fd9287ba30cd9ad` |

### C04 — Reusable Metal frame resource ring

| Exact path | Git object type | Git object ID |
| --- | --- | --- |
| `Mirmir/Modules/UpscalerEngine/ASH/ASHMetalFrameResourceRingV3.swift` | `blob` | `a3f1c4ad9b6b3364730698aad905010398bfb92f` |

### C05 — Canonical packed ASH core

| Exact path | Git object type | Git object ID |
| --- | --- | --- |
| `Mirmir/Modules/UpscalerEngine/ASH/ASHState.swift` | `blob` | `fc7c0066c37cad7ed99ba74d4249ce79498cac09` |
| `Mirmir/Modules/UpscalerEngine/ASH/ASHCode.swift` | `blob` | `c7c61da2acc0e585019fa043cd32946763d7c428` |
| `Mirmir/Modules/UpscalerEngine/ASH/ASHCoreConformance.swift` | `blob` | `ca6a56a69cb6c8a24ca8ea572b44a6bb295d5bec` |
| `Mirmir/Modules/UpscalerEngine/ASH/ASHStrictJSONV3.swift` | `blob` | `8a67674d2c334879c1b2adb7932e6025fc678a45` |

### C06 — ASH V3 Metal runtime and telemetry

| Exact path | Git object type | Git object ID |
| --- | --- | --- |
| `Mirmir/Modules/UpscalerEngine/ASH/ASHMetalSpatialRuntimeV3.swift` | `blob` | `6a586fda6613f66fe5cbe9c01cc7c5b92cd6691a` |
| `Mirmir/Modules/UpscalerEngine/ASH/ASHMetalSpatialRuntimePreparationV3.swift` | `blob` | `7f489b06a0d10661a529e5be78ec0500fb0f9366` |
| `Mirmir/Modules/UpscalerEngine/ASH/ASHMetalSpatialRuntimeSupportV3.swift` | `blob` | `84db629c132ebfbf937b84279ebea24764ae94fb` |
| `Mirmir/Modules/UpscalerEngine/ASH/ASHMetalRuntimeMonitorV3.swift` | `blob` | `afca626e4f1189b4c0f266c86d4c74b5dc525f10` |
| `Mirmir/Modules/Telemetry` | `tree` | `b9a15b1939d144d6628c8481dbbb230051dc248c` |

### C07 — Direct 2x and 3-over-2x NV12 route contracts

| Exact path | Git object type | Git object ID |
| --- | --- | --- |
| `Mirmir/Modules/UpscalerEngine/ASH/ASHLockedVideoMappingV2.swift` | `blob` | `d274cb57bbb670a2fdb63d83facfd45a5ddf3829` |
| `Mirmir/Modules/UpscalerEngine/ASH/ASHLockedVideoMappingV2+ConfigurationValidation.swift` | `blob` | `506f151ad8ba048348e0f4cd6baefa7bc8b96abc` |
| `Mirmir/Modules/UpscalerEngine/ASH/ASHLockedVideoMappingV2Validation.swift` | `blob` | `3e441bc3e0a9ef0d5b678ea53f0c1856a4921ee7` |

### C08 — Output identity and atomic verification

| Exact path | Git object type | Git object ID |
| --- | --- | --- |
| `Mirmir/Modules/MediaPipeline/AtomicMediaOutput.swift` | `blob` | `db0c648d15f4eee61a95ddb81cb6dd5be83c022e` |
| `Mirmir/Modules/MediaPipeline/OutputMediaVerificationTypes.swift` | `blob` | `28fff7aadffdaf5e57ff16aad2659dee3a397bda` |
| `Mirmir/Modules/MediaPipeline/OutputMediaVerifier.swift` | `blob` | `4d605757f9b4733b78e29f8bceb6021601743fc0` |
| `Mirmir/Modules/MediaPipeline/AVFoundationMediaSessionFinalization.swift` | `blob` | `3fb51b930455c917686063788d987428f9204092` |

### C09 — Exact resource validation and legacy build injection

| Exact path | Git object type | Git object ID |
| --- | --- | --- |
| `Mirmir/Modules/UpscalerEngine/ASH/ASHLockedArtifactStoreV3.swift` | `blob` | `9cc1eb4e8fde977f3fd0b4a361c65ac8954dd356` |
| `Scripts/inject-ash-p06-release.sh` | `blob` | `c8f9ab8977b47c5f295fb4bff9b36ab60fb7e153` |
| `project.yml` | `blob` | `53e4a6889c3cd737d7879c91121ed6b6784003cc` |

### C10 — Offline calibration and exact-app evidence infrastructure

| Exact path | Git object type | Git object ID |
| --- | --- | --- |
| `validation` | `tree` | `51af382583c657d8c99187a0ddc911d46e5f9171` |
| `MirmirP08Tests` | `tree` | `5d70219b8cbbc90d9fd45c7dc3b4b0a7ff9913ef` |
| `Scripts/run-ash-p08-native-evidence.sh` | `blob` | `3fd6562ea9c8d06f3753a0a57df2d326d0d293ee` |

### C11 — ASH V3 operator bank and LUT assets

| Exact path | Git object type | Git object ID |
| --- | --- | --- |
| `Mirmir/Modules/UpscalerEngine/ASH/ASHSpatialOperatorBankV2.swift` | `blob` | `d138c77803ae85f13243d4f23a00d1f5b6bb8a4c` |
| `Mirmir/Modules/UpscalerEngine/ASH/ASHImmutableLUTLoaderV3.swift` | `blob` | `15cc0e0ccd8403976d6d3cc58b66992181c57e11` |
| `Mirmir/Modules/UpscalerEngine/ASH/ASHLUTCompilerV3.swift` | `blob` | `b2e21c46f672141b0b47ee58dae2b92392722aa8` |
| `Mirmir/Modules/UpscalerEngine/ASH/ASHLUTBinaryFormatV3.swift` | `blob` | `ddd3b7940229e01e15993a8ad3ad5982b9570b07` |
| `Mirmir/Resources/ASH` | `tree` | `c5c027817a9568f2a45afaa52b3fdef326208b8f` |

## Retire or Replace

| Exact path | Rationale | Phase |
| --- | --- | --- |
| `validation/calibration_v2/tools/run_p06_production_calibration_v2.py` | Retire the monolithic production coordinator entry point as current authority | `R00` |
| `validation/calibration_v2/tools/run_p07_locked_holdout.py` | Retire the legacy holdout entry point as current authority | `R00` |
| `Scripts/inject-ash-p06-release.sh` | Retain as historical tooling but remove its product build-phase authorization | `R00` |
| `Mirmir/Modules/UpscalerEngine/VTSuperResolutionDriver.swift` | Replace pseudocode and copy fallback with a qualified backend after capability and baseline evidence | `R04` |
| `Mirmir/Modules/ModelAssets/VTModelStager.swift` | Replace simulated readiness with measured capability and asset state | `R01` |
| `Mirmir/Modules/UpscalerEngine/ASH/ASHLockedUpscaleBackendV3.swift` | Retain as a reference while retiring the production-primary assumption | `R03` |

## Missing Roadmap Inputs

- `canonical-computational-specification.md` — absent from the source checkpoint
- `Mirmir_Sprint_Evidence_Audit_2026-07-16.md` — absent from the source checkpoint
- `Mirmir_P06_Revised_Plan_Assessment_2026-07-17.md` — absent from the source checkpoint
- `mirmir-concept-exploration.md` — absent from the source checkpoint
- `Mirmir071626.zip` — absent from the source checkpoint

## Roadmap Input Resolutions

- `ash-v3-production-wiring-design.md` resolves to `project-notes/ash-v3-production-wiring-design.md` at Git object `bf73f86df0426b66dae36d905d29badd896ddd8e` (`unambiguous_tracked_candidate`).

## Official Evidence Boundary

Section 13 names official Apple evidence descriptively but records no tracked URL snapshot or content hash; R00 does not claim repository-local preservation of those external sources.

## Other Absent Historical Paths

- `Artifacts/ASH/20260713-p06-postrepair-8f0de437-3230-421e-8b25-464e2dbbe16e/g06/g06-postrepair-r1.failed` — absent from the source checkpoint and local host

## External P06 Evidence Boundary

The tracked authenticated receipt is preserved; the external bulk tree is unavailable and is not claimed as locally possessed or reopened.

- Receipt: `analysis/ash-failure-patterns/evidence/p06-v1-terminal-failure-analysis-receipt-v1.json`
- Receipt Git object: `41df9fd52abe112d52987126d8cf0c7bc947bce1`
- Receipt-bound external root: `Artifacts/ASH/20260714-current-source-de4feb30-9c90-4706-aaa7-c6dd82cac1fb/p06-current-source-r1/support-calibration-run/p06-current-source-r1.failed`
- Receipt-bound tree: `818` files, `3340628824` bytes (3.11 GiB), SHA-256 `5d1f22b2467a5caa83b5b7b499389e6577d244721af466c57989d23513b22d76`
- Local tree available: `false`
- Bytes reopened for R00: `false`

## Historical Preservation Identities

| Exact path | Git object type | Git object ID |
| --- | --- | --- |
| `Artifacts/ASH` | `tree` | `cb0edcfbf74ab0e56915f53436120cbbbeb09e2e` |
| `analysis/ash-failure-patterns` | `tree` | `300273852bed40d53bcdcfaee3caef3b29661997` |
| `audit-result.json` | `blob` | `2040a7d4d5c1d3a13caf9de92a420a440ee7a247` |
| `analysis/ash-failure-patterns/evidence/p06-v1-terminal-failure-analysis-receipt-v1.json` | `blob` | `41df9fd52abe112d52987126d8cf0c7bc947bce1` |

## Holdout Boundary

- Pixel access authorized: `false`
- Verification scope: tracked no-pixel metadata only
- Physical sparsebundle verified: `false`
- Keychain item verified: `false`
