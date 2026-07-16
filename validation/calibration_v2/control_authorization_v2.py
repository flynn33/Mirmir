"""Fail-closed P06 V2 control authorization over immutable snapshot bytes.

This module is intentionally isolated from the scheduler persistence adapters.
It authenticates the exact five P06 authorities, replays fixed, conventional,
and non-ASH control selection, and proves an exact transitive dependency set
before returning an authorization result.  Run evidence is consumed only from
an :class:`AuthenticatedClosureSnapshotV2`; no evidence pathname is reopened.
"""

from __future__ import annotations

from dataclasses import dataclass
import hashlib
import json
import math
import os
from pathlib import Path
import re
import stat
from typing import Callable, Dict, Iterable, Mapping, Optional, Sequence, Tuple

from jsonschema import Draft202012Validator

from validation.calibration_v2.authenticated_closure_snapshot_v2 import (
    AuthenticatedClosureSnapshotV2,
    AuthenticatedClosureSnapshotV2Error,
    ClosureFileBindingV2,
)
from validation.calibration_v2.non_ash_selector_artifacts_v2 import (
    ATTEMPT_FAILURE_KIND,
    ATTEMPT_LEDGER_KIND,
    EVALUATION_EVIDENCE_KIND,
    EVALUATION_EVIDENCE_SCHEMA_VERSION,
    NEIGHBOR_MANIFEST_KIND,
    SELECTION_KIND,
    NonAshSelectorArtifactV2Error,
    verify_development_selection_v2,
    verify_validation_selection_v2,
)
from validation.calibration_v2.non_ash_selector_v2 import (
    NonAshSelectorEvaluationScopeV2,
    NonAshSelectorExecutionProfileV2,
    NonAshSelectorV2Error,
    rule_mapping_v2,
)
from validation.calibration_v2.production_evaluator import (
    CONTROL_MEASUREMENT_FRAME_ENCODING_V2,
    ControlExecutionProducerIdentityV2,
    ControlExecutionSemanticContextV2,
    ControlWriterProducerIdentityV2,
    ControlWriterSemanticContextV2,
    NON_ASH_SELECTOR_ID_V2,
    ProductionEvaluatorError,
    conventional_control_request,
    conventional_control_configuration_sha256_v2,
    corpus_metric_bundle,
    decode_control_measurement_frame_bytes_v2,
    fixed_control_request,
    fixed_control_configuration_sha256_v2,
    hierarchical_control_objective_v2,
    non_ash_control_configuration_sha256_v2,
    non_ash_control_request_for_selector_v2,
)
from validation.quality.src.mirmir_quality.arrays import frame_sha256


CALIBRATION_ROOT = Path(__file__).resolve().parent
REPOSITORY_ROOT = CALIBRATION_ROOT.parents[1]
SCHEMA_ROOT = CALIBRATION_ROOT / "schemas"
CONTRACT_ROOT = CALIBRATION_ROOT / "contracts"

OBJECTIVE_SUMMARY_KIND = "p06_control_objective_summary_v2"
OUTPUT_MANIFEST_KIND = "p06_control_output_manifest_v2"
FIXED_SELECTION_KIND = "p06_fixed_control_selection_v2"
CONVENTIONAL_SELECTION_KIND = "p06_conventional_control_selection_v2"
CONTROL_AUTHORIZATION_BUNDLE_KIND = "p06_control_authorization_bundle_v2"
VALIDATION_ADMISSION_KIND = (
    "p06_validation_candidate_development_evidence_v2"
)

CONTROL_OUTPUT_BYTES_KIND = "p06_control_output_bytes_v2"
CONTROL_TARGET_FRAME_BYTES_KIND = "p06_control_target_frame_bytes_v2"
CONTROL_LOW_RESOLUTION_INPUT_BYTES_KIND = (
    "p06_control_low_resolution_input_bytes_v2"
)
CONTROL_SOURCE_TARGET_PROVENANCE_KIND = (
    "p06_control_source_target_provenance_v2"
)
CONTROL_DEGRADATION_PROFILE_KIND = "p06_control_degradation_profile_v2"
CONTROL_EXECUTION_PROVENANCE_KIND = "p06_control_execution_provenance_v2"
CONTROL_WRITER_EVIDENCE_BYTES_KIND = "p06_control_writer_evidence_bytes_v2"
CONTROL_WRITER_ENCODED_CONTAINER_BYTES_KIND = (
    "p06_control_writer_encoded_container_bytes_v2"
)
CONTROL_WRITER_REPORT_BYTES_KIND = "p06_control_writer_report_bytes_v2"
CONTROL_WRITER_DECODED_PAYLOAD_BYTES_KIND = (
    "p06_control_writer_decoded_payload_bytes_v2"
)
CONTROL_MEASUREMENT_EVIDENCE_KIND = "p06_control_metric_measurement_v2"
CONTROL_METRIC_ALGORITHM = "corpus_metric_bundle-v1"
NON_ASH_FAILURE_EVIDENCE_BYTES_KIND = (
    "p06_non_ash_failure_evidence_bytes_v2"
)
NON_ASH_IMMUTABLE_CONTENT_KIND = "p06_non_ash_immutable_content_v2"
CACHED_OPERATOR_OUTPUT_MANIFEST_KIND = (
    "p06_cached_16_operator_output_manifest_v2"
)

SCHEMA_VERSION_V2 = "2.0.0"
DEPENDENCY_SET_HASH_DOMAIN_V2 = (
    "mirmir-p06-control-authorization-dependency-set-v2"
)
CONTROL_AUTHORIZATION_HASH_DOMAIN_V2 = (
    "mirmir-p06-control-authorization-semantic-v2"
)

SELECTION_METRICS = (
    "y_psnr_db",
    "y_ms_ssim",
    "y_ssim",
    "cb_psnr_db",
    "cr_psnr_db",
)
METRIC_FIELDS = frozenset(
    {
        "y_psnr_db",
        "cb_psnr_db",
        "cr_psnr_db",
        "y_ssim",
        "cb_ssim",
        "cr_ssim",
        "y_ms_ssim",
        "cb_ms_ssim",
        "cr_ms_ssim",
        "writer_y_psnr_contribution_db",
    }
)
FIXED_DESCRIPTOR_IDS = tuple(range(16))
CONVENTIONAL_ALGORITHM_IDS = (
    "bilinear-separable-v1",
    "keys-cubic-a-minus-0.5-separable-v1",
    "lanczos3-separable-v1",
)
SELECTION_OBJECTIVE = {
    "comparison_domain": "engine_raw",
    "row_scope": "natural corpus asset rows only",
    "per_source_aggregation": (
        "unweighted arithmetic mean across that source's locked "
        "degradation-profile rows"
    ),
    "across_source_aggregation": (
        "unweighted arithmetic mean across source assets"
    ),
    "direction": "lexicographically maximize",
    "metric_order": list(SELECTION_METRICS),
}
SELECTION_TUPLE_DESCRIPTION = (
    "lexicographically maximize [y_psnr_db, y_ms_ssim, y_ssim, "
    "cb_psnr_db, cr_psnr_db]"
)

_ZERO_SHA256 = "0" * 64
_SAFE_PATH = re.compile(
    r"^(?!/)(?!.*\\)(?!.*//)(?!.*(?:^|/)\.\.?(?:/|$))"
    r"(?!.*/$)[A-Za-z0-9._/-]+$"
)

# The new schema hashes are filled after their canonical files are finalized.
_SCHEMA_SPECS = {
    OBJECTIVE_SUMMARY_KIND: (
        SCHEMA_ROOT / "control-objective-summary-v2.schema.json",
        "2eaf46f2555cc93eee8d44ea7b2f00a412fc18170059fe8a23dd40cf4e42fe55",
    ),
    OUTPUT_MANIFEST_KIND: (
        SCHEMA_ROOT / "control-output-manifest-v2.schema.json",
        "a8fb32c27c64bc6ecf837bcd8f5e679cc37c44f7d30086ae1bed966548855865",
    ),
    FIXED_SELECTION_KIND: (
        SCHEMA_ROOT / "fixed-control-selection-v2.schema.json",
        "1afc7a9506770dbffa811eca71ef22e016b65cfe834ff7a8585bbadaecc2eae9",
    ),
    CONVENTIONAL_SELECTION_KIND: (
        SCHEMA_ROOT / "conventional-control-selection-v2.schema.json",
        "e650acfad66e557894ad62555dd8e0a577668ed1495e8f6f5aa046f10cd9fd68",
    ),
    EVALUATION_EVIDENCE_KIND: (
        SCHEMA_ROOT / "non-ash-selector-evaluation-evidence-v2.schema.json",
        "4f6828cad18dc1b588b0e292d37f96ceb8769a9dd60de21d73b864931bbd4e3a",
    ),
    CONTROL_AUTHORIZATION_BUNDLE_KIND: (
        SCHEMA_ROOT / "p06-control-authorization-bundle-v2.schema.json",
        "9b6aa34dd923752fa12f4938a948a43665953b34fae23485e99a249ad5ff29a6",
    ),
}

_EXISTING_SCHEMA_SPECS = {
    VALIDATION_ADMISSION_KIND: (
        SCHEMA_ROOT / "validation-candidate-development-evidence-v2.schema.json",
        "8ba2c914ba2aa1619a6c6cc7e43f823102c79468b099778447e5e5c9d1981f3f",
    ),
    ATTEMPT_FAILURE_KIND: (
        SCHEMA_ROOT / "non-ash-selector-attempt-failure-v2.schema.json",
        "2add191fa95c8b2eca8c4ed3a79b77afa1b311a480b7d205c92d87afa33affb4",
    ),
    ATTEMPT_LEDGER_KIND: (
        SCHEMA_ROOT / "non-ash-selector-attempt-ledger-v2.schema.json",
        "3d2937faaeefbd97e17447554146fdfae6a041b328bdf13f4e7004c324d0bfe9",
    ),
    SELECTION_KIND: (
        SCHEMA_ROOT / "non-ash-selector-selection-v2.schema.json",
        "2c978578e6b7e27c285fe827c9519d4262a79da7040988021158a171ab82c1b8",
    ),
    NEIGHBOR_MANIFEST_KIND: (
        SCHEMA_ROOT / "non-ash-validation-neighbor-manifest-v2.schema.json",
        "f1da0ec50e475490cbadb92b949e42f3e8a8e104d36920e4d0cb6cf70fb525d2",
    ),
}

_AUTHORITY_SPECS = {
    "baseline_ablation_budget_v2": {
        "path": CONTRACT_ROOT / "baseline-ablation-budget-v2.json",
        "schema_path": SCHEMA_ROOT / "baseline-ablation-budget-v2.schema.json",
        "file_sha256": (
            "1885aa30b46f72ed1de0570a3de5f615cf788ec0d494ed5396731279763da4c8"
        ),
        "schema_file_sha256": (
            "080cc48a86569d68aecb0ca9384c89300df57dbeaa995e0651cf6082c969416b"
        ),
        "self_field": "artifact_sha256",
        "self_sha256": (
            "405d9ca4413e7e291315257682f206d951a081f052d5ecee6f3a36ac72cd22be"
        ),
    },
    "calibration_plan_v2": {
        "path": CONTRACT_ROOT / "calibration-plan-v2.json",
        "schema_path": SCHEMA_ROOT / "calibration-plan-v2.schema.json",
        "file_sha256": (
            "1977c85b9a3b7001294a04d33e7654ae20ffb4266ac0c8d2dc76880bdec99fef"
        ),
        "schema_file_sha256": (
            "09a21861104bd1b03667d1207a79d523386ad4431e710ba44e4d298180753c09"
        ),
        "self_field": "plan_sha256",
        "self_sha256": (
            "e6070a7cdd8f3b53231635027055669c8319d311af1790d672723d6e7e048d0f"
        ),
    },
    "candidate_evidence_policy_v2": {
        "path": CONTRACT_ROOT / "candidate-evidence-policy-v2.json",
        "schema_path": SCHEMA_ROOT / "candidate-evidence-policy-v2.schema.json",
        "file_sha256": (
            "d6df835467485f59b253e12d8e80cb8c8fa21dd308566ab3634495ccc8604433"
        ),
        "schema_file_sha256": (
            "581a3bb6ba0ec3ea288076685124a9e7fd332aa883ee2165f18a27a4fb1c249e"
        ),
        "self_field": "artifact_sha256",
        "self_sha256": (
            "70860c19f36efe41401e16381c80d6102b37f683056b2e3210a67e9d0b66dc75"
        ),
    },
    "compiler_contract_v2": {
        "path": CONTRACT_ROOT / "compiler-contract-v2.json",
        "schema_path": SCHEMA_ROOT / "compiler-contract-v2.schema.json",
        "file_sha256": (
            "8c2f532ff126fd5517040a05c9f8669d2a83d1d7220f61fed5933d5fa470470a"
        ),
        "schema_file_sha256": (
            "5f7a49e1f585e4f0e108e733ae3c6f28b47869b3cc2909419688714e76f57897"
        ),
        "self_field": "artifact_sha256",
        "self_sha256": (
            "797d6fda359a6bfaca9487a31b0078a5eba8e41fdb6fd0985390e20c25df8237"
        ),
    },
    "shared_bank_configuration_identity_v2": {
        "path": CONTRACT_ROOT / "shared-bank-configuration-identity-v2.json",
        "schema_path": (
            SCHEMA_ROOT / "shared-bank-configuration-identity-v2.schema.json"
        ),
        "file_sha256": (
            "48f5eef7cf9f7c513cf8e6568b3eeb4d607845c1e70e6c39b6ca0192a4c297de"
        ),
        "schema_file_sha256": (
            "0cee4c9ed9083d734491d90eaa3f02265b07295d7873733c006cce9df317147c"
        ),
        "self_field": "artifact_sha256",
        "self_sha256": (
            "e522afa73e8dc01c51303d1d1d99a95fe2ea78f968a2696dc0583f695fce7c37"
        ),
    },
}


