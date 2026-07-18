# P06 legacy-run observation — 2026-07-17

## Purpose and authority boundary

This note preserves two read-only observations of the legacy P06 V3 transaction that ran from source checkpoint `89778b103da855fab5470618ba8f0329f7ab38d1`. It is historical testing evidence for the resumability redesign. It does not authorize a release, resume, retry, salvage operation, candidate selection, validation access, holdout access, or downstream stage.

The compact machine-readable testing fixture is [p06-v3-i00-observation-20260717](../validation/calibration_v2/tests/fixtures/p06-v3-i00-observation-20260717/). The fixture and this note preserve observations; neither is a terminal P06 artifact.

## Snapshot 1 — Safe Observation Protocol

Observation time: `2026-07-17T16:17:37-0500`.

The following facts were observed without modifying the transaction:

| Observation | Exact value |
| --- | --- |
| P06 parent process | PID `10671`; PPID `1`; started `2026-07-17 08:06:57 -0500`; elapsed `08:10:40`; accumulated CPU time `08:02.73`; state `Ss`; sampled CPU `0.0%`; sampled memory `19.8%` |
| Active native child | PID `10924`; PPID `10671`; started `2026-07-17 08:07:40 -0500`; elapsed `08:09:57`; accumulated CPU time `480:51.83`; state `R`; sampled CPU `98.6%`; sampled memory `1.0%` |
| Liveness conclusion | The original parent existed and its native child was actively consuming CPU. |
| Source checkpoint | Worktree clean at `89778b103da855fab5470618ba8f0329f7ab38d1` on branch `ash-v3-release-closure`. |
| Terminal publication | Immutable V3 release bundle or manifest absent; exact-six resource directory `LockedV3` absent; terminal receipt absent. |
| Failure publication | No `.failed`, quarantine, or collision path observed under the inspected P06 output authorities. |
| Content-addressed evidence documents | `1,070` documents under the evidence/documents authority. |
| Run-root file inventory | `29,126` files. |
| Run-root allocated size | `8,733,720 KiB`. |
| Available filesystem capacity | `440,709,428 KiB`. |
| Holdout boundary | Holdout remained sealed; access count was `0`; `holdout_accessed` remained `false`; no holdout media path was opened. |

The absent terminal names mean that this snapshot did not establish P06 success or failure. The process signals establish only that the observed transaction was live at the stated time.

## Snapshot 2 — analytic I00 inventory

Observation time: `2026-07-17T16:27:04-0500`.

This second read-only inventory separated the outer full-ASH scheduler from the inner non-ASH control selector executing inside its first candidate:

| Layer | Observed progress |
| --- | --- |
| Outer full-ASH development search | `0` durable outer attempt records; the first outer candidate was active. The zero is a durable-ledger count, not a claim that no computation had occurred. |
| Inner non-ASH development selector | `614` attempt records: `526` unique candidate evaluations and `88` cache-hit attempts. The identity `526 + 88 = 614` reconciled exactly. |
| Inner native-cache-support inventory | `526` unique candidate entries plus `19` control entries, for `545` total unique candidate/control entries. The identity `526 + 19 = 545` reconciled exactly. |

The active outer candidate was bound to these exact identities:

| Identity | Exact value |
| --- | --- |
| Candidate vector SHA-256 | `5ef8b175db2a957509037f5a8c48f1a1238de6e08cf57d7511f44552e1dfb1dc` |
| Configuration ID | `ash-p06-5ef8b175db2a957509037f5a` |
| Shared-bank configuration SHA-256 | `a9e66dd89a6b5efe01dc758c4d9947f75e0bcc9f60cc71c20eaa6259bce03e8f` |
| Locked compiler-input file SHA-256 | `04ae8202586e540490650dd14c0cb7b158be93f42cbf80375ebb5886fb50a3a8` |
| Compiler-input semantic binding SHA-256 | `a88e7f5151a428e0426530760640da5c1be89c8e1542e0cb702f418d8fb54c95` |

The first scheduled inner attempt without completion evidence was zero-based attempt ordinal `614`: sweep `4`, coordinate ordinal `6`, coordinate `bias_descriptor_06_q8_8`, value `128`, rule SHA-256 `1d2ae1d3fae11fbc287e4994777454a0fd3d114d9c07cc28e160d1e63cad22e0`. This was the first missing scheduled rule. The observation did **not** prove that this rule was the rule executing at the instant of observation.

