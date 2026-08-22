# Deterministic engine v4 performance qualification

`script/v4/run_performance_gate_v4.sh` is the fail-closed qualification for
the version 4 processing-time target. It compares the frozen P05 source at
`d3a4de55c08391ea8a08c00beb766b5650dc9f58` with one committed P06 candidate.
Both lanes use the same locked three-frame input, output request, Release build,
machine, power state, semantic verification, five warmups, and ten ordered
measurements per mandatory backend and scale class.

The measured matrix is CPU and Metal at exact 2x and 3/2 scaling. The
end-to-end timer includes probe, verified runtime preparation, decode, frame
processing, encode, writer finalization, application validation, independent
track verification, and decoded visible-pixel hashing. Raw engine-frame and
end-to-end arrays remain in the sealed evidence so the release aggregator can
recompute every statistic.

A release passes only when all three paired metrics meet the target:

- candidate aggregate-corpus wall median / P05 median is at most `0.80`;
- candidate engine-frame median / P05 median is at most `0.80`;
- candidate engine-frame p95 / P05 p95 is at most `0.80`; and
- the deterministic 95% paired-bootstrap upper bound is at most `0.80` for
  each metric.

The candidate must also use the release-qualified
`ash-p06-deterministic-v4` bundle with code-owned trust roots, preserve all
required output semantics on every run, remain within the declared temporal
history memory allowance, and hold hardware, software, power, and thermal
conditions constant. Missing or unsealed files, altered identities, fallback,
unstable pixels, and incomplete samples are rejected.

Run the final qualification only against the committed P06 release candidate:

```sh
script/v4/run_performance_gate_v4.sh \
  --output /path/to/release-evidence/same_scope_performance \
  --candidate /path/to/candidate-identity.json \
  --application-archive /path/to/Mirmir-sealed.zip \
  --runtime <repository>/Mirmir/Resources/ASH-P06.bundle \
  --release-configuration \
    <repository>/script/v4/release-candidate-v4.xcconfig \
  --warmups 5 \
  --samples 10
```

The runner writes `baseline/` and `candidate/` raw captures, the locked
contract, `performance-gate-report.json`, nested artifact seals, and a recursive
root evidence seal. It never benchmarks the dirty working tree.

## Producer receipt and sample transcripts

The frozen P05 lane is produced by the contract-locked Release capture source
and runner. Before `xcodebuild` starts, the runner creates an invocation nonce
and challenge and writes the exact fifteen-field producer environment to a
fixed-path request artifact held under an exclusive lock. The unchanged capture
source reads and hashes that request, while the same values remain in the exact
build argv and environment. The P05 export, DerivedData, Clang/Swift module
caches, and injected request source use one fixed canonical producer root under
the same exclusive lock. Every run proves that root is absent before creating
it, writes the same owner token into it, and removes it only while that token
still matches. A foreign or stale canonical root fails closed and remains
untouched.

The runner forces `SWIFT_DETERMINISTIC_HASHING=1`,
`SWIFTC_MAXIMUM_DETERMINISM=1`, one Xcode build job, one effective Swift thread,
and exactly one LLVM RNG seed. Source and DerivedData prefixes are mapped in
both Swift and C compiler flags. A mode-`0755` wrapper at the fixed canonical
`SWIFT_EXEC` path delegates to the resolved Xcode Swift compiler whose exact
path, bytes, mode, and version are sealed. For each compile-driver invocation,
the wrapper rejects a missing incoming job control, removes every separated or
joined Xcode `-j` value, adds exactly one fixed
`-driver-use-frontend-path`, adds exactly one `-save-temps`, appends exactly one
terminal `-j 1`, and force-exports both deterministic variables plus the fixed
owner-only `TMPDIR` before job projection and execution. The non-integrated
driver must project exactly one arm64 frontend job for each of `Mirmir` and
`MirmirTests`, and the projected executable must be the sealed mode-`0755`
frontend shim. Each projected job must retain exactly one
`-num-threads 1`, exactly one `-Xllvm -rng-seed=1`, the complete source and
DerivedData prefix maps, no driver job option, no direct frontend
`-working-directory`, exactly one fixed `-file-compilation-dir`, and exactly
one equivalent Xcc-forwarded working directory. Explicit Swift
modules are disabled: the accepted cache policy is exactly one
`-module-cache-path` naming the fixed canonical module cache and no
`-clang-scanner-module-cache-path` or `-sdk-module-cache-path`.