class ControlAuthorizationV2Error(ValueError):
    """An authority, schema, snapshot byte, or control relation is invalid."""


def _is_sha256(value: object) -> bool:
    return (
        type(value) is str
        and len(value) == 64
        and value != _ZERO_SHA256
        and all(character in "0123456789abcdef" for character in value)
    )


def _sha256(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def _snapshot_json(value: object, *, label: str) -> object:
    active: set[int] = set()

    def visit(member: object, location: str) -> object:
        if member is None or type(member) in {str, bool, int}:
            return member
        if type(member) is float:
            if not math.isfinite(member):
                raise ControlAuthorizationV2Error(
                    f"{label} contains a nonfinite number at {location}"
                )
            return member
        if type(member) not in {dict, list}:
            raise ControlAuthorizationV2Error(
                f"{label} contains a non-JSON value at {location}"
            )
        identity = id(member)
        if identity in active:
            raise ControlAuthorizationV2Error(
                f"{label} contains a cycle at {location}"
            )
        active.add(identity)
        try:
            if type(member) is list:
                return [
                    visit(item, f"{location}/{index}")
                    for index, item in enumerate(member)
                ]
            result: Dict[str, object] = {}
            for key, item in member.items():
                if type(key) is not str:
                    raise ControlAuthorizationV2Error(
                        f"{label} contains a non-string key at {location}"
                    )
                result[key] = visit(item, f"{location}/{key}")
            return result
        finally:
            active.remove(identity)

    return visit(value, "<root>")


def canonical_json_bytes_v2(value: object) -> bytes:
    """Return strict sorted-key compact UTF-8 JSON without a final LF."""

    snapshot = _snapshot_json(value, label="canonical JSON input")
    try:
        return json.dumps(
            snapshot,
            ensure_ascii=False,
            allow_nan=False,
            sort_keys=True,
            separators=(",", ":"),
        ).encode("utf-8")
    except (TypeError, ValueError, UnicodeEncodeError) as error:
        raise ControlAuthorizationV2Error(
            "canonical JSON serialization failed"
        ) from error


def canonical_json_file_bytes_v2(document: Mapping[str, object]) -> bytes:
    if type(document) is not dict:
        raise ControlAuthorizationV2Error(
            "artifact serialization requires a built-in object"
        )
    return canonical_json_bytes_v2(document) + b"\n"


def _reject_duplicate_pairs(pairs: Sequence[Tuple[str, object]]) -> object:
    result: Dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise ControlAuthorizationV2Error(f"duplicate JSON key {key!r}")
        result[key] = value
    return result


def _reject_nonfinite(token: str) -> object:
    raise ControlAuthorizationV2Error(f"nonfinite JSON number {token!r}")


def _parse_json(payload: bytes, *, label: str) -> Dict[str, object]:
    if type(payload) is not bytes or not payload:
        raise ControlAuthorizationV2Error(f"{label} is not nonempty bytes")
    if payload.startswith(b"\xef\xbb\xbf"):
        raise ControlAuthorizationV2Error(f"{label} contains a UTF-8 BOM")
    try:
        value = json.loads(
            payload,
            object_pairs_hook=_reject_duplicate_pairs,
            parse_constant=_reject_nonfinite,
        )
    except ControlAuthorizationV2Error:
        raise
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ControlAuthorizationV2Error(
            f"{label} is not valid UTF-8 JSON"
        ) from error
    if type(value) is not dict:
        raise ControlAuthorizationV2Error(f"{label} is not a JSON object")
    return value


def _parse_canonical_file(payload: bytes, *, label: str) -> Dict[str, object]:
    if (
        not payload.endswith(b"\n")
        or payload.endswith(b"\n\n")
        or b"\r" in payload
    ):
        raise ControlAuthorizationV2Error(
            f"{label} must end with exactly one LF"
        )
    document = _parse_json(payload, label=label)
    if canonical_json_file_bytes_v2(document) != payload:
        raise ControlAuthorizationV2Error(
            f"{label} is not canonical compact JSON plus one LF"
        )
    return document


def _parse_canonical_compact(
    payload: bytes,
    *,
    label: str,
) -> Dict[str, object]:
    document = _parse_json(payload, label=label)
    if canonical_json_bytes_v2(document) != payload:
        raise ControlAuthorizationV2Error(
            f"{label} is not canonical compact JSON"
        )
    return document


def _parse_canonical_compact_or_file(
    payload: bytes,
    *,
    label: str,
) -> Dict[str, object]:
    if payload.endswith(b"\n"):
        return _parse_canonical_file(payload, label=label)
    return _parse_canonical_compact(payload, label=label)


def _read_regular_file(path: Path, *, label: str) -> bytes:
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        raise ControlAuthorizationV2Error(f"{label} cannot be opened") from error
    try:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode):
            raise ControlAuthorizationV2Error(f"{label} is not a regular file")
        chunks = []
        while True:
            chunk = os.read(descriptor, 1024 * 1024)
            if not chunk:
                break
            chunks.append(chunk)
        after = os.fstat(descriptor)
    finally:
        os.close(descriptor)
    payload = b"".join(chunks)
    if (
        (before.st_dev, before.st_ino) != (after.st_dev, after.st_ino)
        or before.st_size != after.st_size
        or before.st_mtime_ns != after.st_mtime_ns
        or before.st_ctime_ns != after.st_ctime_ns
        or len(payload) != after.st_size
    ):
        raise ControlAuthorizationV2Error(f"{label} changed while read")
    return payload


def _self_sha256(document: Mapping[str, object], *, field: str) -> str:
    snapshot = _snapshot_json(document, label=f"{field} input")
    if type(snapshot) is not dict:
        raise ControlAuthorizationV2Error(f"{field} input is not an object")
    snapshot.pop(field, None)
    return _sha256(canonical_json_bytes_v2(snapshot))


def finalize_artifact_sha256_v2(
    document: Mapping[str, object],
) -> Dict[str, object]:
    """Return a detached artifact with ``artifact_sha256`` recomputed."""

    snapshot = _snapshot_json(document, label="artifact finalization input")
    if type(snapshot) is not dict:
        raise ControlAuthorizationV2Error(
            "artifact finalization input is not an object"
        )
    snapshot["artifact_sha256"] = _self_sha256(
        snapshot,
        field="artifact_sha256",
    )
    return snapshot


def authority_bindings_v2() -> Dict[str, object]:
    """Return the exact five authenticated authority triples."""

    return {
        identifier: {
            "file_sha256": spec["file_sha256"],
            "schema_file_sha256": spec["schema_file_sha256"],
            "self_sha256": spec["self_sha256"],
        }
        for identifier, spec in sorted(_AUTHORITY_SPECS.items())
    }


def _authenticate_authorities(bindings: object) -> None:
    expected = authority_bindings_v2()
    if type(bindings) is not dict or bindings != expected:
        raise ControlAuthorizationV2Error(
            "authority bindings differ from the exact five-authority set"
        )
    for identifier, spec in _AUTHORITY_SPECS.items():
        contract_payload = _read_regular_file(
            spec["path"],
            label=f"authority {identifier}",
        )
        schema_payload = _read_regular_file(
            spec["schema_path"],
            label=f"authority schema {identifier}",
        )
        if (
            _sha256(contract_payload) != spec["file_sha256"]
            or _sha256(schema_payload) != spec["schema_file_sha256"]
        ):
            raise ControlAuthorizationV2Error(
                f"authority {identifier} byte identity differs"
            )
        contract = _parse_json(
            contract_payload,
            label=f"authority {identifier}",
        )
        if (
            contract.get(spec["self_field"]) != spec["self_sha256"]
            or _self_sha256(contract, field=spec["self_field"])
            != spec["self_sha256"]
        ):
            raise ControlAuthorizationV2Error(
                f"authority {identifier} self identity differs"
            )


def _load_schema(kind: str) -> Mapping[str, object]:
    spec = _SCHEMA_SPECS.get(kind) or _EXISTING_SCHEMA_SPECS.get(kind)
    if spec is None:
        raise ControlAuthorizationV2Error(
            f"artifact kind {kind!r} has no authenticated schema"
        )
    path, expected_sha256 = spec
    payload = _read_regular_file(path, label=f"schema {path.name}")
    if _sha256(payload) != expected_sha256:
        raise ControlAuthorizationV2Error(
            f"schema {path.name} byte identity differs"
        )
    schema = _parse_canonical_file(payload, label=f"schema {path.name}")
    try:
        Draft202012Validator.check_schema(schema)
    except Exception as error:
        raise ControlAuthorizationV2Error(
            f"schema {path.name} is invalid"
        ) from error
    return schema


def schema_sha256_for_kind_v2(kind: str) -> str:
    """Return the pinned schema digest for a supported typed artifact kind."""

    spec = _SCHEMA_SPECS.get(kind) or _EXISTING_SCHEMA_SPECS.get(kind)
    if spec is None:
        raise ControlAuthorizationV2Error(
            f"artifact kind {kind!r} has no authenticated schema"
        )
    return spec[1]


def _validate_schema(
    document: Mapping[str, object],
    *,
    kind: str,
    schema_cache: Dict[str, Mapping[str, object]],
) -> None:
    schema = schema_cache.get(kind)
    if schema is None:
        schema = _load_schema(kind)
        schema_cache[kind] = schema
    errors = sorted(
        Draft202012Validator(schema).iter_errors(document),
        key=lambda error: tuple(str(item) for item in error.absolute_path),
    )
    if errors:
        details = []
        for error in errors:
            location = "/".join(
                str(item) for item in error.absolute_path
            ) or "<root>"
            details.append(f"{location}: {error.message}")
        raise ControlAuthorizationV2Error(
            f"{kind} schema validation failed: " + "; ".join(details)
        )


def _verify_new_artifact(
    document: Mapping[str, object],
    *,
    expected_kind: str,
    schema_cache: Dict[str, Mapping[str, object]],
    authority_files_authenticated: bool = False,
) -> None:
    if type(document) is not dict or document.get("artifact_kind") != expected_kind:
        raise ControlAuthorizationV2Error(
            f"artifact kind differs from {expected_kind}"
        )
    _validate_schema(document, kind=expected_kind, schema_cache=schema_cache)
    if authority_files_authenticated:
        if document.get("authority_bindings") != authority_bindings_v2():
            raise ControlAuthorizationV2Error(
                "authority bindings differ from the exact five-authority set"
            )
    else:
        _authenticate_authorities(document.get("authority_bindings"))
    if document.get("artifact_sha256") != _self_sha256(
        document,
        field="artifact_sha256",
    ):
        raise ControlAuthorizationV2Error(
            f"{expected_kind} self identity differs"
        )


@dataclass(frozen=True)
class TypedArtifactBindingV2:
    """An exact immutable byte binding with a declared artifact schema."""

    artifact_kind: str
    schema_sha256: str
    path: str
    sha256: str
    size_bytes: int

    def __post_init__(self) -> None:
        if (
            type(self.artifact_kind) is not str
            or re.fullmatch(r"[a-z][a-z0-9_]*", self.artifact_kind) is None
            or not _is_sha256(self.schema_sha256)
            or type(self.path) is not str
            or _SAFE_PATH.fullmatch(self.path) is None
            or any(part in {"", ".", ".."} for part in self.path.split("/"))
            or not _is_sha256(self.sha256)
            or type(self.size_bytes) is not int
            or self.size_bytes < 1
        ):
            raise ControlAuthorizationV2Error(
                "typed artifact binding is invalid"
            )

    @classmethod
    def from_document(cls, value: object) -> "TypedArtifactBindingV2":
        if type(value) is not dict or set(value) != {
            "artifact_kind",
            "schema_sha256",
            "path",
            "sha256",
            "size_bytes",
        }:
            raise ControlAuthorizationV2Error(
                "typed artifact binding field set differs"
            )
        try:
            return cls(
                artifact_kind=value["artifact_kind"],
                schema_sha256=value["schema_sha256"],
                path=value["path"],
                sha256=value["sha256"],
                size_bytes=value["size_bytes"],
            )
        except (KeyError, ControlAuthorizationV2Error) as error:
            raise ControlAuthorizationV2Error(
                "typed artifact binding is invalid"
            ) from error

    def as_document(self) -> Dict[str, object]:
        return {
            "artifact_kind": self.artifact_kind,
            "schema_sha256": self.schema_sha256,
            "path": self.path,
            "sha256": self.sha256,
            "size_bytes": self.size_bytes,
        }

    def closure_binding(self) -> ClosureFileBindingV2:
        try:
            return ClosureFileBindingV2(
                self.path,
                self.sha256,
                self.size_bytes,
            )
        except AuthenticatedClosureSnapshotV2Error as error:
            raise ControlAuthorizationV2Error(
                "typed binding cannot identify closure bytes"
            ) from error


def _binding_sort_key(binding: TypedArtifactBindingV2) -> Tuple[object, ...]:
    return (
        binding.path,
        binding.artifact_kind,
        binding.schema_sha256,
        binding.sha256,
        binding.size_bytes,
    )


def dependency_set_sha256_v2(
    bindings: Sequence[TypedArtifactBindingV2],
) -> str:
    """Hash one sorted, unique, typed dependency closure."""

    if type(bindings) not in {list, tuple}:
        raise ControlAuthorizationV2Error(
            "dependency set is not a concrete sequence"
        )
    copied = tuple(bindings)
    if any(type(binding) is not TypedArtifactBindingV2 for binding in copied):
        raise ControlAuthorizationV2Error(
            "dependency set contains an invalid binding type"
        )
    ordered = tuple(sorted(copied, key=_binding_sort_key))
    if copied != ordered or len(set(ordered)) != len(ordered):
        raise ControlAuthorizationV2Error(
            "dependency set is not sorted and unique"
        )
    identity = [binding.as_document() for binding in ordered]
    prefix = DEPENDENCY_SET_HASH_DOMAIN_V2.encode("ascii") + b"\x00"
    return _sha256(prefix + canonical_json_bytes_v2(identity))


