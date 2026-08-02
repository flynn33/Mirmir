# Mirmir

![Mirmir application icon](Mirmir/Assets.xcassets/AppIcon.appiconset/mirmir_icon_128x128@2x.png)

Mirmir is a native macOS video upscaler built for explicit, local processing.
It combines deterministic CPU and Metal preview engines with supported Apple
scaling frameworks, while keeping every backend choice and fallback boundary
visible to the user.

The current application version is recorded in [`VERSION`](VERSION). Release
packaging, signing, notarization, and publication remain manual operations.

## Highlights

- Midnight Nordic interface with an interactive before-and-after comparison
  viewer for completed jobs.
- Deterministic CPU and Metal preview routes for supported 2× and 3:2 NV12
  inputs, with no silent backend substitution.
- Explicit Apple-native choices using VideoToolbox, MetalFX, Metal Performance
  Shaders, Core Image, Accelerate/vImage, and pixel transfer where available.
- HEVC, H.264, and Apple ProRes 422 output in a QuickTime movie container.
- Source timing, display orientation, supported SDR color metadata, and one
  compatible audio track are preserved.
- Output is validated before atomic publication; cancellation and failure remove
  temporary output.

See [`PRODUCT_SUPPORT.md`](PRODUCT_SUPPORT.md) for exact backend contracts,
availability requirements, media behavior, and current limitations.

## Requirements

- macOS 15.4 or later
- Xcode 26 or later
- A Metal-capable Mac for GPU-backed processing routes

Some VideoToolbox enhancement routes require macOS 26 or later and may require
an Apple-managed model download. The application reports unavailable routes and
their reasons without silently selecting a different method.

## Build and run

Open `Mirmir.xcodeproj` in Xcode and run the `Mirmir` scheme, or use:

```bash
./script/build_and_run.sh
```

The helper also supports `--debug`, `--logs`, `--telemetry`, and `--verify`.

To build without launching the application:

```bash
xcodebuild \
  -project Mirmir.xcodeproj \
  -scheme Mirmir \
  -configuration Debug \
  -destination 'platform=macOS' \
  build
```

## Test

```bash
xcodebuild \
  -project Mirmir.xcodeproj \
  -scheme Mirmir \
  -configuration Debug \
  -destination 'platform=macOS' \
  test
```

Version tooling can be checked independently on any machine with Python 3:

```bash
python3 script/update_version.py --check
python3 script/test_update_version.py
```

## Versioning

Mirmir uses `release.feature.patch` versions. Exactly one version label may be
applied to a same-repository pull request:

| Pull-request label | Result from `1.2.3` |
| --- | --- |
| `release` | `2.0.0` |
| `feature-release` | `1.3.0` |
| `patch/hotfix` | `1.2.4` |
| No version label | No increment (`1.2.3`) |

The pull-request version workflow calculates the target from the base branch,
updates `VERSION` and every Xcode `MARKETING_VERSION` setting, validates the
result, and commits the change to the pull-request branch. Repeated runs resolve
to the same target rather than incrementing again. Conflicting version labels
fail the workflow. Fork pull requests are never given write access.

`CFBundleShortVersionString` is sourced from `MARKETING_VERSION`, and
`CFBundleVersion` remains the separate Xcode build number.

Notable changes are recorded in [`CHANGELOG.md`](CHANGELOG.md).

## License and model notices

Mirmir includes separately governed deterministic ASH model material. Its
license is bundled at `Mirmir/Resources/Legal/ASH-Model-LICENSE.txt` and must
remain present in application distributions.
