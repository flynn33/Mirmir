"""Concrete release-locked P07 native evaluator.

All release, compiler, control-selection, degradation, and analytic-fixture
identities are resolved before a holdout access guard is entered.  The native
compiler is run again in the isolated P07 cache and both resulting LUT files
must be byte-identical to the locked P06 release files.  The evaluator callback
then accepts only the extraction document and temporary crop directory exposed
by :class:`P07HoldoutExecutor`.
"""

from __future__ import annotations

from contextlib import contextmanager
from dataclasses import dataclass
import hashlib
import json
import math
import os
from pathlib import Path
import stat
import subprocess
import uuid
from typing import Callable, Dict, Iterator, Mapping, MutableMapping, Optional, Sequence, Tuple

from validation.calibration_v2.native_adapter.factory import (
    NativeCandidateCallable,
    NativeCandidateAdapterFactory,
    NativeConfiguration,
    NativeExecutable,
    NativeSwiftSession,
    P00NativeHelper,
    _run_checked,
    authorized_process_environment,
    run_authorized_process,
)
from validation.calibration_v2.macos_code_identity import (
    authorize_running_code,
    static_code_identity,
)
from validation.calibration_v2.p07.execution import (
    P07ContextualError,
    P07DualFailure,
    P07ExecutionError,
    P07MediaContext,
    P07Preflight,
    _canonical_bytes,
    _decode_json,
    _path_under,
    _read_json,
    _read_regular_file,
    _validate_existing_path,
)
from validation.calibration_v2.p07.gate import (
    CONTROL_ORDER,
    CONVENTIONAL_CONTROLS,
    DEGRADATION_KIND_ORDER,
    DOMAINS,
    FIXED_CONTROLS,
)
from validation.calibration_v2.release_evidence import evidence_binding
from validation.calibration_v2.production_evaluator import (
    CONVENTIONAL_ALGORITHM_IDS,
    ControlSelectionBundle,
    ProductionEvaluatorError,
    _freeze_frame,
    _invoke_native_control,
    _validate_writer_round_trip,
    conventional_control_request,
    degradation_native_input,
    fixed_control_request,
    make_control_selection_bundle,
)
from validation.calibration_v2.production_providers import (
    ContentAddressedEvidenceStore,
    NativeProductionWriterCapability,
    _analytic_metric_bundle,
    content_addressed_evidence_store,
    production_writer_settings_document,
    production_writer_capability,
)
from validation.calibration_v2.runner import (
    candidate_vector_sha256,
    shared_bank_configuration_sha256,
)
from validation.quality.src.mirmir_quality.arrays import (
    PlanarFrame,
    frame_sha256,
)
from validation.quality.src.mirmir_quality.conformance import (
    _analytic_reference,
)
from validation.quality.src.mirmir_quality.degradation import apply_degradation
from validation.quality.src.mirmir_quality.json_tools import (
    canonical_json_bytes,
    canonical_sha256,
    manifest_sha256,
    validate_schema,
)
from validation.quality.src.mirmir_quality.metrics import (
    channel_psnr,
    ms_ssim,
    ssim,
)
from validation.quality.src.mirmir_quality.common_writer import (
    PRODUCT_MEDIA_TYPES_PATH,
    ProductionWriterAuthorizedExecution,
)
from validation.quality.src.mirmir_quality.production_dry_run import (
    CandidateAdapter,
    CandidateContext,
    _round_trip_locked_bt709_video_range_nv12,
    _video_range_nv12_to_planar,
)


ROUTE_ORDER = ("direct-2x", "direct-3over2")
ROUTE_FILENAMES = {
    "direct-2x": "direct2x.ashlut",
    "direct-3over2": "direct3over2.ashlut",
}
RELEASE_ARTIFACT_IDS = {
    "selection": "calibration_selection",
    "evaluation": "selected_evaluation",
    "mapping": "locked_mapping",
    "operator_bank": "locked_operator_bank",
    "metric_policy": "locked_metric_policy",
    "compiler_input": "locked_compiler_input",
    "lut_manifest": "lut_manifest",
    "configuration_lock": "configuration_lock",
    "evidence_closure": "evidence_closure",
}
RAW_OUTPUT_CONTRACT = {
    "pixel_contract": "bt709-video-range-420v-8bit-nv12-v1",
    "chroma_conversion": (
        "ASHLockedCandidateAdapterBridgeV2.centeredChroma_subtract_0.5_once"
    ),
    "quantization": "common_420v_round_to_nearest_even",
    "output_reopen_verification": True,
}
CONVENTIONAL_KEY_BY_ID = dict(zip(CONVENTIONAL_ALGORITHM_IDS, CONVENTIONAL_CONTROLS))
PRODUCTION_EXECUTION_BINDING_FRAGMENT_SCHEMA = (
    Path(__file__).resolve().parents[1]
    / "schemas"
    / "p07-production-authorized-execution-binding-fragment-v1.schema.json"
)
P06_RELEASE_BUNDLE_SCHEMA = (
    Path(__file__).resolve().parents[1]
    / "schemas"
    / "p06-release-bundle-v1.schema.json"
)
P06_EVIDENCE_CLOSURE_SCHEMA = (
    Path(__file__).resolve().parents[1]
    / "schemas"
    / "p06-evidence-closure-v1.schema.json"
)
CANDIDATE_RUNTIME_MANIFEST_SCHEMA = (
    Path(__file__).resolve().parents[1]
    / "schemas"
    / "candidate-lut-runtime-manifest-v1.schema.json"
)


class P07ProductionError(P07ExecutionError):
    """Release or runtime evidence differs from the locked P07 inputs."""


