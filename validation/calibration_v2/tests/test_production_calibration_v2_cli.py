from __future__ import annotations

from argparse import Namespace
from pathlib import Path
from types import SimpleNamespace
import tempfile
import unittest
from unittest import mock

from validation.calibration_v2.tools import run_p06_production_calibration as legacy
from validation.calibration_v2.tools import run_p06_production_calibration_v2 as cli


class ProductionCalibrationV2CLICompositionTests(unittest.TestCase):
    def test_concrete_v2_composition_reaches_only_native_source(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            paths = {}
            for name in (
                "repository", "open", "calibration", "release", "evidence",
                "native", "writer", "dispatch", "resources", "g04", "g05",
                "g05-package", "g06",
            ):
                path = root / name
                path.mkdir()
                paths[name] = path
            run_id = "p06-v2-test"
            (paths["calibration"] / run_id).mkdir()
            receipt = root / "resource-receipt.json"
            arguments = Namespace(
                run_id=run_id,
                repository_root=paths["repository"],
                open_split_root=paths["open"],
                calibration_output_root=paths["calibration"],
                release_root=paths["release"],
                evidence_root=paths["evidence"],
                native_cache_root=paths["native"],
                writer_root=paths["writer"],
                dispatch_measurement_root=paths["dispatch"],
                p08_resource_root=paths["resources"],
                p08_resource_receipt=receipt,
                g04_root=paths["g04"],
                g05_root=paths["g05"],
                g05_instruction_package_root=paths["g05-package"],
                g05_baseline_commit="1" * 40,
                g06_root=paths["g06"],
                g06_execution_run_name="execution",
                locked_utc="2026-07-16T12:00:00Z",
                timeout_seconds=1.0,
            )
            native_bound = SimpleNamespace()
            evaluation_bound = SimpleNamespace(
                documents={"metric_performance_tolerances": {}}
            )
            factory = SimpleNamespace()
            assembly = SimpleNamespace(adapter_factory=factory)
            persistence = SimpleNamespace(
                plan="plan-v2",
                calibration=SimpleNamespace(non_ash_profile="profile-v2"),
            )
            source = object()
            provider = SimpleNamespace(
                control_producer_capabilities=mock.Mock()
            )
            coordinator = mock.Mock()
            coordinator.run.return_value = "run-result"
            gates = ("G04", "G05", "G06")
            with mock.patch.object(cli, "_arguments", return_value=arguments), \
                    mock.patch.object(
                        cli,
                        "_live_holdout_preopen_binding",
                        return_value="live-binding",
                    ), mock.patch.object(
                        cli,
                        "reopen_and_stage_current_source_gates_v2",
                        return_value=gates,
                    ), mock.patch.object(
                        cli,
                        "current_source_git_identity_v2",
                        return_value=("a" * 40, b""),
                    ), mock.patch.object(
                        cli,
                        "bind_preregistered_inputs_v2",
                        return_value=(native_bound, evaluation_bound),
                    ), mock.patch.object(
                        cli,
                        "make_production_calibration_assembly_from_bound_inputs",
                        return_value=assembly,
                    ), mock.patch.object(
                        cli,
                        "CalibrationSelectionPersistenceAdapterV2",
                        return_value=persistence,
                    ), mock.patch.object(
                        cli,
                        "production_apple_native_candidate_measurement_source_v2",
                        return_value=source,
                    ) as native_source, mock.patch.object(
                        cli,
                        "production_candidate_evaluation_provider_v2",
                        return_value=provider,
                    ) as provider_factory, mock.patch.object(
                        cli,
                        "P06ProductionCoordinatorV2",
                        return_value=coordinator,
                    ), mock.patch.object(
                        cli,
                        "build_p06_release_transaction_v3",
                        return_value={
                            "configuration_id": "ash-p06-v2-test",
                            "artifact_sha256": "b" * 64,
                        },
                    ) as release, mock.patch.object(
                        cli,
                        "export_p08_release_resources_v3",
                        return_value={"resource_set_sha256": "c" * 64},
                    ) as export, mock.patch("builtins.print"):
                status = cli.main()

            self.assertEqual(status, 0)
            native_source.assert_called_once_with(
                assembly=assembly,
                open_split_root=paths["open"],
                artifact_root=paths["calibration"] / run_id,
                evaluation_bound_inputs=evaluation_bound,
                plan="plan-v2",
                non_ash_profile="profile-v2",
            )
            provider_factory.assert_called_once()
            self.assertIs(
                provider_factory.call_args.kwargs["measurement_source"],
                source,
            )
            release.assert_called_once()
            export.assert_called_once_with(
                release_root=paths["release"],
                resource_root=paths["resources"],
                receipt_path=receipt,
                support_evidence_roots={
                    "open_split": paths["open"],
                    "calibration_evidence": paths["evidence"].parent,
                    "native_cache": paths["native"].parent,
                    "production_writer": paths["writer"].parent,
                    "dispatch_measurement": paths["dispatch"].parent,
                    "calibration_run": paths["calibration"],
                },
            )
            self.assertNotIn("measurement_source", vars(arguments))
            self.assertNotIn("analytic_test_mode", vars(arguments))

    def test_legacy_entry_point_is_non_authorizing(self) -> None:
        with mock.patch.object(legacy, "_arguments", return_value=Namespace()), \
                mock.patch.object(
                    legacy,
                    "_live_holdout_preopen_binding",
                    return_value=object(),
                ), mock.patch("sys.stderr"):
            status = legacy.main()
        self.assertEqual(status, 2)
        self.assertFalse(hasattr(legacy, "make_production_calibration_assembly"))
        self.assertFalse(hasattr(legacy, "CalibrationExecutor"))


if __name__ == "__main__":
    unittest.main()
