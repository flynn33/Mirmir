# P06 calibration contracts

This directory owns the preregistered P06 calibration and LUT contracts. The
files are inputs to calibration, not calibration results. Their status fields
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

`locked-compiler-input-v1.template.json` is deliberately non-consumable: its
angle-bracket placeholders fail the strict locked-input schema. The selection
stage must replace every placeholder, recompute the penalty table, compute the
canonical self-hash, and validate the result before either compiler may read it.

Run both test runners before executing calibration. Some evidence/provider tests
use pytest-style functions and are intentionally outside unittest discovery.

```sh
python3 -m unittest discover -s validation/calibration_v2/tests -p 'test_*.py'
python3 -m pytest validation/calibration_v2/tests
```

`tools/run_p06_production_calibration.py` is the supported normal-mode entry
point. It assembles the native Swift adapter, product HEVC writer, locked
analytic fixtures, formula-derived evidence provider, and persistent
content-addressed evidence store. It accepts no analytic test provider or
injected measurement resolver. After development tuning and validation
selection, the same command atomically publishes the mapping, operator bank,
quality and metric policies, independent byte-identical LUTs, configuration
lock, and the 17-artifact release bundle.

The command requires five pre-release evidence IDs in this exact order:

1. `python_calibration_full_suite`
2. `xcode_native_integration`
3. `xcode_release_runtime`
4. `swiftlint`
5. `release_lock_unit_suite`

Each path must be the matching root JSON returned by
`tools/run_g06_verification.py`, and all five paths must share that verifier run
root. Release publication revalidates the schema, ordinal, passing status,
no-holdout flag, self-hash, verifier-source/schema hashes, exact group command
contract, independently parsed test counts and diagnostics, command/log
closure, and every declared file or directory-tree digest. Release build and
runtime evidence is accepted only with zero warnings and zero errors. It then
copies each JSON and its declared artifacts to
`test-evidence/<evidence-id>/` without changing the relative artifact IDs. The
release evidence closure hashes each resulting evidence directory as a whole,
so the copied JSON, logs, products, summaries, and `.xcresult` contents remain
one transitive release-local binding.

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

A passing verifier directory is provisional until its enclosing evidence
wrapper publishes `artifact-manifest.json`, recursively freezes the complete
run tree, and reopens the same manifest and tree snapshot. The manifest belongs
in the wrapper, not the verifier run root, because P06 requires exactly the five
top-level G06 evidence JSON files in that run root.

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

It also requires preserved failure evidence containing
`p00_pinned_lanczos_postcommit_handler`. The release evidence closure binds
those records, the complete calibration run tree, the selected controls, both
compiler implementations, and every configuration artifact using the same
digest modes enforced by the one-time holdout guard. It also tree-hashes the
external open-split, content-addressed evaluation, native-cache,
production-writer, dispatch-measurement, and canonical calibration-run stores
so referenced proof hashes remain independently recoverable and can be
revalidated before P07. P06 reads
development and validation pixels only; it does not accept or open a holdout
payload path. The corpus-lock bundle binds the sampling plan's file/self hashes
and its pre-open `target_pixel_hashes_known_before_p07=false` state.

## P07 locked holdout transaction

`tools/run_p07_locked_holdout.py` is the single supported P07 entry point. It
must be invoked only after the final P06 release and all six support roots are
frozen. The exact support IDs are `open_split`, `calibration_evidence`,
`native_cache`, `production_writer`, `dispatch_measurement`, and
`calibration_run`; the last path is the canonical calibration output root that
directly contains the locked run directory.

Before guard intent, the command reopens every direct preregistered input,
performs support-aware P06 release validation, independently recompiles both
released LUT routes, builds the Swift extraction loader twice, requires
byte-identical executables, runs its deterministic media-free self-test twice,
and independently reproduces all 14 analytic fixtures. The P07 cache must be a
fresh, empty directory outside the repository, holdout, release, support,
ledger, and anchor roots. The output directory and temporary publication root
must also remain outside those protected trees; a dedicated P07 sibling under
an artifact parent is allowed.

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
