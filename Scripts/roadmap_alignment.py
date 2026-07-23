#!/usr/bin/env python3
"""Verify that repository state remains aligned with the canonical roadmap."""

from __future__ import annotations

import argparse
from collections import Counter
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time
from typing import Any
from urllib import error as urlerror
from urllib import request as urlrequest


DEFAULT_POLICY_PATH = Path(".github/roadmap-alignment-policy.json")
R03_LOCAL_CONTINUATION_EXCEPTION = {
    "active_phase_status": "in_progress",
    "closure_required_path": "docs/roadmaps/evidence/r02/records/conformance.json",
    "dependency_phase_id": "R02",
    "dependency_phase_status": "in_progress",
    "predecessor_binding": {
        "acceptance_state": "not_claimed",
        "accepted_merge_commit": None,
        "closure_commit": "673b0582c0b4d6b4ad81de6b01ba9e3f35f4e3d4",
        "closure_state": "local_unpublished_closure",
        "closure_tree": "a5e95d810abacbdb872ddc6e94125103831e6fba",
        "continuation_scope": "local_implementation_only",
        "phase_id": "R02",
    },
    "preregistration_identity": {
        "phase_id": "R03",
        "preregistration_state": "contract_frozen_for_local_implementation",
        "roadmap_version": "1.0.1",
        "schema_version": "1.0.0",
    },
    "preregistration_path": "docs/roadmaps/evidence/r03/records/preregistration.json",
    "preregistration_required_keys": [
        "authorization_boundary",
        "checks",
        "contract",
        "fixture_catalog",
        "metrics",
        "observation_policy",
        "phase_id",
        "predecessor_binding",
        "preregistration_state",
        "roadmap_version",
        "schema_bindings",
        "schema_version",
        "stop_rules",
    ],
}
R03_PHASE_ACCEPTANCE_OVERRIDE = {
    "active_phase_status": "passed",
    "dependency_phase_id": "R02",
    "dependency_phase_status": "in_progress",
    "dependency_conformance_binding": {
        "path": "docs/roadmaps/evidence/r02/records/conformance.json",
        "size_bytes": 13488,
        "sha256": "8eaccc72d82beb4bbe26dfa7af52809743e017e3ad9ba09d3cc4febc7f8187b1",
    },
    "acceptance_record_binding": {
        "path": (
            "docs/roadmaps/evidence/r03/records/functional-phase-acceptance.json"
        ),
        "size_bytes": 4940,
        "sha256": "46469f1c2764a88ccdb5752f3aeab2a9a4fd25e954eef65ad8eb02a78d18a476",
    },
    "acceptance_identity": {
        "schema_version": "1.0.0",
        "roadmap_version": "1.0.1",
        "phase_id": "R03",
        "evidence_kind": "r03_operator_functional_phase_acceptance_v1",
        "override_id": "r03.software-function-phase-acceptance.v1",
        "result": {
            "status": "passed",
            "phase_status_before": "in_progress",
            "phase_status_after": "passed",
            "acceptance": "accepted",
            "accepted_backend_id": "r03.mps.lanczos",
            "acceptance_scope": "functional_software_phase_acceptance",
        },
    },
}
R07_PHASE_ACCEPTANCE_OVERRIDE = {
    "active_phase_status": "passed",
    "dependency_phase_id": "R06",
    "dependency_phase_status": "in_progress",
    "dependency_phase_evidence_binding": {
        "path": "docs/roadmaps/evidence/r06/phase-evidence.json",
        "size_bytes": 11395,
        "sha256": "555508b60108903019798d31e34f3cecd6575e18a39cff07069237e7cf823f00",
    },
    "dependency_conformance_binding": {
        "path": (
            "docs/roadmaps/evidence/r06/records/orchestration-conformance.json"
        ),
        "size_bytes": 5800,
        "sha256": "19f25269e9cb62ba162e2c53d716a79a392fef740a0be0c7d981cbdac3bfeccc",
    },
    "acceptance_record_binding": {
        "path": (
            "docs/roadmaps/evidence/r07/records/functional-phase-acceptance.json"
        ),
        "size_bytes": 14303,
        "sha256": "a58896db4a44a4fd4da00c3de53b059066a1531dda9df7a91dc735544117ed6b",
    },
    "acceptance_identity": {
        "schema_version": "1.0.0",
        "roadmap_version": "1.0.1",
        "phase_id": "R07",
        "evidence_kind": "r07_operator_functional_phase_acceptance_v1",
        "override_id": "r07.software-function-phase-acceptance.v1",
        "comparative_requirement": "superseded_not_required",
        "dependency_alignment_override": {
            "phase_id": "R06",
            "phase_status": "in_progress",
            "predecessor_result": "blocked",
            "acceptance_state": "not_claimed",
            "closure_commit": "9ed01ea938a933f6406fd67e88edb74e7c84f5f4",
            "closure_tree": "32365e745dbf53d59213fe2294a6b63ba2642df7",
            "blocked_evidence_disposition": (
                "preserved_non_authorizing_historical_evidence"
            ),
            "r07_progression": "operator_authorized_functional_acceptance_only",
        },
        "superseded_gate": {
            "gate": (
                "ASH Auto must reduce preregistered temporal artifact and "
                "chroma-displacement measures relative to each underlying backend "
                "used alone, with no material loss in spatial quality."
            ),
            "disposition": "superseded_for_r07_phase_acceptance",
            "retained_value": "historical_optional_non_authorizing_evidence",
        },
        "result": {
            "status": "passed",
            "phase_status_before": "in_progress",
            "phase_status_after": "passed",
            "acceptance": "accepted",
            "acceptance_scope": (
                "functional_deterministic_software_phase_acceptance"
            ),
            "execution_mode": "deterministic_fixture_simulation",
            "product_qualification": "not_claimed",
        },
    },
}
R04_LOCAL_CONTINUATION_EXCEPTION = {
    "active_phase_status": "in_progress",
    "closure_required_path": "docs/roadmaps/evidence/r03/records/baseline-conformance.json",
    "dependency_phase_id": "R03",
    "dependency_phase_status": "in_progress",
    "predecessor_binding": {
        "acceptance_state": "not_claimed",
        "accepted_merge_commit": None,
        "closure_commit": "947983a8414c60e4f5f4246e6cb658792fc7c357",
        "closure_state": "local_unpublished_blocked_closure",
        "closure_tree": "d1a89e5b9edf8d42b1da9ba06a3b6a0c139f08f3",
        "continuation_scope": "local_implementation_only",
        "phase_id": "R03",
        "predecessor_result": "blocked",
    },
    "preregistration_identity": {
        "phase_id": "R04",
        "preregistration_state": "contract_frozen_for_local_implementation",
        "roadmap_version": "1.0.1",
        "schema_version": "1.0.0",
    },
    "preregistration_path": "docs/roadmaps/evidence/r04/records/preregistration.json",
    "preregistration_required_keys": [
        "schema_version",
        "roadmap_version",
        "phase_id",
        "preregistration_state",
        "predecessor_binding",
        "toolchain_boundary",
        "observation_policy",
        "fixture_catalog",
        "schema_bindings",
        "contract",
        "subjects",
        "checks",
        "stop_rules",
        "authorization_boundary",
    ],
}
R05_LOCAL_CONTINUATION_EXCEPTION = {
    "active_phase_status": "in_progress",
    "closure_required_path": (
        "docs/roadmaps/evidence/r04/records/integration-conformance.json"
    ),
    "dependency_phase_id": "R04",
    "dependency_phase_status": "in_progress",
    "predecessor_binding": {
        "acceptance_state": "not_claimed",
        "accepted_merge_commit": None,
        "closure_commit": "88e26f5967f7eb35a54791017ca0c2b888f2fbf5",
        "closure_state": "local_unpublished_diagnostic_only_closure",
        "closure_tree": "4a7cc588b6fa51c21f2293e56cf3dea389acd908",
        "continuation_scope": "local_implementation_only",
        "phase_id": "R04",
        "predecessor_result": "diagnostic_only",
    },
    "preregistration_identity": {
        "phase_id": "R05",
        "preregistration_state": "contract_frozen_for_local_implementation",
        "roadmap_version": "1.0.1",
        "schema_version": "1.0.0",
    },
    "preregistration_path": "docs/roadmaps/evidence/r05/records/preregistration.json",
    "preregistration_required_keys": [
        "schema_version",
        "roadmap_version",
        "phase_id",
        "preregistration_state",
        "predecessor_binding",
        "toolchain_boundary",
        "observation_policy",
        "fixture_catalog",
        "schema_bindings",
        "contract",
        "subjects",
        "checks",
        "stop_rules",
        "authorization_boundary",
    ],
}
R06_LOCAL_CONTINUATION_EXCEPTION = {
    "active_phase_status": "in_progress",
    "closure_required_path": (
        "docs/roadmaps/evidence/r05/records/suitability-conformance.json"
    ),
    "dependency_phase_id": "R05",
    "dependency_phase_status": "in_progress",
    "predecessor_binding": {
        "acceptance_state": "not_claimed",
        "accepted_merge_commit": None,
        "closure_commit": "b955fc9d0b02dd066c359dfcb99a9ad31aeb817a",
        "closure_state": "local_unpublished_diagnostic_only_closure",
        "closure_tree": "10a97bd3df7f72834f7afcb7fa3b63c598fa4931",
        "continuation_scope": "local_implementation_only",
        "phase_id": "R05",
        "predecessor_result": "diagnostic_only",
    },
    "preregistration_identity": {
        "phase_id": "R06",
        "preregistration_state": "contract_frozen_for_local_implementation",
        "roadmap_version": "1.0.1",
        "schema_version": "1.0.0",
    },
    "preregistration_path": "docs/roadmaps/evidence/r06/records/preregistration.json",
    "preregistration_required_keys": [
        "schema_version",
        "roadmap_version",
        "phase_id",
        "preregistration_state",
        "predecessor_binding",
        "observation_policy",
        "fixture_catalog",
        "schema_bindings",
        "orchestration_contract",
        "ash_state_contract",
        "message_policy_contract",
        "scoring_contract",
        "transition_contract",
        "mask_contract",
        "product_gate",
        "ablations",
        "checks",
        "stop_rules",
        "authorization_boundary",
    ],
}
R07_LOCAL_CONTINUATION_EXCEPTION = {
    "active_phase_status": "in_progress",
    "closure_required_path": "docs/roadmaps/evidence/r06/phase-evidence.json",
    "dependency_phase_id": "R06",
    "dependency_phase_status": "in_progress",
    "predecessor_binding": {
        "acceptance_state": "not_claimed",
        "accepted_merge_commit": None,
        "closure_commit": "9ed01ea938a933f6406fd67e88edb74e7c84f5f4",
        "closure_state": "local_unpublished_blocked_closure",
        "closure_tree": "32365e745dbf53d59213fe2294a6b63ba2642df7",
        "continuation_scope": "local_implementation_only",
        "phase_id": "R06",
        "predecessor_result": "blocked",
    },
    "preregistration_identity": {
        "phase_id": "R07",
        "preregistration_state": "contract_frozen_for_local_implementation",
        "roadmap_version": "1.0.1",
        "schema_version": "1.0.0",
    },
    "preregistration_path": "docs/roadmaps/evidence/r07/records/preregistration.json",
    "preregistration_required_keys": [
        "schema_version",
        "roadmap_version",
        "phase_id",
        "preregistration_state",
        "predecessor_binding",
        "observation_policy",
        "fixture_catalog",
        "schema_bindings",
        "numeric_contract",
        "temporal_analysis_contract",
        "history_contract",
        "artifact_contract",
        "protected_content_contract",
        "weighted_mae_contract",
        "support_stage_contract",
        "postflight_feedback_contract",
        "product_comparator_contract",
        "product_gate",
        "checks",
        "stop_rules",
        "authorization_boundary",
    ],
}
R04_PHASE_START_REQUIREMENT = {
    "statuses": ["in_progress", "evidence_ready", "passed"],
    "paths": [
        "docs/roadmaps/evidence/r04/records/preregistration.json",
        "docs/roadmaps/evidence/r04/records/fixtures/fixture-catalog.json",
    ],
}
R05_PHASE_START_REQUIREMENT = {
    "statuses": ["in_progress", "evidence_ready", "passed"],
    "paths": [
        "docs/roadmaps/evidence/r05/records/preregistration.json",
        "docs/roadmaps/evidence/r05/records/fixtures/fixture-catalog.json",
    ],
}
R06_PHASE_START_REQUIREMENT = {
    "statuses": ["in_progress", "evidence_ready", "passed"],
    "paths": [
        "docs/roadmaps/evidence/r06/records/preregistration.json",
        "docs/roadmaps/evidence/r06/records/fixtures/fixture-catalog.json",
    ],
}
R07_PHASE_START_REQUIREMENT = {
    "statuses": ["in_progress", "evidence_ready", "passed"],
    "paths": [
        "docs/roadmaps/evidence/r07/records/preregistration.json",
        "docs/roadmaps/evidence/r07/records/fixtures/fixture-catalog.json",
    ],
}
R08_PHASE_START_REQUIREMENT = {
    "statuses": ["in_progress", "evidence_ready", "passed"],
    "paths": [
        "docs/roadmaps/evidence/r08/records/preregistration.json",
        "docs/roadmaps/evidence/r08/records/fixtures/fixture-catalog.json",
    ],
}
R10_PHASE_START_REQUIREMENT = {
    "statuses": ["in_progress", "evidence_ready", "passed"],
    "predecessors": ["R07", "R09"],
    "paths": [
        "docs/roadmaps/evidence/r10/records/preregistration.json",
        "docs/roadmaps/evidence/r10/records/fixtures/fixture-catalog.json",
        "docs/roadmaps/evidence/r10/records/fixtures/evaluation-catalog.json",
        "docs/roadmaps/evidence/r10/records/fixtures/policy-catalog.json",
    ],
}
R08_FUNCTIONAL_EVIDENCE_REQUIREMENT = {
    "required_status": "passed",
    "paths": [
        "Scripts/r08_phase_acceptance.py",
        "Scripts/tests/test_r08_phase_acceptance.py",
        (
            "docs/roadmaps/evidence/schema/"
            "r08-functional-execution-receipt-v1.json"
        ),
        (
            "docs/roadmaps/evidence/schema/"
            "r08-functional-phase-acceptance-v1.json"
        ),
        "docs/roadmaps/evidence/r08/records/functional-execution-receipt.json",
        "docs/roadmaps/evidence/r08/records/functional-phase-acceptance.json",
        (
            "docs/roadmaps/evidence/r08/records/artifacts/"
            "functional-phase-acceptance/xcodebuild.log"
        ),
        (
            "docs/roadmaps/evidence/r08/records/artifacts/"
            "functional-phase-acceptance/xcresult-summary.json"
        ),
    ],
}
R09_FUNCTIONAL_EVIDENCE_REQUIREMENT = {
    "required_status": "passed",
    "paths": [
        "Scripts/r09_phase_acceptance.py",
        "Scripts/tests/test_r09_phase_acceptance.py",
        (
            "docs/roadmaps/evidence/schema/"
            "r09-functional-execution-receipt-v1.json"
        ),
        (
            "docs/roadmaps/evidence/schema/"
            "r09-functional-phase-acceptance-v1.json"
        ),
        "docs/roadmaps/evidence/r09/records/functional-execution-receipt.json",
        "docs/roadmaps/evidence/r09/records/functional-phase-acceptance.json",
        (
            "docs/roadmaps/evidence/r09/records/artifacts/"
            "functional-phase-acceptance/xcodebuild.log"
        ),
        (
            "docs/roadmaps/evidence/r09/records/artifacts/"
            "functional-phase-acceptance/xcresult-summary.json"
        ),
    ],
}
R10_FUNCTIONAL_EVIDENCE_REQUIREMENT = {
    "required_status": "passed",
    "paths": [
        "Scripts/r10_phase_acceptance.py",
        "Scripts/tests/test_r10_phase_acceptance.py",
        "docs/roadmaps/evidence/schema/r10-calibration-run-receipt-v1.json",
        "docs/roadmaps/evidence/schema/r10-functional-execution-receipt-v1.json",
        "docs/roadmaps/evidence/schema/r10-functional-phase-acceptance-v1.json",
        "docs/roadmaps/evidence/r10/records/functional-execution-receipt.json",
        "docs/roadmaps/evidence/r10/records/functional-phase-acceptance.json",
        (
            "docs/roadmaps/evidence/r10/records/artifacts/"
            "functional-phase-acceptance/unittest.log"
        ),
        (
            "docs/roadmaps/evidence/r10/records/artifacts/"
            "functional-phase-acceptance/calibration-run/run-receipt.json"
        ),
    ],
}


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def read_json(path: Path) -> dict[str, Any]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError("top-level JSON value must be an object")
    return value


