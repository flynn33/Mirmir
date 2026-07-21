#!/usr/bin/env python3
"""Create and verify the R01 operator-waived observation matrix.

This path records that hardware and simulator observations were not required by
the operator.  It never promotes an unobserved capability to runnable, eligible,
measured, product-qualified, or backend-qualified.
"""

from __future__ import annotations

import argparse
from datetime import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
from typing import Any

from phase_evidence import decode_json, validate_json_schema_instance
from r01_preregistration import (
    ANCHOR_CONTRACTS,
    FIXTURE_CATALOG_PATH,
    PREREGISTRATION_PATH,
    ROADMAP_PATH,
    build_capabilities,
)


REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
SCHEMA_PATH = Path(
    "docs/roadmaps/evidence/schema/r01-observation-waiver-v1.json"
)
OUTPUT_JSON_PATH = Path("project-notes/apple-upscale-capabilities.json")
OUTPUT_MARKDOWN_PATH = Path("project-notes/apple-upscale-capability-report.md")
SCHEMA_VERSION = "1.0"
ROADMAP_VERSION = "1.0.1"
PHASE_ID = "R01"
EVIDENCE_KIND = "operator_observation_waiver"
OBSERVATION_REQUIREMENT = "waived_not_a_blocker"
UNOBSERVED_REASON = "operator_gate_waiver"
QUALIFICATION_VALUE = "not_evaluated_in_r01"
ANCHORS = tuple(value[0] for value in ANCHOR_CONTRACTS)
GIT_OBJECT_PATTERN = re.compile(r"^(?!0{40}$)[0-9a-f]{40}$")
RFC3339_PATTERN = re.compile(
    r"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}"
    r"(?:\.[0-9]+)?(?:Z|[+-][0-9]{2}:[0-9]{2})$"
)
MAX_EVIDENCE_FILE_BYTES = 25 * 1024 * 1024
REQUIRED_SOURCE_PATHS = (
    Path("Scripts/phase_evidence.py"),
    Path("Scripts/r01_observation_waiver.py"),
    Path("Scripts/r01_preregistration.py"),
    SCHEMA_PATH,
    ROADMAP_PATH,
    Path("MirmirTests/AppleUpscaleCapabilityProbeTests.swift"),
)