def control_authorization_semantic_sha256_v2(
    document: Mapping[str, object],
) -> str:
    """Hash every authorization member except the two self-hash fields."""

    snapshot = _snapshot_json(document, label="authorization semantic input")
    if type(snapshot) is not dict:
        raise ControlAuthorizationV2Error(
            "authorization semantic input is not an object"
        )
    snapshot.pop("authorization_semantic_sha256", None)
    snapshot.pop("artifact_sha256", None)
    prefix = CONTROL_AUTHORIZATION_HASH_DOMAIN_V2.encode("ascii") + b"\x00"
    return _sha256(prefix + canonical_json_bytes_v2(snapshot))


def finalize_control_authorization_bundle_v2(
    document: Mapping[str, object],
) -> Dict[str, object]:
    """Finalize dependency, semantic, and artifact hashes in dependency order."""

    snapshot = _snapshot_json(document, label="authorization finalization input")
    if type(snapshot) is not dict:
        raise ControlAuthorizationV2Error(
            "authorization finalization input is not an object"
        )
    raw_dependencies = snapshot.get("dependency_bindings")
    if type(raw_dependencies) is not list:
        raise ControlAuthorizationV2Error(
            "authorization dependency bindings are absent"
        )
    dependencies = [
        TypedArtifactBindingV2.from_document(value)
        for value in raw_dependencies
    ]
    snapshot["dependency_set_sha256"] = dependency_set_sha256_v2(dependencies)
    snapshot["authorization_semantic_sha256"] = (
        control_authorization_semantic_sha256_v2(snapshot)
    )
    return finalize_artifact_sha256_v2(snapshot)


@dataclass(frozen=True)
class ControlAuthorizationScopeV2:
    """Caller-derived scope against which one bundle is authorized."""

    run_id: str
    split: str
    shared_bank_configuration_sha256: str
    degradation_policy_sha256: str
    source_profile_matrix_sha256: str
    development_source_profile_matrix_sha256: Optional[str] = None
    validation_admission: Optional[TypedArtifactBindingV2] = None

    def __post_init__(self) -> None:
        if (
            type(self.run_id) is not str
            or not self.run_id
            or self.split not in {"development", "validation"}
            or not _is_sha256(self.shared_bank_configuration_sha256)
            or not _is_sha256(self.degradation_policy_sha256)
            or not _is_sha256(self.source_profile_matrix_sha256)
        ):
            raise ControlAuthorizationV2Error(
                "control authorization scope is invalid"
            )
        if self.split == "development":
            if (
                self.development_source_profile_matrix_sha256 is not None
                or self.validation_admission is not None
            ):
                raise ControlAuthorizationV2Error(
                    "development control scope contains validation predecessors"
                )
            return
        if (
            not _is_sha256(
                self.development_source_profile_matrix_sha256
            )
            or self.development_source_profile_matrix_sha256
            == self.source_profile_matrix_sha256
            or type(self.validation_admission) is not TypedArtifactBindingV2
            or self.validation_admission.artifact_kind
            != VALIDATION_ADMISSION_KIND
            or self.validation_admission.schema_sha256
            != schema_sha256_for_kind_v2(VALIDATION_ADMISSION_KIND)
        ):
            raise ControlAuthorizationV2Error(
                "validation control scope predecessors are invalid"
            )

    def development_scope(self) -> "ControlAuthorizationScopeV2":
        """Return the authenticated development scope for this bundle."""

        matrix = (
            self.source_profile_matrix_sha256
            if self.split == "development"
            else self.development_source_profile_matrix_sha256
        )
        if not _is_sha256(matrix):
            raise ControlAuthorizationV2Error(
                "development source/profile matrix is absent"
            )
        return ControlAuthorizationScopeV2(
            run_id=self.run_id,
            split="development",
            shared_bank_configuration_sha256=(
                self.shared_bank_configuration_sha256
            ),
            degradation_policy_sha256=self.degradation_policy_sha256,
            source_profile_matrix_sha256=matrix,
        )


@dataclass(frozen=True)
class VerifiedControlAuthorizationV2:
    """Detached result of complete bundle and dependency replay."""

    bundle_binding: TypedArtifactBindingV2
    document: Mapping[str, object]
    control_selection_bindings: Tuple[TypedArtifactBindingV2, ...]
    dependency_bindings: Tuple[TypedArtifactBindingV2, ...]
    dependency_set_sha256: str
    authorization_semantic_sha256: str


class _SnapshotResolverV2:
    def __init__(
        self,
        snapshot: AuthenticatedClosureSnapshotV2,
        declared: Sequence[TypedArtifactBindingV2],
    ) -> None:
        if type(snapshot) is not AuthenticatedClosureSnapshotV2:
            raise ControlAuthorizationV2Error(
                "evidence snapshot has the wrong type"
            )
        self.snapshot = snapshot
        self.declared = tuple(declared)
        if self.declared != tuple(
            sorted(self.declared, key=_binding_sort_key)
        ):
            raise ControlAuthorizationV2Error(
                "declared dependency bindings are not sorted"
            )
        paths = [binding.path for binding in self.declared]
        digests = [binding.sha256 for binding in self.declared]
        if (
            len(paths) != len(set(paths))
            or len(digests) != len(set(digests))
            or len(self.declared) != len(set(self.declared))
        ):
            raise ControlAuthorizationV2Error(
                "declared dependency binding identities repeat"
            )
        self.by_path = {binding.path: binding for binding in self.declared}
        self.by_digest = {binding.sha256: binding for binding in self.declared}
        self.expected: set[TypedArtifactBindingV2] = set()

    def require_binding(
        self,
        binding: TypedArtifactBindingV2,
        *,
        expected_kind: Optional[str] = None,
        expected_schema_sha256: Optional[str] = None,
    ) -> bytes:
        if type(binding) is not TypedArtifactBindingV2:
            raise ControlAuthorizationV2Error("required binding has wrong type")
        if expected_kind is not None and binding.artifact_kind != expected_kind:
            raise ControlAuthorizationV2Error(
                f"binding kind differs from {expected_kind}"
            )
        if (
            expected_schema_sha256 is not None
            and binding.schema_sha256 != expected_schema_sha256
        ):
            raise ControlAuthorizationV2Error(
                f"binding schema differs for {binding.artifact_kind}"
            )
        if self.by_path.get(binding.path) != binding:
            raise ControlAuthorizationV2Error(
                "required binding is absent from the declared dependency set"
            )
        self.expected.add(binding)
        try:
            return self.snapshot.payload(binding.closure_binding())
        except AuthenticatedClosureSnapshotV2Error as error:
            raise ControlAuthorizationV2Error(
                f"snapshot bytes differ for {binding.path}"
            ) from error

    def require_digest(
        self,
        digest: object,
        *,
        expected_kind: Optional[str] = None,
        expected_schema_sha256: Optional[str] = None,
    ) -> Tuple[TypedArtifactBindingV2, bytes]:
        if not _is_sha256(digest):
            raise ControlAuthorizationV2Error("dependency digest is invalid")
        binding = self.by_digest.get(digest)
        if binding is None:
            raise ControlAuthorizationV2Error(
                f"dependency {digest} is omitted"
            )
        return (
            binding,
            self.require_binding(
                binding,
                expected_kind=expected_kind,
                expected_schema_sha256=expected_schema_sha256,
            ),
        )

    def finish(self) -> None:
        actual = set(self.declared)
        if self.expected != actual:
            omitted = sorted(
                binding.path for binding in self.expected - actual
            )
            extra = sorted(binding.path for binding in actual - self.expected)
            raise ControlAuthorizationV2Error(
                "transitive dependency closure differs "
                f"(missing={omitted}, extra={extra})"
            )


def _finite_number(value: object, *, label: str) -> float:
    if type(value) not in {int, float} or not math.isfinite(value):
        raise ControlAuthorizationV2Error(f"{label} is not finite")
    return float(value)


def _objective_tuple(value: object, *, label: str) -> Tuple[float, ...]:
    if type(value) is not list or len(value) != len(SELECTION_METRICS):
        raise ControlAuthorizationV2Error(
            f"{label} is not an exact five-member array"
        )
    return tuple(
        _finite_number(member, label=f"{label}/{index}")
        for index, member in enumerate(value)
    )


def _typed_binding(value: object) -> TypedArtifactBindingV2:
    return TypedArtifactBindingV2.from_document(value)


def _source_profile_identity(row: Mapping[str, object]) -> Dict[str, object]:
    fields = (
        "source_asset_id",
        "source_family_id",
        "categories",
        "target_route",
        "degradation_profile_id",
        "degradation_profile_sha256",
        "source_target_provenance",
        "degradation_profile",
    )
    return {field: row[field] for field in fields}


