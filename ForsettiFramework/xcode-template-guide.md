# Xcode Template Guide

This document is the canonical support guide for Forsetti Xcode templates.
It explains what the templates generate, who owns each file, and how to move from developer setup to production deployment.

## 1. Template behavior before and after remediation

Before remediation, the `Forsetti App.xctemplate` defaulted to demo-oriented wiring through `ForsettiModulesExample`.
That was useful for evaluation, but it blurred ownership and made starter apps feel like wrappers around sample content.

After remediation, the template defaults to an app-owned module flow:

- App-owned module registry (`___PACKAGENAME___ModuleRegistry.swift`)
- App-owned starter module (`AppModule/___PACKAGENAME___AppModule.swift`)
- App-owned starter module view (`AppModule/___PACKAGENAME___AppModuleView.swift`)
- Explicit deployment mode configuration (`___PACKAGENAME___DeploymentMode.swift`)
- Starter manifest resources under `Resources/ForsettiManifests/`
- Production rendering waits for runtime boot and app module activation before showing the app module view.

`ForsettiModulesExample` remains available for evaluation only, not as the default production starter path.

## 2. Template catalog

### 2.1 Forsetti App.xctemplate

Purpose:

- Create a production-oriented starter app with app-owned module scaffolding.

Generated files (logical structure):

```text
<MyApp>/
├── <MyApp>App.swift
├── ContentView.swift
├── <MyApp>ForsettiBootstrap.swift
├── <MyApp>DeploymentMode.swift
├── <MyApp>ModuleRegistry.swift
├── AppModule/
│   ├── <MyApp>AppModule.swift
│   └── <MyApp>AppModuleView.swift
└── Resources/
    └── ForsettiManifests/
        └── <MyApp>AppModuleManifest.json
```

### 2.2 Forsetti UI Module.xctemplate

Purpose:

- Generate a starter UI module suitable for Pattern A iteration or Pattern B UI layer ownership.

Generated files:

- `___PACKAGENAME___UIModule.swift`
- `___PACKAGENAME___UIModuleView.swift`
- `Resources/ForsettiManifests/___PACKAGENAME___UIModuleManifest.json`

### 2.3 Forsetti Service Module.xctemplate

Purpose:

- Generate a starter service/background module for Pattern B multi-module apps.

Generated files:

- `___PACKAGENAME___ServiceModule.swift`
- `Resources/ForsettiManifests/___PACKAGENAME___ServiceModuleManifest.json`

### 2.4 Forsetti Manifest.xctemplate

Purpose:

- Generate a standalone starter manifest JSON that matches Forsetti schema requirements.

Generated files:

- `Resources/ForsettiManifests/___PACKAGENAME___ModuleManifest.json`

## 3. Ownership model (app-owned vs framework-owned)

App-owned (you edit these):

- Generated app/template files in your app project.
- Your module class implementations.
- Your module registry entries.
- Your manifest JSON files.
- Your deployment mode setting.

Framework-owned (do not patch for app-specific behavior):

- `Sources/ForsettiCore/*`
- `Sources/ForsettiPlatform/*`
- `Sources/ForsettiHostTemplate/*`

Decision rule:

- If your app behavior requires changing framework internals, stop and add/ask for a public extension point instead.

## 4. First customization path (build the first real module)

Start from the generated app module files:

1. Update `AppModule/<MyApp>AppModuleView.swift` with your real feature UI.
2. Keep module identity aligned in both files:
   - `AppModule/<MyApp>AppModule.swift`
   - `Resources/ForsettiManifests/<MyApp>AppModuleManifest.json`
3. Keep `entryPoint` in manifest equal to the registry registration string.
4. Register the module once in `<MyApp>ModuleRegistry.swift`.

## 5. Adding a second module (Pattern B)

To add a service module:

1. Generate scaffold files from `Forsetti Service Module.xctemplate`.
2. Add the service module factory in `<MyApp>ModuleRegistry.swift`.
3. Add the service manifest JSON into `Resources/ForsettiManifests/`.
4. Ensure module IDs and entry points are unique.
5. Verify capabilities requested are necessary and policy-approved.

To add a second UI module (rare in Pattern B):

1. Generate from `Forsetti UI Module.xctemplate`.
2. Register the module in the app registry.
3. Add view injection mapping in `<MyApp>ForsettiBootstrap.swift`.
4. Keep one UI module as primary for end-user flow.

## 6. Manifest handling model

Manifest location:

- `Resources/ForsettiManifests/*.json` in your app target.

Runtime loading:

- Template bootstrap calls `ForsettiHostTemplateBootstrap.makeController(..., manifestsSubdirectory: "ForsettiManifests")`.

Safety rules:

- Keep manifest `moduleID` consistent with module descriptor.
- Keep manifest `entryPoint` consistent with registry factory key.
- Keep requested capabilities minimal.
- Treat manifest changes as architecture changes, not UI-only changes.

## 7. Deployment patterns and generated structure

Pattern A (recommended starting point):

- One app-owned module (`ForsettiAppModule`) is your complete app UI.
- Use generated app template as-is and build real features in app module files.

Pattern B (multi-module single app):

- Keep one UI module plus one or more service modules.
- Add service module(s) and manifests, then register them.

Pattern C (developer testing):

- Keep framework controls visible for testing multiple modules.
- Generated template defaults to this via `.development` deployment mode.

Pattern D (dashboard or multi-app host):

- Keep explicit framework controls and navigation surfaces where needed.
- Add dashboard-specific module and routing overlays intentionally.

## 8. Move from developer mode to production mode

In `<MyApp>DeploymentMode.swift`:

- `.development`: keeps framework controls visible for testing.
- `.production`: boots the runtime, activates the configured app module, and then shows the app-owned module UI as the primary user surface.

Production checklist:

1. Set deployment mode to `.production`.
2. Confirm app module view is production UI, not placeholder text.
3. Confirm no example/demo package dependency is required for app identity.
4. Validate manifests and module registry alignment.
5. Confirm the app module manifest declares capabilities needed by its UI contributions, such as `view_injection`.
6. Run tests and guardrails before release.

## 9. Template install and uninstall

Install all Forsetti templates:

```bash
./Scripts/install-forsetti-xcode-template.sh
```

Uninstall templates:

```bash
./Scripts/uninstall-forsetti-xcode-template.sh
```

The install script replaces any previously installed Forsetti templates to avoid stale template artifacts.

## 10. Troubleshooting

Template not visible in Xcode:

1. Re-run install script.
2. Verify templates exist in `~/Library/Developer/Xcode/Templates/Project Templates/Forsetti/`.
3. Fully quit and relaunch Xcode.

"Module not discovered" at runtime:

1. Confirm manifest JSON is in app target resources.
2. Confirm file is under `Resources/ForsettiManifests/`.
3. Confirm manifest schema and required fields are valid.

"entryPoint not registered":

1. Confirm manifest `entryPoint` matches `ModuleRegistry.register(entryPoint:...)` exactly.
2. Confirm factory returns the expected module type.
