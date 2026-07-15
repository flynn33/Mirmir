"""Strict, data-free codec for the preregistered P06 calibration plan V2."""

from __future__ import annotations

from dataclasses import dataclass
import hashlib
import json
from pathlib import Path
from typing import Dict, Mapping, Sequence, Tuple

import jsonschema

from validation.calibration_v2.reference import (
    calibration_plan_v2 as calibration_plan_v2_reference,
)
from validation.calibration_v2.reference.calibration_plan_v2 import (
    ATOMIC_STRUCTURAL_COORDINATE,
    COORDINATE_COLUMN_MULTIPLIERS,
    MODE_COLUMN_MULTIPLIERS,
    MODE_COLUMN_XOR_OFFSETS,
    STRUCTURAL_FACTOR_ORDER,
    THRESHOLD_BANDS,
    base_parameter_domains,
    inherited_scalar_initial_values,
    inherited_scalar_parameter_order,
    scalar_domain_cardinality_sum,
    structural_vectors,
    validate_structural_design,
)
from validation.quality.src.mirmir_quality.json_tools import (
    canonical_json_bytes,
    canonical_sha256,
    manifest_sha256,
)


CALIBRATION_ROOT = Path(__file__).resolve().parent
PLAN_V2_SCHEMA_PATH = CALIBRATION_ROOT / "schemas" / "calibration-plan-v2.schema.json"
REFERENCE_V2_SOURCE_PATH = Path(calibration_plan_v2_reference.__file__).resolve()
EXPECTED_PLAN_V2_FILE_SHA256 = (
    "1977c85b9a3b7001294a04d33e7654ae20ffb4266ac0c8d2dc76880bdec99fef"
)
EXPECTED_PLAN_V2_SELF_SHA256 = (
    "e6070a7cdd8f3b53231635027055669c8319d311af1790d672723d6e7e048d0f"
)
EXPECTED_PLAN_V2_SCHEMA_SHA256 = (
    "09a21861104bd1b03667d1207a79d523386ad4431e710ba44e4d298180753c09"
)
EXPECTED_CATALOG_SHA256 = (
    "8f9eda0eb6de5f6a43787eaea80ebbea0d2f5b80ca8db836666b92207879370c"
)
EXPECTED_SCALAR_ORDER_SHA256 = (
    "6e2acf16b548c15e63a8e41661a6062661193adbaa08b7bea3e7d181a8870d89"
)
EXPECTED_SCALAR_INITIAL_SHA256 = (
    "f51f5480aad3eecea89223f1f03e020343ac928119c1b52f04cfcdc459c96f69"
)
EXPECTED_SCALAR_DOMAINS_SHA256 = (
    "dbcc23f54f846375fff35b31c9933db3285528e082446841ad934a348188b481"
)
_THRESHOLD_MINIMUM_SEPARATION = 3277
_THRESHOLD_PAIR_CONSTRAINT = "low <= high and high - low >= 3277"


class CalibrationPlanCodecError(ValueError):
    """The V2 plan, one of its bindings, or a candidate vector is invalid."""


@dataclass(frozen=True)
class ParsedCalibrationPlanV2:
    """Immutable executable fields derived from the authenticated V2 overlay."""

    plan_file_sha256: str
    plan_self_sha256: str
    logical_parameter_order: Tuple[str, ...]
    physical_candidate_order: Tuple[str, ...]
    scalar_parameter_order: Tuple[str, ...]
    scalar_initial_values: Tuple[Tuple[str, object], ...]
    scalar_domains: Tuple[Tuple[str, Tuple[object, ...]], ...]
    structural_factor_order: Tuple[str, ...]
    structural_vectors: Tuple[Tuple[object, ...], ...]


def _reject_duplicate_pairs(
    pairs: Sequence[Tuple[str, object]],
) -> Dict[str, object]:
    result: Dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise CalibrationPlanCodecError(f"duplicate JSON member: {key}")
        result[key] = value
    return result


def _nonfinite_json(token: str) -> object:
    raise CalibrationPlanCodecError(f"non-finite JSON value: {token}")


def _floating_json(token: str) -> object:
    raise CalibrationPlanCodecError(f"floating-point JSON value is forbidden: {token}")


