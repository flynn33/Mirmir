#!/usr/bin/env python3
"""Derive and validate R10 deterministic software-function acceptance evidence."""

from __future__ import annotations

import argparse
import ast
from dataclasses import dataclass
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import subprocess
import sys
import tempfile
from typing import Any, Iterable, Mapping, Sequence

_MODULE_REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
if str(_MODULE_REPOSITORY_ROOT) not in sys.path:
    sys.path.insert(0, str(_MODULE_REPOSITORY_ROOT))

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

from Scripts.r10_contracts import (
    R10ContractError,
    parse_evaluation_catalog_r10,
    parse_fixture_catalog_r10,
    parse_policy_catalog_r10,
)
from validation.calibration_v2.r10_optimizer import (
    R10AttemptDisposition,
    R10Checkpoint,
    R10CheckpointStatus,
    R10ConstraintName,
    R10EvaluationCatalog,
    R10ProcessingIdentity,
)
from validation.calibration_v2.r10_persistence import (
    MAX_R10_ARTIFACT_BYTES,
    R10ArtifactBinding,
    R10PersistenceError,
    R10PersistenceStore,
)


REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
ROADMAP_PATH = Path(
    "docs/roadmaps/Mirmir_Apple_Native_ASH_Roadmap_2026-07-18.json"
)
EXECUTION_RECEIPT_PATH = Path(
    "docs/roadmaps/evidence/r10/records/functional-execution-receipt.json"
)
ACCEPTANCE_PATH = Path(
    "docs/roadmaps/evidence/r10/records/functional-phase-acceptance.json"
)
ARTIFACT_DIRECTORY = Path(
    "docs/roadmaps/evidence/r10/records/artifacts/functional-phase-acceptance"
)
UNITTEST_LOG_PATH = ARTIFACT_DIRECTORY / "unittest.log"
RUN_DIRECTORY = ARTIFACT_DIRECTORY / "calibration-run"
RUN_RECEIPT_PATH = RUN_DIRECTORY / "run-receipt.json"

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
PHASE_EVIDENCE_PATH = Path("Scripts/phase_evidence.py")
RUN_RECEIPT_SCHEMA_PATH = Path(
    "docs/roadmaps/evidence/schema/r10-calibration-run-receipt-v1.json"
)
EXECUTION_RECEIPT_SCHEMA_PATH = Path(
    "docs/roadmaps/evidence/schema/r10-functional-execution-receipt-v1.json"
)
ACCEPTANCE_SCHEMA_PATH = Path(
    "docs/roadmaps/evidence/schema/r10-functional-phase-acceptance-v1.json"
)

OPTIMIZER_PATH = Path("validation/calibration_v2/r10_optimizer.py")
PERSISTENCE_PATH = Path("validation/calibration_v2/r10_persistence.py")
CONTRACT_VALIDATOR_PATH = Path("Scripts/r10_contracts.py")
RUNNER_PATH = Path(
    "validation/calibration_v2/tools/run_r10_fixture_calibration.py"
)
OPTIMIZER_TEST_PATH = Path(
    "validation/calibration_v2/tests/test_r10_optimizer.py"
)
PERSISTENCE_TEST_PATH = Path(
    "validation/calibration_v2/tests/test_r10_persistence.py"
)
RUNNER_TEST_PATH = Path(
    "validation/calibration_v2/tests/test_run_r10_fixture_calibration.py"
)
CONTRACT_VALIDATOR_TEST_PATH = Path("Scripts/tests/test_r10_contracts.py")
PHASE_ACCEPTANCE_VALIDATOR_PATH = Path("Scripts/r10_phase_acceptance.py")
PHASE_ACCEPTANCE_VALIDATOR_TEST_PATH = Path(
    "Scripts/tests/test_r10_phase_acceptance.py"
)

CONTRACT_PATHS = (
    ("r10_preregistration", PREREGISTRATION_PATH),
    ("r10_fixture_catalog", FIXTURE_CATALOG_PATH),
    ("r10_evaluation_catalog", EVALUATION_CATALOG_PATH),
    ("r10_policy_catalog", POLICY_CATALOG_PATH),
    ("r10_preregistration_schema", PREREGISTRATION_SCHEMA_PATH),
    ("r10_fixture_catalog_schema", FIXTURE_CATALOG_SCHEMA_PATH),
    ("r10_evaluation_catalog_schema", EVALUATION_CATALOG_SCHEMA_PATH),
    ("r10_policy_catalog_schema", POLICY_CATALOG_SCHEMA_PATH),
    ("r10_calibration_run_receipt_schema", RUN_RECEIPT_SCHEMA_PATH),
    ("r10_functional_execution_receipt_schema", EXECUTION_RECEIPT_SCHEMA_PATH),
    ("r10_functional_phase_acceptance_schema", ACCEPTANCE_SCHEMA_PATH),
)

IMPLEMENTATION_PATHS = (
    ("r10_optimizer_contract", OPTIMIZER_PATH),
    ("r10_persistence_contract", PERSISTENCE_PATH),
    ("r10_catalog_contract_parser", CONTRACT_VALIDATOR_PATH),
    ("r10_fixture_calibration_runner", RUNNER_PATH),
    ("r10_optimizer_contract_tests", OPTIMIZER_TEST_PATH),
    ("r10_persistence_contract_tests", PERSISTENCE_TEST_PATH),
    ("r10_fixture_calibration_runner_tests", RUNNER_TEST_PATH),
    ("r10_catalog_contract_parser_tests", CONTRACT_VALIDATOR_TEST_PATH),
    ("r10_phase_acceptance_validator", PHASE_ACCEPTANCE_VALIDATOR_PATH),
    (
        "r10_phase_acceptance_validator_tests",
        PHASE_ACCEPTANCE_VALIDATOR_TEST_PATH,
    ),
)

SOURCE_FILE_ROLES = (
    ("optimizer_contract", OPTIMIZER_PATH),
    ("persistence_contract", PERSISTENCE_PATH),
    ("fixture_catalog", FIXTURE_CATALOG_PATH),
    ("evaluation_catalog_raw_envelope", EVALUATION_CATALOG_PATH),
    ("policy_catalog", POLICY_CATALOG_PATH),
    ("fixture_catalog_schema", FIXTURE_CATALOG_SCHEMA_PATH),
    ("evaluation_catalog_schema", EVALUATION_CATALOG_SCHEMA_PATH),
    ("policy_catalog_schema", POLICY_CATALOG_SCHEMA_PATH),
    ("schema_validation_runtime", PHASE_EVIDENCE_PATH),
    ("fixture_calibration_runner", RUNNER_PATH),
    ("catalog_contract_parser", CONTRACT_VALIDATOR_PATH),
)

OPTIMIZER_TEST_METHODS = (
    "test_persistence_contract_identity_is_independent_and_propagated",
    "test_invalid_duplicate_and_nonfinite_inputs_fail_closed",
    "test_evaluation_catalog_is_canonical_immutable_and_unique",
    "test_finite_bound_caps_catalog_observations",
    "test_each_hard_constraint_rejects_before_catalog_observation",
    "test_permutation_and_exact_tie_are_byte_deterministic",
    "test_exact_resume_matches_uninterrupted_bytes",
    "test_resume_mismatch_fails_before_catalog_observation",
    "test_cancellation_occurs_between_candidates_and_resumes_exactly",
    "test_cancellation_exception_is_deterministic_transactional_failure",
    "test_catalog_missing_and_candidate_mismatch_fail_transactionally",
    "test_catalog_substitution_cannot_change_bound_scores",
    "test_completed_resume_replays_scores_and_reproduces_exact_result",
    "test_completed_resume_rejects_structurally_valid_forged_score",
    "test_every_partial_resume_status_replays_prior_scores",
    "test_resume_replay_missing_and_mismatch_are_transactional",
    "test_all_rejected_is_typed_failure_without_catalog_observation",
    "test_completed_checkpoint_reconstructs_full_candidate_contract",
    "test_checkpoint_value_cannot_be_replaced_without_detection",
    "test_checkpoint_bytes_remain_canonical_json",
)

PERSISTENCE_TEST_METHODS = (
    "test_each_incremental_checkpoint_is_content_addressed_and_reopens",
    "test_success_publishes_policy_only_after_checkpoint_reopen",
    "test_missing_checkpoint_prevents_frozen_policy_publication",
    "test_cancel_and_failure_publish_terminal_records_without_policy",
    "test_identical_runs_publish_byte_identical_frozen_policies",
    "test_frozen_policy_name_collision_never_replaces_first_policy",
    "test_mutated_checkpoint_is_rejected_on_reopen",
    "test_idempotent_publish_reopens_existing_exact_bytes",
    "test_context_manager_and_idempotent_close_reject_later_use",
    "test_root_swap_to_symlink_is_rejected_by_pinned_identity",
    "test_second_store_never_removes_an_unowned_active_temporary",
    "test_two_stores_concurrently_publish_identical_checkpoint",
    "test_published_artifacts_are_sealed_read_only",
    "test_exact_bounded_read_rejects_oversize_and_growth",
    "test_outcomes_require_exact_bound_evaluation_catalog",
    "test_forged_scored_checkpoint_cannot_publish_or_reopen_policy",
    "test_forged_scored_checkpoint_cannot_publish_or_reopen_terminal",
    "test_reopened_outcomes_reject_dangling_checkpoint_dependency",
    "test_reopened_outcomes_replay_checkpoint_semantics",
)


@dataclass(frozen=True)
class TestSuite:
    module: str
    class_name: str
    path: Path
    methods: tuple[str, ...]

    @property
    def identifiers(self) -> tuple[str, ...]:
        return tuple(
            f"{self.module}.{self.class_name}.{method}"
            for method in sorted(self.methods)
        )


TEST_SUITES = (
    TestSuite(
        module="validation.calibration_v2.tests.test_r10_optimizer",
        class_name="R10OptimizerContractTests",
        path=OPTIMIZER_TEST_PATH,
        methods=OPTIMIZER_TEST_METHODS,
    ),
    TestSuite(
        module="validation.calibration_v2.tests.test_r10_persistence",
        class_name="R10PersistenceTests",
        path=PERSISTENCE_TEST_PATH,
        methods=PERSISTENCE_TEST_METHODS,
    ),
)
EXPECTED_SELECTED_TEST_COUNT = 39
UNITTEST_COMMAND = (
    "PYTHONDONTWRITEBYTECODE=1 python3 -m unittest -v "
    "validation.calibration_v2.tests.test_r10_optimizer "
    "validation.calibration_v2.tests.test_r10_persistence"
)


def _test_identifier(suite: TestSuite, method: str) -> str:
    return f"{suite.module}.{suite.class_name}.{method}"


