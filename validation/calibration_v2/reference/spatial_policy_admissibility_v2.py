"""Deterministic P05 spatial-policy admissibility derivation and validation."""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import stat
from typing import Dict, Mapping, Sequence, Tuple

import jsonschema

from validation.quality.src.mirmir_quality.json_tools import (
    canonical_json_bytes,
    manifest_sha256,
)


CONTRACT_RELATIVE_PATH = Path(
    "validation/calibration_v2/contracts/spatial-semantics-preregistration-v2.json"
)
CONTRACT_SCHEMA_RELATIVE_PATH = Path(
    "validation/calibration_v2/schemas/spatial-semantics-preregistration-v2.schema.json"
)
MANIFEST_SCHEMA_RELATIVE_PATH = Path(
    "validation/calibration_v2/schemas/spatial-policy-admissibility-manifest-v2.schema.json"
)

_POLICY_COUNT = 48
_KERNEL_RULE_COUNT = 3
_SUPPORT_RULE_COUNT = 4
_DETAIL_RULE_COUNT = 2
_LIMITER_RULE_COUNT = 2
_TRUTH_VECTOR_ENCODING = (
    "one unsigned byte descriptor ID per state-phase row in preregistered truth order"
)
_SELF_REFERENCE_BOUNDARY = (
    "spatial-policy-admissibility-manifest.json is excluded from its own "
    "input_bindings and bound by manifest_sha256 over this document without "
    "that field"
)
_INPUT_BINDING_PATHS = (
    (
        "canonical_json_implementation",
        Path("validation/quality/src/mirmir_quality/json_tools.py"),
    ),
    (
        "spatial_policy_admissibility_cli",
        Path(
            "validation/calibration_v2/tools/"
            "build_spatial_policy_admissibility_v2.py"
        ),
    ),
    (
        "spatial_policy_admissibility_generator",
        Path(
            "validation/calibration_v2/reference/"
            "spatial_policy_admissibility_v2.py"
        ),
    ),
    (
        "spatial_policy_admissibility_manifest_schema",
        MANIFEST_SCHEMA_RELATIVE_PATH,
    ),
    (
        "spatial_semantics_preregistration",
        CONTRACT_RELATIVE_PATH,
    ),
    (
        "spatial_semantics_preregistration_schema",
        CONTRACT_SCHEMA_RELATIVE_PATH,
    ),
)


class SpatialPolicyContractError(ValueError):
    """The preregistered spatial-policy contract or its derivation is invalid."""


def _reject_duplicate_pairs(pairs: Sequence[Tuple[str, object]]) -> Dict[str, object]:
    result: Dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise SpatialPolicyContractError(f"duplicate JSON member: {key}")
        result[key] = value
    return result


def _strict_json(payload: bytes, *, label: str) -> Mapping[str, object]:
    try:
        value = json.loads(
            payload,
            object_pairs_hook=_reject_duplicate_pairs,
            parse_constant=lambda token: (_ for _ in ()).throw(
                SpatialPolicyContractError(
                    f"{label} contains non-finite JSON value: {token}"
                )
            ),
        )
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise SpatialPolicyContractError(f"{label} is not valid JSON") from error
    if not isinstance(value, dict):
        raise SpatialPolicyContractError(f"{label} must be a JSON object")
    return value


def _open_parent_directory_nofollow(
    path: Path, *, label: str
) -> tuple[int, os.stat_result, str, Path]:
    absolute = Path(os.path.abspath(path))
    if not absolute.name:
        raise SpatialPolicyContractError(f"{label} path has no leaf name: {absolute}")
    flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(
        os, "O_NOFOLLOW", 0
    )
    try:
        descriptor = os.open(absolute.anchor, flags)
    except OSError as error:
        raise SpatialPolicyContractError(f"{label} root cannot be opened") from error
    try:
        opened = os.fstat(descriptor)
        for component in absolute.parts[1:-1]:
            try:
                before = os.stat(
                    component, dir_fd=descriptor, follow_symlinks=False
                )
            except OSError as error:
                raise SpatialPolicyContractError(
                    f"{label} parent component is absent: {component}"
                ) from error
            if not stat.S_ISDIR(before.st_mode):
                raise SpatialPolicyContractError(
                    f"{label} parent component is not a real directory: {component}"
                )
            try:
                child = os.open(component, flags, dir_fd=descriptor)
            except OSError as error:
                raise SpatialPolicyContractError(
                    f"{label} parent component cannot be opened safely: {component}"
                ) from error
            child_metadata = os.fstat(child)
            if (
                not stat.S_ISDIR(child_metadata.st_mode)
                or (child_metadata.st_dev, child_metadata.st_ino)
                != (before.st_dev, before.st_ino)
            ):
                os.close(child)
                raise SpatialPolicyContractError(
                    f"{label} parent component changed while opening: {component}"
                )
            os.close(descriptor)
            descriptor = child
            opened = child_metadata
        return descriptor, opened, absolute.name, absolute
    except BaseException:
        os.close(descriptor)
        raise