def _strict_json_object(
    payload: bytes,
    *,
    label: str,
    require_plan_file_serialization: bool = False,
) -> Mapping[str, object]:
    if not isinstance(payload, bytes):
        raise CalibrationPlanCodecError(f"{label} payload must be bytes")
    if payload.startswith(b"\xef\xbb\xbf"):
        raise CalibrationPlanCodecError(f"{label} contains a UTF-8 byte-order mark")
    if require_plan_file_serialization and (
        not payload.endswith(b"}\n") or b"\r" in payload
    ):
        raise CalibrationPlanCodecError(
            f"{label} must end with exactly one LF after its closing object"
        )
    try:
        value = json.loads(
            payload,
            object_pairs_hook=_reject_duplicate_pairs,
            parse_constant=_nonfinite_json,
            parse_float=_floating_json,
        )
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise CalibrationPlanCodecError(f"{label} is not valid UTF-8 JSON") from error
    if not isinstance(value, dict):
        raise CalibrationPlanCodecError(f"{label} must be a JSON object")
    return value


def _object(value: object, *, label: str) -> Mapping[str, object]:
    if not isinstance(value, dict):
        raise CalibrationPlanCodecError(f"{label} must be an object")
    return value


def _array(value: object, *, label: str) -> Sequence[object]:
    if not isinstance(value, list):
        raise CalibrationPlanCodecError(f"{label} must be an array")
    return value


def _validate_schema(
    document: Mapping[str, object],
    schema: Mapping[str, object],
    *,
    label: str,
) -> None:
    try:
        jsonschema.Draft202012Validator.check_schema(schema)
        validator = jsonschema.Draft202012Validator(
            schema,
            format_checker=jsonschema.FormatChecker(),
        )
        errors = sorted(
            validator.iter_errors(document),
            key=lambda error: tuple(str(item) for item in error.absolute_path),
        )
    except (TypeError, ValueError, jsonschema.SchemaError) as error:
        raise CalibrationPlanCodecError(f"{label} schema is invalid") from error
    if errors:
        descriptions = []
        for error in errors:
            location = "/".join(str(item) for item in error.absolute_path) or "<root>"
            descriptions.append(f"{location}: {error.message}")
        raise CalibrationPlanCodecError(
            f"{label} schema validation failed: " + "; ".join(descriptions)
        )


def _verify_bound_payloads(
    plan: Mapping[str, object],
    bound_payloads: Mapping[str, bytes],
) -> Mapping[str, Mapping[str, object]]:
    bindings = _array(plan.get("input_bindings"), label="input_bindings")
    binding_by_id: Dict[str, Mapping[str, object]] = {}
    for index, value in enumerate(bindings):
        binding = _object(value, label=f"input_bindings[{index}]")
        identifier = binding.get("id")
        if not isinstance(identifier, str) or identifier in binding_by_id:
            raise CalibrationPlanCodecError("input binding IDs are absent or duplicated")
        binding_by_id[identifier] = binding
    if set(bound_payloads) != set(binding_by_id) or len(bound_payloads) != len(binding_by_id):
        raise CalibrationPlanCodecError(
            "bound payload IDs do not exactly match the plan input bindings"
        )

    parsed_json: Dict[str, Mapping[str, object]] = {}
    for identifier, binding in binding_by_id.items():
        payload = bound_payloads[identifier]
        if not isinstance(payload, bytes):
            raise CalibrationPlanCodecError(
                f"bound payload must be bytes: {identifier}"
            )
        if len(payload) != binding.get("size_bytes"):
            raise CalibrationPlanCodecError(
                f"bound payload size mismatch: {identifier}"
            )
        if hashlib.sha256(payload).hexdigest() != binding.get("sha256"):
            raise CalibrationPlanCodecError(
                f"bound payload SHA-256 mismatch: {identifier}"
            )
        self_hash_field = binding.get("self_hash_field")
        if self_hash_field is not None:
            document = _strict_json_object(payload, label=identifier)
            if document.get(self_hash_field) != binding.get("self_sha256"):
                raise CalibrationPlanCodecError(
                    f"bound payload self-hash field mismatch: {identifier}"
                )
            if manifest_sha256(document, field=str(self_hash_field)) != binding.get(
                "self_sha256"
            ):
                raise CalibrationPlanCodecError(
                    f"bound payload self-hash is invalid: {identifier}"
                )
            parsed_json[identifier] = document
    return parsed_json


