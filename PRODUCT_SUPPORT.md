# Mirmir product support

Mirmir is a sandboxed macOS 15.4-or-later app. It reads one enabled local video track, writes a QuickTime movie atomically, and exposes each processing backend explicitly. A backend failure never invokes a different scaler under the same selection.

## Implemented backends

| Backend | Current contract |
| --- | --- |
| Mirmir Deterministic — CPU Reference (Preview) | Explicit selection only. Exact ASH 2× and 3:2 routes, progressive 8-bit `420v`/`420f` NV12, recognized chroma siting, sequential processing, and no Apple fallback. |
| Mirmir Deterministic — Metal Accelerated (Preview) | Explicit selection only. Exact ASH 2× and 3:2 routes, progressive 8-bit `420v`/`420f` NV12, recognized chroma siting, and no backend fallback. The checked-in P05 definitions are serialized into the existing Metal ABI in memory during preparation, so no external runtime files are required. This development input is not represented as a release-locked artifact. |
| VideoToolbox Super Resolution — Quality | macOS 26 or later, dimensions/factors reported by the current API, and an explicit system-model download when VideoToolbox reports it is required. |
| VideoToolbox Super Resolution — Low Latency | macOS 26 or later and only dimensions/factors/pixel formats accepted by the current API. |
| VideoToolbox Smooth Motion + Spatial Upscale | macOS 26 or later, 2× spatial scale and the API-supported midpoint phase, producing 2× cadence without changing normal playback duration. The first reference frame uses a disclosed VideoToolbox pixel-transfer boundary scale. |
| MetalFX Spatial | MetalFX-capable GPU, video-range 8-bit NV12, and explicit BT.709 primaries/transfer/matrix. Uses an audited NV12 ↔ linear RGBA16Float bridge. |
| MPS Lanczos / Bilinear | Metal Performance Shaders with progressive SDR 8-bit NV12 and explicit range. |
| Core Image Lanczos / Bicubic | Progressive SDR 8-bit NV12 with explicit range. This is a filter conversion/resampling path, not code-value preservation. |
| Accelerate/vImage High Quality / Standard | Progressive SDR 8-bit NV12 with explicit video/full range. |
| VideoToolbox Pixel Transfer | Progressive SDR 8-bit NV12 with explicit range. |

Automatic uses one fixed documented order and considers spatial-only Apple backends. It excludes Deterministic and Smooth Motion.

## Deterministic Metal preview validation

The preview runs the six checked-in Metal kernels through the product backend and preserves the exact `mirmirDeterministicMetal` identity on success or failure. It never substitutes the CPU reference backend. Metal fast math is disabled, and FP32 functions are compiled in precise mode. On the validated Apple-silicon Mac, repeated Metal executions produced byte-identical output for both routes, both supported NV12 ranges, and constant, ramp, impulse, and directional-edge patterns.

Metal output is not advertised as bit-identical to the CPU reference. In that bounded pattern matrix, constant frames matched exactly; non-constant frames had maximum absolute code-value differences from 4 through 19, with an overall observed maximum of 19. These measurements describe the tested preview contract, not a general error bound or a release-lock certification.

## Media behavior and limitations

- Output codecs: HEVC, H.264, and Apple ProRes 422 in a `.mov` container.
- One audio track is passed through when compatible; otherwise it is decoded to PCM and encoded as AAC. Silent input remains silent. Alternate audio, subtitles, captions, chapters, timecode, and auxiliary tracks are not copied.
- Source PTS is preserved for spatial processing, including variable-rate input. Smooth Motion synthesizes midpoint PTS and retains source playback duration/audio timing.
- The encoded raster is scaled and the source preferred transform is retained, so portrait display orientation remains correct.
- Color primaries, transfer function, YCbCr matrix, chroma location, and range are propagated under the supported 8-bit contracts.
- No implemented path preserves P010/10-bit HDR end to end. HDR inputs are marked unavailable; Mirmir does not silently tone-map them to SDR.
- One enabled video track is supported. Interlaced video, non-square pixels, explicit clean-aperture rescaling, alpha, and arbitrary Deterministic geometry are unavailable with specific reasons.
- Existing destinations require explicit replacement. Work is written to a sibling temporary file, validated, and published atomically; cancellation and failure discard the temporary output.
