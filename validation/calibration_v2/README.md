# P05/P06 semantic and calibration contracts

This directory owns preregistered P05 spatial semantics and P06 calibration
and LUT contracts. The files are inputs to calibration, not calibration
results. Their status fields
must remain `preregistered_not_executed` or `preregistered_not_measured` until
the separate calibration runner creates hash-locked outputs.

The contracts establish:

- deterministic development tuning and validation selection order;
- every permitted mapping, operator, compiler, and confidence candidate;
- exact branch semantics, penalties, fixed-point arithmetic, and tie-breaks;
- a little-endian route-LUT byte layout with complete integrity coverage;
- spatial-only handling of every temporal state and context in P06;
- quality, numeric-conformance, and performance limits declared before search;
- native parity between `production_swift` and `independent_test_python`;
- a metadata-only P07 sampling plan with one exact midpoint sample and centered
  even 324x192 crop per sealed source, bound before any target pixel is read;
- a corrected schema for a future locked metric policy.

The P00 conflict record controls platform normalization. No calibration command,
quality result, holdout result, generated LUT, or pass claim belongs in this
directory during contract closure.

## Instruction conflict normalization

`contracts/instruction-conflict-normalization-v1.json` is the canonical pre-lock
resolution of six package conflicts that affect P07, P08, and P11. Consumers
must validate it against
`schemas/instruction-conflict-normalization-v1.schema.json`, require canonical
file bytes and its self-hash, bind the complete instruction-package manifest,
and bind every cited package-relative source range to the recorded complete-file
SHA-256. The contract changes no gate result, holdout state, or release
configuration; it fixes interpretation before those phases execute.

## P05 spatial-semantics preregistration

`contracts/spatial-semantics-preregistration-v2.json` freezes the unselected
structural-policy and per-plane anisotropy domains before implementation or
quality measurement. Its deterministic derived lock is checked in at
`locks/spatial-policy-admissibility-manifest.json`. The lock is a calibration
input, not a per-run result or a G05 pass claim; a G05 evidence wrapper must
copy and bind it separately.

Verify the checked-in lock without writing:

```sh
/usr/bin/env PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$PWD" /usr/bin/python3 \
  validation/calibration_v2/tools/build_spatial_policy_admissibility_v2.py \
  verify \
  --repository-root "$PWD" \
  --manifest \
    validation/calibration_v2/locks/spatial-policy-admissibility-manifest.json
```

Prove deterministic regeneration with a fresh exclusive output:

```sh
temporary_root="$(cd "$(mktemp -d)" && pwd -P)"
/usr/bin/env PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$PWD" /usr/bin/python3 \
  validation/calibration_v2/tools/build_spatial_policy_admissibility_v2.py \
  build \
  --repository-root "$PWD" \
  --output "$temporary_root/spatial-policy-admissibility-manifest.json"
cmp \
  validation/calibration_v2/locks/spatial-policy-admissibility-manifest.json \
  "$temporary_root/spatial-policy-admissibility-manifest.json"
```

`locked-compiler-input-v1.template.json` is deliberately non-consumable: its
angle-bracket placeholders fail the strict locked-input schema. The selection
stage must replace every placeholder, recompute the penalty table, compute the
canonical self-hash, and validate the result before either compiler may read it.

`locked-compiler-input-v2.template.json` is the equally non-consumable sibling
for plane-aware format 1.2. Schema 2 preserves the six schema-1 hash bindings
and every legacy non-anisotropy tunable at its existing shared scope. Each route
adds one admissible spatial-policy ID and one anisotropy-mode ordinal per plane;
the two coordinate policies and route analysis-grid step retain their existing
scope. The mode ordinal is the sole compiler-input authority and maps through
the plane-aware preregistration to its exact mode ID, Q12 strength, and
`use_anisotropy` value. The all-isotropic four-plane vector is invalid.

Schema 2 contains no confidence value, format selector, default, or winner.
Version dispatch supplies format 1.2 and its confidence ABI marker; dynamic
chroma confidence remains runtime sidecar data and is not stored in a LUT. No
consumable schema-2 input may be generated from this preregistration until the
versioned joint-vector plan has been implemented and a fresh formal
development/validation selection has completed. `contracts/calibration-plan-v2.json`
now binds the plane-aware preregistration through the unchanged `calibration_plan_sha256` field,
while repository contracts remain bound by
quality-manifest and gate evidence outside the six binary-header digests.

