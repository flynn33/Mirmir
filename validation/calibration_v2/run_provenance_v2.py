"""Authenticated P06 V2 run provenance and non-cyclic input closure.

This module is deliberately isolated from the production runner.  It provides
construction and verification primitives only; it does not execute calibration,
open validation/holdout data, publish artifacts, or mutate repository inputs.
"""

from __future__ import annotations

from dataclasses import dataclass
import hashlib
import json
import os
import platform as host_platform
from pathlib import Path, PurePosixPath
import re
import stat
import sys
from typing import Callable, Mapping, Optional, Sequence, Tuple

import jsonschema


CALIBRATION_ROOT = Path(__file__).resolve().parent
PROVENANCE_SCHEMA_PATH = (
    CALIBRATION_ROOT / "schemas/p06-run-provenance-receipt-v2.schema.json"
)
RUN_INPUT_MANIFEST_SCHEMA_PATH = (
    CALIBRATION_ROOT / "schemas/p06-run-input-manifest-v2.schema.json"
)
PROVENANCE_SCHEMA_SHA256 = (
    "1eebdd2608bf4f10b2f62eb926b2974065fb00c74595ef9331c7752da679550c"
)
RUN_INPUT_MANIFEST_SCHEMA_SHA256 = (
    "2be79eb0f14e6ebe6e94ee389aef5d6d26ca185d7b792011c6fe104dacf7beb2"
)
PROVENANCE_PATH = "p06-run-provenance-receipt-v2.json"
RUN_INPUT_MANIFEST_PATH = "p06-run-input-manifest-v2.json"
RUN_LEDGER_PATH = "calibration-run-ledger-v2.json"
PLAN_ID = "mirmir-p06-spatial-calibration-v2"
PLAN_FILE_SHA256 = (
    "1977c85b9a3b7001294a04d33e7654ae20ffb4266ac0c8d2dc76880bdec99fef"
)
INPUT_BUNDLE_SHA256 = (
    "ad46b6ec3d3629c3a29f17898c6a9b4eec1bca731276ff626dfe58f87bcadd20"
)
GATE_IDS = ("G04", "G05", "G06")
PRODUCER_SOURCE_PATH = "validation/calibration_v2/run_provenance_v2.py"
PROVENANCE_SCHEMA_RELATIVE_PATH = (
    "validation/calibration_v2/schemas/"
    "p06-run-provenance-receipt-v2.schema.json"
)
RUN_INPUT_MANIFEST_SCHEMA_RELATIVE_PATH = (
    "validation/calibration_v2/schemas/"
    "p06-run-input-manifest-v2.schema.json"
)
FAILURE_SCHEMA_RELATIVE_PATH = (
    "validation/calibration_v2/schemas/p06-calibration-failure-v2.schema.json"
)
RUN_LEDGER_SCHEMA_RELATIVE_PATH = (
    "validation/calibration_v2/schemas/calibration-run-ledger-v2.schema.json"
)

FIXED_EXCLUSIONS = (
    {
        "path": RUN_LEDGER_PATH,
        "reason": "run_ledger_binds_run_input_manifest",
    },
    {"path": RUN_INPUT_MANIFEST_PATH, "reason": "manifest_self"},
)

FAILURE_INTEGRATION_REQUIREMENTS_V2 = (
    "The finalized failure remains a p06_calibration_failure_v2 document; its "
    "existing schema is not extended by this module.",
    "failure_bindings.artifact_manifest must be applicable and must equal the "
    "final p06-run-input-manifest-v2 file binding.",
    "The run ledger supplies every finalized candidate and terminal failure file "
    "binding independently to manifest verification.",
    "A mandatory run-ledger semantic verifier must complete authenticated replay "
    "before the manifest derives any failure relation from that ledger.",
    "The manifest records only failure_identity_sha256, never a failure content "
    "address or content-addressed path, so the exclusion is cycle-free.",
    "failure_identity_sha256 removes artifact_sha256 and normalizes only the "
    "cyclic manifest binding digest and size; every other failure field remains "
    "authenticated.",
    "Verification is bidirectional: each declared identity must reopen one "
    "finalized failure and every supplied cyclic failure must be declared.",
)

_SHA256_RE = re.compile(r"^(?!0{64}$)[0-9a-f]{64}$")
_COMMIT_RE = re.compile(r"^[0-9a-f]{40}$")
_IDENTIFIER_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
_SAFE_PATH_RE = re.compile(
    r"^(?!/)(?!.*\\)(?!.*//)(?!.*(?:^|/)\.\.?(?:/|$))"
    r"(?!.*/$)[A-Za-z0-9._/-]+$"
)
_FAILURE_PATH_RE = re.compile(r"^failures/[0-9a-f]{64}\.json$")

_AUTHORITY_SPECS = (
    {
        "id": "baseline_ablation_budget_v2",
        "artifact_kind": "p06_baseline_ablation_budget_preregistration",
        "path": "validation/calibration_v2/contracts/baseline-ablation-budget-v2.json",
        "size_bytes": 8475,
        "file_sha256": "1885aa30b46f72ed1de0570a3de5f615cf788ec0d494ed5396731279763da4c8",
        "schema_path": "validation/calibration_v2/schemas/baseline-ablation-budget-v2.schema.json",
        "schema_size_bytes": 8722,
        "schema_file_sha256": "080cc48a86569d68aecb0ca9384c89300df57dbeaa995e0651cf6082c969416b",
        "self_field": "artifact_sha256",
        "self_sha256": "405d9ca4413e7e291315257682f206d951a081f052d5ecee6f3a36ac72cd22be",
    },
    {
        "id": "calibration_plan_v2",
        "artifact_kind": "p06_plane_aware_joint_calibration_plan",
        "path": "validation/calibration_v2/contracts/calibration-plan-v2.json",
        "size_bytes": 21234,
        "file_sha256": "1977c85b9a3b7001294a04d33e7654ae20ffb4266ac0c8d2dc76880bdec99fef",
        "schema_path": "validation/calibration_v2/schemas/calibration-plan-v2.schema.json",
        "schema_size_bytes": 32022,
        "schema_file_sha256": "09a21861104bd1b03667d1207a79d523386ad4431e710ba44e4d298180753c09",
        "self_field": "plan_sha256",
        "self_sha256": "e6070a7cdd8f3b53231635027055669c8319d311af1790d672723d6e7e048d0f",
    },
    {
        "id": "candidate_evidence_policy_v2",
        "artifact_kind": "candidate_evidence_policy_preregistration",
        "path": "validation/calibration_v2/contracts/candidate-evidence-policy-v2.json",
        "size_bytes": 23800,
        "file_sha256": "d6df835467485f59b253e12d8e80cb8c8fa21dd308566ab3634495ccc8604433",
        "schema_path": "validation/calibration_v2/schemas/candidate-evidence-policy-v2.schema.json",
        "schema_size_bytes": 25040,
        "schema_file_sha256": "581a3bb6ba0ec3ea288076685124a9e7fd332aa883ee2165f18a27a4fb1c249e",
        "self_field": "artifact_sha256",
        "self_sha256": "70860c19f36efe41401e16381c80d6102b37f683056b2e3210a67e9d0b66dc75",
    },
    {
        "id": "compiler_contract_v2",
        "artifact_kind": "plane_aware_state_conditioned_leaf_compiler_contract",
        "path": "validation/calibration_v2/contracts/compiler-contract-v2.json",
        "size_bytes": 26462,
        "file_sha256": "8c2f532ff126fd5517040a05c9f8669d2a83d1d7220f61fed5933d5fa470470a",
        "schema_path": "validation/calibration_v2/schemas/compiler-contract-v2.schema.json",
        "schema_size_bytes": 27445,
        "schema_file_sha256": "5f7a49e1f585e4f0e108e733ae3c6f28b47869b3cc2909419688714e76f57897",
        "self_field": "artifact_sha256",
        "self_sha256": "797d6fda359a6bfaca9487a31b0078a5eba8e41fdb6fd0985390e20c25df8237",
    },
    {
        "id": "shared_bank_configuration_identity_v2",
        "artifact_kind": "shared_bank_configuration_identity_preregistration",
        "path": (
            "validation/calibration_v2/contracts/"
            "shared-bank-configuration-identity-v2.json"
        ),
        "size_bytes": 13164,
        "file_sha256": "48f5eef7cf9f7c513cf8e6568b3eeb4d607845c1e70e6c39b6ca0192a4c297de",
        "schema_path": (
            "validation/calibration_v2/schemas/"
            "shared-bank-configuration-identity-v2.schema.json"
        ),
        "schema_size_bytes": 13946,
        "schema_file_sha256": "0cee4c9ed9083d734491d90eaa3f02265b07295d7873733c006cce9df317147c",
        "self_field": "artifact_sha256",
        "self_sha256": "e522afa73e8dc01c51303d1d1d99a95fe2ea78f968a2696dc0583f695fce7c37",
    },
)


class RunProvenanceV2Error(ValueError):
    """A P06 provenance byte, identity, or closure relation is invalid."""


PayloadReopenerV2 = Callable[[Mapping[str, object]], bytes]


@dataclass(frozen=True)
class ContentBindingV2:
    path: str
    sha256: str
    size_bytes: int

    @classmethod
    def from_mapping(
        cls,
        value: Mapping[str, object],
        *,
        label: str,
    ) -> "ContentBindingV2":
        if type(value) is not dict or set(value) != {
            "path",
            "sha256",
            "size_bytes",
        }:
            raise RunProvenanceV2Error(f"{label} field set differs")
        path = value["path"]
        digest = value["sha256"]
        size = value["size_bytes"]
        if type(path) is not str or _SAFE_PATH_RE.fullmatch(path) is None:
            raise RunProvenanceV2Error(f"{label} path is unsafe")
        if not _is_sha256(digest):
            raise RunProvenanceV2Error(f"{label} SHA-256 is invalid")
        if type(size) is not int or size < 1:
            raise RunProvenanceV2Error(f"{label} size is invalid")
        return cls(path=path, sha256=digest, size_bytes=size)

    def document(self) -> Mapping[str, object]:
        return {
            "path": self.path,
            "sha256": self.sha256,
            "size_bytes": self.size_bytes,
        }


