from __future__ import annotations

import copy
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPOSITORY_ROOT / "Scripts"))

from r02_contracts import (  # noqa: E402
    CATALOG_SCENARIO_IDS,
    CONFORMANCE_CHECK_IDS,
    CONFORMANCE_TRACEABILITY,
    CONFORMANCE_PATH,
    CONFORMANCE_SCHEMA_PATH,
    EXPECTED_BACKEND_SCENARIO_IDS,
    EXPECTED_CONFORMANCE_LIMITATIONS,
    EXPECTED_CONFORMANCE_METRIC_VALUES,
    EXPECTED_CONFORMANCE_OBSERVATION_STATUS,
    EXPECTED_CATALOG_SCENARIOS,
    FIXTURE_CATALOG_PATH,
    FIXTURE_CATALOG_SCHEMA_PATH,
    FIXTURE_BACKEND_IDS,
    FIXTURE_IDS,
    FIXTURE_GENERATOR_PATH,
    METRIC_CONTRACTS,
    OUTCOMES,
    PREREGISTRATION_PATH,
    PREREGISTRATION_SCHEMA_PATH,
    R01_CAPABILITY_MATRIX_PATH,
    R02ContractVerifier,
    LIFECYCLE_CONTRACTS,
    SCENARIO_CONTRACTS,
    expected_outcome_coverage,
)


class ConformanceGitStubVerifier(R02ContractVerifier):
    source_commit = "a" * 40
    source_tree = "b" * 40

    def git(self, *arguments: str) -> subprocess.CompletedProcess[str]:
        joined = " ".join(arguments)
        if self.source_commit in joined:
            if arguments[0] == "rev-parse":
                return subprocess.CompletedProcess(
                    arguments, 0, stdout=f"{self.source_tree}\n", stderr=""
                )
            return subprocess.CompletedProcess(arguments, 0, stdout="", stderr="")
        return super().git(*arguments)

    def git_bytes(self, *arguments: str) -> subprocess.CompletedProcess[bytes]:
        prefix = f"{self.source_commit}:"
        if arguments[0] == "show" and arguments[1].startswith(prefix):
            relative = Path(arguments[1][len(prefix) :])
            return subprocess.CompletedProcess(
                arguments,
                0,
                stdout=(REPOSITORY_ROOT / relative).read_bytes(),
                stderr=b"",
            )
        return super().git_bytes(*arguments)


