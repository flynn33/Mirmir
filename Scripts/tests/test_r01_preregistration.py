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

from r01_preregistration import (  # noqa: E402
    ANCHOR_CONTRACTS,
    FIXTURE_CATALOG_PATH,
    FIXTURE_CATALOG_SCHEMA_PATH,
    PREREGISTRATION_PATH,
    PREREGISTRATION_SCHEMA_PATH,
    ROADMAP_PATH,
    HostFactCollectionError,
    PreregistrationVerifier,
    _fixture_digest,
    check_materialized_fixtures,
    collect_host_facts,
    materialize_fixtures,
)


class R01PreregistrationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary_directory.name)
        for relative in (
            PREREGISTRATION_PATH,
            PREREGISTRATION_SCHEMA_PATH,
            FIXTURE_CATALOG_PATH,
            FIXTURE_CATALOG_SCHEMA_PATH,
            ROADMAP_PATH,
        ):
            destination = self.root / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(REPOSITORY_ROOT / relative, destination)
        self.preregistration = self.read_json(self.root / PREREGISTRATION_PATH)
        self.catalog = self.read_json(self.root / FIXTURE_CATALOG_PATH)

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    @staticmethod
    def read_json(path: Path) -> dict[str, object]:
        return json.loads(path.read_text(encoding="utf-8"))

    @staticmethod
    def write_json(path: Path, value: dict[str, object]) -> None:
        path.write_text(
            json.dumps(value, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )

    def write_preregistration(self) -> None:
        self.write_json(self.root / PREREGISTRATION_PATH, self.preregistration)

    def write_catalog(self) -> None:
        self.write_json(self.root / FIXTURE_CATALOG_PATH, self.catalog)

    def freeze_analysis_model(
        self,
        path: str = ".r01-local-assets/probe-model.bin",
        model_identity: str = "r01-core-ai-probe-model-v1",
    ) -> None:
        model = self.catalog["fixtures"][-1]
        model.update(
            {
                "status": "frozen",
                "materialization_path": path,
                "byte_count": 7,
                "content_sha256": hashlib.sha256(b"model-v1").hexdigest(),
                "model_identity": model_identity,
            }
        )
        self.write_catalog()
        catalog_payload = (self.root / FIXTURE_CATALOG_PATH).read_bytes()
        self.preregistration["fixture_catalog"]["sha256"] = hashlib.sha256(
            catalog_payload
        ).hexdigest()
        self.write_preregistration()

    def verifier(self) -> PreregistrationVerifier:
        return PreregistrationVerifier(self.root)

    def assert_error_contains(self, fragment: str) -> None:
        errors = self.verifier().check()
        self.assertTrue(
            any(fragment in error for error in errors),
            f"expected error containing {fragment!r}; found {errors!r}",
        )

    @staticmethod
    def profile(
        hardware_class: str,
        chip: str,
        os_version: str,
        xcode_version: str,
        sdk_version: str,
        suffix: str,
    ) -> dict[str, object]:
        return {
            "host_id": f"host-{suffix}",
            "model_identifier": f"Mac{suffix}",
            "hardware_class": hardware_class,
            "chip": chip,
            "memory_bytes": 16 * 1024 * 1024 * 1024,
            "os_version": os_version,
            "os_build": f"OS{suffix}",
            "xcode_version": xcode_version,
            "xcode_build": f"XC{suffix}",
            "sdk_version": sdk_version,
            "sdk_build": f"SDK{suffix}",
        }

    def assign_all_anchors(self) -> None:
        profiles = (
            self.profile("apple_silicon", "Apple M1", "15.4", "16.3", "15.4", "1"),
            self.profile("macbook_air", "Apple M3", "26.0", "26.0", "26.0", "2"),
            self.profile("pro_max_tier", "Apple M4 Pro", "26.5", "26.2", "26.2", "3"),
            self.profile("core_ai_capable", "Apple M4 Max", "27.0", "27.0", "27.0", "4"),
        )
        profiles[1]["model_identifier"] = "Mac15,12"
        assignments = self.preregistration["anchor_assignments"]
        self.assertIsInstance(assignments, list)
        for assignment, profile in zip(assignments, profiles):
            assignment["assignment_state"] = "assigned"
            assignment["host_profile"] = profile
        self.preregistration["preregistration_state"] = "live_assignments_frozen"
        self.write_preregistration()

    def test_repository_preregistration_is_valid(self) -> None:
        self.assertEqual(PreregistrationVerifier(REPOSITORY_ROOT).check(), [])

    def test_capabilities_are_exactly_a01_through_a18(self) -> None:
        capabilities = self.preregistration["capabilities"]
        self.assertEqual(
            [item["id"] for item in capabilities],
            [f"A{index:02d}" for index in range(1, 19)],
        )

    def test_probe_class_assignments_are_closed(self) -> None:
        by_class: dict[str, list[str]] = {}
        for capability in self.preregistration["capabilities"]:
            by_class.setdefault(capability["probe_class"], []).append(capability["id"])
        self.assertEqual(
            by_class,
            {
                "primary_scaler": [
                    "A01",
                    "A02",
                    "A06",
                    "A07",
                    "A08",
                    "A09",
                    "A11",
                    "A12",
                    "A14",
                    "A16",
                ],
                "cadence_transform": ["A03", "A10"],
                "support_filter": ["A04", "A13", "A15", "A17"],
                "temporal_analyzer": ["A05"],
                "analysis_runtime": ["A18"],
            },
        )

    def test_fixture_ids_are_exact_and_ordered(self) -> None:
        self.assertEqual(
            [item["id"] for item in self.catalog["fixtures"]],
            [
                "scaler-720p",
                "scaler-1080p",
                "support-frame",
                "support-guidance",
                "support-history",
                "temporal-frame-0",
                "temporal-frame-1",
                "cadence-frame-0",
                "cadence-frame-1",
                "analysis-proxy",
                "analysis-probe-model",
            ],
        )

    def test_frozen_fixture_hash_matches_generator(self) -> None:
        fixture = self.catalog["fixtures"][0]
        observed_size, observed_hash = _fixture_digest("nv12_frame", 1280, 720, 0)
        self.assertEqual(fixture["byte_count"], observed_size)
        self.assertEqual(fixture["content_sha256"], observed_hash)

    def small_fixture_catalog(self) -> dict[str, object]:
        byte_count, content_sha256 = _fixture_digest("nv12_frame", 4, 2, 0)
        return {
            "fixtures": [
                {
                    "id": "small-fixture",
                    "status": "frozen",
                    "media_kind": "nv12_frame",
                    "dimensions": {"width": 4, "height": 2},
                    "frame_index": 0,
                    "materialization_path": "fixtures/small.bin",
                    "byte_count": byte_count,
                    "content_sha256": content_sha256,
                },
                {
                    "id": "unassigned-model",
                    "status": "unassigned",
                    "materialization_path": None,
                },
            ]
        }

    def test_materialize_and_check_fixture_bytes(self) -> None:
        catalog = self.small_fixture_catalog()
        paths = materialize_fixtures(self.root, catalog)
        self.assertEqual(paths, [self.root.resolve() / "fixtures/small.bin"])
        self.assertEqual(check_materialized_fixtures(self.root, catalog), [])
        self.assertEqual(materialize_fixtures(self.root, catalog), paths)

    def test_materializer_refuses_to_overwrite_drifted_bytes(self) -> None:
        catalog = self.small_fixture_catalog()
        path = self.root / "fixtures/small.bin"
        path.parent.mkdir(parents=True)
        path.write_bytes(b"drift")
        with self.assertRaisesRegex(ValueError, "byte count differs"):
            materialize_fixtures(self.root, catalog)
        self.assertEqual(path.read_bytes(), b"drift")

    def test_materializer_rejects_symbolic_link_components(self) -> None:
        catalog = self.small_fixture_catalog()
        outside = self.root / "outside"
        outside.mkdir()
        (self.root / "fixtures").symlink_to(outside, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "symbolic link"):
            materialize_fixtures(self.root, catalog)

    def test_scaler_and_analysis_dimensions_are_frozen(self) -> None:
        fixtures = {item["id"]: item for item in self.catalog["fixtures"]}
        self.assertEqual(
            fixtures["scaler-720p"]["scale_output"],
            {"width": 1920, "height": 1080},
        )
        self.assertEqual(
            fixtures["scaler-1080p"]["scale_output"],
            {"width": 3840, "height": 2160},
        )
        self.assertEqual(
            fixtures["analysis-proxy"]["dimensions"],
            {"width": 512, "height": 288},
        )

    def test_cadence_timing_is_frozen(self) -> None:
        fixtures = {item["id"]: item for item in self.catalog["fixtures"]}
        self.assertEqual(
            fixtures["cadence-frame-0"]["timing"],
            {"pts": 0, "duration": 20, "timescale": 600},
        )
        self.assertEqual(
            fixtures["cadence-frame-1"]["timing"],
            {"pts": 20, "duration": 20, "timescale": 600},
        )

    def test_execution_counts_and_timeout_are_frozen(self) -> None:
        self.assertEqual(
            self.preregistration["execution_controls"],
            {
                "sessions": 3,
                "warm_up_units_per_session": 5,
                "measured_units_per_session": 30,
                "timeout_seconds_per_session": 120,
                "repeatability_observations": 3,
                "clock": "monotonic",
            },
        )

    def test_altered_fixture_fails_closed(self) -> None:
        self.catalog["fixtures"][0]["content_sha256"] = "0" * 64
        self.write_catalog()
        errors = self.verifier().check()
        self.assertTrue(any("catalog SHA-256 differs" in error for error in errors), errors)
        self.assertTrue(any("scaler-720p differs" in error for error in errors), errors)

    def test_altered_capability_class_fails(self) -> None:
        self.preregistration["capabilities"][0]["probe_class"] = "support_filter"
        self.write_preregistration()
        self.assert_error_contains("capability identities/classes")

    def test_altered_execution_control_fails(self) -> None:
        self.preregistration["execution_controls"]["sessions"] = 2
        self.write_preregistration()
        self.assert_error_contains("execution_controls differs")

    def test_altered_stop_rule_fails(self) -> None:
        self.preregistration["stop_rules"].pop()
        self.write_preregistration()
        self.assert_error_contains("stop_rules differs")

    def test_extra_claim_fails_closed_schema(self) -> None:
        self.preregistration["product_qualified"] = True
        self.write_preregistration()
        self.assert_error_contains("field is not allowed")

    def test_duplicate_json_key_is_rejected(self) -> None:
        path = self.root / PREREGISTRATION_PATH
        text = path.read_text(encoding="utf-8")
        text = text.replace(
            '  "phase_id": "R01",',
            '  "phase_id": "R01",\n  "phase_id": "R01",',
            1,
        )
        path.write_text(text, encoding="utf-8")
        self.assert_error_contains("duplicate JSON key: phase_id")

    def test_symbolic_link_catalog_is_rejected(self) -> None:
        catalog_path = self.root / FIXTURE_CATALOG_PATH
        target = self.root / "fixture-catalog-target.json"
        shutil.copy2(catalog_path, target)
        catalog_path.unlink()
        catalog_path.symlink_to(target)
        self.assert_error_contains("symbolic-link component")

    def test_nonregular_catalog_is_rejected(self) -> None:
        catalog_path = self.root / FIXTURE_CATALOG_PATH
        catalog_path.unlink()
        catalog_path.mkdir()
        self.assert_error_contains("must resolve to a regular file")

    def test_source_identity_is_rejected_from_preregistration_profile(self) -> None:
        self.assign_all_anchors()
        self.preregistration = self.read_json(self.root / PREREGISTRATION_PATH)
        self.preregistration["anchor_assignments"][0]["host_profile"][
            "source_commit"
        ] = "1" * 40
        self.write_preregistration()
        self.assert_error_contains("must match exactly one allowed schema")

    def test_partial_assignment_fails_closed(self) -> None:
        assignment = self.preregistration["anchor_assignments"][0]
        assignment["assignment_state"] = "assigned"
        assignment["host_profile"] = self.profile(
            "apple_silicon", "Apple M1", "15.4", "16.3", "15.4", "1"
        )
        self.write_preregistration()
        self.assert_error_contains("offline preregistration state requires all anchors unassigned")

    def test_private_host_profile_values_fail_closed(self) -> None:
        mutations = (
            ("operator@example.com", "email address"),
            ("/Users/operator/model", "private filesystem path"),
            ("/home/operator/model", "private filesystem path"),
            ("file:///private/model", "private filesystem path"),
            ("serial number: C02PRIVATE", "labeled private identifier"),
            ("hardware UUID=PRIVATE", "labeled private identifier"),
            ("account id: PRIVATE", "labeled private identifier"),
            ("user=operator", "labeled private identifier"),
        )
        for value, fragment in mutations:
            with self.subTest(value=value):
                preregistration = copy.deepcopy(self.preregistration)
                self.preregistration = preregistration
                self.assign_all_anchors()
                self.preregistration = self.read_json(self.root / PREREGISTRATION_PATH)
                self.preregistration["anchor_assignments"][0]["host_profile"][
                    "model_identifier"
                ] = value
                self.write_preregistration()
                self.assert_error_contains(fragment)

    def test_complete_role_correct_assignments_validate(self) -> None:
        self.assign_all_anchors()
        self.assertEqual(self.verifier().check(), [])

    def test_wrong_m3_chip_fails_role_contract(self) -> None:
        self.assign_all_anchors()
        self.preregistration = self.read_json(self.root / PREREGISTRATION_PATH)
        self.preregistration["anchor_assignments"][1]["host_profile"]["chip"] = (
            "Apple M3 Pro"
        )
        self.write_preregistration()
        self.assert_error_contains("chip exactly Apple M3")

    def test_m3_air_requires_official_air_model_identifier(self) -> None:
        self.assign_all_anchors()
        self.preregistration = self.read_json(self.root / PREREGISTRATION_PATH)
        self.preregistration["anchor_assignments"][1]["host_profile"][
            "model_identifier"
        ] = "Mac15,3"
        self.write_preregistration()
        self.assert_error_contains("model identifier Mac15,12 or Mac15,13")

    def test_assigned_host_id_uses_closed_sanitized_identifier(self) -> None:
        self.assign_all_anchors()
        self.preregistration = self.read_json(self.root / PREREGISTRATION_PATH)
        self.preregistration["anchor_assignments"][0]["host_profile"]["host_id"] = (
            "operator@example.com"
        )
        self.write_preregistration()
        errors = self.verifier().check()
        self.assertTrue(any("host_id is not a closed identifier" in error for error in errors))
        self.assertTrue(any("email address" in error for error in errors))

    def test_core_ai_requires_os_xcode_and_sdk_major_27(self) -> None:
        self.assign_all_anchors()
        self.preregistration = self.read_json(self.root / PREREGISTRATION_PATH)
        profile = self.preregistration["anchor_assignments"][3]["host_profile"]
        profile["os_version"] = "26.5"
        profile["xcode_version"] = "26.2"
        profile["sdk_version"] = "26.2"
        self.write_preregistration()
        errors = self.verifier().check()
        for name in ("macOS", "Xcode", "SDK"):
            self.assertTrue(any(f"requires {name} major 27" in error for error in errors))

    def test_offline_record_blocks_live_probe(self) -> None:
        errors = self.verifier().check_live_readiness("pro-max", host_facts={})
        self.assertTrue(any("all four assignments" in error for error in errors), errors)
        self.assertTrue(any("pro-max is not assigned" in error for error in errors), errors)

    def test_live_readiness_matches_injected_host_facts(self) -> None:
        self.assign_all_anchors()
        preregistration = self.read_json(self.root / PREREGISTRATION_PATH)
        profile = copy.deepcopy(
            preregistration["anchor_assignments"][2]["host_profile"]
        )
        profile.pop("hardware_class")
        self.assertEqual(
            self.verifier().check_live_readiness("pro-max", host_facts=profile), []
        )

    def test_live_readiness_rejects_host_mismatch(self) -> None:
        self.assign_all_anchors()
        preregistration = self.read_json(self.root / PREREGISTRATION_PATH)
        profile = copy.deepcopy(
            preregistration["anchor_assignments"][2]["host_profile"]
        )
        profile.pop("hardware_class")
        profile["memory_bytes"] += 1
        errors = self.verifier().check_live_readiness("pro-max", host_facts=profile)
        self.assertTrue(any("memory_bytes differs" in error for error in errors), errors)

    def test_core_ai_live_readiness_requires_frozen_model(self) -> None:
        self.assign_all_anchors()
        preregistration = self.read_json(self.root / PREREGISTRATION_PATH)
        profile = copy.deepcopy(
            preregistration["anchor_assignments"][3]["host_profile"]
        )
        profile.pop("hardware_class")
        errors = self.verifier().check_live_readiness("core-ai", host_facts=profile)
        self.assertTrue(any("frozen analysis-probe-model" in error for error in errors))

    def test_core_ai_missing_ignored_model_allows_negative_probe(self) -> None:
        self.assign_all_anchors()
        self.preregistration = self.read_json(self.root / PREREGISTRATION_PATH)
        self.freeze_analysis_model()
        profile = copy.deepcopy(
            self.preregistration["anchor_assignments"][3]["host_profile"]
        )
        profile.pop("hardware_class")
        self.assertEqual(
            self.verifier().check_live_readiness("core-ai", host_facts=profile), []
        )

    def test_core_ai_present_model_must_match_frozen_bytes(self) -> None:
        self.assign_all_anchors()
        self.preregistration = self.read_json(self.root / PREREGISTRATION_PATH)
        self.freeze_analysis_model()
        model_path = self.root / ".r01-local-assets/probe-model.bin"
        model_path.parent.mkdir()
        model_path.write_bytes(b"drift")
        profile = copy.deepcopy(
            self.preregistration["anchor_assignments"][3]["host_profile"]
        )
        profile.pop("hardware_class")
        errors = self.verifier().check_live_readiness("core-ai", host_facts=profile)
        self.assertTrue(any("byte count differs" in error for error in errors), errors)

    def test_core_ai_model_path_must_use_ignored_local_asset_directory(self) -> None:
        self.assign_all_anchors()
        self.preregistration = self.read_json(self.root / PREREGISTRATION_PATH)
        self.freeze_analysis_model("project-notes/probe-model.bin")
        self.assert_error_contains("ignored .r01-local-assets directory")

    def test_core_ai_model_path_must_be_normalized_and_contained(self) -> None:
        invalid_paths = (
            ".r01-local-assets/../tracked-model.bin",
            ".r01-local-assets//probe.bin",
            ".r01-local-assets/./probe.bin",
            ".r01-local-assets\\probe.bin",
        )
        base_catalog = copy.deepcopy(self.catalog)
        base_preregistration = copy.deepcopy(self.preregistration)
        for path in invalid_paths:
            with self.subTest(path=path):
                self.catalog = copy.deepcopy(base_catalog)
                self.preregistration = copy.deepcopy(base_preregistration)
                self.freeze_analysis_model(path)
                self.assert_error_contains("normalized within the ignored .r01-local-assets")

    def test_analysis_model_identity_is_privacy_scanned_before_commit(self) -> None:
        mutations = (
            ("operator@example.com", "email address"),
            ("/Users/operator/model", "private filesystem path"),
            ("serial number: SECRET", "labeled private identifier"),
            ("hardware UUID=ABC", "labeled private identifier"),
        )
        base_catalog = copy.deepcopy(self.catalog)
        base_preregistration = copy.deepcopy(self.preregistration)
        for identity, fragment in mutations:
            with self.subTest(identity=identity):
                self.catalog = copy.deepcopy(base_catalog)
                self.preregistration = copy.deepcopy(base_preregistration)
                self.freeze_analysis_model(model_identity=identity)
                self.assert_error_contains(fragment)

    def test_core_ai_model_path_rejects_symbolic_link_components(self) -> None:
        outside = self.root / "outside-model-assets"
        outside.mkdir()
        (self.root / ".r01-local-assets").symlink_to(
            outside, target_is_directory=True
        )
        self.freeze_analysis_model()
        self.assert_error_contains("symbolic-link component")

    def test_frozen_analysis_model_rejects_all_zero_hash(self) -> None:
        self.freeze_analysis_model()
        self.catalog = self.read_json(self.root / FIXTURE_CATALOG_PATH)
        self.catalog["fixtures"][-1]["content_sha256"] = "0" * 64
        self.write_catalog()
        catalog_payload = (self.root / FIXTURE_CATALOG_PATH).read_bytes()
        self.preregistration["fixture_catalog"]["sha256"] = hashlib.sha256(
            catalog_payload
        ).hexdigest()
        self.write_preregistration()
        self.assert_error_contains("SHA-256 is invalid")

    def test_host_fact_collector_uses_only_allowlisted_commands(self) -> None:
        outputs = {
            ("/usr/sbin/sysctl", "-n", "hw.model"): "Mac16,7\n",
            ("/usr/sbin/sysctl", "-n", "machdep.cpu.brand_string"): "Apple M4 Pro\n",
            ("/usr/sbin/sysctl", "-n", "hw.memsize"): "51539607552\n",
            ("/usr/bin/sw_vers", "-productVersion"): "26.5.2\n",
            ("/usr/bin/sw_vers", "-buildVersion"): "25F84\n",
            ("/usr/bin/xcodebuild", "-version"): "Xcode 26.2\nBuild version 17C52\n",
            ("/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-version"): "26.2\n",
            ("/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-build-version"): "25C58\n",
        }
        observed: list[tuple[str, ...]] = []

        def run(command: tuple[str, ...], **_: object) -> subprocess.CompletedProcess[str]:
            observed.append(command)
            return subprocess.CompletedProcess(command, 0, outputs[command], "")

        facts = collect_host_facts(run)
        self.assertEqual(facts["model_identifier"], "Mac16,7")
        self.assertEqual(facts["chip"], "Apple M4 Pro")
        self.assertEqual(facts["memory_bytes"], 51539607552)
        self.assertEqual(set(observed), set(outputs))

    def test_host_fact_collection_failure_does_not_echo_command_output(self) -> None:
        def run(command: tuple[str, ...], **_: object) -> subprocess.CompletedProcess[str]:
            raise subprocess.CalledProcessError(
                1, command, output="SERIAL-NUMBER", stderr="ACCOUNT-DATA"
            )

        with self.assertRaises(HostFactCollectionError) as context:
            collect_host_facts(run)
        self.assertNotIn("SERIAL-NUMBER", str(context.exception))
        self.assertNotIn("ACCOUNT-DATA", str(context.exception))

    def test_anchor_contract_order_is_exact(self) -> None:
        self.assertEqual(
            [item[0] for item in ANCHOR_CONTRACTS],
            ["oldest-supported", "m3-air", "pro-max", "core-ai"],
        )


if __name__ == "__main__":
    unittest.main()
