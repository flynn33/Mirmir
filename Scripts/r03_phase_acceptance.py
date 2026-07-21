#!/usr/bin/env python3
"""Validate the operator-overridden R03 functional phase-acceptance record."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys
from typing import Any, Iterable

from phase_evidence import decode_json, validate_json_schema_instance
from r02_contracts import CONFORMANCE_PATH as R02_CONFORMANCE_PATH
from r02_contracts import R02ContractVerifier
from r03_product_qualification import (
    CHECK_IDS as QUALIFICATION_CHECK_IDS,
    DECISION_PATH as QUALIFICATION_DECISION_PATH,
    EXECUTION_RECEIPT_PATH as QUALIFICATION_RECEIPT_PATH,
    FUNCTIONAL_METRIC_IDS,
    METRIC_IDS,
    ROUTE_CONTRACTS,
    R03ProductQualificationVerifier,
)


REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
ACCEPTANCE_PATH = Path(
    "docs/roadmaps/evidence/r03/records/functional-phase-acceptance.json"
)
ACCEPTANCE_SCHEMA_PATH = Path(
    "docs/roadmaps/evidence/schema/r03-functional-phase-acceptance-v1.json"
)
SOURCE_COMMIT = "b5c19c0040f845b7f32fe98bd5f01249c1b071f2"
SOURCE_TREE = "74e39285521fe31f9588cff5e43184c8f91f9180"

EVIDENCE_PATHS = (
    ("r02_session_conformance", R02_CONFORMANCE_PATH),
    ("r03_v2_execution_receipt", QUALIFICATION_RECEIPT_PATH),
    ("r03_v2_qualification_decision", QUALIFICATION_DECISION_PATH),
)

OPERATOR_OVERRIDE = {
    "authority": "operator",
    "authorization_date": "2026-07-21",
    "acceptance_basis": "software_performs_intended_task",
    "override_id": "r03.software-function-phase-acceptance.v1",
    "hardware_simulator_operator_observation": "waived_not_a_blocker",
    "historical_evidence_policy": "preserve_r03_v1_and_v2_unchanged",
}

SUPERSEDED_GATE = {
    "gate": (
        "One baseline matrix establishes the quality/performance/resource "
        "envelope of every deterministic Apple path."
    ),
    "disposition": "superseded_for_r03_phase_acceptance",
    "retained_value": "optional_comparative_evidence",
}

FUNCTIONAL_GATE = {
    "backend_id": "r03.mps.lanczos",
    "capability_id": "A11",
    "framework": "MetalPerformanceShaders",
    "framework_symbol": "MPSImageLanczosScale",
    "qualification_scope": "functional_product_eligibility",
    "required_route_ids": [contract["id"] for contract in ROUTE_CONTRACTS],
    "repeat_count_per_route": 3,
    "required_media_contract": (
        "1920x1080_to_3840x2160_h264_aac_timing_metadata_reopen_atomic"
    ),
    "required_lifecycle_contract": "apple-upscale-session-v1",
    "fallback_policy": "none",
    "functional_metric_ids": [
        metric_id for metric_id in METRIC_IDS if metric_id in FUNCTIONAL_METRIC_IDS
    ],
}

DERIVED_CHECK_IDS = (
    "source_checkpoint_exact",
    "evidence_bindings_exact",
    "r02_common_session_conformance",
    "r03_v2_decision_valid",
    "genuine_mps_execution",
    "canonical_routes",
    "three_repeat_determinism",
    "media_transaction_preservation",
    "lifecycle_and_resource_lifetime",
    "identity_and_no_fallback",
    "functional_metrics",
    "truthful_observation_boundary",
)

RESULT = {
    "status": "passed",
    "phase_status_before": "in_progress",
    "phase_status_after": "passed",
    "acceptance": "accepted",
    "accepted_backend_id": "r03.mps.lanczos",
    "acceptance_scope": "functional_software_phase_acceptance",
}

AUTHORIZATIONS = {
    "phase_progression": "authorized",
    "product_qualification": "r03.mps.lanczos_A11_only",
    "production_default": "not_authorized",
    "auto_mode": "blocked",
    "holdout": "blocked",
    "perceptual_quality_claims": "not_authorized",
    "performance_claims": "not_authorized",
    "product_publication": "not_authorized",
    "release": "not_authorized",
}

LIMITATIONS = (
    "R03 phase acceptance is based only on the operator-authorized software "
    "function gate and the bound passing A11 evidence.",
    "The frozen v1 blocked evidence and narrower v2 qualification decision "
    "remain immutable historical records.",
    "This record does not select a production default or authorize Auto, "
    "holdout, perceptual-quality, performance, product-publication, or release claims.",
)


def _sha256(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


class R03PhaseAcceptanceVerifier:
    def __init__(self, root: Path) -> None:
        self.root = root.resolve()

    def git(self, *arguments: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["git", *arguments],
            cwd=self.root,
            check=False,
            capture_output=True,
            text=True,
        )

    def git_bytes(self, *arguments: str) -> subprocess.CompletedProcess[bytes]:
        return subprocess.run(
            ["git", *arguments],
            cwd=self.root,
            check=False,
            capture_output=True,
        )

    def _read_json(
        self, relative: Path, context: str, errors: list[str]
    ) -> dict[str, Any] | None:
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

    def _file_binding(self, identifier: str, relative: Path) -> dict[str, object]:
        payload = (self.root / relative).read_bytes()
        return {
            "id": identifier,
            "path": relative.as_posix(),
            "size_bytes": len(payload),
            "sha256": _sha256(payload),
        }

    def _source_errors(self) -> list[str]:
        errors: list[str] = []
        commit = self.git("cat-file", "-e", f"{SOURCE_COMMIT}^{{commit}}")
        if commit.returncode != 0:
            return ["R03 acceptance source commit is unavailable"]
        tree = self.git("rev-parse", f"{SOURCE_COMMIT}^{{tree}}")
        if tree.returncode != 0 or tree.stdout.strip() != SOURCE_TREE:
            errors.append("R03 acceptance source tree differs")
        ancestor = self.git("merge-base", "--is-ancestor", SOURCE_COMMIT, "HEAD")
        if ancestor.returncode != 0:
            errors.append("R03 acceptance source commit is not an ancestor of HEAD")
        for identifier, relative in EVIDENCE_PATHS:
            path = self.root / relative
            if path.is_symlink() or not path.is_file():
                errors.append(f"R03 acceptance evidence is absent: {identifier}")
                continue
            historical = self.git_bytes(
                "show", f"{SOURCE_COMMIT}:{relative.as_posix()}"
            )
            if historical.returncode != 0 or historical.stdout != path.read_bytes():
                errors.append(
                    f"R03 acceptance evidence differs from source: {identifier}"
                )
        return errors

    @staticmethod
    def _functional_evidence_errors(
        r02_conformance: dict[str, Any],
        decision: dict[str, Any],
        receipt: dict[str, Any],
    ) -> list[str]:
        errors: list[str] = []
        r02_result = r02_conformance.get("result")
        if not isinstance(r02_result, dict) or r02_result.get("status") != "passed":
            errors.append("R02 common-session software conformance did not pass")

        result = decision.get("result")
        expected_result = {
            "status": "passed",
            "product_qualification": "product_qualified",
            "product_qualified_backend_id": "r03.mps.lanczos",
            "qualification_scope": "functional_product_eligibility",
        }
        if not isinstance(result, dict) or any(
            result.get(key) != value for key, value in expected_result.items()
        ):
            errors.append("R03 v2 decision does not qualify A11 functional software")

        checks = decision.get("derived_checks")
        if not isinstance(checks, list) or checks != [
            {"id": check_id, "status": "passed"}
            for check_id in QUALIFICATION_CHECK_IDS
        ]:
            errors.append("R03 v2 derived checks are not all exactly passed")

        observation = receipt.get("observation_status")
        if not isinstance(observation, dict) or (
            observation.get("deterministic_software_execution") != "observed"
            or observation.get("genuine_mps_execution") != "observed"
        ):
            errors.append("genuine deterministic MPS software execution is absent")

        identity = receipt.get("processing_identity")
        if not isinstance(identity, dict) or (
            identity.get("backend_id") != "r03.mps.lanczos"
            or identity.get("capability_id") != "A11"
            or identity.get("framework") != "MetalPerformanceShaders"
            or identity.get("framework_symbol") != "MPSImageLanczosScale"
            or identity.get("fallback_history") != []
        ):
            errors.append("R03 A11 processing identity or fallback history differs")

        routes = receipt.get("route_results")
        if not isinstance(routes, list) or len(routes) != len(ROUTE_CONTRACTS):
            errors.append("R03 canonical route results are incomplete")
        else:
            for route, contract in zip(routes, ROUTE_CONTRACTS):
                runs = route.get("runs") if isinstance(route, dict) else None
                if (
                    not isinstance(route, dict)
                    or route.get("route_id") != contract["id"]
                    or route.get("input_dimensions") != contract["input_dimensions"]
                    or route.get("output_dimensions") != contract["output_dimensions"]
                    or not isinstance(runs, list)
                    or len(runs) != 3
                ):
                    errors.append(f"R03 route contract differs: {contract['id']}")
                    continue
                hashes = {
                    run.get("logical_output_sha256")
                    for run in runs
                    if isinstance(run, dict)
                }
                if len(hashes) != 1 or None in hashes:
                    errors.append(f"R03 route is not deterministic: {contract['id']}")
                for run in runs:
                    lifecycle = (
                        run.get("lifecycle_observation")
                        if isinstance(run, dict)
                        else None
                    )
                    if (
                        not isinstance(run, dict)
                        or run.get("fallback_history") != []
                        or not isinstance(lifecycle, dict)
                        or lifecycle.get("input_release_count") != 1
                        or lifecycle.get("output_release_count") != 1
                        or lifecycle.get("terminalization_count") != 1
                        or lifecycle.get("finish_idempotent") is not True
                        or lifecycle.get("cancel_idempotent") is not True
                    ):
                        errors.append(
                            f"R03 lifecycle or fallback contract differs: {contract['id']}"
                        )
                        break

        media = receipt.get("media_transaction_result")
        media_runs = media.get("runs") if isinstance(media, dict) else None
        if not isinstance(media_runs, list) or len(media_runs) != 3:
            errors.append("R03 media transaction repeats are incomplete")
        else:
            for run in media_runs:
                frames = run.get("frame_observations") if isinstance(run, dict) else None
                frame_records_valid = isinstance(frames, list) and all(
                    isinstance(frame, dict) for frame in frames
                )
                if (
                    not isinstance(run, dict)
                    or run.get("output_dimensions") != {"height": 2160, "width": 3840}
                    or run.get("video_codec") != "h264"
                    or run.get("audio_codec") != "aac"
                    or run.get("reopen_succeeded") is not True
                    or run.get("atomic_publication_succeeded") is not True
                    or run.get("fallback_history") != []
                    or not frame_records_valid
                    or [frame.get("sequence_number") for frame in frames] != [0, 1, 2]
                    or any(
                        frame.get("resource_release_count") != 1 for frame in frames
                    )
                ):
                    errors.append("R03 media preservation contract differs")
                    break

        evaluations = decision.get("metric_evaluations")
        evaluation_by_id = (
            {
                item.get("id"): item
                for item in evaluations
                if isinstance(item, dict)
            }
            if isinstance(evaluations, list)
            else {}
        )
        for metric_id in FUNCTIONAL_GATE["functional_metric_ids"]:
            metric = evaluation_by_id.get(metric_id)
            if not isinstance(metric, dict) or (
                metric.get("status") != "measured" or metric.get("passed") is not True
            ):
                errors.append(f"R03 functional metric did not pass: {metric_id}")
        return errors

    def expected_record(
        self, decision: dict[str, Any], receipt: dict[str, Any]
    ) -> dict[str, object]:
        return {
            "schema_version": "1.0.0",
            "roadmap_version": "1.0.1",
            "phase_id": "R03",
            "evidence_kind": "r03_operator_functional_phase_acceptance_v1",
            "source": {"commit": SOURCE_COMMIT, "tree": SOURCE_TREE},
            "operator_override": dict(OPERATOR_OVERRIDE),
            "superseded_gate": dict(SUPERSEDED_GATE),
            "functional_gate": dict(FUNCTIONAL_GATE),
            "evidence_bindings": [
                self._file_binding(identifier, relative)
                for identifier, relative in EVIDENCE_PATHS
            ],
            "qualification_source": dict(receipt["source"]),
            "derived_checks": [
                {"id": check_id, "status": "passed"}
                for check_id in DERIVED_CHECK_IDS
            ],
            "result": dict(RESULT),
            "authorizations": dict(AUTHORIZATIONS),
            "limitations": list(LIMITATIONS),
        }

    def _upstream(
        self, errors: list[str]
    ) -> tuple[dict[str, Any], dict[str, Any], dict[str, Any]] | None:
        errors.extend(R02ContractVerifier(self.root).check_conformance())
        errors.extend(R03ProductQualificationVerifier(self.root).check_decision())
        r02 = self._read_json(R02_CONFORMANCE_PATH, "R02 conformance", errors)
        decision = self._read_json(
            QUALIFICATION_DECISION_PATH, "R03 v2 qualification decision", errors
        )
        receipt = self._read_json(
            QUALIFICATION_RECEIPT_PATH, "R03 v2 execution receipt", errors
        )
        if r02 is None or decision is None or receipt is None:
            return None
        errors.extend(self._functional_evidence_errors(r02, decision, receipt))
        return r02, decision, receipt

    def check(self) -> list[str]:
        errors = self._source_errors()
        upstream = self._upstream(errors)
        record = self._read_json(ACCEPTANCE_PATH, "R03 phase acceptance", errors)
        schema = self._read_json(
            ACCEPTANCE_SCHEMA_PATH, "R03 phase acceptance schema", errors
        )
        if record is not None and schema is not None:
            errors.extend(
                f"R03 phase acceptance schema: {error}"
                for error in validate_json_schema_instance(schema, record)
            )
        if upstream is not None and record is not None and not errors:
            _, decision, receipt = upstream
            if record != self.expected_record(decision, receipt):
                errors.append(
                    "R03 phase acceptance is not exactly derived from bound software evidence"
                )
        return sorted(set(errors))

    def write(self) -> list[str]:
        errors = self._source_errors()
        upstream = self._upstream(errors)
        schema = self._read_json(
            ACCEPTANCE_SCHEMA_PATH, "R03 phase acceptance schema", errors
        )
        if upstream is None or schema is None or errors:
            return sorted(set(errors))
        _, decision, receipt = upstream
        record = self.expected_record(decision, receipt)
        errors.extend(
            f"R03 phase acceptance schema: {error}"
            for error in validate_json_schema_instance(schema, record)
        )
        if errors:
            return sorted(set(errors))
        path = self.root / ACCEPTANCE_PATH
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(
            json.dumps(record, indent=2, ensure_ascii=False) + "\n",
            encoding="utf-8",
        )
        return self.check()


def emit_errors(errors: Iterable[str]) -> int:
    observed = list(errors)
    if not observed:
        return 0
    for error in observed:
        print(f"ERROR: {error}", file=sys.stderr)
    return 1


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--check", action="store_true")
    group.add_argument("--write", action="store_true")
    arguments = parser.parse_args(argv)
    verifier = R03PhaseAcceptanceVerifier(REPOSITORY_ROOT)
    errors = verifier.write() if arguments.write else verifier.check()
    if not errors:
        print("R03 functional phase acceptance: PASS")
    return emit_errors(errors)


if __name__ == "__main__":
    raise SystemExit(main())
