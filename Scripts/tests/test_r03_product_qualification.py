from __future__ import annotations

import copy
import hashlib
import json
from pathlib import Path
import sys
import unittest


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPOSITORY_ROOT / "Scripts"))

from phase_evidence import validate_json_schema_instance  # noqa: E402
from r03_product_qualification import (  # noqa: E402
    ARTIFACT_BINDING_IDS,
    CANDIDATE_IDENTITY,
    CHECK_IDS,
    COLOR_OBSERVATION,
    DECISION_SCHEMA_PATH,
    EXECUTION_RECEIPT_SCHEMA_PATH,
    FIXTURE_CATALOG_PATH,
    FIXTURE_CATALOG_SCHEMA_PATH,
    FUNCTIONAL_METRIC_IDS,
    FIXTURE_CATALOG_SEMANTIC_SHA256,
    LEGACY_METRIC_CONTRACTS,
    NATIVE_ROUTE_INPUT_SHA256S,
    NOT_APPLICABLE_REASONS,
    PREREGISTRATION_PATH,
    PREREGISTRATION_SCHEMA_PATH,
    PREREGISTRATION_SEMANTIC_SHA256,
    REQUIRED_TEST_IDENTIFIERS,
    MINIMUM_SELECTED_TEST_COUNT,
    QUALIFICATION_INVOCATION_CONTRACT_ID,
    ROUTE_CONTRACTS,
    SOURCE_BINDING_REQUIREMENTS,
    TEST_BINDING_REQUIREMENTS,
    TOOLCHAIN_FIELDS,
    R03ProductQualificationVerifier,
    _qualification_invocation,
    _semantic_sha256,
)


def read_json(relative: Path) -> dict[str, object]:
    value = json.loads((REPOSITORY_ROOT / relative).read_text(encoding="utf-8"))
    assert isinstance(value, dict)
    return value


def fake_binding(path: str, identifier: str | None = None) -> dict[str, object]:
    binding: dict[str, object] = {
        "path": path,
        "size_bytes": 1,
        "sha256": hashlib.sha256(path.encode("utf-8")).hexdigest(),
    }
    if identifier is not None:
        binding = {"id": identifier, **binding}
    return binding


