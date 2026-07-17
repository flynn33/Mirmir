from __future__ import annotations

import hashlib
import json
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
        self.bundle = {
            "schema_version": "3.0.1",
            "bundle_id": "mirmir-p06-spatial-release-lock-v3",
            "holdout_accessed": False,
            "artifact_sha256": "a" * 64,
            "artifacts": artifacts,
        }
        self.manifest_payload = resources.canonical_json_file_bytes_v2(
            self.bundle
        )
        (self.release / "p06-release-bundle.json").write_bytes(
            self.manifest_payload
        )
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
            receipt_prefix = (
                f".{self.receipt.name}.p06-v3-exact-six-receipt."
            )
            if name.startswith(receipt_prefix) and name.endswith(".partial"):
                staged_receipt = self.receipt.parent / name
                staged_receipt.chmod(0o600)
                staged_receipt.write_bytes(b'{"substituted":true}\n')

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
        self.assertFalse(self.receipt.exists())

    def test_resource_member_change_during_receipt_publication_is_rejected(self) -> None:
        self._preexisting_exact()
        publish_receipt = resources._publish_receipt
        filename = next(iter(self.payloads))

        def mutate_then_publish(path, document, *, verify_before_commit):
            publication = publish_receipt(
                path,
                document,
                verify_before_commit=verify_before_commit,
            )
            member = self.destination / filename
            member.chmod(0o600)
            member.write_bytes(b"mutated-after-reopen\n")
            return publication

        with mock.patch.object(
            resources,
            "_publish_receipt",
            side_effect=mutate_then_publish,
        ), self.assertRaisesRegex(
            resources.ProductionReleaseResourcesV3Error,
            "resource bytes differ",
        ):
            self._export()
        self.assertFalse(self.receipt.exists())
        self.assertEqual(
            len(list(self.root.glob(
                f".{self.receipt.name}.p06-v3-exact-six-receipt.*.failed"
            ))),
            1,
        )

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

    def test_linked_root_is_rejected_and_interrupted_partial_is_quarantined(self) -> None:
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
        self.assertEqual(self._export()["status"], "published_and_reopened")
        self.assertFalse(foreign_partial.exists())
        quarantined = sorted(
            path
            for path in self.root.iterdir()
            if path.name.startswith(foreign_partial.name + ".interrupted.")
            and path.name.endswith(".failed")
        )
        self.assertEqual(len(quarantined), 1)

    def test_failed_owned_partial_is_preserved_without_blocking_retry(self) -> None:
        write_new_at = resources._write_new_at
        invocation_count = 0

        def fail_second_write(
            directory_descriptor: int,
            name: str,
            payload: bytes,
        ) -> None:
            nonlocal invocation_count
            invocation_count += 1
            if invocation_count == 2:
                raise OSError("injected exact-six write failure")
            write_new_at(directory_descriptor, name, payload)

        with mock.patch.object(
            resources,
            "_write_new_at",
            side_effect=fail_second_write,
        ), self.assertRaisesRegex(OSError, "injected exact-six write failure"):
            self._export()

        staging_prefix = f".{self.destination.name}.p06-v3-exact-six."
        preserved = sorted(
            path
            for path in self.root.iterdir()
            if path.name.startswith(staging_prefix)
            and path.name.endswith(".partial.failed")
        )
        self.assertEqual(len(preserved), 1)
        self.assertFalse(
            any(
                path.name.startswith(staging_prefix)
                and path.name.endswith(".partial")
                for path in self.root.iterdir()
            )
        )
        first_filename = next(iter(self.payloads))
        self.assertEqual(
            (preserved[0] / first_filename).read_bytes(),
            self.payloads[first_filename],
        )
        self.assertEqual(self._export()["status"], "published_and_reopened")

    def test_publication_outputs_are_disjoint_from_authenticated_inputs(self) -> None:
        cases = (
            (
                "resource-in-release",
                self.release / "p08-six",
                self.receipt,
            ),
            (
                "resource-in-support",
                self.support_roots["calibration_evidence"] / "p08-six",
                self.receipt,
            ),
            (
                "receipt-in-release",
                self.destination,
                self.release / "receipt.json",
            ),
            (
                "receipt-in-support",
                self.destination,
                self.support_roots["calibration_evidence"] / "receipt.json",
            ),
        )
        for label, resource_root, receipt_path in cases:
            with self.subTest(case=label), self.assertRaisesRegex(
                resources.ProductionReleaseResourcesV3Error,
                "overlaps protected input root",
            ):
                resources.export_p08_release_resources_v3(
                    release_root=self.release,
                    resource_root=resource_root,
                    receipt_path=receipt_path,
                    support_evidence_roots=self.support_roots,
                )
            self.assertFalse(resource_root.exists())
            self.assertFalse(receipt_path.exists())

    def test_directory_paths_require_exact_component_spelling(self) -> None:
        canonical = self.root / "ExactCaseDirectory"
        canonical.mkdir()
        with self.assertRaisesRegex(
            resources.ProductionReleaseResourcesV3Error,
            "exact directory entry spelling",
        ):
            resources._strict_directory(
                self.root / "exactcasedirectory",
                label="case-alias fixture",
            )

    def test_root_replacement_during_receipt_publication_is_rejected(self) -> None:
        self._preexisting_exact()
        original = resources._publish_receipt

        def replace_then_publish(path, document, *, verify_before_commit):
            displaced = self.root / "displaced-six"
            self.destination.rename(displaced)
            self.destination.mkdir()
            for filename, payload in self.payloads.items():
                (self.destination / filename).write_bytes(payload)
            return original(
                path,
                document,
                verify_before_commit=verify_before_commit,
            )

        with mock.patch.object(
            resources,
            "_publish_receipt",
            side_effect=replace_then_publish,
        ), self.assertRaisesRegex(
            resources.ProductionReleaseResourcesV3Error,
            "changed before receipt commit",
        ):
            self._export()
        self.assertFalse(self.receipt.exists())

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

    def test_support_authority_is_replayed_after_receipt_publication(self) -> None:
        sentinel = self.support_roots["calibration_run"] / "transitive.bin"
        sentinel.write_bytes(b"original\n")
        replay_count = 0

        def full_replay(**arguments):
            nonlocal replay_count
            replay_count += 1
            self.assertEqual(arguments["support_evidence_roots"], self.support_roots)
            if replay_count == 2:
                sentinel.write_bytes(b"mutated\n")
                raise resources.ProductionReleaseResourcesV3Error(
                    "support evidence changed during exact-six export"
                )
            return self.bundle

        self.validator.side_effect = full_replay
        with self.assertRaisesRegex(
            resources.ProductionReleaseResourcesV3Error,
            "support evidence changed during exact-six export",
        ):
            self._export()
        self.assertEqual(replay_count, 2)
        self.assertFalse(self.receipt.exists())

    def test_second_replay_resource_mutation_blocks_receipt_commit(self) -> None:
        replay_count = 0
        filename = next(iter(self.payloads))

        def full_replay(**arguments):
            nonlocal replay_count
            replay_count += 1
            self.assertEqual(arguments["support_evidence_roots"], self.support_roots)
            if replay_count == 2:
                member = self.destination / filename
                member.chmod(0o600)
                member.write_bytes(b"mutated-by-second-replay\n")
            return self.bundle

        self.validator.side_effect = full_replay
        with self.assertRaisesRegex(
            resources.ProductionReleaseResourcesV3Error,
            "resource bytes differ",
        ):
            self._export()
        self.assertEqual(replay_count, 2)
        self.assertFalse(self.receipt.exists())

    def test_second_replay_requires_identical_release_authority(self) -> None:
        replay_count = 0

        def full_replay(**arguments):
            nonlocal replay_count
            replay_count += 1
            self.assertEqual(arguments["support_evidence_roots"], self.support_roots)
            if replay_count == 2:
                return {**self.bundle, "artifact_sha256": "b" * 64}
            return self.bundle

        self.validator.side_effect = full_replay
        with self.assertRaisesRegex(
            resources.ProductionReleaseResourcesV3Error,
            "release authority changed",
        ):
            self._export()
        self.assertEqual(replay_count, 2)
        self.assertFalse(self.receipt.exists())

    def test_second_replay_requires_identical_raw_manifest_bytes(self) -> None:
        replay_count = 0

        def full_replay(**arguments):
            nonlocal replay_count
            replay_count += 1
            self.assertEqual(arguments["support_evidence_roots"], self.support_roots)
            if replay_count == 2:
                (self.release / "p06-release-bundle.json").write_text(
                    json.dumps(self.bundle, indent=2) + "\n",
                    encoding="utf-8",
                )
            return self.bundle

        self.validator.side_effect = full_replay
        with self.assertRaisesRegex(
            resources.ProductionReleaseResourcesV3Error,
            "manifest bytes changed",
        ):
            self._export()
        self.assertEqual(replay_count, 2)
        self.assertFalse(self.receipt.exists())

    def test_terminal_receipt_change_is_quarantined(self) -> None:
        publish_receipt = resources._publish_receipt

        def corrupt_after_publish(path, document, *, verify_before_commit):
            publication = publish_receipt(
                path,
                document,
                verify_before_commit=verify_before_commit,
            )
            self.receipt.chmod(0o600)
            self.receipt.write_bytes(b'{"corrupted":true}\n')
            return publication

        with mock.patch.object(
            resources,
            "_publish_receipt",
            side_effect=corrupt_after_publish,
        ), self.assertRaisesRegex(
            resources.ProductionReleaseResourcesV3Error,
            "terminal exact-six receipt identifies different bytes",
        ):
            self._export()
        self.assertFalse(self.receipt.exists())
        self.assertEqual(
            len(list(self.root.glob(
                f".{self.receipt.name}.p06-v3-exact-six-receipt."
                "*.published.failed"
            ))),
            1,
        )

    def test_exact_six_rechecks_earlier_member_identity(self) -> None:
        self._preexisting_exact()
        filenames = list(self.payloads)
        first = self.destination / filenames[0]
        trigger = filenames[1]
        read_file = resources._read_file
        mutated = False

        def mutate_earlier_member(path, *, label):
            nonlocal mutated
            payload = read_file(path, label=label)
            if path.name == trigger and not mutated:
                mutated = True
                first.write_bytes(b"changed-after-first-read\n")
            return payload

        with mock.patch.object(
            resources,
            "_read_file",
            side_effect=mutate_earlier_member,
        ), self.assertRaisesRegex(
            resources.ProductionReleaseResourcesV3Error,
            "changed across exact-six reopening",
        ):
            resources._verify_exact_six(self.destination, self.payloads)

    def test_exact_six_binds_identity_before_each_member_read(self) -> None:
        self._preexisting_exact()
        filename = next(iter(self.payloads))
        member = self.destination / filename
        read_file = resources._read_file
        mutated = False

        def mutate_same_member(path, *, label):
            nonlocal mutated
            payload = read_file(path, label=label)
            if path == member and not mutated:
                mutated = True
                member.write_bytes(b"changed-after-own-read\n")
            return payload

        with mock.patch.object(
            resources,
            "_read_file",
            side_effect=mutate_same_member,
        ), self.assertRaisesRegex(
            resources.ProductionReleaseResourcesV3Error,
            "changed while reopening",
        ):
            resources._verify_exact_six(self.destination, self.payloads)

    def test_failed_new_file_write_removes_partial_final_name(self) -> None:
        descriptor = os.open(self.root, os.O_RDONLY | os.O_DIRECTORY)
        try:
            with mock.patch.object(
                resources.os,
                "write",
                side_effect=OSError("injected write failure"),
            ), self.assertRaisesRegex(OSError, "injected write failure"):
                resources._write_new_at(
                    descriptor,
                    "failed-receipt.partial",
                    b"receipt\n",
                )
        finally:
            os.close(descriptor)
        self.assertFalse((self.root / "failed-receipt.partial").exists())

    def test_failed_new_file_close_removes_partial_and_allows_retry(self) -> None:
        descriptor = os.open(self.root, os.O_RDONLY | os.O_DIRECTORY)
        real_close = os.close
        try:
            with mock.patch.object(
                resources.os,
                "close",
                side_effect=OSError("injected close failure"),
            ), self.assertRaisesRegex(OSError, "injected close failure"):
                resources._write_new_at(
                    descriptor,
                    "close-failed-receipt.partial",
                    b"receipt\n",
                )
            partial = self.root / "close-failed-receipt.partial"
            self.assertFalse(partial.exists())
            resources._write_new_at(
                descriptor,
                partial.name,
                b"receipt\n",
            )
            self.assertEqual(partial.read_bytes(), b"receipt\n")
        finally:
            real_close(descriptor)


if __name__ == "__main__":
    unittest.main()
