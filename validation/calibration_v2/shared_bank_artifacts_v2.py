"""Authenticated materialization and validation of P06 schema-2 bank artifacts."""

from __future__ import annotations

from collections.abc import Mapping, Sequence
from dataclasses import dataclass
import hashlib
import json
from pathlib import Path, PurePosixPath
from typing import Dict

import jsonschema

from validation.calibration_v2.calibration_plan_codec import (
    CalibrationPlanCodecError,
    ParsedCalibrationPlanV2,
    candidate_vector_sha256_v2,
    parse_calibration_plan_v2,
    shared_bank_configuration_sha256_v2,
    validate_candidate_constraints_v2,
    validate_materialized_candidate_identity_v2,
)
from validation.quality.src.mirmir_quality.json_tools import (
    canonical_json_bytes,
    manifest_sha256,
)


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
CONTRACT_RELATIVE_PATH = Path(
    "validation/calibration_v2/contracts/"
    "shared-bank-artifact-materialization-v2.json"
)
CONTRACT_SCHEMA_RELATIVE_PATH = Path(
    "validation/calibration_v2/schemas/"
    "shared-bank-artifact-materialization-v2.schema.json"
)
MAPPING_SCHEMA_RELATIVE_PATH = Path(
    "validation/calibration_v2/schemas/video-mapping-v2.schema.json"
)
OPERATOR_SCHEMA_RELATIVE_PATH = Path(
    "validation/calibration_v2/schemas/operator-bank-v2.schema.json"
)

EXPECTED_CONTRACT_FILE_SHA256 = (
    "478e35dcbd6217659680a401cfb2c7a7babc0127d8a0ef37c20b755dfbc80112"
)
EXPECTED_CONTRACT_SELF_SHA256 = (
    "c78271a10dad47327f45b35dc6a7016fe5795cc8d964aca679e922e3c3d52de3"
)
EXPECTED_CONTRACT_SCHEMA_FILE_SHA256 = (
    "8cfbf68bedcf70afa71f73cbc00526b31e3bf53c857c734f7e9b1a6b0b29267c"
)
EXPECTED_MAPPING_SCHEMA_FILE_SHA256 = (
    "af5302bb26bee4c7ba0944749657a96865c0ce0fbacfe8f2175fbd2c4d499e28"
)
EXPECTED_OPERATOR_SCHEMA_FILE_SHA256 = (
    "5d7d14e912bfa29d90959f9d368f50a784b40e4f603fc8b8146da216eac3c8fd"
)
EXPECTED_PLAN_FILE_SHA256 = (
    "1977c85b9a3b7001294a04d33e7654ae20ffb4266ac0c8d2dc76880bdec99fef"
)
EXPECTED_PLAN_SELF_SHA256 = (
    "e6070a7cdd8f3b53231635027055669c8319d311af1790d672723d6e7e048d0f"
)
EXPECTED_PLAN_SCHEMA_FILE_SHA256 = (
    "09a21861104bd1b03667d1207a79d523386ad4431e710ba44e4d298180753c09"
)
EXPECTED_SHARED_BANK_IDENTITY_FILE_SHA256 = (
    "48f5eef7cf9f7c513cf8e6568b3eeb4d607845c1e70e6c39b6ca0192a4c297de"
)
EXPECTED_SHARED_BANK_IDENTITY_SELF_SHA256 = (
    "e522afa73e8dc01c51303d1d1d99a95fe2ea78f968a2696dc0583f695fce7c37"
)
EXPECTED_SHARED_BANK_IDENTITY_SCHEMA_FILE_SHA256 = (
    "0cee4c9ed9083d734491d90eaa3f02265b07295d7873733c006cce9df317147c"
)

_MODE_FIELD_NAMES = (
    "direct_2x_luma_anisotropy_mode_ordinal",
    "direct_2x_chroma_anisotropy_mode_ordinal",
    "direct_3_over_2_luma_anisotropy_mode_ordinal",
    "direct_3_over_2_chroma_anisotropy_mode_ordinal",
)
_AUTHORITY_VALUE = {
    "shared_bank_artifact_materialization_v2_file_sha256": (
        EXPECTED_CONTRACT_FILE_SHA256
    ),
    "shared_bank_artifact_materialization_v2_self_sha256": (
        EXPECTED_CONTRACT_SELF_SHA256
    ),
    "shared_bank_artifact_materialization_v2_schema_file_sha256": (
        EXPECTED_CONTRACT_SCHEMA_FILE_SHA256
    ),
}