class R03ProductQualificationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.verifier = R03ProductQualificationVerifier(REPOSITORY_ROOT)
        self.preregistration = read_json(PREREGISTRATION_PATH)
        self.catalog = read_json(FIXTURE_CATALOG_PATH)

    @staticmethod
    def valid_qualification_invocation() -> dict[str, str]:
        return _qualification_invocation("c" * 64, "a" * 40, "b" * 40)

    @staticmethod
    def valid_receipt() -> dict[str, object]:
        route_results = []
        for route_index, route in enumerate(ROUTE_CONTRACTS, start=1):
            output_hash = f"{route_index}" * 64
            runs = []
            for ordinal in range(1, 4):
                runs.append(
                    {
                        "run_ordinal": ordinal,
                        "logical_output_sha256": output_hash,
                        "output_dimensions": copy.deepcopy(route["output_dimensions"]),
                        "color_observation": dict(COLOR_OBSERVATION),
                        "frame_order_preserved": True,
                        "pts_preserved": True,
                        "duration_preserved": True,
                        "metadata_preserved": True,
                        "lifecycle_observation": {
                            "input_release_count": 1,
                            "output_release_count": 1,
                            "terminalization_count": 1,
                            "reset_generation_advanced": True,
                            "finish_idempotent": True,
                            "cancel_idempotent": True,
                        },
                        "fallback_history": [],
                    }
                )
            route_results.append(
                {
                    "route_id": route["id"],
                    "configuration_identity": route["configuration_identity"],
                    "input_dimensions": copy.deepcopy(route["input_dimensions"]),
                    "output_dimensions": copy.deepcopy(route["output_dimensions"]),
                    "runs": runs,
                }
            )

        expected_frames = [
            {
                "sequence_number": sequence,
                "pts_value": sequence * 1001,
                "pts_timescale": 30000,
                "duration_value": 1001,
                "duration_timescale": 30000,
                "metadata_identity": f"r03-v2-media-transaction.frame-{sequence}",
                "resource_release_count": 1,
            }
            for sequence in range(3)
        ]
        media_runs = [
            {
                "run_ordinal": ordinal,
                "output_dimensions": {"width": 3840, "height": 2160},
                "video_codec": "h264",
                "audio_codec": "aac",
                "logical_frame_sha256s": ["3" * 64, "4" * 64, "5" * 64],
                "frame_observations": copy.deepcopy(expected_frames),
                "audio_semantic_sha256": (
                    "db9e6e337c0359715f730a6ef39eb44269290390a42a1044b4e481fb61092cef"
                ),
                "reopen_succeeded": True,
                "atomic_publication_succeeded": True,
                "fallback_history": [],
            }
            for ordinal in range(1, 4)
        ]
        passing_values = {
            "dimension_mismatch_count": 0,
            "pixel_format_mismatch_count": 0,
            "color_identity_mismatch_count": 0,
            "frame_timing_mismatch_count": 0,
            "audio_identity_mismatch_count": 0,
            "metadata_identity_mismatch_count": 0,
            "resource_lifetime_violation_count": 0,
            "silent_fallback_count": 0,
            "incomplete_identity_count": 0,
            "nonfinite_metric_count": 0,
            "distinct_output_hash_count": 1,
            "temporal_repeatability_mismatch_count": 0,
            "peak_in_flight_resources": 1,
        }
        metrics = []
        for metric_id, unit, _operator, _threshold in LEGACY_METRIC_CONTRACTS:
            if metric_id in FUNCTIONAL_METRIC_IDS:
                metrics.append(
                    {
                        "id": metric_id,
                        "unit": unit,
                        "status": "measured",
                        "value": passing_values[metric_id],
                        "reason": None,
                    }
                )
            else:
                metrics.append(
                    {
                        "id": metric_id,
                        "unit": unit,
                        "status": "not_applicable",
                        "value": None,
                        "reason": NOT_APPLICABLE_REASONS[metric_id],
                    }
                )
        source_bindings = [
            fake_binding(item["path"], item["id"])
            for item in SOURCE_BINDING_REQUIREMENTS
        ]
        test_bindings = [
            fake_binding(item["path"], item["id"])
            for item in TEST_BINDING_REQUIREMENTS
        ]
        artifact_bindings = [
            fake_binding(
                f"docs/roadmaps/evidence/r03/records/artifacts/product-qualification-v2/{identifier}.json",
                identifier,
            )
            for identifier in ARTIFACT_BINDING_IDS
        ]
        toolchain_values = {
            "xcode_version": "Xcode 26.0",
            "xcode_build_version": "17A1",
            "swift_version": "Swift 6.2",
            "sdk_name": "macosx",
            "sdk_version": "26.0",
            "destination": "platform=macOS",
            "command": "xcodebuild test -only-testing:MirmirTests/R03A11NativeMPSProductTests",
            "os_version": "26.0",
            "architecture": "arm64",
        }
        return {
            "schema_version": "2.0.0",
            "phase_id": "R03",
            "evidence_kind": "r03_a11_genuine_mps_functional_execution_receipt_v2",
            "source": {"commit": "a" * 40, "tree": "b" * 40},
            "preregistration_binding": fake_binding(PREREGISTRATION_PATH.as_posix()),
            "fixture_catalog_binding": fake_binding(FIXTURE_CATALOG_PATH.as_posix()),
            "source_bindings": source_bindings,
            "test_bindings": test_bindings,
            "artifact_bindings": artifact_bindings,
            "toolchain": {field: toolchain_values[field] for field in TOOLCHAIN_FIELDS},
            "observation_status": {
                "platform": "macos_host",
                "deterministic_software_execution": "observed",
                "genuine_mps_execution": "observed",
                "hardware_capability_observation": "not_observed",
                "simulator_execution": "not_observed",
                "operator_observed_operation": "not_observed",
                "product_runtime_support": "not_claimed",
            },
            "processing_identity": {
                **CANDIDATE_IDENTITY,
                "backend_revision": "1",
                "model_assets_identity": "notRequired",
                "fallback_history": [],
            },
            "route_results": route_results,
            "media_transaction_result": {
                "fixture_id": "r03-v2-media-transaction-2x",
                "runs": media_runs,
            },
            "metric_results": metrics,
        }

    def receipt_errors(self, value: dict[str, object]) -> list[str]:
        errors: list[str] = []
        self.verifier._check_receipt_semantics(value, errors, verify_files=False)
        return errors

    @staticmethod
    def valid_test_summary(
        count: int = MINIMUM_SELECTED_TEST_COUNT,
    ) -> dict[str, object]:
        identifiers = list(REQUIRED_TEST_IDENTIFIERS)
        identifiers.extend(
            f"R03A11NativeMPSProductTests/testAdditional{index}()"
            for index in range(count - len(identifiers))
        )
        toolchain_values = {
            "xcode_version": "Xcode 26.0",
            "xcode_build_version": "17A1",
            "swift_version": "Swift 6.2",
            "sdk_name": "macosx",
            "sdk_version": "26.0",
            "destination": "platform=macOS",
            "command": "xcodebuild test -only-testing:R03ProductQualification",
            "os_version": "26.0",
            "architecture": "arm64",
        }
        return {
            "schema_version": "1.0.0",
            "evidence_kind": "r03_a11_selected_test_summary_v1",
            "expected_selected_test_count": count,
            "selected_test_count": count,
            "passed_test_count": count,
            "failed_test_count": 0,
            "skipped_test_count": 0,
            "test_identifiers": identifiers,
            "toolchain": {field: toolchain_values[field] for field in TOOLCHAIN_FIELDS},
            "qualification_invocation": (
                R03ProductQualificationTests.valid_qualification_invocation()
            ),
        }

    @classmethod
    def valid_raw_xcresult(
        cls,
        count: int = MINIMUM_SELECTED_TEST_COUNT,
    ) -> tuple[dict[str, object], dict[str, object]]:
        identifiers = cls.valid_test_summary(count)["test_identifiers"]
        return (
            {
                "totalTestCount": count,
                "passedTests": count,
                "failedTests": 0,
                "skippedTests": 0,
                "result": "Passed",
                "testFailures": [],
            },
            {
                "testNodes": [
                    {
                        "nodeType": "Test Case",
                        "nodeIdentifier": identifier,
                        "result": "Passed",
                    }
                    for identifier in identifiers
                ]
            },
        )

    @staticmethod
    def valid_native_route_observations() -> dict[str, object]:
        color_identity = {
            "primaries": COLOR_OBSERVATION["primaries"],
            "transfer_function": COLOR_OBSERVATION["transfer_function"],
            "matrix": COLOR_OBSERVATION["matrix"],
            "chroma_location": COLOR_OBSERVATION["chroma_location"],
            "range": COLOR_OBSERVATION["range"],
        }

        def frame(dimensions: object) -> dict[str, object]:
            return {
                "dimensions": copy.deepcopy(dimensions),
                "plane_count": 2,
                "pixel_format": "420v",
                "pixel_format_raw_value": 875704438,
                "color_identity": dict(color_identity),
            }

        routes = []
        for route_index, route in enumerate(ROUTE_CONTRACTS, start=3):
            runs = []
            for ordinal in range(1, 4):
                runs.append(
                    {
                        "run_ordinal": ordinal,
                        "logical_input_sha256": NATIVE_ROUTE_INPUT_SHA256S[route["id"]],
                        "logical_output_sha256": str(route_index) * 64,
                        "sequence_number": 0,
                        "presentation_timestamp": {
                            "value": 30,
                            "timescale": 30,
                            "flags": 1,
                            "epoch": 0,
                        },
                        "duration": {
                            "value": 1,
                            "timescale": 30,
                            "flags": 1,
                            "epoch": 0,
                        },
                        "metadata_identity": "r03.metadata.0",
                        "input_token_identity": (
                            f"r03.a11.native.{route['id']}.run-{ordinal}.0"
                        ),
                        "output_token_identity": "r03.mps.lanczos.output.0",
                        "frame_order_preserved": True,
                        "pts_preserved": True,
                        "duration_preserved": True,
                        "metadata_preserved": True,
                        "lifecycle_observation": {
                            "input_release_count": 1,
                            "output_release_count": 1,
                            "terminalization_count": 1,
                            "pre_submit_reset_operations": 2,
                            "post_terminal_reset_operations": 2,
                            "finish_operations": 4,
                            "cancel_operations": 2,
                            "reset_next_history_generations": [1, 2],
                            "processed_history_generation": 2,
                            "finish_idempotent": True,
                            "cancel_idempotent": True,
                        },
                        "fallback_history": [],
                    }
                )
            routes.append(
                {
                    "route_id": route["id"],
                    "configuration_identity": route["configuration_identity"],
                    "input_identity": frame(route["input_dimensions"]),
                    "output_identity": frame(route["output_dimensions"]),
                    "runs": runs,
                }
            )
        return {
            "schema_version": "1.0.0",
            "evidence_kind": "r03_a11_native_route_observations_v1",
            "qualification_invocation": (
                R03ProductQualificationTests.valid_qualification_invocation()
            ),
            "backend_identity": {
                "backend_id": CANDIDATE_IDENTITY["backend_id"],
                "backend_revision": "1",
                "capability_id": CANDIDATE_IDENTITY["capability_id"],
                "framework_identity": CANDIDATE_IDENTITY["framework"],
                "model_assets_identity": "notRequired",
                "policy_identity": CANDIDATE_IDENTITY["policy_identity"],
                "material_decision_identity": CANDIDATE_IDENTITY[
                    "material_decision_identity"
                ],
            },
            "routes": routes,
        }

    def test_repository_preimplementation_contract_passes(self) -> None:
        self.assertEqual(self.verifier.check_preregistration(), [])
        self.assertEqual(self.verifier.check_fixtures(), [])
        self.assertEqual(self.verifier.check_preimplementation(), [])

    def test_additive_record_semantic_hashes_are_frozen_and_reject_mutation(self) -> None:
        self.assertEqual(
            _semantic_sha256(self.preregistration),
            PREREGISTRATION_SEMANTIC_SHA256,
        )
        self.assertEqual(
            _semantic_sha256(self.catalog),
            FIXTURE_CATALOG_SEMANTIC_SHA256,
        )

        preregistration = copy.deepcopy(self.preregistration)
        preregistration["roadmap_version"] = "mutated"
        errors: list[str] = []
        self.verifier._check_preregistration_semantics(preregistration, errors)
        self.assertIn("R03 v2 preregistration semantic contract differs", errors)

        catalog = copy.deepcopy(self.catalog)
        catalog["roadmap_version"] = "mutated"
        errors = []
        self.verifier._check_fixture_semantics(catalog, errors)
        self.assertIn("R03 v2 fixture catalog semantic contract differs", errors)

    def test_all_new_schemas_are_closed(self) -> None:
        fixtures = (
            (PREREGISTRATION_SCHEMA_PATH, self.preregistration),
            (FIXTURE_CATALOG_SCHEMA_PATH, self.catalog),
            (EXECUTION_RECEIPT_SCHEMA_PATH, self.valid_receipt()),
        )
        for schema_path, value in fixtures:
            with self.subTest(schema_path=schema_path):
                schema = read_json(schema_path)
                self.assertEqual(validate_json_schema_instance(schema, value), [])
                mutated = copy.deepcopy(value)
                mutated["unexpected"] = True
                self.assertTrue(validate_json_schema_instance(schema, mutated))

    def test_preregistration_rejects_candidate_and_metric_drift(self) -> None:
        candidate = copy.deepcopy(self.preregistration)
        candidate["candidate_contract"]["backend_id"] = "fixture.apple.mps_lanczos"
        errors: list[str] = []
        self.verifier._check_preregistration_semantics(candidate, errors)
        self.assertTrue(any("candidate contract" in error for error in errors))

        metric = copy.deepcopy(self.preregistration)
        metric["metrics"][0]["threshold"] = 1
        errors = []
        self.verifier._check_preregistration_semantics(metric, errors)
        self.assertTrue(any("metric contracts" in error for error in errors))

    def test_catalog_rejects_route_and_generated_media_drift(self) -> None:
        route = copy.deepcopy(self.catalog)
        route["routes"][1]["input_dimensions"]["width"] = 16
        errors: list[str] = []
        self.verifier._check_fixture_semantics(route, errors)
        self.assertTrue(any("route contracts" in error for error in errors))

        frame = copy.deepcopy(self.catalog)
        frame["media_transaction"]["frames"][0]["generated_content_sha256"] = "f" * 64
        errors = []
        self.verifier._check_fixture_semantics(frame, errors)
        self.assertTrue(any("media transaction differs" in error for error in errors))

    def test_complete_receipt_is_schema_valid_and_semantically_eligible(self) -> None:
        receipt = self.valid_receipt()
        schema = read_json(EXECUTION_RECEIPT_SCHEMA_PATH)
        self.assertEqual(validate_json_schema_instance(schema, receipt), [])
        self.assertEqual(self.receipt_errors(receipt), [])

    def test_receipt_rejects_non_candidate_and_hand_authored_claim(self) -> None:
        receipt = self.valid_receipt()
        receipt["processing_identity"]["backend_id"] = "r03.mps.bilinear"
        self.assertTrue(any("processing identity" in error for error in self.receipt_errors(receipt)))

        claim = self.valid_receipt()
        claim["product_qualification"] = "product_qualified"
        schema = read_json(EXECUTION_RECEIPT_SCHEMA_PATH)
        self.assertTrue(validate_json_schema_instance(schema, claim))

    def test_receipt_rejects_route_identity_ordinal_and_repeat_drift(self) -> None:
        mutations = []
        configuration = self.valid_receipt()
        configuration["route_results"][0]["configuration_identity"] = "wrong"
        mutations.append(configuration)
        ordinal = self.valid_receipt()
        ordinal["route_results"][0]["runs"][0]["run_ordinal"] = 2
        mutations.append(ordinal)
        repeat = self.valid_receipt()
        repeat["route_results"][0]["runs"][2]["logical_output_sha256"] = "f" * 64
        mutations.append(repeat)
        for mutation in mutations:
            self.assertTrue(self.receipt_errors(mutation))

    def test_receipt_rejects_media_sequence_pts_and_metadata_drift(self) -> None:
        for key, value in (
            ("sequence_number", 7),
            ("pts_value", 7),
            ("metadata_identity", "wrong"),
        ):
            with self.subTest(key=key):
                receipt = self.valid_receipt()
                receipt["media_transaction_result"]["runs"][0]["frame_observations"][0][key] = value
                self.assertTrue(any("media frame semantics" in error for error in self.receipt_errors(receipt)))

    def test_receipt_rejects_missing_failed_or_fabricated_metrics(self) -> None:
        missing = self.valid_receipt()
        missing["metric_results"].pop()
        self.assertTrue(any("metric IDs" in error for error in self.receipt_errors(missing)))

        failed = self.valid_receipt()
        failed["metric_results"][0]["value"] = 1
        self.assertTrue(any("functional floor failed" in error for error in self.receipt_errors(failed)))

        fabricated = self.valid_receipt()
        fabricated["metric_results"][11].update(status="measured", value=0, reason=None)
        self.assertTrue(any("not-applicable disposition" in error for error in self.receipt_errors(fabricated)))

    def test_receipt_rejects_missing_source_test_and_artifact_bindings(self) -> None:
        for key in ("source_bindings", "test_bindings", "artifact_bindings"):
            with self.subTest(key=key):
                receipt = self.valid_receipt()
                receipt[key].pop(0)
                self.assertTrue(self.receipt_errors(receipt))

    def test_receipt_rejects_extra_or_reordered_bindings_and_revision_drift(self) -> None:
        for key in ("source_bindings", "test_bindings", "artifact_bindings"):
            with self.subTest(key=key):
                receipt = self.valid_receipt()
                receipt[key].append(
                    fake_binding(f"extra/{key}.json", f"extra_{key}")
                )
                self.assertTrue(
                    any("IDs/order differ" in error for error in self.receipt_errors(receipt))
                )

                receipt = self.valid_receipt()
                receipt[key][0], receipt[key][1] = receipt[key][1], receipt[key][0]
                self.assertTrue(
                    any("IDs/order differ" in error for error in self.receipt_errors(receipt))
                )

        receipt = self.valid_receipt()
        receipt["processing_identity"]["backend_revision"] = "2"
        self.assertTrue(
            any("processing identity differs" in error for error in self.receipt_errors(receipt))
        )

    def test_receipt_rejects_fabricated_simulator_observation(self) -> None:
        receipt = self.valid_receipt()
        receipt["observation_status"]["simulator_execution"] = "observed"
        self.assertTrue(any("contradictory" in error for error in self.receipt_errors(receipt)))

    def test_decision_is_exactly_derived_and_preserves_boundary(self) -> None:
        receipt = self.valid_receipt()
        bindings = {
            "preregistration_binding": fake_binding(PREREGISTRATION_PATH.as_posix()),
            "fixture_catalog_binding": fake_binding(FIXTURE_CATALOG_PATH.as_posix()),
            "receipt_binding": fake_binding("receipt.json"),
            "validator_binding": fake_binding("Scripts/r03_product_qualification.py"),
        }
        decision = self.verifier.expected_decision(receipt, **bindings)
        schema = read_json(DECISION_SCHEMA_PATH)
        self.assertEqual(validate_json_schema_instance(schema, decision), [])
        self.assertEqual(decision["result"]["phase_status"], "in_progress")
        self.assertEqual(decision["result"]["product_qualification"], "product_qualified")
        self.assertIsNone(decision["result"]["default_backend_id"])

        errors: list[str] = []
        self.verifier._check_decision_semantics(decision, receipt, errors, **bindings)
        self.assertEqual(errors, [])
        fabricated = copy.deepcopy(decision)
        fabricated["result"]["acceptance"] = "accepted"
        errors = []
        self.verifier._check_decision_semantics(fabricated, receipt, errors, **bindings)
        self.assertTrue(any("not exactly derived" in error for error in errors))

    def test_decision_check_ids_are_unique_and_exact(self) -> None:
        receipt = self.valid_receipt()
        decision = self.verifier.expected_decision(
            receipt,
            preregistration_binding=fake_binding(PREREGISTRATION_PATH.as_posix()),
            fixture_catalog_binding=fake_binding(FIXTURE_CATALOG_PATH.as_posix()),
            receipt_binding=fake_binding("receipt.json"),
            validator_binding=fake_binding("Scripts/r03_product_qualification.py"),
        )
        ids = [item["id"] for item in decision["derived_checks"]]
        self.assertEqual(ids, list(CHECK_IDS))
        self.assertEqual(len(ids), len(set(ids)))

    def test_assembler_requires_exact_passing_selected_test_summary(self) -> None:
        summary = self.valid_test_summary()
        errors: list[str] = []
        self.verifier._check_test_summary(
            summary, errors, expected_selected_count=MINIMUM_SELECTED_TEST_COUNT
        )
        self.assertEqual(errors, [])

        failed = copy.deepcopy(summary)
        failed["passed_test_count"] = 11
        failed["failed_test_count"] = 1
        errors = []
        self.verifier._check_test_summary(
            failed, errors, expected_selected_count=MINIMUM_SELECTED_TEST_COUNT
        )
        self.assertTrue(any("not an exact passing selection" in error for error in errors))

        later_exact = self.valid_test_summary(MINIMUM_SELECTED_TEST_COUNT + 1)
        errors = []
        self.verifier._check_test_summary(
            later_exact,
            errors,
            expected_selected_count=MINIMUM_SELECTED_TEST_COUNT + 1,
        )
        self.assertEqual(errors, [])

    def test_xcresult_summary_is_mechanically_derived_from_raw_results(self) -> None:
        raw_summary, raw_tests = self.valid_raw_xcresult()
        toolchain = self.valid_test_summary()["toolchain"]
        errors: list[str] = []
        summary = self.verifier._derive_xcresult_summary(
            raw_summary=raw_summary,
            raw_tests=raw_tests,
            expected_test_count=MINIMUM_SELECTED_TEST_COUNT,
            toolchain=toolchain,
            qualification_invocation=self.valid_qualification_invocation(),
            errors=errors,
        )
        self.assertEqual(errors, [])
        self.assertEqual(
            summary["selected_test_count"], MINIMUM_SELECTED_TEST_COUNT
        )
        self.assertEqual(summary["passed_test_count"], MINIMUM_SELECTED_TEST_COUNT)
        self.assertEqual(summary["failed_test_count"], 0)
        self.assertEqual(summary["skipped_test_count"], 0)
        self.assertEqual(
            summary["test_identifiers"],
            sorted(self.valid_test_summary()["test_identifiers"]),
        )

    def test_xcresult_summary_rejects_failure_duplicate_and_suite_omission(self) -> None:
        raw_summary, raw_tests = self.valid_raw_xcresult()
        toolchain = self.valid_test_summary()["toolchain"]
        raw_summary["passedTests"] = 11
        raw_summary["failedTests"] = 1
        raw_summary["result"] = "Failed"
        raw_summary["testFailures"] = [{"testIdentifier": "failing"}]
        raw_tests["testNodes"][0]["result"] = "Failed"
        raw_tests["testNodes"][1]["nodeIdentifier"] = raw_tests["testNodes"][0][
            "nodeIdentifier"
        ]
        raw_tests["testNodes"][2]["nodeIdentifier"] = (
            "R03A11NativeMPSProductTests/testReplacement()"
        )
        errors: list[str] = []
        self.verifier._derive_xcresult_summary(
            raw_summary=raw_summary,
            raw_tests=raw_tests,
            expected_test_count=MINIMUM_SELECTED_TEST_COUNT,
            toolchain=toolchain,
            qualification_invocation=self.valid_qualification_invocation(),
            errors=errors,
        )
        self.assertTrue(any("zero-failure" in error for error in errors))
        self.assertTrue(any("did not pass" in error for error in errors))
        self.assertTrue(any("not unique" in error for error in errors))
        self.assertTrue(any("omits required test" in error for error in errors))

    def test_xcresult_summary_rejects_missing_result_and_token_spoofing(self) -> None:
        raw_summary, raw_tests = self.valid_raw_xcresult()
        toolchain = self.valid_test_summary()["toolchain"]
        for node in raw_tests["testNodes"]:
            node.pop("result")
            node["nodeIdentifier"] = (
                "FakeSuite/test_"
                + node["nodeIdentifier"].replace("/", "_").replace("()", "")
                + "()"
            )
        errors: list[str] = []
        self.verifier._derive_xcresult_summary(
            raw_summary=raw_summary,
            raw_tests=raw_tests,
            expected_test_count=MINIMUM_SELECTED_TEST_COUNT,
            toolchain=toolchain,
            qualification_invocation=self.valid_qualification_invocation(),
            errors=errors,
        )
        self.assertTrue(any("did not pass" in error for error in errors))
        self.assertTrue(any("omits required test" in error for error in errors))
        self.assertTrue(any("outside the exact qualification suites" in error for error in errors))

    def test_native_route_observations_are_strictly_normalized(self) -> None:
        raw = self.valid_native_route_observations()
        errors: list[str] = []
        transformed = self.verifier._transform_native_route_observations(raw, errors)
        self.assertEqual(errors, [])
        self.assertIsNotNone(transformed)
        processing_identity, route_results = transformed
        self.assertEqual(
            processing_identity,
            {
                **CANDIDATE_IDENTITY,
                "backend_revision": "1",
                "model_assets_identity": "notRequired",
                "fallback_history": [],
            },
        )
        self.assertEqual(
            [route["route_id"] for route in route_results],
            [route["id"] for route in ROUTE_CONTRACTS],
        )
        self.assertEqual(
            [run["run_ordinal"] for run in route_results[0]["runs"]],
            [1, 2, 3],
        )

    def test_native_route_transform_rejects_identity_hash_and_contract_drift(self) -> None:
        mutations = []
        identity = self.valid_native_route_observations()
        identity["backend_identity"]["policy_identity"] = "wrong"
        mutations.append(identity)
        revision = self.valid_native_route_observations()
        revision["backend_identity"]["backend_revision"] = "2"
        mutations.append(revision)
        dimensions = self.valid_native_route_observations()
        dimensions["routes"][0]["input_identity"]["dimensions"]["width"] = 1
        mutations.append(dimensions)
        input_hash = self.valid_native_route_observations()
        for run in input_hash["routes"][0]["runs"]:
            run["logical_input_sha256"] = "f" * 64
        mutations.append(input_hash)
        output_hash = self.valid_native_route_observations()
        output_hash["routes"][0]["runs"][2]["logical_output_sha256"] = "e" * 64
        mutations.append(output_hash)
        ordinal = self.valid_native_route_observations()
        ordinal["routes"][0]["runs"][0]["run_ordinal"] = 2
        mutations.append(ordinal)
        timing = self.valid_native_route_observations()
        timing["routes"][0]["runs"][0]["presentation_timestamp"]["value"] = 31
        mutations.append(timing)
        lifecycle = self.valid_native_route_observations()
        lifecycle["routes"][0]["runs"][0]["lifecycle_observation"][
            "processed_history_generation"
        ] = 1
        mutations.append(lifecycle)
        reset_generations = self.valid_native_route_observations()
        reset_generations["routes"][0]["runs"][0]["lifecycle_observation"][
            "reset_next_history_generations"
        ] = [1, 3]
        mutations.append(reset_generations)
        fallback = self.valid_native_route_observations()
        fallback["routes"][0]["runs"][0]["fallback_history"] = ["fallback"]
        mutations.append(fallback)

        for mutation in mutations:
            with self.subTest(mutation=mutations.index(mutation)):
                errors: list[str] = []
                self.verifier._transform_native_route_observations(mutation, errors)
                self.assertTrue(errors)

    def test_qualification_invocation_rejects_splicing_or_digest_drift(self) -> None:
        invocation = self.valid_qualification_invocation()
        self.assertEqual(
            invocation["contract_id"], QUALIFICATION_INVOCATION_CONTRACT_ID
        )
        errors: list[str] = []
        observed = self.verifier._check_qualification_invocation(
            invocation,
            "test",
            errors,
            expected_source=("a" * 40, "b" * 40),
        )
        self.assertEqual(errors, [])
        self.assertEqual(observed, invocation)

        for key, value in (
            ("batch_id", "d" * 64),
            ("source_commit", "d" * 40),
            ("source_tree", "d" * 40),
            ("binding_sha256", "d" * 64),
        ):
            with self.subTest(key=key):
                mutated = copy.deepcopy(invocation)
                mutated[key] = value
                errors = []
                self.verifier._check_qualification_invocation(
                    mutated,
                    "test",
                    errors,
                    expected_source=("a" * 40, "b" * 40),
                )
                self.assertTrue(errors)

    def test_media_audio_hash_accepts_runtime_identity_but_rejects_invalid_hashes(self) -> None:
        receipt = self.valid_receipt()
        for ordinal, run in enumerate(
            receipt["media_transaction_result"]["runs"], start=10
        ):
            run["audio_semantic_sha256"] = format(ordinal, "064x")
        self.assertEqual(self.receipt_errors(receipt), [])

        for invalid_hash in ("0" * 64, "A" * 64, "f" * 63):
            with self.subTest(invalid_hash=invalid_hash):
                invalid = copy.deepcopy(receipt)
                invalid["media_transaction_result"]["runs"][0][
                    "audio_semantic_sha256"
                ] = invalid_hash
                self.assertTrue(
                    any(
                        "audio identity differs" in error
                        for error in self.receipt_errors(invalid)
                    )
                )

    def test_assembler_rejects_media_input_ordinal_drift(self) -> None:
        document = {
            "schema_version": "1.0.0",
            "evidence_kind": "r03_a11_media_transaction_observation_v1",
            "fixture_id": "r03-v2-media-transaction-2x",
            "qualification_invocation": self.valid_qualification_invocation(),
            "run": {"run_ordinal": 2},
        }
        errors: list[str] = []
        self.verifier._check_media_observation_document(document, 1, errors)
        self.assertTrue(any("identity differs" in error for error in errors))

    def test_xcodebuild_log_rejects_failure_and_private_identity(self) -> None:
        errors: list[str] = []
        self.verifier._check_xcodebuild_log_text(
            "** TEST SUCCEEDED **\n/Users/private/DerivedData\n",
            errors,
        )
        self.assertTrue(any("private filesystem path" in error for error in errors))

        errors = []
        self.verifier._check_xcodebuild_log_text(
            "** TEST SUCCEEDED **\n** TEST FAILED **\n",
            errors,
        )
        self.assertTrue(any("does not record test success" in error for error in errors))

        invocation = self.valid_qualification_invocation()
        valid_log = (
            f"R03_QUALIFICATION_INVOCATION_SHA256={invocation['binding_sha256']}\n"
            "** TEST SUCCEEDED **\n"
        )
        errors = []
        self.verifier._check_xcodebuild_log_text(
            valid_log,
            errors,
            expected_invocation=invocation,
        )
        self.assertEqual(errors, [])

        errors = []
        self.verifier._check_xcodebuild_log_text(
            "** TEST SUCCEEDED **\n",
            errors,
            expected_invocation=invocation,
        )
        self.assertTrue(any("invocation marker" in error for error in errors))

    def test_bound_xcresult_summary_rejects_private_identity(self) -> None:
        summary = self.valid_test_summary()
        summary["test_identifiers"][-1] = "/Users/private/testIdentifier"
        errors: list[str] = []
        self.verifier._check_test_summary(summary, errors)
        self.assertTrue(any("private filesystem path" in error for error in errors))

    def test_assembler_rejects_commit_tree_mismatch_or_dirty_source(self) -> None:
        errors: list[str] = []
        self.verifier._check_implementation_source("0" * 40, "1" * 40, errors)
        self.assertTrue(any("commit differs" in error for error in errors))
        self.assertTrue(any("tree differs" in error for error in errors))


if __name__ == "__main__":
    unittest.main()
