from __future__ import annotations

import hashlib
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
    _verify_manifest_descriptor,
    _walk_artifact_descriptor,
    finalize_runtime_correction,
    verify_frozen_runtime_correction,
    verify_runtime_correction_copy,
)
from validation.quality.src.mirmir_quality.json_tools import (
    canonical_json_bytes,
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
        self.root = Path(self.temporary.name).resolve(strict=True)
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

    def _copy_finalized_closure(self, name: str) -> Path:
        self._finalize()
        copied = self.root / name
        copied.mkdir()
        for source in self.final.iterdir():
            if source.is_file():
                (copied / source.name).write_bytes(source.read_bytes())
        return copied

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

    def test_public_verifier_reopens_exact_frozen_closure(self) -> None:
        self._finalize()
        manifest_payload = (self.final / "artifact-manifest.json").read_bytes()
        verified = verify_frozen_runtime_correction(
            self.final,
            expected_manifest_file_sha256=hashlib.sha256(
                manifest_payload
            ).hexdigest(),
            expected_root_label=(
                "Artifacts/ASH/test/p06/runtime-feasibility-correction-r2"
            ),
        )

        self.assertEqual(verified.root, self.final)
        self.assertEqual(
            verified.manifest_file_sha256,
            hashlib.sha256(manifest_payload).hexdigest(),
        )
        self.assertEqual(
            [path for path, _ in verified.files],
            ["artifact-manifest.json", "artifact-records.json", "benchmark.json"],
        )
        with self.assertRaisesRegex(
            RuntimeCorrectionArtifactError,
            "manifest file SHA-256 differs",
        ):
            verify_frozen_runtime_correction(
                self.final,
                expected_manifest_file_sha256="0" * 64,
            )

        with self.assertRaisesRegex(
            RuntimeCorrectionArtifactError,
            "root label differs",
        ):
            verify_frozen_runtime_correction(
                self.final,
                expected_manifest_file_sha256=hashlib.sha256(
                    manifest_payload
                ).hexdigest(),
                expected_root_label="Artifacts/ASH/substituted",
            )

    def test_copy_verifier_requires_canonical_manifest_and_time_order(self) -> None:
        self._finalize()
        copied = self.root / "runtime-copy"
        copied.mkdir()
        for source in self.final.iterdir():
            if source.is_file():
                (copied / source.name).write_bytes(source.read_bytes())
        manifest_path = copied / "artifact-manifest.json"
        manifest_payload = manifest_path.read_bytes()
        verified = verify_runtime_correction_copy(
            copied,
            expected_manifest_file_sha256=hashlib.sha256(
                manifest_payload
            ).hexdigest(),
        )
        self.assertEqual(verified.manifest["root"], (
            "Artifacts/ASH/test/p06/runtime-feasibility-correction-r2"
        ))

        manifest = json.loads(manifest_payload)
        noncanonical = json.dumps(manifest, indent=2, sort_keys=True).encode() + b"\n"
        manifest_path.write_bytes(noncanonical)
        with self.assertRaisesRegex(
            RuntimeCorrectionArtifactError,
            "not canonical",
        ):
            verify_runtime_correction_copy(
                copied,
                expected_manifest_file_sha256=hashlib.sha256(
                    noncanonical
                ).hexdigest(),
            )

        manifest["finished_utc"] = "1999-12-31T23:59:59Z"
        manifest["manifest_sha256"] = manifest_sha256(manifest)
        reordered = canonical_json_bytes(manifest) + b"\n"
        manifest_path.write_bytes(reordered)
        with self.assertRaisesRegex(
            RuntimeCorrectionArtifactError,
            "time ordering differs",
        ):
            verify_runtime_correction_copy(
                copied,
                expected_manifest_file_sha256=hashlib.sha256(
                    reordered
                ).hexdigest(),
            )

    def test_copy_verifier_rejects_duplicate_json_metadata_member(self) -> None:
        copied = self._copy_finalized_closure("duplicate-metadata-copy")
        metadata_path = copied / "artifact-records.json"
        metadata = json.loads(metadata_path.read_bytes())
        duplicate_metadata = (
            "{\"artifact_kind\":"
            + json.dumps(
                metadata["artifact_kind"],
                separators=(",", ":"),
            )
            + ",\"records\":"
            + json.dumps(
                metadata["records"],
                sort_keys=True,
                separators=(",", ":"),
            )
            + ",\"schema_version\":\"1.0.0\""
            + ",\"schema_version\":\"1.0.0\"}\n"
        ).encode("utf-8")
        metadata_path.write_bytes(duplicate_metadata)

        manifest_path = copied / "artifact-manifest.json"
        manifest = json.loads(manifest_path.read_bytes())
        metadata_record = next(
            record
            for record in manifest["artifacts"]
            if record["path"] == "artifact-records.json"
        )
        metadata_record["size_bytes"] = len(duplicate_metadata)
        metadata_record["sha256"] = hashlib.sha256(
            duplicate_metadata
        ).hexdigest()
        manifest["manifest_sha256"] = manifest_sha256(manifest)
        manifest_payload = canonical_json_bytes(manifest) + b"\n"
        manifest_path.write_bytes(manifest_payload)

        with self.assertRaisesRegex(
            RuntimeCorrectionArtifactError,
            "artifact metadata contains a duplicate JSON member: schema_version",
        ):
            verify_runtime_correction_copy(
                copied,
                expected_manifest_file_sha256=hashlib.sha256(
                    manifest_payload
                ).hexdigest(),
            )

    def test_copy_verifier_rejects_symbolic_ancestor(self) -> None:
        self._finalize()
        symbolic_parent = self.root / "symbolic-artifact-parent"
        symbolic_parent.symlink_to(self.final.parent, target_is_directory=True)
        symbolic_root = symbolic_parent / self.final.name
        manifest_payload = (self.final / "artifact-manifest.json").read_bytes()

        with self.assertRaisesRegex(
            RuntimeCorrectionArtifactError,
            "frozen artifact root has a symbolic ancestor",
        ):
            verify_runtime_correction_copy(
                symbolic_root,
                expected_manifest_file_sha256=hashlib.sha256(
                    manifest_payload
                ).hexdigest(),
            )

    def test_copy_verifier_returns_the_single_validated_descriptor_walk(
        self,
    ) -> None:
        copied = self._copy_finalized_closure("single-walk-copy")
        manifest_payload = (copied / "artifact-manifest.json").read_bytes()
        walk_count = 0

        def substitute_only_on_a_second_walk(
            root_descriptor: int,
        ) -> object:
            nonlocal walk_count
            walk_count += 1
            files, directories = _walk_artifact_descriptor(root_descriptor)
            if walk_count == 1:
                return files, directories
            substituted = tuple(
                (
                    relative,
                    b"substituted-after-validation"
                    if relative == "benchmark.json"
                    else payload,
                    metadata,
                )
                for relative, payload, metadata in files
            )
            return substituted, directories

        with mock.patch(
            "validation.calibration_v2.tools."
            "finalize_p06_runtime_correction._walk_artifact_descriptor",
            side_effect=substitute_only_on_a_second_walk,
        ):
            verified = verify_runtime_correction_copy(
                copied,
                expected_manifest_file_sha256=hashlib.sha256(
                    manifest_payload
                ).hexdigest(),
            )

        self.assertEqual(walk_count, 1)
        self.assertEqual(
            dict(verified.files)["benchmark.json"],
            b'{"status":"passed"}\n',
        )

    def test_copy_verifier_detects_descriptor_relative_file_path_swap(
        self,
    ) -> None:
        copied = self._copy_finalized_closure("file-path-swap-copy")
        benchmark_path = copied / "benchmark.json"
        displaced_path = copied / "displaced-benchmark.json"
        expected_identity = os.stat(benchmark_path, follow_symlinks=False)
        manifest_payload = (copied / "artifact-manifest.json").read_bytes()
        original_read = os.read
        injected = False

        def swap_path_at_eof(descriptor: int, length: int) -> bytes:
            nonlocal injected
            payload = original_read(descriptor, length)
            opened = os.fstat(descriptor)
            if (
                not injected
                and not payload
                and (opened.st_dev, opened.st_ino)
                == (expected_identity.st_dev, expected_identity.st_ino)
            ):
                injected = True
                os.rename(benchmark_path, displaced_path)
                benchmark_path.write_bytes(b"substituted")
            return payload

        with mock.patch(
            "validation.calibration_v2.tools."
            "finalize_p06_runtime_correction.os.read",
            side_effect=swap_path_at_eof,
        ):
            with self.assertRaisesRegex(
                RuntimeCorrectionArtifactError,
                "descriptor-relative artifact path changed while reading: "
                "benchmark.json",
            ):
                verify_runtime_correction_copy(
                    copied,
                    expected_manifest_file_sha256=hashlib.sha256(
                        manifest_payload
                    ).hexdigest(),
                )

        self.assertTrue(injected)
        self.assertEqual(displaced_path.read_bytes(), b'{"status":"passed"}\n')
        self.assertEqual(benchmark_path.read_bytes(), b"substituted")

    def test_copy_verifier_detects_root_path_replacement(self) -> None:
        copied = self._copy_finalized_closure("root-replacement-copy")
        displaced_root = self.root / "displaced-root-replacement-copy"
        manifest_payload = (copied / "artifact-manifest.json").read_bytes()

        def replace_root_after_validated_walk(
            root_descriptor: int,
            expected_manifest: object,
            *,
            metadata_relative: str,
            require_directory_immutable: bool,
            require_tree_read_only: bool = True,
            require_file_immutable: bool = True,
        ) -> object:
            snapshot = _verify_manifest_descriptor(
                root_descriptor,
                expected_manifest,  # type: ignore[arg-type]
                metadata_relative=metadata_relative,
                require_directory_immutable=require_directory_immutable,
                require_tree_read_only=require_tree_read_only,
                require_file_immutable=require_file_immutable,
            )
            os.rename(copied, displaced_root)
            copied.mkdir()
            (copied / "foreign-marker").write_bytes(b"foreign")
            return snapshot

        with mock.patch(
            "validation.calibration_v2.tools."
            "finalize_p06_runtime_correction._verify_manifest_descriptor",
            side_effect=replace_root_after_validated_walk,
        ):
            with self.assertRaisesRegex(
                RuntimeCorrectionArtifactError,
                "artifact root path changed during verification",
            ):
                verify_runtime_correction_copy(
                    copied,
                    expected_manifest_file_sha256=hashlib.sha256(
                        manifest_payload
                    ).hexdigest(),
                )

        self.assertEqual((copied / "foreign-marker").read_bytes(), b"foreign")
        self.assertTrue((displaced_root / "artifact-manifest.json").is_file())

    def test_finalizer_rejects_unbound_empty_directory(self) -> None:
        (self.partial / "empty").mkdir()
        with self.assertRaisesRegex(
            RuntimeCorrectionArtifactError,
            "directory set is not derived",
        ):
            self._finalize()

    def test_finalizer_fails_closed_on_inaccessible_unbound_subtree(self) -> None:
        hidden = self.partial / "hidden-unbound"
        hidden.mkdir()
        (hidden / "unbound.bin").write_bytes(b"unbound\n")
        hidden.chmod(0)
        try:
            with self.assertRaisesRegex(
                RuntimeCorrectionArtifactError,
                "tree traversal failed",
            ):
                self._finalize()
        finally:
            hidden.chmod(0o700)

        self.assertFalse(self.final.exists())
        self.assertTrue((hidden / "unbound.bin").is_file())

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