class SharedBankArtifactV2Error(ValueError):
    """The schema-2 authority, candidate, or artifact pair is invalid."""


@dataclass(frozen=True)
class SharedBankArtifactPairV2:
    """Canonical schema-2 artifact bytes and their complete-file identities."""

    mapping_bytes: bytes
    operator_bank_bytes: bytes
    mapping_sha256: str
    operator_bank_sha256: str
    candidate_vector_sha256: str
    shared_bank_configuration_sha256: str


@dataclass(frozen=True)
class _AuthoritiesV2:
    contract: Mapping[str, object]
    mapping_schema: Mapping[str, object]
    operator_schema: Mapping[str, object]
    plan: ParsedCalibrationPlanV2
    mode_resolution: Mapping[int, tuple[int, bool]]


def _reject_duplicate_pairs(
    pairs: Sequence[tuple[str, object]],
) -> Dict[str, object]:
    result: Dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise SharedBankArtifactV2Error(f"duplicate JSON member: {key}")
        result[key] = value
    return result


def _reject_float(token: str) -> object:
    raise SharedBankArtifactV2Error(
        f"floating-point JSON value is forbidden: {token}"
    )


def _reject_nonfinite(token: str) -> object:
    raise SharedBankArtifactV2Error(f"non-finite JSON value: {token}")


def _strict_object(
    payload: bytes,
    *,
    label: str,
    require_canonical_file: bool,
) -> Mapping[str, object]:
    if type(payload) is not bytes:
        raise SharedBankArtifactV2Error(f"{label} payload must be exact bytes")
    if payload.startswith(b"\xef\xbb\xbf"):
        raise SharedBankArtifactV2Error(f"{label} contains a UTF-8 byte-order mark")
    try:
        value = json.loads(
            payload,
            object_pairs_hook=_reject_duplicate_pairs,
            parse_float=_reject_float,
            parse_constant=_reject_nonfinite,
        )
    except SharedBankArtifactV2Error:
        raise
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise SharedBankArtifactV2Error(
            f"{label} is not valid UTF-8 JSON"
        ) from error
    if type(value) is not dict:
        raise SharedBankArtifactV2Error(f"{label} must be a JSON object")
    if require_canonical_file:
        expected = canonical_json_bytes(value) + b"\n"
        if payload != expected:
            raise SharedBankArtifactV2Error(
                f"{label} bytes are not canonical JSON with exactly one LF"
            )
    return value


def _schema_validator(
    schema: Mapping[str, object],
    *,
    label: str,
) -> jsonschema.Draft202012Validator:
    try:
        jsonschema.Draft202012Validator.check_schema(schema)
        return jsonschema.Draft202012Validator(
            schema,
            format_checker=jsonschema.FormatChecker(),
        )
    except (TypeError, ValueError, jsonschema.SchemaError) as error:
        raise SharedBankArtifactV2Error(f"{label} schema is invalid") from error


def _validate_document(
    document: Mapping[str, object],
    validator: jsonschema.Draft202012Validator,
    *,
    label: str,
) -> None:
    errors = sorted(
        validator.iter_errors(document),
        key=lambda error: tuple(str(item) for item in error.absolute_path),
    )
    if errors:
        descriptions = []
        for error in errors:
            location = "/".join(
                str(item) for item in error.absolute_path
            ) or "<root>"
            descriptions.append(f"{location}: {error.message}")
        raise SharedBankArtifactV2Error(
            f"{label} schema validation failed: " + "; ".join(descriptions)
        )


def _safe_bound_path(root: Path, value: object, *, label: str) -> Path:
    if type(value) is not str or not value or "\\" in value:
        raise SharedBankArtifactV2Error(f"{label} path is invalid")
    relative = PurePosixPath(value)
    if relative.is_absolute() or any(part in ("", ".", "..") for part in relative.parts):
        raise SharedBankArtifactV2Error(f"{label} path is not safe and relative")
    return root.joinpath(*relative.parts)


