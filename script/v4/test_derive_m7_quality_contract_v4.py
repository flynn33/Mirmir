#!/usr/bin/env python3
"""Tests for run-specific M7 P05 executable binding."""

from __future__ import annotations

import importlib.util
import sys
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).with_name("derive_m7_quality_contract_v4.py")
SPEC = importlib.util.spec_from_file_location("derive_m7_quality_contract_v4", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
derivation = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = derivation
SPEC.loader.exec_module(derivation)


def canonical() -> dict:
    return {
        "schemaVersion": "fixture",
        "frozenP05Baseline": {
            "schemaVersion": "mirmir-ash-v4-p05-baseline-identity-v1",
            "implementationVersion": "p05",
            "sourceRevision": "a" * 40,
            "sourceTreeIdentitySHA256": "b" * 64,
            "sourceManifestPath": "script/v4/source.json",
            "sourceManifestSHA256": "c" * 64,
            "captureSourceSHA256": "d" * 64,
            "executableSHA256": "e" * 64,
            "captureExecutableSHA256": "f" * 64,
        },
        "otherContractData": {"preserved": True},
    }


def discovery() -> dict:
    return {
        "sourceTreeIdentitySHA256": "b" * 64,
        "sourceManifestSHA256": "c" * 64,
        "captureSourceSHA256": "d" * 64,
        "executableSHA256": "1" * 64,
        "captureExecutableSHA256": "2" * 64,
    }


class M7QualityContractDerivationTests(unittest.TestCase):
    def test_rebinds_only_executable_identities(self) -> None:
        source = canonical()
        derived, binding = derivation.derive(
            source,
            discovery(),
            canonical_sha256="3" * 64,
        )

        expected = canonical()
        expected["frozenP05Baseline"]["executableSHA256"] = "1" * 64
        expected["frozenP05Baseline"]["captureExecutableSHA256"] = "2" * 64
        self.assertEqual(derived, expected)
        self.assertEqual(source, canonical())
        self.assertEqual(binding["canonicalContractSHA256"], "3" * 64)
        self.assertEqual(
            binding["derivedContractSHA256"],
            derivation.sha256_bytes(derivation.encoded(derived)),
        )

    def test_rejects_source_identity_drift(self) -> None:
        observed = discovery()
        observed["captureSourceSHA256"] = "9" * 64

        with self.assertRaisesRegex(derivation.DerivationError, "source identity differs"):
            derivation.derive(canonical(), observed, canonical_sha256="3" * 64)

    def test_rejects_extra_discovery_field(self) -> None:
        observed = discovery()
        observed["unexpected"] = "4" * 64

        with self.assertRaisesRegex(derivation.DerivationError, "field set differs"):
            derivation.derive(canonical(), observed, canonical_sha256="3" * 64)


if __name__ == "__main__":
    unittest.main()
