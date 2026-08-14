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
module. Batch, eager module emission, parallel-WMO, and parallel-WMO-target
modes are disabled. Swift explicit modules are disabled; Clang explicit modules
remain enabled. Compilation, Clang fine-grained-output, and SDK-stat caches are
disabled. Incremental imports are disabled, LLVM receives the fixed RNG seed
`1`, source/debug paths map to `/mirmir/source`, and `ZERO_AR_DATE=YES`. The
normal LLVM optimization and machine-scheduling pipelines remain enabled.
`ENABLE_TESTABILITY=NO` is an explicit locked command-line setting rather than
an assumed Release default.

Xcode does not expose a build setting that owns the final Swift-driver `-jN`
argument it synthesizes. The clean builder therefore creates a mode-`0755`
`SWIFT_EXEC` wrapper at the canonical build root with exclusive creation and
binds its exact bytes, filesystem identity, interpreter, underlying `swiftc`
path, executable hashes, and versions in the receipt. The wrapper removes every
joined or separated driver `-j` option and appends one terminal `-j 1`. It also
fails closed unless each architecture's driver invocation contains exactly one
`-num-threads 1`, one `-Xllvm -rng-seed=1`, and its expected target. Before
execution, it asks the exact inspected Swift executable for `-driver-print-jobs`
and independently requires one projected frontend job with the same target and
the same single thread and RNG controls. Missing, duplicate, substituted,
malformed, or later-overridden controls are rejected. The arm64 and x86_64
markers are canonically sorted before hashing so scheduler-dependent reporting
order does not change their identity. Wrapper bytes, node identities, audit
file mode, Swift executable, and interpreter are revalidated after the build.

Swift's same-process `-enable-deterministic-check` remains a fail-closed
diagnostic, not a reproducibility proof. It compares compiler instances inside
one process and cannot replace independent executions. Qualification found a
real independent-process variance in the four clean-aperture values previously
constructed through tuple-array iteration: optimized WMO objects differed, and
the same four PHI nodes were already reordered in `-emit-irgen` output before
LLVM optimization. The implementation now validates the four fields through
explicit calls to a non-inlined helper, eliminating that unordered equivalent
IR group without disabling broad optimizations or machine placement. On the
post-change pre-freeze snapshot, three exact arm64 IRGen replays were identical
at SHA-256
`227065fa9ee04158edf5194c63c59017a21a86deb8a8e91c0b56cc6b86c906b8`;
three exact arm64 WMO objects were identical at
`101ddaad4b40fbcd01d60976fb56c8e3427f3de541f83530ba2b009ff7764aaa`;
and three exact x86_64 WMO objects were identical at
`a60e211d96b28e961f5494c2c90a754aff712509321d3b2ae55efd9f76fd9071`.
Those targeted replays validate the repair but do not replace the final
three-build gate from the integrated release commit.

## External Metal build

Xcode is prevented from compiling the two release `.metal` inputs. The clean
builder instead resolves the installed `MetalToolchain` component with
`xcodebuild -showComponent MetalToolchain -json` and binds its stable asset,
build, and toolchain identifiers. For `metal`, `metallib`, and `metal-nm`, the
receipt records the component-relative dispatcher and versioned underlying
executable paths, hashes, and versions. Compilation and symbol inspection use
the exact resolved underlying `metal` and `air-nm` binaries. Linking invokes
the exact resolved `usr/bin/metallib` entry point so its `argv[0]` selects
metallib compatibility mode, while the receipt also binds the underlying
`air-lld` identity. Directly invoking `air-lld` is not treated as an equivalent
link command.

The compiler's exact `-print-resource-dir` tree is sealed as a sorted manifest
of regular-file paths, modes, sizes, and hashes. The manifest must contain
`metal_stdlib`, `module.modulemap`, and `libmetal_rt_osx.a`; links and special
files are rejected. This closes the transitive resource/header/runtime-library
dependency boundary rather than binding only top-level launchers. The complete
component, executable, and resource resolution is repeated after Metal
execution and must remain byte-for-byte identical. Absolute MobileAsset mount
paths in diagnostic output are normalized only to `$METAL_TOOLCHAIN`; the
component-relative identities and file bytes remain bound.

Each source is compiled with explicit `-O3`, `-std=metal3.2`,
`-target air64-apple-macos15.4`, safe Metal math, and precise FP32 functions.
The receipt binds both source files, every command, normalized transcript, AIR
output, final `default.metallib`, and the exact eleven-function symbol
inventory. A direct three-run qualification on the installed
`com.apple.dt.toolchain.Metal.32023.864` component produced identical
134,446-byte libraries with SHA-256
`c81de056a2adeae53cb8a12120021dec6f123225be1bfdb80007310c7f58b6ba`.
That focused proof validates the external Metal path; final acceptance still
requires the complete canonical receipt equality below.

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
