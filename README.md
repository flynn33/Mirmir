# Mirmir

Mirmir is a native macOS video-upscaling application built with Swift, SwiftUI,
Foundation, AVFoundation, CoreVideo, Metal, VideoToolbox, and the Forsetti
Framework for Mac and iOS.

The shipping application target contains Apple-native code and resources only.
Python under `validation/` is offline calibration, evidence, and test tooling; it
is not a source of the `Mirmir` application target and is not embedded in the
application bundle.

## Current Scope

- macOS application target: `Mirmir`
- macOS unit-test target: `MirmirTests`
- unhosted evidence-launcher target: `MirmirP08Tests`
- minimum macOS deployment target: `15.4`
- bundle identifier: `com.mirmir.app`
- app category: `public.app-category.video`
- current app version in `Info.plist`: `1.0.0`

The repository does not define an iOS or Windows target.

## Architecture

Mirmir uses Forsetti as a sealed package dependency pinned in `project.yml`.
The app follows a one-UI-module pattern with separate service modules for Metal,
model-asset status, AVFoundation media IO, and upscale orchestration.

Production launch activates the product modules directly and opens the Mirmir
workspace. The developer host is available only in Debug builds when
`MIRMIR_DEVELOPER_WORKSPACE=1` is set.

See [ARCHITECTURE.md](ARCHITECTURE.md) for the module inventory and transaction
boundaries.

## ASH V3 Production Path

The product composition injects the bundle-backed, Metal-enabled locked V3
factory. Its application call graph is:

```text
MirmirForsettiBootstrap
  -> DefaultUpscalerEngineService
       -> ASHLockedUpscaleBackendFactoryV3(bundle:metal:)
            -> ASHLockedArtifactStoreV3
            -> ASHMetalUpscaleBackendV3
                 -> ASHMetalSpatialRuntimeV3
                      -> analyze luma
                      -> analyze and pack chroma state
                      -> decode immutable LUT dispatch
                      -> reconstruct luma and chroma
                      -> fixed-size telemetry reduction
       -> AVFoundationMediaSession.appendOutput
```

The service probes the source, selects the route, and loads the complete locked
artifact set before creating an output session. A missing or rejected set
therefore cannot create output state. The product path does not fall back to the
development P05 backend, a runtime LUT compiler or selector, a fixed control,
or the former Lanczos polish path.

The CPU locked-reference backend remains available only through explicitly
constructed development and test factories. It is used as a parity and
benchmark reference, not as the product execution path.

### Locked Runtime Contract

| Contract | Implemented boundary |
| --- | --- |
| Spatial routes | Direct 2× and direct 3/2× |
| Pixel format | 8-bit NV12 `420v` |
| Mapping declaration | BT.709 |
| Code range | Video range only |
| Chroma | 4:2:0, left-sited |
| Runtime data | Immutable format-1.2 LUT and fixed decoder buffers created once per backend |
| Per-frame GPU work | Six cached compute pipelines with fixed-size summary readback |
| Candidate budget | One primary and an optional secondary candidate per LUT dispatch |
| Temporal reconstruction | None; V3 is spatial-only |
| In-flight resources | Three-slot reusable Metal resource ring |

The mapping loader validates its BT.709 declaration. The pixel-buffer boundary
directly enforces NV12 plane geometry, `420v` video range, left chroma siting,
and route-derived destination dimensions; it does not infer authorization from
the buffer's YCbCr-matrix attachment. Full-range `420f`, non-left chroma,
malformed geometry, 10-bit/HDR formats, and unsupported scale pairs are
rejected.

Metal analysis preserves codes outside the nominal video-range endpoints so
its deterministic state matches the CPU analyzer. Reconstruction separately
clamps every normalized source code before exact, filtered, or conservative
fallback sampling, matching the CPU NV12 reconstruction boundary for both
routes and planes.

Metal submission is asynchronous through a command-buffer completion handler;
the production runtime does not call `waitUntilCompleted`. Source and
destination pixel buffers, CVMetalTexture references, reusable buffers, and
immutable LUT/decoder buffers are retained through command completion. The
three-slot lease is released only after AVFoundation accepts the completed
destination frame, or by the error/deinitialization cleanup path.

### Exact Authorized Release Resources

The app consumes exactly these six files from
`Contents/Resources/ASH/LockedV3`:

```text
lut-manifest-v3.json
locked-compiler-input-v2.json
locked-mapping.json
direct2x.ashlut
direct3over2.ashlut
native-lut-parity-manifest-v3.json
```

`ASHLockedArtifactStoreV3` validates the exact filename set, canonical
manifests, self-hashes, sizes, SHA-256 bindings, routes, configuration
bindings, payload hashes, and CRCs before atomically publishing one cached
artifact set. Missing, additional, linked, swapped, mutated, or mismatched
members reject the whole transaction.

The selected mapping/operator artifacts remain the exact content-addressed
`calibration_candidate` bytes measured during P06. Selection and
`locked_before_p07` authority are supplied by the enclosing 23-artifact V3
release/evidence closure; release publication never rewrites candidate bytes
and therefore cannot invalidate the compiler or LUT hashes they produced.

The sole authorizing production P06 command is
`validation/calibration_v2/tools/run_p06_production_calibration_v2.py`. It
reopens the actual current-source G04/G05/G06 trees, executes the Apple-native
schema-2 calibration path, publishes and reopens only the schema-3 release,
then publishes and reopens the external exact-six resource set and its terminal
receipt. Export outputs must be disjoint from the authenticated release and all
six support trees. The exporter reopens the receipt bytes, reopens the exact-six
members again after receipt publication, and replays the complete release,
support, and raw-manifest authority before the terminal commit. The receipt is
staged and reopened first, exclusively published as the last commit action,
and reopened again; a failing post-commit readback quarantines a newly owned
receipt rather than leaving a success document at its terminal path. An
interrupted matching staging artifact is exclusively quarantined under a
collision-safe, nonblocking `.failed` name; its bytes are never adopted, and it
cannot permanently block recovery. The historical
`run_p06_production_calibration.py` command validates only its legacy anchor
diagnostics, constructs no candidate or release, and exits with status `2`.

If the V3 release completed but its exact-six export must be recovered,
`export_p08_release_resources_v3.py` reopens that existing authoritative
release and only publishes or idempotently replays the six-file set and
receipt. It cannot select a candidate, rerun calibration, or replace P06.

The source tree intentionally does not contain
`Mirmir/Resources/ASH/LockedV3`. An authorized P06 build sets
`MIRMIR_P08_P06_RELEASE_ROOT`; the final application build phase validates an
absolute non-symlink directory containing exactly six single-link regular
files, copies them through a private staging directory, and byte-compares both
the staged and bundled copies. If the variable is absent, the script removes
any stale injected `LockedV3` directory from a reused build location.

### Output Identity and Telemetry

Every locked backend records one job identity containing the configuration ID,
release-manifest SHA-256, selected route, LUT whole-file and payload SHA-256,
format version, spatial-only flag, luma/chroma coordinate and anisotropy modes,
and analysis-grid step.

The same identity and the reset numerical-fallback count form the preflight
template for one QuickTime timed metadata group spanning the complete output.
Finalization recomputes that count while preserving the exact key set. Before
the atomic output transaction is committed, the verifier reopens the encoded
file and requires one metadata track, one full-duration group, and an exact
key/value match.

Bounded telemetry includes command-buffer status and GPU timestamps, fixed
state/message/operator histograms, decode status, declared and actual operator
counts, affine correction/fallback, numerical fallback, parity recomputation,
source-aligned preservation, and frame/job stages. Runtime diagnostics expose
the resource-ring occupancy and submission/completion state. The ASH release
identity, frame-reduction, and ring-diagnostic payloads contain no source
pixels, feature grids, or filesystem paths.

## Release-Closure Status

The runtime, exact-byte build injection, schema-2 calibration coordinator,
control authorization boundary, native P08 producers, and G08 evidence
finalizer are implemented in the current source. Their presence is not a gate
result.

The dependency-ordered release transaction is:

```text
clean committed source checkpoint
-> fresh G04
-> fresh G05
-> native runtime correction evidence
-> fresh G06 and immutable P06 V3 release
-> build ordinary Release Mirmir.app with the exact six P06 files
-> execute and seal P08 pre-G07 evidence over those exact app bytes
-> open P07 once and publish G07 over the exact P06 bytes
-> promote the unchanged P08 seal with G07 and finalize G08
```

P06 seals the fresh G04/G05/G06 semantic receipts and complete external gate
tree identities. Before recording any P07 holdout intent, the schema-2 runner
reopens those actual external trees with the authoritative gate validators
under the unchanged clean commit and requires the fresh results to match the
P06 execution authority; receipt assertions by themselves cannot authorize an
opening.