def _stable_file_metadata(metadata: os.stat_result) -> tuple[int, ...]:
    return (
        metadata.st_dev,
        metadata.st_ino,
        metadata.st_mode,
        metadata.st_nlink,
        metadata.st_size,
        metadata.st_mtime_ns,
        metadata.st_ctime_ns,
    )


def _read_regular(path: Path, *, label: str) -> bytes:
    parent, parent_metadata, leaf, absolute = _open_parent_directory_nofollow(
        path, label=label
    )
    try:
        try:
            before = os.stat(leaf, dir_fd=parent, follow_symlinks=False)
        except OSError as error:
            raise SpatialPolicyContractError(f"{label} is absent: {absolute}") from error
        if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
            raise SpatialPolicyContractError(
                f"{label} is not a single-link regular file: {absolute}"
            )
        flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
        try:
            descriptor = os.open(leaf, flags, dir_fd=parent)
        except OSError as error:
            raise SpatialPolicyContractError(
                f"{label} cannot be opened without link traversal: {absolute}"
            ) from error
        opened = os.fstat(descriptor)
        if (
            not stat.S_ISREG(opened.st_mode)
            or opened.st_nlink != 1
            or (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino)
        ):
            os.close(descriptor)
            raise SpatialPolicyContractError(
                f"{label} changed while opening: {absolute}"
            )
        try:
            chunks = []
            while True:
                chunk = os.read(descriptor, 1024 * 1024)
                if not chunk:
                    break
                chunks.append(chunk)
            after = os.fstat(descriptor)
        finally:
            os.close(descriptor)
        try:
            current = os.stat(leaf, dir_fd=parent, follow_symlinks=False)
        except OSError as error:
            raise SpatialPolicyContractError(
                f"{label} disappeared while reading: {absolute}"
            ) from error
        payload = b"".join(chunks)
        if (
            _stable_file_metadata(after) != _stable_file_metadata(before)
            or _stable_file_metadata(current) != _stable_file_metadata(before)
            or len(payload) != before.st_size
        ):
            raise SpatialPolicyContractError(
                f"{label} changed while reading: {absolute}"
            )
    finally:
        os.close(parent)

    current_parent, current_parent_metadata, current_leaf, _ = (
        _open_parent_directory_nofollow(absolute, label=label)
    )
    try:
        try:
            path_current = os.stat(
                current_leaf, dir_fd=current_parent, follow_symlinks=False
            )
        except OSError as error:
            raise SpatialPolicyContractError(
                f"{label} path disappeared after reading: {absolute}"
            ) from error
        if (
            (current_parent_metadata.st_dev, current_parent_metadata.st_ino)
            != (parent_metadata.st_dev, parent_metadata.st_ino)
            or _stable_file_metadata(path_current) != _stable_file_metadata(before)
        ):
            raise SpatialPolicyContractError(
                f"{label} path changed while reading: {absolute}"
            )
    finally:
        os.close(current_parent)
    return payload


def _require_repository_root(repository_root: Path) -> Path:
    root = Path(os.path.abspath(repository_root))
    try:
        metadata = os.stat(root, follow_symlinks=False)
    except OSError as error:
        raise SpatialPolicyContractError(
            f"repository root is absent: {root}"
        ) from error
    if not stat.S_ISDIR(metadata.st_mode):
        raise SpatialPolicyContractError(
            f"repository root is not a real directory: {root}"
        )
    return root


