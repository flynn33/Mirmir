# Release candidate provenance v1

The deterministic-v4 candidate archive is accepted only when its application,
source commit, Release configuration, and P06 runtime form one verified build.
`prepare_release_candidate_v4.py` no longer combines an arbitrary ZIP hash with
independent repository identities.

The signed claims are necessary but are not treated as proof that the compiler
read the claimed source. Candidate construction exports the declared commit
with `git archive`, verifies every exported byte and mode against a canonical
clean-source manifest, and emits its receipt beside the app in the xcarchive.
Sealing requires that exact receipt, validates it against the notarized app,
and requires a second clean build to reproduce it byte for byte. Candidate
preparation then requires a third clean build to reproduce the receipt carried
by the attestation. Git replacement objects, repository redirection, global
configuration, system attributes, and archive-umask variation are disabled by
a fixed export command and environment.

## Provenance chain

The application Info.plist contains nine build claims supplied by a generated
xcconfig overlay. The app code signature seals those claims together with the
main executable and embedded P06 resources.

`MirmirV4BuildAttestation.json` is then added as a top-level ZIP entry. Its
canonical document binds:

- the exact source commit and canonical source-tree identity;
- the committed Release xcconfig hash;
- the semantic and raw P06 manifest hashes, runtime artifact set, and source
  revision;
- the signed Info.plist and claim-set identities;
- the final executable hash and mode, the exact `arm64` + `x86_64`
  architecture contract, every slice's full CodeDirectory SHA-256, semantic
  entitlements, policy flags, and verified designated requirement;
- every non-attestation ZIP entry's path, kind, mode, size, and content hash;
- the committed sealing and verification tool set;
- the clean-source manifest, exact normalized xcodebuild command and
  environment, fixed credential-free ad-hoc signing policy, selected
  Xcode/Swift/Clang binaries and versions, macOS SDK, normalized build
  transcript, and successful build receipt.

The replayed product must have the same processed Info.plist, runtime,
signature-stripped executable SHA-256 and mode, every non-signature bundle file
and directory (including modes), code identifier, semantic entitlements on
both slices, and per-architecture signing policy flags as the candidate. The
ad-hoc-only CodeDirectory flag is normalized; hardened-runtime and other policy
flags are not. A truthy `com.apple.security.get-task-allow` on either slice is
always rejected. Identity-backed slices must have one designated requirement;
ad-hoc slices must use the default requirement for their own cdhash. Mixed
signature modes and custom ad-hoc requirements fail closed.

The final signed executable's raw SHA-256, full per-architecture CodeDirectory
SHA-256 set, and designated requirement remain separately verified and bound by
the archive attestation. They are rechecked after every observer extraction.
They are deliberately not asserted to be reproducible by an independent build
with another certificate. Developer ID and local development signatures have
different certificate-dependent designated requirements and CMS payloads. The
CMS size changes `LC_CODE_SIGNATURE` allocation in the Mach-O header, and that
header page is itself hashed by the CodeDirectory. Exact CodeDirectory equality
therefore applies to the signed candidate and its verified extractions, while
source replay uses the signer-independent content boundary above.

The payload identity deliberately excludes only the attestation entry. The
candidate record's raw `appBundleSHA256` includes that entry, so the two hashes
form a non-circular seal over the complete archive.

Archive inspection hashes and parses one anonymous snapshot copied from a held
`O_NOFOLLOW` regular-file descriptor. Device, inode, mode, size, mtime, and
ctime must remain unchanged through the copy. Sealing first makes a private
copy and performs both inspection passes on that copy, so pathname replacement
cannot pair an old inspection with new archive bytes.

## Build and seal

The distributable app must be compiled by the committed helper, not by an
`xcodebuild archive` launched in a working checkout. The helper independently
exports and verifies the declared commit, builds at the one canonical physical
layout, and rigorously constructs the xcarchive from that verified product:

```sh
python3 script/v4/seal_release_candidate_archive_v4.py build-xcarchive \
  --repository "$PWD" \
  --source-commit HEAD \
  --runtime Mirmir/Resources/ASH-P06.bundle \
  --release-configuration script/v4/release-candidate-v4.xcconfig \
  --signing-identity "Developer ID Application: RELEASE IDENTITY" \
  --output-xcarchive /path/to/Mirmir.xcarchive
```

The resulting app is
`Mirmir.xcarchive/Products/Applications/Mirmir.app`. The archive also contains
the canonical clean-build receipt. Developer ID signing is applied only after
the compiled app has matched that receipt, and signing is re-observed to prove
that it did not change any signer-independent byte or policy. Use that exact
app for the notarized-smoke workflow, submit a canonical ZIP to notarytool,
staple the accepted ticket, and then create the unsealed provenance ZIP:

```sh
ditto -c -k --norsrc --noextattr --noacl --noqtn --keepParent \
  /path/to/Mirmir.xcarchive/Products/Applications/Mirmir.app \
  /tmp/Mirmir-notary-submission.zip
xcrun notarytool submit /tmp/Mirmir-notary-submission.zip \
  --keychain-profile Mirmir-Notary --wait
xcrun stapler staple \
  /path/to/Mirmir.xcarchive/Products/Applications/Mirmir.app
ditto -c -k --norsrc --noextattr --noacl --noqtn --keepParent \
  /path/to/Mirmir.xcarchive/Products/Applications/Mirmir.app \
  /tmp/Mirmir-unsealed.zip
python3 script/v4/seal_release_candidate_archive_v4.py seal \
  --repository "$PWD" \
  --source-commit HEAD \
  --runtime Mirmir/Resources/ASH-P06.bundle \
  --release-configuration script/v4/release-candidate-v4.xcconfig \
  --input-archive /tmp/Mirmir-unsealed.zip \
  --source-build-receipt \
    /path/to/Mirmir.xcarchive/MirmirV4CanonicalBuildReceipt.json \
  --output-archive /tmp/Mirmir-sealed.zip
```