O = TEST_SUITES[0]
P = TEST_SUITES[1]
FUNCTIONAL_TEST_METHODS = (
    (
        "typed_input_and_schema_rejection",
        (
            _test_identifier(
                O, "test_invalid_duplicate_and_nonfinite_inputs_fail_closed"
            ),
        ),
    ),
    (
        "finite_candidate_bound_and_catalog_observation_cap",
        (
            _test_identifier(O, "test_finite_bound_caps_catalog_observations"),
            _test_identifier(
                O, "test_all_rejected_is_typed_failure_without_catalog_observation"
            ),
        ),
    ),
    (
        "six_constraints_reject_independently",
        (
            _test_identifier(
                O, "test_each_hard_constraint_rejects_before_catalog_observation"
            ),
        ),
    ),
    (
        "canonical_catalog_identity_and_replay",
        (
            _test_identifier(
                O, "test_evaluation_catalog_is_canonical_immutable_and_unique"
            ),
            _test_identifier(
                O, "test_catalog_missing_and_candidate_mismatch_fail_transactionally"
            ),
            _test_identifier(
                O, "test_catalog_substitution_cannot_change_bound_scores"
            ),
            _test_identifier(
                O,
                "test_completed_resume_rejects_structurally_valid_forged_score",
            ),
            _test_identifier(
                P, "test_outcomes_require_exact_bound_evaluation_catalog"
            ),
        ),
    ),
    (
        "deterministic_order_rank_and_tie_break",
        (
            _test_identifier(
                O, "test_permutation_and_exact_tie_are_byte_deterministic"
            ),
            _test_identifier(O, "test_checkpoint_bytes_remain_canonical_json"),
            _test_identifier(
                P, "test_identical_runs_publish_byte_identical_frozen_policies"
            ),
        ),
    ),
    (
        "incremental_checkpoint_chain_and_exact_resume",
        (
            _test_identifier(
                O, "test_exact_resume_matches_uninterrupted_bytes"
            ),
            _test_identifier(
                O, "test_resume_mismatch_fails_before_catalog_observation"
            ),
            _test_identifier(
                O, "test_completed_resume_replays_scores_and_reproduces_exact_result"
            ),
            _test_identifier(
                O, "test_every_partial_resume_status_replays_prior_scores"
            ),
            _test_identifier(
                O, "test_resume_replay_missing_and_mismatch_are_transactional"
            ),
            _test_identifier(
                O, "test_completed_checkpoint_reconstructs_full_candidate_contract"
            ),
            _test_identifier(
                O, "test_checkpoint_value_cannot_be_replaced_without_detection"
            ),
            _test_identifier(
                P, "test_each_incremental_checkpoint_is_content_addressed_and_reopens"
            ),
        ),
    ),
    (
        "cancellation_and_callback_failure_transactional",
        (
            _test_identifier(
                O, "test_cancellation_occurs_between_candidates_and_resumes_exactly"
            ),
            _test_identifier(
                O, "test_cancellation_exception_is_deterministic_transactional_failure"
            ),
            _test_identifier(
                P, "test_cancel_and_failure_publish_terminal_records_without_policy"
            ),
        ),
    ),
    (
        "atomic_no_follow_content_addressed_persistence",
        (
            _test_identifier(
                P, "test_frozen_policy_name_collision_never_replaces_first_policy"
            ),
            _test_identifier(
                P, "test_context_manager_and_idempotent_close_reject_later_use"
            ),
        ),
    ),
    (
        "tamper_dangling_oversize_and_path_escape_rejection",
        (
            _test_identifier(
                P, "test_mutated_checkpoint_is_rejected_on_reopen"
            ),
            _test_identifier(
                P, "test_root_swap_to_symlink_is_rejected_by_pinned_identity"
            ),
            _test_identifier(
                P, "test_exact_bounded_read_rejects_oversize_and_growth"
            ),
        ),
    ),
    (
        "concurrent_idempotent_publication_and_read_only_sealing",
        (
            _test_identifier(
                P, "test_idempotent_publish_reopens_existing_exact_bytes"
            ),
            _test_identifier(
                P, "test_second_store_never_removes_an_unowned_active_temporary"
            ),
            _test_identifier(
                P, "test_two_stores_concurrently_publish_identical_checkpoint"
            ),
            _test_identifier(P, "test_published_artifacts_are_sealed_read_only"),
        ),
    ),
    (
        "frozen_policy_complete_identity_and_dependency_closure",
        (
            _test_identifier(
                O,
                "test_persistence_contract_identity_is_independent_and_propagated",
            ),
            _test_identifier(
                P, "test_missing_checkpoint_prevents_frozen_policy_publication"
            ),
            _test_identifier(
                P, "test_forged_scored_checkpoint_cannot_publish_or_reopen_policy"
            ),
            _test_identifier(
                P, "test_forged_scored_checkpoint_cannot_publish_or_reopen_terminal"
            ),
            _test_identifier(
                P, "test_reopened_outcomes_reject_dangling_checkpoint_dependency"
            ),
            _test_identifier(
                P, "test_reopened_outcomes_replay_checkpoint_semantics"
            ),
        ),
    ),
    (
        "comparison_absent_and_production_auto_blocked",
        (
            _test_identifier(
                P, "test_success_publishes_policy_only_after_checkpoint_reopen"
            ),
        ),
    ),
)
FUNCTIONAL_CHECK_IDS = tuple(
    identifier for identifier, _ in FUNCTIONAL_TEST_METHODS
)

DERIVED_CHECK_IDS = (
    "source_checkpoint_exact",
    "contract_bindings_exact",
    "implementation_bindings_exact",
    "exact_39_test_execution",
    "calibration_run_receipt_schema_exact",
    "dynamic_artifact_closure_exact",
    "processing_identity_exact",
    "counts_and_independent_constraints_exact",
    "typed_reopen_exact_evaluation_catalog",
    "resume_cancel_failure_filesystem_coverage_exact",
    "fixture_only_noncomparative_scope_exact",
    "production_auto_and_holdout_blocked",
)

OBSERVATION_STATUS = {
    "deterministic_software_execution": "observed",
    "deterministic_fixture_simulation": "observed",
    "physical_hardware_execution": "not_observed",
    "apple_simulator_execution": "not_observed",
    "operator_observed_operation": "not_observed",
}

COMPARISON_POLICY = {
    "comparative_testing": "not_run_not_required",
    "a_b_testing": "not_run_not_required",
    "superiority_requirement": "not_run_not_required",
    "comparison_acceptance_dependency": "none",
}

AUTHORIZATION_BOUNDARY = {
    "fixture_policy_publication": "authorized",
    "production_auto": "not_authorized",
    "holdout": "not_authorized",
    "product_publication": "not_authorized",
    "quality_claims": "not_authorized",
    "performance_claims": "not_authorized",
    "release": "not_authorized",
}

ACCEPTANCE_AUTHORIZATION_BOUNDARY = {
    "r10_phase_acceptance": "authorized",
    "fixture_policy_evidence_publication": "authorized",
    "production_auto": "not_authorized",
    "holdout": "not_authorized",
    "product_publication": "not_authorized",
    "quality_claims": "not_authorized",
    "performance_claims": "not_authorized",
    "release": "not_authorized",
}

OPERATOR_OVERRIDE = {
    "authority": "operator",
    "acceptance_basis": "software_does_what_it_says_it_does",
    "comparison_requirement": "not_run_not_required",
    "hardware_requirement": "waived_not_a_blocker",
    "simulator_requirement": "waived_not_a_blocker",
    "operator_observation_requirement": "waived_not_a_blocker",
}

FUNCTIONAL_GATE = {
    "status": "passed",
    "phase_status_before": "in_progress",
    "phase_status_after": "passed",
    "acceptance": "accepted",
    "acceptance_basis": "software_does_what_it_says_it_does",
    "acceptance_scope": "declared_software_function_only",
    "execution_mode": "deterministic_fixture_simulation",
    "roadmap_exit_outcome": "passed",
}

EXECUTION_LIMITATIONS = (
    "R10 evidence covers deterministic fixture-policy optimization only; it "
    "does not authorize production Auto, holdout, or product publication.",
    "The nine numeric candidate records are software-test inputs and are not "
    "product or quality thresholds.",
    "No comparative, A/B, or superiority method was run or required.",
    "Physical hardware, Apple simulator, and operator-observed operation were "
    "not observed and are not required by this software-function gate.",
)

ACCEPTANCE_LIMITATIONS = (
    "R10 acceptance is limited to exact-source proof that the bounded optimizer "
    "and persistence software perform their declared deterministic task.",
    "The frozen output is fixture-policy evidence only; production Auto, "
    "holdout, claims, product publication, and release remain unauthorized.",
    "No comparative, A/B, superiority, hardware, simulator, or operator "
    "observation gate is part of this acceptance.",
)

_GIT_OID_PATTERN = re.compile(r"^(?!0{40}$)[0-9a-f]{40}$")
_TEST_RESULT_PATTERN = re.compile(
    r"^(test_[A-Za-z0-9_]+) \(([^)]+)\) \.\.\. "
    r"(ok|FAIL|ERROR|skipped .+)$"
)
_RUN_SUMMARY_PATTERN = re.compile(
    r"^Ran ([0-9]+) tests? in [0-9]+(?:\.[0-9]+)?s$"
)
_MAX_LOG_BYTES = 8 * 1024 * 1024
_MAX_JSON_BYTES = 16 * 1024 * 1024
_MAX_SOURCE_BLOB_BYTES = 4 * 1024 * 1024