def _reference_source_payload() -> bytes:
    try:
        return REFERENCE_V2_SOURCE_PATH.read_bytes()
    except OSError as error:
        raise CalibrationPlanCodecError(
            "calibration-plan V2 reference source cannot be read"
        ) from error


def _verify_executed_reference_source(
    bound_payloads: Mapping[str, bytes],
) -> None:
    expected = bound_payloads["calibration_plan_v2_reference"]
    if _reference_source_payload() != expected:
        raise CalibrationPlanCodecError(
            "executed calibration-plan V2 reference source differs from its binding"
        )


def _base_plan_and_schema(
    bound_payloads: Mapping[str, bytes],
) -> Mapping[str, object]:
    base_plan = _strict_json_object(
        bound_payloads["calibration_plan_v1"],
        label="calibration_plan_v1",
        require_plan_file_serialization=True,
    )
    base_schema = _strict_json_object(
        bound_payloads["calibration_plan_v1_schema"],
        label="calibration_plan_v1_schema",
    )
    _validate_schema(base_plan, base_schema, label="calibration_plan_v1")
    mapping = _object(
        _object(base_plan.get("ranges"), label="calibration_plan_v1.ranges").get(
            "mapping"
        ),
        label="calibration_plan_v1.ranges.mapping",
    )
    if mapping.get("pair_constraint") != _THRESHOLD_PAIR_CONSTRAINT:
        raise CalibrationPlanCodecError(
            "calibration_plan_v1 threshold-pair constraint is not frozen"
        )
    return base_plan


