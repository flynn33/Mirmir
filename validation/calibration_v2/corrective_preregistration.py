"""Strict preregistration for the open-development corrective diagnostic."""

from __future__ import annotations

from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
from typing import Mapping, Sequence

from validation.calibration_v2.corrective_diagnostics import (
    ANISOTROPY_CELLS,
    COORDINATE_CELLS,
    ROUTES,
    canonical_artifact_file_bytes,
    coordinate_anisotropy_dimension_contract,
    risk_state_dimension_contract,
)
from validation.calibration_v2.runner import candidate_vector_sha256
from validation.quality.src.mirmir_quality.json_tools import (
    canonical_json_bytes,
    canonical_sha256,
    validate_schema,
)


CALIBRATION_ROOT = Path(__file__).resolve().parent
PREREGISTRATION_SCHEMA = (
    CALIBRATION_ROOT
    / "schemas/corrective-diagnostic-preregistration-v1.schema.json"
)
LIVE_VERIFICATION_SCHEMA = (
    CALIBRATION_ROOT
    / "schemas/live-holdout-preopen-verification-v1.schema.json"
)
DERIVATION_CONTRACT = "p06-next-coordinate-input-carry-forward-v1"


class CorrectivePreregistrationError(ValueError):
    """A corrective diagnostic preregistration is absent or inconsistent."""


def _require(condition: bool, message: str) -> None:
    if not condition:
        raise CorrectivePreregistrationError(message)


def _is_sha256(value: object) -> bool:
    return (
        isinstance(value, str)
        and len(value) == 64
        and all(character in "0123456789abcdef" for character in value)
    )


def _strict_object_pairs(
    pairs: list[tuple[str, object]],
) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise CorrectivePreregistrationError(
                f"attempt ledger contains duplicate JSON key: {key}"
            )
        result[key] = value
    return result


def _reject_constant(token: str) -> object:
    raise CorrectivePreregistrationError(
        f"attempt ledger contains non-finite JSON number: {token}"
    )


def verify_attempt_ledger_payload(
    payload: bytes,
) -> tuple[Mapping[str, object], ...]:
    """Validate canonical NDJSON bytes and the complete record hash chain."""

    _require(payload.endswith(b"\n"), "attempt ledger lacks its terminal LF")
    lines = payload.splitlines()
    _require(bool(lines), "attempt ledger is empty")
    records: list[Mapping[str, object]] = []
    previous = "0" * 64
    for sequence, line in enumerate(lines):
        _require(bool(line), "attempt ledger contains an empty record")
        try:
            record = json.loads(
                line,
                object_pairs_hook=_strict_object_pairs,
                parse_constant=_reject_constant,
            )
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            raise CorrectivePreregistrationError(
                "attempt ledger is not canonical UTF-8 NDJSON"
            ) from error
        _require(isinstance(record, dict), "attempt ledger record is not an object")
        _require(
            canonical_json_bytes(record) == line,
            "attempt ledger record bytes are not canonical JSON",
        )
        unhashed = dict(record)
        claimed = unhashed.pop("record_sha256", None)
        _require(
            record.get("sequence") == sequence
            and record.get("previous_record_sha256") == previous
            and _is_sha256(claimed)
            and claimed == canonical_sha256(unhashed),
            "attempt ledger hash chain is invalid",
        )
        previous = str(claimed)
        records.append(record)
    return tuple(records)


def corrective_dimension_contract_hashes() -> Mapping[str, object]:
    """Return separate and combined hashes for every fixed experiment axis."""

    combined = coordinate_anisotropy_dimension_contract()
    return {
        "coordinate_dimension_sha256": canonical_sha256(
            {
                "routes": list(ROUTES),
                "coordinate_cells": [dict(value) for value in COORDINATE_CELLS],
            }
        ),
        "anisotropy_dimension_sha256": canonical_sha256(
            {
                "routes": list(ROUTES),
                "anisotropy_cells": [dict(value) for value in ANISOTROPY_CELLS],
            }
        ),
        "coordinate_anisotropy_contract_sha256": canonical_sha256(combined),
        "risk_state_contract_sha256": canonical_sha256(
            risk_state_dimension_contract()
        ),
    }


