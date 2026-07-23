from __future__ import annotations

import copy
from contextlib import redirect_stderr, redirect_stdout
import hashlib
from io import StringIO
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPOSITORY_ROOT))
sys.path.insert(0, str(REPOSITORY_ROOT / "Scripts"))

from phase_evidence import validate_json_schema_instance  # noqa: E402
from r10_contracts import (  # noqa: E402
    CANDIDATE_IDS,
    CATALOG_PATHS,
    CAUSAL_VARIABLE_NAMES,
    CHECK_IDS,
    CONSTRAINT_ORDER,
    EVALUATION_CATALOG_PATH,
    EVALUATION_CATALOG_RAW_SHA256,
    EVALUATION_CATALOG_SCHEMA_PATH,
    EVALUATION_CATALOG_SEMANTIC_SHA256,
    EVALUATOR_SEMANTIC_SHA256,
    FIXTURE_CATALOG_PATH,
    FIXTURE_CATALOG_RAW_SHA256,
    FIXTURE_CATALOG_SCHEMA_PATH,
    FIXTURE_CATALOG_SEMANTIC_SHA256,
    IMPLEMENTATION_PATHS,
    MAX_CONTRACT_BYTES,
    PHASE_ACCEPTANCE_PATH,
    POLICY_CATALOG_PATH,
    POLICY_CATALOG_RAW_SHA256,
    POLICY_CATALOG_SCHEMA_PATH,
    POLICY_CATALOG_SEMANTIC_SHA256,
    PREDECESSOR_BINDINGS,
    PREREGISTRATION_PATH,
    PREREGISTRATION_RAW_SHA256,
    PREREGISTRATION_SCHEMA_PATH,
    PREREGISTRATION_SEMANTIC_SHA256,
    R10ContractError,
    R10ContractVerifier,
    ROADMAP_PATH,
    SCHEMA_PATHS,
    SCORE_DIMENSION_ORDER,
    STOP_RULE_IDS,
    VALID_CANDIDATE_IDS,
    main,
    parse_evaluation_catalog_r10,
    parse_fixture_catalog_r10,
    parse_policy_catalog_r10,
)
from validation.calibration_v2.r10_optimizer import (  # noqa: E402
    R10AttemptDisposition,
    R10ProcessingIdentity,
    R10RunStatus,
    optimize_r10,
)
from validation.calibration_v2.tests.test_run_r10_fixture_calibration import (  # noqa: E402
    _exact_source_repository,
)
from validation.calibration_v2.tools.run_r10_fixture_calibration import (  # noqa: E402
    run_fixture_calibration,
)


def read_bytes(relative: Path) -> bytes:
    return (REPOSITORY_ROOT / relative).read_bytes()


def read_json(relative: Path) -> dict[str, object]:
    value = json.loads(read_bytes(relative))
    assert isinstance(value, dict)
    return value


def semantic_sha256(value: object) -> str:
    return hashlib.sha256(
        json.dumps(
            value,
            ensure_ascii=False,
            allow_nan=False,
            sort_keys=True,
            separators=(",", ":"),
        ).encode("utf-8")
    ).hexdigest()


def encoded(value: object) -> bytes:
    return (
        json.dumps(value, ensure_ascii=False, allow_nan=False, indent=2)
        + "\n"
    ).encode("utf-8")


