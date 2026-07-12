from __future__ import annotations

from collections import OrderedDict
import hashlib
from pathlib import Path
import shlex
import tempfile
import unittest

from validation.calibration_v2.release_evidence import evidence_binding
from validation.calibration_v2.release_orchestrator import (
    P06ReleaseOrchestrationError,
    REQUIRED_G06_TEST_EVIDENCE_IDS,
    _copy_g06_test_evidence_set,
)
from validation.calibration_v2.tools import run_g06_verification as g06
from validation.quality.src.mirmir_quality.json_tools import (
    canonical_json_bytes,
    canonical_sha256,
)


REPOSITORY_ROOT = Path(__file__).resolve().parents[3]


class G06ReleaseEvidenceHandoffTests(unittest.TestCase):
    @staticmethod
    def _executor(identifier: str) -> object:
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
                first, first_binding = command(
                    1,
                    [
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
                        "/usr/bin/python3",
                        "-m",
                        "pytest",
                        "-q",
                        "validation/calibration_v2/tests",
                    ],
                    "logs/python-pytest.log",
                    pytest_log,
                )
                commands = [first, second]
                artifacts = [first_binding, second_binding]
                counts = (
                    g06.parse_unittest_output(unittest_log.decode()),
                    g06.parse_pytest_output(pytest_log.decode()),
                )
                summary = {
                    "runners": [
                        {"runner": runner, "counts": result}
                        for runner, result in zip(
                            ("unittest_discovery", "pytest"),
                            counts,
                        )
                    ],
                    "aggregate_executed_test_count": 5,
                    "required_runner_order": ["unittest_discovery", "pytest"],
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
        executors = {
            identifier: self._executor(identifier)
            for identifier in REQUIRED_G06_TEST_EVIDENCE_IDS
        }
        result = g06.G06VerificationRunner(
            repository_root=REPOSITORY_ROOT,
            output_root=root,
            run_id="g06-pass",
            group_executors=executors,
        ).run()
        self.assertEqual(result.status, "passed")
        return (
            result.path.resolve(strict=True),
            OrderedDict(
                (identifier, path.resolve(strict=True))
                for identifier, path in result.evidence_paths
            ),
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

    def test_success_copies_each_json_and_its_complete_transitive_closure(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory(prefix="mirmir-g06-handoff-") as value:
            root = Path(value)
            run_root, evidence_paths = self._make_run(root / "source")
            release = root / "release"
            release.mkdir()
            copied = _copy_g06_test_evidence_set(
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
                    _copy_g06_test_evidence_set(
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
                _copy_g06_test_evidence_set(
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
                _copy_g06_test_evidence_set(
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
                _copy_g06_test_evidence_set(
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
                _copy_g06_test_evidence_set(
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
                    _copy_g06_test_evidence_set(
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
                    _copy_g06_test_evidence_set(
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
                    _copy_g06_test_evidence_set(
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
                _copy_g06_test_evidence_set(
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
                _copy_g06_test_evidence_set(
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
                _copy_g06_test_evidence_set(
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
                    alias / "g06-pass" / path.name,
                )
                for identifier, path in evidence_paths.items()
            )
            release = root / "release"
            release.mkdir()
            with self.assertRaisesRegex(
                P06ReleaseOrchestrationError,
                "symbolic ancestor",
            ):
                _copy_g06_test_evidence_set(
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
                _copy_g06_test_evidence_set(
                    test_evidence_paths=evidence_paths,
                    release_root=release,
                )


if __name__ == "__main__":
    unittest.main()
