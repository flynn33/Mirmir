from __future__ import annotations

import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPOSITORY_ROOT / "Scripts"))

from r00_inventory import InventoryVerifier, render_inventory  # noqa: E402


class R00InventoryTests(unittest.TestCase):
    def setUp(self) -> None:
        self.inventory_path = (
            REPOSITORY_ROOT
            / "docs/roadmaps/evidence/r00-current-source-inventory.json"
        )
        self.inventory = json.loads(self.inventory_path.read_text(encoding="utf-8"))
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.temp_root = Path(self.temporary_directory.name)

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def verifier_for(self, inventory: dict[str, object]) -> InventoryVerifier:
        inventory_path = self.temp_root / "inventory.json"
        markdown_path = self.temp_root / "inventory.md"
        inventory_path.write_text(
            json.dumps(inventory, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        markdown_path.write_text(render_inventory(inventory), encoding="utf-8")
        return InventoryVerifier(
            REPOSITORY_ROOT,
            inventory_path=inventory_path,
            markdown_path=markdown_path,
        )

    def assert_error_contains(
        self, inventory: dict[str, object], fragment: str
    ) -> None:
        errors = self.verifier_for(inventory).check()
        self.assertTrue(
            any(fragment in error for error in errors),
            f"expected error containing {fragment!r}; found {errors!r}",
        )

    def test_repository_inventory_is_valid(self) -> None:
        verifier = InventoryVerifier(REPOSITORY_ROOT)
        self.assertEqual(verifier.check(), [])

    def test_missing_c01_c11_entry_fails(self) -> None:
        self.inventory["entries"] = self.inventory["entries"][:-1]
        self.assert_error_contains(self.inventory, "entry IDs/order")

    def test_altered_source_path_fails(self) -> None:
        self.inventory["entries"][0]["sources"][0]["path"] = "missing/project.yml"
        self.assert_error_contains(self.inventory, "path is absent at source checkpoint")

    def test_altered_baseline_source_path_fails(self) -> None:
        self.inventory["entries"][0]["baseline_sources"][0]["path"] = (
            "missing/project.yml"
        )
        self.assert_error_contains(self.inventory, "path is absent at baseline checkpoint")

    def test_altered_baseline_source_identity_fails(self) -> None:
        self.inventory["entries"][0]["baseline_sources"][0]["git_object_id"] = (
            "0" * 40
        )
        self.assert_error_contains(self.inventory, "baseline Git object ID differs")

    def test_missing_baseline_source_fails(self) -> None:
        self.inventory["entries"][0]["baseline_sources"].pop()
        self.assert_error_contains(self.inventory, "baseline source inventory hash differs")

    def test_altered_source_object_id_fails(self) -> None:
        self.inventory["entries"][0]["sources"][0]["git_object_id"] = "0" * 40
        self.assert_error_contains(self.inventory, "source Git object ID differs")

    def test_future_candidate_source_changes_do_not_rewrite_checkpoint(self) -> None:
        verifier = self.verifier_for(self.inventory)
        original_git = verifier.git
        checkpoint = self.inventory["source_checkpoint"]

        def simulated_git(*arguments: str) -> subprocess.CompletedProcess[str]:
            if arguments == (
                "diff",
                "--no-ext-diff",
                "--no-renames",
                "--name-only",
                "-z",
                checkpoint,
                "--",
            ):
                return subprocess.CompletedProcess(
                    arguments,
                    0,
                    "Mirmir/Runtime/MirmirModule.swift\0",
                    "",
                )
            return original_git(*arguments)

        with patch.object(verifier, "git", side_effect=simulated_git):
            self.assertEqual(verifier.check(), [])

    def test_candidate_holdout_record_drift_fails(self) -> None:
        verifier = self.verifier_for(self.inventory)
        original_git = verifier.git
        checkpoint = self.inventory["source_checkpoint"]
        ledger_path = self.inventory["holdout_verification"]["sealed_ledger_path"]

        def simulated_git(*arguments: str) -> subprocess.CompletedProcess[str]:
            if arguments == ("diff", "--quiet", checkpoint, "--", ledger_path):
                return subprocess.CompletedProcess(arguments, 1, "", "")
            return original_git(*arguments)

        with patch.object(verifier, "git", side_effect=simulated_git):
            errors = verifier.check()
        self.assertTrue(
            any("tracked holdout no-pixel record differs" in error for error in errors),
            errors,
        )

    def test_missing_required_runtime_source_fails(self) -> None:
        self.inventory["entries"][0]["sources"] = [
            source
            for source in self.inventory["entries"][0]["sources"]
            if source["path"] != "Mirmir/Runtime"
        ]
        self.assert_error_contains(self.inventory, "accepted source paths/order differ")

    def test_removed_manifest_cannot_be_listed_at_checkpoint(self) -> None:
        manifest = self.inventory["entries"][0]["baseline_sources"][-1].copy()
        self.inventory["entries"][0]["sources"].append(manifest)
        self.assert_error_contains(self.inventory, "path is absent at source checkpoint")

    def test_altered_checkpoint_fails(self) -> None:
        self.inventory["source_checkpoint"] = "0" * 40
        self.assert_error_contains(self.inventory, "checkpoint commit is unavailable")

    def test_valid_but_wrong_accepted_checkpoint_fails(self) -> None:
        self.inventory["source_checkpoint"] = self.inventory["baseline_checkpoint"]
        self.inventory["source_tree_git_object_id"] = self.inventory[
            "baseline_tree_git_object_id"
        ]
        self.assert_error_contains(
            self.inventory, "accepted inventory source checkpoint differs from policy"
        )

    def test_altered_source_tree_fails(self) -> None:
        self.inventory["source_tree_git_object_id"] = "0" * 40
        self.assert_error_contains(self.inventory, "source tree Git object ID differs")

    def test_altered_preservation_identity_fails(self) -> None:
        self.inventory["historical_preservation"][0]["git_object_id"] = "0" * 40
        self.assert_error_contains(self.inventory, "preservation identities differ")

    def test_altered_receipt_identity_fails(self) -> None:
        self.inventory["external_p06_evidence"]["receipt_git_object_id"] = "0" * 40
        self.assert_error_contains(self.inventory, "external P06 evidence record differs")

    def test_altered_classification_fails(self) -> None:
        self.inventory["entries"][0]["future_phase"] = "R01"
        self.assert_error_contains(self.inventory, "classification hash differs")

    def test_altered_retirement_contract_fails(self) -> None:
        self.inventory["retire_or_replace"][0]["phase"] = "R01"
        self.assert_error_contains(self.inventory, "retire_or_replace contract hash differs")

    def test_altered_holdout_hash_fails(self) -> None:
        self.inventory["holdout_verification"]["attestation_sha256"] = "0" * 64
        self.assert_error_contains(self.inventory, "holdout verification differs from policy")

    def test_altered_holdout_semantics_fail(self) -> None:
        self.inventory["holdout_verification"]["mounted"] = True
        self.assert_error_contains(self.inventory, "holdout verification differs from policy")

    def test_holdout_authorization_boundary_fails_closed(self) -> None:
        self.inventory["holdout_boundary"]["pixel_access_authorized"] = True
        self.assert_error_contains(self.inventory, "holdout boundary differs from policy")

    def test_altered_official_evidence_boundary_fails(self) -> None:
        self.inventory["official_evidence_boundary"] = (
            "All external evidence was preserved and verified."
        )
        self.assert_error_contains(
            self.inventory, "official evidence boundary differs from policy"
        )

    def test_altered_inventory_identity_and_date_fail(self) -> None:
        for key, value, fragment in (
            ("inventory_id", "replacement", "inventory ID differs from policy"),
            ("recorded_date", "2026-07-20", "recorded date differs from policy"),
        ):
            with self.subTest(key=key):
                inventory = json.loads(json.dumps(self.inventory))
                inventory[key] = value
                self.assert_error_contains(inventory, fragment)

    def test_extra_top_level_claim_fails(self) -> None:
        self.inventory["external_bytes_verified"] = True
        self.assert_error_contains(self.inventory, "closed schema")

    def test_extra_entry_claim_fails(self) -> None:
        self.inventory["entries"][0]["quality_qualified"] = True
        self.assert_error_contains(self.inventory, "entry fields differ from the closed schema")

    def test_nonzero_legacy_process_match_fails(self) -> None:
        self.inventory["legacy_process_check"]["matching_process_count"] = 1
        self.inventory["legacy_process_check"]["matching_processes"] = [
            {"pid": 123, "command": "run_p07_locked_holdout.py"}
        ]
        self.assert_error_contains(self.inventory, "legacy process check differs from policy")

    def test_stale_legacy_process_timestamp_fails(self) -> None:
        self.inventory["legacy_process_check"]["checked_at"] = "invalid"
        self.assert_error_contains(self.inventory, "legacy process check differs from policy")

    def test_stale_markdown_fails(self) -> None:
        verifier = self.verifier_for(self.inventory)
        verifier.markdown_path.write_text("stale\n", encoding="utf-8")
        self.assertTrue(
            any("generated Markdown summary is stale" in error for error in verifier.check())
        )


if __name__ == "__main__":
    unittest.main()
