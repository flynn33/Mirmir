# Notarized application smoke qualification v1

> This lane is retained for an optional future release decision. Notarization,
> stapling, Gatekeeper checks, shipping, and distribution are outside the
> simulator-only M7 scope adopted September 21, 2026.

This lane qualifies the exact stapled Mirmir release archive after Apple has
accepted it. It does not submit an archive for notarization and it cannot
manufacture an Apple acceptance result. Two explicit acceptance providers are
supported: a live `notarytool` replay of a retained pre-staple submission, and
the accepted Developer ID submission receipt retained by an Xcode
`.xcarchive`.

The locked contract is
`script/v4/notarized-smoke-contract-v1.json`. The recorder is
`script/v4/run_notarized_smoke_v4.py`; the independent evaluator and replay
verifier is `script/v4/notarized_smoke_v4.py`. Their SHA-256 identities and the
shipping observer source identity are part of the lane contract and every
report.

## Release inputs

### Xcode archive provider

Use this provider when Xcode performed cloud-managed Developer ID signing and
notarization and the machine does not have a local Developer ID identity or a
`notarytool` Keychain profile. Retain the exact `.xcarchive`. It must contain
exactly one matching `Distributions` receipt and
`Submissions/<UUID>/notarization-log.json`. The runner invokes the selected
Xcode's real `xcodebuild -exportNotarizedApp`, records that command, and retains
the exported app as the submitted-app evidence archive.

```sh
python3 script/v4/run_notarized_smoke_v4.py \
  --candidate /absolute/release-candidate.json \
  --application-archive /absolute/Mirmir-stapled.zip \
  --xcode-archive /absolute/Mirmir.xcarchive \
  --release-contract /absolute/script/v4/release-qualification-contract-v1.json \
  --output /absolute/notarized-smoke
```

If an archive contains more than one submission, add the exact accepted UUID
with `--xcode-submission-id`. Ambiguity otherwise fails closed. The evaluator
requires a successful Developer ID upload and completed Apple processing for
team `9AQ2C2838M`, with no receipt errors or warnings. It requires Apple's
ticket-content CodeDirectory hashes to match the exact exported and candidate
app for both `arm64` and `x86_64`. The log's `sha256` remains the identity of
Apple's original Xcode transport ZIP; it is never relabeled as the locally
reconstructed evidence ZIP.

### notarytool provider

Retain both archives during release assembly:

- the exact archive uploaded to Apple, before ticket stapling;
- the exact stapled archive used by
  `candidate.appBundleSHA256` in the release-candidate evidence.

This provider also requires the accepted notary submission UUID and a
`notarytool` Keychain profile. The Keychain profile name is recorded as part of
the command; credentials are not copied into evidence.

Run the lane only after ticket stapling:

```sh
python3 script/v4/run_notarized_smoke_v4.py \
  --candidate /absolute/release-candidate.json \
  --application-archive /absolute/Mirmir-stapled.zip \
  --submitted-archive /absolute/Mirmir-submitted.zip \
  --notary-submission-id 00000000-0000-0000-0000-000000000000 \
  --notary-keychain-profile Mirmir-Release \
  --release-contract /absolute/script/v4/release-qualification-contract-v1.json \
  --output /absolute/notarized-smoke
```

The output path must not exist. A successful run creates `report.json`, ten
action attestations, their independently derived transcripts, a replay
receipt, all raw inputs and process records, and `sealed-manifest.json`.

Replay verification performs no external commands:

```sh
python3 script/v4/notarized_smoke_v4.py verify \
  --capture /absolute/notarized-smoke/raw/capture.json \
  --report /absolute/notarized-smoke/report.json \
  --contract /absolute/script/v4/notarized-smoke-contract-v1.json \
  --release-contract /absolute/script/v4/release-qualification-contract-v1.json
```

Capture evidence expires after the contract's one-hour admission window;
Apple acceptance evidence expires after seven days. Release aggregation should
therefore immediately copy the completed suite into the candidate evidence
root and evaluate it.

## What is executed

The recorder invokes and captures exact executable hashes for:

1. either `notarytool info` plus `notarytool log`, or the selected Xcode's
   `xcodebuild -exportNotarizedApp` plus its retained distribution receipt and
   notarization log, for Apple acceptance;
2. `spctl --assess` for Gatekeeper acceptance;
3. `stapler validate` for the attached ticket;
4. `codesign` verification, signing metadata, entitlements, and designated
   requirements for both the submitted and stapled apps;
5. the main executable inside the stapled shipping app twice.

The code-signing gate requires a secure timestamp, Developer ID Application
certificate, team `9AQ2C2838M`, hardened-runtime flag, app sandbox, and
application-scoped persistent bookmarks. It rejects
`com.apple.security.get-task-allow`. The submitted and stapled apps must retain
the same executable SHA-256, every required-architecture CDHash, designated
requirement, bundle identity, and embedded P06 runtime identities. With the
`notarytool` provider, the Apple log's archive SHA-256 must equal the retained
submitted archive. With the Xcode provider, every `arm64` and `x86_64` ticket
CDHash must equal the exported and candidate app CodeDirectory hash.

## Shipping-app observer

The dormant observer entry point lives in `Mirmir/App/MirmirApp.swift`, which
is already part of the shipping target. It is enabled only by one exact
canonical, base64-encoded command envelope. Qualification mode does not create
the normal application view model, so it never opens the user's production
queue.

The first app process creates a deterministic H.264/NV12 movie, probes it with
the production media probe, and completes an uninterrupted deterministic CPU
P06 reference through the production durable workflow with one-frame segment
boundaries. It submits the identical request to a second isolated production
queue and pauses at the first committed boundary. It must leave no final
paused-job output. Matching the reference and recovered segment/assembly path
means pause plus process relaunch is the only semantic variable; independent
lossy H.264 encoding sessions are never treated as a pixel-equivalent control.

The probe records whether bit depth, range, and field count came directly from
the H.264 format description or from the locked writer contract. This makes
OS-version differences in omitted default H.264 extensions explicit while
still requiring the same 8-bit, video-range, progressive facts.

The second app process reopens that isolated queue, verifies the sealed
phase-one state and unchanged queue tree, requires launch recovery to present
exactly one idle, paused, resumable job without containment, resumes that job,
and requires completion. It decodes the matched uninterrupted reference and
recovered outputs and requires exact equality of raster, frame count,
duration, normalized sample timing SHA-256, and visible NV12 pixel SHA-256.

Both processes use the unique root:

```text
~/Library/Containers/com.mirmir.app/Data/Library/Application Support/
  MirmirQualificationV4/notarized-smoke/<random-request-uuid>
```

The runner snapshots that root after each process. It removes only that exact
UUID root after the evaluator and replay verifier succeed. User queue paths are
outside this namespace. A failed unsealed suite is retained next to the
requested output with a `.failed.<uuid>` suffix for diagnosis.

## Fail-closed evidence rules

The evaluator does not trust capture booleans. It independently:

- rejects duplicate JSON keys, non-finite numbers, unsafe paths, symbolic
  links, hard links, special files, archive path traversal, encrypted ZIP
  entries, and oversized trees;
- recomputes every file, archive, executable, invocation, request, result,
  queue-tree, transcript, attestation, replay, and sealed-set identity;
- requires every external command to exit zero within the bounded capture
  interval and parses the semantic acceptance facts from raw output;
- binds the exact candidate, lane/release contracts, embedded P06 manifest,
  observer, evaluator, runner, system tools, acceptance provider and receipt,
  submitted/exported app archive, and shipping executable;
- decodes the actual shipping-app stdout markers and requires them to match the
  result files in both copied sandbox trees byte for byte;
- reopens the phase-one state and independently recomputes the paused and final
  durable queue tree seals;
- rejects fabricated, contradictory, stale, incomplete, nonzero, tampered, or
  unsealed evidence.

The ten emitted action IDs and evidence kinds exactly match the optional release
contract: Apple notary acceptance, Gatekeeper, stapler, code signature,
shipping-app launch, production P06 load, real media probe, deterministic
processing, semantic output verification, and queue relaunch recovery.