def corrective_candidate_binding(
    vector: Mapping[str, object],
    plan: Mapping[str, object],
) -> Mapping[str, object]:
    """Bind both plan-order serialization and canonical object encodings."""

    copied = json.loads(canonical_json_bytes(vector))
    _require(isinstance(copied, dict), "candidate vector is not an object")
    object_payload = canonical_json_bytes(copied)
    return {
        "vector": copied,
        "plan_ordered_vector_sha256": candidate_vector_sha256(copied, plan),
        "canonical_vector_object_sha256": hashlib.sha256(
            object_payload
        ).hexdigest(),
        "canonical_vector_file_sha256": hashlib.sha256(
            object_payload + b"\n"
        ).hexdigest(),
    }


def derive_incumbent_binding(
    records: Sequence[Mapping[str, object]],
    *,
    expected_source_sequence: int,
    expected_source_record_sha256: str,
    expected_source_candidate_vector_sha256: str,
    expected_carry_forward_sequence: int,
    expected_carry_forward_record_sha256: str,
) -> Mapping[str, object]:
    """Prove an explicitly named incumbent from a later-coordinate input row."""

    _require(
        isinstance(expected_source_sequence, int)
        and not isinstance(expected_source_sequence, bool)
        and 0 <= expected_source_sequence < len(records),
        "explicit source sequence is outside the attempt ledger",
    )
    _require(
        isinstance(expected_carry_forward_sequence, int)
        and not isinstance(expected_carry_forward_sequence, bool)
        and expected_source_sequence < expected_carry_forward_sequence < len(records),
        "explicit carry-forward sequence is outside or before the source",
    )
    for value, label in (
        (expected_source_record_sha256, "source record"),
        (expected_source_candidate_vector_sha256, "source candidate vector"),
        (expected_carry_forward_record_sha256, "carry-forward record"),
    ):
        _require(_is_sha256(value), f"explicit {label} hash is invalid")

    source = records[expected_source_sequence]
    carry = records[expected_carry_forward_sequence]
    _require(
        source.get("record_sha256") == expected_source_record_sha256
        and source.get("candidate_vector_sha256")
        == expected_source_candidate_vector_sha256
        and carry.get("record_sha256") == expected_carry_forward_record_sha256,
        "explicit incumbent anchors differ from the ledger",
    )
    _require(
        source.get("split") == "development"
        and source.get("phase") == "coordinate_search"
        and carry.get("split") == "development"
        and carry.get("phase") == "coordinate_search",
        "incumbent derivation is not wholly development coordinate-search evidence",
    )
    source_vector = source.get("candidate_vector")
    carry_vector = carry.get("candidate_vector")
    source_coordinate = source.get("coordinate")
    carry_coordinate = carry.get("coordinate")
    _require(
        isinstance(source_vector, dict)
        and isinstance(carry_vector, dict)
        and set(source_vector) == set(carry_vector)
        and isinstance(source_coordinate, str)
        and source_coordinate in source_vector
        and isinstance(carry_coordinate, str)
        and carry_coordinate in carry_vector
        and carry_coordinate != source_coordinate,
        "incumbent derivation vector or coordinate is invalid",
    )
    changed = sorted(
        name
        for name in source_vector
        if source_vector[name] != carry_vector[name]
    )
    _require(
        changed == [carry_coordinate],
        "carry-forward row does not preserve the source vector outside its coordinate",
    )
    _require(
        source.get("value") == source_vector[source_coordinate]
        and carry.get("value") == carry_vector[carry_coordinate],
        "incumbent coordinate value differs from its candidate vector",
    )
    evaluation = source.get("evaluation")
    _require(
        isinstance(evaluation, dict) and _is_sha256(evaluation.get("sha256")),
        "source incumbent evaluation binding is absent",
    )
    source_row_payload = canonical_json_bytes(source)
    derivation = {
        "derivation_contract": DERIVATION_CONTRACT,
        "source_sequence": expected_source_sequence,
        "source_record_sha256": source["record_sha256"],
        "source_previous_record_sha256": source["previous_record_sha256"],
        "source_record_canonical_sha256": hashlib.sha256(
            source_row_payload
        ).hexdigest(),
        "source_candidate_vector_sha256": source["candidate_vector_sha256"],
        "source_evaluation_sha256": evaluation["sha256"],
        "source_summary_sha256": source.get("summary_sha256"),
        "source_development_search_rank_sha256": source.get(
            "development_search_rank_sha256"
        ),
        "source_coordinate": source_coordinate,
        "source_value": source["value"],
        "carry_forward_sequence": expected_carry_forward_sequence,
        "carry_forward_record_sha256": carry["record_sha256"],
        "carry_forward_previous_record_sha256": carry[
            "previous_record_sha256"
        ],
        "carry_forward_coordinate": carry_coordinate,
        "carry_forward_value": carry["value"],
        "carry_forward_candidate_vector_sha256": carry[
            "candidate_vector_sha256"
        ],
        "unchanged_coordinate_count": len(source_vector) - 1,
        "changed_coordinates": changed,
    }
    for field in (
        "source_previous_record_sha256",
        "source_summary_sha256",
        "source_development_search_rank_sha256",
        "carry_forward_previous_record_sha256",
        "carry_forward_candidate_vector_sha256",
    ):
        _require(_is_sha256(derivation[field]), f"derived {field} is invalid")
    return {
        **derivation,
        "derivation_sha256": canonical_sha256(derivation),
    }


