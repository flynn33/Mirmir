# G01/G03 Gate Report

## G01 — Trace and telemetry: pass

The current production call graph is documented in `analysis/call-graph.md`. The retained optimized direct-route run produced a successful, balanced telemetry snapshot and a Logging trace for process `Mirmir (51165)`, subsystem `com.mirmir.ash.engine`, category `ASH`. `analysis/signpost-validation.json` independently resolves trace references and verifies that telemetry count equals raw Begin count, raw End count, and completed interval count for every catalog stage. No unexpected name, event type, non-positive interval, dropped event, dropped timing sample, or runtime error was found.

The result is route-scoped. Conditional GPU completion/error observations and reopen verification remain G02 obligations; temporal fusion remains G10; final telemetry-schema packaging and route-complete in-flight/readback evidence remain G11.

## G03 — Canonical core conformance: pass

Production Swift and the independent Python oracle share only the locked declarative contract `validation/reference/ash-core-v1.contract.json`, SHA-256 `97ff97a79257707824c91f6f99bc7495bd4b78b221e930f8614c8ce12d782936`. Each implementation independently validates that contract and emits the same binary fixture.

The retained evidence checks 512 raw states, 256 valid-parity states, 16 codewords, 4,096 exact affine records, 36,864 one-bit records, and 147,456 required two-bit records. The final binary is 3,016,832 bytes with SHA-256 `19b1dfe4f7aa3f1e77e1364afbced3799aca261e88024c823f8cc1d68fb42776`. Generator-row and decoder-radius mutations are rejected by both implementations. The focused Swift result contains 4 passed tests with no failure or skip.

The lower phase inventory's Windows result label is superseded by the controlling macOS/Xcode project scope, as recorded in `conformance/platform-output-resolution.json`; no substitute result was fabricated.

## Checkpoint boundary

Both mandatory gates have zero gate-local failures. No later gate is pre-passed by this checkpoint, no holdout was accessed, Forsetti remains sealed, and no fetch, push, pull request, tag, release, or remote configuration change occurred.
