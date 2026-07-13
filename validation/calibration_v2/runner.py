"""Fail-closed deterministic P06 calibration search and evidence aggregation.

This module deliberately does not implement ASH reconstruction.  A production
run must inject the hash-bound ``CandidateAdapter`` used by the existing
quality harness; that adapter is expected to delegate reconstruction to the
native Swift runtime.  Python owns only preregistered search order, evidence
validation, metric aggregation, and atomic run records.
"""

from __future__ import annotations

import base64
import ctypes
from dataclasses import dataclass, field
import errno
import hashlib
import json
import math
import os
from pathlib import Path, PurePosixPath
import stat
from typing import Callable, Dict, List, Mapping, MutableMapping, Optional, Protocol, Sequence, Tuple
import uuid

import numpy as np

from validation.quality.src.mirmir_quality.arrays import PlanarFrame, frame_sha256
from validation.quality.src.mirmir_quality.bootstrap import paired_bootstrap
from validation.quality.src.mirmir_quality.corpus import (
    QUALITY_CATEGORIES,
    validate_corpus_lock,
)
from validation.quality.src.mirmir_quality.fixtures import (
    locked_analytic_fixture_frames,
)
from validation.quality.src.mirmir_quality.harness_manifest import (
    validate_quality_harness_implementation_manifest,
)
from validation.quality.src.mirmir_quality.json_tools import (
    canonical_json_bytes,
    canonical_sha256,
    manifest_sha256,
    read_json,
    validate_schema,
    write_json,
)
from validation.quality.src.mirmir_quality.production_dry_run import (
    CandidateAdapter,
    CandidateContext,
    _round_trip_locked_bt709_video_range_nv12,
)
from validation.quality.src.mirmir_quality.samples import (
    load_development_samples,
    load_validation_samples,
)
from validation.calibration_v2.live_holdout_preopen import (
    verify_live_holdout_preopen,
)
from validation.calibration_v2.release_lock import (
    candidate_vector_sha256_for_plan,
    locked_compiler_input_document,
    operator_bank_document,
    shared_bank_configuration_sha256_for_plan,
    validate_dispatch_measurement_document,
    video_mapping_document,
)


CALIBRATION_ROOT = Path(__file__).resolve().parent
DEFAULT_PLAN_PATH = CALIBRATION_ROOT / "contracts" / "calibration-plan-v1.json"
DEFAULT_TOLERANCES_PATH = (
    CALIBRATION_ROOT / "contracts" / "metric-performance-tolerances-v1.json"
)
SCHEMAS_ROOT = CALIBRATION_ROOT / "schemas"
SHA256_PATTERN_LENGTH = 64
ROUTES = ("direct-2x", "direct-3over2")
ROUTE_PHASE_PAIR_COUNTS = {
    "direct-2x": 4,
    "direct-3over2": 9,
}
CONVENTIONAL_ALGORITHM_IDS = (
    "bilinear-separable-v1",
    "keys-cubic-a-minus-0.5-separable-v1",
    "lanczos3-separable-v1",
)
_EXTRA_REQUIRED_BINDINGS = {
    "calibration_plan": "validation/calibration_v2/contracts/calibration-plan-v1.json",
}
_THRESHOLD_BANDS = (
    "edge_present",
    "coherent_structure",
    "texture_high_frequency",
    "alias_or_ringing_risk",
    "chroma_luma_structure_aligned",
)
_GLOBAL_DEVELOPMENT_CHECK_FAILURES = frozenset(
    {
        "compiler_invariants",
        "operator_distinctness",
        "state_causality",
        "analysis_grid_route_quality",
        "analysis_grid_occupancy",
        "candidate_count",
    }
)
_RUN_TRANSACTION_MARKER = ".calibration-transaction.json"
_RUN_RECOVERY_DIRECTORY = "stale-transaction-recoveries"
_RUN_TRANSACTION_INTENT_SUFFIX = ".calibration-transaction-intent"
_RUN_TRANSACTION_INTENT_TARGET_PREFIX = "mirmir-p06-intent-v1:"
_RUN_PREMARKER_RECOVERY_JOURNAL = ".calibration-pre-marker-recovery"
_RUN_PREMARKER_RECOVERY_TARGET_PREFIX = "mirmir-p06-pre-marker-recovery-v1:"
_RUN_RECOVERY_PENDING_TARGET_PREFIX = "mirmir-p06-recovery-record-v1:"
_DEVELOPMENT_CONTROL_SELECTION_CACHE_DIRECTORY = (
    ".development-control-selection-cache-v1"
)
_DEVELOPMENT_CONTROL_SELECTION_CACHE_SCHEMA = (
    "development-control-selection-cache-v1.schema.json"
)
_PREMARKER_RECOVERY_ACTIONS = frozenset(
    {
        "not_required",
        "validated_durable_marker",
        "published_marker_from_durable_intent",
        "replaced_incomplete_marker_temporary",
        "completed_durable_marker_temporary",
        "removed_linked_marker_temporary",
    }
)
_RENAME_EXCL = 0x00000004
_RENAME_NOFOLLOW_ANY = 0x00000010
_RENAME_RESOLVE_BENEATH = 0x00000020
_RENAME_TRANSACTION_FLAGS = (
    _RENAME_EXCL | _RENAME_NOFOLLOW_ANY | _RENAME_RESOLVE_BENEATH
)
_LIBC = ctypes.CDLL(None, use_errno=True)
_RENAMEATX_NP = getattr(_LIBC, "renameatx_np", None)
if _RENAMEATX_NP is not None:
    _RENAMEATX_NP.argtypes = (
        ctypes.c_int,
        ctypes.c_char_p,
        ctypes.c_int,
        ctypes.c_char_p,
        ctypes.c_uint,
    )
    _RENAMEATX_NP.restype = ctypes.c_int


class CalibrationError(ValueError):
    """Base error for rejected calibration state or evidence."""


class CalibrationBindingError(CalibrationError):
    """A preregistered input is absent, unsafe, changed, or inconsistent."""


class CandidateEvaluationPreconditionError(CalibrationError):
    """A domain-valid candidate cannot satisfy a mandatory evaluation control."""

    def __init__(
        self,
        *,
        control_id: str,
        parameter: str,
        value: object,
        incompatible_descriptor_ids: Sequence[int],
    ) -> None:
        descriptor_ids = tuple(incompatible_descriptor_ids)
        self.control_id = control_id
        self.parameter = parameter
        self.value = value
        self.incompatible_descriptor_ids = descriptor_ids
        super().__init__(
            "mandatory control bank compatibility failed: "
            f"control_id={control_id}; {parameter}={value}; "
            f"incompatible_descriptor_ids={list(descriptor_ids)}"
        )


class CalibrationRunInterrupted(RuntimeError):
    """A run failed after its partial evidence was preserved."""

    def __init__(self, message: str, failure_path: Path) -> None:
        super().__init__(message)
        self.failure_path = failure_path


class MeasurementArtifactResolver:
    """Reopen content-addressed validation measurement JSON under one root."""

    def __init__(self, root: Path) -> None:
        try:
            metadata = os.stat(root, follow_symlinks=False)
        except OSError as error:
            raise CalibrationBindingError("dispatch-measurement root is absent") from error
        if root.is_symlink() or not stat.S_ISDIR(metadata.st_mode):
            raise CalibrationBindingError(
                "dispatch-measurement root is symbolic or not a directory"
            )
        self._root = root.resolve(strict=True)

    def __call__(self, binding: Mapping[str, object]) -> Mapping[str, object]:
        relative = _safe_relative_path(binding.get("artifact_id"))
        rebound = _hash_regular_file(self._root, relative.as_posix())
        expected = {
            "artifact_id": relative.as_posix(),
            "sha256": binding.get("sha256"),
            "size_bytes": binding.get("size_bytes"),
        }
        actual = {
            "artifact_id": rebound["path"],
            "sha256": rebound["sha256"],
            "size_bytes": rebound["size_bytes"],
        }
        if actual != expected:
            raise CalibrationBindingError("dispatch measurement binding changed")
        document = _load_bound_json(self._root, rebound)
        return document


@dataclass(frozen=True)
class LiveHoldoutPreopenBinding:
    """Explicit metadata-only arguments for the separately rooted live guard."""

    live_ledger_path: Path
    live_anchor_path: Path
    live_preopen_receipt_path: Path
    expected_live_ledger_root_identity_sha256: str
    expected_live_anchor_root_identity_sha256: str
    expected_live_preopen_receipt_sha256: str
    repository_sealed_copy_path: Path
    expected_repository_sealed_copy_sha256: str
    repository_attestation_path: Path
    expected_repository_attestation_sha256: str

    def verify(self) -> Mapping[str, object]:
        return verify_live_holdout_preopen(
            live_ledger_path=self.live_ledger_path,
            live_anchor_path=self.live_anchor_path,
            live_preopen_receipt_path=self.live_preopen_receipt_path,
            expected_live_ledger_root_identity_sha256=(
                self.expected_live_ledger_root_identity_sha256
            ),
            expected_live_anchor_root_identity_sha256=(
                self.expected_live_anchor_root_identity_sha256
            ),
            expected_live_preopen_receipt_sha256=(
                self.expected_live_preopen_receipt_sha256
            ),
            repository_sealed_copy_path=self.repository_sealed_copy_path,
            expected_repository_sealed_copy_sha256=(
                self.expected_repository_sealed_copy_sha256
            ),
            repository_attestation_path=self.repository_attestation_path,
            expected_repository_attestation_sha256=(
                self.expected_repository_attestation_sha256
            ),
        )


def _is_sha256(value: object) -> bool:
    return (
        isinstance(value, str)
        and len(value) == SHA256_PATTERN_LENGTH
        and all(character in "0123456789abcdef" for character in value)
    )


def _safe_relative_path(value: object) -> PurePosixPath:
    if not isinstance(value, str):
        raise CalibrationBindingError("bound input path must be a string")
    path = PurePosixPath(value)
    if (
        not value
        or value.startswith("/")
        or "\\" in value
        or path.as_posix() != value
        or any(part in {"", ".", ".."} for part in path.parts)
    ):
        raise CalibrationBindingError(f"unsafe bound input path: {value!r}")
    return path


def _hash_regular_file(repository_root: Path, relative_path: str) -> Dict[str, object]:
    relative = _safe_relative_path(relative_path)
    root = repository_root.resolve(strict=True)
    cursor = root
    for part in relative.parts[:-1]:
        cursor = cursor / part
        try:
            metadata = os.stat(cursor, follow_symlinks=False)
        except OSError as error:
            raise CalibrationBindingError(
                f"bound input parent is absent: {relative_path}"
            ) from error
        if cursor.is_symlink() or not stat.S_ISDIR(metadata.st_mode):
            raise CalibrationBindingError(
                f"bound input traverses a symbolic or non-directory parent: {relative_path}"
            )
    path = root.joinpath(*relative.parts)
    try:
        before = os.stat(path, follow_symlinks=False)
    except OSError as error:
        raise CalibrationBindingError(f"bound input is absent: {relative_path}") from error
    if path.is_symlink() or not stat.S_ISREG(before.st_mode):
        raise CalibrationBindingError(
            f"bound input is symbolic or not a regular file: {relative_path}"
        )
    flags = os.O_RDONLY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    digest = hashlib.sha256()
    try:
        descriptor = os.open(path, flags)
        try:
            opened = os.fstat(descriptor)
            if (
                not stat.S_ISREG(opened.st_mode)
                or (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino)
            ):
                raise CalibrationBindingError(
                    f"bound input changed while opening: {relative_path}"
                )
            while True:
                chunk = os.read(descriptor, 1024 * 1024)
                if not chunk:
                    break
                digest.update(chunk)
            after_read = os.fstat(descriptor)
        finally:
            os.close(descriptor)
    except OSError as error:
        raise CalibrationBindingError(f"bound input cannot be read: {relative_path}") from error
    after_path = os.stat(path, follow_symlinks=False)
    identity = (before.st_dev, before.st_ino)
    if (
        (after_read.st_dev, after_read.st_ino) != identity
        or (after_path.st_dev, after_path.st_ino) != identity
        or after_read.st_size != before.st_size
        or after_path.st_size != before.st_size
        or after_read.st_mtime_ns != before.st_mtime_ns
        or after_path.st_mtime_ns != before.st_mtime_ns
    ):
        raise CalibrationBindingError(f"bound input changed while hashing: {relative_path}")
    return {
        "path": relative_path,
        "sha256": digest.hexdigest(),
        "size_bytes": before.st_size,
    }


def _load_bound_json(repository_root: Path, binding: Mapping[str, object]) -> Mapping[str, object]:
    path = repository_root.joinpath(*_safe_relative_path(binding["path"]).parts)
    payload = path.read_bytes()
    if (
        len(payload) != binding["size_bytes"]
        or hashlib.sha256(payload).hexdigest() != binding["sha256"]
    ):
        raise CalibrationBindingError("bound JSON changed after initial binding")
    try:
        document = json.loads(payload)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise CalibrationBindingError(f"bound input is not valid JSON: {binding['path']}") from error
    if not isinstance(document, dict):
        raise CalibrationBindingError(f"bound input must be a JSON object: {binding['path']}")
    return document


@dataclass(frozen=True)
class BoundInputs:
    """Immutable before-first-candidate bindings and parsed split metadata."""

    repository_root: Path
    records: Tuple[Mapping[str, object], ...]
    documents: Mapping[str, Mapping[str, object]]
    live_holdout_preopen_binding: LiveHoldoutPreopenBinding
    live_holdout_preopen_verification: Mapping[str, object]
    bundle_sha256: str

    def record(self, identifier: str) -> Mapping[str, object]:
        matches = [record for record in self.records if record["id"] == identifier]
        if len(matches) != 1:
            raise CalibrationBindingError(f"bound input ID is absent or ambiguous: {identifier}")
        return matches[0]

    def verify_unchanged(self) -> None:
        current = []
        for record in self.records:
            rebound = _hash_regular_file(self.repository_root, str(record["path"]))
            current.append({"id": record["id"], **rebound})
        try:
            live_verification = self.live_holdout_preopen_binding.verify()
        except Exception as error:
            raise CalibrationBindingError(
                "live holdout metadata no longer proves unopened state"
            ) from error
        bundle = {
            "repository_file_bindings": current,
            "live_holdout_preopen_verification": live_verification,
        }
        if (
            tuple(current) != self.records
            or live_verification != self.live_holdout_preopen_verification
            or canonical_sha256(bundle) != self.bundle_sha256
        ):
            raise CalibrationBindingError("a preregistered input changed after first binding")


def _validate_sample_lock(document: Mapping[str, object], split: str) -> None:
    if split not in {"development", "validation"}:
        raise CalibrationBindingError("calibration sample split must be development or validation")
    if document.get("schema_version") != "1.1.0":
        raise CalibrationBindingError(f"unsupported {split} sample-lock version")
    if document.get("manifest_sha256") != manifest_sha256(document):
        raise CalibrationBindingError(f"{split} sample-lock self-hash mismatch")
    policy = document.get("sample_policy")
    samples = document.get("samples")
    expected_count = 6 if split == "development" else 3
    if (
        not isinstance(policy, dict)
        or policy.get("split") != split
        or not isinstance(samples, list)
        or len(samples) != expected_count
    ):
        raise CalibrationBindingError(f"{split} sample lock has the wrong split or count")
    identifiers = [
        sample.get("source_asset_id") if isinstance(sample, dict) else None
        for sample in samples
    ]
    if any(not isinstance(value, str) or not value for value in identifiers):
        raise CalibrationBindingError(f"{split} sample lock has an invalid source ID")
    if len(identifiers) != len(set(identifiers)):
        raise CalibrationBindingError(f"{split} sample lock repeats a source ID")


def _validate_corpus_lock_metadata(
    document: Mapping[str, object],
    *,
    binding: Mapping[str, object],
    attestation: Mapping[str, object],
) -> None:
    """Validate the complete locked corpus without resolving any media path."""

    try:
        validate_schema(
            document,
            CALIBRATION_ROOT.parent / "quality/schemas/corpus-lock.schema.json",
        )
        validate_corpus_lock(
            document,
            allowed_categories=set(QUALITY_CATEGORIES),
            require_all_splits=True,
            require_exact_allocation=True,
            require_category_minima=True,
        )
    except (OSError, ValueError) as error:
        raise CalibrationBindingError(
            "corpus lock metadata or self-hash is invalid"
        ) from error
    sealed = attestation.get("production_corpus_lock")
    if (
        not isinstance(sealed, dict)
        or sealed.get("manifest_sha256") != document.get("manifest_sha256")
        or sealed.get("file_sha256") != binding.get("sha256")
        or sealed.get("asset_count") != len(document.get("assets", []))
        or sealed.get("source_family_count")
        != len(
            {
                asset.get("source_family_id")
                for asset in document.get("assets", [])
                if isinstance(asset, dict)
            }
        )
        or sealed.get("split_counts")
        != {
            split: sum(
                1
                for asset in document.get("assets", [])
                if isinstance(asset, dict) and asset.get("split") == split
            )
            for split in ("development", "validation", "holdout")
        }
    ):
        raise CalibrationBindingError(
            "corpus lock differs from the no-pixel seal attestation"
        )


