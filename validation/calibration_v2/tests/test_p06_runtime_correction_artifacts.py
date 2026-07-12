from __future__ import annotations

import json
import os
from pathlib import Path
import shutil
import stat
import tempfile
import unittest
from unittest import mock

from validation.calibration_v2.tools.finalize_p06_runtime_correction import (
    RuntimeCorrectionArtifactError,
    _rename_exclusive,
    _rename_exclusive_at,
    _seal_root_descriptor,
    _verify_descriptor_snapshots_unchanged,
    finalize_runtime_correction,
)
from validation.quality.src.mirmir_quality.json_tools import (
    manifest_sha256,
    read_json,
    validate_schema,
)


REPOSITORY_ROOT = Path(__file__).resolve().parents[3]
SCHEMA_PATH = (
    REPOSITORY_ROOT
    / "validation/calibration_v2/schemas/"
    "p06-runtime-correction-artifact-manifest-v1.schema.json"
)


class P06RuntimeCorrectionArtifactTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.final = self.root / "runtime-feasibility-correction-r2"
        self.partial = self.root / ".runtime-feasibility-correction-r2.test.partial"
        self.partial.mkdir()
        (self.partial / "benchmark.json").write_text(
            '{"status":"passed"}\n',
            encoding="utf-8",
        )
        self.metadata_path = self.partial / "artifact-records.json"
        self._write_metadata(("artifact-records.json", "benchmark.json"))

    def tearDown(self) -> None:
        for path in (self.final, self.partial):
            self._thaw(path)
        self.temporary.cleanup()

    @staticmethod
    def _thaw(root: Path) -> None:
        if not root.exists():
            return
        if hasattr(os, "chflags") and hasattr(stat, "UF_IMMUTABLE"):
            try:
                flags = os.stat(root, follow_symlinks=False).st_flags
                os.chflags(root, flags & ~stat.UF_IMMUTABLE, follow_symlinks=False)
            except OSError:
                pass
        try:
            os.chmod(root, 0o755, follow_symlinks=False)
        except OSError:
            pass
        paths = list(root.rglob("*"))
        for path in paths:
            if path.is_symlink():
                continue
            if hasattr(os, "chflags") and hasattr(stat, "UF_IMMUTABLE"):
                try:
                    flags = os.stat(path, follow_symlinks=False).st_flags
                    os.chflags(
                        path,
                        flags & ~stat.UF_IMMUTABLE,
                        follow_symlinks=False,
                    )
                except OSError:
                    pass
            try:
                os.chmod(path, 0o755 if path.is_dir() else 0o644)
            except OSError:
                pass
        shutil.rmtree(root, ignore_errors=True)

    def _write_metadata(self, paths: tuple[str, ...]) -> None:
        document = {
            "schema_version": "1.0.0",
            "artifact_kind": "p06_runtime_feasibility_correction_artifact_metadata",
            "records": [
                {
                    "path": path,
                    "producer": "Mirmir P06 verification harness",
                    "command": "python3 -m pytest native-benchmark",
                    "platform": "macOS arm64",
                    "gate_ids": ["P06"],
                }
                for path in paths
            ],
        }
        self.metadata_path.write_text(
            json.dumps(document, sort_keys=True, separators=(",", ":")) + "\n",
            encoding="utf-8",
        )

    def _finalize(self) -> Path:
        return finalize_runtime_correction(
            partial=self.partial,
            final=self.final,
            metadata_path=self.metadata_path,
            run_id="p06-runtime-feasibility-correction-r2-test",
            run_uuid="123e4567-e89b-42d3-a456-426614174000",
            started_utc="2000-01-01T12:00:00Z",
            finished_utc="2000-01-01T12:01:00Z",
            root_label=(
                "Artifacts/ASH/test/p06/runtime-feasibility-correction-r2"
            ),
        )

    def test_finalizes_exact_tree_with_complete_provenance(self) -> None:
        result = self._finalize()

        self.assertEqual(result, self.final)
        self.assertFalse(self.partial.exists())
        manifest = read_json(self.final / "artifact-manifest.json")
        validate_schema(manifest, SCHEMA_PATH)
        self.assertEqual(manifest["manifest_sha256"], manifest_sha256(manifest))
        self.assertFalse(manifest["holdout_accessed"])
        self.assertEqual(
            manifest["run_uuid"],
            "123e4567-e89b-42d3-a456-426614174000",
        )
        self.assertEqual(
            manifest["project_commit"],
            manifest["repository_state"]["project_commit"],
        )
        self.assertEqual(
            manifest["dirty_state_sha256"],
            manifest["repository_state"]["dirty_state_sha256"],
        )
        self.assertEqual(
            [record["path"] for record in manifest["artifacts"]],
            ["artifact-records.json", "benchmark.json"],
        )
        for record in manifest["artifacts"]:
            self.assertEqual(record["producer"], "Mirmir P06 verification harness")
            self.assertTrue(record["command"])
            self.assertEqual(record["platform"], "macOS arm64")
            self.assertEqual(record["gate_ids"], ["P06"])
        for path in (self.final, self.final / "artifact-manifest.json"):
            metadata = os.stat(path, follow_symlinks=False)
            self.assertFalse(
                metadata.st_mode & (stat.S_IWUSR | stat.S_IWGRP | stat.S_IWOTH)
            )
            self.assertTrue(metadata.st_flags & stat.UF_IMMUTABLE)

    def test_refuses_preexisting_final_without_modifying_it(self) -> None:
        self.final.mkdir()
        marker = self.final / "marker"
        marker.write_bytes(b"existing")

        with self.assertRaisesRegex(
            RuntimeCorrectionArtifactError,
            "final artifact directory already exists",
        ):
            self._finalize()

        self.assertEqual(marker.read_bytes(), b"existing")
        self.assertTrue(self.partial.is_dir())
        self.assertFalse((self.partial / "artifact-manifest.json").exists())

    def test_refuses_metadata_that_does_not_cover_exact_file_set(self) -> None:
        self._write_metadata(("artifact-records.json",))

        with self.assertRaisesRegex(
            RuntimeCorrectionArtifactError,
            "does not match exact file set",
        ):
            self._finalize()

        self.assertFalse(self.final.exists())
        self.assertFalse((self.partial / "artifact-manifest.json").exists())

    def test_refuses_symbolic_link_in_partial_tree(self) -> None:
        (self.partial / "link.json").symlink_to(self.partial / "benchmark.json")
        self._write_metadata(
            ("artifact-records.json", "benchmark.json", "link.json")
        )

        with self.assertRaisesRegex(
            RuntimeCorrectionArtifactError,
            "not a single-link file",
        ):
            self._finalize()

        self.assertFalse(self.final.exists())

    def test_exclusive_directory_rename_never_replaces_destination(self) -> None:
        source = self.root / "source"
        destination = self.root / "destination"
        source.mkdir()
        destination.mkdir()
        (source / "source-marker").write_bytes(b"source")
        (destination / "destination-marker").write_bytes(b"destination")

        with self.assertRaisesRegex(
            RuntimeCorrectionArtifactError,
            "already exists",
        ):
            _rename_exclusive(source, destination)

        self.assertEqual((source / "source-marker").read_bytes(), b"source")
        self.assertEqual(
            (destination / "destination-marker").read_bytes(),
            b"destination",
        )

    def test_recovers_recognized_stale_manifest_temporary_and_records_it(
        self,
    ) -> None:
        stale = (
            self.partial
            / ".artifact-manifest.json.0123456789abcdef0123456789abcdef.tmp"
        )
        stale.write_bytes(b"interrupted manifest")

        self._finalize()

        manifest = read_json(self.final / "artifact-manifest.json")
        self.assertEqual(
            manifest["recovery_actions"],
            [
                {
                    "action": "removed_recognized_stale_manifest_temporary",
                    "path": stale.name,
                    "sha256": (
                        "69f0f35644bb103283df602e5023b1ea3aee7e5ae73d55ed"
                        "e90f46d74a314776"
                    ),
                    "size_bytes": len(b"interrupted manifest"),
                }
            ],
        )
        self.assertFalse((self.final / stale.name).exists())

    def test_stale_temp_audit_survives_crash_before_recorded_deletion(
        self,
    ) -> None:
        stale = (
            self.partial
            / ".artifact-manifest.json.fedcba9876543210fedcba9876543210.tmp"
        )
        stale.write_bytes(b"stale-before-durable-recovery")

        with mock.patch(
            "validation.calibration_v2.tools."
            "finalize_p06_runtime_correction."
            "_delete_recorded_manifest_temporaries",
            side_effect=RuntimeCorrectionArtifactError(
                "injected after durable recovery record"
            ),
        ):
            with self.assertRaisesRegex(
                RuntimeCorrectionArtifactError,
                "injected after durable recovery record",
            ):
                self._finalize()

        self.assertTrue(stale.is_file())
        partial_manifest = read_json(
            self.partial / "artifact-manifest.json"
        )
        self.assertEqual(
            [action["path"] for action in partial_manifest["recovery_actions"]],
            [stale.name],
        )

        self.assertEqual(self._finalize(), self.final)
        final_manifest = read_json(self.final / "artifact-manifest.json")
        self.assertEqual(
            final_manifest["recovery_actions"],
            partial_manifest["recovery_actions"],
        )
        self.assertFalse((self.final / stale.name).exists())

    def test_resume_rejects_unrecorded_temp_after_durable_recovery_record(
        self,
    ) -> None:
        recorded = (
            self.partial
            / ".artifact-manifest.json.11111111111111111111111111111111.tmp"
        )
        recorded.write_bytes(b"recorded")
        with mock.patch(
            "validation.calibration_v2.tools."
            "finalize_p06_runtime_correction."
            "_delete_recorded_manifest_temporaries",
            side_effect=RuntimeCorrectionArtifactError("injected crash"),
        ):
            with self.assertRaisesRegex(
                RuntimeCorrectionArtifactError,
                "injected crash",
            ):
                self._finalize()
        unrecorded = (
            self.partial
            / ".artifact-manifest.json.22222222222222222222222222222222.tmp"
        )
        unrecorded.write_bytes(b"unrecorded")

        with self.assertRaisesRegex(
            RuntimeCorrectionArtifactError,
            "unrecorded temporary",
        ):
            self._finalize()

        self.assertFalse(recorded.exists())
        self.assertEqual(unrecorded.read_bytes(), b"unrecorded")
        self.assertFalse(self.final.exists())

    def test_resume_rejects_changed_recorded_temp_without_deleting_it(
        self,
    ) -> None:
        stale = (
            self.partial
            / ".artifact-manifest.json.33333333333333333333333333333333.tmp"
        )
        stale.write_bytes(b"original")
        with mock.patch(
            "validation.calibration_v2.tools."
            "finalize_p06_runtime_correction."
            "_delete_recorded_manifest_temporaries",
            side_effect=RuntimeCorrectionArtifactError("injected crash"),
        ):
            with self.assertRaisesRegex(
                RuntimeCorrectionArtifactError,
                "injected crash",
            ):
                self._finalize()
        stale.write_bytes(b"changed")

        with self.assertRaisesRegex(
            RuntimeCorrectionArtifactError,
            "bytes changed",
        ):
            self._finalize()

        self.assertEqual(stale.read_bytes(), b"changed")
        self.assertFalse(self.final.exists())

    def test_resumes_after_manifest_publication_interruption(self) -> None:
        with mock.patch(
            "validation.calibration_v2.tools."
            "finalize_p06_runtime_correction._freeze_tree_descriptor",
            side_effect=RuntimeCorrectionArtifactError(
                "injected after manifest publication"
            ),
        ):
            with self.assertRaisesRegex(
                RuntimeCorrectionArtifactError,
                "injected after manifest publication",
            ):
                self._finalize()

        self.assertTrue((self.partial / "artifact-manifest.json").is_file())
        self.assertFalse(self.final.exists())
        self.assertEqual(self._finalize(), self.final)

    def test_resumes_directory_sealing_after_atomic_rename(self) -> None:
        with mock.patch(
            "validation.calibration_v2.tools."
            "finalize_p06_runtime_correction._seal_root_descriptor",
            side_effect=RuntimeCorrectionArtifactError(
                "injected after atomic rename"
            ),
        ):
            with self.assertRaisesRegex(
                RuntimeCorrectionArtifactError,
                "injected after atomic rename",
            ):
                self._finalize()

        self.assertFalse(self.partial.exists())
        self.assertTrue(self.final.is_dir())
        self.assertEqual(self._finalize(), self.final)
        self.assertTrue(
            os.stat(self.final, follow_symlinks=False).st_flags
            & stat.UF_IMMUTABLE
        )

    def test_resumes_frozen_partial_after_transient_rename_failure(self) -> None:
        original = _rename_exclusive_at
        injected = False

        def fail_final_once(
            source_directory_descriptor: int,
            source_name: str,
            destination_directory_descriptor: int,
            destination_name: str,
        ) -> None:
            nonlocal injected
            if not injected and destination_name == self.final.name:
                injected = True
                raise OSError("injected transient directory rename failure")
            original(
                source_directory_descriptor,
                source_name,
                destination_directory_descriptor,
                destination_name,
            )

        with mock.patch(
            "validation.calibration_v2.tools."
            "finalize_p06_runtime_correction._rename_exclusive_at",
            side_effect=fail_final_once,
        ):
            with self.assertRaisesRegex(
                OSError,
                "injected transient directory rename failure",
            ):
                self._finalize()

        self.assertTrue(self.partial.is_dir())
        self.assertTrue(
            os.stat(
                self.partial / "artifact-manifest.json",
                follow_symlinks=False,
            ).st_flags
            & stat.UF_IMMUTABLE
        )
        self.assertEqual(self._finalize(), self.final)

    def test_completed_publication_is_idempotently_verified(self) -> None:
        self.assertEqual(self._finalize(), self.final)
        first = (self.final / "artifact-manifest.json").read_bytes()

        self.assertEqual(self._finalize(), self.final)

        self.assertEqual(
            (self.final / "artifact-manifest.json").read_bytes(),
            first,
        )

    def test_rejects_hard_link_without_mutating_shared_inode(self) -> None:
        external = self.root / "external.json"
        external.write_bytes(b"shared")
        linked = self.partial / "linked.json"
        os.link(external, linked)
        self._write_metadata(
            ("artifact-records.json", "benchmark.json", "linked.json")
        )
        mode_before = os.stat(external).st_mode

        with self.assertRaisesRegex(
            RuntimeCorrectionArtifactError,
            "not a single-link file",
        ):
            self._finalize()

        self.assertEqual(external.read_bytes(), b"shared")
        self.assertEqual(os.stat(external).st_mode, mode_before)
        self.assertFalse(os.stat(external).st_flags & stat.UF_IMMUTABLE)

    def test_metadata_swap_after_snapshot_is_detected(self) -> None:
        def mutate_then_verify(
            root_descriptor: int,
            snapshots: object,
            *,
            ignored_paths: object = (),
        ) -> None:
            self.metadata_path.write_text("{}\n", encoding="utf-8")
            _verify_descriptor_snapshots_unchanged(
                root_descriptor,
                snapshots,  # type: ignore[arg-type]
                ignored_paths=ignored_paths,  # type: ignore[arg-type]
            )

        with mock.patch(
            "validation.calibration_v2.tools."
            "finalize_p06_runtime_correction."
            "_verify_descriptor_snapshots_unchanged",
            side_effect=mutate_then_verify,
        ):
            with self.assertRaisesRegex(
                RuntimeCorrectionArtifactError,
                "artifact changed during finalization",
            ):
                self._finalize()

        self.assertFalse((self.partial / "artifact-manifest.json").exists())
        self.assertFalse(self.final.exists())

    def test_source_identity_swap_is_quarantined_without_final(self) -> None:
        saved = self.root / "expected-saved-by-injected-swap"
        injected = False

        def swap_then_rename(
            source_directory_descriptor: int,
            source_name: str,
            destination_directory_descriptor: int,
            destination_name: str,
            *,
            nofollow_any: bool = True,
        ) -> None:
            nonlocal injected
            if (
                not injected
                and source_name == self.partial.name
                and destination_name == self.final.name
            ):
                injected = True
                os.rename(self.partial, saved)
                self.partial.mkdir()
                (self.partial / "foreign-marker").write_bytes(b"foreign")
            _rename_exclusive_at(
                source_directory_descriptor,
                source_name,
                destination_directory_descriptor,
                destination_name,
                nofollow_any=nofollow_any,
            )

        try:
            with mock.patch(
                "validation.calibration_v2.tools."
                "finalize_p06_runtime_correction._rename_exclusive_at",
                side_effect=swap_then_rename,
            ):
                with self.assertRaisesRegex(
                    RuntimeCorrectionArtifactError,
                    "quarantined as",
                ):
                    self._finalize()

            self.assertFalse(self.final.exists())
            quarantines = tuple(
                self.root.glob(
                    ".runtime-feasibility-correction-r2.*."
                    "identity-mismatch.quarantine"
                )
            )
            self.assertEqual(len(quarantines), 1)
            self.assertEqual(
                (quarantines[0] / "foreign-marker").read_bytes(),
                b"foreign",
            )
            self.assertTrue((saved / "artifact-manifest.json").is_file())
        finally:
            self._thaw(saved)
            for quarantine in self.root.glob(
                ".runtime-feasibility-correction-r2.*."
                "identity-mismatch.quarantine"
            ):
                self._thaw(quarantine)

    def test_final_swap_during_root_seal_quarantines_foreign_path(self) -> None:
        saved = self.root / "expected-saved-during-root-seal"
        injected = False

        def swap_then_seal(
            descriptor: int,
            expected_identity: os.stat_result,
        ) -> None:
            nonlocal injected
            if not injected:
                injected = True
                os.rename(self.final, saved)
                self.final.mkdir()
                (self.final / "foreign-marker").write_bytes(b"foreign")
            _seal_root_descriptor(descriptor, expected_identity)

        try:
            with mock.patch(
                "validation.calibration_v2.tools."
                "finalize_p06_runtime_correction._seal_root_descriptor",
                side_effect=swap_then_seal,
            ):
                with self.assertRaisesRegex(
                    RuntimeCorrectionArtifactError,
                    "quarantined",
                ):
                    self._finalize()

            self.assertFalse(self.final.exists())
            quarantines = tuple(
                self.root.glob(
                    ".runtime-feasibility-correction-r2.*."
                    "identity-mismatch.quarantine"
                )
            )
            self.assertEqual(len(quarantines), 1)
            self.assertEqual(
                (quarantines[0] / "foreign-marker").read_bytes(),
                b"foreign",
            )
            self.assertFalse(
                os.stat(quarantines[0], follow_symlinks=False).st_flags
                & stat.UF_IMMUTABLE
            )
            self.assertTrue(
                os.stat(saved, follow_symlinks=False).st_flags
                & stat.UF_IMMUTABLE
            )
        finally:
            self._thaw(saved)
            for quarantine in self.root.glob(
                ".runtime-feasibility-correction-r2.*."
                "identity-mismatch.quarantine"
            ):
                self._thaw(quarantine)

    def test_recovery_swap_during_root_seal_quarantines_foreign_path(
        self,
    ) -> None:
        with mock.patch(
            "validation.calibration_v2.tools."
            "finalize_p06_runtime_correction._seal_root_descriptor",
            side_effect=RuntimeCorrectionArtifactError(
                "injected initial root-seal interruption"
            ),
        ):
            with self.assertRaisesRegex(
                RuntimeCorrectionArtifactError,
                "initial root-seal interruption",
            ):
                self._finalize()
        self.assertTrue(self.final.is_dir())

        saved = self.root / "expected-recovery-saved-during-root-seal"
        injected = False

        def swap_then_seal(
            descriptor: int,
            expected_identity: os.stat_result,
        ) -> None:
            nonlocal injected
            if not injected:
                injected = True
                os.rename(self.final, saved)
                self.final.mkdir()
                (self.final / "foreign-marker").write_bytes(b"foreign")
            _seal_root_descriptor(descriptor, expected_identity)

        try:
            with mock.patch(
                "validation.calibration_v2.tools."
                "finalize_p06_runtime_correction._seal_root_descriptor",
                side_effect=swap_then_seal,
            ):
                with self.assertRaisesRegex(
                    RuntimeCorrectionArtifactError,
                    "quarantined as",
                ):
                    self._finalize()

            self.assertFalse(self.final.exists())
            quarantines = tuple(
                self.root.glob(
                    ".runtime-feasibility-correction-r2.*."
                    "identity-mismatch.quarantine"
                )
            )
            self.assertEqual(len(quarantines), 1)
            self.assertEqual(
                (quarantines[0] / "foreign-marker").read_bytes(),
                b"foreign",
            )
            self.assertTrue(
                os.stat(saved, follow_symlinks=False).st_flags
                & stat.UF_IMMUTABLE
            )
        finally:
            self._thaw(saved)
            for quarantine in self.root.glob(
                ".runtime-feasibility-correction-r2.*."
                "identity-mismatch.quarantine"
            ):
                self._thaw(quarantine)

    def test_non_directory_swaps_during_root_seal_are_quarantined(self) -> None:
        for recovery in (False, True):
            for foreign_kind in ("regular", "symlink"):
                with self.subTest(recovery=recovery, foreign_kind=foreign_kind):
                    case = self.root / f"case-{int(recovery)}-{foreign_kind}"
                    case.mkdir()
                    final = case / "runtime-feasibility-correction-r2"
                    partial = (
                        case
                        / ".runtime-feasibility-correction-r2.test.partial"
                    )
                    partial.mkdir()
                    (partial / "benchmark.json").write_text(
                        '{"status":"passed"}\n',
                        encoding="utf-8",
                    )
                    metadata_path = partial / "artifact-records.json"
                    metadata_path.write_text(
                        json.dumps(
                            {
                                "schema_version": "1.0.0",
                                "artifact_kind": (
                                    "p06_runtime_feasibility_correction_"
                                    "artifact_metadata"
                                ),
                                "records": [
                                    {
                                        "path": path,
                                        "producer": "P06 harness",
                                        "command": "focused-test",
                                        "platform": "macOS arm64",
                                        "gate_ids": ["P06"],
                                    }
                                    for path in (
                                        "artifact-records.json",
                                        "benchmark.json",
                                    )
                                ],
                            },
                            sort_keys=True,
                            separators=(",", ":"),
                        )
                        + "\n",
                        encoding="utf-8",
                    )

                    def finalize_case() -> Path:
                        return finalize_runtime_correction(
                            partial=partial,
                            final=final,
                            metadata_path=metadata_path,
                            run_id="123e4567-e89b-42d3-a456-426614174000",
                            run_uuid=(
                                "123e4567-e89b-42d3-a456-426614174000"
                            ),
                            started_utc="2000-01-01T12:00:00Z",
                            finished_utc="2000-01-01T12:01:00Z",
                            root_label=(
                                "Artifacts/ASH/test/p06/"
                                f"non-directory-{int(recovery)}-{foreign_kind}"
                            ),
                        )

                    if recovery:
                        with mock.patch(
                            "validation.calibration_v2.tools."
                            "finalize_p06_runtime_correction."
                            "_seal_root_descriptor",
                            side_effect=RuntimeCorrectionArtifactError(
                                "initial recovery setup interruption"
                            ),
                        ):
                            with self.assertRaisesRegex(
                                RuntimeCorrectionArtifactError,
                                "recovery setup interruption",
                            ):
                                finalize_case()

                    saved = case / "expected-saved"
                    target = case / "symlink-target"
                    injected = False

                    def swap_then_seal(
                        descriptor: int,
                        expected_identity: os.stat_result,
                    ) -> None:
                        nonlocal injected
                        if not injected:
                            injected = True
                            os.rename(final, saved)
                            if foreign_kind == "regular":
                                final.write_bytes(b"foreign-file")
                            else:
                                target.mkdir()
                                final.symlink_to(target, target_is_directory=True)
                        _seal_root_descriptor(descriptor, expected_identity)

                    try:
                        with mock.patch(
                            "validation.calibration_v2.tools."
                            "finalize_p06_runtime_correction."
                            "_seal_root_descriptor",
                            side_effect=swap_then_seal,
                        ):
                            with self.assertRaisesRegex(
                                RuntimeCorrectionArtifactError,
                                "quarantined as",
                            ):
                                finalize_case()
                        self.assertFalse(final.exists())
                        quarantines = tuple(
                            case.glob(
                                ".runtime-feasibility-correction-r2.*."
                                "identity-mismatch.quarantine"
                            )
                        )
                        self.assertEqual(len(quarantines), 1)
                        if foreign_kind == "regular":
                            self.assertEqual(
                                quarantines[0].read_bytes(),
                                b"foreign-file",
                            )
                        else:
                            self.assertTrue(quarantines[0].is_symlink())
                            self.assertEqual(
                                os.readlink(quarantines[0]),
                                str(target),
                            )
                        self.assertTrue(
                            os.stat(saved, follow_symlinks=False).st_flags
                            & stat.UF_IMMUTABLE
                        )
                    finally:
                        self._thaw(saved)
                        for quarantine in case.glob(
                            ".runtime-feasibility-correction-r2.*."
                            "identity-mismatch.quarantine"
                        ):
                            if quarantine.is_symlink() or quarantine.is_file():
                                quarantine.unlink()
                            else:
                                self._thaw(quarantine)
                        if target.exists():
                            target.rmdir()
                        shutil.rmtree(case, ignore_errors=True)

    def test_sealed_root_cannot_be_swapped_after_root_seal(self) -> None:
        self.assertEqual(self._finalize(), self.final)
        destination = self.root / "forbidden-post-seal-move"

        with self.assertRaises(PermissionError):
            os.rename(self.final, destination)

        self.assertTrue(self.final.is_dir())
        self.assertFalse(destination.exists())
        self.assertEqual(self._finalize(), self.final)
        with self.assertRaises(PermissionError):
            os.rename(self.final, destination)


if __name__ == "__main__":
    unittest.main()