@dataclass(frozen=True)
class TypedArtifactBindingV2:
    id: str
    artifact_kind: str
    content_type: str
    schema_sha256: Optional[str]
    path: str
    sha256: str
    size_bytes: int

    @classmethod
    def from_mapping(
        cls,
        value: Mapping[str, object],
        *,
        label: str,
    ) -> "TypedArtifactBindingV2":
        expected = {
            "id",
            "artifact_kind",
            "content_type",
            "schema_sha256",
            "path",
            "sha256",
            "size_bytes",
        }
        if type(value) is not dict or set(value) != expected:
            raise RunProvenanceV2Error(f"{label} field set differs")
        identifier = value["id"]
        kind = value["artifact_kind"]
        content_type = value["content_type"]
        schema_sha256 = value["schema_sha256"]
        if (
            type(identifier) is not str
            or _IDENTIFIER_RE.fullmatch(identifier) is None
            or type(kind) is not str
            or _IDENTIFIER_RE.fullmatch(kind) is None
            or content_type
            not in {"canonical_json", "json_schema", "opaque_bytes"}
        ):
            raise RunProvenanceV2Error(f"{label} type identity is invalid")
        if content_type == "canonical_json":
            if not _is_sha256(schema_sha256):
                raise RunProvenanceV2Error(
                    f"{label} canonical JSON schema identity is invalid"
                )
        elif schema_sha256 is not None:
            raise RunProvenanceV2Error(
                f"{label} non-document schema identity must be null"
            )
        content = ContentBindingV2.from_mapping(
            {
                "path": value["path"],
                "sha256": value["sha256"],
                "size_bytes": value["size_bytes"],
            },
            label=label,
        )
        return cls(
            id=identifier,
            artifact_kind=kind,
            content_type=content_type,
            schema_sha256=schema_sha256,
            path=content.path,
            sha256=content.sha256,
            size_bytes=content.size_bytes,
        )

    @property
    def content_binding(self) -> ContentBindingV2:
        return ContentBindingV2(self.path, self.sha256, self.size_bytes)

    def document(self) -> Mapping[str, object]:
        return {
            "id": self.id,
            "artifact_kind": self.artifact_kind,
            "content_type": self.content_type,
            "schema_sha256": self.schema_sha256,
            "path": self.path,
            "sha256": self.sha256,
            "size_bytes": self.size_bytes,
        }


@dataclass(frozen=True)
class VerifiedGateReceiptV2:
    gate_id: str
    artifact_kind: str
    schema_sha256: str
    source_commit: str
    working_tree_clean: bool
    current_source: bool
    status: str
    holdout_accessed: bool
    closure_bindings: Tuple[TypedArtifactBindingV2, ...]


@dataclass(frozen=True)
class VerifiedCommandPlanV2:
    artifact_kind: str
    schema_sha256: str
    run_id: str
    plan_id: str
    source_commit: str
    status: str
    holdout_accessed: bool
    required_input_closure: Tuple[TypedArtifactBindingV2, ...]


GateReceiptVerifierV2 = Callable[
    [TypedArtifactBindingV2, bytes],
    VerifiedGateReceiptV2,
]
CommandPlanVerifierV2 = Callable[
    [TypedArtifactBindingV2, bytes],
    VerifiedCommandPlanV2,
]
FailureSemanticVerifierV2 = Callable[
    [Mapping[str, object], bytes],
    Mapping[str, object],
]
RunLedgerSemanticVerifierV2 = Callable[
    [TypedArtifactBindingV2, bytes],
    Mapping[str, object],
]


@dataclass(frozen=True)
class AuthenticatedAuthoritiesV2:
    documents: Tuple[Tuple[str, Mapping[str, object]], ...]

    @property
    def authority_bindings(self) -> Mapping[str, object]:
        return authority_bindings_v2()

    @property
    def input_bindings(self) -> Tuple[Mapping[str, object], ...]:
        return authority_input_bindings_v2()


@dataclass(frozen=True)
class VerifiedRunProvenanceReceiptV2:
    document: Mapping[str, object]
    binding: Optional[TypedArtifactBindingV2]
    source_commit: str
    gate_receipts: Tuple[VerifiedGateReceiptV2, ...]


@dataclass(frozen=True)
class FailureCycleExclusionV2:
    failure_identity_sha256: str

    def __post_init__(self) -> None:
        if not _is_sha256(self.failure_identity_sha256):
            raise RunProvenanceV2Error(
                "failure cycle-exclusion identity is invalid"
            )

    def document(self) -> Mapping[str, object]:
        return {
            "failure_identity_sha256": self.failure_identity_sha256,
            "relation": "failure_binds_this_manifest_and_is_cycle_excluded",
        }


@dataclass(frozen=True)
class _LedgerFailureRelationV2:
    binding: ContentBindingV2
    role: str
    split: Optional[str]
    candidate_vector_sha256: Optional[str]
    shared_bank_configuration_sha256: Optional[str]
    attempt_ledger_binding: Optional[ContentBindingV2]


@dataclass(frozen=True)
class VerifiedRunInputManifestV2:
    document: Mapping[str, object]
    binding: TypedArtifactBindingV2
    provenance: VerifiedRunProvenanceReceiptV2
    failure_identities: Tuple[str, ...]


def canonical_json_bytes_v2(value: object) -> bytes:
    try:
        return json.dumps(
            value,
            sort_keys=True,
            separators=(",", ":"),
            ensure_ascii=False,
            allow_nan=False,
        ).encode("utf-8")
    except (TypeError, ValueError) as error:
        raise RunProvenanceV2Error("value is not strict JSON") from error


def canonical_json_file_bytes_v2(value: object) -> bytes:
    return canonical_json_bytes_v2(value) + b"\n"


def _sha256(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def _is_sha256(value: object) -> bool:
    return type(value) is str and _SHA256_RE.fullmatch(value) is not None


def _snapshot_json(value: object, *, label: str) -> object:
    try:
        return json.loads(canonical_json_bytes_v2(value))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise RunProvenanceV2Error(f"{label} is not strict JSON") from error


def _reject_duplicate_pairs(
    pairs: Sequence[Tuple[str, object]],
) -> Mapping[str, object]:
    result = {}
    for key, value in pairs:
        if key in result:
            raise RunProvenanceV2Error(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def _reject_nonfinite(value: str) -> object:
    raise RunProvenanceV2Error(f"non-finite JSON number: {value}")


def _parse_json_object(payload: bytes, *, label: str) -> Mapping[str, object]:
    if type(payload) is not bytes or payload.startswith(b"\xef\xbb\xbf"):
        raise RunProvenanceV2Error(f"{label} is not plain UTF-8 JSON bytes")
    try:
        document = json.loads(
            payload,
            object_pairs_hook=_reject_duplicate_pairs,
            parse_constant=_reject_nonfinite,
        )
    except RunProvenanceV2Error:
        raise
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise RunProvenanceV2Error(f"{label} is not valid JSON") from error
    if type(document) is not dict:
        raise RunProvenanceV2Error(f"{label} is not a JSON object")
    return document


def _parse_canonical_file(payload: bytes, *, label: str) -> Mapping[str, object]:
    if (
        not payload
        or not payload.endswith(b"\n")
        or payload.endswith(b"\n\n")
        or b"\r" in payload
    ):
        raise RunProvenanceV2Error(
            f"{label} must end in exactly one LF and contain no CR"
        )
    document = _parse_json_object(payload, label=label)
    if canonical_json_file_bytes_v2(document) != payload:
        raise RunProvenanceV2Error(f"{label} is not canonical JSON")
    return document


def _read_regular_file(path: Path, *, label: str) -> bytes:
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        raise RunProvenanceV2Error(f"{label} cannot be opened") from error
    try:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode):
            raise RunProvenanceV2Error(f"{label} is not a regular file")
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
        or len(payload) != after.st_size
    ):
        raise RunProvenanceV2Error(f"{label} changed while being read")
    return payload


def _load_schema(path: Path, expected_sha256: str, *, label: str) -> Mapping[str, object]:
    payload = _read_regular_file(path, label=label)
    if _sha256(payload) != expected_sha256:
        raise RunProvenanceV2Error(f"{label} bytes differ from their frozen digest")
    schema = _parse_json_object(payload, label=label)
    try:
        jsonschema.Draft202012Validator.check_schema(schema)
    except jsonschema.SchemaError as error:
        raise RunProvenanceV2Error(f"{label} is not a valid schema") from error
    return schema


def _validate_schema(
    document: Mapping[str, object],
    schema: Mapping[str, object],
    *,
    label: str,
) -> None:
    try:
        errors = sorted(
            jsonschema.Draft202012Validator(schema).iter_errors(document),
            key=lambda error: tuple(str(part) for part in error.absolute_path),
        )
    except (TypeError, ValueError, jsonschema.SchemaError) as error:
        raise RunProvenanceV2Error(f"{label} schema evaluation failed") from error
    if errors:
        details = []
        for error in errors[:8]:
            location = "/".join(str(part) for part in error.absolute_path) or "<root>"
            details.append(f"{location}: {error.message}")
        raise RunProvenanceV2Error(
            f"{label} schema validation failed: " + "; ".join(details)
        )


def _semantic_sha256(document: Mapping[str, object], *, field: str) -> str:
    snapshot = _snapshot_json(document, label="self-hash input")
    if type(snapshot) is not dict:
        raise RunProvenanceV2Error("self-hash input is not an object")
    snapshot.pop(field, None)
    return _sha256(canonical_json_bytes_v2(snapshot))


def _reopen_payload(
    binding: ContentBindingV2,
    reopener: PayloadReopenerV2,
    *,
    label: str,
) -> bytes:
    if not callable(reopener):
        raise RunProvenanceV2Error(f"{label} reopener is required")
    try:
        value = reopener(binding.document())
    except Exception as error:
        raise RunProvenanceV2Error(f"{label} cannot be reopened") from error
    if type(value) is not bytes:
        raise RunProvenanceV2Error(f"{label} reopener returned non-bytes")
    payload = bytes(value)
    if len(payload) != binding.size_bytes or _sha256(payload) != binding.sha256:
        raise RunProvenanceV2Error(f"{label} bytes differ from their binding")
    return payload


def _require_stable_reopen(
    binding: ContentBindingV2,
    payload: bytes,
    reopener: PayloadReopenerV2,
    *,
    label: str,
) -> None:
    if _reopen_payload(binding, reopener, label=label) != payload:
        raise RunProvenanceV2Error(f"{label} changed across semantic verification")


def authority_bindings_v2() -> Mapping[str, object]:
    return {
        str(spec["id"]): {
            "file_sha256": spec["file_sha256"],
            "schema_file_sha256": spec["schema_file_sha256"],
            "self_sha256": spec["self_sha256"],
        }
        for spec in _AUTHORITY_SPECS
    }


def authority_input_bindings_v2() -> Tuple[Mapping[str, object], ...]:
    return tuple(
        {
            "id": spec["id"],
            "path": spec["path"],
            "sha256": spec["file_sha256"],
            "size_bytes": spec["size_bytes"],
        }
        for spec in _AUTHORITY_SPECS
    )


