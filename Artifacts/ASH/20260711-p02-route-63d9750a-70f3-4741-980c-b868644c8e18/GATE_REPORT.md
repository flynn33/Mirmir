# G02 Gate Report

## G02 — Route and transaction correctness: pass

The direct 1080p-to-2160p and ASH-plus-Lanczos 720p-to-1080p production routes each completed, reopened, and published one HEVC frame. The verified PTS is `0/600`; the exact logical duration and asset endpoint are `10/600`. AVFoundation reports an encoded minimum sample duration of `40/600`; this distinct container field is retained rather than conflated with the verified endpoint. Both decoded NV12 planes are nonempty.

The Lanczos route records one command buffer in created, committed, and completed order, all bound to frame zero and PTS `0/600`; the terminal observation contains ordered GPU timestamps and no error. The frozen CPU/GPU parity contract covers constants, horizontal and vertical ramps, center and border impulses, legal endpoints, isolated chroma edges, and fixed-seed random planes. Twenty-nine of thirty fixture/channel rows are byte exact. The remaining vertical-ramp luma row differs by one code value in 8 of 1,152 samples, with RMSE `0.08333333333333333`, within the locked maximum absolute error of 1 and RMSE limit of 0.25.

The output transaction is an explicit no-clobber state machine. Focused tests prove destination-race protection, verification-before-publication, typed bounded cleanup failures, idempotent terminal delivery, rename failure, cancellation, and verification failure. Both production runs end with no recognized partial file.

## Dependent G01 reassessment: pass

The signpost recorder and stage catalog are unchanged from the G01 checkpoint. Both new production snapshots contain all twenty catalog stages, balanced intervals, zero dropped events, zero dropped timing samples, and no errors. The Lanczos snapshot adds frame/PTS-bound command-buffer observations without changing the signpost implementation.

## Checkpoint boundary

G02 has zero mandatory failures. Full GPU ASH reconstruction, presentation-space media semantics, temporal reconstruction, soak/performance qualification, and final release audit remain owned by their later gates. Forsetti remains sealed, and no remote operation occurred.
