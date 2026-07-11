#!/usr/bin/env python3
"""Generate and verify the independent ASH canonical-core binary fixture."""

from __future__ import annotations

import argparse
import hashlib
import json
import struct
from itertools import combinations
from pathlib import Path
from typing import Optional


SCRIPT_ROOT = Path(__file__).resolve().parent
CONTRACT_PATH = SCRIPT_ROOT / "ash-core-v1.contract.json"
GENERATED_ROOT = SCRIPT_ROOT / "generated"
FIXTURE_PATH = GENERATED_ROOT / "ash-core-v1.bin"
HASH_PATH = GENERATED_ROOT / "ash-core-v1.sha256"


class ContractError(ValueError):
    """The shared canonical contract differs from the locked core."""


def require_contract_value(contract: dict, keys: tuple[str, ...], expected: object) -> None:
    value: object = contract
    for key in keys:
        if not isinstance(value, dict) or key not in value:
            raise ContractError(f"missing contract field {'.'.join(keys)}")
        value = value[key]
    if type(value) is not type(expected) or value != expected:
        raise ContractError(
            f"contract mismatch for {'.'.join(keys)}: expected {expected!r}, received {value!r}"
        )


def validate_contract(contract: dict) -> None:
    locked_values = {
        ("contract_schema_version",): 1,
        ("core", "state_bits"): 9,
        ("core", "payload_bits"): 8,
        ("core", "message_bits"): 4,
        ("core", "coordinate_1_packed_bit"): 8,
        ("core", "coordinate_9_packed_bit"): 0,
        ("core", "message_bit_1_order"): "most_significant",
        ("core", "integrity_coordinate"): 9,
        ("core", "integrity_operation"): "xor",
        ("core", "integrity_source_coordinates"): list(range(1, 9)),
        ("core", "generator_rows"): [
            "111100000",
            "110011000",
            "101010100",
            "100110001",
        ],
        ("binary", "magic"): "ASHCORE1",
        ("binary", "schema_version"): 1,
        ("binary", "endianness"): "little",
        ("binary", "endianness_code"): 1,
        ("binary", "bit_order_code"): 1,
        ("binary", "decoder_radius"): 1,
        ("binary", "implicit_padding"): False,
        ("binary", "header_size"): 64,
        ("binary", "record_sizes", "raw_state"): 4,
        ("binary", "record_sizes", "codeword"): 4,
        ("binary", "record_sizes", "affine"): 16,
        ("binary", "section_offsets", "raw_state"): 64,
        ("binary", "section_offsets", "codeword"): 2112,
        ("binary", "section_offsets", "affine"): 2176,
        ("binary", "file_size"): 3016832,
        ("binary", "status_codes", "exact"): 0,
        ("binary", "status_codes", "corrected"): 1,
        ("binary", "status_codes", "rejected"): 2,
        ("binary", "affine_section_order"): ["exact", "one_bit", "two_bit"],
        ("binary", "raw_state_field_order"): [
            "raw_u16",
            "payload_parity_u8",
            "integrity_valid_u8",
        ],
        ("binary", "codeword_field_order"): [
            "message_u8",
            "hamming_weight_u8",
            "codeword_u16",
        ],
        ("binary", "affine_field_order"): [
            "anchor_u16",
            "message_u8",
            "fault_count_u8",
            "first_fault_coordinate_u8",
            "second_fault_coordinate_u8",
            "relative_codeword_u16",
            "transmitted_affine_u16",
            "received_affine_u16",
            "status_u8",
            "corrected_coordinate_u8",
            "nearest_distance_u8",
            "nearest_count_u8",
        ],
        ("exhaustive", "raw_state_count"): 512,
        ("exhaustive", "valid_anchor_count"): 256,
        ("exhaustive", "codeword_count"): 16,
        ("exhaustive", "exact_affine_count"): 4096,
        ("exhaustive", "one_bit_affine_count"): 36864,
        ("exhaustive", "two_bit_fault_pair_count"): 36,
        ("exhaustive", "two_bit_affine_count"): 147456,
    }
    for keys, expected in locked_values.items():
        require_contract_value(contract, keys, expected)


