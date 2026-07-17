from __future__ import annotations

import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock

from validation.calibration_v2 import current_source_gate_closure_v2 as gates
from validation.calibration_v2.tools import run_p07_locked_holdout as runner
from validation.quality.src.mirmir_quality.holdout import (
    HoldoutAccessError,
    P06V3HoldoutAccessGuard,
    V3_CONFIGURATION_FILE_ORDER,
    initialize_holdout_access_ledger,
)
from validation.quality.src.mirmir_quality.json_tools import canonical_sha256


def _sha(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


class P07V3GuardRunnerTests(unittest.TestCase):
    def _guard_fixture(
        self,
        root: Path,
    ) -> tuple[P06V3HoldoutAccessGuard, dict[str, object], Path, Path]:
        release = root / "release"
        ledger_root = root / "ledger"
        anchor_root = root / "anchor"
        release.mkdir()
        ledger_root.mkdir()
        anchor_root.mkdir()
        rows = []
        for identifier, filename in V3_CONFIGURATION_FILE_ORDER:
            payload = f"{identifier}-bytes\n".encode("utf-8")
            (release / filename).write_bytes(payload)
            rows.append(
                {
                    "id": identifier,
                    "path": filename,
                    "sha256": _sha(payload),
                    "size_bytes": len(payload),
                }
            )
        corpus_sha256 = _sha(b"corpus")
        ledger = ledger_root / "ledger.json"
        anchor = anchor_root / "anchor.json"
        initialize_holdout_access_ledger(
            ledger,
            corpus_sha256,
            created_utc="2026-01-01T00:00:00Z",
            anchor_path=anchor,
        )
        configuration = {
            "schema_version": "2.0.0",
            "artifact_kind": "p06_configuration_lock_v2",
            "status": "locked_before_p07",
            "locked_utc": "2026-01-01T00:00:00Z",
            "configuration_id": "ash-p06-0123456789abcdef01234567",
            "candidate_vector_sha256": _sha(b"candidate"),
            "shared_bank_configuration_sha256": _sha(b"bank"),
            "calibration_selection": {
                "path": "calibration-selection-v2.json",
                "sha256": _sha(b"selection"),
                "size_bytes": 1,
            },
            "selected_evaluation": {
                "path": "evaluations/{}.json".format(_sha(b"candidate")),
                "sha256": _sha(b"evaluation"),
                "size_bytes": 1,
            },
            "configuration_files": rows,
            "candidate_bytes_rewritten_after_selection": False,
            "holdout_accessed": False,
        }
        configuration["manifest_sha256"] = canonical_sha256(configuration)
        (release / "configuration-lock-v2.json").write_text(
            json.dumps(configuration, sort_keys=True, separators=(",", ":")) + "\n",
            encoding="utf-8",
        )
        guard = P06V3HoldoutAccessGuard(
            corpus_sha256,
            ledger_path=ledger,
            anchor_path=anchor,
            release_root=release,
        )
        return guard, configuration, release, anchor

    def test_v3_guard_reopens_exact_ordered_configuration_files(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            guard, configuration, release, anchor = self._guard_fixture(
                Path(temporary)
            )
            guard.validate_lock(configuration)
            self.assertFalse(anchor.exists())
            (release / "locked-compiler-input-v2.json").write_bytes(b"changed\n")
            with self.assertRaisesRegex(
                HoldoutAccessError,
                "configuration lock release validation failed",
            ):
                guard.validate_lock(configuration)
            self.assertFalse(anchor.exists())

    def test_v3_guard_rejects_legacy_filename_alias_before_intent(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            guard, configuration, _, anchor = self._guard_fixture(Path(temporary))
            configuration["configuration_files"][4]["path"] = (
                "locked-compiler-input.json"
            )
            configuration["manifest_sha256"] = canonical_sha256(
                {
                    key: value
                    for key, value in configuration.items()
                    if key != "manifest_sha256"
                }
            )
            with self.assertRaisesRegex(HoldoutAccessError, "schema validation failed"):
                guard.validate_lock(configuration)
            self.assertFalse(anchor.exists())

    def test_runner_requires_manifest_bound_configuration_lock_v2_name(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            release = root / "release"
            release.mkdir()
            manifest = release / "p06-release-bundle.json"
            bundle = {
                "artifacts": [
                    {
                        "id": "configuration_lock",
                        "path": "configuration-lock.json",
                        "sha256": _sha(b"legacy"),
                        "size_bytes": 6,
                    }
                ]
            }
            manifest.write_text(json.dumps(bundle), encoding="utf-8")
            expected = _sha(b"bundle")
            with mock.patch.object(
                runner,
                "p06_release_bundle_sha256",
                return_value=expected,
            ), self.assertRaisesRegex(ValueError, "binding is not exact"):
                runner._read_v3_configuration_lock(
                    release_root=release,
                    release_manifest_path=manifest,
                    expected_release_manifest_sha256=expected,
                )

    def test_fresh_gate_reopen_matches_actual_semantics_and_tree(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            repository = root / "repository"
            release = root / "release"
            repository.mkdir()
            release.mkdir()
            (release / "source-gates").mkdir()
            source_commit = "a" * 40
            gate_roots = {}
            semantics = {}
            for gate_id in ("G04", "G05", "G06"):
                gate_root = root / gate_id
                gate_root.mkdir()
                (gate_root / "evidence.json").write_text(gate_id, encoding="utf-8")
                gate_roots[gate_id] = gate_root
                semantic = {
                    "gate_id": gate_id,
                    "source_commit": source_commit,
                    "working_tree_clean": True,
                    "holdout_accessed": False,
                }
                semantics[gate_id] = semantic
                receipt = {
                    "schema_version": "2.0.0",
                    "artifact_kind": "p06_current_source_gate_receipt_v2",
                    "gate_id": gate_id,
                    "status": "pass",
                    "source_commit": source_commit,
                    "working_tree_clean": True,
                    "holdout_accessed": False,
                    "semantic_reopen": semantic,
                    "gate_tree": gates._tree_binding(gate_root),
                }
                (release / "source-gates" / f"{gate_id}.json").write_text(
                    json.dumps(receipt, sort_keys=True, separators=(",", ":")) + "\n",
                    encoding="utf-8",
                )
            instruction = root / "instructions"
            instruction.mkdir()
            g06 = mock.Mock()
            g06.verify_published_release_evidence.return_value = semantics["G06"]
            with mock.patch.object(
                gates,
                "current_source_git_identity_v2",
                return_value=(source_commit, b""),
            ), mock.patch.object(
                gates,
                "reopen_finalized_g04_current_source",
                return_value=semantics["G04"],
            ) as g04_reopen, mock.patch.object(
                gates,
                "reopen_finalized_g05_current_source",
                return_value=semantics["G05"],
            ) as g05_reopen, mock.patch.object(
                gates,
                "G06VerificationRunner",
                return_value=g06,
            ):
                result = gates.reopen_staged_current_source_gate_receipts_v2(
                    repository_root=repository,
                    release_root=release,
                    g04_root=gate_roots["G04"],
                    g05_root=gate_roots["G05"],
                    g05_instruction_package_root=instruction,
                    g05_baseline_commit="b" * 40,
                    g06_root=gate_roots["G06"],
                    g06_execution_run_name="execution",
                )
                (gate_roots["G04"] / "post-seal.json").write_text(
                    "changed",
                    encoding="utf-8",
                )
                with self.assertRaisesRegex(
                    ValueError,
                    "fresh semantics or gate tree differ from P06",
                ):
                    gates.reopen_staged_current_source_gate_receipts_v2(
                        repository_root=repository,
                        release_root=release,
                        g04_root=gate_roots["G04"],
                        g05_root=gate_roots["G05"],
                        g05_instruction_package_root=instruction,
                        g05_baseline_commit="b" * 40,
                        g06_root=gate_roots["G06"],
                        g06_execution_run_name="execution",
                    )
            self.assertEqual(result["status"], "pass")
            self.assertEqual(g04_reopen.call_count, 2)
            self.assertEqual(g05_reopen.call_count, 2)
            self.assertEqual(g06.verify_published_release_evidence.call_count, 2)

    def test_startup_failure_archive_rejects_foreign_collision(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "p07-result"
            target = runner._publish_startup_nonopening_failure(
                output_directory=output,
                error=ValueError("configuration unavailable"),
            )
            document = json.loads(target.read_text(encoding="utf-8"))
            self.assertEqual(document["status"], "failed_before_holdout_intent")
            self.assertFalse(document["holdout_intent_recorded"])
            self.assertFalse(document["holdout_accessed"])
            self.assertEqual(
                document["manifest_sha256"],
                canonical_sha256(
                    {
                        key: value
                        for key, value in document.items()
                        if key != "manifest_sha256"
                    }
                ),
            )
            (target.parent / "foreign").write_text("foreign", encoding="utf-8")
            with self.assertRaisesRegex(RuntimeError, "foreign state"):
                runner._publish_startup_nonopening_failure(
                    output_directory=output,
                    error=ValueError("configuration unavailable"),
                )


if __name__ == "__main__":
    unittest.main()