## Plane-aware joint calibration plan

`contracts/calibration-plan-v2.json`, validated by
`schemas/calibration-plan-v2.schema.json`, is a hash-bound overlay on the exact
schema-1 plan. It preserves all 37 nonstructural search coordinates and replaces
the four independently searched route-plane coordinate policies plus global
anisotropy strength with one atomic ten-factor structural unit. Its reference
derivation is `reference/calibration_plan_v2.py`.

The structural domain is a deterministic 256-row GF(16) mixed-level covering
array. Every route-policy pair occurs exactly once, every one- and two-factor
combination is covered, all 16 complete coordinate vectors occur, and no row is
all-isotropic. The design contains 226 of the 1,295 admissible complete mode vectors
and makes no exhaustive claim for interactions of strength three or
greater. Formal results may identify only the best feasible candidate among
these 256 preregistered atoms, never an optimum over all 5,304,320 admissible
complete structural configurations.

Plan v2 separates 38 logical search units from 48 physical candidate fields.
Each sweep evaluates all 256 complete structural rows before the 37 inherited
scalar coordinates; eight full sweeps contain at most 3,288 attempts and there
is no pre-sweep structural default. The contract alone does not authorize
execution. Versioned runner, compiler/runtime, ledger, cache-budget, selection,
and release evidence paths plus fresh current-source G04-G06 evidence remain
mandatory before a consumable schema-2 compiler input can exist.

## Shared-bank configuration identity V2

`contracts/shared-bank-configuration-identity-v2.json`, validated by
`schemas/shared-bank-configuration-identity-v2.schema.json`, freezes the
standalone schema-2 bank digest before any V2 cache or evidence writer uses it.
The SHA-256 preimage is compact canonical JSON containing the exact plan domain
separator and 23 ordered field-name/value pairs from an exactly materialized
48-field candidate. Field names enter the digest; the calibration-plan file
hash does not, because candidate cache identity binds the plan separately.
Changing a bank field name, order, meaning, structural catalog, or semantic
authority requires a new identity version and domain separator. This boundary
also freezes the exact candidate-field set relation to the bound schema-2
compiler input: 19 shared fields, four bank-only fields, and 15 compiler-only
fields. Compiler-derived constants remain outside the compiler candidate set.
The contract does not select or evaluate a candidate and does not alter the
live V1 run.

## Plane-aware LUT preregistration

`contracts/plane-aware-lut-preregistration-v1.json`, validated by
`schemas/plane-aware-lut-preregistration-v1.schema.json`, is the sole design
binding for the future plane-aware compiler and spatial LUT format 1.2. It
freezes sibling V3 version dispatch, plane-major luma/chroma entries, one
admissible policy per route, one mode and coordinate policy per route-plane,
plane-local source exactness, exact but inert runtime chroma-confidence
transport, and spatial-only mirroring of all temporal contexts through G07.
It selects no policy, mode, coordinate vector, or anisotropy default and makes
no gate claim. After G07, the complete spatial LUT bytes and SHA-256 are
immutable; P10 must use a separately preregistered temporal overlay that binds
the exact spatial LUT SHA-256.

## Plane-aware compiler contract V2

`contracts/compiler-contract-v2.json`, validated by
`schemas/compiler-contract-v2.schema.json`, freezes the future format-1.2
compiler boundary without claiming that the current format-1.1 Swift or Python
implementation satisfies it. The contract adds plane-major
route/plane/phase/context/state indexing, plane-local source-exact semantics,
joint route-plane coordinate and anisotropy-mode selection, and the exact V3
header extension. It preserves the eleven byte-semantic V1 compiler sections,
keeps temporal contexts spatially mirrored through G07, and requires downstream
Swift production and independent conformance implementations before any LUT
bytes can become release evidence.

## Candidate evidence and comparator budget V2

