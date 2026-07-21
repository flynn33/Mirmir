from __future__ import annotations

import copy
from contextlib import redirect_stderr, redirect_stdout
import hashlib
from io import StringIO
import json
from pathlib import Path
import subprocess
import sys
import unittest


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPOSITORY_ROOT / "Scripts"))

from phase_evidence import validate_json_schema_instance  # noqa: E402
from r07_contracts import (  # noqa: E402
    A04_CONFIGURATION_IDENTITY,
    A13_PROCESSING_IDENTITY,
    A15_PROCESSING_IDENTITY,
    ARTIFACT_ORDER,
    CHECK_IDS,
    COMPARATOR_DIMENSIONS,
    CONFORMANCE_PATH,
    CONFORMANCE_SCHEMA_PATH,
    FAMILY_IDS,
    FIXTURE_CATALOG_PATH,
    FIXTURE_CATALOG_SCHEMA_PATH,
    FIXTURE_CHECK_IDS,
    NUMERIC_CONTRACT,
    POSTFLIGHT_REJECTION_PRECEDENCE,
    PREDECESSOR,
    PREREGISTRATION_PATH,
    PREREGISTRATION_SCHEMA_PATH,
    PREREGISTRATION_TOP_LEVEL_KEYS,
    PRODUCT_DIMENSIONS,
    PRODUCT_GATE,
    PROTECTED_KINDS,
    R07ContractVerifier,
    SOURCE_BINDINGS,
    main,
)


def read_json(relative: Path) -> dict[str, object]:
    value = json.loads((REPOSITORY_ROOT / relative).read_text(encoding="utf-8"))
    assert isinstance(value, dict)
    return value


def binding(relative: Path) -> dict[str, object]:
    payload = (REPOSITORY_ROOT / relative).read_bytes()
    return {
        "path": relative.as_posix(),
        "size_bytes": len(payload),
        "sha256": hashlib.sha256(payload).hexdigest(),
    }


def frozen_leaf_paths(value: object, prefix: tuple[object, ...] = ()) -> list[tuple[object, ...]]:
    if isinstance(value, dict):
        if not value:
            return [prefix]
        result: list[tuple[object, ...]] = []
        for key, nested in value.items():
            result.extend(frozen_leaf_paths(nested, prefix + (key,)))
        return result
    if isinstance(value, list):
        if not value:
            return [prefix]
        result = []
        for index, nested in enumerate(value):
            result.extend(frozen_leaf_paths(nested, prefix + (index,)))
        return result
    return [prefix]


def mutate_leaf(value: object) -> object:
    if value is None:
        return "mutated"
    if isinstance(value, bool):
        return not value
    if isinstance(value, int):
        return value + 1
    if isinstance(value, float):
        return value + 0.01
    if isinstance(value, str):
        return value + ".mutated"
    if isinstance(value, list):
        return ["mutated"]
    if isinstance(value, dict):
        return {"mutated": True}
    raise AssertionError(f"unsupported leaf type: {type(value)!r}")


def set_path(value: object, path: tuple[object, ...]) -> None:
    target = value
    for component in path[:-1]:
        target = target[component]  # type: ignore[index]
    component = path[-1]
    target[component] = mutate_leaf(target[component])  # type: ignore[index]


