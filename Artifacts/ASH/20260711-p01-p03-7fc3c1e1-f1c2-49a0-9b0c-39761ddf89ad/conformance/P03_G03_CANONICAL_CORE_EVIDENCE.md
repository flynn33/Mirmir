# P03 / G03 Canonical-Core Evidence

Status: **PASS**
Assessment time: `2026-07-11T13:19:26Z`
Repository inspected: `/Users/jimdaley/GitHub/Mirmir`
Instruction package inspected: `mirmr-iA.1.0.1.0`

## Determination

All seven technical criteria in G03 are satisfied by the current implementation, shared canonical JSON contract, locked canonical fixture, independent reference implementation, and retained Xcode result. The evidence directory includes the canonical-vector index, checksum sidecar, and Swift conformance result under their phase output names.

The G03 criteria are defined in `config/audit_gates.json:52-62`. The required P03 loops and binary comparison are defined in `instructions/16_PHASE_BY_PHASE_IMPLEMENTATION_BLUEPRINT.md:79-93`.

## Canonical core

- The state is a packed 9-bit `UInt16`; values with any upper bit set are rejected (`Mirmir/Modules/UpscalerEngine/ASH/ASHState.swift:56-72`).
- Logical coordinate 1 occupies packed bit 8 and logical coordinate 9 occupies packed bit 0 (`ASHState.swift:75-105`).
- Coordinate 9 equals the XOR parity of coordinates 1 through 8 (`ASHState.swift:99-125`).
- Four message bits are interpreted most-significant-bit first (`ASHState.swift:138-167`).
- The generator rows are `111100000`, `110011000`, `101010100`, and `100110001` (`Mirmir/Modules/UpscalerEngine/ASH/ASHCode.swift:18-24`).
- Encoding is the XOR combination of selected generator rows (`ASHCode.swift:40-50`).
- Decoding succeeds only for a unique codeword at distance zero or one; every other input is rejected (`ASHCode.swift:60-86`). Affine decoding first XORs with the known anchor (`ASHCode.swift:88-100`).

The current SHA-256 values of `ASHState.swift` and `ASHCode.swift` exactly match the P00 baseline entries at `Artifacts/ASH/20260711-p00-baseline-824a5910-8b63a2ed/baseline-source.sha256:60,68`:

| File | P00 SHA-256 | Current SHA-256 | Result |
|---|---|---|---|
| `ASHCode.swift` | `b0e97c0016ee73979138e5fe5fe585a359044969e5a5df63c7561c09abe58ddc` | same | unchanged |
| `ASHState.swift` | `c96f0ef0a1e087cc3c7ac0bf821caa88d72a7e959deabae3749a6f1ad5ebdee2` | same | unchanged |

The same coordinate order, parity relation, generator matrix, and radius-one policy appear in the pinned reference at `evidence/reference_pipeline_reproduction/ash_pinned_src/ash_model/bits.py:22-38,61-85` and `ash_model/code.py:29-34,51-71,156-207` in the instruction package.

## Canonical binary layout

Both emitters consume `validation/reference/ash-core-v1.contract.json`, SHA-256 `97ff97a79257707824c91f6f99bc7495bd4b78b221e930f8614c8ce12d782936`; an identical evidence copy is retained as `conformance/ash-core-v1.contract.json`. The contract locks the core dimensions, bit and message order, parity relation, generator rows, decoder radius, binary field order, offsets, status codes, section ordering, file size, and exhaustive counts. Production Swift decodes and validates every contract field against `ASHState`, `ASHMessage`, `ASHCode.generatorRows`, and its fixed binary layout before emitting bytes (`Mirmir/Modules/UpscalerEngine/ASH/ASHCoreConformance.swift:118-214`). The independent verifier loads the same JSON and validates it against its own locked implementation and `struct` layouts before emission (`validation/reference/ash_core_oracle.py:15-180`). The application does not bundle or load the contract at runtime (`MirmirTests/ASHCoreConformanceTests.swift:7-31`; `validation/reference/README.md:9-20`).

