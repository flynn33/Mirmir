from __future__ import annotations

import copy
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPOSITORY_ROOT / "Scripts"))

from r01_capabilities import (  # noqa: E402
    AGGREGATE_JSON_PATH,
    AGGREGATE_MARKDOWN_PATH,
    AGGREGATE_SCHEMA_PATH,
    ALL_METRICS,
    ANCHORS,
    CAPABILITY_IDENTITIES,
    CLASS_METRICS,
    COMMON_METRICS,
    FAILURE_CLASSES,
    FIXTURE_CATALOG_PATH,
    FIXTURE_CATALOG_SCHEMA_PATH,
    FIXTURE_IDS,
    HOST_SCHEMA_PATH,
    METRIC_UNITS,
    PREREGISTRATION_PATH,
    PREREGISTRATION_SCHEMA_PATH,
    PRIMARY_SCALER_OBSERVATIONS,
    QUALIFICATION_VALUE,
    RAW_REPORT_PATHS,
    REQUIRED_IMPLEMENTATION_PATHS,
    R01CapabilityVerifier,
    canonical_json_bytes,
    decode_json_bytes,
    main,
    sha256_bytes,
    validate_local_model_path,
    validate_instances_against_schemas,
    validate_schema_bundle,
)
from r01_preregistration import ROADMAP_PATH  # noqa: E402


