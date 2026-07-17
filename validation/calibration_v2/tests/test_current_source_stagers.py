from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
from types import SimpleNamespace
import tempfile
import unittest
from unittest import mock

from validation.calibration_v2.tools import run_g05_current_source as g05
from validation.calibration_v2.tools import stage_g05_current_source as stage_g05
from validation.quality.tools import finalize_g04_current_source as g04


SOURCE_COMMIT = "1" * 40
BASELINE_COMMIT = "2" * 40


class CurrentSourceStagerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(
            prefix="mirmir-current-source-stager-tests-"
        )
        self.root = Path(self.temporary.name).resolve(strict=True)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    @staticmethod
    def _json_bytes(document: object) -> bytes:
        return (
            json.dumps(
                document,
                ensure_ascii=False,
                allow_nan=False,
                sort_keys=True,
                separators=(",", ":"),
            )
            + "\n"
        ).encode("utf-8")

    @classmethod
    def _write_json(cls, path: Path, document: object) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(cls._json_bytes(document))

    @staticmethod
    def _binding(root: Path, relative: str) -> dict[str, object]:
        payload = (root / relative).read_bytes()
        return {
            "path": relative,
            "sha256": hashlib.sha256(payload).hexdigest(),
            "size_bytes": len(payload),
        }

    @staticmethod
    def _write_text(path: Path, payload: str) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(payload, encoding="utf-8")

    def _write_result_bundle(self, path: Path) -> None:
        (path / "Data").mkdir(parents=True)
        (path / "Info.plist").write_bytes(b"fixture-xcresult-info\n")

    @staticmethod
    def _data_boundary() -> dict[str, bool]:
        return {
            "holdout_accessed": False,
            "holdout_media_bytes_read": False,
            "validation_pixels_decoded_or_evaluated": False,
            "validation_metrics_computed": False,
            "validation_used_for_selection": False,
        }

    def _g04_case(
        self,
        name: str,
    ) -> tuple[Path, Path, Path, dict[str, object], dict[str, object]]:
        repository = self.root / name / "repository"
        artifact_parent = repository / "Artifacts/ASH"
        artifact_parent.mkdir(parents=True)
        final_root = artifact_parent / "g04-current-source"
        partial_root = artifact_parent / ".g04-current-source.partial"
        (partial_root / "analysis").mkdir(parents=True)
        quality_payload = self._json_bytes({"manifest_sha256": "a" * 64})
        installed_quality = repository / g05.QUALITY_MANIFEST_RELATIVE
        installed_quality.parent.mkdir(parents=True)
        installed_quality.write_bytes(quality_payload)
        implementation = repository / "validation/quality/src/fixture.py"
        self._write_text(implementation, "FIXTURE = True\n")

        xcode_summary = {
            "expectedFailures": 0,
            "failedTests": 0,
            "passedTests": 2,
            "result": "Passed",
            "skippedTests": 0,
            "totalTestCount": 2,
        }
        release_summary = {
            "status": "succeeded",
            "warningCount": 0,
            "errorCount": 0,
            "analyzerWarningCount": 0,
            "warnings": [],
            "errors": [],
            "analyzerWarnings": [],
            "destination": {"architecture": "arm64", "platform": "macOS"},
        }
        self._write_json(partial_root / "xcode/full-tests-summary.json", xcode_summary)
        self._write_json(
            partial_root / "xcode/full-coverage.json",
            {"targets": [{"name": "Mirmir"}]},
        )
        self._write_text(
            partial_root / "xcode/full-tests.log",
            "** TEST SUCCEEDED **\n",
        )
        self._write_result_bundle(partial_root / "xcode/full-tests.xcresult")
        self._write_json(
            partial_root / "xcode/release-build-summary.json",
            release_summary,
        )
        self._write_text(
            partial_root / "xcode/release-build.log",
            "** BUILD SUCCEEDED **\n",
        )
        binary_sha256 = "b" * 64
        self._write_text(
            partial_root / "xcode/release-binary-verification.log",
            "\n".join(
                (
                    "Mirmir: Mach-O 64-bit executable arm64",
                    "Format=app bundle with Mach-O thin (arm64)",
                    "CodeDirectory flags=0x10002(adhoc,runtime)",
                    f"{binary_sha256}  /fixture/Mirmir",
                    "",
                )
            ),
        )
        self._write_result_bundle(partial_root / "xcode/release-build.xcresult")
        self._write_text(
            partial_root / "tests/python-unittest.log",
            "Ran 3 tests in 0.001s\n\nOK\n",
        )
        self._write_text(partial_root / "tests/python-compileall.log", "")
        self._write_text(
            partial_root / "tests/instruction-package-validation.log",
            "PASS\ntotal_files=3\npayload_files=1\nchecksum_entries=2\n",
        )
        self._write_text(
            partial_root / "tests/swiftlint-strict.log",
            "Done linting! Found 0 violations, 0 serious in 2 files.\n",
        )
        metric = {
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
        self._write_json(partial_root / "tests/metric-oracle.log", metric)
        codec_fixture_relative = (
            "raw/actual-codec/actual-h264-software-nv12-v1.mp4"
        )
        codec_fixture_payload = b"fixture-generated-codec-bytes\n"
        codec_fixture_path = partial_root / codec_fixture_relative
        codec_fixture_path.parent.mkdir(parents=True, exist_ok=True)
        codec_fixture_path.write_bytes(codec_fixture_payload)
        self._write_json(
            partial_root / "raw/actual-codec/actual-codec-fixture-lock.json",
            {
                "schema_version": "1.0.0",
                "status": "pass",
                "fixture": {
                    "path": codec_fixture_path.name,
                    "sha256": hashlib.sha256(codec_fixture_payload).hexdigest(),
                    "size_bytes": len(codec_fixture_payload),
                },
            },
        )
        codec_binding = self._binding(
            partial_root,
            "raw/actual-codec/actual-codec-fixture-lock.json",
        )
        codec_fixture_binding = self._binding(
            partial_root,
            codec_fixture_relative,
        )
        self._write_text(
            partial_root / "tests/actual-codec-cli.log",
            "actual codec fixture verification passed: "
            f"{codec_binding['sha256']}\n",
        )
        self._write_json(
            partial_root / "attribution-scan.json",
            {
                "status": "pass",
                "base": BASELINE_COMMIT,
                "changed_file_count": 4,
                "findings": [],
            },
        )
        self._write_json(
            partial_root / "production-run/run/artifact-manifest.json",
            {"schema_version": "1.0.0", "artifacts": []},
        )
        self._write_json(
            partial_root / "production-run/run.failed/failure.json",
            {"status": "failed", "failure": "injected"},
        )
        self._write_json(
            partial_root / "production-run/run/input-bindings.json",
            {"status": "pass", "binding": "fixture"},
        )
        artifact_binding = self._binding(
            partial_root,
            "production-run/run/artifact-manifest.json",
        )
        failure_binding = self._binding(
            partial_root,
            "production-run/run.failed/failure.json",
        )
        execution_binding = self._binding(
            partial_root,
            "production-run/run/input-bindings.json",
        )
        implementation_payload = implementation.read_bytes()
        implementation_binding = {
            "path": implementation.relative_to(repository).as_posix(),
            "sha256": hashlib.sha256(implementation_payload).hexdigest(),
            "size_bytes": len(implementation_payload),
        }
        boundary = self._data_boundary()
        self._write_json(
            partial_root / "analysis/production-run-verification.json",
            {
                "schema_version": "1.0.0",
                "status": "pass",
                "source_commit": SOURCE_COMMIT,
                "semantic_reverification": True,
                "resume_recomputed": True,
                "writer_run_count": 2,
                "data_access": boundary,
                "artifact_manifest": artifact_binding,
                "injected_failure": failure_binding,
            },
        )
        self._write_json(
            partial_root / "analysis/data-access-attestation.json",
            {
                "schema_version": "1.0.0",
                "status": "pass",
                "source_commit": SOURCE_COMMIT,
                "execution_boundary": boundary,
                "execution_binding": execution_binding,
                "implementation_binding": implementation_binding,
                "observed_input_binding_flags": {
                    "all_split_evidence_rehashed": True,
                    "holdout_accessed": False,
                    "holdout_media_rehashed": False,
                },
            },
        )
        for relative in g04.QUALITY_REBUILD_RELATIVES:
            path = partial_root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(quality_payload)
        tests: dict[str, object] = {
            "schema_version": "1.0.0",
            "source_commit": SOURCE_COMMIT,
            "status": "pass",
            "xcode_full": {
                "status": "passed",
                "total": 2,
                "passed": 2,
                "failed": 0,
                "skipped": 0,
                "summary": "xcode/full-tests-summary.json",
                "coverage": "xcode/full-coverage.json",
                "result_bundle": "xcode/full-tests.xcresult",
                "log": "xcode/full-tests.log",
            },
            "release_build": {
                "status": "succeeded",
                "warnings": 0,
                "errors": 0,
                "analyzer_warnings": 0,
                "architecture": "arm64",
                "hardened_runtime": True,
                "binary_sha256": binary_sha256,
                "summary": "xcode/release-build-summary.json",
                "result_bundle": "xcode/release-build.xcresult",
                "log": "xcode/release-build.log",
                "verification": "xcode/release-binary-verification.log",
            },
            "python": {
                "status": "pass",
                "test_count": 3,
                "failures": 0,
                "skips": 0,
                "log": "tests/python-unittest.log",
            },
            "production_dry_run": {
                "status": "pass",
                "holdout_accessed": False,
                "case_count": 2,
                "writer_run_count": 2,
                "injected_failure_preserved": True,
                "resume_recomputed": True,
                "verification": "analysis/production-run-verification.json",
                "data_access_attestation": "analysis/data-access-attestation.json",
                "data_access": boundary,
                "artifact_manifest": artifact_binding,
                "injected_failure": failure_binding,
            },
            "metric_oracle": {
                "status": "pass",
                "log": "tests/metric-oracle.log",
            },
            "actual_codec_cli": {
                "status": "pass",
                "log": "tests/actual-codec-cli.log",
                "evidence": codec_binding,
                "fixture": codec_fixture_binding,
                "evidence_sha256": codec_binding["sha256"],
            },
            "static_validation": {
                "status": "pass",
                "log": "tests/python-compileall.log",
            },
            "instruction_package": {
                "status": "pass",
                "log": "tests/instruction-package-validation.log",
            },
            "attribution_scan": {
                "status": "pass",
                "findings": 0,
                "path": "attribution-scan.json",
            },
            "swiftlint": {
                "status": "pass",
                "violations": 0,
                "log": "tests/swiftlint-strict.log",
            },
            "quality_harness_manifest": {
                "status": "pass",
                "deterministic_rebuild_count": 2,
                "manifest_sha256": "a" * 64,
                "installed_file_sha256": hashlib.sha256(quality_payload).hexdigest(),
                "rebuild_a": self._binding(
                    partial_root,
                    g04.QUALITY_REBUILD_RELATIVES[0],
                ),
                "rebuild_b": self._binding(
                    partial_root,
                    g04.QUALITY_REBUILD_RELATIVES[1],
                ),
            },
        }
        mandatory_evidence = [
            "analysis/data-access-attestation.json",
            "analysis/production-run-verification.json",
            "attribution-scan.json",
            *g04.QUALITY_REBUILD_RELATIVES,
            "production-run/run.failed/failure.json",
            "production-run/run/artifact-manifest.json",
            "production-run/run/input-bindings.json",
            "raw/actual-codec/actual-codec-fixture-lock.json",
            codec_fixture_relative,
            "test-results.json",
            "tests/actual-codec-cli.log",
            "tests/instruction-package-validation.log",
            "tests/metric-oracle.log",
            "tests/python-compileall.log",
            "tests/python-unittest.log",
            "tests/swiftlint-strict.log",
            "xcode/full-coverage.json",
            "xcode/full-tests-summary.json",
            "xcode/full-tests.log",
            "xcode/release-binary-verification.log",
            "xcode/release-build-summary.json",
            "xcode/release-build.log",
        ]
        assessment: dict[str, object] = {
            "schema_version": "1.0.0",
            "gate": "G04",
            "status": "pass",
            "project_commit": SOURCE_COMMIT,
            "holdout_accessed": False,
            "algorithm_quality_claimed": False,
            "criteria": [
                {"criterion": criterion, "pass": True}
                for criterion in g04.g05_gate.G04_ASSESSMENT_CRITERIA
            ],
            "evidence": sorted(mandatory_evidence),
            "test_results": "test-results.json",
        }
        self._write_json(
            partial_root / g04.ASSESSMENT_RELATIVE,
            assessment,
        )
        self._write_json(
            partial_root / g04.TEST_RESULTS_RELATIVE,
            tests,
        )
        return repository, partial_root, final_root, assessment, tests

    @staticmethod
    def _repository_state() -> SimpleNamespace:
        return SimpleNamespace(project_commit=SOURCE_COMMIT)

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

    def _g04_patches(self) -> tuple[object, object, object, object]:
        state = self._repository_state()
        return (
            mock.patch.object(g04, "_repository_state", return_value=state),
            mock.patch.object(
                g04,
                "_validate_quality_manifest",
                return_value="a" * 64,
            ),
            mock.patch.object(g04, "validate_schema"),
            mock.patch.object(
                g04,
                "_xcresult_document",
                side_effect=self._extract_fixture_xcresult,
            ),
        )

    def _validate_g04(self, repository: Path, partial: Path) -> g04.ValidatedG04Evidence:
        patches = self._g04_patches()
        with patches[0], patches[1], patches[2], patches[3]:
            return g04.validate_staged_g04(
                repository_root=repository,
                partial_root=partial,
                expected_source_commit=SOURCE_COMMIT,
            )

    def test_g04_staged_contract_accepts_only_explicit_same_source_pass(self) -> None:
        repository, partial, _, _, _ = self._g04_case("g04-valid")
        evidence = self._validate_g04(repository, partial)
        self.assertEqual(evidence.assessment["holdout_accessed"], False)
        self.assertEqual(evidence.tests["source_commit"], SOURCE_COMMIT)
        self.assertGreater(len(evidence.files), 20)

    def test_g04_staged_contract_rejects_holdout_and_unbound_evidence(self) -> None:
        repository, partial, _, assessment, tests = self._g04_case("g04-reject")
        assessment["holdout_accessed"] = True
        self._write_json(partial / g04.ASSESSMENT_RELATIVE, assessment)
        with self.assertRaisesRegex(
            g04.G04CurrentSourceError,
            "explicit same-source no-holdout pass",
        ):
            self._validate_g04(repository, partial)

        assessment["holdout_accessed"] = False
        tests["actual_codec_cli"]["evidence"] = {
            "path": "missing.bin",
            "sha256": hashlib.sha256(b"missing").hexdigest(),
            "size_bytes": len(b"missing"),
        }
        self._write_json(partial / g04.ASSESSMENT_RELATIVE, assessment)
        self._write_json(partial / g04.TEST_RESULTS_RELATIVE, tests)
        with self.assertRaisesRegex(
            g04.G04CurrentSourceError,
            "file is absent",
        ):
            self._validate_g04(repository, partial)

    def test_g04_repository_and_staged_binding_namespaces_cannot_cross(self) -> None:
        repository, partial, _, _, tests = self._g04_case("g04-binding-roots")
        attestation_path = partial / "analysis/data-access-attestation.json"
        attestation = json.loads(attestation_path.read_bytes())
        repository_binding = dict(attestation["implementation_binding"])
        staged_binding = self._binding(
            partial,
            "production-run/run/input-bindings.json",
        )

        attestation["implementation_binding"] = staged_binding
        self._write_json(attestation_path, attestation)
        with self.assertRaisesRegex(
            g04.G04CurrentSourceError,
            "production implementation binding is absent",
        ):
            self._validate_g04(repository, partial)

        attestation["implementation_binding"] = repository_binding
        self._write_json(attestation_path, attestation)
        tests["production_dry_run"]["artifact_manifest"] = repository_binding
        self._write_json(partial / g04.TEST_RESULTS_RELATIVE, tests)
        with self.assertRaisesRegex(
            g04.G04CurrentSourceError,
            "production artifact manifest file is absent",
        ):
            self._validate_g04(repository, partial)

    def test_g04_rejects_status_only_two_file_wrapper(self) -> None:
        repository = self.root / "g04-two-file/repository"
        partial = repository / "Artifacts/ASH/.g04.partial"
        (partial / "analysis").mkdir(parents=True)
        self._write_json(
            partial / g04.ASSESSMENT_RELATIVE,
            {
                "schema_version": "1.0.0",
                "gate": "G04",
                "status": "pass",
                "project_commit": SOURCE_COMMIT,
                "holdout_accessed": False,
                "algorithm_quality_claimed": False,
                "test_results": "test-results.json",
                "criteria": [],
                "evidence": ["test-results.json"],
            },
        )
        self._write_json(
            partial / g04.TEST_RESULTS_RELATIVE,
            {
                "schema_version": "1.0.0",
                "source_commit": SOURCE_COMMIT,
                "status": "pass",
            },
        )
        with mock.patch.object(
            g04,
            "_repository_state",
            return_value=self._repository_state(),
        ):
            with self.assertRaisesRegex(
                g04.g05_gate.G05GateError,
                "Xcode evidence is absent",
            ):
                g04.validate_staged_g04(
                    repository_root=repository,
                    partial_root=partial,
                    expected_source_commit=SOURCE_COMMIT,
                )

    def test_g04_rejects_missing_and_invalid_mandatory_evidence(self) -> None:
        cases = (
            (
                "missing-python",
                lambda root, tests: (root / "tests/python-unittest.log").unlink(),
                "not manifest-bound",
            ),
            (
                "bad-xcode-summary",
                lambda root, tests: self._write_json(
                    root / "xcode/full-tests-summary.json",
                    {
                        "expectedFailures": 0,
                        "failedTests": 1,
                        "passedTests": 1,
                        "result": "Failed",
                        "skippedTests": 0,
                        "totalTestCount": 2,
                    },
                ),
                "summary content differs",
            ),
            (
                "bad-swiftlint",
                lambda root, tests: self._write_text(
                    root / "tests/swiftlint-strict.log",
                    "Done linting! Found 1 violations, 1 serious in 2 files.\n",
                ),
                "does not prove one zero-violation",
            ),
            (
                "bad-actual-codec-fixture",
                lambda root, tests: self._write_text(
                    root
                    / "raw/actual-codec/actual-h264-software-nv12-v1.mp4",
                    "substituted fixture bytes\n",
                ),
                "actual-codec fixture differs from its file bytes",
            ),
            (
                "missing-xcresult-info",
                lambda root, tests: (
                    root / "xcode/full-tests.xcresult/Info.plist"
                ).unlink(),
                "lacks the canonical xcresult",
            ),
        )
        for name, mutate, message in cases:
            with self.subTest(case=name):
                repository, partial, _, _, tests = self._g04_case(name)
                mutate(partial, tests)
                with self.assertRaisesRegex(Exception, message):
                    self._validate_g04(repository, partial)

    def test_g04_rejects_nonidentical_quality_manifest_rebuilds(self) -> None:
        repository, partial, _, _, tests = self._g04_case("quality-mismatch")
        rebuild_b = partial / g04.QUALITY_REBUILD_RELATIVES[1]
        self._write_json(rebuild_b, {"manifest_sha256": "f" * 64})
        tests["quality_harness_manifest"]["rebuild_b"] = self._binding(
            partial,
            g04.QUALITY_REBUILD_RELATIVES[1],
        )
        self._write_json(partial / g04.TEST_RESULTS_RELATIVE, tests)
        with self.assertRaisesRegex(
            g04.G04CurrentSourceError,
            "not two byte-identical installed-lock rebuilds",
        ):
            self._validate_g04(repository, partial)

    def _publish_mock_g04(
        self,
        *,
        partial: Path,
        final: Path,
        mutate_relative: str | None = None,
    ) -> Path:
        os.rename(partial, final)
        if mutate_relative is not None:
            (final / mutate_relative).write_text("mutated\n", encoding="utf-8")
        artifacts = []
        directories = []
        for path in sorted(final.rglob("*")):
            relative = path.relative_to(final).as_posix()
            if path.is_dir():
                directories.append(relative)
            else:
                payload = path.read_bytes()
                artifacts.append(
                    {
                        "path": relative,
                        "sha256": hashlib.sha256(payload).hexdigest(),
                        "size_bytes": len(payload),
                    }
                )
        self._write_json(
            final / "artifact-manifest.json",
            {
                "schema_version": "2.0.0",
                "working_tree_clean": True,
                "project_commit": SOURCE_COMMIT,
                "directories": directories,
                "artifacts": artifacts,
            },
        )
        return final

    def test_g04_finalizer_delegates_schema_two_publication_and_reopens(self) -> None:
        repository, partial, final, _, _ = self._g04_case("g04-finalize")
        def publish(**arguments: object) -> Path:
            self.assertEqual(arguments["partial"], partial)
            self.assertEqual(arguments["final"], final)
            self.assertEqual(arguments["gate_ids"], ("G04",))
            return self._publish_mock_g04(partial=partial, final=final)

        patches = self._g04_patches()
        with patches[0], patches[1], patches[2], patches[3], mock.patch.object(
            g04,
            "finalize_evidence_wrapper",
            side_effect=publish,
        ) as finalizer, mock.patch.object(
            g04.g05,
            "_validate_finalized_g04_closure",
            return_value={"status": "pass"},
        ) as reopen:
            published = g04.finalize_g04_current_source(
                repository_root=repository,
                partial_root=partial,
                final_root=final,
                expected_source_commit=SOURCE_COMMIT,
            )
        self.assertEqual(published, final)
        finalizer.assert_called_once()
        reopen.assert_called_once()

    def test_g04_finalizer_rejects_mandatory_evidence_toctou_change(self) -> None:
        repository, partial, final, _, _ = self._g04_case("g04-toctou")

        def publish(**_: object) -> Path:
            return self._publish_mock_g04(
                partial=partial,
                final=final,
                mutate_relative="tests/python-unittest.log",
            )

        patches = self._g04_patches()
        with patches[0], patches[1], patches[2], patches[3], mock.patch.object(
            g04,
            "finalize_evidence_wrapper",
            side_effect=publish,
        ), mock.patch.object(
            g04.g05,
            "_validate_finalized_g04_closure",
            return_value={"status": "pass"},
        ):
            with self.assertRaisesRegex(
                g04.G04CurrentSourceError,
                "published mandatory G04 evidence changed",
            ):
                g04.finalize_g04_current_source(
                    repository_root=repository,
                    partial_root=partial,
                    final_root=final,
                    expected_source_commit=SOURCE_COMMIT,
                )

    def _g05_case(self, name: str) -> tuple[Path, Path, Path, Path]:
        repository = self.root / name / "repository"
        artifact_parent = repository / "Artifacts/ASH"
        artifact_parent.mkdir(parents=True)
        final_root = artifact_parent / "g05-current-source"
        partial_root = artifact_parent / ".g05-current-source.partial"
        instruction_root = self.root / name / "instruction-package"
        instruction_root.mkdir()
        self._write_json(instruction_root / "package_manifest.json", {"fixture": True})
        (instruction_root / "SHA256SUMS.txt").write_text(
            f"{'0' * 64}  package_manifest.json\n",
            encoding="utf-8",
        )
        (instruction_root / "policy.json").write_text(
            '{"fixture":"policy"}\n',
            encoding="utf-8",
        )
        return repository, partial_root, final_root, instruction_root

    @staticmethod
    def _stager_patches(
        command_runner: object,
    ) -> tuple[object, object, object, object]:
        return (
            mock.patch.object(
                stage_g05.g05,
                "_validate_repository_state",
                return_value="f" * 64,
            ),
            mock.patch.object(
                stage_g05.g05,
                "_validate_baseline_commit",
                return_value={"status": "pass"},
            ),
            mock.patch.object(
                stage_g05.g05.shutil,
                "which",
                return_value="/usr/bin/true",
            ),
            mock.patch.object(
                stage_g05.g05.subprocess,
                "run",
                side_effect=command_runner,
            ),
        )

    def test_g05_stager_creates_only_the_assessor_owned_initial_closure(self) -> None:
        repository, partial, final, instruction = self._g05_case("g05-valid")
        expected_instruction = g05._instruction_validation_output(instruction)
        calls: list[tuple[str, ...]] = []

        def execute(argv: tuple[str, ...], **_: object) -> SimpleNamespace:
            command = tuple(argv)
            calls.append(command)
            if command[0] == "/usr/bin/true":
                payload = (
                    b"Done linting! Found 0 violations, 0 serious in 1 files.\n"
                )
            elif command[-1] == "tools/validate_instruction_package.py":
                payload = expected_instruction
            elif command == ("/usr/bin/git", "diff", "--check"):
                payload = b""
            else:
                raise AssertionError(f"unexpected executed command: {command}")
            return SimpleNamespace(returncode=0, stdout=payload, stderr=b"")

        patches = self._stager_patches(execute)
        with patches[0], patches[1], patches[2], patches[3]:
            staged = stage_g05.stage_g05_current_source(
                repository_root=repository,
                partial_root=partial,
                final_root=final,
                expected_source_commit=SOURCE_COMMIT,
                instruction_package_root=instruction,
                p00_baseline_commit=BASELINE_COMMIT,
            )
        self.assertEqual(staged, partial)
        self.assertEqual(len(calls), 3)
        executed = "\n".join(" ".join(call) for call in calls)
        self.assertNotIn("run_p05_evidence.py", executed)
        self.assertNotIn("build_quality_harness_implementation_manifest.py", executed)
        self.assertNotIn("scan_project_attribution.py", executed)
        self.assertEqual(
            g05._collect_files(partial),
            tuple(sorted(g05._initial_staged_paths())),
        )
        self.assertEqual(
            g05._collect_directories(partial),
            tuple(sorted(g05._initial_staged_directories())),
        )
        plan = json.loads((partial / "inputs/g05-command-plan.json").read_bytes())
        self.assertEqual(plan["source_commit"], SOURCE_COMMIT)
        self.assertEqual(
            [row["id"] for row in plan["commands"]],
            list(g05.COMMAND_IDS),
        )

    def test_g05_stager_preserves_partial_and_rejects_stderr(self) -> None:
        repository, partial, final, instruction = self._g05_case("g05-stderr")

        def execute(_: tuple[str, ...], **__: object) -> SimpleNamespace:
            return SimpleNamespace(
                returncode=0,
                stdout=b"",
                stderr=b"unexpected diagnostic\n",
            )

        patches = self._stager_patches(execute)
        with patches[0], patches[1], patches[2], patches[3]:
            with self.assertRaisesRegex(
                g05.G05CurrentSourceError,
                "bound command failed or emitted stderr",
            ):
                stage_g05.stage_g05_current_source(
                    repository_root=repository,
                    partial_root=partial,
                    final_root=final,
                    expected_source_commit=SOURCE_COMMIT,
                    instruction_package_root=instruction,
                    p00_baseline_commit=BASELINE_COMMIT,
                )
        self.assertTrue(partial.is_dir())
        self.assertTrue((partial / "inputs/g05-command-plan.json").is_file())
        self.assertFalse((partial / "outputs/swiftlint.log").exists())


if __name__ == "__main__":
    unittest.main()
