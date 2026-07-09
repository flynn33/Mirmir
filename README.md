# Mirmir

Mirmir is a macOS video upscaling app built with Swift, SwiftUI, Foundation, AVFoundation, Metal, VideoToolbox, and the Forsetti Framework for Mac and iOS.

The app provides a product-first workspace for choosing a source video, selecting an upscale strategy, configuring quality controls, choosing output settings, and running a deterministic upscale job.

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
    UpscalerEngine/            Upscale orchestration and ASH backend
  Resources/
    ASH/                       Bundled ASH runtime assets
    ForsettiManifests/         Module manifests
MirmirTests/                   Unit and guardrail tests
Scripts/                       Repository verification scripts
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

## App Icon

The macOS app icon is stored in `Mirmir/Assets.xcassets/AppIcon.appiconset`. The app target uses:

```text
ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon
```

Debug and Release builds compile the asset catalog into `AppIcon.icns` and `Assets.car` inside the app bundle.

## Notes

- The default product UI does not expose framework or architecture controls in the main workflow.
- Technical architecture details are kept in settings, diagnostics, tests, and repository documentation.
- App Intents `linkd.autoShortcut` messages can appear in local macOS test logs; they are non-fatal local service messages.
