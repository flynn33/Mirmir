# Mirmir quality validation

This directory contains the offline quality harness used to verify Mirmir's
media pipeline before implementation work advances beyond G04. It is not linked
into the `Mirmir` application target, copied into `Mirmir.app`, or called by the
product runtime. The application remains native Swift/SwiftUI/AVFoundation/
Metal code. Automated harness tests use generated fixtures; a production
development run reads only locked development/open-split evidence and leaves
holdout media sealed.

The harness provides:

- canonical planar Y, Cb, and Cr storage with byte-bound frame identities;
- PSNR, SSIM, MS-SSIM, edge, ringing, thin-line, chroma-displacement, and forbidden-band alias metrics;
- a serialized analytic-fixture contract and independent metric oracle;
- deterministic spatial, codec, and motion degradation profiles;
- Left-sited Apple H.264 common-writer evidence and product-settings HEVC output evidence;
- one-container-per-case HEVC metric isolation, with multi-frame output explicitly non-metric;
- source-asset paired bootstrap with 10,000 replicates and seed `20260710`;
- an exact 6/3/3 corpus lock with source-family isolation, category minima, rights evidence, media-byte binding, canonical display geometry, and safe relative paths;
- a six-source development sample lock bound to the corpus media, frozen decode evidence, the first representative record, exact centered crop, active Y/CbCr bytes, and code-value excursion counts;
- explicit nominal video-range clamping for target-crop normalization while retaining the upstream padded-buffer decoder hash separately from the active-plane hash;
- recursive binding of the complete quality harness, P05 spatial implementation,
  runtime configuration, and deterministic spatial-evidence implementation set;
- fail-closed holdout authorization with 13 required hashes, a separately rooted user-immutable access receipt, and pre/post loader revalidation;
- interrupted-run preservation, checkpoint reproduction, recursive semantic verification, a self-hashed artifact manifest, and immutable atomic publication.

## Requirements

- macOS
- Python 3.9 or newer
- NumPy and jsonschema
- Xcode with AVFoundation, CoreMedia, CoreVideo, CryptoKit, and VideoToolbox

The verified Python packages are recorded in `requirements-lock.txt`.

Python is an evidence implementation detail, not an application dependency.
`project.yml` does not add this directory to the app target. Apple-native Swift
tools and XCTest results are invoked by the harness as external producers and
their exact outputs are hash-bound into the resulting gate closure.

## Run all tests

```bash
cd "$REPO_ROOT"
PYTHONPATH=validation/quality/src /usr/bin/python3 -m unittest discover \
  -s validation/quality/tests -v
```

## Reproduce the actual-codec fixture

The fixture selects the Apple H.264 software encoder, disables temporal prediction and frame reordering, requests all-I output, records Left chroma siting, and verifies the software and AVFoundation decode routes. MP4 byte identity across independent runs is not claimed; decoded-pixel and metadata conformance are required.

```bash
cd "$REPO_ROOT"
/usr/bin/python3 validation/quality/tools/run_actual_codec_fixture.py \
  --output-directory "$RUN_ROOT/actual-codec"
```

## Rebuild the development sample lock

`build_development_sample_lock.py` requires exact mappings for all six development assets. Supply the frozen corpus/evidence root as both `--sample-root` and `--asset-root` when those files share one root. The tool refuses to overwrite an existing lock.

The resulting lock must validate against `schemas/development-sample-lock.schema.json`. Its policy requires:

- `representative_samples[0]` with record index 0;
- decode media resolving to the exact corpus asset;
- source dimensions matching corpus presentation dimensions;
- full-frame clean aperture, square pixels, and identity orientation;
- exact centered 324x192 crop with even 4:2:0 origin;
- independently recomputed `active_planes_sha256` over Y followed by CbCr;
- recorded Y, Cb, and Cr nominal-range excursion counts; and
- clamping to the nominal video intervals before target normalization.

## Rebuild the validation sample lock

`build_validation_sample_lock.py` applies the identical byte, provenance, geometry, and nominal-range checks to exactly three validation assets. It requires exact decode/evidence-manifest mappings for the validation split, writes a lock conforming to `schemas/validation-sample-lock.schema.json`, and refuses to overwrite an existing lock.

The shared sample loader accepts only `development` and `validation`. It rejects any other split before resolving a sample, evidence, media, or asset path. Calibration code can therefore tune against the development lock and select against the validation lock without providing a holdout root to this loader.

Development samples require the complete source-format color triplet. A validation sample may instead carry the schema-bound `validation_decoded_attachment_corpus_agreement_v1` resolution only when the source triplet is entirely absent, source range is explicitly video, source chroma is Left/Left, every representative decoded buffer has identical 709 and Left/Left attachments, and the frozen corpus agrees exactly. Partial, mixed, conflicting, unnecessary, or tampered resolution evidence is rejected.

## Run the production-locked development benchmark

```bash
cd "$REPO_ROOT"
PYTHONPATH=validation/quality/src /usr/bin/python3 \
  validation/quality/tools/run_production_development_dry_run.py \
  --output-root "$RUN_ROOT" \
  --run-id "$RUN_ID" \
  --corpus-lock validation/quality/locks/corpus-lock.json \
  --asset-root "$EVIDENCE_ROOT" \
  --evidence-root "$EVIDENCE_ROOT" \
  --development-sample-lock validation/quality/locks/development-sample-lock.json \
  --sample-root "$EVIDENCE_ROOT"
```

The benchmark executes 24 development cases in both `engine_raw` and `container_decoded` domains. Two isolated H.264 common-writer runs provide route-specific low-resolution inputs. Twenty-four separate product-settings HEVC runs provide the post-encode metric inputs, one case per process and container.

