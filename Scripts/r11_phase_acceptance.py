#!/usr/bin/env python3
"""Derive and deeply validate bounded R11 software-function evidence."""

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

from validation.calibration_v2.r11_traceability import (
    R11BoundaryState,
    R11ClaimDisposition,
    R11ClaimToken,
    R11ExecutionReceipt,
    R11TraceabilityError,
    canonical_json_file_bytes_r11,
    reopen_execution_receipt_r11,
)
from Scripts.r11_contracts import R11ContractVerifier


REPOSITORY_ROOT = _MODULE_REPOSITORY_ROOT
BASELINE_COMMIT = "169dd17495cc7cdb1c3356979277aa0931af1c76"
BASELINE_TREE = "a50b177e664051c0946312858beee618a95137cf"

ROADMAP_PATH = Path(
    "docs/roadmaps/Mirmir_Apple_Native_ASH_Roadmap_2026-07-18.json"
)
RECORDS_DIRECTORY = Path("docs/roadmaps/evidence/r11/records")
RUN_RECEIPT_PATH = RECORDS_DIRECTORY / "traceability-run-receipt.json"
EXECUTION_RECEIPT_PATH = RECORDS_DIRECTORY / "functional-execution-receipt.json"
ACCEPTANCE_PATH = RECORDS_DIRECTORY / "functional-phase-acceptance.json"
ARTIFACT_DIRECTORY = (
    RECORDS_DIRECTORY / "artifacts/functional-phase-acceptance"
)
UNITTEST_LOG_PATH = ARTIFACT_DIRECTORY / "unittest.log"
RUN_RECEIPT_ARTIFACT_PATH = (
    ARTIFACT_DIRECTORY / "traceability-run-receipt.json"
)

PREREGISTRATION_PATH = RECORDS_DIRECTORY / "preregistration.json"
FIXTURE_CATALOG_PATH = RECORDS_DIRECTORY / "fixtures/fixture-catalog.json"
PREREGISTRATION_SCHEMA_PATH = Path(
    "docs/roadmaps/evidence/schema/r11-preregistration-v1.json"
)
FIXTURE_CATALOG_SCHEMA_PATH = Path(
    "docs/roadmaps/evidence/schema/r11-fixture-catalog-v1.json"
)
RUN_RECEIPT_SCHEMA_PATH = Path(
    "docs/roadmaps/evidence/schema/r11-traceability-run-receipt-v1.json"
)
EXECUTION_RECEIPT_SCHEMA_PATH = Path(
    "docs/roadmaps/evidence/schema/r11-functional-execution-receipt-v1.json"
)
ACCEPTANCE_SCHEMA_PATH = Path(
    "docs/roadmaps/evidence/schema/r11-functional-phase-acceptance-v1.json"
)
PHASE_EVIDENCE_PATH = Path("Scripts/phase_evidence.py")
CORE_PATH = Path("validation/calibration_v2/r11_traceability.py")
RUNNER_PATH = Path(
    "validation/calibration_v2/tools/run_r11_fixture_traceability.py"
)
CONTRACTS_PATH = Path("Scripts/r11_contracts.py")
CORE_TEST_PATH = Path(
    "validation/calibration_v2/tests/test_r11_traceability.py"
)
RUNNER_TEST_PATH = Path(
    "validation/calibration_v2/tests/test_run_r11_fixture_traceability.py"
)
CONTRACTS_TEST_PATH = Path("Scripts/tests/test_r11_contracts.py")
PHASE_ACCEPTANCE_VALIDATOR_PATH = Path("Scripts/r11_phase_acceptance.py")
PHASE_ACCEPTANCE_VALIDATOR_TEST_PATH = Path(
    "Scripts/tests/test_r11_phase_acceptance.py"
)