class R07ContractTests(unittest.TestCase):
    def setUp(self) -> None:
        self.verifier = R07ContractVerifier(REPOSITORY_ROOT)
        self.preregistration = read_json(PREREGISTRATION_PATH)
        self.catalog = read_json(FIXTURE_CATALOG_PATH)
        self.preregistration_schema = read_json(PREREGISTRATION_SCHEMA_PATH)
        self.catalog_schema = read_json(FIXTURE_CATALOG_SCHEMA_PATH)
        self.conformance_schema = read_json(CONFORMANCE_SCHEMA_PATH)

    def preregistration_errors(self, value: dict[str, object]) -> list[str]:
        errors: list[str] = []
        self.verifier._check_preregistration_semantics(value, errors)
        return errors

    def fixture_errors(self, value: dict[str, object]) -> list[str]:
        errors: list[str] = []
        self.verifier._check_fixture_semantics(value, errors)
        return errors

    @staticmethod
    def fixture_map(
        catalog: dict[str, object], family: str
    ) -> dict[str, dict[str, object]]:
        values = catalog[family]
        assert isinstance(values, list)
        return {
            item["id"]: item
            for item in values
            if isinstance(item, dict) and isinstance(item.get("id"), str)
        }

    def valid_conformance(self) -> dict[str, object]:
        head = subprocess.run(
            ["git", "rev-parse", "HEAD"], cwd=REPOSITORY_ROOT,
            capture_output=True, check=True, text=True
        ).stdout.strip()
        tree = subprocess.run(
            ["git", "rev-parse", "HEAD^{tree}"], cwd=REPOSITORY_ROOT,
            capture_output=True, check=True, text=True
        ).stdout.strip()
        reason = "upstream_no_product_qualified_primary_backend"
        return {
            "schema_version": "1.0.0",
            "roadmap_version": "1.0.1",
            "phase_id": "R07",
            "evidence_kind": "r07_temporal_artifact_contract",
            "source": {"commit": head, "tree": tree},
            "preregistration_binding": binding(PREREGISTRATION_PATH),
            "fixture_catalog_binding": binding(FIXTURE_CATALOG_PATH),
            "observation_status": {
                "hardware_capability_observation": "not_observed",
                "simulator_execution": "not_observed",
                "operator_observed_operation": "not_observed",
                "product_comparison_execution": "not_observed",
                "quality_claims": "forbidden",
                "performance_claims": "forbidden",
            },
            "product_gate_result": {
                "reason": reason,
                "eligible_backend_count": 0,
                "selected_route_id": None,
                "selected_plan_id": None,
                "output_identity": None,
                "disposition": "blocked",
            },
            "fixture_checks": [
                {"id": identifier, "status": "passed"}
                for identifier in FIXTURE_CHECK_IDS
            ],
            "product_comparisons": [
                {"id": identifier, "status": "not_observed", "reason": reason}
                for identifier in PRODUCT_DIMENSIONS
            ],
            "checks": [
                {"id": identifier, "status": "passed"}
                for identifier in CHECK_IDS
            ],
            "result": {
                "status": "blocked",
                "reason": reason,
                "default_backend_id": None,
                "selected_route_id": None,
                "selected_plan_id": None,
                "output_identity": None,
                "product_qualification": "not_claimed",
                "quality_claims": "forbidden",
                "performance_claims": "forbidden",
                "acceptance": "not_claimed",
            },
            "limitations": [
                "Deterministic fixture conformance does not establish product qualification, quality, or performance.",
                "R07 A13/A15 support reconstruction execution was not observed; descriptor-and-admission conformance makes no support output claim.",
            ],
        }

    def test_repository_preregistration_fixtures_and_optional_conformance_pass(self) -> None:
        self.assertEqual(self.verifier.check_preregistration(), [])
        self.assertEqual(self.verifier.check_fixtures(), [])
        self.assertEqual(self.verifier.check_conformance(), [])
        self.assertFalse(self.verifier.conformance_materialized)
        self.assertFalse((REPOSITORY_ROOT / CONFORMANCE_PATH).exists())

    def test_records_and_future_conformance_validate_against_closed_schemas(self) -> None:
        cases = (
            (self.preregistration_schema, self.preregistration),
            (self.catalog_schema, self.catalog),
            (self.conformance_schema, self.valid_conformance()),
        )
        for schema, value in cases:
            with self.subTest(phase=value.get("phase_id"), keys=tuple(value)):
                self.assertEqual(validate_json_schema_instance(schema, value), [])

    def test_default_cli_checks_all_and_accepts_absent_conformance(self) -> None:
        stdout, stderr = StringIO(), StringIO()
        with redirect_stdout(stdout), redirect_stderr(stderr):
            result = main([])
        self.assertEqual(result, 0)
        self.assertEqual(stderr.getvalue(), "")
        self.assertIn("R07 preregistration: PASS", stdout.getvalue())
        self.assertIn("R07 fixtures: PASS", stdout.getvalue())
        self.assertIn("not materialized; accepted preimplementation", stdout.getvalue())

    def test_each_cli_mode_passes(self) -> None:
        for option in (
            "--check-preregistration", "--check-fixtures", "--check-conformance"
        ):
            with self.subTest(option=option):
                with redirect_stdout(StringIO()), redirect_stderr(StringIO()):
                    self.assertEqual(main([option]), 0)

    def test_predecessor_commit_tree_and_policy_are_exact(self) -> None:
        self.assertEqual(self.preregistration["predecessor_binding"], PREDECESSOR)
        errors: list[str] = []
        self.verifier._check_predecessor(self.preregistration, errors)
        self.assertEqual(errors, [])
        mutated = copy.deepcopy(self.preregistration)
        mutated["predecessor_binding"]["closure_state"] = "canonical_blocked_closure"
        errors = []
        self.verifier._check_predecessor(mutated, errors)
        self.assertTrue(errors)

    def test_top_level_key_order_and_closed_contract_sections_are_exact(self) -> None:
        self.assertEqual(tuple(self.preregistration), PREREGISTRATION_TOP_LEVEL_KEYS)
        for key in (
            "observation_policy", "numeric_contract", "temporal_analysis_contract",
            "history_contract", "artifact_contract", "protected_content_contract",
            "weighted_mae_contract", "support_stage_contract",
            "postflight_feedback_contract", "product_comparator_contract",
            "product_gate", "authorization_boundary",
        ):
            with self.subTest(key=key):
                mutated = copy.deepcopy(self.preregistration)
                mutated[key] = {}
                self.assertTrue(
                    validate_json_schema_instance(self.preregistration_schema, mutated)
                )

    def test_every_preregistration_leaf_is_frozen_by_mutation(self) -> None:
        paths = frozen_leaf_paths(self.preregistration)
        self.assertGreater(len(paths), 200)
        for path in paths:
            with self.subTest(path=path):
                mutated = copy.deepcopy(self.preregistration)
                set_path(mutated, path)
                self.assertIn(
                    "R07 preregistration semantic contract differs",
                    self.preregistration_errors(mutated),
                )

    def test_every_fixture_catalog_leaf_is_frozen_by_mutation(self) -> None:
        paths = frozen_leaf_paths(self.catalog)
        self.assertGreater(len(paths), 700)
        for path in paths:
            with self.subTest(path=path):
                mutated = copy.deepcopy(self.catalog)
                set_path(mutated, path)
                self.assertIn(
                    "R07 fixture catalog semantic contract differs",
                    self.fixture_errors(mutated),
                )

    def test_each_fixture_kind_and_outcome_is_closed_by_schema(self) -> None:
        for family, identifiers in FAMILY_IDS.items():
            fixtures = self.fixture_map(self.catalog, family)
            self.assertEqual(tuple(fixtures), identifiers)
            for identifier in identifiers:
                with self.subTest(family=family, fixture=identifier):
                    mutated = copy.deepcopy(self.catalog)
                    target = self.fixture_map(mutated, family)[identifier]
                    target["kind"] = "unfrozen_kind"
                    self.assertTrue(validate_json_schema_instance(self.catalog_schema, mutated))

    def test_all_source_authorities_are_byte_exact(self) -> None:
        observed = self.catalog["source_bindings"]
        self.assertIsInstance(observed, list)
        self.assertEqual(len(observed), len(SOURCE_BINDINGS))
        for item in observed:
            assert isinstance(item, dict)
            identifier = item["id"]
            expected = SOURCE_BINDINGS[identifier]
            with self.subTest(identifier=identifier):
                payload = (REPOSITORY_ROOT / expected[0]).read_bytes()
                self.assertEqual(len(payload), expected[1])
                self.assertEqual(hashlib.sha256(payload).hexdigest(), expected[2])

    def test_numeric_vector_and_ringing_domains_are_exact(self) -> None:
        self.assertEqual(self.preregistration["numeric_contract"], NUMERIC_CONTRACT)
        mutated = copy.deepcopy(self.catalog)
        artifact = self.fixture_map(mutated, "artifact_fixtures")
        artifact["artifact-step-ringing"]["inputs"]["candidate"][0] = -65537
        errors = self.fixture_errors(mutated)
        self.assertTrue(any("ringing candidate signed Q16 domain" in item for item in errors))

        mutated = copy.deepcopy(self.catalog)
        artifact = self.fixture_map(mutated, "artifact_fixtures")
        artifact["artifact-thin-line-control"]["inputs"]["candidate"][0] = -1
        errors = self.fixture_errors(mutated)
        self.assertTrue(any("normal Q16 domain" in item for item in errors))

        mutated = copy.deepcopy(self.catalog)
        artifact = self.fixture_map(mutated, "artifact_fixtures")
        artifact["artifact-step-ringing"]["inputs"]["lower_bounds"][0] = 1
        artifact["artifact-step-ringing"]["inputs"]["upper_bounds"][0] = 0
        errors = self.fixture_errors(mutated)
        self.assertTrue(any("ringing bounds/domain relation" in item for item in errors))

    def test_oversize_vectors_are_rejected_never_clamped(self) -> None:
        temporal = self.fixture_map(self.catalog, "temporal_fixtures")
        vector_boundary = temporal["temporal-vector-boundary-4096"]
        self.assertEqual(vector_boundary["inputs"]["declared_sample_count"], 4096)
        self.assertEqual(vector_boundary["inputs"]["generator"], "constant_fill")
        self.assertTrue(vector_boundary["expected"]["accepted"])
        self.assertNotIn("current", vector_boundary["inputs"])
        protected = self.fixture_map(self.catalog, "protected_content_fixtures")
        mask_boundary = protected["protected-mask-boundary-4096"]
        self.assertEqual(
            (
                mask_boundary["inputs"]["width"],
                mask_boundary["inputs"]["height"],
                mask_boundary["inputs"]["declared_sample_count"],
                mask_boundary["inputs"]["generator"],
            ),
            (64, 64, 4096, "constant_fill"),
        )
        self.assertTrue(mask_boundary["expected"]["accepted"])
        self.assertNotIn("mask_q15", mask_boundary["inputs"])

        artifact = self.fixture_map(self.catalog, "artifact_fixtures")
        rejection = artifact["artifact-vector-oversize-rejection"]
        self.assertEqual(rejection["inputs"]["declared_sample_count"], 4097)
        self.assertEqual(rejection["expected"]["policy"], "reject_never_clamp")
        self.assertNotIn("candidate", rejection["inputs"])

        mutated = copy.deepcopy(self.catalog)
        temporal_mutated = self.fixture_map(mutated, "temporal_fixtures")
        temporal_mutated["temporal-identical"]["inputs"]["current"] = [0] * 4097
        schema_errors = validate_json_schema_instance(self.catalog_schema, mutated)
        self.assertTrue(any("more than 4096" in item for item in schema_errors))
        semantic_errors = self.fixture_errors(mutated)
        self.assertTrue(any("4096-sample bound" in item for item in semantic_errors))

    def test_negative_and_initial_state_semantics_are_exact(self) -> None:
        temporal = self.fixture_map(self.catalog, "temporal_fixtures")
        temporal_rejections = {
            "temporal-empty-vector-rejection": "empty_vector_rejected",
            "temporal-sample-count-mismatch-rejection": "sample_count_mismatch_rejected",
            "temporal-all-occluded-motion-rejection": "no_valid_motion_samples_rejected",
        }
        for identifier, reason in temporal_rejections.items():
            with self.subTest(identifier=identifier):
                self.assertFalse(temporal[identifier]["expected"]["accepted"])
                self.assertEqual(temporal[identifier]["expected"]["reason"], reason)

        artifact = self.fixture_map(self.catalog, "artifact_fixtures")
        artifact_rejections = {
            "artifact-all-occluded-ghosting-rejection": "no_valid_ghosting_samples_rejected",
            "artifact-zero-halo-support-rejection": "zero_support_rejected",
            "artifact-false-texture-insufficient-samples-rejection": "insufficient_samples_rejected",
        }
        for identifier, reason in artifact_rejections.items():
            with self.subTest(identifier=identifier):
                self.assertFalse(artifact[identifier]["expected"]["accepted"])
                self.assertEqual(artifact[identifier]["expected"]["reason"], reason)

        protected = self.fixture_map(self.catalog, "protected_content_fixtures")
        zero_weight = protected["protected-zero-weight-rejection"]
        self.assertEqual(zero_weight["inputs"]["mask_q15"], [0, 0])
        self.assertEqual(zero_weight["expected"]["reason"], "zero_weight_rejected")

        history = self.fixture_map(self.catalog, "history_fixtures")
        zero = history["history-zero-transitions"]["expected"]
        self.assertEqual(
            (zero["transition_count"], zero["backend_churn_q16"], zero["strength_churn_q16"]),
            (0, 0, 0),
        )
        self.assertFalse(zero["backend_churn_excessive"])
        self.assertFalse(zero["strength_churn_excessive"])
        empty = history["history-empty-artifact-persistence"]["expected"]
        self.assertEqual((empty["window_entry_count"], empty["mean_risk_q16"], empty["excessive"]), (0, 0, False))
        single = history["history-single-artifact-persistence"]["expected"]
        self.assertEqual((single["window_entry_count"], single["mean_risk_q16"], single["uses_entry_artifact_risk"]), (1, 4096, True))

    def test_threshold_equality_semantics_are_deliberately_asymmetric(self) -> None:
        temporal = self.fixture_map(self.catalog, "temporal_fixtures")
        self.assertTrue(temporal["temporal-scene-cut-threshold-equality"]["expected"]["scene_cut_detected"])
        self.assertTrue(temporal["temporal-motion-threshold-equality"]["expected"]["motion_valid"])
        self.assertTrue(temporal["temporal-occlusion-threshold-equality"]["expected"]["occlusion_detected"])

        history = self.fixture_map(self.catalog, "history_fixtures")
        for identifier in (
            "history-a-a-b", "history-strength-changes",
            "history-artifact-persistence",
        ):
            with self.subTest(identifier=identifier):
                self.assertTrue(history[identifier]["expected"]["within_bound"])
                self.assertFalse(history[identifier]["expected"]["excessive"])

        artifact = self.fixture_map(self.catalog, "artifact_fixtures")
        equality = artifact["artifact-threshold-equality"]["expected"]
        self.assertEqual(equality["normalized_risk_q16_by_artifact"], [65536] * 6)
        for key, value in equality.items():
            if key.endswith("_detected"):
                self.assertFalse(value)

    def test_artifact_order_normalization_and_max_aggregation_are_exact(self) -> None:
        artifact = self.fixture_map(self.catalog, "artifact_fixtures")
        aggregate = artifact["artifact-risk-aggregate-order"]
        self.assertEqual(aggregate["inputs"]["artifact_order"], list(ARTIFACT_ORDER))
        self.assertEqual(aggregate["expected"]["normalized_risk_q16"], [0, 0, 0, 0, 0, 32768])
        self.assertEqual(aggregate["expected"]["aggregate_risk_q16"], 32768)
        self.assertEqual(aggregate["expected"]["arithmetic"], "checked_Int64_toward_zero")

    def test_protected_empty_overlap_and_weighted_mae_contracts_are_exact(self) -> None:
        protected = self.fixture_map(self.catalog, "protected_content_fixtures")
        self.assertEqual(tuple(PROTECTED_KINDS), (
            "ui_capture", "subtitle", "text", "face", "line_art", "animation"
        ))
        empty = protected["protected-empty-regions"]
        self.assertEqual(empty["expected"]["composed_q15"], [0, 0, 0, 0])
        self.assertEqual(empty["expected"]["owner_by_pixel"], [None] * 4)
        overlap = protected["protected-overlap-precedence"]
        self.assertEqual(overlap["expected"]["owner_by_pixel"], ["ui_capture", "subtitle", None, None])
        weighted = protected["protected-weighted-mae"]
        self.assertEqual(weighted["inputs"]["candidate"], [0, 65536, 0, 65536])
        self.assertEqual(weighted["expected"]["weighted_mae_q16"], 32768)
        self.assertEqual(self.preregistration["weighted_mae_contract"]["nonzero_weight_sum_required"], True)
        self.assertEqual(self.preregistration["weighted_mae_contract"]["zero_weight_policy"], "zero_weight_rejected")

    def test_a04_admission_matrix_and_support_parameters_are_exact(self) -> None:
        support = self.fixture_map(self.catalog, "support_stage_fixtures")
        matrix = (
            ("support-a04-not-observed", "not_observed", "diagnostic_not_planned", False),
            ("support-a04-unsupported", "unsupported", "unavailable_not_planned", False),
            ("support-a04-fixture-admitted", "fixture_admitted", "deterministic_fixture_only_descriptor", True),
        )
        for identifier, status, outcome, constructed in matrix:
            with self.subTest(identifier=identifier):
                self.assertEqual(support[identifier]["inputs"]["qualification_status"], status)
                self.assertEqual(support[identifier]["expected"]["outcome"], outcome)
                self.assertIs(support[identifier]["expected"]["plan_constructed"], constructed)
                self.assertEqual(support[identifier]["expected"]["runtime_qualification"], "not_established")
                self.assertEqual(support[identifier]["expected"]["product_qualification"], "not_established")
        admitted = support["support-a04-fixture-admitted"]
        self.assertEqual(admitted["expected"]["configuration_identity"], A04_CONFIGURATION_IDENTITY)
        self.assertEqual(admitted["expected"]["strength_q16"], 24576)
        self.assertEqual(support["support-a05-temporal-analyzer"]["expected"]["role"], "analysis_only")
        a13 = support["support-a13-guided-filter"]["inputs"]
        self.assertEqual(
            (
                a13["source_pixel_format"], a13["guidance_pixel_format"],
                a13["output_pixel_format"],
            ),
            ("R8", "R8", "R8"),
        )
        self.assertEqual(a13["processing_identity"], A13_PROCESSING_IDENTITY)
        a13_expected = support["support-a13-guided-filter"]["expected"]
        self.assertEqual(
            (
                a13_expected["conformance_scope"],
                a13_expected["reconstruction_execution"],
                a13_expected["output_claims"],
            ),
            ("descriptor_and_admission_only", "not_observed", "forbidden"),
        )
        a15 = support["support-a15-edge-preserve"]["inputs"]
        self.assertEqual(
            (
                a15["mask_pixel_format"], a15["guidance_pixel_format"],
                a15["output_pixel_format"],
            ),
            ("R8", "R8", "R8"),
        )
        self.assertEqual(a15["processing_identity"], A15_PROCESSING_IDENTITY)
        a15_expected = support["support-a15-edge-preserve"]["expected"]
        self.assertEqual(
            (
                a15_expected["conformance_scope"],
                a15_expected["reconstruction_execution"],
                a15_expected["output_claims"],
            ),
            ("descriptor_and_admission_only", "not_observed", "forbidden"),
        )
        self.assertFalse(support["support-product-gate-first"]["expected"]["support_stage_construction_attempted"])

    def test_postflight_payload_duplicate_and_rejection_precedence_are_exact(self) -> None:
        postflight = self.fixture_map(self.catalog, "postflight_fixtures")
        completed = postflight["postflight-completed-n"]
        next_decision = postflight["postflight-n-plus-1"]
        self.assertEqual(completed["inputs"]["decision_contract"], "R06")
        self.assertEqual(next_decision["inputs"]["decision_contract"], "R06")
        self.assertEqual(
            self.preregistration["postflight_feedback_contract"]["report_binding"],
            "completed_R06_decision_N_same_shot",
        )
        self.assertEqual(completed["inputs"]["artifact_risk_q16"], 32768)
        self.assertEqual(completed["inputs"]["finding_ids"], ["ringing", "ghosting"])
        self.assertEqual(next_decision["expected"]["feedback_artifact_risk_q16"], 32768)
        self.assertEqual(next_decision["expected"]["feedback_finding_ids"], ["ringing", "ghosting"])
        duplicate = postflight["postflight-duplicate"]["expected"]
        self.assertEqual(duplicate["attempt_dispositions"], [
            "accepted_scheduled_for_n_plus_1", "duplicate_rejected_discarded"
        ])
        self.assertEqual(duplicate["pending_feedback_count"], 1)
        overlap = postflight["postflight-rejection-precedence-overlap"]["expected"]
        self.assertEqual(overlap["precedence"], list(POSTFLIGHT_REJECTION_PRECEDENCE))
        self.assertEqual(overlap["selected_rejection"], "duplicate")
        self.assertTrue(all(not item["expected"]["rewrites_decision_n"] for item in postflight.values()))

    def test_product_gate_and_comparators_are_nonvacuous_not_observed(self) -> None:
        self.assertEqual(self.preregistration["product_gate"], PRODUCT_GATE)
        comparators = self.fixture_map(self.catalog, "comparator_fixtures")
        blocked_ids = FAMILY_IDS["comparator_fixtures"][:4]
        for identifier, dimension in zip(blocked_ids, COMPARATOR_DIMENSIONS):
            item = comparators[identifier]
            with self.subTest(identifier=identifier):
                self.assertEqual(item["inputs"]["dimension"], dimension["id"])
                self.assertEqual(item["inputs"]["equation"], dimension["equation"])
                self.assertEqual(item["inputs"]["pass_operator"], dimension["pass_operator"])
                self.assertEqual(item["inputs"]["pass_threshold"], dimension["pass_threshold"])
                self.assertEqual(item["inputs"]["used_backend_ids"], [])
                self.assertFalse(item["expected"]["nonvacuous_requirement_satisfied"])
                self.assertFalse(item["expected"]["fixture_comparison_executed"])
                self.assertEqual(item["expected"]["product_comparison_execution"], "not_observed")
                self.assertEqual(item["expected"]["product_qualification"], "not_claimed")
                self.assertEqual(item["expected"]["claim"], "forbidden")

        synthetic_ids = FAMILY_IDS["comparator_fixtures"][4:]
        backend_ids = []
        observed = {identifier: [] for identifier in PRODUCT_DIMENSIONS}
        for identifier in synthetic_ids:
            item = comparators[identifier]
            inputs, expected = item["inputs"], item["expected"]
            backend_ids.extend(inputs["fixture_backend_ids"])
            observed[inputs["dimension"]].append((expected["computed_delta"], expected["passed"]))
            with self.subTest(identifier=identifier):
                self.assertEqual(len(inputs["fixture_backend_ids"]), 1)
                self.assertEqual(inputs["comparison_record_count"], 1)
                self.assertTrue(inputs["comparison_complete"])
                self.assertEqual(inputs["backend_scope"], "synthetic_fixture_only")
                self.assertTrue(expected["nonvacuous_requirement_satisfied"])
                self.assertTrue(expected["fixture_comparison_executed"])
                self.assertEqual(expected["product_comparison_execution"], "not_observed")
                self.assertEqual(expected["product_qualification"], "not_claimed")
                self.assertEqual(expected["claim"], "forbidden")
        self.assertEqual(len(backend_ids), len(set(backend_ids)))
        self.assertEqual(observed["temporal_artifact"], [(1, True), (0, False)])
        self.assertEqual(observed["chroma_displacement"], [(1, True), (0, False)])
        self.assertEqual(observed["spatial_ms_ssim"], [(-5000, True), (-5001, False)])
        self.assertEqual(observed["protected_integrity"], [(0, True), (1, False)])

    def test_privacy_mutations_fail_closed(self) -> None:
        mutated = copy.deepcopy(self.preregistration)
        mutated["authorization_boundary"]["user_name"] = "private@example.com"
        errors = self.preregistration_errors(mutated)
        self.assertTrue(any("forbidden private key" in item for item in errors))
        self.assertTrue(any("email address" in item for item in errors))

    def test_future_conformance_requires_exact_complete_checks_and_dimensions(self) -> None:
        valid = self.valid_conformance()
        self.assertEqual(validate_json_schema_instance(self.conformance_schema, valid), [])
        cases = []
        missing_check = copy.deepcopy(valid)
        missing_check["checks"].pop()
        cases.append(missing_check)
        failed_check = copy.deepcopy(valid)
        failed_check["fixture_checks"][0]["status"] = "blocked"
        cases.append(failed_check)
        missing_dimension = copy.deepcopy(valid)
        missing_dimension["product_comparisons"].pop()
        cases.append(missing_dimension)
        fabricated_backend = copy.deepcopy(valid)
        fabricated_backend["product_comparisons"][0]["backend_id"] = "invented"
        cases.append(fabricated_backend)
        for index, value in enumerate(cases):
            with self.subTest(case=index):
                self.assertTrue(validate_json_schema_instance(self.conformance_schema, value))


if __name__ == "__main__":
    unittest.main()