`contracts/candidate-evidence-policy-v2.json`, validated by
`schemas/candidate-evidence-policy-v2.schema.json`, freezes the 48-field
candidate identity, 23-field shared-bank identity, split-aware cache tuple,
3,288-attempt development ceiling, 374-candidate validation neighborhood,
typed failure coverage, Pareto dimensions, and final canonical-byte tie-break.
It also names every versioned evidence sibling and the non-colliding release
schema required before execution. Policy version 2.0.1 authenticates the V2
compiler contract as a fifth evidence authority. The frozen V1 route counts
4,096 and 9,216 remain format-1.1 historical per-plane values only; current
format-1.2 evidence binds two planes and exact serialized route totals of 8,192
and 18,432, with 663,552 and 1,492,992 offline leaf evaluations respectively.

The policy binds `contracts/baseline-ablation-budget-v2.json` and
`schemas/baseline-ablation-budget-v2.schema.json`. That overlay preserves the
V1 non-ASH selector rule family, 27-coordinate order, seven-value domains, and
selection rules while extending the maximum from eight to eighteen complete
sweeps. Its 3,403-attempt ceiling is the smallest whole-sweep ceiling that is
not below the V2 full-ASH ceiling of 3,288. These contracts perform no
candidate evaluation, validation access, holdout access, selection, compiler
execution, or gate decision.

`baseline_ablation_budget_v2.py` authenticates the overlay bytes, its schema,
all seven authority payloads, and the exact five-field materialization before
exposing an immutable V2 execution profile. `non_ash_selector_v2.py` is the
data-free selector core for that profile. It preserves the V1 canonical
sorted-key rule-object hash and tie-break, records the initial attempt and each
ordered coordinate/value scan including cache hits, distinguishes convergence
from an eighteenth-sweep change, and emits no terminal rule on exhaustion or
abort. Every evaluation and replay is bound to one shared-bank configuration,
degradation policy, calibration-plan identity, and cached 16-operator output
manifest. Cache hits require a content-addressed evidence reopener, and
evidence-integrity failures abort.

Validation evaluation is structurally unavailable until the core has replayed
a complete converged development trace, reopened every unique development
evaluation, and proved development evidence for the exact terminal-plus-one-
coordinate neighborhood of 163 rules. The four `non-ash-*-v2` schemas freeze
the attempt failure, development ledger, neighbor manifest, and two-stage
selection artifact surfaces. Schema validation is only the structural layer:
publication and reopening must also invoke semantic replay to prove ordinal
arithmetic, the previous-record hash chain, rule hashes, exact neighbor order,
one-coordinate differences, and complete validation outcome coverage.
`non_ash_selector_artifacts_v2.py` is that persistence boundary. It
authenticates the four schemas and their authority files, snapshots caller
state before callbacks, requires content-addressed predecessor references,
reopens every development cache hit and scored validation evaluation, follows
typed-failure and external-sibling byte references, and replays the complete
dependency chain before publication.

The attempt-failure and selection schema surfaces are patch version `2.0.2`;
the attempt ledger and validation-neighbor manifest are patch version `2.0.1`.
Their V2 artifact and selector identities are unchanged. The migration records
the compiler-contract authority in addition to the earlier portable-path and
validation-evaluation content-address repairs. Producers using an earlier
surface or the former four-authority map are rejected.

The eight full-ASH V2 evidence schemas named by the candidate policy now bind
candidate evaluations, immutable attempts, the run ledger, validation
admission, final selection, typed run failure, evidence closure, and the
non-colliding P06 release bundle V3. The seven V2 surfaces are patch version
`2.0.1`, and the release-bundle V3 surface is patch version `3.0.1`. Their
attempt surface mirrors the pure V2
scheduler, including its all-zero genesis predecessor, exact 48-field physical
candidate, split-aware cache tuple, evaluation semantic hash, and mutually
exclusive content-addressed evaluation or failure reference.

