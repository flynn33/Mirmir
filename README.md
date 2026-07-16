# Mirmir

Mirmir is a macOS video upscaling app built with Swift, SwiftUI, Foundation, AVFoundation, Metal, VideoToolbox, and the Forsetti Framework for Mac and iOS.

The app provides a product-first workspace for choosing a source video, selecting an upscale strategy, configuring quality controls, choosing output settings, and running a deterministic upscale job when a complete authorized ASH release set is installed.

## Current Scope

- macOS app target: `Mirmir`
- macOS unit test target: `MirmirTests`
- Minimum macOS deployment target: `15.4`
- Bundle identifier: `com.mirmir.app`
- App category: `public.app-category.video`
- Current app version in `Info.plist`: `1.0.0`

The current repository does not define an iOS target or a Windows target.

## Architecture

Mirmir uses Forsetti as a sealed package dependency pinned in `project.yml`. The app follows a one-UI-module pattern with separate service modules for rendering, model asset status, media IO, and upscale orchestration.

Production launch activates the product modules directly and opens the Mirmir workspace. The developer host is available only in Debug builds when `MIRMIR_DEVELOPER_WORKSPACE=1` is set.

See [ARCHITECTURE.md](ARCHITECTURE.md) for module inventory and runtime boundary details.

## ASH V3 Runtime Status

The product composition now selects the locked ASH V3 backend. The active call graph is:

```text
DefaultUpscalerEngineService
  -> ASHLockedUpscaleBackendFactoryV3
  -> ASHLockedArtifactStoreV3
  -> ASHLockedUpscaleBackendV3
  -> ASHLockedFramePipelineV3
  -> ASHLockedRuntimeV3
  -> ASHNV12FrameCodec
```

The service probes the input and selects the route, then loads the complete locked artifact set and constructs the backend before it creates the media output session. A missing or rejected artifact set therefore prevents output-session creation. The default application path does not fall back to the development P05 backend, a runtime LUT compiler or selector, or the former Lanczos polish path. Development and tests can request P05 only by explicitly injecting `ASHDevelopmentUpscaleBackendFactory`.

The current locked mapping and runtime have this bounded contract:

| Contract | Current behavior |
| --- | --- |
| Spatial routes | Direct 2× and direct 3/2× |
| Pixel format | 8-bit NV12 `420v` |
| Mapping color declaration | BT.709 |
| Code range | Video range only |
| Chroma | 4:2:0, left-sited |
| Per-frame preparation | One analyzer traversal; one luma and one shared chroma dispatch grid |
| Per-sample LUT budget | One primary candidate and an optional secondary candidate |
| Temporal reconstruction | None; the locked path is spatial-only |
| Execution | CPU locked-reference path; P08 Metal parity, performance, and memory work remains open |

The locked mapping declares BT.709, but the current pixel-buffer boundary does not inspect the YCbCr-matrix attachment. Runtime checks enforce NV12 plane geometry, `420v` video range, left chroma siting, and route-derived destination dimensions. `420f`, non-left chroma locations, malformed geometry, and mismatched destinations are rejected before destination mutation.

### Authorized Release Resources

The application expects exactly these six regular, non-symlink files under `Mirmir/Resources/ASH/LockedV3` in source or `Contents/Resources/ASH/LockedV3` in the app bundle:

```text
lut-manifest-v3.json
locked-compiler-input-v2.json
locked-mapping.json
direct2x.ashlut
direct3over2.ashlut
native-lut-parity-manifest-v3.json
```

The store validates the exact filename set, canonical manifests, self-hashes, file sizes and SHA-256 bindings, LUT routes, configuration bindings, payload hashes, and CRCs before publishing one immutable cached set. Missing, additional, symlinked, route-swapped, mutated, or mismatched resources reject the complete set; no partial cache or development substitute is published.

This repository does not currently contain `Mirmir/Resources/ASH/LockedV3`. The root-level ASH files are development and reference resources, not an authorized V3 release. Locked export activation remains gated on an authorized P06 release, current-source G04-G07 evidence over the exact bytes, bundled hash reproduction, and P08/G08 Metal parity and performance evidence.

See [ASH Plane-Aware V3 Production Wiring Design](project-notes/ash-v3-production-wiring-design.md) for the implementation boundary and open gates.

## Project Layout

```text
Mirmir/
  App/                         App entry points and runtime bootstrap
  Assets.xcassets/             App icon asset catalog
  Modules/
    MediaPipeline/             AVFoundation ingest and export boundary
    MetalRendering/            Metal device and command queue service
    ModelAssets/               VideoToolbox model asset readiness service
    UI/                        Product workspace, view model, theme, and views
    UpscalerEngine/            Upscale orchestration, locked V3, and explicit development backends
  Resources/
    ASH/                       Development/reference assets and the future LockedV3 release root
    ForsettiManifests/         Module manifests
MirmirTests/                   Unit and guardrail tests
Scripts/                       Repository verification scripts
project-notes/                 Dated implementation designs and evidence boundaries
project.yml                    XcodeGen project source
```

## Requirements

- macOS with Xcode command line tools installed
- XcodeGen
- SwiftLint
- Network access for resolving the pinned Forsetti package dependency

The repository is configured through XcodeGen. Update `project.yml` first, then refresh the Xcode project.

```bash
xcodegen generate
```

## Build

Resolve packages:

```bash
xcodebuild -resolvePackageDependencies -project Mirmir.xcodeproj -scheme Mirmir
```

Build Debug:

```bash
xcodebuild build \
  -project Mirmir.xcodeproj \
  -scheme Mirmir \
  -configuration Debug \
  -destination 'platform=macOS'
```

Build Release:

```bash
xcodebuild build \
  -project Mirmir.xcodeproj \
  -scheme Mirmir \
  -configuration Release \
  -destination 'platform=macOS'
```

## Test

Run the full macOS unit test target:

```bash
xcodebuild test \
  -project Mirmir.xcodeproj \
  -scheme Mirmir \
  -configuration Debug \
  -destination 'platform=macOS'
```

Run the repository guardrails:

```bash
./Scripts/verify-mirmir-guardrails.sh
```

The guardrail script checks diff hygiene, JSON validity, text/path hygiene, SwiftLint, project metadata, package resolution, Debug build, full tests, and Release build.

The ASH V3 wiring validation recorded on 2026-07-16 completed 280 tests with 279 passes, one expected skip, and zero failures. Strict SwiftLint reported zero violations across 172 files; Debug and Release builds, repository guardrails, and the app build-and-launch smoke check passed. These are implementation checks over source fixtures, not authorization or quality-gate evidence for release assets.

## App Icon

The macOS app icon is stored in `Mirmir/Assets.xcassets/AppIcon.appiconset`. The app target uses:

```text
ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon
```

Debug and Release builds compile the asset catalog into `AppIcon.icns` and `Assets.car` inside the app bundle.

## Notes

- The default product UI does not expose framework or architecture controls in the main workflow.
- Technical architecture details are kept in settings, diagnostics, tests, and repository documentation.
- Application boot does not load the locked release set. The first upscale request loads it after source probing and before output-session creation.
- App Intents `linkd.autoShortcut` messages can appear in local macOS test logs; they are non-fatal local service messages.
