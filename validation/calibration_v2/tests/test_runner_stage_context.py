from __future__ import annotations

from contextlib import ExitStack
import hashlib
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock

from validation.calibration_v2 import runner
from validation.quality.src.mirmir_quality.json_tools import (
    canonical_sha256,
    manifest_sha256,
    write_json,
)
from validation.quality.src.mirmir_quality.production_dry_run import (
    CandidateAdapter,
)


CALIBRATION_ROOT = Path(__file__).resolve().parents[1]


class _BoundWithoutPixels:
    def __init__(
        self,
        documents: dict[str, dict[str, object]] | None = None,
    ) -> None:
        self.verification_count = 0
        self.documents = {} if documents is None else documents

    def verify_unchanged(self) -> None:
        self.verification_count += 1


class _LifecycleCallable:
    def __init__(self, *, close_error: BaseException | None = None) -> None:
        self.close_count = 0
        self.close_error = close_error

    def __call__(self, *_args: object, **_kwargs: object) -> object:
        raise AssertionError("lifecycle callable reconstruction was not expected")

    def close(self) -> None:
        self.close_count += 1
        if self.close_error is not None:
            raise self.close_error


class _LifecycleCallableWithoutClose:
    def __call__(self, *_args: object, **_kwargs: object) -> object:
        raise AssertionError("lifecycle callable reconstruction was not expected")


class _LifecycleView:
    @staticmethod
    def _unconsumed_case_tokens() -> tuple[object, ...]:
        return ()


class AdapterLifecycleTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.plan = json.loads(
            (CALIBRATION_ROOT / "contracts/calibration-plan-v1.json").read_text(
                encoding="utf-8"
            )
        )
        cls.vector = dict(cls.plan["search"]["initial_vector_values"])
        cls.baseline_contract = json.loads(
            (CALIBRATION_ROOT / "contracts/baseline-ablation-contract-v1.json").read_text(
                encoding="utf-8"
            )
        )
        cls.bank_sha256 = runner.shared_bank_configuration_sha256(
            cls.vector,
            cls.plan,
        )

    def _executor(
        self,
        callable_value: object,
        evaluator: object,
        *,
        analytic_test_mode: bool = True,
    ) -> runner.CalibrationExecutor:
        configuration = {"implementation_role": "analytic_test_fixture"}
        adapter = CandidateAdapter(
            candidate_id="adapter-lifecycle-test",
            configuration=configuration,
            configuration_sha256=canonical_sha256(configuration),
            callable=callable_value,
        )
        executor = object.__new__(runner.CalibrationExecutor)
        executor._development_control_selections = {}
        executor._validation_control_selections = {}
        executor._validation_candidate_evidence_path = None
        executor._validation_candidate_evidence_file_binding = None
        executor._validation_candidate_evidence_binding = None
        executor._loaded_split_frames = {}
        executor.candidate = SimpleNamespace(
            adapter_factory=lambda _vector, _split: adapter,
            evaluator=evaluator,
        )
        executor.analytic_test_mode = analytic_test_mode
        executor.measurement_resolver = lambda _request: {}
        executor._split_frames = lambda *_args, **_kwargs: ()
        return executor

    def _evaluate_with_patched_validators(
        self,
        executor: runner.CalibrationExecutor,
    ) -> tuple[object, object, bool, tuple[object, ...]]:
        evaluation = {"evaluation": "accepted"}
        bundle = runner.ControlSelectionBundle(
            selection_stage="development_provisional",
            shared_bank_configuration_sha256=self.bank_sha256,
            artifacts={},
            bundle_sha256="a" * 64,
        )
        patches = (
            mock.patch.object(runner, "load_split_metadata", return_value=[]),
            mock.patch.object(
                runner,
                "_evaluation_view",
                return_value=_LifecycleView(),
            ),
            mock.patch.object(runner, "_validate_runtime_adapter"),
            mock.patch.object(runner, "_validate_evaluation_shape"),
            mock.patch.object(
                runner,
                "_control_selection_bundle",
                return_value=bundle,
            ),
            mock.patch.object(runner, "_validate_dispatch_measurement_evidence"),
            mock.patch.object(
                runner,
                "summarize_evaluation",
                return_value={"summary": "accepted"},
            ),
            mock.patch.object(
                runner,
                "evaluation_feasible",
                return_value=(True, ()),
            ),
        )
        with ExitStack() as stack:
            for patcher in patches:
                stack.enter_context(patcher)
            return executor._evaluate(
                self.vector,
                "development",
                bound=_BoundWithoutPixels(
                    {"baseline_ablation_contract": self.baseline_contract}
                ),
                plan=self.plan,
                tolerances={},
                cache=object(),
            )

    def test_successful_evaluation_closes_adapter_after_summary(self) -> None:
        callable_value = _LifecycleCallable()
        expected_evaluation = {"evaluation": "accepted"}

        def evaluator(*_args: object, **_kwargs: object) -> object:
            return expected_evaluation

        result = self._evaluate_with_patched_validators(
            self._executor(callable_value, evaluator)
        )
        self.assertEqual(
            result,
            (expected_evaluation, {"summary": "accepted"}, True, ()),
        )
        self.assertEqual(callable_value.close_count, 1)

    def test_evaluator_failure_closes_adapter_and_preserves_primary_error(self) -> None:
        primary = RuntimeError("primary evaluator failure")
        callable_value = _LifecycleCallable(
            close_error=RuntimeError("secondary close failure")
        )

        def evaluator(*_args: object, **_kwargs: object) -> object:
            raise primary

        with self.assertRaises(RuntimeError) as raised:
            self._evaluate_with_patched_validators(
                self._executor(callable_value, evaluator)
            )
        self.assertIs(raised.exception, primary)
        self.assertEqual(callable_value.close_count, 1)

    def test_close_failure_after_success_is_fail_closed(self) -> None:
        callable_value = _LifecycleCallable(
            close_error=RuntimeError("close failure")
        )

        def evaluator(*_args: object, **_kwargs: object) -> object:
            return {"evaluation": "accepted"}

        with self.assertRaisesRegex(
            runner.CalibrationError,
            "adapter close failed",
        ):
            self._evaluate_with_patched_validators(
                self._executor(callable_value, evaluator)
            )
        self.assertEqual(callable_value.close_count, 1)

    def test_close_base_exceptions_after_success_are_preserved_unchanged(self) -> None:
        for close_error in (KeyboardInterrupt("close interrupt"), SystemExit(91)):
            with self.subTest(error_type=type(close_error).__name__):
                callable_value = _LifecycleCallable(close_error=close_error)

                def evaluator(*_args: object, **_kwargs: object) -> object:
                    return {"evaluation": "accepted"}

                with self.assertRaises(type(close_error)) as raised:
                    self._evaluate_with_patched_validators(
                        self._executor(callable_value, evaluator)
                    )
                self.assertIs(raised.exception, close_error)
                self.assertEqual(callable_value.close_count, 1)

    def test_normal_mode_rejects_adapter_without_close_capability(self) -> None:
        callable_value = _LifecycleCallableWithoutClose()

        def evaluator(*_args: object, **_kwargs: object) -> object:
            return {"evaluation": "accepted"}

        with self.assertRaisesRegex(
            runner.CalibrationError,
            "no close capability",
        ):
            self._evaluate_with_patched_validators(
                self._executor(
                    callable_value,
                    evaluator,
                    analytic_test_mode=False,
                )
            )


class MandatoryControlBankCompatibilityTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.plan = json.loads(
            (CALIBRATION_ROOT / "contracts/calibration-plan-v1.json").read_text(
                encoding="utf-8"
            )
        )
        cls.baseline_contract = json.loads(
            (CALIBRATION_ROOT / "contracts/baseline-ablation-contract-v1.json").read_text(
                encoding="utf-8"
            )
        )

    def _vector(self, detail_gain_q12: int) -> dict[str, object]:
        vector = dict(self.plan["search"]["initial_vector_values"])
        vector["detail_gain_q12"] = detail_gain_q12
        return vector

    def test_zero_remains_candidate_valid_and_reports_incompatible_descriptors(
        self,
    ) -> None:
        vector = self._vector(0)
        runner.validate_candidate_vector(vector, self.plan)

        with self.assertRaises(
            runner.CandidateEvaluationPreconditionError
        ) as raised:
            runner._validate_mandatory_control_bank_compatibility(
                vector,
                self.baseline_contract,
            )

        self.assertEqual(raised.exception.control_id, "fixed-descriptor-uniform-v1")
        self.assertEqual(raised.exception.parameter, "detail_gain_q12")
        self.assertEqual(raised.exception.value, 0)
        self.assertEqual(
            raised.exception.incompatible_descriptor_ids,
            (4, 5, 6, 7, 12, 13, 14, 15),
        )
        self.assertEqual(
            str(raised.exception),
            "mandatory control bank compatibility failed: "
            "control_id=fixed-descriptor-uniform-v1; detail_gain_q12=0; "
            "incompatible_descriptor_ids=[4, 5, 6, 7, 12, 13, 14, 15]",
        )

    def test_positive_detail_gain_values_pass_control_bank_precondition(self) -> None:
        for detail_gain_q12 in (384, 768, 1152, 1536):
            with self.subTest(detail_gain_q12=detail_gain_q12):
                vector = self._vector(detail_gain_q12)
                runner.validate_candidate_vector(vector, self.plan)
                runner._validate_mandatory_control_bank_compatibility(
                    vector,
                    self.baseline_contract,
                )

    def test_rejection_precedes_split_metadata_pixels_and_native_adapter(self) -> None:
        vector = self._vector(0)
        executor = object.__new__(runner.CalibrationExecutor)
        executor._development_control_selections = {}
        executor._validation_control_selections = {}
        executor._validation_candidate_evidence_path = None
        executor._validation_candidate_evidence_file_binding = None
        executor._validation_candidate_evidence_binding = None
        executor._loaded_split_frames = {}
        executor.analytic_test_mode = True
        split_frames = mock.Mock(name="split_frames")
        adapter_factory = mock.Mock(name="adapter_factory")
        evaluator = mock.Mock(name="evaluator")
        executor._split_frames = split_frames
        executor.candidate = SimpleNamespace(
            adapter_factory=adapter_factory,
            evaluator=evaluator,
        )
        bound = _BoundWithoutPixels(
            {"baseline_ablation_contract": self.baseline_contract}
        )

        with (
            mock.patch.object(runner, "load_split_metadata") as load_metadata,
            mock.patch.object(runner, "_evaluation_view") as evaluation_view,
            mock.patch.object(
                runner,
                "candidate_vector_sha256",
                wraps=runner.candidate_vector_sha256,
            ) as vector_hash,
            mock.patch.object(
                runner,
                "shared_bank_configuration_sha256",
                wraps=runner.shared_bank_configuration_sha256,
            ) as bank_hash,
        ):
            with self.assertRaises(runner.CandidateEvaluationPreconditionError):
                executor._evaluate(
                    vector,
                    "development",
                    bound=bound,
                    plan=self.plan,
                    tolerances={},
                    cache=object(),
                )

        self.assertEqual(bound.verification_count, 1)
        vector_hash.assert_called_once_with(vector, self.plan)
        bank_hash.assert_called_once_with(vector, self.plan)
        load_metadata.assert_not_called()
        split_frames.assert_not_called()
        evaluation_view.assert_not_called()
        adapter_factory.assert_not_called()
        evaluator.assert_not_called()


class ValidationStageContextTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.plan = json.loads(
            (CALIBRATION_ROOT / "contracts/calibration-plan-v1.json").read_text(
                encoding="utf-8"
            )
        )
        cls.vector = dict(cls.plan["search"]["initial_vector_values"])
        cls.vector_sha256 = runner.candidate_vector_sha256(
            cls.vector,
            cls.plan,
        )
        cls.bank_sha256 = runner.shared_bank_configuration_sha256(
            cls.vector,
            cls.plan,
        )

    def _executor(self) -> runner.CalibrationExecutor:
        executor = object.__new__(runner.CalibrationExecutor)
        executor._development_control_selections = {}
        executor._validation_control_selections = {}
        executor._validation_candidate_evidence_path = None
        executor._validation_candidate_evidence_file_binding = None
        executor._validation_candidate_evidence_binding = None
        executor._loaded_split_frames = {}
        executor.candidate = None
        executor.analytic_test_mode = True
        return executor

    def _development_selection(self) -> runner.ControlSelectionBundle:
        return runner.ControlSelectionBundle(
            selection_stage="development_provisional",
            shared_bank_configuration_sha256=self.bank_sha256,
            artifacts={},
            bundle_sha256="a" * 64,
        )

    def _write_candidate_evidence(
        self,
        root: Path,
    ) -> tuple[Path, dict[str, object], runner.ValidationCandidateEvidenceBinding]:
        document: dict[str, object] = {
            "schema_version": "1.0.0",
            "artifact_kind": "p06_validation_candidate_development_evidence",
            "development_terminal_vector_sha256": self.vector_sha256,
            "neighbor_evidence": [
                {
                    "candidate_vector_sha256": self.vector_sha256,
                    "development_feasible": True,
                    "development_summary_sha256": "b" * 64,
                    "development_evaluation": {
                        "path": f"evaluations/{'c' * 64}.json",
                        "sha256": "d" * 64,
                        "size_bytes": 1,
                    },
                }
            ],
            "validation_candidate_vector_sha256_values": [self.vector_sha256],
            "validation_accessed_while_building": False,
        }
        document["manifest_sha256"] = manifest_sha256(document)
        path = root / "validation-candidate-evidence.json"
        write_json(path, document)
        file_binding: dict[str, object] = {
            "path": path.name,
            "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
            "size_bytes": path.stat().st_size,
        }
        verified = runner._verify_validation_candidate_evidence_file(
            path,
            expected_file_binding=file_binding,
        )
        return path, file_binding, verified

    def _assert_validation_rejected_before_pixel_loader(
        self,
        executor: runner.CalibrationExecutor,
        expected_error: type[BaseException],
    ) -> None:
        payload_reads = 0

        def pixel_loader(*_args: object, **_kwargs: object) -> object:
            nonlocal payload_reads
            payload_reads += 1
            raise AssertionError("validation pixel loader must not run")

        executor._split_frames = pixel_loader
        with self.assertRaises(expected_error):
            executor._evaluate(
                self.vector,
                "validation",
                bound=_BoundWithoutPixels(),
                plan=self.plan,
                tolerances={},
                cache=object(),
            )
        self.assertEqual(payload_reads, 0)

    def test_missing_development_selection_prevents_validation_pixel_read(self) -> None:
        self._assert_validation_rejected_before_pixel_loader(
            self._executor(),
            runner.CalibrationError,
        )

    def test_missing_frozen_candidate_binding_prevents_validation_pixel_read(self) -> None:
        executor = self._executor()
        executor._development_control_selections[self.bank_sha256] = (
            self._development_selection()
        )
        self._assert_validation_rejected_before_pixel_loader(
            executor,
            runner.CalibrationError,
        )

    def test_changed_frozen_candidate_file_prevents_validation_pixel_read(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mirmir-stage-context-") as value:
            path, file_binding, verified = self._write_candidate_evidence(
                Path(value)
            )
            executor = self._executor()
            executor._development_control_selections[self.bank_sha256] = (
                self._development_selection()
            )
            executor._validation_candidate_evidence_path = path
            executor._validation_candidate_evidence_file_binding = file_binding
            executor._validation_candidate_evidence_binding = verified
            path.write_bytes(path.read_bytes() + b" ")
            self._assert_validation_rejected_before_pixel_loader(
                executor,
                runner.CalibrationBindingError,
            )

    def test_validation_bundle_carries_verified_self_and_file_binding(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mirmir-stage-context-") as value:
            _, _, verified = self._write_candidate_evidence(Path(value))
            development = self._development_selection()
            self.assertIsNone(
                development.full_ash_development_candidates_frozen_sha256
            )
            validation = runner._bind_validation_candidate_evidence(
                development,
                verified,
            )
            self.assertEqual(
                validation.full_ash_development_candidates_frozen_sha256,
                verified.manifest_sha256,
            )
            self.assertEqual(
                validation.validation_candidate_evidence.file_sha256,
                verified.file_sha256,
            )
            self.assertNotEqual(validation.bundle_sha256, development.bundle_sha256)

    def test_stage_bundle_rejects_omitted_or_cross_stage_frozen_hash(self) -> None:
        embedded = {
            key: {
                "sha256": hashlib.sha256(key.encode("utf-8")).hexdigest(),
                "document": {
                    "selection_stage": "development_provisional",
                    "shared_bank_configuration_sha256": self.bank_sha256,
                },
            }
            for key in ("best_fixed", "conventional", "non_ash_selector")
        }
        development = {"control_selection_artifacts": embedded}
        bundle = runner._control_selection_bundle(development)
        self.assertIsNone(bundle.validation_candidate_evidence)

        invalid = dict(development)
        invalid["full_ash_development_candidates_frozen_sha256"] = "e" * 64
        with self.assertRaisesRegex(
            runner.CalibrationError,
            "omitted or changed",
        ):
            runner._control_selection_bundle(invalid)


class CandidateSchemaContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.schema = json.loads(
            (
                CALIBRATION_ROOT
                / "schemas/candidate-evaluation-v1.schema.json"
            ).read_text(encoding="utf-8")
        )

    def test_natural_corpus_metric_contract_covers_all_three_channels(self) -> None:
        bundle = self.schema["$defs"]["corpusMetricBundle"]
        expected = {
            "y_psnr_db",
            "cb_psnr_db",
            "cr_psnr_db",
            "y_ssim",
            "cb_ssim",
            "cr_ssim",
            "y_ms_ssim",
            "cb_ms_ssim",
            "cr_ms_ssim",
            "writer_y_psnr_contribution_db",
        }
        self.assertEqual(set(bundle["required"]), expected)
        self.assertEqual(set(bundle["properties"]), expected)

    def test_frozen_candidate_hash_is_validation_only(self) -> None:
        conditional = self.schema["allOf"][0]
        self.assertEqual(
            conditional["then"]["not"]["required"],
            ["full_ash_development_candidates_frozen_sha256"],
        )
        self.assertEqual(
            conditional["else"]["required"],
            ["full_ash_development_candidates_frozen_sha256"],
        )

    def test_writer_evidence_is_required_for_corpus_and_analytic_rows(self) -> None:
        expected_controls = {
            "full_ash",
            "best_fixed",
            "conventional",
            "non_ash_selector",
            "state_only",
            "state_plus_branch",
            "h07_direct_3_over_2",
            "nearest_same_writer",
            "current_production_ash",
        }
        writer = self.schema["$defs"]["controlWriterEvidence"]
        self.assertEqual(set(writer["required"]), expected_controls)
        self.assertEqual(set(writer["properties"]), expected_controls)
        for definition_name in ("assetResult", "analyticFixtureResult"):
            definition = self.schema["$defs"][definition_name]
            self.assertIn(
                "writer_evidence_sha256_values",
                definition["required"],
            )

    def test_checks_and_performance_require_canonical_evidence(self) -> None:
        for definition_name in ("checks", "performance"):
            definition = self.schema["$defs"][definition_name]
            self.assertIn("evidence", definition["required"])
            self.assertIn("evidence_sha256", definition["required"])
        route_quality = self.schema["$defs"]["checksEvidence"]["properties"][
            "analysis_grid"
        ]["properties"]["route_quality"]["properties"]["routes"]["items"]
        for field in (
            "maximum_ringing_increase",
            "maximum_alias_increase",
            "maximum_chroma_displacement_increase_pixels",
        ):
            self.assertIn(field, route_quality["required"])
        checks_evidence = self.schema["$defs"]["checksEvidence"]
        self.assertIn("output_cache", checks_evidence["required"])
        output_cache = self.schema["$defs"]["outputCacheEvidence"]
        self.assertEqual(
            set(output_cache["required"]),
            {
                "preparation_records",
                "preparation_records_sha256",
                "fixed_reconstruction_proof",
                "non_ash_reconstruction_proof",
                "control_reconstruction_proof",
            },
        )

    def test_dispatch_binding_uses_sanitized_artifact_id_not_path(self) -> None:
        binding = self.schema["$defs"]["dispatchMeasurement"]["properties"][
            "measurement_evidence_bindings"
        ]["items"]
        self.assertEqual(
            set(binding["required"]),
            {"artifact_id", "sha256", "size_bytes"},
        )
        self.assertNotIn("path", binding["properties"])

    def test_same_bank_threshold_neighbors_keep_distinct_state_only_identity(
        self,
    ) -> None:
        plan = json.loads(
            (CALIBRATION_ROOT / "contracts/calibration-plan-v1.json").read_text(
                encoding="utf-8"
            )
        )
        first = dict(plan["search"]["initial_vector_values"])
        second = dict(first)
        second["edge_present_low_unorm15"] = 4915
        runner.validate_candidate_vector(first, plan)
        runner.validate_candidate_vector(second, plan)

        first_vector_hash = runner.candidate_vector_sha256(first, plan)
        second_vector_hash = runner.candidate_vector_sha256(second, plan)
        self.assertNotEqual(first_vector_hash, second_vector_hash)
        self.assertEqual(
            runner.shared_bank_configuration_sha256(first, plan),
            runner.shared_bank_configuration_sha256(second, plan),
        )
        self.assertNotEqual(
            runner._state_only_configuration_sha256(first_vector_hash),
            runner._state_only_configuration_sha256(second_vector_hash),
        )


if __name__ == "__main__":
    unittest.main()
