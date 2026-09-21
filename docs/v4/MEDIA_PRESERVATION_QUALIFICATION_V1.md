# Release media-preservation qualification v1

> This lane is retained as optional release evidence. It is not an M7 gate
> under the simulator-only scope adopted September 21, 2026.

This lane qualifies the deterministic v4 engine against the complete media-preservation contract. It is a release gate, not a unit-test claim: evidence is admitted only when it was captured from the exact committed Release candidate, its release-qualified P06 runtime, and the code-owned P06 trust root.

## Locked coverage

The six real AVFoundation fixtures in `script/v4/media-preservation-contract-v1.json` jointly cover:

- P010 Main10 precision under both BT.2020/PQ and BT.2020/HLG transfer profiles;
- PQ static HDR plus frame-bound standards-valid HDR10+, and HLG static HDR with dynamic metadata forbidden;
- top-field-first interlace normalization to deterministic progressive double-rate output;
- non-square sample aspect ratio, clean aperture, and preferred-transform rescaling;
- straight and premultiplied ProRes 4444 alpha, including pre-encode versus decoded alpha identity;
- multiple enabled video tracks, alternate-audio selection groups, subtitles, captions, chapters, timecode, timed metadata, and auxiliary picture tracks;
- mandatory combined P010/HDR/interlace/geometry and alpha/geometry cases.

The `combined-p010-hdr-interlaced` source uses disjoint, detail-bearing
top/bottom P010 code bands. This makes field dominance visible in the decoded
pixels, not merely in attachment labels or timestamps. The
`auxiliary-picture-track` source carries an exact archived HLG Main10 primary
alongside the auxiliary picture track, so HLG decoding, processing, encoding,
and auxiliary preservation are exercised in one candidate-bound fixture.

Every enabled input track must have an accounted output track. Pass-through fixtures require exact track, timing, encoded-payload, decoded-pixel, attachment, asset-metadata, and chapter-metadata identities. Transforming fixtures require exact rational geometry, repeat-run pixel identity, and the policy-specific HDR, cadence, or alpha invariants.

## Evidence construction

`script/v4/run_media_preservation_v4.sh` archives the requested Git revision, appends the locked capture source to the committed private AVFoundation fixture factory, and runs only the qualification capture test in Release. The runner rejects dirty tool substitutions, candidate/revision mismatches, an absent or development P06 runtime, an unconfigured trust root, and an output directory that is not empty.

The capture publishes, for each input and output side:

- the real `.mov` fixture;
- a complete track graph and metadata observation;
- per-track sample timing and encoded-payload identities;
- decoded visible pixel bytes and pixel observations;
- format, geometry, HDR, field-order, and alpha attachments.

The PQ fixture is admitted only after a freshly encoded source-reader preflight
observes exactly three nonempty, presentation-time-bound HDR10+ records in both
the compressed and decoded AVFoundation views. The fixture constructs a
standards-valid HEVC prefix-SEI NAL (NAL type 39, payload type 4) from the locked
64-byte registered ITU-T T.35 payload, applies start-code emulation prevention,
and inserts the length-prefixed NAL immediately before the first VCL NAL. The
rewriter independently parses the encoded sample and validates the inserted
NAL, exact payload, and RBSP trailing bits before remux. This check runs before
the production processor, so an empty source stream cannot be mistaken for
successful preservation. Field normalization must then replicate those three
records to the six progressive output frames exactly.

The shipping session selects its preservation route from the prepared primary
track's canonical dynamic-HDR inventory. When that inventory is empty, it
retains the original one-pass processed-track migration; no transient segment,
remux, or assembly is run. The v4.3 preservation report records
`routeID = ash.canonical-dynamic-absent-one-pass.v4`, separate canonical empty
source/output ledger identities, `rewrittenSampleCount = 0`, and
`segmentCount = 0`. Its `timelineMappingSHA256` is a distinct not-applicable
identity domain-separated over that route and the canonical track-plan hash;
it is never zero or omitted. The executor still compares the decoded pre-encode and
reopened compressed dynamic-metadata accumulators, so the absent route cannot
silently invent metadata.

