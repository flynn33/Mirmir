# Mirmir

![Mirmir application icon](Mirmir/Assets.xcassets/AppIcon.appiconset/mirmir_icon_128x128@2x.png)

Mirmir is a native macOS video upscaler built for explicit, local processing.
Version 1.3.1 build 4 carries the deterministic ASH P06 CPU and Metal engine
beside the supported Apple scaling frameworks and records the completed
simulator-only M7 candidate selection, while keeping every backend choice,
preservation decision, and fallback boundary visible to the user.

The current marketing version and build number are recorded in
[`VERSION`](VERSION) and [`BUILD_NUMBER`](BUILD_NUMBER), then synchronized with
Xcode. Release packaging, signing, notarization, and publication remain
deliberate operator actions.

## Highlights

- Midnight Nordic interface with an interactive before-and-after comparison
  viewer for completed jobs.
- Branded Dashboard and About surfaces with live, app-specific CPU, memory, and
  disk telemetry plus truthful explicit Metal-route activity.
- Deterministic CPU and Metal ASH P06 routes for arbitrary integral target
  dimensions, with one canonical fixed-point plan and no silent backend
  substitution.
- Native 8-bit NV12 and 10-bit P010/HDR processing, field-aware deinterlacing,
  rational sample-aspect/clean-aperture geometry, and ProRes 4444 alpha output.
- State-conditioned spatial reconstruction plus bounded, motion-compensated
  temporal history with deterministic checkpoint restoration.
- Explicit Apple-native choices using VideoToolbox, MetalFX, Metal Performance
  Shaders, Core Image, Accelerate/vImage, and pixel transfer where available.
- HEVC, H.264, Apple ProRes 422, and alpha-capable Apple ProRes 4444 output in
  a QuickTime movie container.
- Ordered video, audio, subtitle, caption, chapter, timecode, timed-metadata,
  and auxiliary tracks are planned explicitly and preserved or transcoded
  according to a verified whole-asset plan.
- Durable bookmark-backed batch jobs survive relaunch. Pause/resume uses
  segment and temporal checkpoints; launch recovery contains corrupt work and
  reconciles registered partial artifacts.
- Output is semantically validated before atomic publication; cancellation,
  failure, and crash recovery account for temporary artifacts explicitly.

See [`PRODUCT_SUPPORT.md`](PRODUCT_SUPPORT.md) for exact backend contracts,
availability requirements, media behavior, and current limitations.
See [`CHANGELOG.md`](CHANGELOG.md) for the 1.3.1 qualification update, the
1.3.0 engine landing record, and
[`docs/v4/`](docs/v4/) for the qualification evidence contracts.
The [Mirmir Wiki](https://github.com/flynn33/Mirmir/wiki) provides the complete
product guide, architecture reference, ASH engine documentation, diagrams,
testing procedures, and troubleshooting material.

## Deterministic Engine v4

[![Roadmap tracker](https://github.com/flynn33/Mirmir/actions/workflows/roadmap-tracker.yml/badge.svg?branch=main&event=push)](https://github.com/flynn33/Mirmir/actions/workflows/roadmap-tracker.yml)

![Live Deterministic Engine v4 roadmap status](docs/v4/roadmap-status.svg)

The tracker is generated from the canonical roadmap, version authorities, and
current qualification status. Its workflow recomputes and byte-compares the
graphic on every push and pull request; a stale or contradictory
tracker fails the check.

The [`DETERMINISTIC_ENGINE_V4_ROADMAP.md`](DETERMINISTIC_ENGINE_V4_ROADMAP.md)
records the v4 architecture, delivery sequence, and M7 simulator selection for
at least 5% higher quality and 20% lower processing time. Engine, media, and
durable-workflow implementation originally landed in 1.3.0; version 1.3.1
records the altered simulator-only M7 scope and completed decision. The sealed
168-case headless XCTest frame-simulator run from
commit `ce780af87107d90142d860f328dca4a72fea3047` ranked `candidate_v4` first:
quality improved 22.792052% with a 22.312761% paired-bootstrap lower bound, and
total measured engine time fell 97.478689% versus frozen P05. Physical hardware,
external devices, notarization, shipping, and distribution are outside this
roadmap and are not required to complete M7.

The dated identities, completed checks, and exact simulator result are recorded in
[`docs/v4/CURRENT_QUALIFICATION_STATUS.md`](docs/v4/CURRENT_QUALIFICATION_STATUS.md).
The simulator protocol and deterministic winner-selection rule are documented
in [`docs/v4/M7_SIMULATION_QUALIFICATION_V1.md`](docs/v4/M7_SIMULATION_QUALIFICATION_V1.md).
The complete sealed evidence and five-candidate ranking are in
[`docs/v4/evidence/m7-simulation-selection-2026-09-21/`](docs/v4/evidence/m7-simulation-selection-2026-09-21/).

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

Checked-in v4 identities can be replayed the same way:

```bash
python3 script/v4/test_p06_source_identity_v4.py
python3 script/v4/test_repository_identity_v4.py
python3 script/v4/repository_identity_v4.py --repository "$PWD"
```

Run the simulator-only M7 candidate comparison from a clean committed checkout:

```bash
script/v4/run_m7_simulation_v4.sh \
  --output /tmp/mirmir-m7-simulation-evidence
```

The runner preserves the frozen P05 source, tree, and capture-source identities,
then discovers and reproduces run-specific executable hashes under the active
toolchain before comparing candidates. The
[`M7 simulator qualification`](.github/workflows/m7-simulation-qualification.yml)
workflow offers a pinned Xcode 26.2 (17C52) environment and uploads the sealed
evidence tree for independent replay.

The `Verify deterministic v4 identities` workflow also loads
`Mirmir/Resources/ASH-P06.bundle` through
`script/v4/run_p06_runtime_load_check.sh`. It computes the domain-separated
manifest identity and reads the manifest provenance source revision and builder
hash, then passes those four arguments into the production loader. A bundle
that does not match the declared trust roots cannot pass CI.

See [`CHANGELOG.md`](CHANGELOG.md) for the 1.3.1 qualification and
identity-check record.

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

`CFBundleShortVersionString` is sourced from `MARKETING_VERSION`.
`CFBundleVersion` is sourced from `CURRENT_PROJECT_VERSION`; `BUILD_NUMBER`
keeps every Xcode build setting synchronized and can be updated with
`python3 script/update_version.py --set-build N`.

Notable changes are recorded in [`CHANGELOG.md`](CHANGELOG.md).

## License and model notices

Mirmir includes separately governed deterministic ASH model material. Its
license is bundled at `Mirmir/Resources/Legal/ASH-Model-LICENSE.txt` and must
remain present in application distributions.
