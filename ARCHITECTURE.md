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
| `com.mirmir.app.upscaler-engine` | `UpscalerEngineServiceModule` | Service | Upscale job orchestration over media, Metal, and model asset services | `telemetry` | None | Private store `com.mirmir.app.upscaler-engine` |

All bundled manifests use schema/template `1.1`, require minimum Forsetti `0.1.4`, and declare explicit runtime requirements. Swift module manifests, JSON manifests, descriptors, and registry factories are covered by `ManifestRegistryAlignmentTests`.