Swift's driver creates a randomized supplementary-output-map transport path.
The fixed frontend shim closes that boundary without rewriting a compiled
binary or trusting an `xcodebuild` display line. At the actual frontend
invocation, it verifies the fixed and random temporary directories as owned,
real mode-`0700` directories; verifies the raw map as an owned mode-`0644`,
single-link regular file; and holds the same device, inode, owner, mode, link
count, and size from pre-open inspection through post-read `fstat` and final
path inspection. It validates the map's module-bound source and fixed
DerivedData outputs, creates one deterministic per-module copy with
`O_EXCL`/mode `0600`, replaces only the raw map value in the actual frontend
argv, appends a locked mode-`0600` actual-frontend audit record, and then
executes the exact pinned Swift frontend. The compiler therefore consumes the
canonical copied map, not merely an audited random path. Bypass, duplicate,
cross-module, symlink-parent, map-content, and output-path substitutions fail
closed.

The evaluator replays the sealed driver wrapper and frontend shim bytes,
interpreter and underlying compiler/frontend identities, both audit artifacts,
both canonical map artifacts, and exactly one invocation of each required
module. The stable compiler facts bind canonical-map size/hash and normalized
effective frontend argv identity. Raw randomized transport paths and their
filesystem metadata remain exact receipt-local evidence and do not enter the
stable identity. No UUID stripping, binary rewriting, or post-build
normalization is permitted.

Keeping run-specific values out of compiled source while keeping physical
source, cache, and build paths fixed makes the exact application and test
executable identities reproducible across distinct evidence roots. The request
lock also carries the per-process owner token: cleanup removes only that
owner's fixed request/source files, while contention fails closed without
altering another producer's contents.
If `xcodebuild` fails, the runner first preserves the raw driver wrapper,
frontend shim, both partial audits, canonical supplementary maps, and raw saved
temporary maps beside the already-retained log and partial `.xcresult`, then
performs the same owner-token-validated cleanup before returning the original
build status.
The v2
producer receipt binds the completed process interval and exit status, exact
Release command and configuration, source revision and tree, source-identity,
contract/capture/runner identities, hashed build request, locked input, built application and test
executables, full `.xcresult` tree, normalized test summary, build log, raw
capture, exact Swift driver/frontend helpers, both effective-job audits, both
canonical supplementary-output maps, and every sample-transcript artifact.

The evaluator derives one chained transcript row for every engine and
end-to-end sample. Each row covers the exact captured timing, memory, output
verification, case identity, producer context, and predecessor. Replaying the
evaluator must reproduce the complete transcript document. Both capture
directories and every file below them are recursively sealed; symbolic links,
unmanifested files, copied descriptors, and altered raw result/log bytes are
rejected.

The normalized result summary is recomputed from the sealed `.xcresult` with
`xcresulttool` and must name the locked test with exactly one passed test, no
failures, no skips, and result `Passed`. The sealed locked-input copy must match
the contract byte count and SHA-256. The application and test artifacts must be
distinct Mach-O executables and their exact identities are reported.

## Stable and per-run identities

The raw producer receipt, `.xcresult`, log, challenge-bound transcript set,
measurement-set identity, timestamps, nonces, and absolute working paths are
intentionally per-run. They are exact, locally replayed evidence, but their raw
hashes are not external reproducibility pins.

The report separately exposes a path-neutral stable-producer fact map and its
domain-separated identity. That map contains the frozen P05 source, tree,
source-identity, contract, capture source, runner, toolchain, warmup/sample
counts, semantic and sealed input identities, normalized argv/environment,
the recomputed compiler-control audit,
locked test identifier and summary, exact application/test executable hashes,
and a timing-neutral workload identity. The workload identity covers ordered
case/backend/target/request facts, engine and end-to-end sample topology,
processed/frame counts, every deterministic verification flag, and semantic
pixel/track hashes. It deliberately excludes frame and wall timings, peak RSS,
nonce, challenge, and transport paths. Capture, DerivedData, input, nonce, and
challenge values are replaced with logical tokens. Equivalent evidence roots
with independent timings, memory observations, nonces, and challenges therefore
have different raw receipts, measurement sets, and challenge-bound transcripts
but the same workload and stable producer identities.

This is a trusted-producer execution proof, not a secret-key attestation. The
release boundary externally pins the exact producer/evaluator/runner bytes and
requires operator-observed execution. Resealed copied receipts, substituted
commands, synthetic summaries, stale transcripts, and self-consistent
environment substitutions are rejected without claiming that unkeyed evidence
is cryptographically unforgeable against a malicious replacement producer.

## Frozen P05 producer reproduction proof

On 2026-08-15, two fresh-root baseline-only captures independently rebuilt and
executed the frozen P05 producer from absent fixed request and producer roots:

- A: `/private/tmp/mirmir-performance-p05-swiftexec-final-a.FrgAyX/evidence/baseline`
- B: `/private/tmp/mirmir-performance-p05-swiftexec-final-b.hUsxov/evidence/baseline`