def _parse_utc(value: object) -> datetime:
    _require(isinstance(value, str) and value.endswith("Z"), "preregistered UTC is invalid")
    try:
        result = datetime.fromisoformat(value[:-1] + "+00:00")
    except ValueError as error:
        raise CorrectivePreregistrationError(
            "preregistered UTC is invalid"
        ) from error
    _require(result.tzinfo is not None, "preregistered UTC lacks a timezone")
    return result.astimezone(timezone.utc)


def _validate_live_holdout_binding(bindings: Mapping[str, object]) -> None:
    live = bindings.get("live_holdout")
    _require(isinstance(live, dict), "preregistration live guard binding is absent")
    verification = live.get("fresh_verification")
    _require(
        isinstance(verification, dict),
        "preregistration fresh live guard verification is absent",
    )
    validate_schema(verification, LIVE_VERIFICATION_SCHEMA)
    _require(
        live.get("fresh_verification_sha256")
        == canonical_sha256(verification),
        "preregistration fresh live guard verification hash differs",
    )
    explicit_to_verification = {
        "expected_live_ledger_root_identity_sha256": (
            "live_ledger_root_identity_sha256"
        ),
        "expected_live_anchor_root_identity_sha256": (
            "live_anchor_root_identity_sha256"
        ),
        "expected_live_preopen_receipt_sha256": "live_preopen_receipt_sha256",
        "expected_repository_sealed_copy_sha256": (
            "repository_sealed_copy_sha256"
        ),
        "expected_repository_attestation_sha256": (
            "repository_attestation_sha256"
        ),
    }
    _require(
        all(
            live.get(binding_field) == verification.get(verification_field)
            for binding_field, verification_field in explicit_to_verification.items()
        ),
        "preregistration fresh live guard differs from explicit guard anchors",
    )


def build_corrective_preregistration(
    *,
    preregistered_utc: str,
    bindings: Mapping[str, object],
    candidate_vector: Mapping[str, object],
    plan: Mapping[str, object],
    attempt_ledger_payload: bytes,
    expected_source_sequence: int,
    expected_source_record_sha256: str,
    expected_source_candidate_vector_sha256: str,
    expected_carry_forward_sequence: int,
    expected_carry_forward_record_sha256: str,
) -> Mapping[str, object]:
    """Seal an explicitly anchored preregistration without choosing a candidate."""

    records = verify_attempt_ledger_payload(attempt_ledger_payload)
    candidate = corrective_candidate_binding(candidate_vector, plan)
    derivation = derive_incumbent_binding(
        records,
        expected_source_sequence=expected_source_sequence,
        expected_source_record_sha256=expected_source_record_sha256,
        expected_source_candidate_vector_sha256=(
            expected_source_candidate_vector_sha256
        ),
        expected_carry_forward_sequence=expected_carry_forward_sequence,
        expected_carry_forward_record_sha256=expected_carry_forward_record_sha256,
    )
    _require(
        candidate["vector"]
        == records[expected_source_sequence].get("candidate_vector")
        and candidate["plan_ordered_vector_sha256"]
        == expected_source_candidate_vector_sha256,
        "supplied candidate is not the explicitly anchored source incumbent",
    )
    body = {
        "schema_version": "1.0.0",
        "artifact_kind": (
            "p06_open_development_corrective_diagnostic_preregistration"
        ),
        "status": "preregistered_not_executed",
        "preregistered_utc": preregistered_utc,
        "split": "development",
        "validation_accessed": False,
        "holdout_accessed": False,
        "selected_winner": None,
        "bindings": json.loads(canonical_json_bytes(bindings)),
        "candidate": candidate,
        "dimension_contracts": corrective_dimension_contract_hashes(),
        "incumbent_derivation": derivation,
    }
    _parse_utc(preregistered_utc)
    _validate_live_holdout_binding(body["bindings"])
    document = {**body, "artifact_sha256": canonical_sha256(body)}
    validate_schema(document, PREREGISTRATION_SCHEMA)
    return document


