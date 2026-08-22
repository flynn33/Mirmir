#!/usr/bin/env python3
"""Unit tests for P06 clean-build evidence helpers."""

from __future__ import annotations

import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


SCRIPT_DIRECTORY = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location(
    "capture_p06_reproduction_v4",
    SCRIPT_DIRECTORY / "capture_p06_reproduction_v4.py",
)
assert SPEC is not None and SPEC.loader is not None
capture = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(capture)


class P06ReproductionCaptureTests(unittest.TestCase):
    def test_v2_contract_pins_current_capture_tools(self) -> None:
        contract = json.loads(
            (SCRIPT_DIRECTORY / "p06-reproduction-contract-v2.json").read_text(
                encoding="utf-8"
            )
        )
        expected = {
            "buildRunnerSHA256": SCRIPT_DIRECTORY / "build_p06_release_runtime.sh",
            "captureSourceSHA256": SCRIPT_DIRECTORY / "capture_p06_reproduction_v4.py",
            "evaluatorSHA256": SCRIPT_DIRECTORY / "p06_reproduction_v4.py",
            "runnerSHA256": SCRIPT_DIRECTORY / "run_p06_reproduction_v4.sh",
            "runtimeLoadCheckRunnerSHA256": SCRIPT_DIRECTORY
            / "run_p06_runtime_load_check.sh",
            "runtimeLoadCheckSourceSHA256": SCRIPT_DIRECTORY
            / "P06RuntimeLoadCheckMain.swift",
            "sourceIdentityToolSHA256": SCRIPT_DIRECTORY / "p06_source_identity_v4.py",
            "sourceProvenanceContractSHA256": SCRIPT_DIRECTORY
            / "p06-source-provenance-v1.json",
        }
        self.assertEqual(set(contract["capture"]), set(expected))
        for key, path in expected.items():
            self.assertEqual(contract["capture"][key], capture.sha256(path), key)

    def test_artifact_set_is_order_independent_and_path_sensitive(self) -> None:
        first = capture.artifact_set_sha([("b", "2" * 64), ("a", "1" * 64)])
        second = capture.artifact_set_sha([("a", "1" * 64), ("b", "2" * 64)])
        moved = capture.artifact_set_sha([("a", "1" * 64), ("c", "2" * 64)])
        self.assertEqual(first, second)
        self.assertNotEqual(first, moved)

    def test_source_tree_identity_changes_with_committed_bytes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            repository = Path(temporary)
            subprocess.run(["git", "init", "-q"], cwd=repository, check=True)
            subprocess.run(["git", "config", "user.name", "P06 Test"], cwd=repository, check=True)
            subprocess.run(
                ["git", "config", "user.email", "p06-test@example.invalid"],
                cwd=repository,
                check=True,
            )
            source = repository / "source.txt"
            source.write_text("first\n", encoding="utf-8")
            subprocess.run(["git", "add", "source.txt"], cwd=repository, check=True)
            subprocess.run(["git", "commit", "-qm", "first"], cwd=repository, check=True)
            first_commit = subprocess.check_output(
                ["git", "rev-parse", "HEAD"], cwd=repository, text=True
            ).strip()
            first = capture.source_tree_identity(repository, first_commit)
            source.write_text("second\n", encoding="utf-8")
            subprocess.run(["git", "commit", "-qam", "second"], cwd=repository, check=True)
            second_commit = subprocess.check_output(
                ["git", "rev-parse", "HEAD"], cwd=repository, text=True
            ).strip()
            second = capture.source_tree_identity(repository, second_commit)
            self.assertRegex(first, r"^[0-9a-f]{64}$")
            self.assertNotEqual(first, second)

    def test_candidate_parser_rejects_missing_identity(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "candidate.json"
            path.write_text(json.dumps({"sourceCommit": "a" * 40}), encoding="utf-8")
            with self.assertRaisesRegex(capture.CaptureError, "field set mismatch"):
                capture.parse_candidate(path)

    def test_runner_preserves_command_search_path_after_input_validation(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            repository = root / "repository"
            runtime = root / "runtime"
            executable_directory = root / "bin"
            repository.mkdir()
            runtime.mkdir()
            executable_directory.mkdir()
            repository_runner = (
                repository / "script" / "v4" / "run_p06_reproduction_v4.sh"
            )
            repository_runner.parent.mkdir(parents=True)
            shutil.copy2(
                SCRIPT_DIRECTORY / "run_p06_reproduction_v4.sh",
                repository_runner,
            )
            candidate = root / "candidate.json"
            configuration = root / "Release.xcconfig"
            contract = root / "contract.json"
            for required_file in (candidate, configuration, contract):
                required_file.write_text("{}", encoding="utf-8")

            invocation_log = root / "python-invocations.txt"
            fake_python = executable_directory / "python3"
            fake_python.write_text(
                "#!/bin/sh\n"
                "printf '%s\\n' \"$*\" >> \"$P06_RUNNER_CALLS\"\n",
                encoding="utf-8",
            )
            fake_python.chmod(0o755)
            result = subprocess.run(
                [
                    "/bin/zsh",
                    str(repository_runner),
                    "--repository",
                    str(repository),
                    "--candidate",
                    str(candidate),
                    "--runtime",
                    str(runtime),
                    "--release-configuration",
                    str(configuration),
                    "--output",
                    str(root / "evidence"),
                    "--contract",
                    str(contract),
                ],
                check=False,
                capture_output=True,
                text=True,
                env={
                    **os.environ,
                    "PATH": f"{executable_directory}:/usr/bin:/bin",
                    "P06_RUNNER_CALLS": str(invocation_log),
                },
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            invocations = invocation_log.read_text(encoding="utf-8").splitlines()
            self.assertEqual(len(invocations), 2)
            self.assertIn("capture_p06_reproduction_v4.py", invocations[0])
            self.assertIn(f"--contract {contract.resolve()}", invocations[0])
            self.assertIn("p06_reproduction_v4.py verify", invocations[1])

            exported_runner = root / "exported-runner.sh"
            exported_runner.write_bytes(
                repository_runner.read_bytes() + b"\n# modified exported copy\n"
            )
            exported_result = subprocess.run(
                [
                    "/bin/zsh",
                    str(exported_runner),
                    "--repository",
                    str(repository),
                    "--candidate",
                    str(candidate),
                    "--runtime",
                    str(runtime),
                    "--release-configuration",
                    str(configuration),
                    "--output",
                    str(root / "other-evidence"),
                    "--contract",
                    str(contract),
                ],
                check=False,
                capture_output=True,
                text=True,
                env={
                    **os.environ,
                    "PATH": f"{executable_directory}:/usr/bin:/bin",
                    "P06_RUNNER_CALLS": str(invocation_log),
                },
            )
            self.assertEqual(exported_result.returncode, 66)
            self.assertIn(
                "executing P06 runner differs",
                exported_result.stderr,
            )


if __name__ == "__main__":
    unittest.main()