def authority_closure_bindings_v2() -> Tuple[TypedArtifactBindingV2, ...]:
    bindings = []
    for spec in _AUTHORITY_SPECS:
        bindings.append(
            TypedArtifactBindingV2(
                id=str(spec["id"]),
                artifact_kind=str(spec["artifact_kind"]),
                content_type="canonical_json",
                schema_sha256=str(spec["schema_file_sha256"]),
                path=str(spec["path"]),
                sha256=str(spec["file_sha256"]),
                size_bytes=int(spec["size_bytes"]),
            )
        )
        bindings.append(
            TypedArtifactBindingV2(
                id=f"{spec['id']}_schema",
                artifact_kind="json_schema_2020_12",
                content_type="json_schema",
                schema_sha256=None,
                path=str(spec["schema_path"]),
                sha256=str(spec["schema_file_sha256"]),
                size_bytes=int(spec["schema_size_bytes"]),
            )
        )
    return tuple(bindings)


def authenticate_authorities_v2(
    payload_reopener: PayloadReopenerV2,
) -> AuthenticatedAuthoritiesV2:
    """Authenticate exact bytes, schemas, and self hashes for all five authorities."""

    documents = []
    snapshots = []
    for spec in _AUTHORITY_SPECS:
        contract_binding = ContentBindingV2(
            str(spec["path"]),
            str(spec["file_sha256"]),
            int(spec["size_bytes"]),
        )
        schema_binding = ContentBindingV2(
            str(spec["schema_path"]),
            str(spec["schema_file_sha256"]),
            int(spec["schema_size_bytes"]),
        )
        contract_payload = _reopen_payload(
            contract_binding,
            payload_reopener,
            label=f"{spec['id']} authority",
        )
        schema_payload = _reopen_payload(
            schema_binding,
            payload_reopener,
            label=f"{spec['id']} authority schema",
        )
        contract = _parse_json_object(
            contract_payload,
            label=f"{spec['id']} authority",
        )
        schema = _parse_json_object(
            schema_payload,
            label=f"{spec['id']} authority schema",
        )
        try:
            jsonschema.Draft202012Validator.check_schema(schema)
        except jsonschema.SchemaError as error:
            raise RunProvenanceV2Error(
                f"{spec['id']} authority schema is invalid"
            ) from error
        _validate_schema(contract, schema, label=f"{spec['id']} authority")
        self_field = str(spec["self_field"])
        if (
            contract.get(self_field) != spec["self_sha256"]
            or _semantic_sha256(contract, field=self_field) != spec["self_sha256"]
        ):
            raise RunProvenanceV2Error(f"{spec['id']} authority self-hash differs")
        documents.append((str(spec["id"]), contract))
        snapshots.extend(
            (
                (contract_binding, contract_payload, f"{spec['id']} authority"),
                (schema_binding, schema_payload, f"{spec['id']} authority schema"),
            )
        )
    observed_bundle = _sha256(
        canonical_json_bytes_v2(list(authority_input_bindings_v2()))
    )
    if observed_bundle != INPUT_BUNDLE_SHA256:
        raise RunProvenanceV2Error("authenticated authority input bundle differs")
    for binding, payload, label in snapshots:
        _require_stable_reopen(
            binding,
            payload,
            payload_reopener,
            label=label,
        )
    return AuthenticatedAuthoritiesV2(tuple(documents))


def _gate_binding_from_row(
    row: Mapping[str, object],
    *,
    label: str,
) -> TypedArtifactBindingV2:
    if type(row) is not dict:
        raise RunProvenanceV2Error(f"{label} is not an object")
    return TypedArtifactBindingV2.from_mapping(
        {key: row.get(key) for key in (
            "id",
            "artifact_kind",
            "content_type",
            "schema_sha256",
            "path",
            "sha256",
            "size_bytes",
        )},
        label=label,
    )


def _verify_gate_receipts(
    gate_bindings: Sequence[Mapping[str, object]],
    *,
    payload_reopener: PayloadReopenerV2,
    gate_receipt_verifiers: Mapping[str, GateReceiptVerifierV2],
) -> Tuple[
    Tuple[Mapping[str, object], ...],
    Tuple[VerifiedGateReceiptV2, ...],
    str,
    Tuple[Tuple[ContentBindingV2, bytes, str], ...],
]:
    if type(gate_bindings) not in {list, tuple} or len(gate_bindings) != 3:
        raise RunProvenanceV2Error("exactly three gate receipt bindings are required")
    if (
        type(gate_receipt_verifiers) is not dict
        or tuple(gate_receipt_verifiers) != GATE_IDS
        or any(not callable(value) for value in gate_receipt_verifiers.values())
    ):
        raise RunProvenanceV2Error(
            "gate semantic verifiers must be the exact ordered G04/G05/G06 set"
        )
    typed = tuple(
        TypedArtifactBindingV2.from_mapping(
            value,
            label=f"{GATE_IDS[index]} receipt binding",
        )
        for index, value in enumerate(gate_bindings)
    )
    if tuple(binding.id for binding in typed) != GATE_IDS:
        raise RunProvenanceV2Error("gate receipt order differs from G04/G05/G06")
    rows = []
    claims = []
    snapshots = []
    for binding in typed:
        if binding.content_type != "canonical_json" or binding.schema_sha256 is None:
            raise RunProvenanceV2Error(
                f"{binding.id} receipt lacks an explicit schema identity"
            )
        payload = _reopen_payload(
            binding.content_binding,
            payload_reopener,
            label=f"{binding.id} receipt",
        )
        try:
            claim = gate_receipt_verifiers[binding.id](binding, payload)
        except Exception as error:
            raise RunProvenanceV2Error(
                f"{binding.id} receipt semantic verification failed"
            ) from error
        if type(claim) is not VerifiedGateReceiptV2:
            raise RunProvenanceV2Error(
                f"{binding.id} semantic verifier returned the wrong claim type"
            )
        if (
            claim.gate_id != binding.id
            or claim.artifact_kind != binding.artifact_kind
            or claim.schema_sha256 != binding.schema_sha256
            or type(claim.source_commit) is not str
            or _COMMIT_RE.fullmatch(claim.source_commit) is None
            or claim.working_tree_clean is not True
            or claim.current_source is not True
            or claim.status != "pass"
            or claim.holdout_accessed is not False
        ):
            raise RunProvenanceV2Error(
                f"{binding.id} receipt does not prove a clean current-source pass"
            )
        closure = _normalize_verified_closure(
            claim.closure_bindings,
            label=f"{binding.id} verified transitive closure",
            minimum_count=1,
        )
        wrapper_id = f"{binding.id}_wrapper_manifest"
        wrapper = tuple(item for item in closure if item.id == wrapper_id)
        if (
            len(wrapper) != 1
            or wrapper[0].content_type != "canonical_json"
            or wrapper[0].schema_sha256 is None
        ):
            raise RunProvenanceV2Error(
                f"{binding.id} verified closure lacks its typed wrapper manifest"
            )
        closure_rows = [dict(item.document()) for item in closure]
        row = dict(binding.document())
        row.update(
            {
                "source_commit": claim.source_commit,
                "working_tree_clean": True,
                "current_source": True,
                "status": "pass",
                "holdout_accessed": False,
                "closure_bindings": closure_rows,
            }
        )
        rows.append(row)
        claims.append(claim)
        snapshots.append((binding.content_binding, payload, f"{binding.id} receipt"))
        for item in closure:
            closure_payload = _reopen_payload(
                item.content_binding,
                payload_reopener,
                label=f"{binding.id} closure artifact {item.path}",
            )
            snapshots.append(
                (
                    item.content_binding,
                    closure_payload,
                    f"{binding.id} closure artifact {item.path}",
                )
            )
    commits = {claim.source_commit for claim in claims}
    if len(commits) != 1:
        raise RunProvenanceV2Error("G04/G05/G06 source commits differ")
    return tuple(rows), tuple(claims), commits.pop(), tuple(snapshots)


def _normalize_verified_closure(
    values: object,
    *,
    label: str,
    minimum_count: int,
) -> Tuple[TypedArtifactBindingV2, ...]:
    if (
        type(values) is not tuple
        or len(values) < minimum_count
        or any(type(value) is not TypedArtifactBindingV2 for value in values)
    ):
        raise RunProvenanceV2Error(
            f"{label} must be an immutable typed binding tuple"
        )
    bindings = tuple(values)
    identifiers = [binding.id for binding in bindings]
    paths = [binding.path for binding in bindings]
    digests = [binding.sha256 for binding in bindings]
    if (
        paths != sorted(paths)
        or len(set(identifiers)) != len(identifiers)
        or len(set(paths)) != len(paths)
        or len(set(digests)) != len(digests)
        or set(paths) & {RUN_LEDGER_PATH, RUN_INPUT_MANIFEST_PATH}
        or any(_FAILURE_PATH_RE.fullmatch(path) is not None for path in paths)
    ):
        raise RunProvenanceV2Error(
            f"{label} is unordered, duplicated, aliased, or cyclic"
        )
    return bindings


def _required_schema_from_closure(
    closure: Sequence[TypedArtifactBindingV2],
    *,
    identifier: str,
    path: str,
    label: str,
) -> TypedArtifactBindingV2:
    matches = tuple(binding for binding in closure if binding.id == identifier)
    if (
        len(matches) != 1
        or matches[0].artifact_kind != "json_schema_2020_12"
        or matches[0].content_type != "json_schema"
        or matches[0].schema_sha256 is not None
        or matches[0].path != path
    ):
        raise RunProvenanceV2Error(f"{label} binding is absent or mistyped")
    return matches[0]


def _current_execution_environment() -> Tuple[
    Mapping[str, object],
    Tuple[Mapping[str, object], ...],
    Path,
    bytes,
]:
    uname = host_platform.uname()
    platform_row = {
        "os": uname.system,
        "release": uname.release,
        "machine": uname.machine,
    }
    if any(type(value) is not str or not value for value in platform_row.values()):
        raise RunProvenanceV2Error("current platform identity is unavailable")
    try:
        executable = Path(sys.executable).resolve(strict=True)
    except OSError as error:
        raise RunProvenanceV2Error(
            "current Python executable cannot be resolved"
        ) from error
    executable_payload = _read_regular_file(
        executable,
        label="current Python executable",
    )
    version = sys.version
    if not version:
        raise RunProvenanceV2Error("current Python version is unavailable")
    toolchain = (
        {
            "id": "python",
            "executable": str(executable),
            "executable_sha256": _sha256(executable_payload),
            "version": version,
            "version_sha256": _sha256(version.encode("utf-8")),
        },
    )
    return platform_row, toolchain, executable, executable_payload


