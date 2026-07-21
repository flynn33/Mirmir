#!/usr/bin/env python3
"""Validate the frozen R02 architecture and deterministic fixture contracts."""

from __future__ import annotations

import argparse
from fractions import Fraction
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
from r02_fixture_generator import (
    GENERATOR_CONTRACT,
    NV12_GENERATOR_ID,
    PCM_GENERATOR_ID,
    nv12_frame_bytes,
    pcm_s16le_bytes,
)


REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
PREREGISTRATION_PATH = Path(
    "docs/roadmaps/evidence/r02/records/preregistration.json"
)
PREREGISTRATION_SCHEMA_PATH = Path(
    "docs/roadmaps/evidence/schema/r02-preregistration-v1.json"
)
FIXTURE_CATALOG_PATH = Path(
    "docs/roadmaps/evidence/r02/records/fixtures/fixture-catalog.json"
)
FIXTURE_CATALOG_SCHEMA_PATH = Path(
    "docs/roadmaps/evidence/schema/r02-fixture-catalog-v1.json"
)
CONFORMANCE_PATH = Path(
    "docs/roadmaps/evidence/r02/records/conformance.json"
)
CONFORMANCE_SCHEMA_PATH = Path(
    "docs/roadmaps/evidence/schema/r02-session-conformance-v1.json"
)
ROADMAP_PATH = Path(
    "docs/roadmaps/Mirmir_Apple_Native_ASH_Roadmap_2026-07-18.json"
)
R01_PHASE_EVIDENCE_PATH = Path("docs/roadmaps/evidence/r01/phase-evidence.json")
R01_CAPABILITY_MATRIX_PATH = Path("project-notes/apple-upscale-capabilities.json")
FIXTURE_GENERATOR_PATH = Path("Scripts/r02_fixture_generator.py")
R02_SCHEMA_PATHS = {
    "preregistration": PREREGISTRATION_SCHEMA_PATH,
    "fixture_catalog": FIXTURE_CATALOG_SCHEMA_PATH,
    "conformance": CONFORMANCE_SCHEMA_PATH,
}
EXPECTED_R02_SCHEMA_BINDINGS = {
    "conformance": {
        "path": CONFORMANCE_SCHEMA_PATH.as_posix(),
        "size_bytes": 13488,
        "sha256": "da1bee31e4b797cc09f99f11c549398fe470797e0337d7fcbed3de5068568991",
    },
    "fixture_catalog": {
        "path": FIXTURE_CATALOG_SCHEMA_PATH.as_posix(),
        "size_bytes": 9214,
        "sha256": "fd61b61fb62b0b5c209f095649fd6315bb21e694059a9807e593c7bae5949d30",
    },
    "preregistration": {
        "path": PREREGISTRATION_SCHEMA_PATH.as_posix(),
        "size_bytes": 13233,
        "sha256": "c74e09d7f6e07473be7b41084ed2e9404b8029ba8c463fd402650a99f2f654ae",
    },
}

