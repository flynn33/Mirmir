from __future__ import annotations

from collections import OrderedDict
import hashlib
import os
from pathlib import Path, PurePosixPath
import shlex
import stat
import tempfile
from typing import Mapping
import unittest
from unittest import mock

from validation.calibration_v2.release_evidence import evidence_binding
from validation.calibration_v2 import release_orchestrator as orchestrator
from validation.calibration_v2.release_orchestrator import (
    P06ReleaseOrchestrationError,
    REQUIRED_G06_TEST_EVIDENCE_IDS,
    _copy_g06_test_evidence_set,
)
from validation.calibration_v2.tests.native_benchmark_fixture import (
    BENCHMARK_SCHEMA_PATH,
    create_frozen_runtime_fixture,
    thaw_and_remove_runtime_fixture,
)
from validation.calibration_v2.tools.finalize_p06_runtime_correction import (
    VerifiedRuntimeCorrection,
)
from validation.calibration_v2.tools import run_g06_verification as g06
from validation.quality.src.mirmir_quality.json_tools import (
    canonical_json_bytes,
    canonical_sha256,
    manifest_sha256,
)


REPOSITORY_ROOT = Path(__file__).resolve().parents[3]
RUNTIME_MANIFEST_SCHEMA = (
    REPOSITORY_ROOT
    / "validation/calibration_v2/schemas/"
    "p06-runtime-correction-artifact-manifest-v1.schema.json"
)


def _clean_repository_state() -> dict[str, object]:
    project_commit = g06._git_head(REPOSITORY_ROOT)
    empty_sha256 = hashlib.sha256(b"").hexdigest()
    dirty_state_sha256 = canonical_sha256(
        {
            "algorithm": "git-diff-head-binary-plus-content-bound-untracked-v1",
            "artifact_pathspec_exclusion": "Artifacts/**",
            "project_commit": project_commit,
            "tracked_diff_sha256": empty_sha256,
            "tracked_diff_size_bytes": 0,
            "ordered_untracked_files": [],
        }
    )
    return {
        "algorithm": "git-diff-head-binary-plus-content-bound-untracked-v1",
        "artifact_pathspec_exclusion": "Artifacts/**",
        "project_commit": project_commit,
        "tracked_diff_sha256": empty_sha256,
        "tracked_diff_size_bytes": 0,
        "untracked_file_count": 0,
        "ordered_untracked_files_sha256": canonical_sha256([]),
        "dirty_state_sha256": dirty_state_sha256,
    }


def _native_runtime_fixture(
    run_root: Path,
    *,
    frozen: VerifiedRuntimeCorrection,
    provenance: Mapping[str, object],
) -> tuple[dict[str, object], dict[str, object]]:
    runtime_root = run_root / "inputs/native-runtime-evidence"
    g06._copy_runtime_evidence_snapshot(
        frozen,
        destination=runtime_root,
    )
    runtime_binding = dict(
        g06._tree_binding(
            runtime_root,
            run_root=run_root,
            artifact_kind="native_runtime_evidence_input",
        )
    )
    return runtime_binding, dict(provenance)


