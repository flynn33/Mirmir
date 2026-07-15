"""Strict, data-free codec for the P06 baseline-ablation budget V2 overlay."""

from __future__ import annotations

import copy
from dataclasses import dataclass
import hashlib
import json
import math
from collections.abc import Mapping
from typing import Dict, Sequence, Tuple

import jsonschema

from validation.quality.src.mirmir_quality.json_tools import (
    canonical_json_bytes,
    manifest_sha256,
)


EXPECTED_OVERLAY_FILE_SHA256 = (
    "1885aa30b46f72ed1de0570a3de5f615cf788ec0d494ed5396731279763da4c8"
)
EXPECTED_OVERLAY_SELF_SHA256 = (
    "405d9ca4413e7e291315257682f206d951a081f052d5ecee6f3a36ac72cd22be"
)
EXPECTED_OVERLAY_SCHEMA_SHA256 = (
    "080cc48a86569d68aecb0ca9384c89300df57dbeaa995e0651cf6082c969416b"
)
EXPECTED_OVERLAY_SIZE_BYTES = 8475
EXPECTED_OVERLAY_SCHEMA_SIZE_BYTES = 8722
EXPECTED_MATERIALIZED_SELECTOR_SHA256 = (
    "b032e9169f7224e2eb44dfe0bb908c26cd4819ddd6138e97cf3b58962a1e950c"
)
EXPECTED_MATERIALIZED_SELECTOR_SIZE_BYTES = 3308

SELECTOR_ID_V2 = "continuous-linear-bank-selector-q15-v2"
COORDINATE_ORDER_V2 = (
    "bias_descriptor_00_q8_8",
    "bias_descriptor_01_q8_8",
    "bias_descriptor_02_q8_8",
    "bias_descriptor_03_q8_8",
    "bias_descriptor_04_q8_8",
    "bias_descriptor_05_q8_8",
    "bias_descriptor_06_q8_8",
    "bias_descriptor_07_q8_8",
    "bias_descriptor_08_q8_8",
    "bias_descriptor_09_q8_8",
    "bias_descriptor_10_q8_8",
    "bias_descriptor_11_q8_8",
    "bias_descriptor_12_q8_8",
    "bias_descriptor_13_q8_8",
    "bias_descriptor_14_q8_8",
    "bias_descriptor_15_q8_8",
    "weight_magnitude_q8_8",
    "weight_coherence_q8_8",
    "weight_texture_q8_8",
    "weight_risk_q8_8",
    "weight_chroma_alignment_q8_8",
    "weight_orientation_cos_q8_8",
    "weight_orientation_sin_q8_8",
    "weight_noise_q8_8",
    "weight_horizontal_phase_q8_8",
    "weight_vertical_phase_q8_8",
    "weight_route_q8_8",
)
VALUES_V2 = (-384, -256, -128, 0, 128, 256, 384)
INITIAL_VALUE_V2 = 0
MAXIMUM_SWEEPS_V2 = 18
MAXIMUM_DEVELOPMENT_ATTEMPTS_V2 = 3403
MAXIMUM_VALIDATION_CANDIDATES_V2 = 163
FULL_ASH_MAXIMUM_DEVELOPMENT_ATTEMPTS_V2 = 3288

AUTHORITY_BINDING_IDS = (
    "baseline_ablation_contract_v1",
    "baseline_ablation_contract_v1_schema",
    "quality_gate_policy_v1_seed",
    "calibration_plan_v2",
    "calibration_plan_v2_schema",
    "shared_bank_configuration_identity_v2",
    "shared_bank_configuration_identity_v2_schema",
)