def canonical_json_bytes(value: object) -> bytes:
    return (
        json.dumps(
            value,
            allow_nan=False,
            ensure_ascii=False,
            indent=2,
            sort_keys=True,
        ).encode("utf-8")
        + b"\n"
    )


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def read_json(path: Path) -> dict[str, Any]:
    value = decode_json(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError(f"{path}: top-level JSON value must be an object")
    return value


def git_bytes(root: Path, *arguments: str) -> subprocess.CompletedProcess[bytes]:
    return subprocess.run(
        ("git", *arguments),
        cwd=root,
        check=False,
        capture_output=True,
    )


def source_tree(root: Path, commit: str) -> str:
    if GIT_OBJECT_PATTERN.fullmatch(commit) is None:
        raise ValueError("source commit must be a nonzero 40-character Git object ID")
    result = git_bytes(root, "rev-parse", f"{commit}^{{tree}}")
    tree = result.stdout.decode("ascii", errors="replace").strip()
    if result.returncode != 0 or GIT_OBJECT_PATTERN.fullmatch(tree) is None:
        raise ValueError(f"source commit {commit} is unavailable")
    return tree


def validate_generation_source(root: Path, commit: str) -> list[str]:
    errors: list[str] = []
    head = git_bytes(root, "rev-parse", "HEAD")
    observed_head = head.stdout.decode("ascii", errors="replace").strip()
    if head.returncode != 0 or observed_head != commit:
        errors.append("waiver generation source_commit must equal clean repository HEAD")
    status = git_bytes(root, "status", "--porcelain", "--untracked-files=all")
    if status.returncode != 0 or status.stdout:
        errors.append("waiver generation requires a completely clean working tree")
    return errors


def validate_source(root: Path, commit: object, tree: object) -> list[str]:
    errors: list[str] = []
    if not isinstance(commit, str) or GIT_OBJECT_PATTERN.fullmatch(commit) is None:
        return ["source_commit must be a nonzero 40-character Git object ID"]
    if not isinstance(tree, str) or GIT_OBJECT_PATTERN.fullmatch(tree) is None:
        return ["source_tree must be a nonzero 40-character Git object ID"]
    try:
        expected_tree = source_tree(root, commit)
    except ValueError as error:
        return [str(error)]
    if tree != expected_tree:
        errors.append("source_tree does not match source_commit^{tree}")
    for relative in REQUIRED_SOURCE_PATHS:
        result = git_bytes(root, "cat-file", "-e", f"{commit}:{relative.as_posix()}")
        if result.returncode != 0:
            errors.append(
                f"required waiver source is absent at source_commit: {relative.as_posix()}"
            )
    return errors


def source_binding(root: Path, commit: str, relative: Path) -> dict[str, object]:
    result = git_bytes(root, "show", f"{commit}:{relative.as_posix()}")
    if result.returncode != 0:
        raise ValueError(
            f"required bound source is absent at source_commit: {relative.as_posix()}"
        )
    return {
        "path": relative.as_posix(),
        "size_bytes": len(result.stdout),
        "sha256": sha256_bytes(result.stdout),
    }


def source_json(root: Path, commit: str, relative: Path) -> dict[str, Any]:
    result = git_bytes(root, "show", f"{commit}:{relative.as_posix()}")
    if result.returncode != 0:
        raise ValueError(
            f"required bound source is absent at source_commit: {relative.as_posix()}"
        )
    try:
        value = decode_json(result.stdout.decode("utf-8"))
    except (UnicodeError, ValueError) as error:
        raise ValueError(
            f"bound source is not closed UTF-8 JSON: {relative.as_posix()}"
        ) from error
    if not isinstance(value, dict):
        raise ValueError(f"bound source must be a JSON object: {relative.as_posix()}")
    return value


def validate_unassigned_inputs(root: Path, commit: str) -> list[str]:
    errors: list[str] = []
    try:
        preregistration = source_json(root, commit, PREREGISTRATION_PATH)
        catalog = source_json(root, commit, FIXTURE_CATALOG_PATH)
    except ValueError as error:
        return [str(error)]
    if preregistration.get("preregistration_state") != (
        "offline_contract_frozen_live_blocked"
    ):
        errors.append("not-observed closure requires the original offline preregistration state")
    assignments = preregistration.get("anchor_assignments")
    if not isinstance(assignments, list) or len(assignments) != len(ANCHORS):
        errors.append("not-observed closure requires exactly four unassigned anchors")
    else:
        observed_anchors: list[object] = []
        for assignment in assignments:
            if not isinstance(assignment, dict):
                errors.append("not-observed anchor assignments must be objects")
                continue
            observed_anchors.append(assignment.get("anchor"))
            if assignment.get("assignment_state") != "unassigned":
                errors.append("not-observed anchor assignment must remain unassigned")
            if assignment.get("host_profile") is not None:
                errors.append("not-observed anchor assignment must not contain a host profile")
        if observed_anchors != list(ANCHORS):
            errors.append("not-observed anchor assignment order differs")
    fixtures = catalog.get("fixtures")
    model = None
    if isinstance(fixtures, list):
        model = next(
            (
                item
                for item in fixtures
                if isinstance(item, dict)
                and item.get("id") == "analysis-probe-model"
            ),
            None,
        )
    if not isinstance(model, dict) or model.get("status") != "unassigned":
        errors.append("not-observed closure requires an unassigned analysis probe model")
    elif any(
        model.get(key) is not None
        for key in (
            "materialization_path",
            "byte_count",
            "content_sha256",
            "model_identity",
        )
    ):
        errors.append("not-observed model identity, hash, path, and size must remain null")
    return errors


def parse_timestamp(value: object) -> bool:
    if not isinstance(value, str) or RFC3339_PATTERN.fullmatch(value) is None:
        return False
    try:
        datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return False
    return True


def expected_anchor_record(anchor: str, contract: str) -> dict[str, str]:
    return {
        "anchor": anchor,
        "hardware_observation": "not_observed",
        "simulator_observation": "not_observed",
        "target_contract": contract,
    }


def expected_capability_record(anchor: str) -> dict[str, str]:
    return {
        "anchor": anchor,
        "backend_eligibility": QUALIFICATION_VALUE,
        "compile_state": "not_observed",
        "hardware_eligibility": "not_observed",
        "measurement_status": "not_measured",
        "model_readiness": "not_observed",
        "observation_status": "not_observed",
        "performance_claims": "forbidden",
        "product_qualification": QUALIFICATION_VALUE,
        "public_api_status": "not_observed",
        "quality_evaluation": QUALIFICATION_VALUE,
        "reason_code": UNOBSERVED_REASON,
        "runtime_disposition": "diagnostic_only",
        "support_query": "not_observed",
    }


def build_matrix(
    root: Path,
    source_commit: str,
    generated_at: str,
) -> dict[str, Any]:
    root = root.resolve()
    tree = source_tree(root, source_commit)
    if not parse_timestamp(generated_at):
        raise ValueError("generated_at must be an RFC 3339 timestamp")
    roadmap = source_json(root, source_commit, ROADMAP_PATH)
    if roadmap.get("roadmap_version") != ROADMAP_VERSION:
        raise ValueError("canonical roadmap version differs from R01 waiver policy")
    capabilities = build_capabilities(roadmap)
    anchor_records = [
        expected_anchor_record(anchor, contract)
        for anchor, contract, _ in ANCHOR_CONTRACTS
    ]
    capability_records = []
    for capability in capabilities:
        capability_records.append(
            {
                **capability,
                "anchor_records": [
                    expected_capability_record(anchor) for anchor in ANCHORS
                ],
            }
        )
    return {
        "schema_version": SCHEMA_VERSION,
        "roadmap_version": ROADMAP_VERSION,
        "phase_id": PHASE_ID,
        "evidence_kind": EVIDENCE_KIND,
        "observation_requirement": OBSERVATION_REQUIREMENT,
        "source_commit": source_commit,
        "source_tree": tree,
        "generated_at": generated_at,
        "observation_policy": {
            "hardware_required": False,
            "observed_operation_required": False,
            "performance_claims": "forbidden",
            "simulator_required": False,
        },
        "preregistration_binding": source_binding(
            root, source_commit, PREREGISTRATION_PATH
        ),
        "fixture_catalog_binding": source_binding(
            root, source_commit, FIXTURE_CATALOG_PATH
        ),
        "model_observation": {
            "identity": None,
            "sha256": None,
            "status": "not_observed",
        },
        "anchors": anchor_records,
        "capabilities": capability_records,
        "limitations": [
            "Physical-hardware execution was not required by explicit operator override.",
            "Simulator availability and simulator execution were not required by explicit operator override.",
            "No compile, runtime, support, hardware, performance, memory, repeatability, product-qualification, backend-eligibility, or perceptual-quality result is inferred from an unobserved record.",
        ],
    }


def semantic_errors(root: Path, matrix: dict[str, Any]) -> list[str]:
    errors: list[str] = []
    expected_keys = {
        "anchors",
        "capabilities",
        "evidence_kind",
        "generated_at",
        "limitations",
        "fixture_catalog_binding",
        "observation_requirement",
        "observation_policy",
        "model_observation",
        "phase_id",
        "preregistration_binding",
        "roadmap_version",
        "schema_version",
        "source_commit",
        "source_tree",
    }
    if set(matrix) != expected_keys:
        errors.append("matrix fields differ from the closed waiver contract")
        return errors
    for key, expected in (
        ("schema_version", SCHEMA_VERSION),
        ("roadmap_version", ROADMAP_VERSION),
        ("phase_id", PHASE_ID),
        ("evidence_kind", EVIDENCE_KIND),
        ("observation_requirement", OBSERVATION_REQUIREMENT),
    ):
        if matrix.get(key) != expected:
            errors.append(f"{key} differs from the closed waiver contract")
    if not parse_timestamp(matrix.get("generated_at")):
        errors.append("generated_at must be an RFC 3339 timestamp")
    errors.extend(validate_source(root, matrix.get("source_commit"), matrix.get("source_tree")))
    try:
        commit = matrix.get("source_commit")
        if not isinstance(commit, str) or GIT_OBJECT_PATTERN.fullmatch(commit) is None:
            raise ValueError("source_commit must be a nonzero 40-character Git object ID")
        roadmap = source_json(root, commit, ROADMAP_PATH)
        expected_capabilities = build_capabilities(roadmap)
    except (OSError, ValueError, json.JSONDecodeError) as error:
        errors.append(str(error))
        return sorted(set(errors))
    expected_anchors = [
        expected_anchor_record(anchor, contract)
        for anchor, contract, _ in ANCHOR_CONTRACTS
    ]
    if matrix.get("anchors") != expected_anchors:
        errors.append("anchors differ from the four closed unobserved contracts")
    expected_policy = {
        "hardware_required": False,
        "observed_operation_required": False,
        "performance_claims": "forbidden",
        "simulator_required": False,
    }
    if matrix.get("observation_policy") != expected_policy:
        errors.append("observation_policy differs from the operator waiver")
    if matrix.get("model_observation") != {
        "identity": None,
        "sha256": None,
        "status": "not_observed",
    }:
        errors.append("model_observation must remain explicitly unobserved")
    commit = matrix.get("source_commit")
    if isinstance(commit, str) and GIT_OBJECT_PATTERN.fullmatch(commit):
        errors.extend(validate_unassigned_inputs(root, commit))
        for key, relative in (
            ("preregistration_binding", PREREGISTRATION_PATH),
            ("fixture_catalog_binding", FIXTURE_CATALOG_PATH),
        ):
            try:
                expected_binding = source_binding(root, commit, relative)
            except ValueError as error:
                errors.append(str(error))
            else:
                if matrix.get(key) != expected_binding:
                    errors.append(f"{key} differs from source_commit bytes")
    capabilities = matrix.get("capabilities")
    if not isinstance(capabilities, list) or len(capabilities) != len(expected_capabilities):
        errors.append("capabilities must contain exactly A01-A18")
    else:
        for index, expected in enumerate(expected_capabilities):
            record = capabilities[index]
            if not isinstance(record, dict):
                errors.append(f"capabilities[{index}] must be an object")
                continue
            identity = {key: record.get(key) for key in expected}
            if identity != expected:
                errors.append(f"capabilities[{index}] identity differs from the roadmap")
            expected_records = [
                expected_capability_record(anchor) for anchor in ANCHORS
            ]
            if record.get("anchor_records") != expected_records:
                errors.append(
                    f"capabilities[{index}].anchor_records must remain entirely unobserved"
                )
            if set(record) != {*expected, "anchor_records"}:
                errors.append(f"capabilities[{index}] fields differ from the closed contract")
    expected_limitations = build_matrix(
        root,
        str(matrix.get("source_commit")),
        str(matrix.get("generated_at")),
    )["limitations"] if not errors else None
    if expected_limitations is not None and matrix.get("limitations") != expected_limitations:
        errors.append("limitations differ from the closed operator-override statement")
    forbidden_keys = {
        "acquisition_seconds",
        "elapsed_seconds",
        "frame_rate",
        "inference_seconds",
        "initialization_seconds",
        "load_seconds",
        "measurements",
        "memory_bytes",
        "metrics",
        "p95_wall_seconds",
        "peak_resident_memory_delta_bytes",
        "sessions",
        "specialization_seconds",
        "throughput_units_per_second",
    }

    def reject_performance(value: object, context: str) -> None:
        if isinstance(value, dict):
            for key, item in value.items():
                if key in forbidden_keys:
                    errors.append(f"{context}.{key} is forbidden in not-observed evidence")
                reject_performance(item, f"{context}.{key}")
        elif isinstance(value, list):
            for index, item in enumerate(value):
                reject_performance(item, f"{context}[{index}]")

    reject_performance(matrix, "matrix")
    return sorted(set(errors))


def markdown_cell(value: object) -> str:
    return str(value).replace("|", "\\|").replace("\n", " ")


def render_markdown(matrix: dict[str, Any]) -> str:
    lines = [
        "# Apple Upscale Capability Report",
        "",
        f"- **Schema version:** `{matrix['schema_version']}`",
        f"- **Roadmap version:** `{matrix['roadmap_version']}`",
        f"- **Phase:** `{matrix['phase_id']}`",
        f"- **Evidence kind:** `{matrix['evidence_kind']}`",
        f"- **Observation requirement:** `{matrix['observation_requirement']}`",
        f"- **Source commit:** `{matrix['source_commit']}`",
        f"- **Source tree:** `{matrix['source_tree']}`",
        f"- **Generated at:** `{matrix['generated_at']}`",
        "",
        "Physical-hardware execution, simulator availability, simulator execution, and operator-observed execution were waived as blockers by explicit operator direction. Every capability below therefore remains diagnostic-only and unobserved.",
        "",
        "The preregistration and fixture-catalog bindings preserve the original unassigned host/model state; no model identity or digest was synthesized.",
        "",
        "## Anchor Observation Status",
        "",
        "| Anchor | Target contract | Hardware | Simulator |",
        "| --- | --- | --- | --- |",
    ]
    for anchor in matrix["anchors"]:
        lines.append(
            f"| `{markdown_cell(anchor['anchor'])}` | "
            f"{markdown_cell(anchor['target_contract'])} | "
            f"`{anchor['hardware_observation']}` | "
            f"`{anchor['simulator_observation']}` |"
        )
    lines.extend(
        [
            "",
            "## Capability Matrix",
            "",
            "| ID | Family / method | Probe class | Anchor | Compile | Runtime | Reason | Measurements |",
            "| --- | --- | --- | --- | --- | --- | --- | --- |",
        ]
    )
    for capability in matrix["capabilities"]:
        for record in capability["anchor_records"]:
            lines.append(
                f"| `{capability['id']}` | "
                f"{markdown_cell(capability['family'])} / {markdown_cell(capability['method'])} | "
                f"`{capability['probe_class']}` | `{record['anchor']}` | "
                f"`{record['compile_state']}` | `{record['runtime_disposition']}` | "
                f"`{record['reason_code']}` | `{record['measurement_status']}` |"
            )
    lines.extend(["", "## Limitations", ""])
    lines.extend(f"- {value}" for value in matrix["limitations"])
    lines.append("")
    return "\n".join(lines)


def validate_outputs(root: Path) -> list[str]:
    root = root.resolve()
    errors: list[str] = []
    try:
        schema = read_json(root / SCHEMA_PATH)
        matrix = read_json(root / OUTPUT_JSON_PATH)
    except (OSError, ValueError, json.JSONDecodeError) as error:
        return [str(error)]
    errors.extend(validate_json_schema_instance(schema, matrix))
    errors.extend(semantic_errors(root, matrix))
    try:
        json_payload = (root / OUTPUT_JSON_PATH).read_bytes()
    except OSError as error:
        errors.append(str(error))
    else:
        if json_payload != canonical_json_bytes(matrix):
            errors.append("capability matrix is not canonical deterministic JSON")
        if len(json_payload) > MAX_EVIDENCE_FILE_BYTES:
            errors.append("capability matrix exceeds the evidence-file limit")
    expected_markdown = render_markdown(matrix).encode("utf-8")
    try:
        observed_markdown = (root / OUTPUT_MARKDOWN_PATH).read_bytes()
    except OSError as error:
        errors.append(str(error))
    else:
        if observed_markdown != expected_markdown:
            errors.append("capability report differs from deterministic output")
        if len(observed_markdown) > MAX_EVIDENCE_FILE_BYTES:
            errors.append("capability report exceeds the evidence-file limit")
    return sorted(set(errors))


def atomic_write(path: Path, payload: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.is_symlink():
        raise OSError(f"refusing to replace symbolic link: {path}")
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{path.name}.", suffix=".tmp", dir=path.parent
    )
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "wb") as destination:
            destination.write(payload)
            destination.flush()
            os.fsync(destination.fileno())
        os.replace(temporary, path)
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    action = parser.add_mutually_exclusive_group(required=True)
    action.add_argument("--write", action="store_true")
    action.add_argument("--check", action="store_true")
    parser.add_argument("--root", type=Path, default=REPOSITORY_ROOT)
    parser.add_argument("--source-commit")
    parser.add_argument("--generated-at")
    return parser