class G06ReleaseEvidenceHandoffTests(unittest.TestCase):
    def setUp(self) -> None:
        self.repository_state = _clean_repository_state()
        self.repository_state_patcher = mock.patch.object(
            orchestrator,
            "runtime_correction_repository_state",
            return_value=(self.repository_state, True),
        )
        self.g06_repository_state_patcher = mock.patch.object(
            g06,
            "runtime_correction_repository_state",
            return_value=(self.repository_state, True),
        )
        self.repository_state_patcher.start()
        self.g06_repository_state_patcher.start()
        artifacts_root = REPOSITORY_ROOT / "Artifacts/ASH"
        artifacts_root.mkdir(parents=True, exist_ok=True)
        self.runtime_parent_context = tempfile.TemporaryDirectory(
            prefix="mirmir-g06-handoff-runtime-",
            dir=artifacts_root,
        )
        self.addCleanup(self.runtime_parent_context.cleanup)
        runtime_parent = Path(self.runtime_parent_context.name)
        (
            self.runtime_source,
            self.runtime_manifest_file_sha256,
            _,
        ) = create_frozen_runtime_fixture(
            runtime_parent,
            repository_root=REPOSITORY_ROOT,
            repository_state=self.repository_state,
        )
        self.addCleanup(
            thaw_and_remove_runtime_fixture,
            self.runtime_source,
        )
        relative_root = PurePosixPath(
            self.runtime_source.relative_to(REPOSITORY_ROOT).as_posix()
        )
        self.runtime_verified = g06.verify_frozen_runtime_correction(
            self.runtime_source,
            expected_manifest_file_sha256=(
                self.runtime_manifest_file_sha256
            ),
            expected_root_label=relative_root.as_posix(),
        )
        self.runtime_provenance = g06._native_runtime_source_provenance(
            self.runtime_verified,
            repository_root=REPOSITORY_ROOT,
            repository_relative_root=relative_root,
        )

    def tearDown(self) -> None:
        self.g06_repository_state_patcher.stop()
        self.repository_state_patcher.stop()

    def _executor(self, identifier: str) -> object:
        def execute(run_root: Path) -> g06.GroupResult:
            def command(
                index: int,
                argv: list[str],
                artifact_id: str,
                payload: bytes,
                *,
                artifact_kind: str = "command_log",
            ) -> tuple[dict[str, object], dict[str, object]]:
                path = run_root.joinpath(*Path(artifact_id).parts)
                g06._write_new(path, payload)
                binding = dict(
                    g06._file_binding(
                        path,
                        run_root=run_root,
                        artifact_kind=artifact_kind,
                    )
                )
                return (
                    {
                        "command_index": index,
                        "argv": argv,
                        "command_text": shlex.join(argv),
                        "working_directory": ".",
                        "exit_code": 0,
                        "timed_out": False,
                        "duration_seconds": 0.0,
                        "status": "passed",
                        "log_binding": binding,
                    },
                    binding,
                )

            def xcode_test_argv(
                configuration: str,
                derived: Path,
                result: Path,
                tests: tuple[str, ...],
                *,
                clean: bool,
            ) -> list[str]:
                return [
                    "xcodebuild",
                    "-project",
                    "Mirmir.xcodeproj",
                    "-scheme",
                    "Mirmir",
                    "-configuration",
                    configuration,
                    "-destination",
                    "platform=macOS,arch=arm64",
                    "-derivedDataPath",
                    str(derived),
                    "-resultBundlePath",
                    str(result),
                    "-enableCodeCoverage",
                    "YES",
                    "-parallel-testing-enabled",
                    "NO",
                    "CODE_SIGNING_ALLOWED=NO",
                    *(("ENABLE_TESTABILITY=YES",) if configuration == "Release" else ()),
                    *(f"-only-testing:MirmirTests/{name}" for name in tests),
                    *(("clean", "test") if clean else ("test",)),
                ]

            xcresult_document = {
                "totalTestCount": 2,
                "passedTests": 2,
                "failedTests": 0,
                "skippedTests": 0,
                "expectedFailures": 0,
                "result": "Passed",
            }
            commands: list[dict[str, object]] = []
            artifacts: list[dict[str, object]] = []
            summary: dict[str, object]

            if identifier == "python_calibration_full_suite":
                unittest_log = b"Ran 2 tests in 0.1s\n\nOK\n"
                pytest_log = b"3 passed in 0.1s\n"
                native_benchmark_proof_log = b"1 passed in 0.1s\n"
                runtime_binding, runtime_source = _native_runtime_fixture(
                    run_root,
                    frozen=self.runtime_verified,
                    provenance=self.runtime_provenance,
                )
                benchmark_path = (
                    run_root
                    / "inputs/native-runtime-evidence/"
                    "native-aggregate-benchmark.json"
                )
                first, first_binding = command(
                    1,
                    [
                        "/usr/bin/env",
                        "PYTHONOPTIMIZE=",
                        "/usr/bin/python3",
                        "-m",
                        "unittest",
                        "discover",
                        "-s",
                        "validation/calibration_v2/tests",
                        "-p",
                        "test_*.py",
                    ],
                    "logs/python-unittest-discovery.log",
                    unittest_log,
                )
                second, second_binding = command(
                    2,
                    [
                        "/usr/bin/env",
                        "PYTEST_ADDOPTS=",
                        "PYTEST_DISABLE_PLUGIN_AUTOLOAD=1",
                        "PYTEST_PLUGINS=",
                        "PYTHONHOME=",
                        "PYTHONOPTIMIZE=",
                        f"PYTHONPATH={REPOSITORY_ROOT}",
                        "MIRMIR_AGGREGATE_BENCHMARK_OUTPUT=",
                        "MIRMIR_RUN_NATIVE_AGGREGATE_BENCHMARK=1",
                        (
                            "MIRMIR_NATIVE_AGGREGATE_BENCHMARK_OUTPUT="
                            f"{benchmark_path}"
                        ),
                        "/usr/bin/python3",
                        "-m",
                        "pytest",
                        "-c",
                        "/dev/null",
                        "-p",
                        "no:cacheprovider",
                        "--noconftest",
                        "-q",
                        "validation/calibration_v2/tests",
                    ],
                    "logs/python-pytest.log",
                    pytest_log,
                )
                third_argv = [
                    *second["argv"][:-1],
                    g06.NATIVE_BENCHMARK_PROOF_NODE_ID,
                ]
                third, third_binding = command(
                    3,
                    third_argv,
                    "logs/python-native-benchmark-proof.log",
                    native_benchmark_proof_log,
                )
                commands = [first, second, third]
                artifacts = [
                    first_binding,
                    second_binding,
                    third_binding,
                    runtime_binding,
                ]
                counts = (
                    g06.parse_unittest_output(unittest_log.decode()),
                    g06.parse_pytest_output(pytest_log.decode()),
                    g06.parse_pytest_output(
                        native_benchmark_proof_log.decode()
                    ),
                )
                summary = {
                    "runners": [
                        {"runner": runner, "counts": result}
                        for runner, result in zip(
                            (
                                "unittest_discovery",
                                "pytest",
                                "native_benchmark_proof",
                            ),
                            counts,
                        )
                    ],
                    "aggregate_executed_test_count": 6,
                    "required_runner_order": [
                        "unittest_discovery",
                        "pytest",
                        "native_benchmark_proof",
                    ],
                    "native_runtime_evidence_input": runtime_binding,
                    "native_runtime_source": runtime_source,
                }
            elif identifier == "xcode_native_integration":
                derived = run_root / "build/native-integration-derived-data"
                result = run_root / "artifacts/native-integration.xcresult"
                g06._write_new(result / "Info.plist", b"result-info\n")
                first, first_binding = command(
                    1,
                    xcode_test_argv(
                        "Debug",
                        derived,
                        result,
                        g06.NATIVE_INTEGRATION_TESTS,
                        clean=True,
                    ),
                    "logs/xcode-native-integration.log",
                    b"native integration passed\n",
                )
                summary_argv = [
                    "xcrun",
                    "xcresulttool",
                    "get",
                    "test-results",
                    "summary",
                    "--path",
                    str(result),
                ]
                second, second_binding = command(
                    2,
                    summary_argv,
                    "artifacts/native-integration-xcresult-summary.log",
                    canonical_json_bytes(xcresult_document) + b"\n",
                    artifact_kind="xcresult_summary",
                )
                result_binding = dict(
                    g06._tree_binding(
                        result,
                        run_root=run_root,
                        artifact_kind="xcresult",
                    )
                )
                commands = [first, second]
                artifacts = [first_binding, second_binding, result_binding]
                summary = {
                    "configuration": "Debug",
                    "scheme": "Mirmir",
                    "destination": "platform=macOS,arch=arm64",
                    "only_testing": list(g06.NATIVE_INTEGRATION_TESTS),
                    "test_counts": g06.parse_xcresult_summary(xcresult_document),
                    "warning_count": 0,
                    "error_count": 0,
                }
            elif identifier == "xcode_release_runtime":
                derived = run_root / "build/release-derived-data"
                result = run_root / "artifacts/release-runtime.xcresult"
                g06._write_new(result / "Info.plist", b"release-result-info\n")
                build_argv = [
                    "xcodebuild",
                    "-project",
                    "Mirmir.xcodeproj",
                    "-scheme",
                    "Mirmir",
                    "-configuration",
                    "Release",
                    "-destination",
                    "platform=macOS,arch=arm64",
                    "-derivedDataPath",
                    str(derived),
                    "CODE_SIGNING_ALLOWED=NO",
                    "ENABLE_TESTABILITY=YES",
                    "clean",
                    "build",
                ]
                first, first_binding = command(
                    1,
                    build_argv,
                    "logs/xcode-release-build.log",
                    b"** BUILD SUCCEEDED **\n",
                )
                second, second_binding = command(
                    2,
                    xcode_test_argv(
                        "Release",
                        derived,
                        result,
                        g06.RELEASE_RUNTIME_TESTS,
                        clean=False,
                    ),
                    "logs/xcode-release-runtime.log",
                    b"release runtime passed\n",
                )
                summary_argv = [
                    "xcrun",
                    "xcresulttool",
                    "get",
                    "test-results",
                    "summary",
                    "--path",
                    str(result),
                ]
                third, third_binding = command(
                    3,
                    summary_argv,
                    "artifacts/release-runtime-xcresult-summary.log",
                    canonical_json_bytes(xcresult_document) + b"\n",
                    artifact_kind="xcresult_summary",
                )
                result_binding = dict(
                    g06._tree_binding(
                        result,
                        run_root=run_root,
                        artifact_kind="xcresult",
                    )
                )
                product = (
                    derived
                    / "Build/Products/Release/Mirmir.app/Contents/MacOS/Mirmir"
                )
                g06._write_new(product, b"release-product\n")
                product.chmod(0o755)
                product_binding = dict(
                    g06._file_binding(
                        product,
                        run_root=run_root,
                        artifact_kind="release_product",
                    )
                )
                commands = [first, second, third]
                artifacts = [
                    first_binding,
                    second_binding,
                    third_binding,
                    result_binding,
                    product_binding,
                ]
                summary = {
                    "configuration": "Release",
                    "scheme": "Mirmir",
                    "destination": "platform=macOS,arch=arm64",
                    "only_testing": list(g06.RELEASE_RUNTIME_TESTS),
                    "build_warning_count": 0,
                    "build_error_count": 0,
                    "runtime_warning_count": 0,
                    "runtime_error_count": 0,
                    "test_counts": g06.parse_xcresult_summary(xcresult_document),
                }
            elif identifier == "swiftlint":
                first, first_binding = command(
                    1,
                    ["swiftlint", "version"],
                    "logs/swiftlint-version.log",
                    b"0.63.2\n",
                )
                second, second_binding = command(
                    2,
                    ["swiftlint", "lint", "--strict", "--config", ".swiftlint.yml"],
                    "logs/swiftlint-strict.log",
                    b"Done linting! Found 0 violations, 0 serious in 91 files.\n",
                )
                commands = [first, second]
                artifacts = [first_binding, second_binding]
                summary = {
                    "strict": True,
                    "warning_count": 0,
                    "error_count": 0,
                }
            else:
                release_lock_log = b"Ran 37 tests in 1.0s\n\nOK\n"
                first, first_binding = command(
                    1,
                    [
                        "/usr/bin/env",
                        "PYTHONOPTIMIZE=",
                        "/usr/bin/python3",
                        "-m",
                        "unittest",
                        *g06.RELEASE_LOCK_TEST_MODULES,
                    ],
                    "logs/release-lock-unit-suite.log",
                    release_lock_log,
                )
                commands = [first]
                artifacts = [first_binding]
                summary = {
                    "modules": list(g06.RELEASE_LOCK_TEST_MODULES),
                    "test_counts": g06.parse_unittest_output(
                        release_lock_log.decode()
                    ),
                }
            return g06.GroupResult(
                status="passed",
                started_utc="2026-07-11T00:00:00.000000Z",
                finished_utc="2026-07-11T00:00:01.000000Z",
                commands=tuple(commands),
                artifacts=tuple(artifacts),
                summary=summary,
                failure_reason=None,
            )

        return execute

    def _make_run(self, root: Path) -> tuple[Path, OrderedDict[str, Path]]:
        wrapper_partial = root.parent / f".{root.name}.partial"
        execution_output_root = wrapper_partial / "g06"
        execution_output_root.mkdir(parents=True)
        executors = {
            identifier: self._executor(identifier)
            for identifier in REQUIRED_G06_TEST_EVIDENCE_IDS
        }
        result = g06.G06VerificationRunner(
            repository_root=REPOSITORY_ROOT,
            output_root=execution_output_root,
            run_id="g06-pass",
            native_runtime_evidence_root=self.runtime_source,
            expected_native_runtime_manifest_file_sha256=(
                self.runtime_manifest_file_sha256
            ),
            group_executors=executors,
        ).run()
        self.assertEqual(result.status, "passed")
        wrapper_partial.rename(root)
        run_root = root / "g06" / result.path.name
        self._thaw_outer_wrapper(root)
        return (
            run_root.resolve(strict=True),
            OrderedDict(
                (
                    identifier,
                    (run_root / path.name).resolve(strict=True),
                )
                for identifier, path in result.evidence_paths
            ),
        )

    def _write_outer_wrapper_manifest(self, wrapper_root: Path) -> None:
        manifest_path = wrapper_root / orchestrator.G06_OUTER_WRAPPER_MANIFEST_NAME
        if manifest_path.exists() or manifest_path.is_symlink():
            manifest_path.unlink()
        transaction_path = (
            wrapper_root / orchestrator.G06_OUTER_WRAPPER_TRANSACTION_NAME
        )
        transaction = {
            "schema_version": "1.0.0",
            "artifact_kind": "evidence_wrapper_publication_transaction",
            "transaction_token": "1" * 32,
            "created_utc": "2026-07-11T00:00:01Z",
            "project_commit": self.repository_state["project_commit"],
            "partial_name": f".{wrapper_root.name}.partial",
            "final_name": wrapper_root.name,
            "failure_name": f"{wrapper_root.name}.failed",
            "gate_ids": ["G06", "P06"],
            "root_device": wrapper_root.stat().st_dev,
            "root_inode": wrapper_root.stat().st_ino,
        }
        transaction_path.write_bytes(canonical_json_bytes(transaction) + b"\n")
        rows = []
        for path in sorted(
            wrapper_root.rglob("*"),
            key=lambda candidate: candidate.relative_to(wrapper_root).as_posix(),
        ):
            metadata = path.lstat()
            if not stat.S_ISREG(metadata.st_mode):
                continue
            payload = path.read_bytes()
            rows.append(
                {
                    "path": path.relative_to(wrapper_root).as_posix(),
                    "sha256": hashlib.sha256(payload).hexdigest(),
                    "size_bytes": len(payload),
                    "producer": "G06 handoff test fixture",
                    "gate_ids": ["G06", "P06"],
                    "command": "G06 handoff fixture execution",
                    "platform": "macOS arm64 unit-test platform",
                    "machine": "macOS arm64 unit-test fixture",
                }
            )
        manifest = {
            "schema_version": "2.0.0",
            "created_utc": "2026-07-11T00:00:02Z",
            "project_commit": self.repository_state["project_commit"],
            "working_tree_clean": True,
            "directories": sorted(
                path.relative_to(wrapper_root).as_posix()
                for path in wrapper_root.rglob("*")
                if path.is_dir() and not path.is_symlink()
            ),
            "artifacts": rows,
        }
        manifest_path.write_bytes(canonical_json_bytes(manifest) + b"\n")

    @staticmethod
    def _freeze_outer_wrapper(wrapper_root: Path) -> None:
        paths = [*wrapper_root.rglob("*"), wrapper_root]
        frozen_files: set[tuple[int, int]] = set()
        for path in paths:
            if path.is_symlink():
                continue
            metadata = path.lstat()
            if stat.S_ISREG(metadata.st_mode):
                identity = (metadata.st_dev, metadata.st_ino)
                if identity in frozen_files:
                    continue
                executable = metadata.st_mode & (
                    stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH
                )
                os.chmod(path, 0o444 | executable)
                os.chflags(
                    path,
                    metadata.st_flags | stat.UF_IMMUTABLE,
                    follow_symlinks=False,
                )
                frozen_files.add(identity)
        directories = sorted(
            (
                path
                for path in paths
                if not path.is_symlink() and path.is_dir()
            ),
            key=lambda path: len(path.parts),
            reverse=True,
        )
        for path in directories:
            metadata = path.lstat()
            os.chmod(path, 0o555)
            os.chflags(
                path,
                metadata.st_flags | stat.UF_IMMUTABLE,
                follow_symlinks=False,
            )

    @staticmethod
    def _thaw_outer_wrapper(wrapper_root: Path) -> None:
        if not wrapper_root.exists():
            return
        paths = [wrapper_root, *wrapper_root.rglob("*")]
        for path in paths:
            if path.is_symlink():
                continue
            try:
                metadata = path.lstat()
                os.chflags(
                    path,
                    metadata.st_flags & ~stat.UF_IMMUTABLE,
                    follow_symlinks=False,
                )
                mode = stat.S_IMODE(metadata.st_mode) | stat.S_IWUSR
                if path.is_dir():
                    mode |= stat.S_IXUSR
                os.chmod(path, mode)
            except OSError:
                continue

    def _consume_g06(
        self,
        *,
        test_evidence_paths: Mapping[str, Path],
        release_root: Path,
    ) -> Mapping[str, Path]:
        wrappers: list[Path] = []
        for source in test_evidence_paths.values():
            lexical_wrapper = Path(source).parent.parent.parent
            wrapper = lexical_wrapper.resolve(strict=True)
            if wrapper not in wrappers:
                wrappers.append(wrapper)
        try:
            for wrapper in wrappers:
                self._write_outer_wrapper_manifest(wrapper)
                self._freeze_outer_wrapper(wrapper)
            return _copy_g06_test_evidence_set(
                test_evidence_paths=test_evidence_paths,
                release_root=release_root,
            )
        finally:
            for wrapper in wrappers:
                self._thaw_outer_wrapper(wrapper)

    def test_producer_rechecks_repository_state_before_passing_publication(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory(
            prefix="mirmir-g06-final-state-"
        ) as value:
            output = Path(value) / "source"
            runner = g06.G06VerificationRunner(
                repository_root=REPOSITORY_ROOT,
                output_root=output,
                run_id="g06-final-state",
                native_runtime_evidence_root=self.runtime_source,
                expected_native_runtime_manifest_file_sha256=(
                    self.runtime_manifest_file_sha256
                ),
                group_executors={
                    identifier: self._executor(identifier)
                    for identifier in REQUIRED_G06_TEST_EVIDENCE_IDS
                },
            )

            with mock.patch.object(
                orchestrator,
                "runtime_correction_repository_state",
                return_value=(self.repository_state, False),
            ), self.assertRaisesRegex(
                g06.G06VerificationError,
                "release semantics differ",
            ):
                runner.run()

            self.assertFalse((output / ".g06-final-state.partial").exists())
            self.assertFalse((output / "g06-final-state").exists())
            self.assertFalse((output / "g06-final-state.failed").exists())
            archives = list(output.glob("g06-final-state.failed-recovery-*"))
            self.assertEqual(len(archives), 1)
            self.assertEqual(
                len(list(archives[0].glob("g06-failure-recovery-*.json"))),
                1,
            )

    @staticmethod
    def _rewrite_document(
        path: Path,
        mutate: object,
        *,
        rehash: bool,
    ) -> None:
        document = dict(g06._read_json(path))
        mutate(document)
        if rehash:
            unhashed = dict(document)
            unhashed.pop("evidence_sha256", None)
            document["evidence_sha256"] = canonical_sha256(unhashed)
        path.write_bytes(canonical_json_bytes(document) + b"\n")

    @staticmethod
    def _rebind_file(
        document: dict[str, object],
        *,
        artifact_id: str,
        path: Path,
    ) -> None:
        payload = path.read_bytes()
        replacement = None
        for binding in document["artifacts"]:
            if binding["artifact_id"] == artifact_id:
                binding["sha256"] = hashlib.sha256(payload).hexdigest()
                binding["size_bytes"] = len(payload)
                replacement = dict(binding)
                break
        if replacement is None:
            raise AssertionError("test artifact binding is absent")
        for command in document["commands"]:
            if command["log_binding"]["artifact_id"] == artifact_id:
                command["log_binding"] = replacement
                break

    @staticmethod
    def _rebind_native_runtime_tree(
        document: dict[str, object],
        *,
        run_root: Path,
    ) -> None:
        artifact_id = "inputs/native-runtime-evidence"
        replacement = dict(
            g06._tree_binding(
                run_root / artifact_id,
                run_root=run_root,
                artifact_kind="native_runtime_evidence_input",
            )
        )
        for index, binding in enumerate(document["artifacts"]):
            if binding["artifact_id"] == artifact_id:
                document["artifacts"][index] = replacement
                break
        else:
            raise AssertionError("native runtime tree binding is absent")
        document["summary"]["native_runtime_evidence_input"] = replacement
        runtime_root = run_root / artifact_id
        manifest_path = runtime_root / "artifact-manifest.json"
        manifest_payload = manifest_path.read_bytes()
        manifest = g06._read_json(manifest_path)
        benchmark_record = next(
            (
                dict(record)
                for record in manifest.get("artifacts", [])
                if record.get("path") == "native-aggregate-benchmark.json"
            ),
            None,
        )
        if benchmark_record is not None:
            document["summary"]["native_runtime_source"] = {
                "repository_root": manifest.get("root"),
                "manifest_file_sha256": hashlib.sha256(
                    manifest_payload
                ).hexdigest(),
                "manifest_sha256": manifest.get("manifest_sha256"),
                "run_id": manifest.get("run_id"),
                "project_commit": manifest.get("project_commit"),
                "benchmark_record": benchmark_record,
                "manifest_schema": g06._repository_source_binding(
                    RUNTIME_MANIFEST_SCHEMA
                ),
            }

    def test_success_copies_each_json_and_its_complete_transitive_closure(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory(prefix="mirmir-g06-handoff-") as value:
            root = Path(value).resolve(strict=True)
            run_root, evidence_paths = self._make_run(root / "source")
            release = root / "release"
            release.mkdir()
            copied = self._consume_g06(
                test_evidence_paths=evidence_paths,
                release_root=release,
            )
            self.assertEqual(tuple(copied), REQUIRED_G06_TEST_EVIDENCE_IDS)
            primary_logs = {
                "python_calibration_full_suite": "python-unittest-discovery.log",
                "xcode_native_integration": "xcode-native-integration.log",
                "xcode_release_runtime": "xcode-release-build.log",
                "swiftlint": "swiftlint-version.log",
                "release_lock_unit_suite": "release-lock-unit-suite.log",
            }
            for identifier, destination in copied.items():
                self.assertEqual(
                    destination,
                    release / "test-evidence" / identifier,
                )
                self.assertTrue((destination / f"{identifier}.json").is_file())
                log_name = primary_logs[identifier]
                self.assertEqual(
                    (destination / "logs" / log_name).read_bytes(),
                    (run_root / "logs" / log_name).read_bytes(),
                )
                rebound = evidence_binding(
                    identifier=identifier,
                    root_id="release",
                    path=destination,
                    root=release,
                )
                self.assertEqual(rebound["kind"], "directory_tree")
            native = copied["xcode_native_integration"]
            self.assertEqual(
                (
                    native / "artifacts/native-integration.xcresult/Info.plist"
                ).read_bytes(),
                b"result-info\n",
            )
            python = copied["python_calibration_full_suite"]
            wrapper_manifest_payload = (
                run_root.parent.parent
                / orchestrator.G06_OUTER_WRAPPER_MANIFEST_NAME
            ).read_bytes()
            copied_wrapper_manifest = (
                python
                / orchestrator.G06_COPIED_OUTER_WRAPPER_MANIFEST_NAME
            )
            self.assertEqual(
                copied_wrapper_manifest.read_bytes(),
                wrapper_manifest_payload,
            )
            wrapper_binding = g06._read_json(
                python / orchestrator.G06_OUTER_WRAPPER_BINDING_NAME
            )
            self.assertEqual(
                wrapper_binding["sha256"],
                hashlib.sha256(wrapper_manifest_payload).hexdigest(),
            )
            self.assertEqual(
                wrapper_binding["size_bytes"],
                len(wrapper_manifest_payload),
            )
            self.assertEqual(
                wrapper_binding["copied_manifest_path"],
                (
                    "test-evidence/python_calibration_full_suite/"
                    f"{orchestrator.G06_COPIED_OUTER_WRAPPER_MANIFEST_NAME}"
                ),
            )
            self.assertEqual(
                wrapper_binding["manifest_sha256"],
                manifest_sha256(wrapper_binding),
            )
            self.assertEqual(
                (
                    python
                    / "inputs/native-runtime-evidence/"
                    "native-aggregate-benchmark.json"
                ).read_bytes(),
                (
                    run_root
                    / "inputs/native-runtime-evidence/"
                    "native-aggregate-benchmark.json"
                ).read_bytes(),
            )

    def test_handoff_rejects_release_product_executable_mode_loss(self) -> None:
        with tempfile.TemporaryDirectory(
            prefix="mirmir-g06-release-product-mode-loss-"
        ) as value:
            root = Path(value).resolve(strict=True)
            run_root, evidence_paths = self._make_run(root / "source")
            product = (
                run_root
                / "build/release-derived-data/Build/Products/Release/"
                "Mirmir.app/Contents/MacOS/Mirmir"
            )
            self.assertEqual(product.stat().st_mode & 0o111, 0o111)
            product.chmod(0o600)
            release = root / "release"
            release.mkdir()

            with self.assertRaisesRegex(
                P06ReleaseOrchestrationError,
                "artifact binding changed",
            ):
                self._consume_g06(
                    test_evidence_paths=evidence_paths,
                    release_root=release,
                )

    def test_outer_wrapper_requires_manifest_and_complete_sealing(self) -> None:
        with tempfile.TemporaryDirectory(
            prefix="mirmir-g06-missing-wrapper-manifest-"
        ) as value:
            root = Path(value)
            run_root, evidence_paths = self._make_run(root / "source")
            wrapper = run_root.parent.parent
            self._freeze_outer_wrapper(wrapper)
            release = root / "release"
            release.mkdir()
            try:
                with self.assertRaisesRegex(
                    P06ReleaseOrchestrationError,
                    "descriptor-relative file is absent",
                ):
                    _copy_g06_test_evidence_set(
                        test_evidence_paths=evidence_paths,
                        release_root=release,
                    )
            finally:
                self._thaw_outer_wrapper(wrapper)

        with tempfile.TemporaryDirectory(
            prefix="mirmir-g06-mutable-wrapper-"
        ) as value:
            root = Path(value)
            run_root, evidence_paths = self._make_run(root / "source")
            wrapper = run_root.parent.parent
            self._write_outer_wrapper_manifest(wrapper)
            release = root / "release"
            release.mkdir()
            with self.assertRaisesRegex(
                P06ReleaseOrchestrationError,
                "directory is not sealed",
            ):
                _copy_g06_test_evidence_set(
                    test_evidence_paths=evidence_paths,
                    release_root=release,
                )

    def test_outer_wrapper_rejects_manifest_closure_and_content_drift(
        self,
    ) -> None:
        cases = ("missing", "extra", "mutated")
        for case in cases:
            with self.subTest(case=case), tempfile.TemporaryDirectory(
                prefix=f"mirmir-g06-wrapper-{case}-"
            ) as value:
                root = Path(value)
                run_root, evidence_paths = self._make_run(root / "source")
                wrapper = run_root.parent.parent
                target = run_root / "logs/python-unittest-discovery.log"
                self._write_outer_wrapper_manifest(wrapper)
                if case == "missing":
                    target.unlink()
                elif case == "extra":
                    (run_root / "unbound-extra.bin").write_bytes(b"extra")
                else:
                    target.write_bytes(target.read_bytes() + b"mutated\n")
                self._freeze_outer_wrapper(wrapper)
                release = root / "release"
                release.mkdir()
                try:
                    with self.assertRaisesRegex(
                        P06ReleaseOrchestrationError,
                        (
                            "artifact manifest path closure differs"
                            if case != "mutated"
                            else "artifact binding differs"
                        ),
                    ):
                        _copy_g06_test_evidence_set(
                            test_evidence_paths=evidence_paths,
                            release_root=release,
                        )
                finally:
                    self._thaw_outer_wrapper(wrapper)

    def test_outer_wrapper_rejects_truthfully_manifested_unbound_empty_directory(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory(
            prefix="mirmir-g06-wrapper-unbound-empty-"
        ) as value:
            root = Path(value)
            run_root, evidence_paths = self._make_run(root / "source")
            wrapper = run_root.parent.parent
            (run_root / "post-g06-unbound-empty").mkdir()
            self._write_outer_wrapper_manifest(wrapper)
            self._freeze_outer_wrapper(wrapper)
            release = root / "release"
            release.mkdir()
            try:
                with self.assertRaisesRegex(
                    P06ReleaseOrchestrationError,
                    "artifact closure|foreign path",
                ):
                    _copy_g06_test_evidence_set(
                        test_evidence_paths=evidence_paths,
                        release_root=release,
                    )
            finally:
                self._thaw_outer_wrapper(wrapper)

    def test_outer_wrapper_rejects_wrong_project_commit(self) -> None:
        with tempfile.TemporaryDirectory(
            prefix="mirmir-g06-wrapper-wrong-commit-"
        ) as value:
            root = Path(value)
            run_root, evidence_paths = self._make_run(root / "source")
            wrapper = run_root.parent.parent
            self._write_outer_wrapper_manifest(wrapper)
            manifest_path = (
                wrapper / orchestrator.G06_OUTER_WRAPPER_MANIFEST_NAME
            )
            manifest = dict(g06._read_json(manifest_path))
            manifest["project_commit"] = "0" * 40
            manifest_path.write_bytes(canonical_json_bytes(manifest) + b"\n")
            self._freeze_outer_wrapper(wrapper)
            release = root / "release"
            release.mkdir()
            try:
                with self.assertRaisesRegex(
                    P06ReleaseOrchestrationError,
                    "project provenance differs",
                ):
                    _copy_g06_test_evidence_set(
                        test_evidence_paths=evidence_paths,
                        release_root=release,
                    )
            finally:
                self._thaw_outer_wrapper(wrapper)

    def test_outer_wrapper_rejects_invalid_transaction_timestamp(self) -> None:
        with tempfile.TemporaryDirectory(
            prefix="mirmir-g06-wrapper-invalid-transaction-time-"
        ) as value:
            root = Path(value)
            run_root, evidence_paths = self._make_run(root / "source")
            wrapper = run_root.parent.parent
            self._write_outer_wrapper_manifest(wrapper)
            transaction_path = (
                wrapper / orchestrator.G06_OUTER_WRAPPER_TRANSACTION_NAME
            )
            transaction = dict(g06._read_json(transaction_path))
            transaction["created_utc"] = "not-a-utc-timestamp"
            transaction_path.write_bytes(
                canonical_json_bytes(transaction) + b"\n"
            )
            self._freeze_outer_wrapper(wrapper)
            release = root / "release"
            release.mkdir()
            try:
                with self.assertRaisesRegex(
                    P06ReleaseOrchestrationError,
                    "transaction binding differs",
                ):
                    _copy_g06_test_evidence_set(
                        test_evidence_paths=evidence_paths,
                        release_root=release,
                    )
            finally:
                self._thaw_outer_wrapper(wrapper)

    def test_outer_wrapper_requires_canonical_manifest_and_exact_gate_ids(
        self,
    ) -> None:
        cases = ("noncanonical", "gate-order")
        for case in cases:
            with self.subTest(case=case), tempfile.TemporaryDirectory(
                prefix=f"mirmir-g06-wrapper-{case}-"
            ) as value:
                root = Path(value)
                run_root, evidence_paths = self._make_run(root / "source")
                wrapper = run_root.parent.parent
                self._write_outer_wrapper_manifest(wrapper)
                manifest_path = (
                    wrapper / orchestrator.G06_OUTER_WRAPPER_MANIFEST_NAME
                )
                manifest = dict(g06._read_json(manifest_path))
                if case == "noncanonical":
                    manifest_path.write_bytes(
                        b" " + canonical_json_bytes(manifest) + b"\n"
                    )
                    message = "artifact manifest is not canonical"
                else:
                    manifest["artifacts"][0]["gate_ids"] = ["P06", "G06"]
                    manifest_path.write_bytes(
                        canonical_json_bytes(manifest) + b"\n"
                    )
                    message = "artifact provenance differs"
                self._freeze_outer_wrapper(wrapper)
                release = root / "release"
                release.mkdir()
                try:
                    with self.assertRaisesRegex(
                        P06ReleaseOrchestrationError,
                        message,
                    ):
                        _copy_g06_test_evidence_set(
                            test_evidence_paths=evidence_paths,
                            release_root=release,
                        )
                finally:
                    self._thaw_outer_wrapper(wrapper)

    def test_outer_wrapper_rejects_symbolic_special_and_multilink_entries(
        self,
    ) -> None:
        cases = ("symlink", "special", "multilink")
        for case in cases:
            with self.subTest(case=case), tempfile.TemporaryDirectory(
                prefix=f"mirmir-g06-wrapper-{case}-"
            ) as value:
                root = Path(value)
                run_root, evidence_paths = self._make_run(root / "source")
                wrapper = run_root.parent.parent
                if case == "symlink":
                    target = run_root / "symbolic-target.bin"
                    target.write_bytes(b"target")
                    (run_root / "symbolic-entry.bin").symlink_to(target.name)
                elif case == "special":
                    os.mkfifo(run_root / "special-entry.pipe")
                else:
                    os.link(
                        run_root / "logs/python-unittest-discovery.log",
                        run_root / "multilink-entry.log",
                    )
                self._write_outer_wrapper_manifest(wrapper)
                self._freeze_outer_wrapper(wrapper)
                release = root / "release"
                release.mkdir()
                try:
                    with self.assertRaisesRegex(
                        P06ReleaseOrchestrationError,
                        "non-regular file",
                    ):
                        _copy_g06_test_evidence_set(
                            test_evidence_paths=evidence_paths,
                            release_root=release,
                        )
                finally:
                    self._thaw_outer_wrapper(wrapper)

    def test_outer_wrapper_accepts_only_its_sibling_partial_relocation(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory(
            prefix="mirmir-g06-wrapper-relocation-"
        ) as value:
            root = Path(value).resolve(strict=True)
            run_root, evidence_paths = self._make_run(root / "source")
            release = root / "release-valid"
            release.mkdir()
            copied = self._consume_g06(
                test_evidence_paths=evidence_paths,
                release_root=release,
            )
            self.assertEqual(tuple(copied), REQUIRED_G06_TEST_EVIDENCE_IDS)

            foreign_wrapper = root / "foreign"
            run_root.parent.parent.rename(foreign_wrapper)
            foreign_run = foreign_wrapper / "g06" / run_root.name
            foreign_paths = OrderedDict(
                (
                    identifier,
                    foreign_run / path.name,
                )
                for identifier, path in evidence_paths.items()
            )
            foreign_release = root / "release-foreign"
            foreign_release.mkdir()
            with self.assertRaisesRegex(
                P06ReleaseOrchestrationError,
                "execution path differs",
            ):
                self._consume_g06(
                    test_evidence_paths=foreign_paths,
                    release_root=foreign_release,
                )

    def test_outer_wrapper_rejects_the_legacy_direct_run_layout(self) -> None:
        with tempfile.TemporaryDirectory(
            prefix="mirmir-g06-wrapper-direct-root-"
        ) as value:
            root = Path(value).resolve(strict=True)
            run_root, evidence_paths = self._make_run(root / "source")
            direct_parent = root / "direct"
            direct_parent.mkdir()
            direct_run = direct_parent / run_root.name
            run_root.rename(direct_run)
            direct_paths = OrderedDict(
                (
                    identifier,
                    direct_run / path.name,
                )
                for identifier, path in evidence_paths.items()
            )
            release = root / "release"
            release.mkdir()
            with self.assertRaisesRegex(
                P06ReleaseOrchestrationError,
                "exact wrapper/g06/run tree",
            ):
                _copy_g06_test_evidence_set(
                    test_evidence_paths=direct_paths,
                    release_root=release,
                )

    def test_copy_uses_the_exact_json_payload_that_was_validated(self) -> None:
        with tempfile.TemporaryDirectory(
            prefix="mirmir-g06-single-read-json-"
        ) as value:
            root = Path(value)
            _, evidence_paths = self._make_run(root / "source")
            identifier = REQUIRED_G06_TEST_EVIDENCE_IDS[0]
            source = evidence_paths[identifier]
            validated_payload = source.read_bytes()
            mutated_payload = validated_payload.replace(
                b'"holdout_accessed":false',
                b'"holdout_accessed":0',
                1,
            )
            self.assertNotEqual(mutated_payload, validated_payload)
            release = root / "release"
            release.mkdir()
            destination = (
                release
                / "test-evidence"
                / identifier
                / f"{identifier}.json"
            )
            original_write_new = orchestrator._write_new
            source_mutation_blocked = False

            def mutate_before_copy(
                path: Path,
                payload: bytes,
                *,
                executable: bool = False,
            ) -> None:
                nonlocal source_mutation_blocked
                if path == destination and not source_mutation_blocked:
                    try:
                        source.write_bytes(mutated_payload)
                    except OSError:
                        source_mutation_blocked = True
                original_write_new(path, payload, executable=executable)

            with mock.patch.object(
                orchestrator,
                "_write_new",
                side_effect=mutate_before_copy,
            ):
                self._consume_g06(
                    test_evidence_paths=evidence_paths,
                    release_root=release,
                )

            self.assertTrue(source_mutation_blocked)
            self.assertEqual(source.read_bytes(), validated_payload)
            self.assertEqual(destination.read_bytes(), validated_payload)

    def test_directory_bindings_include_empty_directory_entries(self) -> None:
        with tempfile.TemporaryDirectory(
            prefix="mirmir-release-tree-binding-"
        ) as value:
            root = Path(value)
            tree = root / "tree"
            tree.mkdir()
            (tree / "payload.bin").write_bytes(b"payload")
            before = evidence_binding(
                identifier="tree",
                root_id="fixture",
                path=tree,
                root=root,
            )

            (tree / "empty").mkdir()
            after = evidence_binding(
                identifier="tree",
                root_id="fixture",
                path=tree,
                root=root,
            )

            self.assertEqual(before["file_count"], after["file_count"])
            self.assertEqual(before["size_bytes"], after["size_bytes"])
            self.assertNotEqual(before["sha256"], after["sha256"])

    def test_handoff_rejects_unbound_empty_directory(self) -> None:
        with tempfile.TemporaryDirectory(
            prefix="mirmir-g06-empty-directory-"
        ) as value:
            root = Path(value)
            run_root, evidence_paths = self._make_run(root / "source")
            (
                run_root
                / "inputs/native-runtime-evidence/unbound-empty-directory"
            ).mkdir()
            release = root / "release"
            release.mkdir()

            with self.assertRaisesRegex(
                P06ReleaseOrchestrationError,
                "artifact binding changed",
            ):
                self._consume_g06(
                    test_evidence_paths=evidence_paths,
                    release_root=release,
                )

    def test_rejects_failed_forged_or_schema_invalid_evidence(self) -> None:
        cases = (
            (
                "failed",
                lambda document: document.update(
                    {"status": "failed", "failure_reason": "deliberate failure"}
                ),
                True,
                "passing status",
            ),
            (
                "forged",
                lambda document: document["summary"].update({"forged": True}),
                False,
                "self-hash",
            ),
            (
                "schema",
                lambda document: document.update({"holdout_accessed": True}),
                True,
                "schema validation",
            ),
        )
        for name, mutate, rehash, message in cases:
            with self.subTest(name=name), tempfile.TemporaryDirectory(
                prefix=f"mirmir-g06-{name}-"
            ) as value:
                root = Path(value)
                _, evidence_paths = self._make_run(root / "source")
                target = evidence_paths[REQUIRED_G06_TEST_EVIDENCE_IDS[0]]
                self._rewrite_document(target, mutate, rehash=rehash)
                release = root / "release"
                release.mkdir()
                with self.assertRaisesRegex(P06ReleaseOrchestrationError, message):
                    self._consume_g06(
                        test_evidence_paths=evidence_paths,
                        release_root=release,
                    )

    def test_rejects_self_hashed_pass_claim_over_authentic_failing_log(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mirmir-g06-false-pass-") as value:
            root = Path(value)
            run_root, evidence_paths = self._make_run(root / "source")
            identifier = "python_calibration_full_suite"
            log = run_root / "logs/python-unittest-discovery.log"
            log.write_bytes(
                b"Ran 2 tests in 0.1s\n\nFAILED (failures=1)\n"
            )

            def mutate(document: dict[str, object]) -> None:
                self._rebind_file(
                    document,
                    artifact_id="logs/python-unittest-discovery.log",
                    path=log,
                )

            self._rewrite_document(
                evidence_paths[identifier],
                mutate,
                rehash=True,
            )
            release = root / "release"
            release.mkdir()
            with self.assertRaisesRegex(
                P06ReleaseOrchestrationError,
                "unittest log",
            ):
                self._consume_g06(
                    test_evidence_paths=evidence_paths,
                    release_root=release,
                )

    def test_rejects_non_utf8_command_log(self) -> None:
        with tempfile.TemporaryDirectory(
            prefix="mirmir-g06-non-utf8-log-"
        ) as value:
            root = Path(value)
            run_root, evidence_paths = self._make_run(root / "source")
            identifier = "python_calibration_full_suite"
            log = run_root / "logs/python-unittest-discovery.log"
            log.write_bytes(b"Ran 2 tests in 0.1s\n\nOK\n\xff")

            def mutate(document: dict[str, object]) -> None:
                self._rebind_file(
                    document,
                    artifact_id="logs/python-unittest-discovery.log",
                    path=log,
                )

            self._rewrite_document(
                evidence_paths[identifier],
                mutate,
                rehash=True,
            )
            release = root / "release"
            release.mkdir()
            with self.assertRaisesRegex(
                P06ReleaseOrchestrationError,
                "strict UTF-8",
            ):
                self._consume_g06(
                    test_evidence_paths=evidence_paths,
                    release_root=release,
                )

    def test_rejects_self_hashed_group_summary_and_release_warning_forgery(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory(prefix="mirmir-g06-summary-") as value:
            root = Path(value)
            _, evidence_paths = self._make_run(root / "source")

            def mutate_summary(document: dict[str, object]) -> None:
                document["summary"]["configuration"] = "Release"

            self._rewrite_document(
                evidence_paths["xcode_native_integration"],
                mutate_summary,
                rehash=True,
            )
            release = root / "release"
            release.mkdir()
            with self.assertRaisesRegex(P06ReleaseOrchestrationError, "summary"):
                self._consume_g06(
                    test_evidence_paths=evidence_paths,
                    release_root=release,
                )

        with tempfile.TemporaryDirectory(prefix="mirmir-g06-warning-") as value:
            root = Path(value)
            run_root, evidence_paths = self._make_run(root / "source")
            log = run_root / "logs/xcode-release-build.log"
            log.write_bytes(
                b"** BUILD SUCCEEDED **\nfile.swift:1: warning: forged warning\n"
            )

            def mutate_warning(document: dict[str, object]) -> None:
                self._rebind_file(
                    document,
                    artifact_id="logs/xcode-release-build.log",
                    path=log,
                )

            self._rewrite_document(
                evidence_paths["xcode_release_runtime"],
                mutate_warning,
                rehash=True,
            )
            release = root / "release"
            release.mkdir()
            with self.assertRaisesRegex(
                P06ReleaseOrchestrationError,
                "zero-warning",
            ):
                self._consume_g06(
                    test_evidence_paths=evidence_paths,
                    release_root=release,
                )

    def test_rejects_boolean_alias_for_numeric_summary_field(self) -> None:
        with tempfile.TemporaryDirectory(
            prefix="mirmir-g06-summary-type-alias-"
        ) as value:
            root = Path(value)
            _, evidence_paths = self._make_run(root / "source")
            target = evidence_paths["python_calibration_full_suite"]

            def mutate(document: dict[str, object]) -> None:
                document["summary"]["runners"][0]["counts"]["failed"] = False

            self._rewrite_document(target, mutate, rehash=True)
            release = root / "release"
            release.mkdir()
            with self.assertRaisesRegex(
                P06ReleaseOrchestrationError,
                "Python summary differs",
            ):
                self._consume_g06(
                    test_evidence_paths=evidence_paths,
                    release_root=release,
                )

    def test_rejects_self_hashed_verifier_source_substitution(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mirmir-g06-source-") as value:
            root = Path(value)
            _, evidence_paths = self._make_run(root / "source")

            def mutate(document: dict[str, object]) -> None:
                document["verifier_source"]["sha256"] = "0" * 64

            self._rewrite_document(
                evidence_paths["python_calibration_full_suite"],
                mutate,
                rehash=True,
            )
            release = root / "release"
            release.mkdir()
            with self.assertRaisesRegex(
                P06ReleaseOrchestrationError,
                "verifier source",
            ):
                self._consume_g06(
                    test_evidence_paths=evidence_paths,
                    release_root=release,
                )

    def test_rejects_self_hashed_runner_order_and_release_lock_modules(self) -> None:
        cases = (
            (
                "runner-order",
                "python_calibration_full_suite",
                lambda document: document["summary"].update(
                    {"required_runner_order": ["pytest", "unittest_discovery"]}
                ),
                "Python summary",
            ),
            (
                "release-modules",
                "release_lock_unit_suite",
                lambda document: document["summary"].update(
                    {"modules": ["validation.calibration_v2.tests.test_release_lock"]}
                ),
                "release-lock summary",
            ),
        )
        for name, identifier, mutate, message in cases:
            with self.subTest(name=name), tempfile.TemporaryDirectory(
                prefix=f"mirmir-g06-{name}-"
            ) as value:
                root = Path(value)
                _, evidence_paths = self._make_run(root / "source")
                self._rewrite_document(
                    evidence_paths[identifier],
                    mutate,
                    rehash=True,
                )
                release = root / "release"
                release.mkdir()
                with self.assertRaisesRegex(P06ReleaseOrchestrationError, message):
                    self._consume_g06(
                        test_evidence_paths=evidence_paths,
                        release_root=release,
                    )

    def test_rejects_self_hashed_native_runtime_artifact_substitution(self) -> None:
        for mode in ("missing", "wrong-kind"):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory(
                prefix=f"mirmir-g06-native-artifact-{mode}-"
            ) as value:
                root = Path(value)
                _, evidence_paths = self._make_run(root / "source")
                target = evidence_paths["python_calibration_full_suite"]

                def mutate(document: dict[str, object]) -> None:
                    if mode == "missing":
                        del document["artifacts"][3]
                    else:
                        binding = document["artifacts"][3]
                        binding["artifact_kind"] = "xcresult"
                        document["summary"][
                            "native_runtime_evidence_input"
                        ] = dict(binding)

                self._rewrite_document(target, mutate, rehash=True)
                release = root / "release"
                release.mkdir()
                with self.assertRaisesRegex(
                    P06ReleaseOrchestrationError,
                    "artifact closure",
                ):
                    self._consume_g06(
                        test_evidence_paths=evidence_paths,
                        release_root=release,
                    )

    def test_rejects_self_hashed_native_runtime_command_substitution(self) -> None:
        cases = (
            (
                "addopts",
                1,
                (
                    "PYTEST_ADDOPTS=--ignore=validation/calibration_v2/tests/"
                    "test_control_aggregate_native_benchmark.py"
                ),
            ),
            ("plugin-autoload", 2, "PYTEST_DISABLE_PLUGIN_AUTOLOAD=0"),
            ("plugins", 3, "PYTEST_PLUGINS=substituted_plugin"),
            ("python-home", 4, "PYTHONHOME=/tmp/substituted"),
            ("python-optimize", 5, "PYTHONOPTIMIZE=2"),
            ("python-path", 6, "PYTHONPATH=/tmp/substituted"),
            (
                "legacy-output",
                7,
                "MIRMIR_AGGREGATE_BENCHMARK_OUTPUT=/tmp/substituted.json",
            ),
            ("opt-in", 8, "MIRMIR_RUN_NATIVE_AGGREGATE_BENCHMARK=0"),
            (
                "output",
                9,
                (
                    "MIRMIR_NATIVE_AGGREGATE_BENCHMARK_OUTPUT=/tmp/inputs/"
                    "native-runtime-evidence/native-aggregate-benchmark.json"
                ),
            ),
            ("python", 10, "/usr/local/bin/python3"),
            ("pytest-config", 14, "/tmp/substituted-pytest.ini"),
            ("cache-provider", 16, "cacheprovider"),
            ("conftest", 17, "--confcutdir=/tmp"),
        )
        for name, index, replacement in cases:
            with self.subTest(name=name), tempfile.TemporaryDirectory(
                prefix=f"mirmir-g06-native-command-{name}-"
            ) as value:
                root = Path(value)
                _, evidence_paths = self._make_run(root / "source")
                target = evidence_paths["python_calibration_full_suite"]

                def mutate(document: dict[str, object]) -> None:
                    command = document["commands"][1]
                    command["argv"][index] = replacement
                    command["command_text"] = shlex.join(command["argv"])

                self._rewrite_document(target, mutate, rehash=True)
                release = root / "release"
                release.mkdir()
                with self.assertRaisesRegex(
                    P06ReleaseOrchestrationError,
                    "command contract",
                ):
                    self._consume_g06(
                        test_evidence_paths=evidence_paths,
                        release_root=release,
                    )

    def test_rejects_native_benchmark_proof_target_substitution(self) -> None:
        with tempfile.TemporaryDirectory(
            prefix="mirmir-g06-native-proof-command-"
        ) as value:
            root = Path(value)
            _, evidence_paths = self._make_run(root / "source")
            target = evidence_paths["python_calibration_full_suite"]

            def mutate(document: dict[str, object]) -> None:
                command = document["commands"][2]
                command["argv"][-1] = (
                    "validation/calibration_v2/tests/"
                    "test_control_aggregate_native_benchmark.py"
                )
                command["command_text"] = shlex.join(command["argv"])

            self._rewrite_document(target, mutate, rehash=True)
            release = root / "release"
            release.mkdir()
            with self.assertRaisesRegex(
                P06ReleaseOrchestrationError,
                "command contract",
            ):
                self._consume_g06(
                    test_evidence_paths=evidence_paths,
                    release_root=release,
                )

    def test_rejects_external_and_alias_xcode_transaction_paths(self) -> None:
        cases = (
            (
                "external-derived",
                "xcode_native_integration",
                0,
                10,
                Path("/tmp/build/native-integration-derived-data"),
            ),
            (
                "alias-result",
                "xcode_release_runtime",
                1,
                12,
                None,
            ),
        )
        for name, identifier, command_index, argv_index, replacement in cases:
            with self.subTest(name=name), tempfile.TemporaryDirectory(
                prefix=f"mirmir-g06-xcode-path-{name}-"
            ) as value:
                root = Path(value).resolve(strict=True)
                _, evidence_paths = self._make_run(root / "source")
                if replacement is None:
                    alias = root / "source-alias"
                    alias.symlink_to(root / "source", target_is_directory=True)
                    replacement = (
                        alias
                        / ".g06-pass.partial/artifacts/"
                        "release-runtime.xcresult"
                    )
                target = evidence_paths[identifier]

                def mutate(document: dict[str, object]) -> None:
                    command = document["commands"][command_index]
                    command["argv"][argv_index] = str(replacement)
                    command["command_text"] = shlex.join(command["argv"])

                self._rewrite_document(target, mutate, rehash=True)
                release = root / "release"
                release.mkdir()
                with self.assertRaisesRegex(
                    P06ReleaseOrchestrationError,
                    "command contract",
                ):
                    self._consume_g06(
                        test_evidence_paths=evidence_paths,
                        release_root=release,
                    )

    def test_rejects_lexical_symlink_alias_for_native_runtime_output(self) -> None:
        with tempfile.TemporaryDirectory(
            prefix="mirmir-g06-native-command-alias-"
        ) as value:
            root = Path(value).resolve(strict=True)
            _, evidence_paths = self._make_run(root / "source")
            alias = root / "source-alias"
            alias.symlink_to(root / "source", target_is_directory=True)
            target = evidence_paths["python_calibration_full_suite"]

            def mutate(document: dict[str, object]) -> None:
                command = document["commands"][1]
                command["argv"][9] = (
                    "MIRMIR_NATIVE_AGGREGATE_BENCHMARK_OUTPUT="
                    f"{alias}/.g06-pass.partial/inputs/native-runtime-evidence/"
                    "native-aggregate-benchmark.json"
                )
                command["command_text"] = shlex.join(command["argv"])

            self._rewrite_document(target, mutate, rehash=True)
            release = root / "release"
            release.mkdir()
            with self.assertRaisesRegex(
                P06ReleaseOrchestrationError,
                "command contract",
            ):
                self._consume_g06(
                    test_evidence_paths=evidence_paths,
                    release_root=release,
                )

    def test_rejects_rebound_native_runtime_tree_and_content_tampering(
        self,
    ) -> None:
        cases = (
            ("manifest", "closure validation"),
            ("schema", "closure validation"),
            ("benchmark", "closure validation"),
            ("gates", "closure validation"),
            ("tree", "closure validation"),
            ("project", "closure validation"),
        )
        for mode, message in cases:
            with self.subTest(mode=mode), tempfile.TemporaryDirectory(
                prefix=f"mirmir-g06-native-tree-{mode}-"
            ) as value:
                root = Path(value)
                run_root, evidence_paths = self._make_run(root / "source")
                runtime_root = run_root / "inputs/native-runtime-evidence"
                manifest_path = runtime_root / "artifact-manifest.json"
                if mode == "benchmark":
                    (runtime_root / "native-aggregate-benchmark.json").write_bytes(
                        b"tampered benchmark\n"
                    )
                elif mode == "tree":
                    (runtime_root / "unrecorded.txt").write_bytes(b"unrecorded\n")
                else:
                    manifest = dict(g06._read_json(manifest_path))
                    if mode == "manifest":
                        manifest["manifest_sha256"] = "0" * 64
                    elif mode == "schema":
                        manifest.pop("created_utc")
                        manifest["manifest_sha256"] = manifest_sha256(manifest)
                    elif mode == "gates":
                        manifest["artifacts"] = [
                            dict(record) for record in manifest["artifacts"]
                        ]
                        benchmark_record = next(
                            record
                            for record in manifest["artifacts"]
                            if record["path"]
                            == "native-aggregate-benchmark.json"
                        )
                        benchmark_record["gate_ids"] = ["P06"]
                        manifest["manifest_sha256"] = manifest_sha256(manifest)
                    else:
                        manifest["repository_state"] = dict(
                            manifest["repository_state"]
                        )
                        manifest["repository_state"]["project_commit"] = "c" * 40
                        manifest["manifest_sha256"] = manifest_sha256(manifest)
                    manifest_path.write_bytes(
                        canonical_json_bytes(manifest) + b"\n"
                    )

                target = evidence_paths["python_calibration_full_suite"]

                def mutate(document: dict[str, object]) -> None:
                    self._rebind_native_runtime_tree(
                        document,
                        run_root=run_root,
                    )

                self._rewrite_document(target, mutate, rehash=True)
                release = root / "release"
                release.mkdir()
                with self.assertRaisesRegex(P06ReleaseOrchestrationError, message):
                    self._consume_g06(
                        test_evidence_paths=evidence_paths,
                        release_root=release,
                    )

    def test_rejects_coordinated_native_runtime_provenance_forgery(self) -> None:
        cases = (
            ("invalid-benchmark", "benchmark"),
            ("run-linkage", "finalized provenance"),
            ("schema-path", "schema binding"),
            ("schema-sha256", "schema binding"),
            ("schema-size", "schema binding"),
            ("binding-statement", "finalized provenance"),
            ("project", "manifest provenance"),
            ("producer", "benchmark record"),
            ("gate-order", "benchmark record"),
        )
        for mode, message in cases:
            with self.subTest(mode=mode), tempfile.TemporaryDirectory(
                prefix=f"mirmir-g06-native-coordinated-{mode}-"
            ) as value:
                root = Path(value)
                run_root, evidence_paths = self._make_run(root / "source")
                runtime_root = run_root / "inputs/native-runtime-evidence"
                manifest_path = runtime_root / "artifact-manifest.json"
                metadata_path = runtime_root / "artifact-records.json"
                benchmark_path = runtime_root / "native-aggregate-benchmark.json"
                manifest = dict(g06._read_json(manifest_path))
                manifest["artifacts"] = [
                    dict(record) for record in manifest["artifacts"]
                ]
                metadata = dict(g06._read_json(metadata_path))
                metadata["records"] = [
                    dict(record) for record in metadata["records"]
                ]
                benchmark = dict(g06._read_json(benchmark_path))

                if mode == "invalid-benchmark":
                    benchmark = {"fixture": "substituted"}
                    benchmark["evidence_sha256"] = canonical_sha256(benchmark)
                elif mode == "run-linkage":
                    benchmark["run_identity"] = dict(
                        benchmark["run_identity"]
                    )
                    benchmark["run_identity"]["run_id"] = (
                        "00000000-0000-4000-8000-000000000002"
                    )
                elif mode.startswith("schema-"):
                    benchmark["schema_binding"] = dict(
                        benchmark["schema_binding"]
                    )
                    if mode == "schema-path":
                        benchmark["schema_binding"]["path"] = (
                            "validation/calibration_v2/schemas/substituted.json"
                        )
                    elif mode == "schema-sha256":
                        benchmark["schema_binding"]["sha256"] = "0" * 64
                    else:
                        benchmark["schema_binding"]["size_bytes"] = 1
                elif mode == "binding-statement":
                    benchmark["run_identity"] = dict(
                        benchmark["run_identity"]
                    )
                    final_bundle_linkage = dict(
                        benchmark["run_identity"]["final_bundle_linkage"]
                    )
                    final_bundle_linkage["required_binding"] = (
                        "substituted schema-valid binding"
                    )
                    benchmark["run_identity"]["final_bundle_linkage"] = (
                        final_bundle_linkage
                    )
                elif mode == "project":
                    project_commit = "c" * 40
                    manifest["project_commit"] = project_commit
                    state = dict(manifest["repository_state"])
                    state["project_commit"] = project_commit
                    dirty_document = {
                        "algorithm": state["algorithm"],
                        "artifact_pathspec_exclusion": state[
                            "artifact_pathspec_exclusion"
                        ],
                        "project_commit": project_commit,
                        "tracked_diff_sha256": state["tracked_diff_sha256"],
                        "tracked_diff_size_bytes": 0,
                        "ordered_untracked_files": [],
                    }
                    state["dirty_state_sha256"] = canonical_sha256(
                        dirty_document
                    )
                    manifest["dirty_state_sha256"] = state[
                        "dirty_state_sha256"
                    ]
                    manifest["repository_state"] = state
                    benchmark["run_identity"] = dict(
                        benchmark["run_identity"]
                    )
                    benchmark_repository_state = dict(
                        benchmark["run_identity"]["repository_state"]
                    )
                    benchmark_repository_state["head_commit"] = project_commit
                    benchmark["run_identity"]["repository_state"] = (
                        benchmark_repository_state
                    )
                else:
                    benchmark_manifest_record = next(
                        record
                        for record in manifest["artifacts"]
                        if record["path"]
                        == "native-aggregate-benchmark.json"
                    )
                    benchmark_metadata_record = next(
                        record
                        for record in metadata["records"]
                        if record["path"]
                        == "native-aggregate-benchmark.json"
                    )
                    if mode == "producer":
                        benchmark_manifest_record["producer"] = "substituted"
                        benchmark_metadata_record["producer"] = "substituted"
                    else:
                        benchmark_manifest_record["gate_ids"] = ["G06", "P06"]
                        benchmark_metadata_record["gate_ids"] = ["G06", "P06"]

                schema_valid_benchmark_modes = {
                    "run-linkage",
                    "schema-path",
                    "schema-sha256",
                    "schema-size",
                    "binding-statement",
                    "project",
                }
                if mode in schema_valid_benchmark_modes:
                    benchmark.pop("evidence_sha256", None)
                    benchmark["evidence_sha256"] = canonical_sha256(benchmark)
                    g06.validate_schema(benchmark, BENCHMARK_SCHEMA_PATH)
                benchmark_payload = canonical_json_bytes(benchmark) + b"\n"
                benchmark_path.write_bytes(benchmark_payload)
                metadata_payload = canonical_json_bytes(metadata) + b"\n"
                metadata_path.write_bytes(metadata_payload)
                for record in manifest["artifacts"]:
                    artifact_path = runtime_root / str(record["path"])
                    payload = artifact_path.read_bytes()
                    record["sha256"] = hashlib.sha256(payload).hexdigest()
                    record["size_bytes"] = len(payload)
                manifest.pop("manifest_sha256", None)
                manifest["manifest_sha256"] = manifest_sha256(manifest)
                manifest_path.write_bytes(canonical_json_bytes(manifest) + b"\n")

                target = evidence_paths["python_calibration_full_suite"]

                def mutate(document: dict[str, object]) -> None:
                    self._rebind_native_runtime_tree(
                        document,
                        run_root=run_root,
                    )

                self._rewrite_document(target, mutate, rehash=True)
                release = root / "release"
                release.mkdir()
                with self.assertRaisesRegex(P06ReleaseOrchestrationError, message):
                    self._consume_g06(
                        test_evidence_paths=evidence_paths,
                        release_root=release,
                    )

    def test_rejects_self_hashed_native_runtime_summary_substitution(self) -> None:
        for mode in ("tree-binding", "source-provenance"):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory(
                prefix=f"mirmir-g06-native-summary-{mode}-"
            ) as value:
                root = Path(value)
                _, evidence_paths = self._make_run(root / "source")
                target = evidence_paths["python_calibration_full_suite"]

                def mutate(document: dict[str, object]) -> None:
                    if mode == "tree-binding":
                        document["summary"]["native_runtime_evidence_input"][
                            "sha256"
                        ] = "0" * 64
                    else:
                        document["summary"]["native_runtime_source"][
                            "repository_root"
                        ] = "Artifacts/ASH/substituted"

                self._rewrite_document(target, mutate, rehash=True)
                release = root / "release"
                release.mkdir()
                with self.assertRaisesRegex(
                    P06ReleaseOrchestrationError,
                    "Python summary",
                ):
                    self._consume_g06(
                        test_evidence_paths=evidence_paths,
                        release_root=release,
                    )

    def test_rejects_missing_tampered_and_symbolic_artifacts(self) -> None:
        for mode in ("missing", "tampered", "symbolic", "symbolic_parent"):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory(
                prefix=f"mirmir-g06-{mode}-"
            ) as value:
                root = Path(value)
                run_root, evidence_paths = self._make_run(root / "source")
                identifier = REQUIRED_G06_TEST_EVIDENCE_IDS[0]
                log = run_root / "logs/python-unittest-discovery.log"
                if mode == "missing":
                    log.unlink()
                elif mode == "tampered":
                    log.write_bytes(b"tampered\n")
                else:
                    if mode == "symbolic":
                        outside = root / "outside.log"
                        outside.write_bytes(b"outside\n")
                        log.unlink()
                        log.symlink_to(outside)
                    else:
                        real_logs = run_root / "real-logs"
                        (run_root / "logs").rename(real_logs)
                        (run_root / "logs").symlink_to(
                            real_logs,
                            target_is_directory=True,
                        )
                release = root / "release"
                release.mkdir()
                with self.assertRaises(P06ReleaseOrchestrationError):
                    self._consume_g06(
                        test_evidence_paths=evidence_paths,
                        release_root=release,
                    )

    def test_rejects_path_escape_and_overlapping_artifact_paths(self) -> None:
        cases = (
            ("escape", "../outside.log", "unsafe"),
            (
                "overlap",
                "logs/python-pytest.log/child",
                "overlap",
            ),
        )
        for name, replacement, message in cases:
            with self.subTest(name=name), tempfile.TemporaryDirectory(
                prefix=f"mirmir-g06-{name}-"
            ) as value:
                root = Path(value)
                _, evidence_paths = self._make_run(root / "source")
                identifier = REQUIRED_G06_TEST_EVIDENCE_IDS[0]

                def mutate(document: dict[str, object]) -> None:
                    artifact = document["artifacts"][0]
                    artifact["artifact_id"] = replacement
                    document["commands"][0]["log_binding"] = dict(artifact)

                self._rewrite_document(
                    evidence_paths[identifier],
                    mutate,
                    rehash=True,
                )
                release = root / "release"
                release.mkdir()
                with self.assertRaisesRegex(P06ReleaseOrchestrationError, message):
                    self._consume_g06(
                        test_evidence_paths=evidence_paths,
                        release_root=release,
                    )

    def test_rejects_wrong_order_mixed_roots_and_extra_root_json(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mirmir-g06-order-") as value:
            root = Path(value)
            _, evidence_paths = self._make_run(root / "source")
            release = root / "release"
            release.mkdir()
            reversed_paths = OrderedDict(reversed(tuple(evidence_paths.items())))
            with self.assertRaisesRegex(P06ReleaseOrchestrationError, "set or order"):
                self._consume_g06(
                    test_evidence_paths=reversed_paths,
                    release_root=release,
                )

        with tempfile.TemporaryDirectory(prefix="mirmir-g06-roots-") as value:
            root = Path(value)
            _, evidence_paths = self._make_run(root / "source-a")
            _, other_paths = self._make_run(root / "source-b")
            mixed = OrderedDict(evidence_paths)
            last = REQUIRED_G06_TEST_EVIDENCE_IDS[-1]
            mixed[last] = other_paths[last]
            release = root / "release"
            release.mkdir()
            with self.assertRaisesRegex(P06ReleaseOrchestrationError, "one run root"):
                self._consume_g06(
                    test_evidence_paths=mixed,
                    release_root=release,
                )

        with tempfile.TemporaryDirectory(prefix="mirmir-g06-extra-") as value:
            root = Path(value)
            run_root, evidence_paths = self._make_run(root / "source")
            (run_root / "unexpected.json").write_text("{}\n", encoding="utf-8")
            release = root / "release"
            release.mkdir()
            with self.assertRaisesRegex(P06ReleaseOrchestrationError, "JSON set"):
                self._consume_g06(
                    test_evidence_paths=evidence_paths,
                    release_root=release,
                )

    def test_rejects_symlink_in_any_run_root_ancestor(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mirmir-g06-ancestor-") as value:
            root = Path(value).resolve(strict=True)
            _, evidence_paths = self._make_run(root / "source")
            alias = root / "source-alias"
            alias.symlink_to(root / "source", target_is_directory=True)
            linked_paths = OrderedDict(
                (
                    identifier,
                    alias / "g06" / "g06-pass" / path.name,
                )
                for identifier, path in evidence_paths.items()
            )
            release = root / "release"
            release.mkdir()
            with self.assertRaisesRegex(
                P06ReleaseOrchestrationError,
                "symbolic ancestor",
            ):
                self._consume_g06(
                    test_evidence_paths=linked_paths,
                    release_root=release,
                )

        with tempfile.TemporaryDirectory(prefix="mirmir-g06-json-link-") as value:
            root = Path(value).resolve(strict=True)
            _, evidence_paths = self._make_run(root / "source")
            identifier = "python_calibration_full_suite"
            source = evidence_paths[identifier]
            real_source = source.with_suffix(".evidence")
            source.rename(real_source)
            source.symlink_to(real_source)
            release = root / "release"
            release.mkdir()
            with self.assertRaisesRegex(
                P06ReleaseOrchestrationError,
                "not a regular file",
            ):
                self._consume_g06(
                    test_evidence_paths=evidence_paths,
                    release_root=release,
                )


if __name__ == "__main__":
    unittest.main()
