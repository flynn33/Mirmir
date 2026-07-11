# ASH canonical-core conformance fixture

`ash_core_oracle.py` is an independent, test-only implementation of the
canonical nine-bit ASH state, coordinate-9 parity, `[9,4,4]` encoder, affine
XOR orbit, and strict radius-one decoder. It does not import application code,
application resources, or generated fixture data. The application does not
load or execute this script.

`ash-core-v1.contract.json` is the shared canonical input for both conformance
generators. It locks the core dimensions, coordinate and message order, parity
relation, generator rows, decoder radius, binary layout, status codes, section
ordering, and exhaustive counts. Production Swift validates it against
`ASHState`, `ASHMessage`, `ASHCode.generatorRows`, and the fixed binary layout
before emitting vectors. The independent script validates the same JSON against
its own locked implementation before generating bytes.

The JSON remains under `validation/reference`; it is not declared as an Xcode
application or test resource. XCTest reads it from the source tree and passes
its URL to the production conformance emitter. The application does not search
for, bundle, or load the contract at runtime.

The locked fixture is `generated/ash-core-v1.bin`; its SHA-256 sidecar is
`generated/ash-core-v1.sha256`. Regenerate and verify it with:

```sh
python3 validation/reference/ash_core_oracle.py --write
python3 validation/reference/ash_core_oracle.py --check
```

The `--check` path also mutates one generator row and the decoder radius in
memory and requires both altered contracts to be rejected before fixture
comparison. `ASHCoreConformanceTests` performs the corresponding production
Swift mutation checks.

## Binary contract

All multibyte integers are unsigned and little-endian. There is no implicit
padding. Coordinate 1 is the first logical coordinate and occupies packed bit
8; coordinate 9 occupies packed bit 0. Message bit 1 is the most-significant
of the four message bits. Fault coordinates are one-based; zero means absent.

The 64-byte header is:

| Offset | Bytes | Field | Locked value |
|---:|---:|---|---:|
| 0 | 8 | ASCII magic | `ASHCORE1` |
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
| 32 | 4 | parity-valid anchor count | 256 |
| 36 | 4 | exact affine record count | 4,096 |
| 40 | 4 | one-bit affine record count | 36,864 |
| 44 | 4 | two-bit affine record count | 147,456 |
| 48 | 4 | raw-state section offset | 64 |
| 52 | 4 | codeword section offset | 2,112 |
| 56 | 4 | affine section offset | 2,176 |
| 60 | 4 | total file size | 3,016,832 |

Each four-byte raw-state record contains:

| Offset | Bytes | Field |
|---:|---:|---|
| 0 | 2 | packed raw state |
| 2 | 1 | XOR parity of coordinates 1 through 8 |
| 3 | 1 | coordinate-9 integrity validity, 0 or 1 |

Raw-state records are ordered by packed value `0...511`.

Each four-byte codeword record contains:

| Offset | Bytes | Field |
|---:|---:|---|
| 0 | 1 | packed message `0...15` |
| 1 | 1 | codeword Hamming weight |
| 2 | 2 | packed codeword |

Codeword records are ordered by packed message.

Each 16-byte affine record contains:

| Offset | Bytes | Field |
|---:|---:|---|
| 0 | 2 | parity-valid source anchor |
| 2 | 1 | packed message |
| 3 | 1 | fault count, 0, 1, or 2 |
| 4 | 1 | first fault coordinate |
| 5 | 1 | second fault coordinate |
| 6 | 2 | relative codeword |
| 8 | 2 | transmitted affine state, `anchor XOR codeword` |
| 10 | 2 | received affine state after declared faults |
| 12 | 1 | status: 0 exact, 1 corrected, 2 rejected |
| 13 | 1 | corrected coordinate, or 0 |
| 14 | 1 | nearest-codeword distance |
| 15 | 1 | number of codewords at that distance |

Affine sections are concatenated in this order:

1. Exact: anchor ascending, then message ascending.
2. One-bit: anchor, message, then fault coordinate `1...9`.
3. Two-bit: anchor, message, then every lexicographically ordered unordered
   coordinate pair from `(1,2)` through `(8,9)`.

This order serializes all 4,096 anchor/message affine states, all 36,864
one-bit corruptions, and all 147,456 anchor-expanded two-bit corruptions.