def _sha256(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def _privacy_errors(value: object, context: str) -> list[str]:
    errors: list[str] = []

    def visit(item: object, location: str) -> None:
        if isinstance(item, dict):
            for key, nested in item.items():
                if str(key).casefold() in PRIVATE_EVIDENCE_KEYS:
                    errors.append(
                        f"{context} contains private key at {location}.{key}"
                    )
                visit(nested, f"{location}.{key}")
        elif isinstance(item, list):
            for index, nested in enumerate(item):
                visit(nested, f"{location}[{index}]")
        elif isinstance(item, str) and (
            EMAIL_PATTERN.search(item) or PRIVATE_PATH_PATTERN.search(item)
        ):
            errors.append(f"{context} contains private identity at {location}")

    visit(value, "$")
    return errors


def _safe_relative_path(value: object, context: str) -> str:
    if type(value) is not str:
        raise ValueError(f"{context} must be one relative path")
    path = PurePosixPath(value)
    if (
        path.is_absolute()
        or not path.parts
        or path.as_posix() != value
        or any(part in {"", ".", ".."} for part in path.parts)
    ):
        raise ValueError(f"{context} is unsafe")
    return value


def _decode_object(payload: bytes, context: str) -> dict[str, Any]:
    if (
        type(payload) is not bytes
        or not payload
        or len(payload) > _MAX_JSON_BYTES
        or not payload.endswith(b"\n")
        or b"\x00" in payload
        or b"\r" in payload
    ):
        raise ValueError(f"{context} bytes are outside the closed boundary")
    try:
        value = decode_json(payload.decode("utf-8"))
    except (UnicodeDecodeError, ValueError, json.JSONDecodeError) as error:
        raise ValueError(f"{context} JSON is invalid: {error}") from error
    if type(value) is not dict:
        raise ValueError(f"{context} must be one JSON object")
    privacy = _privacy_errors(value, context)
    if privacy:
        raise ValueError("; ".join(privacy))
    return value


@dataclass(frozen=True)
class TestExecution:
    identifiers: tuple[str, ...]
    log_payload: bytes


@dataclass(frozen=True)
class RunEvidence:
    receipt: dict[str, Any]
    receipt_payload: bytes
    dynamic_payloads: tuple[tuple[str, bytes], ...]
    checkpoints: tuple[R10Checkpoint, ...]


class R10PhaseAcceptanceVerifier:
    def __init__(
        self,
        root: Path,
        *,
        contract_paths: Sequence[tuple[str, Path]] = CONTRACT_PATHS,
        implementation_paths: Sequence[tuple[str, Path]] = IMPLEMENTATION_PATHS,
        test_suites: Sequence[TestSuite] = TEST_SUITES,
        functional_test_methods: Sequence[
            tuple[str, Sequence[str]]
        ] = FUNCTIONAL_TEST_METHODS,
    ) -> None:
        self.root = root.resolve()
        self.contract_paths = tuple(contract_paths)
        self.implementation_paths = tuple(implementation_paths)
        self.test_suites = tuple(test_suites)
        self.functional_test_methods = tuple(
            (identifier, tuple(methods))
            for identifier, methods in functional_test_methods
        )
        self._source_cache: dict[str, dict[str, str]] = {}
        self._checkpoint_cache: dict[tuple[str, Path], bytes] = {}
        self._blob_cache: dict[tuple[str, Path], str] = {}

    def _git(self, *arguments: str) -> subprocess.CompletedProcess[bytes]:
        executable = "/usr/bin/git" if Path("/usr/bin/git").is_file() else "git"
        return subprocess.run(
            [executable, "-C", os.fspath(self.root), "--no-pager", *arguments],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )

    def _git_text(self, *arguments: str, context: str) -> str:
        result = self._git(*arguments)
        if result.returncode != 0:
            raise ValueError(f"R10 {context} Git query failed")
        try:
            value = result.stdout.decode("ascii").strip()
        except UnicodeDecodeError as error:
            raise ValueError(f"R10 {context} is not ASCII") from error
        if result.stdout != f"{value}\n".encode("ascii"):
            raise ValueError(f"R10 {context} Git output is not canonical")
        return value

    def resolve_source(self, revision: str) -> dict[str, str]:
        if type(revision) is not str or _GIT_OID_PATTERN.fullmatch(revision) is None:
            raise ValueError(
                "R10 implementation commit must be one exact nonzero lowercase "
                "40-character Git object ID"
            )
        cached = self._source_cache.get(revision)
        if cached is not None:
            return dict(cached)
        commit = self._git_text(
            "rev-parse",
            "--verify",
            "--end-of-options",
            f"{revision}^{{commit}}",
            context="implementation commit",
        )
        if commit != revision:
            raise ValueError("R10 implementation commit is not exact")
        tree = self._git_text(
            "rev-parse",
            "--verify",
            "--end-of-options",
            f"{commit}^{{tree}}",
            context="implementation tree",
        )
        if _GIT_OID_PATTERN.fullmatch(tree) is None:
            raise ValueError("R10 implementation tree is invalid")
        source = {"commit": commit, "tree": tree}
        self._source_cache[revision] = source
        return dict(source)

    def _source_errors(self, source: object) -> list[str]:
        if (
            type(source) is not dict
            or tuple(source) != ("commit", "tree")
            or _GIT_OID_PATTERN.fullmatch(str(source.get("commit", ""))) is None
            or _GIT_OID_PATTERN.fullmatch(str(source.get("tree", ""))) is None
        ):
            return ["R10 source commit/tree shape is invalid"]
        try:
            resolved = self.resolve_source(str(source["commit"]))
        except ValueError as error:
            return [str(error)]
        if resolved != source:
            return ["R10 source commit/tree binding differs"]
        return []

    def _checkpoint_bytes(
        self,
        source: Mapping[str, str],
        relative: Path,
    ) -> bytes:
        cache_key = (source["commit"], relative)
        cached = self._checkpoint_cache.get(cache_key)
        if cached is not None:
            return cached
        path = relative.as_posix()
        expression = f"{source['commit']}:{path}"
        object_id = self._git_text(
            "rev-parse",
            "--verify",
            "--end-of-options",
            expression,
            context=f"checkpoint blob {path}",
        )
        object_type = self._git("cat-file", "-t", object_id)
        if object_type.returncode != 0 or object_type.stdout != b"blob\n":
            raise ValueError(f"R10 checkpoint path is not a blob: {path}")
        size_text = self._git_text(
            "cat-file",
            "-s",
            object_id,
            context=f"checkpoint blob size {path}",
        )
        if (
            not size_text.isascii()
            or not size_text.isdecimal()
            or (len(size_text) > 1 and size_text.startswith("0"))
        ):
            raise ValueError(f"R10 checkpoint blob size is invalid: {path}")
        size = int(size_text)
        if size < 1 or size > _MAX_SOURCE_BLOB_BYTES:
            raise ValueError(
                f"R10 checkpoint blob size is outside the fixed boundary: {path}"
            )
        result = self._git(
            "show",
            "--no-ext-diff",
            "--no-textconv",
            "--format=",
            expression,
        )
        if result.returncode != 0:
            raise ValueError(f"R10 checkpoint blob cannot be read: {path}")
        if len(result.stdout) != size:
            raise ValueError(f"R10 checkpoint blob length differs: {path}")
        self._blob_cache[cache_key] = object_id
        self._checkpoint_cache[cache_key] = result.stdout
        return result.stdout

    def _checkpoint_blob_id(
        self,
        source: Mapping[str, str],
        relative: Path,
    ) -> str:
        cache_key = (source["commit"], relative)
        cached = self._blob_cache.get(cache_key)
        if cached is not None:
            return cached
        value = self._git_text(
            "rev-parse",
            "--verify",
            "--end-of-options",
            f"{source['commit']}:{relative.as_posix()}",
            context=f"checkpoint blob {relative.as_posix()}",
        )
        if _GIT_OID_PATTERN.fullmatch(value) is None:
            raise ValueError(
                f"R10 checkpoint blob identity is invalid: {relative.as_posix()}"
            )
        self._blob_cache[cache_key] = value
        return value

    def _checkpoint_binding(
        self,
        source: Mapping[str, str],
        identifier: str,
        relative: Path,
    ) -> dict[str, object]:
        payload = self._checkpoint_bytes(source, relative)
        if not payload:
            raise ValueError(
                f"R10 checkpoint file is empty: {relative.as_posix()}"
            )
        return {
            "id": identifier,
            "path": relative.as_posix(),
            "size_bytes": len(payload),
            "sha256": _sha256(payload),
        }

    def _checkpoint_file_errors(
        self,
        source: Mapping[str, str],
        paths: Sequence[tuple[str, Path]],
        context: str,
    ) -> list[str]:
        errors: list[str] = []
        seen_ids: set[str] = set()
        seen_paths: set[Path] = set()
        for identifier, relative in paths:
            if identifier in seen_ids or relative in seen_paths:
                errors.append(f"R10 {context} inventory repeats")
                continue
            seen_ids.add(identifier)
            seen_paths.add(relative)
            try:
                self._checkpoint_binding(source, identifier, relative)
            except ValueError as error:
                errors.append(str(error))
        return errors

    def _write_source_errors(
        self,
        source: Mapping[str, str],
    ) -> list[str]:
        errors: list[str] = []
        for _identifier, relative in (
            *self.contract_paths,
            *self.implementation_paths,
        ):
            try:
                current = self._read_repository_file(
                    relative,
                    context=f"R10 current source {relative.as_posix()}",
                    maximum=_MAX_SOURCE_BLOB_BYTES,
                )
                checkpoint = self._checkpoint_bytes(source, relative)
            except ValueError as error:
                errors.append(f"R10 current source read failed: {error}")
                continue
            if current != checkpoint:
                errors.append(
                    f"R10 current source differs from implementation commit: "
                    f"{relative.as_posix()}"
                )
        return errors

    @staticmethod
    def _suite_methods(
        payload: bytes,
        suite: TestSuite,
    ) -> tuple[tuple[str, ...], list[str]]:
        errors: list[str] = []
        try:
            module = ast.parse(payload.decode("utf-8"))
        except (UnicodeDecodeError, SyntaxError) as error:
            return (), [
                f"R10 checkpoint test source is invalid: "
                f"{suite.path.as_posix()}: {error}"
            ]
        classes = [
            node
            for node in module.body
            if isinstance(node, ast.ClassDef) and node.name == suite.class_name
        ]
        if len(classes) != 1:
            return (), [
                f"R10 checkpoint test class differs: {suite.class_name}"
            ]
        methods = tuple(
            node.name
            for node in classes[0].body
            if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef))
            and node.name.startswith("test_")
        )
        if len(set(methods)) != len(methods):
            errors.append(
                f"R10 checkpoint test methods repeat: {suite.class_name}"
            )
        if methods != suite.methods:
            errors.append(
                f"R10 checkpoint test inventory differs: {suite.class_name}"
            )
        return methods, errors

    def _checkpoint_test_inventory(
        self,
        source: Mapping[str, str],
    ) -> tuple[tuple[str, ...], list[str]]:
        identifiers: list[str] = []
        errors: list[str] = []
        for suite in self.test_suites:
            try:
                payload = self._checkpoint_bytes(source, suite.path)
            except ValueError as error:
                errors.append(str(error))
                continue
            methods, method_errors = self._suite_methods(payload, suite)
            errors.extend(method_errors)
            identifiers.extend(
                f"{suite.module}.{suite.class_name}.{method}"
                for method in sorted(methods)
            )
        if len(identifiers) != EXPECTED_SELECTED_TEST_COUNT:
            errors.append(
                "R10 checkpoint selected test count differs: expected 39, "
                f"observed {len(identifiers)}"
            )
        if len(set(identifiers)) != len(identifiers):
            errors.append("R10 checkpoint selected test identifiers repeat")
        mapped = [
            test_id
            for _check_id, tests in self.functional_test_methods
            for test_id in tests
        ]
        if len(mapped) != EXPECTED_SELECTED_TEST_COUNT:
            errors.append("R10 functional test map does not contain exactly 39 tests")
        if len(set(mapped)) != len(mapped):
            errors.append("R10 functional test map repeats a selected test")
        if set(mapped) != set(identifiers):
            errors.append(
                "R10 functional test map differs from exact selected inventory"
            )
        if (
            tuple(identifier for identifier, _ in self.functional_test_methods)
            != FUNCTIONAL_CHECK_IDS
        ):
            errors.append("R10 functional check IDs or order differ")
        return tuple(identifiers), errors

    @staticmethod
    def _directory_flags() -> int:
        return (
            os.O_RDONLY
            | os.O_DIRECTORY
            | os.O_NOFOLLOW
            | getattr(os, "O_CLOEXEC", 0)
        )

    @staticmethod
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

    @classmethod
    def _open_directory_at(
        cls,
        parent_descriptor: int,
        name: str,
        *,
        context: str,
    ) -> int:
        descriptor = -1
        if not name or name in {".", ".."} or "/" in name or "\x00" in name:
            raise ValueError(f"{context} directory component is unsafe")
        try:
            before = os.stat(
                name,
                dir_fd=parent_descriptor,
                follow_symlinks=False,
            )
            descriptor = os.open(
                name,
                cls._directory_flags(),
                dir_fd=parent_descriptor,
            )
            opened = os.fstat(descriptor)
            after = os.stat(
                name,
                dir_fd=parent_descriptor,
                follow_symlinks=False,
            )
        except OSError as error:
            if descriptor >= 0:
                os.close(descriptor)
            raise ValueError(
                f"{context} directory ancestor is unavailable or unsafe"
            ) from error
        if (
            not stat.S_ISDIR(before.st_mode)
            or not stat.S_ISDIR(opened.st_mode)
            or cls._stat_identity(before) != cls._stat_identity(opened)
            or cls._stat_identity(opened) != cls._stat_identity(after)
        ):
            os.close(descriptor)
            raise ValueError(
                f"{context} directory ancestor identity differs"
            )
        return descriptor

    def _open_repository_directory(
        self,
        relative: Path,
        *,
        context: str,
    ) -> int:
        try:
            relative_value = _safe_relative_path(
                relative.as_posix(), f"{context} path"
            )
        except ValueError:
            raise
        parts = PurePosixPath(relative_value).parts
        descriptor = -1
        try:
            before = os.lstat(self.root)
            descriptor = os.open(self.root, self._directory_flags())
            opened = os.fstat(descriptor)
            after = os.lstat(self.root)
        except OSError as error:
            if descriptor >= 0:
                os.close(descriptor)
            raise ValueError(
                f"{context} repository root is unavailable or unsafe"
            ) from error
        if (
            not stat.S_ISDIR(before.st_mode)
            or self._stat_identity(before) != self._stat_identity(opened)
            or self._stat_identity(opened) != self._stat_identity(after)
        ):
            os.close(descriptor)
            raise ValueError(f"{context} repository root identity differs")
        try:
            for part in parts:
                child = self._open_directory_at(
                    descriptor,
                    part,
                    context=context,
                )
                os.close(descriptor)
                descriptor = child
            return descriptor
        except BaseException:
            os.close(descriptor)
            raise

    def _open_repository_parent(
        self,
        relative: Path,
        *,
        context: str,
    ) -> tuple[int, str]:
        value = _safe_relative_path(relative.as_posix(), f"{context} path")
        parts = PurePosixPath(value).parts
        parent = Path(*parts[:-1])
        descriptor = self._open_repository_directory(
            parent,
            context=context,
        )
        return descriptor, parts[-1]

    @classmethod
    def _read_regular_at(
        cls,
        parent_descriptor: int,
        name: str,
        *,
        context: str,
        maximum: int,
        require_read_only: bool = False,
    ) -> tuple[bytes, os.stat_result]:
        descriptor = -1
        if not name or name in {".", ".."} or "/" in name or "\x00" in name:
            raise ValueError(f"{context} file name is unsafe")
        try:
            before = os.stat(
                name,
                dir_fd=parent_descriptor,
                follow_symlinks=False,
            )
        except OSError as error:
            raise ValueError(f"{context} cannot be inspected") from error
        if (
            not stat.S_ISREG(before.st_mode)
            or before.st_nlink != 1
            or before.st_size < 1
            or before.st_size > maximum
            or (
                require_read_only
                and stat.S_IMODE(before.st_mode) != 0o400
            )
        ):
            raise ValueError(f"{context} file identity or size differs")
        try:
            descriptor = os.open(
                name,
                os.O_RDONLY
                | os.O_NOFOLLOW
                | getattr(os, "O_CLOEXEC", 0),
                dir_fd=parent_descriptor,
            )
            opened = os.fstat(descriptor)
            after_open = os.stat(
                name,
                dir_fd=parent_descriptor,
                follow_symlinks=False,
            )
        except OSError as error:
            if descriptor >= 0:
                os.close(descriptor)
            raise ValueError(f"{context} cannot be opened safely") from error
        expected_identity = cls._stat_identity(before)
        try:
            if (
                cls._stat_identity(opened) != expected_identity
                or cls._stat_identity(after_open) != expected_identity
            ):
                raise ValueError(f"{context} changed while being opened")
            chunks: list[bytes] = []
            remaining = before.st_size
            while remaining:
                chunk = os.read(descriptor, min(1024 * 1024, remaining))
                if not chunk:
                    raise ValueError(f"{context} is truncated")
                chunks.append(chunk)
                remaining -= len(chunk)
            if os.read(descriptor, 1):
                raise ValueError(f"{context} grew beyond its declared size")
            after_read = os.fstat(descriptor)
            after_path = os.stat(
                name,
                dir_fd=parent_descriptor,
                follow_symlinks=False,
            )
            if (
                cls._stat_identity(after_read) != expected_identity
                or cls._stat_identity(after_path) != expected_identity
            ):
                raise ValueError(f"{context} changed while being read")
            payload = b"".join(chunks)
            if len(payload) != before.st_size:
                raise ValueError(f"{context} exact bounded read differs")
            return payload, before
        except OSError as error:
            raise ValueError(f"{context} cannot be read safely") from error
        finally:
            os.close(descriptor)

    def _read_repository_file(
        self,
        relative: Path,
        *,
        context: str,
        maximum: int,
        require_read_only: bool = False,
    ) -> bytes:
        parent_descriptor = -1
        try:
            parent_descriptor, name = self._open_repository_parent(
                relative,
                context=context,
            )
            payload, _status = self._read_regular_at(
                parent_descriptor,
                name,
                context=context,
                maximum=maximum,
                require_read_only=require_read_only,
            )
            return payload
        finally:
            if parent_descriptor >= 0:
                os.close(parent_descriptor)

    def _repository_entry_state(
        self,
        relative: Path,
        *,
        expected_directory: bool,
        context: str,
    ) -> str:
        parent_descriptor = -1
        try:
            parent_descriptor, name = self._open_repository_parent(
                relative,
                context=context,
            )
            try:
                value = os.stat(
                    name,
                    dir_fd=parent_descriptor,
                    follow_symlinks=False,
                )
            except FileNotFoundError:
                return "absent"
            except OSError as error:
                raise ValueError(f"{context} cannot be inspected") from error
            expected = (
                stat.S_ISDIR(value.st_mode)
                if expected_directory
                else stat.S_ISREG(value.st_mode)
            )
            if not expected:
                raise ValueError(
                    f"{context} must be a regular non-symlink "
                    f"{'directory' if expected_directory else 'file'}"
                )
            return "present"
        except ValueError as error:
            cause = error.__cause__
            if isinstance(cause, FileNotFoundError):
                return "absent"
            raise
        finally:
            if parent_descriptor >= 0:
                os.close(parent_descriptor)

    @classmethod
    def _snapshot_directory_at(
        cls,
        descriptor: int,
        destination: Path,
        *,
        context: str,
    ) -> None:
        before = os.fstat(descriptor)
        if not stat.S_ISDIR(before.st_mode):
            raise ValueError(f"{context} snapshot root is not a directory")
        try:
            names_before = tuple(sorted(os.listdir(descriptor)))
        except OSError as error:
            raise ValueError(f"{context} cannot be enumerated") from error
        destination.mkdir(mode=0o700, parents=True, exist_ok=False)
        for name in names_before:
            if not name or name in {".", ".."} or "/" in name or "\x00" in name:
                raise ValueError(f"{context} contains an unsafe entry")
            try:
                child_status = os.stat(
                    name,
                    dir_fd=descriptor,
                    follow_symlinks=False,
                )
            except OSError as error:
                raise ValueError(f"{context} entry changed") from error
            child_destination = destination / name
            if stat.S_ISDIR(child_status.st_mode):
                child_descriptor = cls._open_directory_at(
                    descriptor,
                    name,
                    context=context,
                )
                try:
                    cls._snapshot_directory_at(
                        child_descriptor,
                        child_destination,
                        context=f"{context}/{name}",
                    )
                finally:
                    os.close(child_descriptor)
            elif stat.S_ISREG(child_status.st_mode):
                payload, stable_status = cls._read_regular_at(
                    descriptor,
                    name,
                    context=f"{context}/{name}",
                    maximum=max(
                        _MAX_LOG_BYTES,
                        _MAX_JSON_BYTES,
                        MAX_R10_ARTIFACT_BYTES,
                    ),
                )
                child_destination.write_bytes(payload)
                child_destination.chmod(stat.S_IMODE(stable_status.st_mode))
            else:
                raise ValueError(
                    f"{context}/{name} is not a regular no-follow entry"
                )
        try:
            names_after = tuple(sorted(os.listdir(descriptor)))
            after = os.fstat(descriptor)
        except OSError as error:
            raise ValueError(f"{context} changed during snapshot") from error
        if (
            names_after != names_before
            or cls._stat_identity(after) != cls._stat_identity(before)
        ):
            raise ValueError(f"{context} changed during snapshot")

    def _snapshot_repository_directory(
        self,
        relative: Path,
        destination: Path,
        *,
        context: str,
    ) -> None:
        descriptor = self._open_repository_directory(
            relative,
            context=context,
        )
        try:
            self._snapshot_directory_at(
                descriptor,
                destination,
                context=context,
            )
        finally:
            os.close(descriptor)

    @classmethod
    def _ensure_directory_at(
        cls,
        parent_descriptor: int,
        name: str,
        *,
        context: str,
    ) -> tuple[int, bool]:
        created = False
        try:
            os.mkdir(name, 0o700, dir_fd=parent_descriptor)
            created = True
            os.fsync(parent_descriptor)
        except FileExistsError:
            pass
        except OSError as error:
            raise ValueError(f"{context} directory cannot be created") from error
        return (
            cls._open_directory_at(
                parent_descriptor,
                name,
                context=context,
            ),
            created,
        )

    @staticmethod
    def _publish_payload_at(
        parent_descriptor: int,
        name: str,
        payload: bytes,
        *,
        mode: int,
        context: str,
    ) -> None:
        descriptor = -1
        created = False
        if (
            not name
            or name in {".", ".."}
            or "/" in name
            or "\x00" in name
            or not payload
        ):
            raise ValueError(f"{context} publication input is unsafe")
        try:
            descriptor = os.open(
                name,
                os.O_WRONLY
                | os.O_CREAT
                | os.O_EXCL
                | os.O_NOFOLLOW
                | getattr(os, "O_CLOEXEC", 0),
                mode,
                dir_fd=parent_descriptor,
            )
            created = True
            offset = 0
            while offset < len(payload):
                written = os.write(descriptor, payload[offset:])
                if written <= 0:
                    raise ValueError(f"{context} write made no progress")
                offset += written
            os.fchmod(descriptor, mode)
            os.fsync(descriptor)
            sealed = os.fstat(descriptor)
            if (
                not stat.S_ISREG(sealed.st_mode)
                or sealed.st_nlink != 1
                or sealed.st_size != len(payload)
                or stat.S_IMODE(sealed.st_mode) != mode
            ):
                raise ValueError(f"{context} did not publish exactly")
            os.close(descriptor)
            descriptor = -1
            reopened, _status = R10PhaseAcceptanceVerifier._read_regular_at(
                parent_descriptor,
                name,
                context=context,
                maximum=len(payload),
                require_read_only=mode == 0o400,
            )
            if reopened != payload:
                raise ValueError(f"{context} bytes differ after publication")
            os.fsync(parent_descriptor)
        except (OSError, ValueError) as error:
            if descriptor >= 0:
                os.close(descriptor)
            if created:
                try:
                    os.unlink(name, dir_fd=parent_descriptor)
                except OSError:
                    pass
            if isinstance(error, ValueError):
                raise
            raise ValueError(f"{context} publication failed") from error

    @classmethod
    def _remove_tree_at(
        cls,
        parent_descriptor: int,
        name: str,
    ) -> None:
        try:
            value = os.stat(
                name,
                dir_fd=parent_descriptor,
                follow_symlinks=False,
            )
        except FileNotFoundError:
            return
        if not stat.S_ISDIR(value.st_mode):
            os.unlink(name, dir_fd=parent_descriptor)
            return
        descriptor = cls._open_directory_at(
            parent_descriptor,
            name,
            context="R10 rollback",
        )
        try:
            for child in os.listdir(descriptor):
                cls._remove_tree_at(descriptor, child)
        finally:
            os.close(descriptor)
        os.rmdir(name, dir_fd=parent_descriptor)

    def _repository_directory_matches(
        self,
        relative: Path,
        descriptor: int,
        *,
        context: str,
    ) -> bool:
        reopened = -1
        try:
            reopened = self._open_repository_directory(
                relative,
                context=context,
            )
            return (
                os.fstat(reopened).st_dev,
                os.fstat(reopened).st_ino,
            ) == (
                os.fstat(descriptor).st_dev,
                os.fstat(descriptor).st_ino,
            )
        except (OSError, ValueError):
            return False
        finally:
            if reopened >= 0:
                os.close(reopened)

    @staticmethod
    def _test_log_errors(
        payload: bytes,
        expected_identifiers: Sequence[str],
    ) -> list[str]:
        errors: list[str] = []
        if (
            type(payload) is not bytes
            or not payload
            or len(payload) > _MAX_LOG_BYTES
            or b"\x00" in payload
            or b"\r" in payload
        ):
            return ["R10 unittest log bytes are outside the closed boundary"]
        try:
            text = payload.decode("utf-8")
        except UnicodeDecodeError:
            return ["R10 unittest log is not UTF-8"]
        errors.extend(_privacy_errors(text, "R10 unittest log"))
        observed: list[str] = []
        statuses: list[str] = []
        summaries: list[int] = []
        for line in text.splitlines():
            result = _TEST_RESULT_PATTERN.fullmatch(line)
            if result is not None:
                method, identifier, status_value = result.groups()
                if identifier.rsplit(".", 1)[-1] != method:
                    errors.append("R10 unittest log method/identifier differs")
                observed.append(identifier)
                statuses.append(status_value)
            summary = _RUN_SUMMARY_PATTERN.fullmatch(line)
            if summary is not None:
                summaries.append(int(summary.group(1)))
        if tuple(observed) != tuple(expected_identifiers):
            errors.append("R10 unittest log exact 39-test inventory differs")
        if len(set(observed)) != len(observed):
            errors.append("R10 unittest log repeats a test result")
        if statuses != ["ok"] * EXPECTED_SELECTED_TEST_COUNT:
            errors.append("R10 unittest log contains a failure, error, or skip")
        if summaries != [EXPECTED_SELECTED_TEST_COUNT]:
            errors.append("R10 unittest log summary does not record exactly 39 tests")
        stripped = [line.strip() for line in text.splitlines() if line.strip()]
        if stripped.count("OK") != 1 or any(
            line.startswith("FAILED")
            or line.startswith("OK (")
            or "failures=" in line
            or "errors=" in line
            or "skipped=" in line
            for line in stripped
        ):
            errors.append("R10 unittest log does not record one zero-exception OK")
        return errors

    def _read_input_file(
        self,
        path: Path,
        *,
        context: str,
        maximum: int,
        require_read_only: bool = False,
    ) -> bytes:
        descriptor = -1
        try:
            before = os.lstat(path)
        except OSError as error:
            raise ValueError(f"{context} cannot be inspected") from error
        if (
            not stat.S_ISREG(before.st_mode)
            or before.st_nlink != 1
            or before.st_size < 1
            or before.st_size > maximum
            or (
                require_read_only
                and stat.S_IMODE(before.st_mode) != 0o400
            )
        ):
            raise ValueError(f"{context} file identity or size differs")
        try:
            descriptor = os.open(
                path,
                os.O_RDONLY
                | os.O_NOFOLLOW
                | getattr(os, "O_CLOEXEC", 0),
            )
            opened = os.fstat(descriptor)
            after_open = os.lstat(path)
        except OSError as error:
            if descriptor >= 0:
                os.close(descriptor)
            raise ValueError(f"{context} cannot be opened safely") from error

        def identity(value: os.stat_result) -> tuple[int, ...]:
            return (
                value.st_dev,
                value.st_ino,
                value.st_mode,
                value.st_nlink,
                value.st_size,
                value.st_mtime_ns,
                value.st_ctime_ns,
            )

        expected_identity = identity(before)
        try:
            if (
                identity(opened) != expected_identity
                or identity(after_open) != expected_identity
            ):
                raise ValueError(f"{context} changed while being opened")
            chunks: list[bytes] = []
            remaining = before.st_size
            while remaining:
                chunk = os.read(descriptor, min(1024 * 1024, remaining))
                if not chunk:
                    raise ValueError(f"{context} is truncated")
                chunks.append(chunk)
                remaining -= len(chunk)
            if os.read(descriptor, 1):
                raise ValueError(f"{context} grew beyond its declared size")
            after_read = os.fstat(descriptor)
            after_path = os.lstat(path)
            if (
                identity(after_read) != expected_identity
                or identity(after_path) != expected_identity
            ):
                raise ValueError(f"{context} changed while being read")
            payload = b"".join(chunks)
            if len(payload) != before.st_size:
                raise ValueError(f"{context} exact bounded read differs")
            return payload
        except OSError as error:
            raise ValueError(f"{context} cannot be read safely") from error
        finally:
            os.close(descriptor)

    def _checkpoint_json(
        self,
        source: Mapping[str, str],
        path: Path,
        context: str,
    ) -> dict[str, Any]:
        return _decode_object(self._checkpoint_bytes(source, path), context)

    @staticmethod
    def _schema_errors(
        schema: Mapping[str, Any],
        value: object,
        context: str,
    ) -> list[str]:
        return [
            f"{context}: {error}"
            for error in validate_json_schema_instance(schema, value)
        ]

    def _expected_processing_identity(
        self,
        source: Mapping[str, str],
        evaluation_catalog: R10EvaluationCatalog,
    ) -> R10ProcessingIdentity:
        return R10ProcessingIdentity(
            source_commit=source["commit"],
            source_tree=source["tree"],
            optimizer_contract_sha256=_sha256(
                self._checkpoint_bytes(source, OPTIMIZER_PATH)
            ),
            persistence_contract_sha256=_sha256(
                self._checkpoint_bytes(source, PERSISTENCE_PATH)
            ),
            fixture_catalog_sha256=_sha256(
                self._checkpoint_bytes(source, FIXTURE_CATALOG_PATH)
            ),
            evaluator_sha256=evaluation_catalog.evaluator_sha256,
            policy_catalog_sha256=_sha256(
                self._checkpoint_bytes(source, POLICY_CATALOG_PATH)
            ),
        )

    def _expected_run_source_files(
        self,
        source: Mapping[str, str],
    ) -> list[dict[str, object]]:
        values: list[dict[str, object]] = []
        for role, relative in SOURCE_FILE_ROLES:
            payload = self._checkpoint_bytes(source, relative)
            values.append(
                {
                    "role": role,
                    "path": relative.as_posix(),
                    "git_blob": self._checkpoint_blob_id(source, relative),
                    "size_bytes": len(payload),
                    "sha256": _sha256(payload),
                }
            )
        return values

    @staticmethod
    def _binding_from_document(
        value: object,
        context: str,
    ) -> R10ArtifactBinding:
        if type(value) is not dict or set(value) != {
            "path",
            "size_bytes",
            "sha256",
        }:
            raise ValueError(f"{context} binding shape differs")
        try:
            return R10ArtifactBinding(
                path=_safe_relative_path(value["path"], f"{context}.path"),
                sha256=str(value["sha256"]),
                size_bytes=value["size_bytes"],
            )
        except (KeyError, R10PersistenceError, ValueError) as error:
            raise ValueError(f"{context} binding is invalid") from error

    def _run_manifest_errors(
        self,
        run_root: Path,
        expected_files: set[str],
    ) -> list[str]:
        errors: list[str] = []
        observed_files: set[str] = set()
        observed_directories: set[str] = set()
        for directory, names, files in os.walk(run_root, followlinks=False):
            directory_path = Path(directory)
            relative_directory = directory_path.relative_to(run_root).as_posix()
            if relative_directory != ".":
                observed_directories.add(relative_directory)
            for name in list(names):
                child = directory_path / name
                if child.is_symlink():
                    errors.append(
                        "R10 calibration run contains a symlink directory: "
                        f"{child.relative_to(run_root).as_posix()}"
                    )
            for name in files:
                child = directory_path / name
                relative = child.relative_to(run_root).as_posix()
                if child.is_symlink() or not child.is_file():
                    errors.append(
                        f"R10 calibration run contains an unsafe file: {relative}"
                    )
                observed_files.add(relative)
        if observed_files != expected_files:
            errors.append("R10 calibration run dynamic file closure differs")
        if not observed_directories.issubset(
            {"checkpoints", "frozen-policies", "terminals"}
        ):
            errors.append("R10 calibration run dynamic directory closure differs")
        return errors

    def _validate_run(
        self,
        run_root: Path,
        source: Mapping[str, str],
    ) -> tuple[RunEvidence | None, list[str]]:
        errors: list[str] = []
        if run_root.is_symlink() or not run_root.is_dir():
            return None, [
                "R10 calibration run root must be a regular non-symlink directory"
            ]
        try:
            receipt_payload = self._read_input_file(
                run_root / "run-receipt.json",
                context="R10 calibration run receipt",
                maximum=_MAX_JSON_BYTES,
                require_read_only=True,
            )
            receipt = _decode_object(
                receipt_payload, "R10 calibration run receipt"
            )
        except ValueError as error:
            return None, [str(error)]

        try:
            schema = self._checkpoint_json(
                source,
                RUN_RECEIPT_SCHEMA_PATH,
                "R10 calibration run receipt schema",
            )
        except ValueError as error:
            errors.append(str(error))
            schema = {}
        if schema:
            errors.extend(
                self._schema_errors(
                    schema, receipt, "R10 calibration run receipt schema"
                )
            )

        try:
            fixture_payload = self._checkpoint_bytes(
                source, FIXTURE_CATALOG_PATH
            )
            evaluation_payload = self._checkpoint_bytes(
                source, EVALUATION_CATALOG_PATH
            )
            policy_payload = self._checkpoint_bytes(
                source, POLICY_CATALOG_PATH
            )
            _fixture_document, fixture_candidates = parse_fixture_catalog_r10(
                fixture_payload
            )
            _evaluation_document, evaluation_catalog = (
                parse_evaluation_catalog_r10(evaluation_payload)
            )
            policy_document = parse_policy_catalog_r10(policy_payload)
            identity = self._expected_processing_identity(
                source, evaluation_catalog
            )
        except (ValueError, R10ContractError) as error:
            errors.append(f"R10 exact catalog parsing failed: {error}")
            return None, sorted(set(errors))

        raw_evaluation_binding = {
            "path": EVALUATION_CATALOG_PATH.as_posix(),
            "size_bytes": len(evaluation_payload),
            "sha256": _sha256(evaluation_payload),
        }
        expected_top_level = {
            "schema_version": "1.0.0",
            "phase_id": "R10",
            "artifact_kind": "r10_fixture_calibration_run_receipt",
            "result_status": "succeeded",
        }
        for key, value in expected_top_level.items():
            if receipt.get(key) != value:
                errors.append(f"R10 calibration run receipt field differs: {key}")
        if receipt.get("processing_identity") != identity.to_document():
            errors.append("R10 calibration processing identity differs")
        if receipt.get("processing_identity_sha256") != identity.identity_sha256:
            errors.append("R10 calibration processing identity SHA-256 differs")
        try:
            expected_source_files = self._expected_run_source_files(source)
        except ValueError as error:
            errors.append(str(error))
            expected_source_files = []
        if receipt.get("source_files") != expected_source_files:
            errors.append("R10 calibration source-file bindings differ")
        if receipt.get("raw_evaluation_catalog_binding") != raw_evaluation_binding:
            errors.append("R10 raw evaluation-catalog binding differs")
        if (
            receipt.get("semantic_evaluator_sha256")
            != evaluation_catalog.evaluator_sha256
        ):
            errors.append("R10 semantic evaluator SHA-256 differs")

        expected_execution_contract = {
            "maximum_candidates": 9,
            "candidate_count": 9,
            "scored_count": 3,
            "rejected_count": 6,
            "independently_rejected_constraints": [
                name.value for name in R10ConstraintName
            ],
            "evaluation_observation_count": 3,
            "tie_break": {
                "equal_score_candidate_ids": [
                    "fixture-valid-alpha",
                    "fixture-valid-beta",
                ],
                "rule": (
                    "absolute_score_dimensions_descending_then_"
                    "canonical_candidate_bytes_ascending"
                ),
                "winner_candidate_id": "fixture-valid-alpha",
            },
            "execution_scope": "deterministic_fixture_policy_only",
            "comparison_methods_used": False,
            "production_auto_authorized": False,
            "holdout_authorized": False,
        }
        if receipt.get("execution_contract") != expected_execution_contract:
            errors.append("R10 calibration execution contract differs")
        if (
            policy_document.get("publication_scope")
            != "deterministic_fixture_policy_only"
            or policy_document.get("comparative_metrics_used") is not False
            or policy_document.get("production_auto_authorized") is not False
            or policy_document.get("holdout_authorized") is not False
        ):
            errors.append("R10 policy catalog authorization boundary differs")

        checkpoint_records = receipt.get("checkpoint_bindings")
        publication = receipt.get("publication")
        if type(checkpoint_records) is not list or len(checkpoint_records) != 10:
            errors.append("R10 calibration checkpoint binding count differs")
            checkpoint_records = []
        if type(publication) is not dict:
            errors.append("R10 calibration publication is invalid")
            publication = {}

        checkpoint_bindings: list[R10ArtifactBinding] = []
        for index, record in enumerate(checkpoint_records):
            if type(record) is not dict:
                errors.append(f"R10 checkpoint record {index} is invalid")
                continue
            try:
                binding = self._binding_from_document(
                    record.get("artifact"), f"R10 checkpoint {index}"
                )
            except ValueError as error:
                errors.append(str(error))
                continue
            expected_path = f"checkpoints/{binding.sha256}.json"
            if binding.path != expected_path:
                errors.append(f"R10 checkpoint {index} is not content-addressed")
            checkpoint_bindings.append(binding)
        try:
            frozen_binding = self._binding_from_document(
                publication.get("frozen_policy"), "R10 frozen policy"
            )
        except ValueError as error:
            errors.append(str(error))
            frozen_binding = None

        expected_files = {"run-receipt.json"}
        expected_files.update(binding.path for binding in checkpoint_bindings)
        if frozen_binding is not None:
            expected_files.add(frozen_binding.path)
        errors.extend(self._run_manifest_errors(run_root, expected_files))

        dynamic_payloads: list[tuple[str, bytes]] = []
        checkpoints: list[R10Checkpoint] = []
        if (
            len(checkpoint_bindings) == 10
            and len({binding.path for binding in checkpoint_bindings}) == 10
            and frozen_binding is not None
        ):
            try:
                for binding in checkpoint_bindings:
                    payload = self._read_input_file(
                        run_root / binding.path,
                        context=f"R10 dynamic artifact {binding.path}",
                        maximum=MAX_R10_ARTIFACT_BYTES,
                        require_read_only=True,
                    )
                    if (
                        len(payload) != binding.size_bytes
                        or _sha256(payload) != binding.sha256
                    ):
                        errors.append(
                            f"R10 dynamic checkpoint binding differs: "
                            f"{binding.path}"
                        )
                    dynamic_payloads.append((binding.path, payload))
                frozen_payload = self._read_input_file(
                    run_root / frozen_binding.path,
                    context=f"R10 dynamic artifact {frozen_binding.path}",
                    maximum=MAX_R10_ARTIFACT_BYTES,
                    require_read_only=True,
                )
                if (
                    len(frozen_payload) != frozen_binding.size_bytes
                    or _sha256(frozen_payload) != frozen_binding.sha256
                ):
                    errors.append("R10 dynamic frozen-policy binding differs")
                dynamic_payloads.append((frozen_binding.path, frozen_payload))
            except ValueError as error:
                errors.append(str(error))

            try:
                with R10PersistenceStore(run_root) as store:
                    for index, binding in enumerate(checkpoint_bindings):
                        checkpoint = store.reopen_checkpoint(binding)
                        checkpoints.append(checkpoint)
                        record = checkpoint_records[index]
                        if (
                            record.get("checkpoint_sha256")
                            != checkpoint.checkpoint_sha256
                            or record.get("status") != checkpoint.status.value
                            or record.get("next_candidate_index")
                            != checkpoint.next_candidate_index
                        ):
                            errors.append(
                                f"R10 checkpoint {index} typed fields differ"
                            )
                        if checkpoint.processing_identity != identity:
                            errors.append(
                                f"R10 checkpoint {index} processing identity differs"
                            )
                        for attempt in checkpoint.attempts:
                            if (
                                attempt.disposition
                                is R10AttemptDisposition.SCORED
                            ):
                                if (
                                    attempt.score is None
                                    or evaluation_catalog.score_for(
                                        attempt.candidate
                                    )
                                    != attempt.score
                                ):
                                    errors.append(
                                        f"R10 checkpoint {index} evaluator replay differs"
                                    )
                    frozen_policy = store.reopen_frozen_policy(
                        frozen_binding,
                        evaluation_catalog=evaluation_catalog,
                    )
            except (R10PersistenceError, R10ContractError, ValueError) as error:
                errors.append(f"R10 typed artifact reopen failed: {error}")
                frozen_policy = None

            if len(checkpoints) == 10:
                final = checkpoints[-1]
                if (
                    [item.next_candidate_index for item in checkpoints]
                    != list(range(10))
                    or [item.status for item in checkpoints]
                    != [R10CheckpointStatus.IN_PROGRESS] * 9
                    + [R10CheckpointStatus.COMPLETED]
                    or any(
                        item.attempts != final.attempts[:index]
                        for index, item in enumerate(checkpoints)
                    )
                    or any(
                        item.candidate_set_sha256
                        != final.candidate_set_sha256
                        for item in checkpoints
                    )
                ):
                    errors.append("R10 incremental checkpoint sequence differs")
                scored = [
                    item
                    for item in final.attempts
                    if item.disposition is R10AttemptDisposition.SCORED
                ]
                rejected = [
                    item
                    for item in final.attempts
                    if item.disposition is R10AttemptDisposition.REJECTED
                ]
                rejected_constraints = [
                    constraint.value
                    for attempt in rejected
                    for constraint in attempt.rejected_constraints
                ]
                if (
                    final.candidate_count != 9
                    or final.maximum_candidates != 9
                    or len(final.attempts) != 9
                    or len(scored) != 3
                    or len(rejected) != 6
                    or sorted(rejected_constraints)
                    != sorted(name.value for name in R10ConstraintName)
                    or tuple(attempt.candidate for attempt in final.attempts)
                    != tuple(
                        sorted(
                            fixture_candidates,
                            key=lambda candidate: candidate.canonical_bytes,
                        )
                    )
                ):
                    errors.append(
                        "R10 final 9/3/6 candidate and constraint closure differs"
                    )
                if publication.get("final_checkpoint") != checkpoint_records[-1].get(
                    "artifact"
                ):
                    errors.append("R10 final checkpoint publication differs")
                if frozen_policy is not None:
                    if (
                        frozen_policy.processing_identity != identity
                        or frozen_policy.candidate_set_sha256
                        != final.candidate_set_sha256
                        or frozen_policy.final_checkpoint.checkpoint_sha256
                        != final.checkpoint_sha256
                        or frozen_policy.selection.selected_candidate.candidate_id
                        != "fixture-valid-alpha"
                        or frozen_policy.to_document().get("publication_scope")
                        != "deterministic_fixture_policy_only"
                        or frozen_policy.to_document().get(
                            "production_auto_authorized"
                        )
                        is not False
                        or frozen_policy.to_document().get(
                            "comparative_metrics_used"
                        )
                        is not False
                        or publication.get("policy_sha256")
                        != frozen_policy.policy_sha256
                        or publication.get("selection_sha256")
                        != frozen_policy.selection.selection_sha256
                        or publication.get("selected_candidate_id")
                        != "fixture-valid-alpha"
                    ):
                        errors.append("R10 frozen fixture-policy closure differs")

        if errors:
            return None, sorted(set(errors))
        return (
            RunEvidence(
                receipt=receipt,
                receipt_payload=receipt_payload,
                dynamic_payloads=tuple(dynamic_payloads),
                checkpoints=tuple(checkpoints),
            ),
            [],
        )

    def _base_errors(
        self,
        source: Mapping[str, str],
    ) -> list[str]:
        errors = self._source_errors(dict(source))
        if errors:
            return errors
        errors.extend(
            self._checkpoint_file_errors(
                source, self.contract_paths, "contract"
            )
        )
        errors.extend(
            self._checkpoint_file_errors(
                source, self.implementation_paths, "implementation"
            )
        )
        _identifiers, inventory_errors = self._checkpoint_test_inventory(source)
        errors.extend(inventory_errors)
        return sorted(set(errors))

    def contract_bindings(
        self,
        source: Mapping[str, str],
    ) -> list[dict[str, object]]:
        return [
            self._checkpoint_binding(source, identifier, relative)
            for identifier, relative in self.contract_paths
        ]

    def implementation_bindings(
        self,
        source: Mapping[str, str],
    ) -> list[dict[str, object]]:
        return [
            self._checkpoint_binding(source, identifier, relative)
            for identifier, relative in self.implementation_paths
        ]

    @staticmethod
    def _payload_binding(
        path: Path,
        payload: bytes,
        *,
        identifier: str | None = None,
    ) -> dict[str, object]:
        binding: dict[str, object] = {}
        if identifier is not None:
            binding["id"] = identifier
        binding.update(
            {
                "path": path.as_posix(),
                "size_bytes": len(payload),
                "sha256": _sha256(payload),
            }
        )
        return binding

    def _artifact_payloads(
        self,
        log_payload: bytes,
        run_evidence: RunEvidence,
    ) -> tuple[tuple[str, Path, bytes], ...]:
        values: list[tuple[str, Path, bytes]] = [
            ("unittest_log", UNITTEST_LOG_PATH, log_payload),
            (
                "calibration_run_receipt",
                RUN_RECEIPT_PATH,
                run_evidence.receipt_payload,
            ),
        ]
        for index, (relative, payload) in enumerate(
            run_evidence.dynamic_payloads
        ):
            identifier = (
                f"calibration_checkpoint_{index:02d}"
                if relative.startswith("checkpoints/")
                else "calibration_frozen_policy"
            )
            values.append(
                (identifier, RUN_DIRECTORY / relative, payload)
            )
        return tuple(values)

    def expected_execution_receipt(
        self,
        *,
        source: Mapping[str, str],
        test_execution: TestExecution,
        run_evidence: RunEvidence,
        artifact_payloads: Sequence[tuple[str, Path, bytes]] | None = None,
    ) -> dict[str, object]:
        payloads = (
            self._artifact_payloads(
                test_execution.log_payload, run_evidence
            )
            if artifact_payloads is None
            else tuple(artifact_payloads)
        )
        return {
            "schema_version": "1.0.0",
            "roadmap_version": "1.0.1",
            "phase_id": "R10",
            "evidence_kind": "r10_deterministic_functional_execution_receipt_v1",
            "source": dict(source),
            "contract_bindings": self.contract_bindings(source),
            "implementation_bindings": self.implementation_bindings(source),
            "artifact_bindings": [
                self._payload_binding(path, payload, identifier=identifier)
                for identifier, path, payload in payloads
            ],
            "test_execution": {
                "execution_mode": "deterministic_fixture_simulation",
                "expected_selected_test_count": EXPECTED_SELECTED_TEST_COUNT,
                "selected_test_count": EXPECTED_SELECTED_TEST_COUNT,
                "passed_test_count": EXPECTED_SELECTED_TEST_COUNT,
                "failed_test_count": 0,
                "skipped_test_count": 0,
                "test_identifiers": list(test_execution.identifiers),
                "command": UNITTEST_COMMAND,
            },
            "run_result": {
                "result_status": "succeeded",
                "candidate_count": 9,
                "scored_count": 3,
                "rejected_count": 6,
                "checkpoint_count": 10,
                "selected_candidate_id": "fixture-valid-alpha",
                "typed_reopen": "passed",
            },
            "functional_checks": [
                {
                    "id": identifier,
                    "status": "passed",
                    "evidence_tests": list(tests),
                }
                for identifier, tests in self.functional_test_methods
            ],
            "observation_status": dict(OBSERVATION_STATUS),
            "comparison_policy": dict(COMPARISON_POLICY),
            "acceptance_basis": "software_does_what_it_says_it_does",
            "authorization_boundary": dict(AUTHORIZATION_BOUNDARY),
            "limitations": list(EXECUTION_LIMITATIONS),
        }

    def expected_acceptance(
        self,
        *,
        source: Mapping[str, str],
        execution_receipt_payload: bytes,
        run_receipt_payload: bytes,
    ) -> dict[str, object]:
        return {
            "schema_version": "1.0.0",
            "roadmap_version": "1.0.1",
            "phase_id": "R10",
            "evidence_kind": "r10_operator_functional_phase_acceptance_v1",
            "source": dict(source),
            "operator_override": dict(OPERATOR_OVERRIDE),
            "execution_receipt_binding": self._payload_binding(
                EXECUTION_RECEIPT_PATH, execution_receipt_payload
            ),
            "run_receipt_binding": self._payload_binding(
                RUN_RECEIPT_PATH, run_receipt_payload
            ),
            "functional_gate": dict(FUNCTIONAL_GATE),
            "checks": [
                {"id": identifier, "status": "passed"}
                for identifier in DERIVED_CHECK_IDS
            ],
            "observation_status": dict(OBSERVATION_STATUS),
            "authorization_boundary": dict(
                ACCEPTANCE_AUTHORIZATION_BOUNDARY
            ),
            "limitations": list(ACCEPTANCE_LIMITATIONS),
        }

    @staticmethod
    def _json_payload(value: Mapping[str, object]) -> bytes:
        return (
            json.dumps(
                value,
                indent=2,
                ensure_ascii=False,
                allow_nan=False,
            )
            + "\n"
        ).encode("utf-8")

    def _read_generated_json(
        self,
        relative: Path,
        context: str,
        errors: list[str],
    ) -> tuple[dict[str, Any], bytes] | None:
        try:
            payload = self._read_repository_file(
                relative,
                context=context,
                maximum=_MAX_JSON_BYTES,
            )
            value = _decode_object(payload, context)
        except ValueError as error:
            errors.append(str(error))
            return None
        return value, payload

    def check_generated(self) -> list[str]:
        errors: list[str] = []
        execution_record = self._read_generated_json(
            EXECUTION_RECEIPT_PATH,
            "R10 functional execution receipt",
            errors,
        )
        acceptance_record = self._read_generated_json(
            ACCEPTANCE_PATH,
            "R10 functional phase acceptance",
            errors,
        )
        if execution_record is None or acceptance_record is None:
            return sorted(set(errors))
        execution, execution_payload = execution_record
        acceptance, _acceptance_payload = acceptance_record
        source_value = execution.get("source")
        source_errors = self._source_errors(source_value)
        errors.extend(source_errors)
        if source_errors or type(source_value) is not dict:
            return sorted(set(errors))
        source = {
            "commit": str(source_value["commit"]),
            "tree": str(source_value["tree"]),
        }
        errors.extend(self._base_errors(source))

        identifiers, inventory_errors = self._checkpoint_test_inventory(source)
        errors.extend(inventory_errors)
        with tempfile.TemporaryDirectory(
            prefix="mirmir-r10-checked-evidence-"
        ) as temporary:
            artifact_snapshot = Path(temporary) / "functional-phase-acceptance"
            try:
                self._snapshot_repository_directory(
                    ARTIFACT_DIRECTORY,
                    artifact_snapshot,
                    context="R10 checked-in artifact directory",
                )
            except ValueError as error:
                errors.append(str(error))
                return sorted(set(errors))
            snapshot_entries = {
                path.name for path in artifact_snapshot.iterdir()
            }
            if snapshot_entries != {"unittest.log", "calibration-run"}:
                errors.append(
                    "R10 checked-in artifact directory closure differs"
                )
            try:
                log_payload = self._read_input_file(
                    artifact_snapshot / "unittest.log",
                    context="R10 unittest log",
                    maximum=_MAX_LOG_BYTES,
                )
            except ValueError as error:
                errors.append(str(error))
                log_payload = b""
            errors.extend(self._test_log_errors(log_payload, identifiers))
            run_evidence, run_errors = self._validate_run(
                artifact_snapshot / "calibration-run", source
            )
            errors.extend(run_errors)
        if run_evidence is None:
            return sorted(set(errors))

        try:
            execution_schema = self._checkpoint_json(
                source,
                EXECUTION_RECEIPT_SCHEMA_PATH,
                "R10 functional execution receipt schema",
            )
            acceptance_schema = self._checkpoint_json(
                source,
                ACCEPTANCE_SCHEMA_PATH,
                "R10 functional phase acceptance schema",
            )
        except ValueError as error:
            errors.append(str(error))
            return sorted(set(errors))
        errors.extend(
            self._schema_errors(
                execution_schema,
                execution,
                "R10 functional execution receipt schema",
            )
        )
        errors.extend(
            self._schema_errors(
                acceptance_schema,
                acceptance,
                "R10 functional phase acceptance schema",
            )
        )

        test_execution = TestExecution(
            identifiers=identifiers,
            log_payload=log_payload,
        )
        expected_execution = self.expected_execution_receipt(
            source=source,
            test_execution=test_execution,
            run_evidence=run_evidence,
        )
        if execution != expected_execution:
            errors.append(
                "R10 functional execution receipt is not exactly derived "
                "from the implementation checkpoint and run closure"
            )
        expected_acceptance = self.expected_acceptance(
            source=source,
            execution_receipt_payload=execution_payload,
            run_receipt_payload=run_evidence.receipt_payload,
        )
        if acceptance != expected_acceptance:
            errors.append(
                "R10 functional phase acceptance is not exactly derived "
                "from the software-function evidence"
            )
        return sorted(set(errors))

    def _roadmap_phase_status(self) -> str | None:
        try:
            payload = self._read_repository_file(
                ROADMAP_PATH,
                context="canonical roadmap",
                maximum=_MAX_JSON_BYTES,
            )
            value = decode_json(payload.decode("utf-8"))
        except (UnicodeDecodeError, ValueError):
            return None
        phases = value.get("phases") if type(value) is dict else None
        if type(phases) is not list:
            return None
        phase = next(
            (
                item
                for item in phases
                if type(item) is dict and item.get("id") == "R10"
            ),
            None,
        )
        return phase.get("status") if type(phase) is dict else None

    def check(self) -> list[str]:
        targets = (
            (
                EXECUTION_RECEIPT_PATH,
                False,
                "R10 functional execution receipt",
            ),
            (
                ACCEPTANCE_PATH,
                False,
                "R10 functional phase acceptance",
            ),
            (
                ARTIFACT_DIRECTORY,
                True,
                "R10 functional acceptance artifact directory",
            ),
        )
        states: list[str] = []
        try:
            for relative, is_directory, context in targets:
                states.append(
                    self._repository_entry_state(
                        relative,
                        expected_directory=is_directory,
                        context=context,
                    )
                )
        except ValueError as error:
            return [str(error)]
        exists = tuple(state == "present" for state in states)
        if not any(exists):
            status = self._roadmap_phase_status()
            if status in {"planned", "in_progress"}:
                return []
            return [
                "R10 generated acceptance evidence is absent while canonical "
                f"phase status is {status!r}"
            ]
        if not all(exists):
            return ["R10 generated acceptance evidence is only partially present"]
        return self.check_generated()

    def _write_bundle(
        self,
        *,
        execution_payload: bytes,
        acceptance_payload: bytes,
        artifact_payloads: Sequence[tuple[str, Path, bytes]],
    ) -> list[str]:
        records_descriptor = -1
        artifact_parent_descriptor = -1
        artifact_descriptor = -1
        execution_published = False
        acceptance_published = False
        artifacts_published = False
        try:
            records_descriptor = self._open_repository_directory(
                EXECUTION_RECEIPT_PATH.parent,
                context="R10 evidence records directory",
            )
            artifact_parent_descriptor, _created_parent = (
                self._ensure_directory_at(
                    records_descriptor,
                    ARTIFACT_DIRECTORY.parent.name,
                    context="R10 evidence artifact parent",
                )
            )
            for descriptor, name, context in (
                (
                    records_descriptor,
                    EXECUTION_RECEIPT_PATH.name,
                    "R10 functional execution receipt",
                ),
                (
                    records_descriptor,
                    ACCEPTANCE_PATH.name,
                    "R10 functional phase acceptance",
                ),
                (
                    artifact_parent_descriptor,
                    ARTIFACT_DIRECTORY.name,
                    "R10 functional acceptance artifacts",
                ),
            ):
                try:
                    os.stat(
                        name,
                        dir_fd=descriptor,
                        follow_symlinks=False,
                    )
                except FileNotFoundError:
                    continue
                except OSError as error:
                    raise ValueError(
                        f"{context} target cannot be inspected"
                    ) from error
                raise ValueError(
                    "R10 generated acceptance outputs already exist; validate "
                    "them with --check-generated"
                )
            try:
                os.mkdir(
                    ARTIFACT_DIRECTORY.name,
                    0o700,
                    dir_fd=artifact_parent_descriptor,
                )
                artifacts_published = True
                os.fsync(artifact_parent_descriptor)
            except OSError as error:
                raise ValueError(
                    "R10 functional acceptance artifact directory cannot "
                    "be exclusively created"
                ) from error
            artifact_descriptor = self._open_directory_at(
                artifact_parent_descriptor,
                ARTIFACT_DIRECTORY.name,
                context="R10 functional acceptance artifacts",
            )
            for _identifier, canonical_path, payload in artifact_payloads:
                relative = canonical_path.relative_to(ARTIFACT_DIRECTORY)
                parts = PurePosixPath(
                    _safe_relative_path(
                        relative.as_posix(),
                        "R10 artifact publication path",
                    )
                ).parts
                parent = os.dup(artifact_descriptor)
                try:
                    for part in parts[:-1]:
                        child, _created = self._ensure_directory_at(
                            parent,
                            part,
                            context="R10 artifact publication",
                        )
                        os.close(parent)
                        parent = child
                    self._publish_payload_at(
                        parent,
                        parts[-1],
                        payload,
                        mode=0o400,
                        context=f"R10 artifact {relative.as_posix()}",
                    )
                finally:
                    os.close(parent)
            self._publish_payload_at(
                records_descriptor,
                EXECUTION_RECEIPT_PATH.name,
                execution_payload,
                mode=0o644,
                context="R10 functional execution receipt",
            )
            execution_published = True
            self._publish_payload_at(
                records_descriptor,
                ACCEPTANCE_PATH.name,
                acceptance_payload,
                mode=0o644,
                context="R10 functional phase acceptance",
            )
            acceptance_published = True
            if (
                not self._repository_directory_matches(
                    EXECUTION_RECEIPT_PATH.parent,
                    records_descriptor,
                    context="R10 evidence records directory",
                )
                or not self._repository_directory_matches(
                    ARTIFACT_DIRECTORY.parent,
                    artifact_parent_descriptor,
                    context="R10 evidence artifact parent",
                )
                or not self._repository_directory_matches(
                    ARTIFACT_DIRECTORY,
                    artifact_descriptor,
                    context="R10 functional acceptance artifacts",
                )
                or self._read_repository_file(
                    EXECUTION_RECEIPT_PATH,
                    context="R10 published execution receipt",
                    maximum=_MAX_JSON_BYTES,
                )
                != execution_payload
                or self._read_repository_file(
                    ACCEPTANCE_PATH,
                    context="R10 published phase acceptance",
                    maximum=_MAX_JSON_BYTES,
                )
                != acceptance_payload
            ):
                raise ValueError(
                    "R10 evidence publication ancestor identity changed"
                )
            return []
        except (OSError, ValueError) as error:
            if acceptance_published and records_descriptor >= 0:
                try:
                    os.unlink(
                        ACCEPTANCE_PATH.name,
                        dir_fd=records_descriptor,
                    )
                except OSError:
                    pass
            if execution_published and records_descriptor >= 0:
                try:
                    os.unlink(
                        EXECUTION_RECEIPT_PATH.name,
                        dir_fd=records_descriptor,
                    )
                except OSError:
                    pass
            if artifacts_published and artifact_parent_descriptor >= 0:
                try:
                    self._remove_tree_at(
                        artifact_parent_descriptor,
                        ARTIFACT_DIRECTORY.name,
                    )
                except (OSError, ValueError):
                    pass
            return [f"R10 evidence output transaction failed: {error}"]
        finally:
            for descriptor in (
                artifact_descriptor,
                artifact_parent_descriptor,
                records_descriptor,
            ):
                if descriptor >= 0:
                    os.close(descriptor)

    def write(
        self,
        revision: str,
        *,
        test_log: Path,
        run_root: Path,
    ) -> list[str]:
        try:
            source = self.resolve_source(revision)
        except ValueError as error:
            return [str(error)]
        errors = self._base_errors(source)
        errors.extend(self._write_source_errors(source))
        identifiers, inventory_errors = self._checkpoint_test_inventory(source)
        errors.extend(inventory_errors)
        log_input = (
            test_log
            if test_log.is_absolute()
            else Path.cwd() / test_log
        )
        run_input = (
            run_root
            if run_root.is_absolute()
            else Path.cwd() / run_root
        )
        try:
            log_payload = self._read_input_file(
                log_input,
                context="R10 input unittest log",
                maximum=_MAX_LOG_BYTES,
            )
        except ValueError as error:
            errors.append(str(error))
            log_payload = b""
        errors.extend(self._test_log_errors(log_payload, identifiers))
        run_evidence, run_errors = self._validate_run(
            run_input, source
        )
        errors.extend(run_errors)
        if errors or run_evidence is None:
            return sorted(set(errors))

        test_execution = TestExecution(
            identifiers=identifiers,
            log_payload=log_payload,
        )
        artifact_payloads = self._artifact_payloads(
            log_payload, run_evidence
        )
        execution = self.expected_execution_receipt(
            source=source,
            test_execution=test_execution,
            run_evidence=run_evidence,
            artifact_payloads=artifact_payloads,
        )
        execution_payload = self._json_payload(execution)
        acceptance = self.expected_acceptance(
            source=source,
            execution_receipt_payload=execution_payload,
            run_receipt_payload=run_evidence.receipt_payload,
        )
        acceptance_payload = self._json_payload(acceptance)
        try:
            execution_schema = self._checkpoint_json(
                source,
                EXECUTION_RECEIPT_SCHEMA_PATH,
                "R10 functional execution receipt schema",
            )
            acceptance_schema = self._checkpoint_json(
                source,
                ACCEPTANCE_SCHEMA_PATH,
                "R10 functional phase acceptance schema",
            )
        except ValueError as error:
            return [str(error)]
        errors.extend(
            self._schema_errors(
                execution_schema,
                execution,
                "R10 functional execution receipt schema",
            )
        )
        errors.extend(
            self._schema_errors(
                acceptance_schema,
                acceptance,
                "R10 functional phase acceptance schema",
            )
        )
        if errors:
            return sorted(set(errors))
        errors.extend(
            self._write_bundle(
                execution_payload=execution_payload,
                acceptance_payload=acceptance_payload,
                artifact_payloads=artifact_payloads,
            )
        )
        if errors:
            return sorted(set(errors))
        return self.check_generated()