class R01CapabilityTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary_directory.name)
        for relative in (
            HOST_SCHEMA_PATH,
            AGGREGATE_SCHEMA_PATH,
            PREREGISTRATION_SCHEMA_PATH,
            FIXTURE_CATALOG_SCHEMA_PATH,
            ROADMAP_PATH,
        ):
            destination = self.root / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(REPOSITORY_ROOT / relative, destination)
        shutil.copy2(REPOSITORY_ROOT / ".gitignore", self.root / ".gitignore")
        for relative in REQUIRED_IMPLEMENTATION_PATHS:
            destination = self.root / relative
            if destination.exists():
                continue
            destination.parent.mkdir(parents=True, exist_ok=True)
            source = REPOSITORY_ROOT / relative
            if source.is_file():
                shutil.copy2(source, destination)
            else:
                destination.write_text(
                    f"// deterministic test placeholder for {relative.as_posix()}\n",
                    encoding="utf-8",
                )
        self.preregistration = json.loads(
            (REPOSITORY_ROOT / PREREGISTRATION_PATH).read_text(encoding="utf-8")
        )
        self.catalog = json.loads(
            (REPOSITORY_ROOT / FIXTURE_CATALOG_PATH).read_text(encoding="utf-8")
        )
        self.profiles = {
            "oldest-supported": self.profile(
                "Mac14,2", "apple_silicon", "Apple M1", "15.4", "16.3", "15.4", "1"
            ),
            "m3-air": self.profile(
                "Mac15,12", "macbook_air", "Apple M3", "26.0", "26.0", "26.0", "2"
            ),
            "pro-max": self.profile(
                "Mac16,7", "pro_max_tier", "Apple M4 Pro", "26.5", "26.2", "26.2", "3"
            ),
            "core-ai": self.profile(
                "Mac17,1", "core_ai_capable", "Apple M4 Max", "27.0", "27.0", "27.0", "4"
            ),
        }
        self._freeze_preregistration()
        self._initialize_source_commit()
        self.fixture_by_id = {
            item["id"]: item for item in self.catalog["fixtures"]
        }
        self.reports = {
            anchor: self.build_report(anchor, index)
            for index, anchor in enumerate(ANCHORS)
        }
        self.write_reports()

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    @staticmethod
    def profile(
        model: str,
        hardware_class: str,
        chip: str,
        os_version: str,
        xcode_version: str,
        sdk_version: str,
        suffix: str,
    ) -> dict[str, object]:
        return {
            "host_id": f"r01-host-{int(suffix):02d}",
            "model_identifier": model,
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

    def _freeze_preregistration(self) -> None:
        for fixture in self.catalog["fixtures"][:-1]:
            path = self.root / fixture["materialization_path"]
            path.parent.mkdir(parents=True, exist_ok=True)
            source = REPOSITORY_ROOT / fixture["materialization_path"]
            try:
                os.link(source, path)
            except OSError:
                shutil.copy2(source, path)
        model = self.catalog["fixtures"][-1]
        model_payload = b"frozen model identity"
        model.update(
            {
                "status": "frozen",
                "materialization_path": ".r01-local-assets/r01-probe.mlmodelc",
                "byte_count": len(model_payload),
                "content_sha256": hashlib.sha256(model_payload).hexdigest(),
                "model_identity": "R01 deterministic probe model v1",
            }
        )
        model_path = self.root / model["materialization_path"]
        model_path.parent.mkdir(parents=True, exist_ok=True)
        model_path.write_bytes(model_payload)
        catalog_path = self.root / FIXTURE_CATALOG_PATH
        catalog_path.parent.mkdir(parents=True, exist_ok=True)
        catalog_path.write_bytes(canonical_json_bytes(self.catalog))
        for assignment in self.preregistration["anchor_assignments"]:
            anchor = assignment["anchor"]
            assignment["assignment_state"] = "assigned"
            assignment["host_profile"] = self.profiles[anchor]
        self.preregistration["preregistration_state"] = "live_assignments_frozen"
        self.preregistration["fixture_catalog"] = {
            "path": FIXTURE_CATALOG_PATH.as_posix(),
            "sha256": sha256_bytes(catalog_path.read_bytes()),
        }
        preregistration_path = self.root / PREREGISTRATION_PATH
        preregistration_path.parent.mkdir(parents=True, exist_ok=True)
        preregistration_path.write_bytes(canonical_json_bytes(self.preregistration))

    def git(self, *arguments: str) -> subprocess.CompletedProcess[str]:
        result = subprocess.run(
            ["git", *arguments],
            cwd=self.root,
            check=False,
            capture_output=True,
            text=True,
        )
        if result.returncode != 0:
            self.fail(f"git {' '.join(arguments)} failed: {result.stderr or result.stdout}")
        return result

    def _initialize_source_commit(self) -> None:
        self.git("init", "-q")
        self.git("config", "user.name", "Mirmir Tests")
        self.git("config", "user.email", "mirmir-tests@example.invalid")
        self.git("add", ".")
        self.git("commit", "-q", "-m", "R01 source")
        self.commit = self.git("rev-parse", "HEAD").stdout.strip()
        self.tree = self.git("rev-parse", "HEAD^{tree}").stdout.strip()
        self.git("update-ref", "refs/remotes/origin/r01/test", self.commit)

    def binding(self, relative: Path) -> dict[str, object]:
        payload = (self.root / relative).read_bytes()
        return {
            "path": relative.as_posix(),
            "size_bytes": len(payload),
            "sha256": sha256_bytes(payload),
        }

    def fixture_bindings(self) -> list[dict[str, object]]:
        bindings: list[dict[str, object]] = []
        for fixture in self.catalog["fixtures"]:
            if fixture["id"] == "analysis-probe-model":
                bindings.append(
                    {
                        "id": fixture["id"],
                        "kind": "system_asset",
                        "identity": fixture["model_identity"],
                        "path": None,
                        "size_bytes": None,
                        "sha256": fixture["content_sha256"],
                    }
                )
            else:
                bindings.append(
                    {
                        "id": fixture["id"],
                        "kind": "repository_fixture",
                        "identity": fixture["role"],
                        "path": fixture["materialization_path"],
                        "size_bytes": fixture["byte_count"],
                        "sha256": fixture["content_sha256"],
                    }
                )
        return bindings

    @staticmethod
    def metric_value(metric: str) -> object:
        if metric in {"required_guidance", "confidence_available"}:
            return True
        if metric == "generated_frame_count":
            return 1
        if metric in {
            "output_dimensions",
            "preserved_dimensions",
            "flow_dimensions",
        }:
            return "1920x1080"
        if metric in {"output_format", "preserved_format", "flow_format"}:
            return "420v"
        if metric == "timestamp_contract":
            return "fixed ordered PTS/duration"
        if metric in {"zero_copy_disposition", "stateful_execution_disposition"}:
            return "observed"
        return 1.0

    def build_capability(
        self,
        anchor: str,
        identity: tuple[str, str, str, str],
    ) -> dict[str, object]:
        identifier, family, method, probe_class = identity
        applicable = set(COMMON_METRICS + CLASS_METRICS[probe_class])
        metrics: dict[str, object] = {}
        for metric in ALL_METRICS:
            if metric in applicable:
                metrics[metric] = {
                    "status": "measured",
                    "value": self.metric_value(metric),
                    "unit": METRIC_UNITS[metric],
                    "reason": None,
                }
            else:
                metrics[metric] = {
                    "status": "not_applicable",
                    "value": None,
                    "unit": METRIC_UNITS[metric],
                    "reason": f"not_applicable_for_{probe_class}",
                }
        repeatability = [
            hashlib.sha256(f"{anchor}:{identifier}:{index}".encode()).hexdigest()
            for index in range(3)
        ]
        input_contract = R01CapabilityVerifier._expected_input_contract(
            identifier, probe_class, self.fixture_by_id
        )
        return {
            "id": identifier,
            "family": family,
            "method": method,
            "probe_class": probe_class,
            "compile_state": "available",
            "runtime_disposition": "runnable",
            "reason_code": "none",
            "failure_class": "none",
            "public_api_status": "public",
            "hardware_eligibility": "eligible",
            "platform_requirements": {
                "minimum_os_version": "15.4",
                "minimum_sdk_version": "15.4",
                "unavailable_reason": None,
            },
            "support_query": {
                "api_or_equivalent_name": method,
                "observed": True,
                "reason_code": None,
            },
            "input_contract": input_contract,
            "state_history": "stateless",
            "model_readiness": "ready" if identifier == "A18" else "not_required",
            "offline_suitability": "suitable",
            "primary_scaler_observations": (
                [dict(value) for value in PRIMARY_SCALER_OBSERVATIONS]
                if probe_class == "primary_scaler"
                else []
            ),
            "measurements": {
                "session_count": 3,
                "warmup_units_per_session": 5,
                "measured_units_per_session": 30,
                "timeout_seconds_per_session": 120,
                "sessions": [
                    {
                        "session_index": index,
                        "completed_warmup_units": 5,
                        "completed_measured_units": 30,
                        "elapsed_seconds": 1.0,
                        "timed_out": False,
                        "outcome": "completed",
                        "failure_detail": None,
                    }
                    for index in range(1, 4)
                ],
                "metrics": metrics,
                "repeatability": {
                    "status": "measured",
                    "mode": "hash",
                    "observations": repeatability,
                    "tolerance": None,
                    "reason": None,
                },
            },
            "product_qualification": QUALIFICATION_VALUE,
            "backend_eligibility": QUALIFICATION_VALUE,
            "quality_evaluation": QUALIFICATION_VALUE,
            "limitations": [],
        }

    def build_report(self, anchor: str, index: int) -> dict[str, object]:
        profile = self.profiles[anchor]
        hardware_classes = ["apple_silicon", profile["hardware_class"]]
        hardware_classes = list(dict.fromkeys(hardware_classes))
        return {
            "schema_version": "1.0",
            "roadmap_version": "1.0.1",
            "phase_id": "R01",
            "source_commit": self.commit,
            "source_tree": self.tree,
            "generated_at": f"2026-07-19T12:00:0{index}Z",
            "anchor": anchor,
            "host": {
                "host_id": profile["host_id"],
                **{
                    key: value
                    for key, value in profile.items()
                    if key not in {"hardware_class", "host_id"}
                },
                "hardware_classes": hardware_classes,
            },
            "implementation_bindings": [
                self.binding(path) for path in REQUIRED_IMPLEMENTATION_PATHS
            ],
            "preregistration_binding": self.binding(PREREGISTRATION_PATH),
            "fixture_bindings": self.fixture_bindings(),
            "capabilities": [
                self.build_capability(anchor, identity)
                for identity in CAPABILITY_IDENTITIES
            ],
            "limitations": [],
        }

    def make_nonrunnable(
        self,
        capability: dict[str, object],
        *,
        reason_code: str,
        compile_state: str,
        runtime_disposition: str,
        failure_class: str,
        public_api_status: str,
        hardware_eligibility: str,
        support_observed: object,
        model_readiness: str,
        offline_suitability: str,
    ) -> None:
        capability.update(
            {
                "compile_state": compile_state,
                "runtime_disposition": runtime_disposition,
                "reason_code": reason_code,
                "failure_class": failure_class,
                "public_api_status": public_api_status,
                "hardware_eligibility": hardware_eligibility,
                "model_readiness": model_readiness,
                "offline_suitability": offline_suitability,
                "primary_scaler_observations": [],
            }
        )
        capability["support_query"] = {
            "api_or_equivalent_name": capability["method"],
            "observed": support_observed,
            "reason_code": None if support_observed is True else reason_code,
        }
        measurements = capability["measurements"]
        measurements["session_count"] = 0
        measurements["sessions"] = []
        for metric in COMMON_METRICS + CLASS_METRICS[capability["probe_class"]]:
            measurements["metrics"][metric].update(
                {
                    "status": "not_measured",
                    "value": None,
                    "reason": reason_code,
                }
            )
        measurements["repeatability"] = {
            "status": "not_measured",
            "mode": "not_applicable",
            "observations": [],
            "tolerance": None,
            "reason": reason_code,
        }

    @staticmethod
    def reason_contracts_for_tests() -> dict[str, dict[str, object]]:
        common: dict[str, object] = {
            "compile_state": "available",
            "runtime_disposition": "unavailable",
            "failure_class": "unsupported_contract",
            "public_api_status": "public",
            "hardware_eligibility": "eligible",
            "support_observed": True,
            "model_readiness": "not_required",
            "offline_suitability": "suitable",
        }

        def contract(**overrides: object) -> dict[str, object]:
            return {**common, **overrides}

        return {
            "api_absent": contract(
                compile_state="unavailable",
                public_api_status="absent",
                hardware_eligibility="unknown",
                support_observed="not_available",
                offline_suitability="unavailable",
            ),
            "not_public_api": contract(
                runtime_disposition="unsupported",
                public_api_status="not_public",
                support_observed="not_available",
                offline_suitability="unavailable",
            ),
            "os_too_old": contract(
                support_observed=False,
                offline_suitability="unavailable",
            ),
            "sdk_too_old": contract(
                compile_state="conditional",
                support_observed="not_available",
                offline_suitability="unavailable",
            ),
            "hardware_unsupported": contract(
                runtime_disposition="unsupported",
                hardware_eligibility="ineligible",
                support_observed=False,
                offline_suitability="unavailable",
            ),
            "model_unavailable": contract(
                model_readiness="unavailable",
                offline_suitability="requires_acquisition",
            ),
            "model_acquisition_failed": contract(
                runtime_disposition="rejected",
                failure_class="setup_failure",
                model_readiness="acquisition_failed",
                offline_suitability="unavailable",
            ),
            "input_contract_unsatisfied": contract(
                runtime_disposition="rejected",
            ),
            "runtime_probe_failed": contract(
                runtime_disposition="rejected",
                failure_class="processing_failure",
            ),
            "resource_limit": contract(
                runtime_disposition="rejected",
                failure_class="resource_failure",
            ),
            "not_applicable": contract(
                runtime_disposition="unsupported",
                support_observed="not_available",
                offline_suitability="unavailable",
            ),
        }

    def write_reports(self) -> None:
        for anchor, report in self.reports.items():
            path = self.root / RAW_REPORT_PATHS[anchor]
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(canonical_json_bytes(report))

    def write_report(self, anchor: str) -> None:
        (self.root / RAW_REPORT_PATHS[anchor]).write_bytes(
            canonical_json_bytes(self.reports[anchor])
        )

    def verifier(self) -> R01CapabilityVerifier:
        return R01CapabilityVerifier(self.root)

    def assert_error_contains(self, fragment: str) -> None:
        _, errors = self.verifier().load_and_validate_raw_reports()
        self.assertTrue(
            any(fragment in error for error in errors),
            f"expected error containing {fragment!r}; found {errors!r}",
        )

    def test_positive_aggregate_and_check_are_byte_deterministic(self) -> None:
        self.assertEqual(main(["--aggregate", "--root", str(self.root)]), 0)
        json_before = (self.root / AGGREGATE_JSON_PATH).read_bytes()
        markdown_before = (self.root / AGGREGATE_MARKDOWN_PATH).read_bytes()
        self.assertEqual(main(["--aggregate", "--root", str(self.root)]), 0)
        self.assertEqual((self.root / AGGREGATE_JSON_PATH).read_bytes(), json_before)
        self.assertEqual((self.root / AGGREGATE_MARKDOWN_PATH).read_bytes(), markdown_before)
        self.assertEqual(main(["--check", "--root", str(self.root)]), 0)
        aggregate = json.loads(json_before)
        self.assertEqual(aggregate["generated_at"], "2026-07-19T12:00:03Z")

    def test_duplicate_json_key_fails_closed(self) -> None:
        path = self.root / RAW_REPORT_PATHS["oldest-supported"]
        payload = path.read_text(encoding="utf-8")
        path.write_text(payload.replace("{\n", '{\n  "schema_version": "1.0",\n', 1))
        self.assert_error_contains("duplicate JSON key 'schema_version'")

    def test_nonfinite_json_number_fails_closed(self) -> None:
        path = self.root / RAW_REPORT_PATHS["oldest-supported"]
        canonical_payload = path.read_bytes()
        for constant in (b"NaN", b"Infinity", b"-Infinity"):
            with self.subTest(constant=constant.decode("ascii")):
                path.write_bytes(
                    canonical_payload.replace(
                        b'"elapsed_seconds": 1.0',
                        b'"elapsed_seconds": ' + constant,
                        1,
                    )
                )
                self.assert_error_contains("non-finite JSON number")
                path.write_bytes(canonical_payload)

    def test_missing_raw_anchor_fails(self) -> None:
        (self.root / RAW_REPORT_PATHS["core-ai"]).unlink()
        self.assert_error_contains("anchor-core-ai.json")

    def test_unpublished_source_commit_fails(self) -> None:
        self.git("update-ref", "-d", "refs/remotes/origin/r01/test")
        self.assert_error_contains("not contained by a local origin remote-tracking ref")

    def test_source_tree_mismatch_fails(self) -> None:
        self.reports["m3-air"]["source_tree"] = self.commit
        self.write_report("m3-air")
        self.assert_error_contains("source_tree does not match")

    def test_preregistration_binding_mutation_fails(self) -> None:
        self.reports["pro-max"]["preregistration_binding"]["sha256"] = "a" * 64
        self.write_report("pro-max")
        self.assert_error_contains("does not bind the source_commit bytes")

    def test_implementation_source_set_and_schema_order_are_exact(self) -> None:
        expected = (
            "Scripts/r01_capabilities.py",
            "Scripts/r01_preregistration.py",
            "Scripts/phase_evidence.py",
            "Scripts/run-r01-capability-probe.sh",
            "R01CapabilityWorker/main.swift",
            "Mirmir/Modules/UpscalerEngine/AppleUpscaleCapabilityProbe.swift",
            "Mirmir/Modules/UpscalerEngine/AppleUpscaleCapabilitySupportProbe.swift",
            "Mirmir/Modules/UpscalerEngine/AppleUpscaleCapabilityCompileProbe.swift",
            "Mirmir/Modules/UpscalerEngine/AppleUpscaleCapabilityExecutor.swift",
            "Mirmir/Modules/UpscalerEngine/AppleUpscaleCapabilityFixtureContract.swift",
            "Mirmir/Modules/UpscalerEngine/AppleUpscaleCapabilityLiveContext.swift",
            "Mirmir/Modules/UpscalerEngine/AppleUpscaleCapabilityLiveErrors.swift",
            "Mirmir/Modules/UpscalerEngine/AppleUpscaleCapabilityNativeAdapters.swift",
            "Mirmir/Modules/UpscalerEngine/AppleUpscaleCapabilityRawReport.swift",
            "Mirmir/Modules/UpscalerEngine/AppleUpscaleCapabilityReportModels.swift",
            "Mirmir/Modules/UpscalerEngine/AppleUpscaleCapabilityLegacyAdapters.swift",
            "Mirmir/Modules/UpscalerEngine/AppleUpscaleCapabilityReportWriter.swift",
            "Mirmir/Modules/UpscalerEngine/AppleUpscaleCapabilityLiveProducer.swift",
            "Mirmir/Modules/UpscalerEngine/AppleUpscaleCapabilityWorker.swift",
            "MirmirTests/AppleUpscaleCapabilityProbeTests.swift",
            "MirmirTests/AppleUpscaleCapabilityLiveProbeTests.swift",
            "project.yml",
            "Mirmir.xcodeproj/project.pbxproj",
            "docs/roadmaps/evidence/schema/r01-host-report-v1.json",
            "docs/roadmaps/evidence/schema/r01-capability-aggregate-v1.json",
            "docs/roadmaps/evidence/schema/r01-preregistration-v1.json",
            "docs/roadmaps/evidence/schema/r01-fixture-catalog-v1.json",
        )
        self.assertEqual(
            tuple(path.as_posix() for path in REQUIRED_IMPLEMENTATION_PATHS),
            expected,
        )
        schema = json.loads((self.root / HOST_SCHEMA_PATH).read_text(encoding="utf-8"))
        bindings = schema["$defs"]["implementationBindings"]
        self.assertEqual(bindings["minItems"], len(expected))
        self.assertEqual(bindings["maxItems"], len(expected))
        self.assertEqual(
            tuple(
                item["allOf"][1]["properties"]["path"]["const"]
                for item in bindings["prefixItems"]
            ),
            expected,
        )

    def test_stale_implementation_binding_fails(self) -> None:
        self.reports["oldest-supported"]["implementation_bindings"][0][
            "sha256"
        ] = "c" * 64
        self.write_report("oldest-supported")
        self.assert_error_contains("does not bind the source_commit bytes")

    def test_missing_implementation_binding_fails(self) -> None:
        self.reports["oldest-supported"]["implementation_bindings"].pop()
        self.write_report("oldest-supported")
        self.assert_error_contains("must contain exactly 27 bindings")

    def test_uncommitted_implementation_bytes_fail(self) -> None:
        path = self.root / REQUIRED_IMPLEMENTATION_PATHS[5]
        path.write_bytes(path.read_bytes() + b"\n// uncommitted mutation\n")
        self.assert_error_contains("working bytes differ from source_commit")

    def test_implementation_path_missing_at_source_commit_fails(self) -> None:
        missing_path = REQUIRED_IMPLEMENTATION_PATHS[5]
        self.git("rm", "-q", missing_path.as_posix())
        self.git("commit", "-q", "-m", "remove bound source")
        commit = self.git("rev-parse", "HEAD").stdout.strip()
        tree = self.git("rev-parse", "HEAD^{tree}").stdout.strip()
        self.git("update-ref", "refs/remotes/origin/r01/test", commit)
        for anchor in ANCHORS:
            self.reports[anchor]["source_commit"] = commit
            self.reports[anchor]["source_tree"] = tree
        self.write_reports()
        self.assert_error_contains("is absent at source_commit")

    def test_all_reports_require_identical_implementation_bindings(self) -> None:
        self.reports["core-ai"]["implementation_bindings"][0]["sha256"] = "d" * 64
        self.write_report("core-ai")
        self.assert_error_contains("all four reports must bind identical implementation sources")

    def test_fixture_binding_mutation_fails(self) -> None:
        self.reports["oldest-supported"]["fixture_bindings"][0]["sha256"] = "b" * 64
        self.write_report("oldest-supported")
        self.assert_error_contains("sha256 differs from the catalog")

    def test_host_assignment_mutation_fails(self) -> None:
        self.reports["m3-air"]["host"]["chip"] = "Apple M4"
        self.write_report("m3-air")
        self.assert_error_contains("differs from preregistration")

    def test_host_id_is_frozen_by_assignment(self) -> None:
        self.reports["m3-air"]["host"]["host_id"] = "replacement-host"
        self.write_report("m3-air")
        self.assert_error_contains("host_id differs from preregistration")

    def test_m3_air_model_identifier_is_closed_to_two_real_models(self) -> None:
        self.reports["m3-air"]["host"]["model_identifier"] = "Mac15,14"
        self.write_report("m3-air")
        self.assert_error_contains(
            "m3-air model_identifier must be Mac15,12 or Mac15,13"
        )

    def test_private_value_fails(self) -> None:
        self.reports["pro-max"]["limitations"] = ["operator at /Users/private"]
        self.write_report("pro-max")
        self.assert_error_contains("private absolute path")

    def test_schema_only_sanitized_string_rule_is_enforced(self) -> None:
        self.reports["pro-max"]["limitations"] = ["runtime@host"]
        self.write_report("pro-max")
        self.assert_error_contains("string does not match the required pattern")

    def test_capability_identity_and_class_mutation_fail(self) -> None:
        self.reports["oldest-supported"]["capabilities"][0]["id"] = "A02"
        self.reports["oldest-supported"]["capabilities"][0]["probe_class"] = "support_filter"
        self.write_report("oldest-supported")
        self.assert_error_contains("differs from the closed capability catalog")

    def test_extra_quality_claim_fails_closed(self) -> None:
        self.reports["oldest-supported"]["capabilities"][0]["quality_claim"] = True
        self.write_report("oldest-supported")
        self.assert_error_contains("extra=['quality_claim']")

    def test_product_qualification_fails(self) -> None:
        self.reports["oldest-supported"]["capabilities"][0][
            "product_qualification"
        ] = "qualified"
        self.write_report("oldest-supported")
        self.assert_error_contains("exceeds the R01 measurement boundary")

    def test_runtime_reason_pairing_fails(self) -> None:
        capability = self.reports["oldest-supported"]["capabilities"][0]
        capability["reason_code"] = "api_absent"
        self.write_report("oldest-supported")
        self.assert_error_contains("runnable evidence must use reason_code none")

    def test_compile_unavailable_cannot_be_runnable(self) -> None:
        self.reports["oldest-supported"]["capabilities"][0][
            "compile_state"
        ] = "unavailable"
        self.write_report("oldest-supported")
        self.assert_error_contains("cannot be runnable when compile state is unavailable")

    def test_nonpublic_reason_is_closed(self) -> None:
        capability = self.reports["oldest-supported"]["capabilities"][0]
        capability["public_api_status"] = "not_public"
        self.write_report("oldest-supported")
        self.assert_error_contains("non-public API must use reason not_public_api")

    def test_hardware_ineligibility_reason_is_closed(self) -> None:
        capability = self.reports["oldest-supported"]["capabilities"][0]
        capability["hardware_eligibility"] = "ineligible"
        self.write_report("oldest-supported")
        self.assert_error_contains("ineligible hardware must use hardware_unsupported")

    def test_every_reason_code_has_a_valid_closed_state_contract(self) -> None:
        original = copy.deepcopy(self.reports["oldest-supported"])
        for reason_code, contract in self.reason_contracts_for_tests().items():
            with self.subTest(reason_code=reason_code):
                self.reports["oldest-supported"] = copy.deepcopy(original)
                capability = self.reports["oldest-supported"]["capabilities"][0]
                self.make_nonrunnable(
                    capability,
                    reason_code=reason_code,
                    **contract,
                )
                self.write_report("oldest-supported")
                _, errors = self.verifier().load_and_validate_raw_reports()
                self.assertEqual(errors, [], f"{reason_code}: {errors!r}")

    def test_reason_to_state_invariants_fail_closed(self) -> None:
        original = copy.deepcopy(self.reports["oldest-supported"])
        mutations = (
            ("api_absent", "public_api_status", "public"),
            ("not_public_api", "offline_suitability", "suitable"),
            ("os_too_old", "compile_state", "unavailable"),
            ("sdk_too_old", "compile_state", "available"),
            ("hardware_unsupported", "hardware_eligibility", "eligible"),
            ("model_unavailable", "model_readiness", "ready"),
            ("model_acquisition_failed", "offline_suitability", "suitable"),
            ("input_contract_unsatisfied", "public_api_status", "absent"),
            ("runtime_probe_failed", "runtime_disposition", "unsupported"),
            ("resource_limit", "compile_state", "unavailable"),
            ("not_applicable", "offline_suitability", "suitable"),
        )
        contracts = self.reason_contracts_for_tests()
        for reason_code, field, value in mutations:
            with self.subTest(reason_code=reason_code, field=field):
                self.reports["oldest-supported"] = copy.deepcopy(original)
                capability = self.reports["oldest-supported"]["capabilities"][0]
                self.make_nonrunnable(
                    capability,
                    reason_code=reason_code,
                    **contracts[reason_code],
                )
                capability[field] = value
                self.write_report("oldest-supported")
                self.assert_error_contains("incompatible with reason_code")

    def test_schema_enforces_every_reason_state_contract(self) -> None:
        original = copy.deepcopy(self.reports["oldest-supported"])
        mutations = {
            "api_absent": ("public_api_status", "public"),
            "not_public_api": ("support_query.observed", True),
            "os_too_old": ("compile_state", "unavailable"),
            "sdk_too_old": ("compile_state", "available"),
            "hardware_unsupported": ("hardware_eligibility", "eligible"),
            "model_unavailable": ("model_readiness", "ready"),
            "model_acquisition_failed": ("offline_suitability", "suitable"),
            "input_contract_unsatisfied": ("public_api_status", "absent"),
            "runtime_probe_failed": ("runtime_disposition", "unsupported"),
            "resource_limit": ("compile_state", "unavailable"),
            "not_applicable": ("offline_suitability", "suitable"),
        }
        contracts = self.reason_contracts_for_tests()
        for reason_code, (field, value) in mutations.items():
            with self.subTest(reason_code=reason_code):
                self.reports["oldest-supported"] = copy.deepcopy(original)
                capability = self.reports["oldest-supported"]["capabilities"][0]
                self.make_nonrunnable(
                    capability,
                    reason_code=reason_code,
                    **contracts[reason_code],
                )
                if field == "support_query.observed":
                    capability["support_query"]["observed"] = value
                    capability["support_query"]["reason_code"] = None
                else:
                    capability[field] = value
                errors = validate_instances_against_schemas(
                    self.root,
                    [self.reports[anchor] for anchor in ANCHORS],
                )
                self.assertTrue(errors, f"schema accepted invalid {reason_code} state")

    def test_state_to_reason_invariants_fail_closed(self) -> None:
        original = copy.deepcopy(self.reports["oldest-supported"])
        mutations = (
            (
                "public_api_status",
                "absent",
                "public_api_status absent requires api_absent",
            ),
            (
                "public_api_status",
                "not_public",
                "public_api_status not_public requires not_public_api",
            ),
            (
                "hardware_eligibility",
                "ineligible",
                "ineligible hardware requires hardware_unsupported",
            ),
            (
                "model_readiness",
                "unavailable",
                "unavailable model readiness requires model_unavailable",
            ),
            (
                "model_readiness",
                "acquisition_failed",
                "acquisition_failed model readiness requires model_acquisition_failed",
            ),
            (
                "offline_suitability",
                "requires_acquisition",
                "requires_acquisition offline state requires model_unavailable",
            ),
        )
        contract = self.reason_contracts_for_tests()["runtime_probe_failed"]
        for field, value, expected_error in mutations:
            with self.subTest(field=field, value=value):
                self.reports["oldest-supported"] = copy.deepcopy(original)
                capability = self.reports["oldest-supported"]["capabilities"][0]
                self.make_nonrunnable(
                    capability,
                    reason_code="runtime_probe_failed",
                    **contract,
                )
                capability[field] = value
                self.write_report("oldest-supported")
                self.assert_error_contains(expected_error)

    def test_support_query_state_and_reason_must_agree(self) -> None:
        capability = self.reports["oldest-supported"]["capabilities"][0]
        contract = self.reason_contracts_for_tests()["os_too_old"]
        self.make_nonrunnable(
            capability,
            reason_code="os_too_old",
            **contract,
        )
        capability["support_query"]["reason_code"] = "hardware_unsupported"
        self.write_report("oldest-supported")
        self.assert_error_contains("support_query reason must equal reason_code")

    def test_unknown_platform_minimum_requires_reason(self) -> None:
        requirements = self.reports["oldest-supported"]["capabilities"][0][
            "platform_requirements"
        ]
        requirements["minimum_os_version"] = None
        requirements["unavailable_reason"] = None
        self.write_report("oldest-supported")
        self.assert_error_contains("unknown platform minima require a closed reason")

    def test_negative_support_query_requires_reason(self) -> None:
        support = self.reports["oldest-supported"]["capabilities"][0][
            "support_query"
        ]
        support["observed"] = False
        self.write_report("oldest-supported")
        self.assert_error_contains("negative support query requires a closed reason")

    def test_fixture_input_contract_drift_fails(self) -> None:
        contract = self.reports["oldest-supported"]["capabilities"][0][
            "input_contract"
        ]
        contract["scales"] = [2.0]
        self.write_report("oldest-supported")
        self.assert_error_contains("differs from the frozen fixture contract")

    def test_support_filter_contracts_are_capability_specific(self) -> None:
        expected = {
            "A04": {
                "fixture_ids": ["support-frame", "support-history"],
                "formats": ["420v"],
                "guidance_inputs": [],
                "history_inputs": ["support-history"],
            },
            "A13": {
                "fixture_ids": [
                    "support-frame",
                    "support-guidance",
                    "support-history",
                ],
                "formats": ["420v", "L008"],
                "guidance_inputs": ["support-guidance"],
                "history_inputs": ["support-history"],
            },
            "A15": {
                "fixture_ids": ["support-frame", "support-guidance"],
                "formats": ["420v", "L008"],
                "guidance_inputs": ["support-guidance"],
                "history_inputs": [],
            },
            "A17": {
                "fixture_ids": [
                    "support-frame",
                    "support-guidance",
                    "support-history",
                ],
                "formats": ["420v", "L008"],
                "guidance_inputs": ["support-guidance"],
                "history_inputs": ["support-history"],
            },
        }
        capabilities = {
            capability["id"]: capability
            for capability in self.reports["oldest-supported"]["capabilities"]
        }
        for identifier, contract in expected.items():
            with self.subTest(identifier=identifier):
                observed = capabilities[identifier]["input_contract"]
                for key, value in contract.items():
                    self.assertEqual(observed[key], value)

    def test_support_filter_cannot_substitute_another_capability_contract(self) -> None:
        capabilities = {
            capability["id"]: capability
            for capability in self.reports["oldest-supported"]["capabilities"]
        }
        capabilities["A04"]["input_contract"] = copy.deepcopy(
            capabilities["A13"]["input_contract"]
        )
        self.write_report("oldest-supported")
        self.assert_error_contains("differs from the frozen fixture contract")

    def test_primary_scaler_observation_mutations_fail_closed(self) -> None:
        original = copy.deepcopy(self.reports["oldest-supported"])

        def omit(capability: dict[str, object]) -> None:
            capability.pop("primary_scaler_observations")

        def duplicate(capability: dict[str, object]) -> None:
            capability["primary_scaler_observations"][1] = copy.deepcopy(
                capability["primary_scaler_observations"][0]
            )

        def drift(capability: dict[str, object]) -> None:
            capability["primary_scaler_observations"][1][
                "output_dimensions"
            ] = "2560x1440"

        def zero_scale(capability: dict[str, object]) -> None:
            capability["primary_scaler_observations"][0]["scale"] = 0

        def garbage_dimensions(capability: dict[str, object]) -> None:
            capability["primary_scaler_observations"][0][
                "input_dimensions"
            ] = "garbage"

        for name, mutation in (
            ("omission", omit),
            ("duplicate", duplicate),
            ("drift", drift),
            ("zero_scale", zero_scale),
            ("garbage_dimensions", garbage_dimensions),
        ):
            with self.subTest(mutation=name):
                self.reports["oldest-supported"] = copy.deepcopy(original)
                capability = self.reports["oldest-supported"]["capabilities"][0]
                mutation(capability)
                self.write_report("oldest-supported")
                self.assert_error_contains("primary_scaler_observations")

    def test_nonprimary_capability_requires_empty_primary_observations(self) -> None:
        capability = self.reports["oldest-supported"]["capabilities"][3]
        capability["primary_scaler_observations"] = [
            dict(PRIMARY_SCALER_OBSERVATIONS[0])
        ]
        self.write_report("oldest-supported")
        self.assert_error_contains("primary_scaler_observations")

    def test_class_irrelevant_metric_must_be_not_applicable(self) -> None:
        metric = self.reports["oldest-supported"]["capabilities"][0][
            "measurements"
        ]["metrics"]["flow_format"]
        metric.update({"status": "measured", "value": "420v", "reason": None})
        self.write_report("oldest-supported")
        self.assert_error_contains("must be not_applicable")

    def test_metric_unit_is_closed(self) -> None:
        metric = self.reports["oldest-supported"]["capabilities"][0][
            "measurements"
        ]["metrics"]["median_wall_seconds"]
        metric["unit"] = "milliseconds"
        self.write_report("oldest-supported")
        self.assert_error_contains("unit must be exactly 'seconds'")

    def test_p95_cannot_be_below_median(self) -> None:
        metrics = self.reports["oldest-supported"]["capabilities"][0][
            "measurements"
        ]["metrics"]
        metrics["median_wall_seconds"]["value"] = 2.0
        metrics["p95_wall_seconds"]["value"] = 1.0
        self.write_report("oldest-supported")
        self.assert_error_contains("p95 wall time is below median")

    def test_runnable_requires_three_sessions(self) -> None:
        measurements = self.reports["oldest-supported"]["capabilities"][0][
            "measurements"
        ]
        measurements["sessions"].pop()
        measurements["session_count"] = 2
        self.write_report("oldest-supported")
        self.assert_error_contains("requires three completed sessions")

    def test_completed_session_counts_are_closed(self) -> None:
        session = self.reports["oldest-supported"]["capabilities"][0][
            "measurements"
        ]["sessions"][0]
        session["completed_warmup_units"] = 4
        self.write_report("oldest-supported")
        self.assert_error_contains("completed-session closure differs")

    def test_timeout_class_records_120_seconds(self) -> None:
        capability = self.reports["oldest-supported"]["capabilities"][0]
        capability["runtime_disposition"] = "rejected"
        capability["reason_code"] = "runtime_probe_failed"
        capability["failure_class"] = "timeout"
        measurements = capability["measurements"]
        session = measurements["sessions"][0]
        session.update(
            {
                "completed_warmup_units": 5,
                "completed_measured_units": 0,
                "elapsed_seconds": 119,
                "timed_out": True,
                "outcome": "timeout",
                "failure_detail": "session timed out",
            }
        )
        for metric in COMMON_METRICS + CLASS_METRICS["primary_scaler"]:
            measurements["metrics"][metric].update(
                {
                    "status": "not_measured",
                    "value": None,
                    "reason": "runtime_probe_failed",
                }
            )
        measurements["repeatability"] = {
            "status": "not_measured",
            "mode": "not_applicable",
            "observations": [],
            "tolerance": None,
            "reason": "runtime_probe_failed",
        }
        self.write_report("oldest-supported")
        self.assert_error_contains("timeout must stop at 120 seconds")

    def test_repeatability_requires_three_observations(self) -> None:
        repeatability = self.reports["oldest-supported"]["capabilities"][0][
            "measurements"
        ]["repeatability"]
        repeatability["observations"].pop()
        self.write_report("oldest-supported")
        self.assert_error_contains("must contain three values")

    def test_nonrunnable_not_measured_closure_can_validate(self) -> None:
        capability = self.reports["oldest-supported"]["capabilities"][0]
        self.make_nonrunnable(
            capability,
            reason_code="api_absent",
            compile_state="unavailable",
            runtime_disposition="unavailable",
            failure_class="unsupported_contract",
            public_api_status="absent",
            hardware_eligibility="unknown",
            support_observed="not_available",
            model_readiness="not_required",
            offline_suitability="unavailable",
        )
        self.write_report("oldest-supported")
        _, errors = self.verifier().load_and_validate_raw_reports()
        self.assertEqual(errors, [])

    def test_core_ai_a18_model_unavailable_retains_public_compile_surface(self) -> None:
        capability = self.reports["core-ai"]["capabilities"][17]
        self.make_nonrunnable(
            capability,
            reason_code="model_unavailable",
            **self.reason_contracts_for_tests()["model_unavailable"],
        )
        self.write_report("core-ai")
        _, errors = self.verifier().load_and_validate_raw_reports()
        self.assertEqual(errors, [])

    def test_core_ai_a18_rejects_unavailable_compile_surface(self) -> None:
        capability = self.reports["core-ai"]["capabilities"][17]
        self.make_nonrunnable(
            capability,
            reason_code="model_unavailable",
            **self.reason_contracts_for_tests()["model_unavailable"],
        )
        capability["compile_state"] = "unavailable"
        self.write_report("core-ai")
        self.assert_error_contains(
            "core-ai A18 compile surface must be available or conditional"
        )

    def test_core_ai_a18_rejects_absent_public_surface(self) -> None:
        capability = self.reports["core-ai"]["capabilities"][17]
        self.make_nonrunnable(
            capability,
            reason_code="model_unavailable",
            **self.reason_contracts_for_tests()["model_unavailable"],
        )
        capability["public_api_status"] = "absent"
        self.write_report("core-ai")
        self.assert_error_contains("core-ai A18 must record a public API surface")

    def test_nonrunnable_zero_sessions_still_requires_failure_class(self) -> None:
        capability = self.reports["oldest-supported"]["capabilities"][0]
        capability.update(
            {
                "compile_state": "unavailable",
                "runtime_disposition": "unavailable",
                "reason_code": "api_absent",
                "failure_class": "none",
                "public_api_status": "absent",
            }
        )
        measurements = capability["measurements"]
        measurements["session_count"] = 0
        measurements["sessions"] = []
        self.write_report("oldest-supported")
        self.assert_error_contains("non-runnable evidence requires a failure_class")

    def test_failure_class_must_match_reason(self) -> None:
        capability = self.reports["oldest-supported"]["capabilities"][0]
        capability.update(
            {
                "runtime_disposition": "rejected",
                "reason_code": "resource_limit",
                "failure_class": "processing_failure",
            }
        )
        self.write_report("oldest-supported")
        self.assert_error_contains("failure_class is incompatible with reason_code")

    def test_schema_digest_mutation_fails(self) -> None:
        path = self.root / HOST_SCHEMA_PATH
        schema = json.loads(path.read_text(encoding="utf-8"))
        schema["title"] = "mutated"
        path.write_bytes(canonical_json_bytes(schema))
        self.assert_error_contains("differs from its pinned schema digest")

    def test_external_schema_reference_resolution_fails_closed(self) -> None:
        path = self.root / AGGREGATE_SCHEMA_PATH
        schema = json.loads(path.read_text(encoding="utf-8"))
        schema["$defs"]["anchor"]["properties"]["host"]["$ref"] = (
            "missing-host-schema.json#/$defs/host"
        )
        path.write_bytes(canonical_json_bytes(schema))
        errors = validate_schema_bundle(self.root, verify_hashes=False)
        self.assertTrue(any("unresolved external schema reference" in error for error in errors))

    def test_internal_schema_pointer_resolution_fails_closed(self) -> None:
        path = self.root / HOST_SCHEMA_PATH
        schema = json.loads(path.read_text(encoding="utf-8"))
        schema["properties"]["host"]["$ref"] = "#/$defs/missingHost"
        path.write_bytes(canonical_json_bytes(schema))
        errors = validate_schema_bundle(self.root, verify_hashes=False)
        self.assertTrue(any("unresolved schema pointer" in error for error in errors))

    def test_aggregate_json_drift_fails_check(self) -> None:
        self.assertEqual(main(["--aggregate", "--root", str(self.root)]), 0)
        path = self.root / AGGREGATE_JSON_PATH
        path.write_bytes(path.read_bytes() + b" ")
        errors = self.verifier().check_outputs()
        self.assertTrue(any("differs from deterministic output" in error for error in errors))

    def test_markdown_drift_fails_check(self) -> None:
        self.assertEqual(main(["--aggregate", "--root", str(self.root)]), 0)
        path = self.root / AGGREGATE_MARKDOWN_PATH
        path.write_text("mutated\n", encoding="utf-8")
        errors = self.verifier().check_outputs()
        self.assertTrue(any("differs from deterministic output" in error for error in errors))

    def test_aggregate_output_symlink_fails_check(self) -> None:
        self.assertEqual(main(["--aggregate", "--root", str(self.root)]), 0)
        path = self.root / AGGREGATE_JSON_PATH
        target = self.root / "aggregate-target.json"
        path.replace(target)
        path.symlink_to(target)
        errors = self.verifier().check_outputs()
        self.assertTrue(any("symbolic-link component" in error for error in errors))

    def test_aggregate_carries_exact_four_by_eighteen_matrix(self) -> None:
        self.assertEqual(main(["--aggregate", "--root", str(self.root)]), 0)
        aggregate = json.loads((self.root / AGGREGATE_JSON_PATH).read_text())
        self.assertEqual([value["anchor"] for value in aggregate["anchors"]], list(ANCHORS))
        self.assertEqual(
            [value["id"] for value in aggregate["capabilities"]],
            [value[0] for value in CAPABILITY_IDENTITIES],
        )
        self.assertTrue(
            all(len(value["anchor_records"]) == 4 for value in aggregate["capabilities"])
        )

    def test_all_anchors_require_one_identical_source(self) -> None:
        marker = self.root / "source-marker.txt"
        marker.write_text("second commit\n", encoding="utf-8")
        self.git("add", "source-marker.txt")
        self.git("commit", "-q", "-m", "second source")
        second_commit = self.git("rev-parse", "HEAD").stdout.strip()
        second_tree = self.git("rev-parse", "HEAD^{tree}").stdout.strip()
        self.git("update-ref", "refs/remotes/origin/r01/test", second_commit)
        self.reports["core-ai"]["source_commit"] = second_commit
        self.reports["core-ai"]["source_tree"] = second_tree
        self.write_report("core-ai")
        self.assert_error_contains("one identical published source commit/tree")

    def test_report_anchor_must_match_canonical_path(self) -> None:
        self.reports["m3-air"]["anchor"] = "pro-max"
        self.write_report("m3-air")
        self.assert_error_contains("raw report m3-air.anchor")

    def test_fixture_binding_order_is_closed(self) -> None:
        bindings = self.reports["oldest-supported"]["fixture_bindings"]
        bindings[0], bindings[1] = bindings[1], bindings[0]
        self.write_report("oldest-supported")
        self.assert_error_contains("IDs/order differ")

    def test_capability_count_is_exactly_eighteen(self) -> None:
        self.reports["oldest-supported"]["capabilities"].pop()
        self.write_report("oldest-supported")
        self.assert_error_contains("must contain exactly A01-A18")

    def test_timestamp_requires_rfc3339_offset(self) -> None:
        self.reports["oldest-supported"]["generated_at"] = "2026-07-19 12:00:00"
        self.write_report("oldest-supported")
        self.assert_error_contains("must be an RFC3339 timestamp")

    def test_raw_report_must_use_canonical_json_bytes(self) -> None:
        path = self.root / RAW_REPORT_PATHS["oldest-supported"]
        path.write_bytes(path.read_bytes() + b" ")
        self.assert_error_contains("is not canonical deterministic JSON")

    def test_raw_report_symlink_is_rejected(self) -> None:
        path = self.root / RAW_REPORT_PATHS["oldest-supported"]
        target = self.root / "raw-target.json"
        target.write_bytes(path.read_bytes())
        path.unlink()
        path.symlink_to(target)
        self.assert_error_contains("contains symbolic-link component")

    def test_catalog_working_bytes_must_match_source(self) -> None:
        catalog = copy.deepcopy(self.catalog)
        catalog["generator_contract"]["id"] = "mutated"
        (self.root / FIXTURE_CATALOG_PATH).write_bytes(canonical_json_bytes(catalog))
        self.assert_error_contains("differs from source_commit")

    def test_preregistration_metric_contract_matches_report_shape(self) -> None:
        expected = {
            probe_class: list(COMMON_METRICS + metrics)
            for probe_class, metrics in CLASS_METRICS.items()
        }
        expected["primary_scaler"] = list(COMMON_METRICS) + [
            "primary_scaler_observations",
            "frame_rate",
        ]
        self.assertEqual(self.preregistration["class_metrics"], expected)

    def test_preregistration_semantic_policy_mutation_fails(self) -> None:
        preregistration = copy.deepcopy(self.preregistration)
        preregistration["class_metrics"]["primary_scaler"].remove(
            "primary_scaler_observations"
        )
        (self.root / PREREGISTRATION_PATH).write_bytes(
            canonical_json_bytes(preregistration)
        )
        self.assert_error_contains("class_metrics differs from the closed R01 policy")

    def test_preregistration_privacy_mutation_fails(self) -> None:
        preregistration = copy.deepcopy(self.preregistration)
        preregistration["anchor_assignments"][0]["contract"] = (
            "operator fixture at /Users/private"
        )
        (self.root / PREREGISTRATION_PATH).write_bytes(
            canonical_json_bytes(preregistration)
        )
        self.assert_error_contains("contains a private filesystem path")

    def test_deterministic_fixture_contract_mutation_fails(self) -> None:
        catalog = copy.deepcopy(self.catalog)
        catalog["fixtures"][0]["generator"] = "mutated-generator"
        catalog_path = self.root / FIXTURE_CATALOG_PATH
        catalog_path.write_bytes(canonical_json_bytes(catalog))
        preregistration = copy.deepcopy(self.preregistration)
        preregistration["fixture_catalog"]["sha256"] = sha256_bytes(
            catalog_path.read_bytes()
        )
        (self.root / PREREGISTRATION_PATH).write_bytes(
            canonical_json_bytes(preregistration)
        )
        self.assert_error_contains(
            "fixture scaler-720p differs from its deterministic contract"
        )

    def test_aggregate_raw_bindings_match_exact_bytes(self) -> None:
        self.assertEqual(main(["--aggregate", "--root", str(self.root)]), 0)
        aggregate = json.loads((self.root / AGGREGATE_JSON_PATH).read_text())
        for anchor_record in aggregate["anchors"]:
            path = self.root / anchor_record["source_report_binding"]["path"]
            payload = path.read_bytes()
            self.assertEqual(anchor_record["source_report_binding"]["size_bytes"], len(payload))
            self.assertEqual(
                anchor_record["source_report_binding"]["sha256"],
                sha256_bytes(payload),
            )


class R01CapabilityPureTests(unittest.TestCase):
    def test_decode_rejects_all_nonfinite_json_constants(self) -> None:
        for constant in ("NaN", "Infinity", "-Infinity"):
            with self.subTest(constant=constant):
                with self.assertRaisesRegex(ValueError, "non-finite JSON number"):
                    decode_json_bytes(
                        ('{"value": ' + constant + "}").encode("ascii"),
                        "nonfinite.json",
                    )

    def test_canonical_json_rejects_all_nonfinite_float_values(self) -> None:
        for value in (float("nan"), float("inf"), float("-inf")):
            with self.subTest(value=value):
                with self.assertRaises(ValueError):
                    canonical_json_bytes({"value": value})

    def test_local_model_path_is_closed_and_symlink_safe(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            local_assets = root / ".r01-local-assets"
            local_assets.mkdir()
            model = local_assets / "probe.mlmodelc"
            model.write_bytes(b"model")
            errors: list[str] = []
            self.assertEqual(
                validate_local_model_path(
                    root,
                    ".r01-local-assets/probe.mlmodelc",
                    "model.path",
                    errors,
                ),
                Path(".r01-local-assets/probe.mlmodelc"),
            )
            self.assertEqual(errors, [])

            invalid_paths = (
                "../probe.mlmodelc",
                ".r01-local-assets/../probe.mlmodelc",
                ".r01-local-assets//probe.mlmodelc",
                ".r01-local-assets/./probe.mlmodelc",
                ".r01-local-assets\\probe.mlmodelc",
                "r01-local-assets/probe.mlmodelc",
                "/.r01-local-assets/probe.mlmodelc",
            )
            for invalid in invalid_paths:
                with self.subTest(invalid=invalid):
                    invalid_errors: list[str] = []
                    self.assertIsNone(
                        validate_local_model_path(
                            root,
                            invalid,
                            "model.path",
                            invalid_errors,
                        )
                    )
                    self.assertTrue(invalid_errors)

            outside = root / "outside"
            outside.mkdir()
            (local_assets / "link").symlink_to(outside, target_is_directory=True)
            symlink_errors: list[str] = []
            self.assertIsNone(
                validate_local_model_path(
                    root,
                    ".r01-local-assets/link/probe.mlmodelc",
                    "model.path",
                    symlink_errors,
                )
            )
            self.assertTrue(
                any("symbolic-link component" in error for error in symlink_errors)
            )
