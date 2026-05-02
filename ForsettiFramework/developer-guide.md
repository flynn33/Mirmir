# Forsetti Framework Developer Guide

This guide is for teams integrating Forsetti into their own apps.
It defines the engineering rules your project should enforce so Forsetti remains modular, native, and maintainable.
_Last updated: May 1, 2026_

## 1. Required Stack

- Use native Apple technologies only for framework/runtime implementation:
  - Swift
  - Swift Package Manager / Xcode
  - SwiftUI (including dedicated Forsetti UI modules in application implementations)
  - Native Apple frameworks (Foundation, Combine, StoreKit, etc.) where appropriate
- Do not add cross-platform UI/runtime frameworks for core behavior.

## 1b. UI Module Clarification

SwiftUI is valid for the application UI in Forsetti, but the application UI must live in the correct module.
In the multi-module single-application pattern, the application UI belongs in exactly one dedicated UI module.
That UI module may use SwiftUI and other Apple-native UI technologies.
This is a module-boundary rule, not a ban on SwiftUI.

Metal is also a valid Apple-native technology in Forsetti-based applications when it is used in the correct app-owned module or architectural layer.
Forsetti does not prohibit Metal.
Forsetti requires that Metal be used in the correct module with clear modular boundaries.

## 1c. Host UI Definition

In Forsetti documentation, "host UI" refers to the application user interface used by the app built on Forsetti.
In the multi-module single-application pattern, this application UI belongs in a dedicated UI module.
The requirement is about modular separation of responsibilities, not avoidance of Apple-native UI frameworks.

## 2. Integration Boundaries (Required)

Forsetti must be treated as a sealed framework in consumer projects.

### Allowed

- Use Forsetti package products through their public APIs.
- Build your app features in your own targets/packages.
- Implement your own modules using public contracts such as `ForsettiModule`, `ForsettiAppModule`, or `ForsettiUIModule`.

### Not Allowed

- Forking or modifying Forsetti internal targets for app-specific behavior.
- Copying Forsetti source files into your app and editing them.
- Subclassing or patching Forsetti runtime internals through unsupported hooks.
- Coupling your app targets back into Forsetti internal targets.

If a required extension point is missing, request a framework enhancement instead of patching internals.

## 3. OOP Rules (Required)

- Prefer protocol-first design for contracts and behavior boundaries.
- Use constructor dependency injection for collaborators.
- Avoid hidden global state and implicit service lookup patterns.
- Keep objects single-purpose and cohesive.
- Use `final class` for production classes unless there is a clear, documented reason not to.
- Keep access control tight:
  - `private`/`fileprivate`/`internal` by default
  - `public` only for intentional API surface

## 4. Modularity Rules (Required)

- Each module/target must own a clear responsibility.
- Do not leak platform/UI concerns into `ForsettiCore`.
- Keep public APIs minimal and stable.
- Prefer composition over inheritance across module boundaries.
- Avoid cyclic dependencies (direct or indirect).
- Use production platform defaults for app composition; keep in-memory secure storage as an explicit test/debug choice.
- Treat file export filenames as untrusted input and keep writes inside the configured export directory.

## 5. Import Restrictions

Layer-specific restrictions are enforced by lint/tests:
these are target-specific architecture guardrails, not blanket bans for every consumer module.

- `ForsettiCore` must not import:
  - `ForsettiPlatform`, `ForsettiModulesExample`, `ForsettiHostTemplate`
  - `SwiftUI`, `UIKit`, `AppKit`, `StoreKit`
- `ForsettiPlatform` must not import:
  - `ForsettiModulesExample`, `ForsettiHostTemplate`
  - `SwiftUI`, `UIKit`, `AppKit`
- `ForsettiModulesExample` must not import:
  - `ForsettiPlatform`, `ForsettiHostTemplate`
  - `SwiftUI`, `UIKit`, `AppKit`, `StoreKit`
- `ForsettiHostTemplate` must not import:
  - `ForsettiModulesExample`

## 6. How to Enforce These Rules in Your App

Use enforcement in your own repository, not in Forsetti's source tree.

- Add architecture tests in your app repo that validate:
  - allowed target dependencies
  - forbidden cross-layer imports
  - final-class policy for Forsetti-facing runtime classes
- Add a lint configuration (`.swiftlint.yml`) with custom layer/import rules.
- Add a local verification script (for example `Scripts/verify-forsetti-guardrails.sh`) that runs tests and lint in one command.
- Add CI (for example GitHub Actions) to run the same verification on every push and pull request.

Suggested structure in your app repository:

- `Tests/ArchitectureTests/ForsettiArchitecturePolicyTests.swift`
- `.swiftlint.yml`
- `Scripts/verify-forsetti-guardrails.sh`
- `.github/workflows/forsetti-guardrails.yml`

Suggested verify script commands:

```bash
swift test --parallel --enable-code-coverage
swiftlint lint --strict --config .swiftlint.yml
```

## 7. Developer Workflow (Required Before PR)

In your app repository:

1. Run your guardrail script (or equivalent test + lint commands) from repo root.
2. Confirm architecture policy tests pass.
3. Confirm lint rules pass with no violations.
4. Open/update PR only after local guardrails pass.

PRs should be blocked from merge unless guardrails also pass in CI.

## 8. Adding New App Code Safely (Integration-Only)

When adding capabilities in a project that uses Forsetti:

1. Create or choose an app-owned target/package for your Forsetti modules.
2. Implement `ForsettiAppModule` (single-module apps), `ForsettiUIModule` (multi-module UI), or `ForsettiModule` (service/feature) in your own codebase.
3. Define each module's descriptor/manifest and register entry points in your app bootstrap.
4. Compose runtime/services using public Forsetti APIs only.
5. Declare only the capabilities the module needs; service access and UI contributions are enforced against those capabilities at runtime.
6. Keep dependencies injected and avoid global mutable state.
7. Add tests for module behavior and architecture policy in your repository.
8. Run guardrails before opening/updating a PR.
9. If an API gap is discovered, propose an upstream Forsetti change; do not patch internal framework code.

## 9. Review Checklist

Use this checklist for every review:

- Correct target/layer placement?
- Any forbidden imports or new cross-layer coupling?
- Public API necessary and minimal?
- Class/protocol design OOP-consistent and modular?
- Dependencies injected (not hidden globals)?
- Tests added/updated for behavior and architecture impact?
- Guardrail script executed successfully?

## 10. Non-Compliance Policy

Changes that violate these rules must be refactored before merge.
Temporary exceptions require explicit rationale in the PR description and follow-up work item.
