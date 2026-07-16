# Changelog

All notable project changes are recorded here.

## Unreleased

### Added

- Added the earlier deterministic ASH development backend and bundled development/reference ASH resources.
- Added ASH asset conformance, bitwise core, feature reconstruction, backend integration, and internal alpha tests.
- Added tile processing, chroma feature handling, branch evidence checks, Metal luma reference coverage, and buffer-level backend coverage.
- Added a strict canonical V3 release-manifest loader for format-1.2 LUT publication.
- Added an atomic, cached artifact store that accepts exactly the locked configuration, locked mapping, release manifest, native-parity manifest, direct 2× LUT, and direct 3/2× LUT. The store retains validated immutable bytes and rejects partial, additional, symlinked, swapped, mutated, or mismatched resources before publication.
- Added a shared NV12 frame codec that preserves the established extraction, normalization, code-range, chroma-siting, and destination-encoding arithmetic across the development and locked backends.
- Added the locked Y/Cb/Cr frame pipeline for both supported routes. It performs one frame preparation, constructs one luma and one shared chroma dispatch grid, enforces the LUT-declared primary/optional-secondary candidate budget, rejects non-finite or out-of-range samples, and remains spatial-only.
- Added a backend protocol and factory boundary with a locked application factory and an explicitly injected development/test factory.
- Added artifact corruption, route binding, deterministic repetition, source-aligned exactness, NV12 byte behavior, range/siting rejection, pre-session failure, and production-composition guard tests.
- Added the product-first Mirmir upscaling workflow for source selection, strategy/profile settings, output selection, progress, completion, and reveal actions.
- Added the detailed workspace shell with Dashboard, Library, Upscale, Queue, Presets, Settings, About Mirmir, and Diagnostics destinations.
- Added centralized Midnight Nordic and Arctic Indigo theme tokens for the macOS workspace.
- Added the macOS `AppIcon.appiconset` asset catalog and Xcode project wiring.
- Added repository guardrails for text hygiene, project metadata, build, tests, lint, and resource validation.

### Changed

- The default Debug and Release launch path now opens the product workspace.
- The developer workspace is limited to Debug builds with `MIRMIR_DEVELOPER_WORKSPACE=1`.
- The default app composition now requests `ASHLockedUpscaleBackendFactoryV3`; the P05 backend is available only through explicit development or test injection.
- Locked artifact validation and backend construction now occur after input probing and route selection but before media output-session creation. Missing or invalid release resources fail closed without creating output state or selecting a development fallback.
- The service no longer references the former Lanczos polish route; locked V3 reconstruction writes through the shared NV12 boundary after the complete Y/Cb/Cr frame succeeds.
- The current locked mapping limits execution to direct 2× or direct 3/2×, BT.709-declared 8-bit `420v` video range, left-sited 4:2:0 input. Runtime metadata checks enforce geometry, range, and siting; the pixel-buffer boundary does not inspect the YCbCr-matrix attachment.
- UI start conditions now require a supported source, supported target, output destination, available processing engine, and ready workflow state.
- Architecture terminology is kept out of the main product workflow and confined to technical surfaces.

### Fixed

- Corrective diagnostic CLI tests now resolve POSIX paths before comparing temporary output roots, avoiding false mismatches caused by the macOS `/var` to `/private/var` filesystem alias.
- Repository guardrails now exclude preserved `Artifacts` evidence from mutable-source JSON, attribution, and path scans while retaining source, metadata, lint, build, and test enforcement.

### Validation

- Debug and Release builds pass for the `Mirmir` macOS app target.
- The full `MirmirTests` suite executed 280 tests: 279 passed, one expected skip, and zero failed.
- Strict SwiftLint completed across 172 files with zero violations.
- Focused locked artifact-store, frame-pipeline, backend, NV12 codec, integration, corrective CLI, and architecture tests pass.
- ASH proof suite passed during ASH backend integration work.
- Repository guardrail script passes.
- The app build-and-launch verification helper built, signed locally, launched, and found the Mirmir process running.
- Invalid locked resources are verified to reject before media-session creation; range or chroma-siting mismatch is verified to reject before destination mutation.
- App icon asset catalog compiles into Debug and Release app bundles.

### Known Boundaries

- The repository currently has no iOS target.
- Windows and Visual Studio conformance are not applicable to this macOS Xcode project.
- No authorized `Mirmir/Resources/ASH/LockedV3` release set is bundled. The root-level ASH files remain development/reference resources, so the default locked job path currently fails closed at its first artifact request.
- Fresh current-source G04 and G05 evidence, a selected immutable P06 release with G06, G07 over the exact release bytes, and bundled hash reproduction remain required before activation.
- P08/G08 Metal parity, performance, and memory evidence remains open. The current locked implementation is the CPU spatial-reference path and makes no production-throughput or temporal-quality claim.
- The current locked input contract does not authorize `420f`, non-left chroma siting, 10-bit, HDR, BT.2020, or arbitrary resolution pairs.
- Current fixture tests establish repeatability and contract enforcement; they do not establish perceptual superiority or authorize release bytes.
- Local macOS test launches may emit App Intents `linkd.autoShortcut` messages; these do not fail the app build, tests, or guardrails.