def _require_object(value: object, *, label: str) -> Mapping[str, object]:
    if not isinstance(value, dict):
        raise SpatialPolicyContractError(f"{label} must be an object")
    return value


def _require_array(value: object, *, label: str) -> Sequence[object]:
    if not isinstance(value, list):
        raise SpatialPolicyContractError(f"{label} must be an array")
    return value


def _require_string(value: object, *, label: str) -> str:
    if not isinstance(value, str):
        raise SpatialPolicyContractError(f"{label} must be a string")
    return value


def _require_integer(value: object, *, label: str) -> int:
    if type(value) is not int:
        raise SpatialPolicyContractError(f"{label} must be an integer")
    return value


def _require_exact(value: object, expected: object, *, label: str) -> None:
    if value != expected or type(value) is not type(expected):
        raise SpatialPolicyContractError(
            f"{label} does not match the preregistered value"
        )


def _validate_against_schema(
    instance: Mapping[str, object],
    *,
    repository_root: Path,
    schema_relative_path: Path,
    label: str,
) -> bytes:
    schema_path = repository_root / schema_relative_path
    schema_payload = _read_regular(schema_path, label=f"{label} schema")
    schema = _strict_json(schema_payload, label=f"{label} schema")
    try:
        validator = jsonschema.Draft202012Validator(
            schema,
            format_checker=jsonschema.FormatChecker(),
        )
        errors = sorted(
            validator.iter_errors(instance),
            key=lambda error: tuple(str(item) for item in error.absolute_path),
        )
    except (TypeError, ValueError, jsonschema.SchemaError) as error:
        raise SpatialPolicyContractError(f"{label} schema validation failed") from error
    if errors:
        descriptions = []
        for error in errors:
            location = "/".join(str(item) for item in error.absolute_path) or "<root>"
            descriptions.append(f"{location}: {error.message}")
        raise SpatialPolicyContractError(
            f"{label} schema validation failed: " + "; ".join(descriptions)
        )
    return schema_payload


def _string_array(value: object, *, label: str) -> tuple[str, ...]:
    items = _require_array(value, label=label)
    result = tuple(
        _require_string(item, label=f"{label}[{index}]")
        for index, item in enumerate(items)
    )
    return result


def _program_map(
    value: object,
    *,
    label: str,
    expected_rule_ids: Sequence[str],
) -> Mapping[str, tuple[str, ...]]:
    programs = _require_object(value, label=label)
    if tuple(sorted(programs)) != tuple(sorted(expected_rule_ids)):
        raise SpatialPolicyContractError(f"{label} rule IDs are invalid")
    return {
        rule_id: _string_array(programs[rule_id], label=f"{label}.{rule_id}")
        for rule_id in expected_rule_ids
    }