The locked payload is `validation/reference/generated/ash-core-v1.bin`.

- Magic: ASCII `ASHCORE1`.
- Schema: 1.
- No implicit padding.
- All multibyte integers: unsigned little-endian.
- Coordinate order code 1: coordinate 1 is packed bit 8; coordinate 9 is packed bit 0.
- Decoder radius: 1.
- Total size: 3,016,832 bytes.

The 64-byte header is emitted at `ASHCoreConformance.swift:235-262` and independently packed at `validation/reference/ash_core_oracle.py:127-176,279-320`.

| Offset | Bytes | Field | Value |
|---:|---:|---|---:|
| 0 | 8 | magic | `ASHCORE1` |
| 8 | 2 | schema version | 1 |
| 10 | 2 | header size | 64 |
| 12 | 1 | state bits | 9 |
| 13 | 1 | payload bits | 8 |
| 14 | 1 | message bits | 4 |
| 15 | 1 | bit-order code | 1 |
| 16 | 1 | endianness code | 1 |
| 17 | 1 | decoder radius | 1 |
| 18 | 2 | raw-state record size | 4 |
| 20 | 2 | codeword record size | 4 |
| 22 | 2 | affine record size | 16 |
| 24 | 4 | raw-state count | 512 |
| 28 | 4 | codeword count | 16 |
| 32 | 4 | valid-anchor count | 256 |
| 36 | 4 | exact-affine count | 4,096 |
| 40 | 4 | one-bit-affine count | 36,864 |
| 44 | 4 | two-bit-affine count | 147,456 |
| 48 | 4 | raw-state offset | 64 |
| 52 | 4 | codeword offset | 2,112 |
| 56 | 4 | affine offset | 2,176 |
| 60 | 4 | file size | 3,016,832 |

Record contracts:

| Section | Size | Byte layout | Ordering |
|---|---:|---|---|
| Raw state | 4 | `raw:u16`, `payloadParity:u8`, `integrityValid:u8` | raw packed value `0...511` |
| Codeword | 4 | `message:u8`, `weight:u8`, `codeword:u16` | message `0...15` |
| Affine | 16 | `anchor:u16`, `message:u8`, `faultCount:u8`, `faultA:u8`, `faultB:u8`, `relativeCodeword:u16`, `transmitted:u16`, `received:u16`, `status:u8`, `correctedCoordinate:u8`, `distance:u8`, `nearestCount:u8` | exact section; one-bit section; two-bit section |

Affine status is `0=exact`, `1=corrected`, `2=rejected`. A zero fault coordinate means absent. Within each affine section, anchors and messages ascend. One-bit coordinates ascend `1...9`; two-bit coordinates are lexicographically ordered unordered pairs `(1,2)` through `(8,9)`. Production record emission is at `ASHCoreConformance.swift:264-387`; the complete format is documented at `validation/reference/README.md:35-114`.

## Independent reference boundary

`validation/reference/ash_core_oracle.py` loads the shared JSON, validates it against separately locked values and layouts, and implements parity, encoding, nearest-codeword decoding, affine translation, exhaustive loops, serialization, and SHA-256 calculation directly (`ash_core_oracle.py:15-180`, `:183-375`). It imports no application module or application resource. It regenerates bytes in memory before reading the locked fixture (`ash_core_oracle.py:412-425`).

The application target does not load or execute the reference script, and the shared contract is not an application resource (`validation/reference/README.md:3-20`). The XCTest comparison occurs only after production Swift emits its own byte stream (`MirmirTests/ASHCoreConformanceTests.swift:7-31`). The reference algorithm does not consume Swift-emitted expected values.

## Exhaustive loop counts

| Domain | Loop | Count | Verified behavior |
|---|---|---:|---|
| Raw states | `0...511` | 512 | parity classification checked |
| Valid anchors | parity-valid subset | 256 | exactly 256 valid and 256 invalid |
| Messages/codewords | `0...15` | 16 | exact locked codeword for every message |
| Exact affine | `256 × 16` | 4,096 | exact recovery |
| One-bit affine | `256 × 16 × 9` | 36,864 | corrected to transmitted state and original message |
| Two-bit affine | `256 × 16 × C(9,2)` | 147,456 | rejected with no recovered state or message |

