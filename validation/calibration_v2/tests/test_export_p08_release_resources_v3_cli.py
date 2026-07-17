from __future__ import annotations

from argparse import Namespace
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock

from validation.calibration_v2.tools import export_p08_release_resources_v3 as cli


class ExportP08ReleaseResourcesV3CLITests(unittest.TestCase):
    def test_recovery_cli_only_reopens_existing_release_and_exports(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            release = root / "release"
            resource = root / "resource"
            release.mkdir()
            resource.mkdir()
            receipt_path = root / "receipt.json"
            arguments = Namespace(
                release_root=release,
                p08_resource_root=resource,
                p08_resource_receipt=receipt_path,
                open_split_support_root=root / "open-support",
                calibration_evidence_support_root=root / "evidence-support",
                native_cache_support_root=root / "native-support",
                production_writer_support_root=root / "writer-support",
                dispatch_measurement_support_root=root / "dispatch-support",
                calibration_run_support_root=root / "calibration-support",
            )
            receipt = {
                "release_bundle": {"sha256": "a" * 64},
                "resource_set_sha256": "b" * 64,
            }
            with mock.patch.object(cli, "_arguments", return_value=arguments), \
                    mock.patch.object(
                        cli,
                        "export_p08_release_resources_v3",
                        return_value=receipt,
                    ) as export, mock.patch("builtins.print") as output:
                status = cli.main()

            self.assertEqual(status, 0)
            export.assert_called_once_with(
                release_root=release,
                resource_root=resource,
                receipt_path=receipt_path,
                support_evidence_roots={
                    "open_split": arguments.open_split_support_root,
                    "calibration_evidence": (
                        arguments.calibration_evidence_support_root
                    ),
                    "native_cache": arguments.native_cache_support_root,
                    "production_writer": (
                        arguments.production_writer_support_root
                    ),
                    "dispatch_measurement": (
                        arguments.dispatch_measurement_support_root
                    ),
                    "calibration_run": arguments.calibration_run_support_root,
                },
            )
            document = json.loads(output.call_args.args[0])
            self.assertEqual(document["status"], "p08_exact_six_export_reopened")
            self.assertFalse(document["holdout_accessed"])


if __name__ == "__main__":
    unittest.main()