`calibration_persistence_v2.py` authenticates the candidate, attempt, run, and
failure schema bytes plus the six authority triples before opening an artifact
root. It persists canonical one-LF candidate evaluations and typed failures by
content address, reopens the exact G04-G06 source bytes, recomputes the complete
candidate-evidence digest, and replays every attempt before accepting a run
ledger. A run ledger accounts separately for scored evaluations and typed
evaluator failures, requires those outcome identities to be disjoint, and
reopens its manifest, validation admission, controls, candidate artifacts, and
terminal failure. Relative evidence reads are confined to the pinned artifact
root and reject symlinks, traversal, control characters, replacement, and
binding mismatch.

`calibration_selection_persistence_v2.py` derives the validation admission by
replaying the exact development chain, deriving the 374-candidate terminal
neighborhood, and reopening evidence for every constraint-valid member. It
publishes validation evidence only
after the immutable admission and its dependency closure reopen, requires one
scored result or one candidate-bound typed failure for every admitted identity,
and replays the declared Pareto dimensions and canonical tie-break. A selected
artifact is success-only. The separate terminal path requires complete
infeasible-or-failed validation coverage and exact attempt-ledger, run-trace,
and artifact-manifest bindings.

The authenticated candidate policies do not enumerate persisted `check_id`
strings. The schema and persistence boundary therefore enforces nonempty,
unique checks, exact feasible/infeasible status relations, and no failed check
on a feasible result without inventing an additional authority. The production
evaluator remains responsible for independently recomputing every policy
predicate and publishing the compiler, LUT, runtime, control, and source
evidence that those checks identify. These schema and persistence layers do not
authorize production execution or claim that a persisted P06 V2 evidence
family exists.

## Preserved V1 terminal failure analysis

`analysis/ash-failure-patterns/evidence/p06-v1-terminal-failure-analysis-receipt-v1.json`
binds the additive terminal replay, the earlier bounded predecessor, the
1,009-record development ledger, and the complete 818-file failed-run tree.
Its claims are deliberately limited: the V1 run ended without a feasible
terminal vector; no winner, V2 fix, root cause, G06 result, or release is
claimed. `tools/verify_p06_v1_terminal_failure_analysis.py` verifies the
tracked receipt and analyses by default. Supplying `--failed-root` explicitly
adds a complete tree, ledger, evaluation, control-selection, and recomputed
finding verification of the preserved development-only archive.

Run both test runners before executing calibration. Some evidence/provider tests
use pytest-style functions and are intentionally outside unittest discovery.

```sh
python3 -m unittest discover -s validation/calibration_v2/tests -p 'test_*.py'
python3 -m pytest validation/calibration_v2/tests
```

## P06 V2 production and V3 release

`tools/run_p06_production_calibration_v2.py` is the sole production P06 entry
point. The similarly named `run_p06_production_calibration.py` file is retained
only for historical V1 preopen-anchor diagnostics: it has no calibration
factory or executor, returns a non-authorizing status, and cannot publish a
release.

The V2 command requires one clean Git HEAD and the finalized G04, G05, and G06
roots. It freshly reopens their semantic contracts, requires each result to
name the same current commit with `working_tree_clean=true` and
`holdout_accessed=false`, hashes each complete gate tree, and writes the three
canonical receipts in exact G04, G05, G06 order under the calibration run. A
dirty tree, commit drift, semantic mismatch, changed receipt, or changed gate
tree aborts the run.

One preopen operation creates two input views. The production-native view
replaces only the calibration plan and compiler contract with their
authenticated schema-2 forms; the inherited evaluation view retains the
existing quality and corpus authorities. Candidate reconstruction and
measurement are executed by the concrete Apple-native Swift adapter and product
writer. Python owns deterministic search scheduling, strict evidence parsing,
content addressing, selection replay, transaction control, and tests; it is
not a product-runtime upscaler and no Python runtime ships in Mirmir.

After validation selection, the command uses the hardened atomic transaction
shell to publish only release bundle schema `3.0.1`. The selected candidate's
mapping, operator bank, compiler input, and two LUT files are copied from their
content-addressed evaluation as exact bytes. Their internal status remains
`calibration_candidate`; the enclosing selection, evidence closure,
configuration lock, and release bundle provide authority. Rewriting those
candidate bytes to embed post-selection status or hashes is forbidden.

The V3 manifest contains exactly these 23 ordered roles:

1. `calibration_selection`
2. `selected_evaluation`
3. `calibration_run_ledger`
4. `validation_candidate_development_evidence`
5. `calibration_attempt_ledger`
6. `non_ash_development_attempt_ledger`
7. `non_ash_development_selection`
8. `non_ash_validation_neighbor_manifest`
9. `non_ash_validation_selection`
10. `baseline_ablation_budget_v2`
11. `live_holdout_preopen_verification`
12. `locked_mapping`
13. `locked_operator_bank`
14. `locked_quality_policy`
15. `locked_metric_policy`
16. `locked_compiler_input_v2`
17. `direct2x_lut`
18. `direct3over2_lut`
19. `native_parity_manifest`
20. `lut_manifest`
21. `configuration_lock`
22. `evidence_closure`
23. `artifact_manifest`

Validation is role-semantic, not merely a manifest hash check. It replays the
attempt chain and selection, validates the non-ASH predecessor chain, reopens
control authorization dependencies, authenticates all schemas and self-hashes,
recompiles both route LUTs independently, cross-binds native parity and the
LUT manifest, and verifies the artifact-tree closure. The
`configuration-lock-v2.json` validator additionally reopens an exact ordered
nine-file set: mapping, operator bank, quality policy, metric policy, compiler
input, both LUTs, native parity manifest, and LUT manifest. It requires
`candidate_bytes_rewritten_after_selection=false` and
`holdout_accessed=false`.

The G06 verifier also requires a finalized native-runtime evidence root under
repository `Artifacts/ASH` and the expected file SHA-256 of that root's
`artifact-manifest.json`. Before any benchmark command runs, it descriptor-
reopens the complete manifest closure, proves every file and directory is
non-writable and user-immutable, verifies the clean repository identity and
no-holdout provenance, and derives the benchmark binding from the manifest. It
copies the complete verified runtime bundle into the G06 transaction, binds the
copy as tree evidence, and records the benchmark opt-in and copied benchmark
path in the pytest command arguments. The Python group runs unittest discovery,
the complete pytest calibration suite, and the exact native-benchmark pytest
node ID as three separately parsed commands. Each command clears
`PYTHONOPTIMIZE`; pytest also disables plugin autoload, ancestor conftests, and
the cache provider. The full suite therefore retains its zero-skip and
zero-deselection requirement without depending on ambient shell variables.

A passing G06 verifier directory is provisional until its enclosing evidence
wrapper publishes `artifact-manifest.json`, recursively freezes the complete
run tree, and reopens the same manifest and tree snapshot. The manifest belongs
in the wrapper, not the verifier run root. G06 itself publishes the five
ordered evidence roles `python_calibration_full_suite`,
`xcode_native_integration`, `xcode_release_runtime`, `swiftlint`, and
`release_lock_unit_suite`; the fresh G06 semantic reopener authenticates that
closure before P06 stages its G06 receipt.

`tools/finalize_evidence_wrapper.py` performs that publication from the exact
hidden sibling `.<final-name>.partial`. Its version-2 manifest binds every
regular file, every non-root directory path (including empty directories), and
per-file producer, command, platform, machine, and gate provenance. A durable,
identity-bound transaction marker is written before the partial becomes
non-retryable. The marker is enclosed by the wrapper manifest, while its sibling
recovery locator is removed only after a durable completion receipt exists and
the final root has passed a frozen descriptor-relative reopen. A later
invocation either completes receipt cleanup or preserves an interrupted owned
root as immutable failure evidence; source substitutions are never accepted as
successful publication and foreign collisions are retained under neutral
tokenized sibling names.