class ControlAuthorizationVerifierV2:
    """Authenticate and replay one isolated P06 control authorization bundle."""

    def __init__(
        self,
        *,
        control_execution_semantic_verifier: Optional[
            Callable[
                [
                    TypedArtifactBindingV2,
                    Mapping[str, object],
                    ControlExecutionSemanticContextV2,
                ],
                Mapping[str, object],
            ]
        ] = None,
        control_writer_semantic_verifier: Optional[
            Callable[
                [
                    TypedArtifactBindingV2,
                    Mapping[str, object],
                    ControlWriterSemanticContextV2,
                ],
                Mapping[str, object],
            ]
        ] = None,
        control_execution_producer_identity: Optional[
            ControlExecutionProducerIdentityV2
        ] = None,
        control_writer_producer_identity: Optional[
            ControlWriterProducerIdentityV2
        ] = None,
    ) -> None:
        self._schema_cache: Dict[str, Mapping[str, object]] = {}
        self._authority_files_authenticated = False
        self._control_execution_semantic_verifier = (
            control_execution_semantic_verifier
        )
        self._control_writer_semantic_verifier = (
            control_writer_semantic_verifier
        )
        self._control_execution_producer_identity = (
            control_execution_producer_identity
        )
        self._control_writer_producer_identity = (
            control_writer_producer_identity
        )

    def _authenticate_control_execution(
        self,
        binding: TypedArtifactBindingV2,
        document: Mapping[str, object],
        context: ControlExecutionSemanticContextV2,
    ) -> None:
        verifier = self._control_execution_semantic_verifier
        if not callable(verifier):
            raise ControlAuthorizationV2Error(
                "trusted control execution semantic verifier is absent"
            )
        expected = _snapshot_json(
            document,
            label="control execution provenance",
        )
        try:
            reopened = verifier(binding, expected, context)
        except Exception as exc:
            raise ControlAuthorizationV2Error(
                "control execution provenance authentication failed"
            ) from exc
        if _snapshot_json(
            reopened,
            label="authenticated control execution provenance",
        ) != expected:
            raise ControlAuthorizationV2Error(
                "control execution semantic replay returned different evidence"
            )

    def _authenticate_control_writer(
        self,
        binding: TypedArtifactBindingV2,
        document: Mapping[str, object],
        context: ControlWriterSemanticContextV2,
    ) -> None:
        verifier = self._control_writer_semantic_verifier
        if not callable(verifier):
            raise ControlAuthorizationV2Error(
                "trusted control writer semantic verifier is absent"
            )
        expected = _snapshot_json(
            document,
            label="control writer provenance",
        )
        try:
            reopened = verifier(binding, expected, context)
        except Exception as exc:
            raise ControlAuthorizationV2Error(
                "control writer provenance authentication failed"
            ) from exc
        if _snapshot_json(
            reopened,
            label="authenticated control writer provenance",
        ) != expected:
            raise ControlAuthorizationV2Error(
                "control writer semantic replay returned different evidence"
            )

    def _new_document(
        self,
        binding: TypedArtifactBindingV2,
        resolver: _SnapshotResolverV2,
        *,
        expected_kind: str,
    ) -> Dict[str, object]:
        payload = resolver.require_binding(
            binding,
            expected_kind=expected_kind,
            expected_schema_sha256=schema_sha256_for_kind_v2(expected_kind),
        )
        document = _parse_canonical_file(
            payload,
            label=f"{expected_kind} {binding.path}",
        )
        _verify_new_artifact(
            document,
            expected_kind=expected_kind,
            schema_cache=self._schema_cache,
            authority_files_authenticated=self._authority_files_authenticated,
        )
        self._authority_files_authenticated = True
        return document

    def _aggregate_from_bindings(
        self,
        *,
        objective_binding: TypedArtifactBindingV2,
        output_binding: TypedArtifactBindingV2,
        resolver: _SnapshotResolverV2,
        scope: ControlAuthorizationScopeV2,
        expected_family: str,
        expected_split: str,
        expected_stable_id: object,
        expected_control_configuration_sha256: str,
        expected_control_request: Mapping[str, object],
    ) -> Tuple[float, ...]:
        summary = self._new_document(
            objective_binding,
            resolver,
            expected_kind=OBJECTIVE_SUMMARY_KIND,
        )
        manifest = self._new_document(
            output_binding,
            resolver,
            expected_kind=OUTPUT_MANIFEST_KIND,
        )
        common = {
            "run_id": scope.run_id,
            "split": expected_split,
            "control_family": expected_family,
            "stable_id": expected_stable_id,
            "shared_bank_configuration_sha256": (
                scope.shared_bank_configuration_sha256
            ),
            "degradation_policy_sha256": scope.degradation_policy_sha256,
            "control_configuration_sha256": (
                expected_control_configuration_sha256
            ),
            "source_profile_matrix_sha256": (
                scope.source_profile_matrix_sha256
            ),
        }
        for field, expected in common.items():
            if summary.get(field) != expected or manifest.get(field) != expected:
                raise ControlAuthorizationV2Error(
                    f"aggregate {field} differs for {expected_family}"
                )

        matrix = manifest.get("source_profile_matrix")
        if type(matrix) is not list or not matrix:
            raise ControlAuthorizationV2Error(
                "control output manifest source/profile matrix is empty"
            )
        if _sha256(canonical_json_bytes_v2(matrix)) != (
            scope.source_profile_matrix_sha256
        ):
            raise ControlAuthorizationV2Error(
                "control source/profile matrix identity differs"
            )
        identities = []
        pairs = []
        portable_pairs = []
        profile_count_by_source: Dict[str, int] = {}
        source_provenance_by_index: Dict[int, TypedArtifactBindingV2] = {}
        source_provenance_payload_by_index: Dict[int, bytes] = {}
        source_target_by_index: Dict[int, TypedArtifactBindingV2] = {}
        source_target_payload_by_index: Dict[int, bytes] = {}
        source_target_sha256_by_index: Dict[int, str] = {}
        profile_binding_by_index: Dict[int, TypedArtifactBindingV2] = {}
        profile_payload_by_index: Dict[int, bytes] = {}
        source_identity_by_id: Dict[str, Tuple[object, ...]] = {}
        for index, identity in enumerate(matrix):
            if type(identity) is not dict or set(identity) != {
                "source_asset_id",
                "source_family_id",
                "categories",
                "target_route",
                "degradation_profile_id",
                "degradation_profile_sha256",
                "source_target_provenance",
                "degradation_profile",
            }:
                raise ControlAuthorizationV2Error(
                    f"source/profile identity {index} field set differs"
                )
            source_id = identity["source_asset_id"]
            family_id = identity["source_family_id"]
            categories = identity["categories"]
            route = identity["target_route"]
            profile_id = identity["degradation_profile_id"]
            if (
                type(source_id) is not str
                or not source_id
                or type(family_id) is not str
                or not family_id
                or type(categories) is not list
                or not categories
                or any(type(category) is not str or not category for category in categories)
                or len(categories) != len(set(categories))
                or route not in {"direct-2x", "direct-3over2"}
                or type(profile_id) is not str
                or not profile_id
                or not _is_sha256(identity["degradation_profile_sha256"])
            ):
                raise ControlAuthorizationV2Error(
                    f"source/profile identity {index} is invalid"
                )
            source_provenance = _typed_binding(
                identity.get("source_target_provenance")
            )
            source_payload = resolver.require_binding(
                source_provenance,
                expected_kind=CONTROL_SOURCE_TARGET_PROVENANCE_KIND,
                expected_schema_sha256=schema_sha256_for_kind_v2(
                    OUTPUT_MANIFEST_KIND
                ),
            )
            source_record = _parse_canonical_compact(
                source_payload,
                label=f"source-target provenance {index}",
            )
            if set(source_record) != {
                "schema_version",
                "artifact_kind",
                "source_asset_id",
                "source_family_id",
                "categories",
                "target_route",
                "target_frame",
                "target_frame_sha256",
            }:
                raise ControlAuthorizationV2Error(
                    f"source-target provenance {index} field set differs"
                )
            target_binding = _typed_binding(source_record.get("target_frame"))
            target_payload = resolver.require_binding(
                target_binding,
                expected_kind=CONTROL_TARGET_FRAME_BYTES_KIND,
                expected_schema_sha256=schema_sha256_for_kind_v2(
                    OUTPUT_MANIFEST_KIND
                ),
            )
            try:
                source_target_frame = (
                    decode_control_measurement_frame_bytes_v2(target_payload)
                )
            except ProductionEvaluatorError as exc:
                raise ControlAuthorizationV2Error(
                    f"source-target provenance {index} frame is invalid"
                ) from exc
            expected_source_record = {
                "schema_version": "2.0.0",
                "artifact_kind": CONTROL_SOURCE_TARGET_PROVENANCE_KIND,
                "source_asset_id": source_id,
                "source_family_id": family_id,
                "categories": categories,
                "target_route": route,
                "target_frame": target_binding.as_document(),
                "target_frame_sha256": frame_sha256(source_target_frame),
            }
            if source_record != expected_source_record:
                raise ControlAuthorizationV2Error(
                    f"source-target provenance {index} differs"
                )
            profile_binding = _typed_binding(
                identity.get("degradation_profile")
            )
            profile_payload = resolver.require_binding(
                profile_binding,
                expected_kind=CONTROL_DEGRADATION_PROFILE_KIND,
                expected_schema_sha256=schema_sha256_for_kind_v2(
                    OUTPUT_MANIFEST_KIND
                ),
            )
            profile_record = _parse_canonical_compact(
                profile_payload,
                label=f"degradation profile {index}",
            )
            if (
                set(profile_record) != {
                    "schema_version",
                    "artifact_kind",
                    "degradation_policy_sha256",
                    "degradation_profile_id",
                    "profile_definition",
                }
                or profile_record.get("schema_version") != "2.0.0"
                or profile_record.get("artifact_kind")
                != CONTROL_DEGRADATION_PROFILE_KIND
                or profile_record.get("degradation_policy_sha256")
                != scope.degradation_policy_sha256
                or profile_record.get("degradation_profile_id") != profile_id
                or type(profile_record.get("profile_definition")) is not dict
                or not profile_record["profile_definition"]
                or profile_record["profile_definition"].get("id")
                != profile_id
                or profile_record["profile_definition"].get("target_route")
                != route
                or _sha256(
                    canonical_json_bytes_v2(
                        profile_record["profile_definition"]
                    )
                )
                != identity["degradation_profile_sha256"]
            ):
                raise ControlAuthorizationV2Error(
                    f"degradation profile {index} differs from locked scope"
                )
            source_identity = (
                family_id,
                canonical_json_bytes_v2(categories),
                route,
                source_provenance,
                target_binding,
            )
            if (
                source_id in source_identity_by_id
                and source_identity_by_id[source_id] != source_identity
            ):
                raise ControlAuthorizationV2Error(
                    "source-target provenance changes across profiles"
                )
            source_identity_by_id[source_id] = source_identity
            source_provenance_by_index[index] = source_provenance
            source_provenance_payload_by_index[index] = source_payload
            source_target_by_index[index] = target_binding
            source_target_payload_by_index[index] = target_payload
            source_target_sha256_by_index[index] = frame_sha256(
                source_target_frame
            )
            profile_binding_by_index[index] = profile_binding
            profile_payload_by_index[index] = profile_payload
            pair = (source_id, profile_id)
            portable_pair = (source_id.casefold(), profile_id.casefold())
            pairs.append(pair)
            portable_pairs.append(portable_pair)
            profile_count_by_source[source_id] = (
                profile_count_by_source.get(source_id, 0) + 1
            )
            identities.append(_snapshot_json(identity, label="matrix identity"))
        if (
            len(pairs) != len(set(pairs))
            or len(portable_pairs) != len(set(portable_pairs))
            or any(count != 3 for count in profile_count_by_source.values())
            or {identity["target_route"] for identity in matrix}
            != {"direct-2x", "direct-3over2"}
        ):
            raise ControlAuthorizationV2Error(
                "control source/profile matrix coverage differs"
            )
        source_order = list(dict.fromkeys(pair[0] for pair in pairs))
        if manifest.get("source_order") != source_order:
            raise ControlAuthorizationV2Error(
                "control output manifest source order differs"
            )
        comparison_domains = manifest.get("comparison_domains")
        if comparison_domains not in (
            ["engine_raw"],
            ["engine_raw", "container_decoded"],
        ):
            raise ControlAuthorizationV2Error(
                "control output manifest domain order differs"
            )
        producer_identity = self._control_execution_producer_identity
        if type(producer_identity) is not ControlExecutionProducerIdentityV2:
            raise ControlAuthorizationV2Error(
                "authenticated control execution producer identity is absent"
            )
        expected_adapter_identity = _parse_canonical_compact(
            producer_identity.authenticated_adapter_identity_bytes,
            label="authenticated adapter identity",
        )
        if (
            set(expected_adapter_identity) != {
                "adapter_configuration_sha256",
                "native_source_manifest_sha256",
                "native_executable_sha256",
                "native_implementation_source_sha256",
            }
            or expected_adapter_identity.get(
                "adapter_configuration_sha256"
            )
            != producer_identity.adapter_configuration_sha256
            or any(
                not _is_sha256(expected_adapter_identity.get(field))
                for field in expected_adapter_identity
            )
        ):
            raise ControlAuthorizationV2Error(
                "authenticated control execution producer identity differs"
            )
        writer_producer_identity = self._control_writer_producer_identity
        expected_writer_settings: Optional[Mapping[str, object]] = None
        expected_writer_identity: Optional[Mapping[str, object]] = None
        if comparison_domains == ["engine_raw", "container_decoded"]:
            if type(writer_producer_identity) is not ControlWriterProducerIdentityV2:
                raise ControlAuthorizationV2Error(
                    "authenticated control writer producer identity is absent"
                )
            expected_writer_settings = _parse_canonical_compact(
                writer_producer_identity.writer_settings_bytes,
                label="authenticated writer settings",
            )
            expected_writer_identity = _parse_canonical_compact(
                writer_producer_identity.authenticated_writer_identity_bytes,
                label="authenticated writer identity",
            )
            if (
                not expected_writer_settings
                or _sha256(
                    canonical_json_bytes_v2(expected_writer_settings)
                )
                != writer_producer_identity.writer_settings_sha256
                or set(expected_writer_identity) != {
                    "writer_executable_sha256",
                    "writer_settings_source_sha256",
                    "writer_source_manifest_sha256",
                    "writer_implementation_source_sha256",
                }
                or any(
                    not _is_sha256(expected_writer_identity.get(field))
                    for field in expected_writer_identity
                )
            ):
                raise ControlAuthorizationV2Error(
                    "authenticated control writer producer identity differs"
                )

        rows = manifest.get("rows")
        expected_row_count = len(matrix) * len(comparison_domains)
        if type(rows) is not list or len(rows) != expected_row_count:
            raise ControlAuthorizationV2Error(
                "control output rows do not cover their declared domains"
            )
        raw_rows: list[Mapping[str, object]] = []
        row_output_bindings: list[TypedArtifactBindingV2] = []
        writer_evidence_bindings: list[TypedArtifactBindingV2] = []
        writer_encoded_bindings: list[TypedArtifactBindingV2] = []
        writer_report_bindings: list[TypedArtifactBindingV2] = []
        writer_decoded_payload_bindings: list[TypedArtifactBindingV2] = []
        raw_target_bindings: Dict[int, TypedArtifactBindingV2] = {}
        raw_target_frame_sha256: Dict[int, str] = {}
        raw_y_psnr_db: Dict[int, float] = {}
        raw_input_bindings: Dict[int, TypedArtifactBindingV2] = {}
        raw_execution_bindings: Dict[int, TypedArtifactBindingV2] = {}
        raw_output_bindings: Dict[int, TypedArtifactBindingV2] = {}
        raw_output_payloads: Dict[int, bytes] = {}
        raw_output_frame_sha256: Dict[int, str] = {}
        semantic_scope_bytes = canonical_json_bytes_v2(
            {
                "run_id": scope.run_id,
                "split": expected_split,
                "shared_bank_configuration_sha256": (
                    scope.shared_bank_configuration_sha256
                ),
                "degradation_policy_sha256": (
                    scope.degradation_policy_sha256
                ),
                "source_profile_matrix_sha256": (
                    scope.source_profile_matrix_sha256
                ),
                "control_family": expected_family,
                "stable_id": expected_stable_id,
                "control_configuration_sha256": (
                    expected_control_configuration_sha256
                ),
            }
        )
        expected_control_request_bytes = canonical_json_bytes_v2(
            expected_control_request
        )
        for row_index, row in enumerate(rows):
            if type(row) is not dict:
                raise ControlAuthorizationV2Error(
                    f"control row {row_index} is not an object"
                )
            domain_index = row_index // len(matrix)
            identity_index = row_index % len(matrix)
            expected_domain = comparison_domains[domain_index]
            if (
                row.get("comparison_domain") != expected_domain
                or _source_profile_identity(row) != identities[identity_index]
                or row.get("degradation_policy_sha256")
                != scope.degradation_policy_sha256
                or row.get("control_configuration_sha256")
                != expected_control_configuration_sha256
                or row.get("shared_bank_configuration_sha256")
                != scope.shared_bank_configuration_sha256
            ):
                raise ControlAuthorizationV2Error(
                    f"control row {row_index} scope or order differs"
                )
            measurement = row.get("measurement_evidence")
            if (
                type(measurement) is not dict
                or measurement.get("artifact_kind")
                != CONTROL_MEASUREMENT_EVIDENCE_KIND
                or measurement.get("metric_algorithm")
                != CONTROL_METRIC_ALGORITHM
                or measurement.get("frame_encoding")
                != CONTROL_MEASUREMENT_FRAME_ENCODING_V2
                or measurement.get("source_profile_identity_sha256")
                != _sha256(
                    canonical_json_bytes_v2(identities[identity_index])
                )
            ):
                raise ControlAuthorizationV2Error(
                    f"control row {row_index} measurement scope differs"
                )
            metrics = measurement.get("metrics")
            if type(metrics) is not dict or set(metrics) != METRIC_FIELDS:
                raise ControlAuthorizationV2Error(
                    f"control row {row_index} metric field set differs"
                )
            for name in METRIC_FIELDS - {"writer_y_psnr_contribution_db"}:
                _finite_number(metrics[name], label=f"row {row_index}/{name}")
            contribution = metrics["writer_y_psnr_contribution_db"]
            source_provenance = _typed_binding(
                measurement.get("source_target_provenance")
            )
            profile_binding = _typed_binding(
                measurement.get("degradation_profile")
            )
            if (
                source_provenance
                != source_provenance_by_index[identity_index]
                or profile_binding != profile_binding_by_index[identity_index]
            ):
                raise ControlAuthorizationV2Error(
                    f"control row {row_index} provenance binding differs"
                )
            target = _typed_binding(measurement.get("target"))
            target_payload = resolver.require_binding(
                target,
                expected_kind=CONTROL_TARGET_FRAME_BYTES_KIND,
                expected_schema_sha256=schema_sha256_for_kind_v2(
                    OUTPUT_MANIFEST_KIND
                ),
            )
            output = _typed_binding(measurement.get("output"))
            row_output_bindings.append(output)
            output_payload = resolver.require_binding(
                output,
                expected_kind=CONTROL_OUTPUT_BYTES_KIND,
                expected_schema_sha256=schema_sha256_for_kind_v2(
                    OUTPUT_MANIFEST_KIND
                ),
            )
            input_binding = _typed_binding(
                measurement.get("low_resolution_input")
            )
            input_payload = resolver.require_binding(
                input_binding,
                expected_kind=CONTROL_LOW_RESOLUTION_INPUT_BYTES_KIND,
                expected_schema_sha256=schema_sha256_for_kind_v2(
                    OUTPUT_MANIFEST_KIND
                ),
            )
            try:
                target_frame = decode_control_measurement_frame_bytes_v2(
                    target_payload
                )
                output_frame = decode_control_measurement_frame_bytes_v2(
                    output_payload
                )
                input_frame = decode_control_measurement_frame_bytes_v2(
                    input_payload
                )
            except ProductionEvaluatorError as exc:
                raise ControlAuthorizationV2Error(
                    f"control row {row_index} frame evidence is invalid"
                ) from exc
            if (
                target_frame.y.shape != output_frame.y.shape
                or target_frame.cb.shape != output_frame.cb.shape
                or target_frame.cr.shape != output_frame.cr.shape
                or measurement.get("target_frame_sha256")
                != frame_sha256(target_frame)
                or measurement.get("output_frame_sha256")
                != frame_sha256(output_frame)
                or measurement.get("input_frame_sha256")
                != frame_sha256(input_frame)
                or target != source_target_by_index[identity_index]
                or frame_sha256(target_frame)
                != source_target_sha256_by_index[identity_index]
            ):
                raise ControlAuthorizationV2Error(
                    f"control row {row_index} frame identity or geometry differs"
                )
            execution_binding = _typed_binding(
                measurement.get("control_execution")
            )
            execution_payload = resolver.require_binding(
                execution_binding,
                expected_kind=CONTROL_EXECUTION_PROVENANCE_KIND,
                expected_schema_sha256=schema_sha256_for_kind_v2(
                    OUTPUT_MANIFEST_KIND
                ),
            )
            execution = _parse_canonical_compact(
                execution_payload,
                label=f"control execution provenance {row_index}",
            )
            execution_output = (
                output
                if expected_domain == "engine_raw"
                else raw_output_bindings.get(identity_index)
            )
            expected_execution_output_frame_sha256 = (
                frame_sha256(output_frame)
                if expected_domain == "engine_raw"
                else raw_output_frame_sha256.get(identity_index)
            )
            adapter_identity = execution.get("authenticated_adapter_identity")
            native_record = execution.get("native_execution_record")
            if (
                execution_output is None
                or set(execution) != {
                    "schema_version",
                    "artifact_kind",
                    "source_profile_identity_sha256",
                    "source_target_provenance",
                    "degradation_profile",
                    "low_resolution_input",
                    "input_frame_sha256",
                    "control_request",
                    "output",
                    "output_frame_sha256",
                    "authenticated_adapter_identity",
                    "native_execution_record",
                }
                or execution.get("schema_version") != "2.0.0"
                or execution.get("artifact_kind")
                != CONTROL_EXECUTION_PROVENANCE_KIND
                or execution.get("source_profile_identity_sha256")
                != measurement["source_profile_identity_sha256"]
                or execution.get("source_target_provenance")
                != source_provenance.as_document()
                or execution.get("degradation_profile")
                != profile_binding.as_document()
                or execution.get("low_resolution_input")
                != input_binding.as_document()
                or execution.get("input_frame_sha256")
                != frame_sha256(input_frame)
                or execution.get("control_request")
                != dict(expected_control_request)
                or execution.get("output") != execution_output.as_document()
                or execution.get("output_frame_sha256")
                != expected_execution_output_frame_sha256
                or type(adapter_identity) is not dict
                or set(adapter_identity) != {
                    "adapter_configuration_sha256",
                    "native_source_manifest_sha256",
                    "native_executable_sha256",
                    "native_implementation_source_sha256",
                }
                or any(
                    not _is_sha256(adapter_identity.get(field))
                    for field in adapter_identity
                )
                or adapter_identity != expected_adapter_identity
                or type(native_record) is not dict
            ):
                raise ControlAuthorizationV2Error(
                    f"control execution provenance {row_index} differs"
                )
            native_unhashed = dict(native_record)
            native_declared = native_unhashed.pop("record_sha256", None)
            if (
                execution.get("output_frame_sha256")
                != native_record.get("output_frame_sha256")
                or native_record.get("control_key")
                != expected_control_request.get("control_key")
                or native_record.get("control_mode")
                != expected_control_request.get("control_mode")
                or native_record.get("request_sha256")
                != expected_control_request.get("request_sha256")
                or native_record.get("configuration_sha256")
                != expected_control_configuration_sha256
                or native_record.get("shared_bank_configuration_sha256")
                != scope.shared_bank_configuration_sha256
                or native_record.get("input_frame_sha256")
                != frame_sha256(input_frame)
                or native_record.get("target_route")
                != row.get("target_route")
                or native_record.get("parameters")
                != expected_control_request.get("parameters")
                or native_record.get("parameters_sha256")
                != _sha256(
                    canonical_json_bytes_v2(
                        expected_control_request.get("parameters")
                    )
                )
                or native_declared
                != _sha256(canonical_json_bytes_v2(native_unhashed))
            ):
                raise ControlAuthorizationV2Error(
                    f"native control execution record {row_index} differs"
                )
            if expected_domain == "engine_raw":
                self._authenticate_control_execution(
                    execution_binding,
                    execution,
                    ControlExecutionSemanticContextV2(
                        expected_scope_bytes=semantic_scope_bytes,
                        expected_control_request_bytes=(
                            expected_control_request_bytes
                        ),
                        source_profile_identity_bytes=(
                            canonical_json_bytes_v2(
                                identities[identity_index]
                            )
                        ),
                        source_target_provenance_bytes=(
                            source_provenance_payload_by_index[
                                identity_index
                            ]
                        ),
                        source_target_frame_bytes=(
                            source_target_payload_by_index[identity_index]
                        ),
                        degradation_profile_bytes=(
                            profile_payload_by_index[identity_index]
                        ),
                        low_resolution_input_frame_bytes=input_payload,
                        raw_output_frame_bytes=output_payload,
                        physical_candidate_items_bytes=(
                            producer_identity.physical_candidate_items_bytes
                        ),
                        candidate_vector_sha256=(
                            producer_identity.candidate_vector_sha256
                        ),
                        adapter_configuration_sha256=(
                            producer_identity.adapter_configuration_sha256
                        ),
                        authenticated_adapter_identity_bytes=(
                            producer_identity.authenticated_adapter_identity_bytes
                        ),
                    ),
                )
            try:
                recomputed = dict(
                    corpus_metric_bundle(target_frame, output_frame)
                )
            except (ProductionEvaluatorError, ValueError) as exc:
                raise ControlAuthorizationV2Error(
                    f"control row {row_index} metric recomputation failed"
                ) from exc
            if expected_domain == "engine_raw":
                if (
                    contribution is not None
                    or measurement.get("writer_evidence") is not None
                ):
                    raise ControlAuthorizationV2Error(
                        "engine-raw row contains writer-only evidence"
                    )
                raw_target_bindings[identity_index] = target
                raw_target_frame_sha256[identity_index] = frame_sha256(
                    target_frame
                )
                raw_y_psnr_db[identity_index] = _finite_number(
                    recomputed["y_psnr_db"],
                    label=f"row {row_index}/recomputed-y-psnr",
                )
                raw_input_bindings[identity_index] = input_binding
                raw_execution_bindings[identity_index] = execution_binding
                raw_output_bindings[identity_index] = output
                raw_output_payloads[identity_index] = output_payload
                raw_output_frame_sha256[identity_index] = frame_sha256(
                    output_frame
                )
            else:
                _finite_number(
                    contribution,
                    label=f"row {row_index}/writer_y_psnr_contribution_db",
                )
                if (
                    target != raw_target_bindings.get(identity_index)
                    or frame_sha256(target_frame)
                    != raw_target_frame_sha256.get(identity_index)
                    or input_binding
                    != raw_input_bindings.get(identity_index)
                    or execution_binding
                    != raw_execution_bindings.get(identity_index)
                ):
                    raise ControlAuthorizationV2Error(
                        "container-decoded row substitutes its raw target"
                    )
                recomputed["writer_y_psnr_contribution_db"] = (
                    _finite_number(
                        recomputed["y_psnr_db"],
                        label=f"row {row_index}/decoded-y-psnr",
                    )
                    - raw_y_psnr_db[identity_index]
                )
                writer = _typed_binding(measurement.get("writer_evidence"))
                writer_evidence_bindings.append(writer)
                writer_payload = resolver.require_binding(
                    writer,
                    expected_kind=CONTROL_WRITER_EVIDENCE_BYTES_KIND,
                    expected_schema_sha256=schema_sha256_for_kind_v2(
                        OUTPUT_MANIFEST_KIND
                    ),
                )
                writer_document = _parse_canonical_compact(
                    writer_payload,
                    label=f"control writer provenance {row_index}",
                )
                encoded_container = _typed_binding(
                    writer_document.get("encoded_container")
                )
                encoded_container_payload = resolver.require_binding(
                    encoded_container,
                    expected_kind=(
                        CONTROL_WRITER_ENCODED_CONTAINER_BYTES_KIND
                    ),
                    expected_schema_sha256=schema_sha256_for_kind_v2(
                        OUTPUT_MANIFEST_KIND
                    ),
                )
                writer_encoded_bindings.append(encoded_container)
                writer_report = _typed_binding(
                    writer_document.get("writer_report")
                )
                writer_report_payload = resolver.require_binding(
                    writer_report,
                    expected_kind=CONTROL_WRITER_REPORT_BYTES_KIND,
                    expected_schema_sha256=schema_sha256_for_kind_v2(
                        OUTPUT_MANIFEST_KIND
                    ),
                )
                writer_report_bindings.append(writer_report)
                decoded_payload = _typed_binding(
                    writer_document.get("decoded_payload")
                )
                decoded_payload_bytes = resolver.require_binding(
                    decoded_payload,
                    expected_kind=(
                        CONTROL_WRITER_DECODED_PAYLOAD_BYTES_KIND
                    ),
                    expected_schema_sha256=schema_sha256_for_kind_v2(
                        OUTPUT_MANIFEST_KIND
                    ),
                )
                writer_decoded_payload_bindings.append(decoded_payload)
                writer_settings = writer_document.get("writer_settings")
                writer_identity = writer_document.get(
                    "authenticated_writer_identity"
                )
                native_writer_record = writer_document.get(
                    "native_writer_round_trip_record"
                )
                if (
                    set(writer_document) != {
                        "schema_version",
                        "artifact_kind",
                        "source_profile_identity_sha256",
                        "target_route",
                        "control_key",
                        "raw_output",
                        "raw_output_frame_sha256",
                        "decoded_output",
                        "decoded_output_frame_sha256",
                        "writer_settings",
                        "writer_settings_sha256",
                        "authenticated_writer_identity",
                        "encoded_container",
                        "encoded_container_sha256",
                        "writer_report",
                        "writer_report_sha256",
                        "decoded_payload",
                        "decoded_payload_sha256",
                        "native_writer_round_trip_record",
                        "native_writer_round_trip_record_sha256",
                    }
                    or writer_document.get("schema_version") != "2.0.0"
                    or writer_document.get("artifact_kind")
                    != CONTROL_WRITER_EVIDENCE_BYTES_KIND
                    or writer_document.get(
                        "source_profile_identity_sha256"
                    )
                    != measurement["source_profile_identity_sha256"]
                    or writer_document.get("target_route")
                    != row.get("target_route")
                    or writer_document.get("control_key")
                    != expected_control_request.get("control_key")
                    or writer_document.get("raw_output")
                    != raw_output_bindings[identity_index].as_document()
                    or writer_document.get("raw_output_frame_sha256")
                    != raw_output_frame_sha256[identity_index]
                    or writer_document.get("decoded_output")
                    != output.as_document()
                    or writer_document.get("decoded_output_frame_sha256")
                    != frame_sha256(output_frame)
                    or type(writer_settings) is not dict
                    or not writer_settings
                    or not _is_sha256(
                        writer_document.get("writer_settings_sha256")
                    )
                    or writer_document.get("writer_settings_sha256")
                    != _sha256(canonical_json_bytes_v2(writer_settings))
                    or writer_settings != expected_writer_settings
                    or type(writer_identity) is not dict
                    or set(writer_identity) != {
                        "writer_executable_sha256",
                        "writer_settings_source_sha256",
                        "writer_source_manifest_sha256",
                        "writer_implementation_source_sha256",
                    }
                    or any(
                        not _is_sha256(writer_identity.get(field))
                        for field in writer_identity
                    )
                    or writer_identity != expected_writer_identity
                    or writer_document.get("encoded_container")
                    != encoded_container.as_document()
                    or writer_document.get("encoded_container_sha256")
                    != encoded_container.sha256
                    or writer_document.get("writer_report")
                    != writer_report.as_document()
                    or writer_document.get("writer_report_sha256")
                    != writer_report.sha256
                    or writer_document.get("decoded_payload")
                    != decoded_payload.as_document()
                    or writer_document.get("decoded_payload_sha256")
                    != decoded_payload.sha256
                    or type(native_writer_record) is not dict
                    or writer_document.get(
                        "native_writer_round_trip_record_sha256"
                    )
                    != _sha256(
                        canonical_json_bytes_v2(native_writer_record)
                    )
                    or native_writer_record.get("control_key")
                    != expected_control_request.get("control_key")
                    or native_writer_record.get("input_frame_sha256")
                    != raw_output_frame_sha256[identity_index]
                    or native_writer_record.get("decoded_frame_sha256")
                    != frame_sha256(output_frame)
                    or native_writer_record.get("settings_sha256")
                    != writer_document.get("writer_settings_sha256")
                    or native_writer_record.get("encoded_sha256")
                    != encoded_container.sha256
                    or native_writer_record.get("report_sha256")
                    != writer_report.sha256
                    or native_writer_record.get("decoded_payload_sha256")
                    != decoded_payload.sha256
                    or native_writer_record.get("target_route")
                    != row.get("target_route")
                    or native_writer_record.get("comparison_domain")
                    != "container_decoded"
                    or native_writer_record.get("reopened_and_verified")
                    is not True
                ):
                    raise ControlAuthorizationV2Error(
                        f"control writer provenance {row_index} differs"
                    )
                self._authenticate_control_writer(
                    writer,
                    writer_document,
                    ControlWriterSemanticContextV2(
                        expected_scope_bytes=semantic_scope_bytes,
                        expected_control_request_bytes=(
                            expected_control_request_bytes
                        ),
                        source_profile_identity_bytes=(
                            canonical_json_bytes_v2(
                                identities[identity_index]
                            )
                        ),
                        degradation_profile_bytes=(
                            profile_payload_by_index[identity_index]
                        ),
                        raw_output_frame_bytes=(
                            raw_output_payloads[identity_index]
                        ),
                        decoded_output_frame_bytes=output_payload,
                        decoded_payload_bytes=decoded_payload_bytes,
                        encoded_container_bytes=encoded_container_payload,
                        writer_report_bytes=writer_report_payload,
                        writer_provenance_bytes=writer_payload,
                        writer_settings_bytes=(
                            writer_producer_identity.writer_settings_bytes
                        ),
                        writer_settings_sha256=(
                            writer_producer_identity.writer_settings_sha256
                        ),
                        authenticated_writer_identity_bytes=(
                            writer_producer_identity.authenticated_writer_identity_bytes
                        ),
                    ),
                )
            if metrics != recomputed:
                raise ControlAuthorizationV2Error(
                    f"control row {row_index} metrics differ from frame evidence"
                )
            if expected_domain == "engine_raw":
                measured_row = dict(row)
                measured_row["metrics"] = metrics
                raw_rows.append(measured_row)

        if (
            len(row_output_bindings) != len(set(row_output_bindings))
            or len(writer_evidence_bindings)
            != len(set(writer_evidence_bindings))
            or len(writer_encoded_bindings)
            != len(set(writer_encoded_bindings))
            or len(writer_report_bindings)
            != len(set(writer_report_bindings))
            or len(writer_decoded_payload_bindings)
            != len(set(writer_decoded_payload_bindings))
        ):
            raise ControlAuthorizationV2Error(
                "control row output or writer dependency is reused or swapped"
            )

        if any(
            sum(row["source_asset_id"] == source_id for row in raw_rows) != 3
            for source_id in source_order
        ):
            raise ControlAuthorizationV2Error(
                "engine-raw source does not have exactly three profiles"
            )
        try:
            per_source_values, objective = hierarchical_control_objective_v2(
                raw_rows,
                source_order,
            )
        except ProductionEvaluatorError as exc:
            raise ControlAuthorizationV2Error(
                "control objective aggregation failed"
            ) from exc
        per_source = list(per_source_values)
        if (
            summary.get("comparison_domain") != "engine_raw"
            or summary.get("metric_order") != list(SELECTION_METRICS)
            or summary.get("profiles_per_source") != 3
            or summary.get("source_count") != len(source_order)
            or summary.get("per_source_means") != per_source
            or _objective_tuple(
                summary.get("means"),
                label="objective summary means",
            )
            != objective
            or summary.get("selection_tuple") != SELECTION_TUPLE_DESCRIPTION
        ):
            raise ControlAuthorizationV2Error(
                "control objective hierarchy or means differ"
            )
        return objective

    @staticmethod
    def _family_spec(family: str) -> Mapping[str, object]:
        if family == "best_fixed":
            return {
                "kind": FIXED_SELECTION_KIND,
                "ids": FIXED_DESCRIPTOR_IDS,
                "id_field": "descriptor_id",
                "provisional_field": "provisional_descriptor_id",
                "chosen_field": "chosen_descriptor_id",
                "development_tie": (
                    "lexicographically maximize the development engine_raw "
                    "corpus-mean tuple, then choose the numerically smallest "
                    "descriptor ID"
                ),
                "validation_tie": (
                    "lexicographically maximize the validation engine_raw "
                    "corpus-mean tuple, then choose the numerically smallest "
                    "descriptor ID"
                ),
            }
        if family == "conventional":
            return {
                "kind": CONVENTIONAL_SELECTION_KIND,
                "ids": CONVENTIONAL_ALGORITHM_IDS,
                "id_field": "algorithm_id",
                "provisional_field": "provisional_algorithm_id",
                "chosen_field": "chosen_algorithm_id",
                "development_tie": (
                    "lexicographically maximize the development engine_raw "
                    "corpus-mean tuple, then choose the lexicographically "
                    "ascending stable algorithm ID"
                ),
                "validation_tie": (
                    "lexicographically maximize the validation engine_raw "
                    "corpus-mean tuple, then choose the lexicographically "
                    "ascending stable algorithm ID"
                ),
            }
        raise ControlAuthorizationV2Error(
            f"unknown ranked control family {family!r}"
        )

    def _ranked_results(
        self,
        *,
        document: Mapping[str, object],
        results_field: str,
        split: str,
        family: str,
        resolver: _SnapshotResolverV2,
        scope: ControlAuthorizationScopeV2,
    ) -> Tuple[Tuple[object, Tuple[float, ...]], ...]:
        spec = self._family_spec(family)
        results = document.get(results_field)
        ids = spec["ids"]
        id_field = spec["id_field"]
        if type(results) is not list or len(results) != len(ids):
            raise ControlAuthorizationV2Error(
                f"{family} {split} result coverage differs"
            )
        ranked = []
        for expected_id, row in zip(ids, results):
            if type(row) is not dict or row.get(id_field) != expected_id:
                raise ControlAuthorizationV2Error(
                    f"{family} {split} result order differs"
                )
            try:
                if family == "best_fixed":
                    configuration = fixed_control_configuration_sha256_v2(
                        expected_id,
                        scope.shared_bank_configuration_sha256,
                    )
                    control_request = fixed_control_request(
                        expected_id,
                        scope.shared_bank_configuration_sha256,
                    )
                else:
                    configuration = conventional_control_configuration_sha256_v2(
                        expected_id,
                        scope.shared_bank_configuration_sha256,
                    )
                    control_request = conventional_control_request(
                        expected_id,
                        scope.shared_bank_configuration_sha256,
                    )
            except ProductionEvaluatorError as exc:
                raise ControlAuthorizationV2Error(
                    f"{family} {split} control configuration is invalid"
                ) from exc
            if row.get("control_configuration_sha256") != configuration:
                raise ControlAuthorizationV2Error(
                    f"{family} {split} control configuration differs from "
                    "production request semantics"
                )
            objective_binding = _typed_binding(row.get("objective_summary"))
            output_binding = _typed_binding(row.get("output_manifest"))
            objective = self._aggregate_from_bindings(
                objective_binding=objective_binding,
                output_binding=output_binding,
                resolver=resolver,
                scope=scope,
                expected_family=family,
                expected_split=split,
                expected_stable_id=expected_id,
                expected_control_configuration_sha256=configuration,
                expected_control_request=control_request,
            )
            if _objective_tuple(
                row.get("engine_raw_corpus_mean_tuple"),
                label=f"{family} {split} recorded objective",
            ) != objective:
                raise ControlAuthorizationV2Error(
                    f"{family} {split} recorded objective differs"
                )
            ranked.append((expected_id, objective))
        return tuple(ranked)

    @staticmethod
    def _ranked_winner(
        ranked: Sequence[Tuple[object, Tuple[float, ...]]],
    ) -> object:
        best = max(objective for _, objective in ranked)
        return min(identifier for identifier, objective in ranked if objective == best)

    def _verify_ranked_control(
        self,
        *,
        binding: TypedArtifactBindingV2,
        family: str,
        resolver: _SnapshotResolverV2,
        scope: ControlAuthorizationScopeV2,
    ) -> Mapping[str, object]:
        spec = self._family_spec(family)
        kind = spec["kind"]
        selection = self._new_document(
            binding,
            resolver,
            expected_kind=kind,
        )
        if scope.split == "development":
            common = {
                "run_id": scope.run_id,
                "selection_stage": "development_provisional",
                "split": "development",
                "shared_bank_configuration_sha256": (
                    scope.shared_bank_configuration_sha256
                ),
                "degradation_policy_sha256": (
                    scope.degradation_policy_sha256
                ),
                "source_profile_matrix_sha256": (
                    scope.source_profile_matrix_sha256
                ),
                "candidate_ids": list(spec["ids"]),
                "selection_objective": SELECTION_OBJECTIVE,
                "uniform_application": True,
                "tie_break": spec["development_tie"],
            }
            for field, expected in common.items():
                if selection.get(field) != expected:
                    raise ControlAuthorizationV2Error(
                        f"{family} development selection {field} differs"
                    )
            ranked = self._ranked_results(
                document=selection,
                results_field="development_results",
                split="development",
                family=family,
                resolver=resolver,
                scope=scope,
            )
            if selection.get(spec["provisional_field"]) != (
                self._ranked_winner(ranked)
            ):
                raise ControlAuthorizationV2Error(
                    f"{family} development winner differs"
                )
            return selection

        common = {
            "run_id": scope.run_id,
            "selection_stage": "validation_final",
            "split": "validation",
            "shared_bank_configuration_sha256": (
                scope.shared_bank_configuration_sha256
            ),
            "degradation_policy_sha256": scope.degradation_policy_sha256,
            "source_profile_matrix_sha256": (
                scope.source_profile_matrix_sha256
            ),
            "candidate_ids": list(spec["ids"]),
            "selection_objective": SELECTION_OBJECTIVE,
            "uniform_application": True,
            "tie_break": spec["validation_tie"],
        }
        for field, expected in common.items():
            if selection.get(field) != expected:
                raise ControlAuthorizationV2Error(
                    f"{family} final selection {field} differs"
                )
        admission = _typed_binding(selection.get("validation_admission"))
        if admission != scope.validation_admission:
            raise ControlAuthorizationV2Error(
                f"{family} validation admission differs"
            )
        resolver.require_binding(
            admission,
            expected_kind=VALIDATION_ADMISSION_KIND,
            expected_schema_sha256=schema_sha256_for_kind_v2(
                VALIDATION_ADMISSION_KIND
            ),
        )
        development_binding = _typed_binding(
            selection.get("development_selection")
        )
        development = self._new_document(
            development_binding,
            resolver,
            expected_kind=kind,
        )
        development_scope = scope.development_scope()
        development_common = dict(common)
        development_common.update(
            {
                "selection_stage": "development_provisional",
                "split": "development",
                "source_profile_matrix_sha256": (
                    development_scope.source_profile_matrix_sha256
                ),
                "tie_break": spec["development_tie"],
            }
        )
        for field, expected in development_common.items():
            if development.get(field) != expected:
                raise ControlAuthorizationV2Error(
                    f"{family} development predecessor {field} differs"
                )
        development_ranked = self._ranked_results(
            document=development,
            results_field="development_results",
            split="development",
            family=family,
            resolver=resolver,
            scope=development_scope,
        )
        if development.get(spec["provisional_field"]) != self._ranked_winner(
            development_ranked
        ):
            raise ControlAuthorizationV2Error(
                f"{family} development winner differs"
            )
        validation_ranked = self._ranked_results(
            document=selection,
            results_field="validation_results",
            split="validation",
            family=family,
            resolver=resolver,
            scope=scope,
        )
        if selection.get(spec["chosen_field"]) != self._ranked_winner(
            validation_ranked
        ):
            raise ControlAuthorizationV2Error(
                f"{family} validation winner differs"
            )
        return selection

    def _existing_non_ash_document(
        self,
        binding: TypedArtifactBindingV2,
        resolver: _SnapshotResolverV2,
        *,
        expected_kind: str,
    ) -> Dict[str, object]:
        payload = resolver.require_binding(
            binding,
            expected_kind=expected_kind,
            expected_schema_sha256=schema_sha256_for_kind_v2(expected_kind),
        )
        document = _parse_canonical_compact_or_file(
            payload,
            label=f"{expected_kind} {binding.path}",
        )
        if document.get("artifact_kind") != expected_kind:
            raise ControlAuthorizationV2Error(
                f"snapshot artifact kind differs from {expected_kind}"
            )
        _validate_schema(
            document,
            kind=expected_kind,
            schema_cache=self._schema_cache,
        )
        return document

    def _non_ash_evaluation(
        self,
        *,
        digest: object,
        expected_split: str,
        expected_rule_sha256: object,
        expected_rule_values: object,
        expected_objective_summary_sha256: object,
        expected_output_manifest_sha256: object,
        expected_objective: object,
        resolver: _SnapshotResolverV2,
        scope: ControlAuthorizationScopeV2,
        evaluation_scope: NonAshSelectorEvaluationScopeV2,
        profile: NonAshSelectorExecutionProfileV2,
    ) -> None:
        binding, payload = resolver.require_digest(
            digest,
            expected_kind=EVALUATION_EVIDENCE_KIND,
            expected_schema_sha256=schema_sha256_for_kind_v2(
                EVALUATION_EVIDENCE_KIND
            ),
        )
        envelope = _parse_canonical_compact(
            payload,
            label=f"non-ASH evaluation {binding.path}",
        )
        _validate_schema(
            envelope,
            kind=EVALUATION_EVIDENCE_KIND,
            schema_cache=self._schema_cache,
        )
        expected_envelope_scope = {
            "shared_bank_configuration_sha256": (
                scope.shared_bank_configuration_sha256
            ),
            "degradation_policy_sha256": scope.degradation_policy_sha256,
            "calibration_plan_file_sha256": (
                _AUTHORITY_SPECS["calibration_plan_v2"]["file_sha256"]
            ),
            "cached_16_operator_output_manifest_sha256": (
                evaluation_scope.cached_16_operator_output_manifest_sha256
            ),
        }
        expected = {
            "artifact_kind": EVALUATION_EVIDENCE_KIND,
            "schema_version": EVALUATION_EVIDENCE_SCHEMA_VERSION,
            "authority_bindings": authority_bindings_v2(),
            "selector_id": "continuous-linear-bank-selector-q15-v2",
            "split": expected_split,
            "evaluation_scope": expected_envelope_scope,
            "rule_sha256": expected_rule_sha256,
            "objective_summary_sha256": expected_objective_summary_sha256,
            "output_manifest_sha256": expected_output_manifest_sha256,
            "engine_raw_corpus_mean_tuple": list(
                _objective_tuple(
                    expected_objective,
                    label="non-ASH recorded objective",
                )
            ),
        }
        if envelope != expected:
            raise ControlAuthorizationV2Error(
                "non-ASH evaluation envelope differs from its recorded outcome"
            )
        _authenticate_authorities(envelope["authority_bindings"])
        objective_binding, _ = resolver.require_digest(
            expected_objective_summary_sha256,
            expected_kind=OBJECTIVE_SUMMARY_KIND,
            expected_schema_sha256=schema_sha256_for_kind_v2(
                OBJECTIVE_SUMMARY_KIND
            ),
        )
        output_binding, _ = resolver.require_digest(
            expected_output_manifest_sha256,
            expected_kind=OUTPUT_MANIFEST_KIND,
            expected_schema_sha256=schema_sha256_for_kind_v2(
                OUTPUT_MANIFEST_KIND
            ),
        )
        try:
            if type(expected_rule_values) not in {list, tuple}:
                raise ProductionEvaluatorError(
                    "non-ASH rule values are absent"
                )
            rule = rule_mapping_v2(tuple(expected_rule_values), profile)
            if _sha256(canonical_json_bytes_v2(rule)) != expected_rule_sha256:
                raise ProductionEvaluatorError(
                    "non-ASH rule values differ from their identity"
                )
            expected_configuration_sha256 = (
                non_ash_control_configuration_sha256_v2(
                    selector_id=NON_ASH_SELECTOR_ID_V2,
                    rule_sha256=expected_rule_sha256,
                    shared_bank_configuration_sha256=(
                        scope.shared_bank_configuration_sha256
                    ),
                )
            )
            expected_control_request = (
                non_ash_control_request_for_selector_v2(
                    rule,
                    scope.shared_bank_configuration_sha256,
                    selector_id=NON_ASH_SELECTOR_ID_V2,
                )
            )
        except (ProductionEvaluatorError, NonAshSelectorV2Error) as exc:
            raise ControlAuthorizationV2Error(
                "non-ASH control configuration is invalid"
            ) from exc
        objective = self._aggregate_from_bindings(
            objective_binding=objective_binding,
            output_binding=output_binding,
            resolver=resolver,
            scope=scope,
            expected_family="non_ash_selector",
            expected_split=expected_split,
            expected_stable_id=expected_rule_sha256,
            expected_control_configuration_sha256=(
                expected_configuration_sha256
            ),
            expected_control_request=expected_control_request,
        )
        if objective != _objective_tuple(
            expected_objective,
            label="non-ASH evaluation objective",
        ):
            raise ControlAuthorizationV2Error(
                "non-ASH aggregate objective differs from its envelope"
            )

    def _non_ash_failure(
        self,
        digest: object,
        *,
        resolver: _SnapshotResolverV2,
    ) -> Mapping[str, object]:
        binding, payload = resolver.require_digest(
            digest,
            expected_kind=ATTEMPT_FAILURE_KIND,
            expected_schema_sha256=schema_sha256_for_kind_v2(
                ATTEMPT_FAILURE_KIND
            ),
        )
        failure = _parse_canonical_compact_or_file(
            payload,
            label=f"non-ASH failure {binding.path}",
        )
        if failure.get("artifact_kind") != ATTEMPT_FAILURE_KIND:
            raise ControlAuthorizationV2Error(
                "non-ASH failure kind differs"
            )
        _validate_schema(
            failure,
            kind=ATTEMPT_FAILURE_KIND,
            schema_cache=self._schema_cache,
        )
        evidence_bindings = failure.get("evidence_bindings")
        if type(evidence_bindings) is not list:
            raise ControlAuthorizationV2Error(
                "non-ASH failure evidence bindings are invalid"
            )
        for evidence in evidence_bindings:
            if type(evidence) is not dict or set(evidence) != {
                "id",
                "path",
                "sha256",
                "size_bytes",
            }:
                raise ControlAuthorizationV2Error(
                    "non-ASH failure evidence binding differs"
                )
            declared = resolver.by_path.get(evidence["path"])
            if (
                declared is None
                or declared.sha256 != evidence["sha256"]
                or declared.size_bytes != evidence["size_bytes"]
            ):
                raise ControlAuthorizationV2Error(
                    "non-ASH failure evidence dependency is omitted or swapped"
                )
            resolver.require_binding(
                declared,
                expected_kind=NON_ASH_FAILURE_EVIDENCE_BYTES_KIND,
                expected_schema_sha256=schema_sha256_for_kind_v2(
                    ATTEMPT_FAILURE_KIND
                ),
            )
        return failure

    def _immutable_non_ash_content(
        self,
        digest: object,
        *,
        resolver: _SnapshotResolverV2,
    ) -> bytes:
        _, payload = resolver.require_digest(
            digest,
            expected_kind=NON_ASH_IMMUTABLE_CONTENT_KIND,
        )
        return payload

    def _verify_non_ash_control(
        self,
        *,
        binding: TypedArtifactBindingV2,
        predecessor_documents: Mapping[str, object],
        resolver: _SnapshotResolverV2,
        scope: ControlAuthorizationScopeV2,
        profile: NonAshSelectorExecutionProfileV2,
        evaluation_scope: NonAshSelectorEvaluationScopeV2,
    ) -> Mapping[str, object]:
        expected_predecessors = (
            {"development_ledger"}
            if scope.split == "development"
            else {
                "development_ledger",
                "development_selection",
                "validation_neighbor_manifest",
            }
        )
        if (
            type(predecessor_documents) is not dict
            or set(predecessor_documents) != expected_predecessors
        ):
            raise ControlAuthorizationV2Error(
                "non-ASH predecessor binding set differs"
            )
        selection = self._existing_non_ash_document(
            binding,
            resolver,
            expected_kind=SELECTION_KIND,
        )
        predecessor_specs = {
            "development_ledger": ATTEMPT_LEDGER_KIND,
        }
        if scope.split == "validation":
            predecessor_specs.update(
                {
                    "development_selection": SELECTION_KIND,
                    "validation_neighbor_manifest": NEIGHBOR_MANIFEST_KIND,
                }
            )
        predecessors: Dict[str, Mapping[str, object]] = {}
        for name, expected_kind in predecessor_specs.items():
            predecessor_binding = _typed_binding(predecessor_documents[name])
            predecessors[name] = self._existing_non_ash_document(
                predecessor_binding,
                resolver,
                expected_kind=expected_kind,
            )
        expected_stage = (
            "development_provisional"
            if scope.split == "development"
            else "validation_final"
        )
        if (
            selection.get("selection_stage") != expected_stage
            or selection.get("split") != scope.split
            or selection.get("shared_bank_configuration_sha256")
            != scope.shared_bank_configuration_sha256
            or selection.get("degradation_policy_sha256")
            != scope.degradation_policy_sha256
            or evaluation_scope.shared_bank_configuration_sha256
            != scope.shared_bank_configuration_sha256
            or evaluation_scope.degradation_policy_sha256
            != scope.degradation_policy_sha256
            or evaluation_scope.calibration_plan_file_sha256
            != _AUTHORITY_SPECS["calibration_plan_v2"]["file_sha256"]
            or selection.get("cached_16_operator_output_manifest_sha256")
            != evaluation_scope.cached_16_operator_output_manifest_sha256
        ):
            raise ControlAuthorizationV2Error(
                "non-ASH selection scope differs"
            )
        if (
            scope.split == "validation"
            and selection.get("validation_status") != "selected"
        ):
            raise ControlAuthorizationV2Error(
                "non-ASH validation selection did not select a control"
            )

        def evaluation_reopener(digest: str) -> bytes:
            _, payload = resolver.require_digest(
                digest,
                expected_kind=EVALUATION_EVIDENCE_KIND,
                expected_schema_sha256=schema_sha256_for_kind_v2(
                    EVALUATION_EVIDENCE_KIND
                ),
            )
            return payload

        def failure_reopener(digest: str) -> Mapping[str, object]:
            return self._non_ash_failure(digest, resolver=resolver)

        def evidence_binding_reopener(
            evidence: Mapping[str, object],
        ) -> bytes:
            if type(evidence) is not dict:
                raise ControlAuthorizationV2Error(
                    "failure evidence callback binding is invalid"
                )
            binding_for_path = resolver.by_path.get(evidence.get("path"))
            if (
                binding_for_path is None
                or binding_for_path.sha256 != evidence.get("sha256")
                or binding_for_path.size_bytes != evidence.get("size_bytes")
            ):
                raise ControlAuthorizationV2Error(
                    "failure evidence callback binding is omitted or swapped"
                )
            return resolver.require_binding(
                binding_for_path,
                expected_kind=NON_ASH_FAILURE_EVIDENCE_BYTES_KIND,
                expected_schema_sha256=schema_sha256_for_kind_v2(
                    ATTEMPT_FAILURE_KIND
                ),
            )

        def immutable_content_reopener(digest: str) -> bytes:
            return self._immutable_non_ash_content(
                digest,
                resolver=resolver,
            )

        try:
            if scope.split == "development":
                verified = verify_development_selection_v2(
                    selection,
                    profile,
                    evaluation_scope,
                    development_ledger=predecessors[
                        "development_ledger"
                    ],
                    development_evidence_reopener=evaluation_reopener,
                )
            else:
                verified = verify_validation_selection_v2(
                    selection,
                    profile,
                    evaluation_scope,
                    development_ledger=predecessors[
                        "development_ledger"
                    ],
                    development_selection=predecessors[
                        "development_selection"
                    ],
                    validation_neighbor_manifest=predecessors[
                        "validation_neighbor_manifest"
                    ],
                    development_evidence_reopener=evaluation_reopener,
                    validation_evidence_reopener=evaluation_reopener,
                    failure_reopener=failure_reopener,
                    evidence_binding_reopener=evidence_binding_reopener,
                    immutable_content_reopener=immutable_content_reopener,
                )
        except NonAshSelectorArtifactV2Error as error:
            raise ControlAuthorizationV2Error(
                f"complete non-ASH {scope.split} replay failed"
            ) from error
        if verified != selection:
            raise ControlAuthorizationV2Error(
                "complete non-ASH verifier returned different selection"
            )

        ledger = predecessors["development_ledger"]
        development_scope = scope.development_scope()
        records = ledger.get("records")
        if type(records) is not list:
            raise ControlAuthorizationV2Error(
                "non-ASH development records are invalid"
            )
        for row in records:
            if type(row) is not dict or type(row.get("outcome")) is not dict:
                raise ControlAuthorizationV2Error(
                    "non-ASH development outcome is invalid"
                )
            outcome = row["outcome"]
            if outcome.get("outcome_type") == "evaluated":
                self._non_ash_evaluation(
                    digest=outcome.get("evaluation_sha256"),
                    expected_split="development",
                    expected_rule_sha256=row.get("rule_sha256"),
                    expected_rule_values=row.get("canonical_rule_values"),
                    expected_objective_summary_sha256=outcome.get(
                        "objective_summary_sha256"
                    ),
                    expected_output_manifest_sha256=outcome.get(
                        "output_manifest_sha256"
                    ),
                    expected_objective=outcome.get(
                        "engine_raw_corpus_mean_tuple"
                    ),
                    resolver=resolver,
                    scope=development_scope,
                    evaluation_scope=evaluation_scope,
                    profile=profile,
                )
            elif outcome.get("outcome_type") == "failed":
                self._non_ash_failure(
                    outcome.get("attempt_failure_sha256"),
                    resolver=resolver,
                )
            else:
                raise ControlAuthorizationV2Error(
                    "non-ASH development outcome type differs"
                )

        if scope.split == "validation":
            validation_results = selection.get("validation_results")
            neighbor = predecessors["validation_neighbor_manifest"]
            neighbor_candidates = neighbor.get("candidates")
            if type(validation_results) is not list:
                raise ControlAuthorizationV2Error(
                    "non-ASH validation results are invalid"
                )
            if type(neighbor_candidates) is not list:
                raise ControlAuthorizationV2Error(
                    "non-ASH validation neighbor rules are invalid"
                )
            values_by_rule = {
                candidate.get("rule_sha256"): candidate.get(
                    "canonical_rule_values"
                )
                for candidate in neighbor_candidates
                if type(candidate) is dict
            }
            for row in validation_results:
                if (
                    type(row) is not dict
                    or type(row.get("outcome")) is not dict
                ):
                    raise ControlAuthorizationV2Error(
                        "non-ASH validation outcome is invalid"
                    )
                outcome = row["outcome"]
                if outcome.get("outcome_type") == "scored":
                    self._non_ash_evaluation(
                        digest=outcome.get("evaluation_sha256"),
                        expected_split="validation",
                        expected_rule_sha256=row.get("rule_sha256"),
                        expected_rule_values=values_by_rule.get(
                            row.get("rule_sha256")
                        ),
                        expected_objective_summary_sha256=outcome.get(
                            "objective_summary_sha256"
                        ),
                        expected_output_manifest_sha256=outcome.get(
                            "output_manifest_sha256"
                        ),
                        expected_objective=outcome.get(
                            "engine_raw_corpus_mean_tuple"
                        ),
                        resolver=resolver,
                        scope=scope,
                        evaluation_scope=evaluation_scope,
                        profile=profile,
                    )
                elif outcome.get("outcome_type") == "failed":
                    self._non_ash_failure(
                        outcome.get("attempt_failure_sha256"),
                        resolver=resolver,
                    )
                else:
                    raise ControlAuthorizationV2Error(
                        "non-ASH validation outcome type differs"
                    )

            self._immutable_non_ash_content(
                neighbor.get(
                    "development_candidate_evidence_manifest_sha256"
                ),
                resolver=resolver,
            )
        resolver.require_digest(
            evaluation_scope.cached_16_operator_output_manifest_sha256,
            expected_kind=CACHED_OPERATOR_OUTPUT_MANIFEST_KIND,
        )
        terminal_failure = ledger.get("terminal_failure_sha256")
        if terminal_failure is not None and terminal_failure not in {
            row.get("outcome", {}).get("attempt_failure_sha256")
            for row in records
            if type(row) is dict and type(row.get("outcome")) is dict
        }:
            self._immutable_non_ash_content(
                terminal_failure,
                resolver=resolver,
            )
        return selection

    def _verify_validation_admission(
        self,
        *,
        binding: TypedArtifactBindingV2,
        resolver: _SnapshotResolverV2,
        scope: ControlAuthorizationScopeV2,
        semantic_verifier: Callable[
            [TypedArtifactBindingV2, Mapping[str, object]],
            Mapping[str, object],
        ],
    ) -> Mapping[str, object]:
        """Authenticate admission bytes and require trusted semantic replay."""

        payload = resolver.require_binding(
            binding,
            expected_kind=VALIDATION_ADMISSION_KIND,
            expected_schema_sha256=schema_sha256_for_kind_v2(
                VALIDATION_ADMISSION_KIND
            ),
        )
        admission = _parse_canonical_file(
            payload,
            label="validation admission",
        )
        _verify_new_artifact(
            admission,
            expected_kind=VALIDATION_ADMISSION_KIND,
            schema_cache=self._schema_cache,
            authority_files_authenticated=(
                self._authority_files_authenticated
            ),
        )
        self._authority_files_authenticated = True
        if (
            admission.get("run_id") != scope.run_id
            or admission.get("shared_bank_configuration_sha256")
            != scope.shared_bank_configuration_sha256
        ):
            raise ControlAuthorizationV2Error(
                "validation admission scope differs"
            )
        try:
            verified = semantic_verifier(
                binding,
                _snapshot_json(admission, label="validation admission"),
            )
        except Exception as error:
            raise ControlAuthorizationV2Error(
                "validation admission semantic replay failed"
            ) from error
        if verified != admission:
            raise ControlAuthorizationV2Error(
                "validation admission semantic replay returned different bytes"
            )
        return admission

    def verify_bundle(
        self,
        bundle_binding: TypedArtifactBindingV2,
        *,
        evidence_snapshot: AuthenticatedClosureSnapshotV2,
        expected_scope: ControlAuthorizationScopeV2,
        non_ash_profile: NonAshSelectorExecutionProfileV2,
        non_ash_evaluation_scope: NonAshSelectorEvaluationScopeV2,
        validation_admission_semantic_verifier: Optional[
            Callable[
                [TypedArtifactBindingV2, Mapping[str, object]],
                Mapping[str, object],
            ]
        ] = None,
    ) -> VerifiedControlAuthorizationV2:
        """Verify one bundle and its exact snapshot-backed transitive closure."""

        if (
            type(bundle_binding) is not TypedArtifactBindingV2
            or bundle_binding.artifact_kind
            != CONTROL_AUTHORIZATION_BUNDLE_KIND
            or bundle_binding.schema_sha256
            != schema_sha256_for_kind_v2(CONTROL_AUTHORIZATION_BUNDLE_KIND)
            or type(evidence_snapshot) is not AuthenticatedClosureSnapshotV2
            or type(expected_scope) is not ControlAuthorizationScopeV2
            or type(non_ash_profile) is not NonAshSelectorExecutionProfileV2
            or type(non_ash_evaluation_scope)
            is not NonAshSelectorEvaluationScopeV2
            or (
                expected_scope.split == "validation"
                and not callable(validation_admission_semantic_verifier)
            )
        ):
            raise ControlAuthorizationV2Error(
                "bundle verification input types or identities differ"
            )
        try:
            bundle_payload = evidence_snapshot.payload(
                bundle_binding.closure_binding()
            )
        except AuthenticatedClosureSnapshotV2Error as error:
            raise ControlAuthorizationV2Error(
                "bundle bytes are absent from the evidence snapshot"
            ) from error
        bundle = _parse_canonical_file(
            bundle_payload,
            label="control authorization bundle",
        )
        _verify_new_artifact(
            bundle,
            expected_kind=CONTROL_AUTHORIZATION_BUNDLE_KIND,
            schema_cache=self._schema_cache,
            authority_files_authenticated=self._authority_files_authenticated,
        )
        self._authority_files_authenticated = True
        expected_fields = {
            "run_id": expected_scope.run_id,
            "split": expected_scope.split,
            "shared_bank_configuration_sha256": (
                expected_scope.shared_bank_configuration_sha256
            ),
            "degradation_policy_sha256": (
                expected_scope.degradation_policy_sha256
            ),
            "source_profile_matrix_sha256": (
                expected_scope.source_profile_matrix_sha256
            ),
        }
        if expected_scope.split == "validation":
            expected_fields[
                "development_source_profile_matrix_sha256"
            ] = expected_scope.development_source_profile_matrix_sha256
        for field, expected in expected_fields.items():
            if bundle.get(field) != expected:
                raise ControlAuthorizationV2Error(
                    f"control authorization bundle {field} differs"
                )
        admission = None
        if expected_scope.split == "validation":
            admission = _typed_binding(bundle.get("validation_admission"))
            if admission != expected_scope.validation_admission:
                raise ControlAuthorizationV2Error(
                    "control authorization bundle admission differs"
                )
        elif "validation_admission" in bundle:
            raise ControlAuthorizationV2Error(
                "development control authorization contains admission"
            )
        raw_dependencies = bundle.get("dependency_bindings")
        if type(raw_dependencies) is not list:
            raise ControlAuthorizationV2Error(
                "control authorization dependencies are invalid"
            )
        dependencies = tuple(
            _typed_binding(value) for value in raw_dependencies
        )
        resolver = _SnapshotResolverV2(evidence_snapshot, dependencies)
        if bundle.get("dependency_set_sha256") != dependency_set_sha256_v2(
            dependencies
        ):
            raise ControlAuthorizationV2Error(
                "control authorization dependency-set identity differs"
            )
        if bundle.get("authorization_semantic_sha256") != (
            control_authorization_semantic_sha256_v2(bundle)
        ):
            raise ControlAuthorizationV2Error(
                "control authorization semantic identity differs"
            )
        if admission is not None:
            assert validation_admission_semantic_verifier is not None
            self._verify_validation_admission(
                binding=admission,
                resolver=resolver,
                scope=expected_scope,
                semantic_verifier=(
                    validation_admission_semantic_verifier
                ),
            )

        controls = bundle.get("control_selections")
        expected_control_ids = (
            "best_fixed",
            "conventional",
            "non_ash_selector",
        )
        if type(controls) is not list or len(controls) != 3:
            raise ControlAuthorizationV2Error(
                "control authorization lacks exactly three controls"
            )
        control_bindings = []
        control_by_id: Dict[str, TypedArtifactBindingV2] = {}
        for expected_id, entry in zip(expected_control_ids, controls):
            if (
                type(entry) is not dict
                or set(entry) != {"id", "selection"}
                or entry.get("id") != expected_id
            ):
                raise ControlAuthorizationV2Error(
                    "control authorization control order differs"
                )
            control_binding = _typed_binding(entry.get("selection"))
            control_bindings.append(control_binding)
            control_by_id[expected_id] = control_binding

        self._verify_ranked_control(
            binding=control_by_id["best_fixed"],
            family="best_fixed",
            resolver=resolver,
            scope=expected_scope,
        )
        self._verify_ranked_control(
            binding=control_by_id["conventional"],
            family="conventional",
            resolver=resolver,
            scope=expected_scope,
        )
        self._verify_non_ash_control(
            binding=control_by_id["non_ash_selector"],
            predecessor_documents=bundle.get("non_ash_predecessors"),
            resolver=resolver,
            scope=expected_scope,
            profile=non_ash_profile,
            evaluation_scope=non_ash_evaluation_scope,
        )
        resolver.finish()
        return VerifiedControlAuthorizationV2(
            bundle_binding=bundle_binding,
            document=_snapshot_json(bundle, label="verified bundle"),
            control_selection_bindings=tuple(control_bindings),
            dependency_bindings=dependencies,
            dependency_set_sha256=bundle["dependency_set_sha256"],
            authorization_semantic_sha256=bundle[
                "authorization_semantic_sha256"
            ],
        )