## Execute and publish a fresh-current-source G04 closure

`run_g04_current_source.py` is the authoritative producer for a new G04
wrapper. It requires a clean committed checkout outside `Artifacts`, checks
the source identity before and after every command, derives the hidden partial
path from the final publication name, and delegates immutable publication to
`finalize_g04_current_source.py` only after the complete staged contract
passes.

```bash
/usr/bin/python3 validation/quality/tools/run_g04_current_source.py \
  --repository-root "$REPO_ROOT" \
  --final-root "$REPO_ROOT/Artifacts/ASH/$G04_PUBLICATION_NAME" \
  --expected-source-commit "$SOURCE_COMMIT" \
  --p00-baseline-commit "$P00_BASELINE_COMMIT" \
  --instruction-package-root "$INSTRUCTION_PACKAGE_ROOT" \
  --asset-root "$OPEN_SPLIT_ROOT" \
  --evidence-root "$OPEN_SPLIT_ROOT" \
  --sample-root "$OPEN_SPLIT_ROOT" \
  --expected-xcode-skip \
    'ASHTelemetryTests/test_productionTraceFixtureWhenExplicitlyConfigured()'
```

The command executes and binds all of the following against the same commit:

- the full serial arm64 macOS Xcode test run, coverage report, and complete
  result bundle;
- a clean arm64 Release build, result bundle, executable hash, architecture,
  signature, and hardened-runtime verification;
- the quality Python unittest suite with no skips and static compilation;
- two byte-identical rebuilds of the installed quality-harness implementation
  lock;
- the injected-failure and resumed production development dry run, including
  the artifact manifest, execution bindings, and no-holdout attestation;
- the Apple-native actual-codec fixture report and independent metric oracle;
- strict SwiftLint, instruction-package validation, the baseline-bound
  attribution scan, and `git diff --check`.

Every expected Xcode skip must be supplied by exact `nodeIdentifier`; an
unlisted skip or a listed skip that does not occur fails the run. The three
open-split roots are resolved only through the locked development contracts;
the runner has no holdout argument and does not invoke the holdout loader. A
failed producer leaves the deterministic hidden partial wrapper for diagnosis
and never publishes a passing G04 result.

Before publication, the harness reopens and cross-validates every source lock, payload, writer report, decoded payload, result document, checkpoint, bootstrap record, and preserved input. It atomically replaces every artifact pathname with a new owner-read-only inode, makes that inode user-immutable, hashes the detached tree, publishes the manifest through the same detached-inode path, makes every directory nonwritable, atomically renames the run directory, and marks the published directories user-immutable. A descriptor opened against an older inode cannot change the published pathname. A failed finalization is thawed only for preservation under a distinct failed-run name.

## Source checkpoint and downstream identity

G04 is the first gate after the clean release-closure source checkpoint. The
checkpoint must already contain the Metal runtime, exact P06 injection,
schema-2 calibration/control composition, P07/P08 contracts, project metadata,
tests, documentation, and the refreshed quality-harness lock. No tracked edit
is permitted after the checkpoint without invalidating G04 and every dependent
gate.

`run_g04_current_source.py` binds the repository commit and source-tree identity
before and after every command. Its output is valid only for that exact source;
it cannot be reused after a code, schema, Xcode project, script, test, or
documentation change that lies inside the locked source closure.

The downstream order is:

```text
fresh G04
-> fresh G05
-> native runtime correction
-> fresh G06 and immutable P06 V3 release
-> ordinary Release Mirmir.app with the exact six P06 runtime files
-> exact-release integration and native P08 pre-G07 seal
-> one authorized P07/G07 execution
-> unchanged P08 promotion and derived G08 finalization
```

At P06, `run_p06_production_calibration_v2.py` is the sole authorizing
production command. It reopens the actual G04/G05/G06 trees, runs the
Apple-native schema-2 measurement path, publishes/reopens only the V3 release,
and publishes/reopens the exact-six export and receipt. The historical
`run_p06_production_calibration.py` command is non-authorizing and exits with
status `2`. Before any later P07 holdout intent, the P07 runner independently
reopens the same external G04/G05/G06 trees under the unchanged source commit
and matches their derived semantics and tree identities to the P06 authority.

G04 has no holdout path. A G04 pass would establish only the current-source
open-split quality contract and its recorded native/product checks; it would
not authorize a calibration candidate, P06 release, holdout result, exact app,
or Metal performance gate.

## Holdout boundary

The holdout loader remains closed unless the configuration lock is schema-valid and every required hash matches its current bound artifact. The quality-harness hash uses a recursive manifest covering the product settings type, the P05 spatial implementation and configuration, the deterministic spatial-evidence generator and schemas, all harness Python sources, all Python and Swift tools, all quality schemas, and the reference implementation scripts. Nested source changes are checked both before and after loader execution.

The access receipt is protected by the macOS user-immutable flag and stored outside the ledger root. Its stated boundary is cooperating processes. Deliberate owner or administrator flag clearing, direct media access, code bypass, and filesystem rollback are outside this mechanism's scope. The automated suite never opens holdout media or evaluation results.

## Current gate state

The current-source producer and remediation tests are present. Fresh G04 for the
release-closure checkpoint is pending until the complete production command
finishes and the published wrapper reopens with every required command,
expected skip, manifest, source identity, and gate predicate satisfied. This
document intentionally does not record a predicted pass.

Synthetic development output is diagnostic only. Historical G04 evidence is
not current-source evidence, and neither source unit tests nor a successful app
build are product-quality, release-authorization, holdout, or G08 evidence.
Gate outcomes remain in their immutable `Artifacts/ASH/` publications so a pass
or failure does not require a tracked post-gate documentation change.