def _derive_route_truth(
    *,
    route: Mapping[str, object],
    state_domain: Mapping[str, object],
    derived_programs: Mapping[str, tuple[str, ...]],
    rule_programs: Mapping[str, Mapping[str, tuple[str, ...]]],
    rule_ids: Mapping[str, str],
    descriptor_shifts: Mapping[str, int],
) -> Mapping[str, object]:
    route_name = _require_string(route.get("name"), label="route.name")
    scale_numerator = _require_integer(
        route.get("scale_numerator"), label=f"{route_name}.scale_numerator"
    )
    phase_count = _require_integer(
        route.get("phase_count"), label=f"{route_name}.phase_count"
    )
    valid_state_count = _require_integer(
        state_domain.get("valid_state_count"), label="state_domain.valid_state_count"
    )
    if scale_numerator <= 0 or phase_count != scale_numerator * scale_numerator:
        raise SpatialPolicyContractError(f"{route_name} phase geometry is invalid")
    if valid_state_count != 256:
        raise SpatialPolicyContractError("state_domain.valid_state_count must be 256")

    payload_bits = _string_array(
        state_domain.get("payload_bit_order"), label="state_domain.payload_bit_order"
    )
    _require_exact(
        payload_bits,
        ("b1", "b2", "b3", "b4", "b5", "b6", "b7", "b8"),
        label="state_domain.payload_bit_order",
    )
    aliases = _require_object(
        state_domain.get("formula_input_aliases"),
        label="state_domain.formula_input_aliases",
    )
    expected_aliases = {"A": "b8", "C": "b4", "E": "b3", "R": "b6", "T": "b5"}
    if aliases != expected_aliases:
        raise SpatialPolicyContractError("state-domain input aliases are invalid")

    truth = bytearray()
    observed: set[int] = set()
    histogram = [0] * 16
    for phase_ordinal in range(phase_count):
        h = phase_ordinal % scale_numerator
        v = phase_ordinal // scale_numerator
        for valid_state_ordinal in range(valid_state_count):
            variables = {
                bit_name: (valid_state_ordinal >> (7 - index)) & 1
                for index, bit_name in enumerate(payload_bits)
            }
            for alias, bit_name in expected_aliases.items():
                variables[alias] = variables[bit_name]
            variables["two_h_ge_n"] = int(2 * h >= scale_numerator)
            variables["two_v_ge_n"] = int(2 * v >= scale_numerator)
            for signal_name in ("O", "P"):
                variables[signal_name] = evaluate_postfix(
                    derived_programs[signal_name], variables
                )

            descriptor_id = 0
            for axis in ("kernel", "support", "detail", "limiter"):
                bit = evaluate_postfix(
                    rule_programs[axis][rule_ids[axis]], variables
                )
                descriptor_id |= bit << descriptor_shifts[axis]
            if not 0 <= descriptor_id <= 15:
                raise SpatialPolicyContractError("descriptor ID is outside [0,15]")
            truth.append(descriptor_id)
            observed.add(descriptor_id)
            histogram[descriptor_id] += 1

    declared_state_phase_count = _require_integer(
        route.get("state_phase_count"), label=f"{route_name}.state_phase_count"
    )
    if len(truth) != declared_state_phase_count:
        raise SpatialPolicyContractError(
            f"{route_name} state-phase cardinality is inconsistent"
        )
    return {
        "descriptor_histogram": tuple(histogram),
        "descriptor_truth_sha256": hashlib.sha256(truth).hexdigest(),
        "observed_descriptor_ids": tuple(sorted(observed)),
        "route_name": route_name,
        "truth_entry_count": len(truth),
    }


def _json_clone(value: object) -> object:
    return json.loads(canonical_json_bytes(value))


def _input_binding(
    repository_root: Path, binding_id: str, relative_path: Path
) -> Mapping[str, object]:
    payload = _read_regular(
        repository_root / relative_path,
        label=f"input binding {binding_id}",
    )
    return {
        "id": binding_id,
        "path": relative_path.as_posix(),
        "sha256": hashlib.sha256(payload).hexdigest(),
        "size_bytes": len(payload),
    }


def evaluate_postfix(tokens: Sequence[str], variables: Mapping[str, int]) -> int:
    """Evaluate the contract's bounded integer postfix expression language."""

    if isinstance(tokens, (str, bytes)) or not isinstance(tokens, Sequence):
        raise SpatialPolicyContractError("postfix expression must be a token sequence")
    if not isinstance(variables, Mapping):
        raise SpatialPolicyContractError("postfix variables must be a mapping")
    normalized_variables: Dict[str, int] = {}
    for name, value in variables.items():
        if not isinstance(name, str) or not name:
            raise SpatialPolicyContractError("postfix variable name is invalid")
        if type(value) is not int or value not in {0, 1}:
            raise SpatialPolicyContractError(
                f"postfix variable is not Boolean: {name}"
            )
        normalized_variables[name] = value
    stack: list[int] = []
    for token in tokens:
        if not isinstance(token, str) or not token:
            raise SpatialPolicyContractError("postfix token is invalid")
        if token in {"0", "1"}:
            stack.append(int(token))
            continue
        if token in normalized_variables:
            stack.append(normalized_variables[token])
            continue
        if token == "not":
            if not stack:
                raise SpatialPolicyContractError("postfix operator underflow: not")
            stack.append(1 - stack.pop())
            continue
        if token in {"and", "or", "xor"}:
            if len(stack) < 2:
                raise SpatialPolicyContractError(
                    f"postfix operator underflow: {token}"
                )
            right = stack.pop()
            left = stack.pop()
            if token == "and":
                result = left & right
            elif token == "or":
                result = left | right
            else:
                result = left ^ right
            stack.append(result)
            continue
        raise SpatialPolicyContractError(f"unknown postfix token: {token}")
    if len(stack) != 1:
        raise SpatialPolicyContractError(
            f"postfix expression has {len(stack)} terminal values"
        )
    result = stack[0]
    if result not in {0, 1}:
        raise SpatialPolicyContractError("postfix result is not Boolean")
    return result