def _validate_holdout_sampling_plan(
    document: Mapping[str, object],
    corpus: Mapping[str, object],
) -> None:
    """Validate a no-pixel deterministic P07 sample rule against corpus metadata."""

    try:
        validate_schema(
            document,
            SCHEMAS_ROOT / "holdout-sampling-plan-v1.schema.json",
        )
    except ValueError as error:
        raise CalibrationBindingError(
            "holdout sampling plan violates its schema"
        ) from error
    if (
        document.get("manifest_sha256") != manifest_sha256(document)
        or document.get("corpus_manifest_sha256")
        != corpus.get("manifest_sha256")
        or document.get("target_pixel_hashes_known_before_p07") is not False
        or document.get("holdout_accessed") is not False
    ):
        raise CalibrationBindingError(
            "holdout sampling plan self-hash or unopened binding differs"
        )
    corpus_assets = corpus.get("assets")
    plan_assets = document.get("assets")
    if not isinstance(corpus_assets, list) or not isinstance(plan_assets, list):
        raise CalibrationBindingError("holdout sampling assets are absent")
    holdout_assets = [
        asset
        for asset in corpus_assets
        if isinstance(asset, dict) and asset.get("split") == "holdout"
    ]
    if len(holdout_assets) != 3 or len(plan_assets) != 3:
        raise CalibrationBindingError("holdout sampling plan is not exactly three assets")
    for ordinal, (asset, planned) in enumerate(zip(holdout_assets, plan_assets)):
        if not isinstance(planned, dict):
            raise CalibrationBindingError("holdout sampling asset is not an object")
        dimensions = asset.get("presentation_dimensions")
        routes = asset.get("target_routes")
        frame_range = asset.get("frame_range")
        if (
            not isinstance(dimensions, list)
            or len(dimensions) != 2
            or not all(isinstance(value, int) for value in dimensions)
            or not isinstance(routes, list)
            or len(routes) != 1
            or not isinstance(frame_range, dict)
        ):
            raise CalibrationBindingError(
                "holdout corpus metadata cannot support the sampling plan"
            )
        width, height = dimensions
        crop_x = 2 * ((width - 324) // 4)
        crop_y = 2 * ((height - 192) // 4)
        expected = {
            "ordinal": ordinal,
            "asset_id": asset.get("asset_id"),
            "source_asset_id": asset.get("source_asset_id"),
            "source_family_id": asset.get("source_family_id"),
            "source_sha256": asset.get("sha256"),
            "source_size_bytes": asset.get("size_bytes"),
            "presentation_dimensions": {"width": width, "height": height},
            "frame_count": asset.get("frame_count"),
            "frame_range": {
                "start": frame_range.get("start"),
                "duration": frame_range.get("duration"),
                "timescale": frame_range.get("timescale"),
            },
            "target_route": routes[0],
            "crop": {
                "x": crop_x,
                "y": crop_y,
                "width": 324,
                "height": 192,
            },
            "expected_metadata": {
                "pixel_format": asset.get("pixel_format"),
                "range": asset.get("range"),
                "color_primaries": asset.get("color_primaries"),
                "transfer_function": asset.get("transfer_function"),
                "ycbcr_matrix": asset.get("ycbcr_matrix"),
                "chroma_location": asset.get("chroma_location"),
            },
        }
        if planned != expected:
            raise CalibrationBindingError(
                f"holdout sampling metadata differs for ordinal {ordinal}"
            )


def _bind_candidate_evidence_sources(
    repository_root: Path,
    policy: Mapping[str, object],
) -> Tuple[Tuple[Mapping[str, object], ...], Mapping[str, Mapping[str, object]]]:
    """Bind and validate every preregistered P00/P05 evidence source."""

    try:
        validate_schema(
            policy,
            SCHEMAS_ROOT / "candidate-evidence-policy-v1.schema.json",
        )
    except ValueError as error:
        raise CalibrationBindingError(
            "candidate-evidence policy violates its preregistered schema"
        ) from error
    declared = policy.get("source_evidence")
    expected_names = (
        "p00_baseline_reproduction",
        "p05_cpu_reference",
        "p05_operator_discrimination",
        "p05_state_causality",
        "p05_state_fixtures",
    )
    if not isinstance(declared, dict) or tuple(declared) != expected_names:
        raise CalibrationBindingError(
            "candidate-evidence source order or identity differs from policy"
        )
    records: List[Mapping[str, object]] = []
    documents: Dict[str, Mapping[str, object]] = {}
    for name in expected_names:
        source = declared[name]
        if not isinstance(source, dict):
            raise CalibrationBindingError(
                f"candidate-evidence source binding is invalid: {name}"
            )
        path = source.get("path")
        _safe_relative_path(path)
        binding = _hash_regular_file(repository_root, str(path))
        if binding["sha256"] != source.get("file_sha256"):
            raise CalibrationBindingError(
                f"candidate-evidence source hash differs: {name}"
            )
        document = _load_bound_json(repository_root, binding)
        try:
            canonical_json_bytes(document)
        except (TypeError, ValueError) as error:
            raise CalibrationBindingError(
                f"candidate-evidence source is not finite canonical JSON: {name}"
            ) from error
        records.append({"id": f"candidate_evidence_source_{name}", **binding})
        documents[name] = document

    p00 = documents["p00_baseline_reproduction"]
    p00_values = declared["p00_baseline_reproduction"]
    supplied = p00.get("supplied_baseline")
    if (
        p00.get("status") != "pass_with_evidence_based_variance"
        or not isinstance(supplied, dict)
        or supplied.get("one_frame_seconds") != p00_values["one_frame_seconds"]
        or supplied.get("throughput_fps")
        != p00_values["throughput_frames_per_second"]
    ):
        raise CalibrationBindingError(
            "P00 baseline values differ from candidate-evidence policy"
        )

    for name in expected_names[1:]:
        document = documents[name]
        criteria = document.get("criteria")
        if (
            document.get("status") != "pass"
            or document.get("phase") != "P05"
            or document.get("gate") != "G05"
            or document.get("holdout_accessed") is not False
            or document.get("input_scope") != "synthetic_only"
            or not isinstance(criteria, list)
            or not criteria
            or any(
                not isinstance(record, dict) or record.get("status") != "pass"
                for record in criteria
            )
        ):
            raise CalibrationBindingError(
                f"P05 source does not contain exact passing evidence: {name}"
            )

    cpu = documents["p05_cpu_reference"].get("data")
    discrimination = documents["p05_operator_discrimination"].get("data")
    causality = documents["p05_state_causality"].get("data")
    fixtures = documents["p05_state_fixtures"].get("data")
    if (
        not isinstance(cpu, dict)
        or cpu.get("route_count") != 2
        or cpu.get("descriptor_count") != 16
        or cpu.get("maximum_operator_evaluations") != 2
        or cpu.get("runtime_tree_generation_count") != 0
        or not isinstance(discrimination, dict)
        or discrimination.get("descriptor_count")
        != declared["p05_operator_discrimination"]["descriptor_count"]
        or discrimination.get("expected_pair_count")
        != declared["p05_operator_discrimination"]["unordered_pair_count"]
        or discrimination.get("passing_pair_count")
        != declared["p05_operator_discrimination"]["unordered_pair_count"]
        or not isinstance(discrimination.get("pair_witnesses"), list)
        or len(discrimination["pair_witnesses"])
        != declared["p05_operator_discrimination"]["unordered_pair_count"]
        or any(
            not isinstance(witness, dict) or witness.get("pass") is not True
            for witness in discrimination["pair_witnesses"]
        )
        or not isinstance(causality, dict)
        or causality.get("maximum_operator_evaluations") != 2
        or causality.get("exhaustive_primary_descriptor_count") != 16
        or causality.get("exhaustive_route_phase_dispatch_count") != 3328
        or not isinstance(fixtures, dict)
        or fixtures.get("controlled_state_bit_count") != 9
        or not isinstance(fixtures.get("controlled_fixtures"), list)
        or len(fixtures["controlled_fixtures"]) != 9
        or any(
            not isinstance(fixture, dict) or fixture.get("pass") is not True
            for fixture in fixtures["controlled_fixtures"]
        )
    ):
        raise CalibrationBindingError(
            "P05 candidate-evidence values differ from the preregistered policy"
        )
    return tuple(records), documents


def bind_preregistered_inputs(
    repository_root: Path,
    *,
    live_holdout_preopen_binding: LiveHoldoutPreopenBinding,
    validate_implementation_manifest: bool = True,
    implementation_manifest_validator: Optional[
        Callable[[Mapping[str, object], Path], str]
    ] = None,
) -> BoundInputs:
    """Bind all plan inputs, both open calibration splits, and harness sources.

    The corpus lock is hashed as metadata only.  This function never resolves or
    opens a corpus media path, including holdout paths.
    """

    root = repository_root.resolve(strict=True)
    plan_binding = _hash_regular_file(root, _EXTRA_REQUIRED_BINDINGS["calibration_plan"])
    plan = _load_bound_json(root, plan_binding)
    validate_schema(plan, SCHEMAS_ROOT / "calibration-plan-v1.schema.json")
    if (
        plan.get("status") != "preregistered_not_executed"
        or plan.get("data_separation", {}).get("holdout_may_be_opened_in_p06") is not False
    ):
        raise CalibrationBindingError("calibration plan is not sealed for P06 execution")

    requested: List[Tuple[str, str]] = [
        ("calibration_plan", _EXTRA_REQUIRED_BINDINGS["calibration_plan"])
    ]
    declared = plan.get("input_bindings")
    if not isinstance(declared, list) or not declared:
        raise CalibrationBindingError("calibration plan has no input bindings")
    for entry in declared:
        if not isinstance(entry, dict):
            raise CalibrationBindingError("calibration input binding is not an object")
        identifier = entry.get("id")
        path = entry.get("path")
        if not isinstance(identifier, str) or not identifier:
            raise CalibrationBindingError("calibration input binding has no ID")
        _safe_relative_path(path)
        requested.append((identifier, str(path)))
    identifiers = [identifier for identifier, _ in requested]
    paths = [path for _, path in requested]
    if len(identifiers) != len(set(identifiers)) or len(paths) != len(set(paths)):
        raise CalibrationBindingError("preregistered input IDs and paths must be unique")

    records: List[Mapping[str, object]] = []
    documents: Dict[str, Mapping[str, object]] = {}
    for identifier, relative_path in requested:
        binding = _hash_regular_file(root, relative_path)
        record = {"id": identifier, **binding}
        records.append(record)
        documents[identifier] = _load_bound_json(root, binding)

    source_records, source_documents = _bind_candidate_evidence_sources(
        root,
        documents["candidate_evidence_policy"],
    )
    if set(record["path"] for record in records).intersection(
        record["path"] for record in source_records
    ):
        raise CalibrationBindingError(
            "candidate-evidence source duplicates a direct plan input"
        )
    records.extend(source_records)
    documents["candidate_evidence_source_documents"] = source_documents

    _validate_corpus_lock_metadata(
        documents["corpus_lock"],
        binding=next(record for record in records if record["id"] == "corpus_lock"),
        attestation=documents["holdout_preopen_anchor"],
    )
    _validate_sample_lock(documents["development_sample_lock"], "development")
    _validate_sample_lock(documents["validation_sample_lock"], "validation")
    if (
        documents["development_sample_lock"].get("corpus_manifest_sha256")
        != documents["corpus_lock"].get("manifest_sha256")
        or documents["validation_sample_lock"].get("corpus_manifest_sha256")
        != documents["corpus_lock"].get("manifest_sha256")
    ):
        raise CalibrationBindingError("sample locks disagree with the corpus lock")
    _validate_holdout_sampling_plan(
        documents["holdout_sampling_plan"],
        documents["corpus_lock"],
    )

    analytic_fixtures = documents["analytic_fixture_manifest"]
    validate_schema(
        analytic_fixtures,
        root / "validation/quality/schemas/analytic-fixtures-v2.schema.json",
    )
    metric_policy = documents["metric_policy_seed"]
    analytic_binding = metric_policy.get("analytic_fixture_manifest")
    if (
        analytic_fixtures.get("manifest_sha256")
        != manifest_sha256(analytic_fixtures)
        or metric_policy.get("policy_sha256")
        != manifest_sha256(metric_policy, "policy_sha256")
        or not isinstance(analytic_binding, dict)
        or analytic_binding
        != {
            "path": "reference/analytic-fixtures-v2.json",
            "manifest_sha256": analytic_fixtures["manifest_sha256"],
            "file_sha256": next(
                record["sha256"]
                for record in records
                if record["id"] == "analytic_fixture_manifest"
            ),
        }
    ):
        raise CalibrationBindingError(
            "metric policy and complete analytic fixture manifest disagree"
        )

    baseline_contract = documents["baseline_ablation_contract"]
    validate_schema(
        baseline_contract,
        SCHEMAS_ROOT / "baseline-ablation-contract-v1.schema.json",
    )
    quality_seed_record = next(
        record for record in records if record["id"] == "quality_gate_policy_seed"
    )
    provenance = documents["quality_gate_policy_provenance"]
    if (
        quality_seed_record["sha256"]
        != baseline_contract.get("quality_policy_seed", {}).get("sha256")
        or provenance.get("repository_copy_sha256") != quality_seed_record["sha256"]
        or provenance.get("source_package_file_sha256") != quality_seed_record["sha256"]
    ):
        raise CalibrationBindingError("quality-policy seed provenance or contract hash mismatch")
    access_ledger = documents["holdout_access_ledger_sealed_copy"]
    preopen_anchor = documents["holdout_preopen_anchor"]
    if (
        access_ledger.get("status") != "unopened"
        or access_ledger.get("evaluation_access_count") != 0
        or access_ledger.get("entries") != []
        or preopen_anchor.get("pixel_content_included") is not False
        or preopen_anchor.get("evaluation_access", {}).get("status") != "unopened"
        or preopen_anchor.get("evaluation_access", {}).get("evaluation_access_count") != 0
    ):
        raise CalibrationBindingError("holdout metadata no longer proves unopened state")

    manifest = documents["quality_harness_implementation_manifest"]
    validator = (
        implementation_manifest_validator
        if implementation_manifest_validator is not None
        else validate_quality_harness_implementation_manifest
    )
    if validate_implementation_manifest:
        try:
            validator(manifest, root)
        except Exception as error:
            raise CalibrationBindingError(
                "quality-harness implementation manifest is not current"
            ) from error
    elif implementation_manifest_validator is None:
        raise CalibrationBindingError(
            "skipping implementation-manifest validation requires an injected test validator"
        )

    try:
        live_verification = live_holdout_preopen_binding.verify()
    except Exception as error:
        raise CalibrationBindingError(
            "live holdout metadata does not prove an unopened preopen state"
        ) from error
    validate_schema(
        live_verification,
        SCHEMAS_ROOT / "live-holdout-preopen-verification-v1.schema.json",
    )
    if (
        live_verification.get("verification_status") != "pass"
        or live_verification.get("access_status") != "unopened"
        or live_verification.get("access_count") != 0
        or live_verification.get("open_intent_anchor_present") is not False
        or live_verification.get("pixel_content_included") is not False
        or live_verification.get("repository_sealed_copy_sha256")
        != next(
            record["sha256"]
            for record in records
            if record["id"] == "holdout_access_ledger_sealed_copy"
        )
        or live_verification.get("repository_attestation_sha256")
        != next(
            record["sha256"]
            for record in records
            if record["id"] == "holdout_preopen_anchor"
        )
        or live_verification.get("corpus_binding_sha256")
        != documents["corpus_lock"].get("manifest_sha256")
    ):
        raise CalibrationBindingError(
            "live holdout verification is not cross-bound to repository evidence"
        )

    immutable_records = tuple(records)
    sanitized_live_verification = dict(live_verification)
    documents["live_holdout_preopen_verification"] = sanitized_live_verification
    bundle_sha256 = canonical_sha256(
        {
            "repository_file_bindings": records,
            "live_holdout_preopen_verification": sanitized_live_verification,
        }
    )
    bound = BoundInputs(
        repository_root=root,
        records=immutable_records,
        documents=documents,
        live_holdout_preopen_binding=live_holdout_preopen_binding,
        live_holdout_preopen_verification=sanitized_live_verification,
        bundle_sha256=bundle_sha256,
    )
    bound.verify_unchanged()
    return bound


def corpus_lock_bundle_document(bound: BoundInputs) -> Mapping[str, object]:
    """Build the exact metadata-only compiler corpus bundle without media paths."""

    corpus = bound.documents["corpus_lock"]
    holdout_sampling = bound.documents["holdout_sampling_plan"]
    development = bound.documents["development_sample_lock"]
    validation = bound.documents["validation_sample_lock"]
    ledger = bound.documents["holdout_access_ledger_sealed_copy"]
    anchor = bound.documents["holdout_preopen_anchor"]
    live = bound.live_holdout_preopen_verification
    document = {
        "corpus_lock_file_sha256": bound.record("corpus_lock")["sha256"],
        "corpus_manifest_sha256": corpus["manifest_sha256"],
        "holdout_sampling_plan_file_sha256": bound.record("holdout_sampling_plan")["sha256"],
        "holdout_sampling_plan_manifest_sha256": holdout_sampling["manifest_sha256"],
        "holdout_sampling_target_pixel_hashes_known_before_p07": holdout_sampling[
            "target_pixel_hashes_known_before_p07"
        ],
        "development_sample_lock_file_sha256": bound.record("development_sample_lock")["sha256"],
        "development_sample_lock_manifest_sha256": development["manifest_sha256"],
        "validation_sample_lock_file_sha256": bound.record("validation_sample_lock")["sha256"],
        "validation_sample_lock_manifest_sha256": validation["manifest_sha256"],
        "holdout_access_ledger_file_sha256": bound.record("holdout_access_ledger_sealed_copy")["sha256"],
        "holdout_access_ledger_status": ledger["status"],
        "holdout_access_count": ledger["evaluation_access_count"],
        "holdout_preopen_anchor_file_sha256": bound.record("holdout_preopen_anchor")["sha256"],
        "holdout_preopen_anchor_pixel_content_included": anchor["pixel_content_included"],
        "holdout_preopen_anchor_evaluation_status": anchor["evaluation_access"]["status"],
        "live_holdout_verification_receipt_sha256": live[
            "verification_receipt_sha256"
        ],
        "live_holdout_access_status": live["access_status"],
        "live_holdout_access_count": live["access_count"],
        "live_holdout_open_intent_anchor_present": live[
            "open_intent_anchor_present"
        ],
        "live_holdout_pixel_content_included": live["pixel_content_included"],
    }
    contract = bound.documents["calibration_plan"].get(
        "corpus_lock_bundle_contract"
    )
    ordered_fields = (
        contract.get("ordered_fields") if isinstance(contract, dict) else None
    )
    if ordered_fields != list(document):
        raise CalibrationBindingError(
            "corpus-lock bundle fields differ from the preregistered order"
        )
    return document


def corpus_lock_bundle_sha256(bound: BoundInputs) -> str:
    return canonical_sha256(corpus_lock_bundle_document(bound))


def load_split_metadata(bound: BoundInputs, split: str) -> Tuple[Mapping[str, object], ...]:
    """Return only the requested open split, rejecting holdout before any path use."""

    if split not in {"development", "validation"}:
        raise CalibrationBindingError("P06 may load only development or validation metadata")
    lock_id = f"{split}_sample_lock"
    sample_lock = bound.documents[lock_id]
    _validate_sample_lock(sample_lock, split)
    corpus_assets = bound.documents["corpus_lock"].get("assets")
    if not isinstance(corpus_assets, list):
        raise CalibrationBindingError("corpus lock has no assets")
    split_assets = {
        asset.get("source_asset_id"): asset
        for asset in corpus_assets
        if isinstance(asset, dict) and asset.get("split") == split
    }
    samples = sample_lock["samples"]
    sample_ids = {sample["source_asset_id"] for sample in samples}
    if sample_ids != set(split_assets):
        raise CalibrationBindingError(f"{split} sample lock does not exactly cover its corpus split")
    rows = []
    for sample in samples:
        asset = split_assets[sample["source_asset_id"]]
        if sample.get("asset_id") != asset.get("asset_id"):
            raise CalibrationBindingError(f"{split} sample asset binding mismatch")
        rows.append(
            {
                "source_asset_id": sample["source_asset_id"],
                "source_family_id": asset.get("source_family_id"),
                "asset_id": sample["asset_id"],
                "target_route": sample.get("target_route"),
                "categories": asset.get("categories"),
                "target_frame_sha256": sample.get("target_frame_sha256"),
            }
        )
    return tuple(rows)


def spatial_degradation_profiles(
    bound: BoundInputs,
    target_route: str,
) -> Tuple[Mapping[str, object], ...]:
    """Return the three locked spatial profiles in serialized policy order."""

    if target_route not in ROUTES:
        raise CalibrationBindingError("degradation profile route is invalid")
    profiles = bound.documents["degradation_policy"].get("profiles")
    if not isinstance(profiles, list):
        raise CalibrationBindingError("degradation policy has no profile list")
    selected = tuple(
        profile
        for profile in profiles
        if isinstance(profile, dict)
        and profile.get("target_route") == target_route
        and profile.get("kind")
        in {"lowpass_decimate", "camera_blur_decimate", "codec_quantized_proxy"}
    )
    if len(selected) != 3 or len({profile.get("id") for profile in selected}) != 3:
        raise CalibrationBindingError(
            "each spatial route must have exactly three distinct locked profiles"
        )
    return selected


def parameter_domains(plan: Mapping[str, object]) -> Mapping[str, Tuple[object, ...]]:
    """Derive the exact ordered domain for every preregistered coordinate."""

    ranges = plan.get("ranges")
    search = plan.get("search")
    if not isinstance(ranges, dict) or not isinstance(search, dict):
        raise CalibrationError("calibration plan lacks ranges or search policy")
    mapping = ranges.get("mapping")
    operator = ranges.get("operator")
    compiler = ranges.get("compiler")
    if not all(isinstance(value, dict) for value in (mapping, operator, compiler)):
        raise CalibrationError("calibration plan range groups are invalid")
    domains: Dict[str, Tuple[object, ...]] = {}
    for band in _THRESHOLD_BANDS:
        domains[f"{band}_low_unorm15"] = tuple(mapping["low_unorm15"])
        domains[f"{band}_high_unorm15"] = tuple(mapping["high_unorm15"])
    for name in (
        "analysis_epsilon_q0_30",
        "risk_laplacian_weight_unorm15",
        "chroma_edge_confidence_unorm15",
        "direct_2x_analysis_grid_source_step",
        "direct_3_over_2_analysis_grid_source_step",
    ):
        domains[name] = tuple(mapping[name])
    domains["direct_2x_coordinate_policy"] = tuple(operator["coordinate_policy_by_route"])
    domains["direct_3_over_2_coordinate_policy"] = tuple(operator["coordinate_policy_by_route"])
    domains["boundary_mode"] = tuple(operator["boundary_mode"])
    for name, values in operator.items():
        if name not in {"coordinate_policy_by_route", "boundary_mode"}:
            domains[name] = tuple(values)
    for name, values in compiler.items():
        domains[name] = tuple(values)

    order = search.get("parameter_order")
    if not isinstance(order, list) or set(order) != set(domains) or len(order) != len(domains):
        raise CalibrationError("parameter order does not exactly cover derived domains")
    for name in order:
        values = domains[name]
        if not values or len(values) != len(set(values)):
            raise CalibrationError(f"parameter domain is empty or duplicated: {name}")
        if all(isinstance(value, int) and not isinstance(value, bool) for value in values):
            if values != tuple(sorted(values)):
                raise CalibrationError(f"numeric parameter domain is not ascending: {name}")
    initial = search.get("initial_vector_values")
    if not isinstance(initial, dict) or set(initial) != set(domains):
        raise CalibrationError("initial vector does not exactly cover parameter domains")
    if any(initial[name] not in domains[name] for name in order):
        raise CalibrationError("initial vector contains a value outside a declared domain")
    return domains


def validate_candidate_vector(
    vector: Mapping[str, object],
    plan: Mapping[str, object],
) -> None:
    domains = parameter_domains(plan)
    order = plan["search"]["parameter_order"]
    if set(vector) != set(order) or len(vector) != len(order):
        raise CalibrationError("candidate vector does not exactly cover parameter order")
    for name in order:
        if vector[name] not in domains[name]:
            raise CalibrationError(f"candidate value is outside its declared domain: {name}")
    for band in _THRESHOLD_BANDS:
        low = vector[f"{band}_low_unorm15"]
        high = vector[f"{band}_high_unorm15"]
        if not isinstance(low, int) or not isinstance(high, int):
            raise CalibrationError(f"threshold pair is not integral: {band}")
        if low > high or high - low < 3277:
            raise CalibrationError(f"threshold pair constraint failed: {band}")


def _validate_mandatory_control_bank_compatibility(
    vector: Mapping[str, object],
    baseline_contract: Mapping[str, object],
) -> None:
    best_fixed = baseline_contract.get("best_fixed")
    if not isinstance(best_fixed, dict):
        raise CalibrationBindingError(
            "baseline ablation contract lacks its mandatory fixed-descriptor bank"
        )
    control_id = best_fixed.get("control_id")
    descriptor_ids = best_fixed.get("eligible_descriptor_ids")
    if (
        control_id != "fixed-descriptor-uniform-v1"
        or descriptor_ids != list(range(16))
    ):
        raise CalibrationBindingError(
            "baseline ablation contract has an invalid mandatory fixed-descriptor bank"
        )
    if vector.get("detail_gain_q12") != 0:
        return
    incompatible_descriptor_ids = tuple(
        descriptor_id for descriptor_id in descriptor_ids if descriptor_id & (1 << 2)
    )
    raise CandidateEvaluationPreconditionError(
        control_id=control_id,
        parameter="detail_gain_q12",
        value=0,
        incompatible_descriptor_ids=incompatible_descriptor_ids,
    )


def serialized_candidate_vector(
    vector: Mapping[str, object],
    plan: Mapping[str, object],
) -> bytes:
    validate_candidate_vector(vector, plan)
    return canonical_json_bytes([vector[name] for name in plan["search"]["parameter_order"]])


def candidate_vector_sha256(
    vector: Mapping[str, object],
    plan: Mapping[str, object],
) -> str:
    expected = hashlib.sha256(serialized_candidate_vector(vector, plan)).hexdigest()
    observed = candidate_vector_sha256_for_plan(vector, plan)
    if observed != expected:
        raise CalibrationError("release and calibration candidate hashes disagree")
    return observed


_SHARED_BANK_COORDINATES = (
    "analysis_epsilon_q0_30",
    "risk_laplacian_weight_unorm15",
    "chroma_edge_confidence_unorm15",
    "direct_2x_analysis_grid_source_step",
    "direct_3_over_2_analysis_grid_source_step",
    "direct_2x_coordinate_policy",
    "direct_3_over_2_coordinate_policy",
    "boundary_mode",
    "anisotropy_strength_q12",
    "minimum_anisotropic_magnitude_unorm15",
    "minimum_anisotropic_coherence_unorm15",
    "detail_gain_q12",
    "relaxed_limiter_alpha_q12",
    "risk_detail_suppression_unorm15",
    "low_pass_radius_q8_8",
)


def shared_bank_configuration_sha256(
    vector: Mapping[str, object],
    plan: Mapping[str, object],
) -> str:
    validate_candidate_vector(vector, plan)
    return shared_bank_configuration_sha256_for_plan(vector, plan)


def _state_only_configuration_sha256(candidate_vector_hash: str) -> str:
    if not _is_sha256(candidate_vector_hash):
        raise CalibrationError("state-only configuration lacks a candidate-vector hash")
    return canonical_sha256(
        {
            "control_id": "ash-state-only-base-descriptor-v1",
            "candidate_vector_sha256": candidate_vector_hash,
        }
    )


def candidate_artifact_documents(
    vector: Mapping[str, object],
    plan: Mapping[str, object],
    bound: BoundInputs,
) -> Mapping[str, Mapping[str, object]]:
    """Canonical prelock artifacts that make vector-to-runtime hashes testable."""

    vector_hash = candidate_vector_sha256(vector, plan)
    configuration_id = f"ash-p06-{vector_hash[:24]}"
    mapping = video_mapping_document(
        vector=vector,
        plan=plan,
        configuration_id=configuration_id,
        mapping_seed_sha256=str(bound.record("mapping_seed")["sha256"]),
        status="calibration_candidate",
    )
    operator = operator_bank_document(
        vector=vector,
        plan=plan,
        configuration_id=configuration_id,
        operator_bank_seed_sha256=str(
            bound.record("operator_bank_seed")["sha256"]
        ),
        status="calibration_candidate",
    )
    metric: Mapping[str, object] = {
        "artifact_kind": "p06_candidate_metric_policy",
        "metric_policy_seed_sha256": bound.record("metric_policy_seed")["sha256"],
        "metric_performance_tolerances_sha256": bound.record(
            "metric_performance_tolerances"
        )["sha256"],
        "quality_gate_policy_seed_sha256": bound.record("quality_gate_policy_seed")["sha256"],
    }
    return {"mapping": mapping, "operator_bank": operator, "metric_policy": metric}


def one_coordinate_neighbors(
    vector: Mapping[str, object],
    plan: Mapping[str, object],
) -> Tuple[Mapping[str, object], ...]:
    validate_candidate_vector(vector, plan)
    domains = parameter_domains(plan)
    order = plan["search"]["parameter_order"]
    neighbors: Dict[str, Mapping[str, object]] = {
        candidate_vector_sha256(vector, plan): dict(vector)
    }
    for name in order:
        for value in domains[name]:
            candidate = dict(vector)
            candidate[name] = value
            try:
                validate_candidate_vector(candidate, plan)
            except CalibrationError:
                continue
            neighbors[candidate_vector_sha256(candidate, plan)] = candidate
    return tuple(
        sorted(
            neighbors.values(),
            key=lambda candidate: serialized_candidate_vector(candidate, plan),
        )
    )


@dataclass(frozen=True)
class ValidationCandidateEvidenceBinding:
    """Sanitized self/file binding for the development-frozen candidate set."""

    manifest_sha256: str
    file_sha256: str
    size_bytes: int
    development_terminal_vector_sha256: str
    validation_candidate_vector_sha256_values: Tuple[str, ...]

    def as_document(self) -> Mapping[str, object]:
        return {
            "manifest_sha256": self.manifest_sha256,
            "file_sha256": self.file_sha256,
            "size_bytes": self.size_bytes,
            "development_terminal_vector_sha256": (
                self.development_terminal_vector_sha256
            ),
            "validation_candidate_vector_sha256_values": list(
                self.validation_candidate_vector_sha256_values
            ),
        }


@dataclass(frozen=True)
class ControlSelectionBundle:
    """Immutable split-staged uniform control selection for one shared bank."""

    selection_stage: str
    shared_bank_configuration_sha256: str
    artifacts: Mapping[str, Mapping[str, object]]
    bundle_sha256: str
    validation_candidate_evidence: Optional[
        ValidationCandidateEvidenceBinding
    ] = None

    @property
    def full_ash_development_candidates_frozen_sha256(self) -> Optional[str]:
        binding = self.validation_candidate_evidence
        return None if binding is None else binding.manifest_sha256


def _control_selection_bundle_payload(
    *,
    selection_stage: str,
    shared_bank_configuration_sha256: str,
    artifacts: Mapping[str, Mapping[str, object]],
    validation_candidate_evidence: Optional[ValidationCandidateEvidenceBinding],
) -> Mapping[str, object]:
    return {
        "selection_stage": selection_stage,
        "shared_bank_configuration_sha256": shared_bank_configuration_sha256,
        "artifacts": artifacts,
        "validation_candidate_evidence": (
            None
            if validation_candidate_evidence is None
            else validation_candidate_evidence.as_document()
        ),
    }


def _bind_validation_candidate_evidence(
    selection: ControlSelectionBundle,
    binding: ValidationCandidateEvidenceBinding,
) -> ControlSelectionBundle:
    if (
        selection.validation_candidate_evidence is not None
        and selection.validation_candidate_evidence != binding
    ):
        raise CalibrationError("control selection uses stale frozen-candidate evidence")
    payload = _control_selection_bundle_payload(
        selection_stage=selection.selection_stage,
        shared_bank_configuration_sha256=(
            selection.shared_bank_configuration_sha256
        ),
        artifacts=selection.artifacts,
        validation_candidate_evidence=binding,
    )
    return ControlSelectionBundle(
        selection_stage=selection.selection_stage,
        shared_bank_configuration_sha256=(
            selection.shared_bank_configuration_sha256
        ),
        artifacts=selection.artifacts,
        bundle_sha256=canonical_sha256(payload),
        validation_candidate_evidence=binding,
    )


def _control_selection_bundle(
    evaluation: Mapping[str, object],
    *,
    validation_candidate_evidence: Optional[
        ValidationCandidateEvidenceBinding
    ] = None,
) -> ControlSelectionBundle:
    embedded = evaluation["control_selection_artifacts"]
    copied = json.loads(json.dumps(embedded))
    stages = {
        value["document"]["selection_stage"] for value in copied.values()
    }
    banks = {
        value["document"]["shared_bank_configuration_sha256"]
        for value in copied.values()
    }
    if len(stages) != 1 or len(banks) != 1:
        raise CalibrationError("control selection bundle mixes stages or shared banks")
    stage = next(iter(stages))
    bank = next(iter(banks))
    if (stage == "development_provisional") != (
        validation_candidate_evidence is None
    ):
        raise CalibrationError(
            "control selection stage and frozen-candidate evidence differ"
        )
    expected_frozen_sha256 = (
        None
        if validation_candidate_evidence is None
        else validation_candidate_evidence.manifest_sha256
    )
    if evaluation.get(
        "full_ash_development_candidates_frozen_sha256"
    ) != expected_frozen_sha256:
        raise CalibrationError(
            "candidate evaluation omitted or changed frozen-candidate evidence"
        )
    payload = _control_selection_bundle_payload(
        selection_stage=stage,
        shared_bank_configuration_sha256=bank,
        artifacts=copied,
        validation_candidate_evidence=validation_candidate_evidence,
    )
    return ControlSelectionBundle(
        selection_stage=stage,
        shared_bank_configuration_sha256=bank,
        artifacts=copied,
        bundle_sha256=canonical_sha256(payload),
        validation_candidate_evidence=validation_candidate_evidence,
    )


def _verify_validation_candidate_evidence_file(
    path: Path,
    *,
    expected_file_binding: Mapping[str, object],
    expected_binding: Optional[ValidationCandidateEvidenceBinding] = None,
) -> ValidationCandidateEvidenceBinding:
    """Reopen and verify the development-only candidate freeze without pixels."""

    if path.name != expected_file_binding.get("path"):
        raise CalibrationBindingError(
            "validation-candidate evidence path differs from its file binding"
        )
    rebound = _hash_regular_file(path.parent, path.name)
    if rebound != dict(expected_file_binding):
        raise CalibrationBindingError("validation-candidate evidence file changed")
    document = _load_bound_json(path.parent, rebound)
    validate_schema(
        document,
        SCHEMAS_ROOT / "validation-candidate-development-evidence-v1.schema.json",
    )
    if (
        document.get("manifest_sha256") != manifest_sha256(document)
        or document.get("validation_accessed_while_building") is not False
    ):
        raise CalibrationBindingError(
            "validation-candidate evidence self-hash or separation flag is invalid"
        )
    candidate_hashes = document.get(
        "validation_candidate_vector_sha256_values"
    )
    if (
        not isinstance(candidate_hashes, list)
        or len(candidate_hashes) != len(set(candidate_hashes))
        or not candidate_hashes
    ):
        raise CalibrationBindingError(
            "validation-candidate evidence has invalid candidate identities"
        )
    verified = ValidationCandidateEvidenceBinding(
        manifest_sha256=str(document["manifest_sha256"]),
        file_sha256=str(rebound["sha256"]),
        size_bytes=int(rebound["size_bytes"]),
        development_terminal_vector_sha256=str(
            document["development_terminal_vector_sha256"]
        ),
        validation_candidate_vector_sha256_values=tuple(
            str(value) for value in candidate_hashes
        ),
    )
    if expected_binding is not None and verified != expected_binding:
        raise CalibrationBindingError(
            "validation-candidate evidence differs from the frozen binding"
        )
    return verified


class CandidateEvaluator(Protocol):
    def __call__(
        self,
        adapter: CandidateAdapter,
        vector: Mapping[str, object],
        view: "EvaluationView",
        degradation_cache: "LockedDegradationCache",
        control_selection: Optional[ControlSelectionBundle],
    ) -> Mapping[str, object]:
        ...


@dataclass(frozen=True)
class CalibrationCandidate:
    """A production-harness adapter plus the evaluator that invokes it."""

    adapter_factory: Callable[[Mapping[str, object], str], CandidateAdapter]
    evaluator: CandidateEvaluator
    analytic_fixture: bool = False


@dataclass(frozen=True)
class EvaluationView:
    """Split-scoped evaluator capability with no repository or holdout paths."""

    split: str
    cases: Tuple[Mapping[str, object], ...]
    input_sha256_bindings: Tuple[Tuple[str, str], ...]
    corpus_manifest_sha256: str
    corpus_lock_bundle_sha256: str
    quality_harness_implementation_manifest_sha256: str
    analytic_fixture_manifest: Mapping[str, object]
    candidate_evidence_policy: Mapping[str, object]
    candidate_evidence_source_sha256_bindings: Tuple[Tuple[str, str], ...]
    _claim_case: Callable[[str], PlanarFrame]
    _unconsumed_case_tokens: Callable[[], Tuple[str, ...]]

    def load_case(self, opaque_case_token: str) -> PlanarFrame:
        """Consume one immutable open-split target by opaque token exactly once."""

        return self._claim_case(opaque_case_token)


def _evaluation_view(
    bound: BoundInputs,
    split: str,
    cases: Tuple[Mapping[str, object], ...],
    frames: Sequence[PlanarFrame],
) -> EvaluationView:
    if split not in {"development", "validation"}:
        raise CalibrationBindingError("P06 evaluator capability cannot target holdout")
    permitted = (
        "mapping_seed",
        "operator_bank_seed",
        "metric_policy_seed",
        "degradation_policy",
        "canonical_core",
        "lut_binary_contract",
        "compiler_contract",
        "metric_performance_tolerances",
        "quality_gate_policy_seed",
        "baseline_ablation_contract",
        "candidate_evidence_policy",
        "analytic_fixture_manifest",
        "quality_harness_implementation_manifest",
        f"{split}_sample_lock",
    )
    if len(frames) != len(cases):
        raise CalibrationBindingError("split frame capability count mismatch")
    tokens = []
    available: Dict[str, PlanarFrame] = {}
    public_cases = []
    for index, (record, frame) in enumerate(zip(cases, frames)):
        expected_hash = record.get("target_frame_sha256")
        if frame_sha256(frame) != expected_hash:
            raise CalibrationBindingError("split frame capability disagrees with sample lock")
        token = canonical_sha256(
            {
                "split": split,
                "ordinal": index,
                "target_frame_sha256": expected_hash,
                "sample_lock_sha256": bound.record(f"{split}_sample_lock")["sha256"],
            }
        )
        frozen = LockedDegradationCache._freeze(frame)
        available[token] = frozen
        tokens.append(token)
        public_cases.append({**record, "opaque_case_token": token})

    def claim_case(token: str) -> PlanarFrame:
        if not _is_sha256(token) or token not in available:
            raise CalibrationBindingError("opaque case token is absent, foreign, or already consumed")
        return available.pop(token)

    view = EvaluationView(
        split=split,
        cases=tuple(public_cases),
        input_sha256_bindings=tuple(
            (identifier, str(bound.record(identifier)["sha256"]))
            for identifier in permitted
        ),
        corpus_manifest_sha256=str(
            bound.documents["corpus_lock"]["manifest_sha256"]
        ),
        corpus_lock_bundle_sha256=corpus_lock_bundle_sha256(bound),
        quality_harness_implementation_manifest_sha256=str(
            bound.documents["quality_harness_implementation_manifest"][
                "manifest_sha256"
            ]
        ),
        analytic_fixture_manifest=json.loads(
            json.dumps(bound.documents["analytic_fixture_manifest"])
        ),
        candidate_evidence_policy=json.loads(
            json.dumps(bound.documents["candidate_evidence_policy"])
        ),
        candidate_evidence_source_sha256_bindings=tuple(
            (
                name,
                str(bound.record(f"candidate_evidence_source_{name}")["sha256"]),
            )
            for name in bound.documents["candidate_evidence_policy"][
                "source_evidence"
            ]
        ),
        _claim_case=claim_case,
        _unconsumed_case_tokens=lambda: tuple(sorted(available)),
    )
    return view


class LockedDegradationCache:
    """Cache locked degradation outputs while detecting pixel mutation."""

    def __init__(self, degradation_policy_sha256: str) -> None:
        if not _is_sha256(degradation_policy_sha256):
            raise CalibrationError("degradation policy SHA-256 is invalid")
        self.degradation_policy_sha256 = degradation_policy_sha256
        self._frames: MutableMapping[Tuple[str, str, str, str], PlanarFrame] = {}
        self._hashes: MutableMapping[Tuple[str, str, str, str], str] = {}

    @staticmethod
    def _freeze(frame: PlanarFrame) -> PlanarFrame:
        planes = []
        for source in (frame.y, frame.cb, frame.cr):
            target = np.array(source, dtype=np.float64, copy=True, order="C")
            target.setflags(write=False)
            planes.append(target)
        return PlanarFrame(y=planes[0], cb=planes[1], cr=planes[2])

    def get_or_create(
        self,
        *,
        source_asset_id: str,
        target_frame: PlanarFrame,
        target_frame_sha256: str,
        profile_id: str,
        builder: Callable[[PlanarFrame], PlanarFrame],
    ) -> PlanarFrame:
        if frame_sha256(target_frame) != target_frame_sha256:
            raise CalibrationError("degradation cache target pixels do not match their lock")
        key = (
            source_asset_id,
            target_frame_sha256,
            profile_id,
            self.degradation_policy_sha256,
        )
        if key not in self._frames:
            before = frame_sha256(target_frame)
            degraded = builder(target_frame)
            if frame_sha256(target_frame) != before:
                raise CalibrationError("degradation builder mutated target pixels")
            if not isinstance(degraded, PlanarFrame):
                raise CalibrationError("degradation builder did not return a PlanarFrame")
            frozen = self._freeze(degraded)
            self._frames[key] = frozen
            self._hashes[key] = frame_sha256(frozen)
        frame = self._frames[key]
        if frame_sha256(frame) != self._hashes[key]:
            raise CalibrationError("cached degradation pixels changed")
        return frame

    def evidence(self) -> Mapping[str, object]:
        records = []
        for key in sorted(self._frames):
            records.append(
                {
                    "source_asset_id": key[0],
                    "target_frame_sha256": key[1],
                    "profile_id": key[2],
                    "degradation_policy_sha256": key[3],
                    "degraded_frame_sha256": self._hashes[key],
                }
            )
        return {
            "degradation_policy_sha256": self.degradation_policy_sha256,
            "entries": records,
            "cache_manifest_sha256": canonical_sha256(records),
        }


def _degradation_policy_cache_sha256(bound: BoundInputs) -> str:
    """Return the policy's semantic self-hash used by degradation evidence."""

    policy = bound.documents.get("degradation_policy")
    if not isinstance(policy, dict):
        raise CalibrationBindingError("degradation policy document is absent")
    policy_sha256 = policy.get("policy_sha256")
    if not isinstance(policy_sha256, str) or not _is_sha256(policy_sha256):
        raise CalibrationBindingError("degradation policy self-hash is invalid")
    if policy_sha256 != canonical_sha256(
        {key: value for key, value in policy.items() if key != "policy_sha256"}
    ):
        raise CalibrationBindingError("degradation policy self-hash changed")
    return policy_sha256


def _require_finite_number(value: object, label: str) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise CalibrationError(f"{label} must be numeric")
    result = float(value)
    if not math.isfinite(result):
        raise CalibrationError(f"{label} must be finite")
    return result


def _lexicographic_control_winner(
    results: Sequence[Mapping[str, object]],
    *,
    id_field: str,
) -> object:
    if not results:
        raise CalibrationError("control selection has no objective results")
    ranked = []
    for result in results:
        values = result.get("engine_raw_corpus_mean_tuple")
        if not isinstance(values, list) or len(values) != 5:
            raise CalibrationError("control selection objective tuple is invalid")
        ranked.append(
            (
                tuple(
                    _require_finite_number(value, "control selection tuple")
                    for value in values
                ),
                result.get(id_field),
            )
        )
    best_tuple = max(item[0] for item in ranked)
    identifiers = [identifier for values, identifier in ranked if values == best_tuple]
    try:
        return min(identifiers)
    except TypeError as error:
        raise CalibrationError("control stable IDs are not mutually comparable") from error


def _validate_runtime_adapter(
    adapter: CandidateAdapter,
    vector: Mapping[str, object],
    plan: Mapping[str, object],
    bound: BoundInputs,
    *,
    analytic_test_mode: bool,
) -> None:
    if not isinstance(adapter, CandidateAdapter):
        raise CalibrationError("candidate is not a production-dry-run CandidateAdapter")
    adapter.validate_configuration()
    configuration = adapter.configuration
    expected_vector_hash = candidate_vector_sha256(vector, plan)
    if (
        configuration.get("serialized_candidate_vector_sha256") != expected_vector_hash
        or configuration.get("candidate_vector") != dict(vector)
    ):
        raise CalibrationError("candidate adapter is not bound to the attempted vector")
    if (
        configuration.get("implementation_role") == "production_swift"
        and not callable(getattr(adapter.callable, "close", None))
    ):
        raise CalibrationError("production candidate adapter has no close capability")
    if analytic_test_mode:
        if configuration.get("implementation_role") not in {
            "analytic_test_fixture",
            "production_swift",
        }:
            raise CalibrationError("analytic adapter has an invalid implementation role")
        return
    required_hashes = (
        "mapping_sha256",
        "operator_bank_sha256",
        "metric_policy_sha256",
        "compiler_inputs_sha256",
        "compiler_contract_sha256",
        "calibration_plan_sha256",
        "corpus_lock_bundle_sha256",
        "shared_bank_configuration_sha256",
        "mapping_seed_sha256",
        "operator_bank_seed_sha256",
        "metric_policy_seed_sha256",
        "candidate_lut_runtime_manifest_sha256",
        "raw_output_contract_sha256",
        "full_control_configuration_sha256",
    )
    route_bindings = configuration.get("route_luts")
    if (
        configuration.get("implementation_role") != "production_swift"
        or not isinstance(configuration.get("configuration_id"), str)
        or not configuration.get("configuration_id")
        or any(not _is_sha256(configuration.get(name)) for name in required_hashes)
        or not isinstance(route_bindings, dict)
        or set(route_bindings) != set(ROUTES)
    ):
        raise CalibrationError("candidate adapter lacks locked production Swift identity")
    artifacts = candidate_artifact_documents(vector, plan, bound)
    validate_schema(artifacts["mapping"], SCHEMAS_ROOT / "video-mapping-v1.schema.json")
    validate_schema(
        artifacts["operator_bank"],
        SCHEMAS_ROOT / "operator-bank-v1.schema.json",
    )
    if configuration.get("configuration_id") != artifacts["mapping"]["configuration_id"]:
        raise CalibrationError("candidate configuration ID is not vector-derived")
    expected_bindings = {
        "mapping_seed_sha256": bound.record("mapping_seed")["sha256"],
        "operator_bank_seed_sha256": bound.record("operator_bank_seed")["sha256"],
        "metric_policy_seed_sha256": bound.record("metric_policy_seed")["sha256"],
        "mapping_sha256": canonical_sha256(artifacts["mapping"]),
        "operator_bank_sha256": canonical_sha256(artifacts["operator_bank"]),
        "metric_policy_sha256": canonical_sha256(artifacts["metric_policy"]),
        "compiler_contract_sha256": bound.record("compiler_contract")["sha256"],
        "calibration_plan_sha256": bound.record("calibration_plan")["sha256"],
        "corpus_lock_bundle_sha256": corpus_lock_bundle_sha256(bound),
        "shared_bank_configuration_sha256": shared_bank_configuration_sha256(
            vector, plan
        ),
    }
    if any(configuration.get(field) != expected for field, expected in expected_bindings.items()):
        raise CalibrationError("candidate adapter input digests disagree with bound files")
    if configuration.get("candidate_artifacts") != artifacts:
        raise CalibrationError("candidate adapter does not contain exact canonical artifacts")
    expected_compiler_document = locked_compiler_input_document(
        vector=vector,
        plan=plan,
        configuration_id=str(artifacts["mapping"]["configuration_id"]),
        mapping_sha256=expected_bindings["mapping_sha256"],
        operator_bank_sha256=expected_bindings["operator_bank_sha256"],
        metric_policy_sha256=expected_bindings["metric_policy_sha256"],
        calibration_plan_sha256=expected_bindings["calibration_plan_sha256"],
        corpus_lock_bundle_sha256=expected_bindings[
            "corpus_lock_bundle_sha256"
        ],
    )
    if (
        configuration.get("compiler_input_document") != expected_compiler_document
        or configuration.get("compiler_inputs_sha256")
        != expected_compiler_document["hash_bindings"]["compiler_inputs_sha256"]
    ):
        raise CalibrationError("candidate compiler input does not bind all vector artifacts")
    swift_cli = configuration.get("swift_cli")
    if (
        not isinstance(swift_cli, dict)
        or not _is_sha256(swift_cli.get("executable_sha256"))
        or not _is_sha256(swift_cli.get("source_manifest_sha256"))
    ):
        raise CalibrationError("candidate adapter lacks Swift CLI executable/source binding")
    for route in ROUTES:
        binding = route_bindings[route]
        if (
            not isinstance(binding, dict)
            or not _is_sha256(binding.get("whole_file_sha256"))
            or not _is_sha256(binding.get("payload_sha256"))
            or binding.get("coordinate_policy")
            != vector[route.replace("-", "_").replace("3over2", "3_over_2") + "_coordinate_policy"]
            or binding.get("analysis_grid_source_step")
            != vector[route.replace("-", "_").replace("3over2", "3_over_2") + "_analysis_grid_source_step"]
        ):
            raise CalibrationError(f"candidate adapter route binding is invalid: {route}")
    if configuration.get("boundary_mode") != vector["boundary_mode"]:
        raise CalibrationError("candidate adapter boundary mode disagrees with the vector")


@dataclass
class _TrackedCandidateCallable:
    source_adapter: CandidateAdapter
    full_calls: List[Mapping[str, object]]
    control_calls: List[Mapping[str, object]]
    control_native_calls: List[Mapping[str, object]] = field(default_factory=list)

    def _source_records(
        self,
        provider_name: str,
        *,
        required: bool,
    ) -> Optional[Tuple[Mapping[str, object], ...]]:
        provider = getattr(self.source_adapter.callable, provider_name, None)
        if provider is None:
            if required:
                raise CalibrationError(
                    f"native evidence provider is absent: {provider_name}"
                )
            return None
        records = provider()
        if not isinstance(records, (list, tuple)) or any(
            not isinstance(record, dict) for record in records
        ):
            raise CalibrationError(
                f"native evidence records are invalid: {provider_name}"
            )
        return tuple(dict(record) for record in records)

    def _capture_one_source_record(
        self,
        provider_name: str,
        before_count: Optional[int],
        *,
        required: bool,
    ) -> Optional[Mapping[str, object]]:
        if before_count is None:
            if required:
                raise CalibrationError(
                    f"native evidence provider is absent: {provider_name}"
                )
            return None
        after_count = self._source_record_count(provider_name, required=True)
        assert after_count is not None
        if after_count != before_count + 1:
            raise CalibrationError(
                f"native evidence provider did not append exactly one record: {provider_name}"
            )
        record_provider = getattr(
            self.source_adapter.callable,
            f"{provider_name}_record",
            None,
        )
        if record_provider is None:
            raise CalibrationError(
                f"native indexed evidence provider is absent: {provider_name}"
            )
        source_record = record_provider(before_count)
        if not isinstance(source_record, dict):
            raise CalibrationError(
                f"native indexed evidence record is invalid: {provider_name}"
            )
        record = dict(source_record)
        unhashed = dict(record)
        declared = unhashed.pop("record_sha256", None)
        if not _is_sha256(declared) or declared != canonical_sha256(unhashed):
            raise CalibrationError(
                f"native evidence record self-hash is invalid: {provider_name}"
            )
        return record

    def _source_record_count(
        self,
        provider_name: str,
        *,
        required: bool,
    ) -> Optional[int]:
        provider = getattr(
            self.source_adapter.callable,
            f"{provider_name}_count",
            None,
        )
        if provider is None:
            if required:
                raise CalibrationError(
                    f"native indexed evidence provider is absent: {provider_name}"
                )
            return None
        count = provider()
        if (
            not isinstance(count, int)
            or isinstance(count, bool)
            or count < 0
        ):
            raise CalibrationError(
                f"native indexed evidence count is invalid: {provider_name}"
            )
        return count

    def __call__(self, frame: PlanarFrame, context: CandidateContext) -> PlanarFrame:
        input_hash = frame_sha256(frame)
        output = self.source_adapter.reconstruct(frame, context)
        self.full_calls.append(
            {
                "input_frame_sha256": input_hash,
                "output_frame_sha256": frame_sha256(output),
                "target_route": context.target_route,
            }
        )
        return output

    def reconstruct_control(
        self,
        request: Mapping[str, object],
        frame: PlanarFrame,
        context: CandidateContext,
    ) -> PlanarFrame:
        provider = getattr(self.source_adapter.callable, "reconstruct_control", None)
        if provider is None or not isinstance(request, dict):
            raise CalibrationError("native control provider is absent or request is invalid")
        try:
            request_bytes = canonical_json_bytes(request)
        except (TypeError, ValueError) as error:
            raise CalibrationError("native control request is not canonical JSON") from error
        if (
            not isinstance(request.get("control_key"), str)
            or not _is_sha256(request.get("configuration_sha256"))
        ):
            raise CalibrationError("native control request lacks exact control identity")
        unhashed_request = dict(request)
        declared_request_sha256 = unhashed_request.pop("request_sha256", None)
        if (
            not _is_sha256(declared_request_sha256)
            or declared_request_sha256 != canonical_sha256(unhashed_request)
        ):
            raise CalibrationError("native control request self-hash is invalid")
        input_hash = frame_sha256(frame)
        before_native_records = self._source_record_count(
            "control_runtime_records",
            required=False,
        )
        validating_adapter = CandidateAdapter(
            candidate_id=self.source_adapter.candidate_id,
            configuration=self.source_adapter.configuration,
            configuration_sha256=self.source_adapter.configuration_sha256,
            callable=lambda source, candidate_context: provider(
                request, source, candidate_context
            ),
        )
        output = validating_adapter.reconstruct(frame, context)
        native_record = self._capture_one_source_record(
            "control_runtime_records",
            before_native_records,
            required=False,
        )
        if native_record is not None:
            self.control_native_calls.append(native_record)
        self.control_calls.append(
            {
                "request": dict(request),
                "request_sha256": declared_request_sha256,
                "request_document_sha256": hashlib.sha256(request_bytes).hexdigest(),
                "input_frame_sha256": input_hash,
                "output_frame_sha256": frame_sha256(output),
                "target_route": context.target_route,
            }
        )
        return output

    def runtime_records(self) -> object:
        provider = getattr(self.source_adapter.callable, "runtime_records", None)
        return () if provider is None else provider()

    def control_runtime_records(self) -> object:
        return tuple(dict(record) for record in self.control_native_calls)

    def control_runtime_records_count(self) -> int:
        return len(self.control_native_calls)

    def control_runtime_records_record(self, index: int) -> Mapping[str, object]:
        if (
            not isinstance(index, int)
            or isinstance(index, bool)
            or index not in range(len(self.control_native_calls))
        ):
            raise CalibrationError("control runtime record index is invalid")
        return dict(self.control_native_calls[index])

    def flush_control_cache_durability(self) -> Mapping[str, object]:
        provider = getattr(
            self.source_adapter.callable,
            "flush_control_cache_durability",
            None,
        )
        if provider is None:
            raise CalibrationError("native control-cache durability provider is absent")
        record = provider()
        if not isinstance(record, dict):
            raise CalibrationError("native control-cache durability record is invalid")
        return dict(record)

    def measure_dispatch_projection(self, *args: object, **kwargs: object) -> object:
        provider = getattr(
            self.source_adapter.callable, "measure_dispatch_projection", None
        )
        if provider is None:
            raise CalibrationError("native dispatch projection provider is absent")
        return provider(*args, **kwargs)

    def dispatch_environment(self) -> object:
        provider = getattr(self.source_adapter.callable, "dispatch_environment", None)
        if provider is None:
            raise CalibrationError("native dispatch environment provider is absent")
        return provider()

    def p00_identity(self) -> object:
        provider = getattr(self.source_adapter.callable, "p00_identity", None)
        if provider is None:
            raise CalibrationError("native P00 identity provider is absent")
        return provider()

    def candidate_compiler_evidence(self) -> object:
        provider = getattr(
            self.source_adapter.callable,
            "candidate_compiler_evidence",
            None,
        )
        if provider is None:
            raise CalibrationError("candidate compiler evidence provider is absent")
        return provider()

    def prepare_non_ash_cache(self, *args: object, **kwargs: object) -> object:
        provider = getattr(
            self.source_adapter.callable,
            "prepare_non_ash_cache",
            None,
        )
        if provider is None:
            raise CalibrationError("native non-ASH cache provider is absent")
        return provider(*args, **kwargs)

    def reconstruct_non_ash_cached(
        self,
        cache_token: str,
        rule: Mapping[str, object],
    ) -> object:
        return self._invoke_non_ash_cached(
            "reconstruct_non_ash_cached",
            cache_token,
            rule,
        )

    def reopen_non_ash_cached(
        self,
        cache_token: str,
        rule: Mapping[str, object],
    ) -> object:
        return self._invoke_non_ash_cached(
            "reopen_non_ash_cached",
            cache_token,
            rule,
        )

    def _invoke_non_ash_cached(
        self,
        provider_name: str,
        cache_token: str,
        rule: Mapping[str, object],
    ) -> object:
        provider = getattr(self.source_adapter.callable, provider_name, None)
        if provider is None:
            raise CalibrationError(
                f"native cached non-ASH reconstruction is absent: {provider_name}"
            )
        if not _is_sha256(cache_token) or not isinstance(rule, dict):
            raise CalibrationError("native cached non-ASH identity is invalid")
        before = self._source_record_count("non_ash_cache_records", required=True)
        before_control = self._source_record_count(
            "control_runtime_records",
            required=True,
        )
        output = provider(cache_token, rule)
        record = self._capture_one_source_record(
            "non_ash_cache_records",
            before,
            required=True,
        )
        native_control_record = self._capture_one_source_record(
            "control_runtime_records",
            before_control,
            required=True,
        )
        assert record is not None
        assert native_control_record is not None
        rule_configuration = record.get("rule_configuration")
        rule_sha256 = record.get("rule_sha256")
        bank = self.source_adapter.configuration.get(
            "shared_bank_configuration_sha256"
        )
        if (
            not isinstance(rule_configuration, dict)
            or rule_configuration != dict(rule)
            or not _is_sha256(rule_sha256)
            or rule_sha256 != canonical_sha256(rule_configuration)
            or not _is_sha256(bank)
        ):
            raise CalibrationError(
                "native cached non-ASH record identity is invalid or stale"
            )
        parameters = {
            "selector_id": "continuous-linear-bank-selector-q15-v1",
            "selected_rule_sha256": rule_sha256,
            "selected_rule_configuration": rule_configuration,
        }
        configuration_sha256 = canonical_sha256(
            {
                "rule_sha256": rule_sha256,
                "selector_id": "continuous-linear-bank-selector-q15-v1",
                "shared_bank_configuration_sha256": bank,
            }
        )
        request: dict[str, object] = {
            "schema_version": "1.0.0",
            "operation": "reconstruct_control",
            "control_key": "non_ash_selector",
            "control_mode": "non_ash_selector_q15",
            "configuration_sha256": configuration_sha256,
            "shared_bank_configuration_sha256": bank,
            "parameters": parameters,
        }
        request["request_sha256"] = canonical_sha256(request)
        request_bytes = canonical_json_bytes(request)
        if (
            not isinstance(output, PlanarFrame)
            or record.get("cache_token") != cache_token
            or record.get("cache_manifest_sha256") != cache_token
            or record.get("output_frame_sha256") != frame_sha256(output)
            or native_control_record.get("control_key") != "non_ash_selector"
            or native_control_record.get("control_mode")
            != "non_ash_selector_q15"
            or native_control_record.get("request_sha256")
            != request["request_sha256"]
            or native_control_record.get("configuration_sha256")
            != configuration_sha256
            or native_control_record.get("shared_bank_configuration_sha256")
            != bank
            or not _is_sha256(
                native_control_record.get("input_frame_sha256")
            )
            or native_control_record.get("output_frame_sha256")
            != record["output_frame_sha256"]
            or native_control_record.get("target_route")
            != record.get("target_route")
            or native_control_record.get("parameters") != parameters
            or native_control_record.get("parameters_sha256")
            != canonical_sha256(parameters)
            or native_control_record.get("non_ash_cache_record_sha256")
            != record.get("record_sha256")
        ):
            raise CalibrationError(
                "native cached non-ASH control summary differs from its cache record"
            )
        self.control_native_calls.append(native_control_record)
        self.control_calls.append(
            {
                "request": request,
                "request_sha256": request["request_sha256"],
                "request_document_sha256": hashlib.sha256(request_bytes).hexdigest(),
                "input_frame_sha256": native_control_record[
                    "input_frame_sha256"
                ],
                "output_frame_sha256": record["output_frame_sha256"],
                "target_route": record["target_route"],
            }
        )
        return output

    def non_ash_cache_records(self) -> object:
        provider = getattr(
            self.source_adapter.callable,
            "non_ash_cache_records",
            None,
        )
        if provider is None:
            raise CalibrationError("native non-ASH cache records are absent")
        return provider()

    def non_ash_cache_records_count(self) -> int:
        count = self._source_record_count(
            "non_ash_cache_records",
            required=True,
        )
        assert count is not None
        return count

    def non_ash_cache_records_record(self, index: int) -> Mapping[str, object]:
        if not isinstance(index, int) or isinstance(index, bool) or index < 0:
            raise CalibrationError("native non-ASH indexed record index is invalid")
        provider = getattr(
            self.source_adapter.callable,
            "non_ash_cache_records_record",
            None,
        )
        if provider is None:
            raise CalibrationError("native non-ASH indexed records are absent")
        record = provider(index)
        if not isinstance(record, dict):
            raise CalibrationError("native non-ASH indexed record is invalid")
        return dict(record)

    def non_ash_cache_preparation_records(self) -> object:
        provider = getattr(
            self.source_adapter.callable,
            "non_ash_cache_preparation_records",
            None,
        )
        if provider is None:
            raise CalibrationError(
                "native non-ASH cache preparation records are absent"
            )
        return provider()

    def non_ash_cache_preparation_records_count(self) -> int:
        count = self._source_record_count(
            "non_ash_cache_preparation_records",
            required=True,
        )
        assert count is not None
        return count

    def non_ash_cache_preparation_records_record(
        self,
        index: int,
    ) -> Mapping[str, object]:
        if not isinstance(index, int) or isinstance(index, bool) or index < 0:
            raise CalibrationError(
                "native non-ASH preparation record index is invalid"
            )
        provider = getattr(
            self.source_adapter.callable,
            "non_ash_cache_preparation_records_record",
            None,
        )
        if provider is None:
            raise CalibrationError(
                "native non-ASH indexed preparation records are absent"
            )
        record = provider(index)
        if not isinstance(record, dict):
            raise CalibrationError(
                "native non-ASH indexed preparation record is invalid"
            )
        return dict(record)

    def reconstruct_fixed_cached(
        self,
        cache_token: str,
        descriptor_id: int,
    ) -> PlanarFrame:
        provider = getattr(
            self.source_adapter.callable,
            "reconstruct_fixed_cached",
            None,
        )
        if provider is None:
            raise CalibrationError("native cached fixed reconstruction is absent")
        if not _is_sha256(cache_token):
            raise CalibrationError("native fixed cache token is invalid")
        if (
            not isinstance(descriptor_id, int)
            or isinstance(descriptor_id, bool)
            or descriptor_id not in range(16)
        ):
            raise CalibrationError("native cached fixed descriptor is outside 0...15")

        before = self._source_record_count("fixed_cache_records", required=True)
        before_control = self._source_record_count(
            "control_runtime_records",
            required=True,
        )
        output = provider(cache_token, descriptor_id)
        record = self._capture_one_source_record(
            "fixed_cache_records",
            before,
            required=True,
        )
        native_control_record = self._capture_one_source_record(
            "control_runtime_records",
            before_control,
            required=True,
        )
        assert record is not None
        assert native_control_record is not None
        request = record.get("control_request")
        if not isinstance(request, dict):
            raise CalibrationError("native fixed cache record lacks a control request")
        try:
            request_bytes = canonical_json_bytes(request)
        except (TypeError, ValueError) as error:
            raise CalibrationError(
                "native fixed cache control request is not canonical JSON"
            ) from error
        unhashed_request = dict(request)
        declared_request_sha256 = unhashed_request.pop("request_sha256", None)
        if (
            request.get("schema_version") != "1.0.0"
            or request.get("operation") != "reconstruct_control"
            or request.get("control_key") != f"fixed_descriptor_{descriptor_id:02d}"
            or request.get("control_mode") != "fixed_descriptor_uniform"
            or request.get("parameters") != {"descriptor_id": descriptor_id}
            or not _is_sha256(request.get("configuration_sha256"))
            or not _is_sha256(
                request.get("shared_bank_configuration_sha256")
            )
            or request.get("shared_bank_configuration_sha256")
            != record.get("shared_bank_configuration_sha256")
            or request.get("shared_bank_configuration_sha256")
            != self.source_adapter.configuration.get(
                "shared_bank_configuration_sha256"
            )
            or not _is_sha256(declared_request_sha256)
            or declared_request_sha256 != canonical_sha256(unhashed_request)
        ):
            raise CalibrationError(
                "native fixed cache record has an invalid canonical control request"
            )
        expected_record_fields = {
            "schema_version",
            "artifact_kind",
            "cache_token",
            "cache_manifest_sha256",
            "descriptor_id",
            "shared_bank_configuration_sha256",
            "input_frame_sha256",
            "output_frame_sha256",
            "target_route",
            "control_request",
            "stateful_lut_lookup_count",
            "spatial_operator_recompute_count",
            "analysis_grid_invocation_count",
            "record_sha256",
        }
        if (
            set(record) != expected_record_fields
            or record.get("schema_version") != "1.0.0"
            or record.get("artifact_kind")
            != "p06_native_fixed_cached_reconstruction"
            or record.get("cache_token") != cache_token
            or record.get("cache_manifest_sha256") != cache_token
            or record.get("descriptor_id") != descriptor_id
            or not _is_sha256(record.get("shared_bank_configuration_sha256"))
            or not _is_sha256(record.get("input_frame_sha256"))
            or record.get("output_frame_sha256") != frame_sha256(output)
            or record.get("target_route") not in ROUTES
            or record.get("stateful_lut_lookup_count") != 0
            or record.get("spatial_operator_recompute_count") != 0
            or record.get("analysis_grid_invocation_count") != 0
        ):
            raise CalibrationError("native fixed cache record is invalid or stale")
        if (
            native_control_record.get("control_key") != request["control_key"]
            or native_control_record.get("control_mode")
            != "fixed_descriptor_uniform"
            or native_control_record.get("request_sha256")
            != declared_request_sha256
            or native_control_record.get("configuration_sha256")
            != request["configuration_sha256"]
            or native_control_record.get("shared_bank_configuration_sha256")
            != request["shared_bank_configuration_sha256"]
            or native_control_record.get("input_frame_sha256")
            != record["input_frame_sha256"]
            or native_control_record.get("output_frame_sha256")
            != record["output_frame_sha256"]
            or native_control_record.get("target_route") != record["target_route"]
            or native_control_record.get("parameters") != request["parameters"]
            or native_control_record.get("parameters_sha256")
            != canonical_sha256(request["parameters"])
            or native_control_record.get("fixed_cache_record_sha256")
            != record["record_sha256"]
        ):
            raise CalibrationError(
                "native cached fixed control summary differs from its cache record"
            )

        self.control_native_calls.append(native_control_record)
        self.control_calls.append(
            {
                "request": dict(request),
                "request_sha256": declared_request_sha256,
                "request_document_sha256": hashlib.sha256(request_bytes).hexdigest(),
                "input_frame_sha256": record["input_frame_sha256"],
                "output_frame_sha256": record["output_frame_sha256"],
                "target_route": record["target_route"],
            }
        )
        return output

    def fixed_cache_records(self) -> object:
        provider = getattr(
            self.source_adapter.callable,
            "fixed_cache_records",
            None,
        )
        if provider is None:
            raise CalibrationError("native fixed cache records are absent")
        return provider()

    def fixed_cache_records_count(self) -> int:
        count = self._source_record_count(
            "fixed_cache_records",
            required=True,
        )
        assert count is not None
        return count

    def fixed_cache_records_record(self, index: int) -> Mapping[str, object]:
        if not isinstance(index, int) or isinstance(index, bool) or index < 0:
            raise CalibrationError("native fixed indexed record index is invalid")
        provider = getattr(
            self.source_adapter.callable,
            "fixed_cache_records_record",
            None,
        )
        if provider is None:
            raise CalibrationError("native fixed indexed records are absent")
        record = provider(index)
        if not isinstance(record, dict):
            raise CalibrationError("native fixed indexed record is invalid")
        return dict(record)


@dataclass
class _AdapterInvocationTracker:
    source_adapter: CandidateAdapter
    calls: List[Mapping[str, object]]
    control_calls: List[Mapping[str, object]]
    control_native_calls: List[Mapping[str, object]]

    def adapter(self) -> CandidateAdapter:
        return CandidateAdapter(
            candidate_id=self.source_adapter.candidate_id,
            configuration=self.source_adapter.configuration,
            configuration_sha256=self.source_adapter.configuration_sha256,
            callable=_TrackedCandidateCallable(
                source_adapter=self.source_adapter,
                full_calls=self.calls,
                control_calls=self.control_calls,
                control_native_calls=self.control_native_calls,
            ),
        )

    def native_records(self) -> Tuple[Mapping[str, object], ...]:
        provider = getattr(self.source_adapter.callable, "runtime_records", None)
        if provider is None:
            return ()
        records = provider()
        if not isinstance(records, (list, tuple)) or any(
            not isinstance(record, dict) for record in records
        ):
            raise CalibrationError("native adapter runtime records are invalid")
        return tuple(records)

    def control_native_records(self) -> Tuple[Mapping[str, object], ...]:
        return tuple(dict(record) for record in self.control_native_calls)


def _candidate_evidence_source_bindings(
    bound: BoundInputs,
) -> List[Mapping[str, object]]:
    policy = bound.documents["candidate_evidence_policy"]
    return [
        {
            "id": name,
            "sha256": bound.record(
                f"candidate_evidence_source_{name}"
            )["sha256"],
        }
        for name in policy["source_evidence"]
    ]


def _validate_candidate_evidence_header(
    evidence: Mapping[str, object],
    *,
    bound: BoundInputs,
    label: str,
) -> None:
    if (
        evidence.get("candidate_evidence_policy_sha256")
        != bound.record("candidate_evidence_policy")["sha256"]
        or evidence.get("source_sha256_bindings")
        != _candidate_evidence_source_bindings(bound)
    ):
        raise CalibrationError(f"{label} policy/source bindings are stale")


def _validate_candidate_compiler_evidence(
    evidence: Mapping[str, object],
    *,
    adapter: CandidateAdapter,
) -> int:
    provider = getattr(adapter.callable, "candidate_compiler_evidence", None)
    if provider is None:
        raise CalibrationError("candidate compiler evidence provider is absent")
    reopened = provider()
    if not isinstance(reopened, dict) or evidence != reopened:
        raise CalibrationError(
            "published compiler evidence differs from the native provider"
        )
    unhashed = dict(evidence)
    declared_sha256 = unhashed.pop("evidence_sha256", None)
    configuration = adapter.configuration
    compiler_file_sha256 = hashlib.sha256(
        canonical_json_bytes(configuration["compiler_input_document"])
    ).hexdigest()
    if (
        declared_sha256 != canonical_sha256(unhashed)
        or evidence.get("configuration_id")
        != configuration.get("configuration_id")
        or evidence.get("candidate_vector_sha256")
        != configuration.get("serialized_candidate_vector_sha256")
        or evidence.get("compiler_inputs_sha256")
        != configuration.get("compiler_inputs_sha256")
        or evidence.get("compiler_input_document_file_sha256")
        != compiler_file_sha256
        or evidence.get("candidate_lut_runtime_manifest_sha256")
        != configuration.get("candidate_lut_runtime_manifest_sha256")
        or evidence.get("native_executable_sha256")
        != configuration.get("swift_cli", {}).get("executable_sha256")
        or evidence.get("native_source_manifest_sha256")
        != configuration.get("swift_cli", {}).get("source_manifest_sha256")
    ):
        raise CalibrationError("candidate compiler evidence identity is stale")
    routes = evidence.get("routes")
    if not isinstance(routes, list) or [
        route.get("target_route") for route in routes
    ] != list(ROUTES):
        raise CalibrationError("candidate compiler evidence route order differs")
    maximum = 0
    expected_entry_counts = {"direct-2x": 4096, "direct-3over2": 9216}
    for route in routes:
        target_route = str(route["target_route"])
        route_binding = configuration["route_luts"][target_route]
        conditioning = route["state_conditioning_evidence"]
        if (
            route.get("lut_whole_file_sha256")
            != route_binding["whole_file_sha256"]
            or route.get("lut_payload_sha256")
            != route_binding["payload_sha256"]
            or route.get("state_conditioning_evidence_sha256")
            != canonical_sha256(conditioning)
            or conditioning.get("target_route") != target_route
            or conditioning.get("whole_file_sha256")
            != route_binding["whole_file_sha256"]
            or conditioning.get("payload_sha256")
            != route_binding["payload_sha256"]
            or conditioning.get("entry_count")
            != expected_entry_counts[target_route]
            or conditioning.get("state_conditioned") is not True
            or conditioning.get("oracle_validation_passed") is not True
        ):
            raise CalibrationError(
                "candidate compiler oracle evidence is incomplete or stale"
            )
        sensitivity = conditioning["coordinate_sensitivity"]
        if (
            [row["coordinate"] for row in sensitivity]
            != [1, 2, 3, 4, 5, 6, 8]
            or any(
                row["differing_dispatch_pair_count"] <= 0
                or row["first_witness"]["first_signature_sha256"]
                == row["first_witness"]["second_signature_sha256"]
                for row in sensitivity
            )
        ):
            raise CalibrationError(
                "candidate compiler coordinate sensitivity does not prove dispatch changes"
            )
        maximum = max(
            maximum,
            int(conditioning["maximum_operator_evaluations"]),
        )
    if evidence.get("maximum_operator_evaluations") != maximum:
        raise CalibrationError("candidate compiler maximum evaluation count differs")
    return maximum


def _candidate_check_cases(
    evaluation: Mapping[str, object],
) -> List[Mapping[str, object]]:
    natural = [
        {
            "witness_scope": "natural",
            "source_or_fixture_id": row["source_asset_id"],
            "degradation_profile_id": row["degradation_profile_id"],
            "target_route": row["target_route"],
            "input_frame_sha256": row["degraded_input_frame_sha256"],
        }
        for row in evaluation["corpus_asset_results"]
        if row["comparison_domain"] == "engine_raw"
    ]
    analytic = [
        {
            "witness_scope": "analytic",
            "source_or_fixture_id": row["fixture_id"],
            "degradation_profile_id": None,
            "target_route": row["target_route"],
            "input_frame_sha256": row["input_frame_sha256"],
        }
        for row in evaluation["analytic_fixture_results"]
        if row["comparison_domain"] == "engine_raw"
    ]
    cases = natural + analytic
    identities = [
        (
            case["witness_scope"],
            case["source_or_fixture_id"],
            case["degradation_profile_id"],
            case["target_route"],
            case["input_frame_sha256"],
        )
        for case in cases
    ]
    if len(identities) != len(set(identities)):
        raise CalibrationError("candidate check witness scope repeats a case")
    return cases


def _validate_operator_distinctness_evidence(
    evidence: Mapping[str, object],
    *,
    cases: Sequence[Mapping[str, object]],
    tracked_control_calls: Sequence[Mapping[str, object]],
) -> None:
    outputs: Dict[Tuple[str, str, int], str] = {}
    for call in tracked_control_calls:
        request = call.get("request")
        if (
            not isinstance(request, dict)
            or request.get("control_mode") != "fixed_descriptor_uniform"
            or not isinstance(request.get("parameters"), dict)
        ):
            continue
        descriptor = request["parameters"].get("descriptor_id")
        if not isinstance(descriptor, int) or isinstance(descriptor, bool):
            raise CalibrationError("fixed control call has an invalid descriptor")
        key = (
            str(call["input_frame_sha256"]),
            str(call["target_route"]),
            descriptor,
        )
        output_sha256 = str(call["output_frame_sha256"])
        if key in outputs and outputs[key] != output_sha256:
            raise CalibrationError(
                "fixed descriptor produced different outputs for identical bytes"
            )
        outputs[key] = output_sha256

    descriptor_ids = list(range(16))
    for case in cases:
        missing = [
            descriptor
            for descriptor in descriptor_ids
            if (
                str(case["input_frame_sha256"]),
                str(case["target_route"]),
                descriptor,
            )
            not in outputs
        ]
        if missing:
            raise CalibrationError(
                "operator-distinctness scope lacks exhaustive fixed outputs"
            )

    expected_witnesses: List[Mapping[str, object]] = []
    for first_descriptor in descriptor_ids:
        for second_descriptor in range(first_descriptor + 1, 16):
            witness = None
            for case in cases:
                first = outputs[
                    (
                        str(case["input_frame_sha256"]),
                        str(case["target_route"]),
                        first_descriptor,
                    )
                ]
                second = outputs[
                    (
                        str(case["input_frame_sha256"]),
                        str(case["target_route"]),
                        second_descriptor,
                    )
                ]
                if first != second:
                    witness = {
                        "first_descriptor_id": first_descriptor,
                        "second_descriptor_id": second_descriptor,
                        **dict(case),
                        "first_output_frame_sha256": first,
                        "second_output_frame_sha256": second,
                    }
                    break
            if witness is None:
                raise CalibrationError(
                    "one fixed-descriptor pair has no locked-scope witness"
                )
            expected_witnesses.append(witness)
    if evidence != {
        "descriptor_ids": descriptor_ids,
        "witness_scope_case_count": len(cases),
        "pair_witnesses": expected_witnesses,
    }:
        raise CalibrationError(
            "operator-distinctness evidence differs from tracked control outputs"
        )


def _validated_control_native_records(
    records: Sequence[Mapping[str, object]],
) -> List[Mapping[str, object]]:
    result = []
    for record in records:
        copied = dict(record)
        declared = copied.pop("record_sha256", None)
        if declared != canonical_sha256(copied):
            raise CalibrationError("native control record self-hash is invalid")
        result.append(record)
    return result


def _native_callable_record_stream(
    adapter: CandidateAdapter,
    provider_name: str,
) -> List[Mapping[str, object]]:
    provider = getattr(adapter.callable, provider_name, None)
    if not callable(provider):
        raise CalibrationError(
            f"native cache evidence provider is absent: {provider_name}"
        )
    records = provider()
    if not isinstance(records, (list, tuple)) or any(
        not isinstance(record, dict) for record in records
    ):
        raise CalibrationError(
            f"native cache evidence stream is invalid: {provider_name}"
        )
    copied = [dict(record) for record in records]
    try:
        canonical_json_bytes(copied)
    except (TypeError, ValueError) as error:
        raise CalibrationError(
            f"native cache evidence is not canonical JSON: {provider_name}"
        ) from error
    return copied


def _validate_self_hashed_native_record(
    record: Mapping[str, object],
    *,
    label: str,
) -> None:
    unhashed = dict(record)
    declared = unhashed.pop("record_sha256", None)
    if not _is_sha256(declared) or declared != canonical_sha256(unhashed):
        raise CalibrationError(f"{label} self-hash is invalid")


def _cache_reconstruction_proof_binding(
    proof_kind: str,
    records: Sequence[Mapping[str, object]],
) -> Mapping[str, object]:
    if proof_kind not in {"fixed", "non_ash", "control"}:
        raise CalibrationError("native cache proof kind is invalid")
    document = {
        "schema_version": "1.0.0",
        "artifact_kind": "p06_native_cache_reconstruction_proof_manifest",
        "proof_kind": proof_kind,
        "records": [dict(record) for record in records],
    }
    return {
        "artifact_sha256": canonical_sha256(document),
        "size_bytes": len(canonical_json_bytes(document)),
        "record_count": len(records),
        "ordered_record_sha256_values": [
            record["record_sha256"] for record in records
        ],
    }


def _validate_output_cache_evidence(
    output_cache: Mapping[str, object],
    *,
    adapter: CandidateAdapter,
    expected_preparation_count: int,
) -> None:
    if not isinstance(output_cache, dict):
        raise CalibrationError("candidate checks lack native output-cache evidence")
    preparation = _native_callable_record_stream(
        adapter,
        "non_ash_cache_preparation_records",
    )
    if (
        len(preparation) != expected_preparation_count
        or output_cache.get("preparation_records") != preparation
        or output_cache.get("preparation_records_sha256")
        != canonical_sha256(preparation)
    ):
        raise CalibrationError(
            "native output-cache preparation evidence differs from callable order"
        )
    preparation_fields = {
        "schema_version",
        "artifact_kind",
        "identity_sha256",
        "cache_token",
        "cache_origin_manifest_sha256",
        "requesting_configuration_id",
        "shared_bank_configuration_sha256",
        "cache_reused",
        "preparation_analysis_grid_invocation_count",
        "preparation_spatial_operator_evaluation_count",
        "cache_artifact_sha256",
        "cache_artifact_size_bytes",
        "feature_tensor_q15_sha256",
        "descriptor_output_frame_sha256_values",
        "record_sha256",
    }
    bank = adapter.configuration.get("shared_bank_configuration_sha256")
    configuration_id = adapter.configuration.get("configuration_id")
    identity_values = []
    cache_tokens = set()
    for record in preparation:
        _validate_self_hashed_native_record(
            record,
            label="native output-cache preparation record",
        )
        reused = record.get("cache_reused")
        expected_counts = (0, 0) if reused is True else (1, 16)
        descriptor_hashes = record.get(
            "descriptor_output_frame_sha256_values"
        )
        if (
            set(record) != preparation_fields
            or record.get("schema_version") != "1.0.0"
            or record.get("artifact_kind")
            != "p06_non_ash_cache_preparation_evidence"
            or not _is_sha256(record.get("identity_sha256"))
            or not _is_sha256(record.get("cache_token"))
            or not _is_sha256(record.get("cache_origin_manifest_sha256"))
            or record.get("requesting_configuration_id") != configuration_id
            or record.get("shared_bank_configuration_sha256") != bank
            or not isinstance(reused, bool)
            or (
                record.get("preparation_analysis_grid_invocation_count"),
                record.get("preparation_spatial_operator_evaluation_count"),
            )
            != expected_counts
            or not _is_sha256(record.get("cache_artifact_sha256"))
            or not isinstance(record.get("cache_artifact_size_bytes"), int)
            or isinstance(record.get("cache_artifact_size_bytes"), bool)
            or int(record["cache_artifact_size_bytes"]) <= 0
            or not _is_sha256(record.get("feature_tensor_q15_sha256"))
            or not isinstance(descriptor_hashes, list)
            or len(descriptor_hashes) != 16
            or any(not _is_sha256(value) for value in descriptor_hashes)
        ):
            raise CalibrationError(
                "native output-cache preparation record is invalid or stale"
            )
        identity_values.append(record["identity_sha256"])
        cache_tokens.add(record["cache_token"])
    if len(identity_values) != len(set(identity_values)):
        raise CalibrationError("native output-cache preparation identity repeats")

    fixed_records = _native_callable_record_stream(
        adapter,
        "fixed_cache_records",
    )
    fixed_fields = {
        "schema_version",
        "artifact_kind",
        "cache_token",
        "cache_manifest_sha256",
        "descriptor_id",
        "shared_bank_configuration_sha256",
        "input_frame_sha256",
        "output_frame_sha256",
        "target_route",
        "control_request",
        "stateful_lut_lookup_count",
        "spatial_operator_recompute_count",
        "analysis_grid_invocation_count",
        "record_sha256",
    }
    for record in fixed_records:
        _validate_self_hashed_native_record(
            record,
            label="native fixed-cache reconstruction record",
        )
        request = record.get("control_request")
        descriptor_id = record.get("descriptor_id")
        if not isinstance(request, dict):
            raise CalibrationError(
                "native fixed-cache reconstruction lacks a control request"
            )
        unhashed_request = dict(request)
        request_sha256 = unhashed_request.pop("request_sha256", None)
        expected_configuration = canonical_sha256(
            {
                "control_id": "fixed-descriptor-uniform-v1",
                "descriptor_id": descriptor_id,
                "shared_bank_configuration_sha256": bank,
            }
        )
        if (
            set(record) != fixed_fields
            or record.get("schema_version") != "1.0.0"
            or record.get("artifact_kind")
            != "p06_native_fixed_cached_reconstruction"
            or record.get("cache_token") not in cache_tokens
            or record.get("cache_manifest_sha256") != record.get("cache_token")
            or not isinstance(descriptor_id, int)
            or isinstance(descriptor_id, bool)
            or descriptor_id not in range(16)
            or record.get("shared_bank_configuration_sha256") != bank
            or not _is_sha256(record.get("input_frame_sha256"))
            or not _is_sha256(record.get("output_frame_sha256"))
            or record.get("target_route") not in ROUTES
            or request.get("schema_version") != "1.0.0"
            or request.get("operation") != "reconstruct_control"
            or request.get("control_key") != f"fixed_descriptor_{descriptor_id:02d}"
            or request.get("control_mode") != "fixed_descriptor_uniform"
            or request.get("configuration_sha256") != expected_configuration
            or request.get("shared_bank_configuration_sha256") != bank
            or request.get("parameters") != {"descriptor_id": descriptor_id}
            or request_sha256 != canonical_sha256(unhashed_request)
            or record.get("stateful_lut_lookup_count") != 0
            or record.get("spatial_operator_recompute_count") != 0
            or record.get("analysis_grid_invocation_count") != 0
        ):
            raise CalibrationError(
                "native fixed-cache reconstruction record is invalid or stale"
            )

    non_ash_records = _native_callable_record_stream(
        adapter,
        "non_ash_cache_records",
    )
    non_ash_fields = {
        "schema_version",
        "artifact_kind",
        "cache_token",
        "cache_manifest_sha256",
        "rule_configuration",
        "rule_sha256",
        "output_frame_sha256",
        "target_route",
        "stateful_lut_lookup_count",
        "spatial_operator_recompute_count",
        "analysis_grid_invocation_count",
        "record_sha256",
    }
    for record in non_ash_records:
        _validate_self_hashed_native_record(
            record,
            label="native non-ASH cache reconstruction record",
        )
        rule = record.get("rule_configuration")
        if (
            set(record) != non_ash_fields
            or record.get("schema_version") != "1.0.0"
            or record.get("artifact_kind")
            != "p06_native_non_ash_cached_reconstruction"
            or record.get("cache_token") not in cache_tokens
            or record.get("cache_manifest_sha256") != record.get("cache_token")
            or not isinstance(rule, dict)
            or not rule
            or record.get("rule_sha256") != canonical_sha256(rule)
            or not _is_sha256(record.get("output_frame_sha256"))
            or record.get("target_route") not in ROUTES
            or record.get("stateful_lut_lookup_count") != 0
            or record.get("spatial_operator_recompute_count") != 0
            or record.get("analysis_grid_invocation_count") != 0
        ):
            raise CalibrationError(
                "native non-ASH cache reconstruction record is invalid or stale"
            )

    expected_fixed = _cache_reconstruction_proof_binding(
        "fixed",
        fixed_records,
    )
    expected_non_ash = _cache_reconstruction_proof_binding(
        "non_ash",
        non_ash_records,
    )
    if (
        output_cache.get("fixed_reconstruction_proof") != expected_fixed
        or output_cache.get("non_ash_reconstruction_proof")
        != expected_non_ash
    ):
        raise CalibrationError(
            "native output-cache proof binding differs from callable records"
        )
    fixed_record_sha256_values = {
        record["record_sha256"] for record in fixed_records
    }
    non_ash_record_sha256_values = {
        record["record_sha256"] for record in non_ash_records
    }

    all_control_records = _native_callable_record_stream(
        adapter,
        "control_runtime_records",
    )
    decoration_fields = {
        "control_cache_reused",
        "control_cache_origin_manifest_sha256",
        "control_cache_origin_proof_sha256",
        "current_call_analysis_grid_invocation_count",
        "current_call_spatial_operator_evaluation_count",
    }
    persisted_modes = {
        "fixed_descriptor_uniform",
        "conventional_uniform",
        "non_ash_selector_q15",
        "nearest_uniform",
        "p00_current_production_ash",
    }
    decorated_records = []
    for record in all_control_records:
        _validate_self_hashed_native_record(
            record,
            label="native control reconstruction record",
        )
        mode = record.get("control_mode")
        present = decoration_fields.intersection(record)
        if mode in persisted_modes:
            if present != decoration_fields:
                raise CalibrationError(
                    "persistable control record lacks complete cache decoration"
                )
            reused = record.get("control_cache_reused")
            if not isinstance(reused, bool):
                raise CalibrationError("control cache reuse flag is invalid")
            if reused:
                expected_counts = (0, 0)
            elif "fixed_cache_record_sha256" in record:
                if (
                    record.get("fixed_cache_record_sha256")
                    not in fixed_record_sha256_values
                ):
                    raise CalibrationError(
                        "fixed control cache record binding differs"
                    )
                expected_counts = (0, 0)
            elif "non_ash_cache_record_sha256" in record:
                if (
                    record.get("non_ash_cache_record_sha256")
                    not in non_ash_record_sha256_values
                ):
                    raise CalibrationError(
                        "non-ASH control cache record binding differs"
                    )
                expected_counts = (0, 0)
            elif mode in {
                "fixed_descriptor_uniform",
                "non_ash_selector_q15",
                "p00_current_production_ash",
            }:
                expected_counts = (1, 1)
            else:
                expected_counts = (0, 1)
            if (
                not _is_sha256(
                    record.get("control_cache_origin_manifest_sha256")
                )
                or not _is_sha256(
                    record.get("control_cache_origin_proof_sha256")
                )
                or (
                    record.get("current_call_analysis_grid_invocation_count"),
                    record.get(
                        "current_call_spatial_operator_evaluation_count"
                    ),
                )
                != expected_counts
            ):
                raise CalibrationError(
                    "control cache reuse proof or current-call counts differ"
                )
            decorated_records.append(record)
        elif present:
            raise CalibrationError(
                "candidate-bound control record carries forbidden cache decoration"
            )
    expected_control = _cache_reconstruction_proof_binding(
        "control",
        decorated_records,
    )
    if output_cache.get("control_reconstruction_proof") != expected_control:
        raise CalibrationError(
            "native control-cache proof binding differs from decorated records"
        )


def _route_quality_record_and_pass(
    route: str,
    *,
    corpus_rows: Sequence[Mapping[str, object]],
    fixture_rows: Sequence[Mapping[str, object]],
    quality: Mapping[str, object],
) -> Tuple[Mapping[str, object], bool]:
    raw_natural = [
        row
        for row in corpus_rows
        if row["target_route"] == route
        and row["comparison_domain"] == "engine_raw"
    ]
    per_source_values: Dict[str, List[float]] = {}
    for row in raw_natural:
        candidate = row["metrics_by_control"]["full_ash"]["y_psnr_db"]
        conventional = row["metrics_by_control"]["conventional"]["y_psnr_db"]
        per_source_values.setdefault(str(row["source_asset_id"]), []).append(
            float(candidate) - float(conventional)
        )
    if not per_source_values or any(
        len(values) != 3 for values in per_source_values.values()
    ):
        raise CalibrationError("route quality lacks three profiles per source")
    per_source = [
        {
            "source_asset_id": source_id,
            "delta_db": float(np.mean(values, dtype=np.float64)),
        }
        for source_id, values in per_source_values.items()
    ]
    raw_route_fixtures = [
        row
        for row in fixture_rows
        if row["target_route"] == route
        and row["comparison_domain"] == "engine_raw"
    ]
    ringing: List[float] = []
    ringing_increase: List[float] = []
    alias: List[float] = []
    alias_increase: List[float] = []
    chroma: List[float] = []
    chroma_increase: List[float] = []
    for row in raw_route_fixtures:
        candidate = row["metrics_by_control"]["full_ash"]
        conventional = row["metrics_by_control"]["conventional"]
        if row["fixture_kind"] == "ringing":
            candidate_value = max(
                float(candidate["ringing_overshoot"]),
                float(candidate["ringing_undershoot"]),
            )
            conventional_value = max(
                float(conventional["ringing_overshoot"]),
                float(conventional["ringing_undershoot"]),
            )
            ringing.append(candidate_value)
            ringing_increase.append(candidate_value - conventional_value)
        elif row["fixture_kind"] == "alias":
            candidate_value = float(candidate["alias_forbidden_band_ratio"])
            conventional_value = float(
                conventional["alias_forbidden_band_ratio"]
            )
            alias.append(candidate_value)
            alias_increase.append(candidate_value - conventional_value)
        elif row["fixture_kind"] == "chroma_displacement":
            candidate_value = float(candidate["chroma_displacement_pixels"])
            conventional_value = float(
                conventional["chroma_displacement_pixels"]
            )
            chroma.append(candidate_value)
            chroma_increase.append(candidate_value - conventional_value)
    if not all(
        (ringing, ringing_increase, alias, alias_increase, chroma, chroma_increase)
    ):
        raise CalibrationError("route quality analytic coverage is incomplete")
    record = {
        "target_route": route,
        "natural_domain_row_counts": {
            domain: sum(
                1
                for row in corpus_rows
                if row["target_route"] == route
                and row["comparison_domain"] == domain
            )
            for domain in ("engine_raw", "container_decoded")
        },
        "analytic_domain_row_counts": {
            domain: sum(
                1
                for row in fixture_rows
                if row["target_route"] == route
                and row["comparison_domain"] == domain
            )
            for domain in ("engine_raw", "container_decoded")
        },
        "per_source_engine_raw_y_psnr_delta_vs_conventional": per_source,
        "maximum_ringing_excursion": max(ringing),
        "maximum_ringing_increase": max(ringing_increase),
        "maximum_alias_ratio": max(alias),
        "maximum_alias_increase": max(alias_increase),
        "maximum_chroma_displacement_pixels": max(chroma),
        "maximum_chroma_displacement_increase_pixels": max(chroma_increase),
    }
    passed = (
        all(value > 0 for value in record["natural_domain_row_counts"].values())
        and all(value > 0 for value in record["analytic_domain_row_counts"].values())
        and all(
            row["delta_db"]
            >= quality["severe_regression"][
                "per_asset_y_psnr_delta_db_minimum"
            ]
            for row in per_source
        )
        and record["maximum_ringing_excursion"]
        <= quality["ringing"]["absolute_overshoot_maximum"]
        and record["maximum_ringing_excursion"]
        <= quality["ringing"]["absolute_undershoot_magnitude_maximum"]
        and record["maximum_ringing_increase"]
        <= quality["ringing"]["increase_over_best_conventional_maximum"]
        and record["maximum_alias_ratio"]
        <= quality["alias"]["forbidden_band_energy_ratio_maximum"]
        and record["maximum_alias_increase"]
        <= quality["alias"]["increase_over_best_conventional_maximum"]
        and record["maximum_chroma_displacement_pixels"]
        <= quality["chroma_displacement"]["absolute_pixels_maximum"]
        and record["maximum_chroma_displacement_increase_pixels"]
        <= quality["chroma_displacement"][
            "increase_over_best_conventional_pixels_maximum"
        ]
    )
    return record, passed


def _validate_state_and_grid_evidence(
    evidence: Mapping[str, object],
    *,
    cases: Sequence[Mapping[str, object]],
    evaluation: Mapping[str, object],
    compiler_evidence: Mapping[str, object],
    control_native_records: Sequence[Mapping[str, object]],
    tolerances: Mapping[str, object],
) -> Tuple[int, bool, bool, bool, Mapping[str, object]]:
    records = _validated_control_native_records(control_native_records)
    full_records: Dict[
        Tuple[str, str], List[Mapping[str, object]]
    ] = {}
    maximum_operator_evaluations = 0
    for record in records:
        summary = record.get("locked_runtime_summary")
        if record.get("control_mode") not in {"full_ash", "state_only"}:
            continue
        if not isinstance(summary, dict):
            raise CalibrationError("full/state native record has no runtime summary")
        maximum_operator_evaluations = max(
            maximum_operator_evaluations,
            int(summary["maximum_operator_evaluations"]),
        )
        if record.get("control_mode") != "full_ash":
            continue
        key = (
            str(record["input_frame_sha256"]),
            str(record["target_route"]),
        )
        full_records.setdefault(key, []).append(record)

    expected_invocations: List[Mapping[str, object]] = []
    route_histograms: Dict[str, Dict[int, int]] = {
        route: {} for route in ROUTES
    }
    for case in cases:
        key = (
            str(case["input_frame_sha256"]),
            str(case["target_route"]),
        )
        matching = full_records.get(key)
        if not matching:
            raise CalibrationError(
                "candidate checks lack a full-ASH native record for one locked case"
            )
        native = matching.pop(0)
        summary = native["locked_runtime_summary"]
        analysis_count = int(summary["analysis_cell_count"])
        occupied_count = int(summary["occupied_analysis_cell_count"])
        dispatch_count = int(summary["dispatch_record_count"])
        route = str(case["target_route"])
        if (
            analysis_count <= 0
            or not 0 <= occupied_count <= analysis_count
            or dispatch_count
            != analysis_count * ROUTE_PHASE_PAIR_COUNTS[route]
        ):
            raise CalibrationError(
                "analysis-grid occupancy or phase cardinality is invalid"
            )
        expected_invocations.append(
            {
                "scope": case["witness_scope"],
                "source_or_fixture_id": case["source_or_fixture_id"],
                "degradation_profile_id": case["degradation_profile_id"],
                "target_route": case["target_route"],
                "input_frame_sha256": case["input_frame_sha256"],
                "analysis_cell_count": analysis_count,
                "occupied_analysis_cell_count": occupied_count,
                "dispatch_record_count": dispatch_count,
            }
        )
        histogram = route_histograms[str(case["target_route"])]
        for row in summary["state_histogram"]:
            state = int(row["state_raw_value"])
            histogram[state] = histogram.get(state, 0) + int(row["count"])
    if any(records for records in full_records.values()):
        raise CalibrationError(
            "candidate checks include full-ASH native records outside locked scope"
        )

    compiler_routes = {
        route["target_route"]: route
        for route in compiler_evidence["routes"]
    }
    raw_fixture_rows = [
        row
        for row in evaluation["analytic_fixture_results"]
        if row["comparison_domain"] == "engine_raw"
    ]
    expected_state_routes = []
    state_pass = True
    for route in ROUTES:
        histogram = route_histograms[route]
        histogram_rows = [
            {"state_raw_value": state, "count": histogram[state]}
            for state in sorted(histogram)
        ]
        observations = []
        for coordinate in (1, 2, 3, 4, 5, 6, 8):
            mask = 1 << (9 - coordinate)
            one_count = sum(
                count for state, count in histogram.items() if state & mask
            )
            zero_count = sum(histogram.values()) - one_count
            observations.append(
                {
                    "coordinate": coordinate,
                    "zero_count": zero_count,
                    "one_count": one_count,
                }
            )
        inactive_one_count = sum(
            count for state, count in histogram.items() if state & (1 << 2)
        )
        invalid_parity_count = sum(
            count
            for state, count in histogram.items()
            if (state & 1) != (bin(state >> 1).count("1") & 1)
        )
        ablation = next(
            (
                {
                    "fixture_id": row["fixture_id"],
                    "full_output_frame_sha256": row[
                        "control_output_sha256_values"
                    ]["full_ash"],
                    "state_only_output_frame_sha256": row[
                        "control_output_sha256_values"
                    ]["state_only"],
                }
                for row in raw_fixture_rows
                if row["target_route"] == route
                and row["control_output_sha256_values"]["full_ash"]
                != row["control_output_sha256_values"]["state_only"]
            ),
            None,
        )
        if ablation is None:
            raise CalibrationError(
                "state causality has no analytic full/state-only ablation witness"
            )
        sensitivity = compiler_routes[route]["state_conditioning_evidence"][
            "coordinate_sensitivity"
        ]
        expected_state_routes.append(
            {
                "target_route": route,
                "aggregated_state_histogram": histogram_rows,
                "active_coordinate_observations": observations,
                "inactive_coordinate_7_one_count": inactive_one_count,
                "invalid_coordinate_9_parity_count": invalid_parity_count,
                "compiler_coordinate_sensitivity": sensitivity,
                "analytic_ablation_witness": ablation,
            }
        )
        state_pass = state_pass and (
            all(
                row["zero_count"] > 0 and row["one_count"] > 0
                for row in observations
            )
            and inactive_one_count == 0
            and invalid_parity_count == 0
            and all(
                row["differing_dispatch_pair_count"] > 0
                for row in sensitivity
            )
        )
    expected_state = {"routes": expected_state_routes}
    if evidence.get("state_causality") != expected_state:
        raise CalibrationError(
            "state-causality evidence differs from native histograms and oracle"
        )

    route_occupancy = {}
    for route in ROUTES:
        route_rows = [
            row for row in expected_invocations if row["target_route"] == route
        ]
        route_occupancy[route] = {
            "occupied_cells": sum(
                int(row["occupied_analysis_cell_count"])
                for row in route_rows
            ),
            "total_cells": sum(
                int(row["analysis_cell_count"]) for row in route_rows
            ),
        }
    occupancy_pass = all(
        record["occupied_cells"] > 0
        and record["occupied_cells"] == record["total_cells"]
        for record in route_occupancy.values()
    )

    corpus_rows = evaluation["corpus_asset_results"]
    fixture_rows = evaluation["analytic_fixture_results"]
    quality = tolerances["quality"]
    expected_route_quality = []
    route_quality_pass = True
    for route in ROUTES:
        route_record, route_passed = _route_quality_record_and_pass(
            route,
            corpus_rows=corpus_rows,
            fixture_rows=fixture_rows,
            quality=quality,
        )
        expected_route_quality.append(route_record)
        route_quality_pass = route_quality_pass and route_passed
    expected_grid = {
        "invocations": expected_invocations,
        "route_occupancy": route_occupancy,
        "route_quality": {"routes": expected_route_quality},
    }
    if evidence.get("analysis_grid") != expected_grid:
        raise CalibrationError(
            "analysis-grid evidence differs from native counts and quality rows"
        )
    return (
        maximum_operator_evaluations,
        state_pass,
        occupancy_pass,
        route_quality_pass,
        route_occupancy,
    )


def _validate_performance_evidence(
    performance: Mapping[str, object],
    *,
    evaluation: Mapping[str, object],
    native_records: Sequence[Mapping[str, object]],
    control_native_records: Sequence[Mapping[str, object]],
    bound: BoundInputs,
) -> int:
    evidence = performance.get("evidence")
    if (
        not isinstance(evidence, dict)
        or performance.get("evidence_sha256") != canonical_sha256(evidence)
    ):
        raise CalibrationError("performance evidence hash is absent or invalid")
    expected_sources = _candidate_evidence_source_bindings(bound)
    policy_sha256 = bound.record("candidate_evidence_policy")["sha256"]
    _validate_candidate_evidence_header(
        evidence,
        bound=bound,
        label="performance",
    )

    raw_rows = [
        row
        for row in evaluation["corpus_asset_results"]
        if row["comparison_domain"] == "engine_raw"
    ]
    if len(raw_rows) != len(native_records):
        raise CalibrationError("performance natural/native row count differs")
    natural_invocations = []
    maximum_evaluations = 0
    ordinary_by_key: Dict[Tuple[str, str], List[Mapping[str, object]]] = {}
    for row, native in zip(raw_rows, native_records):
        width = int(native.get("output_width", 0))
        height = int(native.get("output_height", 0))
        pixels = width * height
        cells = int(native.get("analysis_cell_count", 0))
        maximum = int(native.get("maximum_operator_evaluations", 0))
        if (
            row["degraded_input_frame_sha256"]
            != native.get("input_frame_sha256")
            or row["target_route"] != native.get("target_route")
            or pixels <= 0
            or cells <= 0
            or maximum not in {1, 2}
        ):
            raise CalibrationError(
                "performance natural invocation differs from native runtime"
            )
        work = (cells + maximum * pixels) / pixels
        natural_invocations.append(
            {
                "source_asset_id": row["source_asset_id"],
                "degradation_profile_id": row["degradation_profile_id"],
                "degradation_profile_sha256": row[
                    "degradation_profile_sha256"
                ],
                "target_route": row["target_route"],
                "input_frame_sha256": row["degraded_input_frame_sha256"],
                "target_luma_width": width,
                "target_luma_height": height,
                "target_luma_pixel_count": pixels,
                "analysis_cell_count": cells,
                "maximum_operator_evaluations": maximum,
                "dispatch_work": work,
            }
        )
        ordinary_by_key.setdefault(
            (
                str(native["input_frame_sha256"]),
                str(native["target_route"]),
            ),
            [],
        ).append(native)
        maximum_evaluations = max(maximum_evaluations, maximum)
    if evidence.get("natural_invocations") != natural_invocations:
        raise CalibrationError(
            "performance natural evidence differs from native dimensions/work"
        )

    h07_by_key: Dict[Tuple[str, str], List[Mapping[str, object]]] = {}
    for record in _validated_control_native_records(control_native_records):
        if record.get("control_mode") == "h07_direct2x_then_lanczos3":
            h07_by_key.setdefault(
                (
                    str(record["input_frame_sha256"]),
                    str(record["target_route"]),
                ),
                [],
            ).append(record)
    h07_invocations = []
    for row, native in zip(raw_rows, native_records):
        if row["target_route"] != "direct-3over2":
            continue
        key = (
            str(row["degraded_input_frame_sha256"]),
            "direct-3over2",
        )
        matching = h07_by_key.get(key)
        if not matching:
            raise CalibrationError(
                "performance H07 evidence lacks a matching native control"
            )
        h07 = matching.pop(0)
        summary = h07.get("h07_direct2_runtime_summary")
        if not isinstance(summary, dict):
            raise CalibrationError("H07 native control lacks direct-2x summary")
        low_width = int(native.get("input_width", 0))
        low_height = int(native.get("input_height", 0))
        intermediate_width = low_width * 2
        intermediate_height = low_height * 2
        target_pixels = int(native["output_width"]) * int(native["output_height"])
        analysis_cells = int(summary.get("analysis_cell_count", 0))
        intermediate_pixels = intermediate_width * intermediate_height
        if min(low_width, low_height, target_pixels, analysis_cells) <= 0:
            raise CalibrationError("H07 performance dimensions are invalid")
        work = (
            analysis_cells
            + 2 * intermediate_pixels
            + 12 * target_pixels
        ) / target_pixels
        h07_invocations.append(
            {
                "source_asset_id": row["source_asset_id"],
                "degradation_profile_id": row["degradation_profile_id"],
                "input_frame_sha256": row["degraded_input_frame_sha256"],
                "low_resolution_luma_width": low_width,
                "low_resolution_luma_height": low_height,
                "direct2_analysis_cell_count": analysis_cells,
                "direct2_intermediate_luma_width": intermediate_width,
                "direct2_intermediate_luma_height": intermediate_height,
                "target_luma_pixel_count": target_pixels,
                "h07_dispatch_work": work,
            }
        )
    if evidence.get("h07_invocations") != h07_invocations:
        raise CalibrationError(
            "performance H07 evidence differs from native dimensions/work"
        )
    natural_sum = sum(
        float(row["dispatch_work"]) for row in natural_invocations
    )
    h07_sum = sum(float(row["h07_dispatch_work"]) for row in h07_invocations)
    arithmetic = {
        "natural_dispatch_work_sum": natural_sum,
        "natural_invocation_count": len(natural_invocations),
        "h07_dispatch_work_sum": h07_sum,
        "h07_invocation_count": len(h07_invocations),
    }
    if evidence.get("arithmetic") != arithmetic:
        raise CalibrationError("performance arithmetic evidence differs")

    policy = bound.documents["candidate_evidence_policy"]["performance_estimate"]
    dispatch_cost = natural_sum / len(natural_invocations)
    h07_cost = h07_sum / len(h07_invocations)
    production_fps = float(policy["production_frames_per_second"])
    expected = {
        "estimate_kind": policy["estimate_kind"],
        "estimate_method": policy["estimate_method"],
        "estimate_model": policy["estimate_model"],
        "estimate_source_artifact_sha256_values": [
            policy_sha256,
            *[record["sha256"] for record in expected_sources],
        ],
        "preregistered_production_estimate_same_machine_speedup": policy[
            "same_machine_speedup"
        ],
        "preregistered_production_estimate_frames_per_second": production_fps,
        "preregistered_production_estimate_dispatch_cost": dispatch_cost,
        "preregistered_production_estimate_full_frame_cpu_reconstruction_loops": policy[
            "full_frame_cpu_reconstruction_loops"
        ],
        "preregistered_production_estimate_runtime_leaf_tree_generations_per_frame": policy[
            "runtime_leaf_tree_generations_per_frame"
        ],
        "preregistered_production_estimate_candidate_evaluations_per_output_cell": policy[
            "candidate_evaluations_per_output_cell"
        ],
        "preregistered_production_estimate_wait_until_completed_calls": policy[
            "production_wait_until_completed_calls"
        ],
        "preregistered_production_estimate_avoidable_full_frame_gpu_readbacks_per_frame": policy[
            "avoidable_full_frame_gpu_readbacks_per_frame"
        ],
        "preregistered_production_estimate_default_in_flight_frames": policy[
            "default_in_flight_frames"
        ],
        "h07_control_estimate_frames_per_second": (
            production_fps * dispatch_cost / h07_cost
        ),
        "h07_control_estimate_dispatch_cost": h07_cost,
        "calibration_estimate_relative_error": policy[
            "calibration_estimate_relative_error_bound"
        ],
        "evidence": evidence,
        "evidence_sha256": canonical_sha256(evidence),
    }
    if performance != expected:
        raise CalibrationError(
            "published performance estimates differ from preregistered formulas"
        )
    return maximum_evaluations


def _validate_candidate_checks_and_performance(
    evaluation: Mapping[str, object],
    *,
    adapter: CandidateAdapter,
    bound: BoundInputs,
    native_records: Sequence[Mapping[str, object]],
    tracked_control_calls: Sequence[Mapping[str, object]],
    control_native_records: Sequence[Mapping[str, object]],
) -> None:
    checks = evaluation.get("checks")
    if not isinstance(checks, dict) or not isinstance(checks.get("evidence"), dict):
        raise CalibrationError("candidate checks have no canonical evidence")
    evidence = checks["evidence"]
    if checks.get("evidence_sha256") != canonical_sha256(evidence):
        raise CalibrationError("candidate checks evidence hash is invalid")
    _validate_candidate_evidence_header(
        evidence,
        bound=bound,
        label="candidate checks",
    )
    output_cache = evidence.get("output_cache")
    if not isinstance(output_cache, dict):
        raise CalibrationError("candidate checks have no output-cache evidence")
    _validate_output_cache_evidence(
        output_cache,
        adapter=adapter,
        expected_preparation_count=sum(
            1
            for row in evaluation["corpus_asset_results"]
            if row["comparison_domain"] == "engine_raw"
        )
        + sum(
            1
            for row in evaluation["analytic_fixture_results"]
            if row["comparison_domain"] == "engine_raw"
        ),
    )

    compiler_evidence = evidence.get("candidate_compiler_evidence")
    if not isinstance(compiler_evidence, dict):
        raise CalibrationError("candidate compiler evidence is absent")
    compiler_maximum = _validate_candidate_compiler_evidence(
        compiler_evidence,
        adapter=adapter,
    )
    cases = _candidate_check_cases(evaluation)
    operator_evidence = evidence.get("operator_distinctness")
    if not isinstance(operator_evidence, dict):
        raise CalibrationError("operator-distinctness evidence is absent")
    _validate_operator_distinctness_evidence(
        operator_evidence,
        cases=cases,
        tracked_control_calls=tracked_control_calls,
    )
    (
        control_maximum,
        state_causality,
        analysis_grid_occupancy,
        analysis_grid_route_quality,
        route_occupancy,
    ) = _validate_state_and_grid_evidence(
        evidence,
        cases=cases,
        evaluation=evaluation,
        compiler_evidence=compiler_evidence,
        control_native_records=control_native_records,
        tolerances=bound.documents["metric_performance_tolerances"],
    )
    performance_maximum = _validate_performance_evidence(
        evaluation["performance"],
        evaluation=evaluation,
        native_records=native_records,
        control_native_records=control_native_records,
        bound=bound,
    )
    ordinary_maximum = max(
        (int(record.get("maximum_operator_evaluations", 0)) for record in native_records),
        default=0,
    )
    estimated_maximum = max(
        compiler_maximum,
        control_maximum,
        performance_maximum,
        ordinary_maximum,
    )
    compiler_invariants = all(
        record.get("runtime_leaf_tree_generations") == 0
        and record.get("runtime_path_generations") == 0
        and record.get("per_frame_lut_load_count") == 0
        and record.get("loaded_lut_instance_count") == 1
        and record.get("route_lut_whole_file_sha256")
        == adapter.configuration["route_luts"][record["target_route"]][
            "whole_file_sha256"
        ]
        for record in native_records
    ) and estimated_maximum <= 2
    expected_checks = {
        "compiler_invariants": compiler_invariants,
        "operator_distinctness": True,
        "state_causality": state_causality,
        "analysis_grid_route_quality": analysis_grid_route_quality,
        "analysis_grid_occupancy": analysis_grid_occupancy,
        "estimated_candidate_count_maximum": estimated_maximum,
        "route_occupancy": route_occupancy,
        "evidence": evidence,
        "evidence_sha256": canonical_sha256(evidence),
    }
    if checks != expected_checks:
        raise CalibrationError(
            "published check predicates differ from independently recomputed evidence"
        )


def _validate_analytic_fixture_frame_hashes(
    row: Mapping[str, object],
    *,
    definition: Mapping[str, object],
    degradation_policy: Mapping[str, object],
) -> None:
    """Cross-bind the pre-420 reference and post-420 native input independently."""

    _, degraded_reference, _ = locked_analytic_fixture_frames(
        definition,
        degradation_policy,
    )
    degraded_reference_sha256 = frame_sha256(degraded_reference)
    if degraded_reference_sha256 != definition.get("low_resolution_frame_sha256"):
        raise CalibrationError(
            "analytic degraded-reference bytes differ from the locked fixture"
        )
    if row.get("degraded_reference_frame_sha256") != degraded_reference_sha256:
        raise CalibrationError(
            "analytic degraded-reference frame hash differs from pre-420 bytes"
        )

    _, native_input = _round_trip_locked_bt709_video_range_nv12(
        degraded_reference
    )
    if row.get("input_frame_sha256") != frame_sha256(native_input):
        raise CalibrationError(
            "analytic input frame hash differs from post-420 native bytes"
        )


def _native_control_key_for_result(
    result_key: str,
    identities: Mapping[str, object],
) -> str:
    if result_key == "best_fixed":
        identity = identities.get("best_fixed")
        descriptor_id = (
            identity.get("descriptor_id") if isinstance(identity, dict) else None
        )
        if (
            not isinstance(descriptor_id, int)
            or isinstance(descriptor_id, bool)
            or descriptor_id not in range(16)
        ):
            raise CalibrationError("best-fixed identity has an invalid descriptor")
        return f"fixed_descriptor_{descriptor_id:02d}"
    if result_key == "conventional":
        identity = identities.get("conventional")
        algorithm_id = (
            identity.get("algorithm_id") if isinstance(identity, dict) else None
        )
        if algorithm_id not in CONVENTIONAL_ALGORITHM_IDS:
            raise CalibrationError(
                "conventional identity has an invalid algorithm"
            )
        return f"conventional_{CONVENTIONAL_ALGORITHM_IDS.index(algorithm_id)}"
    return result_key


def _validate_evaluation_shape(
    evaluation: Mapping[str, object],
    *,
    vector: Mapping[str, object],
    plan: Mapping[str, object],
    bound: BoundInputs,
    vector_hash: str,
    split: str,
    adapter: CandidateAdapter,
    samples: Sequence[Mapping[str, object]],
    tracked_calls: Sequence[Mapping[str, object]],
    native_records: Sequence[Mapping[str, object]],
    tracked_control_calls: Sequence[Mapping[str, object]],
    control_native_records: Sequence[Mapping[str, object]],
    degradation_cache: LockedDegradationCache,
    development_control_selection: Optional[ControlSelectionBundle],
    existing_stage_control_selection: Optional[ControlSelectionBundle],
    validation_candidate_evidence: Optional[
        ValidationCandidateEvidenceBinding
    ],
) -> None:
    if not isinstance(evaluation, dict):
        raise CalibrationError("candidate evaluator did not return an object")
    validate_schema(evaluation, SCHEMAS_ROOT / "candidate-evaluation-v1.schema.json")
    try:
        canonical_json_bytes(evaluation)
    except (TypeError, ValueError) as error:
        raise CalibrationError("candidate evaluation is not finite canonical JSON") from error
    if (
        evaluation.get("candidate_vector_sha256") != vector_hash
        or evaluation.get("split") != split
        or evaluation.get("candidate_id") != adapter.candidate_id
        or evaluation.get("adapter_configuration_sha256")
        != adapter.configuration_sha256
    ):
        raise CalibrationError("candidate evaluation identity is not cross-bound")
    expected_frozen_sha256 = (
        None
        if validation_candidate_evidence is None
        else validation_candidate_evidence.manifest_sha256
    )
    if (
        (split == "development") != (validation_candidate_evidence is None)
        or evaluation.get(
            "full_ash_development_candidates_frozen_sha256"
        )
        != expected_frozen_sha256
    ):
        raise CalibrationError(
            "candidate evaluation frozen-candidate binding is missing or stale"
        )
    if evaluation.get("runtime_evidence") != dict(adapter.configuration):
        raise CalibrationError("candidate runtime evidence differs from adapter configuration")
    identities = evaluation.get("comparison_identities")
    expected_bank_hash = shared_bank_configuration_sha256(vector, plan)
    if (
        not isinstance(identities, dict)
        or identities.get("shared_bank_configuration_sha256") != expected_bank_hash
        or identities.get("quality_policy_seed_sha256")
        != bound.record("quality_gate_policy_seed")["sha256"]
        or identities.get("baseline_ablation_contract_sha256")
        != bound.record("baseline_ablation_contract")["sha256"]
    ):
        raise CalibrationError("comparison identities are stale or not preregistered")
    for name in (
        "best_fixed",
        "conventional",
        "non_ash_selector",
        "state_only",
        "state_plus_branch",
        "h07_direct_3_over_2",
        "nearest_same_writer",
        "current_production_ash",
    ):
        identity = identities.get(name)
        if (
            not isinstance(identity, dict)
            or identity.get("shared_bank_configuration_sha256") != expected_bank_hash
        ):
            raise CalibrationError(f"comparison identity uses a stale shared bank: {name}")
    expected_control_configurations = {
        "best_fixed": canonical_sha256(
            {
                "control_id": "fixed-descriptor-uniform-v1",
                "descriptor_id": identities["best_fixed"].get("descriptor_id"),
                "shared_bank_configuration_sha256": expected_bank_hash,
            }
        ),
        "conventional": canonical_sha256(
            {
                "control_id": "uniform-conventional-selection-v1",
                "algorithm_id": identities["conventional"].get("algorithm_id"),
                "shared_bank_configuration_sha256": expected_bank_hash,
            }
        ),
        "non_ash_selector": canonical_sha256(
            {
                "selector_id": "continuous-linear-bank-selector-q15-v1",
                "rule_sha256": identities["non_ash_selector"].get("rule_sha256"),
                "shared_bank_configuration_sha256": expected_bank_hash,
            }
        ),
        "state_only": _state_only_configuration_sha256(vector_hash),
        "state_plus_branch": adapter.configuration_sha256,
        "h07_direct_3_over_2": canonical_sha256(
            {
                "control_id": "direct2x-then-lanczos3-control-v1",
                "candidate_adapter_configuration_sha256": adapter.configuration_sha256,
            }
        ),
        "nearest_same_writer": canonical_sha256(
            {
                "control_id": "nearest-same-writer-420v-v1",
                "shared_bank_configuration_sha256": expected_bank_hash,
            }
        ),
    }
    if any(
        identities[name].get("configuration_sha256") != expected
        for name, expected in expected_control_configurations.items()
    ):
        raise CalibrationError("control configuration hash is not deterministically bound")
    selection_artifacts = evaluation.get("control_selection_artifacts")
    if (
        existing_stage_control_selection is not None
        and selection_artifacts != existing_stage_control_selection.artifacts
    ):
        raise CalibrationError("evaluator changed a frozen stage control selection")
    if split == "validation" and development_control_selection is None:
        raise CalibrationError("validation lacks a frozen development control selection")
    result_field = (
        "development_results" if split == "development" else "validation_results"
    )
    expected_selection_stage = (
        "development_provisional"
        if split == "development"
        else "validation_final"
    )
    selection_specs = {
        "best_fixed": (
            "fixed-control-selection-v1.schema.json",
            list(range(16)),
            "descriptor_id",
            "provisional_descriptor_id"
            if split == "development"
            else "chosen_descriptor_id",
        ),
        "conventional": (
            "conventional-control-selection-v1.schema.json",
            list(CONVENTIONAL_ALGORITHM_IDS),
            "algorithm_id",
            "provisional_algorithm_id"
            if split == "development"
            else "chosen_algorithm_id",
        ),
    }
    if not isinstance(selection_artifacts, dict):
        raise CalibrationError("control-selection artifacts are absent")
    for name, (schema_name, candidate_ids, id_field, chosen_field) in selection_specs.items():
        embedded = selection_artifacts.get(name)
        if not isinstance(embedded, dict) or not isinstance(embedded.get("document"), dict):
            raise CalibrationError(f"{name} selection artifact is invalid")
        document = embedded["document"]
        validate_schema(document, SCHEMAS_ROOT / schema_name)
        if (
            embedded.get("sha256") != canonical_sha256(document)
            or identities[name]["selection_sha256"] != embedded["sha256"]
            or document["selection_stage"] != expected_selection_stage
            or document["shared_bank_configuration_sha256"] != expected_bank_hash
            or document["candidate_ids"] != candidate_ids
            or [record[id_field] for record in document[result_field]]
            != candidate_ids
            or document[chosen_field]
            != identities[name]["descriptor_id" if name == "best_fixed" else "algorithm_id"]
            or document[chosen_field]
            != _lexicographic_control_winner(
                document[result_field], id_field=id_field
            )
            or split == "validation"
            and document["development_selection_sha256"]
            != development_control_selection.artifacts[name]["sha256"]
        ):
            raise CalibrationError(f"{name} selection is incomplete, mixed, or unbound")
    non_ash_embedded = selection_artifacts.get("non_ash_selector")
    if not isinstance(non_ash_embedded, dict) or not isinstance(
        non_ash_embedded.get("document"), dict
    ):
        raise CalibrationError("non-ASH selection artifact is invalid")
    non_ash_document = non_ash_embedded["document"]
    validate_schema(
        non_ash_document,
        SCHEMAS_ROOT / "non-ash-selector-selection-v1.schema.json",
    )
    selected_rule_field = (
        "development_terminal_rule_sha256"
        if split == "development"
        else "selected_rule_sha256"
    )
    selected_configuration_field = (
        "development_terminal_rule_configuration"
        if split == "development"
        else "selected_rule_configuration"
    )
    if (
        non_ash_embedded.get("sha256") != canonical_sha256(non_ash_document)
        or identities["non_ash_selector"]["selection_sha256"]
        != non_ash_embedded["sha256"]
        or identities["non_ash_selector"]["rule_sha256"]
        != non_ash_document[selected_rule_field]
        or non_ash_document["selection_stage"] != expected_selection_stage
        or non_ash_document["shared_bank_configuration_sha256"]
        != expected_bank_hash
        or set(non_ash_document[selected_configuration_field])
        != set(
            bound.documents["baseline_ablation_contract"]["non_ash_selector"]
            ["coordinates"]["order"]
        )
    ):
        raise CalibrationError("non-ASH rule/search evidence is incomplete or stale")
    if split == "validation":
        winner = _lexicographic_control_winner(
            non_ash_document["validation_results"],
            id_field="stable_candidate_id",
        )
        selected_result = next(
            result
            for result in non_ash_document["validation_results"]
            if result["stable_candidate_id"] == winner
        )
        if (
            len(non_ash_document["validation_results"])
            != non_ash_document["validation_candidate_count"]
            or selected_result["rule_sha256"]
            != non_ash_document["selected_rule_sha256"]
            or selected_result["rule_configuration"]
            != non_ash_document["selected_rule_configuration"]
            or non_ash_document["development_selection_sha256"]
            != development_control_selection.artifacts["non_ash_selector"][
                "sha256"
            ]
            or non_ash_document["development_terminal_rule_sha256"]
            != development_control_selection.artifacts["non_ash_selector"][
                "document"
            ]["development_terminal_rule_sha256"]
        ):
            raise CalibrationError("non-ASH validation selection tuple or count differs")
    expected_cases = []
    for sample in samples:
        for profile in spatial_degradation_profiles(bound, str(sample["target_route"])):
            expected_cases.append(
                {
                    **sample,
                    "degradation_profile_id": profile["id"],
                    "degradation_profile_sha256": canonical_sha256(profile),
                }
            )
    rows = evaluation.get("corpus_asset_results")
    if not isinstance(rows, list):
        raise CalibrationError("candidate evaluation corpus rows are absent")
    rows_by_domain: Dict[str, List[Mapping[str, object]]] = {
        "engine_raw": [],
        "container_decoded": [],
    }
    for row in rows:
        domain = row.get("comparison_domain")
        if domain not in rows_by_domain:
            raise CalibrationError("candidate row has an invalid comparison domain")
        rows_by_domain[domain].append(row)
    raw_output_by_case = {
        (case["source_asset_id"], case["degradation_profile_id"]): tracked[
            "output_frame_sha256"
        ]
        for case, tracked in zip(expected_cases, tracked_calls)
    }
    expected_case_keys = [
        (case["source_asset_id"], case["degradation_profile_id"])
        for case in expected_cases
    ]
    for domain, domain_rows in rows_by_domain.items():
        if [
            (row.get("source_asset_id"), row.get("degradation_profile_id"))
            for row in domain_rows
        ] != expected_case_keys:
            raise CalibrationError(f"{domain} rows do not preserve exact sample order")
        for row, case in zip(domain_rows, expected_cases):
            outputs = row["control_output_sha256_values"]
            writer_evidence = row["writer_evidence_sha256_values"]
            metrics = row["metrics_by_control"]
            route_is_h07 = case.get("target_route") == "direct-3over2"
            if (
                row.get("source_family_id") != case.get("source_family_id")
                or row.get("categories") != case.get("categories")
                or row.get("target_route") != case.get("target_route")
                or row.get("degradation_profile_sha256")
                != case.get("degradation_profile_sha256")
                or row.get("comparison_identities") != identities
                or (outputs["h07_direct_3_over_2"] is not None) != route_is_h07
                or (metrics["h07_direct_3_over_2"] is not None) != route_is_h07
                or outputs["full_ash"] != outputs["state_plus_branch"]
                or metrics["full_ash"] != metrics["state_plus_branch"]
                or set(writer_evidence) != set(outputs)
                or domain == "engine_raw"
                and outputs["full_ash"]
                != raw_output_by_case[
                    (case["source_asset_id"], case["degradation_profile_id"])
                ]
            ):
                raise CalibrationError("candidate asset/control evidence disagrees with locked metadata")
            for control_key, output_sha256 in outputs.items():
                expected_writer_evidence = (
                    domain == "container_decoded" and output_sha256 is not None
                )
                if (
                    writer_evidence[control_key] is not None
                ) != expected_writer_evidence:
                    raise CalibrationError(
                        "corpus writer evidence is missing or assigned to the wrong domain"
                    )
            for bundle in (value for value in metrics.values() if value is not None):
                writer_value = bundle["writer_y_psnr_contribution_db"]
                if (domain == "engine_raw" and writer_value is not None) or (
                    domain == "container_decoded" and writer_value is None
                ):
                    raise CalibrationError("writer contribution is assigned to the wrong domain")

    fixture_definitions = bound.documents["analytic_fixture_manifest"]["fixtures"]
    fixture_rows = evaluation.get("analytic_fixture_results")
    if not isinstance(fixture_rows, list):
        raise CalibrationError("candidate analytic-fixture rows are absent")
    analytic_metric_fields = {
        "edge_profile": {"edge_location_error_pixels"},
        "ringing": {"ringing_overshoot", "ringing_undershoot"},
        "thin_line": {
            "thin_line_retention_ratio",
            "thin_line_false_side_lobe_energy",
        },
        "alias": {"alias_forbidden_band_ratio"},
        "chroma_displacement": {"chroma_displacement_pixels"},
    }
    all_analytic_fields = set().union(*analytic_metric_fields.values())
    for domain in ("engine_raw", "container_decoded"):
        domain_fixture_rows = [
            row for row in fixture_rows if row.get("comparison_domain") == domain
        ]
        if [row.get("fixture_id") for row in domain_fixture_rows] != [
            definition["fixture_id"] for definition in fixture_definitions
        ]:
            raise CalibrationError(
                f"{domain} analytic rows do not preserve the manifest order"
            )
        for row, definition in zip(domain_fixture_rows, fixture_definitions):
            _validate_analytic_fixture_frame_hashes(
                row,
                definition=definition,
                degradation_policy=bound.documents["degradation_policy"],
            )
            outputs = row["control_output_sha256_values"]
            writer_evidence = row["writer_evidence_sha256_values"]
            metrics = row["metrics_by_control"]
            route_is_h07 = definition["target_route"] == "direct-3over2"
            if (
                row.get("fixture_kind") != definition["fixture_kind"]
                or row.get("fixture_definition_sha256")
                != canonical_sha256(definition)
                or row.get("analytic_fixture_manifest_sha256")
                != bound.documents["analytic_fixture_manifest"]["manifest_sha256"]
                or row.get("target_route") != definition["target_route"]
                or row.get("comparison_identities") != identities
                or (outputs["h07_direct_3_over_2"] is not None) != route_is_h07
                or (metrics["h07_direct_3_over_2"] is not None) != route_is_h07
                or outputs["full_ash"] != outputs["state_plus_branch"]
                or metrics["full_ash"] != metrics["state_plus_branch"]
                or set(writer_evidence) != set(outputs)
            ):
                raise CalibrationError("analytic fixture identity or ablation differs")
            for control_key, output_sha256 in outputs.items():
                expected_writer_evidence = (
                    domain == "container_decoded" and output_sha256 is not None
                )
                if (
                    writer_evidence[control_key] is not None
                ) != expected_writer_evidence:
                    raise CalibrationError(
                        "analytic writer evidence is missing or assigned to the wrong domain"
                    )
            required_fields = analytic_metric_fields[definition["fixture_kind"]]
            for bundle in (value for value in metrics.values() if value is not None):
                nonnull = {
                    field for field in all_analytic_fields if bundle[field] is not None
                }
                if nonnull != required_fields:
                    raise CalibrationError(
                        "analytic row populates metrics outside its locked support"
                    )

    declared_control_calls = evaluation.get("control_runtime_invocations")
    if (
        not isinstance(declared_control_calls, list)
        or len(declared_control_calls) != len(tracked_control_calls)
    ):
        raise CalibrationError("native control invocation count is not exact")
    for declared, tracked in zip(declared_control_calls, tracked_control_calls):
        expected_declared = {
            **tracked,
            "native_summary_sha256": declared.get("native_summary_sha256"),
        }
        if declared != expected_declared:
            raise CalibrationError("declared control invocation differs from tracker")
    if adapter.configuration.get("implementation_role") == "production_swift":
        if len(control_native_records) != len(tracked_control_calls):
            raise CalibrationError("native control summaries are incomplete")
        for declared, native in zip(declared_control_calls, control_native_records):
            if declared["native_summary_sha256"] != canonical_sha256(native):
                raise CalibrationError("native control summary hash differs")

    configuration_by_control = {
        "full_ash": adapter.configuration_sha256,
        **{
            name: identities[name]["configuration_sha256"]
            for name in (
                "best_fixed",
                "conventional",
                "non_ash_selector",
                "state_only",
                "h07_direct_3_over_2",
                "nearest_same_writer",
                "current_production_ash",
            )
        },
    }
    tracked_control_outputs = {
        (
            call["request"].get("control_key"),
            call["request"].get("configuration_sha256"),
            call["output_frame_sha256"],
        )
        for call in tracked_control_calls
    }
    raw_rows = [row for row in rows if row["comparison_domain"] == "engine_raw"]
    raw_fixture_rows = [
        row
        for row in fixture_rows
        if row["comparison_domain"] == "engine_raw"
    ]
    for row in raw_rows:
        for control_key, output_hash in row["control_output_sha256_values"].items():
            if control_key in {"full_ash", "state_plus_branch"} or output_hash is None:
                continue
            if (
                _native_control_key_for_result(control_key, identities),
                configuration_by_control[control_key],
                output_hash,
            ) not in tracked_control_outputs:
                raise CalibrationError("corpus control output has no tracked native call")
    for row in raw_fixture_rows:
        for control_key, output_hash in row["control_output_sha256_values"].items():
            if control_key == "state_plus_branch" or output_hash is None:
                continue
            if (
                _native_control_key_for_result(control_key, identities),
                configuration_by_control[control_key],
                output_hash,
            ) not in tracked_control_outputs:
                raise CalibrationError("analytic control output has no tracked native call")
    invocations = evaluation.get("runtime_invocations")
    if not isinstance(invocations, list) or len(invocations) != len(expected_cases):
        raise CalibrationError(
            "candidate must invoke the adapter once per source and degradation profile"
        )
    if len(tracked_calls) != len(expected_cases):
        raise CalibrationError(
            "evaluator did not call CandidateAdapter.reconstruct for every corpus case"
        )
    cache_records = degradation_cache.evidence()["entries"]
    degraded_by_case: Dict[Tuple[str, str], str] = {}
    for record in cache_records:
        degraded_by_case[(record["source_asset_id"], record["profile_id"])] = record[
            "degraded_frame_sha256"
        ]
    for row in rows:
        if row["degraded_input_frame_sha256"] != degraded_by_case.get(
            (row["source_asset_id"], row["degradation_profile_id"])
        ):
            raise CalibrationError("corpus row is not bound to cached degradation bytes")
    for case, declared, tracked in zip(expected_cases, invocations, tracked_calls):
        source_id = case["source_asset_id"]
        profile_id = case["degradation_profile_id"]
        if (
            declared.get("source_asset_id") != source_id
            or declared.get("degradation_profile_id") != profile_id
            or declared.get("degradation_profile_sha256")
            != case["degradation_profile_sha256"]
            or declared.get("target_route") != tracked["target_route"]
            or declared.get("input_frame_sha256") != tracked["input_frame_sha256"]
            or declared.get("output_frame_sha256") != tracked["output_frame_sha256"]
            or declared.get("adapter_configuration_sha256")
            != adapter.configuration_sha256
            or declared.get("input_frame_sha256")
            != degraded_by_case.get((source_id, profile_id))
        ):
            raise CalibrationError("runtime invocation is not bound to tracked locked pixels")
    if adapter.configuration.get("implementation_role") == "production_swift":
        if len(native_records) != len(expected_cases):
            raise CalibrationError("native Swift callable did not expose one summary per case")
        for declared, tracked, native in zip(invocations, tracked_calls, native_records):
            route_binding = adapter.configuration["route_luts"][tracked["target_route"]]
            expected_native = {
                "input_frame_sha256": tracked["input_frame_sha256"],
                "output_frame_sha256": tracked["output_frame_sha256"],
                "configuration_id": adapter.configuration["configuration_id"],
                "mapping_sha256": adapter.configuration["mapping_sha256"],
                "operator_bank_sha256": adapter.configuration["operator_bank_sha256"],
                "metric_policy_sha256": adapter.configuration["metric_policy_sha256"],
                "compiler_inputs_sha256": adapter.configuration["compiler_inputs_sha256"],
                "calibration_plan_sha256": adapter.configuration["calibration_plan_sha256"],
                "corpus_lock_bundle_sha256": adapter.configuration["corpus_lock_bundle_sha256"],
                "shared_bank_configuration_sha256": adapter.configuration[
                    "shared_bank_configuration_sha256"
                ],
                "route_lut_whole_file_sha256": route_binding["whole_file_sha256"],
                "route_lut_payload_sha256": route_binding["payload_sha256"],
                "target_route": tracked["target_route"],
                "candidate_lut_runtime_manifest_sha256": adapter.configuration[
                    "candidate_lut_runtime_manifest_sha256"
                ],
            }
            if (
                any(native.get(field) != value for field, value in expected_native.items())
                or native.get("runtime_leaf_tree_generations") != 0
                or native.get("runtime_path_generations") != 0
                or native.get("per_frame_lut_load_count") != 0
                or native.get("loaded_lut_instance_count") != 1
                or native.get("cpu_reference_analysis_traversals") != 1
                or native.get("cpu_reference_full_frame_loop_count") != 3
                or native.get("production_metal_constraint_satisfied") is not False
                or declared.get("native_summary_sha256") != canonical_sha256(native)
            ):
                raise CalibrationError("native Swift summary does not cross-bind runtime bytes")
    runtime_summary = evaluation.get("runtime_summary")
    if (
        not isinstance(runtime_summary, dict)
        or runtime_summary.get("runtime_leaf_tree_generations") != 0
        or runtime_summary.get("runtime_path_generations") != 0
    ):
        raise CalibrationError("runtime summary does not prove zero forbidden generation paths")
    if adapter.configuration.get("implementation_role") == "production_swift" and (
        runtime_summary.get("measured_cpu_reference_analysis_traversals") != 1
        or runtime_summary.get("measured_cpu_reference_full_frame_reconstruction_loops") != 3
        or runtime_summary.get("production_metal_constraint_satisfied") is not False
        or runtime_summary.get("loaded_lut_instance_count") != 1
        or runtime_summary.get("per_frame_lut_load_count") != 0
        or runtime_summary.get("configuration_id")
        != adapter.configuration.get("configuration_id")
        or runtime_summary.get("chroma_convention")
        != "ASHLockedCandidateAdapterBridgeV2.centeredChroma_subtract_0.5_once"
    ):
        raise CalibrationError("runtime summary disagrees with the locked Swift CPU boundary")
    _validate_candidate_checks_and_performance(
        evaluation,
        adapter=adapter,
        bound=bound,
        native_records=native_records,
        tracked_control_calls=tracked_control_calls,
        control_native_records=control_native_records,
    )


def _validate_dispatch_measurement_evidence(
    evaluation: Mapping[str, object],
    *,
    vector: Mapping[str, object],
    plan: Mapping[str, object],
    adapter: CandidateAdapter,
    bound: BoundInputs,
    resolver: Callable[[Mapping[str, object]], Mapping[str, object]],
) -> None:
    measurement = evaluation["dispatch_measurement"]
    if evaluation["split"] == "development":
        estimated = _require_finite_number(
            evaluation["performance"][
                "preregistered_production_estimate_dispatch_cost"
            ],
            "development static dispatch estimate",
        )
        expected_model_input = canonical_sha256(
            {
                "cost_model_id": measurement["cost_model_id"],
                "candidate_vector_sha256": candidate_vector_sha256(vector, plan),
                "shared_bank_configuration_sha256": shared_bank_configuration_sha256(
                    vector, plan
                ),
                "estimated_dispatch_cost": estimated,
            }
        )
        if (
            measurement["evidence_stage"] != "development_static_model"
            or measurement["validation_accessed"] is not False
            or measurement["estimated_dispatch_cost"] != estimated
            or measurement["cost_model_input_sha256"] != expected_model_input
        ):
            raise CalibrationError(
                "development dispatch estimate is not static or candidate-bound"
            )
        return
    bindings = measurement["measurement_evidence_bindings"]
    declared_records = measurement["measurement_records"]
    if len(bindings) != 1 or len(declared_records) != 1:
        raise CalibrationError("exactly one canonical dispatch measurement is required")
    binding = bindings[0]
    document = resolver(binding)
    if document != declared_records[0]:
        raise CalibrationError("dispatch measurement bytes differ from embedded evidence")
    validate_dispatch_measurement_document(document)

    expected_bank_hash = shared_bank_configuration_sha256(vector, plan)
    expected_vector_hash = candidate_vector_sha256(vector, plan)
    input_bindings = document["input_bindings"]
    common_expected = {
        "candidate_vector_sha256": expected_vector_hash,
        "shared_bank_configuration_sha256": expected_bank_hash,
        "calibration_plan_sha256": bound.record("calibration_plan")["sha256"],
        "corpus_lock_bundle_sha256": corpus_lock_bundle_sha256(bound),
        "validation_sample_lock_sha256": bound.record("validation_sample_lock")[
            "sha256"
        ],
        "degradation_policy_sha256": bound.record("degradation_policy")["sha256"],
    }
    invocations = evaluation["runtime_invocations"]
    expected_matrix = sorted(
        (
            {
                "source_asset_id": invocation["source_asset_id"],
                "target_route": invocation["target_route"],
                "degradation_profile_id": invocation["degradation_profile_id"],
                "degradation_profile_sha256": invocation[
                    "degradation_profile_sha256"
                ],
            }
            for invocation in invocations
        ),
        key=lambda record: (
            record["source_asset_id"],
            record["degradation_profile_id"],
        ),
    )
    common_expected["validation_sample_profile_matrix_sha256"] = canonical_sha256(
        expected_matrix
    )
    if any(input_bindings.get(key) != value for key, value in common_expected.items()):
        raise CalibrationError("dispatch measurement is stale for the candidate or corpus")

    if adapter.configuration.get("implementation_role") == "production_swift":
        production_expected = {
            "configuration_id": adapter.configuration["configuration_id"],
            "mapping_sha256": adapter.configuration["mapping_sha256"],
            "operator_bank_sha256": adapter.configuration["operator_bank_sha256"],
            "metric_policy_sha256": adapter.configuration["metric_policy_sha256"],
            "compiler_inputs_sha256": adapter.configuration["compiler_inputs_sha256"],
            "raw_output_contract_sha256": adapter.configuration[
                "raw_output_contract_sha256"
            ],
            "full_control_configuration_sha256": adapter.configuration[
                "full_control_configuration_sha256"
            ],
        }
        environment = document["environment"]
        swift_cli = adapter.configuration["swift_cli"]
        if (
            any(
                input_bindings.get(key) != value
                for key, value in production_expected.items()
            )
            or environment["executable_sha256"] != swift_cli["executable_sha256"]
            or environment["source_manifest_sha256"]
            != swift_cli["source_manifest_sha256"]
        ):
            raise CalibrationError("dispatch measurement is stale for the Swift runtime")

    samples = document["samples"]
    if len(samples) != len(invocations):
        raise CalibrationError("dispatch measurement sample count differs from validation")
    invocation_by_key = {
        (invocation["source_asset_id"], invocation["degradation_profile_id"]): invocation
        for invocation in invocations
    }
    for sample in samples:
        invocation = invocation_by_key.get(
            (sample["source_asset_id"], sample["degradation_profile_id"])
        )
        if invocation is None:
            raise CalibrationError("dispatch sample has no corpus runtime invocation")
        route = invocation["target_route"]
        expected_lut_hash = None
        if adapter.configuration.get("implementation_role") == "production_swift":
            expected_lut_hash = adapter.configuration["route_luts"][route][
                "whole_file_sha256"
            ]
        if (
            sample["source_asset_id"] != invocation["source_asset_id"]
            or sample["degradation_profile_id"]
            != invocation["degradation_profile_id"]
            or sample["degradation_profile_sha256"]
            != invocation["degradation_profile_sha256"]
            or sample["target_route"] != route
            or sample["input_frame_sha256"] != invocation["input_frame_sha256"]
            or sample["full_output_sha256"] != invocation["output_frame_sha256"]
            or (
                expected_lut_hash is not None
                and sample["lut_whole_file_sha256"] != expected_lut_hash
            )
        ):
            raise CalibrationError("dispatch timing sample is not bound to reconstructed bytes")

    p95 = document["aggregate"]["measured_validation_p95_percent"]
    if (
        measurement["evidence_stage"] != "validation_native_measurement"
        or measurement["measurement_method"]
        != "native-cpu-reference-precomputed-dispatch-control-p95-v1"
        or measurement["shared_bank_configuration_sha256"] != expected_bank_hash
        or measurement["full_ash_configuration_sha256"]
        != adapter.configuration_sha256
        or measurement["measured_validation_p95_percent"] != p95
        or measurement["measurement_run_ids"] != [document["run_id"]]
        or measurement["measurement_artifact_sha256_values"] != [binding["sha256"]]
    ):
        raise CalibrationError("dispatch measurement aggregate is not cross-bound")


def _bootstrap_rows(
    rows: Sequence[Mapping[str, object]],
    candidate_control: str,
    baseline_control: str,
    metric: str,
    *,
    replicates: int,
    seed: int,
) -> Mapping[str, object]:
    records = []
    for row in rows:
        metrics = row["metrics_by_control"]
        records.append(
            {
                "source_asset_id": row["source_asset_id"],
                "categories": row["categories"],
                "candidate": _require_finite_number(
                    metrics[candidate_control][metric],
                    f"{candidate_control} {metric}",
                ),
                "baseline": _require_finite_number(
                    metrics[baseline_control][metric],
                    f"{baseline_control} {metric}",
                ),
            }
        )
    return paired_bootstrap(records, replicates=replicates, seed=seed)


def _summarize_domain(
    rows: Sequence[Mapping[str, object]],
    fixture_rows: Sequence[Mapping[str, object]],
    evaluation: Mapping[str, object],
    tolerances: Mapping[str, object],
) -> Mapping[str, object]:
    paired = tolerances["quality"]["paired_bootstrap"]
    replicates = int(paired["replicates"])
    seed = int(paired["seed"])
    bootstraps = {
        "y_vs_fixed": _bootstrap_rows(
            rows, "full_ash", "best_fixed", "y_psnr_db",
            replicates=replicates, seed=seed,
        ),
        "y_vs_non_ash": _bootstrap_rows(
            rows, "full_ash", "non_ash_selector", "y_psnr_db",
            replicates=replicates, seed=seed,
        ),
        "y_vs_conventional": _bootstrap_rows(
            rows, "full_ash", "conventional", "y_psnr_db",
            replicates=replicates, seed=seed,
        ),
        "ms_ssim_vs_conventional": _bootstrap_rows(
            rows, "full_ash", "conventional", "y_ms_ssim",
            replicates=replicates, seed=seed,
        ),
        "y_vs_state_only": _bootstrap_rows(
            rows, "full_ash", "state_only", "y_psnr_db",
            replicates=replicates, seed=seed,
        ),
    }
    h07_rows = [row for row in rows if row["target_route"] == "direct-3over2"]
    if not h07_rows:
        raise CalibrationError("H07 requires a direct-3over2 case in every open split")
    bootstraps["h07_direct_vs_control"] = _bootstrap_rows(
        h07_rows,
        "full_ash",
        "h07_direct_3_over_2",
        "y_psnr_db",
        replicates=replicates,
        seed=seed,
    )
    bootstraps["h07_ms_ssim_direct_vs_control"] = _bootstrap_rows(
        h07_rows,
        "full_ash",
        "h07_direct_3_over_2",
        "y_ms_ssim",
        replicates=replicates,
        seed=seed,
    )
    per_source: Dict[str, Dict[str, List[float]]] = {}
    source_categories: Dict[str, set[str]] = {}
    source_families: Dict[str, str] = {}
    ringing_values = []
    ringing_increases = []
    alias_values = []
    alias_increases = []
    chroma_values = []
    chroma_increases = []
    for row in rows:
        metrics = row["metrics_by_control"]
        candidate = metrics["full_ash"]
        fixed = metrics["best_fixed"]
        non_ash = metrics["non_ash_selector"]
        conventional_metrics = metrics["conventional"]
        candidate_y = _require_finite_number(candidate["y_psnr_db"], "candidate Y PSNR")
        fixed_y = _require_finite_number(fixed["y_psnr_db"], "fixed Y PSNR")
        non_ash_y = _require_finite_number(non_ash["y_psnr_db"], "non-ASH Y PSNR")
        conventional = _require_finite_number(conventional_metrics["y_psnr_db"], "conventional Y PSNR")
        source_id = row["source_asset_id"]
        grouped = per_source.setdefault(
            source_id,
            {
                "fixed": [],
                "non_ash": [],
                "conventional": [],
                "ms_ssim": [],
            },
        )
        grouped["fixed"].append(candidate_y - fixed_y)
        grouped["non_ash"].append(candidate_y - non_ash_y)
        grouped["conventional"].append(candidate_y - conventional)
        grouped["ms_ssim"].append(
            _require_finite_number(candidate["y_ms_ssim"], "candidate MS-SSIM")
            - _require_finite_number(
                conventional_metrics["y_ms_ssim"], "conventional MS-SSIM"
            )
        )
        source_categories.setdefault(source_id, set()).update(row["categories"])
        existing_family = source_families.setdefault(
            source_id, row["source_family_id"]
        )
        if existing_family != row["source_family_id"]:
            raise CalibrationError("one source asset has multiple source-family IDs")

    for grouped in per_source.values():
        if any(len(values) != 3 for values in grouped.values()):
            raise CalibrationError(
                "each source must contribute exactly three degradation-profile rows"
            )
    source_means = {
        source_id: {
            name: float(np.mean(values, dtype=np.float64))
            for name, values in grouped.items()
        }
        for source_id, grouped in per_source.items()
    }
    y_fixed = [values["fixed"] for values in source_means.values()]
    y_non_ash = [values["non_ash"] for values in source_means.values()]
    conventional_y = [values["conventional"] for values in source_means.values()]
    ms_ssim = [values["ms_ssim"] for values in source_means.values()]
    category_deltas: Dict[str, List[float]] = {}
    category_families: Dict[str, set[str]] = {}
    for source_id, categories in source_categories.items():
        for category in categories:
            category_deltas.setdefault(category, []).append(
                source_means[source_id]["conventional"]
            )
            category_families.setdefault(category, set()).add(
                source_families[source_id]
            )

    for row in fixture_rows:
        candidate = row["metrics_by_control"]["full_ash"]
        conventional_metrics = row["metrics_by_control"]["conventional"]
        fixture_kind = row["fixture_kind"]
        if fixture_kind == "ringing":
            candidate_ring = max(
                _require_finite_number(
                    candidate["ringing_overshoot"], "ringing overshoot"
                ),
                _require_finite_number(
                    candidate["ringing_undershoot"], "ringing undershoot"
                ),
            )
            baseline_ring = max(
                _require_finite_number(
                    conventional_metrics["ringing_overshoot"],
                    "baseline ringing overshoot",
                ),
                _require_finite_number(
                    conventional_metrics["ringing_undershoot"],
                    "baseline ringing undershoot",
                ),
            )
            ringing_values.append(candidate_ring)
            ringing_increases.append(candidate_ring - baseline_ring)
        elif fixture_kind == "alias":
            alias = _require_finite_number(
                candidate["alias_forbidden_band_ratio"], "alias ratio"
            )
            alias_base = _require_finite_number(
                conventional_metrics["alias_forbidden_band_ratio"],
                "baseline alias ratio",
            )
            alias_values.append(alias)
            alias_increases.append(alias - alias_base)
        elif fixture_kind == "chroma_displacement":
            chroma = _require_finite_number(
                candidate["chroma_displacement_pixels"], "chroma displacement"
            )
            chroma_base = _require_finite_number(
                conventional_metrics["chroma_displacement_pixels"],
                "baseline chroma displacement",
            )
            chroma_values.append(chroma)
            chroma_increases.append(chroma - chroma_base)
    if not all(
        (
            ringing_values,
            ringing_increases,
            alias_values,
            alias_increases,
            chroma_values,
            chroma_increases,
        )
    ):
        raise CalibrationError("analytic artifact fixture coverage is incomplete")
    return {
        "mean_y_psnr_delta_vs_fixed_db": float(np.mean(y_fixed, dtype=np.float64)),
        "mean_y_psnr_delta_vs_non_ash_db": float(np.mean(y_non_ash, dtype=np.float64)),
        "mean_y_psnr_delta_vs_conventional_db": float(np.mean(conventional_y, dtype=np.float64)),
        "mean_ms_ssim_delta_vs_conventional": float(np.mean(ms_ssim, dtype=np.float64)),
        "maximum_ringing_excursion": max(ringing_values),
        "maximum_ringing_increase": max(ringing_increases),
        "maximum_alias_ratio": max(alias_values),
        "maximum_alias_increase": max(alias_increases),
        "maximum_chroma_displacement_pixels": max(chroma_values),
        "maximum_chroma_displacement_increase_pixels": max(chroma_increases),
        "minimum_per_asset_y_psnr_delta_db": min(conventional_y),
        "category_mean_y_psnr_deltas_db": {
            category: float(np.mean(values, dtype=np.float64))
            for category, values in sorted(category_deltas.items())
        },
        "category_source_family_counts": {
            category: len(families)
            for category, families in sorted(category_families.items())
        },
        "bootstraps": bootstraps,
        "estimated_dispatch_cost": _require_finite_number(
            evaluation["performance"]["preregistered_production_estimate_dispatch_cost"],
            "estimated dispatch cost",
        ),
    }


def summarize_evaluation(
    evaluation: Mapping[str, object],
    tolerances: Mapping[str, object],
) -> Mapping[str, object]:
    """Keep raw-engine and container-decoded statistics strictly separate."""

    rows = evaluation["corpus_asset_results"]
    fixture_rows = evaluation["analytic_fixture_results"]
    return {
        domain: _summarize_domain(
            [row for row in rows if row["comparison_domain"] == domain],
            [
                row
                for row in fixture_rows
                if row["comparison_domain"] == domain
            ],
            evaluation,
            tolerances,
        )
        for domain in ("engine_raw", "container_decoded")
    }


def _evaluation_feasible_domain(
    evaluation: Mapping[str, object],
    summary: Mapping[str, object],
    tolerances: Mapping[str, object],
) -> Tuple[bool, Tuple[str, ...]]:
    failures: List[str] = []
    checks = evaluation["checks"]
    for field in (
        "compiler_invariants",
        "operator_distinctness",
        "state_causality",
        "analysis_grid_route_quality",
        "analysis_grid_occupancy",
    ):
        if checks[field] is not True:
            failures.append(field)
    if int(checks["estimated_candidate_count_maximum"]) > 2:
        failures.append("candidate_count")
    occupancy = checks["route_occupancy"]
    for route in ROUTES:
        record = occupancy[route]
        if record["occupied_cells"] <= 0 or record["occupied_cells"] > record["total_cells"]:
            failures.append(f"occupancy:{route}")

    quality = tolerances["quality"]
    lower_bounds = quality["y_psnr_paired_delta_lower_bound_db"]
    for name, tolerance_name in (
        ("y_vs_fixed", "full_spatial_ash_vs_best_fixed_same_bank"),
        ("y_vs_non_ash", "full_spatial_ash_vs_non_ash_same_bank_selector"),
        ("y_vs_conventional", "full_spatial_ash_vs_best_conventional_baseline"),
    ):
        if not summary["bootstraps"][name]["ci_low"] > lower_bounds[tolerance_name]:
            failures.append(f"bootstrap:{name}")
    if (
        summary["bootstraps"]["ms_ssim_vs_conventional"]["ci_low"]
        < quality["ms_ssim_noninferiority"]["paired_delta_lower_bound_minimum"]
    ):
        failures.append("ms_ssim_noninferiority")
    if evaluation["split"] == "validation":
        if summary["bootstraps"]["y_vs_state_only"]["ci_low"] <= 0.0:
            failures.append("state_only_ablation")
        if summary["bootstraps"]["h07_direct_vs_control"]["ci_low"] <= 0.0:
            failures.append("h07_y_psnr")
        if (
            summary["bootstraps"]["h07_ms_ssim_direct_vs_control"]["ci_low"]
            < quality["ms_ssim_noninferiority"]["paired_delta_lower_bound_minimum"]
        ):
            failures.append("h07_ms_ssim")
    if (
        summary["maximum_ringing_excursion"] > quality["ringing"]["absolute_overshoot_maximum"]
        or summary["maximum_ringing_excursion"] > quality["ringing"]["absolute_undershoot_magnitude_maximum"]
        or summary["maximum_ringing_increase"] > quality["ringing"]["increase_over_best_conventional_maximum"]
    ):
        failures.append("ringing")
    if (
        summary["maximum_alias_ratio"] > quality["alias"]["forbidden_band_energy_ratio_maximum"]
        or summary["maximum_alias_increase"] > quality["alias"]["increase_over_best_conventional_maximum"]
    ):
        failures.append("alias")
    if (
        summary["maximum_chroma_displacement_pixels"]
        > quality["chroma_displacement"]["absolute_pixels_maximum"]
        or summary["maximum_chroma_displacement_increase_pixels"]
        > quality["chroma_displacement"]["increase_over_best_conventional_pixels_maximum"]
    ):
        failures.append("chroma_displacement")
    severe = quality["severe_regression"]
    if summary["minimum_per_asset_y_psnr_delta_db"] < severe["per_asset_y_psnr_delta_db_minimum"]:
        failures.append("severe_asset_regression")
    if any(
        value < severe["per_category_mean_y_psnr_delta_db_minimum"]
        for value in summary["category_mean_y_psnr_deltas_db"].values()
    ):
        failures.append("severe_category_regression")
    minimum_families = quality["minimum_source_families_per_category"][evaluation["split"]]
    observed_category_counts = summary["category_source_family_counts"]
    if set(observed_category_counts) != set(QUALITY_CATEGORIES) or any(
        observed_category_counts.get(category, 0) < minimum_families
        for category in QUALITY_CATEGORIES
    ):
        failures.append("category_source_families")

    performance = tolerances["performance"]
    observed = evaluation["performance"]
    if (
        observed["preregistered_production_estimate_frames_per_second"]
        < observed["h07_control_estimate_frames_per_second"]
        or observed["preregistered_production_estimate_dispatch_cost"]
        > observed["h07_control_estimate_dispatch_cost"]
    ):
        failures.append("h07_performance")
    floor_fields = (
        ("preregistered_production_estimate_same_machine_speedup", "same_machine_speedup_minimum", lambda a, b: a >= b),
        ("preregistered_production_estimate_frames_per_second", "same_machine_frames_per_second_minimum", lambda a, b: a >= b),
        ("preregistered_production_estimate_full_frame_cpu_reconstruction_loops", "full_frame_cpu_reconstruction_loops_maximum", lambda a, b: a <= b),
        ("preregistered_production_estimate_runtime_leaf_tree_generations_per_frame", "runtime_leaf_tree_generations_per_frame_maximum", lambda a, b: a <= b),
        ("preregistered_production_estimate_candidate_evaluations_per_output_cell", "candidate_evaluations_per_output_cell_maximum", lambda a, b: a <= b),
        ("preregistered_production_estimate_wait_until_completed_calls", "production_wait_until_completed_calls_maximum", lambda a, b: a <= b),
        ("preregistered_production_estimate_avoidable_full_frame_gpu_readbacks_per_frame", "avoidable_full_frame_gpu_readbacks_per_frame_maximum", lambda a, b: a <= b),
        ("preregistered_production_estimate_default_in_flight_frames", "default_in_flight_frames_maximum", lambda a, b: a <= b),
        ("calibration_estimate_relative_error", "calibration_estimate_relative_error_maximum", lambda a, b: a <= b),
    )
    for observed_name, tolerance_name, compare in floor_fields:
        observed_value = _require_finite_number(observed[observed_name], observed_name)
        if not compare(observed_value, performance[tolerance_name]):
            failures.append(f"performance:{observed_name}")
    return not failures, tuple(failures)


def evaluation_feasible(
    evaluation: Mapping[str, object],
    summary: Mapping[str, object],
    tolerances: Mapping[str, object],
) -> Tuple[bool, Tuple[str, ...]]:
    failures = []
    for domain in ("engine_raw", "container_decoded"):
        feasible, reasons = _evaluation_feasible_domain(
            evaluation,
            summary[domain],
            tolerances,
        )
        if not feasible:
            failures.extend(f"{domain}:{reason}" for reason in reasons)
    return not failures, tuple(failures)


def development_objective_key(
    summary: Mapping[str, object],
    vector: Mapping[str, object],
    plan: Mapping[str, object],
) -> Tuple[object, ...]:
    summary = summary["engine_raw"]
    return (
        -summary["mean_y_psnr_delta_vs_fixed_db"],
        -summary["mean_y_psnr_delta_vs_non_ash_db"],
        -summary["mean_ms_ssim_delta_vs_conventional"],
        summary["maximum_ringing_excursion"],
        summary["maximum_alias_ratio"],
        summary["estimated_dispatch_cost"],
        serialized_candidate_vector(vector, plan),
    )


def canonical_development_failure_reasons(
    failures: Sequence[str],
) -> Tuple[str, ...]:
    """Count global predicates once and domain-quality predicates separately."""

    canonical = set()
    for failure in failures:
        domain, separator, reason = failure.partition(":")
        if domain not in {"engine_raw", "container_decoded"} or not separator:
            raise CalibrationError(
                "development failure reason lacks a comparison domain"
            )
        if reason in _GLOBAL_DEVELOPMENT_CHECK_FAILURES:
            canonical.add(f"check:{reason}")
        elif reason.startswith("occupancy:"):
            canonical.add(f"check:route_{reason}")
        elif reason == "h07_performance":
            canonical.add("performance:h07")
        elif reason.startswith("performance:"):
            canonical.add(reason)
        else:
            canonical.add(failure)
    return tuple(sorted(canonical))


def development_search_key(
    result: Tuple[
        Mapping[str, object],
        Mapping[str, object],
        bool,
        Tuple[str, ...],
    ],
    vector: Mapping[str, object],
    plan: Mapping[str, object],
) -> Tuple[object, ...]:
    """Rank feasible values first, then deterministic restoration progress."""

    _, summary, feasible, failures = result
    canonical_failures = canonical_development_failure_reasons(failures)
    if feasible and canonical_failures:
        raise CalibrationError("feasible result contains failure reasons")
    return (
        0 if feasible else 1,
        0 if feasible else len(canonical_failures),
        *development_objective_key(summary, vector, plan),
    )


def development_search_rank_sha256(
    result: Tuple[
        Mapping[str, object],
        Mapping[str, object],
        bool,
        Tuple[str, ...],
    ],
    vector: Mapping[str, object],
    plan: Mapping[str, object],
) -> str:
    """Bind the replay inputs for one candidate's development search rank."""

    _, summary, feasible, failures = result
    objective = development_objective_key(summary, vector, plan)
    return canonical_sha256(
        {
            "candidate_vector_sha256": candidate_vector_sha256(vector, plan),
            "canonical_failure_reasons": list(
                canonical_development_failure_reasons(failures)
            ),
            "development_objective": list(objective[:-1]),
            "serialized_candidate_vector_sha256": hashlib.sha256(
                objective[-1]
            ).hexdigest(),
            "feasible": feasible,
            "summary_sha256": canonical_sha256(summary),
        }
    )


def validation_objective_key(
    summary: Mapping[str, object],
    vector: Mapping[str, object],
    plan: Mapping[str, object],
) -> Tuple[object, ...]:
    summary = summary["engine_raw"]
    return (
        -summary["bootstraps"]["y_vs_fixed"]["ci_low"],
        -summary["bootstraps"]["y_vs_non_ash"]["ci_low"],
        -summary["bootstraps"]["y_vs_conventional"]["ci_low"],
        -summary["mean_ms_ssim_delta_vs_conventional"],
        summary["maximum_ringing_excursion"],
        summary["maximum_alias_ratio"],
        summary["estimated_dispatch_cost"],
        serialized_candidate_vector(vector, plan),
    )


def pareto_frontier(
    candidates: Sequence[Tuple[Mapping[str, object], Mapping[str, object]]],
    *,
    split: str,
    plan: Mapping[str, object],
) -> Tuple[Tuple[Mapping[str, object], Mapping[str, object]], ...]:
    if split not in {"development", "validation"}:
        raise CalibrationError("Pareto filtering accepts only open calibration splits")

    def dimensions(summary: Mapping[str, object]) -> Tuple[float, ...]:
        summary = summary["engine_raw"]
        if split == "development":
            return (
                -summary["mean_y_psnr_delta_vs_fixed_db"],
                -summary["mean_y_psnr_delta_vs_non_ash_db"],
                -summary["mean_ms_ssim_delta_vs_conventional"],
                summary["maximum_ringing_excursion"],
                summary["maximum_alias_ratio"],
                summary["estimated_dispatch_cost"],
            )
        return (
            -summary["bootstraps"]["y_vs_fixed"]["ci_low"],
            -summary["bootstraps"]["y_vs_non_ash"]["ci_low"],
            -summary["bootstraps"]["y_vs_conventional"]["ci_low"],
            -summary["mean_ms_ssim_delta_vs_conventional"],
            summary["maximum_ringing_excursion"],
            summary["maximum_alias_ratio"],
            summary["estimated_dispatch_cost"],
        )

    frontier = []
    for index, candidate in enumerate(candidates):
        observed = dimensions(candidate[1])
        dominated = False
        for other_index, other in enumerate(candidates):
            if index == other_index:
                continue
            comparison = dimensions(other[1])
            if all(left <= right for left, right in zip(comparison, observed)) and any(
                left < right for left, right in zip(comparison, observed)
            ):
                dominated = True
                break
        if not dominated:
            frontier.append(candidate)
    objective = development_objective_key if split == "development" else validation_objective_key
    return tuple(sorted(frontier, key=lambda item: objective(item[1], item[0], plan)))


def derive_dispatch_budget(
    dispatch_measurement: Mapping[str, object],
    tolerances: Mapping[str, object],
    *,
    resolver: Callable[[Mapping[str, object]], Mapping[str, object]],
) -> Mapping[str, object]:
    policy = tolerances["performance"]["ash_dispatch_overhead_budget"]
    run_ids = dispatch_measurement.get("measurement_run_ids")
    artifact_hashes = dispatch_measurement.get("measurement_artifact_sha256_values")
    bindings = dispatch_measurement.get("measurement_evidence_bindings")
    records = dispatch_measurement.get("measurement_records")
    if (
        not isinstance(run_ids, list)
        or len(run_ids) != 1
        or not isinstance(run_ids[0], str)
        or not run_ids[0]
        or not isinstance(artifact_hashes, list)
        or len(artifact_hashes) != 1
        or not _is_sha256(artifact_hashes[0])
        or not isinstance(bindings, list)
        or len(bindings) != 1
        or dispatch_measurement.get("measurement_method")
        != "native-cpu-reference-precomputed-dispatch-control-p95-v1"
        or not isinstance(records, list)
        or len(records) != 1
    ):
        raise CalibrationError("dispatch measurement IDs or artifact hashes are invalid")
    reopened = resolver(bindings[0])
    if reopened != records[0] or artifact_hashes != [bindings[0].get("sha256")]:
        raise CalibrationError("dispatch budget is not derived from reopened bytes")
    validate_dispatch_measurement_document(reopened)
    measured = _require_finite_number(
        reopened["aggregate"]["measured_validation_p95_percent"],
        "measured validation dispatch p95",
    )
    if (
        measured < 0.0
        or run_ids != [reopened["run_id"]]
        or dispatch_measurement.get("measured_validation_p95_percent") != measured
        or reopened["input_bindings"]["shared_bank_configuration_sha256"]
        != dispatch_measurement.get("shared_bank_configuration_sha256")
    ):
        raise CalibrationError("dispatch measurement record is not self-bound")
    margin = float(policy["uncertainty_margin_percentage_points"])
    minimum = float(policy["minimum_budget_percent"])
    derived = max(int(minimum), math.ceil(measured + margin))
    if derived > float(policy["maximum_admissible_budget_percent"]):
        raise CalibrationError("derived ASH dispatch budget exceeds 25 percent")
    return {
        "measurement_method": dispatch_measurement["measurement_method"],
        "shared_bank_configuration_sha256": dispatch_measurement[
            "shared_bank_configuration_sha256"
        ],
        "full_ash_configuration_sha256": dispatch_measurement[
            "full_ash_configuration_sha256"
        ],
        "measured_validation_p95_percent": measured,
        "uncertainty_margin_percentage_points": margin,
        "derived_budget_percent": derived,
        "measurement_run_ids": list(run_ids),
        "measurement_artifact_sha256_values": list(artifact_hashes),
        "measurement_evidence_bindings": list(bindings),
        "measurement_records": list(records),
        "derivation_formula": "max(5, ceil(measured_validation_p95_percent + 5))",
        "locked_before_g08": True,
        "post_g08_adjustment_allowed": False,
    }


class AttemptLedger:
    """Append-only hash-chained NDJSON candidate-attempt ledger."""

    def __init__(
        self,
        path: Path,
        *,
        directory_descriptor: int | None = None,
    ) -> None:
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        if directory_descriptor is not None:
            self._directory_descriptor = os.dup(directory_descriptor)
        else:
            self._directory_descriptor, _ = _open_directory_nofollow(path.parent)
        try:
            self._descriptor = os.open(
                path.name,
                flags,
                0o600,
                dir_fd=self._directory_descriptor,
            )
        except BaseException:
            os.close(self._directory_descriptor)
            self._directory_descriptor = -1
            raise
        opened = os.fstat(self._descriptor)
        self._identity = (opened.st_dev, opened.st_ino)
        self._entry_name = path.name
        try:
            os.fsync(self._descriptor)
            os.fsync(self._directory_descriptor)
            self._verify_entry()
        except BaseException:
            os.close(self._descriptor)
            self._descriptor = -1
            os.close(self._directory_descriptor)
            self._directory_descriptor = -1
            raise
        self.path = path
        self.records: List[Mapping[str, object]] = []
        self._previous = "0" * 64

    @property
    def entry_identity(self) -> tuple[int, int]:
        return self._identity

    def _verify_entry(self) -> None:
        if self._descriptor < 0 or self._directory_descriptor < 0:
            raise CalibrationError("attempt ledger is already closed")
        opened = os.fstat(self._descriptor)
        try:
            current = os.stat(
                self._entry_name,
                dir_fd=self._directory_descriptor,
                follow_symlinks=False,
            )
        except OSError as error:
            raise CalibrationError("attempt ledger entry disappeared") from error
        if (
            not stat.S_ISREG(opened.st_mode)
            or not stat.S_ISREG(current.st_mode)
            or stat.S_ISLNK(current.st_mode)
            or (opened.st_dev, opened.st_ino) != self._identity
            or (current.st_dev, current.st_ino) != self._identity
        ):
            raise CalibrationError("attempt ledger entry was replaced")

    def append(self, record: Mapping[str, object]) -> Mapping[str, object]:
        self._verify_entry()
        payload = dict(record)
        payload["sequence"] = len(self.records)
        payload["previous_record_sha256"] = self._previous
        payload["record_sha256"] = canonical_sha256(payload)
        encoded = canonical_json_bytes(payload) + b"\n"
        offset = 0
        while offset < len(encoded):
            written = os.write(self._descriptor, encoded[offset:])
            if written <= 0:
                raise OSError("attempt ledger append made no progress")
            offset += written
        os.fsync(self._descriptor)
        self._verify_entry()
        self.records.append(payload)
        self._previous = payload["record_sha256"]
        return payload

    def close(self) -> None:
        if self._descriptor >= 0:
            try:
                self._verify_entry()
            finally:
                os.close(self._descriptor)
                self._descriptor = -1
                os.close(self._directory_descriptor)
                self._directory_descriptor = -1


def _write_content_addressed_evaluation(
    run_root: Path,
    evaluation: Mapping[str, object],
    *,
    run_root_descriptor: int | None = None,
) -> Mapping[str, object]:
    payload = canonical_json_bytes(evaluation)
    digest = hashlib.sha256(payload).hexdigest()
    relative = PurePosixPath("evaluations") / f"{digest}.json"
    destination = run_root.joinpath(*relative.parts)
    if run_root_descriptor is not None:
        directory_descriptor = _open_or_create_child_directory_at(
            run_root_descriptor,
            relative.parts[0],
            display_path=destination.parent,
        )
        try:
            _publish_bytes_atomic_durable_at(
                directory_descriptor,
                destination.name,
                payload,
                display_path=destination,
                collision_message="content-addressed evaluation path collision",
                allow_identical_existing=True,
            )
        finally:
            os.close(directory_descriptor)
        return {
            "path": relative.as_posix(),
            "sha256": digest,
            "size_bytes": len(payload),
        }
    destination.parent.mkdir(mode=0o700, exist_ok=True)
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(destination, flags, 0o600)
    except FileExistsError:
        existing = destination.read_bytes()
        if existing != payload:
            raise CalibrationError("content-addressed evaluation path collision")
    else:
        try:
            offset = 0
            while offset < len(payload):
                written = os.write(descriptor, payload[offset:])
                if written <= 0:
                    raise OSError("evaluation artifact write made no progress")
                offset += written
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
    if destination.read_bytes() != payload:
        raise CalibrationError("evaluation artifact changed after publication")
    return {
        "path": relative.as_posix(),
        "sha256": digest,
        "size_bytes": len(payload),
    }


def _write_control_selection_artifacts(
    run_root: Path,
    evaluation: Mapping[str, object],
    *,
    run_root_descriptor: int | None = None,
) -> Tuple[Mapping[str, object], ...]:
    bindings = []
    directory_descriptor = None
    if run_root_descriptor is not None:
        directory_descriptor = _open_or_create_child_directory_at(
            run_root_descriptor,
            "control-selections",
            display_path=run_root / "control-selections",
        )
    try:
        for name, embedded in sorted(evaluation["control_selection_artifacts"].items()):
            document = embedded["document"]
            payload = canonical_json_bytes(document)
            digest = hashlib.sha256(payload).hexdigest()
            if digest != embedded["sha256"]:
                raise CalibrationError("control-selection artifact hash changed before write")
            relative = PurePosixPath("control-selections") / f"{digest}.json"
            destination = run_root.joinpath(*relative.parts)
            if directory_descriptor is not None:
                _publish_bytes_atomic_durable_at(
                    directory_descriptor,
                    destination.name,
                    payload,
                    display_path=destination,
                    collision_message="control-selection content address collided",
                    allow_identical_existing=True,
                )
            else:
                destination.parent.mkdir(mode=0o700, exist_ok=True)
                flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
                if hasattr(os, "O_NOFOLLOW"):
                    flags |= os.O_NOFOLLOW
                try:
                    descriptor = os.open(destination, flags, 0o600)
                except FileExistsError:
                    if destination.read_bytes() != payload:
                        raise CalibrationError("control-selection content address collided")
                else:
                    try:
                        offset = 0
                        while offset < len(payload):
                            written = os.write(descriptor, payload[offset:])
                            if written <= 0:
                                raise OSError(
                                    "control-selection artifact write made no progress"
                                )
                            offset += written
                        os.fsync(descriptor)
                    finally:
                        os.close(descriptor)
                reopened = destination.read_bytes()
                if reopened != payload or hashlib.sha256(reopened).hexdigest() != digest:
                    raise CalibrationError(
                        "control-selection artifact failed reopen validation"
                    )
            bindings.append(
                {
                    "control": name,
                    "path": relative.as_posix(),
                    "sha256": digest,
                    "size_bytes": len(payload),
                }
            )
    finally:
        if directory_descriptor is not None:
            os.close(directory_descriptor)
    return tuple(bindings)


def verify_attempt_ledger(path: Path) -> Tuple[Mapping[str, object], ...]:
    return _verify_attempt_ledger_payload(path.read_bytes())


def _verify_attempt_ledger_payload(
    payload: bytes,
) -> Tuple[Mapping[str, object], ...]:
    previous = "0" * 64
    records = []
    for sequence, line in enumerate(payload.splitlines()):
        try:
            record = json.loads(line)
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            raise CalibrationError("attempt ledger is not valid NDJSON") from error
        if not isinstance(record, dict):
            raise CalibrationError("attempt ledger record is not an object")
        claimed = record.get("record_sha256")
        unhashed = dict(record)
        unhashed.pop("record_sha256", None)
        if (
            record.get("sequence") != sequence
            or record.get("previous_record_sha256") != previous
            or claimed != canonical_sha256(unhashed)
        ):
            raise CalibrationError("attempt ledger hash chain is invalid")
        previous = claimed
        records.append(record)
    return tuple(records)


def _open_directory_nofollow(path: Path) -> tuple[int, tuple[int, int]]:
    try:
        before = os.stat(path, follow_symlinks=False)
    except OSError as error:
        raise CalibrationError(f"run directory is absent: {path}") from error
    if stat.S_ISLNK(before.st_mode) or not stat.S_ISDIR(before.st_mode):
        raise CalibrationError(f"run directory is symbolic or not a directory: {path}")
    descriptor = os.open(
        path,
        os.O_RDONLY
        | getattr(os, "O_DIRECTORY", 0)
        | getattr(os, "O_NOFOLLOW", 0),
    )
    opened = os.fstat(descriptor)
    identity = (opened.st_dev, opened.st_ino)
    if identity != (before.st_dev, before.st_ino) or not stat.S_ISDIR(
        opened.st_mode
    ):
        os.close(descriptor)
        raise CalibrationError(f"run directory changed while opening: {path}")
    return descriptor, identity


def _open_child_directory_nofollow_at(
    parent_descriptor: int,
    name: str,
    *,
    display_path: Path,
) -> tuple[int, tuple[int, int]]:
    try:
        before = os.stat(
            name,
            dir_fd=parent_descriptor,
            follow_symlinks=False,
        )
    except OSError as error:
        raise CalibrationError(f"run directory is absent: {display_path}") from error
    if stat.S_ISLNK(before.st_mode) or not stat.S_ISDIR(before.st_mode):
        raise CalibrationError(
            f"run directory is symbolic or not a directory: {display_path}"
        )
    try:
        descriptor = os.open(
            name,
            os.O_RDONLY
            | getattr(os, "O_DIRECTORY", 0)
            | getattr(os, "O_NOFOLLOW", 0),
            dir_fd=parent_descriptor,
        )
    except OSError as error:
        raise CalibrationError(
            f"run directory changed while opening: {display_path}"
        ) from error
    opened = os.fstat(descriptor)
    identity = (opened.st_dev, opened.st_ino)
    if identity != (before.st_dev, before.st_ino) or not stat.S_ISDIR(
        opened.st_mode
    ):
        os.close(descriptor)
        raise CalibrationError(f"run directory changed while opening: {display_path}")
    return descriptor, identity


def _entry_exists_at(directory_descriptor: int, name: str) -> bool:
    try:
        os.stat(name, dir_fd=directory_descriptor, follow_symlinks=False)
    except FileNotFoundError:
        return False
    return True


def _rename_directory_exclusive_at(
    source_name: str,
    destination_name: str,
    *,
    directory_descriptor: int,
) -> None:
    _rename_exclusive_at(
        source_name,
        destination_name,
        directory_descriptor=directory_descriptor,
        flags=_RENAME_TRANSACTION_FLAGS,
    )


def _rename_exclusive_at(
    source_name: str,
    destination_name: str,
    *,
    directory_descriptor: int,
    flags: int,
) -> None:
    if _RENAMEATX_NP is None:
        raise CalibrationError(
            "exclusive retained-directory run publication is unavailable"
        )
    ctypes.set_errno(0)
    result = _RENAMEATX_NP(
        directory_descriptor,
        os.fsencode(source_name),
        directory_descriptor,
        os.fsencode(destination_name),
        flags,
    )
    if result == 0:
        return
    error_number = ctypes.get_errno()
    if error_number == 0:
        error_number = errno.EIO
    raise OSError(
        error_number,
        os.strerror(error_number),
        destination_name,
    )


def _quarantine_invalid_published_entry(
    destination_name: str,
    *,
    output_root_descriptor: int,
) -> Tuple[str, ...]:
    quarantined = []
    for _ in range(32):
        if not _entry_exists_at(output_root_descriptor, destination_name):
            os.fsync(output_root_descriptor)
            return tuple(quarantined)
        quarantine_name = (
            f".{destination_name}.identity-mismatch-{uuid.uuid4()}.quarantine"
        )
        try:
            _rename_exclusive_at(
                destination_name,
                quarantine_name,
                directory_descriptor=output_root_descriptor,
                flags=_RENAME_EXCL | _RENAME_RESOLVE_BENEATH,
            )
        except FileExistsError:
            continue
        except FileNotFoundError:
            if not _entry_exists_at(output_root_descriptor, destination_name):
                os.fsync(output_root_descriptor)
                return tuple(quarantined)
            continue
        quarantined.append(quarantine_name)
    raise CalibrationError(
        "invalid published run entry could not be cleared from its canonical name"
    )


def _verify_pinned_output_root(
    *,
    output_root: Path,
    output_root_descriptor: int,
    output_root_identity: tuple[int, int],
) -> None:
    pinned_root = os.fstat(output_root_descriptor)
    if (
        not stat.S_ISDIR(pinned_root.st_mode)
        or (pinned_root.st_dev, pinned_root.st_ino) != output_root_identity
    ):
        raise CalibrationError("pinned run output-root identity changed")
    current_root_descriptor, current_root_identity = _open_directory_nofollow(
        output_root
    )
    try:
        if current_root_identity != output_root_identity:
            raise CalibrationError("run output root was replaced")
    finally:
        os.close(current_root_descriptor)


def _verify_pinned_run_directories(
    *,
    output_root: Path,
    output_root_descriptor: int,
    output_root_identity: tuple[int, int],
    partial: Path,
    partial_descriptor: int,
    partial_identity: tuple[int, int],
) -> None:
    _verify_pinned_output_root(
        output_root=output_root,
        output_root_descriptor=output_root_descriptor,
        output_root_identity=output_root_identity,
    )
    pinned_partial = os.fstat(partial_descriptor)
    if (
        not stat.S_ISDIR(pinned_partial.st_mode)
        or (pinned_partial.st_dev, pinned_partial.st_ino) != partial_identity
    ):
        raise CalibrationError("pinned run transaction directory identity changed")
    try:
        partial_metadata = os.stat(
            partial.name,
            dir_fd=output_root_descriptor,
            follow_symlinks=False,
        )
    except OSError as error:
        raise CalibrationError("run partial directory is absent or replaced") from error
    if (
        stat.S_ISLNK(partial_metadata.st_mode)
        or not stat.S_ISDIR(partial_metadata.st_mode)
        or (partial_metadata.st_dev, partial_metadata.st_ino) != partial_identity
    ):
        raise CalibrationError("run partial directory was replaced")


def _fsync_regular_file(path: Path) -> None:
    before = os.stat(path, follow_symlinks=False)
    if stat.S_ISLNK(before.st_mode) or not stat.S_ISREG(before.st_mode):
        raise CalibrationError(f"run artifact is symbolic or not regular: {path}")
    descriptor = os.open(
        path,
        os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0),
    )
    try:
        opened = os.fstat(descriptor)
        if (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino):
            raise CalibrationError(f"run artifact changed while opening: {path}")
        os.fsync(descriptor)
        after = os.fstat(descriptor)
        if (
            (after.st_dev, after.st_ino) != (opened.st_dev, opened.st_ino)
            or after.st_size != opened.st_size
            or after.st_mtime_ns != opened.st_mtime_ns
        ):
            raise CalibrationError(f"run artifact changed while syncing: {path}")
    finally:
        os.close(descriptor)


def _fsync_directory(path: Path) -> None:
    descriptor, identity = _open_directory_nofollow(path)
    try:
        os.fsync(descriptor)
        after = os.fstat(descriptor)
        if (after.st_dev, after.st_ino) != identity:
            raise CalibrationError(f"run directory changed while syncing: {path}")
    finally:
        os.close(descriptor)


def _fsync_run_tree(root: Path) -> None:
    root_descriptor, root_identity = _open_directory_nofollow(root)
    try:
        _fsync_run_tree_at(
            root_descriptor,
            display_path=root,
            expected_identity=root_identity,
        )
    finally:
        os.close(root_descriptor)


def _fsync_run_tree_at(
    directory_descriptor: int,
    *,
    display_path: Path,
    expected_identity: tuple[int, int],
) -> None:
    opened = os.fstat(directory_descriptor)
    if (
        not stat.S_ISDIR(opened.st_mode)
        or (opened.st_dev, opened.st_ino) != expected_identity
    ):
        raise CalibrationError(f"run tree directory identity differs: {display_path}")
    for name in sorted(os.listdir(directory_descriptor)):
        metadata = os.stat(
            name,
            dir_fd=directory_descriptor,
            follow_symlinks=False,
        )
        child_path = display_path / name
        if stat.S_ISREG(metadata.st_mode):
            descriptor = os.open(
                name,
                os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0),
                dir_fd=directory_descriptor,
            )
            try:
                child = os.fstat(descriptor)
                if (child.st_dev, child.st_ino) != (metadata.st_dev, metadata.st_ino):
                    raise CalibrationError(
                        f"run artifact changed while opening: {child_path}"
                    )
                os.fsync(descriptor)
                after = os.fstat(descriptor)
                if (
                    (after.st_dev, after.st_ino) != (child.st_dev, child.st_ino)
                    or after.st_size != child.st_size
                    or after.st_mtime_ns != child.st_mtime_ns
                ):
                    raise CalibrationError(
                        f"run artifact changed while syncing: {child_path}"
                    )
            finally:
                os.close(descriptor)
        elif stat.S_ISDIR(metadata.st_mode) and not stat.S_ISLNK(metadata.st_mode):
            child_descriptor = os.open(
                name,
                os.O_RDONLY
                | getattr(os, "O_DIRECTORY", 0)
                | getattr(os, "O_NOFOLLOW", 0),
                dir_fd=directory_descriptor,
            )
            try:
                _fsync_run_tree_at(
                    child_descriptor,
                    display_path=child_path,
                    expected_identity=(metadata.st_dev, metadata.st_ino),
                )
            finally:
                os.close(child_descriptor)
        else:
            raise CalibrationError(
                f"run tree contains a symbolic or invalid entry: {child_path}"
            )
    os.fsync(directory_descriptor)
    after = os.fstat(directory_descriptor)
    if (after.st_dev, after.st_ino) != expected_identity:
        raise CalibrationError(f"run tree directory changed while syncing: {display_path}")