_BUDGET_FORMULA_V1 = (
    "1 + maximum_sweeps * coordinate_count * values_per_coordinate = "
    "1 + 8*27*7 = 1513; full ASH development search is "
    "1 + 8*sum(42 declared domain cardinalities) = 1 + 8*168 = 1345"
)
_BUDGET_FORMULA_V2 = (
    "1 + maximum_sweeps * coordinate_count * values_per_coordinate = "
    "1 + 18*27*7 = 3403; full ASH V2 development search is "
    "8*(256+155) = 3288"
)
_EXPECTED_REPLACEMENTS = {
    "/budget_formula": _BUDGET_FORMULA_V2,
    "/candidate_evaluation_budget": MAXIMUM_DEVELOPMENT_ATTEMPTS_V2,
    "/coordinates/maximum_sweeps": MAXIMUM_SWEEPS_V2,
    "/full_ash_maximum_candidate_evaluation_budget": (
        FULL_ASH_MAXIMUM_DEVELOPMENT_ATTEMPTS_V2
    ),
    "/selector_id": SELECTOR_ID_V2,
}
_EXPECTED_REPLACEMENT_PATHS = frozenset(_EXPECTED_REPLACEMENTS)
_EXPECTED_SELECTOR_ROOT_FIELDS = (
    "selector_id",
    "bank_descriptor_ids",
    "inputs",
    "input_contract",
    "forbidden_inputs_and_operations",
    "score",
    "coordinates",
    "candidate_evaluation_budget",
    "full_ash_maximum_candidate_evaluation_budget",
    "budget_formula",
    "data_separation",
    "output_cache",
)
_EXPECTED_COORDINATE_FIELDS = (
    "order",
    "values",
    "initial_value",
    "candidate_order",
    "sweep_rule",
    "termination",
    "maximum_sweeps",
    "tie_break",
)
_EXPECTED_SOURCE_REPLACED_VALUES = {
    "/budget_formula": _BUDGET_FORMULA_V1,
    "/candidate_evaluation_budget": 1513,
    "/coordinates/maximum_sweeps": 8,
    "/full_ash_maximum_candidate_evaluation_budget": 1345,
    "/selector_id": "continuous-linear-bank-selector-q15-v1",
}
_RULE_FAMILY_V2 = "continuous-linear-bank-selector-q15-v1-byte-semantic-inheritance"


class BaselineAblationBudgetV2Error(ValueError):
    """The V2 overlay, an authority binding, or its selector is invalid."""


@dataclass(frozen=True)
class NonAshSelectorAuthorityIdentityV2:
    """Exact file, self, and schema identities for the selector authority."""

    overlay_file_sha256: str
    overlay_self_sha256: str
    overlay_schema_sha256: str

    def __post_init__(self) -> None:
        if (
            type(self.overlay_file_sha256) is not str
            or self.overlay_file_sha256 != EXPECTED_OVERLAY_FILE_SHA256
            or type(self.overlay_self_sha256) is not str
            or self.overlay_self_sha256 != EXPECTED_OVERLAY_SELF_SHA256
            or type(self.overlay_schema_sha256) is not str
            or self.overlay_schema_sha256 != EXPECTED_OVERLAY_SCHEMA_SHA256
        ):
            raise BaselineAblationBudgetV2Error(
                "selector authority identity triple is invalid"
            )


@dataclass(frozen=True)
class NonAshSelectorExecutionProfileV2:
    """Immutable executable fields authenticated from the V2 overlay."""

    selector_id: str
    coordinate_order: Tuple[str, ...]
    values: Tuple[int, ...]
    initial_value: int
    maximum_sweeps: int
    maximum_development_attempts: int
    maximum_validation_candidates: int
    authority_identity: NonAshSelectorAuthorityIdentityV2

    def __post_init__(self) -> None:
        if (
            type(self.selector_id) is not str
            or self.selector_id != SELECTOR_ID_V2
            or type(self.coordinate_order) is not tuple
            or self.coordinate_order != COORDINATE_ORDER_V2
            or any(type(value) is not str for value in self.coordinate_order)
            or type(self.values) is not tuple
            or self.values != VALUES_V2
            or any(type(value) is not int for value in self.values)
            or type(self.initial_value) is not int
            or self.initial_value != INITIAL_VALUE_V2
            or type(self.maximum_sweeps) is not int
            or self.maximum_sweeps != MAXIMUM_SWEEPS_V2
            or type(self.maximum_development_attempts) is not int
            or self.maximum_development_attempts
            != MAXIMUM_DEVELOPMENT_ATTEMPTS_V2
            or type(self.maximum_validation_candidates) is not int
            or self.maximum_validation_candidates
            != MAXIMUM_VALIDATION_CANDIDATES_V2
            or type(self.authority_identity)
            is not NonAshSelectorAuthorityIdentityV2
        ):
            raise BaselineAblationBudgetV2Error(
                "non-ASH selector execution profile is invalid"
            )


