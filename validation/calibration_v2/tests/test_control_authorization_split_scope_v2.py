from __future__ import annotations

from copy import deepcopy
import hashlib
import json
from pathlib import Path
import unittest

from jsonschema import Draft202012Validator

from validation.calibration_v2.control_authorization_v2 import (
    CONTROL_AUTHORIZATION_BUNDLE_KIND,
    VALIDATION_ADMISSION_KIND,
    ControlAuthorizationScopeV2,
    ControlAuthorizationV2Error,
    TypedArtifactBindingV2,
    authority_bindings_v2,
    finalize_control_authorization_bundle_v2,
    schema_sha256_for_kind_v2,
)


ROOT = Path(__file__).resolve().parents[1]
BUNDLE_SCHEMA_PATH = (
    ROOT / "schemas/p06-control-authorization-bundle-v2.schema.json"
)
BUNDLE_SCHEMA_SHA256 = (
    "9b6aa34dd923752fa12f4938a948a43665953b34fae23485e99a249ad5ff29a6"
)
ADMISSION_SCHEMA_SHA256 = (
    "8ba2c914ba2aa1619a6c6cc7e43f823102c79468b099778447e5e5c9d1981f3f"
)


def _digest(label: str) -> str:
    return hashlib.sha256(label.encode("utf-8")).hexdigest()


def _typed(kind: str, path: str, *, schema: str | None = None) -> dict[str, object]:
    payload = f"{kind}:{path}\n".encode("utf-8")
    return {
        "artifact_kind": kind,
        "schema_sha256": schema or _digest(f"schema:{kind}"),
        "path": path,
        "sha256": hashlib.sha256(payload).hexdigest(),
        "size_bytes": len(payload),
    }