def load_contract(path: Path = CONTRACT_PATH) -> dict:
    try:
        contract = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ContractError(f"unable to load {path}: {error}") from error
    if not isinstance(contract, dict):
        raise ContractError("contract root must be a JSON object")
    validate_contract(contract)
    return contract


CONTRACT = load_contract()
CORE_CONTRACT = CONTRACT["core"]
BINARY_CONTRACT = CONTRACT["binary"]
EXHAUSTIVE_CONTRACT = CONTRACT["exhaustive"]

MAGIC = BINARY_CONTRACT["magic"].encode("ascii")
SCHEMA_VERSION = BINARY_CONTRACT["schema_version"]
STATE_BITS = CORE_CONTRACT["state_bits"]
PAYLOAD_BITS = CORE_CONTRACT["payload_bits"]
MESSAGE_BITS = CORE_CONTRACT["message_bits"]
BIT_ORDER_CODE = BINARY_CONTRACT["bit_order_code"]
ENDIANNESS_CODE = BINARY_CONTRACT["endianness_code"]
DECODER_RADIUS = BINARY_CONTRACT["decoder_radius"]

RAW_STATE_COUNT = EXHAUSTIVE_CONTRACT["raw_state_count"]
CODEWORD_COUNT = EXHAUSTIVE_CONTRACT["codeword_count"]
VALID_ANCHOR_COUNT = EXHAUSTIVE_CONTRACT["valid_anchor_count"]
EXACT_AFFINE_COUNT = EXHAUSTIVE_CONTRACT["exact_affine_count"]
ONE_BIT_AFFINE_COUNT = EXHAUSTIVE_CONTRACT["one_bit_affine_count"]
TWO_BIT_AFFINE_COUNT = EXHAUSTIVE_CONTRACT["two_bit_affine_count"]
TWO_BIT_FAULT_PAIR_COUNT = EXHAUSTIVE_CONTRACT["two_bit_fault_pair_count"]

HEADER = struct.Struct("<8sHH6B3H10I")
RAW_STATE_RECORD = struct.Struct("<HBB")
CODEWORD_RECORD = struct.Struct("<BBH")
AFFINE_RECORD = struct.Struct("<HBBBBHHHBBBB")

HEADER_SIZE = HEADER.size
RAW_STATE_RECORDS_OFFSET = HEADER_SIZE
CODEWORD_RECORDS_OFFSET = RAW_STATE_RECORDS_OFFSET + RAW_STATE_COUNT * RAW_STATE_RECORD.size
AFFINE_RECORDS_OFFSET = CODEWORD_RECORDS_OFFSET + CODEWORD_COUNT * CODEWORD_RECORD.size
FILE_SIZE = AFFINE_RECORDS_OFFSET + (
    EXACT_AFFINE_COUNT + ONE_BIT_AFFINE_COUNT + TWO_BIT_AFFINE_COUNT
) * AFFINE_RECORD.size

if HEADER_SIZE != BINARY_CONTRACT["header_size"]:
    raise ContractError("runtime header size differs from the shared contract")
if RAW_STATE_RECORD.size != BINARY_CONTRACT["record_sizes"]["raw_state"]:
    raise ContractError("runtime raw-state record size differs from the shared contract")
if CODEWORD_RECORD.size != BINARY_CONTRACT["record_sizes"]["codeword"]:
    raise ContractError("runtime codeword record size differs from the shared contract")
if AFFINE_RECORD.size != BINARY_CONTRACT["record_sizes"]["affine"]:
    raise ContractError("runtime affine record size differs from the shared contract")