Both recursive seals and producer receipts passed independent evaluator replay.
Each normalized result named the locked capture test with one pass, no failures,
and no skips. The application executable was byte-identical in both roots at
`4,386,440` bytes and
`835ac96f4afb64785238d1ec26be52078cfd3d57f2e81e64cb8bed702ee06635`.
The test executable was byte-identical at `1,734,904` bytes and
`29b4d45177cb39635ba9951c0d5692d4f97cd63aa8a38d149018e43cb753ff9f`.
The timing-neutral workload identity was
`e3b82df0a00dc2d3b2e7b1904f3efb1ee425bd6e4908e9af7b27128b02d13e66`,
and the domain-separated stable producer identity was
`54e96f20effe70b21a51832eef6e54962a4f272577113a096d9078790b2931d0`
in both captures. Their exact 24-key stable fact maps were byte-identical; the
canonical newline-terminated map is `58,267` bytes with SHA-256
`a2b3b5f2ea0e2a09a3f1050c9397c4139c872370a7f35ae751f16f13b2da7f1e`.

The stable compiler-control audit was also identical with canonical SHA-256
`5bc9077c5f9b2737574e3d51c2bb84a89271198ca23b2fc625b27d9756066bd6`.
It contains exactly one Mirmir and one MirmirTests driver/frontend job. The
driver audit SHA-256 is
`f8d1fe1db2db2d393d606d53d4472967dc2591f7dab6485bd1bbdcb97d5e7f5e`;
the fixed wrapper and frontend-shim identities are respectively
`23e97ed73f80c899ee36ecd70ced94951a782a5dcd95478d946848bbd4d24f68`
and
`b64e44f346e17a5d6bb33af6c2365e8777783b28815840137074f234bc31b8b6`.
The mode-`0600`, single-link canonical maps were identical: Mirmir used
`1,403` bytes at
`f4467048d9b648d14d17fbe7e5cfb1df7d57c49c0cfdc77e3eb7d310ea49ab63`,
and MirmirTests used `1,476` bytes at
`f6a274c836b7ea5c6a6ee4fa96e99192701a1e6ba6693a3626e4e1522739ac2f`.

The per-run identities remained distinct as required. A and B producer receipt
SHA-256 values were respectively
`994cee647117e8441bfc6ecb2f191c10c8adff852923ea60f162f4fe41814b65`
and
`dd1f3cc40135567b3b5ad55742705e766118b416146fd3149e957b6bbe409456`.
Measurement-set identities were
`81f58c1bd478689b8092b8eb2ee092d51ad02defeb6798b7991321b648b86f21`
and
`3d1ea92cbfea49e6fe0ad7dbcf21c208333e2ee912140258ae31d2273610ae18`.
Transcript artifact identities were
`34f304d7458c13c38b24260e5bc8dce323bc8bcd70d9bf733838962c748b6a0e`
and
`2fd76b2de842246466b398709df576afd45b0725f041b27b638218176f869279`;
their 80-row transcript-set identities were
`9421a491372e2077de26ebadac8e83708c1261f678c9776afd087881f3e89af6`
and
`af4d9aad5191c3300625f1745831eae819efebc2fdadb0cfc4f0e340d5fee42b`.
Nonces, challenges, capture paths, timestamps, logs, result bundles, and raw
frontend transport paths were likewise distinct.

A's independent validation summary is
`/private/tmp/mirmir-performance-p05-swiftexec-final-a.FrgAyX/independent-validation.json`
with SHA-256
`75fceda500c437d795c83f276376d7ad6db3440cd98076668350be00087524f2`.
The exact A/B comparison is
`/private/tmp/mirmir-performance-p05-swiftexec-final-b.hUsxov/a-b-comparison.json`
with SHA-256
`72e13f31f07378f0bf94e4c9283cd83bedb4d4e545ae31846096b382bf48c24c`;
all 18 stable-equality checks and all 17 designed-per-run-difference checks
passed.

This proof qualifies reproducibility and causal evidence for the frozen P05
baseline producer only. It does not establish that a final P06 candidate meets
the required 20% processing-time reduction; that decision still requires the
sealed same-machine paired candidate run and full performance evaluator.

## Frozen-lane execution proof

An exact-revision P05 diagnostic capture completed on 2026-08-02 with all four
cases, five warmups, ten measured end-to-end runs per case, thirty timed engine
frames per case, stable decoded-pixel and semantic-track hashes, and every
semantic check passing. Its aggregate four-case wall median was `838.649 ms`;
the flattened engine-frame median was `52.916 ms` and p95 was `95.216 ms`.
Peak resident memory was `132.36 MiB`.

These numbers establish executable baseline behavior but are not a release
decision. The sealed paired run must be repeated on the final P06 commit so the
candidate and baseline share the exact recorded environment.