def _snapshot_run_tree_at(
    directory_descriptor: int,
    *,
    display_path: Path,
    expected_identity: tuple[int, int],
) -> Tuple[object, ...]:
    opened = os.fstat(directory_descriptor)
    if (
        not stat.S_ISDIR(opened.st_mode)
        or (opened.st_dev, opened.st_ino) != expected_identity
    ):
        raise CalibrationError(f"run tree directory identity differs: {display_path}")
    names = sorted(os.listdir(directory_descriptor))
    children = []
    for name in names:
        metadata = os.stat(
            name,
            dir_fd=directory_descriptor,
            follow_symlinks=False,
        )
        child_path = display_path / name
        if stat.S_ISREG(metadata.st_mode):
            payload = _read_regular_at(
                directory_descriptor,
                name,
                display_path=child_path,
            )
            current = os.stat(
                name,
                dir_fd=directory_descriptor,
                follow_symlinks=False,
            )
            children.append(
                (
                    "file",
                    name,
                    current.st_dev,
                    current.st_ino,
                    current.st_mode,
                    current.st_size,
                    current.st_mtime_ns,
                    hashlib.sha256(payload).hexdigest(),
                )
            )
        elif stat.S_ISDIR(metadata.st_mode) and not stat.S_ISLNK(metadata.st_mode):
            child_descriptor = os.open(
                name,
                os.O_RDONLY
                | getattr(os, "O_DIRECTORY", 0)
                | getattr(os, "O_NOFOLLOW", 0),
                dir_fd=directory_descriptor,
            )
            try:
                child_snapshot = _snapshot_run_tree_at(
                    child_descriptor,
                    display_path=child_path,
                    expected_identity=(metadata.st_dev, metadata.st_ino),
                )
            finally:
                os.close(child_descriptor)
            current = os.stat(
                name,
                dir_fd=directory_descriptor,
                follow_symlinks=False,
            )
            if (
                not stat.S_ISDIR(current.st_mode)
                or (current.st_dev, current.st_ino)
                != (metadata.st_dev, metadata.st_ino)
            ):
                raise CalibrationError(
                    f"run tree directory entry changed while reading: {child_path}"
                )
            children.append(("directory", name, child_snapshot))
        else:
            raise CalibrationError(
                f"run tree contains a symbolic or invalid entry: {child_path}"
            )
    after = os.fstat(directory_descriptor)
    if (
        (after.st_dev, after.st_ino) != expected_identity
        or after.st_mtime_ns != opened.st_mtime_ns
        or sorted(os.listdir(directory_descriptor)) != names
    ):
        raise CalibrationError(f"run tree changed while sealing: {display_path}")
    return (
        "directory",
        after.st_dev,
        after.st_ino,
        after.st_mode,
        after.st_mtime_ns,
        tuple(children),
    )