Candidate compilation and both replay gates use exactly:

- `/private/tmp/com.mirmir.release-v4-canonical-build/source`;
- `/private/tmp/com.mirmir.release-v4-canonical-build/DerivedData`;
- `/private/tmp/com.mirmir.release-v4-canonical-build/home`;
- `/private/tmp/com.mirmir.release-v4-canonical-build/release-provenance.xcconfig`;
- `/private/tmp/com.mirmir.release-v4-canonical-build/tmp`.

The root is created atomically with mode `0700`, must resolve to itself, and
must retain its original device, inode, owner, and mode. A pre-existing root is
never reused, emptied, or removed. Crash residue therefore causes an explicit
failure that an operator must investigate before retrying. Candidate and replay
builds run sequentially at the same physical source and DerivedData paths from
separate verified git exports. `HOME` and `CFFIXED_USER_HOME` both point to a
newly created empty mode-`0700` directory inside that held root, so user
preferences and caches cannot affect the compiler. The receipt records that
exact layout and environment.

The provenance overlay removes serialized debug information and fixes the
integrated Xcode Swift compiler to `-O` whole-module compilation with one LLVM
module. Batch and parallel-WMO modes are disabled, xcodebuild and the Swift
driver each receive a one-job limit, `SWIFTC_MAXIMUM_DETERMINISM=1` overrides
any driver-added concurrency, incremental imports are disabled, and LLVM uses
a fixed RNG seed. Explicit modules remain enabled while the compilation,
Clang fine-grained-output, and SDK-stat caches are disabled. Source/debug paths
map to `/mirmir/source`, `ZERO_AR_DATE=YES`, and the normal LLVM machine
schedulers remain enabled. `ENABLE_TESTABILITY=NO` is an explicit locked
command-line setting rather than an assumed Release default.

Swift's same-process `-enable-deterministic-check` is deliberately not a
release gate. Swift 6.2.3 reported different x86_64 WMO `MirmirApp.o` hashes
`C52B5FAD...` and `70374584...`, while two fresh executions of that exact
failed frontend command produced byte-identical 18,824,608-byte objects with
SHA-256 `382f2842fb8fe22c1a855a2655e5be232f900173b25740531d87af011faf4b6b`.
Swift 6.3.3 repeated the false positive with internal hashes
`3BE4A0D83B9F50904EAC2E3F121BB210913E39B172488FD82A97FC63514364C9`
and `41B41E98DBA582A4C52383A3ACEEB459057B01CB47404A3C1E23A1484B97C099`.
The internal checker constructs two compiler instances in one process and
therefore does not model the independent release builds.

Release qualification instead requires at least three fresh sequential builds
at the canonical physical root. No object or product bytes may be normalized.
All three normalized receipts and signer-independent application identities
must match exactly, including the signature-stripped universal executable,
independently extracted `arm64` and `x86_64` slices and sizes, every resource
and directory mode, processed Info.plist, runtime, entitlements, code
identifier, and signing-policy flags. Candidate construction, sealing replay,
and preparation replay provide the three independent compiler-process
boundaries in the release workflow.

This reproducible executable build intentionally emits no dSYM. A separate
symbol-generation build may be retained for diagnostics, but it is not the
qualified distributable and cannot satisfy the executable provenance boundary.

Clean replay always uses `CODE_SIGN_IDENTITY=-`, `CODE_SIGN_STYLE=Manual`,
`CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO`, and `ENABLE_TESTABILITY=NO`. These
settings require no private release key and cannot be overridden. Source roots,
products, compiler flags, configuration, project, scheme, destination,
DerivedData policy, and xcconfig also cannot be redirected. The successful
compiler transcript is path-mapped and canonically line-sorted before its hash
is recorded so diagnostic emission order cannot alter the receipt.

The archive command retains every regular bundle file, including the stapled
ticket, while omitting filesystem resource forks, extended attributes, ACLs,
and quarantine state. Those attributes otherwise become `._` or `__MACOSX`
AppleDouble records in a ZIP; the provenance verifier rejects such records so
they cannot be mistaken for signed application or P06 runtime payload.

Generated settings, copied applications, xcarchives, and sealed ZIPs are first
completed and verified at private staging paths. Final publication uses
Darwin's atomic `RENAME_EXCL` operation relative to a held and identity-checked
parent directory. If any file, directory, or symlink appears at the requested
destination after validation, publication fails without replacing it.

Candidate preparation independently repeats all archive, resource, signature,
CodeDirectory, requirement, clean-source export, toolchain, and fixed ad-hoc
xcodebuild checks:

```sh
python3 script/v4/prepare_release_candidate_v4.py \
  --repository "$PWD" \
  --source-commit HEAD \
  --runtime Mirmir/Resources/ASH-P06.bundle \
  --release-configuration script/v4/release-candidate-v4.xcconfig \
  --application-archive /tmp/Mirmir-sealed.zip \
  --output /tmp/candidate-identity.json
```

This provenance verification is separate from Developer ID, notarization,
stapling, and Gatekeeper qualification. Those release gates remain mandatory.
Fast observer-lane archive inspection and extraction validate the already-bound
receipt but do not launch another build. Candidate construction creates the
original receipt; the sealer and candidate preparer are its two independent
compilation-provenance replay gates.