def escape_table_cell(value: str) -> str:
    return value.replace("|", "\\|").replace("\n", " ")


def render_progress(roadmap: dict[str, Any], policy: dict[str, Any]) -> str:
    progress = policy["progress"]
    phase_order = progress["phase_order"]
    phases = roadmap["phases"]
    phase_by_id = {phase["id"]: phase for phase in phases}
    ordered = [phase_by_id[phase_id] for phase_id in phase_order]
    completed_statuses = set(progress["completed_statuses"])
    indicators = progress["status_indicators"]
    status_order = progress["status_order"]
    passed = sum(phase["status"] in completed_statuses for phase in ordered)
    total = len(ordered)
    percent = 0 if total == 0 else (passed * 100) // total
    width = int(progress["bar_width"])
    filled = 0 if total == 0 else (passed * width) // total
    bar = "[" + ("#" * filled) + ("-" * (width - filled)) + "]"
    counts = Counter(phase["status"] for phase in ordered)
    status_summary = " · ".join(
        f"{indicators[status]} `{counts[status]}`"
        for status in status_order
        if counts[status]
    )
    active = [
        phase
        for phase in ordered
        if phase["status"] in {"next", "in_progress", "evidence_ready"}
    ]
    if active:
        current_focus = "; ".join(
            f"`{phase['id']}` — {phase['name']}" for phase in active
        )
    else:
        current_focus = "No phase is marked `next`, `in_progress`, or `evidence_ready`."

    lines = [
        f"**Overall:** `{passed} / {total}` roadmap phases passed (`{percent}%`)",
        "",
        f"`{bar}`",
        "",
        f"**Status:** {status_summary}",
        "",
        f"**Current focus:** {current_focus}",
        "",
        "| Phase | Roadmap phase | Status | Progress |",
        "| --- | --- | --- | --- |",
    ]
    for phase in ordered:
        status = phase["status"]
        lines.append(
            "| "
            f"`{escape_table_cell(phase['id'])}` | "
            f"{escape_table_cell(phase['name'])} | "
            f"`{escape_table_cell(status)}` | "
            f"{escape_table_cell(indicators[status])} |"
        )
    return "\n".join(lines)


