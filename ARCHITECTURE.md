# Mirmir Forsetti Architecture

Mirmir uses Forsetti as a sealed package dependency, pinned in `project.yml` and the generated Xcode project to `https://github.com/flynn33/Forsetti-Framework-Mac-iOS.git` at revision `43eef7a739f3b78253c64aa4b070521ab5b1f43c`. That source reports Forsetti version `0.1.4`.

The product follows Forsetti Pattern B: one UI module plus cohesive service modules. The UI module owns the product workspace surface. Service modules own rendering, model asset staging, media IO, and upscale orchestration. Concrete services are assembled once in `MirmirForsettiBootstrap` and injected through module factories.

Production launch activates the five product modules directly and renders `MirmirProductionRootView` only after the UI module is active. Framework developer controls are limited to development deployment mode.

## Module Inventory

| Module ID | Entry point | Type | Responsibility | Capabilities | Default role | Data isolation |
| --- | --- | --- | --- | --- | --- | --- |
| `com.mirmir.app.ui` | `MirmirUIModule` | UI | Workspace view injection and product UI state | `view_injection` | `ui` | Private |
| `com.mirmir.app.metal` | `MetalRenderingServiceModule` | Service | Metal device and command queue readiness | None | None | Private |
| `com.mirmir.app.model-assets` | `ModelAssetsServiceModule` | Service | VideoToolbox model asset readiness and status | `storage`, `telemetry` | None | Private store `com.mirmir.app.model-assets` |
| `com.mirmir.app.media-pipeline` | `MediaPipelineServiceModule` | Service | AVFoundation read/write pipeline and file export boundary | `file_export` | None | Private store `com.mirmir.app.media-pipeline` |
| `com.mirmir.app.upscaler-engine` | `UpscalerEngineServiceModule` | Service | Upscale job orchestration and locked ASH backend selection over media, Metal, and model asset services | `telemetry` | None | Private store `com.mirmir.app.upscaler-engine` |

All bundled manifests use schema/template `1.1`, require minimum Forsetti `0.1.4`, and declare explicit runtime requirements. Swift module manifests, JSON manifests, descriptors, and registry factories are covered by `ManifestRegistryAlignmentTests`.

## Upscale Backend Composition

`DefaultUpscalerEngineService` depends on the internal `ASHUpscaleBackendFactory` protocol rather than constructing an algorithm directly. `MirmirForsettiBootstrap` injects `ASHLockedUpscaleBackendFactoryV3(bundle: .main)` into the product service. The locked factory obtains one complete artifact set and constructs a route-specific `ASHLockedUpscaleBackendV3`.

`ASHDevelopmentUpscaleBackendFactory` is a separate explicit dependency for development tools and tests. It constructs the disposable P05 reference backend. The product bootstrap does not reference that factory, and the service does not inspect errors to select another backend. A locked-load or locked-runtime failure therefore remains a failure; it cannot switch to P05, a runtime compiler or selector, or the former Lanczos polish path.

```text
MirmirForsettiBootstrap
  -> DefaultUpscalerEngineService
       -> ASHLockedUpscaleBackendFactoryV3
            -> ASHLockedArtifactStoreV3
            -> ASHLockedUpscaleBackendV3
                 -> ASHLockedFramePipelineV3
                      -> ASHLockedRuntimeV3.prepareFrame
                      -> ASHLockedRuntimeV3.evaluateSample for Y, Cb, and Cr
                 -> ASHNV12FrameCodec.write
```

The offline LUT compiler is not in this application call graph. The locked backend receives parsed, validated, immutable LUTs and performs no JSON or LUT parsing per frame.

## Locked Artifact Transaction

The product bundle lookup root is `Contents/Resources/ASH/LockedV3`. `ASHLockedArtifactStoreV3` permits exactly six entries:

| File | Role |
| --- | --- |
| `lut-manifest-v3.json` | Canonical schema-3.0 release manifest, route bindings, and manifest self-hash |
| `locked-compiler-input-v2.json` | Canonical locked configuration consumed by both route LUT loaders |
| `locked-mapping.json` | Hash-bound analyzer and input contract |
| `direct2x.ashlut` | Format-1.2 direct 2× route LUT |
| `direct3over2.ashlut` | Format-1.2 direct 3/2× route LUT |
| `native-lut-parity-manifest-v3.json` | Hash-bound native parity evidence manifest |

