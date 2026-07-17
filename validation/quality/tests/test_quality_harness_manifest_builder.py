from __future__ import annotations

import tempfile
from pathlib import Path
import unittest

from validation.quality.src.mirmir_quality.json_tools import canonical_json_bytes
from validation.quality.tools.build_quality_harness_implementation_manifest import (
    _write_manifest,
)


class QualityHarnessManifestBuilderTests(unittest.TestCase):
    def test_writer_emits_canonical_one_lf_and_refuses_overwrite(self) -> None:
        manifest = {"z": [3, 2, 1], "a": {"value": True}}
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "nested/manifest.json"
            _write_manifest(output, manifest)

            self.assertEqual(
                output.read_bytes(),
                canonical_json_bytes(manifest) + b"\n",
            )
            with self.assertRaises(FileExistsError):
                _write_manifest(output, manifest)


if __name__ == "__main__":
    unittest.main()