The P07 guard uses only the manifest-bound `configuration-lock-v2.json` and its
nine ordered V3 file bindings. It shares the P06 descriptor-safe validator,
rejects legacy filename aliases, and records collision-safe startup failures as
non-opening diagnostics before any holdout intent.

`MirmirP08Tests` is an unhosted launcher run by the Release-configured
`Mirmir P08` scheme: it has no `TEST_HOST` or `BUNDLE_LOADER`, launches an
ordinary `Mirmir.app` executable as a separate process, hashes the app tree
before and after each slice, and rejects `Contents/PlugIns`. The dormant app
evidence entry point requires the exact launch argument and environment pair;
normal app launch never enters it.

P08 stages native measurements, the ordinary app tree, the executable,
`default.metallib`, the bundled six-file set, exact benchmark inputs, XCTest
results, Instruments traces, and GPU captures into a self-hashed pre-G07 seal.
That seal states that G08 is unclaimed and the holdout is unopened. Promotion
after G07 reopens every sealed byte, preserves the original seal and native
envelope in the promoted identity, and derives all checks from objective
runtime counters before atomically publishing the G08 decision. Both routes
must satisfy the locked end-to-end speed and frame-rate thresholds. The
standalone finalizer command cannot authorize G08; promotion is the sole
supported path. Gate outcomes remain external immutable artifacts under
`Artifacts/ASH/`; this tracked documentation does not predict them.

See [ASH Plane-Aware V3 Production Wiring Design](project-notes/ash-v3-production-wiring-design.md)
for the detailed evidence contract.

## Project Layout

```text
Mirmir/                         Swift/SwiftUI application target
  App/                          App entry point and runtime bootstrap
  Modules/
    MediaPipeline/              AVFoundation ingest, output, and reopen verification
    MetalRendering/             Metal device, texture cache, queue, and completion bridge
    ModelAssets/                VideoToolbox model-asset readiness
    UI/                         Product workspace and views
    UpscalerEngine/             Job orchestration and ASH CPU/Metal runtimes
  Resources/                    Native app resources; no checked-in LockedV3 release
MirmirTests/                    Hosted application unit tests
MirmirP08Tests/                 Unhosted exact-app evidence launcher
Scripts/                        Build and repository verification scripts
validation/                     Offline Python/Swift calibration and evidence tooling
project-notes/                  Implementation designs and evidence boundaries
project.yml                     XcodeGen project source
```

## Requirements

- macOS with Xcode command-line tools
- XcodeGen
- SwiftLint
- network access when the pinned Forsetti package must be resolved
- Python 3.9 or newer plus locked validation dependencies for offline evidence
  work only

Regenerate the Xcode project after changing `project.yml`:

```bash
xcodegen generate
```

## Build and Test

Resolve packages and build the native app:

```bash
xcodebuild -resolvePackageDependencies -project Mirmir.xcodeproj -scheme Mirmir
xcodebuild build -project Mirmir.xcodeproj -scheme Mirmir \
  -configuration Debug -destination 'platform=macOS'
xcodebuild build -project Mirmir.xcodeproj -scheme Mirmir \
  -configuration Release -destination 'platform=macOS'
```

Run the hosted unit tests and repository guardrails:

```bash
xcodebuild test -project Mirmir.xcodeproj -scheme Mirmir \
  -configuration Debug -destination 'platform=macOS'
./Scripts/verify-mirmir-guardrails.sh
```

The ordinary `Mirmir` scheme is separate from the Release-only `Mirmir P08`
scheme. The P08 producer tests skip unless their explicit execution switch and
all exact authorized inputs are supplied.

The prior merged V3 wiring checkpoint recorded 280 tests with 279 passes, one
expected skip, zero failures, zero strict SwiftLint violations across 172
files, successful Debug and Release builds, guardrails, and an app launch smoke
check. Those historical results do not validate the current release-closure
changes and do not authorize release bytes. Fresh results belong to their
same-commit immutable gate publications.

## Notes

- The main product workflow does not expose framework or architecture controls.
- App boot does not load the release set; the first upscale request loads it
  after source probing and before output-session creation.
- Fixture tests prove only the behavior of their tested bytes. They do not
  establish perceptual superiority or authorize a P06/G07/G08 release.
- App Intents `linkd.autoShortcut` messages can appear in local macOS test logs;
  they are non-fatal local service messages.