def _binding_payload(
    root: Path,
    binding: Mapping[str, object],
    *,
    label: str,
) -> bytes:
    path = _safe_bound_path(root, binding.get("path"), label=label)
    try:
        payload = path.read_bytes()
    except OSError as error:
        raise SharedBankArtifactV2Error(f"{label} cannot be read") from error
    if type(binding.get("size_bytes")) is not int or len(payload) != binding.get(
        "size_bytes"
    ):
        raise SharedBankArtifactV2Error(f"{label} size binding is invalid")
    if type(binding.get("sha256")) is not str or hashlib.sha256(
        payload
    ).hexdigest() != binding.get("sha256"):
        raise SharedBankArtifactV2Error(f"{label} file hash is invalid")

    self_hash = binding.get("self_hash")
    if self_hash is not None:
        if type(self_hash) is not dict:
            raise SharedBankArtifactV2Error(f"{label} self-hash binding is invalid")
        document = _strict_object(
            payload,
            label=label,
            require_canonical_file=False,
        )
        field = self_hash.get("field")
        expected = self_hash.get("sha256")
        if (
            type(field) is not str
            or type(expected) is not str
            or document.get(field) != expected
            or manifest_sha256(document, field=field) != expected
        ):
            raise SharedBankArtifactV2Error(f"{label} self-hash is invalid")
    return payload


def _binding_map(
    document: Mapping[str, object],
    *,
    label: str,
) -> Mapping[str, Mapping[str, object]]:
    values = document.get("authority_bindings")
    if type(values) is not list:
        raise SharedBankArtifactV2Error(f"{label} authority bindings are invalid")
    result: Dict[str, Mapping[str, object]] = {}
    for index, value in enumerate(values):
        if type(value) is not dict or type(value.get("id")) is not str:
            raise SharedBankArtifactV2Error(
                f"{label} authority binding {index} is invalid"
            )
        identifier = value["id"]
        if identifier in result:
            raise SharedBankArtifactV2Error(
                f"{label} authority binding IDs are duplicated"
            )
        result[identifier] = value
    return result


def _load_exact_schema(
    root: Path,
    relative_path: Path,
    expected_sha256: str,
    *,
    label: str,
) -> Mapping[str, object]:
    try:
        payload = (root / relative_path).read_bytes()
    except OSError as error:
        raise SharedBankArtifactV2Error(f"{label} cannot be read") from error
    if hashlib.sha256(payload).hexdigest() != expected_sha256:
        raise SharedBankArtifactV2Error(f"{label} file hash is invalid")
    schema = _strict_object(
        payload,
        label=label,
        require_canonical_file=True,
    )
    _schema_validator(schema, label=label)
    return schema


