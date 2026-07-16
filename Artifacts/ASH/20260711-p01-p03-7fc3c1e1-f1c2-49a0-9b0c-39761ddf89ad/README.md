# P01/P03 ASH Checkpoint Evidence

Run ID: `20260711-p01-p03-7fc3c1e1-f1c2-49a0-9b0c-39761ddf89ad`

This finalized local checkpoint contains the evidence used to pass G01 and G03. It is rooted at the P00 checkpoint `c319b2cdb2ea3906c665cd7a6a5aaec817edf914` and does not record a remote operation.

## Gate results

- G01: pass for the traced one-frame 1920×1080 to 3840×2160 direct production route. The retained Logging trace and telemetry snapshot reconcile all 20 stage counts, including zero-count unexecuted stages. See `analysis/g01-gate-assessment.json` and `analysis/signpost-validation.json`.
- G03: pass. Production Swift and the independent Python oracle emit the same 3,016,832-byte canonical fixture with SHA-256 `19b1dfe4f7aa3f1e77e1364afbced3799aca261e88024c823f8cc1d68fb42776`. See `conformance/g03-gate-assessment.json`.

## Verification summary

- Clean Debug build: pass, zero errors and warnings.
- Clean Release build: pass, zero errors and warnings.
- Focused P01/P03 tests: 18 passed, 0 failed, 0 skipped.
- Complete Debug suite: 82 passed, 0 failed, 1 skipped. The skipped production fixture is intentionally enabled only for the separate retained evidence run, where it passed 1 of 1 tests.
- Strict Swift lint: pass.
- Independent canonical-core check and contract mutation rejection: pass.
- Output inspection: HEVC, 3840×2160, one video sample, PTS `0/600`, duration `40/600`, zero media-analysis errors.

## Scope limits

This checkpoint does not pass later gates. The Lanczos completion-order defect, typed command-buffer error handling, output transaction state machine, and reopen verification remain G02 work. The quality corpus remains G04 work; temporal fusion remains G10 work; final locked telemetry-schema conformance remains G11 work.

`artifact-manifest.json` hashes every retained file except the manifest itself. Raw high-volume allocation and time-profiler bundles are retained at the neutral external path recorded by `external-evidence.json`.