def _derive_provenance_material(
    *,
    run_id: str,
    gate_receipt_bindings: Sequence[Mapping[str, object]],
    producer_source_binding: Mapping[str, object],
    command_plan_binding: Mapping[str, object],
    authority_payload_reopener: PayloadReopenerV2,
    payload_reopener: PayloadReopenerV2,
    gate_receipt_verifiers: Mapping[str, GateReceiptVerifierV2],
    command_plan_verifier: CommandPlanVerifierV2,
) -> Tuple[Mapping[str, object], Tuple[VerifiedGateReceiptV2, ...]]:
    if type(run_id) is not str or _IDENTIFIER_RE.fullmatch(run_id) is None:
        raise RunProvenanceV2Error("run ID is invalid")
    authenticated = authenticate_authorities_v2(authority_payload_reopener)
    gate_rows, gate_claims, source_commit, gate_snapshots = _verify_gate_receipts(
        gate_receipt_bindings,
        payload_reopener=payload_reopener,
        gate_receipt_verifiers=gate_receipt_verifiers,
    )
    producer = TypedArtifactBindingV2.from_mapping(
        producer_source_binding,
        label="provenance producer source",
    )
    if (
        producer.id != "run_provenance_v2_producer"
        or producer.artifact_kind != "python_source"
        or producer.content_type != "opaque_bytes"
        or producer.schema_sha256 is not None
        or producer.path != PRODUCER_SOURCE_PATH
    ):
        raise RunProvenanceV2Error("provenance producer source identity differs")
    producer_payload = _reopen_payload(
        producer.content_binding,
        payload_reopener,
        label="provenance producer source",
    )
    current_producer_payload = _read_regular_file(
        Path(__file__).resolve(strict=True),
        label="current provenance producer source",
    )
    if producer_payload != current_producer_payload:
        raise RunProvenanceV2Error(
            "provenance producer source does not match the executing implementation"
        )
    command = TypedArtifactBindingV2.from_mapping(
        command_plan_binding,
        label="P06 command plan",
    )
    if (
        command.id != "p06_command_plan"
        or command.content_type != "canonical_json"
        or command.schema_sha256 is None
        or not callable(command_plan_verifier)
    ):
        raise RunProvenanceV2Error("P06 command-plan type identity differs")
    command_payload = _reopen_payload(
        command.content_binding,
        payload_reopener,
        label="P06 command plan",
    )
    try:
        command_claim = command_plan_verifier(command, command_payload)
    except Exception as error:
        raise RunProvenanceV2Error("P06 command-plan semantic verification failed") from error
    if (
        type(command_claim) is not VerifiedCommandPlanV2
        or command_claim.artifact_kind != command.artifact_kind
        or command_claim.schema_sha256 != command.schema_sha256
        or command_claim.run_id != run_id
        or command_claim.plan_id != PLAN_ID
        or command_claim.source_commit != source_commit
        or command_claim.status != "pass"
        or command_claim.holdout_accessed is not False
    ):
        raise RunProvenanceV2Error("P06 command-plan semantic identity differs")
    command_closure = _normalize_verified_closure(
        command_claim.required_input_closure,
        label="P06 command-plan required-input closure",
        minimum_count=3,
    )
    _required_schema_from_closure(
        command_closure,
        identifier="p06_calibration_failure_v2_schema",
        path=FAILURE_SCHEMA_RELATIVE_PATH,
        label="P06 failure schema",
    )
    _required_schema_from_closure(
        command_closure,
        identifier="p06_calibration_run_ledger_v2_schema",
        path=RUN_LEDGER_SCHEMA_RELATIVE_PATH,
        label="P06 run-ledger schema",
    )
    if not any(binding.content_type != "json_schema" for binding in command_closure):
        raise RunProvenanceV2Error(
            "P06 command-plan closure has no run-specific non-schema input"
        )
    command_closure_payloads = []
    for binding in command_closure:
        payload = _reopen_payload(
            binding.content_binding,
            payload_reopener,
            label=f"P06 command-plan input {binding.path}",
        )
        if binding.content_type == "json_schema":
            schema = _parse_json_object(
                payload,
                label=f"P06 command-plan schema input {binding.path}",
            )
            try:
                jsonschema.Draft202012Validator.check_schema(schema)
            except jsonschema.SchemaError as error:
                raise RunProvenanceV2Error(
                    f"P06 command-plan schema input {binding.path} is invalid"
                ) from error
        command_closure_payloads.append(payload)
    (
        normalized_platform,
        normalized_toolchain,
        python_executable,
        python_executable_payload,
    ) = _current_execution_environment()
    environment_sha256 = _sha256(
        canonical_json_bytes_v2(
            {
                "platform": normalized_platform,
                "toolchain": list(normalized_toolchain),
            }
        )
    )
    material = {
        "schema_version": "2.0.0",
        "artifact_kind": "p06_run_provenance_receipt_v2",
        "receipt_role": "authenticated_current_source_p06_run_provenance",
        "authority_bindings": authenticated.authority_bindings,
        "run_id": run_id,
        "plan_id": PLAN_ID,
        "plan_file_sha256": PLAN_FILE_SHA256,
        "input_bundle_sha256": INPUT_BUNDLE_SHA256,
        "input_bindings": list(authenticated.input_bindings),
        "source_commit": source_commit,
        "working_tree_clean": True,
        "current_source": True,
        "status": "pass",
        "holdout_accessed": False,
        "gate_receipts": list(gate_rows),
        "producer_source": dict(producer.document()),
        "command_plan": dict(command.document()),
        "command_input_closure": [
            dict(binding.document()) for binding in command_closure
        ],
        "platform": normalized_platform,
        "toolchain": list(normalized_toolchain),
        "execution_environment_sha256": environment_sha256,
    }
    _require_stable_reopen(
        producer.content_binding,
        producer_payload,
        payload_reopener,
        label="provenance producer source",
    )
    _require_stable_reopen(
        command.content_binding,
        command_payload,
        payload_reopener,
        label="P06 command plan",
    )
    for binding, payload in zip(command_closure, command_closure_payloads):
        _require_stable_reopen(
            binding.content_binding,
            payload,
            payload_reopener,
            label=f"P06 command-plan input {binding.path}",
        )
    authenticate_authorities_v2(authority_payload_reopener)
    for binding, payload, label in gate_snapshots:
        _require_stable_reopen(
            binding,
            payload,
            payload_reopener,
            label=label,
        )
    _require_stable_reopen(
        producer.content_binding,
        producer_payload,
        payload_reopener,
        label="provenance producer source",
    )
    _require_stable_reopen(
        command.content_binding,
        command_payload,
        payload_reopener,
        label="P06 command plan",
    )
    for binding, payload in zip(command_closure, command_closure_payloads):
        _require_stable_reopen(
            binding.content_binding,
            payload,
            payload_reopener,
            label=f"P06 command-plan input {binding.path}",
        )
    if _read_regular_file(
        python_executable,
        label="current Python executable",
    ) != python_executable_payload:
        raise RunProvenanceV2Error(
            "current Python executable changed during provenance verification"
        )
    return material, gate_claims


def build_run_provenance_receipt_v2(
    *,
    run_id: str,
    gate_receipt_bindings: Sequence[Mapping[str, object]],
    producer_source_binding: Mapping[str, object],
    command_plan_binding: Mapping[str, object],
    authority_payload_reopener: PayloadReopenerV2,
    payload_reopener: PayloadReopenerV2,
    gate_receipt_verifiers: Mapping[str, GateReceiptVerifierV2],
    command_plan_verifier: CommandPlanVerifierV2,
) -> Mapping[str, object]:
    material, _ = _derive_provenance_material(
        run_id=run_id,
        gate_receipt_bindings=gate_receipt_bindings,
        producer_source_binding=producer_source_binding,
        command_plan_binding=command_plan_binding,
        authority_payload_reopener=authority_payload_reopener,
        payload_reopener=payload_reopener,
        gate_receipt_verifiers=gate_receipt_verifiers,
        command_plan_verifier=command_plan_verifier,
    )
    document = dict(material)
    document["receipt_sha256"] = _semantic_sha256(document, field="receipt_sha256")
    schema = _load_schema(
        PROVENANCE_SCHEMA_PATH,
        PROVENANCE_SCHEMA_SHA256,
        label="P06 run-provenance schema",
    )
    _validate_schema(document, schema, label="P06 run-provenance receipt")
    return document


def verify_run_provenance_receipt_v2(
    document: Mapping[str, object],
    *,
    authority_payload_reopener: PayloadReopenerV2,
    payload_reopener: PayloadReopenerV2,
    gate_receipt_verifiers: Mapping[str, GateReceiptVerifierV2],
    command_plan_verifier: CommandPlanVerifierV2,
    expected_run_id: Optional[str] = None,
) -> VerifiedRunProvenanceReceiptV2:
    snapshot = _snapshot_json(document, label="P06 run-provenance receipt")
    if type(snapshot) is not dict:
        raise RunProvenanceV2Error("P06 run-provenance receipt is not an object")
    schema = _load_schema(
        PROVENANCE_SCHEMA_PATH,
        PROVENANCE_SCHEMA_SHA256,
        label="P06 run-provenance schema",
    )
    _validate_schema(snapshot, schema, label="P06 run-provenance receipt")
    if snapshot["receipt_sha256"] != _semantic_sha256(
        snapshot,
        field="receipt_sha256",
    ):
        raise RunProvenanceV2Error("P06 run-provenance receipt self-hash differs")
    if expected_run_id is not None and snapshot["run_id"] != expected_run_id:
        raise RunProvenanceV2Error("P06 run-provenance run ID differs")
    gate_bindings = [
        _gate_binding_from_row(row, label=f"{GATE_IDS[index]} receipt").document()
        for index, row in enumerate(snapshot["gate_receipts"])
    ]
    material, gate_claims = _derive_provenance_material(
        run_id=str(snapshot["run_id"]),
        gate_receipt_bindings=gate_bindings,
        producer_source_binding=snapshot["producer_source"],
        command_plan_binding=snapshot["command_plan"],
        authority_payload_reopener=authority_payload_reopener,
        payload_reopener=payload_reopener,
        gate_receipt_verifiers=gate_receipt_verifiers,
        command_plan_verifier=command_plan_verifier,
    )
    expected = dict(material)
    expected["receipt_sha256"] = _semantic_sha256(expected, field="receipt_sha256")
    if snapshot != expected:
        raise RunProvenanceV2Error(
            "P06 run-provenance receipt differs from semantic re-derivation"
        )
    return VerifiedRunProvenanceReceiptV2(
        document=snapshot,
        binding=None,
        source_commit=str(snapshot["source_commit"]),
        gate_receipts=gate_claims,
    )


def _require_provenance_binding(
    value: Mapping[str, object],
) -> TypedArtifactBindingV2:
    binding = TypedArtifactBindingV2.from_mapping(
        value,
        label="P06 run-provenance receipt binding",
    )
    if (
        binding.id != "p06_run_provenance_receipt_v2"
        or binding.artifact_kind != "p06_run_provenance_receipt_v2"
        or binding.content_type != "canonical_json"
        or binding.schema_sha256 != PROVENANCE_SCHEMA_SHA256
        or binding.path != PROVENANCE_PATH
    ):
        raise RunProvenanceV2Error("P06 run-provenance receipt binding type differs")
    return binding


