# Customer error 11 investigation — November 9, 2026

Status: **Still open. No customer-causal reproduction. No causal repair.**

Candidate source: **1.7.2 (20)** on My Mac (arm64, macOS 27.0.1). Release app build from
`output/release-readiness-2026-11-09/DerivedData`. This note records today’s attempts and
the smallest evidence still required from Jim. It does not authorize release.

## What “error 11” can mean in this codebase

A bare “11” is ambiguous. Mapped code-11 surfaces include at least:

| Domain / case | Meaning |
| --- | --- |
| `Mirmir.MirmirError` / `protectedAsset` | `VideoProbe` rejects `AVAsset.hasProtectedContent == true` |
| `Mirmir.DeterministicV4MediaSegmentError` / `writerRejectedTrack` | `AVAssetWriter.canAdd` refused (now has an explicit localized description mentioning writer error 11) |
| Several other enums | `pixelAspectRatioExceedsContainerLimit`, `readerCreationFailed`, `primaryVideoMissing`, queue/publication cases, etc. (see `output/investigations/2026-10-24-admission-and-error11-lgvxy9md/error-code-audit/code11-only.tsv`) |
| Process signal 11 | `SIGSEGV` termination code 11 (local private-harness crashes were fixture bugs, not customer evidence) |
| `NSPOSIXErrorDomain` 11 | `EAGAIN`, possible via atomic publication wrapping |

Prior sealed docs already state that a protected-input NSError control does **not** establish
the customer’s cause: `docs/BOUNDED_CONVENTIONAL_QA_2026-10-26.md`,
`docs/FINAL_QA_2026-10-24.md`, `KNOWN_ISSUES.md` QA-002.

## Attempts on this host today

1. **Protected-content control (reproduced as a mapped code-11 path, not as the customer incident).**  
   Fixture: `output/resumed-qa-2026-10-25/protected-content-code11-control-01/locally-generated-cenc-control.mp4`  
   (SHA-256 `edef4b9e667340683e964a3e425e1b2067f04c9d1ed4648c2d174536a67ac9d6`).  
   Standalone AVFoundation probe (`output/release-readiness-2026-11-09/error11/protected-av-probe.json`):
   `hasProtectedContent=true`, `isReadable=false`, `isPlayable=true` → would throw
   `Mirmir.MirmirError.protectedAsset` (mapped NSError code 11).  
   Clear QA fixtures (site057, Alpine Lake variants) report `hasProtectedContent=false`.

2. **Writer `canAdd` admission sweep (did not reproduce refusal).**  
   60 H.264/HEVC/ProRes422 × geometry/variant controls on this host: **0** `canAdd=false`,
   **0** `canApply=false` (`writer-summary.json`). Matches the earlier host/macOS 15.4
   probe in `output/resumed-qa-2026-10-25/error11-minimum-os-writer/summary.json`.

3. **Writer error-11 description regression.**  
   `testMediaSegmentErrorCode11ExplainsWriterRejection` **passed** on the Release testable image.

4. **Local diagnostics / journals.**  
   Accessible Mirmir diagnostic jsonl under Containers: **no** matches for error 11 /
   `protectedAsset` / `writerRejectedTrack` / SIGSEGV. No current
   `~/Library/Logs/DiagnosticReports/Mirmir*` crash reports on disk.

5. **Public / GitHub lookup.**  
   Prior empty issue search retained; today’s web lookup found no authoritative
   flynn33/Mirmir customer error-11 report.

6. **Prior local SIGSEGV code-11 crashes.**  
   Inventory under `output/resumed-qa-2026-10-25/error-code-domain-map-01/` and
   `native-chroma-phase/private-harness-sigsegv-11/` attributes those to private
   harness UV overrun / unrelated QA bundles — explicitly **not** customer cause.

## Root-cause status

**Unknown for the customer incident.** The only reproducible application NSError code-11
path exercised today is intentional protected-content refusal. Writer rejection remains
unreproduced. No retained customer movie, screenshot, Console log, Diagnostics export,
or crash `.ips` with domain+code was available on this Mac.

## Smallest next evidence Jim should supply

Any one of the following is enough to reopen a causal investigation:

1. The exact failing source file (or a byte-identical copy) plus chosen method/output settings, **or**
2. A Diagnostics export / journal snippet from the failing run showing **error domain and code**, **or**
3. A crash `.ips` / Console report if the “11” was a process signal rather than an NSError, **or**
4. A screenshot/text of the full UI error string (not only the number “11”).

Without that, further format-routing work still rests on an unidentified failure mode.

## Not claimed

- No product source change in this investigation.
- No closure of QA-002 / release blocker “reported customer error 11”.
- Protected-content refusal working as designed is not a customer repair.