def encode_policy_id(
    kernel_rule_ordinal: int,
    support_rule_ordinal: int,
    detail_rule_ordinal: int,
    limiter_rule_ordinal: int,
) -> int:
    """Encode the four route-local rule ordinals as one stable policy ID."""

    values = (
        ("kernel", kernel_rule_ordinal, _KERNEL_RULE_COUNT),
        ("support", support_rule_ordinal, _SUPPORT_RULE_COUNT),
        ("detail", detail_rule_ordinal, _DETAIL_RULE_COUNT),
        ("limiter", limiter_rule_ordinal, _LIMITER_RULE_COUNT),
    )
    for label, value, count in values:
        if type(value) is not int or not 0 <= value < count:
            raise SpatialPolicyContractError(
                f"{label} rule ordinal is outside [0,{count})"
            )
    return (
        kernel_rule_ordinal * 16
        + support_rule_ordinal * 4
        + detail_rule_ordinal * 2
        + limiter_rule_ordinal
    )


def decode_policy_id(policy_id: int) -> tuple[int, int, int, int]:
    """Decode one stable policy ID into its four route-local rule ordinals."""

    if type(policy_id) is not int or not 0 <= policy_id < _POLICY_COUNT:
        raise SpatialPolicyContractError("policy ID is outside [0,48)")
    kernel, remainder = divmod(policy_id, 16)
    support, remainder = divmod(remainder, 4)
    detail, limiter = divmod(remainder, 2)
    decoded = (kernel, support, detail, limiter)
    if encode_policy_id(*decoded) != policy_id:
        raise SpatialPolicyContractError("policy ID does not round-trip")
    return decoded


def load_and_validate_spatial_semantics_preregistration(
    repository_root: Path,
) -> Mapping[str, object]:
    """Load the exact checked-in preregistration with strict byte bindings."""

    root = _require_repository_root(repository_root)
    contract_path = root / CONTRACT_RELATIVE_PATH
    payload = _read_regular(contract_path, label="spatial-semantics preregistration")
    contract = _strict_json(payload, label="spatial-semantics preregistration")
    if payload != canonical_json_bytes(contract) + b"\n":
        raise SpatialPolicyContractError(
            "spatial-semantics preregistration bytes are not canonical JSON plus LF"
        )
    _validate_against_schema(
        contract,
        repository_root=root,
        schema_relative_path=CONTRACT_SCHEMA_RELATIVE_PATH,
        label="spatial-semantics preregistration",
    )
    declared_digest = contract.get("artifact_sha256")
    actual_digest = manifest_sha256(contract, "artifact_sha256")
    if declared_digest != actual_digest:
        raise SpatialPolicyContractError(
            "spatial-semantics preregistration self-hash mismatch"
        )
    return contract