if RAW_STATE_RECORDS_OFFSET != BINARY_CONTRACT["section_offsets"]["raw_state"]:
    raise ContractError("runtime raw-state offset differs from the shared contract")
if CODEWORD_RECORDS_OFFSET != BINARY_CONTRACT["section_offsets"]["codeword"]:
    raise ContractError("runtime codeword offset differs from the shared contract")
if AFFINE_RECORDS_OFFSET != BINARY_CONTRACT["section_offsets"]["affine"]:
    raise ContractError("runtime affine offset differs from the shared contract")
if FILE_SIZE != BINARY_CONTRACT["file_size"]:
    raise ContractError("runtime file size differs from the shared contract")

STATUS_EXACT = BINARY_CONTRACT["status_codes"]["exact"]
STATUS_CORRECTED = BINARY_CONTRACT["status_codes"]["corrected"]
STATUS_REJECTED = BINARY_CONTRACT["status_codes"]["rejected"]

# Coordinate 1 is the most-significant of the low nine packed bits. Message
# bit 1 selects row 1, continuing in display order through message bit 4.
GENERATOR_ROWS = tuple(int(row, 2) for row in CORE_CONTRACT["generator_rows"])


def encode(message: int) -> int:
    if not 0 <= message < CODEWORD_COUNT:
        raise ValueError("message must fit in four bits")
    codeword = 0
    for row_index, row in enumerate(GENERATOR_ROWS):
        if message & (1 << (MESSAGE_BITS - 1 - row_index)):
            codeword ^= row
    return codeword


CODEWORDS_BY_MESSAGE = tuple(encode(message) for message in range(CODEWORD_COUNT))
MESSAGE_BY_CODEWORD = {
    codeword: message for message, codeword in enumerate(CODEWORDS_BY_MESSAGE)
}


def is_integrity_valid(raw_state: int) -> bool:
    if not 0 <= raw_state < RAW_STATE_COUNT:
        raise ValueError("state must fit in the low nine bits")
    payload_parity = hamming_weight(raw_state >> 1) & 1
    coordinate_nine = raw_state & 1
    return coordinate_nine == payload_parity


def hamming_weight(value: int) -> int:
    return bin(value).count("1")


def decode_relative(received: int) -> tuple[int, int, Optional[int]]:
    distances = tuple(hamming_weight(received ^ codeword) for codeword in CODEWORDS_BY_MESSAGE)
    minimum = min(distances)
    nearest_messages = tuple(
        message for message, distance in enumerate(distances) if distance == minimum
    )
    if minimum <= DECODER_RADIUS and len(nearest_messages) == 1:
        return minimum, 1, nearest_messages[0]
    return minimum, len(nearest_messages), None


def status_for(distance: int, message: Optional[int]) -> int:
    if message is None:
        return STATUS_REJECTED
    return STATUS_EXACT if distance == 0 else STATUS_CORRECTED


def valid_anchors() -> tuple[int, ...]:
    anchors = tuple(raw for raw in range(RAW_STATE_COUNT) if is_integrity_valid(raw))
    if len(anchors) != VALID_ANCHOR_COUNT:
        raise AssertionError("unexpected parity-valid anchor count")
    return anchors


