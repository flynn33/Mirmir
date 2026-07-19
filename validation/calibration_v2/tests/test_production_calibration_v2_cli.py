from __future__ import annotations

import ast
from contextlib import redirect_stderr, redirect_stdout
import io
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

from validation.calibration_v2.tools import run_p06_production_calibration_v2 as cli


REPOSITORY_ROOT = Path(__file__).resolve().parents[3]
SCRIPT = (
    REPOSITORY_ROOT
    / "validation/calibration_v2/tools/run_p06_production_calibration_v2.py"
)


class ProductionCalibrationV2CLIRetirementTests(unittest.TestCase):
    def test_imported_main_fails_closed_without_parsing_or_side_effects(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            stdout = io.StringIO()
            stderr = io.StringIO()
            with mock.patch.object(
                cli,
                "_arguments",
                side_effect=AssertionError("argument parsing was reached"),
            ), redirect_stdout(stdout), redirect_stderr(stderr):
                status = cli.main()

            self.assertEqual(status, 2)
            self.assertEqual(stdout.getvalue(), "")
            self.assertEqual(stderr.getvalue(), "")
            self.assertEqual(tuple(root.iterdir()), ())

    def test_executable_exits_before_imports_paths_and_outputs(self) -> None:
        self._assert_executable_guard_precedes_imports()
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            result = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    "--repository-root",
                    str(root / "missing-repository"),
                    "--calibration-output-root",
                    str(root / "calibration-output"),
                    "--release-root",
                    str(root / "release-output"),
                    "--live-ledger-path",
                    str(root / "ledger.json"),
                ],
                cwd=root,
                env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"},
                check=False,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )

            self.assertEqual(result.returncode, 2)
            self.assertEqual(result.stdout, b"")
            self.assertEqual(result.stderr, b"")
            self.assertEqual(tuple(root.iterdir()), ())

    def _assert_executable_guard_precedes_imports(self) -> None:
        module = ast.parse(SCRIPT.read_text(encoding="utf-8"), filename=str(SCRIPT))
        imports = [
            node
            for node in module.body
            if isinstance(node, (ast.Import, ast.ImportFrom))
            and not (
                isinstance(node, ast.ImportFrom)
                and node.module == "__future__"
            )
        ]
        guards = [node for node in module.body if isinstance(node, ast.If)]
        self.assertTrue(imports)
        self.assertTrue(guards)
        self.assertLess(guards[0].lineno, min(node.lineno for node in imports))
        self.assertEqual(len(guards[0].body), 1)
        self.assertIsInstance(guards[0].body[0], ast.Raise)


if __name__ == "__main__":
    unittest.main()
