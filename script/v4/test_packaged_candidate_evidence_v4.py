#!/usr/bin/env python3
"""Regression tests for exact packaged-candidate evidence binding."""

from __future__ import annotations

import importlib.util
from pathlib import Path
import tempfile
import unittest


SCRIPT_DIRECTORY = Path(__file__).resolve().parent


def load(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


packaged = load(
    "packaged_candidate_evidence_v4",
    SCRIPT_DIRECTORY / "packaged_candidate_evidence_v4.py",
)
candidate_tests = load(
    "packaged_candidate_fixture_v4",
    SCRIPT_DIRECTORY / "test_prepare_release_candidate_v4.py",
)


class PackagedCandidateEvidenceV4Tests(unittest.TestCase):
    def candidate_record(
        self, fixture: candidate_tests.Fixture, archive: Path, output: Path
    ) -> dict[str, object]:
        arguments = fixture.arguments(archive)
        arguments.output = output
        value = candidate_tests.candidate.make_candidate(
            arguments,
            source_build_runner=fixture.clean_build_runner,
        )
        output.write_bytes(packaged.canonical_bytes(value))
        return value

    def testAttestedArchiveDerivesAllPackagedIdentities(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mirmir-packaged-evidence-") as temporary:
            root = Path(temporary)
            fixture = candidate_tests.Fixture(root)
            archive = fixture.make_sealed_archive("primary")
            candidate_path = root / "candidate.json"
            candidate = self.candidate_record(fixture, archive, candidate_path)

            observed, package, _, _ = packaged.inspected_package(
                fixture.repository,
                candidate_path,
                archive,
                fixture.runtime,
                fixture.release_configuration,
            )

            self.assertEqual(observed, candidate)
            self.assertEqual(
                package["applicationArchiveSHA256"], candidate["appBundleSHA256"]
            )
            self.assertEqual(package["buildConfiguration"], "Release")
            self.assertEqual(package["schemaVersion"], packaged.PACKAGE_SCHEMA)
            self.assertTrue(package["codeDirectories"])
            for key in (
                "applicationPayloadIdentitySHA256",
                "applicationInfoPlistSHA256",
                "applicationExecutableSHA256",
                "codeDirectorySetSHA256",
                "designatedRequirementSHA256",
                "attestationSHA256",
            ):
                self.assertEqual(len(package[key]), 64)

    def testArchiveSwapWithSourceAndRuntimeConstantFailsEveryLane(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mirmir-packaged-swap-") as temporary:
            root = Path(temporary)
            fixture = candidate_tests.Fixture(root)
            primary = fixture.make_sealed_archive("primary")
            alternate = fixture.make_sealed_archive(
                "alternate",
                executable_source=Path("/usr/bin/false"),
                source_build_runner=fixture.self_asserting_build_runner,
            )
            candidate_path = root / "candidate.json"
            candidate = self.candidate_record(fixture, primary, candidate_path)

            alternate_inspection = candidate_tests.provenance.inspect_archive(
                alternate,
                fixture.context,
                fixture.tools,
                require_attestation=True,
            )
            alternate_attestation = alternate_inspection["attestation"]
            self.assertEqual(
                alternate_attestation["source"]["commit"], candidate["sourceCommit"]
            )
            self.assertEqual(
                alternate_attestation["runtime"]["manifestSHA256"],
                candidate["runtimeManifestSHA256"],
            )

            for lane in ("quality", "parity", "performance"):
                with self.subTest(lane=lane), self.assertRaisesRegex(
                    packaged.PackagedEvidenceError,
                    "candidate record differs from the verified application archive",
                ):
                    packaged.inspected_package(
                        fixture.repository,
                        candidate_path,
                        alternate,
                        fixture.runtime,
                        fixture.release_configuration,
                    )

    def testCaptureTreeSealsDirectoriesNamesAndBytes(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mirmir-packaged-tree-") as temporary:
            root = Path(temporary)
            (root / "cases/a").mkdir(parents=True)
            (root / "cases/a/plane.bin").write_bytes(b"plane-a")
            first = packaged.capture_tree(root)
            (root / "cases/a/plane.bin").write_bytes(b"plane-b")
            second = packaged.capture_tree(root)
            self.assertEqual(first["fileCount"], 1)
            self.assertEqual(first["byteCount"], 7)
            self.assertNotEqual(first["sha256"], second["sha256"])


if __name__ == "__main__":
    unittest.main()
