# Coordinate and anisotropy diagnostic addendum

This addendum preserves a bounded interpretation of the older open-development corrective diagnostic. The canonical [receipt](evidence/coordinate-anisotropy-diagnostic-receipt-v1.json) binds the published coordinate, risk-state, and envelope files by full-file SHA-256, embedded self-hash, and byte size. It records development-only status, no selected winner, no validation or holdout access, and no numerical fallbacks.

## Measured pattern

All deltas below are engine-raw arithmetic means of paired per-observation metric deltas, rounded to 12 decimal places. Positive values favor the left-hand cell named in the receipt.

For `direct_2x`, changing both planes from half-pixel to source-aligned coordinates at zero anisotropy improved every measured plane metric in every one of the 12 observations:

| Metric | Source-aligned minus half-pixel |
| --- | ---: |
| Y PSNR | +1.970768927341 dB |
| Y SSIM / MS-SSIM | +0.012562306335 / +0.007032063228 |
| Cb PSNR | +0.646447796827 dB |
| Cb SSIM / MS-SSIM | +0.001305669893 / +0.000330488567 |
| Cr PSNR | +0.822324319249 dB |
| Cr SSIM / MS-SSIM | +0.002744420352 / +0.000879350258 |

At source-aligned coordinates, changing both planes from anisotropy strength 0 to 3072 reduced Y, Cb, and Cr PSNR by 0.387117097971 dB, 0.569358651840 dB, and 0.616292853328 dB respectively; all six corresponding SSIM and MS-SSIM means also declined. The measured `direct_2x` evidence therefore favors `SS-00` over the diagnostic comparison baseline `SS-33`.

For `direct_3_over_2`, half-pixel luma minus source-aligned luma at zero anisotropy improved mean Y PSNR by 0.430047651058 dB, Y SSIM by 0.000835969353, and Y MS-SSIM by 0.000615560194. The observation counts were 5/6, 3/6, and 5/6, so this was not uniform. Chroma remained a tradeoff: source-aligned minus half-pixel changed Cb PSNR by -0.097151744932 dB but Cr PSNR by +0.048452814591 dB. Chroma anisotropy at half-pixel improved mean Cb PSNR by 0.041932232878 dB while reducing mean Cr PSNR by 0.007504777145 dB. At source-aligned coordinates, luma anisotropy reduced all three luma means in all six observations, while chroma anisotropy reduced Cb and Cr PSNR and SSIM means.

## Scope boundary

The receipt preserves 32 route/cell blocks, 31 full-corpus composition bindings, 18 native records, 18 production-reference observations, and zero fallbacks across 864 plane records. The production-V2 outputs match `direct_2x-HH-00` and `direct_3_over_2-SS-00` exactly. The `SS-33` composition is only a diagnostic baseline; it is not a winner.

The native source manifest binds 39 source files. Compared with checkpoint `30d9456b4464965bf38c624b89a234bd07f303fc`, 16 differ and the source manifest contains no commit binding. The diagnostic has metric rows but no formal gate checks or failure list. It tested only coordinate policies half-pixel/source-aligned and anisotropy strengths 0/3072.

The evidence supports preserving route-and-plane-specific coordinate policy through the compiler and runtime contracts. It does not authorize fixed anisotropy strength 3072, a formal gate result, a selected winner, or equivalence to current source. Those claims require a fresh current-source formal gate evaluation.