def _reject_duplicate_pairs(
    pairs: Sequence[Tuple[str, object]],
) -> Dict[str, object]:
    result: Dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise BaselineAblationBudgetV2Error(
                f"duplicate JSON member: {key}"
            )
        result[key] = value
    return result


def _reject_nonfinite(token: str) -> object:
    raise BaselineAblationBudgetV2Error(f"non-finite JSON value: {token}")


def _parse_finite_float(token: str) -> float:
    value = float(token)
    if not math.isfinite(value):
        raise BaselineAblationBudgetV2Error(f"non-finite JSON value: {token}")
    return value


def _strict_json_object(payload: bytes, *, label: str) -> Dict[str, object]:
    if type(payload) is not bytes:
        raise BaselineAblationBudgetV2Error(f"{label} payload must be exact bytes")
    if payload.startswith(b"\xef\xbb\xbf"):
        raise BaselineAblationBudgetV2Error(
            f"{label} contains a UTF-8 byte-order mark"
        )
    try:
        text = payload.decode("utf-8")
        value = json.loads(
            text,
            object_pairs_hook=_reject_duplicate_pairs,
            parse_constant=_reject_nonfinite,
            parse_float=_parse_finite_float,
        )
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise BaselineAblationBudgetV2Error(
            f"{label} is not valid UTF-8 JSON"
        ) from error
    if type(value) is not dict:
        raise BaselineAblationBudgetV2Error(f"{label} must be a JSON object")
    return value


def _mapping_items_once(
    value: Mapping[str, object],
    *,
    label: str,
) -> Tuple[Tuple[object, object], ...]:
    if not isinstance(value, Mapping):
        raise BaselineAblationBudgetV2Error(f"{label} must be a mapping")
    try:
        return tuple(value.items())
    except Exception as error:
        raise BaselineAblationBudgetV2Error(
            f"{label} cannot be snapshotted exactly once"
        ) from error


def _snapshot_json_value(value: object, *, label: str) -> object:
    if isinstance(value, Mapping):
        result: Dict[str, object] = {}
        for raw_key, raw_value in _mapping_items_once(value, label=label):
            if type(raw_key) is not str or raw_key in result:
                raise BaselineAblationBudgetV2Error(
                    f"{label} contains an invalid or repeated key"
                )
            result[raw_key] = _snapshot_json_value(
                raw_value,
                label=f"{label}/{raw_key}",
            )
        return result
    if type(value) is list:
        return [
            _snapshot_json_value(item, label=f"{label}/{index}")
            for index, item in enumerate(value)
        ]
    if type(value) in {str, int, bool} or value is None:
        return value
    if type(value) is float and math.isfinite(value):
        return value
    raise BaselineAblationBudgetV2Error(
        f"{label} contains a non-JSON value or scalar subclass"
    )


def _snapshot_json_mapping(
    value: Mapping[str, object],
    *,
    label: str,
) -> Dict[str, object]:
    snapshot = _snapshot_json_value(value, label=label)
    if type(snapshot) is not dict:
        raise BaselineAblationBudgetV2Error(f"{label} must be a mapping")
    return snapshot


def _snapshot_payload_mapping(
    value: Mapping[str, bytes],
) -> Dict[str, bytes]:
    result: Dict[str, bytes] = {}
    for raw_key, raw_payload in _mapping_items_once(
        value,
        label="authority payloads",
    ):
        if type(raw_key) is not str or raw_key in result:
            raise BaselineAblationBudgetV2Error(
                "authority payload IDs are invalid or repeated"
            )
        if type(raw_payload) is not bytes:
            raise BaselineAblationBudgetV2Error(
                f"authority payload must be exact bytes: {raw_key}"
            )
        result[raw_key] = raw_payload
    return result


def _object(value: object, *, label: str) -> Dict[str, object]:
    if type(value) is not dict:
        raise BaselineAblationBudgetV2Error(f"{label} must be an object")
    return value


def _array(value: object, *, label: str) -> list[object]:
    if type(value) is not list:
        raise BaselineAblationBudgetV2Error(f"{label} must be an array")
    return value


