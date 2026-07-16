"""Strict persistence and semantic reopening for V2 non-ASH artifacts.

The selector core deliberately has no filesystem capability.  This module is
the versioned adapter that validates the four schema-backed selector artifact
surfaces, publishes their exact canonical bytes by content address, and
replays the cross-artifact semantics required before reopened evidence may be
used.
"""

from __future__ import annotations

from dataclasses import dataclass
from functools import lru_cache
import hashlib
import json
import math
import os
from pathlib import Path
import re
import stat
from typing import Callable, Dict, Mapping, Optional, Sequence, Tuple
import unicodedata

from jsonschema import Draft202012Validator

from validation.calibration_v2.baseline_ablation_budget_v2 import (
    NonAshSelectorAuthorityIdentityV2,
    NonAshSelectorExecutionProfileV2,
)
from validation.calibration_v2.non_ash_selector_v2 import (
    DEVELOPMENT_SPLIT,
    DEVELOPMENT_STATUS_ABORTED,
    DEVELOPMENT_STATUS_CONVERGED,
    DEVELOPMENT_STATUS_MAXIMUM_SWEEPS_EXHAUSTED,
    FAILURE_TYPE_CONSTRAINT,
    FAILURE_TYPE_EVALUATION,
    FAILURE_TYPE_EVIDENCE_INTEGRITY,
    VALIDATION_SPLIT,
    NonAshSelectorAttemptRecordV2,
    NonAshSelectorEvaluationFailureV2,
    NonAshSelectorEvaluationScopeV2,
    NonAshSelectorEvaluationV2,
    NonAshSelectorOutcomeV2,
    canonical_rule_values_v2,
    non_ash_validation_neighborhood_v2,
    replay_non_ash_development_search_v2,
    rule_mapping_v2,
    rule_sha256_v2,
)
from validation.calibration_v2.production_providers import (
    ContentAddressedEvidenceStore,
)


CALIBRATION_ROOT = Path(__file__).resolve().parent
SCHEMA_ROOT = CALIBRATION_ROOT / "schemas"
CONTRACT_ROOT = CALIBRATION_ROOT / "contracts"

ATTEMPT_FAILURE_KIND = "p06_non_ash_selector_attempt_failure_v2"
ATTEMPT_LEDGER_KIND = "p06_non_ash_selector_attempt_ledger_v2"
SELECTION_KIND = "p06_non_ash_selector_selection_v2"
NEIGHBOR_MANIFEST_KIND = "p06_non_ash_validation_neighbor_manifest_v2"
EVALUATION_EVIDENCE_KIND = "p06_non_ash_selector_evaluation_evidence_v2"
EVALUATION_EVIDENCE_SCHEMA_VERSION = "2.0.2"

_SCHEMA_SPECS = {
    ATTEMPT_FAILURE_KIND: (
        SCHEMA_ROOT / "non-ash-selector-attempt-failure-v2.schema.json",
        "dd9edd84ca809695e6c0c98438edc9c4b8a5921e513638227e181b99bcb42a16",
    ),
    ATTEMPT_LEDGER_KIND: (
        SCHEMA_ROOT / "non-ash-selector-attempt-ledger-v2.schema.json",
        "bcf065f97e4297c283a7607d4aa447e34dfa108c6dcdd229456f69132b46b7ce",
    ),
    SELECTION_KIND: (
        SCHEMA_ROOT / "non-ash-selector-selection-v2.schema.json",
        "d5cfa23e51a440887c2cc50ef2816eff1e228c1fab6eb86e66ee73a849a85fa9",
    ),
    NEIGHBOR_MANIFEST_KIND: (
        SCHEMA_ROOT / "non-ash-validation-neighbor-manifest-v2.schema.json",
        "d58d7cd27d3907696c8367f5e0fb79e2011733901f2dff34b996c6c3703bfe45",
    ),
}

_AUTHORITY_SPECS = {
    "baseline_ablation_budget_v2": (
        CONTRACT_ROOT / "baseline-ablation-budget-v2.json",
        SCHEMA_ROOT / "baseline-ablation-budget-v2.schema.json",
        "artifact_sha256",
    ),
    "calibration_plan_v2": (
        CONTRACT_ROOT / "calibration-plan-v2.json",
        SCHEMA_ROOT / "calibration-plan-v2.schema.json",
        "plan_sha256",
    ),
    "candidate_evidence_policy_v2": (
        CONTRACT_ROOT / "candidate-evidence-policy-v2.json",
        SCHEMA_ROOT / "candidate-evidence-policy-v2.schema.json",
        "artifact_sha256",
    ),
    "compiler_contract_v2": (
        CONTRACT_ROOT / "compiler-contract-v2.json",
        SCHEMA_ROOT / "compiler-contract-v2.schema.json",
        "artifact_sha256",
    ),
    "control_execution_producer_identity_v2": (
        CONTRACT_ROOT / "control-execution-producer-identity-v2.json",
        SCHEMA_ROOT / "control-execution-producer-identity-v2.schema.json",
        "artifact_sha256",
    ),
    "shared_bank_configuration_identity_v2": (
        CONTRACT_ROOT / "shared-bank-configuration-identity-v2.json",
        SCHEMA_ROOT / "shared-bank-configuration-identity-v2.schema.json",
        "artifact_sha256",
    ),
}

_SHA256_LENGTH = 64
_READ_CHUNK_SIZE = 1024 * 1024
_SAFE_RELATIVE_PATH = re.compile(
    r"^(?!/)(?!.*\\)(?!.*//)(?!.*(?:^|/)\.\.?(?:/|$))[^\x00]+$"
)


class NonAshSelectorArtifactV2Error(ValueError):
    """A V2 artifact byte, schema, authority, or semantic check failed."""


def _snapshot_execution_context(
    profile: NonAshSelectorExecutionProfileV2,
    evaluation_scope: NonAshSelectorEvaluationScopeV2,
) -> Tuple[NonAshSelectorExecutionProfileV2, NonAshSelectorEvaluationScopeV2]:
    """Detach immutable-looking caller objects before any callback can mutate them."""

    if type(profile) is not NonAshSelectorExecutionProfileV2:
        raise NonAshSelectorArtifactV2Error(
            "selector execution profile has the wrong type"
        )
    authority = getattr(profile, "authority_identity", None)
    if type(authority) is not NonAshSelectorAuthorityIdentityV2:
        raise NonAshSelectorArtifactV2Error(
            "selector execution authority has the wrong type"
        )
    if type(evaluation_scope) is not NonAshSelectorEvaluationScopeV2:
        raise NonAshSelectorArtifactV2Error(
            "selector evaluation scope has the wrong type"
        )
    try:
        authority_snapshot = NonAshSelectorAuthorityIdentityV2(
            overlay_file_sha256=authority.overlay_file_sha256,
            overlay_self_sha256=authority.overlay_self_sha256,
            overlay_schema_sha256=authority.overlay_schema_sha256,
        )
        profile_snapshot = NonAshSelectorExecutionProfileV2(
            selector_id=profile.selector_id,
            coordinate_order=tuple(profile.coordinate_order),
            values=tuple(profile.values),
            initial_value=profile.initial_value,
            maximum_sweeps=profile.maximum_sweeps,
            maximum_development_attempts=profile.maximum_development_attempts,
            maximum_validation_candidates=profile.maximum_validation_candidates,
            authority_identity=authority_snapshot,
        )
        scope_snapshot = NonAshSelectorEvaluationScopeV2(
            shared_bank_configuration_sha256=(
                evaluation_scope.shared_bank_configuration_sha256
            ),
            degradation_policy_sha256=evaluation_scope.degradation_policy_sha256,
            calibration_plan_file_sha256=(
                evaluation_scope.calibration_plan_file_sha256
            ),
            cached_16_operator_output_manifest_sha256=(
                evaluation_scope.cached_16_operator_output_manifest_sha256
            ),
        )
    except Exception as error:
        raise NonAshSelectorArtifactV2Error(
            "selector execution context is invalid"
        ) from error
    return profile_snapshot, scope_snapshot


def _snapshot_evaluation_scope(
    scope: NonAshSelectorEvaluationScopeV2,
) -> NonAshSelectorEvaluationScopeV2:
    """Return a detached exact copy of one callback-supplied evaluation scope."""

    if type(scope) is not NonAshSelectorEvaluationScopeV2:
        raise NonAshSelectorArtifactV2Error(
            "reopened evaluation scope has the wrong type"
        )
    try:
        return NonAshSelectorEvaluationScopeV2(
            shared_bank_configuration_sha256=(
                scope.shared_bank_configuration_sha256
            ),
            degradation_policy_sha256=scope.degradation_policy_sha256,
            calibration_plan_file_sha256=scope.calibration_plan_file_sha256,
            cached_16_operator_output_manifest_sha256=(
                scope.cached_16_operator_output_manifest_sha256
            ),
        )
    except Exception as error:
        raise NonAshSelectorArtifactV2Error(
            "reopened evaluation scope is invalid"
        ) from error


def _is_sha256(value: object) -> bool:
    return (
        type(value) is str
        and len(value) == _SHA256_LENGTH
        and value != "0" * _SHA256_LENGTH
        and all(character in "0123456789abcdef" for character in value)
    )


