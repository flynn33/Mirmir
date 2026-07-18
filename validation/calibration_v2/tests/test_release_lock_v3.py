from __future__ import annotations

import hashlib
from pathlib import Path
import tempfile
import unittest
from unittest import mock

from validation.calibration_v2 import release_lock


def _sha256(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


class P06ReleaseBundleV3BuilderTests(unittest.TestCase):
    def _fixture(
        self,
        root: Path,
    ) -> tuple[str, dict[str, dict[str, object]], str]:
        selected_payload = b'{"selected":true}\n'
        selected_path = f"evaluations/{_sha256(selected_payload)}.json"
        provenance: dict[str, dict[str, object]] = {}
        for identifier, fixed_path in release_lock._RELEASE_ARTIFACTS_V3:
            relative = selected_path if fixed_path is None else fixed_path
            path = root.joinpath(*relative.split("/"))
            path.parent.mkdir(parents=True, exist_ok=True)
            payload = (
                selected_payload
                if identifier == "selected_evaluation"
                else f"{identifier}\n".encode("utf-8")
            )
            path.write_bytes(payload)
            provenance[identifier] = {
                "producer": "test-v3-producer",
                "command": "test-v3-command",
                "platform": "macOS",
                "gate_bindings": ["G04", "G05", "G06"],
            }
        authority = root / "p07-production-execution-authority-v2.json"
        authority.write_bytes(b'{"authority":true}\n')
        return selected_path, provenance, _sha256(authority.read_bytes())

    def _build(
        self,
        root: Path,
        selected_path: str,
        provenance: dict[str, dict[str, object]],
        authority_sha256: str,
    ) -> dict[str, object]:
        with mock.patch.object(
            release_lock,
            "_validate_p06_release_v3_cross_bindings",
            return_value={"artifact_sha256": "a" * 64},
        ):
            return dict(
                release_lock.build_p06_release_bundle_v3_manifest(
                    release_root=root,
                    output_path=root / "p06-release-bundle.json",
                    configuration_id="ash-p06-v3-test",
                    locked_utc="2026-07-16T12:00:00Z",
                    shared_bank_configuration_sha256="1" * 64,
                    input_bundle_sha256="2" * 64,
                    corpus_lock_bundle_sha256="3" * 64,
                    selected_evaluation_path=selected_path,
                    authorized_execution_bindings_sha256=authority_sha256,
                    artifact_provenance=provenance,
                )
            )

    def test_builds_exact_ordered_publish_once_v3_manifest(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            selected, provenance, authority = self._fixture(root)

            document = self._build(root, selected, provenance, authority)

            self.assertEqual(document["schema_version"], "3.0.1")
            self.assertEqual(
                document["artifact_ids"],
                [item[0] for item in release_lock._RELEASE_ARTIFACTS_V3],
            )
            self.assertEqual(
                [row["id"] for row in document["artifacts"]],
                document["artifact_ids"],
            )
            self.assertFalse(document["holdout_accessed"])
            self.assertEqual(document["holdout_access_count"], 0)
            self.assertEqual(
                release_lock.p06_release_bundle_sha256(document),
                document["artifact_sha256"],
            )

    def test_rejects_missing_or_extra_provenance_before_publication(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            selected, provenance, authority = self._fixture(root)
            provenance.pop("direct2x_lut")
            provenance["unrecognized"] = {
                "producer": "test",
                "command": "test",
                "platform": "macOS",
                "gate_bindings": ["G06"],
            }

            with self.assertRaisesRegex(
                release_lock.ReleaseLockError,
                "artifact provenance is not exact",
            ):
                self._build(root, selected, provenance, authority)
            self.assertFalse((root / "p06-release-bundle.json").exists())

    def test_rejects_selected_evaluation_with_false_content_address(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            selected, provenance, authority = self._fixture(root)
            false_path = f"evaluations/{'f' * 64}.json"
            (root / false_path).write_bytes((root / selected).read_bytes())

            with self.assertRaisesRegex(
                release_lock.ReleaseLockError,
                "selected evaluation content address differs",
            ):
                self._build(root, false_path, provenance, authority)
            self.assertFalse((root / "p06-release-bundle.json").exists())

    def test_reopen_rejects_mutated_artifact_and_extra_file(self) -> None:
        for mutation in ("artifact", "extra"):
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                selected, provenance, authority = self._fixture(root)
                self._build(root, selected, provenance, authority)
                if mutation == "artifact":
                    (root / "direct2x.ashlut").write_bytes(b"changed\n")
                    message = "artifact changed"
                else:
                    (root / "unexpected.bin").write_bytes(b"unexpected\n")
                    message = "filesystem closure changed"

                with mock.patch.object(
                    release_lock,
                    "_validate_p06_release_v3_cross_bindings",
                    return_value={"artifact_sha256": "a" * 64},
                ), self.assertRaisesRegex(release_lock.ReleaseLockError, message):
                    release_lock.validate_p06_release_bundle_manifest(
                        release_root=root,
                        manifest_path=root / "p06-release-bundle.json",
                    )

    def test_live_preopen_corpus_manifest_is_not_bundle_digest(self) -> None:
        corpus_manifest_sha256 = "7" * 64
        corpus_lock_bundle_sha256 = "b" * 64
        self.assertNotEqual(corpus_manifest_sha256, corpus_lock_bundle_sha256)
        document = {
            "verification_status": "pass",
            "access_status": "unopened",
            "access_count": 0,
            "open_intent_anchor_present": False,
            "pixel_content_included": False,
            "corpus_binding_sha256": corpus_manifest_sha256,
        }
        with mock.patch.object(
            release_lock,
            "_tracked_corpus_manifest_sha256_v3",
            return_value=corpus_manifest_sha256,
        ):
            release_lock._validate_live_preopen_role_v3(document)
            document["corpus_binding_sha256"] = corpus_lock_bundle_sha256
            with self.assertRaisesRegex(
                release_lock.ReleaseLockError,
                "live preopen authority differs",
            ):
                release_lock._validate_live_preopen_role_v3(document)


if __name__ == "__main__":
    unittest.main()