def _verify_derived_contract(
    plan: Mapping[str, object],
    base_plan: Mapping[str, object],
) -> Tuple[
    Tuple[str, ...],
    Tuple[Tuple[str, object], ...],
    Tuple[Tuple[str, Tuple[object, ...]], ...],
    Tuple[str, ...],
    Tuple[str, ...],
    Tuple[Tuple[object, ...], ...],
]:
    try:
        base_domains = base_parameter_domains(base_plan)
        scalar_order = inherited_scalar_parameter_order(base_plan)
        scalar_initial = inherited_scalar_initial_values(base_plan)
        scalar_domains = tuple(
            (name, tuple(base_domains[name])) for name in scalar_order
        )
        design_summary = validate_structural_design()
        vectors = structural_vectors()
    except (KeyError, TypeError, ValueError) as error:
        raise CalibrationPlanCodecError(
            "V2 reference derivation failed"
        ) from error

    inheritance = _object(plan.get("inheritance"), label="inheritance")
    if inheritance.get("inherited_scalar_coordinate_count") != len(scalar_order):
        raise CalibrationPlanCodecError("inherited scalar count does not derive exactly")
    if inheritance.get("inherited_scalar_domain_cardinality_sum") != (
        scalar_domain_cardinality_sum(base_domains, base_plan)
    ):
        raise CalibrationPlanCodecError(
            "inherited scalar domain cardinality does not derive exactly"
        )
    if inheritance.get("inherited_scalar_parameter_order_sha256") != canonical_sha256(
        list(scalar_order)
    ):
        raise CalibrationPlanCodecError("inherited scalar order hash is invalid")
    if inheritance.get("inherited_scalar_initial_values_sha256") != canonical_sha256(
        scalar_initial
    ):
        raise CalibrationPlanCodecError("inherited scalar initial hash is invalid")
    scalar_domain_document = {
        name: list(values) for name, values in scalar_domains
    }
    if inheritance.get("inherited_scalar_domains_sha256") != canonical_sha256(
        scalar_domain_document
    ):
        raise CalibrationPlanCodecError("inherited scalar domain hash is invalid")

    structural = _object(
        plan.get("joint_structural_domain"),
        label="joint_structural_domain",
    )
    if structural.get("factor_order") != list(STRUCTURAL_FACTOR_ORDER):
        raise CalibrationPlanCodecError("structural factor order is invalid")
    design = _object(structural.get("screening_design"), label="screening_design")
    catalog = tuple(
        tuple(vector[name] for name in STRUCTURAL_FACTOR_ORDER)
        for vector in vectors
    )
    catalog_sha256 = canonical_sha256([list(row) for row in catalog])
    if (
        catalog_sha256 != EXPECTED_CATALOG_SHA256
        or design.get("catalog_sha256") != EXPECTED_CATALOG_SHA256
    ):
        raise CalibrationPlanCodecError("structural catalog hash is invalid")
    for name, value in design_summary.items():
        if design.get(name) != value:
            raise CalibrationPlanCodecError(
                f"structural design summary is invalid: {name}"
            )
    row_generation = _object(
        design.get("row_generation"), label="screening_design.row_generation"
    )
    expected_mode_columns = [
        {
            "factor": factor,
            "multiplier": multiplier,
            "xor_offset": xor_offset,
        }
        for factor, multiplier, xor_offset in zip(
            STRUCTURAL_FACTOR_ORDER[2:6],
            MODE_COLUMN_MULTIPLIERS,
            MODE_COLUMN_XOR_OFFSETS,
        )
    ]
    expected_coordinate_columns = [
        {"factor": factor, "multiplier": multiplier}
        for factor, multiplier in zip(
            STRUCTURAL_FACTOR_ORDER[6:10],
            COORDINATE_COLUMN_MULTIPLIERS,
        )
    ]
    if row_generation.get("mode_columns") != expected_mode_columns:
        raise CalibrationPlanCodecError("structural mode columns are invalid")
    if row_generation.get("coordinate_columns") != expected_coordinate_columns:
        raise CalibrationPlanCodecError("structural coordinate columns are invalid")

    search = _object(plan.get("search"), label="search")
    logical_order = tuple(
        str(value)
        for value in _array(
            search.get("logical_parameter_order"),
            label="search.logical_parameter_order",
        )
    )
    physical_order = tuple(
        str(value)
        for value in _array(
            search.get("physical_candidate_order"),
            label="search.physical_candidate_order",
        )
    )
    if logical_order != (ATOMIC_STRUCTURAL_COORDINATE, *scalar_order):
        raise CalibrationPlanCodecError("logical parameter order is invalid")
    if physical_order != (
        ATOMIC_STRUCTURAL_COORDINATE,
        *STRUCTURAL_FACTOR_ORDER,
        *scalar_order,
    ):
        raise CalibrationPlanCodecError("physical candidate order is invalid")
    if search.get("structural_incumbent_before_first_scan") is not None:
        raise CalibrationPlanCodecError("V2 plan contains a structural default")
    return (
        scalar_order,
        tuple((name, scalar_initial[name]) for name in scalar_order),
        scalar_domains,
        logical_order,
        physical_order,
        catalog,
    )


def parse_calibration_plan_v2(
    plan_payload: bytes,
    *,
    bound_payloads: Mapping[str, bytes],
) -> ParsedCalibrationPlanV2:
    """Authenticate and derive the immutable executable V2 plan fields."""

    plan = _strict_json_object(
        plan_payload,
        label="calibration_plan_v2",
        require_plan_file_serialization=True,
    )
    plan_file_sha256 = hashlib.sha256(plan_payload).hexdigest()
    if plan_file_sha256 != EXPECTED_PLAN_V2_FILE_SHA256:
        raise CalibrationPlanCodecError(
            "calibration_plan_v2 file SHA-256 is not the frozen plan"
        )
    schema_payload = PLAN_V2_SCHEMA_PATH.read_bytes()
    if hashlib.sha256(schema_payload).hexdigest() != EXPECTED_PLAN_V2_SCHEMA_SHA256:
        raise CalibrationPlanCodecError(
            "calibration_plan_v2 schema SHA-256 is not frozen"
        )
    schema = _strict_json_object(
        schema_payload,
        label="calibration_plan_v2_schema",
    )
    _validate_schema(plan, schema, label="calibration_plan_v2")
    declared_self_hash = plan.get("plan_sha256")
    unhashed_plan = dict(plan)
    unhashed_plan.pop("plan_sha256", None)
    actual_self_hash = canonical_sha256(unhashed_plan)
    if (
        declared_self_hash != EXPECTED_PLAN_V2_SELF_SHA256
        or actual_self_hash != EXPECTED_PLAN_V2_SELF_SHA256
    ):
        raise CalibrationPlanCodecError("calibration_plan_v2 self-hash is invalid")

    bound_payload_snapshot = _snapshot_mapping(
        bound_payloads,
        label="bound payloads",
    )
    _verify_bound_payloads(plan, bound_payload_snapshot)
    _verify_executed_reference_source(bound_payload_snapshot)
    base_plan = _base_plan_and_schema(bound_payload_snapshot)
    (
        scalar_order,
        scalar_initial,
        scalar_domains,
        logical_order,
        physical_order,
        catalog,
    ) = _verify_derived_contract(plan, base_plan)
    return ParsedCalibrationPlanV2(
        plan_file_sha256=plan_file_sha256,
        plan_self_sha256=actual_self_hash,
        logical_parameter_order=logical_order,
        physical_candidate_order=physical_order,
        scalar_parameter_order=scalar_order,
        scalar_initial_values=scalar_initial,
        scalar_domains=scalar_domains,
        structural_factor_order=tuple(STRUCTURAL_FACTOR_ORDER),
        structural_vectors=catalog,
    )


