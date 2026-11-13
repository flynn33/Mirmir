# Selected-primary independent-media diagnostic review

The original failed checker and result remain unchanged; exact copies are retained as `original-checker.py` and `original-selected-primary-independent-media.json`. This review adds diagnostics only. No production/test source changed, no Xcode/app build or GPU upscaling job ran, and no new encode was generated. FFmpeg/ffprobe and standalone public AVFoundation decoders read the retained test outputs.

## Stored clocks and compressed ordering

All 16 pairs retain the exact raw 72-sample source PTS multiset, output DTS `0...71/24`, and sample duration `1/24`. Raw packet-order PTS differs in all 16: source and processed H.264 have different decode ordering. For example raw decode ordinal 9 has source PTS `7/12` and output PTS `1/2`, while the complete sorted PTS multisets are identical. Equality of processed/source H.264 packet-order PTS is not established by preservation of presentation timing.

When FFmpeg applies edits, its dependency/discard packet inventory also differs: discontinuous source/output enumerate 144/102 packets; repeated enumerate 144/118. Sorted complete presentation-packet PTS agrees for 8/16 pairs. Omitting packets carrying the `D` flag agrees for 12/16. FFmpeg decoded presentation PTS also agrees for 12/16; the four internal pairs retain a reader discrepancy rather than a green result. Those source/output decoded views each enumerate 94 frames, but output replaces source PTS `5/2,61/24` with `4,97/24`.

## Native presentation control for every pair

`all-native-pairs/report.json` records all 16 source/output pairs, including the two simple internal baseline cases, with source/output hashes, native inventories, and every decoded buffer's timing/attachment facts. All 32 AVAssetReader reads completed with no source/output byte changes. Every pair has identical real/control buffer counts and identical raw/output PTS sequences in original order by exact numeric CMTimeCompare.

| Variant | Native real frames, source and output | Controls |
| --- | ---: | ---: |
| discontinuous | 48 | 0 |
| internal, instrumented and simple baseline | 72 | 0 |
| leading | 73 | 0 |
| repeated | 48 | 0 |
| scaled | 24 | 0 |
| trailing | 72 | 0 |
| trimmed | 24 | 0 |

Each count holds for both audio policies. Internal native PTS spans `0...95/24` with the single `25/24` step across its gap; source and output match. Leading's symmetric 73 returned images are recorded as reader inventory only: no claim is made about a blank frame, presentation appearance, or device/player acceptance. The FFmpeg internal discrepancy remains separately retained; these tools disagree on their edited decoded view, and its parser/decoder-internal cause was not diagnosed here.

Native clocks can use different equivalent value/timescale representations. The initial tuple-based ten-read summary was corrected to numeric rational comparison; its pre-correction JSON is retained separately. The all-pair probe compares CMTime values numerically from the outset.

## Reproduced cross-output pixel difference

The byte-hash difference is real and reproducible in both FFmpeg and native decoding. The simple internal audio=false output differs from the first sorted reference output (discontinuous audio=false): 54/72 frames are byte-identical; frames 17-28,38-40,42-44 differ. Underlying source compressed packets and full-media decoded source pixels are identical for the compared inputs, including native normalized source raster order.

The encoded picture structure differs: reference has 3 I / 49 B / 20 P frames; differing output has 3 I / 48 B / 21 P. Display-order frame 18 is B versus P, and decode-order packet PTS changes around ordinals 17-19. Nineteen compressed packets differ in payload/size or timing order. The root code inspection found the same output codec/dimensions/settings shape; no bit-exact cross-run H.264 contract is declared by these fixtures.

For all 18 differing decoded frames, the corresponding same-index reference frame is the unique nearest of all 72 reference frames by component SSE. This is evidence against a source-frame shift/drop/reorder explanation. Diagnostic eight-bit planar YUV measurements (peak 255; no acceptance threshold):

- Full 72-frame PSNR: **45.7108177843 dB**.
- Changed-frame PSNR range: **37.6924837665...49.4406138790 dB**.
- Maximum absolute component difference: **75**; changed component bytes: **108,175**.
- Y/Cb/Cr full-sequence PSNR: **45.9124191974 / 45.2597244156 / 45.4089352582 dB**.

Per-frame/per-plane difference counts, SSE, maximum deltas, bounding boxes, nearest-frame comparisons, and original/differing YUV frames are retained. The evidence supports H.264 encoding variation as the leading explanation: identical retained source pictures, changed P/B decision, unchanged frame identity/order, and differences confined to decoded reconstruction. The simple baseline did not retain pre-encode scaled pixels, so encoder variation versus an unobserved pre-encode pixel change is not conclusively separated. No tolerance or visual-quality acceptance contract was introduced.

## Separate revised stored-media checker

`checker-v2.py` and `../selected-primary-independent-media-v2.json` retain assertions for raw 72-frame/packet counts, exact stored PTS multiset, DTS/duration cadence, retained video packets, PCM and title. All 16 pairs pass those stored-media checks. Cross-output decoded byte equality and FFmpeg edited presentation comparisons are measurement fields; they remain visibly different where observed. Native presentation proof is the separate all-pair report. Creation-date comparison remains a measurement and is not resolved by this review.

The revised checker does not overwrite or relabel the original failed result. All commands, scripts, input hashes and artifact hashes are recorded in provenance.