class ControlAuthorizationSplitScopeV2Tests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        payload = BUNDLE_SCHEMA_PATH.read_bytes()
        cls.schema = json.loads(payload)
        cls.validator = Draft202012Validator(cls.schema)
        cls.shared_bank = _digest("shared-bank")
        cls.degradation = _digest("degradation")
        cls.development_matrix = _digest("development-matrix")
        cls.validation_matrix = _digest("validation-matrix")
        cls.admission = TypedArtifactBindingV2.from_document(
            _typed(
                VALIDATION_ADMISSION_KIND,
                "admission/validation-candidate-development-evidence-v2.json",
                schema=ADMISSION_SCHEMA_SHA256,
            )
        )

    def test_schema_digest_and_runtime_pin_are_exact(self) -> None:
        self.assertEqual(
            hashlib.sha256(BUNDLE_SCHEMA_PATH.read_bytes()).hexdigest(),
            BUNDLE_SCHEMA_SHA256,
        )
        self.assertEqual(
            schema_sha256_for_kind_v2(CONTROL_AUTHORIZATION_BUNDLE_KIND),
            BUNDLE_SCHEMA_SHA256,
        )
        self.assertEqual(
            schema_sha256_for_kind_v2(VALIDATION_ADMISSION_KIND),
            ADMISSION_SCHEMA_SHA256,
        )

    def test_scope_discriminates_development_and_validation(self) -> None:
        development = ControlAuthorizationScopeV2(
            run_id="run-scope",
            split="development",
            shared_bank_configuration_sha256=self.shared_bank,
            degradation_policy_sha256=self.degradation,
            source_profile_matrix_sha256=self.development_matrix,
        )
        self.assertEqual(development.development_scope(), development)

        validation = ControlAuthorizationScopeV2(
            run_id="run-scope",
            split="validation",
            shared_bank_configuration_sha256=self.shared_bank,
            degradation_policy_sha256=self.degradation,
            source_profile_matrix_sha256=self.validation_matrix,
            development_source_profile_matrix_sha256=(
                self.development_matrix
            ),
            validation_admission=self.admission,
        )
        self.assertEqual(
            validation.development_scope().source_profile_matrix_sha256,
            self.development_matrix,
        )
        self.assertIsNone(
            validation.development_scope().validation_admission
        )

        with self.assertRaisesRegex(
            ControlAuthorizationV2Error,
            "development control scope contains validation predecessors",
        ):
            ControlAuthorizationScopeV2(
                run_id="run-scope",
                split="development",
                shared_bank_configuration_sha256=self.shared_bank,
                degradation_policy_sha256=self.degradation,
                source_profile_matrix_sha256=self.development_matrix,
                validation_admission=self.admission,
            )
        with self.assertRaisesRegex(
            ControlAuthorizationV2Error,
            "validation control scope predecessors are invalid",
        ):
            ControlAuthorizationScopeV2(
                run_id="run-scope",
                split="validation",
                shared_bank_configuration_sha256=self.shared_bank,
                degradation_policy_sha256=self.degradation,
                source_profile_matrix_sha256=self.validation_matrix,
                development_source_profile_matrix_sha256=(
                    self.validation_matrix
                ),
                validation_admission=self.admission,
            )

    def _bundle(self, *, split: str) -> dict[str, object]:
        controls = [
            {
                "id": "best_fixed",
                "selection": _typed(
                    "p06_fixed_control_selection_v2",
                    "controls/fixed.json",
                ),
            },
            {
                "id": "conventional",
                "selection": _typed(
                    "p06_conventional_control_selection_v2",
                    "controls/conventional.json",
                ),
            },
            {
                "id": "non_ash_selector",
                "selection": _typed(
                    "p06_non_ash_selector_selection_v2",
                    "controls/non-ash.json",
                ),
            },
        ]
        predecessors = {
            "development_ledger": _typed(
                "p06_non_ash_selector_attempt_ledger_v2",
                "controls/non-ash-development-ledger.json",
            )
        }
        if split == "validation":
            predecessors.update(
                {
                    "development_selection": _typed(
                        "p06_non_ash_selector_selection_v2",
                        "controls/non-ash-development-selection.json",
                    ),
                    "validation_neighbor_manifest": _typed(
                        "p06_non_ash_validation_neighbor_manifest_v2",
                        "controls/non-ash-validation-neighbors.json",
                    ),
                }
            )
        dependencies = sorted(
            [
                entry["selection"] for entry in controls
            ]
            + list(predecessors.values())
            + (
                [self.admission.as_document()]
                if split == "validation"
                else []
            ),
            key=lambda value: value["path"],
        )
        document: dict[str, object] = {
            "schema_version": "2.0.1",
            "artifact_kind": CONTROL_AUTHORIZATION_BUNDLE_KIND,
            "authority_bindings": authority_bindings_v2(),
            "run_id": "run-scope",
            "split": split,
            "shared_bank_configuration_sha256": self.shared_bank,
            "degradation_policy_sha256": self.degradation,
            "source_profile_matrix_sha256": (
                self.development_matrix
                if split == "development"
                else self.validation_matrix
            ),
            "control_selections": controls,
            "non_ash_predecessors": predecessors,
            "dependency_bindings": dependencies,
            "dependency_set_sha256": _digest("placeholder-dependencies"),
            "authorization_semantic_sha256": _digest(
                "placeholder-authorization"
            ),
            "data_access": {
                "development_metrics_accessed": True,
                "validation_accessed": split == "validation",
                "holdout_accessed": False,
                "media_payloads_accessed": False,
                "release_locks_written": False,
                "winner_claim_made": False,
            },
            "artifact_sha256": _digest("placeholder-artifact"),
        }
        if split == "validation":
            document.update(
                {
                    "development_source_profile_matrix_sha256": (
                        self.development_matrix
                    ),
                    "validation_admission": self.admission.as_document(),
                }
            )
        return finalize_control_authorization_bundle_v2(document)

    def test_bundle_schema_has_exact_split_conditional(self) -> None:
        for split in ("development", "validation"):
            with self.subTest(split=split):
                self.assertEqual(
                    list(self.validator.iter_errors(self._bundle(split=split))),
                    [],
                )

        development_with_admission = self._bundle(split="development")
        development_with_admission["validation_admission"] = (
            self.admission.as_document()
        )
        self.assertTrue(
            list(self.validator.iter_errors(development_with_admission))
        )

        validation_without_development_matrix = self._bundle(
            split="validation"
        )
        del validation_without_development_matrix[
            "development_source_profile_matrix_sha256"
        ]
        self.assertTrue(
            list(
                self.validator.iter_errors(
                    validation_without_development_matrix
                )
            )
        )

        wrong_admission_schema = self._bundle(split="validation")
        wrong_admission_schema["validation_admission"][
            "schema_sha256"
        ] = _digest("invented-admission-schema")
        self.assertTrue(
            list(self.validator.iter_errors(wrong_admission_schema))
        )


if __name__ == "__main__":
    unittest.main()