def reopen_run_provenance_receipt_v2(
    binding: Mapping[str, object],
    *,
    authority_payload_reopener: PayloadReopenerV2,
    payload_reopener: PayloadReopenerV2,
    gate_receipt_verifiers: Mapping[str, GateReceiptVerifierV2],
    command_plan_verifier: CommandPlanVerifierV2,
    expected_run_id: Optional[str] = None,
) -> VerifiedRunProvenanceReceiptV2:
    typed = _require_provenance_binding(binding)
    payload = _reopen_payload(
        typed.content_binding,
        payload_reopener,
        label="P06 run-provenance receipt",
    )
    document = _parse_canonical_file(payload, label="P06 run-provenance receipt")
    verified = verify_run_provenance_receipt_v2(
        document,
        authority_payload_reopener=authority_payload_reopener,
        payload_reopener=payload_reopener,
        gate_receipt_verifiers=gate_receipt_verifiers,
        command_plan_verifier=command_plan_verifier,
        expected_run_id=expected_run_id,
    )
    _require_stable_reopen(
        typed.content_binding,
        payload,
        payload_reopener,
        label="P06 run-provenance receipt",
    )
    return VerifiedRunProvenanceReceiptV2(
        document=verified.document,
        binding=typed,
        source_commit=verified.source_commit,
        gate_receipts=verified.gate_receipts,
    )


def _applicable_failure_dependency_bindings(
    failure_document: Mapping[str, object],
) -> Tuple[Tuple[str, ContentBindingV2], ...]:
    failure_bindings = failure_document.get("failure_bindings")
    if type(failure_bindings) is not dict:
        raise RunProvenanceV2Error(
            "P06 failure dependency bindings are absent"
        )
    dependencies = []
    for name, relation in failure_bindings.items():
        if name == "artifact_manifest":
            continue
        if type(relation) is not dict:
            continue
        if relation.get("applicable") is True:
            binding = relation.get("binding")
            if type(binding) is not dict:
                raise RunProvenanceV2Error(
                    f"P06 failure {name} dependency is malformed"
                )
            dependencies.append(
                (
                    str(name),
                    ContentBindingV2.from_mapping(
                        binding,
                        label=f"P06 failure {name} dependency",
                    ),
                )
            )
    recovery = failure_document.get("recovery")
    if type(recovery) is dict:
        resume_source = recovery.get("resume_source")
        if type(resume_source) is dict and resume_source.get("applicable") is True:
            binding = resume_source.get("binding")
            if type(binding) is not dict:
                raise RunProvenanceV2Error(
                    "P06 failure recovery resume dependency is malformed"
                )
            dependencies.append(
                (
                    "recovery.resume_source",
                    ContentBindingV2.from_mapping(
                        binding,
                        label="P06 failure recovery resume dependency",
                    ),
                )
            )
    return tuple(dependencies)


def failure_identity_sha256_v2(
    failure_document: Mapping[str, object],
    *,
    manifest_path: str = RUN_INPUT_MANIFEST_PATH,
) -> str:
    """Compute a failure identity independent of the cyclic manifest digest/size."""

    if manifest_path != RUN_INPUT_MANIFEST_PATH:
        raise RunProvenanceV2Error("failure cycle target is not the run-input manifest")
    snapshot = _snapshot_json(failure_document, label="P06 failure identity input")
    if type(snapshot) is not dict:
        raise RunProvenanceV2Error("P06 failure identity input is not an object")
    if (
        snapshot.get("artifact_kind") != "p06_calibration_failure_v2"
        or snapshot.get("status") != "failed_preserved"
        or type(snapshot.get("failure_bindings")) is not dict
    ):
        raise RunProvenanceV2Error("P06 failure identity fields differ")
    declared_identity = snapshot.pop("failure_identity_sha256", None)
    snapshot.pop("artifact_sha256", None)
    artifact_manifest = snapshot["failure_bindings"].get("artifact_manifest")
    if (
        type(artifact_manifest) is not dict
        or set(artifact_manifest) != {"applicable", "binding"}
        or artifact_manifest.get("applicable") is not True
        or type(artifact_manifest.get("binding")) is not dict
        or set(artifact_manifest["binding"]) != {"path", "sha256", "size_bytes"}
        or artifact_manifest["binding"].get("path") != manifest_path
        or not _is_sha256(artifact_manifest["binding"].get("sha256"))
        or type(artifact_manifest["binding"].get("size_bytes")) is not int
        or artifact_manifest["binding"].get("size_bytes") < 1
    ):
        raise RunProvenanceV2Error(
            "P06 failure does not expose one exact cyclic manifest binding"
        )
    snapshot["failure_bindings"]["artifact_manifest"] = {
        "applicable": True,
        "binding": {
            "path": manifest_path,
            "cycle_normalization": "digest_and_size_excluded_v1",
        },
    }
    manifest_digest = artifact_manifest["binding"]["sha256"]
    for name, dependency in _applicable_failure_dependency_bindings(snapshot):
        if (
            dependency.path in {RUN_INPUT_MANIFEST_PATH, RUN_LEDGER_PATH}
            or _FAILURE_PATH_RE.fullmatch(dependency.path) is not None
            or dependency.sha256 == manifest_digest
        ):
            raise RunProvenanceV2Error(
                f"P06 failure {name} creates an unsupported cycle"
            )
    identity = _sha256(canonical_json_bytes_v2(snapshot))
    if declared_identity is not None and declared_identity != identity:
        raise RunProvenanceV2Error("declared P06 failure identity differs")
    return identity


def build_failure_cycle_exclusion_v2(
    failure_document: Mapping[str, object],
) -> FailureCycleExclusionV2:
    return FailureCycleExclusionV2(
        failure_identity_sha256_v2(failure_document)
    )


def _binding_from_receipt_row(
    row: Mapping[str, object],
    *,
    label: str,
) -> TypedArtifactBindingV2:
    return _gate_binding_from_row(row, label=label)


def _local_schema_binding(
    *,
    identifier: str,
    path: str,
    expected_sha256: str,
    label: str,
) -> TypedArtifactBindingV2:
    payload = _read_regular_file(
        CALIBRATION_ROOT.parents[1] / path,
        label=label,
    )
    if _sha256(payload) != expected_sha256:
        raise RunProvenanceV2Error(f"{label} bytes differ from their frozen digest")
    return TypedArtifactBindingV2(
        id=identifier,
        artifact_kind="json_schema_2020_12",
        content_type="json_schema",
        schema_sha256=None,
        path=path,
        sha256=expected_sha256,
        size_bytes=len(payload),
    )


def _base_closure_bindings(
    provenance: VerifiedRunProvenanceReceiptV2,
) -> Tuple[TypedArtifactBindingV2, ...]:
    if provenance.binding is None:
        raise RunProvenanceV2Error(
            "manifest construction requires a bound provenance receipt"
        )
    document = provenance.document
    result = list(authority_closure_bindings_v2())
    result.extend(
        (
            _local_schema_binding(
                identifier="p06_run_provenance_receipt_v2_schema",
                path=PROVENANCE_SCHEMA_RELATIVE_PATH,
                expected_sha256=PROVENANCE_SCHEMA_SHA256,
                label="P06 run-provenance receipt schema closure",
            ),
            _local_schema_binding(
                identifier="p06_run_input_manifest_v2_schema",
                path=RUN_INPUT_MANIFEST_SCHEMA_RELATIVE_PATH,
                expected_sha256=RUN_INPUT_MANIFEST_SCHEMA_SHA256,
                label="P06 run-input manifest schema closure",
            ),
        )
    )
    for index, row in enumerate(document["gate_receipts"]):
        result.append(
            _binding_from_receipt_row(row, label=f"{GATE_IDS[index]} receipt")
        )
        result.extend(
            TypedArtifactBindingV2.from_mapping(
                value,
                label=f"{GATE_IDS[index]} closure binding {closure_index}",
            )
            for closure_index, value in enumerate(row["closure_bindings"])
        )
    result.append(
        TypedArtifactBindingV2.from_mapping(
            document["producer_source"],
            label="provenance producer source",
        )
    )
    result.append(
        TypedArtifactBindingV2.from_mapping(
            document["command_plan"],
            label="P06 command plan",
        )
    )
    result.extend(
        TypedArtifactBindingV2.from_mapping(
            value,
            label=f"P06 command input binding {index}",
        )
        for index, value in enumerate(document["command_input_closure"])
    )
    result.append(provenance.binding)
    return tuple(result)


def _normalize_binding_closure(
    base: Sequence[TypedArtifactBindingV2],
) -> Tuple[TypedArtifactBindingV2, ...]:
    bindings = list(base)
    identifiers = [binding.id for binding in bindings]
    paths = [binding.path for binding in bindings]
    digests = [binding.sha256 for binding in bindings]
    forbidden = {RUN_LEDGER_PATH, RUN_INPUT_MANIFEST_PATH}
    if (
        len(set(identifiers)) != len(identifiers)
        or len(set(paths)) != len(paths)
        or len(set(digests)) != len(digests)
        or set(paths) & forbidden
        or any(_FAILURE_PATH_RE.fullmatch(path) is not None for path in paths)
    ):
        raise RunProvenanceV2Error(
            "run-input closure is duplicated, aliased, or contains an excluded cycle"
        )
    return tuple(sorted(bindings, key=lambda binding: binding.path))


def _normalize_failure_exclusions(
    values: Sequence[FailureCycleExclusionV2],
) -> Tuple[FailureCycleExclusionV2, ...]:
    if type(values) not in {list, tuple} or any(
        type(value) is not FailureCycleExclusionV2 for value in values
    ):
        raise RunProvenanceV2Error(
            "failure cycle exclusions must be verified identity objects"
        )
    identities = [value.failure_identity_sha256 for value in values]
    if len(set(identities)) != len(identities):
        raise RunProvenanceV2Error("failure cycle-exclusion identities repeat")
    return tuple(sorted(values, key=lambda value: value.failure_identity_sha256))


def _closure_directories(
    bindings: Sequence[TypedArtifactBindingV2],
) -> Tuple[str, ...]:
    directories = set()
    for binding in bindings:
        parts = PurePosixPath(binding.path).parts
        for depth in range(1, len(parts)):
            directories.add(PurePosixPath(*parts[:depth]).as_posix())
    return tuple(sorted(directories))