def derive_policy_records(
    contract: Mapping[str, object],
) -> tuple[Mapping[str, object], ...]:
    """Enumerate all route-local policy records in canonical policy-ID order."""

    contract = _require_object(contract, label="spatial-semantics preregistration")
    if contract.get("artifact_sha256") != manifest_sha256(
        contract, "artifact_sha256"
    ):
        raise SpatialPolicyContractError(
            "spatial-semantics preregistration self-hash mismatch"
        )

    policy_encoding = _require_object(
        contract.get("policy_id_encoding"), label="policy_id_encoding"
    )
    _require_exact(policy_encoding.get("cardinality"), 48, label="policy cardinality")
    _require_exact(policy_encoding.get("range"), [0, 47], label="policy ID range")
    _require_exact(
        policy_encoding.get("legacy_compatibility_anchor_policy_id"),
        0,
        label="legacy compatibility anchor policy ID",
    )

    axis_definitions = _require_array(contract.get("policy_axes"), label="policy_axes")
    axis_specs = (
        ("kernel", "kernel_rule", "K", 3, ("K0", "K1", "K2")),
        ("support", "support_rule", "S", 4, ("S0", "S1", "S2", "S3")),
        ("detail", "detail_rule", "D", 2, ("D0", "D1")),
        ("limiter", "limiter_rule", "L", 2, ("L0", "L1")),
    )
    if len(axis_definitions) != len(axis_specs):
        raise SpatialPolicyContractError("policy axis count is invalid")
    axis_rule_ids: Dict[str, tuple[str, ...]] = {}
    for definition, (axis, name, symbol, cardinality, expected_rules) in zip(
        axis_definitions, axis_specs
    ):
        axis_definition = _require_object(definition, label=f"policy axis {axis}")
        _require_exact(axis_definition.get("name"), name, label=f"{axis} axis name")
        _require_exact(
            axis_definition.get("ordinal_symbol"),
            symbol,
            label=f"{axis} ordinal symbol",
        )
        _require_exact(
            axis_definition.get("cardinality"),
            cardinality,
            label=f"{axis} cardinality",
        )
        rules = _string_array(axis_definition.get("rules"), label=f"{axis} rules")
        _require_exact(rules, expected_rules, label=f"{axis} rules")
        axis_rule_ids[axis] = rules

    postfix_language = _require_object(
        contract.get("postfix_language"), label="postfix_language"
    )
    _require_exact(
        _string_array(
            postfix_language.get("binary_operators"),
            label="postfix_language.binary_operators",
        ),
        ("and", "or", "xor"),
        label="postfix binary operators",
    )
    _require_exact(
        _string_array(
            postfix_language.get("unary_operators"),
            label="postfix_language.unary_operators",
        ),
        ("not",),
        label="postfix unary operators",
    )
    _require_exact(
        postfix_language.get("operand_domain"),
        [0, 1],
        label="postfix operand domain",
    )

    semantic_programs = _require_object(
        contract.get("semantic_programs"), label="semantic_programs"
    )
    derived_programs = _program_map(
        semantic_programs.get("derived"),
        label="semantic_programs.derived",
        expected_rule_ids=("O", "P"),
    )
    rule_programs = {
        axis: _program_map(
            semantic_programs.get(axis),
            label=f"semantic_programs.{axis}",
            expected_rule_ids=axis_rule_ids[axis],
        )
        for axis in ("kernel", "support", "detail", "limiter")
    }

    state_domain = _require_object(contract.get("state_domain"), label="state_domain")
    _require_exact(
        state_domain.get("context_invariant"), True, label="context invariance"
    )
    _require_exact(state_domain.get("context_count"), 4, label="context count")
    _require_exact(
        state_domain.get("valid_state_order"),
        "ascending 8-bit payload ordinal with b1 most significant and b8 least significant",
        label="valid-state order",
    )

    route_domain = _require_array(contract.get("route_domain"), label="route_domain")
    route_specs = (
        ("direct_2x", 2, 4, 1024, 4096),
        ("direct_3_over_2", 3, 9, 2304, 9216),
    )
    if len(route_domain) != len(route_specs):
        raise SpatialPolicyContractError("route count is invalid")
    normalized_routes = []
    for route_value, (name, numerator, phases, rows, contextual_rows) in zip(
        route_domain, route_specs
    ):
        route = _require_object(route_value, label=f"route {name}")
        for field, expected in (
            ("name", name),
            ("scale_numerator", numerator),
            ("phase_count", phases),
            ("context_count", 4),
            ("state_phase_count", rows),
            ("state_phase_context_count", contextual_rows),
            (
                "truth_order",
                "phase_ordinal ascending, then valid_state_ordinal ascending",
            ),
        ):
            _require_exact(route.get(field), expected, label=f"{name}.{field}")
        normalized_routes.append(route)

    descriptor_encoding = _require_object(
        contract.get("descriptor_id_encoding"), label="descriptor_id_encoding"
    )
    descriptor_shifts = {
        axis: _require_integer(
            descriptor_encoding.get(f"{axis}_bit_shift"),
            label=f"descriptor_id_encoding.{axis}_bit_shift",
        )
        for axis in ("kernel", "support", "detail", "limiter")
    }
    _require_exact(
        descriptor_shifts,
        {"kernel": 0, "support": 1, "detail": 2, "limiter": 3},
        label="descriptor bit shifts",
    )
    _require_exact(
        descriptor_encoding.get("range"), [0, 15], label="descriptor ID range"
    )

    admissibility = _require_object(
        contract.get("admissibility_rule"), label="admissibility_rule"
    )
    required_descriptor_ids = tuple(
        _require_integer(value, label="required descriptor ID")
        for value in _require_array(
            admissibility.get("required_descriptor_ids"),
            label="admissibility_rule.required_descriptor_ids",
        )
    )
    _require_exact(
        required_descriptor_ids,
        tuple(range(16)),
        label="required descriptor IDs",
    )
    _require_exact(
        admissibility.get("required_route_count"), 2, label="required route count"
    )
    _require_exact(
        admissibility.get("route_union_is_insufficient"),
        True,
        label="route-local admissibility",
    )

    records = []
    for policy_id in range(_POLICY_COUNT):
        kernel, support, detail, limiter = decode_policy_id(policy_id)
        rule_ordinals = {
            "detail": detail,
            "kernel": kernel,
            "limiter": limiter,
            "support": support,
        }
        rule_ids = {
            axis: axis_rule_ids[axis][rule_ordinals[axis]]
            for axis in ("detail", "kernel", "limiter", "support")
        }
        route_records = []
        for route in normalized_routes:
            truth = _derive_route_truth(
                route=route,
                state_domain=state_domain,
                derived_programs=derived_programs,
                rule_programs=rule_programs,
                rule_ids=rule_ids,
                descriptor_shifts=descriptor_shifts,
            )
            descriptor_ids = list(truth["observed_descriptor_ids"])
            missing_descriptor_ids = [
                descriptor_id
                for descriptor_id in required_descriptor_ids
                if descriptor_id not in descriptor_ids
            ]
            route_records.append(
                {
                    "descriptor_complete": not missing_descriptor_ids,
                    "descriptor_ids": descriptor_ids,
                    "missing_descriptor_ids": missing_descriptor_ids,
                    "route": truth["route_name"],
                    "state_phase_row_count": truth["truth_entry_count"],
                    "truth_vector_encoding": _TRUTH_VECTOR_ENCODING,
                    "truth_vector_sha256": truth["descriptor_truth_sha256"],
                }
            )
        records.append(
            {
                "g05_semantically_admissible": all(
                    route_record["descriptor_complete"]
                    for route_record in route_records
                ),
                "policy_id": policy_id,
                "routes": route_records,
                "rule_ids": rule_ids,
                "rule_ordinals": rule_ordinals,
            }
        )

    admissible_count = sum(
        int(record["g05_semantically_admissible"]) for record in records
    )
    expected_admissible_count = _require_integer(
        admissibility.get("expected_admissible_policy_count"),
        label="expected admissible policy count",
    )
    expected_inadmissible_count = _require_integer(
        admissibility.get("expected_inadmissible_policy_count"),
        label="expected inadmissible policy count",
    )
    if (
        admissible_count != expected_admissible_count
        or len(records) - admissible_count != expected_inadmissible_count
        or (expected_admissible_count, expected_inadmissible_count) != (16, 32)
    ):
        raise SpatialPolicyContractError(
            "derived policy admissibility cardinality does not match preregistration"
        )
    return tuple(records)