def _exact_equal(left: object, right: object) -> bool:
    if type(left) is not type(right):
        return False
    if type(left) is dict:
        if set(left) != set(right) or len(left) != len(right):
            return False
        return all(_exact_equal(left[key], right[key]) for key in left)
    if type(left) is list:
        return len(left) == len(right) and all(
            _exact_equal(left_item, right_item)
            for left_item, right_item in zip(left, right)
        )
    return left == right


def _require_exact(value: object, expected: object, *, label: str) -> None:
    if not _exact_equal(value, expected):
        raise BaselineAblationBudgetV2Error(f"{label} is not the frozen value")


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
        raise BaselineAblationBudgetV2Error(f"{label} schema is invalid") from error
    if errors:
        descriptions = []
        for error in errors:
            location = "/".join(
                str(item) for item in error.absolute_path
            ) or "<root>"
            descriptions.append(f"{location}: {error.message}")
        raise BaselineAblationBudgetV2Error(
            f"{label} schema validation failed: " + "; ".join(descriptions)
        )


def _verify_overlay_and_schema(
    overlay_payload: bytes,
    schema_payload: bytes,
) -> Tuple[Dict[str, object], Dict[str, object]]:
    overlay = _strict_json_object(
        overlay_payload,
        label="baseline_ablation_budget_v2",
    )
    schema = _strict_json_object(
        schema_payload,
        label="baseline_ablation_budget_v2_schema",
    )
    if (
        len(overlay_payload) != EXPECTED_OVERLAY_SIZE_BYTES
        or hashlib.sha256(overlay_payload).hexdigest()
        != EXPECTED_OVERLAY_FILE_SHA256
        or overlay_payload != canonical_json_bytes(overlay) + b"\n"
    ):
        raise BaselineAblationBudgetV2Error(
            "baseline-ablation budget V2 file identity is invalid"
        )
    if (
        len(schema_payload) != EXPECTED_OVERLAY_SCHEMA_SIZE_BYTES
        or hashlib.sha256(schema_payload).hexdigest()
        != EXPECTED_OVERLAY_SCHEMA_SHA256
        or schema_payload != canonical_json_bytes(schema) + b"\n"
    ):
        raise BaselineAblationBudgetV2Error(
            "baseline-ablation budget V2 schema identity is invalid"
        )
    _validate_schema(overlay, schema, label="baseline_ablation_budget_v2")
    if (
        type(overlay.get("artifact_sha256")) is not str
        or overlay["artifact_sha256"] != EXPECTED_OVERLAY_SELF_SHA256
        or manifest_sha256(overlay, field="artifact_sha256")
        != EXPECTED_OVERLAY_SELF_SHA256
    ):
        raise BaselineAblationBudgetV2Error(
            "baseline-ablation budget V2 self-hash is invalid"
        )
    return overlay, schema