def verify_control_authorization_bundle_v2(
    bundle_binding: TypedArtifactBindingV2,
    *,
    evidence_snapshot: AuthenticatedClosureSnapshotV2,
    expected_scope: ControlAuthorizationScopeV2,
    non_ash_profile: NonAshSelectorExecutionProfileV2,
    non_ash_evaluation_scope: NonAshSelectorEvaluationScopeV2,
    validation_admission_semantic_verifier: Optional[
        Callable[
            [TypedArtifactBindingV2, Mapping[str, object]],
            Mapping[str, object],
        ]
    ] = None,
    control_execution_semantic_verifier: Optional[
        Callable[
            [
                TypedArtifactBindingV2,
                Mapping[str, object],
                ControlExecutionSemanticContextV2,
            ],
            Mapping[str, object],
        ]
    ] = None,
    control_writer_semantic_verifier: Optional[
        Callable[
            [
                TypedArtifactBindingV2,
                Mapping[str, object],
                ControlWriterSemanticContextV2,
            ],
            Mapping[str, object],
        ]
    ] = None,
    control_execution_producer_identity: Optional[
        ControlExecutionProducerIdentityV2
    ] = None,
    control_writer_producer_identity: Optional[
        ControlWriterProducerIdentityV2
    ] = None,
) -> VerifiedControlAuthorizationV2:
    """Functional integration entry point for the isolated verifier."""

    return ControlAuthorizationVerifierV2(
        control_execution_semantic_verifier=(
            control_execution_semantic_verifier
        ),
        control_writer_semantic_verifier=(
            control_writer_semantic_verifier
        ),
        control_execution_producer_identity=(
            control_execution_producer_identity
        ),
        control_writer_producer_identity=(
            control_writer_producer_identity
        ),
    ).verify_bundle(
        bundle_binding,
        evidence_snapshot=evidence_snapshot,
        expected_scope=expected_scope,
        non_ash_profile=non_ash_profile,
        non_ash_evaluation_scope=non_ash_evaluation_scope,
        validation_admission_semantic_verifier=(
            validation_admission_semantic_verifier
        ),
    )


