# ASH Reference Pipeline Audit

Repository: `flynn33/ASH-Model`  
Commit: `8782886a8cca9fa63f7d44b529add6eac80a50f8`

## Exhaustive findings

- Integrity-valid source states enumerated: **256**.
- Aggregate branch-prior map identical across every state: **True**.
- Candidate sets, scores, rankings, and reconstruction hashes identical across every state for one fixed source patch: **True**.
- Branch-node affine states change with the source state: **True**.
- Branch messages and weights remain unchanged: **True**.

### Aggregate depth-four message priors

| Message | Prior |
|---|---:|
| `0000` | 0.1328125000 |
| `0001` | 0.0937500000 |
| `0010` | 0.0937500000 |
| `0011` | 0.0546875000 |
| `0100` | 0.0937500000 |
| `0101` | 0.0703125000 |
| `0110` | 0.0546875000 |
| `0111` | 0.0312500000 |
| `1000` | 0.0937500000 |
| `1001` | 0.0546875000 |
| `1010` | 0.0703125000 |
| `1011` | 0.0312500000 |
| `1100` | 0.0546875000 |
| `1101` | 0.0312500000 |
| `1110` | 0.0312500000 |
| `1111` | 0.0078125000 |

## First-frame selection

- Random 8×8 patches tested: **1000**.
- Top-one counts: `{"0000": 1000}`.
- Nearest/`0000` consistency score: **1**.
- `0000` prior: **0.1328125000**.
- Highest nonzero-message prior: **0.0937500000**.
- `0000` strictly dominates when no previous reconstruction is supplied: **True**.

## Operator basis

- Nominal messages: **16**.
- Distinct outputs on the test patch after grouping at 1e-14: **12**.
- Equal-and-opposite isotropic-message pairs:
  - `0000~0011`: maximum absolute difference `1.1102230246251565e-16`
  - `0100~0111`: maximum absolute difference `1.1102230246251565e-16`
  - `1000~1011`: maximum absolute difference `1.1102230246251565e-16`
  - `1100~1111`: maximum absolute difference `1.1102230246251565e-16`

## Branch geometry

- Aggregate message priors unchanged after changing turn angle and length decay: **True**.

## Interpretation boundary

These results audit the pinned ASH Python reference pipeline. They do not prove that Mirmir's Swift port is instruction-for-instruction identical. A direct Mirmir source audit and Instruments/Metal capture are required for implementation-level attribution inside Mirmir.
