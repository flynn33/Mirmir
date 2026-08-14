# Deterministic engine v4 release-qualification evidence

`script/v4/release_qualification_v4.py` is the final fail-closed M7 evidence
aggregator. It does not run the underlying qualification suites and it cannot
turn an incomplete or failed suite into a release pass. It consumes the sealed
reports produced by those suites and proves that they all describe the same
candidate.

Before importing a replay evaluator, M7 requires an external trust-root hash
supplied by the release operator or CI control plane. The trust root binds the
final evaluator itself, the release contract, the support/parity/P05/quality
replay modules, and the exhaustive evidence-role-to-handler dispatch table.
The expected trust-root SHA-256 is deliberately not read from the candidate,
repository, or evidence suite. A mutated evaluator or helper therefore fails
before its Python code can execute, even if an attacker reseals the evidence.

The candidate index follows
`script/v4/release-qualification-evidence-schema-v1.json`. Its candidate record
binds the source commit and tree, semantic P06 manifest identity, raw manifest
file, runtime artifact set, Release build configuration, notarized application
archive, bundle identifier, and product version/build. The semantic and raw
manifest identities are intentionally distinct: the former uses the ASH P06
domain-separated identity procedure, while the latter is the SHA-256 of the
manifest bytes supplied as evidence. Every evidence role is required exactly
once, carries its own locked test-contract hash, and names a sealed artifact
manifest. Missing, duplicate, unexpected, stale, path-escaping, symlinked,
size-mismatched, or hash-mismatched evidence is rejected before release gates
are evaluated.

Each evidence entry also supplies `identityBindings`. A binding contains a JSON
pointer into the report and a file identity. The aggregator hashes that file
and requires the report value, binding value, and computed value to agree. The
quality role binds its metric tool, capture source, corpus manifest, and quality
contract; its P06 semantic identity is recomputed directly. M7 invokes the
quality verifier over the nested recursive seal, validates the frozen P05
source/capture identities, and recomputes every per-clip component from the raw
reference, P05, candidate, and ablation planes before accepting any aggregate.
The performance role additionally binds both source-identity records and both
recursive capture manifests. The parity role binds its release-locked v2 contract, capture,
evaluator, and runner sources. It requires the evaluator-owned 28-label
coverage set, replays the nested recursive manifest, and independently invokes
the locked parity evaluator over both raw captures. Candidate-oriented roles
bind the raw P06 manifest and exact Release configuration, and
application-oriented roles also bind the notarized archive.
This prevents an otherwise valid report from a prior candidate or qualification
toolchain from being reused.

The notarized-smoke role additionally binds the release-locked lane contract,
shipping-app observer source, evaluator, runner, raw two-process capture,
application executable, pre-staple submitted archive, tool manifest, and nested
replay receipt. The aggregator resolves the lane's suite-relative artifacts
inside its recursive seal, independently replays every command-record and
action-transcript relationship, and rejects a weakened signing, entitlement,
observer, or recovery contract even when report pass booleans remain true.

The eight normative roles are:

1. locked natural-corpus quality with a production P06 runtime;
2. same-scope Release performance with raw paired samples and confidence
   intervals;
3. byte-exact CPU/Metal visible-plane, recursive semantic, checkpoint, resume,
   cross-process, and real execution-schedule parity;
4. format, geometry, track, and metadata preservation;
5. pause/resume, restart, crash, corruption, bookmark, and orphan recovery;
6. two clean P06 builds with byte-identical artifact sets;
7. the declared reference and supported machine matrix; and
8. notarized and stapled application smoke evidence.

Construct the reviewed tool manifest and record the printed SHA-256 in the
external release control plane:

```sh
python3 script/v4/release_qualification_trust_v4.py \
  --contract script/v4/release-qualification-contract-v1.json \
  --output /release-control/release-qualification-trust-root.json
```

Run an evaluation with that independently pinned hash:

```sh
python3 script/v4/release_qualification_v4.py evaluate \
  --candidate /path/to/release-candidate-evidence.json \
  --evidence-root /path/to/evidence \
  --trust-root /release-control/release-qualification-trust-root.json \
  --trust-root-sha256 "$PINNED_RELEASE_TRUST_ROOT_SHA256" \
  --output /path/to/release-qualification-report.json
```

Then reproduce the decision from the sealed inputs with:

```sh
python3 script/v4/release_qualification_v4.py verify \
  --candidate /path/to/release-candidate-evidence.json \
  --evidence-root /path/to/evidence \
  --trust-root /release-control/release-qualification-trust-root.json \
  --trust-root-sha256 "$PINNED_RELEASE_TRUST_ROOT_SHA256" \
  --report /path/to/release-qualification-report.json
```

The aggregator does not trust pass booleans or precomputed summaries. It
replays quality raw planes before recomputing cohorts and bootstrap bounds,
paired performance statistics, artifact-set identities, preservation and
recovery accounting, parity coverage, P06 clean-build reproduction, and
support-matrix completeness. Every notarized
smoke action requires its own sealed external attestation and command transcript;
a generic or self-authored placeholder cannot qualify a release.

The output is deterministic and contains only recomputed identities and gate
summaries. `verify` reevaluates every input and requires byte-equivalent
canonical JSON. There is no waiver input: a waiver cannot change quality,
processing-time, determinism, preservation, recovery, or P06 qualification.
