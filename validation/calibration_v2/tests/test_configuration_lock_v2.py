from __future__ import annotations

import copy
import hashlib
import json
from pathlib import Path
import tempfile
import unittest

from validation.calibration_v2 import release_lock


class P06ConfigurationLockV2Tests(unittest.TestCase):
    LOCKED_UTC = "2026-07-16T12:00:00Z"
    CONFIGURATION_ID = "ash-p06-v2-test"
    CANDIDATE_SHA256 = "a" * 64
    BANK_SHA256 = "b" * 64
    CONFIGURATION_FILES = (
        ("locked_mapping", "locked-mapping.json"),
        ("locked_operator_bank", "locked-operator-bank.json"),
        ("locked_quality_policy", "locked-quality-policy.json"),
        ("locked_metric_policy", "locked-metric-policy.json"),
        ("locked_compiler_input_v2", "locked-compiler-input-v2.json"),
        ("direct2x_lut", "direct2x.ashlut"),
        ("direct3over2_lut", "direct3over2.ashlut"),
        ("native_parity_manifest", "native-lut-parity-manifest-v3.json"),
        ("lut_manifest", "lut-manifest-v3.json"),
    )

    @staticmethod
    def _canonical(document: object) -> bytes:
        return (
            json.dumps(
                document,
                ensure_ascii=False,
                allow_nan=False,
                sort_keys=True,
                separators=(",", ":"),
            )
            + "\n"
        ).encode("utf-8")

    @staticmethod
    def _binding(path: Path, relative: str) -> dict[str, object]:
        payload = path.read_bytes()
        return {
            "path": relative,
            "sha256": hashlib.sha256(payload).hexdigest(),
            "size_bytes": len(payload),
        }

    def _fixture(self, root: Path):
        artifacts = {}
        for index, (identifier, relative) in enumerate(
            self.CONFIGURATION_FILES,
            start=1,
        ):
            path = root / relative
            path.write_bytes(f"fixture-{index}\n".encode("ascii"))
            artifacts[identifier] = {
                "id": identifier,
                **self._binding(path, relative),
            }
        selection_path = root / "calibration-selection-v2.json"
        selection_path.write_bytes(b"selection\n")
        selection = self._binding(
            selection_path,
            "calibration-selection-v2.json",
        )
        evaluation_relative = f"evaluations/{'c' * 64}.json"
        evaluation_path = root / evaluation_relative
        evaluation_path.parent.mkdir()
        evaluation_path.write_bytes(b"evaluation\n")
        evaluation = self._binding(evaluation_path, evaluation_relative)
        document = {
            "schema_version": "2.0.0",
            "artifact_kind": "p06_configuration_lock_v2",
            "status": "locked_before_p07",
            "locked_utc": self.LOCKED_UTC,
            "configuration_id": self.CONFIGURATION_ID,
            "candidate_vector_sha256": self.CANDIDATE_SHA256,
            "shared_bank_configuration_sha256": self.BANK_SHA256,
            "calibration_selection": selection,
            "selected_evaluation": evaluation,
            "configuration_files": [
                {"id": identifier, **release_lock._binding_fields(artifacts[identifier])}
                for identifier, _ in self.CONFIGURATION_FILES
            ],
            "candidate_bytes_rewritten_after_selection": False,
            "holdout_accessed": False,
        }
        self._publish(root, document)
        artifacts["calibration_selection"] = selection
        artifacts["selected_evaluation"] = evaluation
        artifacts["configuration_lock"] = self._binding(
            root / "configuration-lock-v2.json",
            "configuration-lock-v2.json",
        )
        bundle = {
            "locked_utc": self.LOCKED_UTC,
            "configuration_id": self.CONFIGURATION_ID,
        }
        return document, artifacts, selection, evaluation, bundle

    def _publish(self, root: Path, document: dict[str, object]) -> None:
        document.pop("manifest_sha256", None)
        document["manifest_sha256"] = release_lock._manifest_sha256(document)
        (root / "configuration-lock-v2.json").write_bytes(
            self._canonical(document)
        )

    def _cross_validate(
        self,
        root: Path,
        artifacts: dict[str, dict[str, object]],
        selection: dict[str, object],
        evaluation: dict[str, object],
        bundle: dict[str, object],
    ) -> None:
        artifacts["configuration_lock"] = self._binding(
            root / "configuration-lock-v2.json",
            "configuration-lock-v2.json",
        )
        release_lock._validate_p06_configuration_lock_v2_cross_bindings(
            release_root=root,
            binding=artifacts["configuration_lock"],
            bundle=bundle,
            artifacts=artifacts,
            selection_binding=selection,
            evaluation_binding=evaluation,
            candidate_vector_sha256=self.CANDIDATE_SHA256,
            shared_bank_configuration_sha256=self.BANK_SHA256,
        )

    def test_exact_schema_self_hash_file_reopen_and_cross_bindings_pass(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            _, artifacts, selection, evaluation, bundle = self._fixture(root)
            self._cross_validate(root, artifacts, selection, evaluation, bundle)

    def test_every_authority_field_and_order_mutation_is_rejected(self) -> None:
        mutations = {
            "locked_utc": lambda document: document.__setitem__(
                "locked_utc", "2026-07-16T12:00:01Z"
            ),
            "configuration_id": lambda document: document.__setitem__(
                "configuration_id", "ash-p06-v2-other"
            ),
            "candidate": lambda document: document.__setitem__(
                "candidate_vector_sha256", "d" * 64
            ),
            "shared_bank": lambda document: document.__setitem__(
                "shared_bank_configuration_sha256", "e" * 64
            ),
            "selection": lambda document: document["calibration_selection"].__setitem__(
                "sha256", "f" * 64
            ),
            "evaluation": lambda document: document["selected_evaluation"].__setitem__(
                "sha256", "1" * 64
            ),
            "file_order": lambda document: document["configuration_files"].reverse(),
            "file_hash": lambda document: document["configuration_files"][0].__setitem__(
                "sha256", "2" * 64
            ),
            "rewritten": lambda document: document.__setitem__(
                "candidate_bytes_rewritten_after_selection", True
            ),
            "holdout": lambda document: document.__setitem__(
                "holdout_accessed", True
            ),
        }
        for label, mutate in mutations.items():
            with self.subTest(label=label), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary).resolve()
                document, artifacts, selection, evaluation, bundle = self._fixture(root)
                changed = copy.deepcopy(document)
                mutate(changed)
                self._publish(root, changed)
                with self.assertRaises((release_lock.ReleaseLockError, ValueError)):
                    self._cross_validate(
                        root,
                        artifacts,
                        selection,
                        evaluation,
                        bundle,
                    )

    def test_noncanonical_bytes_and_unknown_fields_are_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            document, artifacts, selection, evaluation, bundle = self._fixture(root)
            payload = json.dumps(document, indent=2, sort_keys=True).encode("utf-8")
            (root / "configuration-lock-v2.json").write_bytes(payload)
            with self.assertRaisesRegex(
                release_lock.ReleaseLockError,
                "canonical one-LF",
            ):
                self._cross_validate(
                    root,
                    artifacts,
                    selection,
                    evaluation,
                    bundle,
                )

            document["unexpected"] = False
            self._publish(root, document)
            with self.assertRaisesRegex(
                release_lock.ReleaseLockError,
                "schema validation failed",
            ):
                self._cross_validate(
                    root,
                    artifacts,
                    selection,
                    evaluation,
                    bundle,
                )


if __name__ == "__main__":
    unittest.main()
