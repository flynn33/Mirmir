# Deterministic v4 release-evidence index assembly

`script/v4/assemble_release_evidence_index_v4.py` is the production boundary
between the eight independently captured qualification lanes and the final M7
aggregator. It constructs `mirmir-ash-v4-release-candidate-evidence-v1` from
the evidence bytes themselves. Operators do not author report descriptors,
seal descriptors, identity-binding paths, hashes, byte counts, evidence order,
or waivers by hand.

The assembler does not run a lane or decide whether a lane passed. It proves
that exactly one report for each contract role is present, recursively sealed,
and tied to the same inner candidate. The existing release aggregator remains
the independent semantic verifier and release decision maker.

## Closed input layout

Prepare an empty evidence root containing only the eight suite trees. Keep the
inner `candidate-identity.json`, release contract, external trust root, and
eventual qualification report outside this root. Directory names are not
interpreted; every root is assigned explicitly with `--suite ROLE=ROOT`.

The required roles, in canonical output order, are:

1. `quality`
2. `same_scope_performance`
3. `cpu_metal_parity`
4. `media_preservation`
5. `recovery`
6. `p06_reproduction`
7. `support_matrix`
8. `notarized_smoke`

Each suite must contain exactly one JSON report whose `schemaVersion` matches
the role in `release-qualification-contract-v1.json`. Exactly one top-level
`artifact-manifest.json` or `sealed-manifest.json` must recursively close over
every other regular file in that suite, including the report. Declared
recovery, media-preservation, and notarized-smoke artifact-set identities are
independently recomputed with each producer's release-locked algorithm; a
notarized-smoke artifact count is also checked.

## Assembly

```sh
EVIDENCE=/release/evidence/v4-rc1
CANDIDATE=/release/control/v4-rc1/candidate-identity.json

python3 script/v4/assemble_release_evidence_index_v4.py \
  --candidate "$CANDIDATE" \
  --evidence-root "$EVIDENCE" \
  --contract script/v4/release-qualification-contract-v1.json \
  --suite quality="$EVIDENCE/quality" \
  --suite same_scope_performance="$EVIDENCE/same_scope_performance" \
  --suite cpu_metal_parity="$EVIDENCE/cpu_metal_parity" \
  --suite media_preservation="$EVIDENCE/media_preservation" \
  --suite recovery="$EVIDENCE/recovery" \
  --suite p06_reproduction="$EVIDENCE/p06_reproduction" \
  --suite support_matrix="$EVIDENCE/support_matrix" \
  --suite notarized_smoke="$EVIDENCE/notarized_smoke" \
  --output "$EVIDENCE/release-candidate-evidence.json"
```

The output must be a new direct child of the evidence root. The assembler
refuses to overwrite it and prints its SHA-256 after an atomic write. Record
that identity in the release record before aggregation.

The JSON is canonical UTF-8: keys are sorted, separators contain no optional
whitespace, role and binding order are contract-defined, non-finite numbers
are forbidden, and the file ends with one newline. `waivers` is always `[]`;
there is no CLI input that can populate it.

## Fail-closed checks

Assembly stops without publishing an index when it observes any of the
following:

- a missing, duplicate, or unexpected role, report, manifest entry, binding,
  or candidate field;
- a symlink, hard link, special file, overlapping suite root, path escape, or
  file outside the eight suite trees;
- an unsafe or noncanonical manifest path, incomplete recursive seal, stale
  byte count, stale SHA-256, unsealed report, or unsealed role binding;
- a malformed or unsupported release contract, report schema mismatch,
  unresolved or invalid JSON pointer, or missing locked parity source name;
- disagreement between the inner candidate and any full candidate report,
  quality packaged-candidate identity, or performance packaged-candidate
  identity; or
- a pre-existing output or interrupted-write temporary output.

Identity bindings are derived from the release contract in its declared order.
The referenced report value must be a lowercase SHA-256 and must match an
actual regular file inside that role's seal. Bytes from a different lane cannot
stand in for a missing role-local artifact. Where the aggregator locks parity
source basenames, the assembler applies the same basename constraints.

## Independent aggregation

After recording the assembler's index hash, build and externally pin the
release-qualification trust root as described in
`RELEASE_QUALIFICATION_EVIDENCE_V1.md`. Then evaluate and independently replay
the result:

```sh
python3 script/v4/release_qualification_v4.py evaluate \
  --candidate "$EVIDENCE/release-candidate-evidence.json" \
  --evidence-root "$EVIDENCE" \
  --trust-root /release/control/release-qualification-trust-root.json \
  --trust-root-sha256 "$PINNED_RELEASE_TRUST_ROOT_SHA256" \
  --output /release/control/v4-rc1/release-qualification-report.json

python3 script/v4/release_qualification_v4.py verify \
  --candidate "$EVIDENCE/release-candidate-evidence.json" \
  --evidence-root "$EVIDENCE" \
  --trust-root /release/control/release-qualification-trust-root.json \
  --trust-root-sha256 "$PINNED_RELEASE_TRUST_ROOT_SHA256" \
  --report /release/control/v4-rc1/release-qualification-report.json
```

The assembler test suite constructs all eight sealed fixtures, emits an index,
runs it through the existing aggregator twice, and exercises candidate, role,
report, seal, path, link, binding, contract, and overwrite tampering:

```sh
python3 script/v4/test_assemble_release_evidence_index_v4.py -v
```