def _domain_contains(value: object, domain: Sequence[object]) -> bool:
    return any(type(value) is type(candidate) and value == candidate for candidate in domain)


def _snapshot_mapping(
    value: Mapping[str, object],
    *,
    label: str,
) -> Dict[str, object]:
    if not isinstance(value, Mapping):
        raise CalibrationPlanCodecError(f"{label} must be a mapping")
    try:
        return dict(value)
    except Exception as error:
        raise CalibrationPlanCodecError(
            f"{label} cannot be snapshotted exactly once"
        ) from error


def _validate_parsed_plan_model(plan: ParsedCalibrationPlanV2) -> None:
    if type(plan) is not ParsedCalibrationPlanV2:
        raise CalibrationPlanCodecError(
            "candidate codec requires an exact parsed V2 plan model"
        )
    if (
        type(plan.plan_file_sha256) is not str
        or type(plan.plan_self_sha256) is not str
        or plan.plan_file_sha256 != EXPECTED_PLAN_V2_FILE_SHA256
        or plan.plan_self_sha256 != EXPECTED_PLAN_V2_SELF_SHA256
        or type(plan.logical_parameter_order) is not tuple
        or type(plan.physical_candidate_order) is not tuple
        or type(plan.scalar_parameter_order) is not tuple
        or type(plan.scalar_initial_values) is not tuple
        or type(plan.scalar_domains) is not tuple
        or type(plan.structural_factor_order) is not tuple
        or type(plan.structural_vectors) is not tuple
    ):
        raise CalibrationPlanCodecError("parsed V2 plan identity is invalid")
    if any(
        type(name) is not str
        for order in (
            plan.logical_parameter_order,
            plan.physical_candidate_order,
            plan.scalar_parameter_order,
            plan.structural_factor_order,
        )
        for name in order
    ):
        raise CalibrationPlanCodecError("parsed V2 order contains a type alias")
    if plan.structural_factor_order != tuple(STRUCTURAL_FACTOR_ORDER):
        raise CalibrationPlanCodecError("parsed V2 structural order is invalid")
    if plan.logical_parameter_order != (
        ATOMIC_STRUCTURAL_COORDINATE,
        *plan.scalar_parameter_order,
    ):
        raise CalibrationPlanCodecError("parsed V2 logical order is invalid")
    if plan.physical_candidate_order != (
        ATOMIC_STRUCTURAL_COORDINATE,
        *plan.structural_factor_order,
        *plan.scalar_parameter_order,
    ):
        raise CalibrationPlanCodecError("parsed V2 physical order is invalid")
    if (
        len(plan.logical_parameter_order) != 38
        or len(plan.physical_candidate_order) != 48
        or len(plan.scalar_parameter_order) != 37
    ):
        raise CalibrationPlanCodecError("parsed V2 field counts are invalid")
    if canonical_sha256(list(plan.scalar_parameter_order)) != (
        EXPECTED_SCALAR_ORDER_SHA256
    ):
        raise CalibrationPlanCodecError("parsed V2 scalar order hash is invalid")
    if any(
        type(record) is not tuple
        or len(record) != 2
        or type(record[0]) is not str
        or type(record[1]) not in (int, str)
        for record in plan.scalar_initial_values
    ):
        raise CalibrationPlanCodecError("parsed V2 scalar initial types are invalid")
    if tuple(name for name, _ in plan.scalar_initial_values) != (
        plan.scalar_parameter_order
    ):
        raise CalibrationPlanCodecError("parsed V2 scalar initials are misordered")
    if canonical_sha256(dict(plan.scalar_initial_values)) != (
        EXPECTED_SCALAR_INITIAL_SHA256
    ):
        raise CalibrationPlanCodecError("parsed V2 scalar initial hash is invalid")
    if any(
        type(record) is not tuple
        or len(record) != 2
        or type(record[0]) is not str
        or type(record[1]) is not tuple
        or not record[1]
        or any(type(value) not in (int, str) for value in record[1])
        for record in plan.scalar_domains
    ):
        raise CalibrationPlanCodecError("parsed V2 scalar domain types are invalid")
    if tuple(name for name, _ in plan.scalar_domains) != plan.scalar_parameter_order:
        raise CalibrationPlanCodecError("parsed V2 scalar domains are misordered")
    domain_map = dict(plan.scalar_domains)
    if any(
        not _domain_contains(value, domain_map[name])
        for name, value in plan.scalar_initial_values
    ):
        raise CalibrationPlanCodecError(
            "parsed V2 scalar initial is outside its exact domain"
        )
    if canonical_sha256(
        {name: list(values) for name, values in plan.scalar_domains}
    ) != EXPECTED_SCALAR_DOMAINS_SHA256:
        raise CalibrationPlanCodecError("parsed V2 scalar domain hash is invalid")
    if (
        len(plan.structural_vectors) != 256
        or any(
            type(row) is not tuple or len(row) != len(plan.structural_factor_order)
            for row in plan.structural_vectors
        )
    ):
        raise CalibrationPlanCodecError("parsed V2 structural catalog shape is invalid")
    if any(
        any(type(value) is not int for value in row[:6])
        or any(type(value) is not str for value in row[6:])
        for row in plan.structural_vectors
    ):
        raise CalibrationPlanCodecError(
            "parsed V2 structural catalog contains a type alias"
        )
    if canonical_sha256(
        [list(row) for row in plan.structural_vectors]
    ) != EXPECTED_CATALOG_SHA256:
        raise CalibrationPlanCodecError("parsed V2 structural catalog hash is invalid")