def _open_or_create_child_directory_at(
    parent_descriptor: int,
    name: str,
    *,
    display_path: Path,
) -> int:
    try:
        os.mkdir(name, 0o700, dir_fd=parent_descriptor)
        os.fsync(parent_descriptor)
    except FileExistsError:
        pass
    try:
        descriptor, _ = _open_child_directory_nofollow_at(
            parent_descriptor,
            name,
            display_path=display_path,
        )
    except CalibrationError as error:
        raise CalibrationError(
            f"run artifact directory is symbolic or invalid: {display_path}"
        ) from error
    return descriptor


def _read_regular_at(
    directory_descriptor: int,
    name: str,
    *,
    display_path: Path,
    expected_identity: tuple[int, int] | None = None,
) -> bytes:
    before = os.stat(
        name,
        dir_fd=directory_descriptor,
        follow_symlinks=False,
    )
    if stat.S_ISLNK(before.st_mode) or not stat.S_ISREG(before.st_mode):
        raise CalibrationError(f"run artifact is symbolic or invalid: {display_path}")
    if expected_identity is not None and (
        before.st_dev,
        before.st_ino,
    ) != expected_identity:
        raise CalibrationError(f"run artifact entry was replaced: {display_path}")
    descriptor = os.open(
        name,
        os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0),
        dir_fd=directory_descriptor,
    )
    try:
        opened = os.fstat(descriptor)
        if (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino):
            raise CalibrationError(f"run artifact changed while opening: {display_path}")
        chunks = []
        while True:
            chunk = os.read(descriptor, 1024 * 1024)
            if not chunk:
                break
            chunks.append(chunk)
        after = os.fstat(descriptor)
    finally:
        os.close(descriptor)
    if (
        (after.st_dev, after.st_ino) != (opened.st_dev, opened.st_ino)
        or after.st_size != opened.st_size
        or after.st_mtime_ns != opened.st_mtime_ns
    ):
        raise CalibrationError(f"run artifact changed while reading: {display_path}")
    try:
        current = os.stat(
            name,
            dir_fd=directory_descriptor,
            follow_symlinks=False,
        )
    except OSError as error:
        raise CalibrationError(
            f"run artifact entry disappeared while reading: {display_path}"
        ) from error
    if (
        stat.S_ISLNK(current.st_mode)
        or not stat.S_ISREG(current.st_mode)
        or (current.st_dev, current.st_ino) != (after.st_dev, after.st_ino)
        or current.st_size != after.st_size
        or current.st_mtime_ns != after.st_mtime_ns
    ):
        raise CalibrationError(
            f"run artifact entry changed while reading: {display_path}"
        )
    return b"".join(chunks)


