#!/usr/bin/env python3
"""Validate the frozen R10 bounded-calibration start contracts."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import stat
import subprocess
import sys
from typing import Any, Iterable, Mapping, Sequence

_MODULE_ROOT = Path(__file__).resolve().parents[1]
if str(_MODULE_ROOT) not in sys.path:
    sys.path.insert(0, str(_MODULE_ROOT))

try:
    from phase_evidence import (
        EMAIL_PATTERN,
        PRIVATE_EVIDENCE_KEYS,
        PRIVATE_PATH_PATTERN,
        decode_json,
        validate_json_schema_instance,
    )
except ModuleNotFoundError:
    from Scripts.phase_evidence import (
        EMAIL_PATTERN,
        PRIVATE_EVIDENCE_KEYS,
        PRIVATE_PATH_PATTERN,
        decode_json,
        validate_json_schema_instance,
    )

from validation.calibration_v2.r10_optimizer import (
    R10AbsoluteScore,
    R10Candidate,
    R10ConstraintName,
    R10Evaluation,
    R10EvaluationCatalog,
    R10HardConstraint,
    R10OptimizerError,
)


REPOSITORY_ROOT = _MODULE_ROOT
ROADMAP_PATH = Path(
    "docs/roadmaps/Mirmir_Apple_Native_ASH_Roadmap_2026-07-18.json"
)
PREREGISTRATION_PATH = Path(
    "docs/roadmaps/evidence/r10/records/preregistration.json"
)
FIXTURE_CATALOG_PATH = Path(
    "docs/roadmaps/evidence/r10/records/fixtures/fixture-catalog.json"
)
EVALUATION_CATALOG_PATH = Path(
    "docs/roadmaps/evidence/r10/records/fixtures/evaluation-catalog.json"
)
POLICY_CATALOG_PATH = Path(
    "docs/roadmaps/evidence/r10/records/fixtures/policy-catalog.json"
)
PREREGISTRATION_SCHEMA_PATH = Path(
    "docs/roadmaps/evidence/schema/r10-preregistration-v1.json"
)
FIXTURE_CATALOG_SCHEMA_PATH = Path(
    "docs/roadmaps/evidence/schema/r10-fixture-catalog-v1.json"
)
EVALUATION_CATALOG_SCHEMA_PATH = Path(
    "docs/roadmaps/evidence/schema/r10-evaluation-catalog-v1.json"
)
POLICY_CATALOG_SCHEMA_PATH = Path(
    "docs/roadmaps/evidence/schema/r10-policy-catalog-v1.json"
)
RUN_RECEIPT_SCHEMA_PATH = Path(
    "docs/roadmaps/evidence/schema/r10-calibration-run-receipt-v1.json"
)
EXECUTION_RECEIPT_SCHEMA_PATH = Path(
    "docs/roadmaps/evidence/schema/r10-functional-execution-receipt-v1.json"
)
PHASE_ACCEPTANCE_SCHEMA_PATH = Path(
    "docs/roadmaps/evidence/schema/r10-functional-phase-acceptance-v1.json"
)
PHASE_ACCEPTANCE_PATH = Path(
    "docs/roadmaps/evidence/r10/records/functional-phase-acceptance.json"
)
OPTIMIZER_PATH = Path("validation/calibration_v2/r10_optimizer.py")
PERSISTENCE_PATH = Path("validation/calibration_v2/r10_persistence.py")
RUNNER_PATH = Path(
    "validation/calibration_v2/tools/run_r10_fixture_calibration.py"
)

PREREGISTRATION_SIZE_BYTES = 12_703
PREREGISTRATION_RAW_SHA256 = (
    "09e7ad4ace85f59c981653dbcc5842a74a2d131067b11d89680f7c0b93c52d0f"
)
PREREGISTRATION_SEMANTIC_SHA256 = (
    "873a3c8b48c467a48a318755753c2f2fefc6a08cb478b056cc9f58eb1f7c39c0"
)
FIXTURE_CATALOG_SIZE_BYTES = 10_756
FIXTURE_CATALOG_RAW_SHA256 = (
    "e46185da139b6740b2a125323925fa04cd80f2b899f6b406d81e7c388a1372ca"
)
FIXTURE_CATALOG_SEMANTIC_SHA256 = (
    "5705b400dc983271c7b3e858a296968b63204364da6bdf1df85d093829b5e70f"
)
EVALUATION_CATALOG_SIZE_BYTES = 2_394
EVALUATION_CATALOG_RAW_SHA256 = (
    "839a9858892aaaee136103f1b145a79e8a8d14433621159bca6e03c00075ed84"
)
EVALUATION_CATALOG_SEMANTIC_SHA256 = (
    "e68aeaec908a3d3542b2618e4ddb81bf73b11f4821f4b434e704c98e5c83eaa9"
)
EVALUATOR_SEMANTIC_SHA256 = (
    "3950ac85c6db38c44a50dc13525b5fcdd1d7cafc25e131e7596c32848988ae20"
)
POLICY_CATALOG_SIZE_BYTES = 2_542
POLICY_CATALOG_RAW_SHA256 = (
    "2548013d1f2de99fef971e0f2e5109690e66ff05cc6711f6cab27601dc60b73e"
)
POLICY_CATALOG_SEMANTIC_SHA256 = (
    "6e6649c1ace856b66a7c68209fe23d8bf831aab0f4d69dc98743eb5979415612"
)

MAX_CONTRACT_BYTES = 2 * 1024 * 1024
CONSTRAINT_ORDER = (
    "route",
    "plane",
    "temporal",
    "protected_region",
    "resource",
    "safety",
)
CAUSAL_VARIABLE_NAMES = (
    "quality_confidence_weight",
    "minimum_dwell_frames",
    "hysteresis_margin_q16",
)
SCORE_DIMENSION_ORDER = (
    "quality_q16",
    "temporal_stability_q16",
    "protected_region_fidelity_q16",
    "safety_margin_q16",
    "resource_efficiency_q16",
)
EVALUATION_DOCUMENT_DIMENSION_ORDER = SCORE_DIMENSION_ORDER
CANDIDATE_IDS = (
    "fixture-valid-alpha",
    "fixture-valid-beta",
    "fixture-valid-gamma",
    "fixture-reject-route",
    "fixture-reject-plane",
    "fixture-reject-temporal",
    "fixture-reject-protected-region",
    "fixture-reject-resource",
    "fixture-reject-safety",
)
VALID_CANDIDATE_IDS = CANDIDATE_IDS[:3]
CHECK_IDS = (
    "predecessor_bindings_exact",
    "operator_continuation_scope_exact",
    "schemas_and_catalogs_exact",
    "optimizer_and_persistence_bytes_exact",
    "fixture_evaluator_policy_hashes_exact",
    "finite_declared_causal_search_exact",
    "six_independent_constraints_exact",
    "absolute_score_no_comparison_exact",
    "ordering_rejection_ranking_tie_break_exact",
    "checkpoint_resume_identity_exact",
    "failure_cancellation_transaction_exact",
    "content_addressed_publication_exact",
    "frozen_fixture_policy_boundary_exact",
    "observation_and_claim_boundary_truthful",
)
STOP_RULE_IDS = (
    "predecessor_binding_drift",
    "schema_catalog_or_contract_byte_drift",
    "undeclared_or_unbounded_candidate",
    "combined_or_missing_constraint",
    "rejected_candidate_observed_by_evaluator",
    "comparison_field_or_gate_reintroduced",
    "nondeterministic_order_rank_or_tie_break",
    "checkpoint_or_resume_identity_drift",
    "partial_failure_or_cancellation_commit",
    "unsafe_or_non_durable_publication",
    "post_freeze_policy_change",
    "production_or_claim_authority_expansion",
)

R07_ACCEPTANCE_PATH = Path(
    "docs/roadmaps/evidence/r07/records/functional-phase-acceptance.json"
)
R09_ACCEPTANCE_PATH = Path(
    "docs/roadmaps/evidence/r09/records/functional-phase-acceptance.json"
)
PREDECESSOR_BINDINGS: tuple[dict[str, object], ...] = (
    {
        "phase_id": "R07",
        "path": R07_ACCEPTANCE_PATH.as_posix(),
        "size_bytes": 14_303,
        "raw_sha256": (
            "a58896db4a44a4fd4da00c3de53b059066a1531dda9df7a91dc735544117ed6b"
        ),
        "phase_result": "passed",
        "acceptance": "accepted",
        "acceptance_scope": "declared_software_function_only",
        "implementation_commit": "1b46ad469265a6ba837a8449d28b8850889f1d3f",
        "implementation_tree": "09d3a48df01738bb26077aadfd83c08e389a1dc2",
        "accepted_merge_commit": "3fd13e57ec95b1ed98df71f4c83ab165bdfbab6b",
        "accepted_merge_tree": "eb1614dd2a93e1bc4e1911bcf74f41cf372a3304",
    },
    {
        "phase_id": "R09",
        "path": R09_ACCEPTANCE_PATH.as_posix(),
        "size_bytes": 14_823,
        "raw_sha256": (
            "5903cee7dde0050161cf9b08e799d58bcbe5378e1874dbbf205fb5efd1138b14"
        ),
        "phase_result": "passed",
        "acceptance": "accepted",
        "acceptance_scope": "declared_software_function_only",
        "implementation_commit": "3ba7b2b5fdbde3a3f90f011cb548b85d46b2ac8b",
        "implementation_tree": "5f19024af0837d5efd54855bcf0fd705a50eadc9",
        "accepted_merge_commit": "eeabc4224100bc8ed86ae1208189bee508844210",
        "accepted_merge_tree": "ac402f993805cca499d2f688c6186c4684ce8dba",
    },
)
SCHEMA_PATHS = {
    "preregistration": PREREGISTRATION_SCHEMA_PATH,
    "fixture_catalog": FIXTURE_CATALOG_SCHEMA_PATH,
    "evaluation_catalog": EVALUATION_CATALOG_SCHEMA_PATH,
    "policy_catalog": POLICY_CATALOG_SCHEMA_PATH,
    "calibration_run_receipt": RUN_RECEIPT_SCHEMA_PATH,
    "functional_execution_receipt": EXECUTION_RECEIPT_SCHEMA_PATH,
    "functional_phase_acceptance": PHASE_ACCEPTANCE_SCHEMA_PATH,
}
CATALOG_PATHS = {
    "fixture_catalog": FIXTURE_CATALOG_PATH,
    "evaluation_catalog": EVALUATION_CATALOG_PATH,
    "policy_catalog": POLICY_CATALOG_PATH,
}
IMPLEMENTATION_PATHS = {
    "r10_optimizer_contract": OPTIMIZER_PATH,
    "r10_persistence_contract": PERSISTENCE_PATH,
    "r10_fixture_calibration_runner": RUNNER_PATH,
}


class R10ContractError(ValueError):
    """A frozen R10 JSON contract is malformed or semantically inconsistent."""


def _sha256(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def _semantic_sha256(value: object) -> str:
    return _sha256(
        json.dumps(
            value,
            ensure_ascii=False,
            allow_nan=False,
            sort_keys=True,
            separators=(",", ":"),
        ).encode("utf-8")
    )


def _stat_identity(value: os.stat_result) -> tuple[int, ...]:
    return (
        value.st_dev,
        value.st_ino,
        value.st_mode,
        value.st_nlink,
        value.st_size,
        value.st_mtime_ns,
        value.st_ctime_ns,
    )


def _read_regular_nofollow(
    root: Path,
    relative: Path,
    context: str,
    *,
    maximum: int = MAX_CONTRACT_BYTES,
) -> bytes:
    """Read one repository-relative regular file through pinned descriptors."""

    if type(maximum) is not int or isinstance(maximum, bool) or maximum < 1:
        raise R10ContractError(f"{context} read boundary is invalid")
    path_value = relative.as_posix()
    pure_path = PurePosixPath(path_value)
    if (
        pure_path.as_posix() != path_value
        or pure_path.is_absolute()
        or not pure_path.parts
        or any(
            part in {"", ".", ".."} or "/" in part or "\x00" in part
            for part in pure_path.parts
        )
    ):
        raise R10ContractError(f"{context} path is outside the closed boundary")

    directory_flags = (
        os.O_RDONLY
        | os.O_DIRECTORY
        | os.O_NOFOLLOW
        | getattr(os, "O_CLOEXEC", 0)
    )
    file_flags = (
        os.O_RDONLY | os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0)
    )
    descriptors: list[int] = []
    links: list[tuple[int, str, int, os.stat_result]] = []
    try:
        root_named_before = os.stat(root, follow_symlinks=False)
        root_descriptor = os.open(root, directory_flags)
        descriptors.append(root_descriptor)
        root_before = os.fstat(root_descriptor)
        if (
            not stat.S_ISDIR(root_named_before.st_mode)
            or _stat_identity(root_named_before) != _stat_identity(root_before)
        ):
            raise R10ContractError(
                f"{context} must be a regular non-symlink file"
            )

        parent_descriptor = root_descriptor
        for index, name in enumerate(pure_path.parts):
            is_file = index == len(pure_path.parts) - 1
            named_before = os.stat(
                name,
                dir_fd=parent_descriptor,
                follow_symlinks=False,
            )
            if (
                is_file
                and not stat.S_ISREG(named_before.st_mode)
            ) or (
                not is_file
                and not stat.S_ISDIR(named_before.st_mode)
            ):
                raise R10ContractError(
                    f"{context} must be a regular non-symlink file"
                )
            descriptor = os.open(
                name,
                file_flags if is_file else directory_flags,
                dir_fd=parent_descriptor,
            )
            descriptors.append(descriptor)
            descriptor_before = os.fstat(descriptor)
            if _stat_identity(named_before) != _stat_identity(descriptor_before):
                raise R10ContractError(
                    f"{context} changed during bounded no-follow read"
                )
            links.append(
                (parent_descriptor, name, descriptor, descriptor_before)
            )
            parent_descriptor = descriptor

        file_descriptor = descriptors[-1]
        file_before = links[-1][3]
        if (
            not stat.S_ISREG(file_before.st_mode)
            or file_before.st_nlink != 1
            or file_before.st_size < 1
            or file_before.st_size > maximum
        ):
            raise R10ContractError(
                f"{context} bytes are outside the closed boundary"
            )

        remaining = file_before.st_size
        chunks: list[bytes] = []
        while remaining:
            chunk = os.read(file_descriptor, min(64 * 1024, remaining))
            if not chunk:
                raise R10ContractError(
                    f"{context} changed during bounded no-follow read"
                )
            chunks.append(chunk)
            remaining -= len(chunk)
        if os.read(file_descriptor, 1):
            raise R10ContractError(
                f"{context} changed during bounded no-follow read"
            )

        for parent, name, descriptor, expected in reversed(links):
            descriptor_after = os.fstat(descriptor)
            named_after = os.stat(
                name,
                dir_fd=parent,
                follow_symlinks=False,
            )
            if (
                _stat_identity(descriptor_after) != _stat_identity(expected)
                or _stat_identity(named_after) != _stat_identity(expected)
            ):
                raise R10ContractError(
                    f"{context} changed during bounded no-follow read"
                )
        root_after = os.fstat(root_descriptor)
        root_named_after = os.stat(root, follow_symlinks=False)
        if (
            _stat_identity(root_after) != _stat_identity(root_before)
            or _stat_identity(root_named_after) != _stat_identity(root_before)
        ):
            raise R10ContractError(
                f"{context} changed during bounded no-follow read"
            )
        return b"".join(chunks)
    except R10ContractError:
        raise
    except OSError as error:
        raise R10ContractError(
            f"{context} must be a regular non-symlink file"
        ) from error
    finally:
        for descriptor in reversed(descriptors):
            try:
                os.close(descriptor)
            except OSError:
                pass


def _privacy_errors(value: object, context: str) -> list[str]:
    errors: list[str] = []

    def visit(item: object, location: str) -> None:
        if isinstance(item, dict):
            for key, nested in item.items():
                if str(key).lower() in PRIVATE_EVIDENCE_KEYS:
                    errors.append(
                        f"{context} contains forbidden private key at "
                        f"{location}.{key}"
                    )
                visit(nested, f"{location}.{key}")
        elif isinstance(item, list):
            for index, nested in enumerate(item):
                visit(nested, f"{location}[{index}]")
        elif isinstance(item, str):
            if EMAIL_PATTERN.search(item):
                errors.append(f"{context} contains an email address at {location}")
            if PRIVATE_PATH_PATTERN.search(item):
                errors.append(f"{context} contains a private path at {location}")

    visit(value, "$")
    return errors


def _decode_payload(payload: bytes, context: str) -> dict[str, Any]:
    if (
        type(payload) is not bytes
        or not payload
        or len(payload) > MAX_CONTRACT_BYTES
        or not payload.endswith(b"\n")
        or b"\x00" in payload
        or b"\r" in payload
    ):
        raise R10ContractError(f"{context} bytes are outside the closed boundary")
    try:
        text = payload.decode("utf-8")
        value = decode_json(text)
    except (UnicodeDecodeError, ValueError, json.JSONDecodeError) as error:
        raise R10ContractError(f"{context} JSON is invalid: {error}") from error
    if type(value) is not dict:
        raise R10ContractError(f"{context} must be one JSON object")
    privacy = _privacy_errors(value, context)
    if privacy:
        raise R10ContractError("; ".join(privacy))
    return value


def _schema(path: Path) -> dict[str, Any]:
    try:
        payload = _read_regular_nofollow(
            REPOSITORY_ROOT,
            path,
            f"{path.as_posix()} schema",
        )
        value = decode_json(payload.decode("utf-8"))
    except (R10ContractError, UnicodeDecodeError, ValueError) as error:
        raise R10ContractError(f"{path.as_posix()} schema is invalid: {error}") from error
    if type(value) is not dict:
        raise R10ContractError(f"{path.as_posix()} schema must be one object")
    return value


def _validate_schema(
    value: Mapping[str, Any],
    schema_path: Path,
    context: str,
) -> None:
    errors = validate_json_schema_instance(_schema(schema_path), value)
    if errors:
        raise R10ContractError(
            "; ".join(f"{context} schema: {error}" for error in errors)
        )


def _constraint_from_document_r10(
    value: Mapping[str, Any],
) -> R10HardConstraint:
    try:
        constraint = R10HardConstraint(
            name=R10ConstraintName(value["name"]),
            observed=value["observed"],
            minimum=value["minimum"],
            maximum=value["maximum"],
        )
    except (KeyError, ValueError, R10OptimizerError) as error:
        raise R10ContractError("R10 fixture constraint is invalid") from error
    if constraint.to_document() != value:
        raise R10ContractError("R10 fixture constraint semantics differ")
    return constraint


def _candidate_from_document_r10(
    value: Mapping[str, Any],
) -> R10Candidate:
    try:
        variables = value["causal_variables"]
        constraints = value["constraints"]
        if type(variables) is not dict or type(constraints) is not list:
            raise R10ContractError("R10 candidate document shape is invalid")
        candidate = R10Candidate(
            candidate_id=value["candidate_id"],
            causal_variables=tuple(variables.items()),
            constraints=tuple(
                _constraint_from_document_r10(item)
                for item in constraints
                if isinstance(item, dict)
            ),
        )
    except (KeyError, R10OptimizerError) as error:
        raise R10ContractError("R10 fixture candidate is invalid") from error
    if candidate.to_document() != value:
        raise R10ContractError("R10 fixture candidate semantics differ")
    return candidate


def parse_fixture_catalog_r10(
    payload: bytes,
) -> tuple[dict[str, Any], tuple[R10Candidate, ...]]:
    """Parse exact fixture bytes into the nine typed finite candidates."""

    value = _decode_payload(payload, "R10 fixture catalog")
    _validate_schema(value, FIXTURE_CATALOG_SCHEMA_PATH, "R10 fixture catalog")
    if _semantic_sha256(value) != FIXTURE_CATALOG_SEMANTIC_SHA256:
        raise R10ContractError("R10 fixture catalog semantic SHA-256 differs")
    wrappers = value.get("candidates")
    if type(wrappers) is not list:
        raise R10ContractError("R10 fixture candidates must be one array")
    candidates: list[R10Candidate] = []
    expected_rejections: list[str] = []
    for index, wrapper in enumerate(wrappers):
        if type(wrapper) is not dict or type(wrapper.get("candidate")) is not dict:
            raise R10ContractError(f"R10 fixture candidate {index} is invalid")
        candidate = _candidate_from_document_r10(wrapper["candidate"])
        if wrapper.get("candidate_sha256") != candidate.candidate_sha256:
            raise R10ContractError(
                f"R10 fixture candidate {candidate.candidate_id} SHA-256 differs"
            )
        rejected = [name.value for name in candidate.failed_constraints]
        expected = wrapper.get("expected")
        disposition = "rejected" if rejected else "scored"
        if expected != {
            "disposition": disposition,
            "rejected_constraints": rejected,
        }:
            raise R10ContractError(
                f"R10 fixture candidate {candidate.candidate_id} expectation differs"
            )
        expected_rejections.extend(rejected)
        candidates.append(candidate)
    candidate_tuple = tuple(candidates)
    if tuple(candidate.candidate_id for candidate in candidate_tuple) != CANDIDATE_IDS:
        raise R10ContractError("R10 fixture candidate IDs or order differ")
    if (
        len({candidate.candidate_sha256 for candidate in candidate_tuple}) != 9
        or tuple(expected_rejections) != CONSTRAINT_ORDER
        or sum(not candidate.failed_constraints for candidate in candidate_tuple) != 3
        or value.get("maximum_candidates") != 9
        or tuple(value.get("causal_variable_names", ())) != CAUSAL_VARIABLE_NAMES
        or tuple(value.get("constraint_order", ())) != CONSTRAINT_ORDER
        or value.get("comparison_methods_used") is not False
    ):
        raise R10ContractError("R10 finite candidate contract differs")
    return value, candidate_tuple


def parse_evaluation_catalog_r10(
    payload: bytes,
) -> tuple[dict[str, Any], R10EvaluationCatalog]:
    """Parse raw evaluator-envelope bytes and verify its inner semantic digest."""

    value = _decode_payload(payload, "R10 evaluation catalog")
    _validate_schema(
        value,
        EVALUATION_CATALOG_SCHEMA_PATH,
        "R10 evaluation catalog",
    )
    if _semantic_sha256(value) != EVALUATION_CATALOG_SEMANTIC_SHA256:
        raise R10ContractError("R10 evaluation catalog semantic SHA-256 differs")
    inner = value.get("evaluation_catalog")
    if type(inner) is not dict or type(inner.get("evaluations")) is not list:
        raise R10ContractError("R10 inner evaluation catalog is invalid")
    evaluations: list[R10Evaluation] = []
    try:
        for item in inner["evaluations"]:
            if type(item) is not dict or type(item.get("score")) is not dict:
                raise R10ContractError("R10 evaluation item is invalid")
            score = R10AbsoluteScore(**item["score"])
            evaluation = R10Evaluation(
                candidate_id=item["candidate_id"],
                candidate_sha256=item["candidate_sha256"],
                score=score,
            )
            if evaluation.to_document() != item:
                raise R10ContractError("R10 evaluation semantics differ")
            evaluations.append(evaluation)
        catalog = R10EvaluationCatalog(tuple(evaluations))
    except (KeyError, TypeError, R10OptimizerError) as error:
        raise R10ContractError("R10 evaluation catalog is invalid") from error
    if catalog.to_document() != inner:
        raise R10ContractError("R10 evaluation canonical order differs")
    if (
        tuple(item.candidate_id for item in catalog.evaluations)
        != VALID_CANDIDATE_IDS
        or catalog.evaluator_sha256 != EVALUATOR_SEMANTIC_SHA256
        or value.get("evaluator_sha256") != catalog.evaluator_sha256
        or value.get("comparison_methods_used") is not False
    ):
        raise R10ContractError("R10 raw or semantic evaluator identity differs")
    scores = {item.candidate_id: item.score for item in catalog.evaluations}
    if (
        scores["fixture-valid-alpha"] != scores["fixture-valid-beta"]
        or scores["fixture-valid-alpha"] == scores["fixture-valid-gamma"]
    ):
        raise R10ContractError("R10 exact tie and distinct-rank fixtures differ")
    dimensions = value.get("score_contract", {}).get("dimensions")
    if (
        type(dimensions) is not list
        or tuple(
            item.get("name") for item in dimensions if isinstance(item, dict)
        )
        != EVALUATION_DOCUMENT_DIMENSION_ORDER
    ):
        raise R10ContractError("R10 evaluation score dimensions differ")
    return value, catalog


def parse_policy_catalog_r10(payload: bytes) -> dict[str, Any]:
    """Parse the closed finite-search and fixture-publication policy bytes."""

    value = _decode_payload(payload, "R10 policy catalog")
    _validate_schema(value, POLICY_CATALOG_SCHEMA_PATH, "R10 policy catalog")
    if _semantic_sha256(value) != POLICY_CATALOG_SEMANTIC_SHA256:
        raise R10ContractError("R10 policy catalog semantic SHA-256 differs")
    variables = value.get("causal_variables")
    dimensions = value.get("absolute_score_dimensions")
    if (
        type(variables) is not list
        or tuple(
            item.get("name") for item in variables if isinstance(item, dict)
        )
        != CAUSAL_VARIABLE_NAMES
        or type(dimensions) is not list
        or tuple(
            item.get("name") for item in dimensions if isinstance(item, dict)
        )
        != SCORE_DIMENSION_ORDER
        or value.get("maximum_candidates") != 9
        or tuple(value.get("constraint_order", ())) != CONSTRAINT_ORDER
        or value.get("publication_scope")
        != "deterministic_fixture_policy_only"
        or value.get("production_auto_authorized") is not False
        or value.get("holdout_authorized") is not False
        or value.get("comparative_metrics_used") is not False
        or value.get("threshold_relaxation_allowed") is not False
        or value.get("post_freeze_change_allowed") is not False
    ):
        raise R10ContractError("R10 policy boundary differs")
    return value


class R10ContractVerifier:
    def __init__(self, root: Path) -> None:
        self.root = root.resolve()

    def git(self, *arguments: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["git", *arguments],
            cwd=self.root,
            capture_output=True,
            check=False,
            text=True,
        )

    def _read_bytes(
        self,
        relative: Path,
        context: str,
        errors: list[str],
    ) -> bytes | None:
        try:
            return _read_regular_nofollow(
                self.root,
                relative,
                context,
            )
        except R10ContractError as error:
            errors.append(str(error))
            return None

    def _read_json(
        self,
        relative: Path,
        context: str,
        errors: list[str],
    ) -> dict[str, Any] | None:
        payload = self._read_bytes(relative, context, errors)
        if payload is None:
            return None
        try:
            value = _decode_payload(payload, context)
        except R10ContractError as error:
            errors.append(str(error))
            return None
        return value

    def _check_binding(
        self,
        value: object,
        expected_path: Path,
        context: str,
        errors: list[str],
    ) -> None:
        if type(value) is not dict:
            errors.append(f"{context} must be one binding object")
            return
        path_value = value.get("path")
        if type(path_value) is not str:
            errors.append(f"{context}.path must be repository-relative")
            return
        pure_path = PurePosixPath(path_value)
        if (
            pure_path.as_posix() != path_value
            or pure_path.is_absolute()
            or any(part in {"", ".", ".."} for part in pure_path.parts)
            or path_value != expected_path.as_posix()
        ):
            errors.append(f"{context}.path differs")
            return
        payload = self._read_bytes(expected_path, context, errors)
        if payload is None:
            return
        if value.get("size_bytes") != len(payload):
            errors.append(f"{context}.size_bytes differs")
        if value.get("sha256") != _sha256(payload):
            errors.append(f"{context}.sha256 differs")

    @staticmethod
    def _ids(
        value: object,
        context: str,
        errors: list[str],
    ) -> tuple[str, ...]:
        if type(value) is not list:
            errors.append(f"{context} must be one array")
            return ()
        identifiers = tuple(
            item.get("id")
            for item in value
            if type(item) is dict and type(item.get("id")) is str
        )
        if len(identifiers) != len(value) or len(set(identifiers)) != len(value):
            errors.append(f"{context} IDs must be present and unique")
        return identifiers

    def _check_predecessors(
        self,
        value: object,
        errors: list[str],
    ) -> None:
        if value != list(PREDECESSOR_BINDINGS):
            errors.append("R10 predecessor bindings differ")
            return
        for expected in PREDECESSOR_BINDINGS:
            path = Path(str(expected["path"]))
            payload = self._read_bytes(
                path,
                f"accepted {expected['phase_id']} evidence",
                errors,
            )
            if payload is not None and (
                len(payload) != expected["size_bytes"]
                or _sha256(payload) != expected["raw_sha256"]
            ):
                errors.append(
                    f"accepted {expected['phase_id']} raw evidence differs"
                )
            for role in ("implementation", "accepted_merge"):
                commit = str(expected[f"{role}_commit"])
                tree = str(expected[f"{role}_tree"])
                result = self.git("show", "-s", "--format=%T", commit)
                if result.returncode != 0 or result.stdout.strip() != tree:
                    errors.append(
                        f"accepted {expected['phase_id']} {role} commit or tree differs"
                    )
                if (
                    self.git("merge-base", "--is-ancestor", commit, "HEAD").returncode
                    != 0
                ):
                    errors.append(
                        f"accepted {expected['phase_id']} {role} commit is not an ancestor of HEAD"
                    )

    def check_preregistration(self) -> list[str]:
        errors: list[str] = []
        payload = self._read_bytes(
            PREREGISTRATION_PATH,
            "R10 preregistration",
            errors,
        )
        value: dict[str, Any] | None = None
        if payload is not None:
            if (
                len(payload) != PREREGISTRATION_SIZE_BYTES
                or _sha256(payload) != PREREGISTRATION_RAW_SHA256
            ):
                errors.append("R10 preregistration raw byte identity differs")
            try:
                value = _decode_payload(payload, "R10 preregistration")
                _validate_schema(
                    value,
                    PREREGISTRATION_SCHEMA_PATH,
                    "R10 preregistration",
                )
            except R10ContractError as error:
                errors.append(str(error))
        if value is not None:
            if _semantic_sha256(value) != PREREGISTRATION_SEMANTIC_SHA256:
                errors.append("R10 preregistration semantic SHA-256 differs")
            self._check_predecessors(value.get("predecessor_bindings"), errors)
            implementations = value.get("implementation_contract_bindings")
            if self._ids(
                implementations,
                "R10 implementation bindings",
                errors,
            ) != tuple(IMPLEMENTATION_PATHS):
                errors.append("R10 implementation binding IDs differ")
            if type(implementations) is list:
                for item in implementations:
                    if type(item) is dict and item.get("id") in IMPLEMENTATION_PATHS:
                        self._check_binding(
                            {
                                "path": item.get("path"),
                                "size_bytes": item.get("size_bytes"),
                                "sha256": item.get("sha256"),
                            },
                            IMPLEMENTATION_PATHS[str(item["id"])],
                            f"R10 {item['id']} binding",
                            errors,
                        )
            for section_name, expected_paths in (
                ("schema_bindings", SCHEMA_PATHS),
                ("catalog_bindings", CATALOG_PATHS),
            ):
                section = value.get(section_name)
                if type(section) is not dict or set(section) != set(expected_paths):
                    errors.append(f"R10 {section_name} keys differ")
                    continue
                for identifier, expected_path in expected_paths.items():
                    self._check_binding(
                        section.get(identifier),
                        expected_path,
                        f"R10 {identifier} binding",
                        errors,
                    )
            if self._ids(value.get("checks"), "R10 checks", errors) != CHECK_IDS:
                errors.append("R10 check IDs differ")
            if (
                self._ids(value.get("stop_rules"), "R10 stop rules", errors)
                != STOP_RULE_IDS
            ):
                errors.append("R10 stop-rule IDs differ")
            checkpoint = value.get("source_checkpoint_policy")
            if (
                type(checkpoint) is not dict
                or checkpoint.get(
                    "preregistration_self_binds_future_source_checkpoint"
                )
                is not False
                or "source_commit" in checkpoint
                or "source_tree" in checkpoint
            ):
                errors.append(
                    "R10 preregistration must not self-bind its future source checkpoint"
                )
            acceptance = value.get("acceptance_policy")
            if (
                type(acceptance) is not dict
                or acceptance.get("acceptance_dependency")
                != "exact_predecessors_and_preregistered_software_function_checks"
                or acceptance.get("comparison_acceptance_dependency") != "none"
                or any(
                    acceptance.get(key)
                    != "excluded_not_required_non_authorizing"
                    for key in (
                        "comparative_testing",
                        "a_b_testing",
                        "superiority_requirement",
                    )
                )
            ):
                errors.append(
                    "R10 comparison methods must remain excluded and non-authorizing"
                )
            boundary = value.get("authorization_boundary")
            if (
                type(boundary) is not dict
                or boundary.get("r10_implementation") != "authorized"
                or boundary.get("fixture_policy_publication")
                != "authorized_after_preregistered_run_checks_pass"
                or any(
                    boundary.get(key) != "not_authorized"
                    for key in (
                        "production_auto",
                        "holdout",
                        "product_publication",
                        "quality_claims",
                        "performance_claims",
                        "release",
                    )
                )
            ):
                errors.append("R10 authorization boundary differs")
        return errors

    def check_catalogs(self) -> list[str]:
        errors: list[str] = []
        fixture_payload = self._read_bytes(
            FIXTURE_CATALOG_PATH,
            "R10 fixture catalog",
            errors,
        )
        evaluation_payload = self._read_bytes(
            EVALUATION_CATALOG_PATH,
            "R10 evaluation catalog",
            errors,
        )
        policy_payload = self._read_bytes(
            POLICY_CATALOG_PATH,
            "R10 policy catalog",
            errors,
        )
        parsed_fixture: tuple[dict[str, Any], tuple[R10Candidate, ...]] | None = None
        parsed_evaluation: tuple[
            dict[str, Any], R10EvaluationCatalog
        ] | None = None
        policy: dict[str, Any] | None = None
        for payload, context, expected_size, expected_raw, parser in (
            (
                fixture_payload,
                "R10 fixture catalog",
                FIXTURE_CATALOG_SIZE_BYTES,
                FIXTURE_CATALOG_RAW_SHA256,
                parse_fixture_catalog_r10,
            ),
            (
                evaluation_payload,
                "R10 evaluation catalog",
                EVALUATION_CATALOG_SIZE_BYTES,
                EVALUATION_CATALOG_RAW_SHA256,
                parse_evaluation_catalog_r10,
            ),
            (
                policy_payload,
                "R10 policy catalog",
                POLICY_CATALOG_SIZE_BYTES,
                POLICY_CATALOG_RAW_SHA256,
                parse_policy_catalog_r10,
            ),
        ):
            if payload is None:
                continue
            if len(payload) != expected_size or _sha256(payload) != expected_raw:
                errors.append(f"{context} raw byte identity differs")
            try:
                parsed = parser(payload)
            except R10ContractError as error:
                errors.append(str(error))
                continue
            if parser is parse_fixture_catalog_r10:
                parsed_fixture = parsed  # type: ignore[assignment]
            elif parser is parse_evaluation_catalog_r10:
                parsed_evaluation = parsed  # type: ignore[assignment]
            else:
                policy = parsed  # type: ignore[assignment]
        if (
            parsed_fixture is not None
            and parsed_evaluation is not None
            and policy is not None
            and evaluation_payload is not None
            and policy_payload is not None
        ):
            fixture, candidates = parsed_fixture
            evaluation_document, evaluation_catalog = parsed_evaluation
            expected_evaluation_binding = {
                "path": EVALUATION_CATALOG_PATH.as_posix(),
                "size_bytes": len(evaluation_payload),
                "sha256": _sha256(evaluation_payload),
            }
            expected_policy_binding = {
                "path": POLICY_CATALOG_PATH.as_posix(),
                "size_bytes": len(policy_payload),
                "sha256": _sha256(policy_payload),
            }
            if (
                fixture.get("evaluation_catalog_binding")
                != expected_evaluation_binding
            ):
                errors.append("R10 fixture evaluation raw binding differs")
            if fixture.get("policy_catalog_binding") != expected_policy_binding:
                errors.append("R10 fixture policy raw binding differs")
            candidate_by_id = {
                candidate.candidate_id: candidate for candidate in candidates
            }
            if tuple(
                evaluation.candidate_id
                for evaluation in evaluation_catalog.evaluations
            ) != VALID_CANDIDATE_IDS or any(
                evaluation.candidate_sha256
                != candidate_by_id[evaluation.candidate_id].candidate_sha256
                for evaluation in evaluation_catalog.evaluations
            ):
                errors.append("R10 evaluator candidate bindings differ")
            allowed = {
                item["name"]: frozenset(item["allowed_values"])
                for item in policy["causal_variables"]
                if type(item) is dict
            }
            for candidate in candidates:
                variables = dict(candidate.causal_variables)
                if set(variables) != set(allowed) or any(
                    value not in allowed[name] for name, value in variables.items()
                ):
                    errors.append(
                        f"R10 candidate {candidate.candidate_id} exceeds policy values"
                    )
        return errors

    def check_roadmap_status(self) -> list[str]:
        errors: list[str] = []
        roadmap = self._read_json(ROADMAP_PATH, "canonical roadmap", errors)
        if roadmap is None:
            return errors
        phases = roadmap.get("phases")
        phase = (
            next(
                (
                    item
                    for item in phases
                    if type(item) is dict and item.get("id") == "R10"
                ),
                None,
            )
            if type(phases) is list
            else None
        )
        status = phase.get("status") if type(phase) is dict else None
        if status not in {"planned", "in_progress", "passed"}:
            errors.append("canonical R10 status must be planned, in_progress, or passed")
            return errors
        if status == "passed":
            acceptance = self._read_json(
                PHASE_ACCEPTANCE_PATH,
                "R10 functional phase acceptance",
                errors,
            )
            if acceptance is not None:
                try:
                    _validate_schema(
                        acceptance,
                        PHASE_ACCEPTANCE_SCHEMA_PATH,
                        "R10 functional phase acceptance",
                    )
                except R10ContractError as error:
                    errors.append(str(error))
                gate = acceptance.get("functional_gate")
                if (
                    type(gate) is not dict
                    or gate.get("status") != "passed"
                    or gate.get("acceptance") != "accepted"
                    or gate.get("phase_status_after") != "passed"
                ):
                    errors.append("passed R10 status requires accepted phase evidence")
            try:
                from Scripts.r10_phase_acceptance import (
                    R10PhaseAcceptanceVerifier,
                )
            except (ImportError, OSError) as error:
                errors.append(
                    "passed R10 status cannot load the deep generated-evidence "
                    f"verifier: {error}"
                )
            else:
                try:
                    errors.extend(
                        R10PhaseAcceptanceVerifier(
                            self.root
                        ).check_generated()
                    )
                except (OSError, RuntimeError, TypeError, ValueError) as error:
                    errors.append(
                        "passed R10 status deep generated-evidence validation "
                        f"failed closed: {error}"
                    )
        return errors

    def check(self) -> list[str]:
        return [
            *self.check_preregistration(),
            *self.check_catalogs(),
            *self.check_roadmap_status(),
        ]


def emit_errors(errors: Iterable[str]) -> int:
    values = list(dict.fromkeys(errors))
    for error in values:
        print(f"ERROR: {error}", file=sys.stderr)
    return 1 if values else 0


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check-preregistration", action="store_true")
    parser.add_argument("--check-catalogs", action="store_true")
    parser.add_argument("--check-roadmap-status", action="store_true")
    parser.add_argument("--all", action="store_true")
    arguments = parser.parse_args(argv)
    selected = any(
        (
            arguments.check_preregistration,
            arguments.check_catalogs,
            arguments.check_roadmap_status,
            arguments.all,
        )
    )
    check_all = arguments.all or not selected
    verifier = R10ContractVerifier(REPOSITORY_ROOT)
    checks = (
        (
            "R10 preregistration",
            arguments.check_preregistration,
            verifier.check_preregistration,
        ),
        ("R10 catalogs", arguments.check_catalogs, verifier.check_catalogs),
        (
            "R10 roadmap status",
            arguments.check_roadmap_status,
            verifier.check_roadmap_status,
        ),
    )
    errors: list[str] = []
    passed_labels: list[str] = []
    for label, explicitly_selected, check in checks:
        if check_all or explicitly_selected:
            passed_labels.append(label)
            errors.extend(check())
    if not errors:
        for label in passed_labels:
            print(f"{label}: PASS")
    return emit_errors(errors)


if __name__ == "__main__":
    raise SystemExit(main())
