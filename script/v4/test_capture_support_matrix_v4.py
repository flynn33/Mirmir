#!/usr/bin/env python3
"""Fail-closed tests for support-matrix result interpretation."""

from __future__ import annotations

import importlib.util
from pathlib import Path
import unittest


SCRIPT_DIRECTORY = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location(
    "capture_support_matrix_v4",
    SCRIPT_DIRECTORY / "capture_support_matrix_v4.py",
)
assert SPEC is not None and SPEC.loader is not None
support = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(support)


class SupportMatrixCaptureTests(unittest.TestCase):
    def test_skip_extraction_uses_identifiers_and_deduplicates(self) -> None:
        document = {
            "children": [
                {"result": "Skipped", "nodeIdentifier": "Suite/testOne()"},
                {
                    "children": [
                        {"result": "Passed", "nodeIdentifier": "Suite/testTwo()"},
                        {"result": "Skipped", "nodeIdentifier": "Suite/testOne()"},
                    ]
                },
            ]
        }
        self.assertEqual(support.skipped_identifiers(document), {"Suite/testOne()"})

    def test_summary_counts_reject_boolean_and_negative_counts(self) -> None:
        with self.assertRaisesRegex(support.SupportCaptureError, "passedTests"):
            support.summary_counts(
                {"passedTests": True, "failedTests": 0, "skippedTests": 0, "result": "Succeeded"}
            )
        with self.assertRaisesRegex(support.SupportCaptureError, "failedTests"):
            support.summary_counts(
                {"passedTests": 1, "failedTests": -1, "skippedTests": 0, "result": "Succeeded"}
            )

    def test_contract_requires_both_classes_and_zero_skip_allowance(self) -> None:
        valid = {
            "schemaVersion": "mirmir-ash-v4-support-matrix-contract-v1",
            "buildConfiguration": "Release",
            "developmentTeam": "9AQ2C2838M",
            "machineClasses": [
                {
                    "id": "reference",
                    "destinationArchitecture": "arm64",
                    "runtimeMode": "native_apple_silicon",
                },
                {
                    "id": "supported",
                    "destinationArchitecture": "x86_64",
                    "runtimeMode": "rosetta_2_compatibility",
                },
            ],
            "expectedSkippedTests": [],
            "minimumPassingTestCount": 300,
            "project": "Mirmir.xcodeproj",
            "releaseConfigurationPath": "script/v4/release-candidate-v4.xcconfig",
            "runtimeResourcePath": "Mirmir/Resources/ASH-P06.bundle",
            "scheme": "Mirmir",
            "unexpectedSkipAllowance": 0,
        }
        self.assertEqual(support.validate_contract(valid), valid)
        invalid = dict(valid)
        invalid["unexpectedSkipAllowance"] = 1
        with self.assertRaisesRegex(support.SupportCaptureError, "every unexpected skip"):
            support.validate_contract(invalid)

    def test_code_signature_summary_requires_team_architecture_and_runtime(self) -> None:
        detail = "\n".join(
            (
                "Identifier=com.mirmir.app",
                "Format=app bundle with Mach-O thin (x86_64)",
                "CodeDirectory v=20500 flags=0x10000(runtime)",
                "Authority=Apple Development: Release Operator (TEAM)",
                "Authority=Apple Root CA",
                "TeamIdentifier=9AQ2C2838M",
            )
        )
        observed = support.code_signature_summary(
            detail,
            expected_identifier="com.mirmir.app",
            expected_team="9AQ2C2838M",
            expected_architecture="x86_64",
        )
        self.assertTrue(observed["hardenedRuntime"])
        self.assertEqual(observed["executionArchitecture"], "x86_64")
        with self.assertRaisesRegex(support.SupportCaptureError, "team differs"):
            support.code_signature_summary(
                detail,
                expected_identifier="com.mirmir.app",
                expected_team="OTHERTEAM0",
                expected_architecture="x86_64",
            )


if __name__ == "__main__":
    unittest.main()