Only a primary track with declared canonical dynamic HDR enters
`ash.bounded-hdr10plus-segment-prefix-sei.v4`. That route processes at most 60
input frames per independently verified segment. It binds every numeric source
PTS, including explicit nil-metadata records, to a bounded ledger; injects the
exact standards-valid prefix SEI after encode when required; and independently
reopens the compressed result. Per-segment output ledgers are sealed in an
owner-only temporary root and streamed one at a time during assembled and final
output verification. The whole-asset receipt folds the ordered segment ledger
identities into constant-size source/output identities and separately binds the
segment and rewritten-sample counts. Every leaf and the aggregate also bind the
same `timelineMappingSHA256`.

The declared-dynamic route admits only one exact unscaled nonempty primary edit,
optionally preceded by one empty edit that ends exactly at the nonempty target
start. Multiple, reordered, scaled, rounded, or mixed mappings fail closed.
The mapping identity is domain-separated over the exact source-media range,
target-presentation range, offset, accepted topology, and accepted edits.

Backend processing, discontinuity detection, compressed and decoded HDR
ledgers, and scratch verification remain entirely in source-media PTS.
Transient assembly inserts each local segment at the independently planned
target start plus its source-media offset, preserving the leading edit and every
boundary gap. The replacement elementary stream itself is normalized only by
the first source-media PTS, so AVAssetReader exposes raw compressed and decoded
samples from zero even when the presentation track begins later. Graph
verification separately requires the exact planned target time range and edit
map; a raw-sample match cannot substitute for that proof. Progress maps media
end times through the exact offset, while durable checkpoint segment progress
retains its existing zero-offset media-domain behavior. A gap at a 60-frame
boundary remains an empty timeline interval and the preceding frame duration is
not extended. Final processed-video replacement
then migrates the original nonvideo tracks, groups, associations, metadata, and
any required nonvideo transcode hooks through the existing rich-asset executor.
Duplicate, missing, extra, nonnumeric, or conflicting PTS/metadata records fail
before publication, and cancellation is checked during both decoded and raw
verification passes.

AVAssetReader zero-sample edit/control markers are still appended so container
timeline state survives migration. They are neutral to migrated real-sample
counts, last-real-PTS validation, encoded-stream identities, and dynamic-HDR
accumulators. Aggregated audio or caption buffers continue to count once per
appended buffer, preserving the established receipt cardinality.

Arbitrary post-decode property-list attachments remain an in-memory adapter
capability, but are deliberately absent from this on-disk HEVC/MOV contract.
Core Media defines those attachments for format-reader/decoder handoff and does
not define a corresponding HEVC serialization. The evaluator therefore
requires `postDecodeSHA256` to be null on every archived PQ input and output
sample; a non-null value fails as an unsupported on-disk claim.

`script/v4/media_preservation_v4.py` validates the raw descriptors, recomputes all semantic invariants, writes nested side manifests and per-fixture verifiers, and seals every file. Its `verify` command rebuilds the complete evidence directory from the sealed raw capture and requires a byte-identical result.

For both Main10 fixtures, the evaluator reads the archived visible P010 bytes
directly as little-endian, MSB-aligned 10-bit signal codes. It independently
reconstructs every expected luma and interleaved chroma frame with scalar
field-order handling, the causal edge-directed bob and temporal gate, exact
half-pixel-center coordinates, reflect-101 borders, the release Q14
Catmull-Rom coefficient procedure, a single Q28 ties-to-even reduction, and
video-range clamping. It does not call the production scaler or deinterlacer.