def emit_errors(errors: Iterable[str]) -> int:
    observed = list(dict.fromkeys(errors))
    for error in observed:
        print(f"ERROR: {error}", file=sys.stderr)
    return 1 if observed else 0


def build_argument_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--check", action="store_true")
    group.add_argument("--check-generated", action="store_true")
    group.add_argument("--write", metavar="IMPLEMENTATION_COMMIT")
    parser.add_argument("--test-log", type=Path)
    parser.add_argument("--run-root", type=Path)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    parser = build_argument_parser()
    arguments = parser.parse_args(argv)
    verifier = R10PhaseAcceptanceVerifier(REPOSITORY_ROOT)
    if arguments.write is not None:
        if arguments.test_log is None or arguments.run_root is None:
            parser.error("--write requires --test-log and --run-root")
        errors = verifier.write(
            arguments.write,
            test_log=arguments.test_log,
            run_root=arguments.run_root,
        )
    else:
        if arguments.test_log is not None or arguments.run_root is not None:
            parser.error("--test-log and --run-root are valid only with --write")
        errors = (
            verifier.check_generated()
            if arguments.check_generated
            else verifier.check()
        )
    if not errors:
        print("R10 functional phase acceptance: PASS")
    return emit_errors(errors)


if __name__ == "__main__":
    raise SystemExit(main())
