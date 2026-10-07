# Deterministic finish-stage repair evidence — 1.7.0 (17)

[receipt.json](receipt.json) is a sanitized summary of the October 7 production
repair and complete saved-job recovery. It binds the repaired source-at-build,
signed installed executable, original source/checkpoint/request, and published
output by SHA-256. The original receipt digests identify the retained local
evidence without publishing host paths, device identifiers, raw diagnostics,
or private media.

- Complete saved-source production finalization: **passed**, 266.697 seconds,
  original plan/runtime binding accepted unchanged, normal completion
  inspection passed.
- Published HEVC movie: **148,176 video frames**, 3840×1632, two audio tracks,
  **14 chapters**, exact native duration 3,090,087/500 seconds.
- Direct independent output checks: all video/AAC/AC3/chapter encoded packets,
  timing and stored clocks/edits, both audio names, and entire decoded audio
  PCM **passed**. Native beginning/middle/end decode and QuickTime seek passed.
- Normal My Mac Debug: **658 passed, zero failed, 12 opt-in skips**. Complete
  migration suite: **102 passed, zero failed, zero skipped**. The full saved
  finalization test was explicitly enabled and passed separately.
- Fresh publication native Release: **653 passed, zero failed, 13 opt-in
  skips**, no reported runtime warnings. The isolated signed test host used
  the final project's warnings-as-errors settings. This passing repeat does
  not establish the cause of the earlier intermittent decoded-parity incident.
- Universal signed Release build: **passed**, zero compiler warnings/errors
  with warnings treated as errors. Strict signature verification passed;
  installed executable identity and native 1.7.0 / 17 UI readback matched.

Source, checkpoint, and request hashes remain unchanged; original app/cache
backups remain preserved. The historical queue record remains contained.
Recovery used completed GPU frames, so it is not a fresh full GPU render or a
matched whole-movie throughput measurement. Continuous playback, audible
speaker playback, Intel execution, the separate Release decoded-parity cause,
and packaged runtime source closure were not qualified by this recovery.

The source-at-repair-build project hash records the project that produced the
installed repair. Later publication-only project/documentation changes have
their own build/readback evidence and do not change that original receipt.
[publication-verification.json](publication-verification.json) records the
updated warnings-as-errors project, fresh signed universal Release build,
identical installed executable, and the 5:55 PM actual Xcode build with an
unfiltered **No Issues** navigator. It also preserves the failing frozen P06
helper and runtime-closure checks as separate qualification limits.
See [repair mechanisms and tests](../../../DETERMINISTIC_FINALIZATION_REPAIR.md)
and [current qualification status](../../CURRENT_QUALIFICATION_STATUS.md).