def _load_authorities(root: Path) -> _AuthoritiesV2:
    if not isinstance(root, Path):
        raise SharedBankArtifactV2Error("repository root must be a Path")
    contract_schema = _load_exact_schema(
        root,
        CONTRACT_SCHEMA_RELATIVE_PATH,
        EXPECTED_CONTRACT_SCHEMA_FILE_SHA256,
        label="shared_bank_artifact_materialization_v2_schema",
    )
    try:
        contract_payload = (root / CONTRACT_RELATIVE_PATH).read_bytes()
    except OSError as error:
        raise SharedBankArtifactV2Error(
            "shared_bank_artifact_materialization_v2 cannot be read"
        ) from error
    if hashlib.sha256(contract_payload).hexdigest() != EXPECTED_CONTRACT_FILE_SHA256:
        raise SharedBankArtifactV2Error(
            "shared_bank_artifact_materialization_v2 file hash is invalid"
        )
    contract = _strict_object(
        contract_payload,
        label="shared_bank_artifact_materialization_v2",
        require_canonical_file=True,
    )
    _validate_document(
        contract,
        _schema_validator(
            contract_schema,
            label="shared_bank_artifact_materialization_v2_schema",
        ),
        label="shared_bank_artifact_materialization_v2",
    )
    if (
        contract.get("artifact_sha256") != EXPECTED_CONTRACT_SELF_SHA256
        or manifest_sha256(contract, field="artifact_sha256")
        != EXPECTED_CONTRACT_SELF_SHA256
    ):
        raise SharedBankArtifactV2Error(
            "shared_bank_artifact_materialization_v2 self-hash is invalid"
        )

    bindings = _binding_map(
        contract,
        label="shared_bank_artifact_materialization_v2",
    )
    bound_payloads: Dict[str, bytes] = {}
    for identifier, binding in bindings.items():
        bound_payloads[identifier] = _binding_payload(
            root,
            binding,
            label=f"materialization authority {identifier}",
        )

    mapping_schema = _load_exact_schema(
        root,
        MAPPING_SCHEMA_RELATIVE_PATH,
        EXPECTED_MAPPING_SCHEMA_FILE_SHA256,
        label="video_mapping_v2_schema",
    )
    operator_schema = _load_exact_schema(
        root,
        OPERATOR_SCHEMA_RELATIVE_PATH,
        EXPECTED_OPERATOR_SCHEMA_FILE_SHA256,
        label="operator_bank_v2_schema",
    )
    for schema, label in (
        (mapping_schema, "video_mapping_v2_schema"),
        (operator_schema, "operator_bank_v2_schema"),
    ):
        defs = schema.get("$defs")
        authority = defs.get("materializationAuthority") if type(defs) is dict else None
        if type(authority) is not dict or authority.get("const") != _AUTHORITY_VALUE:
            raise SharedBankArtifactV2Error(
                f"{label} materialization authority is invalid"
            )

    identity_payload = bound_payloads.get("shared_bank_configuration_identity_v2")
    identity_schema_payload = bound_payloads.get(
        "shared_bank_configuration_identity_v2_schema"
    )
    if type(identity_payload) is not bytes or type(identity_schema_payload) is not bytes:
        raise SharedBankArtifactV2Error(
            "shared-bank configuration identity bindings are absent"
        )
    if hashlib.sha256(identity_payload).hexdigest() != (
        EXPECTED_SHARED_BANK_IDENTITY_FILE_SHA256
    ) or hashlib.sha256(identity_schema_payload).hexdigest() != (
        EXPECTED_SHARED_BANK_IDENTITY_SCHEMA_FILE_SHA256
    ):
        raise SharedBankArtifactV2Error(
            "shared-bank configuration identity authority is invalid"
        )
    identity_schema = _strict_object(
        identity_schema_payload,
        label="shared_bank_configuration_identity_v2_schema",
        require_canonical_file=True,
    )
    identity = _strict_object(
        identity_payload,
        label="shared_bank_configuration_identity_v2",
        require_canonical_file=True,
    )
    _validate_document(
        identity,
        _schema_validator(
            identity_schema,
            label="shared_bank_configuration_identity_v2_schema",
        ),
        label="shared_bank_configuration_identity_v2",
    )
    if (
        identity.get("artifact_sha256")
        != EXPECTED_SHARED_BANK_IDENTITY_SELF_SHA256
        or manifest_sha256(identity, field="artifact_sha256")
        != EXPECTED_SHARED_BANK_IDENTITY_SELF_SHA256
    ):
        raise SharedBankArtifactV2Error(
            "shared_bank_configuration_identity_v2 self-hash is invalid"
        )
    for identifier, binding in _binding_map(
        identity,
        label="shared_bank_configuration_identity_v2",
    ).items():
        _binding_payload(
            root,
            binding,
            label=f"shared-bank identity authority {identifier}",
        )

    plan_payload = bound_payloads.get("calibration_plan_v2")
    if type(plan_payload) is not bytes:
        raise SharedBankArtifactV2Error("calibration plan V2 binding is absent")
    plan_document = _strict_object(
        plan_payload,
        label="calibration_plan_v2",
        require_canonical_file=False,
    )
    plan_input_bindings = plan_document.get("input_bindings")
    if type(plan_input_bindings) is not list:
        raise SharedBankArtifactV2Error(
            "calibration_plan_v2 input bindings are invalid"
        )
    plan_bound_payloads: Dict[str, bytes] = {}
    for index, value in enumerate(plan_input_bindings):
        if type(value) is not dict or type(value.get("id")) is not str:
            raise SharedBankArtifactV2Error(
                f"calibration_plan_v2 input binding {index} is invalid"
            )
        identifier = value["id"]
        if identifier in plan_bound_payloads:
            raise SharedBankArtifactV2Error(
                "calibration_plan_v2 input binding IDs are duplicated"
            )
        plan_bound_payloads[identifier] = _binding_payload(
            root,
            value,
            label=f"calibration plan authority {identifier}",
        )
    try:
        plan = parse_calibration_plan_v2(
            plan_payload,
            bound_payloads=plan_bound_payloads,
        )
    except CalibrationPlanCodecError as error:
        raise SharedBankArtifactV2Error(
            "calibration_plan_v2 authentication failed"
        ) from error
    if (
        plan.plan_file_sha256 != EXPECTED_PLAN_FILE_SHA256
        or plan.plan_self_sha256 != EXPECTED_PLAN_SELF_SHA256
        or hashlib.sha256(
            bound_payloads["calibration_plan_v2_schema"]
        ).hexdigest()
        != EXPECTED_PLAN_SCHEMA_FILE_SHA256
    ):
        raise SharedBankArtifactV2Error("calibration_plan_v2 identity is invalid")

    materialization = contract.get("operator_bank_materialization")
    rows = materialization.get("mode_resolution") if type(materialization) is dict else None
    if type(rows) is not list:
        raise SharedBankArtifactV2Error("route-plane mode resolution is absent")
    mode_resolution: Dict[int, tuple[int, bool]] = {}
    for row in rows:
        if type(row) is not dict:
            raise SharedBankArtifactV2Error("route-plane mode resolution is invalid")
        ordinal = row.get("mode_ordinal")
        strength = row.get("resolved_anisotropy_strength_q12")
        use = row.get("resolved_use_anisotropy")
        if (
            type(ordinal) is not int
            or type(strength) is not int
            or type(use) is not bool
            or ordinal in mode_resolution
        ):
            raise SharedBankArtifactV2Error("route-plane mode resolution is invalid")
        mode_resolution[ordinal] = (strength, use)
    if set(mode_resolution) != set(range(6)):
        raise SharedBankArtifactV2Error("route-plane mode resolution is incomplete")

    return _AuthoritiesV2(
        contract=contract,
        mapping_schema=mapping_schema,
        operator_schema=operator_schema,
        plan=plan,
        mode_resolution=mode_resolution,
    )