def _closure_sha256(
    *,
    artifacts: Sequence[Mapping[str, object]],
    directories: Sequence[str],
    failure_cycle_exclusions: Sequence[Mapping[str, object]],
) -> str:
    return _sha256(
        canonical_json_bytes_v2(
            {
                "artifacts": list(artifacts),
                "directories": list(directories),
                "failure_cycle_exclusions": list(failure_cycle_exclusions),
                "fixed_exclusions": list(FIXED_EXCLUSIONS),
            }
        )
    )


def _require_manifest_binding(
    value: Mapping[str, object],
) -> TypedArtifactBindingV2:
    binding = TypedArtifactBindingV2.from_mapping(
        value,
        label="P06 run-input manifest binding",
    )
    if (
        binding.id != "p06_run_input_manifest_v2"
        or binding.artifact_kind != "p06_run_input_manifest_v2"
        or binding.content_type != "canonical_json"
        or binding.schema_sha256 != RUN_INPUT_MANIFEST_SCHEMA_SHA256
        or binding.path != RUN_INPUT_MANIFEST_PATH
    ):
        raise RunProvenanceV2Error("P06 run-input manifest binding type differs")
    return binding


def build_run_input_manifest_v2(
    *,
    provenance_receipt_binding: Mapping[str, object],
    failure_cycle_exclusions: Sequence[FailureCycleExclusionV2],
    authority_payload_reopener: PayloadReopenerV2,
    payload_reopener: PayloadReopenerV2,
    gate_receipt_verifiers: Mapping[str, GateReceiptVerifierV2],
    command_plan_verifier: CommandPlanVerifierV2,
    expected_run_id: Optional[str] = None,
) -> Mapping[str, object]:
    provenance = reopen_run_provenance_receipt_v2(
        provenance_receipt_binding,
        authority_payload_reopener=authority_payload_reopener,
        payload_reopener=payload_reopener,
        gate_receipt_verifiers=gate_receipt_verifiers,
        command_plan_verifier=command_plan_verifier,
        expected_run_id=expected_run_id,
    )
    bindings = _normalize_binding_closure(_base_closure_bindings(provenance))
    exclusions = _normalize_failure_exclusions(failure_cycle_exclusions)
    artifact_rows = [dict(binding.document()) for binding in bindings]
    exclusion_rows = [dict(exclusion.document()) for exclusion in exclusions]
    directories = list(_closure_directories(bindings))
    payloads = []
    for binding in bindings:
        payloads.append(
            _reopen_payload(
                binding.content_binding,
                payload_reopener,
                label=f"run-input artifact {binding.path}",
            )
        )
    receipt = provenance.document
    document = {
        "schema_version": "2.0.0",
        "artifact_kind": "p06_run_input_manifest_v2",
        "manifest_role": "exact_authenticated_noncyclic_p06_run_input_closure",
        "manifest_path": RUN_INPUT_MANIFEST_PATH,
        "authority_bindings": receipt["authority_bindings"],
        "run_id": receipt["run_id"],
        "plan_id": receipt["plan_id"],
        "input_bundle_sha256": receipt["input_bundle_sha256"],
        "source_commit": receipt["source_commit"],
        "working_tree_clean": receipt["working_tree_clean"],
        "current_source": receipt["current_source"],
        "provenance_status": receipt["status"],
        "holdout_accessed": receipt["holdout_accessed"],
        "provenance_receipt": dict(provenance.binding.document()),
        "fixed_exclusions": list(FIXED_EXCLUSIONS),
        "failure_cycle_exclusions": exclusion_rows,
        "failure_cycle_exclusion_count": len(exclusion_rows),
        "artifacts": artifact_rows,
        "artifact_count": len(artifact_rows),
        "directories": directories,
        "closure_sha256": _closure_sha256(
            artifacts=artifact_rows,
            directories=directories,
            failure_cycle_exclusions=exclusion_rows,
        ),
    }
    document["manifest_sha256"] = _semantic_sha256(
        document,
        field="manifest_sha256",
    )
    schema = _load_schema(
        RUN_INPUT_MANIFEST_SCHEMA_PATH,
        RUN_INPUT_MANIFEST_SCHEMA_SHA256,
        label="P06 run-input manifest schema",
    )
    _validate_schema(document, schema, label="P06 run-input manifest")
    for binding, payload in zip(bindings, payloads):
        _require_stable_reopen(
            binding.content_binding,
            payload,
            payload_reopener,
            label=f"run-input artifact {binding.path}",
        )
    return document


def _command_input_closure_from_provenance(
    provenance: VerifiedRunProvenanceReceiptV2,
) -> Tuple[TypedArtifactBindingV2, ...]:
    return tuple(
        TypedArtifactBindingV2.from_mapping(
            value,
            label=f"authenticated command-input closure binding {index}",
        )
        for index, value in enumerate(
            provenance.document["command_input_closure"]
        )
    )


def _verify_run_ledger_failure_bindings(
    run_ledger_binding: Mapping[str, object],
    *,
    manifest_binding: TypedArtifactBindingV2,
    provenance: VerifiedRunProvenanceReceiptV2,
    payload_reopener: PayloadReopenerV2,
    run_ledger_semantic_verifier: RunLedgerSemanticVerifierV2,
) -> Tuple[
    Tuple[_LedgerFailureRelationV2, ...],
    Tuple[Tuple[ContentBindingV2, bytes, str], ...],
    ContentBindingV2,
]:
    command_closure = _command_input_closure_from_provenance(provenance)
    schema_binding = _required_schema_from_closure(
        command_closure,
        identifier="p06_calibration_run_ledger_v2_schema",
        path=RUN_LEDGER_SCHEMA_RELATIVE_PATH,
        label="P06 run-ledger schema",
    )
    typed = TypedArtifactBindingV2.from_mapping(
        run_ledger_binding,
        label="P06 run ledger binding",
    )
    if (
        typed.id != "p06_calibration_run_ledger_v2"
        or typed.artifact_kind != "p06_calibration_run_ledger_v2"
        or typed.content_type != "canonical_json"
        or typed.schema_sha256 != schema_binding.sha256
        or typed.path != RUN_LEDGER_PATH
    ):
        raise RunProvenanceV2Error("P06 run ledger binding type differs")
    schema_payload = _reopen_payload(
        schema_binding.content_binding,
        payload_reopener,
        label="P06 run-ledger schema",
    )
    schema = _parse_json_object(schema_payload, label="P06 run-ledger schema")
    try:
        jsonschema.Draft202012Validator.check_schema(schema)
    except jsonschema.SchemaError as error:
        raise RunProvenanceV2Error("P06 run-ledger schema is invalid") from error
    payload = _reopen_payload(
        typed.content_binding,
        payload_reopener,
        label="P06 run ledger",
    )
    ledger = _parse_canonical_file(payload, label="P06 run ledger")
    _validate_schema(ledger, schema, label="P06 run ledger")
    if not callable(run_ledger_semantic_verifier):
        raise RunProvenanceV2Error(
            "P06 run-ledger semantic verifier is required"
        )
    try:
        verified_value = run_ledger_semantic_verifier(typed, payload)
    except Exception as error:
        raise RunProvenanceV2Error(
            "P06 run-ledger semantic verification failed"
        ) from error
    verified_ledger = _snapshot_json(
        verified_value,
        label="P06 run-ledger semantic result",
    )
    if type(verified_ledger) is not dict or verified_ledger != ledger:
        raise RunProvenanceV2Error(
            "P06 run-ledger semantic verifier substituted content"
        )
    receipt = provenance.document
    if (
        ledger.get("authority_bindings") != authority_bindings_v2()
        or ledger.get("run_id") != receipt["run_id"]
        or ledger.get("plan_id") != receipt["plan_id"]
        or ledger.get("input_bundle_sha256") != receipt["input_bundle_sha256"]
        or ledger.get("input_bindings") != receipt["input_bindings"]
        or ledger.get("artifact_manifest")
        != manifest_binding.content_binding.document()
        or ledger.get("artifact_sha256")
        != _semantic_sha256(ledger, field="artifact_sha256")
    ):
        raise RunProvenanceV2Error(
            "P06 run ledger does not bind this authenticated run and manifest"
        )
    data_access = ledger.get("data_access")
    if (
        type(data_access) is not dict
        or data_access.get("holdout_accessed") is not False
        or data_access.get("release_locks_written") is not False
    ):
        raise RunProvenanceV2Error(
            "P06 run ledger opened holdout or wrote release locks"
        )
    candidate_evaluations = ledger.get("candidate_evaluations")
    if type(candidate_evaluations) is not list:
        raise RunProvenanceV2Error(
            "P06 run-ledger candidate-evaluation set is not concrete"
        )
    evaluation_identities = []
    evaluation_cache_identities = []
    for index, entry in enumerate(candidate_evaluations):
        if type(entry) is not dict or set(entry) != {
            "split",
            "candidate_vector_sha256",
            "binding",
        }:
            raise RunProvenanceV2Error(
                f"P06 run-ledger candidate evaluation {index} fields differ"
            )
        binding = ContentBindingV2.from_mapping(
            entry["binding"],
            label=f"P06 run-ledger candidate evaluation {index}",
        )
        if (
            entry["split"] not in {"development", "validation"}
            or not _is_sha256(entry["candidate_vector_sha256"])
            or not binding.path.startswith("evaluations/")
            or binding.path != f"evaluations/{binding.sha256}.json"
        ):
            raise RunProvenanceV2Error(
                f"P06 run-ledger candidate evaluation {index} identity differs"
            )
        evaluation_identities.append(
            [entry["split"], entry["candidate_vector_sha256"], binding.sha256]
        )
        evaluation_cache_identities.append(
            (entry["split"], entry["candidate_vector_sha256"])
        )
    evaluation_identities.sort(key=lambda identity: tuple(identity))
    if (
        len(set(evaluation_cache_identities))
        != len(evaluation_cache_identities)
        or ledger.get("candidate_evaluation_count")
        != len(candidate_evaluations)
        or ledger.get("candidate_evaluation_identity_set_sha256")
        != _sha256(canonical_json_bytes_v2(evaluation_identities))
    ):
        raise RunProvenanceV2Error(
            "P06 run-ledger candidate-evaluation count or set identity differs"
        )
    candidate_failures = ledger.get("candidate_failures")
    if type(candidate_failures) is not list:
        raise RunProvenanceV2Error(
            "P06 run-ledger candidate-failure set is not concrete"
        )
    candidate_identities = []
    candidate_failure_cache_identities = []
    failure_relations = []
    for index, entry in enumerate(candidate_failures):
        if type(entry) is not dict or set(entry) != {
            "split",
            "candidate_vector_sha256",
            "binding",
        }:
            raise RunProvenanceV2Error(
                f"P06 run-ledger candidate failure {index} fields differ"
            )
        binding = ContentBindingV2.from_mapping(
            entry["binding"],
            label=f"P06 run-ledger candidate failure {index}",
        )
        if (
            entry["split"] not in {"development", "validation"}
            or not _is_sha256(entry["candidate_vector_sha256"])
            or _FAILURE_PATH_RE.fullmatch(binding.path) is None
            or binding.path != f"failures/{binding.sha256}.json"
        ):
            raise RunProvenanceV2Error(
                f"P06 run-ledger candidate failure {index} identity differs"
            )
        candidate_identities.append(
            [entry["split"], entry["candidate_vector_sha256"], binding.sha256]
        )
        candidate_failure_cache_identities.append(
            (entry["split"], entry["candidate_vector_sha256"])
        )
        failure_relations.append(
            _LedgerFailureRelationV2(
                binding=binding,
                role="candidate_evaluation_failure",
                split=str(entry["split"]),
                candidate_vector_sha256=str(entry["candidate_vector_sha256"]),
                shared_bank_configuration_sha256=None,
                attempt_ledger_binding=None,
            )
        )
    identity_keys = [tuple(identity) for identity in candidate_identities]
    candidate_identities.sort(key=lambda identity: tuple(identity))
    candidate_set_sha256 = _sha256(canonical_json_bytes_v2(candidate_identities))
    if (
        len(set(identity_keys)) != len(identity_keys)
        or len(
            {
                identity
                for identity in candidate_failure_cache_identities
                if identity[0] == "validation"
            }
        )
        != sum(
            identity[0] == "validation"
            for identity in candidate_failure_cache_identities
        )
        or set(evaluation_cache_identities)
        & {
            identity
            for identity in candidate_failure_cache_identities
            if identity[0] == "validation"
        }
        or ledger.get("candidate_failure_count") != len(candidate_failures)
        or ledger.get("candidate_failure_identity_set_sha256")
        != candidate_set_sha256
    ):
        raise RunProvenanceV2Error(
            "P06 run-ledger candidate-failure count or set identity differs"
        )
    validation_outcome_count = sum(
        identity[0] == "validation" for identity in evaluation_cache_identities
    ) + sum(
        identity[0] == "validation"
        for identity in candidate_failure_cache_identities
    )
    if ledger.get("validation_attempt_count") != validation_outcome_count:
        raise RunProvenanceV2Error(
            "P06 run-ledger validation outcome count differs"
        )
    terminal_failure = ledger.get("failure")
    if terminal_failure is not None:
        if type(terminal_failure) is not dict:
            raise RunProvenanceV2Error("P06 run-ledger failure relation differs")
        terminal_binding = ContentBindingV2.from_mapping(
            terminal_failure,
            label="P06 run-ledger terminal failure",
        )
        if (
            _FAILURE_PATH_RE.fullmatch(terminal_binding.path) is None
            or terminal_binding.path
            != f"failures/{terminal_binding.sha256}.json"
        ):
            raise RunProvenanceV2Error(
                "P06 run-ledger terminal failure is not content addressed"
            )
        attempt_ledger = ledger.get("attempt_ledger")
        if type(attempt_ledger) is not dict:
            raise RunProvenanceV2Error(
                "P06 run-ledger attempt binding is absent"
            )
        terminal_attempt_binding = ContentBindingV2.from_mapping(
            {
                "path": attempt_ledger.get("path"),
                "sha256": attempt_ledger.get("sha256"),
                "size_bytes": attempt_ledger.get("size_bytes"),
            },
            label="P06 run-ledger terminal attempt source",
        )
        run_shared_bank_sha256 = ledger.get("shared_bank_configuration_sha256")
        if not _is_sha256(run_shared_bank_sha256):
            raise RunProvenanceV2Error(
                "P06 run-ledger shared-bank identity differs"
            )
        failure_relations.append(
            _LedgerFailureRelationV2(
                binding=terminal_binding,
                role="terminal_failure",
                split=None,
                candidate_vector_sha256=None,
                shared_bank_configuration_sha256=str(
                    run_shared_bank_sha256
                ),
                attempt_ledger_binding=terminal_attempt_binding,
            )
        )
    failure_paths = [relation.binding.path for relation in failure_relations]
    failure_digests = [relation.binding.sha256 for relation in failure_relations]
    if (
        len(set(failure_paths)) != len(failure_paths)
        or len(set(failure_digests)) != len(failure_digests)
    ):
        raise RunProvenanceV2Error(
            "P06 run-ledger candidate and terminal failures overlap"
        )
    failure_relations_tuple = tuple(
        sorted(failure_relations, key=lambda item: item.binding.path)
    )
    return (
        failure_relations_tuple,
        (
            (schema_binding.content_binding, schema_payload, "P06 run-ledger schema"),
            (typed.content_binding, payload, "P06 run ledger"),
        ),
        typed.content_binding,
    )


