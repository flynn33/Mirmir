# M7 Media-Preservation Qualification v1

This lane qualifies the deterministic v4 engine against the complete media-preservation contract. It is a release gate, not a unit-test claim: evidence is admitted only when it was captured from the exact committed Release candidate, its release-qualified P06 runtime, and the code-owned P06 trust root.

## Locked coverage

The six real AVFoundation fixtures in `script/v4/media-preservation-contract-v1.json` jointly cover:

- P010 Main10 precision, BT.2020/PQ static HDR, frame-bound HDR10+ and post-decode metadata;
- top-field-first interlace normalization to deterministic progressive double-rate output;
- non-square sample aspect ratio, clean aperture, and preferred-transform rescaling;
- straight and premultiplied ProRes 4444 alpha, including pre-encode versus decoded alpha identity;
- multiple enabled video tracks, alternate-audio selection groups, subtitles, captions, chapters, timecode, timed metadata, and auxiliary picture tracks;
- mandatory combined P010/HDR/interlace/geometry and alpha/geometry cases.

Every enabled input track must have an accounted output track. Pass-through fixtures require exact track, timing, encoded-payload, decoded-pixel, attachment, asset-metadata, and chapter-metadata identities. Transforming fixtures require exact rational geometry, repeat-run pixel identity, and the policy-specific HDR, cadence, or alpha invariants.

## Evidence construction

`script/v4/run_media_preservation_v4.sh` archives the requested Git revision, appends the locked capture source to the committed private AVFoundation fixture factory, and runs only the qualification capture test in Release. The runner rejects dirty tool substitutions, candidate/revision mismatches, an absent or development P06 runtime, an unconfigured trust root, and an output directory that is not empty.

The capture publishes, for each input and output side:

- the real `.mov` fixture;
- a complete track graph and metadata observation;
- per-track sample timing and encoded-payload identities;
- decoded visible pixel bytes and pixel observations;
- format, geometry, HDR, field-order, and alpha attachments.

`script/v4/media_preservation_v4.py` validates the raw descriptors, recomputes all semantic invariants, writes nested side manifests and per-fixture verifiers, and seals every file. Its `verify` command rebuilds the complete evidence directory from the sealed raw capture and requires a byte-identical result.

The release aggregator independently parses the nested raw observations, recomputes timing/payload identities and every fixture policy, checks raw-to-copied artifact identity, and requires exact lane-contract, capture, fixture-source, evaluator, runner, runtime-manifest, and Release-configuration bindings.

## Commands

Compile the ephemeral capture harness without publishing evidence:

```sh
script/v4/run_media_preservation_v4.sh --compile-only
```

Capture final evidence after P06 is committed and the trust root is configured:

```sh
script/v4/run_media_preservation_v4.sh \
  --candidate-revision <full-commit> \
  --candidate output/release-candidate.json \
  --release-configuration output/Release.xcconfig \
  --output output/release-evidence/media_preservation
```

Recompute and verify published evidence:

```sh
python3 script/v4/media_preservation_v4.py verify \
  --evidence output/release-evidence/media_preservation
```

The full capture intentionally cannot run against placeholder P06 identities. That is a fail-closed precondition, not an admissible skip.
