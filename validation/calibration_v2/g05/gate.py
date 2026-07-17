"""Current-source P05 evidence validation and deterministic G05 documents."""

from __future__ import annotations

import ast
from contextlib import contextmanager
from datetime import datetime, timezone
import hashlib
import json
import math
import os
import re
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
import stat
import subprocess
from typing import Any, Iterator, Mapping, Optional, Sequence

import jsonschema
from referencing import Registry, Resource

from validation.quality.src.mirmir_quality.json_tools import (
    canonical_json_bytes,
    canonical_sha256,
)
from validation.spatial_v2.run_p05_evidence import (
    CONFIGURATION_FILES,
    EXPECTED_OUTPUTS,
    PRODUCTION_SOURCES,
)


P05_SCHEMA_DIRECTORY = Path("validation/spatial_v2/schemas")
G05_SCHEMA_DIRECTORY = Path("validation/calibration_v2/schemas")
ASSESSMENT_SCHEMA = "g05-gate-assessment-v2.schema.json"
FINDING_REGISTER_SCHEMA = "g05-scoped-finding-register-v2.schema.json"
RECEIPT_SCHEMA = "g05-current-source-receipt-v1.schema.json"
COMMAND_PLAN_SCHEMA = "g05-command-plan-v1.schema.json"
RUN_IDENTITY_SCHEMA = "g05-run-identity-v1.schema.json"
P05_COMMON_SCHEMA = "p05-common.schema.json"
EVIDENCE_FILENAMES = tuple(EXPECTED_OUTPUTS)
EVIDENCE_FILENAME_SET = frozenset(EVIDENCE_FILENAMES)
CANONICAL_RUN_RELATIVE_PATHS = (
    "evidence/run-a",
    "evidence/run-b",
    "evidence/independent-run",
)
G05_COMMAND_IDS = (
    "run-a",
    "run-b",
    "independent-run",
    "quality-lock-a",
    "quality-lock-b",
    "swiftlint",
    "attribution",
    "instruction-package",
    "diff-check",
)
INSTRUCTION_PACKAGE_ROOT_TOKEN = "{instruction-package-root}"
CANONICAL_COMMAND_PATH = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"
UTC_PATTERN = re.compile(
    r"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]{1,6})?Z$"
)
P00_BASELINE_RECORDS = (
    "audit-result.json",
    "local-work-plan.md",
    "validation/calibration_v2/production_evaluator.py",
    "validation/calibration_v2/native_adapter/factory.py",
)
QUALITY_MANIFEST_RELATIVE = (
    "validation/quality/locks/quality-harness-implementation-manifest.json"
)
SPATIAL_PREREGISTRATION_RELATIVE = (
    "validation/calibration_v2/contracts/spatial-semantics-preregistration-v2.json"
)
MAPPING_SEED_RELATIVE = "Mirmir/Resources/ASH/ash_video_mapping_v2.seed.json"
OPERATOR_BANK_SEED_RELATIVE = "Mirmir/Resources/ASH/operator_bank_v2.seed.json"
METRIC_POLICY_RELATIVE = "validation/quality/policies/metric-policy.json"
ASSESSMENT_RELATIVE = "analysis/g05-gate-assessment.json"
FINDING_REGISTER_RELATIVE = "analysis/g05-scoped-finding-register.json"
UPSTREAM_BINDINGS_RELATIVE = "inputs/upstream-bindings.json"
COMMAND_EXECUTION_RELATIVE = "inputs/command-execution-aggregate.json"
G03_CANONICAL_FILES = (
    "conformance/g03-gate-assessment.json",
    "conformance/canonical-vectors.json",
    "conformance/p03-g03-canonical-core-evidence.json",
    "conformance/ash-core-v1.contract.json",
)
G04_CURRENT_SOURCE_FILES = (
    "analysis/g04-gate-assessment.json",
    "test-results.json",
)


@dataclass(frozen=True)
class _PinnedWrapperContext:
    logical_root: Path
    expected_identity: tuple[int, int]


_PINNED_WRAPPER_CONTEXT: Optional[_PinnedWrapperContext] = None
G03_CURRENT_CONTRACT = "validation/reference/ash-core-v1.contract.json"
G03_CURRENT_BINARY = "validation/reference/generated/ash-core-v1.bin"
G03_CORE_SOURCE_FILES = (
    "Mirmir/Modules/UpscalerEngine/ASH/ASHState.swift",
    "Mirmir/Modules/UpscalerEngine/ASH/ASHCode.swift",
)
G03_CURRENT_SOURCE_FILES = (
    *G03_CORE_SOURCE_FILES,
    "Mirmir/Modules/UpscalerEngine/ASH/ASHCoreConformance.swift",
    "MirmirTests/ASHCoreConformanceTests.swift",
    "validation/reference/ash_core_oracle.py",
    G03_CURRENT_CONTRACT,
    "validation/reference/README.md",
    G03_CURRENT_BINARY,
    "validation/reference/generated/ash-core-v1.sha256",
)
REPOSITORY_SEALED_COPY = "validation/quality/locks/holdout-access-ledger.sealed-copy.json"
REPOSITORY_NO_PIXEL_ATTESTATION = (
    "validation/quality/locks/holdout-seal-attestation.no-pixel.json"
)
REPOSITORY_CORPUS_LOCK = "validation/quality/locks/corpus-lock.json"
LIVE_LEDGER_SCHEMA = "validation/quality/schemas/holdout-access-ledger.schema.json"
LIVE_RECEIPT_SCHEMA = "validation/calibration_v2/schemas/live-holdout-preopen-receipt-v1.schema.json"
SEALED_COPY_SCHEMA = "validation/calibration_v2/schemas/sealed-evaluation-access-ledger-v1.schema.json"
NO_PIXEL_ATTESTATION_SCHEMA = (
    "validation/calibration_v2/schemas/holdout-seal-attestation-no-pixel-v1.schema.json"
)
EVIDENCE_WRAPPER_MANIFEST_SCHEMA = (
    "validation/calibration_v2/schemas/evidence-wrapper-artifact-manifest-v2.schema.json"
)
G03_EXHAUSTIVE_COUNTS = {
    "raw_states": 512,
    "valid_anchors": 256,
    "codewords": 16,
    "exact_affine": 4096,
    "one_bit_affine": 36864,
    "two_bit_affine": 147456,
}
G03_VECTOR_COUNTS = {
    "raw_states": G03_EXHAUSTIVE_COUNTS["raw_states"],
    "valid_parity_states": G03_EXHAUSTIVE_COUNTS["valid_anchors"],
    "codewords": G03_EXHAUSTIVE_COUNTS["codewords"],
    "exact_affine": G03_EXHAUSTIVE_COUNTS["exact_affine"],
    "one_bit_affine": G03_EXHAUSTIVE_COUNTS["one_bit_affine"],
    "two_bit_affine": G03_EXHAUSTIVE_COUNTS["two_bit_affine"],
}
G03_ASSESSMENT_CRITERIA = (
    "All 512 states checked",
    "256 valid parity states checked",
    "16 codewords checked",
    "all one-bit affine corruptions corrected",
    "all required two-bit corruptions rejected",
    "Production Swift and independent reference vectors and hashes match exactly",
    "canonical core unchanged or operator-approved math change recorded",
)
G04_ASSESSMENT_CRITERIA = (
    "Native-HR corpus manifest and source rights/provenance recorded",
    "Assets split before tuning and hashes locked",
    "Degradation profiles are deterministic and independently tested",
    "Metric implementations pass analytic/synthetic fixtures",
    "Bootstrap operates at source-asset level",
    "Development/validation/holdout access policy enforced",
    "Pre-change benchmark dry run produces complete schema-valid evidence",
)
LIVE_PREOPEN_RELATIVE_PATHS = (
    "inputs/live-preopen/holdout-access-ledger.p06-spatial-v2.json",
    "inputs/live-preopen/holdout-preopen-receipt.p06-spatial-v2.json",
    "inputs/live-preopen/repository-sealed-holdout-access-ledger.json",
    "inputs/live-preopen/repository-holdout-seal-attestation.json",
)
P05_SCHEMA_FILENAMES = (P05_COMMON_SCHEMA,) + tuple(
    name.replace(".json", ".schema.json") for name in EVIDENCE_FILENAMES
)
P05_HARNESS_FILES = (
    "validation/spatial_v2/P05EvidenceMain.swift",
    "validation/spatial_v2/run_p05_evidence.py",
) + tuple(
    str(P05_SCHEMA_DIRECTORY / name) for name in sorted(P05_SCHEMA_FILENAMES)
)
EXPECTED_CRITERION_IDS = {
    "development-mapping.json": (
        "valid-state-cardinality",
        "development-only-parameters",
        "range-normalization",
    ),
    "state-fixtures.json": (
        "all-state-bits-controlled",
        "normal-tangent-convention",
    ),
    "operator-discrimination.json": (
        "all-descriptor-pairs",
        "constant-equality-allowed",
    ),
    "operator-distinctness.json": (
        "semantic-distinctness",
        "behavioral-distinctness",
    ),
    "coordinate-comparison.json": (
        "both-coordinate-policies",
        "route-phase-cardinality",
        "synthetic-coordinate-tests",
    ),
    "state-causality-results.json": (
        "nonconstant-valid-state-dispatch",
        "bounded-affine-dispatch",
        "per-plane-corrected-phase-dispatch",
        "neutral-phase-preserving-ablation",
        "first-frame-variation",
        "state-disabled-delta",
    ),
    "cpu-reference-results.json": (
        "direct-routes",
        "all-descriptors-and-channels",
        "source-aligned-preservation",
        "no-nearest-substrate",
    ),
    "cpu-reference-vectors.json": (
        "deterministic-vectors",
        "legal-range-limiting",
    ),
}
G05_CRITERIA = (
    (
        "all_state_bits_controlled",
        "Every state bit has controlled fixture coverage",
        ("state-fixtures.json",),
    ),
    (
        "normal_tangent_convention",
        "Structure-tensor normal/tangent convention passes orientation fixtures",
        ("state-fixtures.json",),
    ),
    (
        "direct_routes_synthetic",
        "Direct 2x and 3/2 CPU reference passes synthetic tests",
        ("coordinate-comparison.json", "cpu-reference-results.json", "cpu-reference-vectors.json"),
    ),
    (
        "descriptor_semantic_behavioral_distinctness",
        "16 descriptor records are semantically and behaviorally distinct",
        ("operator-distinctness.json", "operator-discrimination.json"),
    ),
    (
        "no_nearest_substrate",
        "nearest is not the production reconstruction substrate",
        ("cpu-reference-results.json", "state-causality-results.json"),
    ),
    (
        "nonconstant_valid_state_dispatch",
        "dispatch is not constant across valid states",
        ("state-causality-results.json",),
    ),
    (
        "first_frame_not_universal",
        "first-frame top operator is not universal by construction",
        ("state-causality-results.json",),
    ),
    (
        "state_disabled_delta",
        "state-disabled result differs on controlled fixtures",
        ("state-causality-results.json",),
    ),
)


class G05GateError(ValueError):
    """P05 evidence or a G05 document is unsafe, stale, or semantically false."""


@dataclass(frozen=True)
class G05ReceiptValidation:
    """Validated documents and every wrapper-relative file reopened for G05."""

    assessment: Mapping[str, Any]
    finding_register: Mapping[str, Any]
    upstream_bindings: Mapping[str, Any]
    command_execution_aggregate: Mapping[str, Any]
    reopened_relative_paths: tuple[str, ...]


def _require(condition: bool, message: str) -> None:
    if not condition:
        raise G05GateError(message)


