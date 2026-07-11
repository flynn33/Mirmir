# P02 Route and Transaction Evidence

This immutable run records G02 route correctness, Metal completion ordering, fixed-point Lanczos parity, exact frame timing, output reopen verification, atomic no-clobber publication, cancellation, and cleanup behavior.

The production route fixtures are correctness fixtures only. They are excluded from the native-HR quality corpus because their rights status is not asserted for that purpose.

The two production route runs use the same source bytes retained in `inputs/`. Their route descriptors use evidence-relative paths so the package remains relocatable. `route-test-results.json` binds every input, output, and telemetry file by SHA-256.

Development failures are retained as result summaries in `raw/failures/` and classified in `analysis/development-failure-classification.json`. The final fixed-point implementation is bound to the frozen fixture contract and its independent metric record in `lanczos-reference-results.json`.

G01 is reassessed because P02 changes media and telemetry observation surfaces. The signpost recorder and stage catalog are byte-identical to the prior G01 checkpoint; both new route snapshots have twenty balanced stages, no dropped observations, and no recorded errors.
