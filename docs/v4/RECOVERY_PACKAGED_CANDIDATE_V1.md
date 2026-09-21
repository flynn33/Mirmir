# Archived-executable recovery qualification

> This archived-executable lane is retained as optional release evidence. It is
> not an M7 requirement under the simulator-only scope adopted September 21,
> 2026.

The deterministic-v4 recovery gate accepts only evidence produced inside the
exact `Mirmir` executable extracted from the verified Release application
archive. A source-built test host, rebuilt application, helper executable, or
declared scenario result cannot substitute for that producer.

The recovery payload, report, and manifests use the v2 recovery schemas. They
remain inside the shared generic
`mirmir-v4-packaged-evidence-request-v1` / result-v1 envelope so recovery uses
the same archive, request, nonce, runtime, and process boundary as the other
packaged qualification lanes.

## Normative execution

`run_recovery_qualification_v4.sh` invokes
`packaged_candidate_evidence_v4.py capture --lane recovery` twice. Each run:

1. re-inspects the exact application archive and its embedded Release
   attestation;
2. verifies the committed source tree, P06 runtime, Release configuration,
   package identity, universal CodeDirectories, and
   `ENABLE_TESTABILITY=NO` build claim;
3. extracts the archived application into a fresh private directory;
4. launches that archived executable in a fresh process with a fresh request
   identifier and 256-bit nonce;
5. asks the packaged observer to call the production
   `RecoveryQualificationProducerV4`; and
6. seals the request, result, observer source, producer source, archive,
   executable, runtime, package, capture tree, and process identity.

`RecoveryQualificationCaptureTests.swift` is only a thin compile and smoke
wrapper around the production producer. It is never an admissible normative
producer and the recovery report cannot describe an XCTest execution.

## Locked fault matrix

All 15 scenarios are mandatory and ordered by the contract.

| Coverage | Evidence | Required outcome |
| --- | --- | --- |
| append-only event boundary | durable-state derivation | identical resumed result |
| snapshot publish boundary | durable-state derivation | identical resumed result |
| bookmark resolution and TOCTOU | contained-state derivation | explicit contained failure |
| segment commit boundary | durable-state derivation | identical resumed result |
| checkpoint publish boundary | durable-state derivation | identical resumed result |
| prepared decision boundary | durable-state derivation | identical resumed result |
| final assembly boundary | scenario media output | byte- and semantic-identical output |
| atomic output publish boundary | scenario media output | byte- and semantic-identical output |
| pause/resume | scenario media output | byte- and semantic-identical output |
| forced termination/restart | durable-state derivation | identical resumed result |
| disk full | contained-state derivation | explicit contained failure |
| corrupt journal | contained-state derivation | explicit contained failure |
| corrupt checkpoint | contained-state derivation | explicit contained failure |
| orphan partial reconciliation | durable-state derivation | identical resumed result |
| unowned artifact rejection | contained-state derivation | explicit contained failure |

Every identical-outcome scenario owns an independent uninterrupted state and a
separate post-fault recovered state. Durable scenarios serialize a narrowly
defined derivation from each state. Media scenarios preserve the actual
scenario-specific uninterrupted and resumed media plus recomputed track graph,
decoded visible pixels, presentation timeline, sample count, and duration.
Contained scenarios carry neither an uninterrupted state nor success output.

There is no shared reference output. Scenario paths are confined to that
scenario, and each artifact may be claimed exactly once.

## Causal and cross-process checks

The evaluator does not accept producer labels as proof. For each capture it
recomputes:

- the contract, request, nonce, package, source-tree, observer, producer,
  archive, executable, runtime, and process bindings;
- every raw state-file byte count and SHA-256;
- each state artifact-set tree hash and durable-state identity;
- transcript order, fault observation, reopen event, and the reopen-to-state
  binding;
- the causal-binding document and every referenced artifact identity;
- the exact locked durable derivation values;
- media byte identity and semantic-manifest identity; and
- the complete capture file set, rejecting unclaimed or missing files.

It then requires the two captures to use distinct request identifiers, request
hashes, nonces, and process identifiers while holding archive, executable,
source tree, runtime, observer, and producer identities constant. Durable
derivations and media results must be byte-identical within each scenario and
across the two processes.

The adversarial suite reseals forged generic package records before evaluation.
It covers raw durable-state mutation, cross-scenario/shared-output
substitution, derivation relabeling, transcript/state substitution,
cross-process output substitution, archived-executable claim relabeling,
process reuse, state path substitution, and unclaimed capture files. These
forgeries therefore fail the evaluator's independent recomputation rather than
only a stale outer hash.

## Capture and verification

The archive, candidate, and Release configuration are mandatory. The output
directory must be new or empty and named `recovery`.

```sh
script/v4/run_recovery_qualification_v4.sh \
  --output /release/evidence/recovery \
  --candidate /release/control/candidate-identity.json \
  --application-archive /release/control/Mirmir.zip \
  --release-configuration script/v4/release-candidate-v4.xcconfig
```

The command performs both `evaluate` and a fresh `verify` recomputation. It
emits:

- `captures/process-a/` and `captures/process-b/`, each containing its sealed
  packaged request/result/bindings and raw capture;
- `capture-artifact-manifest.json` for both raw capture trees;
- `recovery-report.json`; and
- `sealed-manifest.json`, which recursively seals the complete
  recovery role.

The contract pins the exact archive-provenance evaluator, packaged-evidence
tool, shipping observer source, production recovery source, recovery evaluator,
and runner. Any tool or source change requires pin convergence before capture.

Focused validation:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest -v \
  script/v4/test_recovery_qualification_v4.py
zsh -n script/v4/run_recovery_qualification_v4.sh
script/v4/run_recovery_qualification_v4.sh --compile-only
```

The optional release-qualification aggregator must require the v2 recovery
report and manifests, exactly
two archived-executable captures, all 15 locked scenarios, all recomputed
identity fields, and `recoveryGatePass == true`. Missing, stale, noncanonical,
rehashed-substituted, source-hosted, or independently inconsistent recovery
evidence is release-ineligible.
