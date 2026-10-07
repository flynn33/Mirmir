# Deterministic motion parallelism and processing activity

Introduced in Mirmir 1.6.0 build 16, this implementation parallelizes independent
motion searches within a frame. Source measurement, spatial output, output motion, temporal
reconstruction, and history publication retain their existing order. Correct
NTSC timestamps remain on the exact cadence; timestamp discontinuities are
not used to avoid temporal work.

## Bounded work and exact results

The motion analyzers divide the image into contiguous work batches. Workers
share immutable current and previous samples and own their result buffers.
Full-frame candidate searches borrow both plane sample buffers read-only for
each block search, keeping repeated Array storage access outside the inner
pixel loop. Each borrow stays within its owning closure.
Concurrency is bounded by available processors and available work; small
images use the serial path to avoid dispatch overhead. The shared concurrent
queue requests user-initiated scheduling priority. Full-frame batches own
contiguous block rows; tiled waves own separate tile buffers and join before
the next wave.

Worker completion order does not become vector order. Results are combined in
the original row-major order, with unchanged block indices and candidate
ordering: absolute difference, Manhattan displacement, vertical displacement,
then horizontal displacement. Integer evidence is accumulated before the one
existing final ties-to-even division. Workers finish before a result or an
error returns to the caller. Cancellation is checked in the initiating task
before dispatch and after the joined batch or tile wave.

Temporal history remains bounded and sequential. Each frame still consumes
the previous reconstructed frame, then publishes its own output as the next
history frame. Parallel processing does not make frames, source and output
searches, or checkpoint commits independent.

Short NTSC tracks can report an averaged rate affected by a rounded terminal
tick. The planner now recognizes the exact 1001/24000 cadence when the minimum
duration is an adjacent tick on a fine clock, that clock distinguishes it from
24 fps, and the advertised period is closer to NTSC than to the minimum tick.
The decoded sample lattice still rejects every nonadjacent timestamp. Other
constant cadences and ambiguous coarse clocks retain the existing fallback.

The completion regression also exposed PCM loss during final migration. A
66-frame NTSC source contained 132,132 audio samples at 48 kHz, while a writer
using a reduced 22,500 Hz movie clock retained 132,131. Finalization now includes
the preserved PCM clock and restores the planned edit ranges. Encoded-stream
digests and output validation continue to reject missing or changed samples.
The source's stored sample clock also preserves fractional nominal PCM rates,
without rounding those rates or requiring integer rate values. The
[native writer controls](v4/evidence/motion-parallelism-2026-10-06/pcm-presentation-clock-reproduction.json)
retain the exact sample counts, boundaries and matching failure digests.

## App Nap protection

Active planning, processing, finalization, and publication recovery hold a
scoped `ProcessInfo` user-initiated activity. Pausing, cancellation, failure,
and completion release it; resuming acquires a new activity. Waiting queued
jobs do not hold an activity. The scope permits display sleep and does not
change system power preferences.

## Verification

The final native Debug and Release suites passed 628 and 623 tests respectively,
with zero failures and five opt-in skips each. The universal Release app and
both suite commands emitted zero compiler warnings or errors. The retained
66-frame 1080p-to-4K live Metal job completed and passed all 35 independent
media checks, including every audio sample. An earlier untraced decoded H.264
parity mismatch remains unexplained; later traced repeats and final suites
passed with the strict assertions retained. See the current qualification
status for that limitation and the open full-length qualification work.

Mirmir is a native macOS Xcode target. Use the **My Mac** destination for
XCTest and the production app. iOS Simulator destinations are incompatible
with its supported platform. The earlier M7 frame simulator is a distinct
qualification harness, not an iOS app simulator.

Motion tests compare against an independently implemented serial matcher and
exercise worker counts, uneven image edges, candidate ties, scene cuts, and
repeatability. Whole-job tests must verify final publication, decoded frame
count, timing, dimensions, and preserved audio; a progress record alone does
not establish completion.

Performance measurements compare explicit serial and parallel execution on
the same frames, using an optimized build and equal resulting fields. Worker
count does not imply a proportional speedup: memory bandwidth, cache reuse,
validation, and remaining serial work constrain throughput. The operating
system controls clock frequency and core placement.

The final October 6 optimized benchmark used five alternating pairs on an M4 Pro
with 14 workers. Median full-frame analysis fell from 77.412 to 11.990
milliseconds at 1920×816, and from 312.958 to 48.316 milliseconds at
3840×1632. Every measured field equaled the serial result. These 6.46× and
6.48× ratios apply to motion analysis, not total movie completion time. Raw
measurements and source hashes are retained in
[`v4/evidence/motion-parallelism-2026-10-06/`](v4/evidence/motion-parallelism-2026-10-06/README.md).

Current executed results and limitations are recorded in
[`v4/CURRENT_QUALIFICATION_STATUS.md`](v4/CURRENT_QUALIFICATION_STATUS.md).