PREREGISTRATION_KEYS = frozenset(
    {
        "schema_version",
        "roadmap_version",
        "phase_id",
        "preregistration_state",
        "predecessor_binding",
        "observation_policy",
        "fixture_catalog",
        "contract",
        "metrics",
        "stop_rules",
        "authorization_boundary",
    }
)
CATALOG_KEYS = frozenset(
    {"schema_version", "phase_id", "generator_contract", "fixtures", "scenarios"}
)
CONFORMANCE_KEYS = frozenset(
    {
        "schema_version",
        "roadmap_version",
        "phase_id",
        "evidence_kind",
        "source",
        "preregistration_binding",
        "fixture_catalog_binding",
        "observation_status",
        "backend_runs",
        "outcome_coverage",
        "checks",
        "result",
        "limitations",
    }
)
PREDECESSOR_KEYS = frozenset(
    {
        "phase_id",
        "closure_state",
        "closure_commit",
        "closure_tree",
        "accepted_merge_commit",
        "acceptance_state",
        "continuation_scope",
    }
)
EXPECTED_PREDECESSOR = {
    "phase_id": "R01",
    "closure_state": "local_unpublished_closure",
    "closure_commit": "555ae5a1afce1e492bdc89b6b14f2ba269edc524",
    "closure_tree": "2fbe72d85ace42cc925c45b17d53dd8866a8275b",
    "accepted_merge_commit": None,
    "acceptance_state": "not_claimed",
    "continuation_scope": "local_implementation_only",
}
EXPECTED_OBSERVATION_POLICY = {
    "requirement": "waived_not_a_blocker",
    "hardware_capability_observation": "not_observed",
    "simulator_execution": "not_observed",
    "operator_observed_operation": "not_observed",
    "deterministic_software_conformance": "required",
    "performance_claims": "forbidden",
}
EXPECTED_AUTHORIZATION_BOUNDARY = {
    "production_upscaling": "unavailable",
    "auto_mode": "blocked",
    "holdout": "blocked",
    "release": "not_authorized",
    "publication": "not_authorized_by_this_record",
    "performance_claims": "forbidden",
}
FRAME_FIELDS = (
    "sequence_number",
    "pixel_buffer",
    "presentation_timestamp",
    "duration",
    "color_description",
    "metadata_identity",
    "resource_lifetime_token",
)
OUTCOMES = (
    "processed",
    "unavailable",
    "rejected",
    "failed",
    "fallback_applied",
)
STAGE_PROTOCOLS = (
    "preprocessing",
    "primary_scaling",
    "postprocessing",
    "temporal",
    "analysis",
)
PROCESSING_IDENTITY_FIELDS = (
    "backend_id",
    "backend_revision",
    "model_assets_identity",
    "configuration_identity",
    "policy_identity",
    "fallback_history",
    "material_decision_identity",
)
LIFECYCLE_CONTRACTS = (
    (
        "backend_creation",
        "AppleUpscaleBackend is Sendable, exposes immutable structured identity and explicit capability lookup, and asynchronously creates a session from validated configuration and context.",
    ),
    (
        "actor_isolation",
        "AppleUpscaleSession is actor-isolated and serializes submit, reset, finish, and cancel through one FIFO operation boundary despite actor reentrancy.",
    ),
    (
        "frame_ownership",
        "Every admitted frame retains the complete frozen frame contract until a typed outcome transfers or releases ownership.",
    ),
    (
        "typed_outcomes",
        "Every output is exactly processed, unavailable, rejected, failed, or fallback-applied and carries complete structured processing identity.",
    ),
    (
        "reset_semantics",
        "Reset drains earlier work, clears temporal history, advances history generation, and preserves clip-global sequence numbering.",
    ),
    (
        "cancel_semantics",
        "Cancellation is idempotent, closes admission, rejects queued work, waits for active work to quiesce, and releases resources exactly once.",
    ),
    (
        "finish_semantics",
        "Finish installs an admission fence, drains ordered work, finalizes once, caches its result, and rejects later mutation.",
    ),
    (
        "fallback_visibility",
        "Fallback is selected only by the planner or orchestrator and visibly links the failed route to the selected route.",
    ),
)
SCENARIO_CONTRACTS = (
    ("concurrent_fifo", "Concurrent submissions reach the driver in FIFO order with maximum driver concurrency one."),
    ("actor_reentrancy", "A suspended driver call cannot be bypassed by actor reentrancy."),
    ("reset_ordering", "Reset orders after earlier submissions and before later submissions while clearing history."),
    ("finish_drain_and_fence", "Finish drains admitted work, installs a fence, and finalizes the driver once."),
    ("active_cancel", "Cancellation closes admission, cancels active work, rejects queued work, and terminalizes once."),
    ("stale_completion", "A late success from cancelled work cannot reopen or mutate the terminal session."),
    ("resource_lifetime", "Every input and output lifetime token releases exactly once on success, failure, rejection, and cancellation paths."),
    ("sequence_and_timing", "Duplicate sequence, nonmonotonic PTS, and invalid duration reject before reaching the driver."),
    ("planner_determinism", "Exactly one primary stage is selected and stage order is deterministic."),
    ("fallback_linkage", "Fallback is explicit and links failed and selected route identities without backend-local substitution."),
    ("multiple_backend_fixture", "Both deterministic fixture backends use the same session contract and preserve dimensions, frame order, PTS, and duration."),
    ("audio_metadata_identity", "Audio and metadata fixture identities are preserved by the media transaction."),
    ("reopen_verification", "Output is reopened and verified before publication."),
    ("atomic_publication", "Cancellation or verification failure prevents atomic destination publication."),
    ("production_unavailable", "Production dependency composition remains the unavailable upscaler service."),
)
METRIC_CONTRACTS = (
    ("dimension_mismatch_count", "count", "lower_is_better", "equal", 0),
    ("frame_order_violation_count", "count", "lower_is_better", "equal", 0),
    ("pts_mismatch_count", "count", "lower_is_better", "equal", 0),
    ("duration_mismatch_count", "count", "lower_is_better", "equal", 0),
    ("audio_identity_mismatch_count", "count", "lower_is_better", "equal", 0),
    ("metadata_identity_mismatch_count", "count", "lower_is_better", "equal", 0),
    ("resource_lifetime_violation_count", "count", "lower_is_better", "equal", 0),
    ("lifecycle_violation_count", "count", "lower_is_better", "equal", 0),
    ("silent_fallback_count", "count", "lower_is_better", "equal", 0),
    ("incomplete_identity_count", "count", "lower_is_better", "equal", 0),
    ("atomic_publication_violation_count", "count", "lower_is_better", "equal", 0),
    ("backend_count", "count", "higher_is_better", "greater_than_or_equal", 2),
    ("fixture_count", "count", "higher_is_better", "greater_than_or_equal", 2),
    ("primary_backend_count", "count", "higher_is_better", "equal", 1),
    ("outcome_case_count", "count", "higher_is_better", "equal", 5),
    ("color_identity_mismatch_count", "count", "lower_is_better", "equal", 0),
    ("terminalizations_per_session", "count", "higher_is_better", "equal", 1),
    ("production_backend_count", "count", "lower_is_better", "equal", 0),
)
STOP_RULE_CONTRACTS = (
    ("identity_drift", "Stop this preregistered run if the local R01 closure commit or tree binding changes."),
    ("fixture_or_schema_drift", "Stop if a fixture, schema, generator, or catalog byte changes without a new preregistration."),
    ("media_contract_violation", "Stop closure when frame order, dimensions, PTS, duration, audio, or metadata identity differs."),
    ("lifecycle_violation", "Stop closure on session serialization, reset, finish, cancellation, or resource-lifetime violation."),
    ("silent_fallback", "Stop closure on backend-local fallback, unlinked fallback, or any other silent substitution."),
    ("incomplete_identity", "Stop closure when an outcome lacks backend, revision, configuration, policy, model or not-required, asset, fallback, or ASH decision identity."),
    ("production_reachability", "Stop closure if production composition can reach an R02 fixture or retained comparator backend."),
    ("publication_boundary", "Stop closure if reopen verification or atomic publication behavior is bypassed."),
    ("fabricated_observation", "Stop any hardware, simulator, runtime-support, performance, memory, or quality claim not directly measured and bound to evidence."),
    ("authorization_boundary", "Stop publication, acceptance, holdout, production Auto, claim, tag, or release action without its separate direct authority."),
)
FIXTURE_IDS = (
    "fixture-sequence-a",
    "fixture-sequence-b",
    "fixture-media-transaction",
)
CATALOG_SCENARIO_IDS = (
    "multiple_backends_common_session",
    "session_lifecycle",
    "typed_outcomes_and_fallback",
    "media_transaction_preservation",
)
FIXTURE_BACKEND_IDS = ("r02.fixture.copy-a", "r02.fixture.copy-b")
CONFORMANCE_IDENTITY_KEYS = frozenset(
    {
        "backend_id",
        "backend_revision",
        "model_assets_identity",
        "configuration_identity",
        "policy_identity",
        "fallback_history",
        "material_decision_identity",
    }
)
EXPECTED_CONFORMANCE_LIMITATIONS = (
    "hardware_capability_observation_not_observed",
    "simulator_execution_not_observed",
    "operator_observed_operation_not_observed",
    "performance_not_measured_no_claim",
)
EXPECTED_CONFORMANCE_OBSERVATION_STATUS = {
    **EXPECTED_OBSERVATION_POLICY,
    "deterministic_software_conformance": "passed",
}
EXPECTED_CONFORMANCE_METRIC_VALUES = {
    "dimension_mismatch_count": 0,
    "frame_order_violation_count": 0,
    "pts_mismatch_count": 0,
    "duration_mismatch_count": 0,
    "audio_identity_mismatch_count": 0,
    "metadata_identity_mismatch_count": 0,
    "resource_lifetime_violation_count": 0,
    "lifecycle_violation_count": 0,
    "silent_fallback_count": 0,
    "incomplete_identity_count": 0,
    "atomic_publication_violation_count": 0,
    "backend_count": 2,
    "fixture_count": 3,
    "primary_backend_count": 1,
    "outcome_case_count": 5,
    "color_identity_mismatch_count": 0,
    "terminalizations_per_session": 1,
    "production_backend_count": 0,
}
EXPECTED_FIXTURE_SEMANTIC_HASHES = {
    "fixture-sequence-a": "641998b613497dff31a36ecfc859680e737e306908f6c090eae1b863beb43e6f",
    "fixture-sequence-b": "b27e5d87e935697e511dd6f19818fa55385d780daee4cef7675370087c88e2ef",
    "fixture-media-transaction": "9554471464645a14970516ebb2ef07d7897f0325d1a88cba34bce9b459c8ebe5",
}
EXPECTED_AUDIO_PCM_SHA256 = (
    "d9c0cdd3c0a79ff8fce1ae71b1e00ee8047de3243d6403b73d3d53cf6094b06a"
)
EXPECTED_AUDIO_SEMANTIC_SHA256 = (
    "db9e6e337c0359715f730a6ef39eb44269290390a42a1044b4e481fb61092cef"
)
EXPECTED_CATALOG_SCENARIOS = (
    {
        "id": "multiple_backends_common_session",
        "fixture_ids": ["fixture-sequence-a", "fixture-sequence-b"],
        "backend_ids": list(FIXTURE_BACKEND_IDS),
        "required_checks": [
            "backend_common_contract",
            "dimensions_preserved",
            "frame_order_preserved",
            "pts_preserved",
            "duration_preserved",
            "color_preserved",
            "resource_lifetime_preserved",
        ],
    },
    {
        "id": "session_lifecycle",
        "fixture_ids": ["fixture-sequence-a"],
        "backend_ids": ["r02.fixture.copy-a"],
        "required_checks": [
            "fifo_serial_submission",
            "reset_semantics",
            "finish_semantics",
            "cancel_semantics",
        ],
    },
    {
        "id": "typed_outcomes_and_fallback",
        "fixture_ids": ["fixture-sequence-b"],
        "backend_ids": list(FIXTURE_BACKEND_IDS),
        "required_checks": [
            "typed_outcome_coverage",
            "planner_visible_fallback",
            "processing_identity_complete",
        ],
    },
    {
        "id": "media_transaction_preservation",
        "fixture_ids": ["fixture-media-transaction"],
        "backend_ids": list(FIXTURE_BACKEND_IDS),
        "required_checks": [
            "dimensions_preserved",
            "frame_order_preserved",
            "pts_preserved",
            "duration_preserved",
            "audio_preserved",
            "metadata_preserved",
            "reopen_verification",
            "atomic_publication",
        ],
    },
)
CONFORMANCE_CHECK_IDS = (
    "registry_disposition_preserved",
    "backend_creation_contract",
    "stage_protocols_distinct",
    "planner_exactly_one_primary",
    "planner_deterministic_order",
    "frame_identity_complete",
    "fifo_serial_submission",
    "actor_reentrancy_guarded",
    "reset_semantics",
    "finish_semantics",
    "cancel_semantics",
    "stale_completion_blocked",
    "resource_lifetime_exactly_once",
    "sequence_and_timing",
    "typed_outcome_coverage",
    "planner_visible_fallback",
    "silent_fallback_absent",
    "processing_identity_complete",
    "multiple_backends_common_session",
    "dimensions_preserved",
    "frame_order_preserved",
    "pts_preserved",
    "duration_preserved",
    "color_preserved",
    "audio_preserved",
    "metadata_preserved",
    "reopen_verification",
    "atomic_publication",
    "production_unavailable",
)
CONFORMANCE_TRACEABILITY = {
    "contract.capability_registry": ("registry_disposition_preserved",),
    "contract.backend_contract": ("backend_creation_contract",),
    "contract.frame_fields": ("frame_identity_complete",),
    "contract.outcome_vocabulary": ("typed_outcome_coverage",),
    "contract.stage_protocols": ("stage_protocols_distinct",),
    "contract.planner_contract": (
        "planner_exactly_one_primary",
        "planner_deterministic_order",
    ),
    "contract.processing_identity_fields": ("processing_identity_complete",),
    "contract.production_composition": ("production_unavailable",),
    "lifecycle.backend_creation": ("backend_creation_contract",),
    "lifecycle.actor_isolation": (
        "fifo_serial_submission",
        "actor_reentrancy_guarded",
    ),
    "lifecycle.frame_ownership": (
        "frame_identity_complete",
        "resource_lifetime_exactly_once",
    ),
    "lifecycle.typed_outcomes": (
        "typed_outcome_coverage",
        "processing_identity_complete",
    ),
    "lifecycle.reset_semantics": ("reset_semantics",),
    "lifecycle.cancel_semantics": (
        "cancel_semantics",
        "stale_completion_blocked",
    ),
    "lifecycle.finish_semantics": ("finish_semantics",),
    "lifecycle.fallback_visibility": (
        "planner_visible_fallback",
        "silent_fallback_absent",
    ),
    "scenario.concurrent_fifo": ("fifo_serial_submission",),
    "scenario.actor_reentrancy": ("actor_reentrancy_guarded",),
    "scenario.reset_ordering": ("reset_semantics",),
    "scenario.finish_drain_and_fence": ("finish_semantics",),
    "scenario.active_cancel": ("cancel_semantics",),
    "scenario.stale_completion": ("stale_completion_blocked",),
    "scenario.resource_lifetime": ("resource_lifetime_exactly_once",),
    "scenario.sequence_and_timing": ("sequence_and_timing",),
    "scenario.planner_determinism": (
        "planner_exactly_one_primary",
        "planner_deterministic_order",
    ),
    "scenario.fallback_linkage": (
        "planner_visible_fallback",
        "silent_fallback_absent",
    ),
    "scenario.multiple_backend_fixture": (
        "multiple_backends_common_session",
        "dimensions_preserved",
        "frame_order_preserved",
        "pts_preserved",
        "duration_preserved",
    ),
    "scenario.audio_metadata_identity": (
        "audio_preserved",
        "metadata_preserved",
    ),
    "scenario.reopen_verification": ("reopen_verification",),
    "scenario.atomic_publication": ("atomic_publication",),
    "scenario.production_unavailable": ("production_unavailable",),
    "catalog.required_check.backend_common_contract": (
        "multiple_backends_common_session",
    ),
    "catalog.required_check.dimensions_preserved": ("dimensions_preserved",),
    "catalog.required_check.frame_order_preserved": ("frame_order_preserved",),
    "catalog.required_check.pts_preserved": ("pts_preserved",),
    "catalog.required_check.duration_preserved": ("duration_preserved",),
    "catalog.required_check.color_preserved": ("color_preserved",),
    "catalog.required_check.resource_lifetime_preserved": (
        "resource_lifetime_exactly_once",
    ),
    "catalog.required_check.fifo_serial_submission": ("fifo_serial_submission",),
    "catalog.required_check.reset_semantics": ("reset_semantics",),
    "catalog.required_check.finish_semantics": ("finish_semantics",),
    "catalog.required_check.cancel_semantics": ("cancel_semantics",),
    "catalog.required_check.typed_outcome_coverage": ("typed_outcome_coverage",),
    "catalog.required_check.planner_visible_fallback": (
        "planner_visible_fallback",
    ),
    "catalog.required_check.processing_identity_complete": (
        "processing_identity_complete",
    ),
    "catalog.required_check.audio_preserved": ("audio_preserved",),
    "catalog.required_check.metadata_preserved": ("metadata_preserved",),
    "catalog.required_check.reopen_verification": ("reopen_verification",),
    "catalog.required_check.atomic_publication": ("atomic_publication",),
}
EXPECTED_BACKEND_SCENARIO_IDS = {
    backend_id: tuple(
        scenario["id"]
        for scenario in EXPECTED_CATALOG_SCENARIOS
        if backend_id in scenario["backend_ids"]
    )
    for backend_id in FIXTURE_BACKEND_IDS
}
R01_CAPABILITY_IDS = tuple(f"A{index:02d}" for index in range(1, 19))
PRIVATE_LABEL_PATTERN = (
    "serial number",
    "hardware uuid",
    "account id",
    "username",
)