The root must be a non-symlink directory and every member must be a non-symlink regular file. The store rejects any missing or additional name before parsing. It then validates canonical encoding, manifest field sets and self-hash, configuration and mapping identity, file sizes and SHA-256 values, route identities, payload hashes, entry and parameter counts, and header/payload CRCs. Both route LUTs must validate against the same locked configuration.

Publication is atomic: the actor assigns its cached `ASHLockedArtifactSetV3` only after the complete six-file load succeeds. A failed attempt increments diagnostics but publishes no partial cache. A successful set retains the exact configuration, mapping, manifest, parity-manifest, and LUT bytes and is reused across backend creation; frame processing performs zero artifact loads.

## Job and Frame Transaction Boundaries

One upscale job follows this order:

1. Probe the source media.
2. Select the direct 2× or direct 3/2× route.
3. Build the output profile in memory.
4. Load the complete locked artifact set and construct the route-specific backend.
5. Reset per-backend diagnostics.
6. Begin the media output session.
7. Process and append frames, then finish or cancel the session.

Because backend construction precedes step 6, invalid or unavailable release resources cannot create an output session. Once a session exists, a frame is appended only after backend processing has produced a complete destination buffer. Cancellation or a processing error cancels the active session through the existing media cleanup boundary.

For each frame, `ASHNV12FrameCodec` extracts active Y, Cb, and Cr codes and chroma-location metadata. `ASHLockedFramePipelineV3` validates exact 4:2:0 plane geometry, source and destination code range, chroma siting, and route-derived destination dimensions before evaluation. It then:

1. normalizes Y, Cb, and Cr with the shared byte-bound arithmetic;
2. calls `ASHLockedRuntimeV3.prepareFrame` once;
3. constructs one luma dispatch grid and one shared chroma dispatch grid;
4. reconstructs every Y sample, followed by every Cb and Cr sample;
5. requires each result to be finite and within `[0, 1]`; and
6. writes the destination NV12 planes only after all reconstruction succeeds and cancellation is checked again.

Each LUT entry declares one primary candidate and an optional secondary candidate. The frame summary enforces and reports this one-or-two declared candidate budget. It is not an invocation-level performance counter: a recoverable candidate error may invoke the conservative evaluator after the declared candidates were attempted.

## Supported Locked Contract

| Property | Locked V3 contract |
| --- | --- |
| Routes | Direct 2× and direct 3/2× |
| Pixel layout | 8-bit NV12 `420v`, 4:2:0 |
| Mapping declaration | BT.709 |
| Range | Video range |
| Chroma siting | Left |
| Boundary handling | Hash-bound locked mapping/configuration value |
| Temporal state | None; format 1.2 is spatial-only in this integration |
| Runtime implementation | CPU locked-reference path |

The mapping parser requires the BT.709 declaration, but the current pixel-buffer boundary does not inspect the buffer’s YCbCr-matrix attachment. Runtime validation directly enforces geometry, `420v` video range, left siting, and route dimensions. Full-range `420f`, non-left siting, 10-bit/HDR formats, and arbitrary scale pairs are outside the locked contract.

## Activation Boundary

The product wiring is present, but locked release activation is not complete. This repository does not contain `Mirmir/Resources/ASH/LockedV3`; existing root-level ASH resources are development/reference inputs and are not substituted for the six-file release set. Application boot can complete, but the first upscale request fails closed while loading the absent set, after source probing and before output-session creation.

Activation still requires fresh current-source G04 and G05 evidence, a selected immutable P06 release with G06, G07 over the exact release bytes, bundled resource hashes that reproduce that release, and the remaining integration coverage. P08/G08 must establish Metal parity, determinism, performance, and memory behavior before the locked path can be represented as the production-performance implementation. Fixture determinism tests establish repeatability for identical tested bytes; they do not establish perceptual superiority or release authorization.

See [project-notes/ash-v3-production-wiring-design.md](project-notes/ash-v3-production-wiring-design.md) for the implementation record and gate-level completion criteria.
