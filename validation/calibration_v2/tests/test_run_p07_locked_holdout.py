from __future__ import annotations

import argparse
from contextlib import redirect_stdout
import hashlib
import io
import json
from pathlib import Path
from types import SimpleNamespace
import tempfile
import unittest
from unittest import mock

from validation.calibration_v2.p07.execution import (
    P07ExecutionError,
    SUPPORT_ROOT_IDS,
    _validate_failure_publication,
)
from validation.calibration_v2.tools import run_p07_locked_holdout as runner
from validation.quality.src.mirmir_quality.json_tools import manifest_sha256


def _digest(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


class P07LockedHoldoutCLITests(unittest.TestCase):
    def _fixture(self, root: Path) -> argparse.Namespace:
        repository = root / "repository"
        holdout = root / "holdout"
        release = root / "release"
        p04 = root / "p04"
        cache = root / "cache"
        anchor_root = root / "anchor-root"
        output_parent = root / "output"
        for directory in (
            repository,
            holdout,
            release,
            p04,
            cache,
            anchor_root,
            output_parent,
            holdout / "mount-v2",
        ):
            directory.mkdir(exist_ok=True)
        support_roots = {}
        for identifier in SUPPORT_ROOT_IDS:
            path = root / "support" / identifier
            path.mkdir(parents=True)
            support_roots[identifier] = path

        sampling = repository / "sampling-plan.json"
        no_pixel = repository / "no-pixel.json"
        ledger = holdout / "ledger.json"
        receipt = holdout / "receipt.json"
        sealed_copy = holdout / "sealed-copy.json"
        repository_attestation = holdout / "repository-attestation.json"
        for path, payload in (
            (sampling, b"sampling\n"),
            (no_pixel, b"no-pixel\n"),
            (ledger, b"{}\n"),
            (receipt, b"{}\n"),
            (sealed_copy, b"{}\n"),
            (repository_attestation, b"{}\n"),
        ):
            path.write_bytes(payload)

        release_manifest = {"artifact_kind": "synthetic-release"}
        release_manifest["manifest_sha256"] = manifest_sha256(
            release_manifest
        )
        release_manifest_path = release / "release-bundle-manifest.json"
        release_manifest_path.write_text(
            json.dumps(release_manifest, sort_keys=True, separators=(",", ":"))
            + "\n",
            encoding="utf-8",
        )
        (release / "configuration-lock.json").write_text(
            '{"synthetic_configuration":"locked"}\n',
            encoding="utf-8",
        )
        calibration_plan = (
            repository
            / "validation/calibration_v2/contracts/calibration-plan-v1.json"
        )
        calibration_plan.parent.mkdir(parents=True)
        calibration_plan.write_text(
            json.dumps(
                {
                    "input_bindings": [
                        {
                            "id": identifier,
                            "path": "synthetic/{}.json".format(identifier),
                        }
                        for identifier in (
                            "degradation_policy",
                            "quality_harness_implementation_manifest",
                            "corpus_lock",
                        )
                    ]
                },
                sort_keys=True,
                separators=(",", ":"),
            )
            + "\n",
            encoding="utf-8",
        )
        loader_payload = b"synthetic-loader"
        return argparse.Namespace(
            repository_root=repository,
            holdout_root=holdout,
            sampling_plan_path=sampling,
            expected_sampling_plan_file_sha256=hashlib.sha256(
                sampling.read_bytes()
            ).hexdigest(),
            no_pixel_attestation_path=no_pixel,
            expected_no_pixel_attestation_file_sha256=hashlib.sha256(
                no_pixel.read_bytes()
            ).hexdigest(),
            expected_loader_executable_sha256=hashlib.sha256(
                loader_payload
            ).hexdigest(),
            p06_release_root=release,
            p06_release_manifest_path=release_manifest_path,
            expected_p06_release_manifest_sha256=release_manifest[
                "manifest_sha256"
            ],
            support_root=[
                "{}={}".format(identifier, support_roots[identifier])
                for identifier in sorted(support_roots)
            ],
            p07_cache_root=cache,
            output_directory=output_parent / "p07-result",
            p04_quality_root=p04,
            expected_corpus_manifest_sha256=_digest("corpus"),
            live_ledger_path=ledger,
            live_anchor_path=anchor_root / "anchor.json",
            live_preopen_receipt_path=receipt,
            expected_live_ledger_root_identity_sha256=_digest("ledger-root"),
            expected_live_anchor_root_identity_sha256=_digest("anchor-root"),
            expected_live_preopen_receipt_file_sha256=_digest("receipt"),
            repository_sealed_copy_path=sealed_copy,
            expected_repository_sealed_copy_sha256=_digest("sealed-copy"),
            repository_attestation_path=repository_attestation,
            expected_repository_attestation_sha256=_digest(
                "repository-attestation"
            ),
            timeout_seconds=1.0,
            preopen_verify_only=False,
            synthetic_loader_payload=loader_payload,
        )

    def test_main_recovers_before_fresh_cache_and_unopened_binding(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            arguments = self._fixture(root)
            (arguments.p07_cache_root / "persisted-preopen-cache").write_text(
                "persisted\n",
                encoding="utf-8",
            )
            direct_records = [
                {"id": identifier, "path": "synthetic/{}.json".format(identifier)}
                for identifier in (
                    "degradation_policy",
                    "quality_harness_implementation_manifest",
                    "corpus_lock",
                )
            ]
            intent = {"direct_input_bindings": direct_records}
            expected_result = {"status": "complete", "recovered": True}
            with mock.patch.object(
                runner,
                "_arguments",
                return_value=arguments,
            ), mock.patch.object(
                runner,
                "_recovery_mode",
                return_value=("terminal_or_consumed", intent),
            ), mock.patch.object(
                runner.P07HoldoutExecutor,
                "execute_once",
                return_value=expected_result,
            ) as execute_once, mock.patch.object(
                runner,
                "_validate_cache_before_write",
                side_effect=AssertionError("fresh-cache guard was reached"),
            ), mock.patch.object(
                runner,
                "bind_preregistered_inputs",
                side_effect=AssertionError("unopened binder was reached"),
            ), mock.patch.object(
                runner,
                "_loader_verification",
                side_effect=AssertionError("loader rebuild was reached"),
            ), mock.patch.object(
                runner,
                "make_native_candidate_adapter_factory",
                side_effect=AssertionError("native factory was reached"),
            ), mock.patch.object(
                runner.P07ProductionEvaluator,
                "prepare",
                side_effect=AssertionError("evaluator prepare was reached"),
            ):
                output = io.StringIO()
                with redirect_stdout(output):
                    self.assertEqual(runner.main(), 0)
            self.assertEqual(json.loads(output.getvalue()), expected_result)
            self.assertEqual(execute_once.call_count, 1)
            call = execute_once.call_args.kwargs
            self.assertEqual(
                call["output_directory"],
                arguments.output_directory,
            )
            self.assertEqual(
                call["guard"].ledger_path,
                arguments.live_ledger_path,
            )

    def test_main_preflight_failures_publish_proven_nonconsumption(self) -> None:
        for stage in ("cache", "hash", "binding", "loader", "evaluator"):
            with self.subTest(stage=stage), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary).resolve()
                arguments = self._fixture(root)
                patches = [
                    mock.patch.object(
                        runner,
                        "_arguments",
                        return_value=arguments,
                    )
                ]
                if stage == "cache":
                    (arguments.p07_cache_root / "unexpected-entry").write_text(
                        "occupied\n",
                        encoding="utf-8",
                    )
                elif stage == "hash":
                    arguments.expected_sampling_plan_file_sha256 = _digest(
                        "another-sampling-plan"
                    )
                else:
                    bound = SimpleNamespace(
                        documents={
                            "corpus_lock": {
                                "manifest_sha256": (
                                    arguments.expected_corpus_manifest_sha256
                                )
                            }
                        },
                        verify_unchanged=mock.Mock(),
                    )
                    if stage == "binding":
                        patches.append(
                            mock.patch.object(
                                runner,
                                "bind_preregistered_inputs",
                                side_effect=ValueError(
                                    "injected binding failure"
                                ),
                            )
                        )
                    else:
                        patches.append(
                            mock.patch.object(
                                runner,
                                "bind_preregistered_inputs",
                                return_value=bound,
                            )
                        )
                        if stage == "loader":
                            patches.append(
                                mock.patch.object(
                                    runner,
                                    "_loader_verification",
                                    side_effect=ValueError(
                                        "injected loader failure"
                                    ),
                                )
                            )
                        else:
                            loader = (
                                arguments.p07_cache_root
                                / "p07-holdout-frame-loader-a"
                            )

                            def verified_loader(**unused: object) -> tuple[Path, dict[str, object]]:
                                del unused
                                loader.write_bytes(
                                    arguments.synthetic_loader_payload
                                )
                                return loader, {}

                            patches.extend(
                                [
                                    mock.patch.object(
                                        runner,
                                        "_loader_verification",
                                        side_effect=verified_loader,
                                    ),
                                    mock.patch.object(
                                        runner.P07HoldoutExecutor,
                                        "preflight",
                                        return_value=SimpleNamespace(
                                            release_bundle={
                                                "manifest_sha256": (
                                                    arguments.expected_p06_release_manifest_sha256
                                                )
                                            }
                                        ),
                                    ),
                                    mock.patch.object(
                                        runner,
                                        "make_native_candidate_adapter_factory",
                                        return_value=SimpleNamespace(
                                            repository_root=(
                                                arguments.repository_root
                                            )
                                        ),
                                    ),
                                    mock.patch.object(
                                        runner.P07ProductionEvaluator,
                                        "prepare",
                                        side_effect=ValueError(
                                            "injected evaluator failure"
                                        ),
                                    ),
                                ]
                            )
                entered = []
                try:
                    for patcher in patches:
                        entered.append(patcher.start())
                    with self.assertRaises(Exception):
                        runner.main()
                    if stage == "evaluator":
                        prepare = entered[-1]
                        identity = arguments.p07_cache_root.stat()
                        self.assertEqual(
                            prepare.call_args.kwargs[
                                "expected_cache_root_identity"
                            ],
                            (identity.st_dev, identity.st_ino),
                        )
                        protected = set(
                            prepare.call_args.kwargs["protected_roots"]
                        )
                        self.assertIn(
                            arguments.output_directory.parent,
                            protected,
                        )
                        self.assertIn(arguments.holdout_root, protected)
                        self.assertIn(arguments.repository_root, protected)
                        self.assertNotIn(arguments.p07_cache_root, protected)
                finally:
                    for patcher in reversed(patches):
                        patcher.stop()
                del entered
                _validate_failure_publication(arguments.output_directory)
                archive = json.loads(
                    (
                        arguments.output_directory
                        / "failed-version-archive.json"
                    ).read_text(encoding="utf-8")
                )
                artifact = json.loads(
                    (
                        arguments.output_directory / "artifact-manifest.json"
                    ).read_text(encoding="utf-8")
                )
                self.assertEqual(
                    archive["failure_stage"],
                    "pre_guard_validation",
                )
                self.assertFalse(archive["holdout_access_consumed"])
                self.assertEqual(archive["holdout_access_state"], "sealed")
                self.assertIsNone(archive["direct_input_bindings"])
                self.assertFalse(artifact["holdout_accessed"])
                self.assertFalse(artifact["holdout_access_consumed"])

    def test_main_reopens_actual_pre_guard_archive_before_preflight(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            arguments = self._fixture(root)
            (arguments.p07_cache_root / "unexpected-entry").write_text(
                "occupied\n",
                encoding="utf-8",
            )
            with mock.patch.object(
                runner,
                "_arguments",
                return_value=arguments,
            ):
                with self.assertRaisesRegex(ValueError, "fresh and empty"):
                    runner.main()
            _validate_failure_publication(arguments.output_directory)

            with mock.patch.object(
                runner,
                "_arguments",
                return_value=arguments,
            ), mock.patch.object(
                runner,
                "_validate_cache_before_write",
                side_effect=AssertionError("fresh-cache guard was reached"),
            ) as fresh_guard, mock.patch.object(
                runner,
                "bind_preregistered_inputs",
                side_effect=AssertionError("unopened binder was reached"),
            ) as binder, mock.patch.object(
                runner,
                "_loader_verification",
                side_effect=AssertionError("loader rebuild was reached"),
            ) as loader, mock.patch.object(
                runner,
                "make_native_candidate_adapter_factory",
                side_effect=AssertionError("native factory was reached"),
            ) as native_factory, mock.patch.object(
                runner.P07ProductionEvaluator,
                "prepare",
                side_effect=AssertionError("evaluator prepare was reached"),
            ) as prepare:
                with self.assertRaisesRegex(
                    P07ExecutionError,
                    "validated terminal failure",
                ):
                    runner.main()
            self.assertEqual(fresh_guard.call_count, 0)
            self.assertEqual(binder.call_count, 0)
            self.assertEqual(loader.call_count, 0)
            self.assertEqual(native_factory.call_count, 0)
            self.assertEqual(prepare.call_count, 0)


if __name__ == "__main__":
    unittest.main()