Invoke the verifier with the finalized runtime root and the SHA-256 of its
manifest file (the raw file digest, not the manifest's internal self-hash):

```sh
/usr/bin/python3 validation/calibration_v2/tools/run_g06_verification.py \
  --repository-root /absolute/path/to/Mirmir \
  --output-root /absolute/path/to/Mirmir/Artifacts/ASH/<run>/g06 \
  --run-id <unique-g06-run-id> \
  --native-runtime-evidence-root \
    /absolute/path/to/Mirmir/Artifacts/ASH/<run>/runtime/<finalized-run> \
  --expected-native-runtime-manifest-file-sha256 <lowercase-hex-sha256>
```

The V3 evidence closure tree-hashes six external support authorities:
`open_split`, `calibration_evidence`, `native_cache`, `production_writer`,
`dispatch_measurement`, and `calibration_run`. Full release validation requires
all six roots and transitively reopens the calibration selection. P06 reads
development and validation pixels only; it does not accept or open a holdout
payload path. The live-preopen receipt must remain `unopened`, have zero access
count, no open-intent anchor, and no pixel content. Its corpus binding is the
tracked corpus manifest self-hash, which is deliberately distinct from the
compiler's canonical corpus-lock bundle digest.

On successful V3 publication the production command performs one support-aware
export of the exact six Apple product resources: `lut-manifest-v3.json`,
`locked-compiler-input-v2.json`, `locked-mapping.json`, `direct2x.ashlut`,
`direct3over2.ashlut`, and `native-lut-parity-manifest-v3.json`. The destination
must contain exactly those files and byte-match the authenticated release.
`tools/export_p08_release_resources_v3.py` is the recovery-only entry point for
an already-authoritative V3 release. It requires explicit paths for all six
support roots, performs the same full transitive replay, publishes or
idempotently reopens only the six-file set, and never reruns P06 or creates a
second release. Its receipt records `full_support_replay_performed=true` and
`holdout_accessed=false`.

## P07 locked holdout transaction

`tools/run_p07_locked_holdout.py` is the single supported P07 entry point. It
must be invoked only after the final P06 release and all six support roots are
frozen. The exact support IDs are `open_split`, `calibration_evidence`,
`native_cache`, `production_writer`, `dispatch_measurement`, and
`calibration_run`; the last path is the canonical calibration output root that
directly contains the locked run directory.

The command also requires the original G04, G05, and G06 roots, the G05
instruction-package root and baseline commit, and the G06 execution-run name.
It reruns the authoritative gate reopeners under one unchanged clean HEAD,
rehashes the actual external trees, and requires the fresh semantic/tree
projection to equal the P06-sealed execution authority. Sealed receipt fields
without that fresh external reopening do not authorize P07.

Before guard intent, the command reopens every direct preregistered input,
performs support-aware P06 release validation, independently recompiles both
released LUT routes, builds the Swift extraction loader twice, requires
byte-identical executables, runs its deterministic media-free self-test twice,
and independently reproduces all 14 analytic fixtures. The P07 cache must be a
fresh, empty directory outside the repository, holdout, release, support,
ledger, and anchor roots. The output directory and temporary publication root
must also remain outside those protected trees; a dedicated P07 sibling under
an artifact parent is allowed.

The guard accepts only the release-manifest-bound
`configuration-lock-v2.json`. It invokes the shared P06 schema/self-hash and
descriptor-safe nine-file validator, then reopens the exact ordered V3 files
before and after loader delegation. The schema-2 path never imports the legacy
scalar `_configuration_bindings` helper and does not accept
`locked-compiler-input.json` or `lut-manifest.json` aliases. A startup failure
that occurs before the immutable holdout anchor exists is written as an
exclusive, canonical, fsynced non-opening diagnostic; foreign or changed
collision state is rejected.

Only `HoldoutAccessGuard.read_once` may mount and read the sealed payloads. The
loader requires identity orientation, monotonic presentation timestamps,
first-at-or-after exact-midpoint selection, locked BT.709 video-range 420v
metadata, and the preregistered centered even crop. Temporary NV12 crops and
all holdout-derived binary work remain in the transaction's temporary tree and
are deleted. The persistent cache is rehashed before and after evaluation and
must remain byte-for-byte unchanged.

Successful publication is JSON-only and exact: measurements, frame extraction,
complete native/cache/writer runtime evidence, exhaustive G07 spatial,
bootstrap and ablation evidence, the G07 decision, and the completed execution
receipt. The receipt binds the authoritative completed live-ledger hash chain
and the user-immutable external anchor. A G07 failure or any post-open execution
failure is preserved as non-reusable same-version evidence. Failure-archive
publication errors are surfaced explicitly rather than suppressing the primary
failure.
