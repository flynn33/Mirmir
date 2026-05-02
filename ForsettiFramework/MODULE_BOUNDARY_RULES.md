# Module Boundary Rules

This document explains how to interpret Forsetti’s architectural boundaries correctly.

## Why this document exists

AI coding agents and developers can misread boundary rules if they are written too tersely.

This document states the boundary rules explicitly so they are hard to misinterpret.

## Boundary Principle

Forsetti boundary rules control where responsibilities live.

They do not exist to ban Apple-native frameworks from consumer application code.

## Primary Rule

Ask this question first:

> Which module owns this responsibility?

Do not ask this question first:

> Is this Apple-native framework globally allowed or globally forbidden?

That is the wrong framing for Forsetti.

## UI Boundary Rule

In the multi-module single-application pattern:

- there must be exactly one dedicated UI module
- that UI module owns the application UI
- service modules remain separate from the UI module

The dedicated UI module may use SwiftUI and other Apple-native UI technologies.

This means the rule is about UI placement, not UI prohibition.

## Service Boundary Rule

Service modules own service responsibilities.

They should not be used as a dumping ground for unrelated UI responsibilities.

If a service module begins to own the application’s primary UI, the boundary has been broken.

## Rendering Boundary Rule

If a module owns rendering responsibilities, that module may use rendering-appropriate Apple-native technologies.

This includes Metal when the module’s responsibility justifies it.

Forsetti does not prohibit Metal.
Forsetti requires Metal to be used in the correct module or architectural layer.

## Import Restriction Interpretation Rule

If a Forsetti framework target has an import restriction, interpret that restriction narrowly and correctly.

Correct interpretation:

- that specific target/layer must not import that framework

Incorrect interpretation:

- no Forsetti-based application code may use that framework anywhere

Do not convert a target-level rule into a global technology ban.

## Consumer Application Rule

A consumer application may build app-owned Forsetti-compatible modules in its own targets.

Those app-owned modules may use Apple-native frameworks appropriate to their responsibilities, provided they respect Forsetti’s modular structure and public extension points.

## Explicit Allowed Technology Examples

The following are explicitly valid when used in the correct module or architectural layer:

- Swift
- SwiftUI
- Metal
- other Apple-native frameworks appropriate to the module’s responsibility

## Explicitly Wrong Conclusions

These conclusions are wrong and must not be used:

- “SwiftUI is framework-internal only.”
- “The UI module cannot use SwiftUI.”
- “Metal is disallowed unless the repo says otherwise in multiple places.”
- “A target-level import restriction inside Forsetti bans that framework from all app-owned modules.”
- “Modularity means avoiding native Apple frameworks.”

## Final Rule

Forsetti is a modularity-first Apple-native framework.

The architecture question is always:

> Is this technology being used in the correct module?

That is the correct interpretation rule.