def affine_record(
    *,
    anchor: int,
    message: int,
    fault_coordinates: tuple[int, ...],
) -> bytes:
    codeword = CODEWORDS_BY_MESSAGE[message]
    transmitted = anchor ^ codeword
    received = transmitted
    for coordinate in fault_coordinates:
        if not 1 <= coordinate <= STATE_BITS:
            raise AssertionError("fault coordinate outside 1...9")
        received ^= 1 << (STATE_BITS - coordinate)

    distance, nearest_count, decoded_message = decode_relative(received ^ anchor)
    status = status_for(distance, decoded_message)
    fault_count = len(fault_coordinates)
    expected_status = (STATUS_EXACT, STATUS_CORRECTED, STATUS_REJECTED)[fault_count]
    if status != expected_status or distance != fault_count:
        raise AssertionError("strict affine recovery contract changed")
    if fault_count < 2 and decoded_message != message:
        raise AssertionError("affine recovery returned the wrong message")
    if fault_count == 2 and decoded_message is not None:
        raise AssertionError("two-bit corruption was silently decoded")

    first_coordinate = fault_coordinates[0] if fault_count >= 1 else 0
    second_coordinate = fault_coordinates[1] if fault_count == 2 else 0
    corrected_coordinate = first_coordinate if fault_count == 1 else 0
    return AFFINE_RECORD.pack(
        anchor,
        message,
        fault_count,
        first_coordinate,
        second_coordinate,
        codeword,
        transmitted,
        received,
        status,
        corrected_coordinate,
        distance,
        nearest_count,
    )


def generate_fixture() -> bytes:
    if HEADER_SIZE != 64 or RAW_STATE_RECORD.size != 4:
        raise AssertionError("binary header or raw-state record size changed")
    if CODEWORD_RECORD.size != 4 or AFFINE_RECORD.size != 16:
        raise AssertionError("binary codeword or affine record size changed")
    if len(set(CODEWORDS_BY_MESSAGE)) != CODEWORD_COUNT:
        raise AssertionError("generator rows do not produce 16 distinct codewords")
    if EXACT_AFFINE_COUNT != VALID_ANCHOR_COUNT * CODEWORD_COUNT:
        raise AssertionError("exact affine count differs from shared contract dimensions")
    if ONE_BIT_AFFINE_COUNT != EXACT_AFFINE_COUNT * STATE_BITS:
        raise AssertionError("one-bit affine count differs from shared contract dimensions")
    if TWO_BIT_FAULT_PAIR_COUNT != len(tuple(combinations(range(1, STATE_BITS + 1), 2))):
        raise AssertionError("two-bit fault-pair count differs from shared contract dimensions")
    if TWO_BIT_AFFINE_COUNT != EXACT_AFFINE_COUNT * TWO_BIT_FAULT_PAIR_COUNT:
        raise AssertionError("two-bit affine count differs from shared contract dimensions")

    payload = bytearray()
    payload.extend(
        HEADER.pack(
            MAGIC,
            SCHEMA_VERSION,
            HEADER_SIZE,
            STATE_BITS,
            PAYLOAD_BITS,
            MESSAGE_BITS,
            BIT_ORDER_CODE,
            ENDIANNESS_CODE,
            DECODER_RADIUS,
            RAW_STATE_RECORD.size,
            CODEWORD_RECORD.size,
            AFFINE_RECORD.size,
            RAW_STATE_COUNT,
            CODEWORD_COUNT,
            VALID_ANCHOR_COUNT,
            EXACT_AFFINE_COUNT,
            ONE_BIT_AFFINE_COUNT,
            TWO_BIT_AFFINE_COUNT,
            RAW_STATE_RECORDS_OFFSET,
            CODEWORD_RECORDS_OFFSET,
            AFFINE_RECORDS_OFFSET,
            FILE_SIZE,
        )
    )

    for raw_state in range(RAW_STATE_COUNT):
        payload_parity = hamming_weight(raw_state >> 1) & 1
        payload.extend(
            RAW_STATE_RECORD.pack(
                raw_state,
                payload_parity,
                int(is_integrity_valid(raw_state)),
            )
        )
    if len(payload) != CODEWORD_RECORDS_OFFSET:
        raise AssertionError("raw-state section length mismatch")

    for message, codeword in enumerate(CODEWORDS_BY_MESSAGE):
        if not is_integrity_valid(codeword):
            raise AssertionError("generated codeword violates coordinate-9 parity")
        payload.extend(CODEWORD_RECORD.pack(message, hamming_weight(codeword), codeword))
    if len(payload) != AFFINE_RECORDS_OFFSET:
        raise AssertionError("codeword section length mismatch")

    anchors = valid_anchors()
    for anchor in anchors:
        for message in range(CODEWORD_COUNT):
            payload.extend(affine_record(anchor=anchor, message=message, fault_coordinates=()))

    for anchor in anchors:
        for message in range(CODEWORD_COUNT):
            for coordinate in range(1, STATE_BITS + 1):
                payload.extend(
                    affine_record(
                        anchor=anchor,
                        message=message,
                        fault_coordinates=(coordinate,),
                    )
                )

    for anchor in anchors:
        for message in range(CODEWORD_COUNT):
            for first_coordinate, second_coordinate in combinations(
                range(1, STATE_BITS + 1), 2
            ):
                payload.extend(
                    affine_record(
                        anchor=anchor,
                        message=message,
                        fault_coordinates=(first_coordinate, second_coordinate),
                    )
                )

    if len(payload) != FILE_SIZE:
        raise AssertionError(
            f"fixture size mismatch: expected {FILE_SIZE}, generated {len(payload)}"
        )
    return bytes(payload)