def validate_corrective_preregistration(
    document: Mapping[str, object],
    *,
    artifact_payload: bytes,
    expected_artifact_file_sha256: str,
    expected_bindings: Mapping[str, object],
    plan: Mapping[str, object],
    attempt_ledger_payload: bytes,
    expected_source_sequence: int,
    expected_source_record_sha256: str,
    expected_source_candidate_vector_sha256: str,
    expected_carry_forward_sequence: int,
    expected_carry_forward_record_sha256: str,
    execution_not_before_utc: datetime,
) -> Mapping[str, object]:
    """Recompute every preregistered binding before any development pixel load."""

    _require(
        _is_sha256(expected_artifact_file_sha256),
        "explicit preregistration file hash is invalid",
    )
    validate_schema(document, PREREGISTRATION_SCHEMA)
    canonical_payload = canonical_artifact_file_bytes(document)
    _require(
        artifact_payload == canonical_payload
        and hashlib.sha256(artifact_payload).hexdigest()
        == expected_artifact_file_sha256,
        "preregistration file bytes differ from their explicit hash or canonical form",
    )
    unhashed = dict(document)
    artifact_hash = unhashed.pop("artifact_sha256", None)
    _require(
        artifact_hash == canonical_sha256(unhashed),
        "preregistration self-hash differs",
    )
    _require(
        _parse_utc(document.get("preregistered_utc"))
        <= execution_not_before_utc.astimezone(timezone.utc),
        "preregistration was created after execution began",
    )
    _require(
        document.get("bindings")
        == json.loads(canonical_json_bytes(expected_bindings)),
        "preregistration input bindings differ from current immutable inputs",
    )
    bindings = document.get("bindings")
    assert isinstance(bindings, dict)
    _validate_live_holdout_binding(bindings)

    records = verify_attempt_ledger_payload(attempt_ledger_payload)
    expected_derivation = derive_incumbent_binding(
        records,
        expected_source_sequence=expected_source_sequence,
        expected_source_record_sha256=expected_source_record_sha256,
        expected_source_candidate_vector_sha256=(
            expected_source_candidate_vector_sha256
        ),
        expected_carry_forward_sequence=expected_carry_forward_sequence,
        expected_carry_forward_record_sha256=expected_carry_forward_record_sha256,
    )
    _require(
        document.get("incumbent_derivation") == expected_derivation,
        "preregistration incumbent derivation differs from the archived ledger",
    )
    candidate = document.get("candidate")
    _require(isinstance(candidate, dict), "preregistration candidate is absent")
    vector = candidate.get("vector")
    _require(isinstance(vector, dict), "preregistration candidate vector is absent")
    _require(
        candidate == corrective_candidate_binding(vector, plan)
        and vector == records[expected_source_sequence].get("candidate_vector")
        and candidate.get("plan_ordered_vector_sha256")
        == expected_source_candidate_vector_sha256,
        "preregistration candidate differs from plan or source incumbent",
    )
    _require(
        document.get("dimension_contracts")
        == corrective_dimension_contract_hashes(),
        "preregistration experiment dimension hashes differ",
    )
    return json.loads(canonical_json_bytes(document))


__all__ = [
    "CorrectivePreregistrationError",
    "DERIVATION_CONTRACT",
    "PREREGISTRATION_SCHEMA",
    "build_corrective_preregistration",
    "corrective_candidate_binding",
    "corrective_dimension_contract_hashes",
    "derive_incumbent_binding",
    "validate_corrective_preregistration",
    "verify_attempt_ledger_payload",
]