def _publish_bytes_atomic_durable_at(
    directory_descriptor: int,
    name: str,
    payload: bytes,
    *,
    display_path: Path,
    collision_message: str,
    allow_identical_existing: bool,
) -> None:
    temporary_name = f".{name}.tmp-{uuid.uuid4().hex}"
    descriptor = os.open(
        temporary_name,
        os.O_WRONLY
        | os.O_CREAT
        | os.O_EXCL
        | getattr(os, "O_NOFOLLOW", 0),
        0o600,
        dir_fd=directory_descriptor,
    )
    completed = False
    try:
        offset = 0
        while offset < len(payload):
            written = os.write(descriptor, payload[offset:])
            if written <= 0:
                raise OSError("atomic run artifact write made no progress")
            offset += written
        os.fsync(descriptor)
        os.close(descriptor)
        descriptor = -1
        try:
            os.link(
                temporary_name,
                name,
                src_dir_fd=directory_descriptor,
                dst_dir_fd=directory_descriptor,
                follow_symlinks=False,
            )
        except FileExistsError as error:
            if (
                not allow_identical_existing
                or _read_regular_at(
                    directory_descriptor,
                    name,
                    display_path=display_path,
                )
                != payload
            ):
                raise CalibrationError(collision_message) from error
        os.unlink(temporary_name, dir_fd=directory_descriptor)
        os.fsync(directory_descriptor)
        if _read_regular_at(
            directory_descriptor,
            name,
            display_path=display_path,
        ) != payload:
            raise CalibrationError(f"run artifact failed reopen: {display_path}")
        completed = True
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        if not completed:
            try:
                os.unlink(temporary_name, dir_fd=directory_descriptor)
            except FileNotFoundError:
                pass