class SharedBankArtifactMaterializerV2:
    """Materialize and reopen-validate only the frozen schema-2 artifact family."""

    def __init__(self, repository_root: Path = REPOSITORY_ROOT) -> None:
        self._authorities = _load_authorities(repository_root)
        self._mapping_validator = _schema_validator(
            self._authorities.mapping_schema,
            label="video_mapping_v2_schema",
        )
        self._operator_validator = _schema_validator(
            self._authorities.operator_schema,
            label="operator_bank_v2_schema",
        )

    @property
    def plan(self) -> ParsedCalibrationPlanV2:
        """Return the authenticated immutable V2 plan model."""

        return self._authorities.plan

    def _physical_candidate(
        self,
        candidate: Mapping[str, object],
    ) -> Mapping[str, object]:
        if not isinstance(candidate, Mapping):
            raise SharedBankArtifactV2Error("physical candidate must be a mapping")
        try:
            snapshot = dict(candidate)
        except Exception as error:
            raise SharedBankArtifactV2Error(
                "physical candidate cannot be snapshotted exactly once"
            ) from error
        if all(
            name in snapshot
            and type(snapshot[name]) is int
            and snapshot[name] == 0
            for name in _MODE_FIELD_NAMES
        ):
            raise SharedBankArtifactV2Error(
                "all-isotropic route-plane mode vector is forbidden"
            )
        try:
            validate_materialized_candidate_identity_v2(
                snapshot,
                self._authorities.plan,
            )
            validate_candidate_constraints_v2(
                snapshot,
                self._authorities.plan,
            )
        except CalibrationPlanCodecError as error:
            raise SharedBankArtifactV2Error(str(error)) from error
        return {
            name: snapshot[name]
            for name in self._authorities.plan.physical_candidate_order
        }

    def _candidate_identity(
        self,
        physical: Mapping[str, object],
    ) -> Mapping[str, object]:
        plan = self._authorities.plan
        return {
            "calibration_plan_v2_file_sha256": EXPECTED_PLAN_FILE_SHA256,
            "calibration_plan_v2_self_sha256": EXPECTED_PLAN_SELF_SHA256,
            "calibration_plan_v2_schema_file_sha256": (
                EXPECTED_PLAN_SCHEMA_FILE_SHA256
            ),
            "shared_bank_configuration_v2_file_sha256": (
                EXPECTED_SHARED_BANK_IDENTITY_FILE_SHA256
            ),
            "shared_bank_configuration_v2_self_sha256": (
                EXPECTED_SHARED_BANK_IDENTITY_SELF_SHA256
            ),
            "shared_bank_configuration_v2_schema_file_sha256": (
                EXPECTED_SHARED_BANK_IDENTITY_SCHEMA_FILE_SHA256
            ),
            "physical_candidate_field_count": 48,
            "physical_candidate_items": [
                [name, physical[name]]
                for name in plan.physical_candidate_order
            ],
            "candidate_vector_sha256": candidate_vector_sha256_v2(
                physical,
                plan,
            ),
            "shared_bank_configuration_sha256": (
                shared_bank_configuration_sha256_v2(physical, plan)
            ),
        }

    @staticmethod
    def _selection_binding(
        status: object,
        selection_binding: Mapping[str, object] | None,
    ) -> Mapping[str, object]:
        if selection_binding is None:
            selection = {
                "calibration_selection_sha256": None,
                "selected_evaluation_sha256": None,
            }
        elif isinstance(selection_binding, Mapping):
            try:
                selection = dict(selection_binding)
            except Exception as error:
                raise SharedBankArtifactV2Error(
                    "selection binding cannot be snapshotted"
                ) from error
        else:
            raise SharedBankArtifactV2Error("selection binding must be a mapping")
        if type(status) is not str:
            raise SharedBankArtifactV2Error("artifact status must be an exact string")
        return selection

    def _route_plane(
        self,
        physical: Mapping[str, object],
        prefix: str,
    ) -> Mapping[str, object]:
        ordinal = physical[f"{prefix}_anisotropy_mode_ordinal"]
        if type(ordinal) is not int or ordinal not in self._authorities.mode_resolution:
            raise SharedBankArtifactV2Error(
                f"route-plane anisotropy ordinal is invalid: {prefix}"
            )
        strength, use = self._authorities.mode_resolution[ordinal]
        return {
            "anisotropy_mode_ordinal": ordinal,
            "resolved_anisotropy_strength_q12": strength,
            "resolved_use_anisotropy": use,
            "coordinate_policy": physical[f"{prefix}_coordinate_policy"],
        }

    def _documents(
        self,
        physical: Mapping[str, object],
        *,
        configuration_id: object,
        mapping_seed_sha256: object,
        operator_bank_seed_sha256: object,
        status: object,
        selection_binding: Mapping[str, object] | None,
    ) -> tuple[Mapping[str, object], Mapping[str, object]]:
        selection = self._selection_binding(status, selection_binding)
        identity = self._candidate_identity(physical)
        mapping = {
            "schema_version": "2.0.0",
            "artifact_kind": "p06_video_mapping_v2",
            "status": status,
            "mapping_id": "ash-video-mapping-v2",
            "configuration_id": configuration_id,
            "mapping_seed_sha256": mapping_seed_sha256,
            "materialization_authority": dict(_AUTHORITY_VALUE),
            "candidate_identity": identity,
            "selection_binding": dict(selection),
            "canonical_core_unchanged": True,
            "input_contract": {
                "bit_depth": 8,
                "chroma_siting": "left",
                "matrix": "BT.709",
                "pixel_format": "420v",
                "range": "video",
                "subsampling": "4:2:0",
            },
            "boundary_mode": physical["boundary_mode"],
            "analysis_grid_source_steps": {
                "direct_2x": physical["direct_2x_analysis_grid_source_step"],
                "direct_3_over_2": physical[
                    "direct_3_over_2_analysis_grid_source_step"
                ],
            },
            "thresholds_unorm15": {
                name: {
                    "low": physical[f"{name}_low_unorm15"],
                    "high": physical[f"{name}_high_unorm15"],
                }
                for name in (
                    "edge_present",
                    "coherent_structure",
                    "texture_high_frequency",
                    "alias_or_ringing_risk",
                    "chroma_luma_structure_aligned",
                )
            }
            | {"temporal_support_valid": {"low": 32767, "high": 32767}},
            "analysis_epsilon_q0_30": physical["analysis_epsilon_q0_30"],
            "risk_weights_unorm15": {
                "laplacian": physical["risk_laplacian_weight_unorm15"],
                "alternating_difference": (
                    32767 - physical["risk_laplacian_weight_unorm15"]
                ),
            },
            "chroma_edge_confidence_unorm15": physical[
                "chroma_edge_confidence_unorm15"
            ],
        }
        operator = {
            "schema_version": "2.0.0",
            "artifact_kind": "p06_operator_bank_v2",
            "status": status,
            "operator_bank_id": "ash-spatial-operator-bank-v2",
            "configuration_id": configuration_id,
            "operator_bank_seed_sha256": operator_bank_seed_sha256,
            "materialization_authority": dict(_AUTHORITY_VALUE),
            "candidate_identity": identity,
            "selection_binding": dict(selection),
            "boundary_mode": physical["boundary_mode"],
            "routes": {
                "direct_2x": {
                    "route_spatial_policy_id": physical[
                        "direct_2x_route_spatial_policy_id"
                    ],
                    "luma": self._route_plane(physical, "direct_2x_luma"),
                    "chroma": self._route_plane(physical, "direct_2x_chroma"),
                },
                "direct_3_over_2": {
                    "route_spatial_policy_id": physical[
                        "direct_3_over_2_route_spatial_policy_id"
                    ],
                    "luma": self._route_plane(
                        physical,
                        "direct_3_over_2_luma",
                    ),
                    "chroma": self._route_plane(
                        physical,
                        "direct_3_over_2_chroma",
                    ),
                },
            },
            "operator_parameters": {
                "minimum_anisotropic_magnitude_unorm15": physical[
                    "minimum_anisotropic_magnitude_unorm15"
                ],
                "minimum_anisotropic_coherence_unorm15": physical[
                    "minimum_anisotropic_coherence_unorm15"
                ],
                "detail_gain_q12": physical["detail_gain_q12"],
                "relaxed_limiter_alpha_q12": physical[
                    "relaxed_limiter_alpha_q12"
                ],
                "risk_detail_suppression_unorm15": physical[
                    "risk_detail_suppression_unorm15"
                ],
                "low_pass_radius_q8_8": physical["low_pass_radius_q8_8"],
                "weight_epsilon_f32_bits": 730643660,
            },
            "semantic_steps": {
                "orientation_sector_step": 1,
                "support_radius_step_q8_8": physical[
                    "support_radius_step_q8_8"
                ],
                "detail_gain_step_q12": physical["detail_gain_step_q12"],
                "regularization_step_q12": physical[
                    "regularization_step_q12"
                ],
            },
        }
        return mapping, operator

    def materialize(
        self,
        candidate: Mapping[str, object],
        *,
        configuration_id: str,
        mapping_seed_sha256: str,
        operator_bank_seed_sha256: str,
        status: str = "calibration_candidate",
        selection_binding: Mapping[str, object] | None = None,
    ) -> SharedBankArtifactPairV2:
        """Emit canonical V2 bytes after full candidate and authority validation."""

        physical = self._physical_candidate(candidate)
        mapping, operator = self._documents(
            physical,
            configuration_id=configuration_id,
            mapping_seed_sha256=mapping_seed_sha256,
            operator_bank_seed_sha256=operator_bank_seed_sha256,
            status=status,
            selection_binding=selection_binding,
        )
        mapping_bytes = canonical_json_bytes(mapping) + b"\n"
        operator_bytes = canonical_json_bytes(operator) + b"\n"
        return self._validate_pair(
            mapping_bytes,
            operator_bytes,
            expected_mapping_sha256=None,
            expected_operator_bank_sha256=None,
        )

    def validate(
        self,
        mapping_bytes: bytes,
        operator_bank_bytes: bytes,
        *,
        mapping_sha256: str,
        operator_bank_sha256: str,
    ) -> SharedBankArtifactPairV2:
        """Validate reopened canonical V2 bytes and exact complete-file digests."""

        return self._validate_pair(
            mapping_bytes,
            operator_bank_bytes,
            expected_mapping_sha256=mapping_sha256,
            expected_operator_bank_sha256=operator_bank_sha256,
        )

    def _validate_pair(
        self,
        mapping_bytes: bytes,
        operator_bank_bytes: bytes,
        *,
        expected_mapping_sha256: str | None,
        expected_operator_bank_sha256: str | None,
    ) -> SharedBankArtifactPairV2:
        mapping = _strict_object(
            mapping_bytes,
            label="video_mapping_v2",
            require_canonical_file=True,
        )
        operator = _strict_object(
            operator_bank_bytes,
            label="operator_bank_v2",
            require_canonical_file=True,
        )
        if mapping.get("schema_version") != "2.0.0" or operator.get(
            "schema_version"
        ) != "2.0.0":
            raise SharedBankArtifactV2Error(
                "cross-version or unknown-schema artifact pairing is forbidden"
            )
        _validate_document(
            mapping,
            self._mapping_validator,
            label="video_mapping_v2",
        )
        _validate_document(
            operator,
            self._operator_validator,
            label="operator_bank_v2",
        )

        mapping_identity = mapping.get("candidate_identity")
        operator_identity = operator.get("candidate_identity")
        if type(mapping_identity) is not dict or type(operator_identity) is not dict:
            raise SharedBankArtifactV2Error("candidate identity is absent")
        if canonical_json_bytes(mapping_identity) != canonical_json_bytes(
            operator_identity
        ):
            raise SharedBankArtifactV2Error(
                "mapping and operator candidate identities diverge"
            )
        items = mapping_identity.get("physical_candidate_items")
        if type(items) is not list or len(items) != 48:
            raise SharedBankArtifactV2Error(
                "candidate identity does not contain 48 ordered items"
            )
        physical: Dict[str, object] = {}
        for index, item in enumerate(items):
            if type(item) is not list or len(item) != 2 or type(item[0]) is not str:
                raise SharedBankArtifactV2Error(
                    f"candidate identity item {index} is invalid"
                )
            if item[0] in physical:
                raise SharedBankArtifactV2Error(
                    "candidate identity item names are duplicated"
                )
            physical[item[0]] = item[1]
        physical = dict(self._physical_candidate(physical))
        expected_identity = self._candidate_identity(physical)
        if canonical_json_bytes(mapping_identity) != canonical_json_bytes(
            expected_identity
        ):
            raise SharedBankArtifactV2Error(
                "candidate or shared-bank identity hash is invalid"
            )

        for field in (
            "configuration_id",
            "status",
            "selection_binding",
            "boundary_mode",
        ):
            if canonical_json_bytes(mapping[field]) != canonical_json_bytes(
                operator[field]
            ):
                raise SharedBankArtifactV2Error(
                    f"mapping and operator pairing diverges: {field}"
                )
        expected_mapping, expected_operator = self._documents(
            physical,
            configuration_id=mapping["configuration_id"],
            mapping_seed_sha256=mapping["mapping_seed_sha256"],
            operator_bank_seed_sha256=operator["operator_bank_seed_sha256"],
            status=mapping["status"],
            selection_binding=mapping["selection_binding"],
        )
        if canonical_json_bytes(mapping) != canonical_json_bytes(expected_mapping):
            raise SharedBankArtifactV2Error(
                "video mapping differs from exact candidate materialization"
            )
        if canonical_json_bytes(operator) != canonical_json_bytes(expected_operator):
            raise SharedBankArtifactV2Error(
                "operator bank differs from exact route-plane materialization"
            )

        actual_mapping_sha256 = hashlib.sha256(mapping_bytes).hexdigest()
        actual_operator_sha256 = hashlib.sha256(operator_bank_bytes).hexdigest()
        if expected_mapping_sha256 is not None and (
            type(expected_mapping_sha256) is not str
            or actual_mapping_sha256 != expected_mapping_sha256
        ):
            raise SharedBankArtifactV2Error(
                "video mapping complete-file SHA-256 is invalid"
            )
        if expected_operator_bank_sha256 is not None and (
            type(expected_operator_bank_sha256) is not str
            or actual_operator_sha256 != expected_operator_bank_sha256
        ):
            raise SharedBankArtifactV2Error(
                "operator bank complete-file SHA-256 is invalid"
            )
        return SharedBankArtifactPairV2(
            mapping_bytes=mapping_bytes,
            operator_bank_bytes=operator_bank_bytes,
            mapping_sha256=actual_mapping_sha256,
            operator_bank_sha256=actual_operator_sha256,
            candidate_vector_sha256=expected_identity["candidate_vector_sha256"],
            shared_bank_configuration_sha256=expected_identity[
                "shared_bank_configuration_sha256"
            ],
        )
