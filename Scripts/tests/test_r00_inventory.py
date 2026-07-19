from __future__ import annotations

import json
from pathlib import Path
import sys
import tempfile
import unittest


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
        self.assert_error_contains(self.inventory, "path is absent at checkpoint")

    def test_altered_source_object_id_fails(self) -> None:
        self.inventory["entries"][0]["sources"][0]["git_object_id"] = "0" * 40
        self.assert_error_contains(self.inventory, "Git object ID differs")

    def test_altered_checkpoint_fails(self) -> None:
        self.inventory["source_checkpoint"] = "0" * 40
        self.assert_error_contains(self.inventory, "checkpoint commit is unavailable")

    def test_altered_preservation_identity_fails(self) -> None:
        self.inventory["historical_preservation"][0]["git_object_id"] = "0" * 40
        self.assert_error_contains(self.inventory, "preservation identities differ")

    def test_stale_markdown_fails(self) -> None:
        verifier = self.verifier_for(self.inventory)
        verifier.markdown_path.write_text("stale\n", encoding="utf-8")
        self.assertTrue(
            any("generated Markdown summary is stale" in error for error in verifier.check())
        )


if __name__ == "__main__":
    unittest.main()