class R10ContractTests(unittest.TestCase):
    def setUp(self) -> None:
        self.verifier = R10ContractVerifier(REPOSITORY_ROOT)
        self.preregistration = read_json(PREREGISTRATION_PATH)
        self.fixture = read_json(FIXTURE_CATALOG_PATH)
        self.evaluation = read_json(EVALUATION_CATALOG_PATH)
        self.policy = read_json(POLICY_CATALOG_PATH)

    def temporary_roadmap_root(
        self,
        status: str,
    ) -> tempfile.TemporaryDirectory[str]:
        temporary = tempfile.TemporaryDirectory()
        root = Path(temporary.name)
        roadmap = read_json(ROADMAP_PATH)
        phases = roadmap["phases"]
        assert isinstance(phases, list)
        r10 = next(
            item
            for item in phases
            if isinstance(item, dict) and item.get("id") == "R10"
        )
        r10["status"] = status
        target = root / ROADMAP_PATH
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(encoded(roadmap))
        return temporary

    def test_checked_in_contracts_pass(self) -> None:
        self.assertEqual(self.verifier.check_preregistration(), [])
        self.assertEqual(self.verifier.check_catalogs(), [])
        self.assertEqual(self.verifier.check_roadmap_status(), [])
        self.assertEqual(self.verifier.check(), [])

    def test_cli_checks_all_contracts(self) -> None:
        stdout = StringIO()
        stderr = StringIO()
        with redirect_stdout(stdout), redirect_stderr(stderr):
            result = main(["--all"])
        self.assertEqual(result, 0)
        self.assertEqual(stderr.getvalue(), "")
        for label in (
            "R10 preregistration: PASS",
            "R10 catalogs: PASS",
            "R10 roadmap status: PASS",
        ):
            self.assertIn(label, stdout.getvalue())

    def test_all_seven_schemas_are_closed_draft_2020_12(self) -> None:
        self.assertEqual(len(SCHEMA_PATHS), 7)
        for identifier, path in SCHEMA_PATHS.items():
            with self.subTest(schema=identifier):
                schema = read_json(path)
                self.assertEqual(
                    schema["$schema"],
                    "https://json-schema.org/draft/2020-12/schema",
                )
                self.assertIs(schema["additionalProperties"], False)
                self.assertEqual(schema["type"], "object")

    def test_actual_runner_receipt_matches_closed_run_schema(self) -> None:
        with _exact_source_repository() as (base, repository, commit):
            receipt_path = run_fixture_calibration(
                source_commit=commit,
                output_root=base / "schema-checked-run",
                repository_root=repository,
            )
            receipt = json.loads(receipt_path.read_bytes())
        self.assertEqual(
            validate_json_schema_instance(
                read_json(SCHEMA_PATHS["calibration_run_receipt"]),
                receipt,
            ),
            [],
        )

    def test_future_execution_and_acceptance_schemas_are_satisfiable(self) -> None:
        from Scripts.r10_phase_acceptance import (
            DERIVED_CHECK_IDS,
            FUNCTIONAL_CHECK_IDS,
        )

        source = {"commit": "a" * 40, "tree": "b" * 40}

        def bindings(prefix: str, count: int) -> list[dict[str, object]]:
            return [
                {
                    "id": f"{prefix}-{index:02d}",
                    "path": f"evidence/{prefix}-{index:02d}.json",
                    "size_bytes": index + 1,
                    "sha256": f"{index + 1:064x}",
                }
                for index in range(count)
            ]

        execution_schema = read_json(
            SCHEMA_PATHS["functional_execution_receipt"]
        )
        definitions = execution_schema["$defs"]
        assert isinstance(definitions, dict)
        check_schema = definitions["check"]
        assert isinstance(check_schema, dict)
        check_properties = check_schema["properties"]
        assert isinstance(check_properties, dict)
        id_schema = check_properties["id"]
        assert isinstance(id_schema, dict)
        check_ids = id_schema["enum"]
        assert isinstance(check_ids, list)
        self.assertEqual(tuple(check_ids), FUNCTIONAL_CHECK_IDS)
        test_identifiers = [
            f"R10Tests.test_declared_behavior_{index:02d}"
            for index in range(39)
        ]
        execution = {
            "schema_version": "1.0.0",
            "roadmap_version": "1.0.1",
            "phase_id": "R10",
            "evidence_kind": "r10_deterministic_functional_execution_receipt_v1",
            "source": source,
            "contract_bindings": bindings("contract", 11),
            "implementation_bindings": bindings("implementation", 10),
            "artifact_bindings": bindings("artifact", 13),
            "test_execution": {
                "execution_mode": "deterministic_fixture_simulation",
                "expected_selected_test_count": 39,
                "selected_test_count": 39,
                "passed_test_count": 39,
                "failed_test_count": 0,
                "skipped_test_count": 0,
                "test_identifiers": test_identifiers,
                "command": "python3 -m unittest R10Tests",
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
                    "evidence_tests": [test_identifiers[0]],
                }
                for identifier in check_ids
            ],
            "observation_status": {
                "deterministic_software_execution": "observed",
                "deterministic_fixture_simulation": "observed",
                "physical_hardware_execution": "not_observed",
                "apple_simulator_execution": "not_observed",
                "operator_observed_operation": "not_observed",
            },
            "comparison_policy": {
                "comparative_testing": "not_run_not_required",
                "a_b_testing": "not_run_not_required",
                "superiority_requirement": "not_run_not_required",
                "comparison_acceptance_dependency": "none",
            },
            "acceptance_basis": "software_does_what_it_says_it_does",
            "authorization_boundary": {
                "fixture_policy_publication": "authorized",
                "production_auto": "not_authorized",
                "holdout": "not_authorized",
                "product_publication": "not_authorized",
                "quality_claims": "not_authorized",
                "performance_claims": "not_authorized",
                "release": "not_authorized",
            },
            "limitations": ["Fixture-only deterministic software evidence."],
        }
        self.assertEqual(
            validate_json_schema_instance(execution_schema, execution),
            [],
        )

        raw_binding = {
            "path": "evidence/fixture.json",
            "size_bytes": 1,
            "sha256": "c" * 64,
        }
        acceptance_schema = read_json(
            SCHEMA_PATHS["functional_phase_acceptance"]
        )
        acceptance_definitions = acceptance_schema["$defs"]
        assert isinstance(acceptance_definitions, dict)
        passed_check = acceptance_definitions["passedCheck"]
        assert isinstance(passed_check, dict)
        passed_check_properties = passed_check["properties"]
        assert isinstance(passed_check_properties, dict)
        acceptance_id_schema = passed_check_properties["id"]
        assert isinstance(acceptance_id_schema, dict)
        acceptance_check_ids = acceptance_id_schema["enum"]
        assert isinstance(acceptance_check_ids, list)
        self.assertEqual(tuple(acceptance_check_ids), DERIVED_CHECK_IDS)
        acceptance = {
            "schema_version": "1.0.0",
            "roadmap_version": "1.0.1",
            "phase_id": "R10",
            "evidence_kind": "r10_operator_functional_phase_acceptance_v1",
            "source": source,
            "operator_override": {
                "authority": "operator",
                "acceptance_basis": "software_does_what_it_says_it_does",
                "comparison_requirement": "not_run_not_required",
                "hardware_requirement": "waived_not_a_blocker",
                "simulator_requirement": "waived_not_a_blocker",
                "operator_observation_requirement": "waived_not_a_blocker",
            },
            "execution_receipt_binding": raw_binding,
            "run_receipt_binding": raw_binding,
            "functional_gate": {
                "status": "passed",
                "phase_status_before": "in_progress",
                "phase_status_after": "passed",
                "acceptance": "accepted",
                "acceptance_basis": "software_does_what_it_says_it_does",
                "acceptance_scope": "declared_software_function_only",
                "execution_mode": "deterministic_fixture_simulation",
                "roadmap_exit_outcome": "passed",
            },
            "checks": [
                {"id": identifier, "status": "passed"}
                for identifier in acceptance_check_ids
            ],
            "observation_status": execution["observation_status"],
            "authorization_boundary": {
                "r10_phase_acceptance": "authorized",
                "fixture_policy_evidence_publication": "authorized",
                "production_auto": "not_authorized",
                "holdout": "not_authorized",
                "product_publication": "not_authorized",
                "quality_claims": "not_authorized",
                "performance_claims": "not_authorized",
                "release": "not_authorized",
            },
            "limitations": ["Fixture-only deterministic software evidence."],
        }
        self.assertEqual(
            validate_json_schema_instance(
                acceptance_schema,
                acceptance,
            ),
            [],
        )

        duplicate_execution_check = copy.deepcopy(execution)
        duplicate_checks = duplicate_execution_check["functional_checks"]
        assert isinstance(duplicate_checks, list)
        assert isinstance(duplicate_checks[0], dict)
        assert isinstance(duplicate_checks[1], dict)
        duplicate_checks[1]["id"] = duplicate_checks[0]["id"]
        duplicate_checks[1]["evidence_tests"] = [test_identifiers[1]]
        self.assertTrue(
            validate_json_schema_instance(
                execution_schema,
                duplicate_execution_check,
            )
        )

        forged_test_execution = copy.deepcopy(execution)
        forged_tests = forged_test_execution["test_execution"]
        assert isinstance(forged_tests, dict)
        forged_tests["selected_test_count"] = 38
        forged_tests["test_identifiers"] = [
            test_identifiers[0],
            *test_identifiers[:-1],
        ]
        self.assertTrue(
            validate_json_schema_instance(
                execution_schema,
                forged_test_execution,
            )
        )

        duplicate_acceptance_check = copy.deepcopy(acceptance)
        duplicate_acceptance_checks = duplicate_acceptance_check["checks"]
        assert isinstance(duplicate_acceptance_checks, list)
        assert isinstance(duplicate_acceptance_checks[0], dict)
        assert isinstance(duplicate_acceptance_checks[1], dict)
        duplicate_acceptance_checks[1]["id"] = duplicate_acceptance_checks[0][
            "id"
        ]
        self.assertTrue(
            validate_json_schema_instance(
                acceptance_schema,
                duplicate_acceptance_check,
            )
        )

        for schema, record, key in (
            (execution_schema, execution, "functional_checks"),
            (acceptance_schema, acceptance, "checks"),
        ):
            with self.subTest(record=key, mutation="missing"):
                missing = copy.deepcopy(record)
                values = missing[key]
                assert isinstance(values, list)
                values.pop()
                self.assertTrue(validate_json_schema_instance(schema, missing))
            with self.subTest(record=key, mutation="extra"):
                extra = copy.deepcopy(record)
                values = extra[key]
                assert isinstance(values, list)
                values.append(copy.deepcopy(values[-1]))
                self.assertTrue(validate_json_schema_instance(schema, extra))

    def test_checked_in_start_records_match_schemas(self) -> None:
        for schema_path, instance in (
            (PREREGISTRATION_SCHEMA_PATH, self.preregistration),
            (FIXTURE_CATALOG_SCHEMA_PATH, self.fixture),
            (EVALUATION_CATALOG_SCHEMA_PATH, self.evaluation),
            (POLICY_CATALOG_SCHEMA_PATH, self.policy),
        ):
            with self.subTest(schema=schema_path):
                self.assertEqual(
                    validate_json_schema_instance(
                        read_json(schema_path),
                        instance,
                    ),
                    [],
                )

    def test_raw_and_semantic_record_identities_are_exact(self) -> None:
        expected = (
            (
                PREREGISTRATION_PATH,
                PREREGISTRATION_RAW_SHA256,
                PREREGISTRATION_SEMANTIC_SHA256,
            ),
            (
                FIXTURE_CATALOG_PATH,
                FIXTURE_CATALOG_RAW_SHA256,
                FIXTURE_CATALOG_SEMANTIC_SHA256,
            ),
            (
                EVALUATION_CATALOG_PATH,
                EVALUATION_CATALOG_RAW_SHA256,
                EVALUATION_CATALOG_SEMANTIC_SHA256,
            ),
            (
                POLICY_CATALOG_PATH,
                POLICY_CATALOG_RAW_SHA256,
                POLICY_CATALOG_SEMANTIC_SHA256,
            ),
        )
        for path, raw_sha256, semantic in expected:
            with self.subTest(path=path):
                payload = read_bytes(path)
                value = read_json(path)
                self.assertEqual(hashlib.sha256(payload).hexdigest(), raw_sha256)
                self.assertEqual(semantic_sha256(value), semantic)

    def test_parse_apis_return_typed_closed_contracts(self) -> None:
        fixture, candidates = parse_fixture_catalog_r10(
            read_bytes(FIXTURE_CATALOG_PATH)
        )
        evaluation, catalog = parse_evaluation_catalog_r10(
            read_bytes(EVALUATION_CATALOG_PATH)
        )
        policy = parse_policy_catalog_r10(read_bytes(POLICY_CATALOG_PATH))
        self.assertEqual(fixture, self.fixture)
        self.assertEqual(evaluation, self.evaluation)
        self.assertEqual(policy, self.policy)
        self.assertEqual(
            tuple(candidate.candidate_id for candidate in candidates),
            CANDIDATE_IDS,
        )
        self.assertEqual(
            tuple(item.candidate_id for item in catalog.evaluations),
            VALID_CANDIDATE_IDS,
        )

    def test_raw_evaluation_and_semantic_evaluator_are_separately_bound(self) -> None:
        payload = read_bytes(EVALUATION_CATALOG_PATH)
        _, catalog = parse_evaluation_catalog_r10(payload)
        fixture_binding = self.fixture["evaluation_catalog_binding"]
        assert isinstance(fixture_binding, dict)
        self.assertEqual(
            fixture_binding,
            {
                "path": EVALUATION_CATALOG_PATH.as_posix(),
                "size_bytes": len(payload),
                "sha256": hashlib.sha256(payload).hexdigest(),
            },
        )
        self.assertEqual(
            self.evaluation["evaluator_sha256"],
            EVALUATOR_SEMANTIC_SHA256,
        )
        self.assertEqual(catalog.evaluator_sha256, EVALUATOR_SEMANTIC_SHA256)

    def test_cross_catalog_ranking_dimension_order_is_exact(self) -> None:
        score_contract = self.evaluation["score_contract"]
        assert isinstance(score_contract, dict)
        evaluation_dimensions = score_contract["dimensions"]
        policy_dimensions = self.policy["absolute_score_dimensions"]
        assert isinstance(evaluation_dimensions, list)
        assert isinstance(policy_dimensions, list)
        self.assertEqual(
            tuple(
                item["name"]
                for item in evaluation_dimensions
                if isinstance(item, dict)
            ),
            SCORE_DIMENSION_ORDER,
        )
        self.assertEqual(
            tuple(
                item["name"]
                for item in policy_dimensions
                if isinstance(item, dict)
            ),
            SCORE_DIMENSION_ORDER,
        )

    def test_nine_candidates_cover_six_independent_rejections(self) -> None:
        _, candidates = parse_fixture_catalog_r10(
            read_bytes(FIXTURE_CATALOG_PATH)
        )
        scored = tuple(
            candidate.candidate_id
            for candidate in candidates
            if not candidate.failed_constraints
        )
        rejected = tuple(
            candidate.failed_constraints[0].value
            for candidate in candidates
            if candidate.failed_constraints
        )
        self.assertEqual(scored, VALID_CANDIDATE_IDS)
        self.assertEqual(rejected, CONSTRAINT_ORDER)
        for candidate in candidates[3:]:
            self.assertEqual(len(candidate.failed_constraints), 1)

    def test_candidate_hashes_reconstruct_from_typed_documents(self) -> None:
        _, candidates = parse_fixture_catalog_r10(
            read_bytes(FIXTURE_CATALOG_PATH)
        )
        wrappers = self.fixture["candidates"]
        assert isinstance(wrappers, list)
        self.assertEqual(len(wrappers), len(candidates))
        for wrapper, candidate in zip(wrappers, candidates):
            assert isinstance(wrapper, dict)
            self.assertEqual(
                wrapper["candidate_sha256"],
                candidate.candidate_sha256,
            )
            self.assertEqual(wrapper["candidate"], candidate.to_document())

    def test_catalogs_drive_deterministic_expected_selection(self) -> None:
        _, candidates = parse_fixture_catalog_r10(
            read_bytes(FIXTURE_CATALOG_PATH)
        )
        _, catalog = parse_evaluation_catalog_r10(
            read_bytes(EVALUATION_CATALOG_PATH)
        )
        identity = R10ProcessingIdentity(
            source_commit="1" * 40,
            source_tree="2" * 40,
            optimizer_contract_sha256="3" * 64,
            persistence_contract_sha256="4" * 64,
            fixture_catalog_sha256=FIXTURE_CATALOG_RAW_SHA256,
            evaluator_sha256=catalog.evaluator_sha256,
            policy_catalog_sha256=POLICY_CATALOG_RAW_SHA256,
        )
        result = optimize_r10(
            processing_identity=identity,
            candidates=candidates,
            maximum_candidates=9,
            evaluation_catalog=catalog,
        )
        self.assertEqual(result.status, R10RunStatus.SUCCEEDED)
        self.assertEqual(result.evaluation_observation_count, 3)
        self.assertEqual(len(result.checkpoint.attempts), 9)
        self.assertEqual(
            sum(
                attempt.disposition is R10AttemptDisposition.REJECTED
                for attempt in result.checkpoint.attempts
            ),
            6,
        )
        assert result.selection is not None
        self.assertEqual(
            result.selection.selected_candidate.candidate_id,
            "fixture-valid-alpha",
        )

    def test_policy_freezes_three_causal_variables_and_finite_bound(self) -> None:
        variables = self.policy["causal_variables"]
        assert isinstance(variables, list)
        self.assertEqual(
            tuple(item["name"] for item in variables if isinstance(item, dict)),
            CAUSAL_VARIABLE_NAMES,
        )
        self.assertEqual(self.policy["maximum_candidates"], 9)
        self.assertIs(self.policy["comparative_metrics_used"], False)
        self.assertIs(self.policy["production_auto_authorized"], False)
        self.assertIs(self.policy["holdout_authorized"], False)

    def test_preregistration_has_no_future_source_self_binding(self) -> None:
        policy = self.preregistration["source_checkpoint_policy"]
        assert isinstance(policy, dict)
        self.assertIs(
            policy["preregistration_self_binds_future_source_checkpoint"],
            False,
        )
        self.assertNotIn("source_commit", policy)
        self.assertNotIn("source_tree", policy)

    def test_preregistration_binds_both_canonical_predecessors(self) -> None:
        self.assertEqual(
            self.preregistration["predecessor_bindings"],
            list(PREDECESSOR_BINDINGS),
        )
        for binding in PREDECESSOR_BINDINGS:
            payload = read_bytes(Path(str(binding["path"])))
            self.assertEqual(len(payload), binding["size_bytes"])
            self.assertEqual(
                hashlib.sha256(payload).hexdigest(),
                binding["raw_sha256"],
            )
            for role in ("implementation", "accepted_merge"):
                commit = str(binding[f"{role}_commit"])
                expected_tree = binding[f"{role}_tree"]
                tree = subprocess.run(
                    ["git", "show", "-s", "--format=%T", commit],
                    cwd=REPOSITORY_ROOT,
                    check=True,
                    capture_output=True,
                    text=True,
                ).stdout.strip()
                self.assertEqual(tree, expected_tree)

    def test_preregistration_binds_exact_schema_catalog_and_implementation_bytes(
        self,
    ) -> None:
        for section_name, expected_paths in (
            ("schema_bindings", SCHEMA_PATHS),
            ("catalog_bindings", CATALOG_PATHS),
        ):
            section = self.preregistration[section_name]
            assert isinstance(section, dict)
            self.assertEqual(set(section), set(expected_paths))
            for identifier, path in expected_paths.items():
                binding = section[identifier]
                assert isinstance(binding, dict)
                payload = read_bytes(path)
                self.assertEqual(binding["path"], path.as_posix())
                self.assertEqual(binding["size_bytes"], len(payload))
                self.assertEqual(
                    binding["sha256"],
                    hashlib.sha256(payload).hexdigest(),
                )
        implementations = self.preregistration[
            "implementation_contract_bindings"
        ]
        assert isinstance(implementations, list)
        by_id = {
            item["id"]: item for item in implementations if isinstance(item, dict)
        }
        self.assertEqual(set(by_id), set(IMPLEMENTATION_PATHS))
        for identifier, path in IMPLEMENTATION_PATHS.items():
            payload = read_bytes(path)
            self.assertEqual(by_id[identifier]["path"], path.as_posix())
            self.assertEqual(by_id[identifier]["size_bytes"], len(payload))
            self.assertEqual(
                by_id[identifier]["sha256"],
                hashlib.sha256(payload).hexdigest(),
            )

    def test_check_and_stop_rule_ids_are_closed_and_ordered(self) -> None:
        checks = self.preregistration["checks"]
        stop_rules = self.preregistration["stop_rules"]
        assert isinstance(checks, list)
        assert isinstance(stop_rules, list)
        self.assertEqual(
            tuple(item["id"] for item in checks if isinstance(item, dict)),
            CHECK_IDS,
        )
        self.assertEqual(
            tuple(item["id"] for item in stop_rules if isinstance(item, dict)),
            STOP_RULE_IDS,
        )

    def test_comparison_dependency_is_separate_from_acceptance_dependencies(
        self,
    ) -> None:
        policy = self.preregistration["acceptance_policy"]
        assert isinstance(policy, dict)
        self.assertEqual(
            policy["acceptance_dependency"],
            "exact_predecessors_and_preregistered_software_function_checks",
        )
        self.assertEqual(policy["comparison_acceptance_dependency"], "none")
        for key in (
            "comparative_testing",
            "a_b_testing",
            "superiority_requirement",
        ):
            self.assertEqual(
                policy[key],
                "excluded_not_required_non_authorizing",
            )

    def test_fixture_publication_and_product_authority_are_not_conflated(
        self,
    ) -> None:
        boundary = self.preregistration["authorization_boundary"]
        assert isinstance(boundary, dict)
        self.assertEqual(
            boundary["fixture_policy_publication"],
            "authorized_after_preregistered_run_checks_pass",
        )
        for key in (
            "production_auto",
            "holdout",
            "product_publication",
            "quality_claims",
            "performance_claims",
            "release",
        ):
            self.assertEqual(boundary[key], "not_authorized")

    def test_parser_rejects_duplicate_json_key_and_nonfinite_number(self) -> None:
        with self.assertRaisesRegex(R10ContractError, "duplicate JSON key"):
            parse_policy_catalog_r10(b'{"a":1,"a":2}\n')
        with self.assertRaisesRegex(R10ContractError, "non-finite JSON number"):
            parse_policy_catalog_r10(b'{"value":NaN}\n')

    def test_parser_rejects_non_bytes_missing_newline_cr_and_oversize(self) -> None:
        payload = read_bytes(POLICY_CATALOG_PATH)
        for mutated in (
            payload[:-1],
            payload.replace(b"\n", b"\r\n", 1),
            "not-bytes",
            b"{" + b" " * (2 * 1024 * 1024) + b"}\n",
        ):
            with self.subTest(kind=type(mutated).__name__):
                with self.assertRaises(R10ContractError):
                    parse_policy_catalog_r10(mutated)  # type: ignore[arg-type]

    def test_every_candidate_hash_mutation_is_rejected(self) -> None:
        wrappers = self.fixture["candidates"]
        assert isinstance(wrappers, list)
        for index in range(len(wrappers)):
            with self.subTest(candidate=index):
                mutated = copy.deepcopy(self.fixture)
                candidates = mutated["candidates"]
                assert isinstance(candidates, list)
                wrapper = candidates[index]
                assert isinstance(wrapper, dict)
                wrapper["candidate_sha256"] = "f" * 64
                with self.assertRaises(R10ContractError):
                    parse_fixture_catalog_r10(encoded(mutated))

    def test_each_constraint_expectation_mutation_is_rejected(self) -> None:
        wrappers = self.fixture["candidates"]
        assert isinstance(wrappers, list)
        for index in range(3, 9):
            with self.subTest(candidate=index):
                mutated = copy.deepcopy(self.fixture)
                candidates = mutated["candidates"]
                assert isinstance(candidates, list)
                wrapper = candidates[index]
                assert isinstance(wrapper, dict)
                expected = wrapper["expected"]
                assert isinstance(expected, dict)
                expected["rejected_constraints"] = []
                with self.assertRaises(R10ContractError):
                    parse_fixture_catalog_r10(encoded(mutated))

    def test_evaluation_candidate_score_and_semantic_hash_mutations_reject(
        self,
    ) -> None:
        mutations = []
        changed_candidate = copy.deepcopy(self.evaluation)
        inner = changed_candidate["evaluation_catalog"]
        assert isinstance(inner, dict)
        evaluations = inner["evaluations"]
        assert isinstance(evaluations, list)
        first = evaluations[0]
        assert isinstance(first, dict)
        first["candidate_sha256"] = "f" * 64
        mutations.append(changed_candidate)

        changed_score = copy.deepcopy(self.evaluation)
        inner = changed_score["evaluation_catalog"]
        assert isinstance(inner, dict)
        evaluations = inner["evaluations"]
        assert isinstance(evaluations, list)
        first = evaluations[0]
        assert isinstance(first, dict)
        score = first["score"]
        assert isinstance(score, dict)
        score["quality_q16"] = 1
        mutations.append(changed_score)

        changed_digest = copy.deepcopy(self.evaluation)
        changed_digest["evaluator_sha256"] = "f" * 64
        mutations.append(changed_digest)

        for index, mutated in enumerate(mutations):
            with self.subTest(mutation=index):
                with self.assertRaises(R10ContractError):
                    parse_evaluation_catalog_r10(encoded(mutated))

    def test_policy_boundary_mutations_are_rejected(self) -> None:
        for key, value in (
            ("maximum_candidates", 10),
            ("comparative_metrics_used", True),
            ("production_auto_authorized", True),
            ("holdout_authorized", True),
            ("threshold_relaxation_allowed", True),
            ("post_freeze_change_allowed", True),
        ):
            with self.subTest(key=key):
                mutated = copy.deepcopy(self.policy)
                mutated[key] = value
                with self.assertRaises(R10ContractError):
                    parse_policy_catalog_r10(encoded(mutated))

    def test_comparative_or_private_fields_are_rejected(self) -> None:
        comparative = copy.deepcopy(self.evaluation)
        comparative["baseline_score"] = 123
        with self.assertRaises(R10ContractError):
            parse_evaluation_catalog_r10(encoded(comparative))

        private = copy.deepcopy(self.policy)
        private["note"] = "operator@example.com"
        with self.assertRaisesRegex(R10ContractError, "email address"):
            parse_policy_catalog_r10(encoded(private))

        private_path = copy.deepcopy(self.fixture)
        private_path["note"] = "/Users/operator/private.json"
        with self.assertRaisesRegex(R10ContractError, "private path"):
            parse_fixture_catalog_r10(encoded(private_path))

    def test_fixture_raw_catalog_binding_mutations_are_rejected_by_verifier(
        self,
    ) -> None:
        for key, value in (
            ("path", "../evaluation.json"),
            ("size_bytes", 1),
            ("sha256", "f" * 64),
        ):
            with self.subTest(key=key):
                mutated = copy.deepcopy(self.fixture)
                binding = mutated["evaluation_catalog_binding"]
                assert isinstance(binding, dict)
                binding[key] = value
                with self.assertRaises(R10ContractError):
                    parse_fixture_catalog_r10(encoded(mutated))

    def test_planned_and_in_progress_status_do_not_require_acceptance(self) -> None:
        for status in ("planned", "in_progress"):
            with self.subTest(status=status):
                with self.temporary_roadmap_root(status) as temporary:
                    errors = R10ContractVerifier(
                        Path(temporary)
                    ).check_roadmap_status()
                self.assertEqual(errors, [])

    def test_passed_status_requires_acceptance_record(self) -> None:
        with self.temporary_roadmap_root("passed") as temporary:
            errors = R10ContractVerifier(Path(temporary)).check_roadmap_status()
        self.assertIn(
            "R10 functional phase acceptance must be a regular non-symlink file",
            errors,
        )

    def test_passed_status_rejects_gate_only_forged_acceptance(self) -> None:
        from Scripts.r10_phase_acceptance import R10PhaseAcceptanceVerifier

        with self.temporary_roadmap_root("passed") as temporary:
            root = Path(temporary)
            phase_verifier = R10PhaseAcceptanceVerifier(root)
            acceptance = phase_verifier.expected_acceptance(
                source={"commit": "a" * 40, "tree": "b" * 40},
                execution_receipt_payload=b"forged execution\n",
                run_receipt_payload=b"forged run\n",
            )
            target = root / PHASE_ACCEPTANCE_PATH
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(encoded(acceptance))
            errors = R10ContractVerifier(root).check_roadmap_status()
        self.assertTrue(
            any(
                "R10 functional execution receipt" in error
                for error in errors
            ),
            errors,
        )

    def test_invalid_status_is_rejected(self) -> None:
        with self.temporary_roadmap_root("blocked") as temporary:
            errors = R10ContractVerifier(Path(temporary)).check_roadmap_status()
        self.assertEqual(
            errors,
            "canonical R10 status must be planned, in_progress, or passed".split(
                "\n"
            ),
        )

    def test_passed_status_rejects_malformed_or_symlinked_acceptance(self) -> None:
        with self.temporary_roadmap_root("passed") as temporary:
            root = Path(temporary)
            acceptance = root / PHASE_ACCEPTANCE_PATH
            acceptance.parent.mkdir(parents=True, exist_ok=True)
            acceptance.write_text("{", encoding="utf-8")
            malformed_errors = R10ContractVerifier(
                root
            ).check_roadmap_status()
        self.assertTrue(
            any(
                "R10 functional phase acceptance" in error
                for error in malformed_errors
            )
        )

        with self.temporary_roadmap_root("passed") as temporary:
            root = Path(temporary)
            target = root / "acceptance-target.json"
            target.write_text("{}\n", encoding="utf-8")
            acceptance = root / PHASE_ACCEPTANCE_PATH
            acceptance.parent.mkdir(parents=True, exist_ok=True)
            acceptance.symlink_to(target)
            symlink_errors = R10ContractVerifier(
                root
            ).check_roadmap_status()
        self.assertIn(
            "R10 functional phase acceptance must be a regular non-symlink file",
            symlink_errors,
        )

    def test_missing_or_symlinked_catalogs_fail_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            errors = R10ContractVerifier(Path(temporary)).check_catalogs()
        for label in (
            "R10 fixture catalog",
            "R10 evaluation catalog",
            "R10 policy catalog",
        ):
            self.assertIn(
                f"{label} must be a regular non-symlink file",
                errors,
            )

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            target = root / "catalog-target.json"
            target.write_text("{}\n", encoding="utf-8")
            fixture = root / FIXTURE_CATALOG_PATH
            fixture.parent.mkdir(parents=True, exist_ok=True)
            fixture.symlink_to(target)
            errors = R10ContractVerifier(root).check_catalogs()
        self.assertIn(
            "R10 fixture catalog must be a regular non-symlink file",
            errors,
        )

    def test_bounded_no_follow_reader_rejects_oversize_growth_and_swap(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            target = root / "record.json"
            verifier = R10ContractVerifier(root)

            target.write_bytes(b"x" * (MAX_CONTRACT_BYTES + 1))
            errors: list[str] = []
            self.assertIsNone(
                verifier._read_bytes(target.relative_to(root), "record", errors)
            )
            self.assertIn(
                "record bytes are outside the closed boundary",
                errors,
            )

            target.write_bytes(b"{}\n")
            original_read = os.read
            grew = False

            def grow_after_first_read(
                descriptor: int,
                count: int,
            ) -> bytes:
                nonlocal grew
                payload = original_read(descriptor, count)
                if not grew:
                    grew = True
                    with target.open("ab") as handle:
                        handle.write(b"x")
                        handle.flush()
                        os.fsync(handle.fileno())
                return payload

            errors = []
            with mock.patch(
                "r10_contracts.os.read",
                side_effect=grow_after_first_read,
            ):
                self.assertIsNone(
                    verifier._read_bytes(
                        target.relative_to(root),
                        "record",
                        errors,
                    )
                )
            self.assertIn(
                "record changed during bounded no-follow read",
                errors,
            )

            target.write_bytes(b"{}\n")
            replacement = root / "replacement.json"
            replacement.write_bytes(b'{"forged":true}\n')
            swapped = False

            def swap_after_first_read(
                descriptor: int,
                count: int,
            ) -> bytes:
                nonlocal swapped
                payload = original_read(descriptor, count)
                if not swapped:
                    swapped = True
                    target.unlink()
                    target.symlink_to(replacement)
                return payload

            errors = []
            with mock.patch(
                "r10_contracts.os.read",
                side_effect=swap_after_first_read,
            ):
                self.assertIsNone(
                    verifier._read_bytes(
                        target.relative_to(root),
                        "record",
                        errors,
                    )
                )
            self.assertIn(
                "record changed during bounded no-follow read",
                errors,
            )


if __name__ == "__main__":
    unittest.main()