class R02ContractTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary_directory.name)
        for relative in (
            PREREGISTRATION_PATH,
            PREREGISTRATION_SCHEMA_PATH,
            FIXTURE_CATALOG_PATH,
            FIXTURE_CATALOG_SCHEMA_PATH,
            CONFORMANCE_SCHEMA_PATH,
            FIXTURE_GENERATOR_PATH,
            R01_CAPABILITY_MATRIX_PATH,
        ):
            destination = self.root / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(REPOSITORY_ROOT / relative, destination)
        self.preregistration = self.read(PREREGISTRATION_PATH)
        self.catalog = self.read(FIXTURE_CATALOG_PATH)

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def read(self, relative: Path) -> dict[str, object]:
        return json.loads((self.root / relative).read_text(encoding="utf-8"))

    def write(self, relative: Path, value: object) -> None:
        (self.root / relative).write_text(
            json.dumps(value, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )

    def verifier(self) -> R02ContractVerifier:
        return R02ContractVerifier(self.root, REPOSITORY_ROOT)

    def conformance_verifier(self) -> R02ContractVerifier:
        return ConformanceGitStubVerifier(self.root, REPOSITORY_ROOT)

    def errors(self) -> list[str]:
        return self.verifier().check_preregistration()

    def file_binding(self, relative: Path) -> dict[str, object]:
        payload = (self.root / relative).read_bytes()
        return {
            "path": relative.as_posix(),
            "size_bytes": len(payload),
            "sha256": hashlib.sha256(payload).hexdigest(),
        }

    def valid_conformance(self) -> dict[str, object]:
        backend_runs = []
        for index, backend_id in enumerate(FIXTURE_BACKEND_IDS):
            backend_runs.append(
                {
                    "admission_scope": "fixture_only_nonproduction",
                    "fixture_ids": list(FIXTURE_IDS),
                    "identity": {
                        "backend_id": backend_id,
                        "backend_revision": "1",
                        "configuration_identity": "r02-fixture-copy-v1",
                        "fallback_history": [],
                        "material_decision_identity": (
                            "r02-fixture-copy-decision-v1"
                        ),
                        "model_assets_identity": {
                            "disposition": "not_required",
                            "identifiers": [],
                        },
                        "policy_identity": "r02-fixture-only-v1",
                    },
                    "result": "passed",
                    "scenario_ids": list(
                        EXPECTED_BACKEND_SCENARIO_IDS[backend_id]
                    ),
                    "selected_primary": index == 0,
                    "session_contract": "apple-upscale-session-v1",
                    "terminalization_count": 1,
                }
            )
        metrics = [
            {
                "direction": direction,
                "floor": floor,
                "id": metric_id,
                "operator": operator,
                "passed": True,
                "unit": unit,
                "value": EXPECTED_CONFORMANCE_METRIC_VALUES[metric_id],
            }
            for metric_id, unit, direction, operator, floor in METRIC_CONTRACTS
        ]
        return {
            "backend_runs": backend_runs,
            "checks": [
                {"id": check_id, "status": "passed"}
                for check_id in CONFORMANCE_CHECK_IDS
            ],
            "evidence_kind": "deterministic_software_conformance",
            "fixture_catalog_binding": self.file_binding(FIXTURE_CATALOG_PATH),
            "limitations": list(EXPECTED_CONFORMANCE_LIMITATIONS),
            "observation_status": dict(
                EXPECTED_CONFORMANCE_OBSERVATION_STATUS
            ),
            "outcome_coverage": expected_outcome_coverage(),
            "phase_id": "R02",
            "preregistration_binding": self.file_binding(PREREGISTRATION_PATH),
            "result": {
                "authorization": {
                    "auto_mode": "blocked",
                    "holdout": "blocked",
                    "phase_acceptance": "not_claimed",
                    "performance_claims": "forbidden",
                    "publication": "not_authorized_by_this_record",
                    "product_eligibility": "not_authorized",
                    "production_enablement": "not_authorized",
                    "release": "not_authorized",
                },
                "metrics": metrics,
                "production_composition": {
                    "fixture_backend_reachable": False,
                    "service_type": "UnavailableUpscalerEngineService",
                    "status": "unavailable",
                },
                "status": "passed",
            },
            "roadmap_version": "1.0.1",
            "schema_version": "1.0.0",
            "source": {
                "commit": ConformanceGitStubVerifier.source_commit,
                "tree": ConformanceGitStubVerifier.source_tree,
            },
        }

    def conformance_errors(self, record: dict[str, object]) -> list[str]:
        self.write(CONFORMANCE_PATH, record)
        return self.conformance_verifier().check_conformance()

    def assert_conformance_error_contains(
        self, record: dict[str, object], fragment: str
    ) -> None:
        errors = self.conformance_errors(record)
        self.assertTrue(
            any(fragment in error for error in errors),
            f"expected {fragment!r}; found {errors!r}",
        )

    def assert_error_contains(self, fragment: str) -> None:
        errors = self.errors()
        self.assertTrue(
            any(fragment in error for error in errors),
            f"expected {fragment!r}; found {errors!r}",
        )

    def test_repository_contract_is_valid(self) -> None:
        self.assertEqual(R02ContractVerifier(REPOSITORY_ROOT).check_preregistration(), [])
        self.assertEqual(R02ContractVerifier(REPOSITORY_ROOT).check_fixtures(), [])

    def test_copied_contract_is_valid(self) -> None:
        self.assertEqual(self.errors(), [])

    def test_synthetic_conformance_contract_is_valid(self) -> None:
        self.assertEqual(self.conformance_errors(self.valid_conformance()), [])

    def test_conformance_traceability_covers_every_frozen_requirement(self) -> None:
        expected_sources = {
            "contract.capability_registry",
            "contract.backend_contract",
            "contract.frame_fields",
            "contract.outcome_vocabulary",
            "contract.stage_protocols",
            "contract.planner_contract",
            "contract.processing_identity_fields",
            "contract.production_composition",
            *(f"lifecycle.{item[0]}" for item in LIFECYCLE_CONTRACTS),
            *(f"scenario.{item[0]}" for item in SCENARIO_CONTRACTS),
            *(
                f"catalog.required_check.{check_id}"
                for scenario in EXPECTED_CATALOG_SCENARIOS
                for check_id in scenario["required_checks"]
            ),
        }
        self.assertEqual(set(CONFORMANCE_TRACEABILITY), expected_sources)
        self.assertEqual(
            {
                target
                for targets in CONFORMANCE_TRACEABILITY.values()
                for target in targets
            },
            set(CONFORMANCE_CHECK_IDS),
        )

    def test_conformance_identity_must_be_complete(self) -> None:
        record = self.valid_conformance()
        record["backend_runs"][0]["identity"].pop("fallback_history")
        self.assert_conformance_error_contains(record, "processing identity differs")

    def test_conformance_outcome_identity_must_be_complete(self) -> None:
        record = self.valid_conformance()
        record["outcome_coverage"][0]["processing_identity"].pop(
            "material_decision_identity"
        )
        self.assert_conformance_error_contains(record, "outcome coverage differs")

    def test_conformance_check_cannot_be_not_observed(self) -> None:
        record = self.valid_conformance()
        record["checks"][0]["status"] = "not_observed"
        self.assert_conformance_error_contains(record, "software checks differ")

    def test_conformance_check_set_is_exact_and_ordered(self) -> None:
        mutations = ("missing", "reordered", "duplicate", "unknown")
        for mutation in mutations:
            with self.subTest(mutation=mutation):
                record = self.valid_conformance()
                checks = record["checks"]
                if mutation == "missing":
                    checks.pop()
                elif mutation == "reordered":
                    checks[0], checks[1] = checks[1], checks[0]
                elif mutation == "duplicate":
                    checks[-1] = copy.deepcopy(checks[0])
                else:
                    checks[-1]["id"] = "unknown_check"
                self.assert_conformance_error_contains(
                    record, "software checks differ"
                )

    def test_conformance_must_cover_every_outcome(self) -> None:
        record = self.valid_conformance()
        record["outcome_coverage"].pop()
        self.assert_conformance_error_contains(record, "outcome coverage differs")

    def test_conformance_fallback_requires_linked_identities(self) -> None:
        record = self.valid_conformance()
        record["outcome_coverage"][-1]["processing_identity"][
            "fallback_history"
        ] = []
        self.assert_conformance_error_contains(record, "outcome coverage differs")

    def test_conformance_fallback_routes_must_be_distinct_and_known(self) -> None:
        mutations = ("same_route", "unknown_route", "selected_mismatch")
        for mutation in mutations:
            with self.subTest(mutation=mutation):
                record = self.valid_conformance()
                fallback_identity = record["outcome_coverage"][-1][
                    "processing_identity"
                ]
                link = fallback_identity["fallback_history"][0]
                if mutation == "same_route":
                    link["selected_identity"] = copy.deepcopy(
                        link["failed_identity"]
                    )
                elif mutation == "unknown_route":
                    link["selected_identity"]["backend_id"] = "r02.fixture.unknown"
                else:
                    fallback_identity["backend_id"] = FIXTURE_BACKEND_IDS[0]
                self.assert_conformance_error_contains(
                    record, "outcome coverage differs"
                )

    def test_nonfallback_outcome_cannot_carry_fallback_history(self) -> None:
        record = self.valid_conformance()
        record["outcome_coverage"][0]["processing_identity"][
            "fallback_history"
        ] = copy.deepcopy(
            record["outcome_coverage"][-1]["processing_identity"][
                "fallback_history"
            ]
        )
        self.assert_conformance_error_contains(record, "outcome coverage differs")

    def test_conformance_requires_both_fixture_backends(self) -> None:
        record = self.valid_conformance()
        record["backend_runs"].pop()
        self.assert_conformance_error_contains(
            record, "both fixture-only backends in frozen order"
        )

    def test_conformance_cannot_overstate_backend_scenario_coverage(self) -> None:
        record = self.valid_conformance()
        record["backend_runs"][1]["scenario_ids"] = list(CATALOG_SCENARIO_IDS)
        self.assert_conformance_error_contains(record, "scenario coverage differs")

    def test_conformance_requires_exactly_one_selected_primary(self) -> None:
        record = self.valid_conformance()
        record["backend_runs"][1]["selected_primary"] = True
        self.assert_conformance_error_contains(record, "primary selection differs")

    def test_conformance_requires_at_least_one_selected_primary(self) -> None:
        record = self.valid_conformance()
        record["backend_runs"][0]["selected_primary"] = False
        self.assert_conformance_error_contains(record, "primary selection differs")

    def test_conformance_requires_one_terminalization_per_session(self) -> None:
        record = self.valid_conformance()
        record["backend_runs"][0]["terminalization_count"] = 2
        self.assert_conformance_error_contains(record, "terminalization count differs")

    def test_conformance_cannot_reach_fixture_backend_from_production(self) -> None:
        record = self.valid_conformance()
        record["result"]["production_composition"][
            "fixture_backend_reachable"
        ] = True
        self.assert_conformance_error_contains(
            record, "result differs from the frozen contract"
        )

    def test_conformance_cannot_authorize_product_eligibility(self) -> None:
        record = self.valid_conformance()
        record["result"]["authorization"]["product_eligibility"] = "authorized"
        self.assert_conformance_error_contains(
            record, "result differs from the frozen contract"
        )

    def test_conformance_cannot_claim_acceptance_or_publication(self) -> None:
        for key, value in (
            ("phase_acceptance", "accepted"),
            ("publication", "authorized"),
        ):
            with self.subTest(key=key):
                record = self.valid_conformance()
                record["result"]["authorization"][key] = value
                self.assert_conformance_error_contains(
                    record, "result differs from the frozen contract"
                )

    def test_conformance_derived_metrics_must_match_evidence(self) -> None:
        for metric_id in (
            "backend_count",
            "fixture_count",
            "primary_backend_count",
            "outcome_case_count",
            "terminalizations_per_session",
            "production_backend_count",
        ):
            with self.subTest(metric_id=metric_id):
                record = self.valid_conformance()
                metric = next(
                    item
                    for item in record["result"]["metrics"]
                    if item["id"] == metric_id
                )
                metric["value"] += 1
                self.assert_conformance_error_contains(
                    record, f"not derived from evidence: {metric_id}"
                )

    def test_conformance_cannot_fabricate_hardware_observation(self) -> None:
        record = self.valid_conformance()
        record["observation_status"]["hardware_capability_observation"] = "observed"
        self.assert_conformance_error_contains(
            record, "observation status differs from the operator override"
        )

    def test_conformance_binding_drift_fails(self) -> None:
        record = self.valid_conformance()
        record["fixture_catalog_binding"]["sha256"] = "1" * 64
        self.assert_conformance_error_contains(
            record, "fixture_catalog_binding.sha256 differs"
        )

    def test_conformance_source_must_follow_r01_closure(self) -> None:
        record = self.valid_conformance()
        record["source"] = {
            "commit": "555ae5a1afce1e492bdc89b6b14f2ba269edc524",
            "tree": "2fbe72d85ace42cc925c45b17d53dd8866a8275b",
        }
        self.assert_conformance_error_contains(
            record, "strict descendant of the R01 closure"
        )

    def test_conformance_source_must_contain_frozen_schema_bytes(self) -> None:
        record = self.valid_conformance()
        schema = self.read(CONFORMANCE_SCHEMA_PATH)
        schema["title"] = "drift"
        self.write(CONFORMANCE_SCHEMA_PATH, schema)
        self.assert_conformance_error_contains(
            record, "does not contain the bound R02 contract bytes"
        )

    def test_nonnull_merge_commit_cannot_fabricate_acceptance(self) -> None:
        self.preregistration["predecessor_binding"]["accepted_merge_commit"] = "1" * 40
        self.write(PREREGISTRATION_PATH, self.preregistration)
        self.assert_error_contains("exact local unpublished closure truth")

    def test_predecessor_tree_drift_fails(self) -> None:
        self.preregistration["predecessor_binding"]["closure_tree"] = "1" * 40
        self.write(PREREGISTRATION_PATH, self.preregistration)
        self.assert_error_contains("exact local unpublished closure truth")

    def test_observation_override_cannot_skip_software_conformance(self) -> None:
        self.preregistration["observation_policy"][
            "deterministic_software_conformance"
        ] = "waived"
        self.write(PREREGISTRATION_PATH, self.preregistration)
        self.assert_error_contains("observation policy differs")

    def test_observation_cannot_claim_performance(self) -> None:
        self.preregistration["observation_policy"]["performance_claims"] = "allowed"
        self.write(PREREGISTRATION_PATH, self.preregistration)
        self.assert_error_contains("observation policy differs")

    def test_authorization_boundary_drift_fails(self) -> None:
        self.preregistration["authorization_boundary"]["publication"] = "authorized"
        self.write(PREREGISTRATION_PATH, self.preregistration)
        self.assert_error_contains("authorization boundary differs")

    def test_capability_source_mutation_fails_binding(self) -> None:
        matrix = self.read(R01_CAPABILITY_MATRIX_PATH)
        matrix["capabilities"][0]["anchor_records"][0][
            "runtime_disposition"
        ] = "runnable"
        self.write(R01_CAPABILITY_MATRIX_PATH, matrix)
        self.assert_error_contains("source_binding.sha256 differs")

    def test_capability_registry_cannot_infer_eligibility(self) -> None:
        self.preregistration["contract"]["capability_registry"][
            "eligibility_inference"
        ] = "allowed"
        self.write(PREREGISTRATION_PATH, self.preregistration)
        self.assert_error_contains("schema validation")

    def test_fixture_binding_hash_drift_fails(self) -> None:
        self.preregistration["fixture_catalog"]["sha256"] = "1" * 64
        self.write(PREREGISTRATION_PATH, self.preregistration)
        self.assert_error_contains("fixture_catalog.sha256 differs")

    def test_fixture_binding_rejects_path_escape(self) -> None:
        self.preregistration["fixture_catalog"]["path"] = "../fixture.json"
        self.write(PREREGISTRATION_PATH, self.preregistration)
        self.assert_error_contains("path differs from the frozen path")

    def test_fixture_semantic_hash_drift_fails(self) -> None:
        self.catalog["fixtures"][0]["seed"] += 1
        self.write(FIXTURE_CATALOG_PATH, self.catalog)
        self.assert_error_contains("fixture semantic SHA-256 differs")

    def test_generated_frame_hash_drift_fails(self) -> None:
        self.catalog["fixtures"][0]["frames"][0]["generated_content_sha256"] = (
            "1" * 64
        )
        self.write(FIXTURE_CATALOG_PATH, self.catalog)
        self.assert_error_contains("generated frame SHA-256 differs")

    def test_fixture_generator_source_drift_fails(self) -> None:
        generator_path = self.root / FIXTURE_GENERATOR_PATH
        generator_path.write_text(
            generator_path.read_text(encoding="utf-8") + "# drift\n",
            encoding="utf-8",
        )
        self.assert_error_contains("fixture_generator.source_binding.sha256 differs")

    def test_coordinated_schema_and_binding_drift_fails(self) -> None:
        schema = self.read(CONFORMANCE_SCHEMA_PATH)
        schema["title"] = "weakened"
        self.write(CONFORMANCE_SCHEMA_PATH, schema)
        payload = (self.root / CONFORMANCE_SCHEMA_PATH).read_bytes()
        binding = self.preregistration["contract"]["schema_bindings"][
            "conformance"
        ]
        binding["size_bytes"] = len(payload)
        binding["sha256"] = hashlib.sha256(payload).hexdigest()
        self.write(PREREGISTRATION_PATH, self.preregistration)
        self.assert_error_contains("schema bindings differ from the frozen contract")

    def test_fixture_sequence_must_be_contiguous(self) -> None:
        self.catalog["fixtures"][0]["frames"][1]["sequence_number"] = 9
        self.write(FIXTURE_CATALOG_PATH, self.catalog)
        self.assert_error_contains("sequence is not contiguous")

    def test_fixture_duration_must_be_positive(self) -> None:
        self.catalog["fixtures"][0]["frames"][1]["duration"]["value"] = 0
        self.write(FIXTURE_CATALOG_PATH, self.catalog)
        self.assert_error_contains("duration is not positive")

    def test_fixture_pts_must_increase(self) -> None:
        self.catalog["fixtures"][0]["frames"][1]["pts"]["value"] = 0
        self.write(FIXTURE_CATALOG_PATH, self.catalog)
        self.assert_error_contains("PTS is not increasing")

    def test_fixture_resource_tokens_must_be_unique(self) -> None:
        frames = self.catalog["fixtures"][0]["frames"]
        frames[1]["resource_token_id"] = frames[0]["resource_token_id"]
        self.write(FIXTURE_CATALOG_PATH, self.catalog)
        self.assert_error_contains("metadata/token identities are not unique")

    def test_media_fixture_requires_audio(self) -> None:
        self.catalog["fixtures"][2]["audio_contract"] = None
        self.write(FIXTURE_CATALOG_PATH, self.catalog)
        self.assert_error_contains("must include one AAC audio contract")

    def test_media_fixture_source_pcm_hash_drift_fails(self) -> None:
        self.catalog["fixtures"][2]["audio_contract"]["source_pcm_sha256"] = (
            "1" * 64
        )
        self.write(FIXTURE_CATALOG_PATH, self.catalog)
        self.assert_error_contains("source PCM SHA-256 differs")

    def test_media_fixture_requires_reopen_and_atomic_publication(self) -> None:
        self.catalog["fixtures"][2]["container_contract"][
            "reopen_required"
        ] = False
        self.write(FIXTURE_CATALOG_PATH, self.catalog)
        self.assert_error_contains("must require reopen verification")

    def test_common_session_scenario_requires_both_backends(self) -> None:
        self.catalog["scenarios"][0]["backend_ids"] = ["r02.fixture.copy-a"]
        self.write(FIXTURE_CATALOG_PATH, self.catalog)
        self.assert_error_contains("must name both fixture backends")

    def test_common_session_scenario_requires_both_frame_fixtures(self) -> None:
        self.catalog["scenarios"][0]["fixture_ids"] = ["fixture-sequence-a"]
        self.write(FIXTURE_CATALOG_PATH, self.catalog)
        self.assert_error_contains("must use both frame fixtures")

    def test_coordinated_catalog_scenario_and_binding_drift_fails(self) -> None:
        checks = self.catalog["scenarios"][3]["required_checks"]
        checks[checks.index("audio_preserved")] = "audio_discarded"
        self.write(FIXTURE_CATALOG_PATH, self.catalog)
        payload = (self.root / FIXTURE_CATALOG_PATH).read_bytes()
        self.preregistration["fixture_catalog"]["size_bytes"] = len(payload)
        self.preregistration["fixture_catalog"]["sha256"] = hashlib.sha256(
            payload
        ).hexdigest()
        self.write(PREREGISTRATION_PATH, self.preregistration)
        self.assert_error_contains("fixture scenarios differ from the frozen contract")

    def test_frame_contract_field_drift_fails(self) -> None:
        self.preregistration["contract"]["frame_fields"].pop()
        self.write(PREREGISTRATION_PATH, self.preregistration)
        self.assert_error_contains("frame fields differ")

    def test_outcome_vocabulary_drift_fails(self) -> None:
        self.preregistration["contract"]["outcome_vocabulary"].reverse()
        self.write(PREREGISTRATION_PATH, self.preregistration)
        self.assert_error_contains("outcome vocabulary differs")

    def test_stage_protocol_drift_fails(self) -> None:
        self.preregistration["contract"]["stage_protocols"].pop()
        self.write(PREREGISTRATION_PATH, self.preregistration)
        self.assert_error_contains("five-stage protocol vocabulary differs")

    def test_lifecycle_description_inversion_fails(self) -> None:
        requirements = self.preregistration["contract"]["lifecycle_requirements"]
        requirements[0]["description"], requirements[1]["description"] = (
            requirements[1]["description"],
            requirements[0]["description"],
        )
        self.write(PREREGISTRATION_PATH, self.preregistration)
        self.assert_error_contains("lifecycle requirements differ from the frozen text")

    def test_scenario_description_inversion_fails(self) -> None:
        scenarios = self.preregistration["contract"]["scenarios"]
        scenarios[0]["description"], scenarios[1]["description"] = (
            scenarios[1]["description"],
            scenarios[0]["description"],
        )
        self.write(PREREGISTRATION_PATH, self.preregistration)
        self.assert_error_contains("scenarios differ from the frozen text")

    def test_metric_floor_drift_fails(self) -> None:
        self.preregistration["metrics"][0]["floor"] = 1
        self.write(PREREGISTRATION_PATH, self.preregistration)
        self.assert_error_contains("metric records differ from the frozen contract")

    def test_metric_direction_drift_fails(self) -> None:
        self.preregistration["metrics"][0]["direction"] = "higher_is_better"
        self.write(PREREGISTRATION_PATH, self.preregistration)
        self.assert_error_contains("metric records differ from the frozen contract")

    def test_stop_rule_drift_fails(self) -> None:
        self.preregistration["stop_rules"][0]["id"] = "changed"
        self.write(PREREGISTRATION_PATH, self.preregistration)
        self.assert_error_contains("stop rules differ from the frozen text")

    def test_stop_rule_description_inversion_fails(self) -> None:
        rules = self.preregistration["stop_rules"]
        rules[0]["description"], rules[1]["description"] = (
            rules[1]["description"],
            rules[0]["description"],
        )
        self.write(PREREGISTRATION_PATH, self.preregistration)
        self.assert_error_contains("stop rules differ from the frozen text")

    def test_unknown_top_level_field_fails_closed_schema(self) -> None:
        mutated = copy.deepcopy(self.preregistration)
        mutated["unknown"] = True
        self.write(PREREGISTRATION_PATH, mutated)
        self.assert_error_contains("top-level keys differ")

    def test_null_contract_collections_fail_without_crashing(self) -> None:
        cases = (
            (("contract", "lifecycle_requirements"), "lifecycle requirements differ"),
            (("contract", "scenarios"), "scenarios differ"),
            (("metrics",), "metric records differ"),
            (("stop_rules",), "stop rules differ"),
        )
        for path, expected_error in cases:
            with self.subTest(path=path):
                mutated = copy.deepcopy(self.preregistration)
                target = mutated
                for key in path[:-1]:
                    target = target[key]
                target[path[-1]] = None
                self.write(PREREGISTRATION_PATH, mutated)
                self.assert_error_contains(expected_error)


if __name__ == "__main__":
    unittest.main()