Production vector loops are at `ASHCoreConformance.swift:264-336`; production semantic assertions are at `MirmirTests/ASHCoreConformanceTests.swift:57-183`; independent loops are at `ash_core_oracle.py:323-369`.

The two-bit suite covers all 36 unordered coordinate pairs for every valid anchor and message. This is stronger than a relative-codeword-only set because every affine translation is explicitly exercised.

## Byte and hash agreement

Current locked fixture:

- Path: `validation/reference/generated/ash-core-v1.bin`
- Size: `3016832`
- SHA-256: `19b1dfe4f7aa3f1e77e1364afbced3799aca261e88024c823f8cc1d68fb42776`
- Sidecar: `validation/reference/generated/ash-core-v1.sha256`

`python3 validation/reference/ash_core_oracle.py --check` returned:

```text
PASS bytes=3016832 sha256=19b1dfe4f7aa3f1e77e1364afbced3799aca261e88024c823f8cc1d68fb42776
records raw=512 codewords=16 exact=4096 one_bit=36864 two_bit=147456
contract_mutations generator_row=rejected decoder_radius=rejected
```

The retained focused Xcode result contains passing byte/hash equality, shared-contract mutation rejection, state/codeword, and affine tests. The equality test first requires exact `Data` equality and then requires both SHA-256 values to equal the sidecar (`ASHCoreConformanceTests.swift:7-31`). The mutation test alters one generator row and the decoder radius independently and requires both altered contracts to fail at the named field (`ASHCoreConformanceTests.swift:33-55`).

## Retained Xcode evidence

Result bundle:

`Artifacts/ASH/20260711-p01-p03-7fc3c1e1-f1c2-49a0-9b0c-39761ddf89ad/conformance/swift-conformance.xcresult`

The retained summary reports `Passed`, 4 passed, 0 failed, 0 skipped, on arm64 macOS 26.5.1. The run started at `2026-07-11T13:48:19Z` and finished at `2026-07-11T13:48:27Z`.

| Test | Result | Duration |
|---|---|---:|
| `test_exhaustiveProductionAffineSemantics()` | Passed | 0.722903 s |
| `test_exhaustiveProductionStateAndCodewordSemantics()` | Passed | 0.001751 s |
| `test_productionVectorsMatchIndependentLockedFixtureByteForByteAndBySHA256()` | Passed | 1.074104 s |
| `test_sharedCanonicalContractRejectsGeneratorRowAndDecoderRadiusMutations()` | Passed | 0.000947 s |

The retained full Debug result also reports `Passed`, with 82 passed, 0 failed, and 1 explicitly configured production-fixture test skipped in the ordinary suite:

`Artifacts/ASH/20260711-p01-p03-7fc3c1e1-f1c2-49a0-9b0c-39761ddf89ad/tests/full-debug-pass.xcresult`

Current conformance source hashes:

| File | SHA-256 |
|---|---|
| `Mirmir/Modules/UpscalerEngine/ASH/ASHCoreConformance.swift` | `0f142ef338137cf15deb416c97413e0d0a21451d433464c8914eed999df62f61` |
| `MirmirTests/ASHCoreConformanceTests.swift` | `333a8698c7bcad6a8e5a2896f8dffd538a39f6c955186225d052d642269709d2` |
| `validation/reference/ash_core_oracle.py` | `8f4626ffc8284087a1f463c4e314166c6acf344ff6fe900682a8fcd215060c11` |
| `validation/reference/ash-core-v1.contract.json` | `97ff97a79257707824c91f6f99bc7495bd4b78b221e930f8614c8ce12d782936` |
| `validation/reference/README.md` | `41dbfb19c1ba314296a2b2edea4efc08e6139fbdb6c95d3b1da301a0c990b39c` |
| `validation/reference/generated/ash-core-v1.bin` | `19b1dfe4f7aa3f1e77e1364afbced3799aca261e88024c823f8cc1d68fb42776` |