The semantic verifier records the independently derived expected-visible
identity and recomputes, separately for every decoded frame and plane, maximum
and mean absolute code error, nearest-rank p95 and p99 absolute code error, and
exact signed mean error. The nearest-rank procedure uses
`ceil(percent * frameSampleCount / 100)` with no interpolation. Every frame and
both planes must satisfy every fixture-specific release lock; the verifier also
reports the worst frame index for each metric. Consequently, a sparse,
compressed edge cannot hide a dense wrong reconstruction, and neither a broad
bias nor one biased frame can be diluted by otherwise-correct frames.

These distribution locks follow from the independent reconstruction, not from
a production pass flag. Every Q14 phase sums exactly to 16384, the single Q28
reduction is ties-to-even, and the field reconstructor either copies a source
sample or averages two samples ties-to-even. Those operations preserve a
constant signal. Chroma has no ASH reconstruction stage. Luma ASH is a bounded
detail reconstruction, so it may create local deviation but not an arbitrary
DC shift. The HEVC Main10 boundary can create sparse error around the fixture's
deliberately difficult edges; p95, p99, mean, and signed bias restrict that
codec allowance independently of the worst sample.

The Release calibration was obtained from AVFoundation-decoded P010 artifacts,
including an exact second production processing/decode. Maximum error was
expanded to the next 16-code boundary, mean absolute error to the next integer,
and the percentile tail to a fixed 16-code PQ or 8-code HLG grid. The
independent constant-signal argument locks absolute signed bias per frame to
eight luma and four chroma codes for the high-contrast interlaced PQ path, and
two luma and one chroma code for progressive HLG. These are less than one
percent of the applicable video-range span and cannot be averaged across time.
Those rules produce these worst-frame archived values (`fN` is a zero-based
output-frame index):

| Fixture / plane | Maximum observed / lock | Mean absolute observed / lock | p95 observed / lock | p99 observed / lock | Absolute signed mean observed / lock |
|---|---:|---:|---:|---:|---:|
| PQ interlaced luma | 445 f3 / 448 | 75.012297 f5 / 76 | 211 f5 / 224 | 294 f5 / 304 | 6.623119 f5 / 8 |
| PQ interlaced chroma | 306 f5 / 320 | 42.962674 f5 / 43 | 117 f5 / 128 | 202 f5 / 208 | 3.168692 f5 / 4 |
| HLG progressive luma | 269 f6 / 272 | 7.132668 f6 / 8 | 28 f5 / 32 | 71 f6 / 72 | 1.798177 f5 / 2 |
| HLG progressive chroma | 148 f1 / 160 | 17.067998 f6 / 18 | 51 f6 / 56 | 84 f5 / 88 | 0.844039 f2 / 1 |

The PQ source's minimum decoded field-mean separation is `129547/256`
(approximately 505.65 codes), above its 496-code lock. Repeated decoded output
identities are
`db3c879e422075f61d2e6ce3f900ecdc71531367c9f45fedd85fe8d988ada915`
for PQ and
`a4a5f0569a2a60e20b72183a1edcfd9fb960c5b668166faf6a652781ca6bd480`
for HLG. The PQ byte-plane oracle operates on the encoded raster from 64 x 48
to 96 x 72. Its clean aperture is independently checked from 60 x 44 to
90 x 66; sample aspect ratio 4:3 and preferred transform remain separate
geometry invariants and do not crop or reorient the archived visible bytes.

A changed algorithm, weakened threshold, deterministically wrong pixel,
constant bias, single-frame bias, shifted edge, reversed field order, altered
cadence, transfer-profile swap, metadata loss, or unexpected HLG dynamic
metadata fails even if observation hashes and evidence seals are refreshed.

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
  --candidate /path/to/candidate-identity.json \
  --application-archive /path/to/Mirmir-sealed.zip \
  --release-configuration \
    <repository>/script/v4/release-candidate-v4.xcconfig \
  --output /path/to/release-evidence/media_preservation
```

Recompute and verify published evidence:

```sh
python3 script/v4/media_preservation_v4.py verify \
  --evidence output/release-evidence/media_preservation
```

The full capture intentionally cannot run against placeholder P06 identities. That is a fail-closed precondition, not an admissible skip.