def _verify_authority_bindings(
    overlay: Mapping[str, object],
    authority_payloads: Mapping[str, bytes],
) -> Dict[str, Dict[str, object]]:
    raw_bindings = _array(
        overlay.get("authority_bindings"),
        label="authority_bindings",
    )
    binding_by_id: Dict[str, Dict[str, object]] = {}
    binding_order = []
    for index, raw_binding in enumerate(raw_bindings):
        binding = _object(raw_binding, label=f"authority_bindings[{index}]")
        identifier = binding.get("id")
        if type(identifier) is not str or identifier in binding_by_id:
            raise BaselineAblationBudgetV2Error(
                "authority binding IDs are absent, aliased, or duplicated"
            )
        binding_by_id[identifier] = binding
        binding_order.append(identifier)
    if tuple(binding_order) != AUTHORITY_BINDING_IDS:
        raise BaselineAblationBudgetV2Error(
            "authority binding order or membership is invalid"
        )
    if (
        set(authority_payloads) != set(binding_by_id)
        or len(authority_payloads) != len(binding_by_id)
    ):
        raise BaselineAblationBudgetV2Error(
            "authority payload IDs do not exactly match the overlay bindings"
        )

    parsed: Dict[str, Dict[str, object]] = {}
    for identifier in AUTHORITY_BINDING_IDS:
        binding = binding_by_id[identifier]
        payload = authority_payloads[identifier]
        document = _strict_json_object(payload, label=identifier)
        if (
            type(binding.get("size_bytes")) is not int
            or len(payload) != binding["size_bytes"]
        ):
            raise BaselineAblationBudgetV2Error(
                f"authority payload size mismatch: {identifier}"
            )
        if (
            type(binding.get("sha256")) is not str
            or hashlib.sha256(payload).hexdigest() != binding["sha256"]
        ):
            raise BaselineAblationBudgetV2Error(
                f"authority payload SHA-256 mismatch: {identifier}"
            )
        parsed[identifier] = document
        self_hash = binding.get("self_hash")
        if self_hash is not None:
            self_hash_object = _object(
                self_hash,
                label=f"authority_bindings/{identifier}/self_hash",
            )
            if set(self_hash_object) != {"field", "sha256"}:
                raise BaselineAblationBudgetV2Error(
                    f"authority self-hash shape is invalid: {identifier}"
                )
            field = self_hash_object.get("field")
            expected_sha256 = self_hash_object.get("sha256")
            if (
                type(field) is not str
                or type(expected_sha256) is not str
                or type(document.get(field)) is not str
                or document[field] != expected_sha256
                or manifest_sha256(document, field=field) != expected_sha256
            ):
                raise BaselineAblationBudgetV2Error(
                    f"authority self-hash is invalid: {identifier}"
                )

    _validate_schema(
        parsed["baseline_ablation_contract_v1"],
        parsed["baseline_ablation_contract_v1_schema"],
        label="baseline_ablation_contract_v1",
    )
    _validate_schema(
        parsed["calibration_plan_v2"],
        parsed["calibration_plan_v2_schema"],
        label="calibration_plan_v2",
    )
    _validate_schema(
        parsed["shared_bank_configuration_identity_v2"],
        parsed["shared_bank_configuration_identity_v2_schema"],
        label="shared_bank_configuration_identity_v2",
    )
    return parsed


def _source_replaced_value(
    selector: Mapping[str, object],
    pointer: str,
) -> object:
    if pointer == "/coordinates/maximum_sweeps":
        coordinates = _object(
            selector.get("coordinates"),
            label="base selector coordinates",
        )
        return coordinates.get("maximum_sweeps")
    return selector.get(pointer[1:])


def _difference_paths(
    before: object,
    after: object,
    *,
    pointer: str = "",
) -> frozenset[str]:
    if type(before) is not type(after):
        return frozenset({pointer})
    if type(before) is dict:
        before_keys = set(before)
        after_keys = set(after)
        changed = {
            f"{pointer}/{key}"
            for key in before_keys.symmetric_difference(after_keys)
        }
        for key in before_keys.intersection(after_keys):
            changed.update(
                _difference_paths(
                    before[key],
                    after[key],
                    pointer=f"{pointer}/{key}",
                )
            )
        return frozenset(changed)
    if type(before) is list:
        if len(before) != len(after):
            return frozenset({pointer})
        changed = set()
        for index, (before_item, after_item) in enumerate(zip(before, after)):
            changed.update(
                _difference_paths(
                    before_item,
                    after_item,
                    pointer=f"{pointer}/{index}",
                )
            )
        return frozenset(changed)
    return frozenset() if before == after else frozenset({pointer})


