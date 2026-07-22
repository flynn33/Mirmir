#!/usr/bin/env python3
"""Validate the frozen R08 Core AI analysis-only software contracts."""

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


REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
PREREGISTRATION_PATH = Path(
    "docs/roadmaps/evidence/r08/records/preregistration.json"
)
PREREGISTRATION_SCHEMA_PATH = Path(
    "docs/roadmaps/evidence/schema/r08-preregistration-v1.json"
)
FIXTURE_CATALOG_PATH = Path(
    "docs/roadmaps/evidence/r08/records/fixtures/fixture-catalog.json"
)
FIXTURE_CATALOG_SCHEMA_PATH = Path(
    "docs/roadmaps/evidence/schema/r08-fixture-catalog-v1.json"
)

PREREGISTRATION_SEMANTIC_SHA256 = (
    "eb5c6ba7c190d898e21e4c5ae1c9b0fb10ec0ebdee3828aec70b1f1b8fbd4805"
)
FIXTURE_CATALOG_SEMANTIC_SHA256 = (
    "1524a9c944ba49ae306dad032c89601e2ad655f781c562df8803801ba09f3d64"
)
PREDECESSOR = {
    "phase_id": "R07",
    "merge_commit": "3fd13e57ec95b1ed98df71f4c83ab165bdfbab6b",
    "merge_tree": "eb1614dd2a93e1bc4e1911bcf74f41cf372a3304",
    "predecessor_result": "passed",
    "acceptance_state": "operator_merged_accepted",
}
CATALOG_PREDECESSOR = {
    "phase_id": "R07",
    "merge_commit": PREDECESSOR["merge_commit"],
    "merge_tree": PREDECESSOR["merge_tree"],
}
PREREGISTRATION_TOP_LEVEL_KEYS = (
    "schema_version",
    "roadmap_version",
    "phase_id",
    "preregistration_state",
    "predecessor_binding",
    "observation_policy",
    "operator_acceptance_override",
    "fixture_catalog",
    "schema_bindings",
    "analysis_service_contract",
    "model_io_contract",
    "calibrated_output_contract",
    "scheduling_contract",
    "ash_context_integration_contract",
    "lifecycle_contract",
    "deterministic_fallback_contract",
    "checks",
    "stop_rules",
    "authorization_boundary",
)
FIXTURE_TOP_LEVEL_KEYS = (
    "schema_version",
    "phase_id",
    "contract_id",
    "predecessor_binding",
    "fixture_parameters",
    "calibrated_output_fixtures",
    "scheduling_fixtures",
    "integration_fixtures",
    "lifecycle_fixtures",
    "fallback_fixtures",
    "authorization_fixtures",
)
OUTPUT_HEAD_IDS = (
    "face_skin_protection_mask",
    "text_line_art_protection_mask",
    "animation_ui_content_likelihood",
    "noise_compression_severity_map",
    "blur_motion_blur_estimate",
    "aliasing_ringing_risk_map",
    "texture_detail_confidence",
    "motion_reliability_occlusion_risk",
    "no_reference_quality_estimate",
)
FALLBACK_TRIGGERS = (
    "unsupported_os",
    "framework_unavailable",
    "model_asset_absent",
    "identity_invalid",
    "output_invalid",
    "cancelled",
    "memory_budget_exceeded",
    "latency_budget_exceeded",
)
CHECK_IDS = (
    "predecessor_merge_exact",
    "schemas_and_fixture_catalog_exact",
    "observation_override_nonblocking",
    "analysis_only_module_boundary_exact",
    "calibrated_output_contract_exact",
    "pixel_output_and_control_forbidden",
    "scheduling_exact",
    "ash_context_integration_exact",
    "lifecycle_identity_cache_aot_zero_copy_exact",
    "state_cancellation_and_budgets_exact",
    "deterministic_fallback_exact",
    "comparative_requirement_superseded",
    "production_and_r09_authorization_forbidden",
)
STOP_RULE_IDS = (
    "predecessor_identity_drift",
    "contract_byte_drift",
    "fabricated_native_or_model_observation",
    "analysis_boundary_or_pixel_violation",
    "calibrated_output_violation",
    "scheduling_or_order_violation",
    "identity_cache_or_execution_form_violation",
    "state_cancellation_or_budget_violation",
    "fallback_violation",
    "comparative_gate_reintroduction",
    "authorization_boundary",
)
FAMILY_IDS = {
    "calibrated_output_fixtures": (
        "outputs-complete-nominal",
        "outputs-q15-boundaries",
        "outputs-missing-head",
        "outputs-duplicate-head",
        "outputs-unexpected-head",
        "outputs-q15-underflow",
        "outputs-q15-overflow",
        "outputs-spatial-count-mismatch",
        "outputs-scalar-count-mismatch",
    ),
    "scheduling_fixtures": (
        "schedule-ash-requested-frame",
        "schedule-keyframe",
        "schedule-periodic-proxy",
        "schedule-unscheduled-frame",
        "schedule-trigger-precedence",
        "schedule-duplicate-frame",
        "schedule-stale-frame",
    ),
    "integration_fixtures": (
        "integration-analysis-contribution",
        "integration-protected-mask-composition",
        "integration-pixel-frame-attempt",
        "integration-direct-backend-selection-attempt",
        "integration-incomplete-identity",
    ),
    "lifecycle_fixtures": (
        "lifecycle-specialization-cache-miss",
        "lifecycle-specialization-cache-hit",
        "lifecycle-aot-equivalence",
        "lifecycle-zero-copy-unavailable",
        "lifecycle-state-advance",
        "lifecycle-state-reset-scene-cut",
        "lifecycle-cancellation",
        "lifecycle-memory-budget-boundary",
        "lifecycle-memory-budget-exceeded",
        "lifecycle-latency-budget-boundary",
        "lifecycle-latency-budget-exceeded",
    ),
    "fallback_fixtures": tuple(
        f"fallback-{trigger.replace('_', '-')}" for trigger in FALLBACK_TRIGGERS
    ),
    "authorization_fixtures": (
        "authorization-comparison-superseded",
        "authorization-native-not-observed",
        "authorization-r09-residual-request",
        "authorization-production-default-request",
        "authorization-auto-request",
        "authorization-quality-claim-request",
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
                key_text = str(key)
                if key_text.lower() in PRIVATE_EVIDENCE_KEYS:
                    errors.append(
                        f"{context} contains forbidden private key at "
                        f"{location}.{key_text}"
                    )
                visit(nested, f"{location}.{key_text}")
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


class R08ContractVerifier:
    def __init__(self, root: Path) -> None:
        self.root = root.resolve()

    def git(self, *arguments: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["git", *arguments],
            cwd=self.root,
            capture_output=True,
            check=False,
            text=True,
        )

    def _read_json(
        self, relative: Path, context: str, errors: list[str]
    ) -> dict[str, Any] | None:
        target = self.root / relative
        if target.is_symlink() or not target.is_file():
            errors.append(f"{context} must be a regular non-symlink file")
            return None
        try:
            value = decode_json(target.read_text(encoding="utf-8"))
        except (OSError, UnicodeDecodeError, ValueError) as error:
            errors.append(f"{context} is invalid: {error}")
            return None
        if not isinstance(value, dict):
            errors.append(f"{context} must be an object")
            return None
        return value

    def _read_and_validate(
        self,
        relative: Path,
        schema_relative: Path,
        context: str,
        errors: list[str],
    ) -> dict[str, Any] | None:
        schema = self._read_json(schema_relative, f"{context} schema", errors)
        value = self._read_json(relative, context, errors)
        if schema is not None and value is not None:
            errors.extend(
                f"{context} schema: {error}"
                for error in validate_json_schema_instance(schema, value)
            )
        return value

    @staticmethod
    def _normalized_path(
        value: object, context: str, errors: list[str]
    ) -> str | None:
        if not isinstance(value, str) or not value or "\x00" in value:
            errors.append(f"{context}.path must be a non-empty normalized path")
            return None
        pure = PurePosixPath(value)
        if pure.is_absolute() or ".." in pure.parts or pure.as_posix() != value:
            errors.append(f"{context}.path must be normalized and repository-relative")
            return None
        return value

    def _check_binding(
        self,
        value: object,
        expected_path: Path,
        context: str,
        errors: list[str],
    ) -> None:
        if not isinstance(value, dict):
            errors.append(f"{context} must be an object")
            return
        path_text = self._normalized_path(value.get("path"), context, errors)
        if path_text is None:
            return
        if path_text != expected_path.as_posix():
            errors.append(f"{context}.path differs from the frozen path")
            return
        target = self.root / path_text
        if target.is_symlink() or not target.is_file():
            errors.append(f"{context}.path must name a regular non-symlink file")
            return
        payload = target.read_bytes()
        if value.get("size_bytes") != len(payload):
            errors.append(f"{context}.size_bytes differs from the file")
        if value.get("sha256") != _sha256(payload):
            errors.append(f"{context}.sha256 differs from the file")

    def _check_predecessor(self, value: object, errors: list[str]) -> None:
        if value != PREDECESSOR:
            errors.append("R08 predecessor binding differs from the accepted R07 merge")
            return
        commit = PREDECESSOR["merge_commit"]
        tree = self.git("show", "-s", "--format=%T", commit)
        if tree.returncode != 0:
            errors.append("accepted R07 merge commit is unavailable")
            return
        if tree.stdout.strip() != PREDECESSOR["merge_tree"]:
            errors.append("accepted R07 merge tree differs from the frozen tree")
        parents = self.git("show", "-s", "--format=%P", commit)
        if parents.returncode != 0 or len(parents.stdout.split()) != 2:
            errors.append("accepted R07 predecessor must remain a two-parent merge")
        ancestor = self.git("merge-base", "--is-ancestor", commit, "HEAD")
        if ancestor.returncode != 0:
            errors.append("accepted R07 merge commit must be an ancestor of HEAD")

    @staticmethod
    def _ids(value: object, context: str, errors: list[str]) -> tuple[str, ...]:
        if not isinstance(value, list):
            errors.append(f"{context} must be an array")
            return ()
        identifiers: list[str] = []
        for index, item in enumerate(value):
            if not isinstance(item, dict) or not isinstance(item.get("id"), str):
                errors.append(f"{context}[{index}].id must be a string")
                continue
            identifiers.append(item["id"])
        if len(identifiers) != len(set(identifiers)):
            errors.append(f"{context} contains duplicate IDs")
        return tuple(identifiers)

    def _check_preregistration_semantics(
        self, value: dict[str, Any], errors: list[str]
    ) -> None:
        if tuple(value) != PREREGISTRATION_TOP_LEVEL_KEYS:
            errors.append("R08 preregistration top-level keys or order differ")
        if _semantic_sha256(value) != PREREGISTRATION_SEMANTIC_SHA256:
            errors.append("R08 preregistration semantic SHA-256 differs")
        self._check_predecessor(value.get("predecessor_binding"), errors)
        self._check_binding(
            value.get("fixture_catalog"),
            FIXTURE_CATALOG_PATH,
            "R08 fixture catalog binding",
            errors,
        )
        bindings = value.get("schema_bindings")
        if not isinstance(bindings, dict):
            errors.append("R08 schema_bindings must be an object")
        else:
            self._check_binding(
                bindings.get("preregistration"),
                PREREGISTRATION_SCHEMA_PATH,
                "R08 preregistration schema binding",
                errors,
            )
            self._check_binding(
                bindings.get("fixture_catalog"),
                FIXTURE_CATALOG_SCHEMA_PATH,
                "R08 fixture catalog schema binding",
                errors,
            )
        outputs = value.get("calibrated_output_contract")
        if isinstance(outputs, dict):
            actual_heads = self._ids(
                outputs.get("output_heads"), "R08 output_heads", errors
            )
            if actual_heads != OUTPUT_HEAD_IDS:
                errors.append("R08 calibrated output head order differs")
        else:
            errors.append("R08 calibrated_output_contract must be an object")
        fallback = value.get("deterministic_fallback_contract")
        if not isinstance(fallback, dict) or tuple(fallback.get("triggers", ())) != FALLBACK_TRIGGERS:
            errors.append("R08 deterministic fallback triggers differ")
        if self._ids(value.get("checks"), "R08 checks", errors) != CHECK_IDS:
            errors.append("R08 check IDs differ")
        if self._ids(value.get("stop_rules"), "R08 stop rules", errors) != STOP_RULE_IDS:
            errors.append("R08 stop-rule IDs differ")
        override = value.get("operator_acceptance_override")
        expected_override = {
            "comparative_requirement": "superseded_not_required",
            "blinded_ablation_requirement": "superseded_not_required",
            "comparison_evidence": "not_required",
            "acceptance_authority": "deterministic_software_function_verification_only",
            "quality_claims": "forbidden",
            "performance_claims": "forbidden",
        }
        if override != expected_override:
            errors.append("R08 operator acceptance override differs")
        service = value.get("analysis_service_contract")
        if not isinstance(service, dict) or any(
            service.get(key) != "forbidden" for key in ("pixel_output", "pixel_control")
        ):
            errors.append("R08 pixel output and control must remain forbidden")
        authorization = value.get("authorization_boundary")
        if not isinstance(authorization, dict) or authorization.get(
            "r09_residual_execution"
        ) != "forbidden_requires_separate_operator_authorization":
            errors.append("R08 must not authorize R09 residual execution")
        errors.extend(_privacy_errors(value, "R08 preregistration"))

    def _check_fixture_semantics(
        self, value: dict[str, Any], errors: list[str]
    ) -> None:
        if tuple(value) != FIXTURE_TOP_LEVEL_KEYS:
            errors.append("R08 fixture catalog top-level keys or order differ")
        if _semantic_sha256(value) != FIXTURE_CATALOG_SEMANTIC_SHA256:
            errors.append("R08 fixture catalog semantic SHA-256 differs")
        if value.get("predecessor_binding") != CATALOG_PREDECESSOR:
            errors.append("R08 fixture predecessor differs from the accepted R07 merge")
        all_ids: list[str] = []
        for family, expected_ids in FAMILY_IDS.items():
            actual_ids = self._ids(value.get(family), f"R08 {family}", errors)
            all_ids.extend(actual_ids)
            if actual_ids != expected_ids:
                errors.append(f"R08 {family} IDs or order differ")
        if len(all_ids) != len(set(all_ids)):
            errors.append("R08 fixture IDs must be globally unique")
        parameters = value.get("fixture_parameters")
        if not isinstance(parameters, dict) or parameters.get("native_execution") != "not_observed":
            errors.append("R08 native fixture execution must remain not_observed")
        errors.extend(_privacy_errors(value, "R08 fixture catalog"))

    def check_preregistration(self) -> list[str]:
        errors: list[str] = []
        value = self._read_and_validate(
            PREREGISTRATION_PATH,
            PREREGISTRATION_SCHEMA_PATH,
            "R08 preregistration",
            errors,
        )
        if value is not None:
            self._check_preregistration_semantics(value, errors)
        return errors

    def check_fixtures(self) -> list[str]:
        errors: list[str] = []
        value = self._read_and_validate(
            FIXTURE_CATALOG_PATH,
            FIXTURE_CATALOG_SCHEMA_PATH,
            "R08 fixture catalog",
            errors,
        )
        if value is not None:
            self._check_fixture_semantics(value, errors)
        return errors


def emit_errors(errors: Iterable[str]) -> int:
    values = list(dict.fromkeys(errors))
    for error in values:
        print(f"ERROR: {error}", file=sys.stderr)
    return 1 if values else 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check-preregistration", action="store_true")
    parser.add_argument("--check-fixtures", action="store_true")
    parser.add_argument("--all", action="store_true")
    arguments = parser.parse_args(argv)
    explicit = any(
        (
            arguments.check_preregistration,
            arguments.check_fixtures,
            arguments.all,
        )
    )
    check_all = arguments.all or not explicit
    verifier = R08ContractVerifier(REPOSITORY_ROOT)
    errors: list[str] = []
    if check_all or arguments.check_preregistration:
        errors.extend(verifier.check_preregistration())
    if check_all or arguments.check_fixtures:
        errors.extend(verifier.check_fixtures())
    if not errors:
        if check_all or arguments.check_preregistration:
            print("R08 preregistration: PASS")
        if check_all or arguments.check_fixtures:
            print("R08 fixtures: PASS")
    return emit_errors(errors)


if __name__ == "__main__":
    raise SystemExit(main())