def _json_artifact_bytes(value: object) -> bytes:
    return (
        json.dumps(
            value,
            ensure_ascii=False,
            allow_nan=False,
            sort_keys=True,
            indent=2,
        )
        + "\n"
    ).encode("utf-8")


def _write_json_atomic_durable(
    path: Path,
    value: object,
    *,
    parent_descriptor: int | None = None,
) -> None:
    if parent_descriptor is not None:
        encoded = _json_artifact_bytes(value)
        _publish_bytes_atomic_durable_at(
            parent_descriptor,
            path.name,
            encoded,
            display_path=path,
            collision_message=f"run artifact already exists: {path}",
            allow_identical_existing=False,
        )
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.parent / f".{path.name}.tmp-{uuid.uuid4().hex}"
    completed = False
    try:
        write_json(temporary, value)
        _fsync_regular_file(temporary)
        try:
            os.link(temporary, path, follow_symlinks=False)
        except FileExistsError as error:
            raise CalibrationError(f"run artifact already exists: {path}") from error
        temporary.unlink()
        _fsync_directory(path.parent)
        completed = True
    finally:
        if not completed:
            temporary.unlink(missing_ok=True)


def _validate_development_control_selection_cache_origin(
    origin: Mapping[str, object],
    *,
    identity: Mapping[str, object],
) -> Mapping[str, object]:
    try:
        validate_schema(
            origin,
            SCHEMAS_ROOT / _DEVELOPMENT_CONTROL_SELECTION_CACHE_SCHEMA,
        )
    except ValueError as error:
        raise CalibrationBindingError(
            "expected development control-selection cache artifact is corrupt"
        ) from error
    unhashed = dict(origin)
    declared = unhashed.pop("origin_manifest_sha256", None)
    artifacts = origin.get("artifacts")
    if (
        origin.get("identity") != dict(identity)
        or origin.get("identity_sha256") != canonical_sha256(identity)
        or origin.get("shared_bank_configuration_sha256")
        != identity.get("shared_bank_configuration_sha256")
        or origin.get("split") != "development"
        or origin.get("selection_stage") != "development_provisional"
        or origin.get("validation_evidence_imported") is not False
        or origin.get("holdout_evidence_imported") is not False
        or origin.get("candidate_bound_outputs_cached") is not False
        or declared != canonical_sha256(unhashed)
        or not isinstance(artifacts, dict)
        or set(artifacts)
        != {"best_fixed", "conventional", "non_ash_selector"}
        or any(
            not isinstance(embedded, dict)
            or set(embedded) != {"sha256", "document"}
            or not isinstance(embedded.get("document"), dict)
            or embedded.get("sha256")
            != canonical_sha256(embedded["document"])
            for embedded in artifacts.values()
        )
    ):
        raise CalibrationBindingError(
            "expected development control-selection cache artifact is corrupt"
        )
    return json.loads(canonical_json_bytes(origin))


class _DevelopmentControlSelectionCache:
    """Pinned, atomic, development-only bank selection origin store."""

    def __init__(self, root: Path) -> None:
        if (
            root.name != _DEVELOPMENT_CONTROL_SELECTION_CACHE_DIRECTORY
            or not root.is_absolute()
        ):
            raise CalibrationBindingError(
                "development control-selection cache root is invalid"
            )
        parent_descriptor, parent_identity = _open_directory_nofollow(
            root.parent
        )
        try:
            self._descriptor = _open_or_create_child_directory_at(
                parent_descriptor,
                root.name,
                display_path=root,
            )
        except BaseException:
            os.close(parent_descriptor)
            raise
        self._parent_descriptor = parent_descriptor
        self._parent_identity = parent_identity
        opened = os.fstat(self._descriptor)
        self._identity = (opened.st_dev, opened.st_ino)
        self._root = root
        try:
            storage_source = Path(__file__).resolve(strict=True)
            schema_path = (
                SCHEMAS_ROOT / _DEVELOPMENT_CONTROL_SELECTION_CACHE_SCHEMA
            ).resolve(strict=True)
            if (
                storage_source.is_symlink()
                or not storage_source.is_file()
                or schema_path.is_symlink()
                or not schema_path.is_file()
            ):
                raise OSError("cache implementation closure is not regular")
            self._implementation_identity = {
                "storage_implementation_sha256": hashlib.sha256(
                    storage_source.read_bytes()
                ).hexdigest(),
                "cache_schema_sha256": hashlib.sha256(
                    schema_path.read_bytes()
                ).hexdigest(),
            }
        except OSError as error:
            os.close(self._descriptor)
            self._descriptor = -1
            os.close(self._parent_descriptor)
            self._parent_descriptor = -1
            raise CalibrationBindingError(
                "development control-selection cache implementation cannot be hash-bound"
            ) from error

    @property
    def implementation_identity(self) -> Mapping[str, object]:
        return dict(self._implementation_identity)

    def _require_open(self) -> int:
        if self._descriptor < 0 or self._parent_descriptor < 0:
            raise CalibrationBindingError(
                "development control-selection cache is closed"
            )
        metadata = os.fstat(self._descriptor)
        parent_metadata = os.fstat(self._parent_descriptor)
        try:
            entry_metadata = os.stat(
                self._root.name,
                dir_fd=self._parent_descriptor,
                follow_symlinks=False,
            )
        except OSError as error:
            raise CalibrationBindingError(
                "development control-selection cache directory changed"
            ) from error
        if (
            not stat.S_ISDIR(metadata.st_mode)
            or (metadata.st_dev, metadata.st_ino) != self._identity
            or not stat.S_ISDIR(parent_metadata.st_mode)
            or (parent_metadata.st_dev, parent_metadata.st_ino)
            != self._parent_identity
            or stat.S_ISLNK(entry_metadata.st_mode)
            or not stat.S_ISDIR(entry_metadata.st_mode)
            or (entry_metadata.st_dev, entry_metadata.st_ino) != self._identity
        ):
            raise CalibrationBindingError(
                "development control-selection cache directory is invalid"
            )
        return self._descriptor

    @staticmethod
    def _filename(identity: Mapping[str, object]) -> str:
        return f"{canonical_sha256(identity)}.json"

    def reopen(
        self,
        identity: Mapping[str, object],
    ) -> Optional[Mapping[str, object]]:
        descriptor = self._require_open()
        filename = self._filename(identity)
        if not _entry_exists_at(descriptor, filename):
            return None
        try:
            payload = _read_regular_at(
                descriptor,
                filename,
                display_path=self._root / filename,
            )
            origin = json.loads(payload)
        except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
            raise CalibrationBindingError(
                "expected development control-selection cache artifact is corrupt"
            ) from error
        if not isinstance(origin, dict):
            raise CalibrationBindingError(
                "expected development control-selection cache artifact is corrupt"
            )
        return _validate_development_control_selection_cache_origin(
            origin,
            identity=identity,
        )

    def publish(
        self,
        *,
        identity: Mapping[str, object],
        origin: Mapping[str, object],
    ) -> Mapping[str, object]:
        descriptor = self._require_open()
        validated = _validate_development_control_selection_cache_origin(
            origin,
            identity=identity,
        )
        filename = self._filename(identity)
        payload = canonical_json_bytes(validated)
        _publish_bytes_atomic_durable_at(
            descriptor,
            filename,
            payload,
            display_path=self._root / filename,
            collision_message=(
                "development control-selection cache origin changed"
            ),
            allow_identical_existing=True,
        )
        reopened = self.reopen(identity)
        if reopened != validated:
            raise CalibrationBindingError(
                "development control-selection cache origin failed reopen"
            )
        return reopened

    def close(self) -> None:
        if self._descriptor >= 0:
            os.close(self._descriptor)
            self._descriptor = -1
        if self._parent_descriptor >= 0:
            os.close(self._parent_descriptor)
            self._parent_descriptor = -1


def _run_transaction_marker(run_id: str, transaction_id: str) -> Mapping[str, object]:
    record: dict[str, object] = {
        "schema_version": "1.0.0",
        "artifact_kind": "p06_calibration_run_transaction",
        "run_id": run_id,
        "transaction_id": transaction_id,
        "transaction_state": "in_progress",
    }
    record["record_sha256"] = canonical_sha256(record)
    return record


def _canonical_recovery_history(
    records: Sequence[Mapping[str, object]],
) -> Tuple[Mapping[str, object], ...]:
    by_transaction = {}
    for record in records:
        transaction_id = record.get("stale_transaction_id")
        if not isinstance(transaction_id, str) or transaction_id in by_transaction:
            raise CalibrationError("recovery history transaction IDs are invalid")
        by_transaction[transaction_id] = record
    return tuple(by_transaction[key] for key in sorted(by_transaction))


def _run_transaction_intent(
    run_id: str,
    transaction_id: str,
    *,
    inherited_recovery_history: Sequence[Mapping[str, object]] = (),
    inherited_recovery_source: str | None = None,
) -> Mapping[str, object]:
    canonical_history = _canonical_recovery_history(inherited_recovery_history)
    record: dict[str, object] = {
        "schema_version": "1.0.0",
        "artifact_kind": "p06_calibration_run_transaction_intent",
        "run_id": run_id,
        "transaction_id": transaction_id,
        "transaction_state": "preparing_partial",
        "inherited_recovery_source": inherited_recovery_source,
        "inherited_recovery_history_count": len(canonical_history),
        "inherited_recovery_history_sha256": canonical_sha256(
            list(canonical_history)
        ),
    }
    record["record_sha256"] = canonical_sha256(record)
    return record


def _run_transaction_intent_name(run_id: str) -> str:
    return f".{run_id}{_RUN_TRANSACTION_INTENT_SUFFIX}"


def _run_transaction_intent_target(intent: Mapping[str, object]) -> str:
    encoded = base64.urlsafe_b64encode(canonical_json_bytes(intent)).decode("ascii")
    return _RUN_TRANSACTION_INTENT_TARGET_PREFIX + encoded


def _validate_run_transaction_intent(
    intent: object,
    *,
    run_id: str,
) -> Mapping[str, object] | None:
    fields = {
        "schema_version",
        "artifact_kind",
        "run_id",
        "transaction_id",
        "transaction_state",
        "inherited_recovery_source",
        "inherited_recovery_history_count",
        "inherited_recovery_history_sha256",
        "record_sha256",
    }
    if (
        not isinstance(intent, dict)
        or set(intent) != fields
        or intent.get("schema_version") != "1.0.0"
        or intent.get("artifact_kind")
        != "p06_calibration_run_transaction_intent"
        or intent.get("run_id") != run_id
        or intent.get("transaction_state") != "preparing_partial"
        or not isinstance(intent.get("transaction_id"), str)
        or intent.get("record_sha256")
        != canonical_sha256(
            {key: value for key, value in intent.items() if key != "record_sha256"}
        )
    ):
        return None
    try:
        if str(uuid.UUID(str(intent["transaction_id"]))) != intent["transaction_id"]:
            return None
    except ValueError:
        return None
    history_count = intent.get("inherited_recovery_history_count")
    history_source = intent.get("inherited_recovery_source")
    history_sha256 = intent.get("inherited_recovery_history_sha256")
    if (
        not isinstance(history_count, int)
        or history_count < 0
        or not isinstance(history_sha256, str)
        or len(history_sha256) != SHA256_PATTERN_LENGTH
    ):
        return None
    if history_count == 0:
        if (
            history_source is not None
            or history_sha256 != canonical_sha256([])
        ):
            return None
    else:
        prefix = f"{run_id}.recovered-"
        suffix = ".failed"
        if (
            not isinstance(history_source, str)
            or not history_source.startswith(prefix)
            or not history_source.endswith(suffix)
        ):
            return None
        source_transaction_id = history_source[
            len(prefix) : -len(suffix)
        ]
        try:
            if str(uuid.UUID(source_transaction_id)) != source_transaction_id:
                return None
        except ValueError:
            return None
    return intent


def _read_run_transaction_intent_at(
    output_root_descriptor: int,
    *,
    run_id: str,
) -> Mapping[str, object] | None:
    name = _run_transaction_intent_name(run_id)
    if not _entry_exists_at(output_root_descriptor, name):
        return None
    metadata = os.stat(
        name,
        dir_fd=output_root_descriptor,
        follow_symlinks=False,
    )
    root_metadata = os.fstat(output_root_descriptor)
    if not stat.S_ISLNK(metadata.st_mode) or metadata.st_uid != root_metadata.st_uid:
        raise CalibrationError(
            "run transaction intent exists but is not a recognized owned intent"
        )
    try:
        target = os.readlink(name, dir_fd=output_root_descriptor)
        if not target.startswith(_RUN_TRANSACTION_INTENT_TARGET_PREFIX):
            raise ValueError("transaction intent target prefix differs")
        encoded = target[len(_RUN_TRANSACTION_INTENT_TARGET_PREFIX) :]
        payload = base64.b64decode(
            encoded.encode("ascii"),
            altchars=b"-_",
            validate=True,
        )
        intent = json.loads(payload)
        if canonical_json_bytes(intent) != payload:
            raise ValueError("transaction intent is not canonical")
    except (
        OSError,
        UnicodeError,
        ValueError,
        TypeError,
        json.JSONDecodeError,
    ) as error:
        raise CalibrationError(
            "run transaction intent exists but is not a recognized owned intent"
        ) from error
    validated = _validate_run_transaction_intent(intent, run_id=run_id)
    if validated is None:
        raise CalibrationError(
            "run transaction intent exists but is not a recognized owned intent"
        )
    if _run_transaction_intent_target(validated) != target:
        raise CalibrationError("run transaction intent encoding differs")
    current = os.stat(
        name,
        dir_fd=output_root_descriptor,
        follow_symlinks=False,
    )
    if (
        not stat.S_ISLNK(current.st_mode)
        or (current.st_dev, current.st_ino) != (metadata.st_dev, metadata.st_ino)
        or current.st_size != metadata.st_size
        or current.st_mtime_ns != metadata.st_mtime_ns
    ):
        raise CalibrationError("run transaction intent changed while reading")
    return validated


def _create_run_transaction_intent_at(
    output_root_descriptor: int,
    *,
    run_id: str,
    transaction_id: str,
    inherited_recovery_history: Sequence[Mapping[str, object]] = (),
    inherited_recovery_source: str | None = None,
) -> Mapping[str, object]:
    intent = _run_transaction_intent(
        run_id,
        transaction_id,
        inherited_recovery_history=inherited_recovery_history,
        inherited_recovery_source=inherited_recovery_source,
    )
    name = _run_transaction_intent_name(run_id)
    try:
        os.symlink(
            _run_transaction_intent_target(intent),
            name,
            dir_fd=output_root_descriptor,
        )
    except FileExistsError as error:
        raise CalibrationError("run transaction intent already exists") from error
    os.fsync(output_root_descriptor)
    reopened = _read_run_transaction_intent_at(
        output_root_descriptor,
        run_id=run_id,
    )
    if reopened != intent:
        raise CalibrationError("run transaction intent failed durable reopen")
    return intent


def _remove_run_transaction_intent_at(
    output_root_descriptor: int,
    *,
    run_id: str,
    expected: Mapping[str, object],
) -> None:
    reopened = _read_run_transaction_intent_at(
        output_root_descriptor,
        run_id=run_id,
    )
    if reopened != expected:
        raise CalibrationError("run transaction intent changed before removal")
    os.unlink(
        _run_transaction_intent_name(run_id),
        dir_fd=output_root_descriptor,
    )
    os.fsync(output_root_descriptor)


def _recognized_run_transaction(
    partial_descriptor: int,
    *,
    partial: Path,
    run_id: str,
) -> Mapping[str, object] | None:
    try:
        marker = json.loads(
            _read_regular_at(
                partial_descriptor,
                _RUN_TRANSACTION_MARKER,
                display_path=partial / _RUN_TRANSACTION_MARKER,
            )
        )
    except (
        OSError,
        CalibrationError,
        TypeError,
        ValueError,
        UnicodeDecodeError,
        json.JSONDecodeError,
    ):
        return None
    fields = {
        "schema_version",
        "artifact_kind",
        "run_id",
        "transaction_id",
        "transaction_state",
        "record_sha256",
    }
    if (
        not isinstance(marker, dict)
        or set(marker) != fields
        or marker.get("schema_version") != "1.0.0"
        or marker.get("artifact_kind") != "p06_calibration_run_transaction"
        or marker.get("run_id") != run_id
        or marker.get("transaction_state") != "in_progress"
        or not isinstance(marker.get("transaction_id"), str)
        or marker.get("record_sha256")
        != canonical_sha256(
            {key: value for key, value in marker.items() if key != "record_sha256"}
        )
    ):
        return None
    try:
        if str(uuid.UUID(str(marker["transaction_id"]))) != marker["transaction_id"]:
            return None
    except ValueError:
        return None
    return marker


def _pre_marker_recovery_journal(
    *,
    run_id: str,
    transaction_id: str,
    action: str,
    temporary_name: str | None,
    temporary_payload: bytes | None,
) -> Mapping[str, object]:
    record: dict[str, object] = {
        "schema_version": "1.0.0",
        "artifact_kind": "p06_pre_marker_recovery_journal",
        "run_id": run_id,
        "transaction_id": transaction_id,
        "action": action,
        "temporary_name": temporary_name,
        "temporary_sha256": (
            hashlib.sha256(temporary_payload).hexdigest()
            if temporary_payload is not None
            else None
        ),
        "temporary_size_bytes": (
            len(temporary_payload) if temporary_payload is not None else None
        ),
        "recovery_temporary_name": (
            f".{_RUN_TRANSACTION_MARKER}.recovery-{transaction_id}.tmp"
        ),
    }
    record["record_sha256"] = canonical_sha256(record)
    return record


def _pre_marker_recovery_journal_target(
    journal: Mapping[str, object],
) -> str:
    encoded = base64.urlsafe_b64encode(canonical_json_bytes(journal)).decode("ascii")
    return _RUN_PREMARKER_RECOVERY_TARGET_PREFIX + encoded


def _validate_pre_marker_recovery_journal(
    journal: object,
    *,
    run_id: str,
    transaction_id: str,
) -> Mapping[str, object] | None:
    fields = {
        "schema_version",
        "artifact_kind",
        "run_id",
        "transaction_id",
        "action",
        "temporary_name",
        "temporary_sha256",
        "temporary_size_bytes",
        "recovery_temporary_name",
        "record_sha256",
    }
    if (
        not isinstance(journal, dict)
        or set(journal) != fields
        or journal.get("schema_version") != "1.0.0"
        or journal.get("artifact_kind") != "p06_pre_marker_recovery_journal"
        or journal.get("run_id") != run_id
        or journal.get("transaction_id") != transaction_id
        or journal.get("action") not in _PREMARKER_RECOVERY_ACTIONS
        or journal.get("action") == "not_required"
        or journal.get("record_sha256")
        != canonical_sha256(
            {key: value for key, value in journal.items() if key != "record_sha256"}
        )
    ):
        return None
    temporary_name = journal.get("temporary_name")
    temporary_sha256 = journal.get("temporary_sha256")
    temporary_size = journal.get("temporary_size_bytes")
    if journal.get("recovery_temporary_name") != (
        f".{_RUN_TRANSACTION_MARKER}.recovery-{transaction_id}.tmp"
    ):
        return None
    if temporary_name is None:
        if temporary_sha256 is not None or temporary_size is not None:
            return None
    else:
        prefix = f".{_RUN_TRANSACTION_MARKER}.tmp-"
        if (
            not isinstance(temporary_name, str)
            or not temporary_name.startswith(prefix)
            or len(temporary_name) != len(prefix) + 32
            or not all(
                character in "0123456789abcdef"
                for character in temporary_name[-32:]
            )
            or not isinstance(temporary_sha256, str)
            or len(temporary_sha256) != SHA256_PATTERN_LENGTH
            or not isinstance(temporary_size, int)
            or temporary_size < 0
        ):
            return None
    return journal


def _read_pre_marker_recovery_journal_at(
    partial_descriptor: int,
    *,
    run_id: str,
    transaction_id: str,
) -> Mapping[str, object] | None:
    if not _entry_exists_at(partial_descriptor, _RUN_PREMARKER_RECOVERY_JOURNAL):
        return None
    metadata = os.stat(
        _RUN_PREMARKER_RECOVERY_JOURNAL,
        dir_fd=partial_descriptor,
        follow_symlinks=False,
    )
    partial_metadata = os.fstat(partial_descriptor)
    if not stat.S_ISLNK(metadata.st_mode) or metadata.st_uid != partial_metadata.st_uid:
        raise CalibrationError("pre-marker recovery journal is invalid")
    try:
        target = os.readlink(
            _RUN_PREMARKER_RECOVERY_JOURNAL,
            dir_fd=partial_descriptor,
        )
        if not target.startswith(_RUN_PREMARKER_RECOVERY_TARGET_PREFIX):
            raise ValueError("pre-marker recovery journal prefix differs")
        encoded = target[len(_RUN_PREMARKER_RECOVERY_TARGET_PREFIX) :]
        payload = base64.b64decode(
            encoded.encode("ascii"),
            altchars=b"-_",
            validate=True,
        )
        journal = json.loads(payload)
        if canonical_json_bytes(journal) != payload:
            raise ValueError("pre-marker recovery journal is not canonical")
    except (
        OSError,
        UnicodeError,
        ValueError,
        TypeError,
        json.JSONDecodeError,
    ) as error:
        raise CalibrationError("pre-marker recovery journal is invalid") from error
    validated = _validate_pre_marker_recovery_journal(
        journal,
        run_id=run_id,
        transaction_id=transaction_id,
    )
    if validated is None or _pre_marker_recovery_journal_target(validated) != target:
        raise CalibrationError("pre-marker recovery journal is invalid")
    current = os.stat(
        _RUN_PREMARKER_RECOVERY_JOURNAL,
        dir_fd=partial_descriptor,
        follow_symlinks=False,
    )
    if (
        not stat.S_ISLNK(current.st_mode)
        or (current.st_dev, current.st_ino) != (metadata.st_dev, metadata.st_ino)
        or current.st_size != metadata.st_size
        or current.st_mtime_ns != metadata.st_mtime_ns
    ):
        raise CalibrationError("pre-marker recovery journal changed while reading")
    return validated


