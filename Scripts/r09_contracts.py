#!/usr/bin/env python3
"""Validate the frozen R09 bounded-residual authorization and start contracts."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import subprocess
import sys
from typing import Any, Iterable

from phase_evidence import (
    EMAIL_PATTERN,
    PRIVATE_EVIDENCE_KEYS,
    PRIVATE_PATH_PATTERN,
    decode_json,
    validate_json_schema_instance,
)
from r09_phase_acceptance import R09PhaseAcceptanceVerifier


REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
ROADMAP_PATH = Path("docs/roadmaps/Mirmir_Apple_Native_ASH_Roadmap_2026-07-18.json")
POLICY_PATH = Path(".github/roadmap-alignment-policy.json")
AUTHORIZATION_PATH = Path("docs/roadmaps/evidence/r09/records/operator-authorization.json")
AUTHORIZATION_SCHEMA_PATH = Path("docs/roadmaps/evidence/schema/r09-operator-authorization-v1.json")
PREREGISTRATION_PATH = Path("docs/roadmaps/evidence/r09/records/preregistration.json")
PREREGISTRATION_SCHEMA_PATH = Path("docs/roadmaps/evidence/schema/r09-preregistration-v1.json")
FIXTURE_CATALOG_PATH = Path("docs/roadmaps/evidence/r09/records/fixtures/fixture-catalog.json")
FIXTURE_CATALOG_SCHEMA_PATH = Path("docs/roadmaps/evidence/schema/r09-fixture-catalog-v1.json")
R08_ACCEPTANCE_PATH = Path("docs/roadmaps/evidence/r08/records/functional-phase-acceptance.json")

AUTHORIZATION_SEMANTIC_SHA256 = "152326edc6e877055c8f5ad205b933037fb895386cdfde2e5c6e85ca55a831b6"
PREREGISTRATION_SEMANTIC_SHA256 = "aea36c913c42b812c95b0e47b3d620f90e73008e89b0d186a9c85b8488f8ccf2"
PREREGISTRATION_SIZE_BYTES = 10911
PREREGISTRATION_RAW_SHA256 = "71b9a5938f14d872da23a81390d2d73e6e88a5253e14a348c6ebbfeb9bc9fe1b"
FIXTURE_CATALOG_SEMANTIC_SHA256 = "960065110d14208baf112f5307fcc4b0effd0e196e0e39e74a8306878936a711"
R08_RAW_SHA256 = "0d81917a93cf56cae867c11b7c65fb3c85e53b7596929cf9eec2ef09c24634b0"
R08_IMPLEMENTATION_COMMIT = "368b9284883c189be6a1139df6208bf0e88139dd"
R08_IMPLEMENTATION_TREE = "f8e73d193b7b0c9df7005a7aa006de48ca48f77c"
R08_BINDING = {
    "path": R08_ACCEPTANCE_PATH.as_posix(),
    "size_bytes": 12334,
    "raw_sha256": R08_RAW_SHA256,
    "phase_result": "passed",
    "acceptance": "accepted",
    "acceptance_scope": "declared_software_function_only",
    "implementation_commit": R08_IMPLEMENTATION_COMMIT,
    "implementation_tree": R08_IMPLEMENTATION_TREE,
}
POLICY_AUTHORIZATION = {
    "phase_id": "R09",
    "operator_directive": "resume_work",
    "core_ai_pixel_residual": "authorized_for_r09_bounded_experiment",
    "implementation_scope": "bounded_post_scaler_residual_software_contract",
    "accepted_r08_binding": R08_BINDING,
    "record_binding": {
        "path": AUTHORIZATION_PATH.as_posix(),
        "size_bytes": 1563,
        "sha256": "6e87a981ee4880d325b9db78bdb9d4dbfa1022a5194d3841e7c0c97e341e34a5",
    },
}
CHECK_IDS = (
    "accepted_r08_binding_exact",
    "operator_authorization_exact",
    "schemas_and_fixture_catalog_exact",
    "observation_policy_truthful",
    "proposal_identity_geometry_and_range_exact",
    "ash_authorization_and_bounds_exact",
    "source_temporal_and_protection_exact",
    "apple_only_transactional_fallback_exact",
    "lifecycle_cancellation_and_budget_exact",
    "comparison_methods_absent_non_authorizing",
)
STOP_RULE_IDS = (
    "accepted_r08_drift",
    "authorization_or_contract_byte_drift",
    "fabricated_native_or_model_observation",
    "provider_authority_or_final_frame_violation",
    "identity_geometry_range_or_plane_violation",
    "ash_authorization_or_bound_violation",
    "source_temporal_content_edge_or_hallucination_violation",
    "partial_application_or_rollback_violation",
    "comparison_gate_reintroduction",
    "production_or_claim_authority_expansion",
)
FAMILY_IDS = {
    "authorization_fixtures": (
        "authorization-valid-exact",
        "authorization-frame-shot-route-mismatch",
        "authorization-protected-region-excluded",
    ),
    "application_fixtures": (
        "proposal-bounded-mixed-sign",
        "proposal-hard-limit-boundary",
        "proposal-plane-limit-exceeded",
        "proposal-invalid-identity-count-or-range",
    ),
    "safety_fixtures": (
        "consistency-same-sign-bounded",
        "consistency-sign-mismatch",
        "safety-content-and-edge-bounds",
        "safety-hallucination-risk",
        "safety-low-confidence",
    ),
    "lifecycle_fixtures": (
        "lifecycle-deterministic-repeatability",
        "lifecycle-cancelled",
        "lifecycle-resource-boundary",
        "lifecycle-resource-exceeded",
    ),
    "boundary_fixtures": (
        "boundary-comparison-methods-absent",
        "boundary-native-observations-not-observed",
        "boundary-production-authority-absent",
    ),
}


def _sha256(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def _semantic_sha256(value: object) -> str:
    payload = json.dumps(
        value, ensure_ascii=False, separators=(",", ":"), sort_keys=True
    ).encode("utf-8")
    return _sha256(payload)


def _privacy_errors(value: object, context: str) -> list[str]:
    errors: list[str] = []

    def visit(item: object, location: str) -> None:
        if isinstance(item, dict):
            for key, nested in item.items():
                if str(key).lower() in PRIVATE_EVIDENCE_KEYS:
                    errors.append(f"{context} contains forbidden private key at {location}.{key}")
                visit(nested, f"{location}.{key}")
        elif isinstance(item, list):
            for index, nested in enumerate(item):
                visit(nested, f"{location}[{index}]")
        elif isinstance(item, str):
            if EMAIL_PATTERN.search(item):
                errors.append(f"{context} contains an email address at {location}")
            if PRIVATE_PATH_PATTERN.search(item):
                errors.append(f"{context} contains a private path at {location}")

    visit(value, "$")
    return errors


class R09ContractVerifier:
    def __init__(self, root: Path) -> None:
        self.root = root.resolve()

    def git(self, *arguments: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["git", *arguments], cwd=self.root, capture_output=True, check=False, text=True
        )

    def _read_json(self, relative: Path, context: str, errors: list[str]) -> dict[str, Any] | None:
        path = self.root / relative
        if path.is_symlink() or not path.is_file():
            errors.append(f"{context} must be a regular non-symlink file")
            return None
        try:
            value = decode_json(path.read_text(encoding="utf-8"))
        except (OSError, UnicodeDecodeError, ValueError) as error:
            errors.append(f"{context} is invalid: {error}")
            return None
        if not isinstance(value, dict):
            errors.append(f"{context} must be an object")
            return None
        return value

    def _read_and_validate(self, relative: Path, schema_relative: Path, context: str, errors: list[str]) -> dict[str, Any] | None:
        schema = self._read_json(schema_relative, f"{context} schema", errors)
        value = self._read_json(relative, context, errors)
        if schema is not None and value is not None:
            errors.extend(
                f"{context} schema: {error}"
                for error in validate_json_schema_instance(schema, value)
            )
        return value

    def _check_binding(self, value: object, expected_path: Path, context: str, errors: list[str]) -> None:
        if not isinstance(value, dict):
            errors.append(f"{context} must be an object")
            return
        path_value = value.get("path")
        if not isinstance(path_value, str) or PurePosixPath(path_value).as_posix() != path_value or PurePosixPath(path_value).is_absolute() or ".." in PurePosixPath(path_value).parts:
            errors.append(f"{context}.path must be normalized and repository-relative")
            return
        if path_value != expected_path.as_posix():
            errors.append(f"{context}.path differs")
            return
        target = self.root / path_value
        if target.is_symlink() or not target.is_file():
            errors.append(f"{context}.path must name a regular file")
            return
        payload = target.read_bytes()
        if value.get("size_bytes") != len(payload):
            errors.append(f"{context}.size_bytes differs")
        if value.get("sha256") != _sha256(payload):
            errors.append(f"{context}.sha256 differs")

    def _check_r08(self, value: object, errors: list[str]) -> None:
        if value != R08_BINDING:
            errors.append("accepted R08 binding differs")
            return
        record_path = self.root / R08_ACCEPTANCE_PATH
        if record_path.is_symlink() or not record_path.is_file():
            errors.append(
                "accepted R08 raw record must be a regular non-symlink file"
            )
        else:
            try:
                payload = record_path.read_bytes()
            except OSError as error:
                errors.append(f"accepted R08 raw record is unreadable: {error}")
            else:
                if (
                    len(payload) != R08_BINDING["size_bytes"]
                    or _sha256(payload) != R08_RAW_SHA256
                ):
                    errors.append("accepted R08 raw record differs")
        tree = self.git("show", "-s", "--format=%T", R08_IMPLEMENTATION_COMMIT)
        if tree.returncode != 0 or tree.stdout.strip() != R08_IMPLEMENTATION_TREE:
            errors.append("accepted R08 implementation commit or tree differs")
        if self.git("merge-base", "--is-ancestor", R08_IMPLEMENTATION_COMMIT, "HEAD").returncode != 0:
            errors.append("accepted R08 implementation commit is not an ancestor of HEAD")

    @staticmethod
    def _ids(value: object, context: str, errors: list[str]) -> tuple[str, ...]:
        if not isinstance(value, list):
            errors.append(f"{context} must be an array")
            return ()
        ids = tuple(item.get("id") for item in value if isinstance(item, dict) and isinstance(item.get("id"), str))
        if len(ids) != len(value) or len(ids) != len(set(ids)):
            errors.append(f"{context} IDs must be present and unique")
        return ids

    def check_authorization(self) -> list[str]:
        errors: list[str] = []
        value = self._read_and_validate(AUTHORIZATION_PATH, AUTHORIZATION_SCHEMA_PATH, "R09 operator authorization", errors)
        if value is not None:
            if _semantic_sha256(value) != AUTHORIZATION_SEMANTIC_SHA256:
                errors.append("R09 operator authorization semantic SHA-256 differs")
            self._check_r08(value.get("accepted_r08_binding"), errors)
            authorization = value.get("authorization")
            if not isinstance(authorization, dict) or authorization.get("core_ai_pixel_residual") != "authorized_for_r09_bounded_experiment":
                errors.append("R09 bounded-experiment authorization differs")
            errors.extend(_privacy_errors(value, "R09 operator authorization"))
        return errors

    def check_preregistration(self) -> list[str]:
        errors: list[str] = []
        value = self._read_and_validate(PREREGISTRATION_PATH, PREREGISTRATION_SCHEMA_PATH, "R09 preregistration", errors)
        if value is not None:
            payload = (self.root / PREREGISTRATION_PATH).read_bytes()
            if (
                len(payload) != PREREGISTRATION_SIZE_BYTES
                or _sha256(payload) != PREREGISTRATION_RAW_SHA256
            ):
                errors.append("R09 preregistration raw byte identity differs")
            if _semantic_sha256(value) != PREREGISTRATION_SEMANTIC_SHA256:
                errors.append("R09 preregistration semantic SHA-256 differs")
            self._check_r08(value.get("accepted_r08_binding"), errors)
            self._check_binding(value.get("operator_authorization"), AUTHORIZATION_PATH, "R09 authorization binding", errors)
            self._check_binding(value.get("fixture_catalog"), FIXTURE_CATALOG_PATH, "R09 fixture binding", errors)
            bindings = value.get("schema_bindings")
            if not isinstance(bindings, dict):
                errors.append("R09 schema bindings must be an object")
            else:
                for key, path in (("operator_authorization", AUTHORIZATION_SCHEMA_PATH), ("preregistration", PREREGISTRATION_SCHEMA_PATH), ("fixture_catalog", FIXTURE_CATALOG_SCHEMA_PATH)):
                    self._check_binding(bindings.get(key), path, f"R09 {key} schema binding", errors)
            if self._ids(value.get("checks"), "R09 checks", errors) != CHECK_IDS:
                errors.append("R09 check IDs differ")
            if self._ids(value.get("stop_rules"), "R09 stop rules", errors) != STOP_RULE_IDS:
                errors.append("R09 stop-rule IDs differ")
            acceptance = value.get("acceptance_policy")
            if not isinstance(acceptance, dict) or acceptance.get("acceptance_dependency") != "none" or any(acceptance.get(key) != "excluded_not_required_non_authorizing" for key in ("comparative_testing", "a_b_testing", "blinded_testing", "ablation_testing", "superiority_requirement")):
                errors.append("R09 comparison methods must remain excluded and non-authorizing")
            observation = value.get("observation_policy")
            if not isinstance(observation, dict) or observation.get("native_model_execution") != "not_observed" or observation.get("unavailable_native_execution_blocks_phase") is not False:
                errors.append("R09 native observation policy differs")
            boundary = value.get("authorization_boundary")
            if not isinstance(boundary, dict) or boundary.get("core_ai_pixel_residual") != "authorized_for_r09_bounded_experiment" or any(boundary.get(key) != "not_authorized" for key in ("production_default", "auto_mode", "holdout", "quality_claims", "performance_claims", "publication", "release")):
                errors.append("R09 authorization boundary differs")
            errors.extend(_privacy_errors(value, "R09 preregistration"))
        return errors

    def check_fixtures(self) -> list[str]:
        errors: list[str] = []
        value = self._read_and_validate(FIXTURE_CATALOG_PATH, FIXTURE_CATALOG_SCHEMA_PATH, "R09 fixture catalog", errors)
        if value is not None:
            if _semantic_sha256(value) != FIXTURE_CATALOG_SEMANTIC_SHA256:
                errors.append("R09 fixture catalog semantic SHA-256 differs")
            expected = {"raw_sha256": R08_RAW_SHA256, "implementation_commit": R08_IMPLEMENTATION_COMMIT, "implementation_tree": R08_IMPLEMENTATION_TREE}
            if value.get("accepted_r08_binding") != expected:
                errors.append("R09 fixture R08 binding differs")
            all_ids: list[str] = []
            for family, expected_ids in FAMILY_IDS.items():
                ids = self._ids(value.get(family), f"R09 {family}", errors)
                all_ids.extend(ids)
                if ids != expected_ids:
                    errors.append(f"R09 {family} IDs differ")
            if len(all_ids) != len(set(all_ids)):
                errors.append("R09 fixture IDs must be globally unique")
            parameters = value.get("fixture_parameters")
            if not isinstance(parameters, dict) or parameters.get("fixture_value_scope") != "software_test_inputs_not_product_or_quality_thresholds" or any(parameters.get(key) != "not_observed" for key in ("native_core_ai_execution", "model_asset_execution", "physical_hardware_execution", "simulator_execution", "operator_observation")):
                errors.append("R09 fixture observation or value scope differs")
            errors.extend(_privacy_errors(value, "R09 fixture catalog"))
        return errors

    def check_roadmap_policy(self) -> list[str]:
        errors: list[str] = []
        roadmap = self._read_json(ROADMAP_PATH, "canonical roadmap", errors)
        policy = self._read_json(POLICY_PATH, "roadmap alignment policy", errors)
        if roadmap is not None:
            if not isinstance(roadmap.get("authorizations"), dict) or roadmap["authorizations"].get("core_ai_pixel_residual") != "authorized_for_r09_bounded_experiment":
                errors.append("canonical R09 authorization differs")
            phase = next((item for item in roadmap.get("phases", []) if isinstance(item, dict) and item.get("id") == "R09"), None)
            status = phase.get("status") if isinstance(phase, dict) else None
            if status not in {"in_progress", "passed"}:
                errors.append("canonical R09 status must be in_progress or passed")
            elif status == "passed":
                errors.extend(R09PhaseAcceptanceVerifier(self.root).check())
        if policy is not None:
            if policy.get("r09_authorization") != POLICY_AUTHORIZATION:
                errors.append("roadmap policy R09 authorization differs")
            contract = policy.get("contract")
            if not isinstance(contract, dict) or not isinstance(contract.get("authorizations"), dict) or contract["authorizations"].get("core_ai_pixel_residual") != "authorized_for_r09_bounded_experiment":
                errors.append("roadmap policy canonical authorization contract differs")
        return errors


def emit_errors(errors: Iterable[str]) -> int:
    values = list(dict.fromkeys(errors))
    for error in values:
        print(f"ERROR: {error}", file=sys.stderr)
    return 1 if values else 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check-authorization", action="store_true")
    parser.add_argument("--check-preregistration", action="store_true")
    parser.add_argument("--check-fixtures", action="store_true")
    parser.add_argument("--check-roadmap-policy", action="store_true")
    parser.add_argument("--all", action="store_true")
    arguments = parser.parse_args(argv)
    explicit = any((arguments.check_authorization, arguments.check_preregistration, arguments.check_fixtures, arguments.check_roadmap_policy, arguments.all))
    check_all = arguments.all or not explicit
    verifier = R09ContractVerifier(REPOSITORY_ROOT)
    checks = (
        ("R09 authorization", arguments.check_authorization, verifier.check_authorization),
        ("R09 preregistration", arguments.check_preregistration, verifier.check_preregistration),
        ("R09 fixtures", arguments.check_fixtures, verifier.check_fixtures),
        ("R09 roadmap policy", arguments.check_roadmap_policy, verifier.check_roadmap_policy),
    )
    errors: list[str] = []
    ran: list[str] = []
    for label, selected, check in checks:
        if check_all or selected:
            ran.append(label)
            errors.extend(check())
    if not errors:
        for label in ran:
            print(f"{label}: PASS")
    return emit_errors(errors)


if __name__ == "__main__":
    raise SystemExit(main())