def _sha256(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def _strict_json_snapshot(
    value: object,
    *,
    label: str,
    active_containers: Optional[set[int]] = None,
) -> object:
    if active_containers is None:
        active_containers = set()
    if value is None or type(value) in {str, bool}:
        return value
    if type(value) is int:
        return value
    if type(value) is float:
        if not math.isfinite(value):
            raise NonAshSelectorArtifactV2Error(f"{label} contains a nonfinite number")
        return value
    if type(value) not in {dict, list}:
        raise NonAshSelectorArtifactV2Error(
            f"{label} contains a non-built-in JSON value"
        )
    identity = id(value)
    if identity in active_containers:
        raise NonAshSelectorArtifactV2Error(f"{label} contains a cycle")
    active_containers.add(identity)
    try:
        if type(value) is list:
            return [
                _strict_json_snapshot(
                    member,
                    label=f"{label}[{index}]",
                    active_containers=active_containers,
                )
                for index, member in enumerate(value)
            ]
        snapshot: Dict[str, object] = {}
        for key, member in value.items():
            if type(key) is not str or key in snapshot:
                raise NonAshSelectorArtifactV2Error(
                    f"{label} contains a duplicate or non-string object key"
                )
            snapshot[key] = _strict_json_snapshot(
                member,
                label=f"{label}/{key}",
                active_containers=active_containers,
            )
        return snapshot
    finally:
        active_containers.remove(identity)


def canonical_artifact_bytes_v2(document: Mapping[str, object]) -> bytes:
    """Return exact compact canonical bytes for one built-in JSON object."""

    if type(document) is not dict:
        raise NonAshSelectorArtifactV2Error(
            "artifact root must be an exact built-in dictionary"
        )
    snapshot = _strict_json_snapshot(document, label="artifact")
    try:
        return json.dumps(
            snapshot,
            ensure_ascii=False,
            allow_nan=False,
            sort_keys=True,
            separators=(",", ":"),
        ).encode("utf-8")
    except (TypeError, ValueError, UnicodeError) as error:
        raise NonAshSelectorArtifactV2Error(
            "artifact cannot be encoded as canonical UTF-8 JSON"
        ) from error


def _snapshot_json_object(value: object, *, label: str) -> Dict[str, object]:
    if type(value) is not dict:
        raise NonAshSelectorArtifactV2Error(f"{label} is not a built-in object")
    snapshot = _strict_json_snapshot(value, label=label)
    if type(snapshot) is not dict:
        raise AssertionError("strict JSON object snapshot changed type")
    return snapshot


def _reject_duplicate_pairs(
    pairs: Sequence[Tuple[str, object]],
) -> Dict[str, object]:
    result: Dict[str, object] = {}
    for key, value in pairs:
        if type(key) is not str or key in result:
            raise NonAshSelectorArtifactV2Error(
                "JSON object contains a duplicate or non-string key"
            )
        result[key] = value
    return result


def _reject_nonfinite(token: str) -> object:
    raise NonAshSelectorArtifactV2Error(f"JSON contains nonfinite token {token}")


def _parse_finite_float(token: str) -> float:
    value = float(token)
    if not math.isfinite(value):
        raise NonAshSelectorArtifactV2Error("JSON contains a nonfinite number")
    return value


def _parse_strict_json_object(payload: bytes, *, label: str) -> Dict[str, object]:
    if type(payload) is not bytes or not payload:
        raise NonAshSelectorArtifactV2Error(f"{label} bytes are empty or invalid")
    try:
        value = json.loads(
            payload,
            object_pairs_hook=_reject_duplicate_pairs,
            parse_constant=_reject_nonfinite,
            parse_float=_parse_finite_float,
        )
    except NonAshSelectorArtifactV2Error:
        raise
    except (UnicodeDecodeError, json.JSONDecodeError, ValueError) as error:
        raise NonAshSelectorArtifactV2Error(f"{label} is not strict JSON") from error
    if type(value) is not dict:
        raise NonAshSelectorArtifactV2Error(f"{label} root is not an object")
    return value


def _read_regular_file(path: Path, *, label: str) -> bytes:
    try:
        before = os.stat(path, follow_symlinks=False)
    except OSError as error:
        raise NonAshSelectorArtifactV2Error(f"{label} cannot be inspected") from error
    if stat.S_ISLNK(before.st_mode) or not stat.S_ISREG(before.st_mode):
        raise NonAshSelectorArtifactV2Error(f"{label} is not a regular file")
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        raise NonAshSelectorArtifactV2Error(f"{label} cannot be opened") from error
    try:
        opened = os.fstat(descriptor)
        if (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino):
            raise NonAshSelectorArtifactV2Error(f"{label} changed while opening")
        chunks = []
        while True:
            chunk = os.read(descriptor, _READ_CHUNK_SIZE)
            if not chunk:
                break
            chunks.append(chunk)
        after = os.fstat(descriptor)
    finally:
        os.close(descriptor)
    if (
        (after.st_dev, after.st_ino) != (before.st_dev, before.st_ino)
        or after.st_size != before.st_size
        or after.st_mtime_ns != before.st_mtime_ns
    ):
        raise NonAshSelectorArtifactV2Error(f"{label} changed while reading")
    return b"".join(chunks)


def _canonical_self_sha256(document: Mapping[str, object], field: str) -> str:
    if type(document) is not dict or type(field) is not str or field not in document:
        raise NonAshSelectorArtifactV2Error("artifact self-hash field is absent")
    unhashed = dict(document)
    unhashed.pop(field)
    return _sha256(canonical_artifact_bytes_v2(unhashed))


def _self_hash_field(document: Mapping[str, object]) -> str:
    kind = document.get("artifact_kind")
    if kind == ATTEMPT_FAILURE_KIND:
        return "failure_sha256"
    if kind == ATTEMPT_LEDGER_KIND:
        return "ledger_sha256"
    if kind == NEIGHBOR_MANIFEST_KIND:
        return "manifest_sha256"
    if kind == SELECTION_KIND:
        stage = document.get("selection_stage")
        if stage == "development_provisional":
            return "development_selection_sha256"
        if stage == "validation_final":
            return "validation_selection_sha256"
    raise NonAshSelectorArtifactV2Error("artifact self-hash identity is invalid")


def _verify_self_hash(document: Mapping[str, object]) -> None:
    field = _self_hash_field(document)
    if document.get(field) != _canonical_self_sha256(document, field):
        raise NonAshSelectorArtifactV2Error(f"{field} does not authenticate the artifact")


def _load_authenticated_schema(kind: str) -> Tuple[Mapping[str, object], str]:
    spec = _SCHEMA_SPECS.get(kind)
    if spec is None:
        raise NonAshSelectorArtifactV2Error("artifact kind has no V2 schema")
    path, expected_sha256 = spec
    payload = _read_regular_file(path, label=f"schema {path.name}")
    if _sha256(payload) != expected_sha256:
        raise NonAshSelectorArtifactV2Error(f"schema {path.name} byte hash differs")
    schema = _parse_strict_json_object(payload, label=f"schema {path.name}")
    if payload != canonical_artifact_bytes_v2(schema) + b"\n":
        raise NonAshSelectorArtifactV2Error(f"schema {path.name} is not canonical")
    try:
        Draft202012Validator.check_schema(schema)
    except Exception as error:
        raise NonAshSelectorArtifactV2Error(f"schema {path.name} is invalid") from error
    return schema, expected_sha256


def _verify_authority_bindings(document: Mapping[str, object]) -> None:
    bindings = document.get("authority_bindings")
    if type(bindings) is not dict or tuple(sorted(bindings)) != tuple(
        sorted(_AUTHORITY_SPECS)
    ):
        raise NonAshSelectorArtifactV2Error("authority binding set differs")
    for authority_id, (contract_path, schema_path, self_hash_field) in (
        _AUTHORITY_SPECS.items()
    ):
        binding = bindings.get(authority_id)
        if type(binding) is not dict or set(binding) != {
            "file_sha256",
            "schema_file_sha256",
            "self_sha256",
        }:
            raise NonAshSelectorArtifactV2Error(
                f"authority binding {authority_id} is incomplete"
            )
        contract_payload = _read_regular_file(
            contract_path,
            label=f"authority {authority_id}",
        )
        schema_payload = _read_regular_file(
            schema_path,
            label=f"authority schema {authority_id}",
        )
        contract = _parse_strict_json_object(
            contract_payload,
            label=f"authority {authority_id}",
        )
        if (
            binding.get("file_sha256") != _sha256(contract_payload)
            or binding.get("schema_file_sha256") != _sha256(schema_payload)
            or binding.get("self_sha256")
            != _canonical_self_sha256(contract, self_hash_field)
            or contract.get(self_hash_field) != binding.get("self_sha256")
        ):
            raise NonAshSelectorArtifactV2Error(
                f"authority binding {authority_id} differs from reopened bytes"
            )


@lru_cache(maxsize=1)
def _authenticated_authority_bindings_bytes_v2() -> bytes:
    """Authenticate once and retain immutable canonical binding bytes."""

    bindings: Dict[str, object] = {}
    for authority_id, (contract_path, schema_path, self_hash_field) in (
        _AUTHORITY_SPECS.items()
    ):
        contract_payload = _read_regular_file(
            contract_path,
            label=f"authority {authority_id}",
        )
        schema_payload = _read_regular_file(
            schema_path,
            label=f"authority schema {authority_id}",
        )
        contract = _parse_strict_json_object(
            contract_payload,
            label=f"authority {authority_id}",
        )
        self_sha256 = _canonical_self_sha256(contract, self_hash_field)
        if contract.get(self_hash_field) != self_sha256:
            raise NonAshSelectorArtifactV2Error(
                f"authority {authority_id} self hash differs"
            )
        bindings[authority_id] = {
            "file_sha256": _sha256(contract_payload),
            "schema_file_sha256": _sha256(schema_payload),
            "self_sha256": self_sha256,
        }
    return canonical_artifact_bytes_v2(bindings)


def _authority_bindings_v2() -> Dict[str, object]:
    return _parse_strict_json_object(
        _authenticated_authority_bindings_bytes_v2(),
        label="authenticated authority bindings",
    )


def _require_exact_authority_bindings_v2(document: Mapping[str, object]) -> None:
    if document.get("authority_bindings") != _authority_bindings_v2():
        raise NonAshSelectorArtifactV2Error("authority binding set differs")


def _validate_schema_and_common_scope(
    document: Mapping[str, object],
    profile: NonAshSelectorExecutionProfileV2,
    evaluation_scope: NonAshSelectorEvaluationScopeV2,
) -> str:
    if type(document) is not dict:
        raise NonAshSelectorArtifactV2Error("artifact is not a built-in object")
    canonical_artifact_bytes_v2(document)
    kind = document.get("artifact_kind")
    if type(kind) is not str:
        raise NonAshSelectorArtifactV2Error("artifact kind is absent")
    schema, schema_sha256 = _load_authenticated_schema(kind)
    errors = sorted(
        Draft202012Validator(schema).iter_errors(document),
        key=lambda error: tuple(str(member) for member in error.absolute_path),
    )
    if errors:
        details = []
        for error in errors:
            location = "/".join(str(member) for member in error.absolute_path) or "<root>"
            details.append(f"{location}: {error.message}")
        raise NonAshSelectorArtifactV2Error(
            "artifact schema validation failed: " + "; ".join(details)
        )
    _verify_authority_bindings(document)
    authority = getattr(profile, "authority_identity", None)
    baseline = document["authority_bindings"]["baseline_ablation_budget_v2"]
    if (
        type(profile) is not NonAshSelectorExecutionProfileV2
        or authority is None
        or profile.selector_id != document.get("selector_id")
        or baseline.get("file_sha256")
        != getattr(authority, "overlay_file_sha256", None)
        or baseline.get("self_sha256")
        != getattr(authority, "overlay_self_sha256", None)
        or baseline.get("schema_file_sha256")
        != getattr(authority, "overlay_schema_sha256", None)
    ):
        raise NonAshSelectorArtifactV2Error("selector execution authority differs")
    if (
        type(evaluation_scope) is not NonAshSelectorEvaluationScopeV2
        or document.get("shared_bank_configuration_sha256")
        != evaluation_scope.shared_bank_configuration_sha256
        or document.get("degradation_policy_sha256")
        != evaluation_scope.degradation_policy_sha256
        or document.get("cached_16_operator_output_manifest_sha256")
        != evaluation_scope.cached_16_operator_output_manifest_sha256
        or document["authority_bindings"]["calibration_plan_v2"].get(
            "file_sha256"
        )
        != evaluation_scope.calibration_plan_file_sha256
    ):
        raise NonAshSelectorArtifactV2Error("artifact evaluation scope differs")
    _verify_self_hash(document)
    return schema_sha256


def _rule_values(
    value: object,
    profile: NonAshSelectorExecutionProfileV2,
) -> Tuple[int, ...]:
    if type(value) is not list:
        raise NonAshSelectorArtifactV2Error("canonical rule values are not an array")
    try:
        return canonical_rule_values_v2(
            rule_mapping_v2(tuple(value), profile),
            profile,
        )
    except Exception as error:
        raise NonAshSelectorArtifactV2Error("canonical rule values are invalid") from error


def _objective_tuple(value: object, *, label: str) -> Tuple[object, ...]:
    if type(value) is not list or len(value) != 5:
        raise NonAshSelectorArtifactV2Error(f"{label} is not an exact five-member array")
    result = []
    for member in value:
        if type(member) is int:
            result.append(member)
        elif type(member) is float and math.isfinite(member):
            result.append(member)
        else:
            raise NonAshSelectorArtifactV2Error(
                f"{label} contains a non-built-in or nonfinite number"
            )
    return tuple(result)


def _evaluation_from_ledger_record(
    record: Mapping[str, object],
    scope: NonAshSelectorEvaluationScopeV2,
) -> NonAshSelectorOutcomeV2:
    outcome = record.get("outcome")
    if type(outcome) is not dict:
        raise NonAshSelectorArtifactV2Error("ledger outcome is not an object")
    rule_sha256 = record.get("rule_sha256")
    if outcome.get("outcome_type") == "evaluated":
        return NonAshSelectorEvaluationV2(
            split=DEVELOPMENT_SPLIT,
            scope=scope,
            rule_sha256=rule_sha256,
            evaluation_sha256=outcome.get("evaluation_sha256"),
            objective_summary_sha256=outcome.get("objective_summary_sha256"),
            output_manifest_sha256=outcome.get("output_manifest_sha256"),
            objective_means=_objective_tuple(
                outcome.get("engine_raw_corpus_mean_tuple"),
                label="ledger objective",
            ),
        )
    if outcome.get("outcome_type") == "failed":
        return NonAshSelectorEvaluationFailureV2(
            split=DEVELOPMENT_SPLIT,
            scope=scope,
            rule_sha256=rule_sha256,
            failure_type=outcome.get("failure_type"),
            attempt_failure_sha256=outcome.get("attempt_failure_sha256"),
        )
    raise NonAshSelectorArtifactV2Error("ledger outcome type is invalid")


def _attempt_records_from_ledger(
    document: Mapping[str, object],
    profile: NonAshSelectorExecutionProfileV2,
    scope: NonAshSelectorEvaluationScopeV2,
) -> Tuple[NonAshSelectorAttemptRecordV2, ...]:
    records = document.get("records")
    if type(records) is not list:
        raise NonAshSelectorArtifactV2Error("ledger records are not an array")
    converted = []
    for row in records:
        if type(row) is not dict:
            raise NonAshSelectorArtifactV2Error("ledger record is not an object")
        values = _rule_values(row.get("canonical_rule_values"), profile=profile)
        converted.append(
            NonAshSelectorAttemptRecordV2(
                attempt_ordinal=row.get("attempt_ordinal"),
                previous_record_sha256=row.get("previous_record_sha256"),
                record_sha256=row.get("record_sha256"),
                split=DEVELOPMENT_SPLIT,
                phase=row.get("phase"),
                sweep=row.get("sweep"),
                coordinate_ordinal=row.get("coordinate_ordinal"),
                coordinate_name=row.get("coordinate_name"),
                coordinate_value=row.get("coordinate_value"),
                rule_sha256=row.get("rule_sha256"),
                canonical_rule_values=values,
                cache_hit=row.get("cache_hit"),
                outcome=_evaluation_from_ledger_record(row, scope),
            )
        )
    return tuple(converted)


def _full_content_document(
    value: object,
    expected_sha256: str,
    *,
    label: str,
) -> Mapping[str, object]:
    if type(value) is not dict:
        raise NonAshSelectorArtifactV2Error(f"{label} reopener returned a non-object")
    snapshot = _strict_json_snapshot(value, label=label)
    if type(snapshot) is not dict:
        raise AssertionError("strict JSON object snapshot changed type")
    payload = canonical_artifact_bytes_v2(snapshot)
    if _sha256(payload) != expected_sha256:
        raise NonAshSelectorArtifactV2Error(f"{label} content address differs")
    return snapshot


FailureArtifactReopenerV2 = Callable[[str], Mapping[str, object]]
DevelopmentEvidenceReopenerV2 = Callable[[str], bytes]
ValidationEvidenceReopenerV2 = Callable[[str], bytes]
EvidenceBindingReopenerV2 = Callable[[Mapping[str, object]], bytes]
ImmutableContentReopenerV2 = Callable[[str], bytes]


def canonical_evaluation_evidence_bytes_v2(
    *,
    selector_id: str,
    split: str,
    evaluation_scope: NonAshSelectorEvaluationScopeV2,
    rule_sha256: str,
    objective_summary_sha256: str,
    output_manifest_sha256: str,
    objective_means: Tuple[object, ...],
) -> bytes:
    """Serialize the exact content-addressed non-ASH evaluation evidence envelope."""

    scope = _snapshot_evaluation_scope(evaluation_scope)
    if (
        type(selector_id) is not str
        or not selector_id
        or type(split) is not str
        or split not in {DEVELOPMENT_SPLIT, VALIDATION_SPLIT}
        or not _is_sha256(scope.shared_bank_configuration_sha256)
        or not _is_sha256(scope.degradation_policy_sha256)
        or not _is_sha256(scope.calibration_plan_file_sha256)
        or not _is_sha256(
            scope.cached_16_operator_output_manifest_sha256
        )
        or not _is_sha256(rule_sha256)
        or not _is_sha256(objective_summary_sha256)
        or not _is_sha256(output_manifest_sha256)
        or type(objective_means) is not tuple
    ):
        raise NonAshSelectorArtifactV2Error(
            "evaluation evidence identity is invalid"
        )
    objective = _objective_tuple(
        list(objective_means),
        label="evaluation evidence objective",
    )
    return canonical_artifact_bytes_v2(
        {
            "artifact_kind": EVALUATION_EVIDENCE_KIND,
            "schema_version": EVALUATION_EVIDENCE_SCHEMA_VERSION,
            "authority_bindings": _authority_bindings_v2(),
            "selector_id": selector_id,
            "split": split,
            "evaluation_scope": {
                "shared_bank_configuration_sha256": (
                    scope.shared_bank_configuration_sha256
                ),
                "degradation_policy_sha256": scope.degradation_policy_sha256,
                "calibration_plan_file_sha256": (
                    scope.calibration_plan_file_sha256
                ),
                "cached_16_operator_output_manifest_sha256": (
                    scope.cached_16_operator_output_manifest_sha256
                ),
            },
            "rule_sha256": rule_sha256,
            "objective_summary_sha256": objective_summary_sha256,
            "output_manifest_sha256": output_manifest_sha256,
            "engine_raw_corpus_mean_tuple": list(objective),
        }
    )


def _reopen_evaluation_evidence_v2(
    digest: object,
    reopener: object,
    *,
    expected: NonAshSelectorEvaluationV2,
    selector_id: str,
    label: str,
) -> NonAshSelectorEvaluationV2:
    if not _is_sha256(digest):
        raise NonAshSelectorArtifactV2Error(f"{label} digest is invalid")
    if not callable(reopener):
        raise NonAshSelectorArtifactV2Error(f"{label} reopener is required")
    try:
        value = reopener(digest)
    except Exception as error:
        raise NonAshSelectorArtifactV2Error(
            f"{label} could not be reopened"
        ) from error
    if type(value) is not bytes:
        raise NonAshSelectorArtifactV2Error(
            f"{label} reopener returned non-bytes"
        )
    payload = bytes(value)
    if not payload or _sha256(payload) != digest:
        raise NonAshSelectorArtifactV2Error(f"{label} content address differs")
    document = _parse_strict_json_object(payload, label=label)
    if canonical_artifact_bytes_v2(document) != payload:
        raise NonAshSelectorArtifactV2Error(f"{label} is not canonical")
    expected_fields = {
        "artifact_kind",
        "schema_version",
        "authority_bindings",
        "selector_id",
        "split",
        "evaluation_scope",
        "rule_sha256",
        "objective_summary_sha256",
        "output_manifest_sha256",
        "engine_raw_corpus_mean_tuple",
    }
    scope_document = document.get("evaluation_scope")
    expected_scope_fields = {
        "shared_bank_configuration_sha256",
        "degradation_policy_sha256",
        "calibration_plan_file_sha256",
        "cached_16_operator_output_manifest_sha256",
    }
    if (
        set(document) != expected_fields
        or document.get("artifact_kind") != EVALUATION_EVIDENCE_KIND
        or document.get("schema_version")
        != EVALUATION_EVIDENCE_SCHEMA_VERSION
        or document.get("selector_id") != selector_id
        or type(document.get("split")) is not str
        or document.get("split") not in {DEVELOPMENT_SPLIT, VALIDATION_SPLIT}
        or type(scope_document) is not dict
        or set(scope_document) != expected_scope_fields
    ):
        raise NonAshSelectorArtifactV2Error(f"{label} envelope differs")
    _require_exact_authority_bindings_v2(document)
    try:
        scope = NonAshSelectorEvaluationScopeV2(
            shared_bank_configuration_sha256=scope_document.get(
                "shared_bank_configuration_sha256"
            ),
            degradation_policy_sha256=scope_document.get(
                "degradation_policy_sha256"
            ),
            calibration_plan_file_sha256=scope_document.get(
                "calibration_plan_file_sha256"
            ),
            cached_16_operator_output_manifest_sha256=scope_document.get(
                "cached_16_operator_output_manifest_sha256"
            ),
        )
        reopened = NonAshSelectorEvaluationV2(
            split=document.get("split"),
            scope=_snapshot_evaluation_scope(scope),
            rule_sha256=document.get("rule_sha256"),
            evaluation_sha256=digest,
            objective_summary_sha256=document.get("objective_summary_sha256"),
            output_manifest_sha256=document.get("output_manifest_sha256"),
            objective_means=_objective_tuple(
                document.get("engine_raw_corpus_mean_tuple"),
                label=f"{label} objective",
            ),
        )
        if (
            canonical_evaluation_evidence_bytes_v2(
                selector_id=selector_id,
                split=reopened.split,
                evaluation_scope=reopened.scope,
                rule_sha256=reopened.rule_sha256,
                objective_summary_sha256=reopened.objective_summary_sha256,
                output_manifest_sha256=reopened.output_manifest_sha256,
                objective_means=reopened.objective_means,
            )
            != payload
        ):
            raise NonAshSelectorArtifactV2Error(f"{label} envelope differs")
    except NonAshSelectorArtifactV2Error:
        raise
    except Exception as error:
        raise NonAshSelectorArtifactV2Error(
            f"{label} semantics are invalid"
        ) from error
    if reopened != expected:
        raise NonAshSelectorArtifactV2Error(
            f"{label} reopening differs from its recorded result"
        )
    return reopened


class _MemoizedFailureArtifactReopenerV2:
    """Detach and reuse the first full document returned for each digest."""

    def __init__(self, source: FailureArtifactReopenerV2) -> None:
        self._source = source
        self._cache: Dict[str, Dict[str, object]] = {}

    def __call__(self, digest: str) -> Mapping[str, object]:
        if digest not in self._cache:
            value = self._source(digest)
            self._cache[digest] = _snapshot_json_object(
                value,
                label="typed failure callback result",
            )
        return self._cache[digest]


class _MemoizedImmutableContentReopenerV2:
    """Reuse the first immutable byte result returned for each digest."""

    def __init__(self, source: ImmutableContentReopenerV2) -> None:
        self._source = source
        self._cache: Dict[str, object] = {}

    def __call__(self, digest: str) -> bytes:
        if digest not in self._cache:
            value = self._source(digest)
            self._cache[digest] = bytes(value) if type(value) is bytes else value
        return self._cache[digest]  # type: ignore[return-value]


def _memoized_failure_reopener(
    reopener: Optional[FailureArtifactReopenerV2],
) -> Optional[FailureArtifactReopenerV2]:
    if reopener is None or isinstance(
        reopener,
        _MemoizedFailureArtifactReopenerV2,
    ):
        return reopener
    if not callable(reopener):
        return reopener
    return _MemoizedFailureArtifactReopenerV2(reopener)


def _memoized_immutable_reopener(
    reopener: Optional[ImmutableContentReopenerV2],
) -> Optional[ImmutableContentReopenerV2]:
    if reopener is None or isinstance(
        reopener,
        _MemoizedImmutableContentReopenerV2,
    ):
        return reopener
    if not callable(reopener):
        return reopener
    return _MemoizedImmutableContentReopenerV2(reopener)


def _verify_immutable_content_reference(
    digest: object,
    reopener: Optional[ImmutableContentReopenerV2],
    *,
    label: str,
) -> bytes:
    if not _is_sha256(digest):
        raise NonAshSelectorArtifactV2Error(f"{label} digest is invalid")
    if reopener is None or not callable(reopener):
        raise NonAshSelectorArtifactV2Error(f"{label} byte reopener is required")
    try:
        value = reopener(digest)
    except Exception as error:
        raise NonAshSelectorArtifactV2Error(f"{label} could not be reopened") from error
    if type(value) is not bytes:
        raise NonAshSelectorArtifactV2Error(f"{label} reopener returned non-bytes")
    payload = bytes(value)
    if not payload or _sha256(payload) != digest:
        raise NonAshSelectorArtifactV2Error(f"{label} content address differs")
    return payload


def _verify_failure_reference(
    *,
    content_sha256: str,
    expected_split: str,
    expected_ordinal: int,
    expected_rule_sha256: str,
    expected_values: Tuple[int, ...],
    expected_failure_type: str,
    profile: NonAshSelectorExecutionProfileV2,
    evaluation_scope: NonAshSelectorEvaluationScopeV2,
    failure_reopener: Optional[FailureArtifactReopenerV2],
    evidence_binding_reopener: Optional[EvidenceBindingReopenerV2],
) -> None:
    if failure_reopener is None or not callable(failure_reopener):
        raise NonAshSelectorArtifactV2Error(
            "typed failure content reopener is required"
        )
    try:
        reopened = failure_reopener(content_sha256)
    except Exception as error:
        raise NonAshSelectorArtifactV2Error(
            "typed failure content could not be reopened"
        ) from error
    failure = _full_content_document(
        reopened,
        content_sha256,
        label="typed failure",
    )
    verify_attempt_failure_v2(
        failure,
        profile,
        evaluation_scope,
        evidence_binding_reopener=evidence_binding_reopener,
    )
    if (
        failure.get("split") != expected_split
        or failure.get("attempt_ordinal") != expected_ordinal
        or failure.get("rule_sha256") != expected_rule_sha256
        or _rule_values(failure.get("canonical_rule_values"), profile)
        != expected_values
        or failure.get("failure_type") != expected_failure_type
    ):
        raise NonAshSelectorArtifactV2Error(
            "typed failure content differs from its attempt"
        )


def verify_attempt_failure_v2(
    document: Mapping[str, object],
    profile: NonAshSelectorExecutionProfileV2,
    evaluation_scope: NonAshSelectorEvaluationScopeV2,
    *,
    evidence_binding_reopener: Optional[EvidenceBindingReopenerV2] = None,
) -> Mapping[str, object]:
    """Verify one typed failure, including every declared byte binding."""

    profile, evaluation_scope = _snapshot_execution_context(
        profile,
        evaluation_scope,
    )
    document = _snapshot_json_object(document, label="attempt failure")
    _validate_schema_and_common_scope(document, profile, evaluation_scope)
    if document.get("artifact_kind") != ATTEMPT_FAILURE_KIND:
        raise NonAshSelectorArtifactV2Error("artifact is not an attempt failure")
    values = _rule_values(document.get("canonical_rule_values"), profile)
    if document.get("rule_sha256") != rule_sha256_v2(values, profile):
        raise NonAshSelectorArtifactV2Error("failure rule hash differs")
    bindings = document.get("evidence_bindings")
    if type(bindings) is not list:
        raise NonAshSelectorArtifactV2Error("failure evidence bindings are invalid")
    identities = []
    paths = []
    portable_paths = []
    for binding in bindings:
        if type(binding) is not dict:
            raise NonAshSelectorArtifactV2Error("failure evidence binding is invalid")
        identifier = binding.get("id")
        path = binding.get("path")
        if (
            type(identifier) is not str
            or not identifier
            or type(path) is not str
            or _SAFE_RELATIVE_PATH.fullmatch(path) is None
            or path.endswith("/")
            or path != unicodedata.normalize("NFC", path)
            or any(
                unicodedata.category(character) in {"Cc", "Cf"}
                for character in path
            )
            or any(segment.endswith((" ", ".")) for segment in path.split("/"))
        ):
            raise NonAshSelectorArtifactV2Error("failure evidence path is unsafe")
        identities.append(identifier)
        paths.append(path)
        portable_paths.append(unicodedata.normalize("NFC", path).casefold())
        if evidence_binding_reopener is None or not callable(evidence_binding_reopener):
            raise NonAshSelectorArtifactV2Error(
                "failure evidence byte reopener is required"
            )
        try:
            payload = evidence_binding_reopener(dict(binding))
        except Exception as error:
            raise NonAshSelectorArtifactV2Error(
                "failure evidence binding could not be reopened"
            ) from error
        if (
            type(payload) is not bytes
            or len(payload) != binding.get("size_bytes")
            or _sha256(payload) != binding.get("sha256")
        ):
            raise NonAshSelectorArtifactV2Error(
                "failure evidence binding bytes differ"
            )
    if (
        len(identities) != len(set(identities))
        or len(paths) != len(set(paths))
        or len(portable_paths) != len(set(portable_paths))
    ):
        raise NonAshSelectorArtifactV2Error("failure evidence bindings repeat")
    return document


def verify_development_ledger_v2(
    document: Mapping[str, object],
    profile: NonAshSelectorExecutionProfileV2,
    evaluation_scope: NonAshSelectorEvaluationScopeV2,
    *,
    development_evidence_reopener: DevelopmentEvidenceReopenerV2,
    failure_reopener: Optional[FailureArtifactReopenerV2] = None,
    evidence_binding_reopener: Optional[EvidenceBindingReopenerV2] = None,
    immutable_content_reopener: Optional[ImmutableContentReopenerV2] = None,
):
    """Schema-check and replay the complete development schedule and chain."""

    profile, evaluation_scope = _snapshot_execution_context(
        profile,
        evaluation_scope,
    )
    failure_reopener = _memoized_failure_reopener(failure_reopener)
    immutable_content_reopener = _memoized_immutable_reopener(
        immutable_content_reopener
    )
    document = _snapshot_json_object(document, label="development ledger")
    _validate_schema_and_common_scope(document, profile, evaluation_scope)
    if document.get("artifact_kind") != ATTEMPT_LEDGER_KIND:
        raise NonAshSelectorArtifactV2Error("artifact is not a development ledger")
    if not callable(development_evidence_reopener):
        raise NonAshSelectorArtifactV2Error(
            "development evidence reopener is required"
        )
    try:
        records = _attempt_records_from_ledger(
            document,
            profile,
            evaluation_scope,
        )
        reopened_by_digest: Dict[str, NonAshSelectorEvaluationV2] = {}
        for record in records:
            if type(record.outcome) is not NonAshSelectorEvaluationV2:
                continue
            detached = _reopen_evaluation_evidence_v2(
                record.outcome.evaluation_sha256,
                development_evidence_reopener,
                expected=record.outcome,
                selector_id=profile.selector_id,
                label="development evaluation",
            )
            prior = reopened_by_digest.get(record.outcome.evaluation_sha256)
            if prior is not None and prior != detached:
                raise NonAshSelectorArtifactV2Error(
                    "one development content address identifies different evidence"
                )
            reopened_by_digest[record.outcome.evaluation_sha256] = detached
        result = replay_non_ash_development_search_v2(
            profile,
            evaluation_scope,
            records,
        )
    except NonAshSelectorArtifactV2Error:
        raise
    except Exception as error:
        raise NonAshSelectorArtifactV2Error(
            "development ledger semantic replay failed"
        ) from error
    cache_hits = sum(1 for record in records if record.cache_hit)
    if (
        document.get("attempt_count") != len(records)
        or document.get("unique_evaluation_count") != result.unique_evaluation_count
        or document.get("cache_hit_count") != cache_hits
        or document.get("first_attempt_ordinal") != 0
        or document.get("last_attempt_ordinal") != len(records) - 1
        or document.get("last_record_sha256") != result.last_record_sha256
        or document.get("completed_sweep_count") != result.completed_sweeps
        or document.get("terminal_status") != result.status
    ):
        raise NonAshSelectorArtifactV2Error("development ledger summary differs")
    reason_by_status = {
        DEVELOPMENT_STATUS_CONVERGED: "unchanged_complete_sweep",
        DEVELOPMENT_STATUS_MAXIMUM_SWEEPS_EXHAUSTED: "maximum_sweeps_exhausted",
        DEVELOPMENT_STATUS_ABORTED: "attempt_failure_abort",
    }
    if document.get("termination_reason") != reason_by_status[result.status]:
        raise NonAshSelectorArtifactV2Error("development termination reason differs")
    for record in records:
        if type(record.outcome) is NonAshSelectorEvaluationFailureV2:
            _verify_failure_reference(
                content_sha256=record.outcome.attempt_failure_sha256,
                expected_split=DEVELOPMENT_SPLIT,
                expected_ordinal=record.attempt_ordinal,
                expected_rule_sha256=record.rule_sha256,
                expected_values=record.canonical_rule_values,
                expected_failure_type=record.outcome.failure_type,
                profile=profile,
                evaluation_scope=evaluation_scope,
                failure_reopener=failure_reopener,
                evidence_binding_reopener=evidence_binding_reopener,
            )
    if result.status == DEVELOPMENT_STATUS_CONVERGED:
        terminal = result.incumbent_evaluation
        if (
            result.terminal_rule_values is None
            or result.terminal_rule_sha256 is None
            or terminal is None
        ):
            raise NonAshSelectorArtifactV2Error("converged ledger lacks a terminal")
        provenance = [
            record
            for record in records
            if not record.cache_hit
            and type(record.outcome) is NonAshSelectorEvaluationV2
            and record.rule_sha256 == result.terminal_rule_sha256
            and record.outcome == terminal
        ]
        if not provenance:
            raise NonAshSelectorArtifactV2Error(
                "terminal development evidence has no fresh provenance"
            )
        if (
            document.get("terminal_attempt_ordinal")
            != provenance[0].attempt_ordinal
            or document.get("terminal_rule_sha256")
            != result.terminal_rule_sha256
            or _rule_values(document.get("terminal_rule_values"), profile)
            != result.terminal_rule_values
            or document.get("terminal_objective_summary_sha256")
            != terminal.objective_summary_sha256
            or _objective_tuple(
                document.get("terminal_engine_raw_corpus_mean_tuple"),
                label="terminal objective",
            )
            != terminal.objective_means
        ):
            raise NonAshSelectorArtifactV2Error(
                "development terminal provenance differs"
            )
    elif result.status == DEVELOPMENT_STATUS_ABORTED:
        if (
            not records
            or type(records[-1].outcome) is not NonAshSelectorEvaluationFailureV2
            or document.get("terminal_failure_sha256")
            != records[-1].outcome.attempt_failure_sha256
        ):
            raise NonAshSelectorArtifactV2Error("aborted ledger failure differs")
    elif result.status == DEVELOPMENT_STATUS_MAXIMUM_SWEEPS_EXHAUSTED:
        _verify_immutable_content_reference(
            document.get("terminal_failure_sha256"),
            immutable_content_reopener,
            label="maximum-sweeps terminal failure",
        )
    return result


def verify_development_selection_v2(
    document: Mapping[str, object],
    profile: NonAshSelectorExecutionProfileV2,
    evaluation_scope: NonAshSelectorEvaluationScopeV2,
    *,
    development_ledger: Mapping[str, object],
    development_evidence_reopener: DevelopmentEvidenceReopenerV2,
) -> Mapping[str, object]:
    """Verify the provisional selection against one converged ledger."""

    profile, evaluation_scope = _snapshot_execution_context(
        profile,
        evaluation_scope,
    )
    document = _snapshot_json_object(document, label="development selection")
    development_ledger = _snapshot_json_object(
        development_ledger,
        label="development selection ledger",
    )
    _validate_schema_and_common_scope(document, profile, evaluation_scope)
    if (
        document.get("artifact_kind") != SELECTION_KIND
        or document.get("selection_stage") != "development_provisional"
    ):
        raise NonAshSelectorArtifactV2Error(
            "artifact is not a development provisional selection"
        )
    result = verify_development_ledger_v2(
        development_ledger,
        profile,
        evaluation_scope,
        development_evidence_reopener=development_evidence_reopener,
    )
    if (
        result.status != DEVELOPMENT_STATUS_CONVERGED
        or result.incumbent_evaluation is None
        or result.terminal_rule_values is None
        or result.terminal_rule_sha256 is None
    ):
        raise NonAshSelectorArtifactV2Error(
            "development selection requires a converged ledger"
        )
    if (
        document.get("development_attempt_count") != result.attempt_count
        or document.get("development_last_attempt_ordinal")
        != result.attempt_count - 1
        or document.get("development_attempt_ledger_sha256")
        != development_ledger.get("ledger_sha256")
        or document.get("development_attempt_ledger_tip_sha256")
        != result.last_record_sha256
        or document.get("development_terminal_attempt_ordinal")
        != development_ledger.get("terminal_attempt_ordinal")
        or document.get("development_terminal_rule_sha256")
        != result.terminal_rule_sha256
        or _rule_values(document.get("development_terminal_rule_values"), profile)
        != result.terminal_rule_values
        or document.get("development_objective_summary_sha256")
        != result.incumbent_evaluation.objective_summary_sha256
        or _objective_tuple(
            document.get("development_engine_raw_corpus_mean_tuple"),
            label="development selection objective",
        )
        != result.incumbent_evaluation.objective_means
    ):
        raise NonAshSelectorArtifactV2Error(
            "development selection does not bind its terminal ledger"
        )
    return document


def _neighbor_entry_sha256(entry: Mapping[str, object]) -> str:
    if type(entry) is not dict or "neighbor_entry_sha256" not in entry:
        raise NonAshSelectorArtifactV2Error("neighbor entry self-hash is absent")
    unhashed = dict(entry)
    unhashed.pop("neighbor_entry_sha256")
    return _sha256(canonical_artifact_bytes_v2(unhashed))


def verify_validation_neighbor_manifest_v2(
    document: Mapping[str, object],
    profile: NonAshSelectorExecutionProfileV2,
    evaluation_scope: NonAshSelectorEvaluationScopeV2,
    *,
    development_ledger: Mapping[str, object],
    development_selection: Mapping[str, object],
    development_evidence_reopener: DevelopmentEvidenceReopenerV2,
    immutable_content_reopener: ImmutableContentReopenerV2,
) -> Mapping[str, object]:
    """Prove terminal provenance and exact development-backed 163 neighbors."""

    profile, evaluation_scope = _snapshot_execution_context(
        profile,
        evaluation_scope,
    )
    immutable_content_reopener = _memoized_immutable_reopener(
        immutable_content_reopener
    )
    document = _snapshot_json_object(document, label="validation neighbor manifest")
    development_ledger = _snapshot_json_object(
        development_ledger,
        label="neighbor development ledger",
    )
    development_selection = _snapshot_json_object(
        development_selection,
        label="neighbor development selection",
    )
    _validate_schema_and_common_scope(document, profile, evaluation_scope)
    if document.get("artifact_kind") != NEIGHBOR_MANIFEST_KIND:
        raise NonAshSelectorArtifactV2Error("artifact is not a neighbor manifest")
    result = verify_development_ledger_v2(
        development_ledger,
        profile,
        evaluation_scope,
        development_evidence_reopener=development_evidence_reopener,
    )
    verify_development_selection_v2(
        development_selection,
        profile,
        evaluation_scope,
        development_ledger=development_ledger,
        development_evidence_reopener=development_evidence_reopener,
    )
    if (
        result.status != DEVELOPMENT_STATUS_CONVERGED
        or result.terminal_rule_values is None
        or result.terminal_rule_sha256 is None
        or result.last_record_sha256 is None
        or not callable(development_evidence_reopener)
    ):
        raise NonAshSelectorArtifactV2Error(
            "neighbor manifest requires reopened converged development evidence"
        )
    if (
        document.get("development_attempt_count") != result.attempt_count
        or document.get("development_last_attempt_ordinal")
        != result.attempt_count - 1
        or document.get("development_attempt_ledger_sha256")
        != development_ledger.get("ledger_sha256")
        or document.get("development_attempt_ledger_tip_sha256")
        != result.last_record_sha256
        or document.get("development_selection_sha256")
        != development_selection.get("development_selection_sha256")
        or document.get("terminal_rule_sha256") != result.terminal_rule_sha256
        or _rule_values(document.get("terminal_rule_values"), profile)
        != result.terminal_rule_values
    ):
        raise NonAshSelectorArtifactV2Error(
            "neighbor manifest development linkage differs"
        )
    records = _attempt_records_from_ledger(
        development_ledger,
        profile,
        evaluation_scope,
    )
    expected_by_evaluation: Dict[str, NonAshSelectorEvaluationV2] = {}
    latest_by_rule: Dict[str, NonAshSelectorEvaluationV2] = {}
    for record in records:
        if type(record.outcome) is not NonAshSelectorEvaluationV2:
            raise NonAshSelectorArtifactV2Error(
                "converged ledger contains a failed outcome"
            )
        prior = expected_by_evaluation.get(record.outcome.evaluation_sha256)
        if prior is not None and prior != record.outcome:
            raise NonAshSelectorArtifactV2Error(
                "one development content address identifies different evidence"
            )
        expected_by_evaluation[record.outcome.evaluation_sha256] = record.outcome
        latest_by_rule[record.rule_sha256] = record.outcome
    for digest, expected in expected_by_evaluation.items():
        _reopen_evaluation_evidence_v2(
            digest,
            development_evidence_reopener,
            expected=expected,
            selector_id=profile.selector_id,
            label="development evaluation",
        )
    expected_candidates = non_ash_validation_neighborhood_v2(
        profile,
        rule_mapping_v2(result.terminal_rule_values, profile),
    )
    candidates = document.get("candidates")
    if type(candidates) is not list or len(candidates) != len(expected_candidates):
        raise NonAshSelectorArtifactV2Error("neighbor candidate count differs")
    for expected, actual in zip(expected_candidates, candidates):
        if type(actual) is not dict:
            raise NonAshSelectorArtifactV2Error("neighbor entry is not an object")
        evidence = latest_by_rule.get(expected.rule_sha256)
        if evidence is None:
            raise NonAshSelectorArtifactV2Error(
                "development trace does not cover one validation neighbor"
            )
        common_matches = (
            actual.get("validation_candidate_ordinal") == expected.candidate_ordinal
            and actual.get("rule_sha256") == expected.rule_sha256
            and _rule_values(actual.get("canonical_rule_values"), profile)
            == expected.canonical_rule_values
            and actual.get("development_evidence_sha256")
            == evidence.evaluation_sha256
            and actual.get("neighbor_entry_sha256")
            == _neighbor_entry_sha256(actual)
        )
        if expected.terminal:
            exact_matches = actual.get("candidate_kind") == "terminal"
        else:
            exact_matches = (
                actual.get("candidate_kind") == "one_coordinate_neighbor"
                and actual.get("coordinate_ordinal") == expected.coordinate_ordinal
                and actual.get("coordinate_name") == expected.coordinate_name
                and actual.get("terminal_value") == expected.from_value
                and actual.get("replacement_value") == expected.to_value
            )
        if not common_matches or not exact_matches:
            raise NonAshSelectorArtifactV2Error("neighbor entry semantics differ")
    expected_rule_hashes = [candidate.rule_sha256 for candidate in expected_candidates]
    if document.get("candidate_rule_sha256_values") != expected_rule_hashes:
        raise NonAshSelectorArtifactV2Error("neighbor rule-hash order differs")
    _verify_immutable_content_reference(
        document.get("development_candidate_evidence_manifest_sha256"),
        immutable_content_reopener,
        label="development candidate-evidence manifest",
    )
    return document


def _validation_selection_key(
    values: Tuple[int, ...],
    objective: Tuple[object, ...],
    profile: NonAshSelectorExecutionProfileV2,
) -> Tuple[object, ...]:
    return tuple(-value for value in objective) + (
        canonical_artifact_bytes_v2(rule_mapping_v2(values, profile)),
    )


def verify_validation_selection_v2(
    document: Mapping[str, object],
    profile: NonAshSelectorExecutionProfileV2,
    evaluation_scope: NonAshSelectorEvaluationScopeV2,
    *,
    development_ledger: Mapping[str, object],
    development_selection: Mapping[str, object],
    validation_neighbor_manifest: Mapping[str, object],
    development_evidence_reopener: DevelopmentEvidenceReopenerV2,
    validation_evidence_reopener: Optional[ValidationEvidenceReopenerV2] = None,
    failure_reopener: Optional[FailureArtifactReopenerV2] = None,
    evidence_binding_reopener: Optional[EvidenceBindingReopenerV2] = None,
    immutable_content_reopener: Optional[ImmutableContentReopenerV2] = None,
) -> Mapping[str, object]:
    """Verify exact validation coverage, typed failures, and final tie-break."""

    profile, evaluation_scope = _snapshot_execution_context(
        profile,
        evaluation_scope,
    )
    failure_reopener = _memoized_failure_reopener(failure_reopener)
    immutable_content_reopener = _memoized_immutable_reopener(
        immutable_content_reopener
    )
    document = _snapshot_json_object(document, label="validation selection")
    development_ledger = _snapshot_json_object(
        development_ledger,
        label="validation predecessor development ledger",
    )
    development_selection = _snapshot_json_object(
        development_selection,
        label="validation predecessor development selection",
    )
    validation_neighbor_manifest = _snapshot_json_object(
        validation_neighbor_manifest,
        label="validation predecessor neighbor manifest",
    )
    _validate_schema_and_common_scope(document, profile, evaluation_scope)
    if (
        document.get("artifact_kind") != SELECTION_KIND
        or document.get("selection_stage") != "validation_final"
    ):
        raise NonAshSelectorArtifactV2Error(
            "artifact is not a final validation selection"
        )
    verify_validation_neighbor_manifest_v2(
        validation_neighbor_manifest,
        profile,
        evaluation_scope,
        development_ledger=development_ledger,
        development_selection=development_selection,
        development_evidence_reopener=development_evidence_reopener,
        immutable_content_reopener=immutable_content_reopener,
    )
    _validate_schema_and_common_scope(
        development_selection,
        profile,
        evaluation_scope,
    )
    _validate_schema_and_common_scope(
        validation_neighbor_manifest,
        profile,
        evaluation_scope,
    )
    if (
        development_selection.get("selection_stage")
        != "development_provisional"
        or validation_neighbor_manifest.get("artifact_kind")
        != NEIGHBOR_MANIFEST_KIND
        or document.get("development_selection_sha256")
        != development_selection.get("development_selection_sha256")
        or document.get("development_terminal_rule_sha256")
        != development_selection.get("development_terminal_rule_sha256")
        or document.get("validation_neighbor_manifest_sha256")
        != validation_neighbor_manifest.get("manifest_sha256")
    ):
        raise NonAshSelectorArtifactV2Error(
            "validation selection predecessor linkage differs"
        )
    candidates = validation_neighbor_manifest.get("candidates")
    results = document.get("validation_results")
    if type(candidates) is not list or type(results) is not list or len(results) != 163:
        raise NonAshSelectorArtifactV2Error("validation coverage is incomplete")
    development_evaluation_sha256_values = {
        record.outcome.evaluation_sha256
        for record in _attempt_records_from_ledger(
            development_ledger,
            profile,
            evaluation_scope,
        )
        if type(record.outcome) is NonAshSelectorEvaluationV2
    }
    reopened_validation_by_digest: Dict[str, NonAshSelectorEvaluationV2] = {}
    successful = []
    for candidate, row in zip(candidates, results):
        if type(candidate) is not dict or type(row) is not dict:
            raise NonAshSelectorArtifactV2Error("validation row is invalid")
        ordinal = candidate.get("validation_candidate_ordinal")
        values = _rule_values(candidate.get("canonical_rule_values"), profile)
        if (
            row.get("validation_candidate_ordinal") != ordinal
            or row.get("neighbor_entry_sha256")
            != candidate.get("neighbor_entry_sha256")
            or row.get("rule_sha256") != candidate.get("rule_sha256")
        ):
            raise NonAshSelectorArtifactV2Error(
                "validation result does not bind its neighbor"
            )
        outcome = row.get("outcome")
        if type(outcome) is not dict:
            raise NonAshSelectorArtifactV2Error("validation outcome is invalid")
        if outcome.get("outcome_type") == "scored":
            objective = _objective_tuple(
                outcome.get("engine_raw_corpus_mean_tuple"),
                label="validation objective",
            )
            if validation_evidence_reopener is None or not callable(
                validation_evidence_reopener
            ):
                raise NonAshSelectorArtifactV2Error(
                    "validation evidence reopener is required"
                )
            evaluation_sha256 = outcome.get("evaluation_sha256")
            if evaluation_sha256 in development_evaluation_sha256_values:
                raise NonAshSelectorArtifactV2Error(
                    "validation evaluation content address overlaps development"
                )
            reopened = reopened_validation_by_digest.get(evaluation_sha256)
            expected_evaluation = NonAshSelectorEvaluationV2(
                split=VALIDATION_SPLIT,
                scope=evaluation_scope,
                rule_sha256=candidate.get("rule_sha256"),
                evaluation_sha256=evaluation_sha256,
                objective_summary_sha256=outcome.get("objective_summary_sha256"),
                output_manifest_sha256=outcome.get("output_manifest_sha256"),
                objective_means=objective,
            )
            if reopened is None:
                reopened = _reopen_evaluation_evidence_v2(
                    evaluation_sha256,
                    validation_evidence_reopener,
                    expected=expected_evaluation,
                    selector_id=profile.selector_id,
                    label="validation evaluation",
                )
                reopened_validation_by_digest[evaluation_sha256] = reopened
            if reopened != expected_evaluation:
                raise NonAshSelectorArtifactV2Error(
                    "validation evidence reopening differs from its result"
                )
            successful.append((values, candidate, outcome, objective))
        elif outcome.get("outcome_type") == "failed":
            _verify_failure_reference(
                content_sha256=outcome.get("attempt_failure_sha256"),
                expected_split=VALIDATION_SPLIT,
                expected_ordinal=ordinal,
                expected_rule_sha256=candidate.get("rule_sha256"),
                expected_values=values,
                expected_failure_type=outcome.get("failure_type"),
                profile=profile,
                evaluation_scope=evaluation_scope,
                failure_reopener=failure_reopener,
                evidence_binding_reopener=evidence_binding_reopener,
            )
        else:
            raise NonAshSelectorArtifactV2Error("validation outcome type differs")
    status = document.get("validation_status")
    if status == "selected":
        if not successful:
            raise NonAshSelectorArtifactV2Error("selected validation has no score")
        values, candidate, outcome, _ = min(
            successful,
            key=lambda item: _validation_selection_key(
                item[0],
                item[3],
                profile,
            ),
        )
        if (
            document.get("selected_control_rule_sha256")
            != candidate.get("rule_sha256")
            or _rule_values(document.get("selected_control_rule_values"), profile)
            != values
            or document.get("validation_objective_summary_sha256")
            != outcome.get("objective_summary_sha256")
        ):
            raise NonAshSelectorArtifactV2Error(
                "validation selected rule or objective differs"
            )
    elif status == "failed_all_candidates":
        if successful:
            raise NonAshSelectorArtifactV2Error(
                "failed-all validation contains a successful score"
            )
        _verify_immutable_content_reference(
            document.get("validation_terminal_failure_sha256"),
            immutable_content_reopener,
            label="failed-all validation terminal failure",
        )
    else:
        raise NonAshSelectorArtifactV2Error("validation status differs")
    return document


@dataclass(frozen=True)
class ArtifactReferenceV2:
    """Exact full-byte content address and authenticated schema identity."""

    artifact_kind: str
    sha256: str
    size_bytes: int
    schema_sha256: str

    def __post_init__(self) -> None:
        if (
            type(self.artifact_kind) is not str
            or self.artifact_kind not in _SCHEMA_SPECS
            or not _is_sha256(self.sha256)
            or type(self.size_bytes) is not int
            or self.size_bytes < 1
            or not _is_sha256(self.schema_sha256)
            or self.schema_sha256 != _SCHEMA_SPECS[self.artifact_kind][1]
        ):
            raise NonAshSelectorArtifactV2Error("artifact reference is invalid")


_REFERENCE_DEPENDENCIES = {
    "development_ledger_reference": "development_ledger",
    "development_selection_reference": "development_selection",
    "validation_neighbor_manifest_reference": "validation_neighbor_manifest",
}
_CALLBACK_DEPENDENCY_NAMES = {
    "development_evidence_reopener",
    "validation_evidence_reopener",
    "failure_reopener",
    "evidence_binding_reopener",
    "immutable_content_reopener",
}


class NonAshSelectorArtifactStoreV2:
    """Atomic content-addressed store with mandatory semantic reopening."""

    def __init__(self, root: Path) -> None:
        try:
            self._store = ContentAddressedEvidenceStore(root)
        except Exception as error:
            raise NonAshSelectorArtifactV2Error(
                "content-addressed store root is unsafe"
            ) from error

    def reopen_content_address(self, sha256: str) -> Mapping[str, object]:
        """Reopen exact canonical bytes for use by semantic dependency checks."""

        if not _is_sha256(sha256):
            raise NonAshSelectorArtifactV2Error("content address is invalid")
        try:
            document = self._store.reopen(sha256)
        except Exception as error:
            raise NonAshSelectorArtifactV2Error(
                "content-addressed artifact could not be reopened"
            ) from error
        return _full_content_document(
            document,
            sha256,
            label="content-addressed artifact",
        )

    def _reopen_reference_dependency(
        self,
        reference: object,
        *,
        label: str,
    ) -> Mapping[str, object]:
        if type(reference) is not ArtifactReferenceV2:
            raise NonAshSelectorArtifactV2Error(
                f"{label} reference type differs"
            )
        document = self.reopen_content_address(reference.sha256)
        payload = canonical_artifact_bytes_v2(document)
        if (
            document.get("artifact_kind") != reference.artifact_kind
            or len(payload) != reference.size_bytes
            or _SCHEMA_SPECS[reference.artifact_kind][1]
            != reference.schema_sha256
        ):
            raise NonAshSelectorArtifactV2Error(f"{label} reference differs")
        return document

    def _materialize_store_dependencies(
        self,
        dependencies: Mapping[str, object],
    ) -> Tuple[
        Dict[str, object],
        Tuple[Tuple[str, ArtifactReferenceV2, bytes], ...],
    ]:
        if type(dependencies) is not dict:
            raise NonAshSelectorArtifactV2Error("semantic dependencies are invalid")
        allowed = set(_REFERENCE_DEPENDENCIES) | _CALLBACK_DEPENDENCY_NAMES
        if set(dependencies) - allowed:
            raise NonAshSelectorArtifactV2Error(
                "store dependency field set contains an unknown or raw predecessor"
            )
        materialized: Dict[str, object] = {}
        reference_snapshots = []
        for name, value in dependencies.items():
            mapped_name = _REFERENCE_DEPENDENCIES.get(name)
            if mapped_name is not None:
                if type(value) is not ArtifactReferenceV2:
                    raise NonAshSelectorArtifactV2Error(
                        f"{mapped_name} reference type differs"
                    )
                reference = ArtifactReferenceV2(
                    artifact_kind=value.artifact_kind,
                    sha256=value.sha256,
                    size_bytes=value.size_bytes,
                    schema_sha256=value.schema_sha256,
                )
                document = self._reopen_reference_dependency(
                    reference,
                    label=mapped_name,
                )
                materialized[mapped_name] = document
                reference_snapshots.append(
                    (
                        mapped_name,
                        reference,
                        canonical_artifact_bytes_v2(document),
                    )
                )
            else:
                if value is not None and not callable(value):
                    raise NonAshSelectorArtifactV2Error(
                        f"store dependency {name} is not callable"
                    )
                materialized[name] = value
        return materialized, tuple(reference_snapshots)

    def _revalidate_store_dependencies(
        self,
        reference_snapshots: Sequence[
            Tuple[str, ArtifactReferenceV2, bytes]
        ],
    ) -> None:
        """Raw-reopen every predecessor after callbacks and compare frozen bytes."""

        for label, reference, expected_payload in reference_snapshots:
            try:
                reopened = self._reopen_reference_dependency(
                    reference,
                    label=label,
                )
            except Exception as error:
                raise NonAshSelectorArtifactV2Error(
                    f"{label} predecessor changed during post-callback reopening"
                ) from error
            if canonical_artifact_bytes_v2(reopened) != expected_payload:
                raise NonAshSelectorArtifactV2Error(
                    f"{label} predecessor changed during post-callback reopening"
                )

    @staticmethod
    def _verify(
        document: Mapping[str, object],
        profile: NonAshSelectorExecutionProfileV2,
        evaluation_scope: NonAshSelectorEvaluationScopeV2,
        *,
        development_ledger: Optional[Mapping[str, object]] = None,
        development_selection: Optional[Mapping[str, object]] = None,
        validation_neighbor_manifest: Optional[Mapping[str, object]] = None,
        development_evidence_reopener: Optional[
            DevelopmentEvidenceReopenerV2
        ] = None,
        validation_evidence_reopener: Optional[
            ValidationEvidenceReopenerV2
        ] = None,
        failure_reopener: Optional[FailureArtifactReopenerV2] = None,
        evidence_binding_reopener: Optional[EvidenceBindingReopenerV2] = None,
        immutable_content_reopener: Optional[ImmutableContentReopenerV2] = None,
    ) -> None:
        kind = document.get("artifact_kind")
        if kind == ATTEMPT_FAILURE_KIND:
            verify_attempt_failure_v2(
                document,
                profile,
                evaluation_scope,
                evidence_binding_reopener=evidence_binding_reopener,
            )
        elif kind == ATTEMPT_LEDGER_KIND:
            if development_evidence_reopener is None:
                raise NonAshSelectorArtifactV2Error(
                    "development evidence reopener is required"
                )
            verify_development_ledger_v2(
                document,
                profile,
                evaluation_scope,
                development_evidence_reopener=development_evidence_reopener,
                failure_reopener=failure_reopener,
                evidence_binding_reopener=evidence_binding_reopener,
                immutable_content_reopener=immutable_content_reopener,
            )
        elif kind == SELECTION_KIND and document.get("selection_stage") == (
            "development_provisional"
        ):
            if development_ledger is None or development_evidence_reopener is None:
                raise NonAshSelectorArtifactV2Error(
                    "development selection dependencies are required"
                )
            verify_development_selection_v2(
                document,
                profile,
                evaluation_scope,
                development_ledger=development_ledger,
                development_evidence_reopener=development_evidence_reopener,
            )
        elif kind == NEIGHBOR_MANIFEST_KIND:
            if (
                development_ledger is None
                or development_selection is None
                or development_evidence_reopener is None
            ):
                raise NonAshSelectorArtifactV2Error(
                    "neighbor semantic dependencies are required"
                )
            verify_validation_neighbor_manifest_v2(
                document,
                profile,
                evaluation_scope,
                development_ledger=development_ledger,
                development_selection=development_selection,
                development_evidence_reopener=development_evidence_reopener,
                immutable_content_reopener=immutable_content_reopener,
            )
        elif kind == SELECTION_KIND and document.get("selection_stage") == (
            "validation_final"
        ):
            if (
                development_ledger is None
                or development_selection is None
                or validation_neighbor_manifest is None
                or development_evidence_reopener is None
            ):
                raise NonAshSelectorArtifactV2Error(
                    "validation selection dependencies are required"
                )
            verify_validation_selection_v2(
                document,
                profile,
                evaluation_scope,
                development_ledger=development_ledger,
                development_selection=development_selection,
                validation_neighbor_manifest=validation_neighbor_manifest,
                development_evidence_reopener=development_evidence_reopener,
                validation_evidence_reopener=validation_evidence_reopener,
                failure_reopener=failure_reopener,
                evidence_binding_reopener=evidence_binding_reopener,
                immutable_content_reopener=immutable_content_reopener,
            )
        else:
            raise NonAshSelectorArtifactV2Error("artifact semantic kind is invalid")

    def publish(
        self,
        document: Mapping[str, object],
        profile: NonAshSelectorExecutionProfileV2,
        evaluation_scope: NonAshSelectorEvaluationScopeV2,
        **dependencies: object,
    ) -> ArtifactReferenceV2:
        """Validate, atomically publish, reopen, and revalidate one artifact."""

        profile, evaluation_scope = _snapshot_execution_context(
            profile,
            evaluation_scope,
        )
        if type(document) is not dict:
            raise NonAshSelectorArtifactV2Error(
                "publication requires an exact built-in artifact object"
            )
        snapshot = _strict_json_snapshot(document, label="publication artifact")
        if type(snapshot) is not dict:
            raise AssertionError("publication artifact snapshot changed type")
        dependency_snapshot, reference_snapshots = (
            self._materialize_store_dependencies(dependencies)
        )
        self._verify(
            snapshot,
            profile,
            evaluation_scope,
            **dependency_snapshot,
        )
        payload = canonical_artifact_bytes_v2(snapshot)
        kind = snapshot["artifact_kind"]
        try:
            if kind == ATTEMPT_FAILURE_KIND:
                binding = self._store.preserve_failure(snapshot)
            else:
                binding = self._store.publish(snapshot)
        except Exception as error:
            raise NonAshSelectorArtifactV2Error(
                "atomic content-addressed publication failed"
            ) from error
        reference = ArtifactReferenceV2(
            artifact_kind=kind,
            sha256=binding.get("sha256"),
            size_bytes=binding.get("size_bytes"),
            schema_sha256=_SCHEMA_SPECS[kind][1],
        )
        if reference.sha256 != _sha256(payload) or reference.size_bytes != len(payload):
            raise NonAshSelectorArtifactV2Error("published artifact reference differs")
        reopened = self.reopen_content_address(reference.sha256)
        if (
            canonical_artifact_bytes_v2(reopened) != payload
            or reopened != snapshot
        ):
            raise NonAshSelectorArtifactV2Error(
                "published artifact changed during byte reopening"
            )
        self._revalidate_store_dependencies(reference_snapshots)
        return reference

    def reopen(
        self,
        reference: ArtifactReferenceV2,
        profile: NonAshSelectorExecutionProfileV2,
        evaluation_scope: NonAshSelectorEvaluationScopeV2,
        **dependencies: object,
    ) -> Mapping[str, object]:
        """Reopen by SHA/size/schema reference and replay all supplied semantics."""

        profile, evaluation_scope = _snapshot_execution_context(
            profile,
            evaluation_scope,
        )
        if type(reference) is not ArtifactReferenceV2:
            raise NonAshSelectorArtifactV2Error("artifact reference type differs")
        dependency_snapshot, reference_snapshots = (
            self._materialize_store_dependencies(dependencies)
        )
        document = self.reopen_content_address(reference.sha256)
        payload = canonical_artifact_bytes_v2(document)
        if (
            document.get("artifact_kind") != reference.artifact_kind
            or len(payload) != reference.size_bytes
            or _SCHEMA_SPECS[reference.artifact_kind][1]
            != reference.schema_sha256
        ):
            raise NonAshSelectorArtifactV2Error("reopened artifact reference differs")
        self._verify(
            document,
            profile,
            evaluation_scope,
            **dependency_snapshot,
        )
        self._revalidate_store_dependencies(reference_snapshots)
        return document


__all__ = [
    "ATTEMPT_FAILURE_KIND",
    "ATTEMPT_LEDGER_KIND",
    "ArtifactReferenceV2",
    "EVALUATION_EVIDENCE_KIND",
    "EVALUATION_EVIDENCE_SCHEMA_VERSION",
    "NEIGHBOR_MANIFEST_KIND",
    "NonAshSelectorArtifactStoreV2",
    "NonAshSelectorArtifactV2Error",
    "SELECTION_KIND",
    "canonical_artifact_bytes_v2",
    "canonical_evaluation_evidence_bytes_v2",
    "verify_attempt_failure_v2",
    "verify_development_ledger_v2",
    "verify_development_selection_v2",
    "verify_validation_neighbor_manifest_v2",
    "verify_validation_selection_v2",
]
