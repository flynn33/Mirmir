from __future__ import annotations

import copy
import hashlib
import json
import math
from pathlib import Path
import tempfile
import unittest
from unittest import mock

from validation.calibration_v2.reference.lut_oracle import (
    OracleError,
    ROUTES,
    canonical_compiler_input_sha256,
    compile_all_route_bytes,
    load_locked_compiler_input,
    parse_locked_compiler_input,
    validate_lut,
)
from validation.calibration_v2.release_lock import (
    NativeParityMismatch,
    ReleaseLockError,
    build_configuration_lock,
    build_configuration_lock_from_bindings,
    build_locked_quality_policy,
    build_native_parity_manifest,
    build_lut_manifest,
    build_p06_release_bundle_manifest,
    configuration_lock_document,
    dispatch_measurement_document,
    locked_compiler_input_document,
    locked_metric_policy_document,
    operator_bank_document,
    route_analysis_grid_selection_document,
    validate_lut_manifest,
    validate_p06_release_bundle_manifest,
    validate_dispatch_measurement_document,
    video_mapping_document,
)
from validation.quality.src.mirmir_quality.json_tools import validate_schema
from validation.quality.src.mirmir_quality.holdout import HashBinding


REPOSITORY_ROOT = Path(__file__).resolve().parents[3]
FIXTURE = (
    REPOSITORY_ROOT
    / "validation"
    / "calibration_v2"
    / "fixtures"
    / "locked-compiler-input-shared-v1.json"
)
SCHEMA = (
    REPOSITORY_ROOT
    / "validation"
    / "calibration_v2"
    / "schemas"
    / "lut-manifest-v2.schema.json"
)
CONFIGURATION_HASH_FIELDS = (
    "mapping_sha256",
    "operator_bank_sha256",
    "quality_policy_sha256",
    "metric_policy_sha256",
    "metric_implementation_sha256",
    "metric_conformance_sha256",
    "degradation_policy_sha256",
    "actual_codec_fixture_sha256",
    "actual_codec_evidence_sha256",
    "quality_harness_implementation_manifest_sha256",
    "compiler_inputs_sha256",
    "route_luts_sha256",
    "corpus_manifest_sha256",
)


def canonical_bytes(value: object) -> bytes:
    return json.dumps(
        value,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
        allow_nan=False,
    ).encode("utf-8")


def manifest_hash(document: dict) -> str:
    value = dict(document)
    value.pop("manifest_sha256", None)
    return hashlib.sha256(canonical_bytes(value)).hexdigest()


def percentile(values: list[float], probability: float) -> float:
    position = (len(values) - 1) * probability
    lower = int(position)
    upper = min(len(values) - 1, lower + 1)
    fraction = position - lower
    return values[lower] + ((values[upper] - values[lower]) * fraction)


class ReleaseLUTManifestTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.configuration = load_locked_compiler_input(FIXTURE)
        cls.route_bytes = compile_all_route_bytes(cls.configuration)
        cls.plan = json.loads(
            (
                REPOSITORY_ROOT
                / "validation"
                / "calibration_v2"
                / "contracts"
                / "calibration-plan-v1.json"
            ).read_text(encoding="utf-8")
        )
        cls.metric_seed = json.loads(
            (
                REPOSITORY_ROOT
                / "validation"
                / "quality"
                / "policies"
                / "metric-policy.json"
            ).read_text(encoding="utf-8")
        )
        cls.tolerances_path = (
            REPOSITORY_ROOT
            / "validation"
            / "calibration_v2"
            / "contracts"
            / "metric-performance-tolerances-v1.json"
        )
        cls.tolerances = json.loads(cls.tolerances_path.read_text(encoding="utf-8"))
        cls.baseline_contract_path = (
            REPOSITORY_ROOT
            / "validation"
            / "calibration_v2"
            / "contracts"
            / "baseline-ablation-contract-v1.json"
        )
        cls.baseline_contract = json.loads(
            cls.baseline_contract_path.read_text(encoding="utf-8")
        )
        cls.baseline_contract_sha256 = hashlib.sha256(
            cls.baseline_contract_path.read_bytes()
        ).hexdigest()

    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.release_root = Path(self.temporary.name) / "release"
        self.release_root.mkdir()
        (self.release_root / "swift").mkdir()
        (self.release_root / "python").mkdir()
        (self.release_root / "sources").mkdir()
        (self.release_root / "locked-compiler-input.json").write_bytes(
            FIXTURE.read_bytes()
        )
        route_outputs = {}
        for route_name, route in ROUTES.items():
            payload = self.route_bytes[route_name]
            (self.release_root / route.filename).write_bytes(payload)
            (self.release_root / "swift" / route.filename).write_bytes(payload)
            (self.release_root / "python" / route.filename).write_bytes(payload)
            validated = validate_lut(
                payload,
                expected_configuration=self.configuration,
                expected_route=route,
            )
            route_outputs[route_name] = {
                "path": f"swift/{route.filename}",
                "whole_file_size_bytes": len(payload),
                "whole_file_sha256": validated.whole_file_sha256,
                "payload_sha256": validated.payload_sha256,
                "header_crc32": f"0x{validated.header_crc32:08X}",
                "payload_crc32": f"0x{validated.payload_crc32:08X}",
                "entry_count": validated.entry_count,
                "parameter_count": validated.parameter_count,
            }
        swift_source = b'{"implementation_role":"production_swift"}\n'
        python_source = b'{"implementation_role":"independent_test_python"}\n'
        (self.release_root / "sources" / "swift.json").write_bytes(swift_source)
        (self.release_root / "sources" / "python.json").write_bytes(python_source)
        parity = {
            "schema_version": "1.0.0",
            "manifest_id": "mirmir-native-lut-parity-v1",
            "status": "pass",
            "conflict_record": "Artifacts/ASH/conflict-resolution.md",
            "input_hashes": dict(self.configuration.hash_bindings),
            "implementations": {
                "production_swift": {
                    "implementation_id": "mirmir-swift-lut-compiler-v2",
                    "implementation_version": "1.0.0",
                    "source_manifest_path": "sources/swift.json",
                    "source_manifest_sha256": hashlib.sha256(swift_source).hexdigest(),
                    "source_manifest_size_bytes": len(swift_source),
                    "independence_attested": True,
                },
                "independent_test_python": {
                    "implementation_id": "mirmir-python-lut-oracle-v2",
                    "implementation_version": "1.0.0",
                    "source_manifest_path": "sources/python.json",
                    "source_manifest_sha256": hashlib.sha256(python_source).hexdigest(),
                    "source_manifest_size_bytes": len(python_source),
                    "independence_attested": True,
                },
            },
            "routes": [],
            "all_routes_byte_identical": True,
            "canonicalization": "sorted-key compact UTF-8 JSON with a trailing newline",
        }
        for route_name, route in ROUTES.items():
            production = route_outputs[route_name]
            independent = dict(production)
            independent["path"] = f"python/{route.filename}"
            parity["routes"].append(
                {
                    "route": route.name,
                    "route_id": route.route_id,
                    "expected_entry_count": route.entry_count,
                    "production_swift": production,
                    "independent_test_python": independent,
                    "byte_identical": True,
                    "payload_hash_identical": True,
                    "first_differing_byte_offset": None,
                }
            )
        self.parity = parity
        self._write_parity(parity)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def _write_parity(self, document: object) -> None:
        (self.release_root / "native-lut-parity-manifest.json").write_text(
            json.dumps(document, sort_keys=True, separators=(",", ":")) + "\n",
            encoding="utf-8",
        )

    def _dispatch_measurement(self) -> dict:
        input_bindings = {
            "configuration_id": "ash-p06-spatial-v2-test",
            "candidate_vector_sha256": "c" * 64,
            "shared_bank_configuration_sha256": "d" * 64,
            "mapping_sha256": "e" * 64,
            "operator_bank_sha256": "f" * 64,
            "metric_policy_sha256": "1" * 64,
            "compiler_inputs_sha256": "2" * 64,
            "calibration_plan_sha256": "3" * 64,
            "corpus_lock_bundle_sha256": "4" * 64,
            "validation_sample_lock_sha256": "5" * 64,
            "degradation_policy_sha256": "8" * 64,
            "raw_output_contract_sha256": "6" * 64,
            "full_control_configuration_sha256": "7" * 64,
        }
        expected = []
        raw_samples = []
        sample_index = 0
        for source_index in range(3):
            route = "direct-2x" if source_index == 2 else "direct-3over2"
            for profile_index in range(3):
                profile_id = f"{route}-profile-{profile_index}"
                profile_sha256 = hashlib.sha256(
                    profile_id.encode("utf-8")
                ).hexdigest()
                identity = {
                    "source_asset_id": f"validation-source-{source_index}",
                    "target_route": route,
                    "degradation_profile_id": profile_id,
                    "degradation_profile_sha256": profile_sha256,
                }
                expected.append(identity)
                repetitions = []
                for index in range(10):
                    repetitions.append(
                        {
                            "index": index,
                            "order": (
                                "full_then_control"
                                if index % 2 == 0
                                else "control_then_full"
                            ),
                            "full_analysis_nanoseconds": 500_000,
                            "full_dispatch_nanoseconds": (
                                100_000 + (sample_index * 5_000) + (index * 1_000)
                            ),
                            "full_reconstruction_nanoseconds": 10_000_000,
                            "control_reconstruction_nanoseconds": 10_000_000,
                        }
                    )
                output_hash = f"{sample_index + 1:x}" * 64
                raw_samples.append(
                    {
                        **identity,
                        "input_frame_sha256": f"{sample_index + 4:x}" * 64,
                        "full_output_sha256": output_hash,
                        "control_output_sha256": output_hash,
                        "lut_whole_file_sha256": (
                            "a" * 64 if route == "direct-2x" else "b" * 64
                        ),
                        "measurement_domain": (
                            "native_cpu_reference_projection_not_metal"
                        ),
                        "production_metal_constraint_satisfied": False,
                        "warmup_repetition_count": 3,
                        "measured_repetition_count": 10,
                        "input_bindings": input_bindings,
                        "repetitions": repetitions,
                    }
                )
                sample_index += 1
        return dict(
            dispatch_measurement_document(
                run_id="p06-dispatch-test",
                environment={
                    "hardware_model": "test-hardware",
                    "chip": "test-chip",
                    "logical_cpu_count": 8,
                    "physical_memory_bytes": 17179869184,
                    "os_version": "test-os",
                    "os_build": "test-build",
                    "swift_version": "test-swift",
                    "xcode_version": "test-xcode",
                    "executable_sha256": "a" * 64,
                    "source_manifest_sha256": "b" * 64,
                },
                input_bindings=input_bindings,
                raw_samples=raw_samples,
                expected_sample_profiles=expected,
            )
        )

    def test_build_and_reopen_cross_validates_all_route_bytes(self) -> None:
        output = self.release_root / "lut-manifest.json"
        document = build_lut_manifest(
            repository_root=REPOSITORY_ROOT,
            release_root=self.release_root,
            output_path=output,
        )
        validate_schema(document, SCHEMA)
        self.assertEqual(
            validate_lut_manifest(
                repository_root=REPOSITORY_ROOT,
                release_root=self.release_root,
                manifest_path=output,
            ),
            document,
        )
        self.assertEqual(
            [row["route"] for row in document["routes"]],
            ["direct_2x", "direct_3_over_2"],
        )
        self.assertFalse(document["holdout_accessed"])

    def test_native_parity_builder_reopens_distinct_outputs_and_sources(self) -> None:
        parity_path = self.release_root / "native-lut-parity-manifest.json"
        parity_path.unlink()
        document = build_native_parity_manifest(
            release_root=self.release_root,
            compiler_input_path=self.release_root / "locked-compiler-input.json",
            production_source_manifest_path="sources/swift.json",
            independent_source_manifest_path="sources/python.json",
            output_path=parity_path,
            failure_output_path=self.release_root / "native-lut-parity-failure.json",
            conflict_record="Artifacts/ASH/conflict-resolution.md",
        )
        self.assertTrue(document["all_routes_byte_identical"])
        self.assertTrue(parity_path.is_file())

    def test_native_parity_failure_preserves_first_differing_offset(self) -> None:
        parity_path = self.release_root / "native-lut-parity-manifest.json"
        parity_path.unlink()
        failure_path = self.release_root / "native-lut-parity-failure.json"
        record = {
            "path": "swift/direct2x.ashlut",
            "whole_file_size_bytes": 3,
            "whole_file_sha256": "1" * 64,
            "payload_sha256": "2" * 64,
            "header_crc32": "0x00000001",
            "payload_crc32": "0x00000002",
            "entry_count": 4096,
            "parameter_count": 1,
        }
        independent = dict(record)
        independent["path"] = "python/direct2x.ashlut"
        independent["whole_file_sha256"] = "3" * 64
        with mock.patch(
            "validation.calibration_v2.release_lock._validated_output_record",
            side_effect=[(record, b"abc"), (independent, b"axc")],
        ):
            with self.assertRaises(NativeParityMismatch) as caught:
                build_native_parity_manifest(
                    release_root=self.release_root,
                    compiler_input_path=self.release_root / "locked-compiler-input.json",
                    production_source_manifest_path="sources/swift.json",
                    independent_source_manifest_path="sources/python.json",
                    output_path=parity_path,
                    failure_output_path=failure_path,
                    conflict_record="Artifacts/ASH/conflict-resolution.md",
                )
        self.assertEqual(caught.exception.first_differing_byte_offset, 1)
        self.assertEqual(caught.exception.failure_path, failure_path)
        preserved = json.loads(failure_path.read_text(encoding="utf-8"))
        self.assertEqual(preserved["first_differing_byte_offset"], 1)
        self.assertEqual(preserved["status"], "failed_preserved")
        self.assertFalse(parity_path.exists())

    def test_existing_output_is_never_overwritten(self) -> None:
        output = self.release_root / "lut-manifest.json"
        output.write_bytes(b"existing")
        with self.assertRaises(FileExistsError):
            build_lut_manifest(
                repository_root=REPOSITORY_ROOT,
                release_root=self.release_root,
                output_path=output,
            )
        self.assertEqual(output.read_bytes(), b"existing")

    def test_parity_hash_substitution_is_rejected(self) -> None:
        altered = copy.deepcopy(self.parity)
        altered["routes"][0]["production_swift"]["whole_file_sha256"] = "3" * 64
        self._write_parity(altered)
        with self.assertRaises(ReleaseLockError):
            build_lut_manifest(
                repository_root=REPOSITORY_ROOT,
                release_root=self.release_root,
                output_path=self.release_root / "lut-manifest.json",
            )

    def test_missing_independent_output_is_rejected(self) -> None:
        (self.release_root / "python" / "direct2x.ashlut").unlink()
        with self.assertRaises(ReleaseLockError):
            build_lut_manifest(
                repository_root=REPOSITORY_ROOT,
                release_root=self.release_root,
                output_path=self.release_root / "lut-manifest.json",
            )

    def test_changed_source_manifest_is_rejected(self) -> None:
        (self.release_root / "sources" / "python.json").write_bytes(b"changed\n")
        with self.assertRaises(ReleaseLockError):
            build_lut_manifest(
                repository_root=REPOSITORY_ROOT,
                release_root=self.release_root,
                output_path=self.release_root / "lut-manifest.json",
            )

    def test_route_tamper_is_rejected_after_manifest_publication(self) -> None:
        output = self.release_root / "lut-manifest.json"
        build_lut_manifest(
            repository_root=REPOSITORY_ROOT,
            release_root=self.release_root,
            output_path=output,
        )
        route_path = self.release_root / "direct2x.ashlut"
        payload = bytearray(route_path.read_bytes())
        payload[-1] ^= 1
        route_path.write_bytes(payload)
        with self.assertRaises((OracleError, ReleaseLockError)):
            validate_lut_manifest(
                repository_root=REPOSITORY_ROOT,
                release_root=self.release_root,
                manifest_path=output,
            )

    def test_symbolic_route_is_rejected(self) -> None:
        route_path = self.release_root / "direct2x.ashlut"
        target = self.release_root / "target.ashlut"
        route_path.rename(target)
        route_path.symlink_to(target.name)
        with self.assertRaises(ReleaseLockError):
            build_lut_manifest(
                repository_root=REPOSITORY_ROOT,
                release_root=self.release_root,
                output_path=self.release_root / "lut-manifest.json",
            )

    def test_candidate_and_selected_mapping_bank_are_exact_schema_projections(self) -> None:
        vector = dict(self.plan["search"]["initial_vector_values"])
        candidate_mapping = video_mapping_document(
            vector=vector,
            plan=self.plan,
            configuration_id="ash-p06-candidate-test",
            mapping_seed_sha256="1" * 64,
            status="calibration_candidate",
        )
        candidate_bank = operator_bank_document(
            vector=vector,
            plan=self.plan,
            configuration_id="ash-p06-candidate-test",
            operator_bank_seed_sha256="2" * 64,
            status="calibration_candidate",
        )
        self.assertEqual(
            candidate_mapping["selection_binding"],
            {
                "calibration_selection_sha256": None,
                "selected_evaluation_sha256": None,
            },
        )
        self.assertEqual(
            candidate_mapping["shared_bank_configuration_sha256"],
            candidate_bank["shared_bank_configuration_sha256"],
        )
        self.assertEqual(
            candidate_bank["coordinate_policies"]["direct_2x"],
            {
                "luma_coordinate_policy": vector[
                    "direct_2x_luma_coordinate_policy"
                ],
                "chroma_coordinate_policy": vector[
                    "direct_2x_chroma_coordinate_policy"
                ],
            },
        )
        selected_mapping = video_mapping_document(
            vector=vector,
            plan=self.plan,
            configuration_id="ash-p06-spatial-v2-test",
            mapping_seed_sha256="1" * 64,
            status="locked_before_p07",
            calibration_selection_sha256="3" * 64,
            selected_evaluation_sha256="4" * 64,
        )
        selected_bank = operator_bank_document(
            vector=vector,
            plan=self.plan,
            configuration_id="ash-p06-spatial-v2-test",
            operator_bank_seed_sha256="2" * 64,
            status="locked_before_p07",
            calibration_selection_sha256="3" * 64,
            selected_evaluation_sha256="4" * 64,
        )
        self.assertNotEqual(
            hashlib.sha256(
                json.dumps(candidate_mapping, sort_keys=True, separators=(",", ":")).encode()
            ).hexdigest(),
            hashlib.sha256(
                json.dumps(selected_mapping, sort_keys=True, separators=(",", ":")).encode()
            ).hexdigest(),
        )
        self.assertEqual(
            selected_mapping["configuration_id"],
            selected_bank["configuration_id"],
        )

    def test_mapping_rejects_invalid_spatial_threshold_pair(self) -> None:
        vector = dict(self.plan["search"]["initial_vector_values"])
        vector["edge_present_high_unorm15"] = vector["edge_present_low_unorm15"]
        with self.assertRaises(ReleaseLockError):
            video_mapping_document(
                vector=vector,
                plan=self.plan,
                configuration_id="ash-p06-candidate-test",
                mapping_seed_sha256="1" * 64,
                status="calibration_candidate",
            )

    def test_locked_projection_rejects_missing_selection_binding(self) -> None:
        vector = dict(self.plan["search"]["initial_vector_values"])
        with self.assertRaises(ReleaseLockError):
            operator_bank_document(
                vector=vector,
                plan=self.plan,
                configuration_id="ash-p06-spatial-v2-test",
                operator_bank_seed_sha256="2" * 64,
                status="locked_before_p07",
            )

    def test_compiler_input_projection_self_hashes_and_parses(self) -> None:
        vector = dict(self.plan["search"]["initial_vector_values"])
        document = locked_compiler_input_document(
            vector=vector,
            plan=self.plan,
            configuration_id="ash-p06-spatial-v2-test",
            mapping_sha256="1" * 64,
            operator_bank_sha256="2" * 64,
            metric_policy_sha256="3" * 64,
            calibration_plan_sha256="4" * 64,
            corpus_lock_bundle_sha256="5" * 64,
        )
        parsed = parse_locked_compiler_input(document)
        self.assertEqual(parsed.configuration_id, "ash-p06-spatial-v2-test")
        self.assertEqual(
            parsed.routes["direct_2x"].luma_coordinate_policy,
            vector["direct_2x_luma_coordinate_policy"],
        )
        self.assertEqual(
            parsed.routes["direct_2x"].chroma_coordinate_policy,
            vector["direct_2x_chroma_coordinate_policy"],
        )
        self.assertEqual(
            document["hash_bindings"]["compiler_inputs_sha256"],
            canonical_compiler_input_sha256(document),
        )
        denominator = vector["penalty_decay_denominator"]
        self.assertEqual(
            document["compiler_policy"]["penalty_to_weight_unorm16"][255],
            ((65535 * denominator) + ((denominator + 255) // 2))
            // (denominator + 255),
        )

    def test_dispatch_measurement_recomputes_and_locks_metric_policy(self) -> None:
        measurement = self._dispatch_measurement()
        validate_dispatch_measurement_document(measurement)
        self.assertEqual(measurement["aggregate"]["sample_count"], 9)
        self.assertEqual(measurement["aggregate"]["repetition_count"], 90)
        self.assertEqual(
            [
                (row["source_asset_id"], row["degradation_profile_id"])
                for row in measurement["samples"]
            ],
            sorted(
                (
                    row["source_asset_id"],
                    row["degradation_profile_id"],
                )
                for row in measurement["samples"]
            ),
        )
        measurement_bytes = canonical_bytes(measurement) + b"\n"
        policy = locked_metric_policy_document(
            metric_seed=self.metric_seed,
            tolerances=self.tolerances,
            tolerances_sha256=hashlib.sha256(
                self.tolerances_path.read_bytes()
            ).hexdigest(),
            dispatch_measurement=measurement,
            dispatch_measurement_file_sha256=hashlib.sha256(
                measurement_bytes
            ).hexdigest(),
            dispatch_measurement_size_bytes=len(measurement_bytes),
        )
        self.assertEqual(policy["status"], "locked")
        self.assertEqual(policy["unlocked_release_fields"], [])
        expected_budget = max(
            5,
            math.ceil(
                measurement["aggregate"]["measured_validation_p95_percent"]
                + 5.0
            ),
        )
        self.assertEqual(
            policy["release_tolerances"]["dispatch_overhead_budget"][
                "derived_budget_percent"
            ],
            expected_budget,
        )

    def test_dispatch_measurement_rejects_formula_tamper(self) -> None:
        measurement = self._dispatch_measurement()
        measurement["samples"][0]["repetitions"][0]["overhead_percent"] += 0.5
        measurement["manifest_sha256"] = manifest_hash(measurement)
        with self.assertRaises(ReleaseLockError):
            validate_dispatch_measurement_document(measurement)

    def test_dispatch_measurement_rejects_control_pixel_change(self) -> None:
        measurement = self._dispatch_measurement()
        measurement["samples"][0]["control_output_sha256"] = "f" * 64
        measurement["manifest_sha256"] = manifest_hash(measurement)
        with self.assertRaises(ReleaseLockError):
            validate_dispatch_measurement_document(measurement)

    def test_dispatch_measurement_rejects_profile_matrix_tamper(self) -> None:
        measurement = self._dispatch_measurement()
        measurement["samples"][0]["degradation_profile_id"] = "changed-profile"
        measurement["manifest_sha256"] = manifest_hash(measurement)
        with self.assertRaises(ReleaseLockError):
            validate_dispatch_measurement_document(measurement)

    def test_dispatch_measurement_rejects_unsorted_sample_rows(self) -> None:
        measurement = self._dispatch_measurement()
        measurement["samples"][0], measurement["samples"][1] = (
            measurement["samples"][1],
            measurement["samples"][0],
        )
        measurement["manifest_sha256"] = manifest_hash(measurement)
        with self.assertRaises(ReleaseLockError):
            validate_dispatch_measurement_document(measurement)

    def test_configuration_lock_publishes_exact_nonzero_bindings(self) -> None:
        bindings = {
            field: hashlib.sha256(field.encode("utf-8")).hexdigest()
            for field in CONFIGURATION_HASH_FIELDS
        }
        path = Path(self.temporary.name) / "configuration-lock.json"
        document = build_configuration_lock(
            output_path=path,
            locked_utc="2026-07-11T23:59:00Z",
            hash_bindings=bindings,
        )
        self.assertEqual(
            path.read_bytes(),
            canonical_bytes(document) + b"\n",
        )
        self.assertIsNone(document["holdout_opened_utc"])
        validate_schema(
            document,
            REPOSITORY_ROOT
            / "validation"
            / "quality"
            / "schemas"
            / "configuration-lock.schema.json",
        )

    def _selected_controls(self) -> dict[str, object]:
        bank = hashlib.sha256(b"shared-bank").hexdigest()

        def digest(value: str) -> str:
            return hashlib.sha256(value.encode("utf-8")).hexdigest()

        base = {
            "configuration_sha256": digest("configuration"),
            "selection_sha256": digest("selection"),
            "shared_bank_configuration_sha256": bank,
        }
        return {
            "shared_bank_configuration_sha256": bank,
            "quality_policy_seed_sha256": (
                self.baseline_contract["quality_policy_seed"]["sha256"]
            ),
            "baseline_ablation_contract_sha256": self.baseline_contract_sha256,
            "best_fixed": {
                "control_id": "fixed-descriptor-uniform-v1",
                "descriptor_id": 6,
                **base,
            },
            "conventional": {
                "control_id": "uniform-conventional-selection-v1",
                "algorithm_id": "lanczos3-separable-v1",
                **base,
            },
            "non_ash_selector": {
                "selector_id": "continuous-linear-bank-selector-q15-v1",
                **base,
                "rule_sha256": digest("rule"),
                "candidate_evaluation_budget": 1513,
            },
            "state_only": {
                "control_id": "ash-state-only-base-descriptor-v1",
                **base,
            },
            "state_plus_branch": {
                "control_id": "ash-state-plus-branch-compiler-v1",
                **base,
            },
            "h07_direct_3_over_2": {
                "experiment_id": "H07",
                "direct_id": "direct3over2-locked-route-v1",
                "control_id": "direct2x-then-lanczos3-control-v1",
                **base,
                "evidence_sha256": digest("h07-evidence"),
            },
            "nearest_same_writer": {
                "control_id": "nearest-same-writer-420v-v1",
                **base,
            },
            "current_production_ash": {
                "control_id": "p00-current-production-ash-baseline-v1",
                **base,
            },
        }

    def test_locked_quality_policy_projects_and_publishes_exact_controls(self) -> None:
        selected = self._selected_controls()
        output = Path(self.temporary.name) / "locked-quality-policy.json"
        document = build_locked_quality_policy(
            output_path=output,
            selected_controls=selected,
            quality_policy_seed_sha256=selected["quality_policy_seed_sha256"],
            baseline_ablation_contract=self.baseline_contract,
            baseline_ablation_contract_sha256=self.baseline_contract_sha256,
            input_bundle_sha256=hashlib.sha256(b"input-bundle").hexdigest(),
            shared_bank_configuration_sha256=selected[
                "shared_bank_configuration_sha256"
            ],
        )
        self.assertEqual(
            set(document["selected_controls"]),
            {
                "best_fixed",
                "conventional",
                "non_ash_selector",
                "state_only",
                "state_plus_branch",
                "h07_direct_3_over_2",
                "nearest_same_writer",
                "current_production_ash",
            },
        )
        self.assertEqual(output.read_bytes(), canonical_bytes(document) + b"\n")
        self.assertEqual(document["manifest_sha256"], manifest_hash(document))

    def test_locked_quality_policy_rejects_stale_control_bank(self) -> None:
        selected = self._selected_controls()
        selected["best_fixed"]["shared_bank_configuration_sha256"] = "f" * 64
        with self.assertRaises(ReleaseLockError):
            build_locked_quality_policy(
                output_path=Path(self.temporary.name) / "locked-quality-policy.json",
                selected_controls=selected,
                quality_policy_seed_sha256=selected["quality_policy_seed_sha256"],
                baseline_ablation_contract=self.baseline_contract,
                baseline_ablation_contract_sha256=self.baseline_contract_sha256,
                input_bundle_sha256=hashlib.sha256(b"input-bundle").hexdigest(),
                shared_bank_configuration_sha256=selected[
                    "shared_bank_configuration_sha256"
                ],
            )

    def test_configuration_lock_rejects_missing_extra_zero_and_bad_time(self) -> None:
        bindings = {
            field: hashlib.sha256(field.encode("utf-8")).hexdigest()
            for field in CONFIGURATION_HASH_FIELDS
        }
        missing = dict(bindings)
        missing.pop("mapping_sha256")
        with self.assertRaises(ReleaseLockError):
            configuration_lock_document(
                locked_utc="2026-07-11T23:59:00Z",
                hash_bindings=missing,
            )
        extra = {**bindings, "unexpected_sha256": "1" * 64}
        with self.assertRaises(ReleaseLockError):
            configuration_lock_document(
                locked_utc="2026-07-11T23:59:00Z",
                hash_bindings=extra,
            )
        zero = dict(bindings)
        zero["mapping_sha256"] = "0" * 64
        with self.assertRaises(ReleaseLockError):
            configuration_lock_document(
                locked_utc="2026-07-11T23:59:00Z",
                hash_bindings=zero,
            )
        with self.assertRaises(ReleaseLockError):
            configuration_lock_document(
                locked_utc="not-a-date",
                hash_bindings=bindings,
            )

    def test_configuration_lock_derives_and_rechecks_bound_artifacts(self) -> None:
        root = Path(self.temporary.name)
        bindings = {}
        for field in CONFIGURATION_HASH_FIELDS:
            path = root / f"{field}.json"
            path.write_text(f"{field}\n", encoding="utf-8")
            bindings[field] = HashBinding(path=path, root=root)
        harness_field = "quality_harness_implementation_manifest_sha256"
        bindings[harness_field] = HashBinding(
            path=bindings[harness_field].path,
            root=root,
            digest_mode="quality_harness_manifest",
        )
        expected = {
            field: hashlib.sha256(field.encode("utf-8")).hexdigest()
            for field in CONFIGURATION_HASH_FIELDS
        }
        output = root / "configuration-lock.json"
        with mock.patch(
            "validation.calibration_v2.release_lock.hash_binding_digest",
            side_effect=lambda field, binding: expected[field],
        ) as digest:
            document = build_configuration_lock_from_bindings(
                output_path=output,
                locked_utc="2026-07-11T23:59:00Z",
                artifact_bindings=bindings,
            )
        self.assertEqual(
            {field: document[field] for field in CONFIGURATION_HASH_FIELDS},
            expected,
        )
        self.assertEqual(digest.call_count, len(CONFIGURATION_HASH_FIELDS) * 2)
        self.assertEqual(output.read_bytes(), canonical_bytes(document) + b"\n")

    def test_configuration_binding_requires_recursive_harness_validation(self) -> None:
        root = Path(self.temporary.name)
        bindings = {}
        for field in CONFIGURATION_HASH_FIELDS:
            path = root / f"{field}.json"
            path.write_text(f"{field}\n", encoding="utf-8")
            bindings[field] = HashBinding(path=path, root=root)
        with self.assertRaises(ReleaseLockError):
            build_configuration_lock_from_bindings(
                output_path=root / "configuration-lock.json",
                locked_utc="2026-07-11T23:59:00Z",
                artifact_bindings=bindings,
            )

    def _release_bundle_root(self) -> tuple[Path, str]:
        root = Path(self.temporary.name) / "bundle"
        root.mkdir()
        selected_path = f"evaluations/{'a' * 64}.json"
        paths = [
            "calibration-selection.json",
            selected_path,
            "calibration-run-ledger.json",
            "live-holdout-preopen-verification.json",
            "dispatch-measurement.json",
            "locked-mapping.json",
            "locked-operator-bank.json",
            "locked-quality-policy.json",
            "locked-metric-policy.json",
            "locked-compiler-input.json",
            "route-analysis-grid-selection.json",
            "direct2x.ashlut",
            "direct3over2.ashlut",
            "native-lut-parity-manifest.json",
            "lut-manifest.json",
            "configuration-lock.json",
            "p06-evidence-closure.json",
        ]
        for index, relative in enumerate(paths):
            path = root.joinpath(*relative.split("/"))
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(f"artifact-{index}\n".encode())
        return root, selected_path

    def test_release_bundle_binds_exact_required_output_set(self) -> None:
        root, selected_path = self._release_bundle_root()
        manifest_path = root / "p06-release-bundle.json"
        with mock.patch(
            "validation.calibration_v2.release_lock._validate_p06_release_cross_bindings"
        ):
            document = build_p06_release_bundle_manifest(
                release_root=root,
                output_path=manifest_path,
                configuration_id="ash-p06-spatial-v2-test",
                locked_utc="2026-07-11T23:59:00Z",
                input_bundle_sha256="1" * 64,
                corpus_lock_bundle_sha256="2" * 64,
                selected_evaluation_path=selected_path,
            )
            self.assertEqual(len(document["artifacts"]), 17)
            self.assertEqual(
                validate_p06_release_bundle_manifest(
                    release_root=root,
                    manifest_path=manifest_path,
                ),
                document,
            )

    def test_release_bundle_rejects_postlock_artifact_change(self) -> None:
        root, selected_path = self._release_bundle_root()
        manifest_path = root / "p06-release-bundle.json"
        with mock.patch(
            "validation.calibration_v2.release_lock._validate_p06_release_cross_bindings"
        ):
            build_p06_release_bundle_manifest(
                release_root=root,
                output_path=manifest_path,
                configuration_id="ash-p06-spatial-v2-test",
                locked_utc="2026-07-11T23:59:00Z",
                input_bundle_sha256="1" * 64,
                corpus_lock_bundle_sha256="2" * 64,
                selected_evaluation_path=selected_path,
            )
        (root / "configuration-lock.json").write_bytes(b"changed\n")
        with self.assertRaises(ReleaseLockError):
            validate_p06_release_bundle_manifest(
                release_root=root,
                manifest_path=manifest_path,
            )

    def test_route_selection_freezes_both_routes_and_hashes(self) -> None:
        vector = dict(self.plan["search"]["initial_vector_values"])
        document = route_analysis_grid_selection_document(
            vector=vector,
            plan=self.plan,
            configuration_id="ash-p06-spatial-v2-test",
            calibration_selection_sha256="1" * 64,
            selected_evaluation_sha256="2" * 64,
            mapping_sha256="3" * 64,
            operator_bank_sha256="4" * 64,
            compiler_inputs_sha256="5" * 64,
        )
        self.assertEqual(
            [route["route"] for route in document["routes"]],
            ["direct_2x", "direct_3_over_2"],
        )
        self.assertEqual(
            document["routes"][0]["luma_coordinate_policy"],
            vector["direct_2x_luma_coordinate_policy"],
        )
        self.assertEqual(
            document["routes"][0]["chroma_coordinate_policy"],
            vector["direct_2x_chroma_coordinate_policy"],
        )
        self.assertEqual(document["manifest_sha256"], manifest_hash(document))


if __name__ == "__main__":
    unittest.main()