def _create_pre_marker_recovery_journal_at(
    partial_descriptor: int,
    *,
    journal: Mapping[str, object],
    run_id: str,
    transaction_id: str,
) -> Mapping[str, object]:
    existing = _read_pre_marker_recovery_journal_at(
        partial_descriptor,
        run_id=run_id,
        transaction_id=transaction_id,
    )
    if existing is not None:
        if existing != journal:
            raise CalibrationError("pre-marker recovery journal differs")
        return existing
    os.symlink(
        _pre_marker_recovery_journal_target(journal),
        _RUN_PREMARKER_RECOVERY_JOURNAL,
        dir_fd=partial_descriptor,
    )
    os.fsync(partial_descriptor)
    reopened = _read_pre_marker_recovery_journal_at(
        partial_descriptor,
        run_id=run_id,
        transaction_id=transaction_id,
    )
    if reopened != journal:
        raise CalibrationError("pre-marker recovery journal failed durable reopen")
    return journal


def _remove_pre_marker_recovery_journal_at(
    partial_descriptor: int,
    *,
    expected: Mapping[str, object],
    run_id: str,
    transaction_id: str,
) -> None:
    reopened = _read_pre_marker_recovery_journal_at(
        partial_descriptor,
        run_id=run_id,
        transaction_id=transaction_id,
    )
    if reopened != expected:
        raise CalibrationError("pre-marker recovery journal changed before removal")
    os.unlink(_RUN_PREMARKER_RECOVERY_JOURNAL, dir_fd=partial_descriptor)
    os.fsync(partial_descriptor)


def _recover_or_validate_intent_bound_marker(
    partial_descriptor: int,
    *,
    partial: Path,
    run_id: str,
    transaction_id: str,
    allow_journal_creation: bool,
    allow_inherited_history: bool,
) -> Tuple[Mapping[str, object], Mapping[str, object]]:
    expected_marker = _run_transaction_marker(run_id, transaction_id)
    expected_payload = _json_artifact_bytes(expected_marker)
    temporary_prefix = f".{_RUN_TRANSACTION_MARKER}.tmp-"
    recovery_temporary_name = (
        f".{_RUN_TRANSACTION_MARKER}.recovery-{transaction_id}.tmp"
    )
    journal = _read_pre_marker_recovery_journal_at(
        partial_descriptor,
        run_id=run_id,
        transaction_id=transaction_id,
    )
    entries = sorted(os.listdir(partial_descriptor))
    temporary_names = [
        name
        for name in entries
        if name.startswith(temporary_prefix)
        and len(name) == len(temporary_prefix) + 32
        and all(character in "0123456789abcdef" for character in name[-32:])
    ]
    allowed_progress_entries = set()
    if journal is not None:
        allowed_progress_entries.update(
            {"attempts.ndjson", "failure.json", _RUN_RECOVERY_DIRECTORY}
        )
    elif allow_inherited_history:
        allowed_progress_entries.add(_RUN_RECOVERY_DIRECTORY)
    unrelated = [
        name
        for name in entries
        if name
        not in {
            _RUN_TRANSACTION_MARKER,
            _RUN_PREMARKER_RECOVERY_JOURNAL,
            recovery_temporary_name,
        }
        and name not in temporary_names
        and name not in allowed_progress_entries
    ]
    if unrelated or len(temporary_names) > 1:
        raise CalibrationError(
            "intent-bound pre-marker partial contains an unrecognized entry"
        )

    marker = _recognized_run_transaction(
        partial_descriptor,
        partial=partial,
        run_id=run_id,
    )
    if marker is None and _entry_exists_at(
        partial_descriptor,
        _RUN_TRANSACTION_MARKER,
    ):
        raise CalibrationError("intent-bound canonical marker is invalid")
    if marker is not None and marker != expected_marker:
        raise CalibrationError("run transaction intent and partial marker disagree")

    temporary_name = temporary_names[0] if temporary_names else None
    temporary_payload = (
        _read_regular_at(
            partial_descriptor,
            temporary_name,
            display_path=partial / temporary_name,
        )
        if temporary_name is not None
        else None
    )
    if temporary_payload is not None and not expected_payload.startswith(
        temporary_payload
    ):
        raise CalibrationError(
            "marker temporary does not match the durable transaction intent"
        )
    recovery_temporary_payload = (
        _read_regular_at(
            partial_descriptor,
            recovery_temporary_name,
            display_path=partial / recovery_temporary_name,
        )
        if _entry_exists_at(partial_descriptor, recovery_temporary_name)
        else None
    )
    if recovery_temporary_payload is not None and not expected_payload.startswith(
        recovery_temporary_payload
    ):
        raise CalibrationError(
            "journal-bound recovery marker temporary differs"
        )

    if journal is None:
        if not allow_journal_creation or recovery_temporary_payload is not None:
            raise CalibrationError("pre-marker recovery journal is absent")
        if marker is not None:
            action = (
                "removed_linked_marker_temporary"
                if temporary_payload is not None
                else "validated_durable_marker"
            )
        elif temporary_payload is None:
            action = "published_marker_from_durable_intent"
        elif temporary_payload == expected_payload:
            action = "completed_durable_marker_temporary"
        else:
            action = "replaced_incomplete_marker_temporary"
        journal = _pre_marker_recovery_journal(
            run_id=run_id,
            transaction_id=transaction_id,
            action=action,
            temporary_name=temporary_name,
            temporary_payload=temporary_payload,
        )
        journal = _create_pre_marker_recovery_journal_at(
            partial_descriptor,
            journal=journal,
            run_id=run_id,
            transaction_id=transaction_id,
        )
    else:
        journal_temporary_name = journal.get("temporary_name")
        if temporary_name is not None and temporary_name != journal_temporary_name:
            raise CalibrationError("pre-marker temporary differs from its journal")
        if temporary_payload is not None and (
            journal.get("temporary_sha256")
            != hashlib.sha256(temporary_payload).hexdigest()
            or journal.get("temporary_size_bytes") != len(temporary_payload)
        ):
            raise CalibrationError("pre-marker temporary binding differs")

    if marker is not None:
        for name, payload in (
            (temporary_name, temporary_payload),
            (recovery_temporary_name, recovery_temporary_payload),
        ):
            if name is None or payload is None:
                continue
            if payload != expected_payload:
                raise CalibrationError(
                    "linked marker temporary is not the expected durable payload"
                )
            os.unlink(name, dir_fd=partial_descriptor)
        os.fsync(partial_descriptor)
    elif temporary_payload == expected_payload:
        try:
            os.link(
                temporary_name,
                _RUN_TRANSACTION_MARKER,
                src_dir_fd=partial_descriptor,
                dst_dir_fd=partial_descriptor,
                follow_symlinks=False,
            )
        except FileExistsError as error:
            raise CalibrationError(
                "canonical marker appeared during intent-bound recovery"
            ) from error
        os.unlink(temporary_name, dir_fd=partial_descriptor)
        if recovery_temporary_payload is not None:
            os.unlink(recovery_temporary_name, dir_fd=partial_descriptor)
        os.fsync(partial_descriptor)
    else:
        if temporary_name is not None:
            os.unlink(temporary_name, dir_fd=partial_descriptor)
            os.fsync(partial_descriptor)
        if recovery_temporary_payload is None:
            descriptor = os.open(
                recovery_temporary_name,
                os.O_WRONLY
                | os.O_CREAT
                | os.O_EXCL
                | getattr(os, "O_NOFOLLOW", 0),
                0o600,
                dir_fd=partial_descriptor,
            )
            recovery_temporary_payload = b""
        else:
            before = os.stat(
                recovery_temporary_name,
                dir_fd=partial_descriptor,
                follow_symlinks=False,
            )
            descriptor = os.open(
                recovery_temporary_name,
                os.O_WRONLY
                | os.O_APPEND
                | getattr(os, "O_NOFOLLOW", 0),
                dir_fd=partial_descriptor,
            )
            opened = os.fstat(descriptor)
            if (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino):
                os.close(descriptor)
                raise CalibrationError(
                    "recovery marker temporary changed while reopening"
                )
        try:
            offset = len(recovery_temporary_payload)
            while offset < len(expected_payload):
                written = os.write(descriptor, expected_payload[offset:])
                if written <= 0:
                    raise OSError("recovery marker temporary write made no progress")
                offset += written
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
        os.fsync(partial_descriptor)
        if _read_regular_at(
            partial_descriptor,
            recovery_temporary_name,
            display_path=partial / recovery_temporary_name,
        ) != expected_payload:
            raise CalibrationError("recovery marker temporary failed reopen")
        try:
            os.link(
                recovery_temporary_name,
                _RUN_TRANSACTION_MARKER,
                src_dir_fd=partial_descriptor,
                dst_dir_fd=partial_descriptor,
                follow_symlinks=False,
            )
        except FileExistsError as error:
            raise CalibrationError(
                "canonical marker appeared during journal-bound recovery"
            ) from error
        os.unlink(recovery_temporary_name, dir_fd=partial_descriptor)
        os.fsync(partial_descriptor)
    reopened = _recognized_run_transaction(
        partial_descriptor,
        partial=partial,
        run_id=run_id,
    )
    if reopened != expected_marker:
        raise CalibrationError("intent-bound marker recovery failed reopen")
    return expected_marker, journal


def _recovery_record_name(transaction_id: str) -> str:
    return f"{transaction_id}.json"


def _validate_recovery_record(
    record: object,
    *,
    run_id: str,
    transaction_id: str,
) -> Mapping[str, object] | None:
    fields = {
        "schema_version",
        "artifact_kind",
        "run_id",
        "stale_transaction_id",
        "stale_transaction_record_sha256",
        "action",
        "recovered_path",
        "cleanup_result",
        "pre_marker_recovery_action",
        "record_sha256",
    }
    if (
        not isinstance(record, dict)
        or set(record) != fields
        or record.get("schema_version") != "1.0.0"
        or record.get("artifact_kind")
        != "p06_stale_run_transaction_recovery"
        or record.get("run_id") != run_id
        or record.get("stale_transaction_id") != transaction_id
        or record.get("action") != "archived_recognized_stale_partial"
        or record.get("recovered_path")
        != f"{run_id}.recovered-{transaction_id}.failed"
        or record.get("cleanup_result") != "archived"
        or record.get("pre_marker_recovery_action")
        not in _PREMARKER_RECOVERY_ACTIONS
        or not isinstance(record.get("stale_transaction_record_sha256"), str)
        or len(str(record.get("stale_transaction_record_sha256")))
        != SHA256_PATTERN_LENGTH
        or record.get("record_sha256")
        != canonical_sha256(
            {key: value for key, value in record.items() if key != "record_sha256"}
        )
    ):
        return None
    return record


def _recovery_pending_name(transaction_id: str) -> str:
    return f".{transaction_id}.json.pending"


def _recovery_materialize_name(transaction_id: str) -> str:
    return f".{transaction_id}.json.materialize"


def _recovery_pending_target(record: Mapping[str, object]) -> str:
    encoded = base64.urlsafe_b64encode(canonical_json_bytes(record)).decode("ascii")
    return _RUN_RECOVERY_PENDING_TARGET_PREFIX + encoded


def _read_recovery_pending_at(
    history_descriptor: int,
    *,
    transaction_id: str,
    run_id: str,
) -> Mapping[str, object] | None:
    name = _recovery_pending_name(transaction_id)
    if not _entry_exists_at(history_descriptor, name):
        return None
    metadata = os.stat(
        name,
        dir_fd=history_descriptor,
        follow_symlinks=False,
    )
    history_metadata = os.fstat(history_descriptor)
    if not stat.S_ISLNK(metadata.st_mode) or metadata.st_uid != history_metadata.st_uid:
        raise CalibrationError("pending stale recovery record is invalid")
    try:
        target = os.readlink(name, dir_fd=history_descriptor)
        if not target.startswith(_RUN_RECOVERY_PENDING_TARGET_PREFIX):
            raise ValueError("pending recovery prefix differs")
        encoded = target[len(_RUN_RECOVERY_PENDING_TARGET_PREFIX) :]
        payload = base64.b64decode(
            encoded.encode("ascii"),
            altchars=b"-_",
            validate=True,
        )
        record = json.loads(payload)
        if canonical_json_bytes(record) != payload:
            raise ValueError("pending recovery record is not canonical")
    except (
        OSError,
        UnicodeError,
        ValueError,
        TypeError,
        json.JSONDecodeError,
    ) as error:
        raise CalibrationError("pending stale recovery record is invalid") from error
    validated = _validate_recovery_record(
        record,
        run_id=run_id,
        transaction_id=transaction_id,
    )
    if validated is None or _recovery_pending_target(validated) != target:
        raise CalibrationError("pending stale recovery record is invalid")
    current = os.stat(
        name,
        dir_fd=history_descriptor,
        follow_symlinks=False,
    )
    if (
        not stat.S_ISLNK(current.st_mode)
        or (current.st_dev, current.st_ino) != (metadata.st_dev, metadata.st_ino)
        or current.st_size != metadata.st_size
        or current.st_mtime_ns != metadata.st_mtime_ns
    ):
        raise CalibrationError("pending stale recovery record changed while reading")
    return validated


def _read_recovery_history_at(
    partial_descriptor: int,
    *,
    partial: Path,
    run_id: str,
) -> Tuple[Mapping[str, object], ...]:
    if not _entry_exists_at(partial_descriptor, _RUN_RECOVERY_DIRECTORY):
        return ()
    history_descriptor, _ = _open_child_directory_nofollow_at(
        partial_descriptor,
        _RUN_RECOVERY_DIRECTORY,
        display_path=partial / _RUN_RECOVERY_DIRECTORY,
    )
    try:
        transaction_ids = set()
        for name in os.listdir(history_descriptor):
            if name.endswith(".json") and not name.startswith("."):
                transaction_id = name[: -len(".json")]
            elif name.startswith(".") and name.endswith(".json.pending"):
                transaction_id = name[1 : -len(".json.pending")]
            elif name.startswith(".") and name.endswith(".json.materialize"):
                transaction_id = name[1 : -len(".json.materialize")]
            else:
                raise CalibrationError("stale transaction recovery history is invalid")
            try:
                if str(uuid.UUID(transaction_id)) != transaction_id:
                    raise ValueError("recovery history transaction ID differs")
            except ValueError as error:
                raise CalibrationError(
                    "stale transaction recovery history is invalid"
                ) from error
            transaction_ids.add(transaction_id)

        records = []
        for transaction_id in sorted(transaction_ids):
            final_name = _recovery_record_name(transaction_id)
            final_record = None
            if _entry_exists_at(history_descriptor, final_name):
                try:
                    final_record = json.loads(
                        _read_regular_at(
                            history_descriptor,
                            final_name,
                            display_path=(
                                partial / _RUN_RECOVERY_DIRECTORY / final_name
                            ),
                        )
                    )
                except (
                    OSError,
                    CalibrationError,
                    TypeError,
                    ValueError,
                    UnicodeDecodeError,
                    json.JSONDecodeError,
                ) as error:
                    raise CalibrationError(
                        "stale transaction recovery history is invalid"
                    ) from error
                final_record = _validate_recovery_record(
                    final_record,
                    run_id=run_id,
                    transaction_id=transaction_id,
                )
                if final_record is None:
                    raise CalibrationError(
                        "stale transaction recovery history record differs"
                    )
            pending_record = _read_recovery_pending_at(
                history_descriptor,
                transaction_id=transaction_id,
                run_id=run_id,
            )
            if final_record is None and pending_record is None:
                raise CalibrationError(
                    "recovery materialization lacks its pending record"
                )
            if (
                final_record is not None
                and pending_record is not None
                and final_record != pending_record
            ):
                raise CalibrationError("pending and final recovery records differ")
            record = final_record if final_record is not None else pending_record
            materialize_name = _recovery_materialize_name(transaction_id)
            if _entry_exists_at(history_descriptor, materialize_name):
                materialized = _read_regular_at(
                    history_descriptor,
                    materialize_name,
                    display_path=(
                        partial / _RUN_RECOVERY_DIRECTORY / materialize_name
                    ),
                )
                if not _json_artifact_bytes(record).startswith(materialized):
                    raise CalibrationError(
                        "recovery materialization does not match its pending record"
                    )
            records.append(record)
        return tuple(records)
    finally:
        os.close(history_descriptor)


def _write_recovery_history_at(
    partial_descriptor: int,
    *,
    partial: Path,
    records: Sequence[Mapping[str, object]],
) -> None:
    if not records:
        return
    history_descriptor = _open_or_create_child_directory_at(
        partial_descriptor,
        _RUN_RECOVERY_DIRECTORY,
        display_path=partial / _RUN_RECOVERY_DIRECTORY,
    )
    try:
        seen = set()
        for record in _canonical_recovery_history(records):
            transaction_id = str(record["stale_transaction_id"])
            if transaction_id in seen:
                raise CalibrationError("duplicate stale transaction recovery record")
            seen.add(transaction_id)
            destination = partial / _RUN_RECOVERY_DIRECTORY / _recovery_record_name(
                transaction_id
            )
            validated = _validate_recovery_record(
                record,
                run_id=str(record["run_id"]),
                transaction_id=transaction_id,
            )
            if validated != record:
                raise CalibrationError("stale transaction recovery record is invalid")
            payload = _json_artifact_bytes(record)
            pending_name = _recovery_pending_name(transaction_id)
            materialize_name = _recovery_materialize_name(transaction_id)
            final_exists = _entry_exists_at(history_descriptor, destination.name)
            if final_exists:
                if _read_regular_at(
                    history_descriptor,
                    destination.name,
                    display_path=destination,
                ) != payload:
                    raise CalibrationError("stale transaction recovery record differs")
            else:
                pending = _read_recovery_pending_at(
                    history_descriptor,
                    transaction_id=transaction_id,
                    run_id=str(record["run_id"]),
                )
                if pending is None:
                    os.symlink(
                        _recovery_pending_target(record),
                        pending_name,
                        dir_fd=history_descriptor,
                    )
                    os.fsync(history_descriptor)
                elif pending != record:
                    raise CalibrationError("pending stale recovery record differs")

                if _entry_exists_at(history_descriptor, materialize_name):
                    materialized = _read_regular_at(
                        history_descriptor,
                        materialize_name,
                        display_path=(
                            partial
                            / _RUN_RECOVERY_DIRECTORY
                            / materialize_name
                        ),
                    )
                    if not payload.startswith(materialized):
                        raise CalibrationError(
                            "stale recovery materialization differs"
                        )
                    before = os.stat(
                        materialize_name,
                        dir_fd=history_descriptor,
                        follow_symlinks=False,
                    )
                    descriptor = os.open(
                        materialize_name,
                        os.O_WRONLY
                        | os.O_APPEND
                        | getattr(os, "O_NOFOLLOW", 0),
                        dir_fd=history_descriptor,
                    )
                    opened = os.fstat(descriptor)
                    if (opened.st_dev, opened.st_ino) != (
                        before.st_dev,
                        before.st_ino,
                    ):
                        os.close(descriptor)
                        raise CalibrationError(
                            "stale recovery materialization changed"
                        )
                else:
                    materialized = b""
                    descriptor = os.open(
                        materialize_name,
                        os.O_WRONLY
                        | os.O_CREAT
                        | os.O_EXCL
                        | getattr(os, "O_NOFOLLOW", 0),
                        0o600,
                        dir_fd=history_descriptor,
                    )
                try:
                    offset = len(materialized)
                    while offset < len(payload):
                        written = os.write(descriptor, payload[offset:])
                        if written <= 0:
                            raise OSError(
                                "recovery history write made no progress"
                            )
                        offset += written
                    os.fsync(descriptor)
                finally:
                    os.close(descriptor)
                os.fsync(history_descriptor)
                try:
                    os.link(
                        materialize_name,
                        destination.name,
                        src_dir_fd=history_descriptor,
                        dst_dir_fd=history_descriptor,
                        follow_symlinks=False,
                    )
                except FileExistsError:
                    if _read_regular_at(
                        history_descriptor,
                        destination.name,
                        display_path=destination,
                    ) != payload:
                        raise CalibrationError(
                            "stale transaction recovery record differs"
                        )
            if _entry_exists_at(history_descriptor, materialize_name):
                if _read_regular_at(
                    history_descriptor,
                    materialize_name,
                    display_path=(
                        partial / _RUN_RECOVERY_DIRECTORY / materialize_name
                    ),
                ) != payload:
                    raise CalibrationError("stale recovery materialization differs")
                os.unlink(materialize_name, dir_fd=history_descriptor)
            if _entry_exists_at(history_descriptor, pending_name):
                pending = _read_recovery_pending_at(
                    history_descriptor,
                    transaction_id=transaction_id,
                    run_id=str(record["run_id"]),
                )
                if pending != record:
                    raise CalibrationError("pending stale recovery record differs")
                os.unlink(pending_name, dir_fd=history_descriptor)
            os.fsync(history_descriptor)
    finally:
        os.close(history_descriptor)


def _read_intent_inherited_recovery_history_at(
    output_root_descriptor: int,
    *,
    output_root: Path,
    run_id: str,
    intent: Mapping[str, object],
) -> Tuple[Mapping[str, object], ...]:
    expected_count = int(intent["inherited_recovery_history_count"])
    expected_sha256 = str(intent["inherited_recovery_history_sha256"])
    source_name = intent.get("inherited_recovery_source")
    if expected_count == 0:
        if source_name is not None or expected_sha256 != canonical_sha256([]):
            raise CalibrationError("empty inherited recovery history binding differs")
        return ()
    if not isinstance(source_name, str):
        raise CalibrationError("inherited recovery history source is absent")
    source_path = output_root / source_name
    source_descriptor, source_identity = _open_child_directory_nofollow_at(
        output_root_descriptor,
        source_name,
        display_path=source_path,
    )
    try:
        before = _snapshot_run_tree_at(
            source_descriptor,
            display_path=source_path,
            expected_identity=source_identity,
        )
        records = _read_recovery_history_at(
            source_descriptor,
            partial=source_path,
            run_id=run_id,
        )
        after = _snapshot_run_tree_at(
            source_descriptor,
            display_path=source_path,
            expected_identity=source_identity,
        )
        current_source = os.stat(
            source_name,
            dir_fd=output_root_descriptor,
            follow_symlinks=False,
        )
    finally:
        os.close(source_descriptor)
    if (
        before != after
        or not stat.S_ISDIR(current_source.st_mode)
        or (current_source.st_dev, current_source.st_ino) != source_identity
        or len(records) != expected_count
        or canonical_sha256(list(records)) != expected_sha256
        or not any(record.get("recovered_path") == source_name for record in records)
    ):
        raise CalibrationError("inherited recovery history source binding differs")
    return records


def _scan_recovered_history_at(
    output_root_descriptor: int,
    *,
    output_root: Path,
    run_id: str,
) -> Tuple[Tuple[Mapping[str, object], ...], str | None]:
    prefix = f"{run_id}.recovered-"
    suffix = ".failed"
    candidates = []
    for name in sorted(os.listdir(output_root_descriptor)):
        if not name.startswith(prefix) or not name.endswith(suffix):
            continue
        transaction_id = name[len(prefix) : -len(suffix)]
        try:
            if str(uuid.UUID(transaction_id)) != transaction_id:
                raise ValueError("recovered transaction ID differs")
        except ValueError as error:
            raise CalibrationError(
                "recovered transaction archive name is invalid"
            ) from error
        archive_path = output_root / name
        archive_descriptor, archive_identity = _open_child_directory_nofollow_at(
            output_root_descriptor,
            name,
            display_path=archive_path,
        )
        try:
            before = _snapshot_run_tree_at(
                archive_descriptor,
                display_path=archive_path,
                expected_identity=archive_identity,
            )
            marker = _recognized_run_transaction(
                archive_descriptor,
                partial=archive_path,
                run_id=run_id,
            )
            records = _read_recovery_history_at(
                archive_descriptor,
                partial=archive_path,
                run_id=run_id,
            )
            attempts = _read_regular_at(
                archive_descriptor,
                "attempts.ndjson",
                display_path=archive_path / "attempts.ndjson",
            )
            failure = json.loads(
                _read_regular_at(
                    archive_descriptor,
                    "failure.json",
                    display_path=archive_path / "failure.json",
                )
            )
            after = _snapshot_run_tree_at(
                archive_descriptor,
                display_path=archive_path,
                expected_identity=archive_identity,
            )
            current_archive = os.stat(
                name,
                dir_fd=output_root_descriptor,
                follow_symlinks=False,
            )
        except (
            OSError,
            CalibrationError,
            TypeError,
            ValueError,
            UnicodeDecodeError,
            json.JSONDecodeError,
        ) as error:
            raise CalibrationError(
                "recovered transaction archive is invalid"
            ) from error
        try:
            verified_attempt_count: int | None = len(
                _verify_attempt_ledger_payload(attempts)
            )
        except CalibrationError:
            verified_attempt_count = None
        if (
            before != after
            or not stat.S_ISDIR(current_archive.st_mode)
            or (current_archive.st_dev, current_archive.st_ino)
            != archive_identity
            or marker is None
            or marker.get("transaction_id") != transaction_id
            or not isinstance(failure, dict)
            or failure.get("schema_version") != "1.0.0"
            or failure.get("artifact_kind") != "p06_calibration_failure"
            or failure.get("run_id") != run_id
            or failure.get("holdout_accessed") is not False
            or failure.get("release_locks_written") is not False
            or failure.get("attempt_ledger_sha256")
            != hashlib.sha256(attempts).hexdigest()
            or (
                verified_attempt_count is not None
                and failure.get("attempt_count") != verified_attempt_count
            )
            or not any(
                record.get("stale_transaction_id") == transaction_id
                and record.get("recovered_path") == name
                for record in records
            )
        ):
            raise CalibrationError("recovered transaction archive binding differs")
        candidates.append((name, records))
    if not candidates:
        return (), None
    candidates.sort(key=lambda item: (len(item[1]), item[0]))
    source_name, maximal = candidates[-1]
    maximal_by_transaction = {
        str(record["stale_transaction_id"]): record for record in maximal
    }
    for _, records in candidates[:-1]:
        for record in records:
            if maximal_by_transaction.get(
                str(record["stale_transaction_id"])
            ) != record:
                raise CalibrationError(
                    "recovered transaction histories form conflicting branches"
                )
    return maximal, source_name


def _finalize_run_directory(
    source: Path,
    destination: Path,
    *,
    output_root: Path,
    output_root_descriptor: int,
    output_root_identity: tuple[int, int],
    source_descriptor: int,
    source_identity: tuple[int, int],
) -> None:
    _verify_pinned_run_directories(
        output_root=output_root,
        output_root_descriptor=output_root_descriptor,
        output_root_identity=output_root_identity,
        partial=source,
        partial_descriptor=source_descriptor,
        partial_identity=source_identity,
    )
    if destination.parent != output_root or _entry_exists_at(
        output_root_descriptor,
        destination.name,
    ):
        raise CalibrationError("run final destination exists or escaped its output root")
    pre_fsync_tree = _snapshot_run_tree_at(
        source_descriptor,
        display_path=source,
        expected_identity=source_identity,
    )
    _fsync_run_tree_at(
        source_descriptor,
        display_path=source,
        expected_identity=source_identity,
    )
    sealed_tree = _snapshot_run_tree_at(
        source_descriptor,
        display_path=source,
        expected_identity=source_identity,
    )
    if sealed_tree != pre_fsync_tree:
        raise CalibrationError("run tree changed across its durability commit")
    _verify_pinned_run_directories(
        output_root=output_root,
        output_root_descriptor=output_root_descriptor,
        output_root_identity=output_root_identity,
        partial=source,
        partial_descriptor=source_descriptor,
        partial_identity=source_identity,
    )
    try:
        _rename_directory_exclusive_at(
            source.name,
            destination.name,
            directory_descriptor=output_root_descriptor,
        )
    except FileExistsError as error:
        raise CalibrationError(
            "run final destination appeared during exclusive publication"
        ) from error
    except OSError as error:
        raise CalibrationError("exclusive run directory publication failed") from error
    try:
        published = os.stat(
            destination.name,
            dir_fd=output_root_descriptor,
            follow_symlinks=False,
        )
    except FileNotFoundError as error:
        raise CalibrationError("published run directory disappeared") from error
    except OSError as error:
        quarantined = _quarantine_invalid_published_entry(
            destination.name,
            output_root_descriptor=output_root_descriptor,
        )
        raise CalibrationError(
            "published run directory could not be verified; entry quarantined as "
            + ",".join(quarantined)
        ) from error
    if (
        stat.S_ISLNK(published.st_mode)
        or not stat.S_ISDIR(published.st_mode)
        or (published.st_dev, published.st_ino) != source_identity
    ):
        quarantined = _quarantine_invalid_published_entry(
            destination.name,
            output_root_descriptor=output_root_descriptor,
        )
        raise CalibrationError(
            "published run directory identity differs; invalid entry quarantined as "
            + ",".join(quarantined)
        )
    try:
        published_tree = _snapshot_run_tree_at(
            source_descriptor,
            display_path=destination,
            expected_identity=source_identity,
        )
    except (OSError, CalibrationError) as error:
        quarantined = _quarantine_invalid_published_entry(
            destination.name,
            output_root_descriptor=output_root_descriptor,
        )
        raise CalibrationError(
            "published run tree changed; invalid entry quarantined as "
            + ",".join(quarantined)
        ) from error
    if published_tree != sealed_tree:
        quarantined = _quarantine_invalid_published_entry(
            destination.name,
            output_root_descriptor=output_root_descriptor,
        )
        raise CalibrationError(
            "published run tree binding differs; invalid entry quarantined as "
            + ",".join(quarantined)
        )
    os.fsync(output_root_descriptor)
    _verify_pinned_output_root(
        output_root=output_root,
        output_root_descriptor=output_root_descriptor,
        output_root_identity=output_root_identity,
    )
    try:
        durable = os.stat(
            destination.name,
            dir_fd=output_root_descriptor,
            follow_symlinks=False,
        )
    except FileNotFoundError as error:
        raise CalibrationError("durable run directory disappeared") from error
    except OSError as error:
        quarantined = _quarantine_invalid_published_entry(
            destination.name,
            output_root_descriptor=output_root_descriptor,
        )
        raise CalibrationError(
            "durable run directory could not be verified; entry quarantined as "
            + ",".join(quarantined)
        ) from error
    if (
        stat.S_ISLNK(durable.st_mode)
        or not stat.S_ISDIR(durable.st_mode)
        or (durable.st_dev, durable.st_ino) != source_identity
    ):
        quarantined = _quarantine_invalid_published_entry(
            destination.name,
            output_root_descriptor=output_root_descriptor,
        )
        raise CalibrationError(
            "durable run directory identity differs; invalid entry quarantined as "
            + ",".join(quarantined)
        )
    try:
        durable_tree = _snapshot_run_tree_at(
            source_descriptor,
            display_path=destination,
            expected_identity=source_identity,
        )
    except (OSError, CalibrationError) as error:
        quarantined = _quarantine_invalid_published_entry(
            destination.name,
            output_root_descriptor=output_root_descriptor,
        )
        raise CalibrationError(
            "durable run tree changed; invalid entry quarantined as "
            + ",".join(quarantined)
        ) from error
    if durable_tree != sealed_tree:
        quarantined = _quarantine_invalid_published_entry(
            destination.name,
            output_root_descriptor=output_root_descriptor,
        )
        raise CalibrationError(
            "durable run tree binding differs; invalid entry quarantined as "
            + ",".join(quarantined)
        )


def _recover_stale_run_transaction(
    partial: Path,
    *,
    run_id: str,
    output_root: Path,
    output_root_descriptor: int,
    output_root_identity: tuple[int, int],
    preparation_intent: Mapping[str, object] | None = None,
    baseline_history: Sequence[Mapping[str, object]] = (),
) -> Tuple[Tuple[Mapping[str, object], ...], str]:
    try:
        source_descriptor, source_identity = _open_child_directory_nofollow_at(
            output_root_descriptor,
            partial.name,
            display_path=partial,
        )
    except CalibrationError as error:
        raise CalibrationError(
            "run partial exists but is not a recognized owned stale transaction"
        ) from error
    try:
        _verify_pinned_run_directories(
            output_root=output_root,
            output_root_descriptor=output_root_descriptor,
            output_root_identity=output_root_identity,
            partial=partial,
            partial_descriptor=source_descriptor,
            partial_identity=source_identity,
        )
        pre_marker_recovery_action = "not_required"
        pre_marker_recovery_journal = None
        if preparation_intent is not None:
            source_metadata = os.fstat(source_descriptor)
            root_metadata = os.fstat(output_root_descriptor)
            if (
                source_metadata.st_uid != root_metadata.st_uid
                or stat.S_IMODE(source_metadata.st_mode) != 0o700
            ):
                raise CalibrationError(
                    "run partial exists but is not a recognized owned stale transaction"
                )
            transaction_id = str(preparation_intent["transaction_id"])
            marker, pre_marker_recovery_journal = (
                _recover_or_validate_intent_bound_marker(
                    source_descriptor,
                    partial=partial,
                    run_id=run_id,
                    transaction_id=transaction_id,
                    allow_journal_creation=True,
                    allow_inherited_history=(
                        int(
                            preparation_intent[
                                "inherited_recovery_history_count"
                            ]
                        )
                        > 0
                    ),
                )
            )
            pre_marker_recovery_action = str(
                pre_marker_recovery_journal["action"]
            )
            os.fsync(output_root_descriptor)
        else:
            marker = _recognized_run_transaction(
                source_descriptor,
                partial=partial,
                run_id=run_id,
            )
            if marker is None:
                raise CalibrationError(
                    "run partial exists but is not a recognized owned stale transaction"
                )
            transaction_id = str(marker["transaction_id"])
            pre_marker_recovery_journal = (
                _read_pre_marker_recovery_journal_at(
                    source_descriptor,
                    run_id=run_id,
                    transaction_id=transaction_id,
                )
            )
            if pre_marker_recovery_journal is not None:
                marker, pre_marker_recovery_journal = (
                    _recover_or_validate_intent_bound_marker(
                        source_descriptor,
                        partial=partial,
                        run_id=run_id,
                        transaction_id=transaction_id,
                        allow_journal_creation=False,
                        allow_inherited_history=False,
                    )
                )
                pre_marker_recovery_action = str(
                    pre_marker_recovery_journal["action"]
                )
        _verify_pinned_run_directories(
            output_root=output_root,
            output_root_descriptor=output_root_descriptor,
            output_root_identity=output_root_identity,
            partial=partial,
            partial_descriptor=source_descriptor,
            partial_identity=source_identity,
        )
        transaction_id = str(marker["transaction_id"])
        if (
            preparation_intent is not None
            and preparation_intent.get("transaction_id") != transaction_id
        ):
            raise CalibrationError(
                "run transaction intent and partial marker disagree"
            )
        recovered = output_root / f"{run_id}.recovered-{transaction_id}.failed"
        if _entry_exists_at(output_root_descriptor, recovered.name):
            raise CalibrationError(
                "stale transaction recovery destination already exists"
            )

        attempts_path = partial / "attempts.ndjson"
        attempts_missing = not _entry_exists_at(source_descriptor, attempts_path.name)
        if attempts_missing:
            attempt_ledger_payload = b""
        else:
            attempt_ledger_payload = _read_regular_at(
                source_descriptor,
                attempts_path.name,
                display_path=attempts_path,
            )
        try:
            attempt_count: int | None = len(
                _verify_attempt_ledger_payload(attempt_ledger_payload)
            )
            attempt_ledger_validation = "valid"
        except CalibrationError:
            attempt_count = None
            attempt_ledger_validation = "invalid_preserved"
        attempt_ledger_sha256 = hashlib.sha256(attempt_ledger_payload).hexdigest()

        failure_path = partial / "failure.json"
        failure_missing = not _entry_exists_at(source_descriptor, failure_path.name)
        if failure_missing:
            failure: Mapping[str, object] = {
                "schema_version": "1.0.0",
                "artifact_kind": "p06_calibration_failure",
                "run_id": run_id,
                "error_type": "ProcessTerminatedBeforeFinalization",
                "error": (
                    "recognized in-progress transaction remained after prior "
                    "process termination"
                ),
                "attempt_count": attempt_count,
                "attempt_ledger_sha256": attempt_ledger_sha256,
                "attempt_ledger_validation": attempt_ledger_validation,
                "transaction_id": transaction_id,
                "transaction_state": "in_progress",
                "holdout_accessed": False,
                "release_locks_written": False,
            }
        else:
            try:
                failure = json.loads(
                    _read_regular_at(
                        source_descriptor,
                        failure_path.name,
                        display_path=failure_path,
                    )
                )
            except (
                OSError,
                CalibrationError,
                TypeError,
                ValueError,
                UnicodeDecodeError,
                json.JSONDecodeError,
            ) as error:
                raise CalibrationError(
                    "stale transaction failure artifact is invalid"
                ) from error
            if (
                not isinstance(failure, dict)
                or failure.get("schema_version") != "1.0.0"
                or failure.get("artifact_kind") != "p06_calibration_failure"
                or failure.get("run_id") != run_id
                or failure.get("holdout_accessed") is not False
                or failure.get("release_locks_written") is not False
                or failure.get("attempt_ledger_sha256") != attempt_ledger_sha256
                or (
                    attempt_ledger_validation == "valid"
                    and failure.get("attempt_count") != attempt_count
                )
            ):
                raise CalibrationError(
                    "stale transaction failure artifact does not bind its ledger"
                )

        intent_inherited_history = (
            _read_intent_inherited_recovery_history_at(
                output_root_descriptor,
                output_root=output_root,
                run_id=run_id,
                intent=preparation_intent,
            )
            if preparation_intent is not None
            else ()
        )
        if preparation_intent is not None and baseline_history:
            if {
                str(record["stale_transaction_id"]): record
                for record in intent_inherited_history
            } != {
                str(record["stale_transaction_id"]): record
                for record in baseline_history
            }:
                raise CalibrationError(
                    "intent and recovered-archive history bindings differ"
                )
        inherited_history = (
            intent_inherited_history
            if intent_inherited_history
            else tuple(baseline_history)
        )
        partial_history = list(
            _read_recovery_history_at(
                source_descriptor,
                partial=partial,
                run_id=run_id,
            )
        )
        if not inherited_history:
            history = partial_history
        else:
            inherited_by_transaction = {
                str(record["stale_transaction_id"]): record
                for record in inherited_history
            }
            history = list(inherited_history)
            for existing in partial_history:
                existing_transaction_id = str(existing["stale_transaction_id"])
                inherited = inherited_by_transaction.get(existing_transaction_id)
                if inherited is not None:
                    if inherited != existing:
                        raise CalibrationError(
                            "partial and inherited recovery history differ"
                        )
                elif existing_transaction_id == transaction_id:
                    history.append(existing)
                else:
                    raise CalibrationError(
                        "partial recovery history is absent from its inherited binding"
                    )
        prior_matching_records = [
            existing
            for existing in history
            if existing.get("stale_transaction_id") == transaction_id
        ]
        if (
            pre_marker_recovery_action == "not_required"
            and len(prior_matching_records) == 1
        ):
            pre_marker_recovery_action = str(
                prior_matching_records[0]["pre_marker_recovery_action"]
            )
        record: dict[str, object] = {
            "schema_version": "1.0.0",
            "artifact_kind": "p06_stale_run_transaction_recovery",
            "run_id": run_id,
            "stale_transaction_id": transaction_id,
            "stale_transaction_record_sha256": marker["record_sha256"],
            "action": "archived_recognized_stale_partial",
            "recovered_path": recovered.name,
            "cleanup_result": "archived",
            "pre_marker_recovery_action": pre_marker_recovery_action,
        }
        record["record_sha256"] = canonical_sha256(record)
        matching_records = [
            existing
            for existing in history
            if existing.get("stale_transaction_id") == transaction_id
        ]
        if matching_records:
            if matching_records != [record]:
                raise CalibrationError("stale transaction recovery record differs")
        else:
            history.append(record)
        history = list(_canonical_recovery_history(history))

        _verify_pinned_run_directories(
            output_root=output_root,
            output_root_descriptor=output_root_descriptor,
            output_root_identity=output_root_identity,
            partial=partial,
            partial_descriptor=source_descriptor,
            partial_identity=source_identity,
        )
        if attempts_missing:
            _publish_bytes_atomic_durable_at(
                source_descriptor,
                attempts_path.name,
                b"",
                display_path=attempts_path,
                collision_message="stale attempt ledger appeared during recovery",
                allow_identical_existing=False,
            )
        if failure_missing:
            _write_json_atomic_durable(
                failure_path,
                failure,
                parent_descriptor=source_descriptor,
            )
        _write_recovery_history_at(
            source_descriptor,
            partial=partial,
            records=history,
        )
        _verify_pinned_run_directories(
            output_root=output_root,
            output_root_descriptor=output_root_descriptor,
            output_root_identity=output_root_identity,
            partial=partial,
            partial_descriptor=source_descriptor,
            partial_identity=source_identity,
        )
        if preparation_intent is not None:
            _remove_run_transaction_intent_at(
                output_root_descriptor,
                run_id=run_id,
                expected=preparation_intent,
            )
        if pre_marker_recovery_journal is not None:
            _remove_pre_marker_recovery_journal_at(
                source_descriptor,
                expected=pre_marker_recovery_journal,
                run_id=run_id,
                transaction_id=transaction_id,
            )
        _finalize_run_directory(
            partial,
            recovered,
            output_root=output_root,
            output_root_descriptor=output_root_descriptor,
            output_root_identity=output_root_identity,
            source_descriptor=source_descriptor,
            source_identity=source_identity,
        )
        return tuple(history), recovered.name
    finally:
        os.close(source_descriptor)