def materialize_non_ash_selector_v2(
    base_selector: Mapping[str, object],
    replacements: Mapping[str, object],
) -> Dict[str, object]:
    """Deep-copy the exact V1 selector and apply only the five V2 replacements."""

    base_snapshot = _snapshot_json_mapping(
        base_selector,
        label="base non-ASH selector",
    )
    replacement_snapshot = _snapshot_json_mapping(
        replacements,
        label="selector replacements",
    )
    if tuple(base_snapshot) != _EXPECTED_SELECTOR_ROOT_FIELDS:
        raise BaselineAblationBudgetV2Error(
            "base selector root fields are not the frozen V1 order"
        )
    coordinates = _object(
        base_snapshot.get("coordinates"),
        label="base selector coordinates",
    )
    if tuple(coordinates) != _EXPECTED_COORDINATE_FIELDS:
        raise BaselineAblationBudgetV2Error(
            "base selector coordinate fields are not the frozen V1 order"
        )
    if (
        set(replacement_snapshot) != _EXPECTED_REPLACEMENT_PATHS
        or len(replacement_snapshot) != len(_EXPECTED_REPLACEMENTS)
        or not _exact_equal(replacement_snapshot, _EXPECTED_REPLACEMENTS)
    ):
        raise BaselineAblationBudgetV2Error(
            "selector replacements are not exactly the five registered values"
        )
    for pointer, expected in _EXPECTED_SOURCE_REPLACED_VALUES.items():
        _require_exact(
            _source_replaced_value(base_snapshot, pointer),
            expected,
            label=f"base selector source value {pointer}",
        )

    result = copy.deepcopy(base_snapshot)
    result["selector_id"] = replacement_snapshot["/selector_id"]
    result_coordinates = _object(
        result.get("coordinates"),
        label="materialized selector coordinates",
    )
    result_coordinates["maximum_sweeps"] = replacement_snapshot[
        "/coordinates/maximum_sweeps"
    ]
    result["candidate_evaluation_budget"] = replacement_snapshot[
        "/candidate_evaluation_budget"
    ]
    result["full_ash_maximum_candidate_evaluation_budget"] = (
        replacement_snapshot[
            "/full_ash_maximum_candidate_evaluation_budget"
        ]
    )
    result["budget_formula"] = replacement_snapshot["/budget_formula"]

    if _difference_paths(base_snapshot, result) != _EXPECTED_REPLACEMENT_PATHS:
        raise BaselineAblationBudgetV2Error(
            "materialized selector differs outside the five registered paths"
        )
    payload = canonical_json_bytes(result)
    if (
        len(payload) != EXPECTED_MATERIALIZED_SELECTOR_SIZE_BYTES
        or hashlib.sha256(payload).hexdigest()
        != EXPECTED_MATERIALIZED_SELECTOR_SHA256
    ):
        raise BaselineAblationBudgetV2Error(
            "materialized selector canonical identity is invalid"
        )
    return result


def _verify_flattened_selector(
    overlay: Mapping[str, object],
    selector: Mapping[str, object],
) -> None:
    coordinates = _object(
        selector.get("coordinates"),
        label="materialized selector coordinates",
    )
    expected = {
        "bank_descriptor_ids": selector.get("bank_descriptor_ids"),
        "candidate_order": coordinates.get("candidate_order"),
        "coordinate_order": coordinates.get("order"),
        "data_separation": selector.get("data_separation"),
        "initial_value": coordinates.get("initial_value"),
        "maximum_sweeps": coordinates.get("maximum_sweeps"),
        "output_cache": selector.get("output_cache"),
        "rule_family": _RULE_FAMILY_V2,
        "selector_id": selector.get("selector_id"),
        "sweep_rule": coordinates.get("sweep_rule"),
        "termination": coordinates.get("termination"),
        "tie_break": coordinates.get("tie_break"),
        "values": coordinates.get("values"),
    }
    flattened = _object(
        overlay.get("non_ash_selector_v2"),
        label="non_ash_selector_v2",
    )
    if not _exact_equal(flattened, expected):
        raise BaselineAblationBudgetV2Error(
            "flattened V2 selector differs from the materialized authority"
        )


