from __future__ import annotations

import hashlib
import json
from pathlib import Path
from types import SimpleNamespace
import tempfile
import unittest
from unittest import mock

from validation.calibration_v2 import runner
from validation.calibration_v2.shared_bank_artifacts_v2 import (
    SharedBankArtifactMaterializerV2,
)
from validation.quality.src.mirmir_quality.json_tools import (
    canonical_sha256,
    manifest_sha256,
)


class _LiveBinding:
    def __init__(self, verification: dict[str, object]) -> None:
        self.verification = verification

    def verify(self) -> dict[str, object]:
        return dict(self.verification)


class BoundInputsV2Tests(unittest.TestCase):
    def test_real_materializer_exposes_the_bound_plan_digests(self) -> None:
        repository_root = Path(__file__).resolve().parents[3]
        plan_path = (
            repository_root
            / "validation/calibration_v2/contracts/calibration-plan-v2.json"
        )
        plan_payload = plan_path.read_bytes()
        plan_document = json.loads(plan_payload)
        authenticated = SharedBankArtifactMaterializerV2(repository_root).plan

        self.assertEqual(
            authenticated.plan_file_sha256,
            hashlib.sha256(plan_payload).hexdigest(),
        )
        self.assertEqual(
            authenticated.plan_self_sha256,
            plan_document["plan_sha256"],
        )

    @staticmethod
    def _write_document(
        root: Path,
        relative: str,
        document: dict[str, object],
    ) -> dict[str, object]:
        path = root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        payload = (
            json.dumps(document, sort_keys=True, separators=(",", ":")) + "\n"
        ).encode("utf-8")
        path.write_bytes(payload)
        return {
            "path": relative,
            "sha256": hashlib.sha256(payload).hexdigest(),
            "size_bytes": len(payload),
        }

    @staticmethod
    def _self_hashed(
        document: dict[str, object],
        field: str,
    ) -> dict[str, object]:
        value = dict(document)
        value[field] = manifest_sha256(value, field)
        return value

    def _fixture(self, root: Path):
        plan_relative = (
            "validation/calibration_v2/contracts/calibration-plan-v2.json"
        )
        compiler_relative = (
            "validation/calibration_v2/contracts/compiler-contract-v2.json"
        )
        plan = self._self_hashed(
            {"schema_version": "2.0.1", "plan_sha256": None},
            "plan_sha256",
        )
        compiler = self._self_hashed(
            {"schema_version": "2.0.1", "artifact_sha256": None},
            "artifact_sha256",
        )
        plan_binding = self._write_document(root, plan_relative, plan)
        compiler_binding = self._write_document(
            root,
            compiler_relative,
            compiler,
        )
        old_plan = self._write_document(
            root,
            "legacy/calibration-plan-v1.json",
            {"schema_version": "1.0.0"},
        )
        old_compiler = self._write_document(
            root,
            "legacy/compiler-contract-v1.json",
            {"schema_version": "1.0.0"},
        )
        other = self._write_document(
            root,
            "locks/other.json",
            {"schema_version": "1.0.0"},
        )
        verification = {"verification_status": "pass"}
        legacy = SimpleNamespace(
            repository_root=root,
            records=(
                {"id": "calibration_plan", **old_plan},
                {"id": "compiler_contract", **old_compiler},
                {"id": "other", **other},
            ),
            documents={
                "calibration_plan": {"schema_version": "1.0.0"},
                "compiler_contract": {"schema_version": "1.0.0"},
                "other": {"schema_version": "1.0.0"},
            },
            live_holdout_preopen_binding=_LiveBinding(verification),
            live_holdout_preopen_verification=verification,
            verify_unchanged=mock.Mock(),
        )
        authenticated_plan = SimpleNamespace(
            plan_file_sha256=plan_binding["sha256"],
            plan_self_sha256=plan["plan_sha256"],
        )
        return legacy, authenticated_plan, plan_binding, compiler_binding

    def test_replaces_only_native_plan_and_compiler_from_one_preopen(self) -> None:
        with tempfile.TemporaryDirectory(
            prefix="mirmir-bound-inputs-v2-"
        ) as temporary:
            root = Path(temporary).resolve(strict=True)
            legacy, authenticated, plan_binding, compiler_binding = self._fixture(
                root
            )
            materializer = SimpleNamespace(plan=authenticated)
            with mock.patch.object(
                runner,
                "bind_preregistered_inputs",
                return_value=legacy,
            ), mock.patch.object(
                runner,
                "validate_schema",
            ), mock.patch(
                "validation.calibration_v2.shared_bank_artifacts_v2."
                "SharedBankArtifactMaterializerV2",
                return_value=materializer,
            ):
                native, evaluation = runner.bind_preregistered_inputs_v2(
                    root,
                    live_holdout_preopen_binding=object(),
                )

        self.assertIs(evaluation, legacy)
        self.assertEqual(
            native.record("calibration_plan")["path"],
            plan_binding["path"],
        )
        self.assertEqual(
            native.record("compiler_contract")["path"],
            compiler_binding["path"],
        )
        self.assertEqual(native.record("other"), legacy.records[2])
        self.assertEqual(
            native.bundle_sha256,
            canonical_sha256(
                {
                    "repository_file_bindings": list(native.records),
                    "live_holdout_preopen_verification": (
                        legacy.live_holdout_preopen_verification
                    ),
                }
            ),
        )
        legacy.verify_unchanged.assert_called_once_with()

    def test_rejects_schema_two_plan_that_differs_from_authenticated_plan(self) -> None:
        with tempfile.TemporaryDirectory(
            prefix="mirmir-bound-inputs-v2-mismatch-"
        ) as temporary:
            root = Path(temporary).resolve(strict=True)
            legacy, authenticated, _, _ = self._fixture(root)
            authenticated.plan_self_sha256 = "f" * 64
            with mock.patch.object(
                runner,
                "bind_preregistered_inputs",
                return_value=legacy,
            ), mock.patch.object(
                runner,
                "validate_schema",
            ), mock.patch(
                "validation.calibration_v2.shared_bank_artifacts_v2."
                "SharedBankArtifactMaterializerV2",
                return_value=SimpleNamespace(plan=authenticated),
            ), self.assertRaisesRegex(
                runner.CalibrationBindingError,
                "plan authentication differs",
            ):
                runner.bind_preregistered_inputs_v2(
                    root,
                    live_holdout_preopen_binding=object(),
                )


if __name__ == "__main__":
    unittest.main()