def compare_github_metadata(
    payload: dict[str, Any], expected: dict[str, Any]
) -> list[str]:
    errors: list[str] = []
    if payload.get("full_name") != expected["name_with_owner"]:
        errors.append(
            "GitHub repository identity differs from policy: "
            f"expected {expected['name_with_owner']!r}, "
            f"found {payload.get('full_name')!r}"
        )
    if payload.get("description") != expected["description"]:
        errors.append("GitHub repository description differs from policy")
    actual_topics = sorted(payload.get("topics") or [])
    expected_topics = sorted(expected["topics"])
    if actual_topics != expected_topics:
        errors.append(
            "GitHub repository topics differ from policy: "
            f"expected {expected_topics!r}, found {actual_topics!r}"
        )
    return errors


class AlignmentVerifier:
    def __init__(
        self,
        root: Path,
        policy_path: Path = DEFAULT_POLICY_PATH,
        history_root: Path | None = None,
    ) -> None:
        self.root = root.resolve()
        self.history_root = (history_root or root).resolve()
        self.policy_path = (
            policy_path
            if policy_path.is_absolute()
            else self.root / policy_path
        )
        self.policy = read_json(self.policy_path)
        self.errors: list[str] = []
        self.roadmap: dict[str, Any] | None = None
        self.roadmap_markdown = ""
        self.readme_text = ""
        self._tracked_paths_cache: list[str] | None = None

    def history_git(self, *arguments: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["git", *arguments],
            cwd=self.history_root,
            check=False,
            capture_output=True,
            text=True,
        )

    def path(self, relative: str) -> Path:
        return self.root / relative

    def add_error(self, relative: str, message: str) -> None:
        self.errors.append(f"{relative}: {message}")

    def read_text(self, relative: str) -> str | None:
        path = self.path(relative)
        if not path.is_file():
            self.add_error(relative, "required file is missing")
            return None
        try:
            return path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            self.add_error(relative, "required text file is not valid UTF-8")
            return None

    def check(self) -> list[str]:
        self.errors = []
        self._check_canonical_sources()
        if self.roadmap is not None:
            self._check_roadmap_contract()
            self._check_roadmap_index()
            self._check_readme_canonical_copy()
            self._check_readme_progress()
            self._check_forsetti_boundary()
            self._check_inventory_status_coupling()
            self._check_phase_start_requirements()
            self._check_phase_evidence_requirements()
        self._check_required_phrases()
        self._check_phase_status_documents()
        self._check_forbidden_tracked_paths()
        self._check_workflows()
        return sorted(set(self.errors))

    def _check_canonical_sources(self) -> None:
        canonical = self.policy["canonical"]
        markdown_relative = canonical["markdown_path"]
        json_relative = canonical["json_path"]
        markdown_path = self.path(markdown_relative)
        json_path = self.path(json_relative)

        if markdown_path.is_file():
            actual = sha256(markdown_path)
            if actual != canonical["markdown_sha256"]:
                self.add_error(
                    markdown_relative,
                    "SHA-256 differs from roadmap alignment policy: "
                    f"expected {canonical['markdown_sha256']}, found {actual}",
                )
            try:
                self.roadmap_markdown = markdown_path.read_text(encoding="utf-8")
            except UnicodeDecodeError:
                self.add_error(markdown_relative, "canonical Markdown is not UTF-8")
        else:
            self.add_error(markdown_relative, "canonical Markdown is missing")

        if json_path.is_file():
            actual = sha256(json_path)
            if actual != canonical["json_sha256"]:
                self.add_error(
                    json_relative,
                    "SHA-256 differs from roadmap alignment policy: "
                    f"expected {canonical['json_sha256']}, found {actual}",
                )
            try:
                self.roadmap = read_json(json_path)
            except (UnicodeDecodeError, json.JSONDecodeError, ValueError) as exc:
                self.add_error(json_relative, f"canonical JSON is invalid: {exc}")
        else:
            self.add_error(json_relative, "canonical JSON is missing")

    def _check_roadmap_contract(self) -> None:
        assert self.roadmap is not None
        roadmap = self.roadmap
        canonical = self.policy["canonical"]
        contract = self.policy["contract"]
        json_relative = canonical["json_path"]

        self._local_continuation_exception_contract_is_exact()
        self._phase_acceptance_override_contract_is_exact()

        for key in ("schema_version", "roadmap_version", "date", "revision_date"):
            expected = canonical[key]
            if roadmap.get(key) != expected:
                self.add_error(
                    json_relative,
                    f"{key} differs from policy: expected {expected!r}, "
                    f"found {roadmap.get(key)!r}",
                )

        phases = roadmap.get("phases")
        if not isinstance(phases, list):
            self.add_error(json_relative, "phases must be an array")
            return
        phase_ids = [phase.get("id") for phase in phases if isinstance(phase, dict)]
        if len(phase_ids) != len(phases):
            self.add_error(json_relative, "every phase must be an object with an ID")
            return
        if len(phase_ids) != len(set(phase_ids)):
            self.add_error(json_relative, "phase IDs must be unique")
        if phase_ids != contract["phase_ids"]:
            self.add_error(
                json_relative,
                f"phase IDs/order differ from policy: {phase_ids!r}",
            )
        if self.policy["progress"]["phase_order"] != contract["phase_ids"]:
            self.add_error(
                self.policy_path.relative_to(self.root).as_posix(),
                "progress.phase_order must equal contract.phase_ids",
            )

        methods = roadmap.get("apple_methods")
        if not isinstance(methods, list):
            self.add_error(json_relative, "apple_methods must be an array")
        else:
            method_ids = [
                method.get("id") for method in methods if isinstance(method, dict)
            ]
            if len(method_ids) != len(methods):
                self.add_error(
                    json_relative,
                    "every Apple method must be an object with an ID",
                )
            else:
                if len(method_ids) != len(set(method_ids)):
                    self.add_error(json_relative, "Apple method IDs must be unique")
                if method_ids != contract["apple_method_ids"]:
                    self.add_error(
                        json_relative,
                        f"Apple method IDs/order differ from policy: {method_ids!r}",
                    )

        if roadmap.get("authorizations") != contract["authorizations"]:
            self.add_error(
                json_relative,
                "authorizations differ from the exact roadmap alignment contract",
            )

        allowed_statuses = set(self.policy["progress"]["status_indicators"])
        status_order = self.policy["progress"]["status_order"]
        completed_statuses = set(self.policy["progress"]["completed_statuses"])
        if len(status_order) != len(set(status_order)) or set(status_order) != allowed_statuses:
            self.add_error(
                self.policy_path.relative_to(self.root).as_posix(),
                "progress.status_order must list every supported status exactly once",
            )
        if not completed_statuses <= allowed_statuses:
            self.add_error(
                self.policy_path.relative_to(self.root).as_posix(),
                "progress.completed_statuses contains an unsupported status",
            )
        if not isinstance(self.policy["progress"]["bar_width"], int) or self.policy["progress"]["bar_width"] <= 0:
            self.add_error(
                self.policy_path.relative_to(self.root).as_posix(),
                "progress.bar_width must be a positive integer",
            )
        phase_by_id = {phase["id"]: phase for phase in phases}
        dependencies: dict[str, list[str]] = {}
        for phase in phases:
            phase_id = phase["id"]
            status = phase.get("status")
            if status not in allowed_statuses:
                self.add_error(
                    json_relative,
                    f"phase {phase_id} has unsupported status {status!r}",
                )
            if not isinstance(phase.get("name"), str) or not phase["name"].strip():
                self.add_error(json_relative, f"phase {phase_id} has no name")
            required = phase.get("depends_on")
            if not isinstance(required, list) or not all(
                isinstance(item, str) for item in required
            ):
                self.add_error(
                    json_relative,
                    f"phase {phase_id} depends_on must be an array of IDs",
                )
                dependencies[phase_id] = []
                continue
            dependencies[phase_id] = required
            if len(required) != len(set(required)):
                self.add_error(
                    json_relative,
                    f"phase {phase_id} repeats a dependency",
                )
            for dependency in required:
                if dependency not in phase_by_id:
                    self.add_error(
                        json_relative,
                        f"phase {phase_id} references unknown dependency {dependency}",
                    )
                if dependency == phase_id:
                    self.add_error(
                        json_relative,
                        f"phase {phase_id} depends on itself",
                    )

        self._check_dependency_cycles(dependencies, json_relative)
        self._check_markdown_phase_statuses(phases, canonical["markdown_path"])
        active_statuses = {"next", "in_progress", "evidence_ready", "passed"}
        for phase_id, required in dependencies.items():
            phase = phase_by_id[phase_id]
            if phase.get("status") not in active_statuses:
                continue
            for dependency in required:
                dependency_phase = phase_by_id.get(dependency)
                if dependency_phase is not None and dependency_phase.get("status") != "passed":
                    if self._phase_acceptance_override_allows(
                        phase_id,
                        phase.get("status"),
                        dependency,
                        dependency_phase.get("status"),
                    ):
                        continue
                    if self._local_continuation_exception_allows(
                        phase_id,
                        phase.get("status"),
                        dependency,
                        dependency_phase.get("status"),
                        json_relative,
                    ):
                        continue
                    self.add_error(
                        json_relative,
                        f"phase {phase_id} is {phase.get('status')!r} before "
                        f"dependency {dependency} is passed",
                    )

    def _phase_acceptance_override_allows(
        self,
        phase_id: str,
        phase_status: object,
        dependency_id: str,
        dependency_status: object,
    ) -> bool:
        if not self._phase_acceptance_override_contract_is_exact():
            return False
        if phase_id == "R07":
            return self._r07_phase_acceptance_override_allows(
                phase_status,
                dependency_id,
                dependency_status,
            )
        override = self.policy["phase_acceptance_overrides"].get(phase_id)
        if not isinstance(override, dict):
            return False
        if (
            phase_status != override.get("active_phase_status")
            or dependency_id != override.get("dependency_phase_id")
            or dependency_status != override.get("dependency_phase_status")
        ):
            return False

        valid = True
        for key in ("dependency_conformance_binding", "acceptance_record_binding"):
            binding = override.get(key)
            if not isinstance(binding, dict) or set(binding) != {
                "path",
                "size_bytes",
                "sha256",
            }:
                self.add_error(
                    self.policy_path.relative_to(self.root).as_posix(),
                    f"R03 phase acceptance {key} is malformed",
                )
                valid = False
                continue
            relative = binding.get("path")
            path = self.path(relative) if isinstance(relative, str) else None
            if path is None or path.is_symlink() or not path.is_file():
                self.add_error(
                    str(relative),
                    f"R03 phase acceptance {key} is not a regular file",
                )
                valid = False
                continue
            if (
                path.stat().st_size != binding.get("size_bytes")
                or sha256(path) != binding.get("sha256")
            ):
                self.add_error(
                    relative,
                    f"R03 phase acceptance {key} bytes differ",
                )
                valid = False

        acceptance_binding = override.get("acceptance_record_binding")
        dependency_binding = override.get("dependency_conformance_binding")
        try:
            acceptance = read_json(
                self.path(acceptance_binding["path"])
            ) if isinstance(acceptance_binding, dict) else None
        except (OSError, ValueError, json.JSONDecodeError) as exc:
            self.add_error(
                "docs/roadmaps/evidence/r03/records/functional-phase-acceptance.json",
                f"R03 phase acceptance record is invalid: {exc}",
            )
            acceptance = None
            valid = False
        try:
            conformance = read_json(
                self.path(dependency_binding["path"])
            ) if isinstance(dependency_binding, dict) else None
        except (OSError, ValueError, json.JSONDecodeError) as exc:
            self.add_error(
                "docs/roadmaps/evidence/r02/records/conformance.json",
                f"R02 conformance record is invalid: {exc}",
            )
            conformance = None
            valid = False

        identity = override.get("acceptance_identity")
        if isinstance(acceptance, dict) and isinstance(identity, dict):
            observed_identity = {
                "schema_version": acceptance.get("schema_version"),
                "roadmap_version": acceptance.get("roadmap_version"),
                "phase_id": acceptance.get("phase_id"),
                "evidence_kind": acceptance.get("evidence_kind"),
                "override_id": (
                    acceptance.get("operator_override", {}).get("override_id")
                    if isinstance(acceptance.get("operator_override"), dict)
                    else None
                ),
                "result": acceptance.get("result"),
            }
            if observed_identity != identity:
                self.add_error(
                    acceptance_binding["path"],
                    "R03 phase acceptance identity differs",
                )
                valid = False
        else:
            valid = False

        result = conformance.get("result") if isinstance(conformance, dict) else None
        if not isinstance(result, dict) or result.get("status") != "passed":
            self.add_error(
                dependency_binding["path"]
                if isinstance(dependency_binding, dict)
                else "docs/roadmaps/evidence/r02/records/conformance.json",
                "R03 phase acceptance requires passing R02 software conformance",
            )
            valid = False
        return valid

    def _r07_phase_acceptance_override_allows(
        self,
        phase_status: object,
        dependency_id: str,
        dependency_status: object,
    ) -> bool:
        override = self.policy["phase_acceptance_overrides"].get("R07")
        if not isinstance(override, dict):
            return False
        if (
            phase_status != override.get("active_phase_status")
            or dependency_id != override.get("dependency_phase_id")
            or dependency_status != override.get("dependency_phase_status")
        ):
            return False

        valid = True
        binding_keys = (
            "dependency_phase_evidence_binding",
            "dependency_conformance_binding",
            "acceptance_record_binding",
        )
        records: dict[str, Any] = {}
        for key in binding_keys:
            binding = override.get(key)
            if not isinstance(binding, dict) or set(binding) != {
                "path",
                "size_bytes",
                "sha256",
            }:
                self.add_error(
                    self.policy_path.relative_to(self.root).as_posix(),
                    f"R07 phase acceptance {key} is malformed",
                )
                valid = False
                continue
            relative = binding.get("path")
            path = self.path(relative) if isinstance(relative, str) else None
            if path is None or path.is_symlink() or not path.is_file():
                self.add_error(
                    str(relative),
                    f"R07 phase acceptance {key} is not a regular file",
                )
                valid = False
                continue
            if (
                path.stat().st_size != binding.get("size_bytes")
                or sha256(path) != binding.get("sha256")
            ):
                self.add_error(
                    relative,
                    f"R07 phase acceptance {key} bytes differ",
                )
                valid = False
            try:
                records[key] = read_json(path)
            except (OSError, ValueError, json.JSONDecodeError) as exc:
                self.add_error(
                    relative,
                    f"R07 phase acceptance {key} is invalid: {exc}",
                )
                valid = False

        acceptance_binding = override.get("acceptance_record_binding")
        acceptance = records.get("acceptance_record_binding")
        identity = override.get("acceptance_identity")
        if isinstance(acceptance, dict) and isinstance(identity, dict):
            operator_override = acceptance.get("operator_override")
            observed_identity = {
                "schema_version": acceptance.get("schema_version"),
                "roadmap_version": acceptance.get("roadmap_version"),
                "phase_id": acceptance.get("phase_id"),
                "evidence_kind": acceptance.get("evidence_kind"),
                "override_id": (
                    operator_override.get("override_id")
                    if isinstance(operator_override, dict)
                    else None
                ),
                "comparative_requirement": (
                    operator_override.get("comparative_requirement")
                    if isinstance(operator_override, dict)
                    else None
                ),
                "dependency_alignment_override": acceptance.get(
                    "dependency_alignment_override"
                ),
                "superseded_gate": acceptance.get("superseded_gate"),
                "result": acceptance.get("result"),
            }
            if observed_identity != identity:
                self.add_error(
                    acceptance_binding["path"],
                    "R07 phase acceptance identity differs",
                )
                valid = False
        else:
            valid = False

        phase_evidence = records.get("dependency_phase_evidence_binding")
        phase_result = (
            phase_evidence.get("result")
            if isinstance(phase_evidence, dict)
            else None
        )
        if (
            not isinstance(phase_result, dict)
            or phase_result.get("status") != "blocked"
            or phase_result.get("phase_status_after") != "in_progress"
        ):
            self.add_error(
                override["dependency_phase_evidence_binding"]["path"],
                "R07 phase acceptance requires frozen blocked R06 phase evidence",
            )
            valid = False

        conformance = records.get("dependency_conformance_binding")
        conformance_result = (
            conformance.get("result") if isinstance(conformance, dict) else None
        )
        if (
            not isinstance(conformance_result, dict)
            or conformance_result.get("status") != "blocked"
            or conformance_result.get("acceptance") != "not_claimed"
            or conformance_result.get("product_qualification") != "not_claimed"
        ):
            self.add_error(
                override["dependency_conformance_binding"]["path"],
                "R07 phase acceptance requires frozen unaccepted R06 conformance",
            )
            valid = False
        return valid

    def _phase_acceptance_override_contract_is_exact(self) -> bool:
        expected = {
            "R03": R03_PHASE_ACCEPTANCE_OVERRIDE,
            "R07": R07_PHASE_ACCEPTANCE_OVERRIDE,
        }
        if self.policy.get("phase_acceptance_overrides") != expected:
            self.add_error(
                self.policy_path.relative_to(self.root).as_posix(),
                "phase_acceptance_overrides differ from the exact R03 functional "
                "contract or the exact R07 functional contract",
            )
            return False
        return True

    def _local_continuation_exception_allows(
        self,
        phase_id: str,
        phase_status: object,
        dependency_id: str,
        dependency_status: object,
        roadmap_relative: str,
    ) -> bool:
        if not self._local_continuation_exception_contract_is_exact():
            return False
        exceptions = self.policy.get("local_continuation_exceptions")
        assert isinstance(exceptions, dict)
        exception = exceptions.get(phase_id)
        if not isinstance(exception, dict):
            return False
        expected_exception_keys = {
            "active_phase_status",
            "closure_required_path",
            "dependency_phase_id",
            "dependency_phase_status",
            "predecessor_binding",
            "preregistration_identity",
            "preregistration_path",
            "preregistration_required_keys",
        }
        if set(exception) != expected_exception_keys:
            self.add_error(
                self.policy_path.relative_to(self.root).as_posix(),
                f"local continuation exception keys differ for {phase_id}",
            )
            return False
        if (
            phase_status != exception.get("active_phase_status")
            or dependency_id != exception.get("dependency_phase_id")
            or dependency_status != exception.get("dependency_phase_status")
        ):
            return False
        relative = exception.get("preregistration_path")
        required_keys = exception.get("preregistration_required_keys")
        identity = exception.get("preregistration_identity")
        predecessor = exception.get("predecessor_binding")
        if (
            not isinstance(relative, str)
            or not relative
            or not isinstance(required_keys, list)
            or not required_keys
            or len(required_keys) != len(set(required_keys))
            or not all(isinstance(key, str) and key for key in required_keys)
            or not isinstance(identity, dict)
            or not isinstance(predecessor, dict)
        ):
            self.add_error(
                self.policy_path.relative_to(self.root).as_posix(),
                f"local continuation exception is malformed for {phase_id}",
            )
            return False
        if set(identity) != {
            "schema_version",
            "roadmap_version",
            "phase_id",
            "preregistration_state",
        }:
            self.add_error(
                self.policy_path.relative_to(self.root).as_posix(),
                f"local continuation identity keys differ for {phase_id}",
            )
            return False
        expected_predecessor_keys = {
            "phase_id",
            "closure_state",
            "closure_commit",
            "closure_tree",
            "accepted_merge_commit",
            "acceptance_state",
            "continuation_scope",
        }
        if "predecessor_result" in predecessor:
            expected_predecessor_keys.add("predecessor_result")
        if set(predecessor) != expected_predecessor_keys:
            self.add_error(
                self.policy_path.relative_to(self.root).as_posix(),
                f"local continuation predecessor keys differ for {phase_id}",
            )
            return False
        path = self.path(relative)
        if path.is_symlink() or not path.is_file():
            self.add_error(
                relative,
                f"phase {phase_id} local continuation requires a regular preregistration file",
            )
            return False
        try:
            preregistration = read_json(path)
        except (OSError, ValueError, json.JSONDecodeError) as exc:
            self.add_error(relative, f"local continuation preregistration is invalid: {exc}")
            return False
        valid = True
        if set(preregistration) != set(required_keys):
            self.add_error(relative, "local continuation preregistration keys differ")
            valid = False
        for key, expected in identity.items():
            if preregistration.get(key) != expected:
                self.add_error(
                    relative,
                    f"local continuation preregistration {key} differs",
                )
                valid = False
        if preregistration.get("predecessor_binding") != predecessor:
            self.add_error(relative, "local continuation predecessor binding differs")
            valid = False
        commit = predecessor.get("closure_commit")
        tree = predecessor.get("closure_tree")
        if not isinstance(commit, str) or not isinstance(tree, str):
            self.add_error(relative, "local continuation closure identity is malformed")
            return False
        if self.history_git("cat-file", "-e", f"{commit}^{{commit}}").returncode != 0:
            self.add_error(relative, "local continuation closure commit is unavailable")
            valid = False
        elif self.history_git("rev-parse", f"{commit}^{{tree}}").stdout.strip() != tree:
            self.add_error(relative, "local continuation closure tree differs")
            valid = False
        if self.history_git("merge-base", "--is-ancestor", commit, "HEAD").returncode != 0:
            self.add_error(relative, "local continuation closure is not an ancestor of HEAD")
            valid = False
        closure_path = exception.get("closure_required_path")
        if (
            not isinstance(closure_path, str)
            or self.history_git("cat-file", "-e", f"{commit}:{closure_path}").returncode != 0
        ):
            self.add_error(relative, "local continuation closure record is unavailable")
            valid = False
        if not valid:
            self.add_error(
                roadmap_relative,
                f"phase {phase_id} local continuation exception is not satisfied",
            )
        return valid

    def _local_continuation_exception_contract_is_exact(self) -> bool:
        exceptions = self.policy.get("local_continuation_exceptions")
        expected = {
            "R03": R03_LOCAL_CONTINUATION_EXCEPTION,
            "R04": R04_LOCAL_CONTINUATION_EXCEPTION,
            "R05": R05_LOCAL_CONTINUATION_EXCEPTION,
            "R06": R06_LOCAL_CONTINUATION_EXCEPTION,
            "R07": R07_LOCAL_CONTINUATION_EXCEPTION,
        }
        if exceptions != expected:
            self.add_error(
                self.policy_path.relative_to(self.root).as_posix(),
                "local_continuation_exceptions differ from the frozen R03/R04/R05/R06/R07 exceptions",
            )
            return False
        return True

    def _check_markdown_phase_statuses(
        self, phases: list[dict[str, Any]], relative: str
    ) -> None:
        if not self.roadmap_markdown:
            return
        for phase in phases:
            phase_id = phase["id"]
            section = re.search(
                rf"(?ms)^## {re.escape(phase_id)} —[^\n]*\n"
                rf"(?P<body>.*?)(?=^## R[0-9]{{2}} —|\Z)",
                self.roadmap_markdown,
            )
            if section is None:
                self.add_error(relative, f"phase section is missing for {phase_id}")
                continue
            expected = f"**Status:** `{phase.get('status')}`"
            if expected not in section.group("body"):
                self.add_error(
                    relative,
                    f"phase {phase_id} Markdown status differs from canonical JSON; "
                    f"expected {expected!r}",
                )

    def _check_dependency_cycles(
        self, dependencies: dict[str, list[str]], relative: str
    ) -> None:
        visiting: list[str] = []
        visited: set[str] = set()
        reported: set[tuple[str, ...]] = set()

        def visit(phase_id: str) -> None:
            if phase_id in visiting:
                start = visiting.index(phase_id)
                cycle = tuple(visiting[start:] + [phase_id])
                if cycle not in reported:
                    reported.add(cycle)
                    self.add_error(
                        relative,
                        "phase dependency cycle detected: " + " -> ".join(cycle),
                    )
                return
            if phase_id in visited:
                return
            visiting.append(phase_id)
            for dependency in dependencies.get(phase_id, []):
                if dependency in dependencies:
                    visit(dependency)
            visiting.pop()
            visited.add(phase_id)

        for phase_id in dependencies:
            visit(phase_id)

    def _check_roadmap_index(self) -> None:
        assert self.roadmap is not None
        canonical = self.policy["canonical"]
        relative = canonical["index_path"]
        text = self.read_text(relative)
        if text is None:
            return
        expected_values = {
            f"Roadmap {canonical['roadmap_version']}": "roadmap version",
            canonical["date"]: "roadmap date",
            canonical["revision_date"]: "roadmap revision date",
            canonical["markdown_sha256"]: "Markdown SHA-256",
            canonical["json_sha256"]: "JSON SHA-256",
        }
        for value, label in expected_values.items():
            if value not in text:
                self.add_error(relative, f"index does not display the exact {label}")

    def _read_readme(self) -> str | None:
        if self.readme_text:
            return self.readme_text
        relative = self.policy["readme"]["path"]
        text = self.read_text(relative)
        if text is not None:
            self.readme_text = text
        return text

    def _extract_between_markers(
        self, text: str, start: str, end: str, relative: str, label: str
    ) -> str | None:
        if text.count(start) != 1 or text.count(end) != 1:
            self.add_error(
                relative,
                f"{label} markers must each occur exactly once",
            )
            return None
        start_index = text.index(start) + len(start)
        end_index = text.index(end)
        if start_index >= end_index:
            self.add_error(relative, f"{label} markers are out of order")
            return None
        return text[start_index:end_index]

    def _check_readme_canonical_copy(self) -> None:
        text = self._read_readme()
        if text is None or not self.roadmap_markdown:
            return
        readme_policy = self.policy["readme"]
        relative = readme_policy["path"]
        actual = self._extract_between_markers(
            text,
            readme_policy["canonical_start_marker"],
            readme_policy["canonical_end_marker"],
            relative,
            "canonical-roadmap",
        )
        if actual is None:
            return
        expected = "\n" + self.roadmap_markdown.replace("  \n", "<br>\n")
        if actual != expected:
            self.add_error(
                relative,
                "embedded canonical roadmap differs from canonical Markdown "
                "after hard-break rendering",
            )

    def _check_readme_progress(self) -> None:
        assert self.roadmap is not None
        text = self._read_readme()
        if text is None:
            return
        readme_policy = self.policy["readme"]
        relative = readme_policy["path"]
        if text.count(self.policy["progress"]["heading"]) != 1:
            self.add_error(relative, "Roadmap Progress heading must occur exactly once")
        actual = self._extract_between_markers(
            text,
            readme_policy["progress_start_marker"],
            readme_policy["progress_end_marker"],
            relative,
            "roadmap-progress",
        )
        if actual is None:
            return
        try:
            expected = "\n" + render_progress(self.roadmap, self.policy) + "\n"
        except (KeyError, TypeError, ValueError) as exc:
            self.add_error(relative, f"cannot render roadmap progress: {exc}")
            return
        if actual != expected:
            self.add_error(
                relative,
                "Roadmap Progress block is stale; run "
                "`python3 Scripts/roadmap_alignment.py --write-progress`",
            )

    def _check_required_phrases(self) -> None:
        for relative, phrases in self.policy["required_phrases"].items():
            text = self.read_text(relative)
            if text is None:
                continue
            for phrase in phrases:
                if phrase not in text:
                    self.add_error(relative, f"required alignment text is missing: {phrase!r}")

    def _check_phase_status_documents(self) -> None:
        if self.roadmap is None:
            return
        phase_by_id = {
            phase["id"]: phase
            for phase in self.roadmap.get("phases", [])
            if isinstance(phase, dict) and isinstance(phase.get("id"), str)
        }
        for relative, phase_ids in self.policy["phase_status_documents"].items():
            text = self.read_text(relative)
            if text is None:
                continue
            for phase_id in phase_ids:
                phase = phase_by_id.get(phase_id)
                if phase is None:
                    self.add_error(relative, f"status contract references missing phase {phase_id}")
                    continue
                expected = f"Roadmap phase `{phase_id}`: `{phase.get('status')}`"
                if expected not in text:
                    self.add_error(
                        relative,
                        f"phase status text differs from canonical JSON; expected {expected!r}",
                    )

    def _check_phase_evidence_requirements(self) -> None:
        assert self.roadmap is not None
        phase_by_id = {
            phase["id"]: phase
            for phase in self.roadmap.get("phases", [])
            if isinstance(phase, dict) and isinstance(phase.get("id"), str)
        }
        requirements = self.policy.get("phase_evidence_requirements")
        if not isinstance(requirements, dict):
            self.add_error(
                self.policy_path.relative_to(self.root).as_posix(),
                "phase_evidence_requirements must be an object",
            )
            return
        if requirements.get("R08") != R08_FUNCTIONAL_EVIDENCE_REQUIREMENT:
            self.add_error(
                self.policy_path.relative_to(self.root).as_posix(),
                "R08 phase_evidence_requirements differ from the frozen "
                "software-function acceptance contract",
            )
        if requirements.get("R09") != R09_FUNCTIONAL_EVIDENCE_REQUIREMENT:
            self.add_error(
                self.policy_path.relative_to(self.root).as_posix(),
                "R09 phase_evidence_requirements differ from the frozen "
                "software-function acceptance contract",
            )
        if requirements.get("R10") != R10_FUNCTIONAL_EVIDENCE_REQUIREMENT:
            self.add_error(
                self.policy_path.relative_to(self.root).as_posix(),
                "R10 phase_evidence_requirements differ from the prospective "
                "software-function acceptance contract",
            )
        for phase_id, requirement in requirements.items():
            phase = phase_by_id.get(phase_id)
            if phase is None or not isinstance(requirement, dict):
                self.add_error(
                    self.policy_path.relative_to(self.root).as_posix(),
                    f"phase evidence requirement is invalid for {phase_id}",
                )
                continue
            required_status = requirement.get("required_status")
            paths = requirement.get("paths")
            if not isinstance(required_status, str) or not isinstance(paths, list) or not all(
                isinstance(path, str) and path for path in paths
            ):
                self.add_error(
                    self.policy_path.relative_to(self.root).as_posix(),
                    f"phase evidence requirement fields are invalid for {phase_id}",
                )
                continue
            if phase.get("status") != required_status:
                continue
            for relative in paths:
                path = self.path(relative)
                if path.is_symlink() or not path.is_file():
                    self.add_error(
                        relative,
                        f"phase {phase_id} status {required_status!r} requires a regular evidence file",
                    )

    def _check_phase_start_requirements(self) -> None:
        assert self.roadmap is not None
        phase_by_id = {
            phase["id"]: phase
            for phase in self.roadmap.get("phases", [])
            if isinstance(phase, dict) and isinstance(phase.get("id"), str)
        }
        requirements = self.policy.get("phase_start_requirements")
        if not isinstance(requirements, dict):
            self.add_error(
                self.policy_path.relative_to(self.root).as_posix(),
                "phase_start_requirements must be an object",
            )
            return
        if requirements.get("R04") != R04_PHASE_START_REQUIREMENT:
            self.add_error(
                self.policy_path.relative_to(self.root).as_posix(),
                "R04 phase_start_requirements differ from the frozen contract",
            )
        if requirements.get("R05") != R05_PHASE_START_REQUIREMENT:
            self.add_error(
                self.policy_path.relative_to(self.root).as_posix(),
                "R05 phase_start_requirements differ from the frozen contract",
            )
        if requirements.get("R06") != R06_PHASE_START_REQUIREMENT:
            self.add_error(
                self.policy_path.relative_to(self.root).as_posix(),
                "R06 phase_start_requirements differ from the frozen contract",
            )
        if requirements.get("R07") != R07_PHASE_START_REQUIREMENT:
            self.add_error(
                self.policy_path.relative_to(self.root).as_posix(),
                "R07 phase_start_requirements differ from the frozen contract",
            )
        if requirements.get("R08") != R08_PHASE_START_REQUIREMENT:
            self.add_error(
                self.policy_path.relative_to(self.root).as_posix(),
                "R08 phase_start_requirements differ from the frozen contract",
            )
        if requirements.get("R10") != R10_PHASE_START_REQUIREMENT:
            self.add_error(
                self.policy_path.relative_to(self.root).as_posix(),
                "R10 phase_start_requirements differ from the frozen contract",
            )
        for phase_id, requirement in requirements.items():
            phase = phase_by_id.get(phase_id)
            if phase is None or not isinstance(requirement, dict):
                self.add_error(
                    self.policy_path.relative_to(self.root).as_posix(),
                    f"phase start requirement is invalid for {phase_id}",
                )
                continue
            statuses = requirement.get("statuses")
            predecessors = requirement.get("predecessors")
            paths = requirement.get("paths")
            if (
                not isinstance(statuses, list)
                or not statuses
                or len(statuses) != len(set(statuses))
                or not all(isinstance(status, str) and status for status in statuses)
                or not isinstance(paths, list)
                or not paths
                or len(paths) != len(set(paths))
                or not all(isinstance(path, str) and path for path in paths)
            ):
                self.add_error(
                    self.policy_path.relative_to(self.root).as_posix(),
                    f"phase start requirement fields are invalid for {phase_id}",
                )
                continue
            if predecessors is not None and (
                not isinstance(predecessors, list)
                or not predecessors
                or len(predecessors) != len(set(predecessors))
                or not all(
                    isinstance(predecessor, str) and predecessor
                    for predecessor in predecessors
                )
            ):
                self.add_error(
                    self.policy_path.relative_to(self.root).as_posix(),
                    f"phase start predecessors are invalid for {phase_id}",
                )
                continue
            if predecessors is not None and phase.get("depends_on") != predecessors:
                self.add_error(
                    self.policy_path.relative_to(self.root).as_posix(),
                    f"phase {phase_id} canonical predecessors differ from its start contract",
                )
            if phase.get("status") not in statuses:
                continue
            for relative in paths:
                path = self.path(relative)
                if path.is_symlink() or not path.is_file():
                    self.add_error(
                        relative,
                        f"phase {phase_id} status {phase.get('status')!r} requires a regular start-contract file",
                    )

    def _check_inventory_status_coupling(self) -> None:
        assert self.roadmap is not None
        inventory_policy = self.policy["r00_inventory"]
        relative = inventory_policy["json_path"]
        try:
            inventory = read_json(self.path(relative))
        except (OSError, ValueError, json.JSONDecodeError) as exc:
            self.add_error(relative, f"inventory status cannot be read: {exc}")
            return
        r00 = next(
            (
                phase
                for phase in self.roadmap.get("phases", [])
                if isinstance(phase, dict) and phase.get("id") == "R00"
            ),
            None,
        )
        if r00 is None:
            return
        expected = inventory_policy["status_by_r00_phase_status"].get(r00.get("status"))
        if inventory.get("status") != expected:
            self.add_error(
                relative,
                "inventory status differs from R00 phase status: "
                f"expected {expected!r}, found {inventory.get('status')!r}",
            )

    def tracked_paths(self) -> list[str]:
        if self._tracked_paths_cache is not None:
            return self._tracked_paths_cache
        completed = subprocess.run(
            ["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"],
            cwd=self.root,
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
        )
        if completed.returncode == 0 and completed.stdout:
            paths = [
                value.decode("utf-8")
                for value in completed.stdout.split(b"\0")
                if value
            ]
        else:
            excluded = {".git", ".build", ".swiftpm", "build", "DerivedData"}
            paths = []
            for path in self.root.rglob("*"):
                if not path.is_file() and not path.is_symlink():
                    continue
                relative_parts = path.relative_to(self.root).parts
                if any(part in excluded for part in relative_parts):
                    continue
                paths.append(path.relative_to(self.root).as_posix())
        self._tracked_paths_cache = sorted(paths)
        return self._tracked_paths_cache

    def _check_forbidden_tracked_paths(self) -> None:
        patterns = [
            re.compile(pattern)
            for pattern in self.policy["forsetti"]["forbidden_tracked_path_patterns"]
        ]
        for relative in self.tracked_paths():
            for pattern in patterns:
                if pattern.search(relative):
                    self.add_error(relative, "tracked Forsetti repository/framework path is forbidden")
                    break
            path = self.path(relative)
            if path.is_symlink() and "forsetti" in os.readlink(path).lower():
                self.add_error(relative, "symlink to a Forsetti path is forbidden")

    def _check_forsetti_boundary(self) -> None:
        assert self.roadmap is not None
        forsetti = self.policy["forsetti"]
        phase_id = forsetti["phase_id"]
        phases = self.roadmap.get("phases", [])
        phase = next(
            (item for item in phases if isinstance(item, dict) and item.get("id") == phase_id),
            None,
        )
        if phase is None:
            self.add_error(
                self.policy["canonical"]["json_path"],
                f"Forsetti migration phase {phase_id} is missing",
            )
            return
        status = phase.get("status")
        mode = forsetti["mode_by_phase_status"].get(status)
        if mode is None:
            self.add_error(
                self.policy_path.relative_to(self.root).as_posix(),
                f"no Forsetti enforcement mode exists for R00 status {status!r}",
            )
            return
        missing_declarations = [
            relative
            for relative in (
                forsetti["project_path"],
                forsetti["generated_project_path"],
            )
            if not self.path(relative).is_file()
        ]
        if missing_declarations:
            for relative in missing_declarations:
                self.add_error(relative, "authoritative project declaration is missing")
            return
        legacy_errors = self._legacy_forsetti_errors()
        reference_errors = self._reference_only_forsetti_errors()
        if mode == "legacy_exact":
            for relative, message in legacy_errors:
                self.add_error(relative, message)
        elif mode == "reference_only":
            for relative, message in reference_errors:
                self.add_error(relative, message)
        elif mode == "legacy_or_absent":
            if legacy_errors and reference_errors:
                detail = legacy_errors[0][1]
                self.add_error(
                    forsetti["project_path"],
                    "R00 migration is neither the exact legacy pin nor complete "
                    f"dependency removal: {detail}",
                )
        else:
            self.add_error(
                self.policy_path.relative_to(self.root).as_posix(),
                f"unsupported Forsetti enforcement mode {mode!r}",
            )

    def _legacy_forsetti_errors(self) -> list[tuple[str, str]]:
        forsetti = self.policy["forsetti"]
        project_relative = forsetti["project_path"]
        generated_relative = forsetti["generated_project_path"]
        project = self.path(project_relative)
        generated = self.path(generated_relative)
        errors: list[tuple[str, str]] = []
        if not project.is_file():
            errors.append((project_relative, "legacy Forsetti project declaration is missing"))
            return errors
        if not generated.is_file():
            errors.append((generated_relative, "generated Forsetti declaration is missing"))
            return errors
        project_text = project.read_text(encoding="utf-8")
        generated_text = generated.read_text(encoding="utf-8")
        url = forsetti["allowed_dependency_url"]
        revision = forsetti["allowed_revision"]
        products = sorted(forsetti["allowed_products"])

        if project_text.count(url) != 1:
            errors.append((project_relative, "exact legacy Forsetti URL must occur once"))
        if project_text.count(revision) != 1:
            errors.append((project_relative, "exact legacy Forsetti revision must occur once"))
        if len(revision) != 40 or not re.fullmatch(r"[0-9a-f]{40}", revision):
            errors.append((project_relative, "policy Forsetti revision is not a 40-hex commit"))
        project_urls = sorted(
            value
            for value in re.findall(r"https?://[^\s\"';]+", project_text)
            if "forsetti" in value.lower()
        )
        if project_urls != [url]:
            errors.append((project_relative, "additional or alternate Forsetti URL is present"))
        project_products = sorted(
            re.findall(r"(?m)^\s*-?\s*product:\s*(Forsetti[A-Za-z0-9_]+)\s*$", project_text)
        )
        if project_products != products:
            errors.append(
                (project_relative, f"legacy Forsetti products must be exactly {products!r}")
            )
        if len(re.findall(r"(?m)^\s*ForsettiFramework:\s*$", project_text)) != 1:
            errors.append((project_relative, "ForsettiFramework package declaration is not exact"))
        if len(re.findall(r"(?m)^\s*-\s*package:\s*ForsettiFramework\s*$", project_text)) != len(products):
            errors.append((project_relative, "Forsetti package references are not exact"))

        if generated_text.count(url) != 1:
            errors.append((generated_relative, "generated legacy Forsetti URL must occur once"))
        if generated_text.count(revision) != 1:
            errors.append((generated_relative, "generated legacy Forsetti revision must occur once"))
        generated_urls = sorted(
            value
            for value in re.findall(r"https?://[^\s\"';]+", generated_text)
            if "forsetti" in value.lower()
        )
        if generated_urls != [url]:
            errors.append((generated_relative, "generated project has an alternate Forsetti URL"))
        generated_products = sorted(
            re.findall(r"productName\s*=\s*(Forsetti[A-Za-z0-9_]+);", generated_text)
        )
        if generated_products != products:
            errors.append(
                (generated_relative, f"generated Forsetti products must be exactly {products!r}")
            )

        for relative in self._dependency_manifest_paths():
            if relative in {project_relative, generated_relative}:
                continue
            text = self.path(relative).read_text(encoding="utf-8", errors="ignore")
            if "forsetti-framework-mac-ios" in text.lower():
                errors.append((relative, "additional Forsetti dependency declaration is forbidden"))
        return errors

    def _dependency_manifest_paths(self) -> list[str]:
        manifests: list[str] = []
        for relative in self.tracked_paths():
            name = Path(relative).name
            if (
                name in {"Package.swift", "Package.resolved", ".gitmodules", "project.yml"}
                or relative.endswith(".pbxproj")
            ):
                manifests.append(relative)
        return manifests

    def _reference_only_forsetti_errors(self) -> list[tuple[str, str]]:
        forsetti = self.policy["forsetti"]
        project_relative = forsetti["project_path"]
        generated_relative = forsetti["generated_project_path"]
        products = forsetti["allowed_products"]
        errors: list[tuple[str, str]] = []
        for relative in (project_relative, generated_relative):
            path = self.path(relative)
            if not path.is_file():
                continue
            text = path.read_text(encoding="utf-8")
            forbidden_literals = [
                forsetti["allowed_dependency_url"],
                "ForsettiFramework",
                "Forsetti-Framework-Mac-iOS",
            ]
            forbidden_literals.extend(products)
            if any(value in text for value in forbidden_literals):
                errors.append(
                    (relative, "Forsetti repository package dependency remains after R00")
                )
            if any(
                "forsetti" in value.lower()
                for value in re.findall(r"https?://[^\s\"';]+", text)
            ):
                errors.append(
                    (relative, "Forsetti repository coordinate remains after R00")
                )
            if re.search(
                r"(?m)^\s*(?:-\s*)?(?:product:|productName\s*=)\s*Forsetti[A-Za-z0-9_]+",
                text,
            ):
                errors.append(
                    (relative, "Forsetti package product remains after R00")
                )

        for relative in self._dependency_manifest_paths():
            path = self.path(relative)
            try:
                text = path.read_text(encoding="utf-8")
            except (OSError, UnicodeDecodeError):
                continue
            lower = text.lower()
            forbidden_dependency_literals = {
                forsetti["allowed_dependency_url"].lower(),
                "forsettiframework",
                "forsetti-framework-mac-ios",
                *(product.lower() for product in products),
            }
            if any(value in lower for value in forbidden_dependency_literals):
                errors.append(
                    (relative, "Forsetti dependency declaration remains after R00")
                )
            if any(
                "forsetti" in value.lower()
                for value in re.findall(r"https?://[^\s\"';,)]+", text)
            ):
                errors.append(
                    (relative, "Forsetti repository coordinate remains after R00")
                )

        import_pattern = re.compile(
            r"(?m)^\s*"
            r"(?:(?:@[_A-Za-z][A-Za-z0-9_]*(?:\([^\n)]*\))?)\s+)*"
            r"(?:(?:public|internal|package|fileprivate|private)\s+)?"
            r"import\s+"
            r"(?:(?:class|struct|enum|protocol|typealias|func|var|let)\s+)?"
            r"Forsetti[A-Za-z0-9_]*(?:\.[A-Za-z0-9_.]+)?\s*$"
        )
        for relative in self.tracked_paths():
            if not relative.endswith(".swift"):
                continue
            path = self.path(relative)
            try:
                text = path.read_text(encoding="utf-8")
            except (OSError, UnicodeDecodeError):
                continue
            if import_pattern.search(text):
                errors.append((relative, "Forsetti package import remains after R00"))
        active_path_patterns = [
            re.compile(pattern)
            for pattern in forsetti["forbidden_active_path_patterns"]
        ]
        for relative in self.tracked_paths():
            if any(pattern.search(relative) for pattern in active_path_patterns):
                errors.append(
                    (relative, "Forsetti-named active source or resource path remains after R00")
                )
        gitmodules = self.path(".gitmodules")
        if gitmodules.is_file() and "forsetti" in gitmodules.read_text(encoding="utf-8").lower():
            errors.append((".gitmodules", "Forsetti submodule remains after R00"))
        return errors

    def _check_workflows(self) -> None:
        workflow_policy = self.policy["workflows"]
        root_relative = workflow_policy["root"]
        workflow_root = self.path(root_relative)
        if not workflow_root.is_dir():
            self.add_error(root_relative, "workflow directory is missing")
            return
        command_patterns = [
            re.compile(re.escape(pattern), re.IGNORECASE)
            for pattern in workflow_policy["forbidden_command_patterns"]
        ]
        trigger_patterns = [
            re.compile(re.escape(pattern), re.IGNORECASE)
            for pattern in workflow_policy["forbidden_trigger_patterns"]
        ]
        for path in sorted(workflow_root.rglob("*")):
            if path.suffix not in {".yml", ".yaml"} or not path.is_file():
                continue
            relative = path.relative_to(self.root).as_posix()
            text = path.read_text(encoding="utf-8")
            for pattern in command_patterns:
                if pattern.search(text):
                    self.add_error(
                        relative,
                        f"forbidden legacy/release workflow command matches {pattern.pattern!r}",
                    )
            for pattern in trigger_patterns:
                if pattern.search(text):
                    self.add_error(
                        relative,
                        f"forbidden workflow trigger matches {pattern.pattern!r}",
                    )
        deterministic_relative = workflow_policy["deterministic_required_path"]
        deterministic_path = self.path(deterministic_relative)
        if deterministic_path.is_file():
            deterministic_text = deterministic_path.read_text(encoding="utf-8")
            for value in workflow_policy["deterministic_forbidden_patterns"]:
                if value.lower() in deterministic_text.lower():
                    self.add_error(
                        deterministic_relative,
                        f"deterministic required workflow contains network metadata command {value!r}",
                    )

    @staticmethod
    def _replace_between_markers(
        text: str, start: str, end: str, body: str
    ) -> str:
        if text.count(start) != 1 or text.count(end) != 1:
            raise ValueError("README markers must each occur exactly once")
        start_index = text.index(start) + len(start)
        end_index = text.index(end)
        if start_index >= end_index:
            raise ValueError("README markers are out of order")
        return text[:start_index] + body + text[end_index:]

    def write_progress(self) -> None:
        canonical = self.policy["canonical"]
        roadmap = read_json(self.path(canonical["json_path"]))
        readme_policy = self.policy["readme"]
        readme_path = self.path(readme_policy["path"])
        text = readme_path.read_text(encoding="utf-8")
        start = readme_policy["progress_start_marker"]
        end = readme_policy["progress_end_marker"]
        body = "\n" + render_progress(roadmap, self.policy) + "\n"
        updated = self._replace_between_markers(text, start, end, body)
        readme_path.write_text(updated, encoding="utf-8")

    def write_readme(self) -> None:
        canonical = self.policy["canonical"]
        roadmap = read_json(self.path(canonical["json_path"]))
        markdown = self.path(canonical["markdown_path"]).read_text(encoding="utf-8")
        readme_policy = self.policy["readme"]
        readme_path = self.path(readme_policy["path"])
        text = readme_path.read_text(encoding="utf-8")
        canonical_body = "\n" + markdown.replace("  \n", "<br>\n")
        text = self._replace_between_markers(
            text,
            readme_policy["canonical_start_marker"],
            readme_policy["canonical_end_marker"],
            canonical_body,
        )
        progress_body = "\n" + render_progress(roadmap, self.policy) + "\n"
        text = self._replace_between_markers(
            text,
            readme_policy["progress_start_marker"],
            readme_policy["progress_end_marker"],
            progress_body,
        )
        readme_path.write_text(text, encoding="utf-8")