## Exact commands

Run from `/Users/jimdaley/GitHub/Mirmir`.

Independent locked-fixture verification:

```sh
python3 validation/reference/ash_core_oracle.py --check
```

Focused P03 Xcode reproduction using fresh temporary outputs:

```sh
RESULT_BUNDLE="/tmp/mirmir-p03-focused-$(uuidgen).xcresult"
xcodebuild \
  -project Mirmir.xcodeproj \
  -scheme Mirmir \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/mirmir-p03-deriveddata \
  -resultBundlePath "$RESULT_BUNDLE" \
  -only-testing:MirmirTests/ASHCoreConformanceTests \
  test
xcrun xcresulttool get test-results summary --path "$RESULT_BUNDLE"
xcrun xcresulttool get test-results tests --path "$RESULT_BUNDLE"
```

Retained-result inspection:

```sh
xcrun xcresulttool get test-results summary \
  --path Artifacts/ASH/20260711-p01-p03-7fc3c1e1-f1c2-49a0-9b0c-39761ddf89ad/conformance/swift-conformance.xcresult
xcrun xcresulttool get test-results tests \
  --path Artifacts/ASH/20260711-p01-p03-7fc3c1e1-f1c2-49a0-9b0c-39761ddf89ad/conformance/swift-conformance.xcresult
```

Core preservation check against P00:

```sh
shasum -a 256 \
  Mirmir/Modules/UpscalerEngine/ASH/ASHState.swift \
  Mirmir/Modules/UpscalerEngine/ASH/ASHCode.swift
rg -n 'Mirmir/Modules/UpscalerEngine/ASH/ASH(State|Code)\.swift' \
  Artifacts/ASH/20260711-p00-baseline-824a5910-8b63a2ed/baseline-source.sha256
```

## G03 criterion assessment

| Criterion | Result | Evidence |
|---|---|---|
| All 512 states checked | PASS | Raw loop and classification at `ASHCoreConformanceTests.swift:57-77`; count embedded in fixture header |
| 256 valid parity states checked | PASS | Valid and invalid counts asserted at `ASHCoreConformanceTests.swift:75-77`; anchors rechecked at lines 114-118 |
| 16 codewords checked | PASS | Locked codeword list and exhaustive message loop at `ASHCoreConformanceTests.swift:79-112` |
| All one-bit affine corruptions corrected | PASS | All 36,864 anchor/message/coordinate cases asserted at `ASHCoreConformanceTests.swift:114-155,180-182` |
| All required two-bit corruptions rejected | PASS | All 147,456 anchor/message/pair cases asserted at `ASHCoreConformanceTests.swift:157-182` |
| Production Swift and independent reference vectors and hashes match exactly | PASS | Shared contract validation and mutation rejection at `ASHCoreConformance.swift:118-214` and `ASHCoreConformanceTests.swift:33-55`; exact byte/hash equality at `ASHCoreConformanceTests.swift:7-31`; retained result and independent `--check` passed |
| Canonical core unchanged or approved change recorded | PASS, unchanged branch | Current `ASHState.swift` and `ASHCode.swift` SHA-256 values exactly equal their P00 baseline values |

Overall G03 technical assessment: **PASS**.

## Limitations and platform resolution

- This evidence proves the finite canonical bit core. It does not prove video-state mapping v2, compiled dispatch behavior, Metal pixel parity, upscaling quality, performance, geometry/color/audio handling, or media-route completion.
- `canonical-vectors.json` indexes the deterministic `ash-core-v1.bin` payload and its exact record counts without altering the locked bytes.
- The lower phase inventory names a Windows `.trx` output. The controlling macOS/Xcode scope supersedes that platform label; `platform-output-resolution.json` records the resolution, and no synthetic `.trx` was fabricated.
- The two implementations are separate but intentionally consume the same hash-locked JSON contract; each rejects contract fields that differ from its own implementation and layout.
