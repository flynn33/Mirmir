from __future__ import annotations

import copy
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from jsonschema import Draft202012Validator, ValidationError

from validation.calibration_v2.tools.verify_p06_v1_terminal_failure_analysis import (
    BOUNDED_PREDECESSOR_RELATIVE,
    EXPECTED_ARCHIVE,
    EXPECTED_BOUNDED_PREDECESSOR,
    EXPECTED_TERMINAL_ANALYSIS,
    EXPECTED_TERMINAL_FINDINGS,
    RECEIPT_RELATIVE,
    SCHEMA_RELATIVE,
    TERMINAL_ANALYSIS_RELATIVE,
    TerminalFailureVerificationError,
    _arguments,
    _observed_tree_binding,
    verify_fast,
)
from validation.quality.src.mirmir_quality.json_tools import canonical_json_bytes


REPOSITORY_ROOT = Path(__file__).resolve().parents[3]
VERIFIER_PATH = (
    REPOSITORY_ROOT
    / "validation/calibration_v2/tools/verify_p06_v1_terminal_failure_analysis.py"
)


class P06V1TerminalFailureAnalysisReceiptTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.receipt_path = REPOSITORY_ROOT / RECEIPT_RELATIVE
        cls.schema_path = REPOSITORY_ROOT / SCHEMA_RELATIVE
        cls.terminal_analysis_path = REPOSITORY_ROOT / TERMINAL_ANALYSIS_RELATIVE
        cls.predecessor_path = REPOSITORY_ROOT / BOUNDED_PREDECESSOR_RELATIVE
        cls.raw_receipt = cls.receipt_path.read_bytes()
        cls.receipt = json.loads(cls.raw_receipt)
        cls.schema = json.loads(cls.schema_path.read_text(encoding="utf-8"))
        cls.validator = Draft202012Validator(cls.schema)

    def _write_mutated_receipt(self, root: Path, value: dict[str, object]) -> Path:
        body = copy.deepcopy(value)
        body.pop("receipt_sha256", None)
        body["receipt_sha256"] = hashlib.sha256(canonical_json_bytes(body)).hexdigest()
        destination = root / "mutated-receipt.json"
        destination.write_bytes(canonical_json_bytes(body) + b"\n")
        return destination

    def test_schema_canonical_bytes_self_hash_and_no_absolute_user_path(self) -> None:
        Draft202012Validator.check_schema(self.schema)
        self.validator.validate(self.receipt)
        self.assertEqual(
            self.raw_receipt,
            canonical_json_bytes(self.receipt) + b"\n",
        )
        body = dict(self.receipt)
        observed = body.pop("receipt_sha256")
        self.assertEqual(
            observed,
            hashlib.sha256(canonical_json_bytes(body)).hexdigest(),
        )
        self.assertNotIn(b"/Users/", self.raw_receipt)

    def test_fast_mode_verifies_exact_tracked_artifacts(self) -> None:
        result = verify_fast(REPOSITORY_ROOT)
        self.assertEqual(result["mode"], "fast_tracked_artifacts")
        self.assertEqual(result["status"], "pass")
        self.assertEqual(
            result["receipt_sha256"],
            "835c28df94ac4ebfd76ed6897584f2d009547c277b5a28e6c15acf574c91f85e",
        )
        self.assertEqual(
            result["receipt_file_sha256"],
            "3fd58e93c53331d0a3ccd1fef255cdc61f62087e1614e204de6a74db4424cd55",
        )
        self.assertEqual(
            result["terminal_analysis_file_sha256"],
            EXPECTED_TERMINAL_ANALYSIS["file_sha256"],
        )
        self.assertEqual(
            result["bounded_predecessor_file_sha256"],
            EXPECTED_BOUNDED_PREDECESSOR["file_sha256"],
        )

    def test_direct_script_entry_point_is_cwd_and_pythonpath_independent(self) -> None:
        environment = dict(os.environ)
        environment.pop("PYTHONPATH", None)
        completed = subprocess.run(
            [
                sys.executable,
                str(VERIFIER_PATH),
                "--repository-root",
                str(REPOSITORY_ROOT),
            ],
            cwd="/",
            env=environment,
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        result = json.loads(completed.stdout)
        self.assertEqual(result["mode"], "fast_tracked_artifacts")
        self.assertEqual(result["status"], "pass")

    def test_receipt_preserves_exact_terminal_supplement_and_archive_binding(self) -> None:
        self.assertEqual(self.receipt["terminal_analysis"], EXPECTED_TERMINAL_ANALYSIS)
        self.assertEqual(self.receipt["bounded_predecessor"], EXPECTED_BOUNDED_PREDECESSOR)
        self.assertEqual(self.receipt["terminal_archive"], EXPECTED_ARCHIVE)
        self.assertEqual(self.receipt["terminal_findings"], EXPECTED_TERMINAL_FINDINGS)
        self.assertEqual(
            self.receipt["terminal_archive"]["tree"],
            {
                "digest_mode": "p06_release_evidence_directory_tree_v1",
                "sha256": "5d1f22b2467a5caa83b5b7b499389e6577d244721af466c57989d23513b22d76",
                "size_bytes": 3_340_628_824,
                "file_count": 818,
                "directory_count": 3,
            },
        )
        self.assertEqual(
            self.receipt["terminal_findings"]["search"]["selected_moves_by_sweep"],
            [23, 11, 5, 3, 2, 0],
        )
        self.assertFalse(
            self.receipt["terminal_findings"]["binary_associations"][
                "causal_interpretation_allowed"
            ]
        )

    def test_self_consistently_rehashed_semantic_mutation_is_rejected(self) -> None:
        altered = copy.deepcopy(self.receipt)
        altered["terminal_findings"]["status_counts"]["infeasible"] = 922
        with tempfile.TemporaryDirectory() as temporary:
            path = self._write_mutated_receipt(Path(temporary), altered)
            with self.assertRaisesRegex(
                TerminalFailureVerificationError,
                "terminal findings differ",
            ):
                verify_fast(REPOSITORY_ROOT, path)

    def test_schema_rejects_prohibited_claim_path_expansion_and_extra_fields(self) -> None:
        altered = copy.deepcopy(self.receipt)
        altered["claims"]["release_authorized"] = True
        with self.assertRaises(ValidationError):
            self.validator.validate(altered)

        altered = copy.deepcopy(self.receipt)
        altered["terminal_archive"]["root_path"] = "/tmp/p06-current-source-r1.failed"
        with self.assertRaises(ValidationError):
            self.validator.validate(altered)

        altered = copy.deepcopy(self.receipt)
        altered["unbounded_claim"] = True
        with self.assertRaises(ValidationError):
            self.validator.validate(altered)

    def test_failed_root_mode_requires_an_explicit_argument(self) -> None:
        self.assertIsNone(_arguments([]).failed_root)
        explicit = _arguments(["--failed-root", "/tmp/synthetic.failed"])
        self.assertEqual(explicit.failed_root, Path("/tmp/synthetic.failed"))

    def test_synthetic_tree_uses_exact_closure_walk_order(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "tree"
            (root / "a-dir").mkdir(parents=True)
            (root / "b-dir").mkdir()
            (root / "root.txt").write_bytes(b"root\n")
            (root / "a-dir" / "a.txt").write_bytes(b"alpha\n")
            (root / "b-dir" / "z.txt").write_bytes(b"zeta\n")
            rows = [
                {"path": "a-dir", "entry_kind": "directory", "size_bytes": 0},
                {"path": "b-dir", "entry_kind": "directory", "size_bytes": 0},
                {
                    "path": "root.txt",
                    "entry_kind": "regular_file",
                    "sha256": hashlib.sha256(b"root\n").hexdigest(),
                    "size_bytes": 5,
                },
                {
                    "path": "a-dir/a.txt",
                    "entry_kind": "regular_file",
                    "sha256": hashlib.sha256(b"alpha\n").hexdigest(),
                    "size_bytes": 6,
                },
                {
                    "path": "b-dir/z.txt",
                    "entry_kind": "regular_file",
                    "sha256": hashlib.sha256(b"zeta\n").hexdigest(),
                    "size_bytes": 5,
                },
            ]
            observed = _observed_tree_binding(root)
            self.assertEqual(observed["file_count"], 3)
            self.assertEqual(observed["directory_count"], 2)
            self.assertEqual(observed["size_bytes"], 16)
            self.assertEqual(
                observed["sha256"],
                hashlib.sha256(canonical_json_bytes(rows)).hexdigest(),
            )

    def test_synthetic_tree_digest_detects_content_mutation(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "tree"
            root.mkdir()
            artifact = root / "artifact.json"
            artifact.write_bytes(b"one\n")
            before = _observed_tree_binding(root)
            artifact.write_bytes(b"two\n")
            after = _observed_tree_binding(root)
            self.assertNotEqual(before["sha256"], after["sha256"])
            self.assertEqual(before["size_bytes"], after["size_bytes"])

    @unittest.skipUnless(hasattr(os, "symlink"), "symbolic links are unavailable")
    def test_synthetic_tree_rejects_symbolic_file(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "tree"
            root.mkdir()
            target = Path(temporary) / "outside.json"
            target.write_bytes(b"outside\n")
            os.symlink(target, root / "linked.json")
            with self.assertRaisesRegex(
                TerminalFailureVerificationError,
                "failed tree digest could not be derived",
            ):
                _observed_tree_binding(root)


if __name__ == "__main__":
    unittest.main()
