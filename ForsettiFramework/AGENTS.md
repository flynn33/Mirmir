# AGENTS.md - Forsetti Framework Remediation Rules

Use this file as repository-level guidance while implementing the remediation plan.

## Framework identity

Forsetti is a modularity-first, object-oriented Apple-platform framework for iOS and macOS. The project values protocol boundaries, constructor dependency injection, clear runtime contracts, and one-way target dependencies.

## Required reading before code changes

Before changing code, read these files:

- `CODEX_AGENT_BRIEF.md`
- `MODULE_BOUNDARY_RULES.md`
- `agentic-coding-policy.json`
- `Package.swift`
- `.swiftlint.yml`
- `Scripts/verify-forsetti-guardrails.sh`
- the phase file assigned for the current remediation phase

## Architecture rules

### Target dependency rules

- `ForsettiCore` must remain platform-agnostic.
- `ForsettiCore` must not import `SwiftUI`, `UIKit`, `AppKit`, `StoreKit`, `ForsettiPlatform`, `ForsettiModulesExample`, or `ForsettiHostTemplate`.
- `ForsettiPlatform` may import `ForsettiCore` and native platform frameworks required for adapters.
- `ForsettiPlatform` must not import `ForsettiModulesExample` or `ForsettiHostTemplate`.
- `ForsettiModulesExample` is example/reference code only.
- `ForsettiHostTemplate` may use SwiftUI for generic host/reference composition.

### Object-oriented design rules

- Prefer protocols for public contracts.
- Prefer `final` for production classes unless subclassing is a deliberate public design point.
- Use constructor dependency injection for collaborators.
- Avoid global mutable state.
- Keep service access and module context boundaries explicit.
- Do not use inheritance to avoid dependency injection or protocol boundaries.
- Do not use service-locator shortcuts when a narrower interface is practical.

### Runtime policy rules

- Manifest-declared capabilities must not be treated as advisory only; runtime usage must be enforced.
- A module must not be able to spoof another module's source identity.
- A factory must not be able to silently return a module whose descriptor or manifest does not match the discovered manifest.
- Persisted activation state must restore actual module lifecycle state, not only sets of IDs.
- Production templates must not visually bypass runtime activation, compatibility, or entitlement checks.

## Verification commands

Run the most relevant subset during development and all commands before completing a phase:

```bash
swift test --parallel --enable-code-coverage
swiftlint lint --strict --config .swiftlint.yml
xcodebuild -scheme ForsettiFramework-Package -destination 'generic/platform=iOS Simulator' build
./Scripts/verify-forsetti-guardrails.sh
```

If a command is unavailable in the environment, report it clearly with the exact reason.

## Testing expectations

- Add regression tests for every bug fixed.
- Add negative tests for policy enforcement.
- Prefer focused tests in existing test targets before adding new test targets.
- Do not remove or weaken existing architecture enforcement tests.
- Do not change tests merely to match broken behavior; change tests only after confirming the intended behavior in the assigned phase.

## Documentation expectations

When public behavior changes:

- Update `README.md` if it affects consumers.
- Update `developer-guide.md` if it affects integration guidance.
- Update `CODEX_AGENT_BRIEF.md`, `agentic-coding-policy.json`, or `forsetti-instructions.json` if agent guidance would otherwise drift.
- Keep docs consistent with code and tests.

## Completion report format

At the end of each remediation task, report:

1. Phase and task IDs completed.
2. Files changed.
3. Behavior changed.
4. Tests added or updated.
5. Commands run and their results.
6. Commands skipped and why.
7. Any API compatibility risk.
8. Remaining follow-up items.

## Strict prohibitions

- Do not introduce third-party runtime dependencies.
- Do not use force unwraps in new production code unless there is a documented invariant and no practical alternative.
- Do not swallow errors silently.
- Do not degrade Sendable/concurrency correctness.
- Do not make examples or tests the source of production defaults.
- Do not change proprietary license terms.
