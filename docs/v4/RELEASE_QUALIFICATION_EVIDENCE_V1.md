# Deterministic engine v4 release-qualification evidence

`script/v4/release_qualification_v4.py` is the final fail-closed M7 evidence
aggregator. It does not run the underlying qualification suites and it cannot
turn an incomplete or failed suite into a release pass. It consumes the sealed
reports produced by those suites and proves that they all describe the same
candidate.

Repository CI is not a substitute for that aggregator. The
`Verify deterministic v4 identities` workflow still has to load the committed
production P06 bundle with the identities declared by that bundle. It computes
the domain-separated `ash-p06-runtime-manifest-v4` SHA-256 of
`Mirmir/Resources/ASH-P06.bundle/runtime-manifest.json`, reads
`provenance.sourceRevision` and `provenance.builderSourceSHA256` from the same
manifest, and invokes `script/v4/run_p06_runtime_load_check.sh` with the bundle
path plus those three identities. The loader must verify the binding, accept
only the declared runtime ID and release status, and reject a same-length
artifact mutation. This check does not close the archived-executable or
frozen-candidate M7 gates.

Before importing a replay evaluator, M7 requires an external trust-root hash
supplied by the release operator or CI control plane. The trust root binds the
final evaluator itself, the release contract, the support/parity/P05/quality
replay modules, and the exhaustive evidence-role-to-handler dispatch table.
The expected trust-root SHA-256 is deliberately not read from the candidate,
repository, or evidence suite. A mutated evaluator or helper therefore fails
before its Python code can execute, even if an attacker reseals the evidence.

The authenticated release contract also pins the exact quality, performance,
media-preservation, P06-reproduction, and support-matrix lane contracts and
their evidence-producing source identities. Quality additionally pins the
natural corpus manifest, artifact set, population, source/license sets, the
frozen P05 baseline identity, its repaired capture runner, and deterministic
output set. Performance pins
its frozen P05 source tree and the exact 24-key path-neutral producer fact map,
its canonical map SHA-256, and its domain-separated producer identity. The map
binds the exact app/test executables, input, normalized build/test result,
recomputed compiler-control audit, and timing-neutral workload identity. Raw
timing/memory measurements, receipts, result bundles, logs, and transcript sets
remain per-run evidence and are recursively sealed and replayed rather than
externally pinned. P06 pins
its closed production-source inventory, and support pins the signing team.
These locks are checked before the aggregator derives weights, cohorts,
workload, fixture coverage, source counts, or signing constraints from a
supplied suite. Changing and resealing both a lane contract and its evidence
therefore cannot change the release standard.

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
source/capture identities and externally pinned output set, and recomputes
every per-clip component from the raw reference, P05, candidate, and ablation
planes before accepting any aggregate. The P05 capture runner first copies the
exact locked manifest and artifact inventory into its mode-0700 owned build
root, rejecting non-regular, symlinked, escaping, size-mismatched,
hash-mismatched, or byte-different inputs before the test host reads them.
The performance role additionally binds both source-identity records and both
recursive capture manifests. It invokes the locked performance evaluator to
reconstruct every sample transcript and measurement identity and to validate
the baseline build receipt, input, executables, result-bundle summary,
compiler-control audit, and normalized producer identity before recomputing
timing statistics. The parity
role binds its release-locked v2 contract, capture, evaluator, and runner
sources. It requires the evaluator-owned 34-label
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

The media role invokes its externally locked evaluator over the full raw
capture and requires byte-identical recomputed output. That evaluator is the
single semantic authority for the independent P010 luma/chroma oracle,
PQ/HLG metadata contracts, deinterlacing cadence, alpha, geometry, and track
preservation; M7 retains independent candidate, archive, seal, and structure
admission around that replay.

P06 reproduction uses the v2 source/archive boundary. The locked evaluator
reconstructs the Git commit and tree from sealed source bytes, recomputes the
production source manifest, and validates two chained build executions. Its
unkeyed challenges reject copied receipts without rerunning the externally
pinned builder; they are trusted-producer execution evidence, not a
cryptographic substitute for operator observation of two independent
processes.

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
