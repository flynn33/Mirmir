from __future__ import annotations

import hashlib
import os
from pathlib import Path
import shutil
import tempfile
import unittest
from unittest import mock

from validation.calibration_v2 import production_release_resources_v3 as resources
from validation.quality.src.mirmir_quality.json_tools import canonical_sha256


class ProductionReleaseResourcesV3Tests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name).resolve()
        self.release = self.root / "release"
        self.release.mkdir()
        self.payloads = {}
        artifacts = []
        for index, (identifier, filename) in enumerate(
            resources.P08_RELEASE_RESOURCES_V3
        ):
            payload = f"release-member-{index}\n".encode()
            (self.release / filename).write_bytes(payload)
            self.payloads[filename] = payload
            artifacts.append(
                {
                    "id": identifier,
                    "path": filename,
                    "sha256": hashlib.sha256(payload).hexdigest(),
                    "size_bytes": len(payload),
                }
            )
        self.manifest_payload = b'{"release":"v3"}\n'
        (self.release / "p06-release-bundle.json").write_bytes(
            self.manifest_payload
        )
        self.bundle = {
            "schema_version": "3.0.1",
            "bundle_id": "mirmir-p06-spatial-release-lock-v3",
            "holdout_accessed": False,
            "artifact_sha256": "a" * 64,
            "artifacts": artifacts,
        }
        self.destination = self.root / "p08-six"
        self.receipt = self.root / "p08-six-receipt.json"
        self.support_roots = {
            identifier: self.root / f"support-{identifier}"
            for identifier in (
                "open_split",
                "calibration_evidence",
                "native_cache",
                "production_writer",
                "dispatch_measurement",
                "calibration_run",
            )
        }
        for path in self.support_roots.values():
            path.mkdir()
        self.validation = mock.patch.object(
            resources,
            "validate_p06_release_bundle_manifest",
            return_value=self.bundle,
        )
        self.validator = self.validation.start()

    def tearDown(self) -> None:
        self.validation.stop()
        self.temporary.cleanup()

    def _export(self):
        return resources.export_p08_release_resources_v3(
            release_root=self.release,
            resource_root=self.destination,
            receipt_path=self.receipt,
            support_evidence_roots=self.support_roots,
        )

    def _preexisting_exact(self) -> None:
        self.destination.mkdir()
        for filename, payload in self.payloads.items():
            (self.destination / filename).write_bytes(payload)

    def test_publishes_exact_six_and_receipt_binds_release_and_self(self) -> None:
        document = self._export()

        self.assertEqual(
            sorted(path.name for path in self.destination.iterdir()),
            sorted(self.payloads),
        )
        self.assertEqual(document["resource_count"], 6)
        self.assertEqual(
            document["release_bundle"]["sha256"],
            hashlib.sha256(self.manifest_payload).hexdigest(),
        )
        core = dict(document)
        declared = core.pop("artifact_sha256")
        self.assertEqual(declared, canonical_sha256(core))
        self.assertEqual(document["resource_set_sha256"], canonical_sha256(
            document["resources"]
        ))
        self.assertEqual(self.receipt.read_bytes()[-1:], b"\n")
        self.assertTrue(document["full_support_replay_performed"])
        self.validator.assert_called_with(
            release_root=self.release,
            manifest_path=self.release / "p06-release-bundle.json",
            support_evidence_roots=self.support_roots,
        )

    def test_first_receipt_publication_reopens_the_published_bytes(self) -> None:
        write_new_at = resources._write_new_at

        def substitute_receipt(
            directory_descriptor: int,
            name: str,
            payload: bytes,
        ) -> None:
            write_new_at(directory_descriptor, name, payload)
            if name == self.receipt.name:
                self.receipt.chmod(0o600)
                self.receipt.write_bytes(b'{"substituted":true}\n')

        with mock.patch.object(
            resources,
            "_write_new_at",
            side_effect=substitute_receipt,
        ):
            with self.assertRaisesRegex(
                resources.ProductionReleaseResourcesV3Error,
                "receipt identifies different bytes",
            ):
                self._export()

    def test_exact_preexisting_collision_replays_but_receipt_collision_fails(self) -> None:
        self._preexisting_exact()
        first = self._export()
        second = self._export()
        self.assertEqual(first, second)

        self.receipt.chmod(0o600)
        self.receipt.write_bytes(b'{"foreign":true}\n')
        with self.assertRaisesRegex(
            resources.ProductionReleaseResourcesV3Error,
            "receipt identifies different bytes",
        ):
            self._export()

    def test_missing_extra_swapped_hardlink_and_symlink_members_fail(self) -> None:
        cases = ("missing", "extra", "swapped", "hardlink", "symlink")
        for case in cases:
            with self.subTest(case=case):
                if self.destination.exists() or self.destination.is_symlink():
                    if self.destination.is_symlink():
                        self.destination.unlink()
                    else:
                        shutil.rmtree(self.destination)
                self._preexisting_exact()
                names = list(self.payloads)
                if case == "missing":
                    (self.destination / names[0]).unlink()
                elif case == "extra":
                    (self.destination / "foreign.bin").write_bytes(b"foreign")
                elif case == "swapped":
                    left = self.destination / names[0]
                    right = self.destination / names[1]
                    first = left.read_bytes()
                    left.write_bytes(right.read_bytes())
                    right.write_bytes(first)
                elif case == "hardlink":
                    target = self.destination / names[0]
                    target.unlink()
                    outside = self.root / f"hardlink-source-{case}"
                    outside.write_bytes(self.payloads[names[0]])
                    os.link(outside, target)
                else:
                    target = self.destination / names[0]
                    target.unlink()
                    target.symlink_to(self.release / names[0])
                with self.assertRaises(resources.ProductionReleaseResourcesV3Error):
                    self._export()

    def test_linked_root_and_foreign_partial_are_not_adopted(self) -> None:
        exact = self.root / "foreign-exact"
        exact.mkdir()
        for filename, payload in self.payloads.items():
            (exact / filename).write_bytes(payload)
        self.destination.symlink_to(exact, target_is_directory=True)
        with self.assertRaises(resources.ProductionReleaseResourcesV3Error):
            self._export()
        self.destination.unlink()

        foreign_partial = self.root / (
            f".{self.destination.name}.p06-v3-exact-six."
            + "0" * 32
            + ".partial"
        )
        foreign_partial.mkdir()
        with self.assertRaisesRegex(
            resources.ProductionReleaseResourcesV3Error,
            "foreign exact-six partial",
        ):
            self._export()
        self.assertFalse(self.destination.exists())

    def test_root_replacement_during_receipt_publication_is_rejected(self) -> None:
        self._preexisting_exact()
        original = resources._publish_receipt

        def replace_then_publish(path, document):
            displaced = self.root / "displaced-six"
            self.destination.rename(displaced)
            self.destination.mkdir()
            for filename, payload in self.payloads.items():
                (self.destination / filename).write_bytes(payload)
            original(path, document)

        with mock.patch.object(
            resources,
            "_publish_receipt",
            side_effect=replace_then_publish,
        ), self.assertRaisesRegex(
            resources.ProductionReleaseResourcesV3Error,
            "changed before receipt completion",
        ):
            self._export()

    def test_receipt_inside_resource_root_is_rejected(self) -> None:
        with self.assertRaisesRegex(
            resources.ProductionReleaseResourcesV3Error,
            "receipt must be outside",
        ):
            resources.export_p08_release_resources_v3(
                release_root=self.release,
                resource_root=self.destination,
                receipt_path=self.destination / "receipt.json",
                support_evidence_roots=self.support_roots,
            )

    def test_missing_support_root_fails_closed_before_publication(self) -> None:
        incomplete = dict(self.support_roots)
        incomplete.pop("calibration_run")
        with self.assertRaisesRegex(
            resources.ProductionReleaseResourcesV3Error,
            "exact six P06 support roots",
        ):
            resources.export_p08_release_resources_v3(
                release_root=self.release,
                resource_root=self.destination,
                receipt_path=self.receipt,
                support_evidence_roots=incomplete,
            )
        self.assertFalse(self.destination.exists())

    def test_transitive_support_mutation_blocks_export(self) -> None:
        sentinel = self.support_roots["calibration_run"] / "transitive.bin"
        sentinel.write_bytes(b"original\n")

        def full_replay(**arguments):
            self.assertEqual(arguments["support_evidence_roots"], self.support_roots)
            if sentinel.read_bytes() != b"original\n":
                raise resources.ProductionReleaseResourcesV3Error(
                    "support evidence changed"
                )
            return self.bundle

        self.validator.side_effect = full_replay
        sentinel.write_bytes(b"mutated\n")
        with self.assertRaisesRegex(
            resources.ProductionReleaseResourcesV3Error,
            "support evidence changed",
        ):
            self._export()
        self.assertFalse(self.destination.exists())


if __name__ == "__main__":
    unittest.main()