CONTRACT_PATHS = (
    ("r11_preregistration", PREREGISTRATION_PATH),
    ("r11_fixture_catalog", FIXTURE_CATALOG_PATH),
    ("r11_preregistration_schema", PREREGISTRATION_SCHEMA_PATH),
    ("r11_fixture_catalog_schema", FIXTURE_CATALOG_SCHEMA_PATH),
    ("r11_traceability_run_receipt_schema", RUN_RECEIPT_SCHEMA_PATH),
    ("r11_functional_execution_receipt_schema", EXECUTION_RECEIPT_SCHEMA_PATH),
    ("r11_functional_phase_acceptance_schema", ACCEPTANCE_SCHEMA_PATH),
)
IMPLEMENTATION_PATHS = (
    ("r11_traceability_core", CORE_PATH),
    ("r11_traceability_fixture_runner", RUNNER_PATH),
    ("r11_contract_validator", CONTRACTS_PATH),
    ("r11_traceability_core_tests", CORE_TEST_PATH),
    ("r11_traceability_fixture_runner_tests", RUNNER_TEST_PATH),
    ("r11_contract_validator_tests", CONTRACTS_TEST_PATH),
    ("r11_phase_acceptance_validator", PHASE_ACCEPTANCE_VALIDATOR_PATH),
    (
        "r11_phase_acceptance_validator_tests",
        PHASE_ACCEPTANCE_VALIDATOR_TEST_PATH,
    ),
)
SOURCE_FILE_ROLES = (
    ("traceability_core", CORE_PATH),
    ("catalog_contract_parser", CONTRACTS_PATH),
    ("schema_validation_runtime", PHASE_EVIDENCE_PATH),
    ("fixture_catalog", FIXTURE_CATALOG_PATH),
    ("fixture_catalog_schema", FIXTURE_CATALOG_SCHEMA_PATH),
    ("traceability_run_receipt_schema", RUN_RECEIPT_SCHEMA_PATH),
    ("traceability_fixture_runner", RUNNER_PATH),
    ("traceability_preregistration", PREREGISTRATION_PATH),
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


CORE_TEST_METHODS = (
    "test_identity_has_exact_seven_structured_components",
    "test_identity_components_are_frozen",
    "test_identity_rejects_zero_malformed_and_extra_fields",
    "test_canonical_json_rejects_nonfinite_values",
    "test_observed_accepts_only_bounded_canonical_scalars",
    "test_observed_forbids_reason_and_failure_codes",
    "test_not_applicable_reason_is_exact",
    "test_not_observed_reason_is_closed",
    "test_failed_requires_exact_reason_and_failure_code",
    "test_absent_reason_is_exact_and_carries_no_value",
    "test_aggregate_preserves_all_five_states_and_observed_values",
    "test_aggregate_is_input_order_independent",
    "test_homogeneous_aggregate_preserves_exact_state",
    "test_aggregate_rejects_missing_observation",
    "test_aggregate_rejects_duplicate_observation",
    "test_aggregate_rejects_unexpected_observation",
    "test_aggregate_rejects_mismatched_identity",
    "test_aggregate_rejects_noncanonical_or_duplicate_expected_ids",
    "test_aggregate_rejects_bool_counts_and_tampered_state",
    "test_software_behavior_report_is_only_permitted_claim",
    "test_product_and_market_claims_fail_closed_with_forged_authority",
    "test_authorization_assertion_cannot_change_even_supported_decision",
    "test_execution_receipt_reopens_and_recomputes_exactly",
    "test_receipt_bytes_are_order_independent_but_canonical",
    "test_receipt_rejects_tampered_observation_value",
    "test_receipt_rejects_tampered_claim_decision",
    "test_receipt_rejects_comparative_and_provenance_escape_fields",
    "test_receipt_rejects_duplicate_json_keys",
    "test_receipt_rejects_noncanonical_json",
    "test_receipt_rejects_wrong_digest_and_byte_boundaries",
    "test_receipt_rejects_nonfinite_json_constant",
    "test_closed_enums_reject_unknown_states_and_reasons",
)
RUNNER_TEST_METHODS = (
    "test_exact_source_run_publishes_typed_bounded_receipt",
    "test_same_commit_emits_byte_identical_receipt",
    "test_existing_output_root_is_rejected_without_mutation",
    "test_output_root_inside_repository_is_rejected",
    "test_symlinked_output_parent_is_rejected",
    "test_non_exact_source_commit_is_rejected_before_output",
    "test_runtime_dependencies_are_exact_source_bound",
    "test_missing_source_dependency_is_rejected_before_output",
    "test_missing_preregistration_is_rejected_before_output",
    "test_preregistration_byte_drift_is_rejected_before_output",
    "test_preregistration_schema_rejects_tampered_record",
    "test_preregistration_requires_exact_selected_source_bindings",
    "test_selected_core_drift_is_rejected_by_preregistration",
    "test_tampered_fixture_catalog_is_rejected_before_output",
    "test_tampered_run_schema_is_rejected_by_preregistration",
    "test_schema_rejects_missing_reordered_or_truncated_contracts",
    "test_nested_receipt_digest_tamper_is_rejected",
    "test_oversized_source_blob_is_rejected_before_show",
    "test_source_blob_must_match_preflight_size_exactly",
    "test_post_link_failure_removes_final_and_temporary_receipts",
    "test_parser_exposes_only_two_required_operational_arguments",
)
CONTRACT_TEST_METHODS = (
    "test_checked_in_contracts_and_stable_parser_pass",
    "test_cli_all_default_and_each_mode",
    "test_frozen_record_raw_and_semantic_identities",
    "test_all_five_schemas_are_exact_closed_draft_2020_12",
    "test_checked_in_records_match_closed_schemas",
    "test_predecessor_sources_receipts_and_ancestry_are_exact",
    "test_every_preregistered_binding_and_frozen_contract_is_exact",
    "test_check_stop_comparison_claim_and_authority_contracts_are_exact",
    "test_parser_rejects_duplicate_nonfinite_and_invalid_bytes",
    "test_each_observation_state_semantic_mutation_is_rejected",
    "test_identity_digest_and_component_mutations_are_rejected",
    "test_duplicate_missing_unexpected_and_mixed_identity_observations_reject",
    "test_aggregate_hash_count_state_and_observed_value_mutations_reject",
    "test_every_declared_rejection_case_mapping_mutation_rejects",
    "test_claim_scope_comparison_and_authority_mutations_reject",
    "test_forged_authorization_cannot_change_typed_claim_decision",
    "test_private_email_path_and_key_are_rejected",
    "test_nofollow_reader_rejects_symlink_hardlink_oversize_and_escape",
    "test_missing_and_symlinked_fixture_fail_closed",
    "test_planned_in_progress_and_evidence_ready_do_not_require_acceptance",
    "test_passed_requires_all_future_evidence_and_deep_verifier",
    "test_invalid_roadmap_status_rejects",
    "test_strict_decoder_rejects_non_object_and_privacy",
)
TEST_SUITES = (
    TestSuite(
        "validation.calibration_v2.tests.test_r11_traceability",
        "R11TraceabilityTests",
        CORE_TEST_PATH,
        CORE_TEST_METHODS,
    ),
    TestSuite(
        "validation.calibration_v2.tests.test_run_r11_fixture_traceability",
        "R11FixtureTraceabilityCLITests",
        RUNNER_TEST_PATH,
        RUNNER_TEST_METHODS,
    ),
    TestSuite(
        "Scripts.tests.test_r11_contracts",
        "R11ContractTests",
        CONTRACTS_TEST_PATH,
        CONTRACT_TEST_METHODS,
    ),
)
EXPECTED_SELECTED_TEST_COUNT = 76
UNITTEST_COMMAND = (
    "PYTHONDONTWRITEBYTECODE=1 python3 -m unittest -v "
    "validation.calibration_v2.tests.test_r11_traceability "
    "validation.calibration_v2.tests.test_run_r11_fixture_traceability "
    "Scripts.tests.test_r11_contracts"
)

DERIVED_CHECK_IDS = (
    "source_checkpoint_exact",
    "source_ancestry_and_tree_exact",
    "contract_bindings_exact",
    "implementation_bindings_exact",
    "exact_76_test_inventory_and_execution",
    "unittest_log_parser_exact",
    "canonical_run_receipt_import_exact",
    "run_receipt_schema_and_content_exact",
    "nested_execution_receipt_typed_reopen_exact",
    "seven_identity_components_exact",
    "five_observation_states_and_aggregate_exact",
    "no_market_claim_unconditional",
    "comparison_methods_absent_not_required",
    "production_auto_market_product_release_blocked",
    "artifact_closure_and_read_only_sealing_exact",
)
CLAIM_BOUNDARY = {
    "claim_scope": "software_behavior_report",
    "market_disposition": "no_market_claim",
    "production_auto_mode": "blocked",
    "market_leading_claim": "blocked",
}
COMPARISON_POLICY = {
    "comparison_method": "absent_not_required",
    "comparison_success_case": "absent",
    "acceptance_dependency": "none",
}
PREDECESSOR_BINDING = {
    "phase_id": "R10",
    "phase_result": "passed",
    "acceptance_scope": "declared_software_function_only",
    "accepted_source": {
        "commit": "3a76c6a03ea0f52f2a2395925badd5d5d1c03c6b",
        "tree": "37951da694ab4fbca6f8c663bb2883e5084b861c",
    },
    "functional_phase_acceptance": {
        "path": (
            "docs/roadmaps/evidence/r10/records/"
            "functional-phase-acceptance.json"
        ),
        "size_bytes": 3631,
        "sha256": (
            "f7f75fd69691dcca632f2ae8c220cfb34662bb1ecff6769c84602f3a21368785"
        ),
    },
}

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
_MAX_SOURCE_BLOB_BYTES = 8 * 1024 * 1024

RUN_LIMITATIONS = {
    "comparison_methods_used": False,
    "comparison_requirement": "absent_not_required",
    "hardware_observation": "not_observed",
    "simulator_observation": "not_observed",
    "operator_observation": "not_observed",
    "product_qualification": "blocked",
    "production_auto_mode": "blocked",
    "market_position": "blocked",
    "market_leading_claim": "blocked",
}
EXECUTION_LIMITATIONS = (
    "R11 evidence is limited to exact-source deterministic traceability "
    "fixture behavior; product qualification, production Auto, market "
    "position, public claims, product publication, and release remain blocked.",
    "The failed, absent, not-observed, and not-applicable fixture states are "
    "typed software inputs; their complete mixed aggregate is the declared "
    "successful behavior and is not a failed phase result.",
    "No comparative, A/B, superiority, or historical product-comparison "
    "method was run or required.",
    "Physical hardware, Apple simulator, and operator-observed operation were "
    "not observed and are not required by this software-function gate.",
)
ACCEPTANCE_LIMITATIONS = (
    "R11 acceptance is limited to exact-source proof that the traceability, "
    "aggregation, and claim-boundary software perform their declared task.",
    "The unconditional disposition is no_market_claim; product qualification, "
    "production Auto, market position, product publication, and release "
    "remain blocked or unauthorized.",
    "No comparative, A/B, superiority, hardware, simulator, or operator "
    "observation gate is part of this acceptance.",
)


@dataclass(frozen=True)
class TestExecution:
    identifiers: tuple[str, ...]
    log_payload: bytes


@dataclass(frozen=True)
class RunEvidence:
    receipt: dict[str, Any]
    receipt_payload: bytes
    typed_execution: R11ExecutionReceipt


def _sha256(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def _privacy_errors(value: object, context: str) -> list[str]:
    errors: list[str] = []
    pending = [value]
    while pending:
        item = pending.pop()
        if type(item) is dict:
            for key, child in item.items():
                if key in PRIVATE_EVIDENCE_KEYS:
                    errors.append(f"{context} contains private field: {key}")
                pending.append(child)
        elif type(item) is list:
            pending.extend(item)
        elif type(item) is str:
            if EMAIL_PATTERN.search(item) or PRIVATE_PATH_PATTERN.search(item):
                errors.append(f"{context} contains private text")
    return errors


def _safe_relative_path(value: object, context: str) -> str:
    if type(value) is not str or not value or "\x00" in value:
        raise ValueError(f"{context} must be one relative repository path")
    path = PurePosixPath(value)
    if path.is_absolute() or any(part in {"", ".", ".."} for part in path.parts):
        raise ValueError(f"{context} escapes the repository boundary")
    if path.as_posix() != value:
        raise ValueError(f"{context} is not canonical")
    return value


def _decode_object(payload: bytes, context: str) -> dict[str, Any]:
    if (
        type(payload) is not bytes
        or not payload
        or len(payload) > _MAX_JSON_BYTES
        or b"\x00" in payload
        or b"\r" in payload
    ):
        raise ValueError(f"{context} bytes are outside the closed boundary")
    try:
        text = payload.decode("utf-8")
        value = decode_json(text)
    except (UnicodeDecodeError, ValueError) as error:
        raise ValueError(f"{context} is not strict JSON: {error}") from error
    if type(value) is not dict:
        raise ValueError(f"{context} must be one JSON object")
    privacy = _privacy_errors(value, context)
    if privacy:
        raise ValueError(privacy[0])
    return value


class R11PhaseAcceptanceVerifier:
    def __init__(
        self,
        root: Path,
        *,
        contract_paths: Sequence[tuple[str, Path]] = CONTRACT_PATHS,
        implementation_paths: Sequence[tuple[str, Path]] = IMPLEMENTATION_PATHS,
        test_suites: Sequence[TestSuite] = TEST_SUITES,
    ) -> None:
        self.root = root.resolve()
        self.contract_paths = tuple(contract_paths)
        self.implementation_paths = tuple(implementation_paths)
        self.test_suites = tuple(test_suites)
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
            raise ValueError(f"R11 {context} Git query failed")
        try:
            value = result.stdout.decode("ascii").strip()
        except UnicodeDecodeError as error:
            raise ValueError(f"R11 {context} is not ASCII") from error
        if result.stdout != f"{value}\n".encode("ascii"):
            raise ValueError(f"R11 {context} Git output is not canonical")
        return value

    def resolve_source(self, revision: str) -> dict[str, str]:
        if (
            type(revision) is not str
            or _GIT_OID_PATTERN.fullmatch(revision) is None
        ):
            raise ValueError(
                "R11 implementation commit must be one exact nonzero lowercase "
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
        tree = self._git_text(
            "rev-parse",
            "--verify",
            "--end-of-options",
            f"{commit}^{{tree}}",
            context="implementation tree",
        )
        if commit != revision or _GIT_OID_PATTERN.fullmatch(tree) is None:
            raise ValueError("R11 implementation commit or tree differs")
        ancestry = self._git(
            "merge-base",
            "--is-ancestor",
            commit,
            "HEAD",
        )
        if ancestry.returncode != 0:
            raise ValueError("R11 implementation commit is not an ancestor of HEAD")
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
            return ["R11 source commit/tree shape is invalid"]
        try:
            resolved = self.resolve_source(str(source["commit"]))
        except ValueError as error:
            return [str(error)]
        if resolved != source:
            return ["R11 source commit/tree binding differs"]
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
        repository_path = _safe_relative_path(
            relative.as_posix(), "R11 checkpoint path"
        )
        expression = f"{source['commit']}:{repository_path}"
        object_id = self._git_text(
            "rev-parse",
            "--verify",
            "--end-of-options",
            expression,
            context=f"checkpoint blob {repository_path}",
        )
        if not re.fullmatch(r"(?:[0-9a-f]{40}|[0-9a-f]{64})", object_id):
            raise ValueError(
                f"R11 checkpoint blob identity is invalid: {repository_path}"
            )
        object_type = self._git("cat-file", "-t", object_id)
        if object_type.returncode != 0 or object_type.stdout != b"blob\n":
            raise ValueError(f"R11 checkpoint path is not a blob: {repository_path}")
        size_text = self._git_text(
            "cat-file",
            "-s",
            object_id,
            context=f"checkpoint blob size {repository_path}",
        )
        if (
            not size_text.isascii()
            or not size_text.isdecimal()
            or (len(size_text) > 1 and size_text.startswith("0"))
        ):
            raise ValueError(
                f"R11 checkpoint blob size is invalid: {repository_path}"
            )
        size = int(size_text)
        if size < 1 or size > _MAX_SOURCE_BLOB_BYTES:
            raise ValueError(
                "R11 checkpoint blob size is outside the fixed boundary: "
                f"{repository_path}"
            )
        result = self._git(
            "show",
            "--no-ext-diff",
            "--no-textconv",
            "--format=",
            expression,
        )
        if result.returncode != 0 or len(result.stdout) != size:
            raise ValueError(
                f"R11 checkpoint blob cannot be read exactly: {repository_path}"
            )
        self._blob_cache[cache_key] = object_id
        self._checkpoint_cache[cache_key] = result.stdout
        return result.stdout

    def _checkpoint_blob_id(
        self,
        source: Mapping[str, str],
        relative: Path,
    ) -> str:
        cache_key = (source["commit"], relative)
        if cache_key not in self._blob_cache:
            self._checkpoint_bytes(source, relative)
        return self._blob_cache[cache_key]

    def _checkpoint_binding(
        self,
        source: Mapping[str, str],
        identifier: str,
        relative: Path,
    ) -> dict[str, object]:
        payload = self._checkpoint_bytes(source, relative)
        return {
            "id": identifier,
            "path": relative.as_posix(),
            "size_bytes": len(payload),
            "sha256": _sha256(payload),
        }

    @staticmethod
    def _suite_methods(
        payload: bytes,
        suite: TestSuite,
    ) -> tuple[tuple[str, ...], list[str]]:
        try:
            module = ast.parse(payload.decode("utf-8"))
        except (UnicodeDecodeError, SyntaxError) as error:
            return (), [
                "R11 checkpoint test source is invalid: "
                f"{suite.path.as_posix()}: {error}"
            ]
        classes = [
            node
            for node in module.body
            if isinstance(node, ast.ClassDef) and node.name == suite.class_name
        ]
        if len(classes) != 1:
            return (), [
                f"R11 checkpoint test class differs: {suite.class_name}"
            ]
        methods = tuple(
            node.name
            for node in classes[0].body
            if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef))
            and node.name.startswith("test_")
        )
        errors: list[str] = []
        if len(set(methods)) != len(methods):
            errors.append(
                f"R11 checkpoint test methods repeat: {suite.class_name}"
            )
        if methods != suite.methods:
            errors.append(
                f"R11 checkpoint test inventory differs: {suite.class_name}"
            )
        return methods, errors

    def _checkpoint_test_inventory(
        self,
        source: Mapping[str, str],
    ) -> tuple[tuple[str, ...], list[str]]:
        identifiers: list[str] = []
        errors: list[str] = []
        expected_counts = (32, 21, 23)
        if len(self.test_suites) != len(expected_counts):
            return (), ["R11 exact test suite count differs"]
        for suite, expected_count in zip(self.test_suites, expected_counts):
            try:
                payload = self._checkpoint_bytes(source, suite.path)
            except ValueError as error:
                errors.append(str(error))
                continue
            methods, method_errors = self._suite_methods(payload, suite)
            errors.extend(method_errors)
            if len(methods) != expected_count:
                errors.append(
                    f"R11 {suite.class_name} test count differs: expected "
                    f"{expected_count}, observed {len(methods)}"
                )
            identifiers.extend(
                f"{suite.module}.{suite.class_name}.{method}"
                for method in sorted(methods)
            )
        if len(identifiers) != EXPECTED_SELECTED_TEST_COUNT:
            errors.append(
                "R11 checkpoint selected test count differs: expected 76, "
                f"observed {len(identifiers)}"
            )
        if len(set(identifiers)) != len(identifiers):
            errors.append("R11 checkpoint selected test identifiers repeat")
        return tuple(identifiers), errors

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

    @staticmethod
    def _directory_flags() -> int:
        return (
            os.O_RDONLY
            | os.O_DIRECTORY
            | os.O_NOFOLLOW
            | getattr(os, "O_CLOEXEC", 0)
        )

    @classmethod
    def _open_directory_at(
        cls,
        parent_descriptor: int,
        name: str,
        *,
        context: str,
    ) -> int:
        if not name or name in {".", ".."} or "/" in name or "\x00" in name:
            raise ValueError(f"{context} directory component is unsafe")
        descriptor = -1
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
            or cls._stat_identity(before) != cls._stat_identity(opened)
            or cls._stat_identity(opened) != cls._stat_identity(after)
        ):
            os.close(descriptor)
            raise ValueError(f"{context} directory ancestor identity differs")
        return descriptor

    def _open_repository_directory(
        self,
        relative: Path,
        *,
        context: str,
    ) -> int:
        value = _safe_relative_path(relative.as_posix(), f"{context} path")
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
            for part in PurePosixPath(value).parts:
                child = self._open_directory_at(
                    descriptor, part, context=context
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
        return (
            self._open_repository_directory(
                Path(*parts[:-1]), context=context
            ),
            parts[-1],
        )

    @classmethod
    def _read_regular_at(
        cls,
        parent_descriptor: int,
        name: str,
        *,
        context: str,
        maximum: int,
        require_read_only: bool = False,
        allow_git_materialized: bool = False,
    ) -> bytes:
        if not name or name in {".", ".."} or "/" in name or "\x00" in name:
            raise ValueError(f"{context} file name is unsafe")
        descriptor = -1
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
                and stat.S_IMODE(before.st_mode)
                not in (
                    {0o400, 0o444, 0o644}
                    if allow_git_materialized
                    else {0o400}
                )
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
            identity = cls._stat_identity(before)
            if (
                cls._stat_identity(opened) != identity
                or cls._stat_identity(after_open) != identity
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
            if (
                cls._stat_identity(os.fstat(descriptor)) != identity
                or cls._stat_identity(
                    os.stat(
                        name,
                        dir_fd=parent_descriptor,
                        follow_symlinks=False,
                    )
                )
                != identity
            ):
                raise ValueError(f"{context} changed while being read")
            return b"".join(chunks)
        except OSError as error:
            raise ValueError(f"{context} cannot be read safely") from error
        finally:
            if descriptor >= 0:
                os.close(descriptor)

    def _read_repository_file(
        self,
        relative: Path,
        *,
        context: str,
        maximum: int,
        require_read_only: bool = False,
        allow_git_materialized: bool = False,
    ) -> bytes:
        parent_descriptor = -1
        try:
            parent_descriptor, name = self._open_repository_parent(
                relative, context=context
            )
            return self._read_regular_at(
                parent_descriptor,
                name,
                context=context,
                maximum=maximum,
                require_read_only=require_read_only,
                allow_git_materialized=allow_git_materialized,
            )
        finally:
            if parent_descriptor >= 0:
                os.close(parent_descriptor)

    def _read_input_file(
        self,
        path: Path,
        *,
        context: str,
        maximum: int,
        require_read_only: bool = False,
    ) -> bytes:
        absolute = path if path.is_absolute() else Path.cwd() / path
        absolute = Path(os.path.abspath(os.fspath(absolute)))
        parts = absolute.parent.parts
        if not parts or parts[0] != os.sep:
            raise ValueError(f"{context} absolute path is invalid")
        descriptor = -1
        try:
            descriptor = os.open(os.sep, self._directory_flags())
            for part in parts[1:]:
                child = self._open_directory_at(
                    descriptor, part, context=context
                )
                os.close(descriptor)
                descriptor = child
            return self._read_regular_at(
                descriptor,
                absolute.name,
                context=context,
                maximum=maximum,
                require_read_only=require_read_only,
            )
        finally:
            if descriptor >= 0:
                os.close(descriptor)

    def _open_input_directory(self, path: Path, *, context: str) -> int:
        absolute = path if path.is_absolute() else Path.cwd() / path
        absolute = Path(os.path.abspath(os.fspath(absolute)))
        parts = absolute.parts
        if not parts or parts[0] != os.sep:
            raise ValueError(f"{context} absolute path is invalid")
        descriptor = os.open(os.sep, self._directory_flags())
        try:
            for part in parts[1:]:
                child = self._open_directory_at(
                    descriptor, part, context=context
                )
                os.close(descriptor)
                descriptor = child
            return descriptor
        except BaseException:
            os.close(descriptor)
            raise

    def _checkpoint_json(
        self,
        source: Mapping[str, str],
        relative: Path,
        context: str,
    ) -> dict[str, Any]:
        return _decode_object(self._checkpoint_bytes(source, relative), context)

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

    def _expected_run_source_files(
        self,
        source: Mapping[str, str],
    ) -> list[dict[str, object]]:
        values: list[dict[str, object]] = []
        seen_roles: set[str] = set()
        seen_paths: set[Path] = set()
        for role, relative in SOURCE_FILE_ROLES:
            if role in seen_roles or relative in seen_paths:
                raise ValueError("R11 run source-file role inventory repeats")
            seen_roles.add(role)
            seen_paths.add(relative)
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
    def _expected_run_summary(
        typed: R11ExecutionReceipt,
    ) -> dict[str, object]:
        counts = typed.aggregate.state_counts.to_document()
        return {
            "record_count": len(typed.observations),
            "counts": counts,
            "aggregate_state": typed.aggregate.aggregate_state.value,
        }

    def _validate_run(
        self,
        run_root: Path,
        source: Mapping[str, str],
        *,
        imported_artifact_directory: bool = False,
    ) -> tuple[RunEvidence | None, list[str]]:
        errors: list[str] = []
        descriptor = -1
        try:
            descriptor = self._open_input_directory(
                run_root, context="R11 traceability run root"
            )
            before = os.fstat(descriptor)
            names_before = tuple(sorted(os.listdir(descriptor)))
            expected_names = (
                ("traceability-run-receipt.json", "unittest.log")
                if imported_artifact_directory
                else ("traceability-run-receipt.json",)
            )
            if names_before != expected_names:
                errors.append("R11 traceability run file closure differs")
            try:
                receipt_payload = self._read_regular_at(
                    descriptor,
                    "traceability-run-receipt.json",
                    context="R11 traceability run receipt",
                    maximum=_MAX_JSON_BYTES,
                    require_read_only=True,
                    allow_git_materialized=imported_artifact_directory,
                )
            except ValueError as error:
                errors.append(str(error))
                return None, sorted(set(errors))
            names_after = tuple(sorted(os.listdir(descriptor)))
            after = os.fstat(descriptor)
            if (
                names_after != names_before
                or self._stat_identity(after) != self._stat_identity(before)
            ):
                errors.append("R11 traceability run root changed during import")
        except (OSError, ValueError) as error:
            errors.append(str(error))
            return None, sorted(set(errors))
        finally:
            if descriptor >= 0:
                os.close(descriptor)

        try:
            receipt = _decode_object(
                receipt_payload, "R11 traceability run receipt"
            )
            if canonical_json_file_bytes_r11(receipt) != receipt_payload:
                errors.append(
                    "R11 traceability run receipt bytes are not canonical"
                )
        except (R11TraceabilityError, ValueError) as error:
            errors.append(f"R11 traceability run receipt is invalid: {error}")
            return None, sorted(set(errors))

        try:
            schema = self._checkpoint_json(
                source,
                RUN_RECEIPT_SCHEMA_PATH,
                "R11 traceability run receipt schema",
            )
        except ValueError as error:
            errors.append(str(error))
            schema = {}
        if schema:
            errors.extend(
                self._schema_errors(
                    schema, receipt, "R11 traceability run receipt schema"
                )
            )

        expected_header = {
            "schema_version": "1.0.0",
            "roadmap_version": "1.0.1",
            "phase_id": "R11",
            "artifact_kind": "r11_traceability_run_receipt",
            "source": dict(source),
            "result_status": "succeeded",
            "comparison_policy": dict(COMPARISON_POLICY),
            "limitations": dict(RUN_LIMITATIONS),
        }
        for field, expected in expected_header.items():
            if receipt.get(field) != expected:
                errors.append(
                    f"R11 traceability run receipt field differs: {field}"
                )
        expected_predecessor = {
            **PREDECESSOR_BINDING,
            "acceptance": "accepted",
        }
        if receipt.get("predecessor_binding") != expected_predecessor:
            errors.append("R11 traceability predecessor binding differs")
        try:
            expected_source_files = self._expected_run_source_files(source)
        except ValueError as error:
            errors.append(str(error))
            expected_source_files = []
        if receipt.get("source_files") != expected_source_files:
            errors.append("R11 traceability source-file bindings differ")

        nested = receipt.get("execution_receipt")
        expected_nested_sha = receipt.get("execution_receipt_sha256")
        typed: R11ExecutionReceipt | None = None
        try:
            nested_payload = canonical_json_file_bytes_r11(nested)
            typed = reopen_execution_receipt_r11(
                nested_payload,
                expected_sha256=(
                    expected_nested_sha
                    if type(expected_nested_sha) is str
                    else None
                ),
            )
        except R11TraceabilityError as error:
            errors.append(f"R11 nested execution receipt is invalid: {error}")
        if typed is not None:
            if typed.to_document() != nested:
                errors.append("R11 nested typed execution receipt differs")
            if typed.identity.source.to_document() != dict(source):
                errors.append("R11 nested execution source binding differs")
            expected_ids = (
                "observation-absent",
                "observation-failed",
                "observation-not-applicable",
                "observation-not-observed",
                "observation-observed",
            )
            if (
                tuple(item.observation_id for item in typed.observations)
                != expected_ids
                or typed.aggregate.expected_observation_ids != expected_ids
                or typed.aggregate.state_counts.to_document()
                != {
                    "observed": 1,
                    "not_applicable": 1,
                    "not_observed": 1,
                    "failed": 1,
                    "absent": 1,
                }
                or typed.aggregate.aggregate_state.value != "mixed"
            ):
                errors.append(
                    "R11 five-state observation and aggregate closure differs"
                )
            decision = typed.claim_decision
            if (
                decision.permitted_claim
                is not R11ClaimToken.SOFTWARE_BEHAVIOR_REPORT
                or decision.disposition
                is not R11ClaimDisposition.NO_MARKET_CLAIM
                or decision.product_qualification
                is not R11BoundaryState.BLOCKED
                or decision.production_auto_mode
                is not R11BoundaryState.BLOCKED
                or decision.market_position
                is not R11BoundaryState.BLOCKED
                or decision.market_leading_claim
                is not R11BoundaryState.BLOCKED
            ):
                errors.append("R11 typed claim and authority boundary differs")
        if errors or typed is None:
            return None, sorted(set(errors))
        return RunEvidence(receipt, receipt_payload, typed), []

    @staticmethod
    def _test_log_errors(
        payload: bytes,
        expected_identifiers: Sequence[str],
    ) -> list[str]:
        if (
            type(payload) is not bytes
            or not payload
            or len(payload) > _MAX_LOG_BYTES
            or b"\x00" in payload
            or b"\r" in payload
        ):
            return ["R11 unittest log bytes are outside the closed boundary"]
        try:
            text = payload.decode("utf-8")
        except UnicodeDecodeError:
            return ["R11 unittest log is not UTF-8"]
        errors = _privacy_errors(text, "R11 unittest log")
        observed: list[str] = []
        statuses: list[str] = []
        summaries: list[int] = []
        for line in text.splitlines():
            result = _TEST_RESULT_PATTERN.fullmatch(line)
            if result is not None:
                method, container, status_value = result.groups()
                observed.append(f"{container}.{method}")
                statuses.append(status_value)
            summary = _RUN_SUMMARY_PATTERN.fullmatch(line)
            if summary is not None:
                summaries.append(int(summary.group(1)))
        if tuple(observed) != tuple(expected_identifiers):
            errors.append("R11 unittest log exact 76-test inventory differs")
        if len(set(observed)) != len(observed):
            errors.append("R11 unittest log repeats a test result")
        if statuses != ["ok"] * EXPECTED_SELECTED_TEST_COUNT:
            errors.append("R11 unittest log contains a failure, error, or skip")
        if summaries != [EXPECTED_SELECTED_TEST_COUNT]:
            errors.append(
                "R11 unittest log summary does not record exactly 76 tests"
            )
        stripped = [line.strip() for line in text.splitlines() if line.strip()]
        if stripped.count("OK") != 1 or any(
            line.startswith("FAILED")
            or line.startswith("OK (")
            or "failures=" in line
            or "errors=" in line
            or "skipped=" in line
            for line in stripped
        ):
            errors.append("R11 unittest log does not record one zero-exception OK")
        return errors

    def _current_source_errors(
        self,
        source: Mapping[str, str],
    ) -> list[str]:
        errors: list[str] = []
        seen_ids: set[str] = set()
        seen_paths: set[Path] = set()
        for context, values in (
            ("contract", self.contract_paths),
            ("implementation", self.implementation_paths),
        ):
            for identifier, relative in values:
                if identifier in seen_ids or relative in seen_paths:
                    errors.append(f"R11 {context} binding inventory repeats")
                    continue
                seen_ids.add(identifier)
                seen_paths.add(relative)
                try:
                    checkpoint = self._checkpoint_bytes(source, relative)
                    current = self._read_repository_file(
                        relative,
                        context=f"R11 current source {relative.as_posix()}",
                        maximum=_MAX_SOURCE_BLOB_BYTES,
                    )
                except ValueError as error:
                    errors.append(str(error))
                    continue
                if current != checkpoint:
                    errors.append(
                        "R11 current source differs from implementation commit: "
                        f"{relative.as_posix()}"
                    )
        return errors

    def _base_errors(
        self,
        source: Mapping[str, str],
        *,
        require_current_source: bool,
    ) -> list[str]:
        errors = self._source_errors(dict(source))
        if errors:
            return errors
        for _identifier, relative in (
            *self.contract_paths,
            *self.implementation_paths,
        ):
            try:
                self._checkpoint_bytes(source, relative)
            except ValueError as error:
                errors.append(str(error))
        _identifiers, inventory_errors = self._checkpoint_test_inventory(source)
        errors.extend(inventory_errors)
        if require_current_source:
            errors.extend(self._current_source_errors(source))
            contract_verifier = R11ContractVerifier(self.root)
            errors.extend(contract_verifier.check_preregistration())
            errors.extend(contract_verifier.check_fixtures())
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
        value: dict[str, object] = {}
        if identifier is not None:
            value["id"] = identifier
        value.update(
            {
                "path": path.as_posix(),
                "size_bytes": len(payload),
                "sha256": _sha256(payload),
            }
        )
        return value

    def expected_execution_receipt(
        self,
        *,
        source: Mapping[str, str],
        test_execution: TestExecution,
        run_evidence: RunEvidence,
    ) -> dict[str, object]:
        return {
            "schema_version": "1.0.0",
            "roadmap_version": "1.0.1",
            "phase_id": "R11",
            "evidence_kind": "r11_deterministic_functional_execution_receipt_v1",
            "source": dict(source),
            "predecessor_binding": dict(PREDECESSOR_BINDING),
            "contract_bindings": self.contract_bindings(source),
            "implementation_bindings": self.implementation_bindings(source),
            "artifact_bindings": [
                self._payload_binding(
                    UNITTEST_LOG_PATH,
                    test_execution.log_payload,
                    identifier="unittest_log",
                ),
                self._payload_binding(
                    RUN_RECEIPT_PATH,
                    run_evidence.receipt_payload,
                    identifier="canonical_traceability_run_receipt",
                ),
                self._payload_binding(
                    RUN_RECEIPT_ARTIFACT_PATH,
                    run_evidence.receipt_payload,
                    identifier="traceability_run_receipt_artifact",
                ),
            ],
            "test_execution": {
                "selected_test_count": EXPECTED_SELECTED_TEST_COUNT,
                "passed_test_count": EXPECTED_SELECTED_TEST_COUNT,
                "failed_test_count": 0,
                "skipped_test_count": 0,
            },
            "run_summary": self._expected_run_summary(
                run_evidence.typed_execution
            ),
            "acceptance_basis": "software_does_what_it_says_it_does",
            "claim_boundary": dict(CLAIM_BOUNDARY),
            "comparison_policy": dict(COMPARISON_POLICY),
            "limitations": list(EXECUTION_LIMITATIONS),
        }

    def expected_acceptance(
        self,
        *,
        source: Mapping[str, str],
        execution_receipt_payload: bytes,
        run_receipt_payload: bytes,
        phase_status_before: str,
    ) -> dict[str, object]:
        if phase_status_before not in {"in_progress", "evidence_ready"}:
            raise ValueError(
                "R11 phase status before acceptance must be in_progress or "
                "evidence_ready"
            )
        return {
            "schema_version": "1.0.0",
            "roadmap_version": "1.0.1",
            "phase_id": "R11",
            "evidence_kind": "r11_operator_functional_phase_acceptance_v1",
            "source": dict(source),
            "execution_receipt_binding": self._payload_binding(
                EXECUTION_RECEIPT_PATH, execution_receipt_payload
            ),
            "run_receipt_binding": self._payload_binding(
                RUN_RECEIPT_PATH, run_receipt_payload
            ),
            "checks": [
                {"id": identifier, "status": "passed"}
                for identifier in DERIVED_CHECK_IDS
            ],
            "functional_gate": {
                "status": "passed",
                "acceptance_basis": "software_does_what_it_says_it_does",
                "acceptance_scope": "declared_software_function_only",
                "phase_status_before": phase_status_before,
                "phase_status_after": "passed",
            },
            "claim_boundary": dict(CLAIM_BOUNDARY),
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

    def _roadmap_phase_status(self) -> str | None:
        try:
            value = _decode_object(
                self._read_repository_file(
                    ROADMAP_PATH,
                    context="canonical roadmap",
                    maximum=_MAX_JSON_BYTES,
                ),
                "canonical roadmap",
            )
        except ValueError:
            return None
        phases = value.get("phases")
        if type(phases) is not list:
            return None
        selected = [
            item
            for item in phases
            if type(item) is dict and item.get("id") == "R11"
        ]
        if len(selected) != 1:
            return None
        status = selected[0].get("status")
        return status if type(status) is str else None

    def _repository_entry_state(
        self,
        relative: Path,
        *,
        expected_directory: bool,
        context: str,
    ) -> str:
        absolute = self.root / relative
        try:
            os.lstat(absolute)
        except FileNotFoundError:
            return "absent"
        except OSError as error:
            raise ValueError(f"{context} cannot be inspected") from error
        if expected_directory:
            descriptor = self._open_repository_directory(
                relative, context=context
            )
            os.close(descriptor)
            return "present"
        parent_descriptor = -1
        try:
            parent_descriptor, name = self._open_repository_parent(
                relative, context=context
            )
            value = os.stat(
                name,
                dir_fd=parent_descriptor,
                follow_symlinks=False,
            )
            if not stat.S_ISREG(value.st_mode) or value.st_nlink != 1:
                raise ValueError(
                    f"{context} must be one regular no-follow single-link file"
                )
            return "present"
        except OSError as error:
            raise ValueError(f"{context} cannot be inspected") from error
        finally:
            if parent_descriptor >= 0:
                os.close(parent_descriptor)

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
                parent_descriptor, name, context=context
            ),
            created,
        )

    @classmethod
    def _publish_payload_at(
        cls,
        parent_descriptor: int,
        name: str,
        payload: bytes,
        *,
        mode: int,
        context: str,
    ) -> None:
        if (
            not name
            or name in {".", ".."}
            or "/" in name
            or "\x00" in name
            or not payload
        ):
            raise ValueError(f"{context} publication input is unsafe")
        descriptor = -1
        created = False
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
            value = os.fstat(descriptor)
            if (
                not stat.S_ISREG(value.st_mode)
                or value.st_nlink != 1
                or value.st_size != len(payload)
                or stat.S_IMODE(value.st_mode) != mode
            ):
                raise ValueError(f"{context} did not publish exactly")
            os.close(descriptor)
            descriptor = -1
            reopened = cls._read_regular_at(
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
    def _remove_tree_at(cls, parent_descriptor: int, name: str) -> None:
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
            parent_descriptor, name, context="R11 rollback"
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
                relative, context=context
            )
            expected = os.fstat(descriptor)
            observed = os.fstat(reopened)
            return (expected.st_dev, expected.st_ino) == (
                observed.st_dev,
                observed.st_ino,
            )
        except (OSError, ValueError):
            return False
        finally:
            if reopened >= 0:
                os.close(reopened)

    def _write_bundle(
        self,
        *,
        run_receipt_payload: bytes,
        log_payload: bytes,
        execution_payload: bytes,
        acceptance_payload: bytes,
    ) -> list[str]:
        records_descriptor = -1
        artifact_parent_descriptor = -1
        artifact_descriptor = -1
        artifact_parent_created = False
        artifact_directory_created = False
        published_record_names: list[str] = []
        try:
            records_descriptor = self._open_repository_directory(
                RECORDS_DIRECTORY,
                context="R11 evidence records directory",
            )
            for name, context in (
                (
                    RUN_RECEIPT_PATH.name,
                    "R11 canonical traceability run receipt",
                ),
                (
                    EXECUTION_RECEIPT_PATH.name,
                    "R11 functional execution receipt",
                ),
                (
                    ACCEPTANCE_PATH.name,
                    "R11 functional phase acceptance",
                ),
            ):
                try:
                    os.stat(
                        name,
                        dir_fd=records_descriptor,
                        follow_symlinks=False,
                    )
                except FileNotFoundError:
                    continue
                except OSError as error:
                    raise ValueError(f"{context} cannot be inspected") from error
                raise ValueError(
                    "R11 generated acceptance outputs already exist; validate "
                    "them with --check-generated"
                )
            artifact_parent_descriptor, artifact_parent_created = (
                self._ensure_directory_at(
                    records_descriptor,
                    ARTIFACT_DIRECTORY.parent.name,
                    context="R11 evidence artifact parent",
                )
            )
            try:
                os.stat(
                    ARTIFACT_DIRECTORY.name,
                    dir_fd=artifact_parent_descriptor,
                    follow_symlinks=False,
                )
            except FileNotFoundError:
                pass
            except OSError as error:
                raise ValueError(
                    "R11 functional acceptance artifact target cannot be inspected"
                ) from error
            else:
                raise ValueError(
                    "R11 generated acceptance outputs already exist; validate "
                    "them with --check-generated"
                )
            artifact_descriptor, artifact_directory_created = (
                self._ensure_directory_at(
                    artifact_parent_descriptor,
                    ARTIFACT_DIRECTORY.name,
                    context="R11 functional acceptance artifacts",
                )
            )
            self._publish_payload_at(
                artifact_descriptor,
                UNITTEST_LOG_PATH.name,
                log_payload,
                mode=0o400,
                context="R11 unittest log artifact",
            )
            self._publish_payload_at(
                artifact_descriptor,
                RUN_RECEIPT_ARTIFACT_PATH.name,
                run_receipt_payload,
                mode=0o400,
                context="R11 traceability run receipt artifact",
            )
            for name, payload, mode, context in (
                (
                    RUN_RECEIPT_PATH.name,
                    run_receipt_payload,
                    0o400,
                    "R11 canonical traceability run receipt",
                ),
                (
                    EXECUTION_RECEIPT_PATH.name,
                    execution_payload,
                    0o644,
                    "R11 functional execution receipt",
                ),
                (
                    ACCEPTANCE_PATH.name,
                    acceptance_payload,
                    0o644,
                    "R11 functional phase acceptance",
                ),
            ):
                self._publish_payload_at(
                    records_descriptor,
                    name,
                    payload,
                    mode=mode,
                    context=context,
                )
                published_record_names.append(name)
            if (
                not self._repository_directory_matches(
                    RECORDS_DIRECTORY,
                    records_descriptor,
                    context="R11 evidence records directory",
                )
                or not self._repository_directory_matches(
                    ARTIFACT_DIRECTORY.parent,
                    artifact_parent_descriptor,
                    context="R11 evidence artifact parent",
                )
                or not self._repository_directory_matches(
                    ARTIFACT_DIRECTORY,
                    artifact_descriptor,
                    context="R11 functional acceptance artifacts",
                )
                or self._read_repository_file(
                    RUN_RECEIPT_PATH,
                    context="R11 published canonical run receipt",
                    maximum=_MAX_JSON_BYTES,
                    require_read_only=True,
                )
                != run_receipt_payload
                or self._read_repository_file(
                    RUN_RECEIPT_ARTIFACT_PATH,
                    context="R11 published run receipt artifact",
                    maximum=_MAX_JSON_BYTES,
                    require_read_only=True,
                )
                != run_receipt_payload
                or self._read_repository_file(
                    UNITTEST_LOG_PATH,
                    context="R11 published unittest log",
                    maximum=_MAX_LOG_BYTES,
                    require_read_only=True,
                )
                != log_payload
            ):
                raise ValueError(
                    "R11 evidence publication ancestor identity or bytes changed"
                )
            return []
        except (OSError, ValueError) as error:
            if records_descriptor >= 0:
                for name in reversed(published_record_names):
                    try:
                        os.unlink(name, dir_fd=records_descriptor)
                    except OSError:
                        pass
            if (
                artifact_directory_created
                and artifact_parent_descriptor >= 0
            ):
                try:
                    self._remove_tree_at(
                        artifact_parent_descriptor, ARTIFACT_DIRECTORY.name
                    )
                except (OSError, ValueError):
                    pass
            if artifact_parent_created and records_descriptor >= 0:
                try:
                    os.rmdir(
                        ARTIFACT_DIRECTORY.parent.name,
                        dir_fd=records_descriptor,
                    )
                except OSError:
                    pass
            return [f"R11 evidence output transaction failed: {error}"]
        finally:
            for descriptor in (
                artifact_descriptor,
                artifact_parent_descriptor,
                records_descriptor,
            ):
                if descriptor >= 0:
                    os.close(descriptor)

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
            "R11 functional execution receipt",
            errors,
        )
        acceptance_record = self._read_generated_json(
            ACCEPTANCE_PATH,
            "R11 functional phase acceptance",
            errors,
        )
        try:
            canonical_run_payload = self._read_repository_file(
                RUN_RECEIPT_PATH,
                context="R11 canonical traceability run receipt",
                maximum=_MAX_JSON_BYTES,
                require_read_only=True,
                allow_git_materialized=True,
            )
            artifact_run_payload = self._read_repository_file(
                RUN_RECEIPT_ARTIFACT_PATH,
                context="R11 traceability run receipt artifact",
                maximum=_MAX_JSON_BYTES,
                require_read_only=True,
                allow_git_materialized=True,
            )
            log_payload = self._read_repository_file(
                UNITTEST_LOG_PATH,
                context="R11 unittest log artifact",
                maximum=_MAX_LOG_BYTES,
                require_read_only=True,
                allow_git_materialized=True,
            )
        except ValueError as error:
            errors.append(str(error))
            return sorted(set(errors))
        if canonical_run_payload != artifact_run_payload:
            errors.append(
                "R11 canonical and artifact run receipt bytes differ"
            )
        if execution_record is None or acceptance_record is None:
            return sorted(set(errors))
        execution, execution_payload = execution_record
        acceptance, acceptance_payload = acceptance_record
        source_value = execution.get("source")
        source_errors = self._source_errors(source_value)
        errors.extend(source_errors)
        if source_errors or type(source_value) is not dict:
            return sorted(set(errors))
        source = {
            "commit": str(source_value["commit"]),
            "tree": str(source_value["tree"]),
        }
        errors.extend(
            self._base_errors(source, require_current_source=True)
        )
        identifiers, inventory_errors = self._checkpoint_test_inventory(source)
        errors.extend(inventory_errors)
        errors.extend(self._test_log_errors(log_payload, identifiers))
        run_evidence, run_errors = self._validate_run(
            self.root / ARTIFACT_DIRECTORY,
            source,
            imported_artifact_directory=True,
        )
        errors.extend(run_errors)
        if run_evidence is None:
            return sorted(set(errors))
        if run_evidence.receipt_payload != canonical_run_payload:
            errors.append(
                "R11 canonical run receipt is not the validated artifact copy"
            )
        try:
            execution_schema = self._checkpoint_json(
                source,
                EXECUTION_RECEIPT_SCHEMA_PATH,
                "R11 functional execution receipt schema",
            )
            acceptance_schema = self._checkpoint_json(
                source,
                ACCEPTANCE_SCHEMA_PATH,
                "R11 functional phase acceptance schema",
            )
        except ValueError as error:
            errors.append(str(error))
            return sorted(set(errors))
        errors.extend(
            self._schema_errors(
                execution_schema,
                execution,
                "R11 functional execution receipt schema",
            )
        )
        errors.extend(
            self._schema_errors(
                acceptance_schema,
                acceptance,
                "R11 functional phase acceptance schema",
            )
        )
        expected_execution = self.expected_execution_receipt(
            source=source,
            test_execution=TestExecution(identifiers, log_payload),
            run_evidence=run_evidence,
        )
        if execution != expected_execution:
            errors.append(
                "R11 functional execution receipt is not exactly derived "
                "from the implementation checkpoint and run closure"
            )
        if execution_payload != self._json_payload(expected_execution):
            errors.append(
                "R11 functional execution receipt bytes are not canonical "
                "for the derived record"
            )
        gate = acceptance.get("functional_gate")
        phase_status_before = (
            gate.get("phase_status_before")
            if type(gate) is dict
            else None
        )
        try:
            expected_acceptance = self.expected_acceptance(
                source=source,
                execution_receipt_payload=execution_payload,
                run_receipt_payload=canonical_run_payload,
                phase_status_before=(
                    phase_status_before
                    if type(phase_status_before) is str
                    else ""
                ),
            )
        except ValueError as error:
            errors.append(str(error))
            expected_acceptance = {}
        if acceptance != expected_acceptance:
            errors.append(
                "R11 functional phase acceptance is not exactly derived "
                "from the software-function evidence"
            )
        if acceptance_payload != self._json_payload(expected_acceptance):
            errors.append(
                "R11 functional phase acceptance bytes are not canonical "
                "for the derived record"
            )
        return sorted(set(errors))

    def check(self) -> list[str]:
        targets = (
            (
                RUN_RECEIPT_PATH,
                False,
                "R11 canonical traceability run receipt",
            ),
            (
                EXECUTION_RECEIPT_PATH,
                False,
                "R11 functional execution receipt",
            ),
            (
                ACCEPTANCE_PATH,
                False,
                "R11 functional phase acceptance",
            ),
            (
                ARTIFACT_DIRECTORY,
                True,
                "R11 functional acceptance artifact directory",
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
        present = tuple(state == "present" for state in states)
        if not any(present):
            status = self._roadmap_phase_status()
            if status in {"planned", "in_progress", "evidence_ready"}:
                return []
            return [
                "R11 generated acceptance evidence is absent while canonical "
                f"phase status is {status!r}"
            ]
        if not all(present):
            return ["R11 generated acceptance evidence is only partially present"]
        return self.check_generated()

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
        errors = self._base_errors(source, require_current_source=True)
        status = self._roadmap_phase_status()
        if status not in {"in_progress", "evidence_ready"}:
            errors.append(
                "R11 evidence can only be derived while canonical phase status "
                "is in_progress or evidence_ready"
            )
        identifiers, inventory_errors = self._checkpoint_test_inventory(source)
        errors.extend(inventory_errors)
        try:
            log_payload = self._read_input_file(
                test_log,
                context="R11 input unittest log",
                maximum=_MAX_LOG_BYTES,
            )
        except ValueError as error:
            errors.append(str(error))
            log_payload = b""
        errors.extend(self._test_log_errors(log_payload, identifiers))
        run_evidence, run_errors = self._validate_run(run_root, source)
        errors.extend(run_errors)
        if errors or run_evidence is None or status is None:
            return sorted(set(errors))
        execution = self.expected_execution_receipt(
            source=source,
            test_execution=TestExecution(identifiers, log_payload),
            run_evidence=run_evidence,
        )
        execution_payload = self._json_payload(execution)
        try:
            acceptance = self.expected_acceptance(
                source=source,
                execution_receipt_payload=execution_payload,
                run_receipt_payload=run_evidence.receipt_payload,
                phase_status_before=status,
            )
        except ValueError as error:
            return [str(error)]
        acceptance_payload = self._json_payload(acceptance)
        try:
            execution_schema = self._checkpoint_json(
                source,
                EXECUTION_RECEIPT_SCHEMA_PATH,
                "R11 functional execution receipt schema",
            )
            acceptance_schema = self._checkpoint_json(
                source,
                ACCEPTANCE_SCHEMA_PATH,
                "R11 functional phase acceptance schema",
            )
        except ValueError as error:
            return [str(error)]
        errors.extend(
            self._schema_errors(
                execution_schema,
                execution,
                "R11 functional execution receipt schema",
            )
        )
        errors.extend(
            self._schema_errors(
                acceptance_schema,
                acceptance,
                "R11 functional phase acceptance schema",
            )
        )
        if errors:
            return sorted(set(errors))
        errors.extend(
            self._write_bundle(
                run_receipt_payload=run_evidence.receipt_payload,
                log_payload=log_payload,
                execution_payload=execution_payload,
                acceptance_payload=acceptance_payload,
            )
        )
        if errors:
            return sorted(set(errors))
        return self.check_generated()


def emit_errors(errors: Iterable[str]) -> int:
    values = list(dict.fromkeys(errors))
    for error in values:
        print(f"ERROR: {error}", file=sys.stderr)
    return 1 if values else 0


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
    verifier = R11PhaseAcceptanceVerifier(REPOSITORY_ROOT)
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
        print("R11 functional phase acceptance: PASS")
    return emit_errors(errors)


if __name__ == "__main__":
    raise SystemExit(main())