def build_spatial_policy_admissibility_manifest(
    repository_root: Path,
) -> Mapping[str, object]:
    """Derive the complete spatial-policy admissibility manifest."""

    root = _require_repository_root(repository_root)
    contract = load_and_validate_spatial_semantics_preregistration(root)
    records = derive_policy_records(contract)
    admissible_policy_ids = [
        int(record["policy_id"])
        for record in records
        if record["g05_semantically_admissible"] is True
    ]
    inadmissible_policy_ids = [
        int(record["policy_id"])
        for record in records
        if record["g05_semantically_admissible"] is False
    ]
    canonicalization = _require_object(
        _json_clone(contract.get("canonicalization")),
        label="canonicalization",
    )
    canonicalization = dict(canonicalization)
    canonicalization["hash_scope"] = (
        "canonical sorted-key compact UTF-8 JSON excluding /manifest_sha256"
    )
    output_lock = _require_object(contract.get("output_lock"), label="output_lock")
    manifest: Dict[str, object] = {
        "artifact_kind": output_lock.get("artifact_kind"),
        "anisotropy_mode_summary": _json_clone(contract.get("anisotropy_modes")),
        "canonicalization": canonicalization,
        "contract_id": contract.get("contract_id"),
        "data_access": _json_clone(contract.get("data_access")),
        "derived_summary": {
            "admissible_policy_count": len(admissible_policy_ids),
            "admissible_policy_ids": admissible_policy_ids,
            "inadmissible_policy_count": len(inadmissible_policy_ids),
            "inadmissible_policy_ids": inadmissible_policy_ids,
            "policy_count": len(records),
        },
        "gate": contract.get("gate"),
        "input_bindings": [
            _input_binding(root, binding_id, relative_path)
            for binding_id, relative_path in _INPUT_BINDING_PATHS
        ],
        "manifest_id": "mirmir-p05-spatial-policy-admissibility-v2",
        "phase": contract.get("phase"),
        "policy_records": list(records),
        "preregistration_artifact_sha256": contract.get("artifact_sha256"),
        "route_domain": _json_clone(contract.get("route_domain")),
        "schema_version": output_lock.get("schema_version"),
        "selection_state": _json_clone(contract.get("selection_state")),
        "self_reference_boundary": _SELF_REFERENCE_BOUNDARY,
        "status": output_lock.get("status"),
        "structural_cardinality": _json_clone(
            contract.get("structural_cardinality")
        ),
    }
    manifest["manifest_sha256"] = manifest_sha256(manifest)
    _validate_against_schema(
        manifest,
        repository_root=root,
        schema_relative_path=MANIFEST_SCHEMA_RELATIVE_PATH,
        label="spatial-policy admissibility manifest",
    )
    return manifest