The first observed non-ASH completion timestamp was `2026-07-17T13:11:23.013897Z`; the latest completion in the analytic snapshot was `2026-07-17T21:26:52.098983Z`. The measured inner-selector rates were `63.57` unique evaluations per hour and `74.23` attempts per hour. The final one-hour window contained `63` unique completions.

Replay of the completed inner attempt records established that sweep `4` had already changed its incumbent. Therefore the earliest convergence boundary was after sweep `5`, at `946` total inner attempts. From the observed `614` completed attempts, that boundary was `332` attempts away, or approximately `4.47` hours at the measured `74.23` attempts per hour. The inner development ceiling was `2,789` attempts away, or approximately `37.57` hours at the same measured rate.

Those durations are inner-selector projections only. They do not predict when the active outer candidate would return, when later outer candidates would terminate, or when P06 as a whole would finish. Outer-candidate ETA and overall P06 ETA remained unknown.

### Snapshot 2 resource inventory

| Resource observation | Exact value |
| --- | ---: |
| Run-root file inventory | `29,494` files |
| Run-root allocated size | `8,751,540 KiB` |
| Native-cache-support allocated size | `982,584 KiB` |
| Content-addressed evidence allocated size | `17,440 KiB` |
| Content-addressed evidence documents | `1,090` documents: `545` objective-summary/output-manifest pairs |

The prior census retained for the I00 growth comparison contained `24,426` files and occupied `8,507,132 KiB`. The exact observed growth was `5,068` files and `244,408 KiB`. This comparison baseline is distinct from the later Safe Observation Protocol census in Snapshot 1.

No exact terminal workload total was derivable for either adaptive scheduler at this snapshot. The applicable frozen ceilings were:

| Budget | Frozen ceiling |
| --- | ---: |
| Outer development attempts | `3,288` |
| Outer validation neighborhood | `374` |
| Inner non-ASH development attempts | `3,403` |
| Inner non-ASH validation candidates | `163` |

These values are upper bounds, not forecasts and not evidence that every budgeted attempt would execute. The inner-selector projections above are rate extrapolations to two inner boundaries; no outer or overall completion percentage or ETA was asserted because the applicable terminal totals were unknown.

## Source proof for adaptive scheduling

The outer schedule is defined by [calibration_scheduler_v2.py](../validation/calibration_v2/calibration_scheduler_v2.py):

- A complete sweep contains `256` structural attempts and `155` scalar attempts, totaling `411`.
- The schedule permits at most `8` sweeps, establishing the `3,288` development ceiling.
- The structural winner becomes the current candidate before scalar scans begin.
- Each scalar-coordinate winner updates the current candidate before the next coordinate is generated.
- A complete sweep terminates at a fixed point or starts another sweep according to the measured incumbent.

Consequently, later outer candidates and the number of executed outer sweeps depend on earlier measured outcomes. The first in-flight candidate cannot be converted into an exact outer terminal workload total.

The inner schedule is defined by [non_ash_selector_v2.py](../validation/calibration_v2/non_ash_selector_v2.py), with its frozen resource limits defined by [baseline_ablation_budget_v2.py](../validation/calibration_v2/baseline_ablation_budget_v2.py):

- It first evaluates the initial rule, then scans each coordinate over the frozen value domain.
- Each coordinate winner becomes the incumbent used to generate later coordinate candidates.
- A sweep converges when no incumbent changes; otherwise another sweep begins, up to `18` sweeps.
- Its maximum development count is `3,403`, and its maximum validation neighborhood is `163`.
- Repeated rule identities are represented as cache-hit attempts, which explains why attempt count and unique-evaluation count are distinct quantities.

Consequently, the observed `614` inner attempts establish progress through the authenticated adaptive schedule but do not establish its terminal attempt count.

## Deliberate exclusions

This preservation set intentionally excludes:

- source media, holdout media, decoded frames, pixel data, and media-derived payloads;
- bulk native cache contents, candidate output bytes, control output bytes, and the live evidence document corpus;
- user-home, run-root, cache-root, evidence-authority, and holdout absolute paths;
- process command lines containing those absolute paths;
- credentials, tokens, environment contents, and machine-specific transient files.

Only compact counts, process identifiers and signals, checkpoint identity, terminal-name observations, scheduling facts, and integrity-bound testing metadata are preserved. Repository references in this note are relative so the evidence remains reviewable without publishing machine-local paths.
