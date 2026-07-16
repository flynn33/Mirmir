from __future__ import annotations

import argparse
import copy
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock

from validation.calibration_v2.release_evidence import P00_FAILURE_ID
from validation.calibration_v2.release_orchestrator import (
    REQUIRED_G06_TEST_EVIDENCE_IDS,
)
from validation.calibration_v2.tools import run_p06_production_calibration as cli


class ProductionCalibrationCLIAnchorTests(unittest.TestCase):
    @staticmethod
    def _fixture(root: Path) -> argparse.Namespace:
        root.mkdir(parents=True)
        sealed_copy = root / "sealed-copy.json"
        attestation = root / "attestation.json"
        receipt = root / "preopen-receipt.json"
        sealed_copy.write_bytes(b"sealed-copy-anchor\n")
        attestation.write_bytes(b"attestation-anchor\n")
        sealed_copy_sha256 = hashlib.sha256(sealed_copy.read_bytes()).hexdigest()
        attestation_sha256 = hashlib.sha256(attestation.read_bytes()).hexdigest()
        ledger_root_identity = "1" * 64
        anchor_root_identity = "2" * 64
        receipt_document = {
            "live_ledger_root_identity_sha256": ledger_root_identity,
            "live_anchor_root_identity_sha256": anchor_root_identity,
            "repository_sealed_copy_sha256": sealed_copy_sha256,
            "repository_attestation_sha256": attestation_sha256,
        }
        receipt.write_text(
            json.dumps(receipt_document, sort_keys=True, separators=(",", ":"))
            + "\n",
            encoding="utf-8",
        )
        receipt_sha256 = hashlib.sha256(receipt.read_bytes()).hexdigest()
        return argparse.Namespace(
            repository_root=root / "repository",
            open_split_root=root / "open-split",
            calibration_output_root=root / "calibration",
            run_id="anchor-test",
            release_root=root / "release",
            evidence_root=root / "evidence",
            native_cache_root=root / "native-cache",
            writer_root=root / "writer",
            dispatch_measurement_root=root / "dispatch",
            p04_quality_root=root / "p04",
            locked_utc="2026-07-11T00:00:00Z",
            live_ledger_path=root / "live-ledger.json",
            live_anchor_path=root / "live-anchor.json",
            live_preopen_receipt_path=receipt,
            expected_live_ledger_root_identity_sha256=ledger_root_identity,
            expected_live_anchor_root_identity_sha256=anchor_root_identity,
            expected_live_preopen_receipt_sha256=receipt_sha256,
            repository_sealed_copy_path=sealed_copy,
            expected_repository_sealed_copy_sha256=sealed_copy_sha256,
            repository_attestation_path=attestation,
            expected_repository_attestation_sha256=attestation_sha256,
            test_evidence=[
                f"{identifier}={root / (identifier + '.json')}"
                for identifier in REQUIRED_G06_TEST_EVIDENCE_IDS
            ],
            preserved_failure_evidence=[
                f"{P00_FAILURE_ID}={root / 'p00-failure.json'}"
            ],
            timeout_seconds=1.0,
        )

    def _assert_rejected_before_calibration(
        self,
        arguments: argparse.Namespace,
        message: str,
    ) -> None:
        with mock.patch.object(cli, "_arguments", return_value=arguments), mock.patch.object(
            cli,
            "make_production_calibration_assembly",
        ) as factory, mock.patch.object(cli, "CalibrationExecutor") as executor:
            with self.assertRaisesRegex(ValueError, message):
                cli.main()
        factory.assert_not_called()
        executor.assert_not_called()

    def test_binding_uses_only_explicit_expected_anchor_values(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mirmir-p06-cli-anchor-") as value:
            arguments = self._fixture(Path(value) / "fixture")
            binding = cli._live_holdout_preopen_binding(arguments)
        self.assertEqual(
            binding.expected_live_ledger_root_identity_sha256,
            arguments.expected_live_ledger_root_identity_sha256,
        )
        self.assertEqual(
            binding.expected_live_anchor_root_identity_sha256,
            arguments.expected_live_anchor_root_identity_sha256,
        )
        self.assertEqual(
            binding.expected_live_preopen_receipt_sha256,
            arguments.expected_live_preopen_receipt_sha256,
        )
        self.assertEqual(
            binding.expected_repository_sealed_copy_sha256,
            arguments.expected_repository_sealed_copy_sha256,
        )
        self.assertEqual(
            binding.expected_repository_attestation_sha256,
            arguments.expected_repository_attestation_sha256,
        )

    def test_wrong_explicit_anchor_is_rejected_before_factory_or_executor(self) -> None:
        fields = (
            "expected_live_ledger_root_identity_sha256",
            "expected_live_anchor_root_identity_sha256",
            "expected_live_preopen_receipt_sha256",
            "expected_repository_sealed_copy_sha256",
            "expected_repository_attestation_sha256",
        )
        for index, field in enumerate(fields, 5):
            with self.subTest(field=field), tempfile.TemporaryDirectory(
                prefix="mirmir-p06-cli-wrong-anchor-"
            ) as value:
                arguments = self._fixture(Path(value) / "fixture")
                changed = copy.copy(arguments)
                setattr(changed, field, str(index) * 64)
                self._assert_rejected_before_calibration(changed, "explicit expected")

    def test_malformed_explicit_anchor_is_rejected_before_file_trust(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mirmir-p06-cli-format-") as value:
            arguments = self._fixture(Path(value) / "fixture")
            arguments.expected_live_ledger_root_identity_sha256 = "A" * 64
            self._assert_rejected_before_calibration(arguments, "lowercase SHA-256")

    def test_tampered_receipt_and_repository_anchors_fail_before_calibration(
        self,
    ) -> None:
        for target in ("receipt", "sealed_copy", "attestation"):
            with self.subTest(target=target), tempfile.TemporaryDirectory(
                prefix="mirmir-p06-cli-tamper-"
            ) as value:
                arguments = self._fixture(Path(value) / "fixture")
                paths = {
                    "receipt": arguments.live_preopen_receipt_path,
                    "sealed_copy": arguments.repository_sealed_copy_path,
                    "attestation": arguments.repository_attestation_path,
                }
                suffix = b" " if target == "receipt" else b"tampered\n"
                paths[target].write_bytes(paths[target].read_bytes() + suffix)
                expected_message = {
                    "receipt": "receipt differs",
                    "sealed_copy": "sealed copy differs",
                    "attestation": "attestation differs",
                }[target]
                self._assert_rejected_before_calibration(
                    arguments,
                    expected_message,
                )


if __name__ == "__main__":
    unittest.main()