def _validate_run_id(run_id: object) -> str:
    if (
        not isinstance(run_id, str)
        or not run_id
        or run_id in {".", ".."}
        or Path(run_id).is_absolute()
        or Path(run_id).name != run_id
        or "/" in run_id
        or "\\" in run_id
        or "\x00" in run_id
    ):
        raise CalibrationError("run ID must be one safe filename component")
    return run_id


def verify_preserved_run(path: Path, bound: BoundInputs) -> Mapping[str, object]:
    directory_descriptor, directory_identity = _open_directory_nofollow(path)
    try:
        before = _snapshot_run_tree_at(
            directory_descriptor,
            display_path=path,
            expected_identity=directory_identity,
        )
        try:
            bindings = json.loads(
                _read_regular_at(
                    directory_descriptor,
                    "input-bindings.json",
                    display_path=path / "input-bindings.json",
                )
            )
            attempt_ledger_payload = _read_regular_at(
                directory_descriptor,
                "attempts.ndjson",
                display_path=path / "attempts.ndjson",
            )
            records = _verify_attempt_ledger_payload(attempt_ledger_payload)
            failure = json.loads(
                _read_regular_at(
                    directory_descriptor,
                    "failure.json",
                    display_path=path / "failure.json",
                )
            )
        except (
            OSError,
            CalibrationError,
            TypeError,
            ValueError,
            UnicodeDecodeError,
            json.JSONDecodeError,
        ) as error:
            raise CalibrationError("preserved run artifacts are invalid") from error
        after = _snapshot_run_tree_at(
            directory_descriptor,
            display_path=path,
            expected_identity=directory_identity,
        )
        reopened_descriptor, reopened_identity = _open_directory_nofollow(path)
        os.close(reopened_descriptor)
        if before != after or reopened_identity != directory_identity:
            raise CalibrationError("preserved run directory changed while verifying")
    finally:
        os.close(directory_descriptor)
    if (
        not isinstance(bindings, dict)
        or bindings.get("bundle_sha256") != bound.bundle_sha256
        or bindings.get("records") != list(bound.records)
        or bindings.get("live_holdout_preopen_verification")
        != bound.live_holdout_preopen_verification
    ):
        raise CalibrationBindingError("resume input bindings do not match current inputs")
    if (
        not isinstance(failure, dict)
        or failure.get("schema_version") != "1.0.0"
        or failure.get("artifact_kind") != "p06_calibration_failure"
        or failure.get("holdout_accessed") is not False
        or failure.get("release_locks_written") is not False
        or failure.get("attempt_count") != len(records)
        or failure.get("attempt_ledger_sha256")
        != hashlib.sha256(attempt_ledger_payload).hexdigest()
    ):
        raise CalibrationError("preserved failure does not bind its attempt ledger")
    return {
        "path": path.name,
        "input_bundle_sha256": bound.bundle_sha256,
        "attempt_ledger_sha256": failure["attempt_ledger_sha256"],
        "attempt_count": len(records),
    }


class CalibrationExecutor:
    """Execute deterministic development tuning and validation selection."""

    def __init__(
        self,
        *,
        repository_root: Path,
        output_root: Path,
        run_id: str,
        candidate: CalibrationCandidate,
        live_holdout_preopen_binding: LiveHoldoutPreopenBinding,
        analytic_test_mode: bool = False,
        implementation_manifest_validator: Optional[
            Callable[[Mapping[str, object], Path], str]
        ] = None,
        open_split_root: Optional[Path] = None,
        analytic_case_provider: Optional[
            Callable[[str, Sequence[Mapping[str, object]]], Sequence[PlanarFrame]]
        ] = None,
        dispatch_measurement_root: Optional[Path] = None,
        analytic_measurement_resolver: Optional[
            Callable[[Mapping[str, object]], Mapping[str, object]]
        ] = None,
        resume_from: Optional[Path] = None,
    ) -> None:
        self.repository_root = repository_root.resolve(strict=True)
        self.output_root = output_root
        self.run_id = _validate_run_id(run_id)
        self.candidate = candidate
        self.live_holdout_preopen_binding = live_holdout_preopen_binding
        self.analytic_test_mode = analytic_test_mode
        self.implementation_manifest_validator = implementation_manifest_validator
        self.open_split_root = open_split_root
        self.analytic_case_provider = analytic_case_provider
        self.dispatch_measurement_root = dispatch_measurement_root
        self.analytic_measurement_resolver = analytic_measurement_resolver
        self._loaded_split_frames: Dict[str, Tuple[PlanarFrame, ...]] = {}
        self._development_control_selections: Dict[str, ControlSelectionBundle] = {}
        self._validation_control_selections: Dict[str, ControlSelectionBundle] = {}
        self._validation_candidate_evidence_path: Optional[Path] = None
        self._validation_candidate_evidence_file_binding: Optional[
            Mapping[str, object]
        ] = None
        self._validation_candidate_evidence_binding: Optional[
            ValidationCandidateEvidenceBinding
        ] = None
        self.resume_from = resume_from
        if candidate.analytic_fixture != analytic_test_mode:
            raise CalibrationError("analytic candidate and executor mode must agree exactly")
        if analytic_test_mode != (analytic_case_provider is not None):
            raise CalibrationError("analytic mode requires exactly one analytic case provider")
        if not analytic_test_mode and open_split_root is None:
            raise CalibrationError("normal calibration requires an explicit open-split root")
        if analytic_test_mode:
            if analytic_measurement_resolver is None or dispatch_measurement_root is not None:
                raise CalibrationError("analytic mode requires only an injected measurement resolver")
            self.measurement_resolver = analytic_measurement_resolver
        else:
            if dispatch_measurement_root is None or analytic_measurement_resolver is not None:
                raise CalibrationError("normal mode requires only a dispatch-measurement root")
            self.measurement_resolver = MeasurementArtifactResolver(
                dispatch_measurement_root
            )

    def _split_frames(
        self,
        bound: BoundInputs,
        split: str,
        samples: Sequence[Mapping[str, object]],
    ) -> Tuple[PlanarFrame, ...]:
        if split in self._loaded_split_frames:
            return self._loaded_split_frames[split]
        if split not in {"development", "validation"}:
            raise CalibrationBindingError("frame capability rejects sealed holdout")
        if self.analytic_test_mode:
            assert self.analytic_case_provider is not None
            provided = tuple(self.analytic_case_provider(split, samples))
        else:
            assert self.open_split_root is not None
            root = self.open_split_root
            try:
                metadata = os.stat(root, follow_symlinks=False)
            except OSError as error:
                raise CalibrationBindingError("open-split root is absent") from error
            if root.is_symlink() or not stat.S_ISDIR(metadata.st_mode):
                raise CalibrationBindingError("open-split root is symbolic or not a directory")
            resolved = root.resolve(strict=True)
            loader = (
                load_development_samples
                if split == "development"
                else load_validation_samples
            )
            loaded = loader(
                bound.documents[f"{split}_sample_lock"],
                bound.documents["corpus_lock"],
                sample_root=resolved,
                asset_root=resolved,
            )
            if [asset.get("source_asset_id") for asset, _ in loaded] != [
                sample["source_asset_id"] for sample in samples
            ]:
                raise CalibrationBindingError("loaded split frame order differs from lock")
            provided = tuple(frame for _, frame in loaded)
        if len(provided) != len(samples):
            raise CalibrationBindingError("split frame provider returned the wrong count")
        for frame, sample in zip(provided, samples):
            if frame_sha256(frame) != sample.get("target_frame_sha256"):
                raise CalibrationBindingError("split frame provider returned unlocked pixels")
        frozen = tuple(LockedDegradationCache._freeze(frame) for frame in provided)
        self._loaded_split_frames[split] = frozen
        return frozen

    def _evaluate(
        self,
        vector: Mapping[str, object],
        split: str,
        *,
        bound: BoundInputs,
        plan: Mapping[str, object],
        tolerances: Mapping[str, object],
        cache: LockedDegradationCache,
    ) -> Tuple[Mapping[str, object], Mapping[str, object], bool, Tuple[str, ...]]:
        bound.verify_unchanged()
        vector_hash = candidate_vector_sha256(vector, plan)
        bank_hash = shared_bank_configuration_sha256(vector, plan)
        development_selection = self._development_control_selections.get(bank_hash)
        existing_stage_selection = (
            development_selection
            if split == "development"
            else self._validation_control_selections.get(bank_hash)
        )
        validation_candidate_evidence = None
        if split == "validation" and development_selection is None:
            raise CalibrationError(
                "validation candidate has no development-provisional control selection"
            )
        if split == "validation":
            if (
                self._validation_candidate_evidence_path is None
                or self._validation_candidate_evidence_file_binding is None
                or self._validation_candidate_evidence_binding is None
            ):
                raise CalibrationError(
                    "validation candidate has no verified development freeze"
                )
            validation_candidate_evidence = (
                _verify_validation_candidate_evidence_file(
                    self._validation_candidate_evidence_path,
                    expected_file_binding=(
                        self._validation_candidate_evidence_file_binding
                    ),
                    expected_binding=(
                        self._validation_candidate_evidence_binding
                    ),
                )
            )
            if vector_hash not in (
                validation_candidate_evidence
                .validation_candidate_vector_sha256_values
            ):
                raise CalibrationError(
                    "validation vector is outside the development-frozen set"
                )
            base_selection = (
                existing_stage_selection
                if existing_stage_selection is not None
                else development_selection
            )
            assert base_selection is not None
            supplied_selection = _bind_validation_candidate_evidence(
                base_selection,
                validation_candidate_evidence,
            )
        else:
            supplied_selection = existing_stage_selection
            if (
                supplied_selection is not None
                and supplied_selection.validation_candidate_evidence is not None
            ):
                raise CalibrationError(
                    "development control selection exposes validation-only evidence"
                )

        _validate_mandatory_control_bank_compatibility(
            vector,
            bound.documents["baseline_ablation_contract"],
        )

        # Immutable binding/hash checks and candidate evaluation preconditions above
        # must complete before this first possible split metadata or pixel access.
        samples = load_split_metadata(bound, split)
        frames = self._split_frames(bound, split, samples)
        view = _evaluation_view(bound, split, samples, frames)
        adapter = self.candidate.adapter_factory(vector, split)
        primary_error: Optional[BaseException] = None
        try:
            _validate_runtime_adapter(
                adapter,
                vector,
                plan,
                bound,
                analytic_test_mode=self.analytic_test_mode,
            )
            tracker = _AdapterInvocationTracker(
                source_adapter=adapter,
                calls=[],
                control_calls=[],
                control_native_calls=[],
            )
            tracked_adapter = tracker.adapter()
            evaluation = self.candidate.evaluator(
                tracked_adapter,
                vector,
                view,
                cache,
                supplied_selection,
            )
            if view._unconsumed_case_tokens():
                raise CalibrationError(
                    "candidate evaluator did not consume every locked split case"
                )
            _validate_evaluation_shape(
                evaluation,
                vector=vector,
                plan=plan,
                bound=bound,
                vector_hash=vector_hash,
                split=split,
                adapter=adapter,
                samples=samples,
                tracked_calls=tracker.calls,
                native_records=tracker.native_records(),
                tracked_control_calls=tracker.control_calls,
                control_native_records=tracker.control_native_records(),
                degradation_cache=cache,
                development_control_selection=development_selection,
                existing_stage_control_selection=existing_stage_selection,
                validation_candidate_evidence=validation_candidate_evidence,
            )
            produced_selection = _control_selection_bundle(
                evaluation,
                validation_candidate_evidence=validation_candidate_evidence,
            )
            expected_stage = (
                "development_provisional"
                if split == "development"
                else "validation_final"
            )
            if (
                produced_selection.selection_stage != expected_stage
                or produced_selection.shared_bank_configuration_sha256 != bank_hash
            ):
                raise CalibrationError("control selection bundle stage or bank differs")
            if split == "development":
                self._development_control_selections.setdefault(
                    bank_hash, produced_selection
                )
            else:
                self._validation_control_selections.setdefault(
                    bank_hash, produced_selection
                )
            _validate_dispatch_measurement_evidence(
                evaluation,
                vector=vector,
                plan=plan,
                adapter=adapter,
                bound=bound,
                resolver=self.measurement_resolver,
            )
            summary = summarize_evaluation(evaluation, tolerances)
            feasible, failures = evaluation_feasible(
                evaluation,
                summary,
                tolerances,
            )
            bound.verify_unchanged()
            return evaluation, summary, feasible, failures
        except BaseException as error:
            primary_error = error
            raise
        finally:
            close = getattr(adapter.callable, "close", None)
            if close is None and not self.analytic_test_mode:
                if primary_error is None:
                    raise CalibrationError(
                        "production candidate adapter has no close capability"
                    )
            elif close is not None and not callable(close):
                if primary_error is None:
                    raise CalibrationError(
                        "candidate adapter close capability is not callable"
                    )
            elif close is not None:
                try:
                    close()
                except BaseException as close_error:
                    if primary_error is None:
                        if not isinstance(close_error, Exception):
                            raise
                        raise CalibrationError(
                            "candidate adapter close failed"
                        ) from close_error

    def run(self) -> Path:
        self.output_root.mkdir(parents=True, exist_ok=True)
        final = self.output_root / self.run_id
        partial = self.output_root / f".{self.run_id}.partial"
        failed = self.output_root / f"{self.run_id}.failed"
        output_root_descriptor, output_root_identity = _open_directory_nofollow(
            self.output_root
        )
        partial_descriptor = -1
        development_selection_cache: Optional[
            _DevelopmentControlSelectionCache
        ] = None
        active_intent: Mapping[str, object] | None = None
        try:
            if _entry_exists_at(output_root_descriptor, final.name) or _entry_exists_at(
                output_root_descriptor,
                failed.name,
            ):
                raise CalibrationError(
                    "run destination already exists; overwrite is forbidden"
                )
            recovery_history, recovery_history_source = (
                _scan_recovered_history_at(
                    output_root_descriptor,
                    output_root=self.output_root,
                    run_id=self.run_id,
                )
            )
            stale_intent = _read_run_transaction_intent_at(
                output_root_descriptor,
                run_id=self.run_id,
            )
            if stale_intent is not None and not _entry_exists_at(
                output_root_descriptor,
                partial.name,
            ):
                _verify_pinned_output_root(
                    output_root=self.output_root,
                    output_root_descriptor=output_root_descriptor,
                    output_root_identity=output_root_identity,
                )
                os.mkdir(partial.name, 0o700, dir_fd=output_root_descriptor)
                os.fsync(output_root_descriptor)
            if _entry_exists_at(output_root_descriptor, partial.name):
                recovery_history, recovery_history_source = (
                    _recover_stale_run_transaction(
                        partial,
                        run_id=self.run_id,
                        output_root=self.output_root,
                        output_root_descriptor=output_root_descriptor,
                        output_root_identity=output_root_identity,
                        preparation_intent=stale_intent,
                        baseline_history=recovery_history,
                    )
                )
            transaction_id = str(uuid.uuid4())
            _verify_pinned_output_root(
                output_root=self.output_root,
                output_root_descriptor=output_root_descriptor,
                output_root_identity=output_root_identity,
            )
            active_intent = _create_run_transaction_intent_at(
                output_root_descriptor,
                run_id=self.run_id,
                transaction_id=transaction_id,
                inherited_recovery_history=recovery_history,
                inherited_recovery_source=recovery_history_source,
            )
            os.mkdir(partial.name, 0o700, dir_fd=output_root_descriptor)
            os.fsync(output_root_descriptor)
            partial_descriptor, partial_identity = _open_child_directory_nofollow_at(
                output_root_descriptor,
                partial.name,
                display_path=partial,
            )

            def verify_transaction_paths() -> None:
                _verify_pinned_run_directories(
                    output_root=self.output_root,
                    output_root_descriptor=output_root_descriptor,
                    output_root_identity=output_root_identity,
                    partial=partial,
                    partial_descriptor=partial_descriptor,
                    partial_identity=partial_identity,
                )

            verify_transaction_paths()
            _write_json_atomic_durable(
                partial / _RUN_TRANSACTION_MARKER,
                _run_transaction_marker(self.run_id, transaction_id),
                parent_descriptor=partial_descriptor,
            )
            os.fsync(output_root_descriptor)
            verify_transaction_paths()
            _write_recovery_history_at(
                partial_descriptor,
                partial=partial,
                records=recovery_history,
            )
            verify_transaction_paths()
            _remove_run_transaction_intent_at(
                output_root_descriptor,
                run_id=self.run_id,
                expected=active_intent,
            )
            active_intent = None
            verify_transaction_paths()
            ledger = AttemptLedger(
                partial / "attempts.ndjson",
                directory_descriptor=partial_descriptor,
            )
        except BaseException:
            partial_removed = False
            if partial_descriptor >= 0:
                try:
                    _verify_pinned_run_directories(
                        output_root=self.output_root,
                        output_root_descriptor=output_root_descriptor,
                        output_root_identity=output_root_identity,
                        partial=partial,
                        partial_descriptor=partial_descriptor,
                        partial_identity=partial_identity,
                    )
                    os.rmdir(partial.name, dir_fd=output_root_descriptor)
                    os.fsync(output_root_descriptor)
                    partial_removed = True
                except BaseException:
                    pass
                os.close(partial_descriptor)
            if active_intent is not None and partial_removed:
                try:
                    _remove_run_transaction_intent_at(
                        output_root_descriptor,
                        run_id=self.run_id,
                        expected=active_intent,
                    )
                except BaseException:
                    pass
            os.close(output_root_descriptor)
            raise
        try:
            bound = bind_preregistered_inputs(
                self.repository_root,
                live_holdout_preopen_binding=self.live_holdout_preopen_binding,
                implementation_manifest_validator=self.implementation_manifest_validator,
            )
            configure_selection_cache = getattr(
                self.candidate.evaluator,
                "configure_development_control_selection_cache",
                None,
            )
            if configure_selection_cache is not None:
                if not callable(configure_selection_cache):
                    raise CalibrationBindingError(
                        "development control-selection cache configurator is invalid"
                    )
                cache_root = Path(
                    os.path.abspath(
                        os.fspath(
                            self.output_root
                            / _DEVELOPMENT_CONTROL_SELECTION_CACHE_DIRECTORY
                        )
                    )
                )
                development_selection_cache = (
                    _DevelopmentControlSelectionCache(cache_root)
                )
                configure_selection_cache(development_selection_cache)
            verify_transaction_paths()
            _write_json_atomic_durable(
                partial / "input-bindings.json",
                {
                    "bundle_sha256": bound.bundle_sha256,
                    "records": list(bound.records),
                    "live_holdout_preopen_verification": dict(
                        bound.live_holdout_preopen_verification
                    ),
                },
                parent_descriptor=partial_descriptor,
            )
            resume_record = None
            if self.resume_from is not None:
                resume_record = verify_preserved_run(self.resume_from, bound)
            plan = bound.documents["calibration_plan"]
            tolerances = bound.documents["metric_performance_tolerances"]
            validate_schema(
                tolerances,
                SCHEMAS_ROOT / "metric-performance-tolerances-v1.schema.json",
            )
            domains = parameter_domains(plan)
            order = plan["search"]["parameter_order"]
            current = dict(plan["search"]["initial_vector_values"])
            validate_candidate_vector(current, plan)
            degradation_cache = LockedDegradationCache(
                _degradation_policy_cache_sha256(bound)
            )
            evaluation_cache: Dict[Tuple[str, str], Tuple[Mapping[str, object], Mapping[str, object], bool, Tuple[str, ...]]] = {}
            evaluation_bindings: Dict[Tuple[str, str], Mapping[str, object]] = {}
            control_selection_bindings: Dict[
                Tuple[str, str], Tuple[Mapping[str, object], ...]
            ] = {}

            def attempt(
                vector: Mapping[str, object],
                split: str,
                *,
                phase: str,
                sweep: int,
                coordinate: Optional[str],
                value: object,
            ) -> Optional[Tuple[Mapping[str, object], Mapping[str, object], bool, Tuple[str, ...]]]:
                try:
                    validate_candidate_vector(vector, plan)
                except CalibrationError as error:
                    ledger.append(
                        {
                            "phase": phase,
                            "split": split,
                            "sweep": sweep,
                            "coordinate": coordinate,
                            "value": value,
                            "candidate_vector": dict(vector),
                            "candidate_vector_sha256": canonical_sha256(dict(vector)),
                            "status": "constraint_failure",
                            "cache_hit": False,
                            "failure_reasons": [str(error)],
                        }
                    )
                    return None
                vector_hash = candidate_vector_sha256(vector, plan)
                key = (split, vector_hash)
                cache_hit = key in evaluation_cache
                try:
                    if not cache_hit:
                        evaluation_cache[key] = self._evaluate(
                            vector,
                            split,
                            bound=bound,
                            plan=plan,
                            tolerances=tolerances,
                            cache=degradation_cache,
                        )
                        verify_transaction_paths()
                        evaluation_bindings[key] = _write_content_addressed_evaluation(
                            partial,
                            evaluation_cache[key][0],
                            run_root_descriptor=partial_descriptor,
                        )
                        control_selection_bindings[key] = (
                            _write_control_selection_artifacts(
                                partial,
                                evaluation_cache[key][0],
                                run_root_descriptor=partial_descriptor,
                            )
                        )
                    result = evaluation_cache[key]
                    _, summary, feasible, failures = result
                    canonical_failures = canonical_development_failure_reasons(
                        failures
                    ) if split == "development" else ()
                    ledger.append(
                        {
                            "phase": phase,
                            "split": split,
                            "sweep": sweep,
                            "coordinate": coordinate,
                            "value": value,
                            "candidate_vector": dict(vector),
                            "candidate_vector_sha256": vector_hash,
                            "status": "feasible" if feasible else "infeasible",
                            "cache_hit": cache_hit,
                            "failure_reasons": list(failures),
                            **(
                                {
                                    "canonical_failure_reasons": list(
                                        canonical_failures
                                    ),
                                    "canonical_failure_count": len(
                                        canonical_failures
                                    ),
                                    "development_search_rank_sha256": (
                                        development_search_rank_sha256(
                                            result,
                                            vector,
                                            plan,
                                        )
                                    ),
                                }
                                if split == "development"
                                else {}
                            ),
                            "summary_sha256": canonical_sha256(summary),
                            "evaluation": evaluation_bindings[key],
                            "control_selection_artifacts": list(
                                control_selection_bindings[key]
                            ),
                        }
                    )
                    return result
                except CalibrationBindingError:
                    raise
                except Exception as error:
                    ledger.append(
                        {
                            "phase": phase,
                            "split": split,
                            "sweep": sweep,
                            "coordinate": coordinate,
                            "value": value,
                            "candidate_vector": dict(vector),
                            "candidate_vector_sha256": vector_hash,
                            "status": "evaluation_failure",
                            "cache_hit": cache_hit,
                            "failure_reasons": [f"{type(error).__name__}: {error}"],
                        }
                    )
                    return None

            initial = attempt(
                current,
                "development",
                phase="initial",
                sweep=0,
                coordinate=None,
                value=None,
            )
            maximum_sweeps = int(plan["search"]["maximum_sweeps"])
            terminal = None
            sweep_count = 0
            for sweep in range(1, maximum_sweeps + 1):
                sweep_count = sweep
                changed = False
                for coordinate in order:
                    successful_values = []
                    for value in domains[coordinate]:
                        candidate_vector = dict(current)
                        candidate_vector[coordinate] = value
                        result = attempt(
                            candidate_vector,
                            "development",
                            phase="coordinate_search",
                            sweep=sweep,
                            coordinate=coordinate,
                            value=value,
                        )
                        if result is not None:
                            successful_values.append((candidate_vector, result))
                    if successful_values:
                        best_vector, _ = min(
                            successful_values,
                            key=lambda item: development_search_key(
                                item[1],
                                item[0],
                                plan,
                            ),
                        )
                        if best_vector[coordinate] != current[coordinate]:
                            changed = True
                        current = dict(best_vector)
                terminal_result = evaluation_cache.get(
                    ("development", candidate_vector_sha256(current, plan))
                )
                if terminal_result is not None and terminal_result[2]:
                    terminal = dict(current)
                if not changed:
                    break
            else:
                raise CalibrationError("coordinate search did not terminate within eight sweeps")
            if terminal is None:
                raise CalibrationError("coordinate search produced no development-feasible terminal vector")

            terminal_hash = candidate_vector_sha256(terminal, plan)
            neighbor_vectors = one_coordinate_neighbors(terminal, plan)
            neighbor_evidence = []
            validation_vectors = []
            for vector in neighbor_vectors:
                vector_hash = candidate_vector_sha256(vector, plan)
                key = ("development", vector_hash)
                development_result = evaluation_cache.get(key)
                development_binding = evaluation_bindings.get(key)
                if development_result is None or development_binding is None:
                    raise CalibrationError(
                        "validation neighbor lacks exact development evaluation evidence"
                    )
                _, development_summary, development_feasible, _ = development_result
                neighbor_evidence.append(
                    {
                        "candidate_vector_sha256": vector_hash,
                        "development_feasible": development_feasible,
                        "development_summary_sha256": canonical_sha256(
                            development_summary
                        ),
                        "development_evaluation": development_binding,
                    }
                )
                if development_feasible:
                    validation_vectors.append(vector)
            if not validation_vectors:
                raise CalibrationError(
                    "no terminal/neighbor candidate is development-feasible for validation"
                )
            validation_candidate_evidence = {
                "schema_version": "1.0.0",
                "artifact_kind": "p06_validation_candidate_development_evidence",
                "development_terminal_vector_sha256": terminal_hash,
                "neighbor_evidence": neighbor_evidence,
                "validation_candidate_vector_sha256_values": [
                    candidate_vector_sha256(vector, plan)
                    for vector in validation_vectors
                ],
                "validation_accessed_while_building": False,
            }
            validation_candidate_evidence["manifest_sha256"] = manifest_sha256(
                validation_candidate_evidence
            )
            validate_schema(
                validation_candidate_evidence,
                SCHEMAS_ROOT
                / "validation-candidate-development-evidence-v1.schema.json",
            )
            validation_candidate_path = partial / "validation-candidate-evidence.json"
            verify_transaction_paths()
            _write_json_atomic_durable(
                validation_candidate_path,
                validation_candidate_evidence,
                parent_descriptor=partial_descriptor,
            )
            validation_candidate_payload = _read_regular_at(
                partial_descriptor,
                validation_candidate_path.name,
                display_path=validation_candidate_path,
            )
            validation_candidate_binding = {
                "path": "validation-candidate-evidence.json",
                "sha256": hashlib.sha256(validation_candidate_payload).hexdigest(),
                "size_bytes": len(validation_candidate_payload),
            }
            verify_transaction_paths()
            verified_validation_candidate_binding = (
                _verify_validation_candidate_evidence_file(
                    validation_candidate_path,
                    expected_file_binding=validation_candidate_binding,
                )
            )
            if (
                verified_validation_candidate_binding.manifest_sha256
                != validation_candidate_evidence["manifest_sha256"]
                or verified_validation_candidate_binding
                .development_terminal_vector_sha256
                != terminal_hash
                or list(
                    verified_validation_candidate_binding
                    .validation_candidate_vector_sha256_values
                )
                != validation_candidate_evidence[
                    "validation_candidate_vector_sha256_values"
                ]
            ):
                raise CalibrationBindingError(
                    "written validation-candidate freeze differs from development evidence"
                )
            self._validation_candidate_evidence_path = validation_candidate_path
            self._validation_candidate_evidence_file_binding = dict(
                validation_candidate_binding
            )
            self._validation_candidate_evidence_binding = (
                verified_validation_candidate_binding
            )

            validation_results = []
            for vector in validation_vectors:
                result = attempt(
                    vector,
                    "validation",
                    phase="validation_selection",
                    sweep=sweep_count,
                    coordinate=None,
                    value=None,
                )
                if result is not None and result[2]:
                    validation_results.append((vector, result[1]))
            if not validation_results:
                raise CalibrationError("validation selection has no feasible candidate")
            frontier = pareto_frontier(validation_results, split="validation", plan=plan)
            selected_vector, selected_summary = min(
                frontier,
                key=lambda item: validation_objective_key(item[1], item[0], plan),
            )
            selected_hash = candidate_vector_sha256(selected_vector, plan)
            selected_evaluation = evaluation_cache[("validation", selected_hash)][0]
            dispatch_budget = derive_dispatch_budget(
                selected_evaluation["dispatch_measurement"],
                tolerances,
                resolver=self.measurement_resolver,
            )
            bound.verify_unchanged()

            ledger.close()
            verify_transaction_paths()
            attempt_ledger_payload = _read_regular_at(
                partial_descriptor,
                "attempts.ndjson",
                display_path=partial / "attempts.ndjson",
                expected_identity=ledger.entry_identity,
            )
            attempt_records = _verify_attempt_ledger_payload(
                attempt_ledger_payload
            )
            development_sequences = [
                record["sequence"]
                for record in attempt_records
                if record.get("split") == "development"
            ]
            validation_sequences = [
                record["sequence"]
                for record in attempt_records
                if record.get("split") == "validation"
            ]
            if (
                not development_sequences
                or not validation_sequences
                or max(development_sequences) >= min(validation_sequences)
            ):
                raise CalibrationError("development and validation attempt stages overlap")
            run_ledger = {
                "schema_version": "1.0.0",
                "artifact_kind": "p06_calibration_run_ledger",
                "run_id": self.run_id,
                "plan_id": plan["plan_id"],
                "input_bundle_sha256": bound.bundle_sha256,
                "input_bindings": list(bound.records),
                "live_holdout_preopen_verification": dict(
                    bound.live_holdout_preopen_verification
                ),
                "attempt_count": len(attempt_records),
                "attempt_ledger": {
                    "path": "attempts.ndjson",
                    "sha256": hashlib.sha256(attempt_ledger_payload).hexdigest(),
                    "last_record_sha256": (
                        attempt_records[-1]["record_sha256"] if attempt_records else "0" * 64
                    ),
                },
                "maximum_sweeps": maximum_sweeps,
                "completed_sweeps": sweep_count,
                "termination": "complete_sweep_changed_no_coordinate",
                "development_terminal_vector_sha256": terminal_hash,
                "validation_candidate_count": len(validation_vectors),
                "validation_feasible_count": len(validation_results),
                "validation_candidate_development_evidence": validation_candidate_binding,
                "data_separation_evidence": {
                    "development_attempt_count": len(development_sequences),
                    "validation_attempt_count": len(validation_sequences),
                    "last_development_attempt_sequence": max(
                        development_sequences
                    ),
                    "first_validation_attempt_sequence": min(
                        validation_sequences
                    ),
                    "all_development_attempts_precede_validation": True,
                    "development_validation_measurement_binding_count": 0,
                    "holdout_accessed": False,
                },
                "holdout_accessed": False,
                "release_locks_written": False,
                "resume_source": resume_record,
                "degradation_cache": degradation_cache.evidence(),
                "candidate_evaluations": [
                    {"split": split, "candidate_vector_sha256": vector_hash, **binding}
                    for (split, vector_hash), binding in sorted(evaluation_bindings.items())
                ],
                "control_selection_artifacts": [
                    {
                        "split": split,
                        "candidate_vector_sha256": vector_hash,
                        **binding,
                    }
                    for (split, vector_hash), bindings in sorted(
                        control_selection_bindings.items()
                    )
                    for binding in bindings
                ],
                "status": "selection_ready_not_release_locked",
            }
            run_ledger["manifest_sha256"] = manifest_sha256(run_ledger)
            validate_schema(run_ledger, SCHEMAS_ROOT / "calibration-run-ledger-v1.schema.json")
            selection = {
                "schema_version": "1.0.0",
                "artifact_kind": "p06_calibration_selection",
                "run_id": self.run_id,
                "input_bundle_sha256": bound.bundle_sha256,
                "live_holdout_preopen_verification": dict(
                    bound.live_holdout_preopen_verification
                ),
                "development_terminal_vector": terminal,
                "development_terminal_vector_sha256": terminal_hash,
                "validation_candidate_vector_sha256_values": [
                    candidate_vector_sha256(vector, plan) for vector in validation_vectors
                ],
                "validation_candidate_development_evidence": validation_candidate_binding,
                "validation_feasible_vector_sha256_values": [
                    candidate_vector_sha256(vector, plan) for vector, _ in validation_results
                ],
                "pareto_frontier_vector_sha256_values": [
                    candidate_vector_sha256(vector, plan) for vector, _ in frontier
                ],
                "selected_vector": selected_vector,
                "selected_vector_sha256": selected_hash,
                "selected_summary": selected_summary,
                "selected_evaluation_sha256": canonical_sha256(selected_evaluation),
                "selected_controls": selected_evaluation["comparison_identities"],
                "selected_control_selection_artifacts": list(
                    control_selection_bindings[("validation", selected_hash)]
                ),
                "baseline_ablation_contract_sha256": bound.record(
                    "baseline_ablation_contract"
                )["sha256"],
                "quality_policy_seed_sha256": bound.record(
                    "quality_gate_policy_seed"
                )["sha256"],
                "corpus_lock_bundle_sha256": corpus_lock_bundle_sha256(bound),
                "dispatch_budget": dispatch_budget,
                "holdout_accessed": False,
                "release_locks_written": False,
                "status": "selection_ready_not_release_locked",
            }
            selection["manifest_sha256"] = manifest_sha256(selection)
            validate_schema(selection, SCHEMAS_ROOT / "calibration-selection-v1.schema.json")
            verify_transaction_paths()
            _write_json_atomic_durable(
                partial / "calibration-run-ledger.json",
                run_ledger,
                parent_descriptor=partial_descriptor,
            )
            _write_json_atomic_durable(
                partial / "selection.json",
                selection,
                parent_descriptor=partial_descriptor,
            )
            _finalize_run_directory(
                partial,
                final,
                output_root=self.output_root,
                output_root_descriptor=output_root_descriptor,
                output_root_identity=output_root_identity,
                source_descriptor=partial_descriptor,
                source_identity=partial_identity,
            )
            return final
        except BaseException as error:
            archive_succeeded = False
            try:
                ledger.close()
                verify_transaction_paths()
                attempt_ledger_payload = _read_regular_at(
                    partial_descriptor,
                    "attempts.ndjson",
                    display_path=partial / "attempts.ndjson",
                    expected_identity=ledger.entry_identity,
                )
                try:
                    attempt_count = len(
                        _verify_attempt_ledger_payload(attempt_ledger_payload)
                    )
                    ledger_hash = hashlib.sha256(attempt_ledger_payload).hexdigest()
                except Exception:
                    attempt_count = len(ledger.records)
                    ledger_hash = hashlib.sha256(attempt_ledger_payload).hexdigest()
                _write_json_atomic_durable(
                    partial / "failure.json",
                    {
                        "schema_version": "1.0.0",
                        "artifact_kind": "p06_calibration_failure",
                        "run_id": self.run_id,
                        "error_type": type(error).__name__,
                        "error": str(error),
                        "attempt_count": attempt_count,
                        "attempt_ledger_sha256": ledger_hash,
                        "holdout_accessed": False,
                        "release_locks_written": False,
                    },
                    parent_descriptor=partial_descriptor,
                )
                _finalize_run_directory(
                    partial,
                    failed,
                    output_root=self.output_root,
                    output_root_descriptor=output_root_descriptor,
                    output_root_identity=output_root_identity,
                    source_descriptor=partial_descriptor,
                    source_identity=partial_identity,
                )
                archive_succeeded = True
            except BaseException:
                archive_succeeded = False
            if isinstance(error, Exception) and archive_succeeded:
                raise CalibrationRunInterrupted(str(error), failed) from error
            raise
        finally:
            if development_selection_cache is not None:
                development_selection_cache.close()
            os.close(partial_descriptor)
            os.close(output_root_descriptor)