def _verify_failure_cycle_relations(
    exclusions: Sequence[Mapping[str, object]],
    *,
    manifest_binding: TypedArtifactBindingV2,
    failure_relations: Sequence[_LedgerFailureRelationV2],
    run_ledger_content_binding: ContentBindingV2,
    failure_schema_binding: TypedArtifactBindingV2,
    payload_reopener: PayloadReopenerV2,
    failure_semantic_verifier: Optional[FailureSemanticVerifierV2],
    run_id: str,
) -> Tuple[str, ...]:
    failure_schema_payload = _reopen_payload(
        failure_schema_binding.content_binding,
        payload_reopener,
        label="P06 failure schema",
    )
    failure_schema = _parse_json_object(
        failure_schema_payload,
        label="P06 failure schema",
    )
    try:
        jsonschema.Draft202012Validator.check_schema(failure_schema)
    except jsonschema.SchemaError as error:
        raise RunProvenanceV2Error("P06 failure schema is invalid") from error
    declared = []
    for index, exclusion in enumerate(exclusions):
        if type(exclusion) is not dict or set(exclusion) != {
            "failure_identity_sha256",
            "relation",
        }:
            raise RunProvenanceV2Error(
                f"failure cycle exclusion {index} field set differs"
            )
        identity = exclusion["failure_identity_sha256"]
        if (
            not _is_sha256(identity)
            or exclusion["relation"]
            != "failure_binds_this_manifest_and_is_cycle_excluded"
        ):
            raise RunProvenanceV2Error(
                f"failure cycle exclusion {index} identity differs"
            )
        declared.append(identity)
    if declared != sorted(declared) or len(set(declared)) != len(declared):
        raise RunProvenanceV2Error(
            "failure cycle-exclusion identities are unordered or duplicated"
        )
    if type(failure_relations) is not tuple or any(
        type(relation) is not _LedgerFailureRelationV2
        for relation in failure_relations
    ):
        raise RunProvenanceV2Error("ledger failure relations are not typed")
    if failure_relations and not callable(failure_semantic_verifier):
        raise RunProvenanceV2Error("failure semantic verifier is required")
    verifier = failure_semantic_verifier
    cyclic_paths = {
        RUN_INPUT_MANIFEST_PATH,
        RUN_LEDGER_PATH,
        *(relation.binding.path for relation in failure_relations),
    }
    cyclic_digests = {
        manifest_binding.sha256,
        run_ledger_content_binding.sha256,
        *(relation.binding.sha256 for relation in failure_relations),
    }
    observed = []
    snapshots = []
    for index, relation in enumerate(failure_relations):
        binding = relation.binding
        if (
            _FAILURE_PATH_RE.fullmatch(binding.path) is None
            or binding.path != f"failures/{binding.sha256}.json"
        ):
            raise RunProvenanceV2Error(
                f"cyclic failure binding {index} is not content addressed"
            )
        payload = _reopen_payload(
            binding,
            payload_reopener,
            label=f"cyclic failure {index}",
        )
        parsed = _parse_canonical_file(payload, label=f"cyclic failure {index}")
        _validate_schema(parsed, failure_schema, label=f"cyclic failure {index}")
        if verifier is None:
            raise AssertionError("nonempty failure closure lacks its verifier")
        try:
            verified_value = verifier(binding.document(), payload)
        except Exception as error:
            raise RunProvenanceV2Error(
                f"cyclic failure {index} semantic verification failed"
            ) from error
        verified = _snapshot_json(
            verified_value,
            label=f"cyclic failure {index} semantic result",
        )
        if type(verified) is not dict or verified != parsed:
            raise RunProvenanceV2Error(
                f"cyclic failure {index} semantic verifier substituted content"
            )
        if (
            verified.get("artifact_kind") != "p06_calibration_failure_v2"
            or verified.get("run_id") != run_id
            or verified.get("status") != "failed_preserved"
            or verified.get("authority_bindings") != authority_bindings_v2()
            or verified.get("artifact_sha256")
            != _semantic_sha256(verified, field="artifact_sha256")
        ):
            raise RunProvenanceV2Error(
                f"cyclic failure {index} authenticated identity differs"
            )
        if relation.role == "candidate_evaluation_failure":
            expected_stage = (
                "development_search"
                if relation.split == "development"
                else "validation_selection"
            )
            data_access = verified.get("data_access")
            if (
                relation.split not in {"development", "validation"}
                or not _is_sha256(relation.candidate_vector_sha256)
                or verified.get("candidate_vector_sha256")
                != relation.candidate_vector_sha256
                or verified.get("failure_type") != "evaluation"
                or verified.get("failure_stage") != expected_stage
                or type(data_access) is not dict
                or data_access.get("development_accessed") is not True
                or data_access.get("validation_accessed")
                is not (relation.split == "validation")
            ):
                raise RunProvenanceV2Error(
                    f"cyclic failure {index} candidate relation differs"
                )
        elif relation.role == "terminal_failure":
            failure_bindings = verified.get("failure_bindings")
            attempt_relation = (
                failure_bindings.get("attempt_ledger")
                if type(failure_bindings) is dict
                else None
            )
            data_access = verified.get("data_access")
            if (
                relation.split is not None
                or relation.candidate_vector_sha256 is not None
                or not _is_sha256(relation.shared_bank_configuration_sha256)
                or relation.attempt_ledger_binding is None
                or verified.get("failure_type") != "terminal"
                or verified.get("failure_stage") != "development_search"
                or verified.get("shared_bank_configuration_sha256")
                != relation.shared_bank_configuration_sha256
                or type(attempt_relation) is not dict
                or attempt_relation.get("applicable") is not True
                or attempt_relation.get("binding")
                != relation.attempt_ledger_binding.document()
                or type(data_access) is not dict
                or data_access.get("development_accessed") is not True
                or data_access.get("validation_accessed") is not False
            ):
                raise RunProvenanceV2Error(
                    f"cyclic failure {index} terminal relation differs"
                )
        else:
            raise RunProvenanceV2Error(
                f"cyclic failure {index} ledger role differs"
            )
        for name, dependency in _applicable_failure_dependency_bindings(verified):
            if (
                dependency.path in cyclic_paths
                or _FAILURE_PATH_RE.fullmatch(dependency.path) is not None
                or dependency.sha256 in cyclic_digests
            ):
                raise RunProvenanceV2Error(
                    f"cyclic failure {index} {name} creates an undeclared cycle"
                )
        artifact_manifest = verified.get("failure_bindings", {}).get(
            "artifact_manifest"
        )
        if (
            type(artifact_manifest) is not dict
            or artifact_manifest.get("applicable") is not True
            or artifact_manifest.get("binding")
            != manifest_binding.content_binding.document()
        ):
            raise RunProvenanceV2Error(
                f"cyclic failure {index} does not bind this exact manifest"
            )
        for name, relation in verified["failure_bindings"].items():
            if (
                name != "artifact_manifest"
                and type(relation) is dict
                and relation.get("applicable") is True
                and type(relation.get("binding")) is dict
                and relation["binding"].get("path") == RUN_INPUT_MANIFEST_PATH
            ):
                raise RunProvenanceV2Error(
                    f"cyclic failure {index} has an undeclared manifest cycle"
                )
        observed.append(failure_identity_sha256_v2(verified))
        snapshots.append((binding, payload, index))
    if len(set(observed)) != len(observed) or sorted(observed) != declared:
        raise RunProvenanceV2Error(
            "failure cycle exclusions and reopened failures differ bidirectionally"
        )
    for binding, payload, index in snapshots:
        _require_stable_reopen(
            binding,
            payload,
            payload_reopener,
            label=f"cyclic failure {index}",
        )
    _require_stable_reopen(
        failure_schema_binding.content_binding,
        failure_schema_payload,
        payload_reopener,
        label="P06 failure schema",
    )
    return tuple(declared)


