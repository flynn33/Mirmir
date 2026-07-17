from __future__ import annotations

import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock

from validation.calibration_v2 import current_source_gate_closure_v2 as closure
from validation.calibration_v2.calibration_persistence_v2 import (
    canonical_json_file_bytes_v2,
)


SOURCE_COMMIT = "1" * 40
CHANGED_COMMIT = "2" * 40


class CurrentSourceGateClosureV2Tests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(
            prefix="mirmir-current-source-closure-v2-"
        )
        self.root = Path(self.temporary.name).resolve(strict=True)
        self.repository = self.root / "repository"
        self.artifact_root = self.root / "calibration" / "run"
        self.gate_roots = {
            gate_id: self.root / gate_id.lower()
            for gate_id in ("G04", "G05", "G06")
        }
        self.repository.mkdir()
        self.artifact_root.mkdir(parents=True)
        for gate_id, gate_root in self.gate_roots.items():
            gate_root.mkdir()
            (gate_root / "evidence.txt").write_text(
                f"{gate_id} evidence\n",
                encoding="utf-8",
            )

    def tearDown(self) -> None:
        self.temporary.cleanup()

    @staticmethod
    def _semantic(gate_id: str, *, source_commit: str = SOURCE_COMMIT):
        return {
            "gate_id": gate_id,
            "status": "pass",
            "source_commit": source_commit,
            "working_tree_clean": True,
            "holdout_accessed": False,
        }

    def _stage_patches(
        self,
        *,
        identities: tuple[tuple[str, bytes], ...] = (
            (SOURCE_COMMIT, b""),
            (SOURCE_COMMIT, b""),
        ),
        g04: dict[str, object] | None = None,
        g05: dict[str, object] | None = None,
        g06: dict[str, object] | None = None,
    ):
        runner = mock.Mock()
        runner.verify_published_release_evidence.return_value = (
            g06 or self._semantic("G06")
        )
        return (
            mock.patch.object(
                closure,
                "current_source_git_identity_v2",
                side_effect=identities,
            ),
            mock.patch.object(
                closure,
                "reopen_finalized_g04_current_source",
                return_value=g04 or self._semantic("G04"),
            ),
            mock.patch.object(
                closure,
                "reopen_finalized_g05_current_source",
                return_value=g05 or self._semantic("G05"),
            ),
            mock.patch.object(
                closure,
                "G06VerificationRunner",
                return_value=runner,
            ),
        )

    def _stage(self):
        return closure.reopen_and_stage_current_source_gates_v2(
            repository_root=self.repository,
            artifact_root=self.artifact_root,
            g04_root=self.gate_roots["G04"],
            g05_root=self.gate_roots["G05"],
            g05_instruction_package_root=self.root / "instructions",
            g05_baseline_commit="3" * 40,
            g06_root=self.gate_roots["G06"],
            g06_execution_run_name="execution",
        )

    def test_stages_exact_gate_order_and_canonical_receipts(self) -> None:
        patches = self._stage_patches()
        with patches[0], patches[1], patches[2], patches[3]:
            gates = self._stage()

        self.assertEqual(
            tuple(gate.gate_id for gate in gates),
            ("G04", "G05", "G06"),
        )
        for gate in gates:
            path = self.artifact_root / gate.binding.path
            payload = path.read_bytes()
            document = json.loads(payload)
            self.assertEqual(payload, canonical_json_file_bytes_v2(document))
            self.assertEqual(document["gate_id"], gate.gate_id)
            self.assertEqual(document["source_commit"], SOURCE_COMMIT)
            self.assertEqual(document["semantic_reopen"]["gate_id"], gate.gate_id)
            self.assertFalse(document["holdout_accessed"])

    def test_dirty_working_tree_is_rejected_before_gate_reopen(self) -> None:
        with mock.patch.object(
            closure,
            "current_source_git_identity_v2",
            return_value=(SOURCE_COMMIT, b" M tracked.swift\0"),
        ), mock.patch.object(
            closure,
            "reopen_finalized_g04_current_source",
        ) as reopen, self.assertRaisesRegex(
            closure.CurrentSourceGateClosureV2Error,
            "not clean",
        ):
            self._stage()
        reopen.assert_not_called()

    def test_semantic_source_commit_mismatch_is_rejected(self) -> None:
        patches = self._stage_patches(
            g05=self._semantic("G05", source_commit=CHANGED_COMMIT)
        )
        with patches[0], patches[1], patches[2], patches[3], self.assertRaisesRegex(
            closure.CurrentSourceGateClosureV2Error,
            "G05 semantic result",
        ):
            self._stage()

    def test_source_drift_during_reopen_is_rejected(self) -> None:
        patches = self._stage_patches(
            identities=(
                (SOURCE_COMMIT, b""),
                (CHANGED_COMMIT, b""),
            )
        )
        with patches[0], patches[1], patches[2], patches[3], self.assertRaisesRegex(
            closure.CurrentSourceGateClosureV2Error,
            "changed during gate reopening",
        ):
            self._stage()

    def test_staged_projection_rejects_receipt_mutation_and_wrong_order(self) -> None:
        patches = self._stage_patches()
        with patches[0], patches[1], patches[2], patches[3]:
            self._stage()

        release = self.root / "release"
        (release / "source-gates").mkdir(parents=True)
        for gate_id in ("G04", "G05", "G06"):
            source = self.artifact_root / "source-gates" / f"{gate_id}.json"
            (release / "source-gates" / f"{gate_id}.json").write_bytes(
                source.read_bytes()
            )
        g05_path = release / "source-gates/G05.json"
        g05 = json.loads(g05_path.read_bytes())
        g05["gate_id"] = "G06"
        g05_path.write_bytes(canonical_json_file_bytes_v2(g05))

        with mock.patch.object(
            closure,
            "current_source_git_identity_v2",
            return_value=(SOURCE_COMMIT, b""),
        ), self.assertRaisesRegex(
            closure.CurrentSourceGateClosureV2Error,
            "G05 staged source-gate receipt",
        ):
            closure.staged_current_source_gate_receipt_projection_v2(
                repository_root=self.repository,
                release_root=release,
            )


if __name__ == "__main__":
    unittest.main()