def fetch_github_metadata(
    expected: dict[str, Any], attempts: int = 1
) -> dict[str, Any]:
    repository = expected["name_with_owner"]
    configured_repository = os.environ.get("GITHUB_REPOSITORY")
    if configured_repository and configured_repository != repository:
        raise ValueError(
            f"GITHUB_REPOSITORY is {configured_repository!r}, expected {repository!r}"
        )
    headers = {
        "Accept": "application/vnd.github+json",
        "User-Agent": "mirmir-roadmap-alignment",
        "X-GitHub-Api-Version": "2022-11-28",
    }
    token = os.environ.get("GITHUB_TOKEN")
    if token:
        headers["Authorization"] = f"Bearer {token}"
    if attempts < 1 or attempts > 5:
        raise ValueError("metadata attempts must be between 1 and 5")
    payload: Any = None
    for attempt in range(1, attempts + 1):
        request = urlrequest.Request(
            f"https://api.github.com/repos/{repository}",
            headers=headers,
        )
        try:
            with urlrequest.urlopen(request, timeout=30) as response:
                payload = json.load(response)
            break
        except urlerror.HTTPError as exc:
            if exc.code not in {429, 500, 502, 503, 504} or attempt == attempts:
                raise
        except (urlerror.URLError, TimeoutError):
            if attempt == attempts:
                raise
        time.sleep(min(2 ** (attempt - 1), 4))
    if not isinstance(payload, dict):
        raise ValueError("GitHub repository response is not an object")
    return payload