__all__ = [
    "CACHED_OPERATOR_OUTPUT_MANIFEST_KIND",
    "CONVENTIONAL_SELECTION_KIND",
    "CONTROL_AUTHORIZATION_BUNDLE_KIND",
    "CONTROL_DEGRADATION_PROFILE_KIND",
    "CONTROL_EXECUTION_PROVENANCE_KIND",
    "CONTROL_LOW_RESOLUTION_INPUT_BYTES_KIND",
    "CONTROL_MEASUREMENT_EVIDENCE_KIND",
    "CONTROL_METRIC_ALGORITHM",
    "CONTROL_OUTPUT_BYTES_KIND",
    "CONTROL_SOURCE_TARGET_PROVENANCE_KIND",
    "CONTROL_TARGET_FRAME_BYTES_KIND",
    "CONTROL_WRITER_EVIDENCE_BYTES_KIND",
    "CONTROL_WRITER_DECODED_PAYLOAD_BYTES_KIND",
    "CONTROL_WRITER_ENCODED_CONTAINER_BYTES_KIND",
    "CONTROL_WRITER_REPORT_BYTES_KIND",
    "ControlAuthorizationScopeV2",
    "ControlAuthorizationV2Error",
    "ControlAuthorizationVerifierV2",
    "DEPENDENCY_SET_HASH_DOMAIN_V2",
    "FIXED_SELECTION_KIND",
    "NON_ASH_FAILURE_EVIDENCE_BYTES_KIND",
    "NON_ASH_IMMUTABLE_CONTENT_KIND",
    "OBJECTIVE_SUMMARY_KIND",
    "OUTPUT_MANIFEST_KIND",
    "TypedArtifactBindingV2",
    "VALIDATION_ADMISSION_KIND",
    "VerifiedControlAuthorizationV2",
    "authority_bindings_v2",
    "canonical_json_bytes_v2",
    "canonical_json_file_bytes_v2",
    "control_authorization_semantic_sha256_v2",
    "dependency_set_sha256_v2",
    "finalize_artifact_sha256_v2",
    "finalize_control_authorization_bundle_v2",
    "schema_sha256_for_kind_v2",
    "verify_control_authorization_bundle_v2",
]