def _parsed_structural_vector_for_ordinal(
    ordinal: object,
    plan: ParsedCalibrationPlanV2,
) -> Mapping[str, object]:
    if (
        type(ordinal) is not int
        or ordinal < 0
        or ordinal >= len(plan.structural_vectors)
    ):
        raise CalibrationPlanCodecError(
            "structural vector ordinal is outside 0...255"
        )
    row = plan.structural_vectors[ordinal]
    if len(row) != len(plan.structural_factor_order):
        raise CalibrationPlanCodecError(
            "parsed structural catalog row has the wrong field count"
        )
    return dict(zip(plan.structural_factor_order, row))


def _validate_logical_candidate_v2(
    logical_vector: Mapping[str, object],
    plan: ParsedCalibrationPlanV2,
) -> None:
    if (
        any(type(name) is not str for name in logical_vector)
        or set(logical_vector) != set(plan.logical_parameter_order)
        or len(logical_vector) != len(plan.logical_parameter_order)
    ):
        raise CalibrationPlanCodecError(
            "logical candidate does not exactly cover the 38-field order"
        )
    _parsed_structural_vector_for_ordinal(
        logical_vector[ATOMIC_STRUCTURAL_COORDINATE],
        plan,
    )
    domains = dict(plan.scalar_domains)
    for name in plan.scalar_parameter_order:
        if not _domain_contains(logical_vector[name], domains[name]):
            raise CalibrationPlanCodecError(
                f"logical scalar is outside its declared domain: {name}"
            )


