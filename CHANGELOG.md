# Changelog

All notable project changes are recorded here.

## Unreleased

### Added

- Added the deterministic ASH upscaling backend and bundled ASH runtime assets.
- Added ASH asset conformance, bitwise core, feature reconstruction, backend integration, and internal alpha tests.
- Added tile processing, chroma feature handling, branch evidence checks, Metal luma reference coverage, and buffer-level backend coverage.
- Added the product-first Mirmir upscaling workflow for source selection, strategy/profile settings, output selection, progress, completion, and reveal actions.
- Added the detailed workspace shell with Dashboard, Library, Upscale, Queue, Presets, Settings, About Mirmir, and Diagnostics destinations.
- Added centralized Midnight Nordic and Arctic Indigo theme tokens for the macOS workspace.
- Added the macOS `AppIcon.appiconset` asset catalog and Xcode project wiring.
- Added repository guardrails for text hygiene, project metadata, build, tests, lint, and resource validation.

### Changed

- The default Debug and Release launch path now opens the product workspace.
- The developer workspace is limited to Debug builds with `MIRMIR_DEVELOPER_WORKSPACE=1`.
- The default upscale path now uses the ASH backend while preserving the media pipeline, output writer, timing, audio passthrough, progress, and Lanczos polish path.
- UI start conditions now require a supported source, supported target, output destination, available processing engine, and ready workflow state.
- Architecture terminology is kept out of the main product workflow and confined to technical surfaces.

### Validation

- Debug build passes for the `Mirmir` macOS app target.
- Release build passes for the `Mirmir` macOS app target.
- Full `MirmirTests` suite passes.
- Focused ASH tests pass.
- ASH proof suite passed during ASH backend integration work.
- Repository guardrail script passes.
- App icon asset catalog compiles into Debug and Release app bundles.

### Known Boundaries

- The repository currently has no iOS target.
- Windows and Visual Studio conformance are not applicable to this macOS Xcode project.
- Local macOS test launches may emit App Intents `linkd.autoShortcut` messages; these do not fail the app build, tests, or guardrails.
