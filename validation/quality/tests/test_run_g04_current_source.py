from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest import mock

from validation.calibration_v2.tools.finalize_evidence_wrapper import RepositoryState
from validation.quality.tools import finalize_g04_current_source as finalizer
from validation.quality.tools import run_g04_current_source as runner


SOURCE_COMMIT = "1" * 40
BASELINE_COMMIT = "2" * 40
INTERNAL_MANIFEST_SHA256 = "a" * 64


class FakeG04Executor:
    def __init__(
        self,
        *,
        repository: Path,
        instruction_root: Path,
        installed_quality_payload: bytes,
        metric_document: dict[str, object],
        omit_output: str | None = None,
    ) -> None:
        self.repository = repository
        self.instruction_root = instruction_root
        self.installed_quality_payload = installed_quality_payload
        self.metric_document = metric_document
        self.omit_output = omit_output
        self.identifiers: list[str] = []

    @staticmethod
    def _argument(spec: runner.CommandSpec, name: str) -> Path:
        index = spec.argv.index(name)
        return Path(spec.argv[index + 1])

    @staticmethod
    def _write_json(path: Path, document: object) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(
            (
                json.dumps(
                    document,
                    ensure_ascii=False,
                    allow_nan=False,
                    sort_keys=True,
                    separators=(",", ":"),
                )
                + "\n"
            ).encode("utf-8")
        )

    @staticmethod
    def _result(
        stdout: bytes = b"",
        *,
        stderr: bytes = b"",
        returncode: int = 0,
    ) -> runner.CommandResult:
        return runner.CommandResult(
            returncode=returncode,
            stdout=stdout,
            stderr=stderr,
        )

    @staticmethod
    def _bundle(path: Path) -> None:
        (path / "Data").mkdir(parents=True)
        (path / "Info.plist").write_bytes(b"fixture-xcresult\n")

    @staticmethod
    def xcode_summary() -> dict[str, object]:
        return {
            "expectedFailures": 0,
            "failedTests": 0,
            "passedTests": 4,
            "result": "Passed",
            "skippedTests": 0,
            "totalTestCount": 4,
        }

    @staticmethod
    def release_summary() -> dict[str, object]:
        return {
            "status": "succeeded",
            "warningCount": 0,
            "errorCount": 0,
            "analyzerWarningCount": 0,
            "warnings": [],
            "errors": [],
            "analyzerWarnings": [],
            "destination": {"architecture": "arm64", "platform": "macOS"},
        }

    def __call__(self, spec: runner.CommandSpec) -> runner.CommandResult:
        self.identifiers.append(spec.identifier)
        identifier = spec.identifier
        if identifier == "xcode-full":
            self._bundle(self._argument(spec, "-resultBundlePath"))
            return self._result(b"** TEST SUCCEEDED **\n")
        if identifier == "xcresult-test-summary":
            return self._result(json.dumps(self.xcode_summary()).encode("utf-8"))
        if identifier == "xcresult-test-list":
            return self._result(b'{"testNodes":[]}')
        if identifier == "xcode-coverage":
            return self._result(b'{"targets":[{"name":"Mirmir"}]}')
        if identifier == "xcode-release":
            self._bundle(self._argument(spec, "-resultBundlePath"))
            derived = self._argument(spec, "-derivedDataPath")
            binary = derived / "Build/Products/Release/Mirmir.app/Contents/MacOS/Mirmir"
            binary.parent.mkdir(parents=True)
            binary.write_bytes(b"fixture-arm64-release-binary\n")
            return self._result(b"** BUILD SUCCEEDED **\n")
        if identifier == "xcresult-release-summary":
            return self._result(json.dumps(self.release_summary()).encode("utf-8"))
        if identifier == "release-file":
            return self._result(
                f"{spec.argv[-1]}: Mach-O 64-bit executable arm64\n".encode()
            )
        if identifier == "release-lipo":
            return self._result(
                f"Non-fat file: {spec.argv[-1]} is architecture: arm64\n".encode()
            )
        if identifier == "release-codesign-verify":
            return self._result(f"{spec.argv[-1]}: valid on disk\n".encode())
        if identifier == "release-codesign-display":
            return self._result(
                b"Format=app bundle with Mach-O thin (arm64)\n"
                b"CodeDirectory flags=0x10002(adhoc,runtime)\n"
            )
        if identifier == "python-quality-tests":
            return self._result(b"Ran 4 tests in 0.001s\n\nOK\n")
        if identifier == "python-static-validation":
            return self._result()
        if identifier in {"quality-lock-a", "quality-lock-b"}:
            if identifier != self.omit_output:
                output = self._argument(spec, "--output")
                output.write_bytes(self.installed_quality_payload)
            return self._result((INTERNAL_MANIFEST_SHA256 + "\n").encode())
        if identifier == "production-failure-injection":
            output_root = self._argument(spec, "--output-root")
            run_id = spec.argv[spec.argv.index("--run-id") + 1]
            failed = output_root / f"{run_id}.failed-1"
            self._write_json(
                failed / "failure.json",
                {
                    "schema_version": "1.0.0",
                    "run_id": run_id,
                    "failure_type": "RuntimeError",
                    "message": "injected production development dry-run interruption",
                    "partial_preserved": True,
                    "holdout_accessed": False,
                },
            )
            return self._result(
                f"failed_run={failed}\n".encode(),
                returncode=1,
            )
        if identifier == "production-resume":
            output_root = self._argument(spec, "--output-root")
            run_id = spec.argv[spec.argv.index("--run-id") + 1]
            completed = output_root / run_id
            self._write_json(
                completed / "benchmark-dry-run.json",
                {
                    "schema_version": "1.0.0",
                    "status": "pass",
                    "gate_status": "pass",
                    "case_count": 2,
                    "completed_case_count": 2,
                    "artifact_semantic_reverification": True,
                    "resumed_from_failure": True,
                    "resume_checkpoint_semantics": "recomputed",
                    "holdout_accessed": False,
                    "common_writer_runs": [{"id": 1}, {"id": 2}],
                },
            )
            self._write_json(
                completed / "input-bindings.json",
                {
                    "schema_version": "1.0.0",
                    "all_split_evidence_rehashed": True,
                    "holdout_accessed": False,
                    "holdout_media_rehashed": False,
                },
            )
            artifacts = []
            for path in sorted(completed.iterdir()):
                payload = path.read_bytes()
                artifacts.append(
                    {
                        "path": path.name,
                        "sha256": hashlib.sha256(payload).hexdigest(),
                        "size_bytes": len(payload),
                    }
                )
            manifest = {
                "schema_version": "1.0.0",
                "run_id": run_id,
                "artifacts": artifacts,
            }
            manifest["manifest_sha256"] = runner.manifest_sha256(manifest)
            self._write_json(completed / "artifact-manifest.json", manifest)
            return self._result(f"final_run={completed}\n".encode())
        if identifier == "actual-codec":
            output = self._argument(spec, "--output-directory")
            fixture = output / "actual-h264-software-nv12-v1.mp4"
            fixture.parent.mkdir(parents=True, exist_ok=True)
            fixture.write_bytes(b"fixture-generated-codec-bytes\n")
            fixture_payload = fixture.read_bytes()
            self._write_json(
                output / "actual-codec-fixture-lock.json",
                {
                    "schema_version": "1.0.0",
                    "status": "pass",
                    "fixture": {
                        "path": fixture.name,
                        "sha256": hashlib.sha256(fixture_payload).hexdigest(),
                        "size_bytes": len(fixture_payload),
                    },
                },
            )
            return self._result()
        if identifier == "metric-oracle-check":
            return self._result(
                b"locked metric vectors match the independent oracle\n"
            )
        if identifier == "metric-oracle-output":
            return self._result(json.dumps(self.metric_document).encode("utf-8"))
        if identifier == "swiftlint-strict":
            return self._result(
                b"Done linting! Found 0 violations, 0 serious in 12 files.\n"
            )
        if identifier == "instruction-package-validation":
            return self._result(
                runner.g05._instruction_validation_output(self.instruction_root)
            )
        if identifier == "git-diff-check":
            return self._result()
        if identifier == "attribution-scan":
            return self._result(
                json.dumps(
                    {
                        "status": "pass",
                        "base": BASELINE_COMMIT,
                        "changed_file_count": 3,
                        "findings": [],
                    }
                ).encode("utf-8")
            )
        raise AssertionError(f"unexpected command: {identifier}: {spec.argv}")