def canonical_json_bytes(value: object) -> bytes:
    return json.dumps(
        value,
        ensure_ascii=False,
        separators=(",", ":"),
        sort_keys=True,
    ).encode("utf-8")


def pretty_json_bytes(value: object) -> bytes:
    return (
        json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
    ).encode("utf-8")


def read_json(path: Path) -> dict[str, Any]:
    value = decode_json(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError(f"{path}: top-level JSON value must be an object")
    return value


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def expected_route_identity(backend_id: str) -> dict[str, Any]:
    return {
        "backend_id": backend_id,
        "backend_revision": "1",
        "model_assets_identity": {
            "disposition": "not_required",
            "identifiers": [],
        },
        "configuration_identity": "r02-fixture-copy-v1",
        "policy_identity": "r02-fixture-only-v1",
        "material_decision_identity": "r02-fixture-copy-decision-v1",
    }


def expected_processing_identity(
    backend_id: str, fallback_history: list[dict[str, Any]] | None = None
) -> dict[str, Any]:
    return {
        **expected_route_identity(backend_id),
        "fallback_history": list(fallback_history or []),
    }


def expected_outcome_coverage() -> list[dict[str, Any]]:
    primary = FIXTURE_BACKEND_IDS[0]
    fallback = FIXTURE_BACKEND_IDS[1]
    fallback_link = {
        "failed_identity": expected_route_identity(primary),
        "reason_code": "backend_unavailable",
        "selected_identity": expected_route_identity(fallback),
        "selected_fallback_ordinal": 0,
    }
    return [
        {
            "id": outcome,
            "status": "observed",
            "processing_identity": expected_processing_identity(
                fallback if outcome == "fallback_applied" else primary,
                [fallback_link] if outcome == "fallback_applied" else [],
            ),
        }
        for outcome in OUTCOMES
    ]


def safe_relative_path(value: object) -> PurePosixPath | None:
    if not isinstance(value, str) or not value or "\\" in value or "\x00" in value:
        return None
    path = PurePosixPath(value)
    if path.is_absolute() or any(part in ("", ".", "..") for part in path.parts):
        return None
    return path


def privacy_errors(value: object, context: str = "record") -> list[str]:
    errors: list[str] = []
    if isinstance(value, dict):
        for key, item in value.items():
            normalized = key.lower().replace("-", "_")
            if normalized in PRIVATE_EVIDENCE_KEYS:
                errors.append(f"{context}.{key} is a prohibited private field")
            errors.extend(privacy_errors(item, f"{context}.{key}"))
    elif isinstance(value, list):
        for index, item in enumerate(value):
            errors.extend(privacy_errors(item, f"{context}[{index}]"))
    elif isinstance(value, str):
        lowered = value.lower()
        if EMAIL_PATTERN.search(value):
            errors.append(f"{context} contains an email address")
        if PRIVATE_PATH_PATTERN.search(value):
            errors.append(f"{context} contains a private absolute path")
        if any(label in lowered for label in PRIVATE_LABEL_PATTERN):
            errors.append(f"{context} contains a labeled private identifier")
    return errors


class R02ContractVerifier:
    def __init__(self, root: Path, git_root: Path | None = None) -> None:
        self.root = root.resolve()
        self.git_root = (git_root or root).resolve()

    def git(self, *arguments: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ("git", *arguments),
            cwd=self.git_root,
            check=False,
            capture_output=True,
            text=True,
        )

    def git_bytes(self, *arguments: str) -> subprocess.CompletedProcess[bytes]:
        return subprocess.run(
            ("git", *arguments),
            cwd=self.git_root,
            check=False,
            capture_output=True,
        )

    def _read_and_validate(
        self,
        record_path: Path,
        schema_path: Path,
        expected_keys: frozenset[str],
        label: str,
        errors: list[str],
    ) -> dict[str, Any] | None:
        absolute_record = self.root / record_path
        absolute_schema = self.root / schema_path
        for path, kind in ((absolute_record, "record"), (absolute_schema, "schema")):
            if path.is_symlink() or not path.is_file():
                errors.append(f"{label} {kind} must be a regular file: {path}")
                return None
        try:
            record_bytes = absolute_record.read_bytes()
            record = read_json(absolute_record)
            schema = read_json(absolute_schema)
        except (OSError, UnicodeError, ValueError, json.JSONDecodeError) as error:
            errors.append(f"{label} cannot be read: {error}")
            return None
        if schema.get("$schema") != "https://json-schema.org/draft/2020-12/schema":
            errors.append(f"{label} schema must use JSON Schema draft 2020-12")
        if schema.get("additionalProperties") is not False:
            errors.append(f"{label} schema must close its top-level object")
        if set(record) != expected_keys:
            errors.append(f"{label} top-level keys differ from the frozen contract")
        if record_bytes != pretty_json_bytes(record):
            errors.append(f"{label} must use canonical sorted pretty JSON bytes")
        errors.extend(
            f"{label} schema validation: {error}"
            for error in validate_json_schema_instance(schema, record)
        )
        errors.extend(privacy_errors(record, label))
        return record

    def _check_binding(
        self,
        binding: object,
        expected_path: Path,
        context: str,
        errors: list[str],
    ) -> bytes | None:
        if not isinstance(binding, dict):
            errors.append(f"{context} must be a file binding")
            return None
        if set(binding) != {"path", "size_bytes", "sha256"}:
            errors.append(f"{context} keys differ from the closed binding")
            return None
        relative = safe_relative_path(binding.get("path"))
        if relative is None or relative.as_posix() != expected_path.as_posix():
            errors.append(f"{context}.path differs from the frozen path")
            return None
        path = self.root / Path(*relative.parts)
        if path.is_symlink() or not path.is_file():
            errors.append(f"{context} must bind a regular file")
            return None
        payload = path.read_bytes()
        if binding.get("size_bytes") != len(payload):
            errors.append(f"{context}.size_bytes differs from the bound file")
        if binding.get("sha256") != sha256_bytes(payload):
            errors.append(f"{context}.sha256 differs from the bound file")
        return payload

    def _check_predecessor(
        self, preregistration: dict[str, Any], errors: list[str]
    ) -> None:
        predecessor = preregistration.get("predecessor_binding")
        if not isinstance(predecessor, dict) or set(predecessor) != PREDECESSOR_KEYS:
            errors.append("predecessor_binding keys differ from the closed contract")
            return
        if predecessor != EXPECTED_PREDECESSOR:
            errors.append(
                "predecessor_binding must preserve the exact local unpublished closure truth"
            )
            return
        commit = predecessor["closure_commit"]
        tree = predecessor["closure_tree"]
        if self.git("cat-file", "-e", f"{commit}^{{commit}}").returncode != 0:
            errors.append("predecessor closure commit is unavailable")
            return
        observed_tree = self.git("rev-parse", f"{commit}^{{tree}}")
        if observed_tree.returncode != 0 or observed_tree.stdout.strip() != tree:
            errors.append("predecessor closure tree differs from its commit")
        if self.git("merge-base", "--is-ancestor", commit, "HEAD").returncode != 0:
            errors.append("predecessor closure commit must be an ancestor of HEAD")

        roadmap_result = self.git_bytes("show", f"{commit}:{ROADMAP_PATH.as_posix()}")
        if roadmap_result.returncode != 0:
            errors.append("predecessor roadmap is unavailable at the closure commit")
            return
        try:
            roadmap = decode_json(roadmap_result.stdout.decode("utf-8"))
        except (UnicodeError, ValueError, json.JSONDecodeError) as error:
            errors.append(f"predecessor roadmap is invalid: {error}")
            return
        phases = roadmap.get("phases") if isinstance(roadmap, dict) else None
        phase_values = phases if isinstance(phases, list) else []
        statuses = {
            item.get("id"): item.get("status")
            for item in phase_values
            if isinstance(item, dict)
        }
        if statuses.get("R01") != "passed" or statuses.get("R02") != "next":
            errors.append("predecessor roadmap must record R01 passed and R02 next")

        evidence_result = self.git_bytes(
            "show", f"{commit}:{R01_PHASE_EVIDENCE_PATH.as_posix()}"
        )
        if evidence_result.returncode != 0:
            errors.append("R01 phase evidence is absent at the predecessor closure")
        else:
            try:
                evidence = decode_json(evidence_result.stdout.decode("utf-8"))
            except (UnicodeError, ValueError, json.JSONDecodeError) as error:
                errors.append(f"R01 phase evidence is invalid at predecessor: {error}")
            else:
                result = evidence.get("result") if isinstance(evidence, dict) else None
                dispositions = result.get("dispositions") if isinstance(result, dict) else None
                disposition_values = (
                    dispositions if isinstance(dispositions, list) else []
                )
                observed = {
                    item.get("subject_id"): item.get("value")
                    for item in disposition_values
                    if isinstance(item, dict)
                }
                if not isinstance(result, dict) or result.get("status") != "passed":
                    errors.append("R01 predecessor evidence is not passed")
                if tuple(observed) != R01_CAPABILITY_IDS or any(
                    observed[item] != "diagnostic_only" for item in observed
                ):
                    errors.append(
                        "R01 predecessor dispositions must remain A01-A18 diagnostic_only"
                    )

    def _check_r01_capability_binding(
        self, preregistration: dict[str, Any], errors: list[str]
    ) -> None:
        contract = preregistration.get("contract")
        registry = contract.get("capability_registry") if isinstance(contract, dict) else None
        binding = registry.get("source_binding") if isinstance(registry, dict) else None
        payload = self._check_binding(
            binding,
            R01_CAPABILITY_MATRIX_PATH,
            "contract.capability_registry.source_binding",
            errors,
        )
        if payload is None:
            return
        commit = EXPECTED_PREDECESSOR["closure_commit"]
        historical = self.git_bytes(
            "show", f"{commit}:{R01_CAPABILITY_MATRIX_PATH.as_posix()}"
        )
        if historical.returncode != 0 or historical.stdout != payload:
            errors.append(
                "capability registry source binding differs from the predecessor closure bytes"
            )
            return
        try:
            matrix = decode_json(payload.decode("utf-8"))
        except (UnicodeError, ValueError, json.JSONDecodeError) as error:
            errors.append(f"R01 capability matrix is invalid: {error}")
            return
        capabilities = matrix.get("capabilities") if isinstance(matrix, dict) else None
        capability_values = capabilities if isinstance(capabilities, list) else []
        capability_ids = [
            item.get("id") for item in capability_values if isinstance(item, dict)
        ]
        if tuple(capability_ids) != R01_CAPABILITY_IDS:
            errors.append("R01 capability matrix must contain A01-A18 in order")
            return
        for capability in capability_values:
            if not isinstance(capability, dict):
                errors.append("R01 capability matrix entries must be objects")
                continue
            records = capability.get("anchor_records")
            if not isinstance(records, list) or any(
                not isinstance(record, dict)
                or record.get("observation_status") != "not_observed"
                or record.get("runtime_disposition") != "diagnostic_only"
                or record.get("backend_eligibility") != "not_evaluated_in_r01"
                for record in records
            ):
                errors.append(
                    f"R01 capability {capability.get('id')} must remain unobserved, diagnostic-only, and not evaluated for eligibility"
                )

    def _check_preregistration_semantics(
        self, preregistration: dict[str, Any], errors: list[str]
    ) -> None:
        if preregistration.get("schema_version") != "1.0.0":
            errors.append("R02 preregistration schema_version differs")
        if preregistration.get("roadmap_version") != "1.0.1":
            errors.append("R02 preregistration roadmap_version differs")
        if preregistration.get("phase_id") != "R02":
            errors.append("R02 preregistration phase_id differs")
        if preregistration.get("preregistration_state") != (
            "contract_frozen_for_local_implementation"
        ):
            errors.append("R02 preregistration state differs")
        if preregistration.get("observation_policy") != EXPECTED_OBSERVATION_POLICY:
            errors.append("R02 observation policy differs from the operator override")
        if preregistration.get("authorization_boundary") != EXPECTED_AUTHORIZATION_BOUNDARY:
            errors.append("R02 authorization boundary differs")

        contract = preregistration.get("contract")
        if not isinstance(contract, dict):
            errors.append("R02 contract must be an object")
            return
        if contract.get("frame_fields") != list(FRAME_FIELDS):
            errors.append("R02 frame fields differ from the frozen lifecycle contract")
        if contract.get("outcome_vocabulary") != list(OUTCOMES):
            errors.append("R02 outcome vocabulary differs")
        if contract.get("stage_protocols") != list(STAGE_PROTOCOLS):
            errors.append("R02 five-stage protocol vocabulary differs")
        if contract.get("processing_identity_fields") != list(
            PROCESSING_IDENTITY_FIELDS
        ):
            errors.append("R02 processing identity fields differ")
        lifecycle = contract.get("lifecycle_requirements")
        lifecycle_values = lifecycle if isinstance(lifecycle, list) else []
        observed_lifecycle = tuple(
            (item.get("id"), item.get("description"))
            for item in lifecycle_values
            if isinstance(item, dict)
        )
        if observed_lifecycle != LIFECYCLE_CONTRACTS:
            errors.append("R02 lifecycle requirements differ from the frozen text")
        scenarios = contract.get("scenarios")
        scenario_values = scenarios if isinstance(scenarios, list) else []
        observed_scenarios = tuple(
            (item.get("id"), item.get("description"))
            for item in scenario_values
            if isinstance(item, dict)
        )
        if observed_scenarios != SCENARIO_CONTRACTS:
            errors.append("R02 scenarios differ from the frozen text")
        backend = contract.get("backend_contract")
        expected_backend = {
            "capability_source": "explicit_immutable_registry_only",
            "fallback_owner": "planner_orchestrator_only",
            "fixture_backend_identities": list(FIXTURE_BACKEND_IDS),
            "minimum_deterministic_backends": 2,
            "session_contract": "apple-upscale-session-v1",
        }
        if backend != expected_backend:
            errors.append("R02 backend contract differs")
        if contract.get("planner_contract") != (
            "exactly_one_primary_deterministic_order_explicit_fallback"
        ):
            errors.append("R02 planner contract differs")
        if contract.get("production_composition") != "unavailable":
            errors.append("R02 production composition must remain unavailable")
        generator = contract.get("fixture_generator")
        expected_generator = {
            "generator_contract": GENERATOR_CONTRACT,
            "source_binding": {
                "path": FIXTURE_GENERATOR_PATH.as_posix(),
                "size_bytes": 1849,
                "sha256": "6155e72eaeac221bcf88c6fcac48bd45aecaa0043046bf1b6dfd46fb68e53b3e",
            },
        }
        if generator != expected_generator:
            errors.append("R02 fixture-generator source binding differs")
        elif isinstance(generator, dict):
            self._check_binding(
                generator.get("source_binding"),
                FIXTURE_GENERATOR_PATH,
                "contract.fixture_generator.source_binding",
                errors,
            )
        schema_bindings = contract.get("schema_bindings")
        if schema_bindings != EXPECTED_R02_SCHEMA_BINDINGS:
            errors.append("R02 schema bindings differ from the frozen contract")
        elif isinstance(schema_bindings, dict):
            for schema_id, schema_path in R02_SCHEMA_PATHS.items():
                self._check_binding(
                    schema_bindings.get(schema_id),
                    schema_path,
                    f"contract.schema_bindings.{schema_id}",
                    errors,
                )

        metrics = preregistration.get("metrics")
        metric_values = metrics if isinstance(metrics, list) else []
        observed_metrics = tuple(
            (
                item.get("id"),
                item.get("unit"),
                item.get("direction"),
                item.get("operator"),
                item.get("floor"),
            )
            for item in metric_values
            if isinstance(item, dict)
        )
        if observed_metrics != METRIC_CONTRACTS:
            errors.append("R02 metric records differ from the frozen contract")
        stop_rules = preregistration.get("stop_rules")
        stop_rule_values = stop_rules if isinstance(stop_rules, list) else []
        observed_stop_rules = tuple(
            (item.get("id"), item.get("description"))
            for item in stop_rule_values
            if isinstance(item, dict)
        )
        if observed_stop_rules != STOP_RULE_CONTRACTS:
            errors.append("R02 stop rules differ from the frozen text")

    def _check_fixture_semantics(
        self, catalog: dict[str, Any], errors: list[str]
    ) -> None:
        if catalog.get("schema_version") != "1.0.0" or catalog.get("phase_id") != "R02":
            errors.append("R02 fixture catalog identity differs")
        if catalog.get("generator_contract") != (
            "r02-deterministic-contract-fixtures-v1"
        ):
            errors.append("R02 fixture generator contract differs")
        fixtures = catalog.get("fixtures")
        if not isinstance(fixtures, list):
            errors.append("R02 fixtures must be an array")
            return
        if tuple(item.get("id") for item in fixtures if isinstance(item, dict)) != FIXTURE_IDS:
            errors.append("R02 fixture IDs/order differ")
            return
        for fixture in fixtures:
            fixture_id = fixture.get("id")
            semantic_hash = fixture.get("semantic_sha256")
            unhashed = dict(fixture)
            unhashed.pop("semantic_sha256", None)
            if semantic_hash != EXPECTED_FIXTURE_SEMANTIC_HASHES.get(fixture_id):
                errors.append(
                    f"R02 fixture semantic SHA-256 differs from the frozen contract: {fixture_id}"
                )
            if semantic_hash != sha256_bytes(canonical_json_bytes(unhashed)):
                errors.append(f"R02 fixture semantic SHA-256 differs: {fixture_id}")
            if fixture.get("generator_id") != NV12_GENERATOR_ID:
                errors.append(f"R02 fixture generator differs: {fixture_id}")
            frames = fixture.get("frames")
            if not isinstance(frames, list):
                errors.append(f"R02 fixture frames are invalid: {fixture_id}")
                continue
            if any(not isinstance(frame, dict) for frame in frames):
                errors.append(f"R02 fixture frames are invalid: {fixture_id}")
                continue
            sequences = [frame.get("sequence_number") for frame in frames]
            if sequences != list(range(len(frames))):
                errors.append(f"R02 fixture sequence is not contiguous: {fixture_id}")
            metadata = [frame.get("metadata_identity") for frame in frames]
            tokens = [frame.get("resource_token_id") for frame in frames]
            if len(metadata) != len(set(metadata)) or len(tokens) != len(set(tokens)):
                errors.append(f"R02 fixture metadata/token identities are not unique: {fixture_id}")
            previous: Fraction | None = None
            for frame in frames:
                dimensions = fixture.get("source_dimensions")
                try:
                    generated_payload = nv12_frame_bytes(
                        width=dimensions["width"],
                        height=dimensions["height"],
                        seed=fixture["seed"],
                        sequence_number=frame["sequence_number"],
                    )
                except (KeyError, TypeError, ValueError):
                    errors.append(
                        f"R02 generated frame inputs are invalid: {fixture_id}"
                    )
                else:
                    if frame.get("generated_content_sha256") != sha256_bytes(
                        generated_payload
                    ):
                        errors.append(
                            f"R02 generated frame SHA-256 differs: {fixture_id} frame {frame.get('sequence_number')}"
                        )
                pts = frame.get("pts")
                duration = frame.get("duration")
                if not isinstance(pts, dict) or not isinstance(duration, dict):
                    errors.append(f"R02 fixture timing is invalid: {fixture_id}")
                    continue
                try:
                    point = Fraction(pts["value"], pts["timescale"])
                    span = Fraction(duration["value"], duration["timescale"])
                except (KeyError, TypeError, ValueError, ZeroDivisionError):
                    errors.append(f"R02 fixture timing is invalid: {fixture_id}")
                    continue
                if span <= 0:
                    errors.append(f"R02 fixture duration is not positive: {fixture_id}")
                if previous is not None and point <= previous:
                    errors.append(f"R02 fixture PTS is not increasing: {fixture_id}")
                previous = point
            if fixture.get("kind") == "frame_sequence" and (
                fixture.get("audio_contract") is not None
                or fixture.get("container_contract") is not None
            ):
                errors.append(f"R02 frame-sequence fixture must not claim a container: {fixture_id}")
            if fixture.get("kind") == "media_transaction":
                audio = fixture.get("audio_contract")
                container = fixture.get("container_contract")
                if not isinstance(audio, dict) or audio.get("codec") != "aac":
                    errors.append("R02 media fixture must include one AAC audio contract")
                elif audio.get("source_generator_id") != PCM_GENERATOR_ID:
                    errors.append("R02 media fixture audio generator differs")
                else:
                    audio_without_hash = dict(audio)
                    audio_without_hash.pop("semantic_sha256", None)
                    if audio.get("semantic_sha256") != EXPECTED_AUDIO_SEMANTIC_SHA256:
                        errors.append(
                            "R02 media fixture audio semantic SHA-256 differs from the frozen contract"
                        )
                    if audio.get("semantic_sha256") != sha256_bytes(
                        canonical_json_bytes(audio_without_hash)
                    ):
                        errors.append("R02 media fixture audio semantic SHA-256 differs")
                    try:
                        generated_audio = pcm_s16le_bytes(
                            sample_frames=audio["source_sample_frames"],
                            channel_count=audio["channel_count"],
                            seed=fixture["seed"],
                        )
                    except (KeyError, TypeError, ValueError):
                        errors.append("R02 media fixture audio generator inputs are invalid")
                    else:
                        generated_audio_hash = sha256_bytes(generated_audio)
                        if generated_audio_hash != EXPECTED_AUDIO_PCM_SHA256:
                            errors.append(
                                "R02 media fixture generated PCM differs from the frozen contract"
                            )
                        if audio.get("source_pcm_sha256") != generated_audio_hash:
                            errors.append("R02 media fixture source PCM SHA-256 differs")
                if not isinstance(container, dict) or not (
                    container.get("reopen_required") is True
                    and container.get("atomic_publication_required") is True
                ):
                    errors.append(
                        "R02 media fixture must require reopen verification and atomic publication"
                    )
        scenarios = catalog.get("scenarios")
        if not isinstance(scenarios, list):
            errors.append("R02 fixture scenarios must be an array")
            return
        if tuple(scenarios) != EXPECTED_CATALOG_SCENARIOS:
            errors.append("R02 fixture scenarios differ from the frozen contract")
        observed_ids = tuple(
            item.get("id")
            for item in scenarios
            if isinstance(scenarios, list) and isinstance(item, dict)
        )
        if observed_ids != CATALOG_SCENARIO_IDS:
            errors.append("R02 fixture scenario IDs/order differ")
            return
        known_fixtures = set(FIXTURE_IDS)
        for scenario in scenarios:
            if not set(scenario.get("fixture_ids", [])) <= known_fixtures:
                errors.append(f"R02 scenario references an unknown fixture: {scenario.get('id')}")
        multiple = scenarios[0]
        if tuple(multiple.get("backend_ids", [])) != FIXTURE_BACKEND_IDS:
            errors.append("R02 common-session scenario must name both fixture backends")
        if set(multiple.get("fixture_ids", [])) != set(FIXTURE_IDS[:2]):
            errors.append("R02 common-session scenario must use both frame fixtures")

    def _check_source(
        self, source: object, context: str, errors: list[str]
    ) -> None:
        if not isinstance(source, dict) or set(source) != {"commit", "tree"}:
            errors.append(f"{context} must contain only commit and tree")
            return
        commit = source.get("commit")
        tree = source.get("tree")
        if not isinstance(commit, str) or not isinstance(tree, str):
            errors.append(f"{context} commit and tree must be strings")
            return
        if self.git("cat-file", "-e", f"{commit}^{{commit}}").returncode != 0:
            errors.append(f"{context} commit is unavailable")
            return
        predecessor = EXPECTED_PREDECESSOR["closure_commit"]
        if commit == predecessor or self.git(
            "merge-base", "--is-ancestor", predecessor, commit
        ).returncode != 0:
            errors.append(
                f"{context} must be a strict descendant of the R01 closure"
            )
        observed_tree = self.git("rev-parse", f"{commit}^{{tree}}")
        if observed_tree.returncode != 0 or observed_tree.stdout.strip() != tree:
            errors.append(f"{context} tree differs from its commit")
        if self.git("merge-base", "--is-ancestor", commit, "HEAD").returncode != 0:
            errors.append(f"{context} commit must be an ancestor of HEAD")
        for path in (
            PREREGISTRATION_PATH,
            FIXTURE_CATALOG_PATH,
            PREREGISTRATION_SCHEMA_PATH,
            FIXTURE_CATALOG_SCHEMA_PATH,
            CONFORMANCE_SCHEMA_PATH,
            FIXTURE_GENERATOR_PATH,
        ):
            result = self.git_bytes("show", f"{commit}:{path.as_posix()}")
            current_path = self.root / path
            if (
                result.returncode != 0
                or current_path.is_symlink()
                or not current_path.is_file()
                or result.stdout != current_path.read_bytes()
            ):
                errors.append(
                    f"{context} does not contain the bound R02 contract bytes: {path.as_posix()}"
                )

    def _check_conformance_semantics(
        self, conformance: dict[str, Any], errors: list[str]
    ) -> None:
        if conformance.get("schema_version") != "1.0.0":
            errors.append("R02 conformance schema_version differs")
        if conformance.get("roadmap_version") != "1.0.1":
            errors.append("R02 conformance roadmap_version differs")
        if conformance.get("phase_id") != "R02":
            errors.append("R02 conformance phase_id differs")
        if conformance.get("evidence_kind") != "deterministic_software_conformance":
            errors.append("R02 conformance evidence_kind differs")
        if conformance.get("observation_status") != (
            EXPECTED_CONFORMANCE_OBSERVATION_STATUS
        ):
            errors.append(
                "R02 conformance observation status differs from the operator override"
            )

        runs = conformance.get("backend_runs")
        if not isinstance(runs, list):
            errors.append("R02 conformance backend_runs must be an array")
        else:
            observed_backend_ids = tuple(
                run.get("identity", {}).get("backend_id")
                for run in runs
                if isinstance(run, dict)
                and isinstance(run.get("identity"), dict)
            )
            if observed_backend_ids != FIXTURE_BACKEND_IDS:
                errors.append(
                    "R02 conformance must contain both fixture-only backends in frozen order"
                )
            for run in runs:
                if not isinstance(run, dict):
                    errors.append("R02 conformance backend run must be an object")
                    continue
                if set(run) != {
                    "identity",
                    "admission_scope",
                    "session_contract",
                    "fixture_ids",
                    "scenario_ids",
                    "selected_primary",
                    "terminalization_count",
                    "result",
                }:
                    errors.append("R02 conformance backend-run keys differ")
                identity = run.get("identity")
                backend_id = (
                    identity.get("backend_id") if isinstance(identity, dict) else None
                )
                expected_identity = expected_processing_identity(backend_id)
                if (
                    not isinstance(identity, dict)
                    or set(identity) != CONFORMANCE_IDENTITY_KEYS
                    or identity != expected_identity
                ):
                    errors.append(
                        f"R02 conformance processing identity differs: {backend_id}"
                    )
                if run.get("admission_scope") != "fixture_only_nonproduction":
                    errors.append(
                        f"R02 conformance backend is not fixture-only: {backend_id}"
                    )
                if run.get("session_contract") != "apple-upscale-session-v1":
                    errors.append(
                        f"R02 conformance session contract differs: {backend_id}"
                    )
                if run.get("fixture_ids") != list(FIXTURE_IDS):
                    errors.append(
                        f"R02 conformance fixture coverage differs: {backend_id}"
                    )
                if run.get("scenario_ids") != list(
                    EXPECTED_BACKEND_SCENARIO_IDS.get(backend_id, ())
                ):
                    errors.append(
                        f"R02 conformance scenario coverage differs: {backend_id}"
                    )
                if run.get("selected_primary") is not (
                    backend_id == FIXTURE_BACKEND_IDS[0]
                ):
                    errors.append(
                        f"R02 conformance primary selection differs: {backend_id}"
                    )
                if run.get("terminalization_count") != 1:
                    errors.append(
                        f"R02 conformance terminalization count differs: {backend_id}"
                    )
                if run.get("result") != "passed":
                    errors.append(f"R02 conformance backend run failed: {backend_id}")

        expected_outcomes = expected_outcome_coverage()
        if conformance.get("outcome_coverage") != expected_outcomes:
            errors.append("R02 conformance outcome coverage differs")
        expected_checks = [
            {"id": check_id, "status": "passed"}
            for check_id in CONFORMANCE_CHECK_IDS
        ]
        if conformance.get("checks") != expected_checks:
            errors.append("R02 conformance software checks differ")
        expected_trace_sources = {
            "contract.capability_registry",
            "contract.backend_contract",
            "contract.frame_fields",
            "contract.outcome_vocabulary",
            "contract.stage_protocols",
            "contract.planner_contract",
            "contract.processing_identity_fields",
            "contract.production_composition",
            *(f"lifecycle.{item[0]}" for item in LIFECYCLE_CONTRACTS),
            *(f"scenario.{item[0]}" for item in SCENARIO_CONTRACTS),
            *(
                f"catalog.required_check.{check_id}"
                for scenario in EXPECTED_CATALOG_SCENARIOS
                for check_id in scenario["required_checks"]
            ),
        }
        mapped_check_ids = {
            target
            for targets in CONFORMANCE_TRACEABILITY.values()
            for target in targets
        }
        if (
            set(CONFORMANCE_TRACEABILITY) != expected_trace_sources
            or mapped_check_ids != set(CONFORMANCE_CHECK_IDS)
        ):
            errors.append("R02 conformance traceability map is incomplete")

        expected_metrics = [
            {
                "id": metric_id,
                "unit": unit,
                "direction": direction,
                "operator": operator,
                "floor": floor,
                "value": EXPECTED_CONFORMANCE_METRIC_VALUES[metric_id],
                "passed": True,
            }
            for metric_id, unit, direction, operator, floor in METRIC_CONTRACTS
        ]
        expected_result = {
            "status": "passed",
            "metrics": expected_metrics,
            "production_composition": {
                "status": "unavailable",
                "service_type": "UnavailableUpscalerEngineService",
                "fixture_backend_reachable": False,
            },
            "authorization": {
                "phase_acceptance": "not_claimed",
                "publication": "not_authorized_by_this_record",
                "product_eligibility": "not_authorized",
                "production_enablement": "not_authorized",
                "auto_mode": "blocked",
                "holdout": "blocked",
                "release": "not_authorized",
                "performance_claims": "forbidden",
            },
        }
        if conformance.get("result") != expected_result:
            errors.append("R02 conformance result differs from the frozen contract")
        result = conformance.get("result")
        result_metrics = result.get("metrics") if isinstance(result, dict) else None
        metric_values = result_metrics if isinstance(result_metrics, list) else []
        observed_metric_values = {
            item.get("id"): item.get("value")
            for item in metric_values
            if isinstance(item, dict)
        }
        run_values = (
            [item for item in runs if isinstance(item, dict)]
            if isinstance(runs, list)
            else []
        )
        unique_backend_ids = {
            identity.get("backend_id")
            for run in run_values
            if isinstance((identity := run.get("identity")), dict)
        }
        unique_fixture_ids = {
            fixture_id
            for run in run_values
            for fixture_id in (
                run.get("fixture_ids") if isinstance(run.get("fixture_ids"), list) else []
            )
        }
        derived_metric_values = {
            "backend_count": len(unique_backend_ids),
            "fixture_count": len(unique_fixture_ids),
            "primary_backend_count": sum(
                run.get("selected_primary") is True for run in run_values
            ),
            "outcome_case_count": len(
                {
                    item.get("id")
                    for item in (
                        conformance.get("outcome_coverage")
                        if isinstance(conformance.get("outcome_coverage"), list)
                        else []
                    )
                    if isinstance(item, dict) and item.get("status") == "observed"
                }
            ),
            "production_backend_count": sum(
                run.get("admission_scope") != "fixture_only_nonproduction"
                for run in run_values
            ),
        }
        for metric_id, derived_value in derived_metric_values.items():
            if observed_metric_values.get(metric_id) != derived_value:
                errors.append(
                    f"R02 conformance metric is not derived from evidence: {metric_id}"
                )
        terminalization_values = {
            run.get("terminalization_count") for run in run_values
        }
        if terminalization_values != {1} or observed_metric_values.get(
            "terminalizations_per_session"
        ) != 1:
            errors.append(
                "R02 conformance metric is not derived from evidence: terminalizations_per_session"
            )
        if conformance.get("limitations") != list(EXPECTED_CONFORMANCE_LIMITATIONS):
            errors.append("R02 conformance limitations differ")

    def check_preregistration(self) -> list[str]:
        errors: list[str] = []
        preregistration = self._read_and_validate(
            PREREGISTRATION_PATH,
            PREREGISTRATION_SCHEMA_PATH,
            PREREGISTRATION_KEYS,
            "R02 preregistration",
            errors,
        )
        catalog = self._read_and_validate(
            FIXTURE_CATALOG_PATH,
            FIXTURE_CATALOG_SCHEMA_PATH,
            CATALOG_KEYS,
            "R02 fixture catalog",
            errors,
        )
        if preregistration is None or catalog is None:
            return errors
        self._check_predecessor(preregistration, errors)
        self._check_r01_capability_binding(preregistration, errors)
        self._check_preregistration_semantics(preregistration, errors)
        payload = self._check_binding(
            preregistration.get("fixture_catalog"),
            FIXTURE_CATALOG_PATH,
            "fixture_catalog",
            errors,
        )
        if payload is not None and payload != (self.root / FIXTURE_CATALOG_PATH).read_bytes():
            errors.append("R02 fixture catalog binding is unstable")
        self._check_fixture_semantics(catalog, errors)
        return errors

    def check_fixtures(self) -> list[str]:
        errors: list[str] = []
        catalog = self._read_and_validate(
            FIXTURE_CATALOG_PATH,
            FIXTURE_CATALOG_SCHEMA_PATH,
            CATALOG_KEYS,
            "R02 fixture catalog",
            errors,
        )
        if catalog is not None:
            self._check_fixture_semantics(catalog, errors)
        return errors

    def check_conformance(self) -> list[str]:
        errors: list[str] = []
        errors.extend(self.check_preregistration())
        conformance = self._read_and_validate(
            CONFORMANCE_PATH,
            CONFORMANCE_SCHEMA_PATH,
            CONFORMANCE_KEYS,
            "R02 conformance",
            errors,
        )
        if conformance is None:
            return errors
        self._check_source(conformance.get("source"), "R02 conformance source", errors)
        self._check_binding(
            conformance.get("preregistration_binding"),
            PREREGISTRATION_PATH,
            "R02 conformance preregistration_binding",
            errors,
        )
        self._check_binding(
            conformance.get("fixture_catalog_binding"),
            FIXTURE_CATALOG_PATH,
            "R02 conformance fixture_catalog_binding",
            errors,
        )
        self._check_conformance_semantics(conformance, errors)
        return errors


def emit_errors(errors: Iterable[str]) -> int:
    values = list(errors)
    if not values:
        return 0
    for error in values:
        print(f"ERROR: {error}", file=sys.stderr)
    return 1


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check-preregistration", action="store_true")
    parser.add_argument("--check-fixtures", action="store_true")
    parser.add_argument("--check-conformance", action="store_true")
    args = parser.parse_args(argv)
    if not (
        args.check_preregistration
        or args.check_fixtures
        or args.check_conformance
    ):
        parser.error(
            "select --check-preregistration, --check-fixtures, and/or --check-conformance"
        )
    verifier = R02ContractVerifier(REPOSITORY_ROOT)
    errors: list[str] = []
    if args.check_preregistration:
        errors.extend(verifier.check_preregistration())
    if args.check_fixtures:
        errors.extend(verifier.check_fixtures())
    if args.check_conformance:
        errors.extend(verifier.check_conformance())
    return emit_errors(sorted(set(errors)))


if __name__ == "__main__":
    raise SystemExit(main())