def sha256_hex(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def check_contract_mutation_rejection() -> None:
    mutations = (
        (("core", "generator_rows"), ["011100000", *CORE_CONTRACT["generator_rows"][1:]]),
        (("binary", "decoder_radius"), 2),
    )
    for keys, replacement in mutations:
        mutated = json.loads(json.dumps(CONTRACT))
        target = mutated
        for key in keys[:-1]:
            target = target[key]
        target[keys[-1]] = replacement
        try:
            validate_contract(mutated)
        except ContractError as error:
            if ".".join(keys) not in str(error):
                raise AssertionError("contract mutation failed at an unexpected field") from error
        else:
            raise AssertionError(f"contract mutation was accepted for {'.'.join(keys)}")


def write_locked_fixture() -> None:
    fixture = generate_fixture()
    GENERATED_ROOT.mkdir(parents=True, exist_ok=True)
    FIXTURE_PATH.write_bytes(fixture)
    with HASH_PATH.open("w", encoding="ascii", newline="\n") as stream:
        stream.write(f"{sha256_hex(fixture)}  {FIXTURE_PATH.name}\n")
    print(f"wrote {FIXTURE_PATH} ({len(fixture)} bytes)")
    print(f"sha256 {sha256_hex(fixture)}")


def check_locked_fixture() -> None:
    check_contract_mutation_rejection()
    generated = generate_fixture()
    locked = FIXTURE_PATH.read_bytes()
    sidecar_fields = HASH_PATH.read_text(encoding="ascii").split()
    if len(sidecar_fields) != 2 or sidecar_fields[1] != FIXTURE_PATH.name:
        raise AssertionError("invalid SHA-256 sidecar format")
    expected_hash = sidecar_fields[0]
    generated_hash = sha256_hex(generated)
    locked_hash = sha256_hex(locked)
    if generated != locked:
        raise AssertionError("locked fixture differs from independent regeneration")
    if generated_hash != expected_hash or locked_hash != expected_hash:
        raise AssertionError("locked fixture SHA-256 mismatch")
    print(f"PASS bytes={len(locked)} sha256={locked_hash}")
    print(
        "records "
        f"raw={RAW_STATE_COUNT} codewords={CODEWORD_COUNT} "
        f"exact={EXACT_AFFINE_COUNT} one_bit={ONE_BIT_AFFINE_COUNT} "
        f"two_bit={TWO_BIT_AFFINE_COUNT}"
    )
    print("contract_mutations generator_row=rejected decoder_radius=rejected")


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--write", action="store_true", help="write the locked fixture")
    mode.add_argument("--check", action="store_true", help="verify the locked fixture")
    return parser.parse_args()


def main() -> None:
    arguments = parse_arguments()
    if arguments.write:
        write_locked_fixture()
    else:
        check_locked_fixture()


if __name__ == "__main__":
    main()