class G04CurrentSourceRunnerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="mirmir-g04-runner-tests-")
        self.root = Path(self.temporary.name).resolve(strict=True)
        self.repository = self.root / "repository"
        (self.repository / "Artifacts/ASH").mkdir(parents=True)
        self.instruction_root = self.root / "instruction-package"
        (self.instruction_root / "tools").mkdir(parents=True)
        (self.instruction_root / "tools/validate_instruction_package.py").write_text(
            "raise SystemExit(0)\n",
            encoding="utf-8",
        )
        (self.instruction_root / "tools/scan_project_attribution.py").write_text(
            "raise SystemExit(0)\n",
            encoding="utf-8",
        )
        (self.instruction_root / "package_manifest.json").write_text(
            "{}\n",
            encoding="utf-8",
        )
        (self.instruction_root / "SHA256SUMS.txt").write_text(
            f"{'0' * 64}  package_manifest.json\n",
            encoding="utf-8",
        )
        (self.instruction_root / "config").mkdir()
        (self.instruction_root / "config/attribution_policy.json").write_text(
            '{"scan_patterns":["forbidden-fixture-token"]}\n',
            encoding="utf-8",
        )
        self.development_root = self.root / "development-open-split"
        self.development_root.mkdir()
        quality = {"manifest_sha256": INTERNAL_MANIFEST_SHA256}
        self.installed_quality_payload = (
            json.dumps(quality, sort_keys=True, separators=(",", ":")) + "\n"
        ).encode("utf-8")
        quality_path = self.repository / runner.QUALITY_MANIFEST_RELATIVE
        quality_path.parent.mkdir(parents=True)
        quality_path.write_bytes(self.installed_quality_payload)
        implementation = self.repository / runner.PRODUCTION_IMPLEMENTATION_RELATIVE
        implementation.parent.mkdir(parents=True)
        implementation.write_text("FIXTURE_IMPLEMENTATION = True\n", encoding="utf-8")
        self.metric_document = {
            "schema_version": "1.0.0",
            "oracle": "independent fixture",
            "fixture": {
                "id": "metric-fixture",
                "dimensions": [8, 8],
                "candidate_f64le_sha256": "c" * 64,
                "reference_f64le_sha256": "d" * 64,
            },
            "expected": {
                "ssim": 0.5,
                "ms_ssim": 0.75,
                "scale_ssim_means": [0.5, 0.6, 0.7, 0.8, 0.9],
                "scale_contrast_structure_means": [
                    0.51,
                    0.61,
                    0.71,
                    0.81,
                    0.91,
                ],
            },
        }
        metric_path = self.repository / runner.METRIC_VECTORS_RELATIVE
        metric_path.parent.mkdir(parents=True)
        FakeG04Executor._write_json(metric_path, self.metric_document)
        self.state = RepositoryState(
            project_commit=SOURCE_COMMIT,
            tracked_diff_sha256=hashlib.sha256(b"").hexdigest(),
            untracked_paths_sha256=hashlib.sha256(b"").hexdigest(),
        )

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def _executor(self, omit_output: str | None = None) -> FakeG04Executor:
        return FakeG04Executor(
            repository=self.repository,
            instruction_root=self.instruction_root,
            installed_quality_payload=self.installed_quality_payload,
            metric_document=self.metric_document,
            omit_output=omit_output,
        )

    def _run(
        self,
        executor: FakeG04Executor,
        *,
        publish: object,
        state_provider: object | None = None,
        name: str = "fresh-g04",
    ) -> Path:
        return runner.run_g04_current_source(
            repository_root=self.repository,
            final_root=self.repository / f"Artifacts/ASH/{name}",
            expected_source_commit=SOURCE_COMMIT,
            p00_baseline_commit=BASELINE_COMMIT,
            instruction_package_root=self.instruction_root,
            asset_root=self.development_root,
            evidence_root=self.development_root,
            sample_root=self.development_root,
            python_executable=Path("/usr/bin/python3"),
            swiftlint_executable=Path("/usr/bin/true"),
            scratch_root=self.root / f"{name}-scratch",
            executor=executor,
            state_provider=state_provider or (lambda _: self.state),
            publish=publish,
            baseline_validator=lambda *_: None,
        )

    @staticmethod
    def _extract_fixture_xcresult(
        *,
        bundle: Path,
        kind: str,
        label: str,
    ) -> dict[str, object]:
        del label
        filename = (
            "full-tests-summary.json"
            if kind == "test-summary"
            else "release-build-summary.json"
        )
        return json.loads((bundle.parent / filename).read_bytes())

    def test_executes_exact_producer_closure_and_stages_finalizer_input(self) -> None:
        executor = self._executor()
        captured: dict[str, object] = {}

        def publish(**arguments: object) -> Path:
            partial = Path(arguments["partial_root"])
            final = Path(arguments["final_root"])
            evidence = finalizer.validate_staged_g04(
                repository_root=Path(arguments["repository_root"]),
                partial_root=partial,
                expected_source_commit=str(arguments["expected_source_commit"]),
            )
            captured["evidence"] = evidence
            captured["tests"] = json.loads((partial / "test-results.json").read_bytes())
            captured["assessment"] = json.loads(
                (partial / "analysis/g04-gate-assessment.json").read_bytes()
            )
            os.rename(partial, final)
            return final

        with mock.patch.object(
            runner,
            "validate_schema",
        ), mock.patch.object(
            runner,
            "validate_quality_harness_implementation_manifest",
            return_value=INTERNAL_MANIFEST_SHA256,
        ), mock.patch.object(
            finalizer,
            "_repository_state",
            return_value=self.state,
        ), mock.patch.object(
            finalizer,
            "_validate_quality_manifest",
            return_value=INTERNAL_MANIFEST_SHA256,
        ), mock.patch.object(
            finalizer,
            "validate_schema",
        ), mock.patch.object(
            finalizer,
            "_xcresult_document",
            side_effect=self._extract_fixture_xcresult,
        ):
            published = self._run(executor, publish=publish)

        self.assertEqual(published, self.repository / "Artifacts/ASH/fresh-g04")
        self.assertEqual(
            executor.identifiers,
            [
                "xcode-full",
                "xcresult-test-summary",
                "xcresult-test-list",
                "xcode-coverage",
                "xcode-release",
                "xcresult-release-summary",
                "release-file",
                "release-lipo",
                "release-codesign-verify",
                "release-codesign-display",
                "python-quality-tests",
                "python-static-validation",
                "quality-lock-a",
                "quality-lock-b",
                "production-failure-injection",
                "production-resume",
                "actual-codec",
                "metric-oracle-check",
                "metric-oracle-output",
                "swiftlint-strict",
                "instruction-package-validation",
                "git-diff-check",
                "attribution-scan",
            ],
        )
        evidence = captured["evidence"]
        self.assertGreater(len(evidence.files), 20)
        tests = captured["tests"]
        assessment = captured["assessment"]
        self.assertEqual(tests["source_commit"], SOURCE_COMMIT)
        self.assertEqual(tests["python"]["skips"], 0)
        self.assertEqual(tests["production_dry_run"]["holdout_accessed"], False)
        self.assertEqual(
            tests["quality_harness_manifest"]["deterministic_rebuild_count"],
            2,
        )
        self.assertEqual(assessment["evidence"], sorted(set(assessment["evidence"])))
        self.assertNotIn("_partial_root", json.dumps(tests, sort_keys=True))

    def test_missing_producer_output_fails_before_publication(self) -> None:
        executor = self._executor(omit_output="quality-lock-b")
        published = mock.Mock()
        with mock.patch.object(
            runner,
            "validate_quality_harness_implementation_manifest",
            return_value=INTERNAL_MANIFEST_SHA256,
        ):
            with self.assertRaisesRegex(
                runner.G04ExecutionError,
                "quality-harness rebuild 2 is absent",
            ):
                self._run(
                    executor,
                    publish=published,
                    name="missing-quality-output",
                )
        published.assert_not_called()
        self.assertEqual(executor.identifiers[-1], "quality-lock-b")

    def test_production_manifest_rejects_unbound_output_file(self) -> None:
        production = self.root / "manifest-closure"
        production.mkdir()
        (production / "unbound.json").write_text("{}\n", encoding="utf-8")
        manifest = {
            "schema_version": "1.0.0",
            "run_id": "fixture",
            "artifacts": [],
        }
        manifest["manifest_sha256"] = runner.manifest_sha256(manifest)
        manifest_path = production / "artifact-manifest.json"
        FakeG04Executor._write_json(manifest_path, manifest)
        with self.assertRaisesRegex(
            runner.G04ExecutionError,
            "manifest differs from the exact file closure",
        ):
            runner._validate_production_manifest_closure(
                production_root=production,
                manifest_path=manifest_path,
                manifest=manifest,
            )

    def test_repository_state_change_fails_at_command_boundary(self) -> None:
        executor = self._executor()
        calls = 0
        changed = RepositoryState(
            project_commit=SOURCE_COMMIT,
            tracked_diff_sha256="f" * 64,
            untracked_paths_sha256=self.state.untracked_paths_sha256,
        )

        def state_provider(_: Path) -> RepositoryState:
            nonlocal calls
            calls += 1
            return changed if calls >= 4 else self.state

        with self.assertRaisesRegex(
            runner.G04ExecutionError,
            "repository state changed during xcode-full",
        ):
            self._run(
                executor,
                publish=mock.Mock(),
                state_provider=state_provider,
                name="state-drift",
            )
        self.assertEqual(executor.identifiers, ["xcode-full"])


if __name__ == "__main__":
    unittest.main()