def _sha256(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def _source_commit(value: object) -> str:
    _require(
        isinstance(value, str)
        and len(value) == 40
        and all(character in "0123456789abcdef" for character in value),
        "source_commit is not a lowercase 40-character Git object ID",
    )
    return value


def _safe_relative(value: object, label: str) -> PurePosixPath:
    _require(isinstance(value, str) and value, f"{label} path is empty")
    parsed = PurePosixPath(value)
    _require(
        not parsed.is_absolute()
        and parsed.as_posix() == value
        and all(part not in {"", ".", ".."} for part in parsed.parts),
        f"{label} path is not a normalized repository-relative path",
    )
    return parsed


@contextmanager
def pinned_wrapper_root(
    root: Path,
    expected_identity: tuple[int, int],
) -> Iterator[Path]:
    """Yield a cwd-relative wrapper root pinned to one open directory inode."""

    global _PINNED_WRAPPER_CONTEXT
    _require(
        _PINNED_WRAPPER_CONTEXT is None,
        "a pinned G05 wrapper context is already active",
    )
    _require(
        len(expected_identity) == 2
        and all(type(value) is int and value >= 0 for value in expected_identity),
        "pinned G05 wrapper identity is invalid",
    )
    logical_root = _directory(Path(root), "pinned G05 wrapper root")
    flags = (
        os.O_RDONLY
        | getattr(os, "O_DIRECTORY", 0)
        | getattr(os, "O_NOFOLLOW", 0)
    )
    original_descriptor = os.open(".", flags)
    root_descriptor = -1
    cwd_changed = False
    try:
        root_descriptor = os.open(logical_root, flags)
        opened = os.fstat(root_descriptor)
        named = os.lstat(logical_root)
        _require(
            stat.S_ISDIR(opened.st_mode)
            and not stat.S_ISLNK(named.st_mode)
            and (opened.st_dev, opened.st_ino)
            == (named.st_dev, named.st_ino)
            == expected_identity,
            "published G05 wrapper differs from its staged root identity",
        )
        os.fchdir(root_descriptor)
        cwd_changed = True
        current = os.lstat(".")
        _require(
            (current.st_dev, current.st_ino) == expected_identity,
            "pinned G05 wrapper cwd identity differs",
        )
        _PINNED_WRAPPER_CONTEXT = _PinnedWrapperContext(
            logical_root=logical_root,
            expected_identity=expected_identity,
        )
        try:
            yield Path(".")
        finally:
            after = os.fstat(root_descriptor)
            cwd_after = os.lstat(".")
            stable = (
                (after.st_dev, after.st_ino)
                == (cwd_after.st_dev, cwd_after.st_ino)
                == expected_identity
            )
            _PINNED_WRAPPER_CONTEXT = None
            os.fchdir(original_descriptor)
            cwd_changed = False
            _require(stable, "pinned G05 wrapper identity changed during reopen")
    finally:
        _PINNED_WRAPPER_CONTEXT = None
        if cwd_changed:
            os.fchdir(original_descriptor)
        if root_descriptor >= 0:
            os.close(root_descriptor)
        os.close(original_descriptor)


def _directory(path: Path, label: str) -> Path:
    supplied = Path(path)
    if not supplied.is_absolute():
        context = _PINNED_WRAPPER_CONTEXT
        _require(
            context is not None,
            f"{label} path is not absolute outside a pinned wrapper context",
        )
        lexical = Path(os.path.normpath(os.fspath(supplied)))
        _require(
            lexical == supplied
            and all(part not in {"", ".", ".."} for part in supplied.parts),
            f"{label} path is not normalized beneath the pinned wrapper",
        )
        current = Path(".")
        if supplied != Path("."):
            for part in supplied.parts:
                current = current / part
                try:
                    metadata = os.lstat(current)
                except OSError as error:
                    raise G05GateError(
                        f"{label} cannot be inspected: {error}"
                    ) from error
                _require(
                    not stat.S_ISLNK(metadata.st_mode),
                    f"{label} traverses a symbolic link",
                )
            _require(stat.S_ISDIR(metadata.st_mode), f"{label} is not a directory")
        else:
            metadata = os.lstat(".")
            _require(stat.S_ISDIR(metadata.st_mode), f"{label} is not a directory")
        return supplied
    _require(supplied.is_absolute(), f"{label} path is not absolute")
    lexical = Path(os.path.abspath(os.path.normpath(os.fspath(supplied))))
    _require(lexical == supplied, f"{label} path is not lexically normalized")
    try:
        metadata = os.lstat(lexical)
    except OSError as error:
        raise G05GateError(f"{label} cannot be inspected: {error}") from error
    _require(not stat.S_ISLNK(metadata.st_mode), f"{label} is a symbolic link")
    _require(stat.S_ISDIR(metadata.st_mode), f"{label} is not a directory")
    resolved = lexical.resolve(strict=True)
    _require(resolved == lexical, f"{label} path traverses a symbolic link")
    return resolved


def _read_regular_file(
    path: Path,
    label: str,
    *,
    allow_empty: bool = False,
) -> bytes:
    try:
        before = os.lstat(path)
    except OSError as error:
        raise G05GateError(f"{label} cannot be inspected: {error}") from error
    _require(not stat.S_ISLNK(before.st_mode), f"{label} is a symbolic link")
    _require(stat.S_ISREG(before.st_mode), f"{label} is not a regular file")
    _require(before.st_nlink == 1, f"{label} does not have exactly one link")
    flags = os.O_RDONLY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        raise G05GateError(f"{label} cannot be opened safely: {error}") from error
    try:
        opened = os.fstat(descriptor)
        before_fingerprint = (
            before.st_dev,
            before.st_ino,
            before.st_mode,
            before.st_size,
            before.st_mtime_ns,
            before.st_ctime_ns,
            before.st_nlink,
        )
        _require(
            (
                opened.st_dev,
                opened.st_ino,
                opened.st_mode,
                opened.st_size,
                opened.st_mtime_ns,
                opened.st_ctime_ns,
                opened.st_nlink,
            )
            == before_fingerprint,
            f"{label} changed while opening",
        )
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
        path_after = os.lstat(path)
    except OSError as error:
        raise G05GateError(f"{label} changed while reading: {error}") from error
    _require(
        (
            after.st_dev,
            after.st_ino,
            after.st_mode,
            after.st_size,
            after.st_mtime_ns,
            after.st_ctime_ns,
            after.st_nlink,
        )
        == before_fingerprint
        == (
            path_after.st_dev,
            path_after.st_ino,
            path_after.st_mode,
            path_after.st_size,
            path_after.st_mtime_ns,
            path_after.st_ctime_ns,
            path_after.st_nlink,
        )
        and stat.S_ISREG(path_after.st_mode)
        and not stat.S_ISLNK(path_after.st_mode),
        f"{label} changed while reading",
    )
    payload = b"".join(chunks)
    _require(payload or allow_empty, f"{label} is empty")
    return payload


def _repository_file(
    repository_root: Path,
    relative: object,
    label: str,
    *,
    allow_empty: bool = False,
) -> tuple[Path, bytes]:
    root = _directory(repository_root, "repository root")
    parsed = _safe_relative(relative, label)
    current = root
    for index, part in enumerate(parsed.parts):
        current = current / part
        try:
            metadata = os.lstat(current)
        except OSError as error:
            raise G05GateError(f"{label} cannot be inspected: {error}") from error
        _require(not stat.S_ISLNK(metadata.st_mode), f"{label} traverses a symbolic link")
        if index < len(parsed.parts) - 1:
            _require(stat.S_ISDIR(metadata.st_mode), f"{label} parent is not a directory")
    return current, _read_regular_file(current, label, allow_empty=allow_empty)


def _json_object(payload: bytes, label: str) -> Mapping[str, Any]:
    def unique_object(pairs: Sequence[tuple[str, Any]]) -> dict[str, Any]:
        result: dict[str, Any] = {}
        for key, value in pairs:
            if key in result:
                raise G05GateError(f"{label} contains duplicate key {key!r}")
            result[key] = value
        return result

    def reject_constant(value: str) -> None:
        raise G05GateError(f"{label} contains non-finite JSON number {value}")

    try:
        value = json.loads(
            payload.decode("utf-8"),
            object_pairs_hook=unique_object,
            parse_constant=reject_constant,
        )
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise G05GateError(f"{label} is not strict UTF-8 JSON: {error}") from error
    _require(isinstance(value, dict), f"{label} is not a JSON object")
    return value


def _schema_validator(
    repository_root: Path,
    schema_relative_path: str,
    *,
    registry_paths: Sequence[str] = (),
) -> jsonschema.Draft202012Validator:
    resources: list[tuple[str, Resource[Any]]] = []
    for relative in dict.fromkeys((*registry_paths, schema_relative_path)):
        _, payload = _repository_file(repository_root, relative, f"schema {relative}")
        schema = _json_object(payload, f"schema {relative}")
        try:
            jsonschema.Draft202012Validator.check_schema(schema)
            resource = Resource.from_contents(schema)
        except Exception as error:
            raise G05GateError(f"schema {relative} is not valid Draft 2020-12: {error}") from error
        identifier = schema.get("$id")
        _require(isinstance(identifier, str) and identifier, f"schema {relative} has no $id")
        resources.append((identifier, resource))
    registry = Registry().with_resources(resources)
    _, payload = _repository_file(repository_root, schema_relative_path, f"schema {schema_relative_path}")
    schema = _json_object(payload, f"schema {schema_relative_path}")
    return jsonschema.Draft202012Validator(
        schema,
        registry=registry,
        format_checker=jsonschema.FormatChecker(),
    )


def _validate_schema(
    document: Mapping[str, Any],
    validator: jsonschema.Draft202012Validator,
    label: str,
) -> None:
    errors = sorted(
        validator.iter_errors(document),
        key=lambda error: tuple(str(part) for part in error.absolute_path),
    )
    if errors:
        details = []
        for error in errors:
            location = "/".join(str(part) for part in error.absolute_path) or "<root>"
            details.append(f"{location}: {error.message}")
        raise G05GateError(f"{label} schema validation failed: {'; '.join(details)}")


def _composite_sha256(records: Sequence[Mapping[str, Any]]) -> str:
    material = "".join(
        f"{record['path']}\0{record['sha256']}\0{record['byte_count']}\n"
        for record in records
    )
    return _sha256(material.encode("utf-8"))


def _validate_provenance_records(
    repository_root: Path,
    records: object,
    expected_paths: Sequence[str],
    label: str,
) -> Sequence[Mapping[str, Any]]:
    _require(isinstance(records, list), f"{label} provenance records are not an array")
    _require(
        tuple(record.get("path") for record in records if isinstance(record, dict))
        == tuple(expected_paths)
        and len(records) == len(expected_paths),
        f"{label} provenance path closure differs",
    )
    observed: list[Mapping[str, Any]] = []
    for index, record in enumerate(records):
        _require(isinstance(record, dict), f"{label} provenance record {index} is not an object")
        path_value = record.get("path")
        _, payload = _repository_file(
            repository_root,
            path_value,
            f"{label} provenance file {path_value}",
        )
        _require(
            record.get("sha256") == _sha256(payload),
            f"{label} provenance SHA-256 differs for {path_value}",
        )
        _require(
            record.get("byte_count") == len(payload),
            f"{label} provenance size differs for {path_value}",
        )
        observed.append(record)
    return observed


def _validate_provenance(repository_root: Path, documents: Mapping[str, Mapping[str, Any]]) -> Mapping[str, Any]:
    first = documents[EVIDENCE_FILENAMES[0]].get("provenance")
    _require(isinstance(first, dict), "P05 provenance is not an object")
    for filename in EVIDENCE_FILENAMES[1:]:
        _require(documents[filename].get("provenance") == first, f"{filename} provenance differs")
    production = _validate_provenance_records(
        repository_root,
        first.get("production_sources"),
        PRODUCTION_SOURCES,
        "production source",
    )
    configuration = _validate_provenance_records(
        repository_root,
        first.get("configuration_files"),
        CONFIGURATION_FILES,
        "configuration",
    )
    harness = _validate_provenance_records(
        repository_root,
        first.get("harness_files"),
        P05_HARNESS_FILES,
        "P05 harness",
    )
    for field, records in (
        ("production_source_manifest_sha256", production),
        ("configuration_manifest_sha256", configuration),
        ("harness_manifest_sha256", harness),
    ):
        _require(first.get(field) == _composite_sha256(records), f"{field} differs")
    _require(
        first.get("reproduction_command")
        == "python3 validation/spatial_v2/run_p05_evidence.py --output <evidence-directory>",
        "P05 reproduction command differs",
    )
    mapping = documents["development-mapping.json"]["data"]
    mapping_binding = next(
        record for record in configuration if record["path"].endswith("ash_video_mapping_v2.seed.json")
    )
    _require(mapping.get("mapping_sha256") == mapping_binding["sha256"], "mapping configuration binding differs")
    return first


def _validate_document_criteria(documents: Mapping[str, Mapping[str, Any]]) -> None:
    for filename, expected_ids in EXPECTED_CRITERION_IDS.items():
        criteria = documents[filename].get("criteria")
        _require(isinstance(criteria, list), f"{filename} criteria are not an array")
        _require(
            tuple(record.get("id") for record in criteria if isinstance(record, dict)) == expected_ids
            and len(criteria) == len(expected_ids),
            f"{filename} criterion closure differs",
        )
        _require(
            all(
                isinstance(record, dict)
                and record.get("status") == "pass"
                and isinstance(record.get("evidence"), str)
                and bool(record["evidence"])
                for record in criteria
            ),
            f"{filename} contains a non-passing criterion",
        )


def _bits_raw(bits: object, label: str) -> int:
    _require(
        isinstance(bits, list)
        and len(bits) == 9
        and all(type(bit) is int and bit in {0, 1} for bit in bits),
        f"{label} bits differ",
    )
    return sum(bit << (8 - index) for index, bit in enumerate(bits))


def _criterion_state_bits(documents: Mapping[str, Mapping[str, Any]]) -> int:
    data = documents["state-fixtures.json"]["data"]
    fixtures = data.get("controlled_fixtures")
    _require(isinstance(fixtures, list) and len(fixtures) == 9, "state-bit fixture closure differs")
    _require(data.get("controlled_state_bit_count") == 9, "controlled state-bit count differs")
    _require(
        [record.get("target_coordinate") for record in fixtures if isinstance(record, dict)]
        == list(range(1, 10)),
        "state-bit target coordinates differ",
    )
    for target, record in enumerate(fixtures, start=1):
        _require(isinstance(record, dict) and record.get("pass") is True, f"state-bit fixture {target} failed")
        baseline = record.get("baseline_bits")
        variant = record.get("variant_bits")
        baseline_raw = _bits_raw(baseline, f"state-bit fixture {target} baseline")
        variant_raw = _bits_raw(variant, f"state-bit fixture {target} variant")
        _require(record.get("baseline_raw") == baseline_raw, f"state-bit fixture {target} baseline raw differs")
        _require(record.get("variant_raw") == variant_raw, f"state-bit fixture {target} variant raw differs")
        changed = [
            index + 1
            for index, pair in enumerate(zip(baseline, variant))
            if pair[0] != pair[1]
        ]
        expected = [target, 9] if target < 9 else [9]
        _require(changed == expected and record.get("changed_coordinates") == expected, f"state-bit fixture {target} change set differs")
        _require(sum(baseline) % 2 == 0 and record.get("baseline_integrity_valid") is True, f"state-bit fixture {target} baseline integrity differs")
        expected_variant_validity = target < 9
        _require(
            (sum(variant) % 2 == 0) is expected_variant_validity
            and record.get("variant_integrity_valid") is expected_variant_validity,
            f"state-bit fixture {target} variant integrity differs",
        )
    return len(fixtures)


def _criterion_orientation(documents: Mapping[str, Mapping[str, Any]]) -> int:
    data = documents["state-fixtures.json"]["data"]
    fixtures = data.get("orientation_fixtures")
    expected_names = (
        "horizontal_tangent",
        "positive_diagonal_tangent",
        "vertical_tangent",
        "negative_diagonal_tangent",
    )
    _require(isinstance(fixtures, list) and len(fixtures) == 4, "orientation fixture closure differs")
    _require(data.get("orientation_fixture_count") == 4, "orientation fixture count differs")
    _require(tuple(record.get("name") for record in fixtures if isinstance(record, dict)) == expected_names, "orientation fixture order differs")
    for sector, record in enumerate(fixtures):
        _require(isinstance(record, dict) and record.get("pass") is True, f"orientation fixture {sector} failed")
        normal = record.get("edge_normal_radians")
        tangent = record.get("edge_tangent_radians")
        declared = record.get("normal_plus_pi_over_two_mod_pi")
        error = record.get("angular_error")
        _require(
            all(type(value) in {int, float} and math.isfinite(float(value)) for value in (normal, tangent, declared, error)),
            f"orientation fixture {sector} has non-finite values",
        )
        expected_tangent = (float(normal) + math.pi / 2.0) % math.pi
        distance = abs(float(tangent) - expected_tangent) % math.pi
        distance = min(distance, math.pi - distance)
        _require(
            abs(float(declared) - expected_tangent) <= 1.0e-12
            and abs(float(error) - distance) <= 1.0e-12
            and distance <= 1.0e-12,
            f"orientation fixture {sector} normal/tangent relation differs",
        )
        _require(
            record.get("expected_tangent_sector") == sector
            and record.get("observed_tangent_sector") == sector,
            f"orientation fixture {sector} sector differs",
        )
    return len(fixtures)


def _criterion_direct_routes(documents: Mapping[str, Mapping[str, Any]]) -> int:
    results = documents["cpu-reference-results.json"]["data"]
    vectors = documents["cpu-reference-vectors.json"]["data"]
    coordinates = documents["coordinate-comparison.json"]["data"]
    expected_tests = (
        "identity_coordinates",
        "direct_2x_four_phase_pairs",
        "direct_3_over_2_nine_phase_pairs",
        "linear_ramps",
        "impulses",
        "explicit_borders",
        "source_aligned_samples",
        "all_descriptors",
        "normalized_y_cb_cr_legal_ranges",
        "nearest_not_reconstruction_substrate",
        "runtime_tree_generation_zero",
        "candidate_bound",
    )
    tests = results.get("tests")
    _require(
        isinstance(tests, list)
        and tuple(record.get("id") for record in tests if isinstance(record, dict)) == expected_tests
        and all(record.get("status") == "pass" for record in tests if isinstance(record, dict)),
        "CPU synthetic test closure differs",
    )
    rows = vectors.get("vectors")
    _require(isinstance(rows, list) and len(rows) == 192 == results.get("vector_count"), "CPU vector count differs")
    combinations = []
    for index, row in enumerate(rows):
        _require(isinstance(row, dict) and row.get("pass") is True, f"CPU vector {index} failed")
        value = row.get("value")
        low = row.get("legal_minimum")
        high = row.get("legal_maximum")
        _require(
            all(type(item) in {int, float} and math.isfinite(float(item)) for item in (value, low, high))
            and float(low) <= float(value) <= float(high),
            f"CPU vector {index} is outside legal range",
        )
        combinations.append((row.get("route"), row.get("coordinate_policy"), row.get("channel"), row.get("descriptor_id")))
    expected_combinations = {
        (route, policy, channel, descriptor)
        for route in ("direct_2x", "direct_3_over_2")
        for policy in ("half_pixel_center", "source_aligned_rational")
        for channel in ("Y", "Cb", "Cr")
        for descriptor in range(16)
    }
    _require(len(set(combinations)) == 192 and set(combinations) == expected_combinations, "CPU route/policy/channel/descriptor coverage differs")
    aligned = vectors.get("source_aligned_vectors")
    _require(isinstance(aligned, list) and len(aligned) == 32 == results.get("source_aligned_preservation_count"), "source-aligned vector closure differs")
    aligned_pairs = []
    for index, row in enumerate(aligned):
        _require(
            isinstance(row, dict)
            and row.get("pass") is True
            and row.get("expected") == row.get("observed")
            and row.get("source_x", {}).get("is_integral") is True
            and row.get("source_y", {}).get("is_integral") is True,
            f"source-aligned vector {index} differs",
        )
        aligned_pairs.append((row.get("route"), row.get("descriptor_id")))
    _require(
        set(aligned_pairs) == {(route, descriptor) for route in ("direct_2x", "direct_3_over_2") for descriptor in range(16)},
        "source-aligned route/descriptor coverage differs",
    )
    route_records = coordinates.get("route_policy_records")
    _require(isinstance(route_records, list) and len(route_records) == 4, "coordinate route-policy closure differs")
    observed_route_policy_pairs = []
    for row in route_records:
        _require(isinstance(row, dict), "coordinate route-policy record is not an object")
        expected_count = 4 if row.get("route") == "direct_2x" else 9
        _require(
            row.get("route") in {"direct_2x", "direct_3_over_2"}
            and row.get("policy") in {"half_pixel_center", "source_aligned_rational"}
            and row.get("expected_phase_pair_count") == expected_count
            and row.get("observed_phase_pair_count") == expected_count
            and isinstance(row.get("phases"), list)
            and len(row["phases"]) == expected_count
            and row.get("pass") is True,
            "coordinate route phase coverage differs",
        )
        observed_route_policy_pairs.append((row.get("route"), row.get("policy")))
    _require(
        set(observed_route_policy_pairs)
        == {
            (route, policy)
            for route in ("direct_2x", "direct_3_over_2")
            for policy in ("half_pixel_center", "source_aligned_rational")
        }
        and len(set(observed_route_policy_pairs)) == len(observed_route_policy_pairs),
        "coordinate route-policy pair closure differs",
    )
    _require(
        coordinates.get("release_policy_selected") is False
        and coordinates.get("comparison_status") == "development_evidence_only"
        and coordinates.get("siting_corrected_phase_cardinality_pass") is True
        and all(record.get("pass") is True for field in ("identity_vectors", "ramp_vectors", "border_vectors") for record in coordinates.get(field, [])),
        "coordinate comparison is not passing development-only evidence",
    )
    return len(rows)


def _criterion_descriptors(documents: Mapping[str, Mapping[str, Any]]) -> int:
    distinctness = documents["operator-distinctness.json"]["data"]
    discrimination = documents["operator-discrimination.json"]["data"]
    descriptors = distinctness.get("descriptors")
    signatures = distinctness.get("behavior_signatures")
    witnesses = discrimination.get("pair_witnesses")
    _require(isinstance(descriptors, list) and len(descriptors) == 16, "descriptor closure differs")
    semantic_rows = []
    for identifier, row in enumerate(descriptors):
        _require(isinstance(row, dict) and row.get("id") == identifier, f"descriptor {identifier} identity differs")
        semantic_rows.append((row.get("base_kernel"), row.get("support"), row.get("detail"), row.get("limiter")))
    _require(len(set(semantic_rows)) == 16 and distinctness.get("semantically_unique_count") == 16, "descriptor semantics are not distinct")
    _require(isinstance(signatures, list) and len(signatures) == 16, "behavior signature closure differs")
    _require(
        [row.get("descriptor_id") for row in signatures if isinstance(row, dict)] == list(range(16))
        and len({row.get("sha256") for row in signatures if isinstance(row, dict)}) == 16
        and all(row.get("sample_count") == discrimination.get("fixture_case_count") for row in signatures if isinstance(row, dict)),
        "descriptor behavior signatures are not distinct or complete",
    )
    _require(isinstance(witnesses, list) and len(witnesses) == 120, "descriptor witness closure differs")
    pairs = set()
    for index, row in enumerate(witnesses):
        _require(isinstance(row, dict) and row.get("pass") is True, f"descriptor witness {index} failed")
        first = row.get("first_descriptor")
        second = row.get("second_descriptor")
        delta = row.get("absolute_delta")
        _require(
            type(first) is int
            and type(second) is int
            and 0 <= first < second < 16
            and type(delta) in {int, float}
            and math.isfinite(float(delta))
            and float(delta) > 1.0e-12
            and abs(float(delta) - abs(float(row.get("first_value")) - float(row.get("second_value")))) <= 1.0e-15,
            f"descriptor witness {index} is invalid",
        )
        pairs.add((first, second))
    expected_pairs = {(first, second) for first in range(15) for second in range(first + 1, 16)}
    _require(
        pairs == expected_pairs
        and discrimination.get("passing_pair_count") == 120
        and distinctness.get("behaviorally_distinct_pair_count") == 120,
        "descriptor pair coverage differs",
    )
    return len(witnesses)


def _criterion_no_nearest(documents: Mapping[str, Mapping[str, Any]]) -> int:
    results = documents["cpu-reference-results.json"]["data"]
    tests = {record.get("id"): record for record in results.get("tests", []) if isinstance(record, dict)}
    control = documents["state-causality-results.json"]["data"].get("state_disabled_control")
    _require(
        results.get("nearest_expansion_used") is False
        and tests.get("nearest_not_reconstruction_substrate", {}).get("observed") is False
        and results.get("runtime_tree_generation_count") == 0,
        "nearest or runtime tree is present in the CPU reconstruction substrate",
    )
    _require(isinstance(control, dict), "state-disabled control is absent")
    ablations = control.get("per_plane_ablations")
    _require(
        isinstance(ablations, list)
        and len(ablations) == 24
        and all(record.get("nearest_expansion_used") is False for record in ablations if isinstance(record, dict))
        and len(ablations) == sum(isinstance(record, dict) for record in ablations),
        "state-disabled plane evidence used nearest expansion",
    )
    return len(ablations)


def _criterion_nonconstant_dispatch(documents: Mapping[str, Mapping[str, Any]]) -> int:
    data = documents["state-causality-results.json"]["data"]
    records = data.get("state_dispatch_records")
    _require(isinstance(records, list) and len(records) == 256, "valid-state dispatch closure differs")
    primary = set()
    ordinals = []
    for index, row in enumerate(records):
        _require(
            isinstance(row, dict)
            and row.get("integrity_valid") is True
            and row.get("decode_status") == "exact"
            and type(row.get("operator_evaluation_count")) is int
            and 1 <= row["operator_evaluation_count"] <= 2,
            f"valid-state dispatch {index} is invalid",
        )
        ordinals.append(row.get("payload_ordinal"))
        primary.add(row.get("primary_descriptor"))
    _require(ordinals == list(range(256)), "valid-state payload ordering differs")
    _require(
        primary == set(range(16))
        and data.get("unique_primary_descriptor_count") == 16
        and data.get("unique_primary_descriptors") == list(range(16))
        and data.get("exhaustive_primary_descriptor_count") == 16,
        "dispatch is constant or descriptor coverage differs",
    )
    hard = data.get("hard_semantic_constraint_results")
    plane = data.get("per_plane_dispatch_results")
    neutral = data.get("neutral_state_phase_preserving_ablation")
    _require(
        all(
            isinstance(value, dict)
            and value.get("pass") is True
            and value.get("failure_count", value.get("mismatch_count")) == 0
            for value in (hard, plane, neutral)
        )
        and data.get("maximum_operator_evaluations") <= 2,
        "dispatch structural semantic assertions failed",
    )
    return len(records)


def _criterion_first_frame(documents: Mapping[str, Mapping[str, Any]]) -> int:
    data = documents["state-causality-results.json"]["data"]
    records = data.get("first_frame_records")
    _require(
        isinstance(records, list)
        and len(records) == data.get("first_frame_fixture_count")
        and len(records) >= 4,
        "first-frame fixture closure differs",
    )
    primary = set()
    for index, row in enumerate(records):
        _require(
            isinstance(row, dict)
            and row.get("history_present") is False
            and row.get("decode_status") == "exact"
            and type(row.get("operator_evaluation_count")) is int
            and 1 <= row["operator_evaluation_count"] <= 2,
            f"first-frame record {index} is invalid",
        )
        primary.add(row.get("primary_descriptor"))
    _require(
        len(primary) >= 2 and data.get("first_frame_unique_primary_count") == len(primary),
        "first-frame top operator is universal or count differs",
    )
    return len(records)


def _criterion_state_disabled(documents: Mapping[str, Mapping[str, Any]]) -> int:
    control = documents["state-causality-results.json"]["data"].get("state_disabled_control")
    _require(isinstance(control, dict), "state-disabled control is absent")
    _require(
        control.get("pass") is True
        and control.get("state_enabled") is True
        and control.get("state_disabled") is True
        and control.get("enabled_run_state_input_enabled") is True
        and control.get("disabled_run_state_input_enabled") is False
        and control.get("same_source_pixels") is True
        and control.get("same_phase_context") is True
        and type(control.get("maximum_absolute_delta")) in {int, float}
        and math.isfinite(float(control["maximum_absolute_delta"]))
        and float(control["maximum_absolute_delta"]) > 1.0e-12
        and control.get("enabled_output_sha256") != control.get("disabled_output_sha256")
        and control.get("enabled_operator_histogram") != control.get("disabled_operator_histogram"),
        "state-disabled aggregate control does not demonstrate a controlled delta",
    )
    ablations = control.get("per_plane_ablations")
    _require(
        isinstance(ablations, list)
        and len(ablations) == control.get("per_plane_ablation_count") == 24,
        "state-disabled per-plane closure differs",
    )
    combinations = set()
    for index, row in enumerate(ablations):
        _require(
            isinstance(row, dict)
            and row.get("pass") is True
            and row.get("analysis_state_histogram_unchanged") is True
            and row.get("source_pixels_unchanged") is True
            and row.get("plane_phase_context_unchanged") is True
            and row.get("nearest_expansion_used") is False
            and row.get("maximum_operator_evaluations") <= 2
            and float(row.get("overall_maximum_absolute_delta", 0.0)) > 1.0e-12
            and row.get("enabled_output_sha256") != row.get("disabled_output_sha256"),
            f"state-disabled per-plane ablation {index} differs",
        )
        combinations.add((row.get("route"), row.get("coordinate_policy"), row.get("chroma_siting")))
    expected = {
        (route, policy, siting)
        for route in ("direct_2x", "direct_3_over_2")
        for policy in ("half_pixel_center", "source_aligned_rational")
        for siting in ("center", "left", "top_left", "top", "bottom_left", "bottom")
    }
    _require(combinations == expected, "state-disabled route/policy/chroma-siting coverage differs")
    return len(ablations)


def _validate_development_boundary(documents: Mapping[str, Mapping[str, Any]]) -> None:
    for filename, document in documents.items():
        _require(
            document.get("phase") == "P05"
            and document.get("gate") == "G05"
            and document.get("status") == "pass"
            and document.get("parameter_status") == "development_only_not_release_locked"
            and document.get("input_scope") == "synthetic_only"
            and document.get("holdout_accessed") is False,
            f"{filename} is not passing synthetic P05/G05 evidence",
        )
    mapping = documents["development-mapping.json"]["data"]
    _require(
        mapping.get("canonical_core_unchanged") is True
        and mapping.get("valid_state_count") == 256
        and mapping.get("invalid_state_count") == 256
        and mapping.get("thresholds", {}).get("status") == "development_only_not_release_locked"
        and all(record.get("pass") is True for record in mapping.get("range_vectors", [])),
        "development mapping boundary or structural counts differ",
    )


def validate_g05_evidence(
    repository_root: Path,
    run_roots: Sequence[Path],
) -> Mapping[str, Any]:
    """Validate exactly three byte-identical, current-source P05 evidence runs."""

    _directory(repository_root, "repository root")
    _require(len(run_roots) == 3, "G05 requires exactly three P05 evidence runs")
    roots = [_directory(Path(root), f"P05 run {index}") for index, root in enumerate(run_roots, start=1)]
    _require(len(set(roots)) == 3, "P05 evidence run roots are not distinct")
    for root in roots:
        _require(
            all("holdout" not in part.lower() for part in root.parts),
            "P05 evidence run path crosses the holdout boundary",
        )
    payloads_by_run: list[dict[str, bytes]] = []
    for run_index, root in enumerate(roots, start=1):
        try:
            entries = list(root.iterdir())
        except OSError as error:
            raise G05GateError(f"P05 run {run_index} cannot be listed: {error}") from error
        names = {entry.name for entry in entries}
        _require(
            len(entries) == 8 and names == EVIDENCE_FILENAME_SET,
            f"P05 run {run_index} does not contain the exact eight-file closure",
        )
        payloads_by_run.append(
            {
                filename: _read_regular_file(root / filename, f"P05 run {run_index} {filename}")
                for filename in EVIDENCE_FILENAMES
            }
        )
    for filename in EVIDENCE_FILENAMES:
        _require(
            payloads_by_run[0][filename]
            == payloads_by_run[1][filename]
            == payloads_by_run[2][filename],
            f"P05 evidence bytes differ across runs for {filename}",
        )
    common_relative = str(P05_SCHEMA_DIRECTORY / P05_COMMON_SCHEMA)
    documents: dict[str, Mapping[str, Any]] = {}
    for filename in EVIDENCE_FILENAMES:
        document = _json_object(payloads_by_run[0][filename], filename)
        schema_relative = str(P05_SCHEMA_DIRECTORY / filename.replace(".json", ".schema.json"))
        validator = _schema_validator(
            repository_root,
            schema_relative,
            registry_paths=(common_relative,),
        )
        _validate_schema(document, validator, filename)
        documents[filename] = document
    _validate_development_boundary(documents)
    _validate_document_criteria(documents)
    provenance = _validate_provenance(repository_root, documents)
    criterion_counts = {
        "all_state_bits_controlled": _criterion_state_bits(documents),
        "normal_tangent_convention": _criterion_orientation(documents),
        "direct_routes_synthetic": _criterion_direct_routes(documents),
        "descriptor_semantic_behavioral_distinctness": _criterion_descriptors(documents),
        "no_nearest_substrate": _criterion_no_nearest(documents),
        "nonconstant_valid_state_dispatch": _criterion_nonconstant_dispatch(documents),
        "first_frame_not_universal": _criterion_first_frame(documents),
        "state_disabled_delta": _criterion_state_disabled(documents),
    }
    bindings = [
        {
            "path": filename,
            "sha256": _sha256(payloads_by_run[0][filename]),
            "size_bytes": len(payloads_by_run[0][filename]),
        }
        for filename in EVIDENCE_FILENAMES
    ]
    run_sha256 = _sha256(
        "".join(
            f"{row['path']}\0{row['sha256']}\0{row['size_bytes']}\n" for row in bindings
        ).encode("utf-8")
    )
    return {
        "documents": documents,
        "document_bindings": bindings,
        "run_sha256": run_sha256,
        "criterion_counts": criterion_counts,
        "provenance_manifest_sha256": {
            "production_sources": provenance["production_source_manifest_sha256"],
            "configuration": provenance["configuration_manifest_sha256"],
            "harness": provenance["harness_manifest_sha256"],
        },
    }


def _validate_self_hash(document: Mapping[str, Any], field: str, label: str) -> None:
    expected = document.get(field)
    payload = dict(document)
    payload.pop(field, None)
    _require(expected == canonical_sha256(payload), f"{label} canonical self-hash differs")


def _validate_output_document(
    repository_root: Path,
    document: Mapping[str, Any],
    schema_filename: str,
    self_hash_field: str,
    label: str,
) -> None:
    validator = _schema_validator(repository_root, str(G05_SCHEMA_DIRECTORY / schema_filename))
    _validate_schema(document, validator, label)
    _validate_self_hash(document, self_hash_field, label)


def build_g05_assessment(
    *,
    repository_root: Path,
    run_roots: Sequence[Path],
    source_commit: str,
    finding_register_sha256: str,
) -> Mapping[str, Any]:
    """Build a schema-valid deterministic assessment after exhaustive validation."""

    commit = _source_commit(source_commit)
    _require(
        isinstance(finding_register_sha256, str)
        and len(finding_register_sha256) == 64
        and all(character in "0123456789abcdef" for character in finding_register_sha256),
        "finding-register self-hash is not a lowercase SHA-256",
    )
    closure = validate_g05_evidence(repository_root, run_roots)
    counts = closure["criterion_counts"]
    document: dict[str, Any] = {
        "schema_version": "2.0.0",
        "artifact_kind": "g05_gate_assessment",
        "gate_id": "G05",
        "phase": "P05",
        "source_commit": commit,
        "status": "pass",
        "finding_register_sha256": finding_register_sha256,
        "input_scope": "synthetic_only",
        "holdout_accessed": False,
        "evidence_closure": {
            "status": "pass",
            "run_count": 3,
            "files_per_run": 8,
            "document_names": list(EVIDENCE_FILENAMES),
            "document_bindings": closure["document_bindings"],
            "run_sha256": [closure["run_sha256"]] * 3,
            "byte_identical": True,
        },
        "provenance": {
            "status": "pass",
            "current_repository_bytes_verified": True,
            "manifest_sha256": closure["provenance_manifest_sha256"],
        },
        "mandatory_criteria": [
            {
                "id": identifier,
                "criterion": criterion,
                "status": "pass",
                "evidence": list(evidence),
                "verified_assertion_count": counts[identifier],
            }
            for identifier, criterion, evidence in G05_CRITERIA
        ],
    }
    document["assessment_sha256"] = canonical_sha256(document)
    _validate_output_document(
        repository_root,
        document,
        ASSESSMENT_SCHEMA,
        "assessment_sha256",
        "G05 assessment",
    )
    return document


def build_g05_finding_register(
    *,
    repository_root: Path,
    source_commit: str,
    findings: Sequence[Mapping[str, Any]] = (),
) -> Mapping[str, Any]:
    """Build the closed scoped finding register; G05 permits no actual findings."""

    commit = _source_commit(source_commit)
    derived = {
        "severity_1": sum(finding.get("severity") == 1 for finding in findings),
        "severity_2": sum(finding.get("severity") == 2 for finding in findings),
    }
    _require(len(findings) == 0, "G05 finding register contains an actual finding")
    document: dict[str, Any] = {
        "schema_version": "2.0.0",
        "artifact_kind": "g05_scoped_finding_register",
        "gate_id": "G05",
        "phase": "P05",
        "source_commit": commit,
        "review_status": "pass",
        "scope": list(EVIDENCE_FILENAMES),
        "open_counts": derived,
        "findings": list(findings),
    }
    document["register_sha256"] = canonical_sha256(document)
    _validate_output_document(
        repository_root,
        document,
        FINDING_REGISTER_SCHEMA,
        "register_sha256",
        "G05 finding register",
    )
    return document


def build_g05_documents(
    *,
    repository_root: Path,
    run_roots: Sequence[Path],
    source_commit: str,
) -> tuple[Mapping[str, Any], Mapping[str, Any]]:
    """Build the assessment and zero-finding register for a CLI publisher."""

    register = build_g05_finding_register(
        repository_root=repository_root,
        source_commit=source_commit,
    )
    assessment = build_g05_assessment(
        repository_root=repository_root,
        run_roots=run_roots,
        source_commit=source_commit,
        finding_register_sha256=str(register["register_sha256"]),
    )
    return assessment, register


def document_bytes(document: Mapping[str, Any]) -> bytes:
    """Return the deterministic on-disk JSON representation used by receipt bindings."""

    return canonical_json_bytes(document) + b"\n"


def build_file_binding(
    *,
    wrapper_root: Path,
    path: Path,
    label: str,
) -> Mapping[str, Any]:
    """Bind one single-link regular file by wrapper-relative path and bytes."""

    supplied_root = Path(wrapper_root)
    root = _directory(supplied_root, "G05 wrapper root")
    supplied_path = Path(path)
    _require(supplied_path.is_absolute(), f"{label} path is not absolute")
    absolute = Path(os.path.abspath(os.path.normpath(os.fspath(supplied_path))))
    _require(absolute == supplied_path, f"{label} path is not lexically normalized")
    try:
        relative = absolute.relative_to(supplied_root)
    except ValueError as error:
        raise G05GateError(f"{label} is outside the G05 wrapper root") from error
    parsed = _safe_relative(relative.as_posix(), label)
    _, payload = _repository_file(root, parsed.as_posix(), label)
    return {
        "path": parsed.as_posix(),
        "sha256": _sha256(payload),
        "size_bytes": len(payload),
    }


def _validate_finding_register(document: Mapping[str, Any]) -> None:
    findings = document.get("findings")
    _require(isinstance(findings, list), "G05 finding register findings are not an array")
    derived = {
        "severity_1": sum(isinstance(row, dict) and row.get("severity") == 1 for row in findings),
        "severity_2": sum(isinstance(row, dict) and row.get("severity") == 2 for row in findings),
    }
    _require(document.get("open_counts") == derived and len(findings) == 0, "G05 finding counts differ or are nonzero")


def _document_from_binding(
    repository_root: Path,
    binding: object,
    label: str,
    *,
    expected_path: str,
) -> tuple[str, Mapping[str, Any]]:
    _require(isinstance(binding, dict), f"{label} binding is not an object")
    _require(set(binding) == {"path", "sha256", "size_bytes"}, f"{label} binding fields differ")
    relative = _safe_relative(binding.get("path"), label).as_posix()
    _require(relative == expected_path, f"{label} binding path differs")
    _, payload = _repository_file(repository_root, relative, label)
    _require(binding.get("sha256") == _sha256(payload), f"{label} binding SHA-256 differs")
    _require(binding.get("size_bytes") == len(payload), f"{label} binding size differs")
    document = _json_object(payload, label)
    _require(payload == document_bytes(document), f"{label} is not canonical JSON")
    return relative, document


def _execution_file_from_binding(
    wrapper_root: Path,
    binding: object,
    expected_path: str,
    label: str,
) -> tuple[str, bytes]:
    _require(
        isinstance(binding, dict)
        and set(binding) == {"path", "sha256", "size_bytes"}
        and binding.get("path") == expected_path
        and type(binding.get("size_bytes")) is int
        and binding["size_bytes"] >= 0,
        f"{label} binding fields or path differ",
    )
    relative = _safe_relative(expected_path, label).as_posix()
    _, payload = _repository_file(
        wrapper_root,
        relative,
        label,
        allow_empty=expected_path.endswith(".log"),
    )
    _require(
        binding.get("sha256") == _sha256(payload)
        and binding.get("size_bytes") == len(payload),
        f"{label} binding bytes differ",
    )
    return relative, payload


def _parse_utc_z(value: object, label: str) -> datetime:
    _require(
        isinstance(value, str) and UTC_PATTERN.fullmatch(value) is not None,
        f"{label} is not a canonical ISO-Z timestamp",
    )
    try:
        parsed = datetime.fromisoformat(value[:-1] + "+00:00")
    except ValueError as error:
        raise G05GateError(f"{label} is not a valid timestamp") from error
    _require(parsed.utcoffset() == timezone.utc.utcoffset(parsed), f"{label} is not UTC")
    return parsed


def _git_output(repository_root: Path, arguments: Sequence[str], label: str) -> bytes:
    result = subprocess.run(
        ("/usr/bin/git", "-C", os.fspath(repository_root), *arguments),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
        env={
            "HOME": "/var/empty",
            "PATH": "/usr/bin:/bin",
            "LANG": "C",
            "LC_ALL": "C",
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_TERMINAL_PROMPT": "0",
        },
    )
    _require(result.returncode == 0, f"{label} Git verification failed")
    return result.stdout


def _python_string_assignment(payload: bytes, name: str, label: str) -> str:
    try:
        tree = ast.parse(payload, filename=label)
    except (SyntaxError, ValueError) as error:
        raise G05GateError(f"{label} cannot be parsed for its P00 binding") from error
    values: list[str] = []
    for statement in tree.body:
        if not isinstance(statement, (ast.Assign, ast.AnnAssign)):
            continue
        targets = statement.targets if isinstance(statement, ast.Assign) else [statement.target]
        if not any(isinstance(target, ast.Name) and target.id == name for target in targets):
            continue
        value = statement.value
        if isinstance(value, ast.Constant) and isinstance(value.value, str):
            values.append(value.value)
    _require(
        len(values) == 1
        and len(values[0]) == 40
        and all(character in "0123456789abcdef" for character in values[0]),
        f"{label} does not contain one exact P00 commit binding",
    )
    return values[0]


def _validate_p00_baseline_binding(
    *,
    repository_root: Path,
    document: object,
    source_commit: str,
) -> str:
    _require(isinstance(document, dict), "G05 run identity P00 binding is absent")
    material = dict(document)
    claimed = material.pop("binding_sha256", None)
    baseline = material.get("baseline_commit")
    _source_commit(baseline)
    _require(
        set(material)
        == {
            "schema_version",
            "status",
            "baseline_commit",
            "source_commit",
            "ancestry",
            "tracked_records",
        }
        and claimed == canonical_sha256(material)
        and material.get("schema_version") == "1.0.0"
        and material.get("status") == "pass"
        and material.get("source_commit") == source_commit
        and material.get("ancestry") == "baseline_is_ancestor_of_source",
        "G05 run identity P00 binding identity or self-hash differs",
    )
    records = material.get("tracked_records")
    _require(
        isinstance(records, list)
        and len(records) == len(P00_BASELINE_RECORDS)
        and [row.get("path") for row in records if isinstance(row, dict)]
        == list(P00_BASELINE_RECORDS),
        "G05 run identity P00 tracked-record closure differs",
    )
    payloads: dict[str, bytes] = {}
    for index, (record, relative) in enumerate(zip(records, P00_BASELINE_RECORDS)):
        _require(isinstance(record, dict), f"G05 P00 tracked record {index} is not an object")
        _git_output(
            repository_root,
            ("ls-files", "--error-unmatch", "--", relative),
            f"G05 P00 tracked record {relative}",
        )
        _, payload = _repository_file(
            repository_root,
            relative,
            f"G05 P00 tracked record {relative}",
        )
        payloads[relative] = payload
        _require(
            set(record) == {"path", "sha256", "size_bytes"}
            and record.get("sha256") == _sha256(payload)
            and record.get("size_bytes") == len(payload),
            f"G05 P00 tracked record {relative} binding differs",
        )
    audit = _json_object(payloads["audit-result.json"], "G05 tracked audit result")
    audit_scan = audit.get("attribution_scan")
    _require(
        isinstance(audit_scan, dict),
        "G05 tracked audit result lacks its P00 scan binding",
    )
    try:
        work_plan = payloads["local-work-plan.md"].decode("utf-8", errors="strict")
    except UnicodeDecodeError as error:
        raise G05GateError("G05 tracked local work plan is not UTF-8") from error
    plan_matches = re.findall(
        r"^Baseline commit: `([0-9a-f]{40})`$",
        work_plan,
        flags=re.MULTILINE,
    )
    evaluator = _python_string_assignment(
        payloads["validation/calibration_v2/production_evaluator.py"],
        "P00_COMMIT",
        "G05 tracked production evaluator",
    )
    adapter = _python_string_assignment(
        payloads["validation/calibration_v2/native_adapter/factory.py"],
        "_P00_COMMIT",
        "G05 tracked native adapter factory",
    )
    _require(
        len(plan_matches) == 1
        and all(
            value == baseline
            for value in (audit_scan.get("base"), plan_matches[0], evaluator, adapter)
        ),
        "G05 P00 baseline differs from current tracked baseline records",
    )
    head = _git_output(
        repository_root,
        ("rev-parse", "--verify", "HEAD"),
        "G05 current source",
    ).decode("ascii", errors="strict").strip()
    _require(head == source_commit, "G05 repository HEAD differs from the receipt source commit")
    _git_output(
        repository_root,
        ("cat-file", "-e", f"{baseline}^{{commit}}"),
        "G05 P00 baseline object",
    )
    _git_output(
        repository_root,
        ("merge-base", "--is-ancestor", str(baseline), source_commit),
        "G05 P00 baseline ancestry",
    )
    return str(baseline)


def _repository_sha256(repository_root: Path, relative: str, label: str) -> str:
    _, payload = _repository_file(repository_root, relative, label)
    return _sha256(payload)


def _recorded_executable(value: object, label: str) -> str:
    _require(isinstance(value, str) and value, f"{label} executable is absent")
    path = Path(value)
    _require(path.is_absolute(), f"{label} executable is not absolute")
    lexical = Path(os.path.abspath(os.path.normpath(os.fspath(path))))
    _require(lexical == path, f"{label} executable is not lexically normalized")
    try:
        resolved = path.resolve(strict=True)
    except OSError as error:
        raise G05GateError(f"{label} executable cannot be resolved") from error
    _require(resolved == path, f"{label} executable is not canonical")
    return os.fspath(path)


def _validate_run_identity(
    *,
    repository_root: Path,
    document: Mapping[str, Any],
    source_commit: str,
    closure: Mapping[str, Any],
    upstream_bindings_sha256: str,
) -> tuple[str, str, str, datetime, datetime]:
    validator = _schema_validator(
        repository_root,
        str(G05_SCHEMA_DIRECTORY / RUN_IDENTITY_SCHEMA),
    )
    _validate_schema(document, validator, "G05 aggregate run identity")
    _validate_self_hash(document, "identity_sha256", "G05 aggregate run identity")
    started = _parse_utc_z(document.get("started_utc"), "G05 run identity start")
    ended = _parse_utc_z(document.get("ended_utc"), "G05 run identity end")
    _require(ended >= started, "G05 run identity end precedes its start")
    _require(
        document.get("source_commit") == source_commit
        and document.get("outcome") == "pass"
        and document.get("holdout_accessed") is False
        and document.get("holdout_access_status") == "proven_unopened"
        and document.get("assessor_pixel_accessed") is False,
        "G05 run identity pass or data-access semantics differ",
    )
    baseline = _validate_p00_baseline_binding(
        repository_root=repository_root,
        document=document.get("p00_baseline"),
        source_commit=source_commit,
    )
    working_tree = document.get("working_tree")
    _require(
        isinstance(working_tree, dict)
        and working_tree.get("clean") is True
        and working_tree.get("dirty_state_sha256") == _sha256(b""),
        "G05 run identity clean working-tree binding differs",
    )
    provenance = closure.get("provenance_manifest_sha256")
    _require(isinstance(provenance, Mapping), "G05 P05 provenance closure is absent")
    components = document.get("configuration_components")
    context = document.get("evidence_context")
    synthetic_input = document.get("synthetic_input")
    synthetic_target = document.get("synthetic_target")
    instruction = document.get("instruction_package")
    _require(
        isinstance(components, dict)
        and isinstance(context, dict)
        and isinstance(synthetic_input, dict)
        and isinstance(synthetic_target, dict)
        and isinstance(instruction, dict),
        "G05 run identity evidence bindings are absent",
    )
    expected_components = {
        "mapping": _repository_sha256(
            repository_root,
            MAPPING_SEED_RELATIVE,
            "G05 current mapping seed",
        ),
        "operator_bank": _repository_sha256(
            repository_root,
            OPERATOR_BANK_SEED_RELATIVE,
            "G05 current operator-bank seed",
        ),
        "metric_policy": _repository_sha256(
            repository_root,
            METRIC_POLICY_RELATIVE,
            "G05 current metric policy",
        ),
    }
    _require(
        all(
            isinstance(components.get(name), dict)
            and components[name].get("sha256") == digest
            for name, digest in expected_components.items()
        ),
        "G05 run identity current configuration-component hash differs",
    )
    quality = context.get("quality_harness_manifest")
    spatial = context.get("spatial_preregistration")
    upstream = context.get("upstream_bindings")
    _require(
        document.get("configuration_sha256") == provenance.get("configuration")
        and synthetic_input.get("sha256") == provenance.get("harness")
        and synthetic_target.get("sha256") == closure.get("run_sha256")
        and isinstance(quality, dict)
        and quality.get("sha256")
        == _repository_sha256(
            repository_root,
            QUALITY_MANIFEST_RELATIVE,
            "G05 current quality-harness manifest",
        )
        and isinstance(spatial, dict)
        and spatial.get("sha256")
        == _repository_sha256(
            repository_root,
            SPATIAL_PREREGISTRATION_RELATIVE,
            "G05 current spatial preregistration",
        )
        and upstream
        == {"status": "bound_in_wrapper", "sha256": upstream_bindings_sha256}
        and instruction.get("p00_baseline_commit") == baseline,
        "G05 run identity current evidence-context binding differs",
    )
    toolchain = document.get("toolchain")
    _require(isinstance(toolchain, dict), "G05 run identity toolchain is absent")
    python = toolchain.get("python")
    swiftlint = toolchain.get("swiftlint")
    _require(
        isinstance(python, dict) and isinstance(swiftlint, dict),
        "G05 run identity command tool bindings are absent",
    )
    return (
        baseline,
        _recorded_executable(python.get("executable"), "G05 Python"),
        _recorded_executable(swiftlint.get("executable"), "G05 SwiftLint"),
        started,
        ended,
    )


def _canonical_command_environment(
    repository_root: Path,
    *,
    python: bool,
) -> Mapping[str, str]:
    environment = {
        "HOME": os.environ.get("HOME", ""),
        "PATH": CANONICAL_COMMAND_PATH,
        "LANG": "C",
        "LC_ALL": "C",
    }
    if python:
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        environment["PYTHONPATH"] = os.fspath(repository_root)
    return environment


def _original_partial_root(wrapper_root: Path) -> Path:
    if not wrapper_root.is_absolute() and _PINNED_WRAPPER_CONTEXT is not None:
        wrapper_root = _PINNED_WRAPPER_CONTEXT.logical_root
    name = wrapper_root.name
    if name.startswith(".") and name.endswith(".partial") and len(name) > len("..partial"):
        return wrapper_root
    return wrapper_root.parent / f".{name}.partial"


def _expected_command_contracts(
    *,
    repository_root: Path,
    wrapper_root: Path,
    baseline_commit: str,
    python_executable: str,
    swiftlint_executable: str,
) -> Mapping[str, Mapping[str, Any]]:
    partial_root = _original_partial_root(wrapper_root)
    python_environment = dict(_canonical_command_environment(repository_root, python=True))
    native_environment = dict(_canonical_command_environment(repository_root, python=False))
    result: dict[str, Mapping[str, Any]] = {}
    for identifier in G05_COMMAND_IDS[:3]:
        result[identifier] = {
            "id": identifier,
            "argv": [
                python_executable,
                "validation/spatial_v2/run_p05_evidence.py",
                "--output",
                os.fspath(partial_root / "evidence" / identifier),
            ],
            "cwd": os.fspath(repository_root),
            "environment": python_environment,
            "exit_status": 0,
            "output_path": f"outputs/{identifier}.log",
        }
    for identifier, suffix in (("quality-lock-a", "a"), ("quality-lock-b", "b")):
        result[identifier] = {
            "id": identifier,
            "argv": [
                python_executable,
                "validation/quality/tools/"
                "build_quality_harness_implementation_manifest.py",
                "--repository-root",
                os.fspath(repository_root),
                "--output",
                os.fspath(partial_root / f"inputs/quality-harness-lock-{suffix}.json"),
            ],
            "cwd": os.fspath(repository_root),
            "environment": python_environment,
            "exit_status": 0,
            "output_path": f"outputs/{identifier}.log",
        }
    result["swiftlint"] = {
        "id": "swiftlint",
        "argv": [
            swiftlint_executable,
            "lint",
            "--quiet",
            "--strict",
            "--config",
            ".swiftlint.yml",
        ],
        "cwd": os.fspath(repository_root),
        "environment": native_environment,
        "exit_status": 0,
        "output_path": "outputs/swiftlint.log",
    }
    result["attribution"] = {
        "id": "attribution",
        "argv": [
            python_executable,
            "tools/scan_project_attribution.py",
            os.fspath(repository_root),
            "--policy",
            "config/attribution_policy.json",
            "--base",
            baseline_commit,
            "--include",
            os.fspath(partial_root),
        ],
        "cwd": INSTRUCTION_PACKAGE_ROOT_TOKEN,
        "environment": python_environment,
        "exit_status": 0,
        "output_path": "outputs/attribution.log",
    }
    result["instruction-package"] = {
        "id": "instruction-package",
        "argv": [python_executable, "tools/validate_instruction_package.py"],
        "cwd": INSTRUCTION_PACKAGE_ROOT_TOKEN,
        "environment": python_environment,
        "exit_status": 0,
        "output_path": "outputs/instruction-package.log",
    }
    result["diff-check"] = {
        "id": "diff-check",
        "argv": ["/usr/bin/git", "diff", "--check"],
        "cwd": os.fspath(repository_root),
        "environment": native_environment,
        "exit_status": 0,
        "output_path": "outputs/diff-check.log",
    }
    return result


def _validate_command_plan_document(
    *,
    repository_root: Path,
    wrapper_root: Path,
    document: Mapping[str, Any],
    source_commit: str,
    baseline_commit: str,
    python_executable: str,
    swiftlint_executable: str,
) -> Sequence[Mapping[str, Any]]:
    validator = _schema_validator(
        repository_root,
        str(G05_SCHEMA_DIRECTORY / COMMAND_PLAN_SCHEMA),
    )
    _validate_schema(document, validator, "G05 aggregate command plan")
    rows = document.get("commands")
    _require(
        document.get("source_commit") == source_commit
        and isinstance(rows, list)
        and len(rows) == len(G05_COMMAND_IDS)
        and [row.get("id") for row in rows if isinstance(row, dict)]
        == list(G05_COMMAND_IDS),
        "G05 command plan source or exact command order differs",
    )
    contracts = _expected_command_contracts(
        repository_root=repository_root,
        wrapper_root=wrapper_root,
        baseline_commit=baseline_commit,
        python_executable=python_executable,
        swiftlint_executable=swiftlint_executable,
    )
    for index, (row, identifier) in enumerate(zip(rows, G05_COMMAND_IDS)):
        _require(
            isinstance(row, dict) and row == contracts[identifier],
            f"G05 command plan row {index} differs from its canonical contract",
        )
    return rows


def _expected_command_products(identifier: str) -> tuple[str, ...]:
    if identifier in G05_COMMAND_IDS[:3]:
        return tuple(f"evidence/{identifier}/{name}" for name in EVIDENCE_FILENAMES)
    if identifier in {"quality-lock-a", "quality-lock-b"}:
        return (f"inputs/quality-harness-lock-{identifier[-1]}.json",)
    if identifier == "instruction-package":
        return (
            "inputs/instruction-package/package_manifest.json",
            "inputs/instruction-package/SHA256SUMS.txt",
        )
    return ()


def _validate_instruction_package_output(payload: bytes) -> Mapping[str, str]:
    try:
        text = payload.decode("utf-8", errors="strict")
    except UnicodeDecodeError as error:
        raise G05GateError("G05 instruction-package output is not UTF-8") from error
    _require(text.endswith("\n"), "G05 instruction-package output lacks its final LF")
    lines = text.splitlines()
    _require(len(lines) >= 4 and lines[0] == "PASS", "G05 instruction-package PASS line differs")
    counts: dict[str, int] = {}
    for line, key in zip(
        lines[1:4],
        ("total_files", "payload_files", "checksum_entries"),
    ):
        prefix = f"{key}="
        value = line.removeprefix(prefix)
        _require(
            line.startswith(prefix)
            and value.isascii()
            and value.isdecimal()
            and str(int(value)) == value,
            f"G05 instruction-package {key} line differs",
        )
        counts[key] = int(value)
    hash_lines = lines[4:]
    _require(
        counts["total_files"] == counts["payload_files"] + 2
        and counts["checksum_entries"] == counts["total_files"] - 1
        and len(hash_lines) == counts["payload_files"],
        "G05 instruction-package count closure differs",
    )
    bindings: dict[str, str] = {}
    for index, line in enumerate(hash_lines):
        digest, separator, relative = line.partition("  ")
        parsed = _safe_relative(relative, f"G05 instruction-package hash row {index}")
        _require(
            separator == "  "
            and len(digest) == 64
            and all(character in "0123456789abcdef" for character in digest)
            and parsed.as_posix() not in bindings,
            f"G05 instruction-package hash row {index} differs",
        )
        bindings[parsed.as_posix()] = digest
    _require(
        list(bindings) == sorted(bindings),
        "G05 instruction-package hash rows are not in canonical path order",
    )
    return bindings


def _checksum_index_bindings(payload: bytes) -> Mapping[str, str]:
    try:
        text = payload.decode("utf-8", errors="strict")
    except UnicodeDecodeError as error:
        raise G05GateError("G05 instruction-package checksum index is not UTF-8") from error
    _require(text.endswith("\n"), "G05 instruction-package checksum index lacks its final LF")
    result: dict[str, str] = {}
    for index, line in enumerate(text.splitlines()):
        digest, separator, relative = line.partition("  ")
        parsed = _safe_relative(relative, f"G05 instruction checksum row {index}")
        _require(
            separator == "  "
            and len(digest) == 64
            and all(character in "0123456789abcdef" for character in digest)
            and parsed.as_posix() not in result,
            f"G05 instruction checksum row {index} differs",
        )
        result[parsed.as_posix()] = digest
    _require(
        bool(result) and list(result) == sorted(result),
        "G05 instruction checksum path order or closure differs",
    )
    return result


def _validate_instruction_package_products(
    *,
    stdout_bindings: Mapping[str, str],
    product_payloads: Mapping[str, bytes],
    run_identity: Mapping[str, Any],
) -> None:
    manifest_path = "inputs/instruction-package/package_manifest.json"
    checksum_path = "inputs/instruction-package/SHA256SUMS.txt"
    manifest_payload = product_payloads[manifest_path]
    checksum_payload = product_payloads[checksum_path]
    manifest = _json_object(manifest_payload, "G05 instruction-package manifest")
    files = manifest.get("files")
    _require(
        set(manifest)
        == {
            "schema_version",
            "package",
            "created_utc",
            "total_package_file_count",
            "payload_file_count",
            "checksum_entry_count",
            "payload_exclusions",
            "files",
        }
        and isinstance(manifest.get("schema_version"), str)
        and isinstance(manifest.get("package"), str)
        and bool(manifest["package"])
        and isinstance(files, list)
        and manifest.get("payload_exclusions")
        == ["SHA256SUMS.txt", "package_manifest.json"],
        "G05 instruction-package manifest identity differs",
    )
    _parse_utc_z(manifest.get("created_utc"), "G05 instruction-package creation time")
    manifest_bindings: dict[str, str] = {}
    for index, row in enumerate(files):
        _require(isinstance(row, dict), f"G05 instruction manifest row {index} is not an object")
        relative = _safe_relative(row.get("path"), f"G05 instruction manifest row {index}").as_posix()
        digest = row.get("sha256")
        _require(
            set(row) == {"path", "sha256", "size_bytes"}
            and isinstance(digest, str)
            and len(digest) == 64
            and all(character in "0123456789abcdef" for character in digest)
            and type(row.get("size_bytes")) is int
            and row["size_bytes"] > 0
            and relative not in manifest_bindings,
            f"G05 instruction manifest row {index} binding differs",
        )
        manifest_bindings[relative] = str(digest)
    _require(
        manifest_bindings == dict(stdout_bindings)
        and list(manifest_bindings) == sorted(manifest_bindings)
        and type(manifest.get("total_package_file_count")) is int
        and type(manifest.get("payload_file_count")) is int
        and type(manifest.get("checksum_entry_count")) is int
        and manifest.get("total_package_file_count") == len(stdout_bindings) + 2
        and manifest.get("payload_file_count") == len(stdout_bindings)
        and manifest.get("checksum_entry_count") == len(stdout_bindings) + 1,
        "G05 instruction-package manifest payload closure differs",
    )
    checksum_bindings = _checksum_index_bindings(checksum_payload)
    expected_checksums = dict(stdout_bindings)
    expected_checksums["package_manifest.json"] = _sha256(manifest_payload)
    expected_checksums = dict(sorted(expected_checksums.items()))
    _require(
        checksum_bindings == expected_checksums,
        "G05 instruction checksum index does not bind the manifest and payload closure",
    )
    instruction = run_identity.get("instruction_package")
    components = run_identity.get("configuration_components")
    _require(
        isinstance(instruction, dict)
        and instruction.get("package_manifest_sha256") == _sha256(manifest_payload)
        and instruction.get("checksum_index_sha256") == _sha256(checksum_payload)
        and isinstance(components, dict)
        and isinstance(components.get("media_policy"), dict)
        and stdout_bindings.get("config/geometry_color_audio_policy.json")
        == components["media_policy"].get("sha256"),
        "G05 instruction products do not bind the run identity",
    )


def _validate_command_stdout(
    *,
    repository_root: Path,
    identifier: str,
    payload: bytes,
    product_payloads: Mapping[str, bytes],
    baseline_commit: str,
) -> Mapping[str, str] | None:
    if identifier in G05_COMMAND_IDS[:3]:
        expected = b"".join(
            (
                f"{_sha256(product_payloads[f'evidence/{identifier}/{name}'])}  {name}\n"
            ).encode("utf-8")
            for name in EVIDENCE_FILENAMES
        )
        _require(payload == expected, f"G05 {identifier} stdout P05 hash closure differs")
        return None
    if identifier in {"quality-lock-a", "quality-lock-b"}:
        relative = f"inputs/quality-harness-lock-{identifier[-1]}.json"
        product = product_payloads[relative]
        document = _json_object(product, f"G05 {identifier} produced manifest")
        manifest_sha256 = document.get("manifest_sha256")
        _require(
            isinstance(manifest_sha256, str)
            and len(manifest_sha256) == 64
            and all(character in "0123456789abcdef" for character in manifest_sha256)
            and payload == f"{manifest_sha256}\n".encode("ascii"),
            f"G05 {identifier} stdout manifest hash differs",
        )
        _, current = _repository_file(
            repository_root,
            QUALITY_MANIFEST_RELATIVE,
            "G05 current quality-harness manifest",
        )
        _require(product == current, f"G05 {identifier} produced manifest is not current")
        return None
    if identifier == "swiftlint":
        try:
            text = payload.decode("utf-8", errors="strict")
        except UnicodeDecodeError as error:
            raise G05GateError("G05 SwiftLint output is not UTF-8") from error
        summaries = re.findall(
            r"Found 0 violations, 0 serious in [1-9][0-9]* files\.",
            text,
        )
        _require(
            len(summaries) == 1
            and re.search(r"Found [1-9][0-9]* violations", text) is None
            and "error:" not in text.lower(),
            "G05 SwiftLint output does not prove one zero-violation strict run",
        )
        return None
    if identifier == "attribution":
        document = _json_object(payload, "G05 attribution output")
        _require(
            set(document) == {"status", "base", "changed_file_count", "findings"}
            and document.get("status") == "pass"
            and document.get("base") == baseline_commit
            and type(document.get("changed_file_count")) is int
            and document["changed_file_count"] >= 0
            and document.get("findings") == [],
            "G05 attribution output does not prove a clean baseline-bound scan",
        )
        return None
    if identifier == "instruction-package":
        return _validate_instruction_package_output(payload)
    if identifier == "diff-check":
        _require(payload == b"", "G05 diff-check output is not empty")
        return None
    raise G05GateError(f"unsupported G05 command class: {identifier}")


def _validate_command_execution_aggregate(
    *,
    repository_root: Path,
    wrapper_root: Path,
    document: Mapping[str, Any],
    source_commit: str,
    closure: Mapping[str, Any],
    upstream_bindings_sha256: str,
) -> tuple[str, ...]:
    material = dict(document)
    claimed = material.pop("aggregate_sha256", None)
    _require(
        set(material)
        == {
            "schema_version",
            "artifact_kind",
            "status",
            "source_commit",
            "command_plan",
            "run_identity",
            "commands",
        }
        and claimed == canonical_sha256(material)
        and material.get("schema_version") == "1.0.0"
        and material.get("artifact_kind") == "g05_command_execution_aggregate"
        and material.get("status") == "pass"
        and material.get("source_commit") == source_commit,
        "G05 command execution aggregate identity or self-hash differs",
    )
    reopened: list[str] = []
    bound_documents: dict[str, Mapping[str, Any]] = {}
    for field, expected_path in (
        ("command_plan", "inputs/g05-command-plan.json"),
        ("run_identity", "run-identity.json"),
    ):
        relative, payload = _execution_file_from_binding(
            wrapper_root,
            material.get(field),
            expected_path,
            f"G05 aggregate {field}",
        )
        parsed = _json_object(payload, f"G05 aggregate {field}")
        _require(
            payload == document_bytes(parsed),
            f"G05 aggregate {field} is not canonical JSON",
        )
        bound_documents[field] = parsed
        reopened.append(relative)
    (
        baseline,
        python_executable,
        swiftlint_executable,
        run_started,
        run_ended,
    ) = _validate_run_identity(
        repository_root=repository_root,
        document=bound_documents["run_identity"],
        source_commit=source_commit,
        closure=closure,
        upstream_bindings_sha256=upstream_bindings_sha256,
    )
    command_plan_rows = _validate_command_plan_document(
        repository_root=repository_root,
        wrapper_root=wrapper_root,
        document=bound_documents["command_plan"],
        source_commit=source_commit,
        baseline_commit=baseline,
        python_executable=python_executable,
        swiftlint_executable=swiftlint_executable,
    )
    rows = material.get("commands")
    _require(
        isinstance(rows, list)
        and len(rows) == len(G05_COMMAND_IDS)
        and [row.get("id") for row in rows if isinstance(row, dict)]
        == list(G05_COMMAND_IDS),
        "G05 command execution aggregate command closure differs",
    )
    instruction_hashes: Mapping[str, str] | None = None
    instruction_products: Mapping[str, bytes] | None = None
    previous_command_end = run_started
    for row, plan_row, identifier in zip(rows, command_plan_rows, G05_COMMAND_IDS):
        _require(
            isinstance(row, dict)
            and set(row) == {"id", "stdout", "stderr", "result"},
            f"G05 command execution aggregate row differs for {identifier}",
        )
        streams: dict[str, bytes] = {}
        for field, suffix in (("stdout", ".log"), ("stderr", ".stderr.log")):
            expected_path = f"outputs/{identifier}{suffix}"
            relative, payload = _execution_file_from_binding(
                wrapper_root,
                row.get(field),
                expected_path,
                f"G05 aggregate {identifier} {field}",
            )
            reopened.append(relative)
            streams[field] = payload
        result_relative, result_payload = _execution_file_from_binding(
            wrapper_root,
            row.get("result"),
            f"outputs/{identifier}.result.json",
            f"G05 aggregate {identifier} result",
        )
        reopened.append(result_relative)
        result = _json_object(result_payload, f"G05 aggregate {identifier} result")
        result_material = dict(result)
        result_claimed = result_material.pop("receipt_sha256", None)
        _require(
            set(result_material)
            == {
                "schema_version",
                "artifact_kind",
                "command_id",
                "status",
                "started_utc",
                "ended_utc",
                "expected_exit_status",
                "actual_exit_status",
                "command_plan_row_sha256",
                "stdout",
                "stderr",
                "produced_artifacts",
            }
            and result_payload == document_bytes(result)
            and result_claimed == canonical_sha256(result_material)
            and result.get("schema_version") == "1.0.0"
            and result.get("artifact_kind") == "g05_bound_command_result"
            and result.get("command_id") == identifier
            and result.get("status") == "pass"
            and result.get("expected_exit_status") == 0
            and type(result.get("actual_exit_status")) is int
            and result.get("actual_exit_status") == 0
            and result.get("command_plan_row_sha256") == canonical_sha256(plan_row)
            and result.get("stdout") == row.get("stdout")
            and result.get("stderr") == row.get("stderr")
            and streams["stderr"] == b"",
            f"G05 aggregate {identifier} result semantics differ",
        )
        started = _parse_utc_z(result.get("started_utc"), f"G05 {identifier} start")
        ended = _parse_utc_z(result.get("ended_utc"), f"G05 {identifier} end")
        _require(
            run_started <= previous_command_end <= started <= ended <= run_ended,
            f"G05 {identifier} interval is outside the run-identity interval",
        )
        previous_command_end = ended
        expected_products = _expected_command_products(identifier)
        products = result.get("produced_artifacts")
        _require(
            isinstance(products, list)
            and len(products) == len(expected_products)
            and [binding.get("path") for binding in products if isinstance(binding, dict)]
            == list(expected_products),
            f"G05 {identifier} produced-artifact closure differs",
        )
        product_payloads: dict[str, bytes] = {}
        for index, (binding, expected_path) in enumerate(zip(products, expected_products)):
            relative, payload = _execution_file_from_binding(
                wrapper_root,
                binding,
                expected_path,
                f"G05 {identifier} produced artifact {index}",
            )
            reopened.append(relative)
            product_payloads[relative] = payload
        observed_instruction_hashes = _validate_command_stdout(
            repository_root=repository_root,
            identifier=identifier,
            payload=streams["stdout"],
            product_payloads=product_payloads,
            baseline_commit=baseline,
        )
        if observed_instruction_hashes is not None:
            instruction_hashes = observed_instruction_hashes
            instruction_products = product_payloads
    _require(
        instruction_hashes is not None
        and instruction_products is not None,
        "G05 instruction output or product closure is absent",
    )
    _validate_instruction_package_products(
        stdout_bindings=instruction_hashes,
        product_payloads=instruction_products,
        run_identity=bound_documents["run_identity"],
    )
    _require(len(reopened) == len(set(reopened)), "G05 command aggregate paths are ambiguous")
    return tuple(reopened)


def _manifest_rows(document: Mapping[str, Any], label: str) -> Mapping[str, Mapping[str, Any]]:
    rows = document.get("artifacts")
    _require(isinstance(rows, list), f"{label} artifacts are not an array")
    result: dict[str, Mapping[str, Any]] = {}
    for index, row in enumerate(rows):
        _require(isinstance(row, dict), f"{label} artifact {index} is not an object")
        path = row.get("path")
        _safe_relative(path, f"{label} artifact {index}")
        _require(
            isinstance(path, str)
            and path not in result
            and isinstance(row.get("sha256"), str)
            and len(row["sha256"]) == 64
            and all(character in "0123456789abcdef" for character in row["sha256"])
            and type(row.get("size_bytes")) is int
            and row["size_bytes"] >= 0,
            f"{label} artifact {index} binding is invalid or duplicated",
        )
        result[path] = row
    return result


def _g04_closure_material(
    manifest: Mapping[str, Any],
    manifest_sha256: str,
) -> Mapping[str, Any]:
    _require(
        isinstance(manifest_sha256, str)
        and len(manifest_sha256) == 64
        and all(character in "0123456789abcdef" for character in manifest_sha256),
        "G04 closure manifest SHA-256 is invalid",
    )
    _require(
        manifest.get("schema_version") == "2.0.0",
        "G04 closure requires a finalized v2 artifact manifest",
    )
    rows = manifest.get("artifacts")
    directories = manifest.get("directories")
    _require(
        isinstance(rows, list) and bool(rows),
        "G04 closure artifact rows are absent",
    )
    validated_rows = _manifest_rows(manifest, "G04 closure manifest")
    row_paths = [row.get("path") for row in rows if isinstance(row, dict)]
    _require(
        len(row_paths) == len(rows)
        and row_paths == sorted(row_paths)
        and len(set(row_paths)) == len(row_paths),
        "G04 closure artifact path order or uniqueness differs",
    )
    _require(
        "artifact-manifest.json" not in row_paths,
        "G04 closure artifact rows contain the reserved manifest path",
    )
    _require(
        isinstance(directories, list)
        and all(isinstance(path, str) for path in directories)
        and directories == sorted(directories)
        and len(set(directories)) == len(directories),
        "G04 closure directory order or uniqueness differs",
    )
    for index, relative in enumerate(directories):
        _safe_relative(relative, f"G04 closure directory {index}")
    expected_directories: set[str] = set()
    for relative in (*row_paths, *directories):
        parsed = PurePosixPath(relative)
        for depth in range(1, len(parsed.parts)):
            expected_directories.add(PurePosixPath(*parsed.parts[:depth]).as_posix())
    _require(
        expected_directories.issubset(set(directories))
        and not set(row_paths).intersection(directories),
        "G04 closure manifest omits a transitive parent or collides with a file",
    )
    artifact_bindings = [
        {
            "path": path,
            "sha256": validated_rows[path]["sha256"],
            "size_bytes": validated_rows[path]["size_bytes"],
        }
        for path in row_paths
    ]
    return {
        "manifest_sha256": manifest_sha256,
        "directories": directories,
        "artifacts": artifact_bindings,
    }


def build_g04_closure_attestation(
    *,
    manifest: Mapping[str, Any],
    manifest_sha256: str,
) -> Mapping[str, Any]:
    """Build the deterministic compact attestation for a verified G04 wrapper."""

    material = _g04_closure_material(manifest, manifest_sha256)
    artifacts = material["artifacts"]
    directories = material["directories"]
    transaction = next(
        (
            row
            for row in artifacts
            if row["path"] == "publication-transaction.json"
        ),
        None,
    )
    _require(
        transaction is not None,
        "G04 closure manifest omits the publication transaction",
    )
    return {
        "schema_version": "1.0.0",
        "status": "pass",
        "closure_algorithm": "sha256-canonical-json-v1",
        "manifest_sha256": manifest_sha256,
        "artifact_file_count": len(artifacts),
        "wrapper_file_count": len(artifacts) + 1,
        "descendant_directory_count": len(directories),
        "wrapper_directory_count": len(directories) + 1,
        "publication_transaction_sha256": transaction["sha256"],
        "single_link_regular_files": True,
        "root_and_descendants_user_immutable": True,
        "root_and_descendants_read_only": True,
        "closure_composite_sha256": canonical_sha256(material),
    }


def validate_g04_closure_attestation(
    *,
    manifest: Mapping[str, Any],
    manifest_sha256: str,
    attestation: object,
) -> Mapping[str, Any]:
    """Require an exact deterministic attestation for a copied G04 manifest."""

    expected = build_g04_closure_attestation(
        manifest=manifest,
        manifest_sha256=manifest_sha256,
    )
    _require(
        isinstance(attestation, dict) and attestation == expected,
        "G04 transitive closure attestation differs from its copied manifest",
    )
    return expected


def _manifest_bound_reference(
    value: object,
    *,
    manifest_rows: Mapping[str, Mapping[str, Any]],
    manifest_directories: object,
    label: str,
    directory: bool = False,
) -> None:
    _require(isinstance(value, str) and value, f"{label} reference is absent")
    if directory:
        _require(
            isinstance(manifest_directories, list)
            and value in manifest_directories,
            f"{label} directory is not manifest-bound: {value}",
        )
    else:
        _require(value in manifest_rows, f"{label} file is not manifest-bound: {value}")


def _validate_g04_assessment(
    assessment: Mapping[str, Any],
    *,
    source_commit: str,
    manifest_rows: Mapping[str, Mapping[str, Any]],
    manifest_directories: object,
) -> None:
    expected_criteria = [
        {"criterion": criterion, "pass": True}
        for criterion in G04_ASSESSMENT_CRITERIA
    ]
    _require(
        assessment.get("schema_version") == "1.0.0"
        and assessment.get("gate") == "G04"
        and assessment.get("status") == "pass"
        and assessment.get("holdout_accessed") is False
        and assessment.get("project_commit") == source_commit
        and assessment.get("algorithm_quality_claimed") is False
        and assessment.get("criteria") == expected_criteria,
        "G04 assessment is not an exact same-source seven-criterion pass",
    )
    evidence = assessment.get("evidence")
    _require(
        isinstance(evidence, list)
        and bool(evidence)
        and len(evidence) == len(set(evidence)),
        "G04 assessment evidence closure is invalid",
    )
    for index, reference in enumerate(evidence):
        _manifest_bound_reference(
            reference,
            manifest_rows=manifest_rows,
            manifest_directories=manifest_directories,
            label=f"G04 assessment evidence {index}",
        )


def _validate_g04_test_evidence(
    tests: Mapping[str, Any],
    manifest_rows: Mapping[str, Mapping[str, Any]],
    manifest_directories: object,
) -> None:
    _require(
        tests.get("schema_version") == "1.0.0"
        and tests.get("status") == "pass",
        "G04 test-results identity or status differs",
    )
    xcode = tests.get("xcode_full")
    release = tests.get("release_build")
    python = tests.get("python")
    _require(isinstance(xcode, dict), "G04 Xcode evidence is absent")
    _require(isinstance(release, dict), "G04 release-build evidence is absent")
    _require(isinstance(python, dict), "G04 Python evidence is absent")
    total = xcode.get("total")
    passed = xcode.get("passed")
    failed = xcode.get("failed")
    skipped = xcode.get("skipped")
    _require(
        xcode.get("status") in {"pass", "passed"}
        and all(type(value) is int for value in (total, passed, failed, skipped))
        and total > 0
        and passed > 0
        and failed == 0
        and skipped >= 0
        and total == passed + failed + skipped,
        "G04 Xcode counts are absent, inconsistent, or failing",
    )
    if skipped:
        expected = xcode.get(
            "expected_skips",
            xcode.get("expected_skip", xcode.get("expected_non_g04_skip")),
        )
        _require(expected not in (None, "", []), "G04 Xcode has an unexpected skip")
        if isinstance(expected, list):
            _require(len(expected) == skipped, "G04 Xcode expected-skip count differs")
        else:
            _require(skipped == 1, "G04 Xcode expected-skip record is ambiguous")
    _manifest_bound_reference(
        xcode.get("summary"),
        manifest_rows=manifest_rows,
        manifest_directories=manifest_directories,
        label="G04 Xcode summary",
    )
    _manifest_bound_reference(
        xcode.get("coverage"),
        manifest_rows=manifest_rows,
        manifest_directories=manifest_directories,
        label="G04 Xcode coverage",
    )
    _manifest_bound_reference(
        xcode.get("result_bundle"),
        manifest_rows=manifest_rows,
        manifest_directories=manifest_directories,
        label="G04 Xcode result bundle",
        directory=True,
    )
    _require(
        release.get("status") in {"pass", "passed", "succeeded"}
        and set(("warnings", "errors", "analyzer_warnings")).issubset(release)
        and all(
            type(release.get(name)) is int
            for name in ("warnings", "errors", "analyzer_warnings")
        )
        and release.get("warnings") == 0
        and release.get("errors") == 0
        and release.get("analyzer_warnings") == 0,
        "G04 release-build zero-count evidence is absent or failing",
    )
    _manifest_bound_reference(
        release.get("summary"),
        manifest_rows=manifest_rows,
        manifest_directories=manifest_directories,
        label="G04 release summary",
    )
    _manifest_bound_reference(
        release.get("result_bundle"),
        manifest_rows=manifest_rows,
        manifest_directories=manifest_directories,
        label="G04 release result bundle",
        directory=True,
    )
    _require(
        python.get("status") in {"pass", "passed"}
        and type(python.get("test_count")) is int
        and python["test_count"] > 0
        and "failures" in python
        and "skips" in python
        and type(python.get("failures")) is int
        and type(python.get("skips")) is int
        and python.get("failures") == 0
        and python.get("skips") == 0,
        "G04 Python counts are absent or failing",
    )
    _manifest_bound_reference(
        python.get("log"),
        manifest_rows=manifest_rows,
        manifest_directories=manifest_directories,
        label="G04 Python log",
    )
    status_records = (
        ("production_dry_run", "verification"),
        ("metric_oracle", "log"),
        ("actual_codec_cli", "log"),
        ("static_validation", "log"),
        ("instruction_package", "log"),
    )
    for name, reference_key in status_records:
        record = tests.get(name)
        _require(
            isinstance(record, dict) and record.get("status") == "pass",
            f"G04 {name} passing evidence is absent",
        )
        _manifest_bound_reference(
            record.get(reference_key),
            manifest_rows=manifest_rows,
            manifest_directories=manifest_directories,
            label=f"G04 {name} {reference_key}",
        )
    dry_run = tests["production_dry_run"]
    _require(
        dry_run.get("holdout_accessed") is False
        and type(dry_run.get("case_count")) is int
        and dry_run["case_count"] > 0
        and type(dry_run.get("writer_run_count")) is int
        and dry_run["writer_run_count"] > 0
        and dry_run.get("injected_failure_preserved") is True
        and dry_run.get("resume_recomputed") is True,
        "G04 production dry-run semantics differ",
    )
    _require(
        isinstance(tests["actual_codec_cli"].get("evidence_sha256"), str)
        and len(tests["actual_codec_cli"]["evidence_sha256"]) == 64
        and all(
            character in "0123456789abcdef"
            for character in tests["actual_codec_cli"]["evidence_sha256"]
        ),
        "G04 actual-codec evidence hash is invalid",
    )
    attribution = tests.get("attribution_scan")
    _require(
        isinstance(attribution, dict)
        and attribution.get("status") == "pass"
        and type(attribution.get("findings")) is int
        and attribution.get("findings") == 0,
        "G04 attribution evidence is absent or has findings",
    )
    _manifest_bound_reference(
        attribution.get("path"),
        manifest_rows=manifest_rows,
        manifest_directories=manifest_directories,
        label="G04 attribution result",
    )
    swiftlint = tests.get("swiftlint")
    _require(
        isinstance(swiftlint, dict)
        and swiftlint.get("status") == "pass"
        and type(swiftlint.get("violations")) is int
        and swiftlint.get("violations") == 0,
        "G04 SwiftLint evidence is absent or has violations",
    )
    _manifest_bound_reference(
        swiftlint.get("log"),
        manifest_rows=manifest_rows,
        manifest_directories=manifest_directories,
        label="G04 SwiftLint log",
    )


def _current_g03_anchors(repository_root: Path) -> Mapping[str, Any]:
    _, contract_payload = _repository_file(
        repository_root,
        G03_CURRENT_CONTRACT,
        "current G03 contract",
    )
    contract = _json_object(contract_payload, "current G03 contract")
    _, binary_payload = _repository_file(
        repository_root,
        G03_CURRENT_BINARY,
        "current G03 binary",
    )
    source_hashes: dict[str, str] = {}
    for relative in G03_CURRENT_SOURCE_FILES:
        _, payload = _repository_file(
            repository_root,
            relative,
            f"current G03 source {relative}",
        )
        source_hashes[relative] = _sha256(payload)
    binary = contract.get("binary")
    core = contract.get("core")
    exhaustive = contract.get("exhaustive")
    _require(
        contract.get("contract_schema_version") == 1
        and isinstance(binary, dict)
        and isinstance(core, dict)
        and isinstance(exhaustive, dict)
        and binary.get("magic") == "ASHCORE1"
        and binary.get("decoder_radius") == 1
        and binary.get("endianness") == "little"
        and binary.get("bit_order_code") == 1
        and binary.get("affine_section_order") == ["exact", "one_bit", "two_bit"]
        and core.get("coordinate_1_packed_bit") == 8
        and core.get("coordinate_9_packed_bit") == 0
        and core.get("message_bit_1_order") == "most_significant"
        and exhaustive.get("raw_state_count") == G03_EXHAUSTIVE_COUNTS["raw_states"]
        and exhaustive.get("valid_anchor_count") == G03_EXHAUSTIVE_COUNTS["valid_anchors"]
        and exhaustive.get("codeword_count") == G03_EXHAUSTIVE_COUNTS["codewords"]
        and exhaustive.get("exact_affine_count") == G03_EXHAUSTIVE_COUNTS["exact_affine"]
        and exhaustive.get("one_bit_affine_count") == G03_EXHAUSTIVE_COUNTS["one_bit_affine"]
        and exhaustive.get("two_bit_affine_count") == G03_EXHAUSTIVE_COUNTS["two_bit_affine"]
        and exhaustive.get("two_bit_fault_pair_count") == 36
        and binary.get("file_size") == len(binary_payload)
        and binary_payload[:8] == b"ASHCORE1",
        "current G03 contract or binary semantics differ",
    )
    return {
        "contract": contract,
        "contract_payload": contract_payload,
        "contract_sha256": _sha256(contract_payload),
        "binary_payload": binary_payload,
        "binary_sha256": _sha256(binary_payload),
        "binary_size": len(binary_payload),
        "source_hashes": source_hashes,
    }


def _validate_g03_vectors(
    vectors: Mapping[str, Any],
    anchors: Mapping[str, Any],
) -> None:
    _require(
        vectors.get("schema_version") == "1.0.0"
        and vectors.get("format") == "ASHCORE1"
        and vectors.get("decoder_radius") == 1
        and vectors.get("byte_order") == "little_endian"
        and vectors.get("coordinate_order")
        == "coordinate_1_is_packed_bit_8_coordinate_9_is_packed_bit_0"
        and vectors.get("comparison") == "byte_for_byte_and_sha256_equal"
        and vectors.get("payload") == "ash-core-v1.bin"
        and vectors.get("payload_sha256") == anchors["binary_sha256"]
        and vectors.get("payload_size_bytes") == anchors["binary_size"]
        and vectors.get("shared_contract") == "ash-core-v1.contract.json"
        and vectors.get("shared_contract_repository_path") == G03_CURRENT_CONTRACT
        and vectors.get("shared_contract_sha256") == anchors["contract_sha256"]
        and vectors.get("contract_mutation_rejection")
        == "generator_row_and_decoder_radius_rejected_by_both_implementations"
        and vectors.get("records") == G03_VECTOR_COUNTS,
        "G03 canonical vectors do not match current contract and binary semantics",
    )


def _validate_g03_assessment(
    assessment: Mapping[str, Any],
    anchors: Mapping[str, Any],
) -> None:
    expected = [
        {"count": 512, "criterion": G03_ASSESSMENT_CRITERIA[0], "status": "pass"},
        {"count": 256, "criterion": G03_ASSESSMENT_CRITERIA[1], "status": "pass"},
        {"count": 16, "criterion": G03_ASSESSMENT_CRITERIA[2], "status": "pass"},
        {"count": 36864, "criterion": G03_ASSESSMENT_CRITERIA[3], "status": "pass"},
        {"count": 147456, "criterion": G03_ASSESSMENT_CRITERIA[4], "status": "pass"},
        {
            "criterion": G03_ASSESSMENT_CRITERIA[5],
            "sha256": anchors["binary_sha256"],
            "status": "pass",
        },
        {
            "branch": "unchanged_from_p00",
            "criterion": G03_ASSESSMENT_CRITERIA[6],
            "status": "pass",
        },
    ]
    _require(
        assessment.get("schema_version") == "1.0.0"
        and assessment.get("gate_id") == "G03"
        and assessment.get("status") == "pass"
        and assessment.get("defects") == []
        and assessment.get("criteria") == expected,
        "G03 assessment does not contain the exact seven canonical criteria",
    )


def _validate_g03_detailed_evidence(
    evidence: Mapping[str, Any],
    anchors: Mapping[str, Any],
) -> None:
    contract = anchors["contract"]
    binary_contract = evidence.get("binary_contract")
    shared_contract = evidence.get("shared_contract")
    byte_agreement = evidence.get("byte_hash_agreement")
    _require(
        evidence.get("schema_version") == "1.0.0"
        and evidence.get("gate_id") == "G03"
        and evidence.get("phase_id") == "P03"
        and evidence.get("document_status") == "final"
        and evidence.get("overall_technical_assessment") == "pass"
        and isinstance(binary_contract, dict)
        and binary_contract.get("magic_ascii") == "ASHCORE1"
        and binary_contract.get("schema_version") == 1
        and binary_contract.get("endianness") == "little"
        and binary_contract.get("implicit_padding") is False
        and binary_contract.get("file_size_bytes") == anchors["binary_size"]
        and binary_contract.get("sha256") == anchors["binary_sha256"]
        and isinstance(shared_contract, dict)
        and shared_contract.get("path") == G03_CURRENT_CONTRACT
        and shared_contract.get("retained_evidence_path")
        == "conformance/ash-core-v1.contract.json"
        and shared_contract.get("sha256") == anchors["contract_sha256"]
        and isinstance(byte_agreement, dict)
        and byte_agreement.get("reference_check_result") == "pass"
        and byte_agreement.get("production_xctest_result") == "passed"
        and byte_agreement.get("reference_check_bytes") == anchors["binary_size"]
        and byte_agreement.get("reference_check_sha256") == anchors["binary_sha256"],
        "G03 detailed evidence status or current hash bindings differ",
    )
    header_fields = binary_contract.get("header_fields")
    _require(isinstance(header_fields, list), "G03 binary header fields are absent")
    header = {
        row.get("name"): row.get("value")
        for row in header_fields
        if isinstance(row, dict)
    }
    binary = contract["binary"]
    core = contract["core"]
    expected_header = {
        "magic": "ASHCORE1",
        "schema_version": 1,
        "header_size": binary["header_size"],
        "state_bits": core["state_bits"],
        "payload_bits": core["payload_bits"],
        "message_bits": core["message_bits"],
        "bit_order_code": binary["bit_order_code"],
        "endianness_code": binary["endianness_code"],
        "decoder_radius": binary["decoder_radius"],
        "raw_state_record_size": binary["record_sizes"]["raw_state"],
        "codeword_record_size": binary["record_sizes"]["codeword"],
        "affine_record_size": binary["record_sizes"]["affine"],
        "raw_state_count": G03_EXHAUSTIVE_COUNTS["raw_states"],
        "codeword_count": G03_EXHAUSTIVE_COUNTS["codewords"],
        "valid_anchor_count": G03_EXHAUSTIVE_COUNTS["valid_anchors"],
        "exact_affine_count": G03_EXHAUSTIVE_COUNTS["exact_affine"],
        "one_bit_affine_count": G03_EXHAUSTIVE_COUNTS["one_bit_affine"],
        "two_bit_affine_count": G03_EXHAUSTIVE_COUNTS["two_bit_affine"],
        "raw_state_offset": binary["section_offsets"]["raw_state"],
        "codeword_offset": binary["section_offsets"]["codeword"],
        "affine_offset": binary["section_offsets"]["affine"],
        "file_size": anchors["binary_size"],
    }
    _require(
        len(header_fields) == len(expected_header) and header == expected_header,
        "G03 binary header evidence differs",
    )
    expected_exhaustive = [
        ("raw_states", 512, "checked"),
        ("valid_anchors", 256, "checked"),
        ("codewords", 16, "checked"),
        ("exact_affine", 4096, "exact"),
        ("one_bit_affine", 36864, "corrected"),
        ("two_bit_affine", 147456, "rejected"),
    ]
    exhaustive = evidence.get("exhaustive_counts")
    _require(
        isinstance(exhaustive, list)
        and len(exhaustive) == len(expected_exhaustive)
        and [
            (row.get("domain"), row.get("count"), row.get("result"))
            for row in exhaustive
            if isinstance(row, dict)
        ]
        == expected_exhaustive,
        "G03 detailed exhaustive counts differ",
    )
    criteria = evidence.get("gate_criteria")
    _require(
        isinstance(criteria, list)
        and [row.get("criterion") for row in criteria if isinstance(row, dict)]
        == list(G03_ASSESSMENT_CRITERIA)
        and all(isinstance(row, dict) and row.get("result") == "pass" for row in criteria)
        and criteria[3].get("count") == 36864
        and criteria[4].get("count") == 147456
        and criteria[6].get("branch") == "unchanged",
        "G03 detailed gate criteria differ",
    )
    source_rows = evidence.get("source_file_hashes")
    _require(isinstance(source_rows, list), "G03 source-file hashes are absent")
    source_hashes = {
        row.get("path"): row.get("sha256")
        for row in source_rows
        if isinstance(row, dict)
    }
    expected_sources = {
        **anchors["source_hashes"],
        G03_CURRENT_CONTRACT: anchors["contract_sha256"],
        G03_CURRENT_BINARY: anchors["binary_sha256"],
    }
    _require(
        len(source_hashes) == len(source_rows)
        and set(source_hashes) == set(expected_sources)
        and source_hashes == expected_sources,
        "G03 detailed current source-file hashes differ",
    )
    canonical_core = evidence.get("canonical_core")
    _require(isinstance(canonical_core, dict), "G03 canonical-core detail is absent")
    preservation = canonical_core.get("baseline_preservation")
    observed_preservation = {
        row.get("path"): row
        for row in preservation
        if isinstance(row, dict)
    } if isinstance(preservation, list) else {}
    _require(
        canonical_core.get("decoder_radius") == 1
        and canonical_core.get("coordinate_1_packed_bit") == 8
        and canonical_core.get("coordinate_9_packed_bit") == 0
        and len(observed_preservation) == 2
        and all(
            observed_preservation.get(path, {}).get("current_sha256") == digest
            and observed_preservation[path].get("p00_sha256") == digest
            and observed_preservation[path].get("unchanged") is True
            for path, digest in anchors["source_hashes"].items()
            if path in G03_CORE_SOURCE_FILES
        ),
        "G03 canonical-core source preservation differs",
    )


def _validate_live_preopen_metadata(
    *,
    repository_root: Path,
    wrapper_root: Path,
    document: object,
) -> tuple[str, ...]:
    _require(
        isinstance(document, dict)
        and set(document)
        == {
            "status",
            "version_id",
            "metadata_only",
            "pixel_content_included",
            "open_intent_anchor_present",
            "bindings",
        }
        and document.get("status") == "pass"
        and document.get("version_id") == "p06-spatial-v2"
        and document.get("metadata_only") is True
        and document.get("pixel_content_included") is False
        and document.get("open_intent_anchor_present") is False,
        "G05 live preopen metadata identity or unopened semantics differ",
    )
    bindings = document.get("bindings")
    _require(
        isinstance(bindings, list)
        and len(bindings) == len(LIVE_PREOPEN_RELATIVE_PATHS),
        "G05 live preopen binding closure differs",
    )
    reopened: list[str] = []
    payloads: list[bytes] = []
    for index, (binding, expected_path) in enumerate(
        zip(bindings, LIVE_PREOPEN_RELATIVE_PATHS)
    ):
        _require(
            isinstance(binding, dict)
            and set(binding) == {"path", "sha256", "size_bytes"}
            and binding.get("path") == expected_path,
            f"G05 live preopen binding {index} path or fields differ",
        )
        _, payload = _repository_file(
            wrapper_root,
            expected_path,
            f"G05 live preopen metadata {index}",
        )
        _require(
            binding.get("sha256") == _sha256(payload)
            and binding.get("size_bytes") == len(payload),
            f"G05 live preopen metadata {index} bytes differ",
        )
        reopened.append(expected_path)
        payloads.append(payload)
    ledger, receipt, sealed_copy, attestation = (
        _json_object(payload, f"G05 live preopen document {index}")
        for index, payload in enumerate(payloads)
    )
    for value, schema, label in (
        (ledger, LIVE_LEDGER_SCHEMA, "G05 live access ledger"),
        (receipt, LIVE_RECEIPT_SCHEMA, "G05 live preopen receipt"),
        (sealed_copy, SEALED_COPY_SCHEMA, "G05 repository sealed-copy"),
        (
            attestation,
            NO_PIXEL_ATTESTATION_SCHEMA,
            "G05 repository no-pixel attestation",
        ),
    ):
        _validate_schema(value, _schema_validator(repository_root, schema), label)
    _, repository_sealed_payload = _repository_file(
        repository_root,
        REPOSITORY_SEALED_COPY,
        "current repository sealed-copy",
    )
    _, repository_attestation_payload = _repository_file(
        repository_root,
        REPOSITORY_NO_PIXEL_ATTESTATION,
        "current repository no-pixel attestation",
    )
    _require(
        payloads[2] == repository_sealed_payload
        and payloads[3] == repository_attestation_payload,
        "G05 copied repository preopen locks differ from current repository bytes",
    )
    corpus_sha256 = ledger.get("corpus_manifest_sha256")
    events = ledger.get("events")
    _require(
        ledger.get("state") == "sealed"
        and ledger.get("open_intent_utc") is None
        and ledger.get("opened_utc") is None
        and ledger.get("completed_utc") is None
        and isinstance(events, list)
        and len(events) == 1,
        "G05 live ledger does not prove a sealed preopen state",
    )
    event = events[0]
    event_material = dict(event) if isinstance(event, dict) else {}
    event_sha256 = event_material.pop("entry_sha256", None)
    _require(
        isinstance(event, dict)
        and event.get("sequence") == 0
        and event.get("event") == "sealed"
        and event.get("previous_entry_sha256") == "0" * 64
        and event.get("details") == {"corpus_manifest_sha256": corpus_sha256}
        and event_sha256 == canonical_sha256(event_material),
        "G05 live ledger seal event or canonical event hash differs",
    )
    _require(
        sealed_copy.get("status") == "unopened"
        and sealed_copy.get("evaluation_access_count") == 0
        and sealed_copy.get("entries") == []
        and all(
            sealed_copy.get(field) is None
            for field in (
                "evaluation_opened_utc",
                "first_evaluation_access_utc",
                "last_evaluation_access_utc",
                "evaluation_run_id",
            )
        ),
        "G05 repository sealed-copy contains access state",
    )
    _, corpus_payload = _repository_file(
        repository_root,
        REPOSITORY_CORPUS_LOCK,
        "current repository corpus lock",
    )
    corpus = _json_object(corpus_payload, "current repository corpus lock")
    corpus_material = dict(corpus)
    corpus_manifest_sha256 = corpus_material.pop("manifest_sha256", None)
    _require(
        corpus_manifest_sha256 == canonical_sha256(corpus_material),
        "current repository corpus-lock canonical self-hash differs",
    )
    production_lock = attestation.get("production_corpus_lock")
    evaluation_access = attestation.get("evaluation_access")
    outer_hashes = attestation.get("outer_record_hashes")
    container = attestation.get("container")
    inner_inventory = attestation.get("inner_inventory")
    _require(
        attestation.get("pixel_content_included") is False
        and attestation.get("result")
        == "holdout_sealed_and_production_corpus_lock_validated"
        and isinstance(container, dict)
        and container.get("mounted") is False
        and isinstance(inner_inventory, dict)
        and inner_inventory.get("preview_files_present") is False
        and inner_inventory.get("scratch_files_present") is False
        and inner_inventory.get("partial_files_present") is False
        and inner_inventory.get("verification_failures_before_seal") == 0
        and isinstance(production_lock, dict)
        and production_lock.get("file_sha256") == _sha256(corpus_payload)
        and production_lock.get("manifest_sha256") == corpus_manifest_sha256
        and corpus_sha256 == corpus_manifest_sha256
        and sealed_copy.get("revision_id") == attestation.get("revision_id")
        and sealed_copy.get("prepared_for_seal_utc")
        == production_lock.get("created_utc")
        and isinstance(outer_hashes, dict)
        and outer_hashes.get("evaluation_access_ledger_sealed_copy")
        == _sha256(payloads[2])
        and evaluation_access
        == {
            field: sealed_copy.get(field)
            for field in (
                "status",
                "evaluation_opened_utc",
                "first_evaluation_access_utc",
                "last_evaluation_access_utc",
                "evaluation_access_count",
                "evaluation_run_id",
            )
        },
        "G05 repository no-pixel attestation cross-bindings differ",
    )
    receipt_material = dict(receipt)
    receipt_sha256 = receipt_material.pop("receipt_sha256", None)
    _require(
        receipt_sha256 == canonical_sha256(receipt_material)
        and receipt.get("version_id") == "p06-spatial-v2"
        and receipt.get("state") == "sealed"
        and receipt.get("access_count") == 0
        and receipt.get("open_intent_anchor_present") is False
        and receipt.get("pixel_content_included") is False
        and receipt.get("corpus_manifest_sha256") == corpus_sha256
        and receipt.get("live_ledger_sha256") == _sha256(payloads[0])
        and receipt.get("repository_sealed_copy_sha256") == _sha256(payloads[2])
        and receipt.get("repository_attestation_sha256") == _sha256(payloads[3]),
        "G05 live preopen receipt self-hash or file bindings differ",
    )
    return tuple(reopened)


def validate_g05_upstream_bindings(
    *,
    repository_root: Path,
    wrapper_root: Path,
    document: Mapping[str, Any],
    source_commit: str,
) -> tuple[str, ...]:
    """Validate copied G03/G04 evidence and mandatory live preopen metadata."""

    _require(document.get("schema_version") == "1.0.0", "G05 upstream binding schema differs")
    _require(
        set(document) == {"schema_version", "gates", "live_preopen_metadata"},
        "G05 upstream binding fields differ",
    )
    gates = document.get("gates")
    _require(isinstance(gates, dict) and set(gates) == {"G03", "G04"}, "G05 upstream gate closure differs")
    reopened: list[str] = []
    for gate_id, source_paths in (
        ("G03", G03_CANONICAL_FILES),
        ("G04", G04_CURRENT_SOURCE_FILES),
    ):
        gate = gates.get(gate_id)
        expected_gate_fields = {
            "status",
            "source_commit",
            "manifest_file_sha256",
            "copied_files",
        }
        if gate_id == "G04":
            expected_gate_fields.add("closure_attestation")
        _require(
            isinstance(gate, dict)
            and set(gate) == expected_gate_fields
            and gate.get("status") == "pass",
            f"{gate_id} upstream gate record is invalid",
        )
        gate_commit = _source_commit(gate.get("source_commit"))
        if gate_id == "G04":
            _require(gate_commit == source_commit, "G04 upstream source commit differs")
        copied = gate.get("copied_files")
        expected_destinations = (
            f"inputs/{gate_id.lower()}/artifact-manifest.json",
            *(f"inputs/{gate_id.lower()}/{Path(path).name}" for path in source_paths),
        )
        _require(
            isinstance(copied, list)
            and len(copied) == len(expected_destinations),
            f"{gate_id} copied-file closure differs",
        )
        payloads: dict[str, bytes] = {}
        for index, (binding, expected_path) in enumerate(zip(copied, expected_destinations)):
            _require(
                isinstance(binding, dict)
                and set(binding) == {"path", "sha256", "size_bytes"}
                and binding.get("path") == expected_path,
                f"{gate_id} copied-file binding {index} differs",
            )
            relative = _safe_relative(expected_path, f"{gate_id} copied file {index}").as_posix()
            _, payload = _repository_file(wrapper_root, relative, f"{gate_id} copied file {index}")
            _require(
                binding.get("sha256") == _sha256(payload)
                and binding.get("size_bytes") == len(payload),
                f"{gate_id} copied file {index} bytes differ",
            )
            reopened.append(relative)
            payloads[relative] = payload
        manifest_relative = expected_destinations[0]
        manifest_payload = payloads[manifest_relative]
        _require(
            gate.get("manifest_file_sha256") == _sha256(manifest_payload),
            f"{gate_id} upstream manifest hash differs",
        )
        manifest = _json_object(manifest_payload, f"{gate_id} upstream manifest")
        _require(
            type(manifest.get("working_tree_clean")) is bool
            and manifest.get("project_commit") == gate_commit
            and (gate_id == "G03" or manifest.get("working_tree_clean") is True),
            f"{gate_id} upstream manifest identity differs",
        )
        if gate_id == "G04":
            _validate_schema(
                manifest,
                _schema_validator(
                    repository_root,
                    EVIDENCE_WRAPPER_MANIFEST_SCHEMA,
                ),
                "G04 upstream manifest",
            )
            _require(
                manifest_payload == document_bytes(manifest),
                "G04 upstream manifest is not canonical JSON",
            )
            validate_g04_closure_attestation(
                manifest=manifest,
                manifest_sha256=str(gate.get("manifest_file_sha256")),
                attestation=gate.get("closure_attestation"),
            )
        rows = _manifest_rows(manifest, f"{gate_id} upstream manifest")
        for source_path, destination in zip(source_paths, expected_destinations[1:]):
            row = rows.get(source_path)
            payload = payloads[destination]
            _require(
                isinstance(row, dict)
                and row.get("sha256") == _sha256(payload)
                and row.get("size_bytes") == len(payload),
                f"{gate_id} copied evidence is not exact in its upstream manifest: {source_path}",
            )
        assessment = _json_object(
            payloads[expected_destinations[1]],
            f"{gate_id} upstream assessment",
        )
        if gate_id == "G03":
            anchors = _current_g03_anchors(repository_root)
            vectors = _json_object(
                payloads[expected_destinations[2]],
                "G03 canonical vectors",
            )
            detailed = _json_object(
                payloads[expected_destinations[3]],
                "G03 detailed evidence",
            )
            _require(
                payloads[expected_destinations[4]] == anchors["contract_payload"],
                "G03 copied contract differs from current repository bytes",
            )
            _validate_g03_vectors(vectors, anchors)
            _validate_g03_assessment(assessment, anchors)
            _validate_g03_detailed_evidence(detailed, anchors)
        else:
            _validate_g04_assessment(
                assessment,
                source_commit=source_commit,
                manifest_rows=rows,
                manifest_directories=manifest.get("directories"),
            )
            tests = _json_object(
                payloads[expected_destinations[2]],
                "G04 upstream test results",
            )
            _validate_g04_test_evidence(tests, rows, manifest.get("directories"))
    reopened.extend(
        _validate_live_preopen_metadata(
            repository_root=repository_root,
            wrapper_root=wrapper_root,
            document=document.get("live_preopen_metadata"),
        )
    )
    return tuple(reopened)


def _validate_assessment_closure(
    assessment: Mapping[str, Any],
    closure: Mapping[str, Any],
) -> None:
    expected_evidence_closure = {
        "status": "pass",
        "run_count": 3,
        "files_per_run": 8,
        "document_names": list(EVIDENCE_FILENAMES),
        "document_bindings": closure["document_bindings"],
        "run_sha256": [closure["run_sha256"]] * 3,
        "byte_identical": True,
    }
    _require(
        assessment.get("evidence_closure") == expected_evidence_closure,
        "G05 assessment evidence closure differs from reopened P05 evidence",
    )
    _require(
        assessment.get("provenance")
        == {
            "status": "pass",
            "current_repository_bytes_verified": True,
            "manifest_sha256": closure["provenance_manifest_sha256"],
        },
        "G05 assessment provenance differs from current repository bytes",
    )
    counts = closure["criterion_counts"]
    expected_criteria = [
        {
            "id": identifier,
            "criterion": criterion,
            "status": "pass",
            "evidence": list(evidence),
            "verified_assertion_count": counts[identifier],
        }
        for identifier, criterion, evidence in G05_CRITERIA
    ]
    _require(
        assessment.get("mandatory_criteria") == expected_criteria,
        "G05 assessment criterion closure differs from reopened P05 evidence",
    )


def build_g05_receipt(
    *,
    repository_root: Path,
    wrapper_root: Path,
    source_commit: str,
    run_roots: Sequence[Path],
    assessment_path: Path,
    finding_register_path: Path,
    upstream_bindings_path: Path,
    command_execution_path: Path | None = None,
) -> Mapping[str, Any]:
    """Reopen the complete G05 closure and build its current-source receipt."""

    commit = _source_commit(source_commit)
    wrapper = _directory(wrapper_root, "G05 wrapper root")
    _require(len(run_roots) == 3, "G05 receipt requires exactly three P05 run roots")
    canonical_runs: list[Path] = []
    for index, (run_root, relative) in enumerate(
        zip(run_roots, CANONICAL_RUN_RELATIVE_PATHS),
        start=1,
    ):
        observed = _directory(Path(run_root), f"G05 receipt P05 run {index}")
        expected = wrapper.joinpath(*PurePosixPath(relative).parts)
        _require(observed == expected, f"G05 receipt P05 run {index} path is not canonical")
        canonical_runs.append(observed)
    closure = validate_g05_evidence(repository_root, canonical_runs)
    assessment_binding = build_file_binding(
        wrapper_root=wrapper,
        path=assessment_path,
        label="G05 assessment",
    )
    register_binding = build_file_binding(
        wrapper_root=wrapper,
        path=finding_register_path,
        label="G05 finding register",
    )
    upstream_binding = build_file_binding(
        wrapper_root=wrapper,
        path=upstream_bindings_path,
        label="G05 upstream bindings",
    )
    if command_execution_path is None:
        command_execution_path = wrapper / COMMAND_EXECUTION_RELATIVE
    command_execution_binding = build_file_binding(
        wrapper_root=wrapper,
        path=command_execution_path,
        label="G05 command execution aggregate",
    )
    _, assessment = _document_from_binding(
        wrapper,
        assessment_binding,
        "G05 assessment",
        expected_path=ASSESSMENT_RELATIVE,
    )
    _, register = _document_from_binding(
        wrapper,
        register_binding,
        "G05 finding register",
        expected_path=FINDING_REGISTER_RELATIVE,
    )
    _, upstream = _document_from_binding(
        wrapper,
        upstream_binding,
        "G05 upstream bindings",
        expected_path=UPSTREAM_BINDINGS_RELATIVE,
    )
    _, command_execution = _document_from_binding(
        wrapper,
        command_execution_binding,
        "G05 command execution aggregate",
        expected_path=COMMAND_EXECUTION_RELATIVE,
    )
    _validate_output_document(
        repository_root,
        assessment,
        ASSESSMENT_SCHEMA,
        "assessment_sha256",
        "G05 assessment",
    )
    _validate_output_document(
        repository_root,
        register,
        FINDING_REGISTER_SCHEMA,
        "register_sha256",
        "G05 finding register",
    )
    _validate_finding_register(register)
    _require(
        assessment.get("source_commit") == commit
        and register.get("source_commit") == commit
        and assessment.get("status") == "pass"
        and register.get("review_status") == "pass",
        "G05 source commit or document status differs",
    )
    _require(
        assessment.get("finding_register_sha256") == register.get("register_sha256"),
        "G05 assessment finding-register self-hash binding differs",
    )
    _validate_assessment_closure(assessment, closure)
    validate_g05_upstream_bindings(
        repository_root=repository_root,
        wrapper_root=wrapper,
        document=upstream,
        source_commit=commit,
    )
    _validate_command_execution_aggregate(
        repository_root=repository_root,
        wrapper_root=wrapper,
        document=command_execution,
        source_commit=commit,
        closure=closure,
        upstream_bindings_sha256=str(upstream_binding["sha256"]),
    )
    document: dict[str, Any] = {
        "schema_version": "1.0.0",
        "artifact_kind": "g05_current_source_receipt",
        "gate": "G05",
        "phase": "P05",
        "source_commit": commit,
        "status": "pass",
        "holdout_accessed": False,
        "evidence_runs": [
            {"path": relative, "run_sha256": closure["run_sha256"]}
            for relative in CANONICAL_RUN_RELATIVE_PATHS
        ],
        "assessment": assessment_binding,
        "finding_register": register_binding,
        "upstream_bindings": upstream_binding,
        "command_execution": command_execution_binding,
        "verification": {
            "evidence_closure": {"status": "pass"},
            "schema_validation": {"status": "pass"},
            "byte_determinism": {"status": "pass"},
            "source_provenance": {"status": "pass"},
            "semantic_criteria": {"status": "pass"},
            "holdout_boundary": {"status": "pass"},
            "finding_register": {"status": "pass"},
            "command_execution": {"status": "pass"},
        },
    }
    document["receipt_sha256"] = canonical_sha256(document)
    _validate_output_document(repository_root, document, RECEIPT_SCHEMA, "receipt_sha256", "G05 receipt")
    return document


def validate_g05_receipt(
    *,
    repository_root: Path,
    wrapper_root: Path,
    receipt: Mapping[str, Any],
) -> G05ReceiptValidation:
    """Validate a receipt and reopen its full current-source evidence closure."""

    _validate_output_document(repository_root, receipt, RECEIPT_SCHEMA, "receipt_sha256", "G05 receipt")
    commit = _source_commit(receipt.get("source_commit"))
    wrapper = _directory(wrapper_root, "G05 wrapper root")
    run_bindings = receipt.get("evidence_runs")
    _require(
        isinstance(run_bindings, list)
        and len(run_bindings) == len(CANONICAL_RUN_RELATIVE_PATHS),
        "G05 receipt evidence-run closure differs",
    )
    run_roots: list[Path] = []
    for index, (binding, expected_relative) in enumerate(
        zip(run_bindings, CANONICAL_RUN_RELATIVE_PATHS),
        start=1,
    ):
        _require(
            isinstance(binding, dict)
            and set(binding) == {"path", "run_sha256"}
            and binding.get("path") == expected_relative,
            f"G05 receipt evidence-run binding {index} differs",
        )
        run_roots.append(
            _directory(
                wrapper.joinpath(*PurePosixPath(expected_relative).parts),
                f"G05 receipt P05 run {index}",
            )
        )
    closure = validate_g05_evidence(repository_root, run_roots)
    _require(
        all(binding.get("run_sha256") == closure["run_sha256"] for binding in run_bindings),
        "G05 receipt evidence-run aggregate hash differs",
    )
    assessment_path, assessment = _document_from_binding(
        wrapper,
        receipt.get("assessment"),
        "G05 assessment",
        expected_path=ASSESSMENT_RELATIVE,
    )
    register_path, register = _document_from_binding(
        wrapper,
        receipt.get("finding_register"),
        "G05 finding register",
        expected_path=FINDING_REGISTER_RELATIVE,
    )
    upstream_path, upstream = _document_from_binding(
        wrapper,
        receipt.get("upstream_bindings"),
        "G05 upstream bindings",
        expected_path=UPSTREAM_BINDINGS_RELATIVE,
    )
    command_execution_path, command_execution = _document_from_binding(
        wrapper,
        receipt.get("command_execution"),
        "G05 command execution aggregate",
        expected_path=COMMAND_EXECUTION_RELATIVE,
    )
    _validate_output_document(
        repository_root,
        assessment,
        ASSESSMENT_SCHEMA,
        "assessment_sha256",
        "G05 assessment",
    )
    _validate_output_document(
        repository_root,
        register,
        FINDING_REGISTER_SCHEMA,
        "register_sha256",
        "G05 finding register",
    )
    _validate_finding_register(register)
    _require(
        assessment.get("source_commit") == receipt.get("source_commit")
        and register.get("source_commit") == receipt.get("source_commit")
        and assessment.get("status") == "pass"
        and register.get("review_status") == "pass",
        "G05 receipt-bound document identity or status differs",
    )
    _require(
        assessment.get("finding_register_sha256") == register.get("register_sha256"),
        "G05 receipt-bound finding-register self-hash differs",
    )
    _validate_assessment_closure(assessment, closure)
    upstream_paths = validate_g05_upstream_bindings(
        repository_root=repository_root,
        wrapper_root=wrapper,
        document=upstream,
        source_commit=commit,
    )
    command_execution_paths = _validate_command_execution_aggregate(
        repository_root=repository_root,
        wrapper_root=wrapper,
        document=command_execution,
        source_commit=commit,
        closure=closure,
        upstream_bindings_sha256=str(receipt["upstream_bindings"]["sha256"]),
    )
    evidence_paths = tuple(
        f"{run_relative}/{filename}"
        for run_relative in CANONICAL_RUN_RELATIVE_PATHS
        for filename in EVIDENCE_FILENAMES
    )
    _require(
        set(evidence_paths).issubset(command_execution_paths),
        "G05 command results do not reopen the complete P05 product closure",
    )
    reopened_with_command_products = (
        assessment_path,
        register_path,
        upstream_path,
        command_execution_path,
        *evidence_paths,
        *upstream_paths,
        *command_execution_paths,
    )
    reopened = tuple(dict.fromkeys(reopened_with_command_products))
    _require(
        len(reopened_with_command_products) - len(reopened) == len(evidence_paths),
        "G05 receipt reopened path overlap differs from the P05 product closure",
    )
    return G05ReceiptValidation(
        assessment=assessment,
        finding_register=register,
        upstream_bindings=upstream,
        command_execution_aggregate=command_execution,
        reopened_relative_paths=reopened,
    )


file_binding = build_file_binding
