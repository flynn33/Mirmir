# P00 Instruction Conflict Record

## Resolution authority

The master directive establishes macOS/Xcode project execution and requires lower-priority conflicts to be recorded and resolved by the higher-priority contract. The local project contains a macOS application and macOS unit-test target only.

## Recorded discrepancies

1. `instructions/11_XCODE_MACOS_CONFORMANCE_AND_REPRODUCIBILITY.md` contains a sentence declaring macOS, Xcode, Swift, the reference oracle, and macOS targets out of scope, while the document title, the master directive, the package manifest, and every surrounding requirement mandate those same technologies. Resolution: treat the sentence as contradictory text and follow the macOS/Xcode requirements.
2. `config/execution_phases.json`, `config/audit_gates.json`, and the LUT/component schemas contain Windows, Visual Studio, C#, TRX, and simulator artifact labels. The master directive and repository scope exclude a Windows product or conformance project. Resolution: use independent Swift plus test-only Python conformance on macOS, require byte/hash equality, preserve Xcode result bundles, and do not create unrelated platform projects.
3. The P11 blueprint says to run a macOS Simulator host. macOS application testing uses the Apple Silicon `My Mac` destination; no macOS simulator destination exists. Resolution: run the native arm64 macOS targets in Xcode and with equivalent `xcodebuild` commands.
4. Component records C14 and C15 overlap and contain mixed platform wording. Resolution: map the semantic conformance responsibility onto validation-only macOS Xcode test targets and an independent test-only oracle, without creating a duplicate production subsystem.
5. Duplicate headings and repeated words in telemetry/handoff documents do not alter acceptance semantics. Resolution: retain one evidence section per required domain.

## Effect on pass/fail accounting

No impossible platform artifact will be represented as executed. Project-owned normalized audit criteria will cite this record and require the higher-priority native macOS/Xcode evidence. All substantive core, quality, Metal, media, failure, telemetry, determinism, and no-remote gates remain mandatory.
