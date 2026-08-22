# P06 Reproduction Qualification V2

The P06 reproduction lane admits a runtime only when two ordered, independent
clean Release invocations reproduce the shipping `ASH-P06.bundle` byte for
byte. The v2 evidence boundary closes the source-causality gap left by v1: a
claimed source manifest is no longer sufficient. The verifier reconstructs it
from the sealed candidate source bytes.

## Normative inputs

The lane binds all of the following to one candidate identity:

- the exact 40-character source commit and the candidate source-tree identity;
- the raw Release configuration and shipping P06 runtime artifact set;
- `script/v4/p06-reproduction-contract-v2.json` and every capture/evaluation
  tool identity it locks;
- the closed P06 production-source contract; and
- the release builder, production loader check, and source-identity tool.

No signing identity, notarization credential, or publication operation is used
by this lane.

## Sealed candidate source proof

Each clean build carries its own raw Git commit object,
`candidate-source.tar`, and `source-tree-listing.bin`. The verifier:

1. recomputes the Git commit object identity and requires that commit to name
   the reconstructed root tree;
2. recomputes the domain-separated candidate tree identity from the raw Git
   listing;
3. reconstructs the Git blob identity and file mode for every archived file;
4. reconstructs the Git root-tree object from those entries;
5. requires the archive's complete file and directory closure to match the
   listing and its PAX commit binding to match the candidate commit;
6. rediscovers the closed production-source inventory from the archived files;
7. applies only the three declared deployment-trust-root normalizations; and
8. recomputes the complete production-source manifest and source revision from
   the archived bytes before comparing either claim.

The raw archive hash is candidate-evidence-bound rather than release-contract
pinned. This avoids a cycle because the full source archive contains the
release contract. The production-source manifest covers only the locked
shipping Swift and Metal closure, so its exact hash and source count can be
externally pinned without a cycle.

## Build causality

Each build contains a canonical structured transcript and execution receipt.
The receipt binds the detached checkout commit and reconstructed tree object,
clean pre/post checkout states, exact builder argv and working/output roots,
builder process and interval, pinned release-builder identity, source listing
and archive, transcript, recomputed production-source manifest, and runtime
output identities.

Before each builder launch, the capture producer generates an independent
256-bit challenge and passes it through both the exact argv and a single locked
environment entry. The pinned builder rejects disagreement and emits the
challenge together with the completed runtime artifact-set, raw manifest, and
production-source-manifest identities into its structured stdout transcript.
The evaluator recomputes all four values and includes the challenge,
environment, transcript, and outputs in the causal receipt binding.

The two receipts must have distinct invocation, process, execution, working,
and output identities. They execute in contract order without overlap. The
first receipt has the zero predecessor; every later receipt names the exact
previous receipt hash. A domain-separated causal binding covers the semantic
inputs, invocation, transcript, and output. Copied receipts without rerunning
the externally pinned builder are rejected.

This is a trusted-producer execution proof, not a secret-key attestation. The
release contract externally pins the exact capture producer and builder bytes;
under that boundary, a copied receipt cannot acquire the next challenge/output
transcript without rerunning the pinned builder. An actor replacing the trusted
producer could synthesize unkeyed transcript text, so v2 does not claim
cryptographic unforgeability against a malicious evidence producer, and the
unkeyed markers do not replace operator observation of the two-process capture.

## Capture and verification

Run only after the candidate commit contains the final v2 lane and lock values:

```sh
script/v4/run_p06_reproduction_v4.sh \
  --repository /path/to/Mirmir \
  --candidate /path/to/candidate-identity.json \
  --runtime /path/to/ASH-P06.bundle \
  --release-configuration /path/to/release-candidate-v4.xcconfig \
  --contract script/v4/p06-reproduction-contract-v2.json \
  --output /private/path/to/p06-reproduction-evidence
```

The runner refuses an existing output, tool bytes that differ from the
candidate commit, a stale candidate tree, a non-release runtime, or a modified
contract. It captures two clean builds and immediately replays the sealed v2
evidence with `p06_reproduction_v4.py verify`.

Focused adversarial coverage includes fully resealed source-entry changes,
checkout-tree substitutions, copied execution receipts without a builder rerun
but with refreshed labels, descriptors, and causal hashes, failed loader
transcripts, toolchain substitution, candidate substitution, and unsealed extra
files.
