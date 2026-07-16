from __future__ import annotations

import hashlib
import inspect
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

from validation.calibration_v2 import live_holdout_preopen as preopen
from validation.calibration_v2.live_holdout_preopen import (
    LiveHoldoutPreopenError,
    filesystem_directory_identity_sha256,
    initialize_live_holdout_preopen,
    verify_live_holdout_preopen,
)
from validation.quality.src.mirmir_quality.holdout import (
    HOLDOUT_ACCESS_THREAT_BOUNDARY,
)


REPOSITORY_ROOT = Path(__file__).resolve().parents[3]
SOURCE_SEALED_COPY = (
    REPOSITORY_ROOT
    / "validation/quality/locks/holdout-access-ledger.sealed-copy.json"
)
SOURCE_ATTESTATION = (
    REPOSITORY_ROOT
    / "validation/quality/locks/holdout-seal-attestation.no-pixel.json"
)


def _canonical_sha256(value: object) -> str:
    payload = json.dumps(
        value,
        ensure_ascii=False,
        allow_nan=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")
    return hashlib.sha256(payload).hexdigest()


def _read(path: Path) -> dict[str, object]:
    value = json.loads(path.read_text(encoding="utf-8"))
    assert isinstance(value, dict)
    return value


def _write(path: Path, value: object) -> None:
    path.write_text(
        json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2) + "\n",
        encoding="utf-8",
    )


def _event(
    *,
    sequence: int,
    name: str,
    occurred_utc: str,
    previous: str,
    details: dict[str, object],
) -> dict[str, object]:
    value: dict[str, object] = {
        "sequence": sequence,
        "event": name,
        "occurred_utc": occurred_utc,
        "previous_entry_sha256": previous,
        "details": details,
    }
    value["entry_sha256"] = _canonical_sha256(value)
    return value


class LiveHoldoutPreopenTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(
            prefix=".live-preopen-test-",
            dir=REPOSITORY_ROOT,
        )
        self.root = Path(self.temporary.name)
        self.ledger_root = self.root / "live-ledger-registry"
        self.anchor_root = self.root / "live-anchor-registry"
        self.repository_evidence_root = self.root / "repository-evidence"
        self.ledger_root.mkdir()
        self.anchor_root.mkdir()
        self.repository_evidence_root.mkdir()
        self.additional_immutable_paths: list[Path] = []
        self.live_ledger_path = (
            self.ledger_root / preopen.LIVE_LEDGER_FILENAME
        )
        self.live_anchor_path = (
            self.anchor_root / preopen.LIVE_ANCHOR_FILENAME
        )
        self.live_preopen_receipt_path = (
            self.anchor_root / "holdout-preopen-receipt.test-v1.json"
        )
        self.sealed_copy_path = (
            self.repository_evidence_root
            / "holdout-access-ledger.sealed-copy.json"
        )
        self.attestation_path = (
            self.repository_evidence_root
            / "holdout-seal-attestation.no-pixel.json"
        )
        shutil.copyfile(SOURCE_SEALED_COPY, self.sealed_copy_path)
        shutil.copyfile(SOURCE_ATTESTATION, self.attestation_path)
        attestation = _read(self.attestation_path)
        production_lock = attestation["production_corpus_lock"]
        assert isinstance(production_lock, dict)
        self.corpus_manifest_sha256 = str(production_lock["manifest_sha256"])
        self.initialization_arguments: dict[str, object] = {
            "version_id": "test-v1",
            "created_utc": "2026-07-11T18:02:43Z",
            "corpus_manifest_sha256": self.corpus_manifest_sha256,
            "live_ledger_path": self.live_ledger_path,
            "live_anchor_path": self.live_anchor_path,
            "live_preopen_receipt_path": self.live_preopen_receipt_path,
            "repository_sealed_copy_path": self.sealed_copy_path,
            "expected_repository_sealed_copy_sha256": hashlib.sha256(
                self.sealed_copy_path.read_bytes()
            ).hexdigest(),
            "repository_attestation_path": self.attestation_path,
            "expected_repository_attestation_sha256": hashlib.sha256(
                self.attestation_path.read_bytes()
            ).hexdigest(),
        }
        initialization = initialize_live_holdout_preopen(
            **self.initialization_arguments
        )
        self.arguments: dict[str, object] = {
            "live_ledger_path": self.live_ledger_path,
            "live_anchor_path": self.live_anchor_path,
            "live_preopen_receipt_path": self.live_preopen_receipt_path,
            "expected_live_ledger_root_identity_sha256": initialization[
                "live_ledger_root_identity_sha256"
            ],
            "expected_live_anchor_root_identity_sha256": initialization[
                "live_anchor_root_identity_sha256"
            ],
            "expected_live_preopen_receipt_sha256": initialization[
                "live_preopen_receipt_sha256"
            ],
            "repository_sealed_copy_path": self.sealed_copy_path,
            "expected_repository_sealed_copy_sha256": hashlib.sha256(
                self.sealed_copy_path.read_bytes()
            ).hexdigest(),
            "repository_attestation_path": self.attestation_path,
            "expected_repository_attestation_sha256": hashlib.sha256(
                self.attestation_path.read_bytes()
            ).hexdigest(),
        }

    def tearDown(self) -> None:
        for immutable_path in (
            self.live_anchor_path,
            self.live_preopen_receipt_path,
            *self.additional_immutable_paths,
        ):
            self._clear_immutable(immutable_path)
        self.temporary.cleanup()

    def _verify(self) -> dict[str, object]:
        return dict(verify_live_holdout_preopen(**self.arguments))

    def _clear_immutable(self, path: Path) -> None:
        if not path.exists() or not hasattr(os, "chflags"):
            return
        metadata = os.stat(path, follow_symlinks=False)
        if metadata.st_flags & getattr(stat, "UF_IMMUTABLE", 0):
            os.chflags(
                path,
                metadata.st_flags & ~stat.UF_IMMUTABLE,
                follow_symlinks=False,
            )

    def _write_opened_live_ledger(self) -> None:
        ledger = _read(self.live_ledger_path)
        events = ledger["events"]
        assert isinstance(events, list)
        intent = _event(
            sequence=1,
            name="open_intent",
            occurred_utc="2026-07-11T19:00:00Z",
            previous=str(events[-1]["entry_sha256"]),
            details={
                "configuration_sha256": "a" * 64,
                "external_anchor_sha256": "b" * 64,
            },
        )
        opened = _event(
            sequence=2,
            name="opened",
            occurred_utc="2026-07-11T19:00:01Z",
            previous=str(intent["entry_sha256"]),
            details={"receipt": "persisted before loader delegation"},
        )
        ledger.update(
            {
                "state": "opened",
                "open_intent_utc": "2026-07-11T19:00:00Z",
                "opened_utc": "2026-07-11T19:00:01Z",
                "events": [events[0], intent, opened],
            }
        )
        _write(self.live_ledger_path, ledger)

    def test_valid_unopened_state_returns_only_sanitized_digests_and_status(
        self,
    ) -> None:
        record = self._verify()

        self.assertEqual(record["verification_status"], "pass")
        self.assertEqual(record["access_status"], "unopened")
        self.assertEqual(record["access_count"], 0)
        self.assertFalse(record["open_intent_anchor_present"])
        self.assertFalse(record["pixel_content_included"])
        receipt = dict(record)
        declared = receipt.pop("verification_receipt_sha256")
        self.assertEqual(declared, _canonical_sha256(receipt))
        encoded = json.dumps(record, sort_keys=True)
        self.assertNotIn("revision-002", encoded)
        self.assertNotIn("hold-nasa", encoded)
        self.assertNotIn("sparsebundle", encoded)
        self.assertNotIn(str(self.root), encoded)

    def test_initializer_atomically_publishes_and_seals_versioned_receipt(self) -> None:
        self.assertTrue(self.live_ledger_path.is_file())
        self.assertTrue(self.live_preopen_receipt_path.is_file())
        self.assertFalse(self.live_anchor_path.exists())
        receipt_metadata = os.stat(
            self.live_preopen_receipt_path,
            follow_symlinks=False,
        )
        self.assertTrue(receipt_metadata.st_flags & stat.UF_IMMUTABLE)
        self.assertEqual(list(self.ledger_root.glob("*.partial")), [])
        self.assertEqual(list(self.anchor_root.glob("*.partial")), [])
        receipt = _read(self.live_preopen_receipt_path)
        unhashed = dict(receipt)
        declared = unhashed.pop("receipt_sha256")
        self.assertEqual(declared, _canonical_sha256(unhashed))

    def test_initializer_fails_on_existing_without_changing_published_bytes(
        self,
    ) -> None:
        ledger_before = self.live_ledger_path.read_bytes()
        receipt_before = self.live_preopen_receipt_path.read_bytes()

        with self.assertRaises(FileExistsError):
            initialize_live_holdout_preopen(**self.initialization_arguments)
        self.assertEqual(self.live_ledger_path.read_bytes(), ledger_before)
        self.assertEqual(self.live_preopen_receipt_path.read_bytes(), receipt_before)

    def test_initializer_command_round_trip_uses_only_explicit_paths(self) -> None:
        ledger_root = self.root / "command-ledger-registry"
        anchor_root = self.root / "command-anchor-registry"
        ledger_root.mkdir()
        anchor_root.mkdir()
        ledger_path = ledger_root / preopen.LIVE_LEDGER_FILENAME
        anchor_path = anchor_root / preopen.LIVE_ANCHOR_FILENAME
        receipt_path = anchor_root / "holdout-preopen-receipt.command-v1.json"
        self.additional_immutable_paths.append(receipt_path)
        command = [
            sys.executable,
            str(
                REPOSITORY_ROOT
                / "validation/calibration_v2/tools/initialize_live_holdout_guard.py"
            ),
            "--version-id",
            "command-v1",
            "--created-utc",
            "2026-07-11T18:02:43Z",
            "--corpus-manifest-sha256",
            self.corpus_manifest_sha256,
            "--live-ledger-path",
            str(ledger_path),
            "--live-anchor-path",
            str(anchor_path),
            "--live-preopen-receipt-path",
            str(receipt_path),
            "--repository-sealed-copy-path",
            str(self.sealed_copy_path),
            "--repository-sealed-copy-sha256",
            str(self.arguments["expected_repository_sealed_copy_sha256"]),
            "--repository-attestation-path",
            str(self.attestation_path),
            "--repository-attestation-sha256",
            str(self.arguments["expected_repository_attestation_sha256"]),
        ]

        result = subprocess.run(
            command,
            cwd=REPOSITORY_ROOT,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        initialized = json.loads(result.stdout)
        verified = verify_live_holdout_preopen(
            live_ledger_path=ledger_path,
            live_anchor_path=anchor_path,
            live_preopen_receipt_path=receipt_path,
            expected_live_ledger_root_identity_sha256=initialized[
                "live_ledger_root_identity_sha256"
            ],
            expected_live_anchor_root_identity_sha256=initialized[
                "live_anchor_root_identity_sha256"
            ],
            expected_live_preopen_receipt_sha256=initialized[
                "live_preopen_receipt_sha256"
            ],
            repository_sealed_copy_path=self.sealed_copy_path,
            expected_repository_sealed_copy_sha256=initialized[
                "repository_sealed_copy_sha256"
            ],
            repository_attestation_path=self.attestation_path,
            expected_repository_attestation_sha256=initialized[
                "repository_attestation_sha256"
            ],
        )
        self.assertEqual(verified["verification_status"], "pass")
        self.assertFalse(anchor_path.exists())

    def test_mutable_preopen_receipt_is_rejected(self) -> None:
        self._clear_immutable(self.live_preopen_receipt_path)

        with self.assertRaisesRegex(LiveHoldoutPreopenError, "not user immutable"):
            self._verify()

    def test_tampered_preopen_receipt_self_hash_is_rejected(self) -> None:
        self._clear_immutable(self.live_preopen_receipt_path)
        receipt = _read(self.live_preopen_receipt_path)
        receipt["receipt_sha256"] = "f" * 64
        _write(self.live_preopen_receipt_path, receipt)
        os.chflags(
            self.live_preopen_receipt_path,
            os.stat(self.live_preopen_receipt_path, follow_symlinks=False).st_flags
            | stat.UF_IMMUTABLE,
            follow_symlinks=False,
        )
        self.arguments["expected_live_preopen_receipt_sha256"] = hashlib.sha256(
            self.live_preopen_receipt_path.read_bytes()
        ).hexdigest()

        with self.assertRaisesRegex(LiveHoldoutPreopenError, "self-hash is invalid"):
            self._verify()

    def test_repository_copies_unchanged_while_live_state_is_opened_is_rejected(
        self,
    ) -> None:
        sealed_before = self.sealed_copy_path.read_bytes()
        attestation_before = self.attestation_path.read_bytes()
        self._write_opened_live_ledger()
        _write(
            self.live_anchor_path,
            {
                "schema_version": "1.0.0",
                "artifact_kind": "holdout_access_anchor",
                "corpus_manifest_sha256": self.corpus_manifest_sha256,
                "configuration_sha256": "a" * 64,
                "open_intent_utc": "2026-07-11T19:00:00Z",
                "persistence": "macos-user-immutable-v1",
                "threat_boundary": HOLDOUT_ACCESS_THREAT_BOUNDARY,
            },
        )

        with self.assertRaisesRegex(
            LiveHoldoutPreopenError,
            "records prior holdout access",
        ):
            self._verify()
        self.assertEqual(self.sealed_copy_path.read_bytes(), sealed_before)
        self.assertEqual(self.attestation_path.read_bytes(), attestation_before)

    def test_missing_live_anchor_registry_is_rejected(self) -> None:
        self._clear_immutable(self.live_preopen_receipt_path)
        self.live_preopen_receipt_path.unlink()
        self.anchor_root.rmdir()

        with self.assertRaisesRegex(LiveHoldoutPreopenError, "absent or inaccessible"):
            self._verify()

    def test_mutable_open_intent_anchor_is_rejected(self) -> None:
        _write(
            self.live_anchor_path,
            {
                "schema_version": "1.0.0",
                "artifact_kind": "holdout_access_anchor",
                "corpus_manifest_sha256": self.corpus_manifest_sha256,
                "configuration_sha256": "a" * 64,
                "open_intent_utc": "2026-07-11T19:00:00Z",
                "persistence": "macos-user-immutable-v1",
                "threat_boundary": HOLDOUT_ACCESS_THREAT_BOUNDARY,
            },
        )

        with self.assertRaisesRegex(LiveHoldoutPreopenError, "user-immutable"):
            self._verify()

    def test_wrong_live_storage_root_identity_is_rejected(self) -> None:
        wrong_root = self.root / "substituted-ledger-registry"
        wrong_root.mkdir()
        wrong_ledger = wrong_root / preopen.LIVE_LEDGER_FILENAME
        shutil.copyfile(self.live_ledger_path, wrong_ledger)
        self.arguments["live_ledger_path"] = wrong_ledger

        with self.assertRaisesRegex(LiveHoldoutPreopenError, "root identity differs"):
            self._verify()

    def test_live_ledger_symlink_substitution_is_rejected(self) -> None:
        target = self.root / "same-ledger-bytes.json"
        shutil.copyfile(self.live_ledger_path, target)
        self.live_ledger_path.unlink()
        self.live_ledger_path.symlink_to(target)

        with self.assertRaisesRegex(LiveHoldoutPreopenError, "symbolic link"):
            self._verify()

    def test_intermediate_registry_symlink_is_rejected(self) -> None:
        moved = self.root / "moved-ledger-registry"
        self.ledger_root.rename(moved)
        self.ledger_root.symlink_to(moved, target_is_directory=True)

        with self.assertRaisesRegex(LiveHoldoutPreopenError, "symbolic link"):
            self._verify()

    def test_nonzero_live_access_count_is_rejected(self) -> None:
        self._write_opened_live_ledger()

        with self.assertRaisesRegex(
            LiveHoldoutPreopenError,
            "records prior holdout access",
        ):
            self._verify()

    def test_tampered_live_event_self_hash_is_rejected(self) -> None:
        ledger = _read(self.live_ledger_path)
        events = ledger["events"]
        assert isinstance(events, list) and isinstance(events[0], dict)
        events[0]["entry_sha256"] = "f" * 64
        _write(self.live_ledger_path, ledger)

        with self.assertRaisesRegex(LiveHoldoutPreopenError, "self-hash is invalid"):
            self._verify()

    def test_tampered_repository_receipt_binding_is_rejected(self) -> None:
        attestation = _read(self.attestation_path)
        outer_hashes = attestation["outer_record_hashes"]
        assert isinstance(outer_hashes, dict)
        outer_hashes["evaluation_access_ledger_sealed_copy"] = "f" * 64
        _write(self.attestation_path, attestation)
        self.arguments["expected_repository_attestation_sha256"] = hashlib.sha256(
            self.attestation_path.read_bytes()
        ).hexdigest()

        with self.assertRaisesRegex(
            LiveHoldoutPreopenError,
            "receipt does not bind",
        ):
            self._verify()

    def test_expected_repository_hash_tamper_is_rejected(self) -> None:
        sealed = _read(self.sealed_copy_path)
        sealed["prepared_for_seal_utc"] = "2026-07-11T18:02:44Z"
        _write(self.sealed_copy_path, sealed)

        with self.assertRaisesRegex(LiveHoldoutPreopenError, "expected hash"):
            self._verify()

    def test_no_media_root_parameter_or_embedded_path_lookup(self) -> None:
        for callable_value in (
            verify_live_holdout_preopen,
            initialize_live_holdout_preopen,
        ):
            parameter_names = set(inspect.signature(callable_value).parameters)
            self.assertFalse(
                any(
                    token in name
                    for name in parameter_names
                    for token in (
                        "media",
                        "payload",
                        "container",
                        "mount",
                        "corpus_root",
                    )
                )
            )
        read_paths: list[Path] = []
        lstat_paths: list[Path] = []
        real_read = preopen._read_regular_file
        real_lstat = os.lstat

        def recording_read(path: Path, label: str) -> bytes:
            read_paths.append(path)
            return real_read(path, label)

        def recording_lstat(path: object, *args: object, **kwargs: object):
            lstat_paths.append(Path(path))
            return real_lstat(path, *args, **kwargs)

        read_patch = mock.patch.object(
            preopen,
            "_read_regular_file",
            recording_read,
        )
        lstat_patch = mock.patch.object(
            preopen.os,
            "lstat",
            recording_lstat,
        )
        with read_patch, lstat_patch:
            self._verify()

        allowed_reads = {
            self.live_ledger_path,
            self.live_preopen_receipt_path,
            self.sealed_copy_path,
            self.attestation_path,
            preopen.LIVE_LEDGER_SCHEMA,
            preopen.PREOPEN_RECEIPT_SCHEMA,
            preopen.SEALED_COPY_SCHEMA,
            preopen.SEAL_ATTESTATION_SCHEMA,
            preopen.VERIFICATION_SCHEMA,
        }
        self.assertEqual(set(read_paths), allowed_reads)
        observed = "\n".join(str(path) for path in lstat_paths + read_paths)
        self.assertNotIn("Mirmir-P04-Holdout-Revision-002.sparsebundle", observed)
        self.assertNotIn("quality-holdout-v2/mount-v2/payloads", observed)
        self.assertNotIn("validation/quality/locks/corpus-lock.json", observed)


if __name__ == "__main__":
    unittest.main()
