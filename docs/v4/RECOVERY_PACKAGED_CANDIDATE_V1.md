# Recovery qualification packaged-candidate binding

The deterministic-v4 recovery lane has two deliberately separate producers:

- a Release-configured XCTest harness injects faults at internal durable-state
  boundaries and captures recovery semantics; and
- the release archive verifier independently proves the exact sealed
  application package, its clean committed-source build attestation, P06
  runtime, Release configuration, signatures, source tree, and universal
  architectures.

The fault-injection XCTest host is evidence instrumentation only. It is built
from the exact candidate source revision and source-tree identity, with the
locked capture source appended in the ephemeral workspace. It is not the
archived executable, and the report says so explicitly in
`capture.execution`. The recovery scenarios therefore prove the candidate
source's recovery behavior; they do not claim to have run inside the package.

Before appending that capture source, the runner exports the candidate through
the archive-provenance verifier. Git replacement objects and ambient Git
configuration are disabled, the tar umask is fixed, and every exported file's
bytes and executable mode must match both the committed-source manifest and a
fresh manifest of the extracted directory. Attributes such as `export-subst`
or `export-ignore` therefore invalidate the export instead of silently changing
the supposedly source-bound XCTest host.

The host's `ENABLE_TESTABILITY=YES` product is never accepted as the application
package. The recovery report is release-eligible only when the separately
required archive passes the same hardened provenance and attestation verifier
used by packaged quality, performance, and parity evidence. An archive
attestation is accepted only when both its captured build settings and command
contain the exact locked value `ENABLE_TESTABILITY=NO`, with exactly one command
assignment. Missing, case-variant, duplicate, or contradictory assignments fail
closed.

## Capture command

The application archive is mandatory. The runtime and xcconfig supplied by the
release workflow must be the committed release inputs used to create the
candidate identity and archive attestation.

```sh
script/v4/run_recovery_qualification_v4.sh \
  --output /release/evidence/recovery \
  --candidate /release/control/candidate-identity.json \
  --application-archive /release/control/Mirmir.zip \
  --release-configuration script/v4/release-candidate-v4.xcconfig
```

The runner copies the archive, normalized candidate, raw P06 manifest, Release
xcconfig, recovery tools, archive-provenance verifier, and packaged-evidence
verifier into `recovery/bindings/`. The evaluator emits canonical compact
`package-identity.json` and `MirmirV4ReleaseBuildAttestation.json` artifacts.
The recursive recovery suite manifest seals all of them.

`recovery-report.json.packagedCandidate` records:

- the full `mirmir-v4-packaged-candidate-identity-v1` object;
- exact archive and attestation SHA-256 identities;
- hashes of the normalized candidate and package-identity artifacts;
- the locked `arm64`, `x86_64` architecture set; and
- independently recomputed archive and attestation results, plus
  `packageIdentityTestabilitySubstitutionRejected` to state narrowly that the
  testable host cannot substitute for the clean package identity.

Evaluation and verification both reopen the archive. They recompute package
identity from its signatures and embedded attestation, project it back to every
candidate field, compare the staged runtime/configuration bytes, and require
canonical package and attestation artifacts. Changing any one of those files
invalidates the lane before the recovery scenario report can be accepted.

The runtime bundle must be a real directory rather than a symbolic link.
Generated package, attestation, report, and manifest artifacts are created with
exclusive no-follow opens relative to a held directory descriptor. Existing
files and symlinks are never overwritten, including when a symlink is inserted
between path validation and artifact creation.

The recovery tests exercise the production archive inspector through the
bound command-line evaluator, not only an injected verifier. A locally created,
ad-hoc-signed universal archive must pass both `evaluate` and `verify`; archive
swap, runtime/configuration mismatch, embedded-attestation tamper, and
post-evaluation bound-attestation tamper fixtures must all fail closed.

## Central M7 integration diff

The recovery lane intentionally does not modify the shared release contract or
aggregator in this change. The central integration must make these exact
additions together:

1. Add these recovery identity bindings to
   `release-qualification-contract-v1.json`:

   - `/candidate/appBundleSHA256`
   - `/identities/archiveProvenanceSHA256`
   - `/identities/packagedEvidenceSHA256`
   - `/packagedCandidate/applicationArchiveSHA256`
   - `/packagedCandidate/attestationSHA256`
   - `/packagedCandidate/candidateIdentitySHA256`
   - `/packagedCandidate/packageIdentitySHA256`

2. Extend `release_qualification_v4.py` recovery validation to:

   - admit and require the top-level `packagedCandidate` report object;
   - require `archiveProvenanceSHA256` and `packagedEvidenceSHA256` in report
     identities and match them to the recovery contract plus sealed source
     files;
   - admit the recovery contract's `packagedCandidate` policy and its
     `packageIdentity` and `releaseAttestation` artifact schemas;
   - validate the full packaged identity against the aggregate candidate,
     including exactly `arm64` and `x86_64` CodeDirectories;
   - reopen the bound canonical candidate, package-identity, attestation,
     application archive, raw runtime manifest, and Release xcconfig artifacts;
   - require the archive, attestation, candidate, and package hashes to equal
     their report pointers and require the application-archive binding paths to
     resolve to the same sealed file; and
   - require all three packaged pass booleans to be true only after those
     independent recomputations, using the unambiguous
     `packageIdentityTestabilitySubstitutionRejected` field; and
   - require `capture.execution` to say the fault-injection host is source-bound
     to the candidate and that the archived application executable was not the
     scenario producer.

3. Extend the aggregate recovery fixture with those sealed files and bindings,
   then refresh the externally pinned qualification trust root after the shared
   evaluator and contract are finalized.

Focused validation:

```sh
python3 script/v4/test_recovery_qualification_v4.py -v
zsh -n script/v4/run_recovery_qualification_v4.sh
script/v4/run_recovery_qualification_v4.sh --compile-only
```

The Python suite currently contains 32 recovery tests, including five
production-verifier CLI integration cases and the artifact-write/runtime-link
race regressions, plus verified-source export success and Git-attribute
substitution/omission rejection.