def main(argv: list[str] | None = None) -> int:
    arguments = build_parser().parse_args(argv)
    root = arguments.root.resolve()
    if arguments.check:
        if arguments.source_commit is not None or arguments.generated_at is not None:
            print("ERROR: --check does not accept generation arguments", file=sys.stderr)
            return 2
        errors = validate_outputs(root)
        if errors:
            for error in errors:
                print(f"ERROR: {error}", file=sys.stderr)
            return 1
        print("R01 observation-waiver capability matrix: PASS")
        return 0
    if arguments.source_commit is None or arguments.generated_at is None:
        print(
            "ERROR: --write requires --source-commit and --generated-at",
            file=sys.stderr,
        )
        return 2
    try:
        matrix = build_matrix(root, arguments.source_commit, arguments.generated_at)
        source_errors = validate_source(
            root, matrix["source_commit"], matrix["source_tree"]
        )
        if source_errors:
            raise ValueError("; ".join(source_errors))
        input_errors = validate_unassigned_inputs(root, matrix["source_commit"])
        if input_errors:
            raise ValueError("; ".join(input_errors))
        generation_errors = validate_generation_source(
            root, matrix["source_commit"]
        )
        if generation_errors:
            raise ValueError("; ".join(generation_errors))
        schema = read_json(root / SCHEMA_PATH)
        schema_errors = validate_json_schema_instance(schema, matrix)
        if schema_errors:
            raise ValueError("; ".join(schema_errors))
        semantic = semantic_errors(root, matrix)
        if semantic:
            raise ValueError("; ".join(semantic))
        atomic_write(root / OUTPUT_JSON_PATH, canonical_json_bytes(matrix))
        atomic_write(
            root / OUTPUT_MARKDOWN_PATH,
            render_markdown(matrix).encode("utf-8"),
        )
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    print(OUTPUT_JSON_PATH.as_posix())
    print(OUTPUT_MARKDOWN_PATH.as_posix())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
