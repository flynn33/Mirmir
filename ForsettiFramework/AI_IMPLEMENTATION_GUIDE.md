# AI Implementation Guide

This file is a canonical implementation guide for AI coding agents and developers implementing applications with Forsetti.

## Purpose

This guide exists to remove ambiguity.

Do not infer the implementation model from scattered hints across the repository. Use this document as the explicit implementation guide when building a Forsetti-based application.

## Framework Identity

Forsetti is a modularity-first, object-oriented framework for iOS and macOS applications built in Xcode using Apple-native tools, libraries, and frameworks only.

This includes Swift, SwiftUI, Metal, and other Apple-native technologies used in the correct module or architectural layer.

Forsetti is not a platform-agnostic abstraction layer.
Forsetti is not a cross-platform UI abstraction.
Forsetti is not a framework that asks you to avoid Apple-native technologies.

Forsetti requires Apple-native implementation with strict modular boundaries.

## Core Implementation Rule

When building with Forsetti, think in modules first.

Do not start by asking, “What code can I write anywhere?”
Start by asking, “What responsibility belongs in which module?”

## Allowed Deployment Patterns

Forsetti supports multiple deployment patterns. The most important one for most production applications is the multi-module single-application pattern.

### Multi-Module Single Application

In this pattern:

- the application is composed of exactly one dedicated UI module
- one or more service modules may exist alongside the UI module
- the dedicated UI module carries the application’s user interface
- service modules provide background, feature, service, or support capabilities
- end users interact with the application through the UI module’s interface

### Single-Module Application

Forsetti also supports a single application module that contains the complete application and its UI.

## Required Interpretation of “Host UI”

In Forsetti documentation, “host UI” refers to the application user interface used by the app built on Forsetti.

In the multi-module single-application pattern, this application UI belongs in exactly one dedicated UI module.

Do not misread “host UI” as meaning that only framework internals may use SwiftUI.

That is incorrect.

## SwiftUI Rule

SwiftUI is a valid Apple-native technology in Forsetti-based applications.

In the multi-module single-application pattern, the dedicated UI module may use SwiftUI and other Apple-native UI technologies.

This is a module-boundary rule, not a ban on SwiftUI.

The important question is not whether SwiftUI is allowed.
The important question is whether SwiftUI is being used in the correct module.

## Metal Rule

Metal is a valid Apple-native technology in Forsetti-based applications.

Metal may be used in the correct app-owned module or architectural layer when the module’s responsibility justifies it.

For example:

- a rendering-oriented module may use Metal
- a graphics-heavy UI module may use Metal where appropriate
- a module that owns rendering responsibilities may use Metal in that role

Forsetti does not prohibit Metal.
Forsetti governs correct placement and modular separation.

## Import Guardrail Rule

Layer or target import restrictions inside Forsetti are architectural boundary rules.

They are not global bans on Apple-native frameworks in app-owned consumer modules.

Do not interpret an import restriction on a Forsetti framework target as a blanket ban on using that technology in an app-owned module.

Instead, determine:

1. which module owns the responsibility
2. which architectural layer is correct for that responsibility
3. which Apple-native technology is appropriate in that module/layer

## Consumer Module Rule

Consumer applications may build app-owned Forsetti-compatible modules in their own targets.

Those modules may use Apple-native frameworks appropriate to their responsibilities, provided they respect Forsetti’s modular architecture and public contracts.

## Implementation Workflow

Use this workflow when implementing a Forsetti-based application.

### Step 1: Choose the deployment pattern

Choose whether the application is:

- a single-module application
- a multi-module single application
- a specialized testing or dashboard pattern

If the application contains multiple responsibilities separated into modules, use the multi-module single-application pattern.

### Step 2: Define the module set

For a multi-module single application, define:

- exactly one dedicated UI module
- one or more service modules as needed

The dedicated UI module owns the application UI.
Service modules do not own the primary application UI.

### Step 3: Create app-owned module targets

Create app-owned module targets in the consumer application as needed for:

- the UI module
- service modules
- feature modules
- rendering-specific modules where appropriate

### Step 4: Implement the UI in the UI module

Implement the application UI in the dedicated UI module.

This UI module may use:

- SwiftUI
- other Apple-native UI frameworks and tools appropriate to the application

Do not move the UI into unrelated service modules.

### Step 5: Implement service responsibilities in separate modules

Place service logic, background work, support capabilities, and non-UI responsibilities in separate service modules.

Keep service responsibilities separate from the UI module unless the chosen deployment pattern explicitly justifies otherwise.

### Step 6: Use Apple-native technologies in the correct module

Use Apple-native technologies where appropriate to each module’s responsibility.

Examples:

- SwiftUI in the dedicated UI module
- Metal in a rendering-oriented module or a UI module that owns rendering responsibilities
- other Apple-native frameworks in the modules whose responsibilities justify them

### Step 7: Respect Forsetti public contracts

Use Forsetti through its public APIs, public contracts, and supported extension points.

Do not patch Forsetti internals to implement app-specific behavior.

### Step 8: Validate modular boundaries

Before merging:

- confirm the UI remains in the correct dedicated UI module where applicable
- confirm service responsibilities remain in service modules
- confirm chosen Apple-native frameworks are used in the correct module/layer
- confirm no target-level boundary rules have been misread as blanket bans

## Wrong Interpretations to Avoid

The following interpretations are incorrect:

- “SwiftUI is forbidden in Forsetti-based applications.”
- “Only framework internals may use SwiftUI.”
- “Metal is probably disallowed because it is not named.”
- “Import restrictions inside Forsetti framework targets ban those frameworks everywhere.”
- “The framework wants platform-neutral abstractions instead of Apple-native implementation.”
- “The easiest solution is to flatten the architecture and ignore module boundaries.”

## Final Rule

Forsetti is not asking you to avoid Apple-native technologies.

Forsetti is asking you to place Apple-native technologies in the correct module with strict modular boundaries.