def verify_run_input_manifest_v2(
    document: Mapping[str, object],
    *,
    manifest_binding: Mapping[str, object],
    run_ledger_binding: Mapping[str, object],
    authority_payload_reopener: PayloadReopenerV2,
    payload_reopener: PayloadReopenerV2,
    gate_receipt_verifiers: Mapping[str, GateReceiptVerifierV2],
    command_plan_verifier: CommandPlanVerifierV2,
    run_ledger_semantic_verifier: RunLedgerSemanticVerifierV2,
    failure_semantic_verifier: Optional[FailureSemanticVerifierV2],
    expected_run_id: Optional[str] = None,
) -> VerifiedRunInputManifestV2:
    snapshot = _snapshot_json(document, label="P06 run-input manifest")
    if type(snapshot) is not dict:
        raise RunProvenanceV2Error("P06 run-input manifest is not an object")
    typed_manifest = _require_manifest_binding(manifest_binding)
    schema = _load_schema(
        RUN_INPUT_MANIFEST_SCHEMA_PATH,
        RUN_INPUT_MANIFEST_SCHEMA_SHA256,
        label="P06 run-input manifest schema",
    )
    _validate_schema(snapshot, schema, label="P06 run-input manifest")
    canonical_payload = canonical_json_file_bytes_v2(snapshot)
    if (
        typed_manifest.sha256 != _sha256(canonical_payload)
        or typed_manifest.size_bytes != len(canonical_payload)
    ):
        raise RunProvenanceV2Error(
            "P06 run-input manifest binding differs from its canonical document"
        )
    reopened_manifest_payload = _reopen_payload(
        typed_manifest.content_binding,
        payload_reopener,
        label="P06 run-input manifest",
    )
    if reopened_manifest_payload != canonical_payload:
        raise RunProvenanceV2Error(
            "P06 run-input manifest reopener substituted canonical content"
        )
    if snapshot["manifest_sha256"] != _semantic_sha256(
        snapshot,
        field="manifest_sha256",
    ):
        raise RunProvenanceV2Error("P06 run-input manifest self-hash differs")
    provenance_binding = _require_provenance_binding(snapshot["provenance_receipt"])
    provenance = reopen_run_provenance_receipt_v2(
        provenance_binding.document(),
        authority_payload_reopener=authority_payload_reopener,
        payload_reopener=payload_reopener,
        gate_receipt_verifiers=gate_receipt_verifiers,
        command_plan_verifier=command_plan_verifier,
        expected_run_id=expected_run_id,
    )
    receipt = provenance.document
    derived = {
        "authority_bindings": receipt["authority_bindings"],
        "run_id": receipt["run_id"],
        "plan_id": receipt["plan_id"],
        "input_bundle_sha256": receipt["input_bundle_sha256"],
        "source_commit": receipt["source_commit"],
        "working_tree_clean": receipt["working_tree_clean"],
        "current_source": receipt["current_source"],
        "provenance_status": receipt["status"],
        "holdout_accessed": receipt["holdout_accessed"],
    }
    if any(snapshot[name] != value for name, value in derived.items()):
        raise RunProvenanceV2Error(
            "run-input manifest provenance fields were not derived from its receipt"
        )
    if snapshot["fixed_exclusions"] != list(FIXED_EXCLUSIONS):
        raise RunProvenanceV2Error("run-input manifest fixed exclusions differ")
    expected_bindings = _normalize_binding_closure(_base_closure_bindings(provenance))
    expected_rows = [dict(binding.document()) for binding in expected_bindings]
    if snapshot["artifacts"] != expected_rows:
        raise RunProvenanceV2Error(
            "run-input manifest noncyclic closure differs; omissions are not allowed"
        )
    if snapshot["artifact_count"] != len(expected_rows):
        raise RunProvenanceV2Error("run-input manifest artifact count differs")
    expected_directories = list(_closure_directories(expected_bindings))
    if snapshot["directories"] != expected_directories:
        raise RunProvenanceV2Error("run-input manifest directory closure differs")
    if (
        snapshot["failure_cycle_exclusion_count"]
        != len(snapshot["failure_cycle_exclusions"])
        or snapshot["closure_sha256"]
        != _closure_sha256(
            artifacts=expected_rows,
            directories=expected_directories,
            failure_cycle_exclusions=snapshot["failure_cycle_exclusions"],
        )
    ):
        raise RunProvenanceV2Error("run-input manifest closure hash or count differs")
    artifact_payloads = []
    for binding in expected_bindings:
        artifact_payloads.append(
            _reopen_payload(
                binding.content_binding,
                payload_reopener,
                label=f"run-input artifact {binding.path}",
            )
        )
    command_closure = _command_input_closure_from_provenance(provenance)
    failure_schema_binding = _required_schema_from_closure(
        command_closure,
        identifier="p06_calibration_failure_v2_schema",
        path=FAILURE_SCHEMA_RELATIVE_PATH,
        label="P06 failure schema",
    )
    (
        failure_relations,
        ledger_snapshots,
        run_ledger_content_binding,
    ) = _verify_run_ledger_failure_bindings(
        run_ledger_binding,
        manifest_binding=typed_manifest,
        provenance=provenance,
        payload_reopener=payload_reopener,
        run_ledger_semantic_verifier=run_ledger_semantic_verifier,
    )
    failure_identities = _verify_failure_cycle_relations(
        snapshot["failure_cycle_exclusions"],
        manifest_binding=typed_manifest,
        failure_relations=failure_relations,
        run_ledger_content_binding=run_ledger_content_binding,
        failure_schema_binding=failure_schema_binding,
        payload_reopener=payload_reopener,
        failure_semantic_verifier=failure_semantic_verifier,
        run_id=str(snapshot["run_id"]),
    )
    for binding, payload in zip(expected_bindings, artifact_payloads):
        _require_stable_reopen(
            binding.content_binding,
            payload,
            payload_reopener,
            label=f"run-input artifact {binding.path}",
        )
    for binding, payload, label in ledger_snapshots:
        _require_stable_reopen(
            binding,
            payload,
            payload_reopener,
            label=label,
        )
    _require_stable_reopen(
        typed_manifest.content_binding,
        reopened_manifest_payload,
        payload_reopener,
        label="P06 run-input manifest",
    )
    return VerifiedRunInputManifestV2(
        document=snapshot,
        binding=typed_manifest,
        provenance=provenance,
        failure_identities=failure_identities,
    )


def reopen_run_input_manifest_v2(
    binding: Mapping[str, object],
    *,
    run_ledger_binding: Mapping[str, object],
    authority_payload_reopener: PayloadReopenerV2,
    payload_reopener: PayloadReopenerV2,
    gate_receipt_verifiers: Mapping[str, GateReceiptVerifierV2],
    command_plan_verifier: CommandPlanVerifierV2,
    run_ledger_semantic_verifier: RunLedgerSemanticVerifierV2,
    failure_semantic_verifier: Optional[FailureSemanticVerifierV2],
    expected_run_id: Optional[str] = None,
) -> VerifiedRunInputManifestV2:
    typed = _require_manifest_binding(binding)
    payload = _reopen_payload(
        typed.content_binding,
        payload_reopener,
        label="P06 run-input manifest",
    )
    document = _parse_canonical_file(payload, label="P06 run-input manifest")
    verified = verify_run_input_manifest_v2(
        document,
        manifest_binding=typed.document(),
        run_ledger_binding=run_ledger_binding,
        authority_payload_reopener=authority_payload_reopener,
        payload_reopener=payload_reopener,
        gate_receipt_verifiers=gate_receipt_verifiers,
        command_plan_verifier=command_plan_verifier,
        run_ledger_semantic_verifier=run_ledger_semantic_verifier,
        failure_semantic_verifier=failure_semantic_verifier,
        expected_run_id=expected_run_id,
    )
    _require_stable_reopen(
        typed.content_binding,
        payload,
        payload_reopener,
        label="P06 run-input manifest",
    )
    return verified


__all__ = [
    "FAILURE_INTEGRATION_REQUIREMENTS_V2",
    "FIXED_EXCLUSIONS",
    "FailureCycleExclusionV2",
    "PROVENANCE_SCHEMA_SHA256",
    "RUN_INPUT_MANIFEST_SCHEMA_SHA256",
    "RunProvenanceV2Error",
    "TypedArtifactBindingV2",
    "VerifiedCommandPlanV2",
    "VerifiedGateReceiptV2",
    "VerifiedRunInputManifestV2",
    "VerifiedRunProvenanceReceiptV2",
    "authenticate_authorities_v2",
    "authority_bindings_v2",
    "authority_closure_bindings_v2",
    "authority_input_bindings_v2",
    "build_failure_cycle_exclusion_v2",
    "build_run_input_manifest_v2",
    "build_run_provenance_receipt_v2",
    "canonical_json_bytes_v2",
    "canonical_json_file_bytes_v2",
    "failure_identity_sha256_v2",
    "reopen_run_input_manifest_v2",
    "reopen_run_provenance_receipt_v2",
    "verify_run_input_manifest_v2",
    "verify_run_provenance_receipt_v2",
]