def materialize_candidate_vector_v2(
    logical_vector: Mapping[str, object],
    plan: ParsedCalibrationPlanV2,
) -> Mapping[str, object]:
    """Expand one exact 38-field logical vector into its 48-field identity."""

    _validate_parsed_plan_model(plan)
    logical_snapshot = _snapshot_mapping(logical_vector, label="logical candidate")
    try:
        _validate_logical_candidate_v2(logical_snapshot, plan)
        ordinal = logical_snapshot[ATOMIC_STRUCTURAL_COORDINATE]
        structural = _parsed_structural_vector_for_ordinal(ordinal, plan)
    except ValueError as error:
        raise CalibrationPlanCodecError(str(error)) from error
    combined = {
        ATOMIC_STRUCTURAL_COORDINATE: ordinal,
        **structural,
        **{
            name: logical_snapshot[name]
            for name in plan.scalar_parameter_order
        },
    }
    if set(combined) != set(plan.physical_candidate_order):
        raise CalibrationPlanCodecError(
            "materialized candidate does not cover the 48-field order"
        )
    return {name: combined[name] for name in plan.physical_candidate_order}


def _validated_materialized_candidate_snapshot_v2(
    physical_vector: Mapping[str, object],
    plan: ParsedCalibrationPlanV2,
) -> Dict[str, object]:
    _validate_parsed_plan_model(plan)
    physical_snapshot = _snapshot_mapping(
        physical_vector,
        label="physical candidate",
    )

    if (
        any(type(name) is not str for name in physical_snapshot)
        or set(physical_snapshot) != set(plan.physical_candidate_order)
        or len(physical_snapshot) != len(plan.physical_candidate_order)
    ):
        raise CalibrationPlanCodecError(
            "physical candidate does not exactly cover the 48-field order"
        )
    logical = {
        name: physical_snapshot[name]
        for name in plan.logical_parameter_order
    }
    expected = materialize_candidate_vector_v2(logical, plan)
    for name in plan.physical_candidate_order:
        if (
            type(physical_snapshot[name]) is not type(expected[name])
            or physical_snapshot[name] != expected[name]
        ):
            raise CalibrationPlanCodecError(
                f"physical candidate differs from ordinal materialization: {name}"
            )
    return physical_snapshot


def validate_materialized_candidate_identity_v2(
    physical_vector: Mapping[str, object],
    plan: ParsedCalibrationPlanV2,
) -> None:
    """Validate fields, domains, and ordinal materialization without feasibility."""

    _validated_materialized_candidate_snapshot_v2(physical_vector, plan)


def validate_candidate_constraints_v2(
    physical_vector: Mapping[str, object],
    plan: ParsedCalibrationPlanV2,
) -> None:
    """Reject relationally infeasible candidates after their identity is hashable."""

    physical_snapshot = _validated_materialized_candidate_snapshot_v2(
        physical_vector,
        plan,
    )
    for band in THRESHOLD_BANDS:
        low = physical_snapshot[f"{band}_low_unorm15"]
        high = physical_snapshot[f"{band}_high_unorm15"]
        if type(low) is not int or type(high) is not int:
            raise CalibrationPlanCodecError(
                f"threshold pair is not integral: {band}"
            )
        if low > high or high - low < _THRESHOLD_MINIMUM_SEPARATION:
            raise CalibrationPlanCodecError(
                f"threshold pair constraint failed: {band}"
            )


def serialized_candidate_vector_v2(
    physical_vector: Mapping[str, object],
    plan: ParsedCalibrationPlanV2,
) -> bytes:
    """Serialize the canonical 48-value candidate array for identity and ledger use."""

    physical_snapshot = _validated_materialized_candidate_snapshot_v2(
        physical_vector,
        plan,
    )
    return canonical_json_bytes(
        [physical_snapshot[name] for name in plan.physical_candidate_order]
    )


def candidate_vector_sha256_v2(
    physical_vector: Mapping[str, object],
    plan: ParsedCalibrationPlanV2,
) -> str:
    """Hash the canonical 48-value physical candidate array."""

    return hashlib.sha256(
        serialized_candidate_vector_v2(physical_vector, plan)
    ).hexdigest()