def _derive_execution_profile(
    overlay: Mapping[str, object],
    selector: Mapping[str, object],
) -> NonAshSelectorExecutionProfileV2:
    coordinates = _object(
        selector.get("coordinates"),
        label="materialized selector coordinates",
    )
    coordinate_order = _array(
        coordinates.get("order"),
        label="materialized selector coordinate order",
    )
    values = _array(
        coordinates.get("values"),
        label="materialized selector values",
    )
    _require_exact(coordinate_order, list(COORDINATE_ORDER_V2), label="coordinate order")
    _require_exact(values, list(VALUES_V2), label="selector values")
    _require_exact(
        coordinates.get("initial_value"),
        INITIAL_VALUE_V2,
        label="selector initial value",
    )
    _require_exact(
        coordinates.get("maximum_sweeps"),
        MAXIMUM_SWEEPS_V2,
        label="selector maximum sweeps",
    )
    _require_exact(
        selector.get("candidate_evaluation_budget"),
        MAXIMUM_DEVELOPMENT_ATTEMPTS_V2,
        label="selector development ceiling",
    )

    budget = _object(overlay.get("budget"), label="budget")
    validation = _object(
        overlay.get("validation_selection"),
        label="validation_selection",
    )
    for field, expected in (
        ("non_ash_coordinate_count", len(COORDINATE_ORDER_V2)),
        ("non_ash_values_per_coordinate", len(VALUES_V2)),
        ("minimum_sufficient_whole_sweep_count", MAXIMUM_SWEEPS_V2),
        (
            "non_ash_maximum_development_attempt_count",
            MAXIMUM_DEVELOPMENT_ATTEMPTS_V2,
        ),
        (
            "full_ash_v2_maximum_development_attempt_count",
            FULL_ASH_MAXIMUM_DEVELOPMENT_ATTEMPTS_V2,
        ),
    ):
        _require_exact(budget.get(field), expected, label=f"budget/{field}")
    _require_exact(
        validation.get("maximum_validation_candidate_count"),
        MAXIMUM_VALIDATION_CANDIDATES_V2,
        label="validation maximum candidate count",
    )
    if (
        1
        + MAXIMUM_SWEEPS_V2 * len(COORDINATE_ORDER_V2) * len(VALUES_V2)
        != MAXIMUM_DEVELOPMENT_ATTEMPTS_V2
        or 1
        + len(COORDINATE_ORDER_V2)
        * validation.get("noncurrent_value_neighbors_per_coordinate", -1)
        != MAXIMUM_VALIDATION_CANDIDATES_V2
    ):
        raise BaselineAblationBudgetV2Error(
            "selector development or validation ceiling does not derive exactly"
        )

    return NonAshSelectorExecutionProfileV2(
        selector_id=selector["selector_id"],
        coordinate_order=tuple(coordinate_order),
        values=tuple(values),
        initial_value=coordinates["initial_value"],
        maximum_sweeps=coordinates["maximum_sweeps"],
        maximum_development_attempts=selector["candidate_evaluation_budget"],
        maximum_validation_candidates=validation[
            "maximum_validation_candidate_count"
        ],
        authority_identity=NonAshSelectorAuthorityIdentityV2(
            overlay_file_sha256=EXPECTED_OVERLAY_FILE_SHA256,
            overlay_self_sha256=EXPECTED_OVERLAY_SELF_SHA256,
            overlay_schema_sha256=EXPECTED_OVERLAY_SCHEMA_SHA256,
        ),
    )


def parse_baseline_ablation_budget_v2(
    overlay_payload: bytes,
    *,
    schema_payload: bytes,
    authority_payloads: Mapping[str, bytes],
) -> NonAshSelectorExecutionProfileV2:
    """Authenticate the V2 overlay and return its immutable selector profile."""

    authority_snapshot = _snapshot_payload_mapping(authority_payloads)
    overlay, _ = _verify_overlay_and_schema(overlay_payload, schema_payload)
    parsed_authorities = _verify_authority_bindings(
        overlay,
        authority_snapshot,
    )
    base_contract = parsed_authorities["baseline_ablation_contract_v1"]
    base_selector = _object(
        base_contract.get("non_ash_selector"),
        label="baseline_ablation_contract_v1/non_ash_selector",
    )
    materialization = _object(
        overlay.get("selector_materialization"),
        label="selector_materialization",
    )
    replacements = _object(
        materialization.get("replacements"),
        label="selector_materialization/replacements",
    )
    selector = materialize_non_ash_selector_v2(base_selector, replacements)
    _require_exact(
        materialization.get("result_canonical_size_bytes"),
        EXPECTED_MATERIALIZED_SELECTOR_SIZE_BYTES,
        label="materialized selector declared size",
    )
    _require_exact(
        materialization.get("result_canonical_sha256"),
        EXPECTED_MATERIALIZED_SELECTOR_SHA256,
        label="materialized selector declared SHA-256",
    )
    _require_exact(
        materialization.get("result_root_fields"),
        list(_EXPECTED_SELECTOR_ROOT_FIELDS),
        label="materialized selector root fields",
    )
    _verify_flattened_selector(overlay, selector)
    return _derive_execution_profile(overlay, selector)
