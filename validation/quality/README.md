# Mirmir quality validation

This directory contains the local quality harness used to verify Mirmir's media pipeline before implementation work advances beyond G04. It is not linked into the application target. Automated tests use generated fixtures; the production development run reads only the locked development and validation evidence and leaves holdout media sealed.

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
- recursive binding of the complete quality-harness implementation file set;
- fail-closed holdout authorization with 13 required hashes, a separately rooted user-immutable access receipt, and pre/post loader revalidation;
- interrupted-run preservation, checkpoint reproduction, recursive semantic verification, a self-hashed artifact manifest, and immutable atomic publication.

## Requirements

- macOS
- Python 3.9 or newer
- NumPy and jsonschema
- Xcode with AVFoundation, CoreMedia, CoreVideo, CryptoKit, and VideoToolbox

The verified Python packages are recorded in `requirements-lock.txt`.

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

Before publication, the harness reopens and cross-validates every source lock, payload, writer report, decoded payload, result document, checkpoint, bootstrap record, and preserved input. It atomically replaces every artifact pathname with a new owner-read-only inode, makes that inode user-immutable, hashes the detached tree, publishes the manifest through the same detached-inode path, makes every directory nonwritable, atomically renames the run directory, and marks the published directories user-immutable. A descriptor opened against an older inode cannot change the published pathname. A failed finalization is thawed only for preservation under a distinct failed-run name.

## Holdout boundary

The holdout loader remains closed unless the configuration lock is schema-valid and every required hash matches its current bound artifact. The quality-harness hash uses a recursive manifest covering the product settings type, all harness Python sources, all Python and Swift tools, all schemas, and the reference implementation scripts. Nested source changes are checked both before and after loader execution.

The access receipt is protected by the macOS user-immutable flag and stored outside the ledger root. Its stated boundary is cooperating processes. Deliberate owner or administrator flag clearing, direct media access, code bypass, and filesystem rollback are outside this mechanism's scope. The automated suite never opens holdout media or evaluation results.

## Current gate state

The implementation and remediation tests are present, but G04 is not represented as passed until the final production run, Xcode regressions, attribution scan, manifest audit, and gate report all complete against the same locked bytes. Synthetic development output is diagnostic only and is not product-quality or holdout evidence.