def repository_root_from_script() -> Path:
    return Path(__file__).resolve().parent.parent


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    operation = parser.add_mutually_exclusive_group()
    operation.add_argument("--check", action="store_true", help="verify local alignment")
    operation.add_argument(
        "--write-progress",
        action="store_true",
        help="regenerate only the README Roadmap Progress block",
    )
    operation.add_argument(
        "--write-readme",
        action="store_true",
        help="regenerate the README canonical roadmap and progress blocks",
    )
    operation.add_argument(
        "--check-github-metadata",
        action="store_true",
        help="compare live repository description and topics with policy",
    )
    parser.add_argument("--root", type=Path, default=repository_root_from_script())
    parser.add_argument("--policy", type=Path, default=DEFAULT_POLICY_PATH)
    parser.add_argument(
        "--metadata-attempts",
        type=int,
        default=1,
        help="bounded attempts for the live metadata audit (1-5)",
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    try:
        verifier = AlignmentVerifier(args.root, args.policy)
        if args.write_progress:
            verifier.write_progress()
            print("Roadmap Progress updated from canonical JSON.")
            return 0
        if args.write_readme:
            verifier.write_readme()
            print("README roadmap blocks updated from canonical sources.")
            return 0
        if args.check_github_metadata:
            expected = verifier.policy["github_repository"]
            payload = fetch_github_metadata(expected, attempts=args.metadata_attempts)
            errors = compare_github_metadata(payload, expected)
        else:
            errors = verifier.check()
    except (OSError, ValueError, KeyError, json.JSONDecodeError, urlerror.URLError) as exc:
        print(f"roadmap alignment configuration error: {exc}", file=sys.stderr)
        return 2

    if errors:
        for message in errors:
            print(f"roadmap alignment error: {message}", file=sys.stderr)
        return 1
    if args.check_github_metadata:
        print("GitHub repository metadata alignment: PASS")
    else:
        print("Roadmap alignment: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