def validate_spatial_policy_admissibility_manifest(
    manifest: Mapping[str, object],
    *,
    repository_root: Path,
) -> str:
    """Validate a parsed manifest and return its canonical self-hash."""

    root = _require_repository_root(repository_root)
    manifest = _require_object(manifest, label="spatial-policy admissibility manifest")
    _validate_against_schema(
        manifest,
        repository_root=root,
        schema_relative_path=MANIFEST_SCHEMA_RELATIVE_PATH,
        label="spatial-policy admissibility manifest",
    )
    digest = manifest_sha256(manifest)
    if manifest.get("manifest_sha256") != digest:
        raise SpatialPolicyContractError(
            "spatial-policy admissibility manifest self-hash mismatch"
        )
    expected = build_spatial_policy_admissibility_manifest(root)
    if canonical_json_bytes(manifest) != canonical_json_bytes(expected):
        raise SpatialPolicyContractError(
            "spatial-policy admissibility manifest does not match deterministic derivation"
        )
    return digest


def validate_spatial_policy_admissibility_manifest_file(
    manifest_path: Path,
    *,
    repository_root: Path,
) -> str:
    """Read-only validation of one canonical manifest file."""

    payload = _read_regular(manifest_path, label="spatial-policy manifest")
    manifest = _strict_json(payload, label="spatial-policy manifest")
    if payload != canonical_json_bytes(manifest) + b"\n":
        raise SpatialPolicyContractError(
            "spatial-policy manifest bytes are not canonical JSON plus LF"
        )
    return validate_spatial_policy_admissibility_manifest(
        manifest,
        repository_root=repository_root,
    )


__all__ = [
    "SpatialPolicyContractError",
    "build_spatial_policy_admissibility_manifest",
    "decode_policy_id",
    "derive_policy_records",
    "encode_policy_id",
    "evaluate_postfix",
    "load_and_validate_spatial_semantics_preregistration",
    "validate_spatial_policy_admissibility_manifest",
    "validate_spatial_policy_admissibility_manifest_file",
]