def _sha256(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def _is_sha256(value: object) -> bool:
    return (
        isinstance(value, str)
        and len(value) == 64
        and all(character in "0123456789abcdef" for character in value)
    )


def _require_sha256(value: object, label: str) -> str:
    if not _is_sha256(value):
        raise P07ProductionError("{} is not a lowercase SHA-256".format(label))
    return str(value)


def _json_copy(value: object) -> object:
    return json.loads(canonical_json_bytes(value))


def _artifact_binding(bundle: Mapping[str, object], identifier: str) -> Mapping[str, object]:
    rows = bundle.get("artifacts")
    if not isinstance(rows, list):
        raise P07ProductionError("P06 release artifact bindings are absent")
    matches = [row for row in rows if isinstance(row, dict) and row.get("id") == identifier]
    if len(matches) != 1:
        raise P07ProductionError("P06 release artifact is not singular: {}".format(identifier))
    return matches[0]


def _artifact_path(
    release_root: Path,
    bundle: Mapping[str, object],
    identifier: str,
) -> Path:
    return _path_under(
        release_root,
        _artifact_binding(bundle, identifier).get("path"),
        "P06 release artifact {}".format(identifier),
    )


def _read_bound_json(
    release_root: Path,
    bundle: Mapping[str, object],
    identifier: str,
) -> Mapping[str, object]:
    binding = _artifact_binding(bundle, identifier)
    path = _artifact_path(release_root, bundle, identifier)
    payload, document = _read_json(path, "P06 release {}".format(identifier))
    if (
        len(payload) != binding.get("size_bytes")
        or _sha256(payload) != binding.get("sha256")
    ):
        raise P07ProductionError("P06 release artifact bytes changed: {}".format(identifier))
    return document


def _selection_document(embedded: object, label: str) -> Mapping[str, object]:
    if not isinstance(embedded, dict) or set(embedded) != {"sha256", "document"}:
        raise P07ProductionError("{} selection envelope differs".format(label))
    document = embedded.get("document")
    if (
        not isinstance(document, dict)
        or embedded.get("sha256") != canonical_sha256(document)
    ):
        raise P07ProductionError("{} selection hash differs".format(label))
    return document


def _validate_selected_vector_runtime(
    *,
    plan: Mapping[str, object],
    selection: Mapping[str, object],
    evaluation: Mapping[str, object],
) -> Tuple[Mapping[str, object], str, Mapping[str, object]]:
    vector = selection.get("selected_vector")
    vector_hash = selection.get("selected_vector_sha256")
    runtime = evaluation.get("runtime_evidence")
    if not isinstance(vector, dict) or not isinstance(runtime, dict):
        raise P07ProductionError("selected vector or runtime evidence is absent")
    try:
        derived_vector_hash = candidate_vector_sha256(vector, plan)
    except Exception as error:
        raise P07ProductionError("selected vector violates the locked search plan") from error
    if (
        vector_hash != derived_vector_hash
        or evaluation.get("candidate_vector_sha256") != vector_hash
        or runtime.get("candidate_vector") != vector
        or runtime.get("serialized_candidate_vector_sha256") != vector_hash
        or evaluation.get("adapter_configuration_sha256")
        != canonical_sha256(runtime)
    ):
        raise P07ProductionError("selected vector/runtime configuration differs")
    return dict(vector), str(vector_hash), dict(runtime)


def _validate_route_lut_semantics(
    *,
    bundle: Mapping[str, object],
    lut_manifest: Mapping[str, object],
    selected_runtime: Mapping[str, object],
) -> Sequence[Mapping[str, object]]:
    routes = lut_manifest.get("routes")
    if (
        not isinstance(routes, list)
        or [row.get("route") for row in routes if isinstance(row, dict)]
        != ["direct_2x", "direct_3_over_2"]
    ):
        raise P07ProductionError("released LUT route coverage differs")
    selected_routes = selected_runtime.get("route_luts")
    if not isinstance(selected_routes, dict):
        raise P07ProductionError("selected P06 route LUT identities are absent")
    for index, (route, identifier) in enumerate(zip(
        ROUTE_ORDER,
        ("direct2x_lut", "direct3over2_lut"),
    )):
        release_row = routes[index]
        if not isinstance(release_row, dict):
            raise P07ProductionError("released route LUT row is invalid")
        binding = _artifact_binding(bundle, identifier)
        selected_row = selected_routes.get(route)
        if (
            release_row.get("whole_file_sha256") != binding.get("sha256")
            or release_row.get("whole_file_size_bytes") != binding.get("size_bytes")
            or not isinstance(selected_row, dict)
            or selected_row.get("payload_sha256")
            != release_row.get("payload_sha256")
            or selected_row.get("coordinate_policy")
            != release_row.get("coordinate_policy")
            or selected_row.get("analysis_grid_source_step")
            != release_row.get("analysis_grid_source_step")
        ):
            raise P07ProductionError("selected/released route LUT binding differs")
    return tuple(dict(row) for row in routes)


def _production_authorized_execution_binding_fragment(
    *,
    cache_root_identity: Tuple[int, int],
    macos_code_identities: Mapping[str, Mapping[str, object]],
    production_swift_roles: Sequence[Mapping[str, object]],
    p00_native_roles: Sequence[Mapping[str, object]],
    production_writer_roles: Sequence[Mapping[str, object]],
    production_writer_support_tree: Mapping[str, object],
    production_writer_settings_sha256: str,
    product_settings_source_sha256: str,
    production_writer_executable_sha256: str,
    p06_release_bundle_manifest_sha256: str,
) -> Mapping[str, object]:
    """Build the one canonical production authorized-execution fragment."""

    expected_roles = {
        "production_swift": (
            "native_executable",
            "native_source_manifest",
            "compiler_input",
            "mapping",
            "operator_bank",
            "runtime_manifest",
            "direct2x_lut",
            "direct3over2_lut",
        ),
        "p00_native": ("p00_executable",),
        "production_writer": (
            "production_writer_executable",
            "product_settings_source",
        ),
    }
    role_sets = {
        "production_swift": production_swift_roles,
        "p00_native": p00_native_roles,
        "production_writer": production_writer_roles,
    }
    if (
        not isinstance(cache_root_identity, tuple)
        or len(cache_root_identity) != 2
        or any(
            not isinstance(value, int)
            or isinstance(value, bool)
            or value < 0
            for value in cache_root_identity
        )
        or not isinstance(macos_code_identities, dict)
        or set(macos_code_identities) != {
            "production_swift_executable",
            "production_writer_executable",
            "p00_native_executable",
        }
    ):
        raise P07ProductionError(
            "production authorized-execution identity set differs"
        )
    for group, rows in role_sets.items():
        if (
            not isinstance(rows, (list, tuple))
            or tuple(
                row.get("role") if isinstance(row, dict) else None
                for row in rows
            )
            != expected_roles[group]
        ):
            raise P07ProductionError(
                "production authorized-execution retained role set differs"
            )
        for row in rows:
            assert isinstance(row, dict)
            if (
                set(row) != {"role", "sha256", "size_bytes"}
                or not _is_sha256(row.get("sha256"))
                or not isinstance(row.get("size_bytes"), int)
                or isinstance(row.get("size_bytes"), bool)
                or int(row["size_bytes"]) < 1
            ):
                raise P07ProductionError(
                    "production authorized-execution retained role differs"
                )
    for value, label in (
        (production_writer_settings_sha256, "production-writer settings"),
        (product_settings_source_sha256, "product settings source"),
        (production_writer_executable_sha256, "production-writer executable"),
        (p06_release_bundle_manifest_sha256, "P06 release bundle"),
    ):
        _require_sha256(value, label)

    core = {
        "schema_version": "1.0.0",
        "artifact_kind": "p07_authorized_execution_binding_fragment",
        "spawn_policy": {
            "policy_id": "macos-posix-spawn-suspended-gated-v1",
            "spawn_flags": {
                "set_process_group": 0x0002,
                "start_suspended": 0x0080,
                "close_on_exec_default": 0x4000,
            },
            "process_group_id": "child_pid",
            "identity_check_state": "stopped_before_sigcont",
            "gate_authorization_byte_hex": "a5",
            "environment_policy_id": "mirmir-authorized-env-v1",
            "environment": dict(
                authorized_process_environment(Path("/private/tmp"))
            ),
            "umask_octal": "077",
        },
        "cache_root_identity": {
            "device": cache_root_identity[0],
            "inode": cache_root_identity[1],
        },
        "macos_code_identities": _json_copy(macos_code_identities),
        "retained_fd_roles": {
            "production_swift": _json_copy(production_swift_roles),
            "p00_native": _json_copy(p00_native_roles),
            "production_writer": _json_copy(production_writer_roles),
        },
        "production_writer": {
            "support_tree": _json_copy(production_writer_support_tree),
            "settings_sha256": production_writer_settings_sha256,
            "product_settings_source_sha256": (
                product_settings_source_sha256
            ),
            "executable_sha256": production_writer_executable_sha256,
        },
        "p06_release_bundle_manifest_sha256": (
            p06_release_bundle_manifest_sha256
        ),
    }
    document = {
        **core,
        "fragment_sha256": canonical_sha256(core),
    }
    try:
        validate_schema(
            document,
            PRODUCTION_EXECUTION_BINDING_FRAGMENT_SCHEMA,
        )
    except ValueError as error:
        raise P07ProductionError(
            "production authorized-execution fragment violates schema"
        ) from error
    return document


def _strict_existing_root(path: Path, label: str) -> Path:
    if (
        not isinstance(path, Path)
        or not path.is_absolute()
        or Path(os.path.normpath(os.fspath(path))) != path
    ):
        raise P07ProductionError("{} is not normalized and absolute".format(label))
    _validate_existing_path(path, label=label, kind="directory")
    resolved = path.resolve(strict=True)
    if resolved != path:
        raise P07ProductionError("{} path identity differs".format(label))
    return resolved


def _retained_role_record(
    *,
    role: str,
    path: Path,
    label: str,
    expected_sha256: Optional[str] = None,
    expected_size_bytes: Optional[int] = None,
) -> Mapping[str, object]:
    payload = _read_regular_file(path, label)
    digest = _sha256(payload)
    if not payload:
        raise P07ProductionError("{} is empty".format(label))
    if expected_sha256 is not None and digest != expected_sha256:
        raise P07ProductionError("{} hash differs".format(label))
    if expected_size_bytes is not None and len(payload) != expected_size_bytes:
        raise P07ProductionError("{} size differs".format(label))
    return {
        "role": role,
        "sha256": digest,
        "size_bytes": len(payload),
    }


def _released_role_record(
    *,
    release_root: Path,
    release_bundle: Mapping[str, object],
    identifier: str,
    role: str,
) -> Mapping[str, object]:
    binding = _artifact_binding(release_bundle, identifier)
    return _retained_role_record(
        role=role,
        path=_artifact_path(release_root, release_bundle, identifier),
        label="P07 static production role {}".format(role),
        expected_sha256=_require_sha256(
            binding.get("sha256"),
            "P06 {} artifact".format(identifier),
        ),
        expected_size_bytes=binding.get("size_bytes"),
    )


def _singular_evidence_row(
    rows: object,
    identifier: str,
    label: str,
) -> Mapping[str, object]:
    matches = [
        row
        for row in rows
        if isinstance(row, dict) and row.get("id") == identifier
    ] if isinstance(rows, list) else []
    if len(matches) != 1:
        raise P07ProductionError("{} binding is not singular".format(label))
    return matches[0]


def _revalidate_release_evidence_rows(
    *,
    evidence_closure: Mapping[str, object],
    release_root: Path,
    repository_root: Path,
) -> None:
    roots = {
        "release": release_root,
        "repository": repository_root,
    }
    for field in (
        "implementation_artifacts",
        "selected_control_artifacts",
        "test_evidence",
        "preserved_failures",
    ):
        rows = evidence_closure.get(field)
        if not isinstance(rows, list):
            raise P07ProductionError(
                "P06 {} evidence rows are absent".format(field)
            )
        seen = set()
        for row in rows:
            if not isinstance(row, dict):
                raise P07ProductionError(
                    "P06 {} evidence row is invalid".format(field)
                )
            identifier = row.get("id")
            root_id = row.get("root_id")
            if (
                not isinstance(identifier, str)
                or not identifier
                or identifier in seen
            ):
                raise P07ProductionError(
                    "P06 {} evidence identity differs".format(field)
                )
            seen.add(identifier)
            if root_id not in roots:
                continue
            root = roots[str(root_id)]
            path = _path_under(
                root,
                row.get("path"),
                "P06 {} evidence {}".format(field, identifier),
            )
            if evidence_binding(
                identifier=identifier,
                root_id=str(root_id),
                path=path,
                root=root,
            ) != row:
                raise P07ProductionError(
                    "P06 {} evidence bytes differ".format(field)
                )


def _current_p00_executable(
    *,
    p07_cache_root: Path,
    expected_identity: Mapping[str, object],
    cache_guard: "_RetainedCacheDirectory",
    cache_snapshot: Mapping[str, object],
) -> Path:
    expected_hash = _require_sha256(
        expected_identity.get("file_sha256"),
        "P06 P00 executable identity",
    )
    rows = cache_snapshot.get("files")
    candidates = []
    if isinstance(rows, list):
        for row in rows:
            relative = row.get("path") if isinstance(row, dict) else None
            if not isinstance(relative, str):
                continue
            parts = Path(relative).parts
            if (
                len(parts) == 4
                and parts[0] == "current-source-extra-parity"
                and parts[1] == "p00"
                and _is_sha256(parts[2])
                and parts[3] == "ash-p00-control-cli"
            ):
                candidates.append((relative, row))
    if len(candidates) != 1:
        raise P07ProductionError(
            "P07 current P00 executable identity is not singular"
        )
    relative, record = candidates[0]
    executable = p07_cache_root.joinpath(*Path(relative).parts)
    payload = cache_guard.read_regular(executable)
    if (
        _sha256(payload) != expected_hash
        or record.get("sha256") != expected_hash
        or record.get("size_bytes") != len(payload)
        or not os.access(executable, os.X_OK)
    ):
        raise P07ProductionError("P07 current P00 executable bytes differ")
    try:
        identity = static_code_identity(executable)
    except BaseException as error:
        raise P07ProductionError(
            "P07 current P00 static code identity cannot be read"
        ) from error
    if identity != expected_identity:
        raise P07ProductionError(
            "P07 current P00 executable code identity differs"
        )
    return executable


def derive_production_authorized_execution_binding_fragment(
    *,
    release_root: Path,
    release_bundle: Mapping[str, object],
    production_writer_support_root: Path,
    repository_root: Path,
    p07_cache_root: Path,
    expected_cache_root_identity: Tuple[int, int],
) -> Mapping[str, object]:
    """Reconstruct current production identity with a retained cache FD."""

    release_root = _strict_existing_root(release_root, "P06 release root")
    production_writer_support_root = _strict_existing_root(
        production_writer_support_root,
        "P06 production-writer support root",
    )
    repository_root = _strict_existing_root(repository_root, "repository root")
    p07_cache_root = _strict_existing_root(p07_cache_root, "P07 cache root")
    cache_guard = _RetainedCacheDirectory.open(
        p07_cache_root,
        protected_roots=(
            release_root,
            production_writer_support_root,
            repository_root,
        ),
    )
    release_guard: Optional[_RetainedCacheDirectory] = None
    support_guard: Optional[_RetainedCacheDirectory] = None
    retained_roles: Optional[_RetainedInputSet] = None
    try:
        if cache_guard.root_identity != expected_cache_root_identity:
            raise P07ProductionError(
                "P07 cache-root identity differs from CLI pin"
            )
        release_guard = _RetainedCacheDirectory.open(
            release_root,
            protected_roots=(p07_cache_root,),
        )
        support_guard = _RetainedCacheDirectory.open(
            production_writer_support_root,
            protected_roots=(p07_cache_root,),
        )
        before = cache_guard.advance_monotonic()
        release_before = release_guard.advance_monotonic()
        support_before = support_guard.advance_monotonic()
        document, retained_roles = (
            _derive_production_execution_fragment_from_open_cache(
                release_root=release_root,
                release_bundle=release_bundle,
                production_writer_support_root=production_writer_support_root,
                repository_root=repository_root,
                p07_cache_root=p07_cache_root,
                expected_cache_root_identity=expected_cache_root_identity,
                cache_guard=cache_guard,
                cache_snapshot=before,
            )
        )
        retained_roles.verify()
        after = cache_guard.advance_monotonic()
        release_after = release_guard.advance_monotonic()
        support_after = support_guard.advance_monotonic()
        retained_roles.verify()
        if (
            after != before
            or release_after != release_before
            or support_after != support_before
        ):
            raise P07ProductionError(
                "P07 bound tree changed during production identity derivation"
            )
        return document
    finally:
        if retained_roles is not None:
            retained_roles.close()
        if support_guard is not None:
            support_guard.close()
        if release_guard is not None:
            release_guard.close()
        cache_guard.close()


def _derive_production_execution_fragment_from_open_cache(
    *,
    release_root: Path,
    release_bundle: Mapping[str, object],
    production_writer_support_root: Path,
    repository_root: Path,
    p07_cache_root: Path,
    expected_cache_root_identity: Tuple[int, int],
    cache_guard: "_RetainedCacheDirectory",
    cache_snapshot: Mapping[str, object],
) -> Tuple[Mapping[str, object], "_RetainedInputSet"]:
    """Reconstruct current production execution identity without executing code."""

    release_root = _strict_existing_root(release_root, "P06 release root")
    production_writer_support_root = _strict_existing_root(
        production_writer_support_root,
        "P06 production-writer support root",
    )
    repository_root = _strict_existing_root(repository_root, "repository root")
    p07_cache_root = _strict_existing_root(p07_cache_root, "P07 cache root")
    if (
        not isinstance(expected_cache_root_identity, tuple)
        or len(expected_cache_root_identity) != 2
        or any(
            not isinstance(value, int)
            or isinstance(value, bool)
            or value < 0
            for value in expected_cache_root_identity
        )
    ):
        raise P07ProductionError("P07 expected cache-root identity is invalid")
    current_cache_identity = cache_guard.root_identity
    if current_cache_identity != expected_cache_root_identity:
        raise P07ProductionError("P07 cache-root identity differs from CLI pin")

    if not isinstance(release_bundle, dict):
        raise P07ProductionError("P06 release bundle is not a JSON object")
    try:
        validate_schema(release_bundle, P06_RELEASE_BUNDLE_SCHEMA)
    except ValueError as error:
        raise P07ProductionError("P06 release bundle violates schema") from error
    release_hash = _require_sha256(
        release_bundle.get("manifest_sha256"),
        "P06 release bundle manifest",
    )
    if release_hash != canonical_sha256(
        {
            key: value
            for key, value in release_bundle.items()
            if key != "manifest_sha256"
        }
    ):
        raise P07ProductionError("P06 release bundle self-hash differs")
    _, reopened_release_bundle = _read_json(
        release_root / "p06-release-bundle.json",
        "P06 release bundle source",
    )
    if reopened_release_bundle != release_bundle:
        raise P07ProductionError(
            "P06 release bundle differs from the release root"
        )
    artifact_rows = release_bundle.get("artifacts")
    if not isinstance(artifact_rows, list):
        raise P07ProductionError("P06 release artifact rows are absent")
    for binding in artifact_rows:
        if not isinstance(binding, dict):
            raise P07ProductionError("P06 release artifact row is invalid")
        identifier = binding.get("id")
        if not isinstance(identifier, str):
            raise P07ProductionError("P06 release artifact ID is invalid")
        payload = _read_regular_file(
            _artifact_path(release_root, release_bundle, identifier),
            "P06 release artifact {}".format(identifier),
        )
        if (
            _sha256(payload) != binding.get("sha256")
            or len(payload) != binding.get("size_bytes")
        ):
            raise P07ProductionError(
                "P06 release artifact bytes changed: {}".format(identifier)
            )

    selection = _read_bound_json(
        release_root,
        release_bundle,
        "calibration_selection",
    )
    selected_evaluation = _read_bound_json(
        release_root,
        release_bundle,
        "selected_evaluation",
    )
    mapping = _read_bound_json(
        release_root,
        release_bundle,
        "locked_mapping",
    )
    compiler_input = _read_bound_json(
        release_root,
        release_bundle,
        "locked_compiler_input",
    )
    lut_manifest = _read_bound_json(
        release_root,
        release_bundle,
        "lut_manifest",
    )
    configuration_lock = _read_bound_json(
        release_root,
        release_bundle,
        "configuration_lock",
    )
    evidence_closure = _read_bound_json(
        release_root,
        release_bundle,
        "evidence_closure",
    )
    try:
        validate_schema(evidence_closure, P06_EVIDENCE_CLOSURE_SCHEMA)
    except ValueError as error:
        raise P07ProductionError(
            "P06 execution evidence closure violates schema"
        ) from error
    if (
        evidence_closure.get("manifest_sha256")
        != manifest_sha256(evidence_closure)
        or evidence_closure.get("configuration_id")
        != release_bundle.get("configuration_id")
        or evidence_closure.get("input_bundle_sha256")
        != release_bundle.get("input_bundle_sha256")
        or evidence_closure.get("corpus_lock_bundle_sha256")
        != release_bundle.get("corpus_lock_bundle_sha256")
    ):
        raise P07ProductionError("P06 execution evidence closure differs")
    _revalidate_release_evidence_rows(
        evidence_closure=evidence_closure,
        release_root=release_root,
        repository_root=repository_root,
    )

    implementations = evidence_closure.get("implementation_artifacts")
    executable_binding = _singular_evidence_row(
        implementations,
        "production_swift_executable",
        "released Swift executable",
    )
    source_binding = _singular_evidence_row(
        implementations,
        "production_swift_source_manifest",
        "released Swift source manifest",
    )
    if (
        executable_binding.get("root_id") != "release"
        or executable_binding.get("path") != "bin/ash-calibration-cli"
        or executable_binding.get("kind") != "file"
        or executable_binding.get("file_count") != 1
        or source_binding.get("root_id") != "release"
        or source_binding.get("path")
        != "sources/production-swift-source-manifest.json"
        or source_binding.get("kind") != "file"
        or source_binding.get("file_count") != 1
    ):
        raise P07ProductionError("released Swift implementation path differs")
    release_executable_path = _path_under(
        release_root,
        executable_binding["path"],
        "released native executable",
    )
    release_source_manifest_path = _path_under(
        release_root,
        source_binding["path"],
        "released native source manifest",
    )
    if evidence_binding(
        identifier="production_swift_executable",
        root_id="release",
        path=release_executable_path,
        root=release_root,
    ) != executable_binding or evidence_binding(
        identifier="production_swift_source_manifest",
        root_id="release",
        path=release_source_manifest_path,
        root=release_root,
    ) != source_binding:
        raise P07ProductionError("released Swift implementation bytes differ")
    if not os.access(release_executable_path, os.X_OK):
        raise P07ProductionError("released Swift executable is not executable")

    code_identities = evidence_closure.get("macos_code_identities")
    if (
        not isinstance(code_identities, dict)
        or set(code_identities) != {
            "production_swift_executable",
            "production_writer_executable",
            "p00_native_executable",
        }
        or any(not isinstance(value, dict) for value in code_identities.values())
    ):
        raise P07ProductionError("P06 macOS code identities are incomplete")

    writer_tree = _singular_evidence_row(
        evidence_closure.get("support_evidence_trees"),
        "production_writer_tree",
        "production-writer tree",
    )
    writer_root = _path_under(
        production_writer_support_root,
        writer_tree.get("path"),
        "P06 production-writer support tree",
    )
    if evidence_binding(
        identifier="production_writer_tree",
        root_id="production_writer",
        path=writer_root,
        root=production_writer_support_root,
    ) != writer_tree:
        raise P07ProductionError(
            "production-writer support tree differs from the P06 closure"
        )
    writer_executable_path = writer_root / "production-writer"
    expected_writer_identity = code_identities[
        "production_writer_executable"
    ]
    expected_writer_hash = _require_sha256(
        expected_writer_identity.get("file_sha256"),
        "P06 production-writer executable",
    )
    matching_writer_executables = []
    for current_root, directory_names, filenames in os.walk(
        writer_root,
        topdown=True,
        followlinks=False,
    ):
        current = Path(current_root)
        for directory_name in tuple(directory_names):
            metadata = os.lstat(current / directory_name)
            if stat.S_ISLNK(metadata.st_mode):
                raise P07ProductionError(
                    "production-writer support tree contains a symbolic link"
                )
        for filename in filenames:
            candidate = current / filename
            metadata = os.lstat(candidate)
            if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(
                metadata.st_mode
            ):
                raise P07ProductionError(
                    "production-writer support tree contains an unsafe entry"
                )
            if stat.S_IMODE(metadata.st_mode) & 0o111 == 0:
                continue
            payload = _read_regular_file(
                candidate,
                "P06 production-writer executable candidate",
            )
            if _sha256(payload) != expected_writer_hash:
                continue
            try:
                candidate_identity = static_code_identity(candidate)
            except BaseException as error:
                raise P07ProductionError(
                    "production-writer candidate identity cannot be read"
                ) from error
            if candidate_identity == expected_writer_identity:
                matching_writer_executables.append(candidate)
    if matching_writer_executables != [writer_executable_path]:
        raise P07ProductionError(
            "P07 production-writer executable identity is not singular"
        )
    p00_executable_path = _current_p00_executable(
        p07_cache_root=p07_cache_root,
        expected_identity=code_identities["p00_native_executable"],
        cache_guard=cache_guard,
        cache_snapshot=cache_snapshot,
    )
    current_identity_paths = {
        "production_swift_executable": release_executable_path,
        "production_writer_executable": writer_executable_path,
        "p00_native_executable": p00_executable_path,
    }
    for identifier, path in current_identity_paths.items():
        if not os.access(path, os.X_OK):
            raise P07ProductionError(
                "current {} is not executable".format(identifier)
            )
        try:
            current_identity = static_code_identity(path)
        except BaseException as error:
            raise P07ProductionError(
                "current {} static code identity cannot be read".format(
                    identifier
                )
            ) from error
        if current_identity != code_identities[identifier]:
            raise P07ProductionError(
                "current {} code identity differs".format(identifier)
            )

    selected_vector_sha256 = _require_sha256(
        selection.get("selected_vector_sha256"),
        "P06 selected vector",
    )
    configuration_sha256 = canonical_sha256(configuration_lock)
    runtime_identity = canonical_sha256(
        {
            "p06_release_bundle_manifest_sha256": release_hash,
            "configuration_sha256": configuration_sha256,
            "selected_vector_sha256": selected_vector_sha256,
            "native_source_manifest_sha256": source_binding["sha256"],
        }
    )
    runtime_manifest_path = (
        p07_cache_root
        / "release-runtime"
        / runtime_identity
        / "release-runtime-envelope.json"
    )
    runtime_payload = cache_guard.read_regular(runtime_manifest_path)
    runtime_manifest = _decode_json(
        runtime_payload,
        "P07 current release runtime manifest",
    )
    runtime_core = {
        "schema_version": "1.0.0",
        "manifest_id": "mirmir-ash-candidate-route-luts-v1",
        "status": "calibration_candidate",
        "configuration_id": mapping.get("configuration_id"),
        "compiler_input": lut_manifest.get("compiler_input"),
        "hash_bindings": compiler_input.get("hash_bindings"),
        "routes": lut_manifest.get("routes"),
        "swift_cli": {
            "executable_sha256": executable_binding.get("sha256"),
            "source_manifest_sha256": source_binding.get("sha256"),
        },
        "native_parity_claimed": False,
    }
    expected_runtime_manifest = {
        **runtime_core,
        "manifest_sha256": canonical_sha256(runtime_core),
    }
    expected_runtime_payload = (
        canonical_json_bytes(expected_runtime_manifest) + b"\n"
    )
    if (
        runtime_manifest != expected_runtime_manifest
        or runtime_payload != expected_runtime_payload
    ):
        raise P07ProductionError("P07 current release runtime manifest differs")
    try:
        validate_schema(
            runtime_manifest,
            CANDIDATE_RUNTIME_MANIFEST_SCHEMA,
        )
    except ValueError as error:
        raise P07ProductionError(
            "P07 current release runtime manifest violates schema"
        ) from error

    writer_executable_hash = expected_writer_hash
    settings_source_path = (
        repository_root
        / "Mirmir"
        / "Modules"
        / "MediaPipeline"
        / "MediaTypes.swift"
    )
    settings_source_sha256 = _sha256(
        _read_regular_file(
            settings_source_path,
            "P07 static product settings source",
        )
    )
    artifact_roles = (
        ("compiler_input", "locked_compiler_input"),
        ("mapping", "locked_mapping"),
        ("operator_bank", "locked_operator_bank"),
        ("direct2x_lut", "direct2x_lut"),
        ("direct3over2_lut", "direct3over2_lut"),
    )
    role_specifications: Dict[str, Tuple[Path, str, bool]] = {
        "native_executable": (
            release_executable_path,
            _require_sha256(
                executable_binding.get("sha256"),
                "released Swift executable",
            ),
            True,
        ),
        "native_source_manifest": (
            release_source_manifest_path,
            _require_sha256(
                source_binding.get("sha256"),
                "released Swift source manifest",
            ),
            False,
        ),
        **{
            role: (
                _artifact_path(release_root, release_bundle, identifier),
                _require_sha256(
                    _artifact_binding(release_bundle, identifier).get(
                        "sha256"
                    ),
                    "P06 {} artifact".format(identifier),
                ),
                False,
            )
            for role, identifier in artifact_roles[:3]
        },
        "runtime_manifest": (
            runtime_manifest_path,
            _sha256(expected_runtime_payload),
            False,
        ),
        **{
            role: (
                _artifact_path(release_root, release_bundle, identifier),
                _require_sha256(
                    _artifact_binding(release_bundle, identifier).get(
                        "sha256"
                    ),
                    "P06 {} artifact".format(identifier),
                ),
                False,
            )
            for role, identifier in artifact_roles[3:]
        },
        "p00_executable": (
            p00_executable_path,
            _require_sha256(
                code_identities["p00_native_executable"].get("file_sha256"),
                "P06 P00 executable",
            ),
            True,
        ),
        "production_writer_executable": (
            writer_executable_path,
            writer_executable_hash,
            True,
        ),
        "product_settings_source": (
            settings_source_path,
            settings_source_sha256,
            False,
        ),
    }
    retained_roles = _RetainedInputSet.open(role_specifications)
    try:
        retained_roles.verify()

        def rows(names: Sequence[str]) -> Sequence[Mapping[str, object]]:
            return tuple(
                {
                    "role": name,
                    "sha256": retained_roles.values[name].record["sha256"],
                    "size_bytes": retained_roles.values[name].record[
                        "size_bytes"
                    ],
                }
                for name in names
            )

        production_swift_roles = rows(
            (
                "native_executable",
                "native_source_manifest",
                "compiler_input",
                "mapping",
                "operator_bank",
                "runtime_manifest",
                "direct2x_lut",
                "direct3over2_lut",
            )
        )
        p00_roles = rows(("p00_executable",))
        writer_roles = rows(
            (
                "production_writer_executable",
                "product_settings_source",
            )
        )
        expected_sizes = {
            "native_executable": executable_binding.get("size_bytes"),
            "native_source_manifest": source_binding.get("size_bytes"),
            **{
                role: _artifact_binding(release_bundle, identifier).get(
                    "size_bytes"
                )
                for role, identifier in artifact_roles
            },
            "runtime_manifest": len(expected_runtime_payload),
        }
        if any(
            retained_roles.values[role].record["size_bytes"] != expected_size
            for role, expected_size in expected_sizes.items()
        ):
            raise P07ProductionError(
                "P07 retained production role size differs"
            )
        writer_settings_sha256 = _require_sha256(
            selected_evaluation.get("writer_settings_sha256"),
            "selected P06 writer settings",
        )
        derived_writer_settings_sha256 = canonical_sha256(
            production_writer_settings_document(
                executable_sha256=writer_executable_hash,
                product_settings_source_sha256=str(
                    writer_roles[1]["sha256"]
                ),
            )
        )
        if writer_settings_sha256 != derived_writer_settings_sha256:
            raise P07ProductionError(
                "selected P06 production-writer settings differ"
            )
        document = _production_authorized_execution_binding_fragment(
            cache_root_identity=current_cache_identity,
            macos_code_identities=code_identities,
            production_swift_roles=production_swift_roles,
            p00_native_roles=p00_roles,
            production_writer_roles=writer_roles,
            production_writer_support_tree=writer_tree,
            production_writer_settings_sha256=writer_settings_sha256,
            product_settings_source_sha256=str(writer_roles[1]["sha256"]),
            production_writer_executable_sha256=writer_executable_hash,
            p06_release_bundle_manifest_sha256=release_hash,
        )
        retained_roles.verify()
        return document, retained_roles
    except BaseException:
        retained_roles.close()
        raise


@dataclass(frozen=True)
class P07LockedReleaseInputs:
    """All P06 identities that a production P07 evaluator may consume."""

    release_root: Path
    release_bundle: Mapping[str, object]
    selection: Mapping[str, object]
    selected_evaluation: Mapping[str, object]
    mapping: Mapping[str, object]
    operator_bank: Mapping[str, object]
    metric_policy: Mapping[str, object]
    compiler_input: Mapping[str, object]
    lut_manifest: Mapping[str, object]
    configuration_lock: Mapping[str, object]
    evidence_closure: Mapping[str, object]
    degradation_policy: Mapping[str, object]
    analytic_fixture_manifest: Mapping[str, object]
    sampling_plan: Mapping[str, object]
    corpus_lock: Mapping[str, object]
    selected_vector: Mapping[str, object]
    selected_vector_sha256: str
    selected_p06_adapter_configuration_sha256: str
    release_bundle_manifest_sha256: str
    configuration_sha256: str
    fixed_selection: Mapping[str, object]
    conventional_selection: Mapping[str, object]
    non_ash_selection: Mapping[str, object]
    full_ash_development_candidates_frozen_sha256: str
    validation_candidate_development_evidence: Mapping[str, object]
    release_native_executable: NativeExecutable
    production_writer_root: Path
    production_writer_executable: Path
    macos_code_identities: Mapping[str, Mapping[str, object]]

    @classmethod
    def from_preflight(
        cls,
        *,
        preflight: P07Preflight,
        release_root: Path,
        bound_inputs: object,
        calibration_run_support_root: Path,
        production_writer_support_root: Path,
    ) -> "P07LockedReleaseInputs":
        """Cross-bind reopened release artifacts to direct preregistered inputs."""

        release_root = release_root.resolve(strict=True)
        bundle = preflight.release_bundle
        release_hash = _require_sha256(
            bundle.get("manifest_sha256"),
            "P06 release bundle manifest",
        )
        if release_hash != canonical_sha256(
            {key: value for key, value in bundle.items() if key != "manifest_sha256"}
        ):
            raise P07ProductionError("P06 release bundle self-hash differs")

        documents = {
            name: _read_bound_json(release_root, bundle, identifier)
            for name, identifier in RELEASE_ARTIFACT_IDS.items()
        }
        selection = documents["selection"]
        evaluation = documents["evaluation"]
        mapping = documents["mapping"]
        operator = documents["operator_bank"]
        metric = documents["metric_policy"]
        compiler = documents["compiler_input"]
        lut_manifest = documents["lut_manifest"]
        configuration_lock = documents["configuration_lock"]
        evidence_closure = documents["evidence_closure"]

        plan = getattr(bound_inputs, "documents", {}).get("calibration_plan")
        degradation = getattr(bound_inputs, "documents", {}).get("degradation_policy")
        analytic = getattr(bound_inputs, "documents", {}).get(
            "analytic_fixture_manifest"
        )
        if not all(isinstance(value, dict) for value in (plan, degradation, analytic)):
            raise P07ProductionError("direct preregistered P06 inputs are incomplete")
        verify = getattr(bound_inputs, "verify_unchanged", None)
        if not callable(verify):
            raise P07ProductionError("bound P06 inputs have no immutable verifier")
        verify()
        if degradation != preflight.degradation_policy or analytic != preflight.analytic_fixture_manifest:
            raise P07ProductionError("P07 preflight and direct input documents differ")

        vector, vector_hash, runtime = _validate_selected_vector_runtime(
            plan=plan,
            selection=selection,
            evaluation=evaluation,
        )

        embedded = evaluation.get("control_selection_artifacts")
        if not isinstance(embedded, dict) or set(embedded) != {
            "best_fixed", "conventional", "non_ash_selector"
        }:
            raise P07ProductionError("selected control artifacts are incomplete")
        fixed_envelope = embedded["best_fixed"]
        conventional_envelope = embedded["conventional"]
        non_ash_envelope = embedded["non_ash_selector"]
        selection_documents: Dict[str, Mapping[str, object]] = {}
        for name, value in embedded.items():
            document = _selection_document(value, name)
            selection_documents[name] = document
            matches = [
                row for row in selection.get("selected_control_selection_artifacts", [])
                if isinstance(row, dict) and row.get("control") == name
            ]
            if len(matches) != 1 or matches[0].get("sha256") != value.get("sha256"):
                raise P07ProductionError("selected control release binding differs")
            released_path = _path_under(
                release_root,
                matches[0].get("path"),
                "released selected control",
            )
            payload, released = _read_json(released_path, "released selected control")
            if (
                released != document
                or len(payload) != matches[0].get("size_bytes")
                or _sha256(payload) != matches[0].get("sha256")
            ):
                raise P07ProductionError("released selected control bytes differ")

        comparison_identities = evaluation.get("comparison_identities")
        if comparison_identities != selection.get("selected_controls"):
            raise P07ProductionError("selected comparison identities differ")
        frozen = evaluation.get("full_ash_development_candidates_frozen_sha256")
        _require_sha256(frozen, "frozen development candidates")
        development_binding = selection.get(
            "validation_candidate_development_evidence"
        )
        if not isinstance(development_binding, dict):
            raise P07ProductionError("frozen development evidence binding is absent")
        calibration_run_support_root = calibration_run_support_root.resolve(
            strict=True
        )
        closure_run = evidence_closure.get("calibration_run_tree")
        if not isinstance(closure_run, dict):
            raise P07ProductionError("calibration-run closure binding is absent")
        calibration_run_root = _path_under(
            calibration_run_support_root,
            closure_run.get("path"),
            "calibration-run support tree",
        )
        rebound_run = evidence_binding(
            identifier="complete_calibration_run_tree",
            root_id="calibration_run",
            path=calibration_run_root,
            root=calibration_run_support_root,
        )
        if rebound_run != evidence_closure.get("calibration_run_tree"):
            raise P07ProductionError(
                "calibration-run support tree differs from the P06 closure"
            )
        support_trees = evidence_closure.get("support_evidence_trees")
        writer_matches = [
            row
            for row in support_trees
            if isinstance(row, dict) and row.get("id") == "production_writer_tree"
        ] if isinstance(support_trees, list) else []
        if len(writer_matches) != 1:
            raise P07ProductionError("P06 production-writer tree binding is absent")
        writer_binding = writer_matches[0]
        production_writer_support_root = production_writer_support_root.resolve(
            strict=True
        )
        production_writer_root = _path_under(
            production_writer_support_root,
            writer_binding.get("path"),
            "P06 production-writer support tree",
        )
        rebound_writer = evidence_binding(
            identifier="production_writer_tree",
            root_id="production_writer",
            path=production_writer_root,
            root=production_writer_support_root,
        )
        if rebound_writer != writer_binding:
            raise P07ProductionError(
                "production-writer support tree differs from the P06 closure"
            )
        production_writer_executable = (
            production_writer_root / "production-writer"
        )
        writer_executable_payload = _read_regular_file(
            production_writer_executable,
            "P06 production-writer executable",
        )
        if not writer_executable_payload or not os.access(
            production_writer_executable,
            os.X_OK,
        ):
            raise P07ProductionError("P06 production-writer executable is invalid")

        code_identities = evidence_closure.get("macos_code_identities")
        if (
            not isinstance(code_identities, dict)
            or set(code_identities) != {
                "production_swift_executable",
                "production_writer_executable",
                "p00_native_executable",
            }
            or any(not isinstance(value, dict) for value in code_identities.values())
        ):
            raise P07ProductionError("P06 macOS code identities are incomplete")
        writer_code_identity = code_identities["production_writer_executable"]
        if (
            writer_code_identity.get("file_sha256")
            != _sha256(writer_executable_payload)
            or static_code_identity(production_writer_executable)
            != writer_code_identity
        ):
            raise P07ProductionError(
                "P06 production-writer code identity differs"
            )
        development_path = _path_under(
            calibration_run_root,
            development_binding.get("path"),
            "frozen development evidence",
        )
        development_payload, development_evidence = _read_json(
            development_path,
            "frozen development evidence",
        )
        if (
            len(development_payload) != development_binding.get("size_bytes")
            or _sha256(development_payload) != development_binding.get("sha256")
            or development_evidence.get("manifest_sha256") != frozen
            or manifest_sha256(development_evidence) != frozen
        ):
            raise P07ProductionError(
                "frozen development evidence file/manifest binding differs"
            )

        if (
            metric.get("policy_sha256") != manifest_sha256(metric, "policy_sha256")
            or metric.get("analytic_fixture_manifest", {}).get("manifest_sha256")
            != analytic.get("manifest_sha256")
            or degradation.get("policy_sha256")
            != manifest_sha256(degradation, "policy_sha256")
            or analytic.get("manifest_sha256") != manifest_sha256(analytic)
        ):
            raise P07ProductionError("metric/degradation/analytic lock differs")

        artifact_hashes = {
            name: _artifact_binding(bundle, identifier).get("sha256")
            for name, identifier in RELEASE_ARTIFACT_IDS.items()
        }
        compiler_bindings = compiler.get("hash_bindings")
        if not isinstance(compiler_bindings, dict):
            raise P07ProductionError("locked compiler bindings are absent")
        if (
            configuration_lock.get("mapping_sha256") != artifact_hashes["mapping"]
            or configuration_lock.get("operator_bank_sha256")
            != artifact_hashes["operator_bank"]
            or configuration_lock.get("metric_policy_sha256")
            != artifact_hashes["metric_policy"]
            or configuration_lock.get("compiler_inputs_sha256")
            != artifact_hashes["compiler_input"]
            or configuration_lock.get("route_luts_sha256")
            != lut_manifest.get("manifest_sha256")
            or compiler_bindings.get("mapping_sha256") != artifact_hashes["mapping"]
            or compiler_bindings.get("operator_bank_sha256")
            != artifact_hashes["operator_bank"]
            or compiler_bindings.get("metric_policy_sha256")
            != artifact_hashes["metric_policy"]
            or compiler_bindings.get("compiler_inputs_sha256")
            != compiler.get("hash_bindings", {}).get("compiler_inputs_sha256")
            or lut_manifest.get("hash_bindings") != compiler_bindings
        ):
            raise P07ProductionError("release configuration/compiler/LUT cross-link differs")

        routes = _validate_route_lut_semantics(
            bundle=bundle,
            lut_manifest=lut_manifest,
            selected_runtime=runtime,
        )

        derived_bank = shared_bank_configuration_sha256(vector, plan)
        configuration_id = "ash-p06-{}".format(str(vector_hash)[:24])
        selected_controls = selection.get("selected_controls")
        if not isinstance(selected_controls, dict):
            raise P07ProductionError("selected control identities are absent")
        if (
            derived_bank != selected_controls.get("shared_bank_configuration_sha256")
            or derived_bank != mapping.get("shared_bank_configuration_sha256")
            or derived_bank != operator.get("shared_bank_configuration_sha256")
            or runtime.get("shared_bank_configuration_sha256") != derived_bank
            or mapping.get("candidate_vector_sha256") != vector_hash
            or operator.get("candidate_vector_sha256") != vector_hash
            or mapping.get("configuration_id") != configuration_id
            or operator.get("configuration_id") != configuration_id
            or lut_manifest.get("configuration_id") != configuration_id
            or bundle.get("configuration_id") != configuration_id
            or compiler.get("configuration_id") != configuration_id
        ):
            raise P07ProductionError(
                "selected vector shared-bank/configuration identity differs"
            )

        implementations = evidence_closure.get("implementation_artifacts")
        if not isinstance(implementations, list):
            raise P07ProductionError("P06 implementation evidence is absent")
        implementation_by_id = {
            str(row.get("id")): row
            for row in implementations
            if isinstance(row, dict)
        }
        executable_binding = implementation_by_id.get(
            "production_swift_executable"
        )
        source_binding = implementation_by_id.get(
            "production_swift_source_manifest"
        )
        if not isinstance(executable_binding, dict) or not isinstance(source_binding, dict):
            raise P07ProductionError("released Swift implementation binding is absent")
        if (
            executable_binding.get("root_id") != "release"
            or executable_binding.get("path") != "bin/ash-calibration-cli"
            or executable_binding.get("kind") != "file"
            or executable_binding.get("file_count") != 1
            or source_binding.get("root_id") != "release"
            or source_binding.get("path")
            != "sources/production-swift-source-manifest.json"
            or source_binding.get("kind") != "file"
            or source_binding.get("file_count") != 1
        ):
            raise P07ProductionError("released Swift implementation path differs")
        executable_path = _path_under(
            release_root,
            executable_binding["path"],
            "released native executable",
        )
        source_manifest_path = _path_under(
            release_root,
            source_binding["path"],
            "released native source manifest",
        )
        executable_bytes = _read_regular_file(
            executable_path,
            "released native executable",
        )
        source_manifest_bytes = _read_regular_file(
            source_manifest_path,
            "released native source manifest",
        )
        if (
            len(executable_bytes) != executable_binding.get("size_bytes")
            or _sha256(executable_bytes) != executable_binding.get("sha256")
            or len(source_manifest_bytes) != source_binding.get("size_bytes")
            or _sha256(source_manifest_bytes) != source_binding.get("sha256")
            or not os.access(executable_path, os.X_OK)
        ):
            raise P07ProductionError("released Swift implementation bytes differ")
        native_code_identity = code_identities["production_swift_executable"]
        if (
            native_code_identity.get("file_sha256")
            != executable_binding.get("sha256")
            or static_code_identity(executable_path) != native_code_identity
        ):
            raise P07ProductionError("released Swift code identity differs")
        release_executable = NativeExecutable(
            path=executable_path,
            sha256=str(executable_binding["sha256"]),
            source_manifest_path=source_manifest_path,
            source_manifest_sha256=str(source_binding["sha256"]),
            compiled_now=False,
        )

        configuration_sha256 = canonical_sha256(configuration_lock)
        verify()
        return cls(
            release_root=release_root,
            release_bundle=_json_copy(bundle),
            selection=_json_copy(selection),
            selected_evaluation=_json_copy(evaluation),
            mapping=_json_copy(mapping),
            operator_bank=_json_copy(operator),
            metric_policy=_json_copy(metric),
            compiler_input=_json_copy(compiler),
            lut_manifest=_json_copy(lut_manifest),
            configuration_lock=_json_copy(configuration_lock),
            evidence_closure=_json_copy(evidence_closure),
            degradation_policy=_json_copy(degradation),
            analytic_fixture_manifest=_json_copy(analytic),
            sampling_plan=_json_copy(preflight.plan),
            corpus_lock=_json_copy(preflight.corpus_lock),
            selected_vector=_json_copy(vector),
            selected_vector_sha256=str(vector_hash),
            selected_p06_adapter_configuration_sha256=str(
                evaluation["adapter_configuration_sha256"]
            ),
            release_bundle_manifest_sha256=release_hash,
            configuration_sha256=configuration_sha256,
            fixed_selection={
                "sha256": str(fixed_envelope["sha256"]),
                "document": _json_copy(selection_documents["best_fixed"]),
            },
            conventional_selection={
                "sha256": str(conventional_envelope["sha256"]),
                "document": _json_copy(selection_documents["conventional"]),
            },
            non_ash_selection={
                "sha256": str(non_ash_envelope["sha256"]),
                "document": _json_copy(selection_documents["non_ash_selector"]),
            },
            full_ash_development_candidates_frozen_sha256=str(frozen),
            validation_candidate_development_evidence=_json_copy(
                development_evidence
            ),
            release_native_executable=release_executable,
            production_writer_root=production_writer_root,
            production_writer_executable=production_writer_executable,
            macos_code_identities={
                key: _json_copy(value)
                for key, value in code_identities.items()
            },
        )


def _directory_record(metadata: os.stat_result) -> Mapping[str, int]:
    return {
        "device": metadata.st_dev,
        "inode": metadata.st_ino,
        "mode": stat.S_IMODE(metadata.st_mode),
    }


def _directory_snapshot_record(metadata: os.stat_result) -> Mapping[str, int]:
    return {
        **_directory_record(metadata),
        "link_count": metadata.st_nlink,
        "size_bytes": metadata.st_size,
        "mtime_ns": metadata.st_mtime_ns,
        "ctime_ns": metadata.st_ctime_ns,
    }


def _file_record(metadata: os.stat_result, digest: str) -> Mapping[str, object]:
    return {
        "device": metadata.st_dev,
        "inode": metadata.st_ino,
        "mode": stat.S_IMODE(metadata.st_mode),
        "link_count": metadata.st_nlink,
        "size_bytes": metadata.st_size,
        "mtime_ns": metadata.st_mtime_ns,
        "ctime_ns": metadata.st_ctime_ns,
        "sha256": digest,
    }


def _directory_chain(path: Path, label: str) -> Tuple[Tuple[int, int], ...]:
    try:
        _validate_existing_path(path, label=label, kind="directory")
    except P07ExecutionError as error:
        raise P07ProductionError(str(error)) from error
    cursor = Path(path.anchor)
    components = [cursor]
    for part in path.parts[1:]:
        cursor = cursor / part
        components.append(cursor)
    result = []
    for component in components:
        try:
            metadata = os.lstat(component)
        except OSError as error:
            raise P07ProductionError(
                "{} changed during identity inspection".format(label)
            ) from error
        if stat.S_ISLNK(metadata.st_mode):
            raise P07ProductionError("{} traverses a symbolic link".format(label))
        if not stat.S_ISDIR(metadata.st_mode):
            raise P07ProductionError("{} contains a non-directory".format(label))
        result.append((metadata.st_dev, metadata.st_ino))
    return tuple(result)


class _RetainedCacheDirectory:
    """Descriptor-pinned, identity-monotonic P07 pre-open cache."""

    def __init__(
        self,
        *,
        root: Path,
        root_descriptor: int,
        root_identity: os.stat_result,
        protected_identities: Sequence[Tuple[int, int]],
    ) -> None:
        self.root = root
        self._root_descriptor = root_descriptor
        self._root_record = _directory_record(root_identity)
        self._protected_identities = frozenset(protected_identities)
        self._directories: Dict[str, Tuple[int, Mapping[str, int]]] = {
            "": (root_descriptor, self._root_record)
        }
        self._files: Dict[str, Mapping[str, object]] = {}
        self._frozen: Optional[Mapping[str, object]] = None
        self._closed = False

    @classmethod
    def open(
        cls,
        root: Path,
        *,
        protected_roots: Sequence[Path],
    ) -> "_RetainedCacheDirectory":
        root_chain = _directory_chain(root, "P07 cache root")
        protected_chains = tuple(
            _directory_chain(path, "P07 protected root")
            for path in protected_roots
        )
        root_identity = root_chain[-1]
        for chain in protected_chains:
            if root_identity in chain or chain[-1] in root_chain:
                raise P07ProductionError(
                    "P07 cache root overlaps a protected evidence/data root"
                )
        flags = os.O_RDONLY
        if hasattr(os, "O_DIRECTORY"):
            flags |= os.O_DIRECTORY
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        if hasattr(os, "O_CLOEXEC"):
            flags |= os.O_CLOEXEC
        try:
            descriptor = os.open(root, flags)
        except OSError as error:
            raise P07ProductionError("P07 cache root cannot be pinned") from error
        try:
            opened = os.fstat(descriptor)
            if (
                not stat.S_ISDIR(opened.st_mode)
                or (opened.st_dev, opened.st_ino) != root_identity
            ):
                raise P07ProductionError(
                    "P07 cache root identity changed while opening"
                )
            return cls(
                root=root,
                root_descriptor=descriptor,
                root_identity=opened,
                protected_identities=tuple(
                    identity
                    for chain in protected_chains
                    for identity in (chain[-1],)
                ),
            )
        except BaseException:
            os.close(descriptor)
            raise

    def close(self) -> None:
        if self._closed:
            return
        self._closed = True
        descriptors = {descriptor for descriptor, _ in self._directories.values()}
        self._directories.clear()
        for descriptor in descriptors:
            try:
                os.close(descriptor)
            except OSError:
                pass

    @property
    def root_identity(self) -> Tuple[int, int]:
        return (
            int(self._root_record["device"]),
            int(self._root_record["inode"]),
        )

    def __del__(self) -> None:
        self.close()

    @staticmethod
    def _validate_name(name: str) -> None:
        if not name or name in {".", ".."} or "/" in name or "\x00" in name:
            raise P07ProductionError("P07 cache child name is invalid")

    def _require_open(self) -> None:
        if self._closed:
            raise P07ProductionError("P07 retained cache guard is closed")

    def _verify_root(self) -> None:
        self._require_open()
        opened = os.fstat(self._root_descriptor)
        if (
            not stat.S_ISDIR(opened.st_mode)
            or _directory_record(opened) != self._root_record
        ):
            raise P07ProductionError("P07 retained cache root descriptor changed")
        try:
            current = _validate_existing_path(
                self.root,
                label="P07 cache root",
                kind="directory",
            )
        except P07ExecutionError as error:
            raise P07ProductionError(str(error)) from error
        if _directory_record(current) != self._root_record:
            raise P07ProductionError("P07 cache root identity changed")

    def verify_external_path(self, path: Path) -> None:
        if path != self.root:
            raise P07ProductionError("P07 evaluator cache root differs from preopen")
        self._verify_root()

    def _relative_parts(self, path: Path) -> Tuple[str, ...]:
        if not isinstance(path, Path) or not path.is_absolute():
            raise P07ProductionError("P07 cache path must be an absolute pathlib.Path")
        normalized = Path(os.path.normpath(os.fspath(path)))
        if normalized != path:
            raise P07ProductionError("P07 cache path must be lexically normalized")
        try:
            relative = path.relative_to(self.root)
        except ValueError as error:
            raise P07ProductionError("P07 cache path escapes its retained root") from error
        if relative == Path("."):
            return ()
        parts = tuple(relative.parts)
        for part in parts:
            self._validate_name(part)
        return parts

    def _verify_known_directory(
        self,
        parent_descriptor: int,
        name: str,
        relative: str,
    ) -> int:
        descriptor, expected = self._directories[relative]
        try:
            named = os.stat(name, dir_fd=parent_descriptor, follow_symlinks=False)
            opened = os.fstat(descriptor)
        except OSError as error:
            raise P07ProductionError(
                "P07 cache child identity changed: {}".format(relative)
            ) from error
        if (
            stat.S_ISLNK(named.st_mode)
            or not stat.S_ISDIR(named.st_mode)
            or not stat.S_ISDIR(opened.st_mode)
            or _directory_record(named) != expected
            or _directory_record(opened) != expected
        ):
            raise P07ProductionError(
                "P07 cache child identity changed: {}".format(relative)
            )
        return descriptor

    def _open_child_directory(
        self,
        parent_descriptor: int,
        name: str,
        relative: str,
        *,
        create: bool,
    ) -> int:
        if relative in self._directories:
            return self._verify_known_directory(
                parent_descriptor,
                name,
                relative,
            )
        try:
            before = os.stat(name, dir_fd=parent_descriptor, follow_symlinks=False)
        except FileNotFoundError:
            if not create:
                raise P07ProductionError(
                    "P07 cache directory is absent: {}".format(relative)
                )
            try:
                os.mkdir(name, mode=0o700, dir_fd=parent_descriptor)
                os.fsync(parent_descriptor)
                before = os.stat(
                    name,
                    dir_fd=parent_descriptor,
                    follow_symlinks=False,
                )
            except OSError as error:
                raise P07ProductionError(
                    "P07 cache directory cannot be created safely: {}".format(relative)
                ) from error
        except OSError as error:
            raise P07ProductionError(
                "P07 cache directory cannot be inspected: {}".format(relative)
            ) from error
        if stat.S_ISLNK(before.st_mode):
            raise P07ProductionError("P07 cache contains a symbolic link")
        if not stat.S_ISDIR(before.st_mode):
            raise P07ProductionError("P07 cache contains a non-directory child")
        flags = os.O_RDONLY
        if hasattr(os, "O_DIRECTORY"):
            flags |= os.O_DIRECTORY
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        if hasattr(os, "O_CLOEXEC"):
            flags |= os.O_CLOEXEC
        try:
            descriptor = os.open(name, flags, dir_fd=parent_descriptor)
        except OSError as error:
            raise P07ProductionError(
                "P07 cache directory cannot be pinned: {}".format(relative)
            ) from error
        try:
            opened = os.fstat(descriptor)
            final = os.stat(
                name,
                dir_fd=parent_descriptor,
                follow_symlinks=False,
            )
            identity = _directory_record(opened)
            if (
                not stat.S_ISDIR(opened.st_mode)
                or _directory_record(before) != identity
                or _directory_record(final) != identity
            ):
                raise P07ProductionError(
                    "P07 cache child identity changed: {}".format(relative)
                )
            if (opened.st_dev, opened.st_ino) in self._protected_identities:
                raise P07ProductionError(
                    "P07 cache child overlaps a protected evidence/data root"
                )
            self._directories[relative] = (descriptor, identity)
            return descriptor
        except BaseException:
            os.close(descriptor)
            raise

    def _directory_descriptor(self, path: Path, *, create: bool) -> int:
        self._verify_root()
        parts = self._relative_parts(path)
        descriptor = self._root_descriptor
        relative_parts = []
        for part in parts:
            relative_parts.append(part)
            relative = "/".join(relative_parts)
            descriptor = self._open_child_directory(
                descriptor,
                part,
                relative,
                create=create,
            )
        self._verify_root()
        return descriptor

    def _verify_directory_path(self, relative_directory: str) -> None:
        self._verify_root()
        if not relative_directory:
            return
        descriptor = self._root_descriptor
        parts = []
        for name in relative_directory.split("/"):
            parts.append(name)
            descriptor = self._verify_known_directory(
                descriptor,
                name,
                "/".join(parts),
            )
        self._verify_root()

    def ensure_directory(self, path: Path) -> None:
        if self._frozen is not None:
            raise P07ProductionError("P07 frozen cache cannot create a directory")
        self._directory_descriptor(path, create=True)

    def retained_directory_descriptor(self, path: Path) -> int:
        descriptor = self._directory_descriptor(path, create=False)
        relative = "/".join(self._relative_parts(path))
        self._verify_directory_path(relative)
        return descriptor

    @staticmethod
    def _stable_file_metadata(
        metadata: os.stat_result,
    ) -> Tuple[int, int, int, int, int, int, int]:
        return (
            metadata.st_dev,
            metadata.st_ino,
            stat.S_IMODE(metadata.st_mode),
            metadata.st_nlink,
            metadata.st_size,
            metadata.st_mtime_ns,
            metadata.st_ctime_ns,
        )

    def _read_regular_at(
        self,
        parent_descriptor: int,
        name: str,
        relative: str,
    ) -> Tuple[bytes, Mapping[str, object]]:
        try:
            before = os.stat(name, dir_fd=parent_descriptor, follow_symlinks=False)
        except OSError as error:
            raise P07ProductionError(
                "P07 cache file cannot be inspected: {}".format(relative)
            ) from error
        if stat.S_ISLNK(before.st_mode):
            raise P07ProductionError("P07 cache contains a symbolic link")
        if not stat.S_ISREG(before.st_mode):
            raise P07ProductionError("P07 cache contains a nonregular file")
        if before.st_nlink != 1:
            raise P07ProductionError("P07 cache file has a hard link")
        flags = os.O_RDONLY
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        if hasattr(os, "O_CLOEXEC"):
            flags |= os.O_CLOEXEC
        try:
            descriptor = os.open(name, flags, dir_fd=parent_descriptor)
        except OSError as error:
            raise P07ProductionError(
                "P07 cache file cannot be opened safely: {}".format(relative)
            ) from error
        try:
            opened = os.fstat(descriptor)
            if (
                not stat.S_ISREG(opened.st_mode)
                or opened.st_nlink != 1
                or self._stable_file_metadata(opened)
                != self._stable_file_metadata(before)
            ):
                raise P07ProductionError(
                    "P07 cache file identity changed while opening: {}".format(relative)
                )
            digest = hashlib.sha256()
            chunks = []
            while True:
                chunk = os.read(descriptor, 1024 * 1024)
                if not chunk:
                    break
                digest.update(chunk)
                chunks.append(chunk)
            after = os.fstat(descriptor)
            final = os.stat(
                name,
                dir_fd=parent_descriptor,
                follow_symlinks=False,
            )
            if (
                after.st_nlink != 1
                or final.st_nlink != 1
                or self._stable_file_metadata(after)
                != self._stable_file_metadata(before)
                or self._stable_file_metadata(final)
                != self._stable_file_metadata(before)
            ):
                raise P07ProductionError(
                    "P07 cache file changed while reading: {}".format(relative)
                )
            payload = b"".join(chunks)
            if len(payload) != before.st_size:
                raise P07ProductionError(
                    "P07 cache file changed while reading: {}".format(relative)
                )
            record = _file_record(after, digest.hexdigest())
        finally:
            os.close(descriptor)
        previous = self._files.get(relative)
        if previous is not None and previous != record:
            raise P07ProductionError(
                "P07 cache file identity or content changed: {}".format(relative)
            )
        self._files[relative] = record
        return payload, record

    def read_regular(self, path: Path) -> bytes:
        parts = self._relative_parts(path)
        if not parts:
            raise P07ProductionError("P07 cache root is not a regular file")
        parent = self.root.joinpath(*parts[:-1])
        parent_descriptor = self._directory_descriptor(parent, create=False)
        payload, _ = self._read_regular_at(
            parent_descriptor,
            parts[-1],
            "/".join(parts),
        )
        self._verify_directory_path("/".join(parts[:-1]))
        return payload

    def entry_exists(self, path: Path) -> bool:
        parts = self._relative_parts(path)
        if not parts:
            return True
        parent = self.root.joinpath(*parts[:-1])
        parent_descriptor = self._directory_descriptor(parent, create=False)
        try:
            os.stat(
                parts[-1],
                dir_fd=parent_descriptor,
                follow_symlinks=False,
            )
        except FileNotFoundError:
            self._verify_directory_path("/".join(parts[:-1]))
            return False
        except OSError as error:
            raise P07ProductionError("P07 cache entry cannot be inspected") from error
        self._read_regular_at(
            parent_descriptor,
            parts[-1],
            "/".join(parts),
        )
        self._verify_directory_path("/".join(parts[:-1]))
        return True

    def recover_interrupted_publication(self, path: Path) -> None:
        """Remove only recognized, unpublished files for one cache target."""

        if self._frozen is not None:
            raise P07ProductionError(
                "P07 frozen cache cannot recover a publication"
            )
        parts = self._relative_parts(path)
        if not parts:
            raise P07ProductionError("P07 cache root cannot be a file")
        parent_relative = "/".join(parts[:-1])
        parent = self.root.joinpath(*parts[:-1])
        parent_descriptor = self._directory_descriptor(parent, create=False)
        self._recover_interrupted_publication_at(
            parent_descriptor,
            parts[-1],
        )
        self._verify_directory_path(parent_relative)

    def _recover_interrupted_publication_at(
        self,
        parent_descriptor: int,
        name: str,
    ) -> None:
        temporary_prefix = ".{}.p07-uncommitted-".format(name)
        cleaned = False
        for candidate in os.listdir(parent_descriptor):
            if not candidate.startswith(temporary_prefix):
                continue
            suffix = candidate[len(temporary_prefix):]
            if (
                len(suffix) != 32
                or any(character not in "0123456789abcdef" for character in suffix)
            ):
                raise P07ProductionError(
                    "P07 interrupted cache publication name is unsafe"
                )
            try:
                candidate_metadata = os.stat(
                    candidate,
                    dir_fd=parent_descriptor,
                    follow_symlinks=False,
                )
                final_metadata = None
                try:
                    final_metadata = os.stat(
                        name,
                        dir_fd=parent_descriptor,
                        follow_symlinks=False,
                    )
                except FileNotFoundError:
                    pass
            except OSError as error:
                raise P07ProductionError(
                    "P07 interrupted cache publication cannot be inspected"
                ) from error
            linked_publication = (
                final_metadata is not None
                and (candidate_metadata.st_dev, candidate_metadata.st_ino)
                == (final_metadata.st_dev, final_metadata.st_ino)
                and candidate_metadata.st_nlink == 2
            )
            if (
                stat.S_ISLNK(candidate_metadata.st_mode)
                or not stat.S_ISREG(candidate_metadata.st_mode)
                or (
                    candidate_metadata.st_nlink != 1
                    and not linked_publication
                )
            ):
                raise P07ProductionError(
                    "P07 interrupted cache publication is unsafe"
                )
            try:
                os.unlink(candidate, dir_fd=parent_descriptor)
            except OSError as error:
                raise P07ProductionError(
                    "P07 interrupted cache publication cannot be removed"
                ) from error
            cleaned = True
        if cleaned:
            os.fsync(parent_descriptor)

    def write_or_verify(self, path: Path, payload: bytes) -> None:
        if self._frozen is not None:
            raise P07ProductionError("P07 frozen cache cannot be written")
        parts = self._relative_parts(path)
        if not parts:
            raise P07ProductionError("P07 cache root cannot be a file")
        parent_relative = "/".join(parts[:-1])
        parent = self.root.joinpath(*parts[:-1])
        parent_descriptor = self._directory_descriptor(parent, create=False)
        name = parts[-1]
        temporary_prefix = ".{}.p07-uncommitted-".format(name)
        self._recover_interrupted_publication_at(parent_descriptor, name)
        try:
            os.stat(name, dir_fd=parent_descriptor, follow_symlinks=False)
        except FileNotFoundError:
            pass
        except OSError as error:
            raise P07ProductionError("P07 cached artifact cannot be inspected") from error
        else:
            existing, _ = self._read_regular_at(
                parent_descriptor,
                name,
                "/".join(parts),
            )
            if existing != payload:
                raise P07ProductionError("P07 content-addressed artifact changed")
            self._verify_directory_path(parent_relative)
            return

        flags = os.O_RDWR | os.O_CREAT | os.O_EXCL
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        if hasattr(os, "O_CLOEXEC"):
            flags |= os.O_CLOEXEC
        descriptor = -1
        reopened = -1
        temporary_name = temporary_prefix + uuid.uuid4().hex
        complete = False
        won_publication = False
        try:
            descriptor = os.open(
                temporary_name,
                flags,
                0o600,
                dir_fd=parent_descriptor,
            )
            created = os.fstat(descriptor)
            created_identity = (created.st_dev, created.st_ino)
            if (
                not stat.S_ISREG(created.st_mode)
                or created.st_nlink != 1
                or stat.S_IMODE(created.st_mode) != 0o600
            ):
                raise P07ProductionError("P07 cache publication is not singular")
            offset = 0
            while offset < len(payload):
                written = os.write(descriptor, payload[offset:])
                if written <= 0:
                    raise P07ProductionError("P07 cache write made no progress")
                offset += written
            os.fsync(descriptor)
            staged = os.fstat(descriptor)
            if (
                not stat.S_ISREG(staged.st_mode)
                or staged.st_nlink != 1
                or (staged.st_dev, staged.st_ino) != created_identity
            ):
                raise P07ProductionError("P07 cache publication identity changed")
            try:
                os.link(
                    temporary_name,
                    name,
                    src_dir_fd=parent_descriptor,
                    dst_dir_fd=parent_descriptor,
                    follow_symlinks=False,
                )
                won_publication = True
            except FileExistsError:
                existing, _ = self._read_regular_at(
                    parent_descriptor,
                    name,
                    "/".join(parts),
                )
                if existing != payload:
                    raise P07ProductionError(
                        "P07 concurrent cache publication differs"
                    )
            os.unlink(temporary_name, dir_fd=parent_descriptor)
            os.fsync(parent_descriptor)

            reopen_flags = os.O_RDONLY
            if hasattr(os, "O_NOFOLLOW"):
                reopen_flags |= os.O_NOFOLLOW
            if hasattr(os, "O_CLOEXEC"):
                reopen_flags |= os.O_CLOEXEC
            reopened = os.open(name, reopen_flags, dir_fd=parent_descriptor)
            reopened_identity = os.fstat(reopened)
            published = os.fstat(reopened)
            if (
                not stat.S_ISREG(reopened_identity.st_mode)
                or reopened_identity.st_nlink != 1
                or (
                    won_publication
                    and (
                        (reopened_identity.st_dev, reopened_identity.st_ino)
                        != created_identity
                        or stat.S_IMODE(reopened_identity.st_mode) != 0o600
                    )
                )
                or self._stable_file_metadata(reopened_identity)
                != self._stable_file_metadata(published)
            ):
                raise P07ProductionError("P07 cache publication identity changed")
            digest = hashlib.sha256()
            chunks = []
            while True:
                chunk = os.read(reopened, 1024 * 1024)
                if not chunk:
                    break
                digest.update(chunk)
                chunks.append(chunk)
            after = os.fstat(reopened)
            final = os.stat(
                name,
                dir_fd=parent_descriptor,
                follow_symlinks=False,
            )
            if (
                self._stable_file_metadata(after)
                != self._stable_file_metadata(published)
                or self._stable_file_metadata(final)
                != self._stable_file_metadata(published)
                or b"".join(chunks) != payload
            ):
                raise P07ProductionError(
                    "P07 cache publication identity changed on reopen"
                )
            record = _file_record(after, digest.hexdigest())
            previous = self._files.get("/".join(parts))
            if previous is not None and previous != record:
                raise P07ProductionError("P07 cache publication identity changed")
            self._files["/".join(parts)] = record
            self._verify_directory_path(parent_relative)
            complete = True
        except OSError as error:
            raise P07ProductionError("P07 cache publication failed safely") from error
        finally:
            if reopened >= 0:
                os.close(reopened)
            if descriptor >= 0:
                os.close(descriptor)
            try:
                os.unlink(temporary_name, dir_fd=parent_descriptor)
                os.fsync(parent_descriptor)
            except FileNotFoundError:
                pass

    def _snapshot_internal(self) -> Mapping[str, object]:
        self._verify_root()
        directory_rows = []
        file_rows = []

        def visit(descriptor: int, relative_directory: str) -> Mapping[str, int]:
            before = os.fstat(descriptor)
            try:
                names = tuple(sorted(os.listdir(descriptor)))
            except OSError as error:
                raise P07ProductionError("P07 cache cannot be enumerated") from error
            for name in names:
                self._validate_name(name)
                relative = name if not relative_directory else "{}/{}".format(
                    relative_directory,
                    name,
                )
                try:
                    metadata = os.stat(
                        name,
                        dir_fd=descriptor,
                        follow_symlinks=False,
                    )
                except OSError as error:
                    raise P07ProductionError("P07 cache child cannot be inspected") from error
                if stat.S_ISLNK(metadata.st_mode):
                    raise P07ProductionError("P07 cache contains a symbolic link")
                if stat.S_ISDIR(metadata.st_mode):
                    child = self._open_child_directory(
                        descriptor,
                        name,
                        relative,
                        create=False,
                    )
                    child_record = visit(child, relative)
                    directory_rows.append({"path": relative, **child_record})
                elif stat.S_ISREG(metadata.st_mode):
                    _, record = self._read_regular_at(
                        descriptor,
                        name,
                        relative,
                    )
                    file_rows.append({"path": relative, **record})
                else:
                    raise P07ProductionError("P07 cache contains a nonregular entry")
            try:
                final_names = tuple(sorted(os.listdir(descriptor)))
            except OSError as error:
                raise P07ProductionError("P07 cache cannot be re-enumerated") from error
            after = os.fstat(descriptor)
            if (
                final_names != names
                or _directory_snapshot_record(after)
                != _directory_snapshot_record(before)
            ):
                raise P07ProductionError("P07 cache changed during snapshot")
            return _directory_snapshot_record(after)

        root_record = visit(self._root_descriptor, "")
        self._verify_root()
        directory_rows.sort(key=lambda row: str(row["path"]))
        file_rows.sort(key=lambda row: str(row["path"]))
        current_directories = {str(row["path"]) for row in directory_rows}
        current_files = {str(row["path"]) for row in file_rows}
        known_directories = set(self._directories) - {""}
        if not known_directories.issubset(current_directories):
            raise P07ProductionError("P07 cache directory disappeared")
        if not set(self._files).issubset(current_files):
            raise P07ProductionError("P07 cache file disappeared")
        return {
            "root": root_record,
            "directories": directory_rows,
            "files": file_rows,
        }

    @staticmethod
    def _public_snapshot(internal: Mapping[str, object]) -> Mapping[str, object]:
        internal_files = internal.get("files")
        if not isinstance(internal_files, list):
            raise P07ProductionError("P07 cache snapshot is invalid")
        rows = [
            {
                "path": row["path"],
                "sha256": row["sha256"],
                "size_bytes": row["size_bytes"],
            }
            for row in internal_files
            if isinstance(row, dict)
        ]
        if len(rows) != len(internal_files):
            raise P07ProductionError("P07 cache snapshot file rows are invalid")
        return {
            "file_count": len(rows),
            "size_bytes": sum(int(row["size_bytes"]) for row in rows),
            "tree_sha256": canonical_sha256(rows),
            "files": rows,
        }

    def advance_monotonic(self) -> Mapping[str, object]:
        if self._frozen is not None:
            raise P07ProductionError("P07 cache is already frozen")
        return self._snapshot_internal()

    def freeze(self) -> Mapping[str, object]:
        if self._frozen is None:
            self._frozen = _json_copy(self._snapshot_internal())
        return self._public_snapshot(self._frozen)

    def verify_frozen(self) -> Mapping[str, object]:
        if self._frozen is None:
            raise P07ProductionError("P07 cache was not frozen")
        current = self._snapshot_internal()
        if current != self._frozen:
            raise P07ProductionError("P07 frozen cache tree changed")
        return self._public_snapshot(current)


class _RetainedRegularFile:
    """One expected regular-file payload retained by descriptor."""

    def __init__(
        self,
        *,
        path: Path,
        descriptor: int,
        record: Mapping[str, object],
    ) -> None:
        self.path = path
        self.descriptor = descriptor
        self.record = dict(record)
        self._closed = False

    @classmethod
    def open(
        cls,
        path: Path,
        *,
        expected_sha256: str,
        executable: bool = False,
    ) -> "_RetainedRegularFile":
        if not _is_sha256(expected_sha256):
            raise P07ProductionError("retained input expected SHA-256 is invalid")
        try:
            before = _validate_existing_path(
                path,
                label="P07 retained input",
                kind="file",
            )
        except P07ExecutionError as error:
            raise P07ProductionError(str(error)) from error
        if before.st_nlink != 1:
            raise P07ProductionError("P07 retained input has a hard link")
        if executable and stat.S_IMODE(before.st_mode) & 0o111 == 0:
            raise P07ProductionError("P07 retained executable has no execute mode")
        flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
        descriptor = os.open(path, flags)
        try:
            opened = os.fstat(descriptor)
            if (
                not stat.S_ISREG(opened.st_mode)
                or opened.st_nlink != 1
                or _RetainedCacheDirectory._stable_file_metadata(opened)
                != _RetainedCacheDirectory._stable_file_metadata(before)
            ):
                raise P07ProductionError("P07 retained input changed while opening")
            digest = hashlib.sha256()
            size = 0
            while True:
                chunk = os.read(descriptor, 1024 * 1024)
                if not chunk:
                    break
                digest.update(chunk)
                size += len(chunk)
            after = os.fstat(descriptor)
            final = os.lstat(path)
            if (
                size != before.st_size
                or digest.hexdigest() != expected_sha256
                or _RetainedCacheDirectory._stable_file_metadata(after)
                != _RetainedCacheDirectory._stable_file_metadata(before)
                or _RetainedCacheDirectory._stable_file_metadata(final)
                != _RetainedCacheDirectory._stable_file_metadata(before)
            ):
                raise P07ProductionError("P07 retained input identity or bytes differ")
            os.lseek(descriptor, 0, os.SEEK_SET)
            return cls(
                path=path,
                descriptor=descriptor,
                record=_file_record(after, digest.hexdigest()),
            )
        except BaseException:
            os.close(descriptor)
            raise

    @property
    def descriptor_path(self) -> Path:
        if self._closed:
            raise P07ProductionError("P07 retained input is closed")
        return Path("/dev/fd/{}".format(self.descriptor))

    def verify(self) -> None:
        if self._closed:
            raise P07ProductionError("P07 retained input is closed")
        metadata = os.fstat(self.descriptor)
        if metadata.st_nlink != 1:
            raise P07ProductionError("P07 retained input acquired a hard link")
        digest = hashlib.sha256()
        size = 0
        os.lseek(self.descriptor, 0, os.SEEK_SET)
        while True:
            chunk = os.read(self.descriptor, 1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
            size += len(chunk)
        final_descriptor = os.fstat(self.descriptor)
        try:
            live = _validate_existing_path(
                self.path,
                label="P07 retained input",
                kind="file",
            )
        except P07ExecutionError as error:
            raise P07ProductionError(str(error)) from error
        record = _file_record(final_descriptor, digest.hexdigest())
        if (
            size != final_descriptor.st_size
            or record != self.record
            or _RetainedCacheDirectory._stable_file_metadata(live)
            != _RetainedCacheDirectory._stable_file_metadata(final_descriptor)
        ):
            raise P07ProductionError("P07 retained input changed")
        os.lseek(self.descriptor, 0, os.SEEK_SET)

    def close(self) -> None:
        if self._closed:
            return
        self._closed = True
        os.close(self.descriptor)

    def __del__(self) -> None:
        if not getattr(self, "_closed", True):
            self.close()


class _RetainedInputSet:
    def __init__(self, values: Mapping[str, _RetainedRegularFile]) -> None:
        self.values = dict(values)
        self._closed = False

    @classmethod
    def open(
        cls,
        specifications: Mapping[str, Tuple[Path, str, bool]],
    ) -> "_RetainedInputSet":
        values: Dict[str, _RetainedRegularFile] = {}
        try:
            for name, (path, digest, executable) in specifications.items():
                values[name] = _RetainedRegularFile.open(
                    path,
                    expected_sha256=digest,
                    executable=executable,
                )
            return cls(values)
        except BaseException as primary_error:
            cleanup_error: Optional[BaseException] = None
            for value in values.values():
                try:
                    value.close()
                except BaseException as error:
                    cleanup_error = cleanup_error or error
            if cleanup_error is not None:
                raise P07DualFailure(
                    primary_error,
                    cleanup_error,
                ) from primary_error
            raise

    @property
    def pass_fds(self) -> Tuple[int, ...]:
        if self._closed:
            raise P07ProductionError("P07 retained input set is closed")
        return tuple(value.descriptor for value in self.values.values())

    def verify(self) -> None:
        for value in self.values.values():
            value.verify()

    def close(self) -> None:
        if self._closed:
            return
        self._closed = True
        primary: Optional[BaseException] = None
        for value in self.values.values():
            try:
                value.close()
            except BaseException as error:
                if primary is None:
                    primary = error
        if primary is not None:
            raise primary


def _retained_writer_execution(
    locked: P07LockedReleaseInputs,
) -> Tuple[_RetainedInputSet, ProductionWriterAuthorizedExecution, str, str]:
    executable_sha256 = _require_sha256(
        locked.macos_code_identities["production_writer_executable"].get(
            "file_sha256"
        ),
        "P06 production-writer executable",
    )
    settings_payload = _read_regular_file(
        PRODUCT_MEDIA_TYPES_PATH,
        "product MediaTypes settings source",
    )
    settings_source_sha256 = _sha256(settings_payload)
    expected_settings_sha256 = _require_sha256(
        locked.selected_evaluation.get("writer_settings_sha256"),
        "selected P06 writer settings",
    )
    inputs = _RetainedInputSet.open(
        {
            "production_writer_executable": (
                locked.production_writer_executable,
                executable_sha256,
                True,
            ),
            "product_settings_source": (
                PRODUCT_MEDIA_TYPES_PATH,
                settings_source_sha256,
                False,
            ),
        }
    )
    identity = locked.macos_code_identities[
        "production_writer_executable"
    ]
    environment = authorized_process_environment(Path("/private/tmp"))

    def run_writer(
        command: Sequence[str],
        cwd_descriptor: int,
        pass_fds: Sequence[int],
    ) -> subprocess.CompletedProcess[bytes]:
        inputs.verify()
        result = run_authorized_process(
            command,
            cwd_descriptor=cwd_descriptor,
            pass_fds=pass_fds,
            execution_authorizer=lambda pid: authorize_running_code(
                pid,
                identity,
            ),
            authorized_environment=environment,
            timeout_seconds=120.0,
        )
        inputs.verify()
        return result

    return (
        inputs,
        ProductionWriterAuthorizedExecution(
            executable_descriptor=inputs.values[
                "production_writer_executable"
            ].descriptor,
            product_settings_source_descriptor=inputs.values[
                "product_settings_source"
            ].descriptor,
            run_process=run_writer,
        ),
        settings_source_sha256,
        expected_settings_sha256,
    )


def _locked_writer_capability(
    *,
    evidence_root: Path,
    locked: P07LockedReleaseInputs,
    execution: ProductionWriterAuthorizedExecution,
    settings_source_sha256: str,
    expected_settings_sha256: str,
) -> NativeProductionWriterCapability:
    return production_writer_capability(
        evidence_root,
        locked_executable=locked.production_writer_executable,
        expected_executable_sha256=str(
            locked.macos_code_identities["production_writer_executable"][
                "file_sha256"
            ]
        ),
        expected_product_settings_source_sha256=settings_source_sha256,
        expected_settings_sha256=expected_settings_sha256,
        authorized_execution=execution,
    )


@dataclass
class _RetainedNativeRuntime:
    native_inputs: _RetainedInputSet
    p00_inputs: _RetainedInputSet
    native_executable: NativeExecutable
    native_configuration: NativeConfiguration

    def verify(self) -> None:
        self.native_inputs.verify()
        self.p00_inputs.verify()

    def close(self) -> None:
        primary: Optional[BaseException] = None
        try:
            self.native_inputs.close()
        except BaseException as error:
            primary = error
        try:
            self.p00_inputs.close()
        except BaseException as cleanup_error:
            if primary is not None:
                raise P07DualFailure(primary, cleanup_error) from primary
            raise
        if primary is not None:
            raise primary


def _retain_native_runtime(
    *,
    locked: P07LockedReleaseInputs,
    native_factory: NativeCandidateAdapterFactory,
    native_configuration: NativeConfiguration,
) -> _RetainedNativeRuntime:
    p00_executable = native_factory.p00_builder.executable
    expected_p00_identity = locked.macos_code_identities[
        "p00_native_executable"
    ]
    if (
        expected_p00_identity.get("file_sha256") != p00_executable.sha256
        or static_code_identity(p00_executable.path) != expected_p00_identity
    ):
        raise P07ProductionError("P06 P00 native code identity differs")
    runtime_manifest_sha256 = _sha256(
        _read_regular_file(
            native_configuration.runtime_manifest_path,
            "P07 runtime manifest",
        )
    )
    native_inputs = _RetainedInputSet.open(
        {
            "native_executable": (
                locked.release_native_executable.path,
                locked.release_native_executable.sha256,
                True,
            ),
            "native_source_manifest": (
                locked.release_native_executable.source_manifest_path,
                locked.release_native_executable.source_manifest_sha256,
                False,
            ),
            "compiler_input": (
                native_configuration.compiler_input_path,
                str(
                    _artifact_binding(
                        locked.release_bundle,
                        "locked_compiler_input",
                    )["sha256"]
                ),
                False,
            ),
            "mapping": (
                native_configuration.mapping_path,
                str(
                    _artifact_binding(
                        locked.release_bundle,
                        "locked_mapping",
                    )["sha256"]
                ),
                False,
            ),
            "operator_bank": (
                native_configuration.operator_bank_path,
                str(
                    _artifact_binding(
                        locked.release_bundle,
                        "locked_operator_bank",
                    )["sha256"]
                ),
                False,
            ),
            "runtime_manifest": (
                native_configuration.runtime_manifest_path,
                runtime_manifest_sha256,
                False,
            ),
            "direct2x_lut": (
                native_configuration.route_paths["direct-2x"],
                str(
                    _artifact_binding(
                        locked.release_bundle,
                        "direct2x_lut",
                    )["sha256"]
                ),
                False,
            ),
            "direct3over2_lut": (
                native_configuration.route_paths["direct-3over2"],
                str(
                    _artifact_binding(
                        locked.release_bundle,
                        "direct3over2_lut",
                    )["sha256"]
                ),
                False,
            ),
        }
    )
    try:
        p00_inputs = _RetainedInputSet.open(
            {
                "p00_executable": (
                    p00_executable.path,
                    p00_executable.sha256,
                    True,
                )
            }
        )
    except BaseException as primary_error:
        try:
            native_inputs.close()
        except BaseException as cleanup_error:
            raise P07DualFailure(
                primary_error,
                cleanup_error,
            ) from primary_error
        raise
    values = native_inputs.values
    retained_executable = NativeExecutable(
        path=locked.release_native_executable.path,
        sha256=locked.release_native_executable.sha256,
        source_manifest_path=values["native_source_manifest"].descriptor_path,
        source_manifest_sha256=(
            locked.release_native_executable.source_manifest_sha256
        ),
        compiled_now=False,
    )
    retained_configuration = NativeConfiguration(
        root=native_configuration.root,
        compiler_input_path=values["compiler_input"].descriptor_path,
        mapping_path=values["mapping"].descriptor_path,
        operator_bank_path=values["operator_bank"].descriptor_path,
        runtime_manifest_path=values["runtime_manifest"].descriptor_path,
        route_paths={
            "direct-2x": values["direct2x_lut"].descriptor_path,
            "direct-3over2": values["direct3over2_lut"].descriptor_path,
        },
        configuration=native_configuration.configuration,
    )
    return _RetainedNativeRuntime(
        native_inputs=native_inputs,
        p00_inputs=p00_inputs,
        native_executable=retained_executable,
        native_configuration=retained_configuration,
    )


def _mkdir(path: Path) -> None:
    cursor = path
    while True:
        try:
            metadata = os.lstat(cursor)
        except FileNotFoundError:
            if cursor == cursor.parent:
                raise P07ProductionError("P07 cache directory has no existing ancestor")
            cursor = cursor.parent
            continue
        except OSError as error:
            raise P07ProductionError("P07 cache directory cannot be inspected") from error
        if stat.S_ISLNK(metadata.st_mode):
            raise P07ProductionError("P07 cache directory traverses a symbolic link")
        if not stat.S_ISDIR(metadata.st_mode):
            raise P07ProductionError("P07 cache directory ancestor is not a directory")
        break
    guard = _RetainedCacheDirectory.open(cursor, protected_roots=())
    try:
        guard.ensure_directory(path)
        guard.advance_monotonic()
    finally:
        guard.close()


def _write_or_verify(path: Path, payload: bytes) -> None:
    guard = _RetainedCacheDirectory.open(path.parent, protected_roots=())
    try:
        guard.write_or_verify(path, payload)
    finally:
        guard.close()


def _runtime_route_rows(locked: P07LockedReleaseInputs) -> Sequence[Mapping[str, object]]:
    rows = locked.lut_manifest["routes"]
    assert isinstance(rows, list)
    return tuple(dict(row) for row in rows)


def _decode_compile_journal(
    payload: bytes,
) -> Sequence[Mapping[str, object]]:
    if payload and not payload.endswith(b"\n"):
        raise P07ProductionError("P07 compiler journal is truncated")
    entries = []
    state_by_transaction: Dict[str, str] = {}
    for sequence, encoded in enumerate(payload.splitlines()):
        try:
            value = json.loads(encoded)
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            raise P07ProductionError("P07 compiler journal is invalid") from error
        phase = value.get("phase") if isinstance(value, dict) else None
        transaction_id = (
            value.get("transaction_id") if isinstance(value, dict) else None
        )
        staging_name = (
            value.get("staging_name") if isinstance(value, dict) else None
        )
        expected_keys = {
            "schema_version",
            "artifact_kind",
            "phase",
            "transaction_id",
            "staging_name",
            "sequence",
            "previous_event_sha256",
            "event_sha256",
        }
        if phase == "validated":
            expected_keys.add("sha256_by_artifact")
        event_core = (
            {key: item for key, item in value.items() if key != "event_sha256"}
            if isinstance(value, dict)
            else {}
        )
        hashes = value.get("sha256_by_artifact") if isinstance(value, dict) else None
        prior = entries[-1] if entries else None
        prior_phase = prior.get("phase") if prior is not None else None
        prior_transaction_id = (
            prior.get("transaction_id") if prior is not None else None
        )
        if prior is None:
            transition_valid = phase == "started"
        elif prior_phase == "started":
            transition_valid = (
                transaction_id == prior_transaction_id
                and phase in {"validated", "quarantined"}
            )
        elif prior_phase == "validated":
            transition_valid = (
                transaction_id == prior_transaction_id
                and phase == "complete"
            )
        else:
            transition_valid = (
                phase == "started"
                and transaction_id not in state_by_transaction
            )
        if (
            not isinstance(value, dict)
            or _canonical_bytes(value) != encoded
            or set(value) != expected_keys
            or value.get("schema_version") != "1.0.0"
            or value.get("artifact_kind")
            != "p07_compiler_transaction_journal_event"
            or phase
            not in {"started", "validated", "quarantined", "complete"}
            or not isinstance(transaction_id, str)
            or len(transaction_id) != 32
            or any(character not in "0123456789abcdef" for character in transaction_id)
            or staging_name != ".compiler-staging-{}".format(transaction_id)
            or value.get("sequence") != sequence
            or value.get("previous_event_sha256")
            != (prior.get("event_sha256") if prior is not None else None)
            or value.get("event_sha256") != canonical_sha256(event_core)
            or (
                phase == "validated"
                and (
                    not isinstance(hashes, dict)
                    or set(hashes)
                    != {
                        "compile-summary.json",
                        "direct2x.ashlut",
                        "direct3over2.ashlut",
                    }
                    or any(not _is_sha256(item) for item in hashes.values())
                )
            )
            or not transition_valid
        ):
            raise P07ProductionError("P07 compiler journal event differs")
        entries.append(value)
        state_by_transaction[transaction_id] = str(phase)
    return tuple(entries)


def _compile_journal_event_name(index: int) -> str:
    if index < 0 or index > 99_999_999:
        raise P07ProductionError("P07 compiler journal index is invalid")
    return "event-{:08d}.json".format(index)


def _compile_journal_event_index(name: str) -> Optional[int]:
    if (
        len(name) != len("event-00000000.json")
        or not name.startswith("event-")
        or not name.endswith(".json")
    ):
        return None
    encoded_index = name[len("event-"):-len(".json")]
    if len(encoded_index) != 8 or not encoded_index.isascii() or not encoded_index.isdigit():
        return None
    index = int(encoded_index)
    if _compile_journal_event_name(index) != name:
        return None
    return index


def _read_compile_journal(
    cache_guard: _RetainedCacheDirectory,
    directory: Path,
) -> Sequence[Mapping[str, object]]:
    descriptor = cache_guard.retained_directory_descriptor(directory)
    marker = ".p07-uncommitted-"
    for candidate in tuple(os.listdir(descriptor)):
        if marker not in candidate:
            continue
        if not candidate.startswith("."):
            raise P07ProductionError(
                "P07 compiler journal contains an unknown publication"
            )
        final_name, separator, _ = candidate[1:].partition(marker)
        if separator != marker or _compile_journal_event_index(final_name) is None:
            raise P07ProductionError(
                "P07 compiler journal contains an unknown publication"
            )
        cache_guard.recover_interrupted_publication(directory / final_name)

    names = tuple(sorted(os.listdir(descriptor)))
    expected_names = tuple(
        _compile_journal_event_name(index)
        for index in range(len(names))
    )
    if names != expected_names:
        raise P07ProductionError(
            "P07 compiler journal event sequence differs"
        )
    payloads = []
    for name in names:
        payload = cache_guard.read_regular(directory / name)
        if payload.count(b"\n") != 1 or not payload.endswith(b"\n"):
            raise P07ProductionError(
                "P07 compiler journal event boundary differs"
            )
        payloads.append(payload)
    return _decode_compile_journal(b"".join(payloads))


def _append_compile_journal(
    cache_guard: _RetainedCacheDirectory,
    directory: Path,
    event: Mapping[str, object],
) -> Mapping[str, object]:
    existing = tuple(_read_compile_journal(cache_guard, directory))
    materialized = dict(event)
    if set(materialized) not in (
        {
            "schema_version",
            "artifact_kind",
            "phase",
            "transaction_id",
            "staging_name",
        },
        {
            "schema_version",
            "artifact_kind",
            "phase",
            "transaction_id",
            "staging_name",
            "sha256_by_artifact",
        },
    ):
        raise P07ProductionError(
            "P07 compiler journal draft field set differs"
        )
    materialized["sequence"] = len(existing)
    materialized["previous_event_sha256"] = (
        existing[-1]["event_sha256"] if existing else None
    )
    materialized["event_sha256"] = canonical_sha256(materialized)
    prospective = existing + (materialized,)
    encoded = b"".join(
        _canonical_bytes(row) + b"\n"
        for row in prospective
    )
    if tuple(_decode_compile_journal(encoded)) != prospective:
        raise P07ProductionError(
            "P07 compiler journal append differs before publication"
        )
    event_path = directory / _compile_journal_event_name(len(existing))
    cache_guard.write_or_verify(
        event_path,
        _canonical_bytes(materialized) + b"\n",
    )
    if tuple(_read_compile_journal(cache_guard, directory)) != prospective:
        raise P07ProductionError(
            "P07 compiler journal append differs after publication"
        )
    return materialized


def _write_staged_compiler_summary(path: Path, payload: bytes) -> None:
    parent_descriptor = os.open(
        path.parent,
        os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
    )
    descriptor = -1
    try:
        descriptor = os.open(
            path.name,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
            0o600,
            dir_fd=parent_descriptor,
        )
        offset = 0
        while offset < len(payload):
            written = os.write(descriptor, payload[offset:])
            if written <= 0:
                raise P07ProductionError(
                    "P07 compiler staged summary made no progress"
                )
            offset += written
        os.fsync(descriptor)
        os.fsync(parent_descriptor)
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        os.close(parent_descriptor)


def _compiler_journal_event(
    *,
    phase: str,
    transaction_id: str,
    staging_name: str,
    hashes: Optional[Mapping[str, str]] = None,
) -> Mapping[str, object]:
    value: Dict[str, object] = {
        "schema_version": "1.0.0",
        "artifact_kind": "p07_compiler_transaction_journal_event",
        "phase": phase,
        "transaction_id": transaction_id,
        "staging_name": staging_name,
    }
    if hashes is not None:
        value["sha256_by_artifact"] = dict(hashes)
    return value


def _sync_compiler_staging(
    cache_guard: _RetainedCacheDirectory,
    staging_root: Path,
) -> Mapping[str, bytes]:
    """Durably read the exact validated compiler output set through FDs."""

    expected_names = tuple(
        sorted(("compile-summary.json", *ROUTE_FILENAMES.values()))
    )
    parent_descriptor = cache_guard.retained_directory_descriptor(
        staging_root.parent
    )
    directory_descriptor = -1
    try:
        named_directory = os.stat(
            staging_root.name,
            dir_fd=parent_descriptor,
            follow_symlinks=False,
        )
        if (
            stat.S_ISLNK(named_directory.st_mode)
            or not stat.S_ISDIR(named_directory.st_mode)
        ):
            raise P07ProductionError(
                "P07 compiler staging is not a safe directory"
            )
        directory_descriptor = os.open(
            staging_root.name,
            os.O_RDONLY
            | os.O_DIRECTORY
            | os.O_NOFOLLOW
            | getattr(os, "O_CLOEXEC", 0),
            dir_fd=parent_descriptor,
        )
        before_directory = os.fstat(directory_descriptor)
        if _directory_record(before_directory) != _directory_record(named_directory):
            raise P07ProductionError(
                "P07 compiler staging identity changed while opening"
            )
        names = tuple(sorted(os.listdir(directory_descriptor)))
        if names != expected_names:
            raise P07ProductionError(
                "P07 compiler staging file set differs"
            )
        payloads: Dict[str, bytes] = {}
        for name in names:
            descriptor = -1
            try:
                before = os.stat(
                    name,
                    dir_fd=directory_descriptor,
                    follow_symlinks=False,
                )
                if (
                    stat.S_ISLNK(before.st_mode)
                    or not stat.S_ISREG(before.st_mode)
                    or before.st_nlink != 1
                ):
                    raise P07ProductionError(
                        "P07 compiler staging contains an unsafe file"
                    )
                descriptor = os.open(
                    name,
                    os.O_RDONLY
                    | os.O_NOFOLLOW
                    | getattr(os, "O_CLOEXEC", 0),
                    dir_fd=directory_descriptor,
                )
                opened = os.fstat(descriptor)
                if (
                    not stat.S_ISREG(opened.st_mode)
                    or opened.st_nlink != 1
                    or _RetainedCacheDirectory._stable_file_metadata(opened)
                    != _RetainedCacheDirectory._stable_file_metadata(before)
                ):
                    raise P07ProductionError(
                        "P07 compiler staging identity changed while opening"
                    )
                chunks = []
                while True:
                    chunk = os.read(descriptor, 1024 * 1024)
                    if not chunk:
                        break
                    chunks.append(chunk)
                os.fsync(descriptor)
                after = os.fstat(descriptor)
                final = os.stat(
                    name,
                    dir_fd=directory_descriptor,
                    follow_symlinks=False,
                )
                if (
                    _RetainedCacheDirectory._stable_file_metadata(after)
                    != _RetainedCacheDirectory._stable_file_metadata(opened)
                    or _RetainedCacheDirectory._stable_file_metadata(final)
                    != _RetainedCacheDirectory._stable_file_metadata(opened)
                ):
                    raise P07ProductionError(
                        "P07 compiler staging changed during durability sync"
                    )
                payload = b"".join(chunks)
                if len(payload) != opened.st_size:
                    raise P07ProductionError(
                        "P07 compiler staging size changed during durability sync"
                    )
                payloads[name] = payload
            finally:
                if descriptor >= 0:
                    os.close(descriptor)
        os.fsync(directory_descriptor)
        after_directory = os.fstat(directory_descriptor)
        final_names = tuple(sorted(os.listdir(directory_descriptor)))
        final_named_directory = os.stat(
            staging_root.name,
            dir_fd=parent_descriptor,
            follow_symlinks=False,
        )
        if (
            final_names != expected_names
            or _directory_record(after_directory)
            != _directory_record(before_directory)
            or _directory_record(final_named_directory)
            != _directory_record(before_directory)
        ):
            raise P07ProductionError(
                "P07 compiler staging directory identity changed"
            )
        return payloads
    except P07ProductionError:
        raise
    except OSError as error:
        raise P07ProductionError(
            "P07 compiler staging cannot be synchronized"
        ) from error
    finally:
        if directory_descriptor >= 0:
            os.close(directory_descriptor)


def _compiler_staging_inventory(
    cache_guard: _RetainedCacheDirectory,
    recompile_root: Path,
) -> Sequence[str]:
    descriptor = cache_guard.retained_directory_descriptor(recompile_root)
    result = []
    for name in os.listdir(descriptor):
        if not name.startswith(".compiler-staging-"):
            continue
        transaction_id = name[len(".compiler-staging-"):]
        if (
            len(transaction_id) != 32
            or any(
                character not in "0123456789abcdef"
                for character in transaction_id
            )
        ):
            raise P07ProductionError(
                "P07 compiler staging name is not journal-owned"
            )
        metadata = os.stat(
            name,
            dir_fd=descriptor,
            follow_symlinks=False,
        )
        if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISDIR(metadata.st_mode):
            raise P07ProductionError(
                "P07 compiler staging entry is unsafe"
            )
        result.append(name)
    return tuple(sorted(result))


def _archive_completed_compiler_transaction(
    *,
    cache_guard: _RetainedCacheDirectory,
    recompile_root: Path,
    journal_root: Path,
    transaction_id: str,
    staging_name: str,
    expected_hashes: Mapping[str, str],
    append_complete: bool,
) -> Mapping[str, bytes]:
    """Move validated staging out of the temporary namespace durably."""

    if (
        staging_name != ".compiler-staging-{}".format(transaction_id)
        or set(expected_hashes)
        != {
            "compile-summary.json",
            "direct2x.ashlut",
            "direct3over2.ashlut",
        }
        or any(not _is_sha256(value) for value in expected_hashes.values())
    ):
        raise P07ProductionError(
            "P07 completed compiler transaction binding differs"
        )
    completed = recompile_root / "completed"
    cache_guard.ensure_directory(completed)
    recompile_descriptor = cache_guard.retained_directory_descriptor(
        recompile_root
    )
    completed_descriptor = cache_guard.retained_directory_descriptor(completed)

    def metadata_or_none(descriptor: int, name: str) -> Optional[os.stat_result]:
        try:
            return os.stat(
                name,
                dir_fd=descriptor,
                follow_symlinks=False,
            )
        except FileNotFoundError:
            return None
        except OSError as error:
            raise P07ProductionError(
                "P07 completed compiler entry cannot be inspected"
            ) from error

    source = metadata_or_none(recompile_descriptor, staging_name)
    destination = metadata_or_none(completed_descriptor, transaction_id)
    for metadata in (source, destination):
        if metadata is not None and (
            stat.S_ISLNK(metadata.st_mode)
            or not stat.S_ISDIR(metadata.st_mode)
        ):
            raise P07ProductionError(
                "P07 completed compiler entry is unsafe"
            )
    if source is not None and destination is not None:
        raise P07ProductionError(
            "P07 completed compiler source and destination both exist"
        )
    if source is None and destination is None:
        raise P07ProductionError(
            "P07 validated compiler staging is absent"
        )
    payload_root = (
        recompile_root / staging_name
        if source is not None
        else completed / transaction_id
    )
    payloads = _sync_compiler_staging(cache_guard, payload_root)
    if {
        name: _sha256(payload)
        for name, payload in payloads.items()
    } != dict(expected_hashes):
        raise P07ProductionError(
            "P07 completed compiler staging bytes differ"
        )
    if source is not None:
        try:
            os.rename(
                staging_name,
                transaction_id,
                src_dir_fd=recompile_descriptor,
                dst_dir_fd=completed_descriptor,
            )
            os.fsync(recompile_descriptor)
            os.fsync(completed_descriptor)
        except OSError as error:
            raise P07ProductionError(
                "P07 validated compiler staging cannot be archived"
            ) from error
        moved = metadata_or_none(completed_descriptor, transaction_id)
        if (
            moved is None
            or (moved.st_dev, moved.st_ino) != (source.st_dev, source.st_ino)
            or metadata_or_none(recompile_descriptor, staging_name) is not None
        ):
            raise P07ProductionError(
                "P07 completed compiler archive identity changed"
            )
    if append_complete:
        _append_compile_journal(
            cache_guard,
            journal_root,
            _compiler_journal_event(
                phase="complete",
                transaction_id=transaction_id,
                staging_name=staging_name,
            ),
        )
    return payloads


def _quarantine_interrupted_compiler_transaction(
    *,
    cache_guard: _RetainedCacheDirectory,
    recompile_root: Path,
    journal_root: Path,
    event: Mapping[str, object],
) -> None:
    """Durably quarantine one journal-owned interrupted staging tree."""

    if event.get("phase") != "started":
        raise P07ProductionError(
            "P07 compiler quarantine event is not started"
        )
    transaction_id = str(event["transaction_id"])
    staging_name = str(event["staging_name"])
    quarantine = recompile_root / "quarantine"
    cache_guard.ensure_directory(quarantine)
    recompile_descriptor = cache_guard.retained_directory_descriptor(
        recompile_root
    )
    quarantine_descriptor = cache_guard.retained_directory_descriptor(
        quarantine
    )

    def metadata_or_none(descriptor: int, name: str) -> Optional[os.stat_result]:
        try:
            return os.stat(
                name,
                dir_fd=descriptor,
                follow_symlinks=False,
            )
        except FileNotFoundError:
            return None
        except OSError as error:
            raise P07ProductionError(
                "P07 compiler quarantine entry cannot be inspected"
            ) from error

    source = metadata_or_none(recompile_descriptor, staging_name)
    destination = metadata_or_none(quarantine_descriptor, transaction_id)
    for metadata in (source, destination):
        if metadata is not None and (
            stat.S_ISLNK(metadata.st_mode)
            or not stat.S_ISDIR(metadata.st_mode)
        ):
            raise P07ProductionError(
                "P07 compiler quarantine entry is unsafe"
            )
    if source is not None and destination is not None:
        raise P07ProductionError(
            "P07 compiler quarantine source and destination both exist"
        )
    if source is not None:
        try:
            os.rename(
                staging_name,
                transaction_id,
                src_dir_fd=recompile_descriptor,
                dst_dir_fd=quarantine_descriptor,
            )
            os.fsync(recompile_descriptor)
            os.fsync(quarantine_descriptor)
        except OSError as error:
            raise P07ProductionError(
                "P07 compiler staging cannot be quarantined"
            ) from error
        moved = metadata_or_none(quarantine_descriptor, transaction_id)
        if (
            moved is None
            or (moved.st_dev, moved.st_ino) != (source.st_dev, source.st_ino)
            or metadata_or_none(recompile_descriptor, staging_name) is not None
        ):
            raise P07ProductionError(
                "P07 compiler quarantine identity changed"
            )
    _append_compile_journal(
        cache_guard,
        journal_root,
        _compiler_journal_event(
            phase="quarantined",
            transaction_id=transaction_id,
            staging_name=staging_name,
        ),
    )


def _build_release_native_configuration(
    *,
    locked: P07LockedReleaseInputs,
    native_factory: NativeCandidateAdapterFactory,
    cache_guard: _RetainedCacheDirectory,
    evidence_store: ContentAddressedEvidenceStore,
) -> Tuple[NativeConfiguration, Mapping[str, object]]:
    """Recompile independently, compare exact bytes, then bind release files."""

    cache_root = cache_guard.root
    cache_guard.verify_external_path(cache_root)
    identity = canonical_sha256(
        {
            "p06_release_bundle_manifest_sha256": (
                locked.release_bundle_manifest_sha256
            ),
            "configuration_sha256": locked.configuration_sha256,
            "selected_vector_sha256": locked.selected_vector_sha256,
            "native_source_manifest_sha256": (
                locked.release_native_executable.source_manifest_sha256
            ),
        }
    )
    root = cache_root / "release-runtime" / identity
    cache_guard.ensure_directory(root)
    recompile_root = root / "independent-recompile"
    cache_guard.ensure_directory(recompile_root)
    summary_path = recompile_root / "compile-summary.json"
    route_paths = {
        route: recompile_root / filename
        for route, filename in ROUTE_FILENAMES.items()
    }
    compiler_hash = str(
        locked.compiler_input["hash_bindings"]["compiler_inputs_sha256"]
    )
    journal_root = recompile_root / "compile-transaction-journal"
    cache_guard.ensure_directory(journal_root)
    journal = _read_compile_journal(cache_guard, journal_root)
    latest = journal[-1] if journal else None
    allowed_staging_names = (
        {str(latest["staging_name"])}
        if latest is not None
        and latest.get("phase") in {"started", "validated", "complete"}
        else set()
    )
    staging_inventory = set(
        _compiler_staging_inventory(cache_guard, recompile_root)
    )
    if not staging_inventory.issubset(allowed_staging_names):
        raise P07ProductionError(
            "P07 compiler staging is not owned by the latest journal event"
        )
    if cache_guard.entry_exists(summary_path):
        summary = _decode_json(
            cache_guard.read_regular(summary_path),
            "P07 recompile summary",
        )
        if latest is None or latest.get("phase") not in {
            "validated",
            "complete",
        }:
            raise P07ProductionError(
                "P07 compiler publication has no committed transaction"
            )
        if latest.get("phase") == "validated":
            expected_hashes = latest["sha256_by_artifact"]
            published_payloads = {
                "compile-summary.json": cache_guard.read_regular(
                    summary_path
                ),
                **{
                    path.name: cache_guard.read_regular(path)
                    for path in route_paths.values()
                },
            }
            if {
                name: _sha256(payload)
                for name, payload in published_payloads.items()
            } != expected_hashes:
                raise P07ProductionError(
                    "P07 interrupted compiler publication bytes differ"
                )
            _archive_completed_compiler_transaction(
                cache_guard=cache_guard,
                recompile_root=recompile_root,
                journal_root=journal_root,
                transaction_id=str(latest["transaction_id"]),
                staging_name=str(latest["staging_name"]),
                expected_hashes=expected_hashes,
                append_complete=True,
            )
            cache_guard.advance_monotonic()
        else:
            if len(journal) < 2 or journal[-2].get("phase") != "validated":
                raise P07ProductionError(
                    "completed P07 compiler transaction has no validation"
                )
            validated = journal[-2]
            _archive_completed_compiler_transaction(
                cache_guard=cache_guard,
                recompile_root=recompile_root,
                journal_root=journal_root,
                transaction_id=str(latest["transaction_id"]),
                staging_name=str(latest["staging_name"]),
                expected_hashes=validated["sha256_by_artifact"],
                append_complete=False,
            )
            cache_guard.advance_monotonic()
    else:
        if latest is not None and latest.get("phase") == "complete":
            raise P07ProductionError(
                "completed P07 compiler publication is absent"
            )
        staging_root: Optional[Path] = None
        staged_summary_path: Optional[Path] = None
        transaction_id: Optional[str] = None
        validated_hashes: Optional[Mapping[str, str]] = None
        if latest is not None and latest.get("phase") == "validated":
            transaction_id = str(latest["transaction_id"])
            staging_name = str(latest.get("staging_name"))
            staging_root = recompile_root / staging_name
            staged_summary_path = staging_root / "compile-summary.json"
            staged_payloads = _sync_compiler_staging(
                cache_guard,
                staging_root,
            )
            summary = _decode_json(
                staged_payloads["compile-summary.json"],
                "validated P07 compiler summary",
            )
            expected_hashes = latest.get("sha256_by_artifact")
            observed_hashes = {
                name: _sha256(payload)
                for name, payload in staged_payloads.items()
            }
            if observed_hashes != expected_hashes:
                raise P07ProductionError(
                    "validated P07 compiler transaction bytes differ"
                )
            validated_hashes = dict(observed_hashes)
        else:
            if latest is not None and latest.get("phase") == "started":
                _quarantine_interrupted_compiler_transaction(
                    cache_guard=cache_guard,
                    recompile_root=recompile_root,
                    journal_root=journal_root,
                    event=latest,
                )
            transaction_id = uuid.uuid4().hex
            staging_name = ".compiler-staging-{}".format(transaction_id)
            staging_root = recompile_root / staging_name
            _append_compile_journal(
                cache_guard,
                journal_root,
                _compiler_journal_event(
                    phase="started",
                    transaction_id=transaction_id,
                    staging_name=staging_name,
                ),
            )
            recompile_descriptor = os.open(
                recompile_root,
                os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
            )
            try:
                os.mkdir(staging_name, 0o700, dir_fd=recompile_descriptor)
                os.fsync(recompile_descriptor)
            finally:
                os.close(recompile_descriptor)
            compiler_inputs = _RetainedInputSet.open(
                {
                    "executable": (
                        locked.release_native_executable.path,
                        locked.release_native_executable.sha256,
                        True,
                    ),
                    "compiler_input": (
                    _artifact_path(
                        locked.release_root,
                        locked.release_bundle,
                        "locked_compiler_input",
                    ),
                    str(
                        _artifact_binding(
                            locked.release_bundle,
                            "locked_compiler_input",
                        )["sha256"]
                    ),
                    False,
                    ),
                    "mapping": (
                    _artifact_path(
                        locked.release_root,
                        locked.release_bundle,
                        "locked_mapping",
                    ),
                    str(
                        _artifact_binding(
                            locked.release_bundle,
                            "locked_mapping",
                        )["sha256"]
                    ),
                    False,
                    ),
                    "operator_bank": (
                    _artifact_path(
                        locked.release_root,
                        locked.release_bundle,
                        "locked_operator_bank",
                    ),
                    str(
                        _artifact_binding(
                            locked.release_bundle,
                            "locked_operator_bank",
                        )["sha256"]
                    ),
                    False,
                    ),
                }
            )
            command = [
                os.fspath(locked.release_native_executable.path),
                "compile-candidate",
                "--compiler-input",
                os.fspath(
                    compiler_inputs.values["compiler_input"].descriptor_path
                ),
                "--mapping",
                os.fspath(compiler_inputs.values["mapping"].descriptor_path),
                "--operator-bank",
                os.fspath(
                    compiler_inputs.values["operator_bank"].descriptor_path
                ),
                "--output-directory",
                os.fspath(staging_root),
            ]
            try:
                completed = _run_checked(
                    command,
                    cwd=native_factory.repository_root,
                    pass_fds=compiler_inputs.pass_fds,
                    execution_authorizer=lambda pid: authorize_running_code(
                        pid,
                        locked.macos_code_identities[
                            "production_swift_executable"
                        ],
                    ),
                    authorized_environment=authorized_process_environment(
                        Path("/private/tmp")
                    ),
                )
                compiler_inputs.verify()
            except BaseException as primary_error:
                try:
                    compiler_inputs.close()
                except BaseException as cleanup_error:
                    raise P07DualFailure(
                        primary_error,
                        cleanup_error,
                    ) from primary_error
                raise
            else:
                compiler_inputs.close()
            try:
                summary = json.loads(completed.stdout)
            except (UnicodeDecodeError, json.JSONDecodeError) as error:
                raise P07ProductionError(
                    "P07 compiler summary is invalid JSON"
                ) from error
            if not isinstance(summary, dict):
                raise P07ProductionError(
                    "P07 compiler summary is not an object"
                )
            staged_paths = {
                route: staging_root / filename
                for route, filename in ROUTE_FILENAMES.items()
            }
            native_factory.builder._validate_compile_summary(
                summary,
                configuration_id=str(locked.mapping["configuration_id"]),
                compiler_hash=compiler_hash,
                mapping_hash=str(
                    _artifact_binding(
                        locked.release_bundle,
                        "locked_mapping",
                    )["sha256"]
                ),
                operator_hash=str(
                    _artifact_binding(
                        locked.release_bundle,
                        "locked_operator_bank",
                    )["sha256"]
                ),
                route_paths=staged_paths,
            )
            staged_summary_path = staging_root / "compile-summary.json"
            _write_staged_compiler_summary(
                staged_summary_path,
                _canonical_bytes(summary) + b"\n",
            )
            staged_payloads = _sync_compiler_staging(
                cache_guard,
                staging_root,
            )
            hashes = {
                name: _sha256(payload)
                for name, payload in staged_payloads.items()
            }
            _append_compile_journal(
                cache_guard,
                journal_root,
                _compiler_journal_event(
                    phase="validated",
                    transaction_id=transaction_id,
                    staging_name=staging_name,
                    hashes=hashes,
                ),
            )
            validated_hashes = dict(hashes)

        assert staging_root is not None and staged_summary_path is not None
        staged_paths = {
            route: staging_root / filename
            for route, filename in ROUTE_FILENAMES.items()
        }
        native_factory.builder._validate_compile_summary(
            summary,
            configuration_id=str(locked.mapping["configuration_id"]),
            compiler_hash=compiler_hash,
            mapping_hash=str(
                _artifact_binding(locked.release_bundle, "locked_mapping")[
                    "sha256"
                ]
            ),
            operator_hash=str(
                _artifact_binding(
                    locked.release_bundle,
                    "locked_operator_bank",
                )["sha256"]
            ),
            route_paths=staged_paths,
        )
        staged_payloads = _sync_compiler_staging(
            cache_guard,
            staging_root,
        )
        observed_hashes = {
            name: _sha256(payload)
            for name, payload in staged_payloads.items()
        }
        if validated_hashes is None or observed_hashes != validated_hashes:
            raise P07ProductionError(
                "P07 validated compiler staging changed before publication"
            )
        for route, final_path in route_paths.items():
            cache_guard.write_or_verify(
                final_path,
                staged_payloads[staged_paths[route].name],
            )
        cache_guard.write_or_verify(
            summary_path,
            staged_payloads["compile-summary.json"],
        )
        assert transaction_id is not None
        assert validated_hashes is not None
        _archive_completed_compiler_transaction(
            cache_guard=cache_guard,
            recompile_root=recompile_root,
            journal_root=journal_root,
            transaction_id=transaction_id,
            staging_name=staging_root.name,
            expected_hashes=validated_hashes,
            append_complete=True,
        )
        if _compiler_staging_inventory(cache_guard, recompile_root):
            raise P07ProductionError(
                "P07 completed compiler staging was not archived"
            )
        cache_guard.advance_monotonic()

    native_factory.builder._validate_compile_summary(
        summary,
        configuration_id=str(locked.mapping["configuration_id"]),
        compiler_hash=compiler_hash,
        mapping_hash=str(_artifact_binding(locked.release_bundle, "locked_mapping")["sha256"]),
        operator_hash=str(_artifact_binding(locked.release_bundle, "locked_operator_bank")["sha256"]),
        route_paths=route_paths,
    )

    comparisons = []
    released_route_paths: Dict[str, Path] = {}
    for route, identifier in zip(
        ROUTE_ORDER,
        ("direct2x_lut", "direct3over2_lut"),
    ):
        released = _artifact_path(locked.release_root, locked.release_bundle, identifier)
        released_route_paths[route] = released
        compiled_bytes = cache_guard.read_regular(route_paths[route])
        released_bytes = _read_regular_file(released, "P06 released LUT")
        if compiled_bytes != released_bytes:
            raise P07ProductionError("P07 recompiled LUT differs byte-for-byte: {}".format(route))
        comparisons.append(
            {
                "target_route": route,
                "whole_file_sha256": _sha256(released_bytes),
                "size_bytes": len(released_bytes),
                "byte_identical": True,
            }
        )
    recompile_evidence = {
        "schema_version": "1.0.0",
        "artifact_kind": "p07_release_lut_independent_recompile",
        "status": "pass",
        "p06_release_bundle_manifest_sha256": locked.release_bundle_manifest_sha256,
        "configuration_sha256": locked.configuration_sha256,
        "compiler_inputs_sha256": compiler_hash,
        "native_executable_sha256": locked.release_native_executable.sha256,
        "native_source_manifest_sha256": (
            locked.release_native_executable.source_manifest_sha256
        ),
        "current_worktree_builder_executable_sha256": (
            native_factory.builder.executable.sha256
        ),
        "released_binary_used_for_recompile": True,
        "routes": comparisons,
        "holdout_accessed": False,
    }
    evidence_store.publish(recompile_evidence)

    runtime_manifest = {
        "schema_version": "1.0.0",
        "manifest_id": "mirmir-ash-candidate-route-luts-v1",
        "status": "calibration_candidate",
        "configuration_id": locked.mapping["configuration_id"],
        "compiler_input": locked.lut_manifest["compiler_input"],
        "hash_bindings": locked.compiler_input["hash_bindings"],
        "routes": list(_runtime_route_rows(locked)),
        "swift_cli": {
            "executable_sha256": locked.release_native_executable.sha256,
            "source_manifest_sha256": (
                locked.release_native_executable.source_manifest_sha256
            ),
        },
        "native_parity_claimed": False,
    }
    runtime_manifest["manifest_sha256"] = canonical_sha256(runtime_manifest)
    try:
        validate_schema(
            runtime_manifest,
            native_factory.repository_root
            / "validation/calibration_v2/schemas/"
            "candidate-lut-runtime-manifest-v1.schema.json",
        )
    except ValueError as error:
        raise P07ProductionError("P07 release runtime envelope violates schema") from error
    runtime_manifest_path = root / "release-runtime-envelope.json"
    cache_guard.write_or_verify(
        runtime_manifest_path,
        canonical_json_bytes(runtime_manifest) + b"\n",
    )
    cache_guard.advance_monotonic()

    raw_output_hash = canonical_sha256(RAW_OUTPUT_CONTRACT)
    bank = str(locked.mapping["shared_bank_configuration_sha256"])
    full_hash = canonical_sha256(
        {
            "candidate_vector_sha256": locked.selected_vector_sha256,
            "shared_bank_configuration_sha256": bank,
            "mapping_sha256": locked.compiler_input["hash_bindings"]["mapping_sha256"],
            "operator_bank_sha256": locked.compiler_input["hash_bindings"]["operator_bank_sha256"],
            "metric_policy_sha256": locked.compiler_input["hash_bindings"]["metric_policy_sha256"],
            "compiler_inputs_sha256": compiler_hash,
            "raw_output_contract_sha256": raw_output_hash,
        }
    )
    rows_by_route = dict(zip(ROUTE_ORDER, _runtime_route_rows(locked)))
    configuration = {
        "implementation_role": "production_swift_p07_locked_release",
        "configuration_id": locked.mapping["configuration_id"],
        "serialized_candidate_vector_sha256": locked.selected_vector_sha256,
        "candidate_vector": dict(locked.selected_vector),
        "mapping_seed_sha256": native_factory.bound.record("mapping_seed")["sha256"],
        "operator_bank_seed_sha256": native_factory.bound.record("operator_bank_seed")["sha256"],
        "metric_policy_seed_sha256": native_factory.bound.record("metric_policy_seed")["sha256"],
        "candidate_lut_runtime_manifest_sha256": runtime_manifest["manifest_sha256"],
        "mapping_sha256": locked.compiler_input["hash_bindings"]["mapping_sha256"],
        "operator_bank_sha256": locked.compiler_input["hash_bindings"]["operator_bank_sha256"],
        "metric_policy_sha256": locked.compiler_input["hash_bindings"]["metric_policy_sha256"],
        "compiler_inputs_sha256": compiler_hash,
        "compiler_contract_sha256": native_factory.bound.record("compiler_contract")["sha256"],
        "calibration_plan_sha256": locked.compiler_input["hash_bindings"]["calibration_plan_sha256"],
        "corpus_lock_bundle_sha256": locked.compiler_input["hash_bindings"]["corpus_lock_bundle_sha256"],
        "shared_bank_configuration_sha256": bank,
        "raw_output_contract_sha256": raw_output_hash,
        "full_control_configuration_sha256": full_hash,
        "candidate_artifacts": {
            "mapping": dict(locked.mapping),
            "operator_bank": dict(locked.operator_bank),
            "metric_policy": dict(locked.metric_policy),
        },
        "compiler_input_document": dict(locked.compiler_input),
        "boundary_mode": locked.selected_vector["boundary_mode"],
        "route_luts": {
            route: {
                "whole_file_sha256": rows_by_route[route]["whole_file_sha256"],
                "payload_sha256": rows_by_route[route]["payload_sha256"],
                "coordinate_policy": rows_by_route[route]["coordinate_policy"],
                "analysis_grid_source_step": rows_by_route[route]["analysis_grid_source_step"],
            }
            for route in ROUTE_ORDER
        },
        "swift_cli": {
            "executable_sha256": locked.release_native_executable.sha256,
            "source_manifest_sha256": (
                locked.release_native_executable.source_manifest_sha256
            ),
        },
        "p06_release_bundle_manifest_sha256": locked.release_bundle_manifest_sha256,
        "p06_configuration_sha256": locked.configuration_sha256,
        "selected_p06_adapter_configuration_sha256": (
            locked.selected_p06_adapter_configuration_sha256
        ),
        "release_lut_manifest_sha256": locked.lut_manifest["manifest_sha256"],
        "independent_recompile_evidence_sha256": canonical_sha256(
            recompile_evidence
        ),
    }
    return NativeConfiguration(
        root=root,
        compiler_input_path=_artifact_path(
            locked.release_root, locked.release_bundle, "locked_compiler_input"
        ),
        mapping_path=_artifact_path(
            locked.release_root, locked.release_bundle, "locked_mapping"
        ),
        operator_bank_path=_artifact_path(
            locked.release_root, locked.release_bundle, "locked_operator_bank"
        ),
        runtime_manifest_path=runtime_manifest_path,
        route_paths=released_route_paths,
        configuration=configuration,
    ), recompile_evidence


def _corpus_metrics(
    target: PlanarFrame,
    candidate: PlanarFrame,
    *,
    writer_y_psnr_contribution_db: Optional[float],
) -> Mapping[str, object]:
    """Return the exact P06 corpus projection; exact PSNR fails closed."""

    channels = channel_psnr(target, candidate)
    for channel, record in channels.items():
        if channel != "Y" and record == {
            "mse": 0.0,
            "value": None,
            "exact_match": True,
        }:
            continue
        if (
            record.get("exact_match") is not False
            or record.get("value") is None
            or not isinstance(record.get("value"), (int, float))
            or not math.isfinite(float(record["value"]))
            or not isinstance(record.get("mse"), (int, float))
            or float(record["mse"]) <= 0.0
            or not math.isfinite(float(record["mse"]))
        ):
            raise P07ProductionError(
                "P07 corpus {} PSNR is invalid; Y cannot be exact and no cap is permitted".format(
                    channel
                )
            )
    if writer_y_psnr_contribution_db is not None and not math.isfinite(
        writer_y_psnr_contribution_db
    ):
        raise P07ProductionError("P07 writer Y PSNR contribution is nonfinite")
    bundle = {
        "y_psnr_db": dict(channels["Y"]),
        "cb_psnr_db": dict(channels["Cb"]),
        "cr_psnr_db": dict(channels["Cr"]),
        "y_ssim": float(ssim(target.y, candidate.y)),
        "cb_ssim": float(ssim(target.cb, candidate.cb)),
        "cr_ssim": float(ssim(target.cr, candidate.cr)),
        "y_ms_ssim": float(ms_ssim(target.y, candidate.y)),
        "cb_ms_ssim": float(ms_ssim(target.cb, candidate.cb)),
        "cr_ms_ssim": float(ms_ssim(target.cr, candidate.cr)),
        "writer_y_psnr_contribution_db": writer_y_psnr_contribution_db,
    }
    if any(
        not math.isfinite(float(bundle[field]))
        for field in (
            "y_ssim", "cb_ssim", "cr_ssim",
            "y_ms_ssim", "cb_ms_ssim", "cr_ms_ssim",
        )
    ):
        raise P07ProductionError("P07 corpus SSIM projection is nonfinite")
    return bundle


def _boundary_frame(frame: PlanarFrame, label: str) -> PlanarFrame:
    _, reopened = _round_trip_locked_bt709_video_range_nv12(frame)
    if frame_sha256(reopened) != frame_sha256(frame):
        raise P07ProductionError("{} is not on the locked 420v boundary".format(label))
    return _freeze_frame(frame)


def _close_adapter(adapter: CandidateAdapter) -> None:
    close = getattr(adapter.callable, "close", None)
    if not callable(close):
        raise P07ProductionError("P07 native callable has no close operation")
    close()


@contextmanager
def _adapter_lifetime(adapter: CandidateAdapter) -> Iterator[None]:
    primary_error: Optional[BaseException] = None
    primary_traceback = None
    try:
        yield
    except BaseException as error:
        primary_error = error
        primary_traceback = error.__traceback__
    cleanup_error: Optional[BaseException] = None
    try:
        _close_adapter(adapter)
    except BaseException as error:
        cleanup_error = error
    if cleanup_error is not None:
        if primary_error is not None:
            raise P07DualFailure(primary_error, cleanup_error) from primary_error
        raise cleanup_error
    if primary_error is not None:
        raise primary_error.with_traceback(primary_traceback)


def _close_adapter_after_failure(
    adapter: CandidateAdapter,
    primary_error: BaseException,
) -> None:
    try:
        _close_adapter(adapter)
    except BaseException as cleanup_error:
        raise P07DualFailure(primary_error, cleanup_error) from primary_error
    raise primary_error.with_traceback(primary_error.__traceback__)


def _make_release_adapter(
    *,
    locked: P07LockedReleaseInputs,
    native_factory: NativeCandidateAdapterFactory,
    native_configuration: NativeConfiguration,
    split: str,
    artifact_root: Path,
    sampling_plan_manifest_sha256: Optional[str] = None,
    analytic_fixture_manifest_sha256: Optional[str] = None,
    cache_guard: Optional[_RetainedCacheDirectory] = None,
    retained_native_executable: Optional[NativeExecutable] = None,
    native_retained_fds: Sequence[int] = (),
    p00_retained_fds: Sequence[int] = (),
    native_execution_authorizer: Optional[Callable[[int], None]] = None,
    p00_execution_authorizer: Optional[Callable[[int], None]] = None,
    authorized_environment: Optional[Mapping[str, str]] = None,
) -> CandidateAdapter:
    if split not in {"p07_holdout", "p07_holdout_analytic"}:
        raise P07ProductionError("P07 native split is invalid")
    if (
        retained_native_executable is None
        or not native_retained_fds
        or not p00_retained_fds
        or not callable(native_execution_authorizer)
        or not callable(p00_execution_authorizer)
        or authorized_environment is None
    ):
        raise P07ProductionError(
            "P07 native/P00 authorized execution boundary is incomplete"
        )
    configuration = native_configuration.configuration
    configuration_sha256 = canonical_sha256(configuration)
    if cache_guard is None:
        _mkdir(artifact_root)
    else:
        cache_guard.ensure_directory(artifact_root)
    session = NativeSwiftSession(
        retained_native_executable,
        native_configuration,
        timeout_seconds=native_factory.timeout_seconds,
        pass_fds=native_retained_fds,
        execution_authorizer=native_execution_authorizer,
        authorized_environment=authorized_environment,
    )
    try:
        callable_object = NativeCandidateCallable(
            session=session,
            adapter_configuration_sha256=configuration_sha256,
            failure_root=artifact_root / "failures",
            split=split,
            p00_helper=P00NativeHelper(
                native_factory.p00_builder.executable,
                artifact_root / "p00-invocations",
                pass_fds=p00_retained_fds,
                execution_authorizer=p00_execution_authorizer,
                authorized_environment=authorized_environment,
            ),
            validation_sample_lock_sha256=str(
                native_factory.bound.record("validation_sample_lock")["sha256"]
            ),
            degradation_policy_sha256=str(
                native_factory.bound.record("degradation_policy")["sha256"]
            ),
            p07_sampling_plan_manifest_sha256=sampling_plan_manifest_sha256,
            p07_analytic_fixture_manifest_sha256=(
                analytic_fixture_manifest_sha256
            ),
            p07_release_bundle_manifest_sha256=(
                locked.release_bundle_manifest_sha256
            ),
        )
        return CandidateAdapter(
            candidate_id="{}-{}".format(configuration["configuration_id"], split),
            configuration=configuration,
            configuration_sha256=configuration_sha256,
            callable=callable_object,
        )
    except BaseException as primary_error:
        try:
            session.close()
        except BaseException as cleanup_error:
            raise P07DualFailure(primary_error, cleanup_error) from primary_error
        raise primary_error.with_traceback(primary_error.__traceback__)


def _selection_bundle(
    *,
    locked: P07LockedReleaseInputs,
    native_factory: NativeCandidateAdapterFactory,
    adapter: CandidateAdapter,
) -> ControlSelectionBundle:
    try:
        return make_control_selection_bundle(
            shared_bank_configuration_sha256=str(
                adapter.configuration["shared_bank_configuration_sha256"]
            ),
            degradation_policy_sha256=str(
                locked.degradation_policy["policy_sha256"]
            ),
            candidate_vector_sha256=locked.selected_vector_sha256,
            adapter_configuration_sha256=adapter.configuration_sha256,
            fixed_selection=locked.fixed_selection,
            conventional_selection=locked.conventional_selection,
            non_ash_selection=locked.non_ash_selection,
            p00_identity=native_factory.p00_builder.executable.identity,
            full_ash_development_candidates_frozen_sha256=(
                locked.full_ash_development_candidates_frozen_sha256
            ),
        )
    except ProductionEvaluatorError as error:
        raise P07ProductionError("P07 selected-control bundle differs") from error


def _selected_aliases(locked: P07LockedReleaseInputs) -> Mapping[str, str]:
    fixed = _selection_document(locked.fixed_selection, "fixed")
    conventional = _selection_document(
        locked.conventional_selection,
        "conventional",
    )
    descriptor = fixed.get("chosen_descriptor_id")
    algorithm = conventional.get("chosen_algorithm_id")
    if (
        not isinstance(descriptor, int)
        or descriptor not in range(16)
        or algorithm not in CONVENTIONAL_KEY_BY_ID
    ):
        raise P07ProductionError("selected fixed/conventional aliases differ")
    aliases = {
        "best_fixed": "fixed_descriptor_{:02d}".format(descriptor),
        "conventional": CONVENTIONAL_KEY_BY_ID[str(algorithm)],
    }
    identities = locked.selection.get("selected_controls")
    if (
        not isinstance(identities, dict)
        or identities.get("best_fixed", {}).get("descriptor_id") != descriptor
        or identities.get("conventional", {}).get("algorithm_id") != algorithm
    ):
        raise P07ProductionError("selected aliases differ from release identities")
    return aliases


def _configuration_hashes(
    *,
    adapter: CandidateAdapter,
    bundle: ControlSelectionBundle,
    aliases: Mapping[str, str],
) -> Mapping[str, str]:
    bank = bundle.shared_bank_configuration_sha256
    values: MutableMapping[str, str] = {}
    for descriptor in range(16):
        key = "fixed_descriptor_{:02d}".format(descriptor)
        values[key] = str(fixed_control_request(descriptor, bank)["configuration_sha256"])
    for algorithm, key in CONVENTIONAL_KEY_BY_ID.items():
        values[key] = str(
            conventional_control_request(algorithm, bank)["configuration_sha256"]
        )
    for key in (
        "nearest_same_writer",
        "current_production_ash",
        "non_ash_selector",
        "state_only",
        "full_ash",
        "h07_direct_3_over_2",
    ):
        values[key] = str(bundle.request(key)["configuration_sha256"])
    values["best_fixed"] = values[aliases["best_fixed"]]
    values["conventional"] = values[aliases["conventional"]]
    values["state_plus_branch"] = values["full_ash"]
    ordered = {key: values[key] for key in CONTROL_ORDER}
    if (
        ordered["full_ash"] != adapter.configuration_sha256
        or tuple(ordered) != CONTROL_ORDER
    ):
        raise P07ProductionError("P07 control configuration identities differ")
    return ordered


def _p00_continuity_evidence(
    *,
    locked: P07LockedReleaseInputs,
    native_factory: NativeCandidateAdapterFactory,
) -> Mapping[str, object]:
    identity = dict(native_factory.p00_builder.executable.identity)
    selected_identity = locked.selection.get("selected_controls", {}).get(
        "current_production_ash"
    )
    if (
        not isinstance(selected_identity, dict)
        or selected_identity.get("configuration_sha256")
        != canonical_sha256(identity)
    ):
        raise P07ProductionError("P00 selected comparison identity differs")
    expected_parameters = {
        "control_id": "p00-current-production-ash-baseline-v1",
        **identity,
        "p00_backend_reset_before_frame": True,
        "p00_prior_frame_count": 0,
    }
    invocations = locked.selected_evaluation.get("control_runtime_invocations")
    if not isinstance(invocations, list):
        raise P07ProductionError("P06 control invocation evidence is absent")
    p00_requests = [
        row.get("request")
        for row in invocations
        if isinstance(row, dict)
        and isinstance(row.get("request"), dict)
        and row["request"].get("control_mode") == "p00_current_production_ash"
    ]
    if not p00_requests or any(
        request.get("parameters") != expected_parameters
        or request.get("configuration_sha256") != canonical_sha256(identity)
        for request in p00_requests
        if isinstance(request, dict)
    ):
        raise P07ProductionError("P00 P06 runtime identity differs")

    source_path = native_factory.p00_builder.executable.source_manifest_path
    source_payload, source_manifest = _read_json(source_path, "P00 source manifest")
    executable_payload = _read_regular_file(
        native_factory.p00_builder.executable.path,
        "P00 executable",
    )
    adapter = source_manifest.get("adapter_source")
    sources = source_manifest.get("commit_sources")
    commit_tree = source_manifest.get("commit_tree_sha1")
    if (
        _sha256(source_payload) != identity.get("source_manifest_sha256")
        or _sha256(executable_payload) != identity.get("executable_sha256")
        or source_manifest.get("commit") != identity.get("commit")
        or not isinstance(commit_tree, str)
        or len(commit_tree) != 40
        or any(character not in "0123456789abcdef" for character in commit_tree)
    ):
        raise P07ProductionError("P00 rebuilt source/executable identity differs")
    if (
        not isinstance(adapter, dict)
        or not _is_sha256(adapter.get("sha256"))
        or not isinstance(sources, list)
        or not sources
        or any(
            not isinstance(row, dict)
            or not _is_sha256(row.get("sha256"))
            for row in sources
        )
    ):
        raise P07ProductionError("P00 source-tree/adapter evidence is incomplete")
    return {
        "schema_version": "1.0.0",
        "artifact_kind": "p07_p00_continuity_evidence",
        "status": "pass",
        "selected_p06_configuration_sha256": canonical_sha256(identity),
        "commit": identity["commit"],
        "commit_tree_sha1": source_manifest["commit_tree_sha1"],
        "backend_source_sha256": identity["backend_source_sha256"],
        "source_manifest_sha256": identity["source_manifest_sha256"],
        "adapter_source_sha256": adapter["sha256"],
        "executable_sha256": identity["executable_sha256"],
        "configuration_sha256": identity["configuration_sha256"],
        "compatibility_boundary_normalization": identity[
            "compatibility_boundary_normalization"
        ],
        "selected_p06_runtime_invocation_count": len(p00_requests),
        "holdout_accessed": False,
    }


def _tree_snapshot(root: Path) -> Mapping[str, object]:
    guard = _RetainedCacheDirectory.open(root, protected_roots=())
    try:
        return guard.freeze()
    finally:
        guard.close()


@dataclass(frozen=True)
class _EvaluatedControlCase:
    output_sha256_by_control: Mapping[str, object]
    writer_evidence_sha256_by_control: Mapping[str, object]
    corpus_metrics_by_domain: Optional[Mapping[str, Mapping[str, object]]]
    analytic_metrics_by_domain: Optional[Mapping[str, Mapping[str, object]]]
    evidence_sha256: str
    case_evidence: Mapping[str, object]
    native_records_by_control: Mapping[str, Mapping[str, object]]
    writer_evidence_by_control: Mapping[str, object]


class _P07NativeCaseEvaluator:
    """Evaluate one target/input pair through every locked control."""

    def __init__(
        self,
        *,
        adapter: CandidateAdapter,
        selection_bundle: ControlSelectionBundle,
        selected_aliases: Mapping[str, str],
        configuration_hashes: Mapping[str, str],
        writer: NativeProductionWriterCapability,
        evidence_store: ContentAddressedEvidenceStore,
        expected_scope_field: str,
        expected_scope_binding: Mapping[str, object],
    ) -> None:
        if expected_scope_field not in {"p07_sample_binding", "p07_analytic_binding"}:
            raise P07ProductionError("P07 native record scope field is invalid")
        self.adapter = adapter
        self.selection_bundle = selection_bundle
        self.selected_aliases = dict(selected_aliases)
        self.configuration_hashes = dict(configuration_hashes)
        self.writer = writer
        self.evidence_store = evidence_store
        self.expected_scope_field = expected_scope_field
        self.expected_scope_binding = dict(expected_scope_binding)

    def _invoke(
        self,
        *,
        request: Mapping[str, object],
        low_resolution: PlanarFrame,
        context: CandidateContext,
    ) -> Tuple[PlanarFrame, Mapping[str, object]]:
        try:
            output, record = _invoke_native_control(
                adapter=self.adapter,
                request=request,
                low_resolution=low_resolution,
                context=context,
            )
        except ProductionEvaluatorError as error:
            raise P07ProductionError("P07 native control failed") from error
        output = _boundary_frame(output, str(request.get("control_key")))
        if record.get(self.expected_scope_field) != self.expected_scope_binding:
            raise P07ProductionError("P07 native record scope binding differs")
        return output, record

    def evaluate(
        self,
        *,
        case_id: str,
        target: PlanarFrame,
        low_resolution: PlanarFrame,
        context: CandidateContext,
        public_identity: Mapping[str, object],
        analytic_definition: Optional[Mapping[str, object]] = None,
        analytic_support: object = None,
    ) -> _EvaluatedControlCase:
        raw: Dict[str, PlanarFrame] = {}
        native_records: Dict[str, Mapping[str, object]] = {}
        bank = self.selection_bundle.shared_bank_configuration_sha256
        for descriptor in range(16):
            key = "fixed_descriptor_{:02d}".format(descriptor)
            raw[key], native_records[key] = self._invoke(
                request=fixed_control_request(descriptor, bank),
                low_resolution=low_resolution,
                context=context,
            )
        for algorithm, key in CONVENTIONAL_KEY_BY_ID.items():
            raw[key], native_records[key] = self._invoke(
                request=conventional_control_request(algorithm, bank),
                low_resolution=low_resolution,
                context=context,
            )
        for key in (
            "nearest_same_writer",
            "current_production_ash",
            "non_ash_selector",
            "state_only",
            "full_ash",
        ):
            raw[key], native_records[key] = self._invoke(
                request=self.selection_bundle.request(key),
                low_resolution=low_resolution,
                context=context,
            )
        if context.target_route == "direct-3over2":
            key = "h07_direct_3_over_2"
            raw[key], native_records[key] = self._invoke(
                request=self.selection_bundle.request(key),
                low_resolution=low_resolution,
                context=context,
            )

        raw["best_fixed"] = raw[self.selected_aliases["best_fixed"]]
        raw["conventional"] = raw[self.selected_aliases["conventional"]]
        raw["state_plus_branch"] = raw["full_ash"]
        ordered_raw: Dict[str, Optional[PlanarFrame]] = {
            key: raw.get(key) for key in CONTROL_ORDER
        }

        decoded_unique: Dict[str, PlanarFrame] = {}
        writer_unique: Dict[str, str] = {}
        alias_keys = {"best_fixed", "conventional", "state_plus_branch"}
        for key in CONTROL_ORDER:
            frame = ordered_raw[key]
            if frame is None or key in alias_keys:
                continue
            result = self.writer.round_trip(
                control_key="p07:{}:{}".format(case_id, key),
                frame=frame,
                context=context,
            )
            try:
                decoded_unique[key] = _validate_writer_round_trip(
                    writer=self.writer,
                    result=result,
                    control_key="p07:{}:{}".format(case_id, key),
                    raw_frame=frame,
                    context=context,
                )
            except ProductionEvaluatorError as error:
                raise P07ProductionError("P07 writer evidence differs") from error
            writer_unique[key] = result.evidence_sha256
        decoded: Dict[str, Optional[PlanarFrame]] = {
            key: decoded_unique.get(key) for key in CONTROL_ORDER
        }
        writer_hashes: Dict[str, object] = {
            key: writer_unique.get(key) for key in CONTROL_ORDER
        }
        for alias, source in (
            ("best_fixed", self.selected_aliases["best_fixed"]),
            ("conventional", self.selected_aliases["conventional"]),
            ("state_plus_branch", "full_ash"),
        ):
            decoded[alias] = decoded[source]
            writer_hashes[alias] = writer_hashes[source]

        raw_hashes = {
            key: (None if value is None else frame_sha256(value))
            for key, value in ordered_raw.items()
        }
        decoded_hashes = {
            key: (None if value is None else frame_sha256(value))
            for key, value in decoded.items()
        }
        corpus_metrics: Optional[Mapping[str, Mapping[str, object]]] = None
        analytic_metrics: Optional[Mapping[str, Mapping[str, object]]] = None
        if analytic_definition is None:
            raw_metrics: Dict[str, object] = {}
            decoded_metrics: Dict[str, object] = {}
            for key in CONTROL_ORDER:
                raw_frame = ordered_raw[key]
                decoded_frame = decoded[key]
                if raw_frame is None or decoded_frame is None:
                    raw_metrics[key] = None
                    decoded_metrics[key] = None
                    continue
                raw_bundle = _corpus_metrics(
                    target,
                    raw_frame,
                    writer_y_psnr_contribution_db=None,
                )
                decoded_psnr = channel_psnr(target, decoded_frame)["Y"]
                raw_psnr = raw_bundle["y_psnr_db"]
                if (
                    decoded_psnr.get("exact_match") is not False
                    or decoded_psnr.get("value") is None
                    or not isinstance(raw_psnr, dict)
                    or raw_psnr.get("value") is None
                ):
                    raise P07ProductionError(
                        "P07 decoded corpus Y PSNR is exact; no cap is permitted"
                    )
                contribution = float(decoded_psnr["value"]) - float(raw_psnr["value"])
                raw_metrics[key] = raw_bundle
                decoded_metrics[key] = _corpus_metrics(
                    target,
                    decoded_frame,
                    writer_y_psnr_contribution_db=contribution,
                )
            corpus_metrics = {
                "engine_raw": raw_metrics,
                "container_decoded": decoded_metrics,
            }
        else:
            analytic_metrics = {
                domain: {
                    key: (
                        None
                        if frame is None
                        else dict(_analytic_metric_bundle(
                            analytic_definition,
                            target,
                            frame,
                            analytic_support,
                        ))
                    )
                    for key, frame in frames.items()
                }
                for domain, frames in (
                    ("engine_raw", ordered_raw),
                    ("container_decoded", decoded),
                )
            }

        evidence = {
            "schema_version": "1.0.0",
            "artifact_kind": "p07_native_case_evidence",
            "case_id": case_id,
            **dict(public_identity),
            "adapter_configuration_sha256": self.adapter.configuration_sha256,
            "control_configuration_sha256_by_control": self.configuration_hashes,
            "engine_raw_output_sha256_by_control": raw_hashes,
            "container_decoded_output_sha256_by_control": decoded_hashes,
            "writer_evidence_sha256_by_control": writer_hashes,
            "native_record_sha256_by_control": {
                key: record.get("record_sha256")
                for key, record in native_records.items()
            },
            self.expected_scope_field: self.expected_scope_binding,
        }
        binding = self.evidence_store.publish(evidence)
        if self.evidence_store.reopen(str(binding["sha256"])) != evidence:
            raise P07ProductionError("P07 case evidence failed content-address reopen")
        return _EvaluatedControlCase(
            output_sha256_by_control={
                "engine_raw": raw_hashes,
                "container_decoded": decoded_hashes,
            },
            writer_evidence_sha256_by_control=writer_hashes,
            corpus_metrics_by_domain=corpus_metrics,
            analytic_metrics_by_domain=analytic_metrics,
            evidence_sha256=str(binding["sha256"]),
            case_evidence=evidence,
            native_records_by_control={
                key: dict(record) for key, record in native_records.items()
            },
            writer_evidence_by_control={
                key: (
                    None
                    if digest is None
                    else dict(self.writer.reopen_evidence(str(digest)))
                )
                for key, digest in writer_hashes.items()
            },
        )


def _profile_matrix(
    degradation_policy: Mapping[str, object],
) -> Tuple[Mapping[str, object], ...]:
    profiles = degradation_policy.get("profiles")
    if not isinstance(profiles, list):
        raise P07ProductionError("locked degradation profiles are absent")
    result = []
    for route in ROUTE_ORDER:
        for kind in DEGRADATION_KIND_ORDER:
            matches = [
                row for row in profiles
                if isinstance(row, dict)
                and row.get("target_route") == route
                and row.get("kind") == kind
            ]
            if len(matches) != 1:
                raise P07ProductionError(
                    "route-specific degradation profile is not singular"
                )
            result.append(dict(matches[0]))
    return tuple(result)


def _locked_profile_rows(
    profiles: Sequence[Mapping[str, object]],
) -> Sequence[Mapping[str, object]]:
    return tuple(
        {
            "target_route": row["target_route"],
            "kind": row["kind"],
            "profile_id": row["id"],
            "profile_sha256": canonical_sha256(row),
        }
        for row in profiles
    )


def _locked_fixture_rows(
    manifest: Mapping[str, object],
) -> Sequence[Mapping[str, object]]:
    fixtures = manifest.get("fixtures")
    if not isinstance(fixtures, list) or len(fixtures) != 14:
        raise P07ProductionError("locked analytic fixture count differs")
    return tuple(
        {
            "fixture_id": definition["fixture_id"],
            "fixture_kind": definition["fixture_kind"],
            "target_route": definition["target_route"],
            "fixture_definition_sha256": canonical_sha256(definition),
        }
        for definition in fixtures
        if isinstance(definition, dict)
    )


def _runtime_case_record(
    result: _EvaluatedControlCase,
) -> Mapping[str, object]:
    record = {
        "case_evidence_sha256": result.evidence_sha256,
        "case_evidence": dict(result.case_evidence),
        "native_records_by_control": {
            key: dict(value)
            for key, value in result.native_records_by_control.items()
        },
        "writer_evidence_by_control": {
            key: (None if value is None else dict(value))
            for key, value in result.writer_evidence_by_control.items()
        },
    }
    _validate_runtime_case_closure(record)
    return record


def _corpus_media_context(
    source: Mapping[str, object],
    case_id: str,
) -> P07MediaContext:
    asset_id = source.get("asset_id")
    ordinal = source.get("sampling_ordinal")
    timestamp = source.get("selected_presentation_time")
    if (
        not isinstance(asset_id, str)
        or not asset_id
        or not isinstance(ordinal, int)
        or isinstance(ordinal, bool)
        or ordinal < 0
        or not isinstance(timestamp, dict)
    ):
        raise P07ProductionError("P07 corpus media identity is incomplete")
    return P07MediaContext(
        asset_id=asset_id,
        case_id=case_id,
        presentation_timestamp=dict(timestamp),
    )


def _validate_runtime_case_closure(record: Mapping[str, object]) -> None:
    if set(record) != {
        "case_evidence_sha256",
        "case_evidence",
        "native_records_by_control",
        "writer_evidence_by_control",
    }:
        raise P07ProductionError("P07 runtime case wrapper field set differs")
    case = record.get("case_evidence")
    native = record.get("native_records_by_control")
    writer = record.get("writer_evidence_by_control")
    if (
        not isinstance(case, dict)
        or not isinstance(native, dict)
        or not isinstance(writer, dict)
        or record.get("case_evidence_sha256") != canonical_sha256(case)
        or case.get("artifact_kind") != "p07_native_case_evidence"
        or tuple(writer) != CONTROL_ORDER
    ):
        raise P07ProductionError("P07 runtime case content address differs")
    raw_hashes = case.get("engine_raw_output_sha256_by_control")
    decoded_hashes = case.get("container_decoded_output_sha256_by_control")
    writer_hashes = case.get("writer_evidence_sha256_by_control")
    native_hashes = case.get("native_record_sha256_by_control")
    if not all(
        isinstance(value, dict)
        for value in (raw_hashes, decoded_hashes, writer_hashes, native_hashes)
    ):
        raise P07ProductionError("P07 runtime case hash maps are absent")
    if (
        tuple(raw_hashes) != CONTROL_ORDER
        or tuple(decoded_hashes) != CONTROL_ORDER
        or tuple(writer_hashes) != CONTROL_ORDER
        or set(native_hashes) != set(native)
    ):
        raise P07ProductionError("P07 runtime case control coverage differs")
    for control, native_record in native.items():
        if (
            not isinstance(native_record, dict)
            or native_record.get("record_sha256")
            != canonical_sha256(
                {
                    key: value
                    for key, value in native_record.items()
                    if key != "record_sha256"
                }
            )
            or native_hashes.get(control) != native_record.get("record_sha256")
            or raw_hashes.get(control) != native_record.get("output_frame_sha256")
        ):
            raise P07ProductionError("P07 native runtime record binding differs")
    for control in CONTROL_ORDER:
        document = writer[control]
        digest = writer_hashes[control]
        if document is None:
            if digest is not None or decoded_hashes[control] is not None:
                raise P07ProductionError("P07 absent writer evidence is inconsistent")
            continue
        if (
            not isinstance(document, dict)
            or digest != canonical_sha256(document)
            or document.get("input_frame_sha256") != raw_hashes[control]
            or document.get("decoded_frame_sha256") != decoded_hashes[control]
            or document.get("reopened_and_verified") is not True
        ):
            raise P07ProductionError("P07 writer runtime evidence binding differs")
    aliases = (
        ("state_plus_branch", "full_ash"),
    )
    for alias, source in aliases:
        if (
            raw_hashes[alias] != raw_hashes[source]
            or decoded_hashes[alias] != decoded_hashes[source]
            or writer_hashes[alias] != writer_hashes[source]
            or writer[alias] != writer[source]
        ):
            raise P07ProductionError("P07 runtime state/branch alias differs")


def _validate_loader_verification(
    loader: Mapping[str, object],
    *,
    expected_executable_sha256: str,
) -> Mapping[str, object]:
    if set(loader) != {
        "build", "reproducibility_build", "builds_byte_identical",
        "self_tests", "self_tests_byte_identical",
    }:
        raise P07ProductionError("P07 loader verification field set differs")
    build = loader.get("build")
    reproducibility_build = loader.get("reproducibility_build")
    tests = loader.get("self_tests")
    if (
        not isinstance(build, dict)
        or reproducibility_build != build
        or loader.get("builds_byte_identical") is not True
        or build.get("manifest_sha256") != canonical_sha256(
            {key: value for key, value in build.items() if key != "manifest_sha256"}
        )
        or build.get("executable_sha256") != expected_executable_sha256
        or not isinstance(build.get("mach_o_uuid"), str)
        or len(str(build.get("mach_o_uuid"))) != 32
        or build.get("mach_o_uuid_contract")
        != "sha256_first_128_bits_after_zeroing_lc_uuid_rfc4122_v3_variant"
        or build.get("code_signing")
        != "deterministic_ad_hoc_fixed_identifier_no_timestamp"
        or build.get("code_signing_identifier")
        != "local.mirmir.p07-holdout-frame-loader"
        or not isinstance(tests, list)
        or len(tests) != 2
        or tests[0] != tests[1]
        or loader.get("self_tests_byte_identical") is not True
    ):
        raise P07ProductionError("P07 loader build/self-test binding differs")
    for document in tests:
        if (
            not isinstance(document, dict)
            or document.get("manifest_sha256") != canonical_sha256(
                {
                    key: value
                    for key, value in document.items()
                    if key != "manifest_sha256"
                }
            )
            or document.get("artifact_kind")
            != "p07_holdout_frame_loader_self_test"
            or document.get("status") != "pass"
            or document.get("repeat_byte_identical") is not True
            or document.get("presentation_order_monotonicity_checked") is not True
            or document.get("midpoint_tie_selects_first") is not True
            or document.get("descending_presentation_time_rejected") is not True
            or document.get("holdout_accessed") is not False
        ):
            raise P07ProductionError("P07 loader self-test evidence differs")
    return _json_copy(loader)


class P07ProductionEvaluator:
    """Prepared pre-open analytics plus a one-use holdout evaluator callback."""

    def __init__(
        self,
        *,
        locked: P07LockedReleaseInputs,
        native_factory: NativeCandidateAdapterFactory,
        native_configuration: NativeConfiguration,
        release_lut_recompile: Mapping[str, object],
        p07_cache_root: Path,
        cache_guard: _RetainedCacheDirectory,
        preopen_cache_snapshot: Mapping[str, object],
        selected_aliases: Mapping[str, str],
        configuration_hashes: Mapping[str, str],
        analytic_rows: Sequence[Mapping[str, object]],
        analytic_runtime_cases: Sequence[Mapping[str, object]],
        analytic_comparison: Mapping[str, object],
        p00_continuity: Mapping[str, object],
        loader_verification: Mapping[str, object],
        writer_inputs: _RetainedInputSet,
        writer_execution: ProductionWriterAuthorizedExecution,
        writer_settings_source_sha256: str,
        expected_writer_settings_sha256: str,
        retained_native_runtime: _RetainedNativeRuntime,
    ) -> None:
        self.locked = locked
        self.native_factory = native_factory
        self.native_configuration = native_configuration
        self.release_lut_recompile = _json_copy(release_lut_recompile)
        self.p07_cache_root = p07_cache_root
        self._cache_guard = cache_guard
        self.preopen_cache_snapshot = dict(preopen_cache_snapshot)
        self.selected_aliases = dict(selected_aliases)
        self.configuration_hashes = dict(configuration_hashes)
        self.analytic_rows = tuple(_json_copy(row) for row in analytic_rows)
        self.analytic_runtime_cases = tuple(
            _json_copy(row) for row in analytic_runtime_cases
        )
        self.analytic_comparison = _json_copy(analytic_comparison)
        self.p00_continuity = _json_copy(p00_continuity)
        self.loader_verification = _json_copy(loader_verification)
        self._writer_inputs = writer_inputs
        self._writer_execution = writer_execution
        self._writer_settings_source_sha256 = writer_settings_source_sha256
        self._expected_writer_settings_sha256 = expected_writer_settings_sha256
        self._retained_native_runtime = retained_native_runtime
        self.profiles = _profile_matrix(locked.degradation_policy)
        self._used = False
        self._runtime_guard: Optional[_RetainedCacheDirectory] = None

    @classmethod
    def prepare(
        cls,
        *,
        preflight: P07Preflight,
        release_root: Path,
        calibration_run_support_root: Path,
        production_writer_support_root: Path,
        bound_inputs: object,
        native_factory: NativeCandidateAdapterFactory,
        p07_cache_root: Path,
        loader_verification: Mapping[str, object],
        protected_roots: Sequence[Path],
        expected_cache_root_identity: Tuple[int, int],
    ) -> "P07ProductionEvaluator":
        """Complete all release checks and synthetic analytics before guard."""

        locked = P07LockedReleaseInputs.from_preflight(
            preflight=preflight,
            release_root=release_root,
            bound_inputs=bound_inputs,
            calibration_run_support_root=calibration_run_support_root,
            production_writer_support_root=production_writer_support_root,
        )
        loader = _validate_loader_verification(
            loader_verification,
            expected_executable_sha256=preflight.loader_sha256,
        )
        if not protected_roots:
            raise P07ProductionError("P07 complete protected-root set is absent")
        if (
            not isinstance(expected_cache_root_identity, tuple)
            or len(expected_cache_root_identity) != 2
            or any(
                not isinstance(value, int)
                or isinstance(value, bool)
                or value < 0
                for value in expected_cache_root_identity
            )
        ):
            raise P07ProductionError("P07 expected cache-root identity is invalid")
        cache_guard = _RetainedCacheDirectory.open(
            p07_cache_root,
            protected_roots=tuple(protected_roots)
            + (
                release_root,
                calibration_run_support_root,
                production_writer_support_root,
                native_factory.repository_root,
                preflight.mount_root,
                preflight.mount_root.parent,
                *(path.parent for path in preflight.workflow_paths.values()),
            ),
        )
        if cache_guard.root_identity != expected_cache_root_identity:
            cache_guard.close()
            raise P07ProductionError("P07 cache-root identity differs from CLI pin")
        evidence_store = content_addressed_evidence_store(
            p07_cache_root / "preopen-evidence"
        )
        native_configuration, release_lut_recompile = (
            _build_release_native_configuration(
                locked=locked,
                native_factory=native_factory,
                cache_guard=cache_guard,
                evidence_store=evidence_store,
            )
        )
        retained_native_runtime = _retain_native_runtime(
            locked=locked,
            native_factory=native_factory,
            native_configuration=native_configuration,
        )
        authorized_environment = authorized_process_environment(
            Path("/private/tmp")
        )
        native_authorizer = lambda pid: authorize_running_code(
            pid,
            locked.macos_code_identities["production_swift_executable"],
        )
        p00_authorizer = lambda pid: authorize_running_code(
            pid,
            locked.macos_code_identities["p00_native_executable"],
        )
        p00_continuity = _p00_continuity_evidence(
            locked=locked,
            native_factory=native_factory,
        )
        evidence_store.publish(p00_continuity)
        (
            writer_inputs,
            writer_execution,
            writer_settings_source_sha256,
            expected_writer_settings_sha256,
        ) = _retained_writer_execution(locked)
        analytic_adapter = _make_release_adapter(
            locked=locked,
            native_factory=native_factory,
            native_configuration=retained_native_runtime.native_configuration,
            split="p07_holdout_analytic",
            artifact_root=p07_cache_root / "preopen-native-analytic",
            analytic_fixture_manifest_sha256=str(
                locked.analytic_fixture_manifest["manifest_sha256"]
            ),
            cache_guard=cache_guard,
            retained_native_executable=(
                retained_native_runtime.native_executable
            ),
            native_retained_fds=(
                retained_native_runtime.native_inputs.pass_fds
            ),
            p00_retained_fds=(
                retained_native_runtime.p00_inputs.pass_fds
            ),
            native_execution_authorizer=native_authorizer,
            p00_execution_authorizer=p00_authorizer,
            authorized_environment=authorized_environment,
        )
        with _adapter_lifetime(analytic_adapter):
            writer = _locked_writer_capability(
                evidence_root=p07_cache_root / "preopen-analytic-writer",
                locked=locked,
                execution=writer_execution,
                settings_source_sha256=writer_settings_source_sha256,
                expected_settings_sha256=expected_writer_settings_sha256,
            )
            bundle = _selection_bundle(
                locked=locked,
                native_factory=native_factory,
                adapter=analytic_adapter,
            )
            aliases = _selected_aliases(locked)
            configuration_hashes = _configuration_hashes(
                adapter=analytic_adapter,
                bundle=bundle,
                aliases=aliases,
            )
            analytic_binding = {
                "analytic_fixture_manifest_sha256": str(
                    locked.analytic_fixture_manifest["manifest_sha256"]
                ),
                "p06_release_bundle_manifest_sha256": (
                    locked.release_bundle_manifest_sha256
                ),
                "adapter_configuration_sha256": (
                    analytic_adapter.configuration_sha256
                ),
            }
            evaluator = _P07NativeCaseEvaluator(
                adapter=analytic_adapter,
                selection_bundle=bundle,
                selected_aliases=aliases,
                configuration_hashes=configuration_hashes,
                writer=writer,
                evidence_store=evidence_store,
                expected_scope_field="p07_analytic_binding",
                expected_scope_binding=analytic_binding,
            )
            analytic_rows, analytic_cases = cls._precompute_analytics(
                locked=locked,
                evaluator=evaluator,
            )
        analytic_comparison = cls._compare_p06_analytics(
            locked=locked,
            analytic_rows=analytic_rows,
        )
        evidence_store.publish(analytic_comparison)
        snapshot = cache_guard.freeze()
        return cls(
            locked=locked,
            native_factory=native_factory,
            native_configuration=retained_native_runtime.native_configuration,
            release_lut_recompile=release_lut_recompile,
            p07_cache_root=p07_cache_root,
            cache_guard=cache_guard,
            preopen_cache_snapshot=snapshot,
            selected_aliases=aliases,
            configuration_hashes=configuration_hashes,
            analytic_rows=analytic_rows,
            analytic_runtime_cases=analytic_cases,
            analytic_comparison=analytic_comparison,
            p00_continuity=p00_continuity,
            loader_verification=loader,
            writer_inputs=writer_inputs,
            writer_execution=writer_execution,
            writer_settings_source_sha256=writer_settings_source_sha256,
            expected_writer_settings_sha256=expected_writer_settings_sha256,
            retained_native_runtime=retained_native_runtime,
        )

    @staticmethod
    def _precompute_analytics(
        *,
        locked: P07LockedReleaseInputs,
        evaluator: _P07NativeCaseEvaluator,
    ) -> Tuple[Sequence[Mapping[str, object]], Sequence[Mapping[str, object]]]:
        fixtures = locked.analytic_fixture_manifest.get("fixtures")
        profiles = {
            str(row["id"]): row
            for row in locked.degradation_policy.get("profiles", [])
            if isinstance(row, dict) and isinstance(row.get("id"), str)
        }
        if not isinstance(fixtures, list) or len(fixtures) != 14:
            raise P07ProductionError("locked analytic fixture matrix differs")
        per_domain: Dict[str, list[Mapping[str, object]]] = {
            domain: [] for domain in DOMAINS
        }
        runtime_cases = []
        for definition in fixtures:
            if not isinstance(definition, dict):
                raise P07ProductionError("analytic fixture definition is invalid")
            target, support = _analytic_reference(definition)
            profile = profiles.get(str(definition.get("degradation_profile_id")))
            if not isinstance(profile, dict):
                raise P07ProductionError("analytic degradation profile is absent")
            pre_boundary = apply_degradation(target, profile)
            if frame_sha256(pre_boundary) != definition.get("low_resolution_frame_sha256"):
                raise P07ProductionError("analytic low-resolution fixture hash changed")
            _, low_resolution = _round_trip_locked_bt709_video_range_nv12(
                pre_boundary
            )
            geometry = definition.get("target_geometry")
            if not isinstance(geometry, dict):
                raise P07ProductionError("analytic target geometry is absent")
            context = CandidateContext(
                y_shape=tuple(int(value) for value in geometry["y"]),
                cb_shape=tuple(int(value) for value in geometry["cb"]),
                cr_shape=tuple(int(value) for value in geometry["cr"]),
                target_route=str(definition["target_route"]),
            )
            fixture_binding = {
                "fixture_id": definition["fixture_id"],
                "fixture_kind": definition["fixture_kind"],
                "fixture_definition_sha256": canonical_sha256(definition),
                "target_route": definition["target_route"],
            }
            result = evaluator.evaluate(
                case_id="analytic:{}".format(definition["fixture_id"]),
                target=target,
                low_resolution=_freeze_frame(low_resolution),
                context=context,
                public_identity=fixture_binding,
                analytic_definition=definition,
                analytic_support=support,
            )
            if result.analytic_metrics_by_domain is None:
                raise P07ProductionError("analytic result omits metric evidence")
            for domain in DOMAINS:
                per_domain[domain].append(
                    {
                        **fixture_binding,
                        "comparison_domain": domain,
                        "configuration_sha256_by_control": dict(
                            evaluator.configuration_hashes
                        ),
                        "output_sha256_by_control": dict(
                            result.output_sha256_by_control[domain]
                        ),
                        "writer_evidence_sha256_by_control": (
                            {key: None for key in CONTROL_ORDER}
                            if domain == "engine_raw"
                            else dict(result.writer_evidence_sha256_by_control)
                        ),
                        "metrics_by_control": dict(
                            result.analytic_metrics_by_domain[domain]
                        ),
                    }
                )
            runtime_cases.append(_runtime_case_record(result))
        rows = tuple(per_domain["engine_raw"] + per_domain["container_decoded"])
        return rows, tuple(runtime_cases)

    @staticmethod
    def _compare_p06_analytics(
        *,
        locked: P07LockedReleaseInputs,
        analytic_rows: Sequence[Mapping[str, object]],
    ) -> Mapping[str, object]:
        p06_rows = locked.selected_evaluation.get("analytic_fixture_results")
        if not isinstance(p06_rows, list) or len(p06_rows) != 28:
            raise P07ProductionError("P06 selected analytic evidence is incomplete")
        selected_controls = (
            "full_ash", "best_fixed", "conventional", "non_ash_selector",
            "state_only", "state_plus_branch", "h07_direct_3_over_2",
            "nearest_same_writer", "current_production_ash",
        )
        comparisons = []
        for reproduced, previous in zip(analytic_rows, p06_rows):
            if not isinstance(previous, dict):
                raise P07ProductionError("P06 analytic row is invalid")
            for field in (
                "fixture_id", "fixture_kind", "fixture_definition_sha256",
                "target_route", "comparison_domain",
            ):
                if reproduced.get(field) != previous.get(field):
                    raise P07ProductionError("P06/P07 analytic fixture order differs")
            previous_outputs = previous.get("control_output_sha256_values")
            previous_metrics = previous.get("metrics_by_control")
            if not isinstance(previous_outputs, dict) or not isinstance(previous_metrics, dict):
                raise P07ProductionError("P06 analytic output/metric evidence is absent")
            for control in selected_controls:
                if (
                    reproduced["output_sha256_by_control"][control]
                    != previous_outputs.get(control)
                    or reproduced["metrics_by_control"][control]
                    != previous_metrics.get(control)
                ):
                    raise P07ProductionError(
                        "release-runtime analytic semantics differ from selected P06"
                    )
            comparisons.append(
                canonical_sha256(
                    {
                        "fixture_id": reproduced["fixture_id"],
                        "comparison_domain": reproduced["comparison_domain"],
                        "selected_control_outputs": {
                            control: reproduced["output_sha256_by_control"][control]
                            for control in selected_controls
                        },
                        "selected_control_metrics": {
                            control: reproduced["metrics_by_control"][control]
                            for control in selected_controls
                        },
                    }
                )
            )
        return {
            "schema_version": "1.0.0",
            "artifact_kind": "p07_preopen_analytic_p06_comparison",
            "status": "pass",
            "reproduction_mode": "independently_reproduced_exhaustive_controls",
            "fixture_row_count": 28,
            "selected_control_count": len(selected_controls),
            "ordered_comparison_sha256_values": comparisons,
            "raw_and_decoded_outputs_and_metrics_identical": True,
            "holdout_accessed": False,
        }

    def _source_bindings(
        self,
        extraction: Mapping[str, object],
    ) -> Sequence[Mapping[str, object]]:
        plan_assets = self.locked.sampling_plan.get("assets")
        extracted_assets = extraction.get("assets")
        corpus_assets = self.locked.corpus_lock.get("assets")
        if not all(
            isinstance(value, list)
            for value in (plan_assets, extracted_assets, corpus_assets)
        ):
            raise P07ProductionError("P07 source-binding documents are incomplete")
        holdout_by_source = {
            str(row["source_asset_id"]): row
            for row in corpus_assets
            if isinstance(row, dict) and row.get("split") == "holdout"
        }
        result = []
        for plan, extracted in zip(plan_assets, extracted_assets):
            if not isinstance(plan, dict) or not isinstance(extracted, dict):
                raise P07ProductionError("P07 source-binding row is invalid")
            source = holdout_by_source.get(str(plan.get("source_asset_id")))
            if source is None:
                raise P07ProductionError("P07 extraction substitutes a source asset")
            selected_time = extracted.get("selected_presentation_time")
            if (
                extracted.get("ordinal") != plan.get("ordinal")
                or extracted.get("asset_id") != plan.get("asset_id")
                or extracted.get("source_asset_id") != plan.get("source_asset_id")
                or extracted.get("source_family_id") != plan.get("source_family_id")
                or extracted.get("target_route") != plan.get("target_route")
                or extracted.get("crop") != plan.get("crop")
                or extracted.get("crop_nv12_size_bytes") != 93_312
                or source.get("source_family_id") != plan.get("source_family_id")
                or source.get("target_routes") != [plan.get("target_route")]
                or not isinstance(selected_time, dict)
                or set(selected_time) != {"value", "timescale"}
                or not isinstance(selected_time.get("value"), int)
                or isinstance(selected_time.get("value"), bool)
                or int(selected_time["value"]) < 0
                or not isinstance(selected_time.get("timescale"), int)
                or isinstance(selected_time.get("timescale"), bool)
                or int(selected_time["timescale"]) <= 0
            ):
                raise P07ProductionError("P07 source/extraction/route binding differs")
            categories = source.get("categories")
            if (
                not isinstance(categories, list)
                or not categories
                or len(categories) != len(set(categories))
            ):
                raise P07ProductionError("P07 source categories are invalid")
            result.append(
                {
                    "asset_id": plan["asset_id"],
                    "sampling_ordinal": plan["ordinal"],
                    "source_asset_id": plan["source_asset_id"],
                    "source_family_id": plan["source_family_id"],
                    "categories": list(categories),
                    "target_route": plan["target_route"],
                    "crop_nv12_filename": extracted["crop_nv12_filename"],
                    "crop_nv12_sha256": extracted["crop_nv12_sha256"],
                    "crop_nv12_size_bytes": extracted["crop_nv12_size_bytes"],
                    "selected_presentation_time": dict(
                        selected_time
                    ),
                }
            )
        if len(result) != 3:
            raise P07ProductionError("P07 source-binding count differs")
        return tuple(result)

    def _locked_performance(self) -> Mapping[str, object]:
        performance = self.locked.selected_evaluation.get("performance")
        if not isinstance(performance, dict):
            raise P07ProductionError("selected P06 performance evidence is absent")
        full_fps = performance.get(
            "preregistered_production_estimate_frames_per_second"
        )
        control_fps = performance.get(
            "h07_control_estimate_frames_per_second"
        )
        full_cost = performance.get(
            "preregistered_production_estimate_dispatch_cost"
        )
        control_cost = performance.get("h07_control_estimate_dispatch_cost")
        if not all(
            isinstance(value, (int, float))
            and not isinstance(value, bool)
            and math.isfinite(float(value))
            for value in (full_fps, control_fps, full_cost, control_cost)
        ):
            raise P07ProductionError("selected P06 performance values are invalid")
        return {
            "selected_evaluation_sha256": _artifact_binding(
                self.locked.release_bundle,
                "selected_evaluation",
            )["sha256"],
            "full_frames_per_second": full_fps,
            "h07_control_frames_per_second": control_fps,
            "full_dispatch_cost": full_cost,
            "h07_control_dispatch_cost": control_cost,
            "no_worse_frames_per_second": float(full_fps) >= float(control_fps),
            "no_worse_dispatch_cost": float(full_cost) <= float(control_cost),
        }

    @property
    def authorized_execution_binding_fragment(self) -> Mapping[str, object]:
        """Return the canonical no-secret identity fragment for execution evidence."""

        writer_trees = [
            row
            for row in self.locked.evidence_closure.get(
                "support_evidence_trees",
                [],
            )
            if isinstance(row, dict)
            and row.get("id") == "production_writer_tree"
        ]
        if len(writer_trees) != 1:
            raise P07ProductionError(
                "production-writer tree binding is not singular"
            )

        def roles(inputs: _RetainedInputSet) -> Sequence[Mapping[str, object]]:
            inputs.verify()
            return tuple(
                {
                    "role": role,
                    "sha256": value.record["sha256"],
                    "size_bytes": value.record["size_bytes"],
                }
                for role, value in inputs.values.items()
            )

        return _production_authorized_execution_binding_fragment(
            cache_root_identity=self._cache_guard.root_identity,
            macos_code_identities=self.locked.macos_code_identities,
            production_swift_roles=list(
                roles(self._retained_native_runtime.native_inputs)
            ),
            p00_native_roles=list(
                roles(self._retained_native_runtime.p00_inputs)
            ),
            production_writer_roles=list(roles(self._writer_inputs)),
            production_writer_support_tree=writer_trees[0],
            production_writer_settings_sha256=(
                self._expected_writer_settings_sha256
            ),
            product_settings_source_sha256=(
                self._writer_settings_source_sha256
            ),
            production_writer_executable_sha256=str(
                self.locked.macos_code_identities[
                    "production_writer_executable"
                ]["file_sha256"]
            ),
            p06_release_bundle_manifest_sha256=(
                self.locked.release_bundle_manifest_sha256
            ),
        )

    def close(self) -> None:
        errors: list[BaseException] = []
        for attribute in (
            "_runtime_guard",
            "_retained_native_runtime",
            "_writer_inputs",
            "_cache_guard",
        ):
            value = getattr(self, attribute, None)
            if value is None:
                continue
            setattr(self, attribute, None)
            try:
                value.close()
            except BaseException as error:
                errors.append(error)
        if len(errors) == 1:
            raise errors[0]
        if len(errors) > 1:
            combined: BaseException = errors[-1]
            for primary in reversed(errors[:-1]):
                combined = P07DualFailure(primary, combined)
            raise combined

    def __del__(self) -> None:
        self.close()

    def __call__(
        self,
        extraction: Mapping[str, object],
        extraction_directory: Path,
        p07_cache_root: Path,
    ) -> Mapping[str, object]:
        if self._used:
            raise P07ProductionError("P07 production evaluator is one-use")
        self._used = True
        try:
            return self._evaluate_once(
                extraction,
                extraction_directory,
                p07_cache_root,
            )
        finally:
            self.close()

    def _bind_live_adapter(
        self,
        *,
        adapter: CandidateAdapter,
        writer: NativeProductionWriterCapability,
        temporary_evidence: ContentAddressedEvidenceStore,
        extraction: Mapping[str, object],
    ) -> Tuple[_P07NativeCaseEvaluator, Mapping[str, str]]:
        bind_extraction = getattr(
            adapter.callable,
            "bind_p07_frame_extraction",
            None,
        )
        if not callable(bind_extraction):
            raise P07ProductionError("P07 native extraction binder is absent")
        bind_extraction(
            sampling_plan_manifest_sha256=str(
                self.locked.sampling_plan["manifest_sha256"]
            ),
            frame_extraction_manifest_sha256=str(extraction["manifest_sha256"]),
        )
        bundle = _selection_bundle(
            locked=self.locked,
            native_factory=self.native_factory,
            adapter=adapter,
        )
        hashes = _configuration_hashes(
            adapter=adapter,
            bundle=bundle,
            aliases=self.selected_aliases,
        )
        if hashes != self.configuration_hashes:
            raise P07ProductionError("P07 analytic/corpus control identities differ")
        sample_binding = {
            "sampling_plan_manifest_sha256": str(
                self.locked.sampling_plan["manifest_sha256"]
            ),
            "frame_extraction_manifest_sha256": str(extraction["manifest_sha256"]),
        }
        evaluator = _P07NativeCaseEvaluator(
            adapter=adapter,
            selection_bundle=bundle,
            selected_aliases=self.selected_aliases,
            configuration_hashes=hashes,
            writer=writer,
            evidence_store=temporary_evidence,
            expected_scope_field="p07_sample_binding",
            expected_scope_binding=sample_binding,
        )
        return evaluator, hashes

    def _evaluate_once(
        self,
        extraction: Mapping[str, object],
        extraction_directory: Path,
        p07_cache_root: Path,
    ) -> Mapping[str, object]:
        """Evaluate the one opened extraction and return measurement/runtime JSON."""

        self._cache_guard.verify_external_path(p07_cache_root)
        if (
            extraction.get("manifest_sha256") != manifest_sha256(extraction)
            or extraction.get("sampling_plan_manifest_sha256")
            != self.locked.sampling_plan.get("manifest_sha256")
        ):
            raise P07ProductionError("P07 extraction self/sample binding differs")
        before = self._cache_guard.verify_frozen()
        if before != self.preopen_cache_snapshot:
            raise P07ProductionError("P07 preopen cache changed before holdout pixels")
        sources = self._source_bindings(extraction)
        runtime_guard = _RetainedCacheDirectory.open(
            extraction_directory,
            protected_roots=(self.p07_cache_root,),
        )
        self._runtime_guard = runtime_guard
        runtime_root = extraction_directory / ".p07-runtime"
        runtime_guard.ensure_directory(runtime_root)
        runtime_guard.ensure_directory(runtime_root / "evidence")
        runtime_guard.ensure_directory(runtime_root / "writer")
        runtime_guard.ensure_directory(runtime_root / "native")
        temporary_evidence = content_addressed_evidence_store(
            runtime_root / "evidence"
        )
        self._writer_inputs.verify()
        writer = _locked_writer_capability(
            evidence_root=runtime_root / "writer",
            locked=self.locked,
            execution=self._writer_execution,
            settings_source_sha256=self._writer_settings_source_sha256,
            expected_settings_sha256=self._expected_writer_settings_sha256,
        )
        self._retained_native_runtime.verify()
        adapter = _make_release_adapter(
            locked=self.locked,
            native_factory=self.native_factory,
            native_configuration=self.native_configuration,
            split="p07_holdout",
            artifact_root=runtime_root / "native",
            sampling_plan_manifest_sha256=str(
                self.locked.sampling_plan["manifest_sha256"]
            ),
            cache_guard=runtime_guard,
            retained_native_executable=(
                self._retained_native_runtime.native_executable
            ),
            native_retained_fds=(
                self._retained_native_runtime.native_inputs.pass_fds
            ),
            p00_retained_fds=(
                self._retained_native_runtime.p00_inputs.pass_fds
            ),
            native_execution_authorizer=lambda pid: authorize_running_code(
                pid,
                self.locked.macos_code_identities[
                    "production_swift_executable"
                ],
            ),
            p00_execution_authorizer=lambda pid: authorize_running_code(
                pid,
                self.locked.macos_code_identities[
                    "p00_native_executable"
                ],
            ),
            authorized_environment=authorized_process_environment(
                Path("/private/tmp")
            ),
        )
        try:
            evaluator, hashes = self._bind_live_adapter(
                adapter=adapter,
                writer=writer,
                temporary_evidence=temporary_evidence,
                extraction=extraction,
            )
        except BaseException as error:
            _close_adapter_after_failure(adapter, error)
        rows_by_domain: Dict[str, list[Mapping[str, object]]] = {
            domain: [] for domain in DOMAINS
        }
        runtime_cases = []
        with _adapter_lifetime(adapter):
            profiles = {
                (str(row["target_route"]), str(row["kind"])): row
                for row in self.profiles
            }
            for source in sources:
                crop_case_id = "corpus:{}:frame".format(
                    source["source_asset_id"]
                )
                crop_media_context = _corpus_media_context(
                    source,
                    crop_case_id,
                )
                try:
                    crop_path = extraction_directory / str(
                        source["crop_nv12_filename"]
                    )
                    payload = runtime_guard.read_regular(crop_path)
                    if (
                        len(payload) != source["crop_nv12_size_bytes"]
                        or _sha256(payload) != source["crop_nv12_sha256"]
                    ):
                        raise P07ProductionError("P07 temporary crop bytes differ")
                    target = _video_range_nv12_to_planar(
                        payload,
                        width=324,
                        height=192,
                    )
                    context = CandidateContext(
                        y_shape=target.y.shape,
                        cb_shape=target.cb.shape,
                        cr_shape=target.cr.shape,
                        target_route=str(source["target_route"]),
                    )
                except BaseException as error:
                    if isinstance(error, P07ContextualError):
                        raise
                    raise P07ContextualError(
                        "P07 crop read/hash/decode failed in {}".format(
                            crop_case_id
                        ),
                        media_context=crop_media_context,
                    ) from error
                for kind in DEGRADATION_KIND_ORDER:
                    case_id = "corpus:{}:{}".format(
                        source["source_asset_id"],
                        kind,
                    )
                    media_context = _corpus_media_context(source, case_id)
                    try:
                        profile = profiles.get((context.target_route, kind))
                        if not isinstance(profile, dict):
                            raise P07ProductionError("P07 route profile is absent")
                        low_resolution = degradation_native_input(target, profile)
                        public_identity = {
                            "asset_id": source["asset_id"],
                            "sampling_ordinal": source["sampling_ordinal"],
                            "selected_presentation_time": dict(
                                source["selected_presentation_time"]
                            ),
                            "source_asset_id": source["source_asset_id"],
                            "source_family_id": source["source_family_id"],
                            "categories": list(source["categories"]),
                            "target_route": source["target_route"],
                            "degradation_kind": kind,
                            "degradation_profile_id": profile["id"],
                            "degradation_profile_sha256": canonical_sha256(
                                profile
                            ),
                            "source_crop_nv12_sha256": source[
                                "crop_nv12_sha256"
                            ],
                            "degraded_input_frame_sha256": frame_sha256(
                                low_resolution
                            ),
                        }
                        result = evaluator.evaluate(
                            case_id=case_id,
                            target=target,
                            low_resolution=low_resolution,
                            context=context,
                            public_identity=public_identity,
                        )
                        if result.corpus_metrics_by_domain is None:
                            raise P07ProductionError("P07 corpus metrics are absent")
                        for domain in DOMAINS:
                            rows_by_domain[domain].append(
                                {
                                    **public_identity,
                                    "comparison_domain": domain,
                                    "configuration_sha256_by_control": dict(hashes),
                                    "output_sha256_by_control": dict(
                                        result.output_sha256_by_control[domain]
                                    ),
                                    "writer_evidence_sha256_by_control": (
                                        {key: None for key in CONTROL_ORDER}
                                        if domain == "engine_raw"
                                        else dict(
                                            result.writer_evidence_sha256_by_control
                                        )
                                    ),
                                    "metrics_by_control": dict(
                                        result.corpus_metrics_by_domain[domain]
                                    ),
                                }
                            )
                        runtime_cases.append(_runtime_case_record(result))
                    except BaseException as error:
                        if isinstance(error, P07ContextualError):
                            raise
                        raise P07ContextualError(
                            "P07 corpus case failed in {}".format(case_id),
                            media_context=media_context,
                        ) from error
        after = self._cache_guard.verify_frozen()
        if after != before:
            raise P07ProductionError("P07 persistent preopen cache changed during holdout")
        corpus_rows = tuple(
            rows_by_domain["engine_raw"]
            + rows_by_domain["container_decoded"]
        )
        measurement_core = {
            "schema_version": "1.0.0",
            "artifact_kind": "p07_spatial_holdout_measurements",
            "status": "complete",
            "configuration_sha256": self.locked.configuration_sha256,
            "locked_metric_policy_sha256": self.locked.metric_policy[
                "policy_sha256"
            ],
            "sampling_plan_manifest_sha256": self.locked.sampling_plan[
                "manifest_sha256"
            ],
            "frame_extraction_manifest_sha256": extraction["manifest_sha256"],
            "analytic_fixture_manifest_sha256": self.locked.analytic_fixture_manifest[
                "manifest_sha256"
            ],
            "comparison_domains": list(DOMAINS),
            "source_order": [row["source_asset_id"] for row in sources],
            "degradation_kind_order": list(DEGRADATION_KIND_ORDER),
            "locked_degradation_profiles": list(
                _locked_profile_rows(self.profiles)
            ),
            "locked_analytic_fixtures": list(
                _locked_fixture_rows(self.locked.analytic_fixture_manifest)
            ),
            "selected_aliases": dict(self.selected_aliases),
            "control_configuration_sha256_by_control": dict(hashes),
            "locked_p06_performance_evidence": self._locked_performance(),
            "corpus_rows": list(corpus_rows),
            "analytic_fixture_rows": list(self.analytic_rows),
            "holdout_accessed": True,
            "configuration_files_modified_after_holdout": False,
        }
        core_sha256 = canonical_sha256(measurement_core)
        runtime_evidence = {
            "schema_version": "1.0.0",
            "artifact_kind": "p07_runtime_evidence",
            "status": "complete",
            "configuration_sha256": self.locked.configuration_sha256,
            "p06_release_bundle_manifest_sha256": (
                self.locked.release_bundle_manifest_sha256
            ),
            "release_native_executable_sha256": (
                self.locked.release_native_executable.sha256
            ),
            "release_native_source_manifest_sha256": (
                self.locked.release_native_executable.source_manifest_sha256
            ),
            "release_lut_manifest_sha256": self.locked.lut_manifest[
                "manifest_sha256"
            ],
            "release_lut_independent_recompile": self.release_lut_recompile,
            "sampling_plan_manifest_sha256": self.locked.sampling_plan[
                "manifest_sha256"
            ],
            "frame_extraction_manifest_sha256": extraction["manifest_sha256"],
            "measurement_core_sha256": core_sha256,
            "preopen_cache_snapshot_before": before,
            "preopen_cache_snapshot_after": after,
            "preopen_cache_unchanged": True,
            "loader_preopen_verification": self.loader_verification,
            "p00_continuity_evidence": self.p00_continuity,
            "analytic_preopen_evidence": {
                "status": "pass",
                "fixture_count": 14,
                "row_count": 28,
                "evaluated_before_guard": True,
                "reproduction_mode": (
                    "independently_reproduced_exhaustive_controls"
                ),
                "p06_semantic_comparison": self.analytic_comparison,
                "case_evidence": list(self.analytic_runtime_cases),
            },
            "corpus_case_evidence": runtime_cases,
            "persistent_holdout_binary_artifact_count": 0,
            "temporary_binary_artifacts_published": False,
            "holdout_accessed": True,
            "configuration_files_modified_after_holdout": False,
        }
        runtime_evidence["manifest_sha256"] = canonical_sha256(runtime_evidence)
        measurements = {
            **measurement_core,
            "runtime_evidence_manifest_sha256": runtime_evidence[
                "manifest_sha256"
            ],
        }
        measurements["measurement_sha256"] = canonical_sha256(measurements)
        try:
            validate_schema(
                runtime_evidence,
                self.native_factory.repository_root
                / "validation/calibration_v2/schemas/"
                "p07-runtime-evidence-v1.schema.json",
            )
            validate_schema(
                measurements,
                self.native_factory.repository_root
                / "validation/calibration_v2/schemas/"
                "p07-spatial-holdout-measurements-v1.schema.json",
            )
        except ValueError as error:
            raise P07ProductionError("P07 measurement/runtime schema failed") from error
        measurement_binding = temporary_evidence.publish(measurements)
        runtime_binding = temporary_evidence.publish(runtime_evidence)
        if (
            temporary_evidence.reopen(str(measurement_binding["sha256"]))
            != measurements
            or temporary_evidence.reopen(str(runtime_binding["sha256"]))
            != runtime_evidence
        ):
            raise P07ProductionError("P07 final JSON evidence content address differs")
        runtime_guard.freeze()
        return {
            "measurements": measurements,
            "runtime_evidence": runtime_evidence,
        }
