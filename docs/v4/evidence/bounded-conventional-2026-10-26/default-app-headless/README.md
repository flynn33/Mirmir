# Exact default-app headless workflow evidence

The actual non-testable universal Release development app executes the existing built-in observer in two separate processes. Host macOS 27.0.1 and actual macOS 15.4 both pass probe, P06 load, deterministic CPU processing, durable pause and fresh-process recovery. Twelve 96x72 H264 frames, with audio omitted, match the uninterrupted reference in decoded visible pixels, normalized duration, geometry and presentation timing. This does not establish encoded packet/DTS/whole-file equality, arbitrary input/conventional routes, or distribution acceptance.

`summary.json`, `macos154-verification.json`, original wire results, app/ZIP/source identities and checks are retained. The ZIP is a real local copy of the tested app, not a notarized artifact. The source commit is c1dbe8509fdc06d3a8acd085008ccc00af98a013; subsequent report-only commits do not alter its production bytes.

The first private wrapper falsely rejected valid Foundation JSON because Python rendered one Double with different digits. `prepare-run.json` preserves that failed wrapper result; the app itself exited zero. The repository's release-capture parser has the same reproduced defect and remains unchanged. Native Foundation canonicalization validates the wire bytes.

Host terminal access to the sandbox's live JSON files is denied with EPERM. No TCC/security setting was changed. Explicit private fallback supplies SHA256 of the exact original prepare stdout result; the unchanged app's recover reads its own live file and requires that seal. The final wrapper additionally checks all eight returned checks, artifact/job continuity and decoded semantic equality. External file comparison remains labeled unavailable. Actual macOS 15.4 runs the default app with only HOME/PATH/TMPDIR/NSUnbufferedIO and no XCTest/DYLD injection; all 21 app files and signatures remain unchanged.

Private helper sources are retained as measured evidence; they are not a repair or replacement for the repository release-capture harness. No UI, notarization, Store or GitHub operation is part of this workflow check.
