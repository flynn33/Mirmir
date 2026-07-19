#!/usr/bin/env python3
"""Validate and render closed roadmap phase-evidence manifests."""

from __future__ import annotations

import argparse
from datetime import datetime
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys
from typing import Any, Iterable


SCHEMA_VERSION = "1.0"
SCHEMA_SHA256 = "3a80e0a653aae3224325659f7c218de6a1ec0ba053c7802b6c015f029e7c2f0d"
PHASE_IDS = tuple(f"R{index:02d}" for index in range(1, 14))
PHASE_CLOSURE_PREDECESSORS = {
    "R01": ("R00",),
    "R02": ("R01",),
    "R03": ("R02",),
    "R04": ("R03",),
    "R05": ("R04",),
    "R06": ("R04", "R05"),
    "R07": ("R06",),
    "R08": ("R07",),
    "R09": ("R08",),
    "R10": ("R08",),
    "R11": ("R10",),
    "R12": ("R11",),
    "R13": ("R11", "R12"),
}
MAX_EVIDENCE_FILE_BYTES = 25 * 1024 * 1024
MAX_PHASE_EVIDENCE_BYTES = 100 * 1024 * 1024
TOP_LEVEL_KEYS = (
    "schema_version",
    "roadmap_version",
    "phase_id",
    "source",
    "hosts",
    "preregistration",
    "commands",
    "outputs",
    "verification",
    "result",
    "authorizations",
    "limitations",
)
SOURCE_KEYS = ("commit", "tree")
HOST_KEYS = (
    "host_id",
    "roles",
    "hardware_classes",
    "model_identifier",
    "chip",
    "memory_bytes",
    "os_version",
    "os_build",
    "xcode_version",
    "xcode_build",
    "sdk_version",
    "source_commit",
)
PREREGISTRATION_KEYS = (
    "record",
    "inputs",
    "fixtures",
    "parameters",
    "metrics",
    "floors",
    "stop_rules",
    "disposition_subjects",
)
COMMAND_KEYS = (
    "command_id",
    "host_id",
    "argv",
    "environment_flags",
    "started_at",
    "ended_at",
    "exit_status",
    "result",
    "skip_reason",
    "consent_receipt",
)
OUTPUT_KEYS = (
    "id",
    "kind",
    "binding",
    "generated_summary",
    "redistributable",
    "contains_holdout_pixels",
    "system_asset",
)
VERIFICATION_KEYS = ("checks",)
VERIFICATION_CHECK_KEYS = (
    "id",
    "category",
    "required",
    "status",
    "command_ids",
    "output_ids",
    "reason",
)
VERIFICATION_ARTIFACT_KEYS = (
    "schema_version",
    "category",
    "command_ids",
    "status",
    "exit_status",
    "summary",
)
RESULT_KEYS = (
    "status",
    "disposition",
    "phase_status_before",
    "phase_status_after",
    "dispositions",
    "summary",
)
AUTHORIZATION_KEYS = ("before", "after", "proposed_decisions")
AUTHORIZATION_VALUE_KEYS = ("id", "value")
FILE_BINDING_KEYS = ("path", "size_bytes", "sha256")
INPUT_KEYS = ("id", "kind", "identity", "binding", "limitations")
FIXTURE_KEYS = ("id", "role", "binding", "redistributable")
PARAMETER_KEYS = ("id", "value", "unit")
METRIC_KEYS = ("id", "unit", "direction", "applicability")
FLOOR_KEYS = ("metric_id", "comparison", "value", "scope")
STATEMENT_KEYS = ("id", "description")
DISPOSITION_SUBJECT_KEYS = ("subject_id", "allowed_values")
RESULT_DISPOSITION_KEYS = ("subject_id", "value", "reason")
ENVIRONMENT_FLAG_KEYS = ("name", "value")
RESULT_STATUSES = ("passed", "diagnostic_only", "rejected", "blocked")
EXECUTION_STATUSES = ("passed", "failed", "skipped")
INPUT_KINDS = ("repository_fixture", "external_receipt", "system_asset")
METRIC_DIRECTIONS = (
    "higher_is_better",
    "lower_is_better",
    "observation_only",
)
FLOOR_COMPARISONS = (
    "equal",
    "greater_than",
    "greater_than_or_equal",
    "less_than",
    "less_than_or_equal",
    "not_applicable",
)
GIT_OBJECT_PATTERN = re.compile(r"^(?!0{40}$)[0-9a-f]{40}$")
SHA256_PATTERN = re.compile(r"^(?!0{64}$)[0-9a-f]{64}$")
IDENTIFIER_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
SEMVER_PATTERN = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+$")
RFC3339_PATTERN = re.compile(
    r"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}"
    r"(?:\.[0-9]+)?(?:Z|[+-][0-9]{2}:[0-9]{2})$"
)
PHASE_STATUS_VALUES = (
    "planned",
    "next",
    "in_progress",
    "evidence_ready",
    "passed",
    "blocked",
)
OUTPUT_KINDS = (
    "command_log",
    "host_record",
    "fixture",
    "report",
    "summary",
    "test_result",
    "build_result",
    "receipt",
    "supporting_record",
)
VERIFICATION_CATEGORIES = (
    "json",
    "lint",
    "unit_test",
    "mutation_test",
    "repository",
    "dependency_scan",
    "project_generation",
    "build",
    "hosted_test",
    "smoke_test",
    "runtime",
    "evidence_integrity",
)
VERIFICATION_CATEGORY_OUTPUT_KINDS = {
    "json": frozenset({"command_log"}),
    "lint": frozenset({"command_log"}),
    "unit_test": frozenset({"test_result"}),
    "mutation_test": frozenset({"test_result"}),
    "repository": frozenset({"command_log"}),
    "dependency_scan": frozenset({"command_log"}),
    "project_generation": frozenset({"command_log"}),
    "build": frozenset({"build_result"}),
    "hosted_test": frozenset({"test_result"}),
    "smoke_test": frozenset({"test_result"}),
    "runtime": frozenset({"test_result"}),
    "evidence_integrity": frozenset({"command_log"}),
}
HARDWARE_CLASSES = (
    "apple_silicon",
    "macbook_air",
    "pro_max_tier",
    "core_ai_capable",
)
COMMON_REQUIRED_VERIFICATION_CATEGORIES = frozenset(
    {
        "json",
        "lint",
        "unit_test",
        "mutation_test",
        "repository",
        "dependency_scan",
        "project_generation",
        "build",
        "hosted_test",
        "evidence_integrity",
    }
)
PHASE_OUTCOME_DISPOSITIONS = {
    "R01": {
        "passed": frozenset({"passed"}),
        "blocked": frozenset({"blocked"}),
    },
    "R02": {
        "passed": frozenset({"passed"}),
        "blocked": frozenset({"blocked"}),
    },
    "R03": {
        "passed": frozenset({"passed"}),
        "blocked": frozenset({"blocked"}),
    },
    "R04": {
        "passed": frozenset({"passed"}),
        "blocked": frozenset({"blocked"}),
    },
    "R05": {
        "passed": frozenset(
            {"qualified_spatial", "qualified_temporal", "qualified_temporal_denoised"}
        ),
        "diagnostic_only": frozenset({"diagnostic_only"}),
        "rejected": frozenset({"rejected_for_decoded_video"}),
        "blocked": frozenset({"blocked"}),
    },
    "R06": {
        "passed": frozenset({"passed"}),
        "blocked": frozenset({"blocked"}),
    },
    "R07": {
        "passed": frozenset({"passed"}),
        "blocked": frozenset({"blocked"}),
    },
    "R08": {
        "passed": frozenset({"passed"}),
        "diagnostic_only": frozenset({"diagnostic_only"}),
        "blocked": frozenset({"blocked"}),
    },
    "R09": {
        "passed": frozenset(
            {"qualified_local_residual", "qualified_for_specific_content_class"}
        ),
        "rejected": frozenset(
            {
                "no_incremental_value",
                "rejected_hallucination_risk",
                "rejected_resource_cost",
            }
        ),
        "blocked": frozenset({"blocked"}),
    },
    "R10": {
        "passed": frozenset({"passed"}),
        "blocked": frozenset({"blocked"}),
    },
    "R11": {
        "passed": frozenset({"passed"}),
        "blocked": frozenset({"blocked"}),
    },
    "R12": {
        "passed": frozenset({"passed"}),
        "blocked": frozenset({"blocked"}),
    },
    "R13": {
        "passed": frozenset({"passed"}),
        "blocked": frozenset({"blocked"}),
    },
}
R01_ANCHOR_ROLES = (
    "oldest-supported",
    "m3-air",
    "pro-max",
    "core-ai",
)
R01_CAPABILITY_IDS = tuple(f"A{index:02d}" for index in range(1, 19))
R01_CAPABILITY_DISPOSITIONS = (
    "runnable",
    "restricted",
    "diagnostic_only",
    "unsupported",
    "unavailable",
    "rejected",
)
R01_REQUIRED_OUTPUT_PATHS = frozenset(
    {
        "project-notes/evidence/r01/hosts/anchor-oldest-supported.json",
        "project-notes/evidence/r01/hosts/anchor-m3-air.json",
        "project-notes/evidence/r01/hosts/anchor-pro-max.json",
        "project-notes/evidence/r01/hosts/anchor-core-ai.json",
        "project-notes/apple-upscale-capability-report.md",
        "project-notes/apple-upscale-capabilities.json",
    }
)
R01_ANCHOR_OUTPUT_PATHS = {
    "oldest-supported": (
        "project-notes/evidence/r01/hosts/anchor-oldest-supported.json"
    ),
    "m3-air": "project-notes/evidence/r01/hosts/anchor-m3-air.json",
    "pro-max": "project-notes/evidence/r01/hosts/anchor-pro-max.json",
    "core-ai": "project-notes/evidence/r01/hosts/anchor-core-ai.json",
}
R01_REQUIRED_SOURCE_PATHS = (
    "MirmirTests/AppleUpscaleCapabilityProbeTests.swift",
)
TEXT_EVIDENCE_SUFFIXES = frozenset(
    {".csv", ".json", ".log", ".md", ".plist", ".py", ".sh", ".swift", ".txt", ".yaml", ".yml"}
)
PRIVATE_EVIDENCE_KEYS = frozenset(
    {
        "account",
        "account_id",
        "hardware_uuid",
        "home_directory",
        "serial",
        "serial_number",
        "user_name",
        "username",
    }
)
EMAIL_PATTERN = re.compile(
    r"(?i)(?<![A-Za-z0-9._%+-])[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"
)
PRIVATE_PATH_PATTERN = re.compile(r"(?i)(?:file://|/Users/|/home/)")
LABELED_PRIVATE_VALUE_PATTERN = re.compile(
    r"(?i)(?:serial(?: number)?|hardware uuid|account(?: id)?|username)\s*[:=]"
)


def decode_json(text: str) -> Any:
    def closed_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
        result: dict[str, Any] = {}
        for key, item in pairs:
            if key in result:
                raise ValueError(f"duplicate JSON key: {key}")
            result[key] = item
        return result

    def reject_constant(value: str) -> object:
        raise ValueError(f"non-finite JSON number: {value}")

    return json.loads(
        text,
        object_pairs_hook=closed_object,
        parse_constant=reject_constant,
    )


def read_json(path: Path) -> dict[str, Any]:
    value = decode_json(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError("top-level JSON value must be an object")
    return value


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _json_schema_type_matches(value: object, expected: str) -> bool:
    if expected == "object":
        return isinstance(value, dict)
    if expected == "array":
        return isinstance(value, list)
    if expected == "string":
        return isinstance(value, str)
    if expected == "integer":
        return isinstance(value, int) and not isinstance(value, bool)
    if expected == "number":
        return isinstance(value, (int, float)) and not isinstance(value, bool)
    if expected == "boolean":
        return isinstance(value, bool)
    if expected == "null":
        return value is None
    return False


def _json_schema_equal(left: object, right: object) -> bool:
    if isinstance(left, bool) or isinstance(right, bool):
        return type(left) is type(right) and left == right
    return left == right


def validate_json_schema_instance(
    schema_root: dict[str, Any], instance: object
) -> list[str]:
    errors: list[str] = []

    def resolve(reference: object, path: str) -> dict[str, Any] | None:
        if not isinstance(reference, str) or not reference.startswith("#/$defs/"):
            errors.append(f"{path}: unsupported schema reference {reference!r}")
            return None
        name = reference.removeprefix("#/$defs/")
        definitions = schema_root.get("$defs")
        target = definitions.get(name) if isinstance(definitions, dict) else None
        if not isinstance(target, dict):
            errors.append(f"{path}: unresolved schema reference {reference!r}")
            return None
        return target

    def validate(schema: object, value: object, path: str) -> list[str]:
        local_errors: list[str] = []
        if not isinstance(schema, dict):
            return [f"{path}: schema node must be an object"]
        if "$ref" in schema:
            target = resolve(schema["$ref"], path)
            if target is None:
                return []
            return validate(target, value, path)
        if "oneOf" in schema:
            branches = schema["oneOf"]
            if not isinstance(branches, list):
                return [f"{path}: oneOf schema must be an array"]
            matches = sum(not validate(branch, value, path) for branch in branches)
            if matches != 1:
                return [f"{path}: value must match exactly one allowed schema"]

        expected_type = schema.get("type")
        if expected_type is not None:
            allowed_types = (
                expected_type if isinstance(expected_type, list) else [expected_type]
            )
            if not all(isinstance(item, str) for item in allowed_types) or not any(
                _json_schema_type_matches(value, item) for item in allowed_types
            ):
                return [f"{path}: value has the wrong JSON type"]

        if "const" in schema and not _json_schema_equal(value, schema["const"]):
            local_errors.append(f"{path}: value differs from the required constant")
        enum = schema.get("enum")
        if isinstance(enum, list) and not any(
            _json_schema_equal(value, candidate) for candidate in enum
        ):
            local_errors.append(f"{path}: value is outside the closed enumeration")

        if isinstance(value, dict):
            required = schema.get("required", [])
            if isinstance(required, list):
                for key in required:
                    if isinstance(key, str) and key not in value:
                        local_errors.append(f"{path}.{key}: required field is absent")
            properties = schema.get("properties", {})
            if isinstance(properties, dict):
                for key, item in value.items():
                    property_schema = properties.get(key)
                    if isinstance(property_schema, dict):
                        local_errors.extend(
                            validate(property_schema, item, f"{path}.{key}")
                        )
                    elif schema.get("additionalProperties") is False:
                        local_errors.append(f"{path}.{key}: field is not allowed")

        if isinstance(value, list):
            minimum_items = schema.get("minItems")
            if isinstance(minimum_items, int) and len(value) < minimum_items:
                local_errors.append(
                    f"{path}: array contains fewer than {minimum_items} items"
                )
            if schema.get("uniqueItems") is True:
                tokens = [
                    json.dumps(item, sort_keys=True, separators=(",", ":"))
                    for item in value
                ]
                if len(tokens) != len(set(tokens)):
                    local_errors.append(f"{path}: array items must be unique")
            item_schema = schema.get("items")
            if isinstance(item_schema, dict):
                for index, item in enumerate(value):
                    local_errors.extend(
                        validate(item_schema, item, f"{path}[{index}]")
                    )

        if isinstance(value, str):
            minimum_length = schema.get("minLength")
            if isinstance(minimum_length, int) and len(value) < minimum_length:
                local_errors.append(
                    f"{path}: string is shorter than {minimum_length} characters"
                )
            pattern = schema.get("pattern")
            if isinstance(pattern, str) and re.search(pattern, value) is None:
                local_errors.append(f"{path}: string does not match the required pattern")
            if schema.get("format") == "date-time" and (
                RFC3339_PATTERN.fullmatch(value) is None
            ):
                local_errors.append(f"{path}: string is not an RFC 3339 timestamp")

        if isinstance(value, (int, float)) and not isinstance(value, bool):
            minimum = schema.get("minimum")
            maximum = schema.get("maximum")
            if isinstance(minimum, (int, float)) and value < minimum:
                local_errors.append(f"{path}: number is below the minimum")
            if isinstance(maximum, (int, float)) and value > maximum:
                local_errors.append(f"{path}: number exceeds the maximum")
        return local_errors

    errors.extend(validate(schema_root, instance, "$"))
    return errors


def markdown_cell(value: object) -> str:
    return str(value).replace("|", "\\|").replace("\n", " ")


def render_phase_evidence(manifest: dict[str, Any]) -> str:
    source = manifest["source"]
    result = manifest["result"]
    lines = [
        f"# {manifest['phase_id']} Phase Evidence",
        "",
        f"- **Schema version:** `{manifest['schema_version']}`",
        f"- **Roadmap version:** `{manifest['roadmap_version']}`",
        f"- **Source commit:** `{source['commit']}`",
        f"- **Source tree:** `{source['tree']}`",
        f"- **Result status:** `{result['status']}`",
        f"- **Result disposition:** `{result['disposition']}`",
        f"- **Phase status before:** `{result['phase_status_before']}`",
        f"- **Phase status after:** `{result['phase_status_after']}`",
        "",
        "This summary is generated from `phase-evidence.json`; the JSON manifest "
        "is canonical.",
        "",
        "## Hosts",
        "",
        "| Host | Roles | Hardware classes | Model | Chip | Memory bytes | "
        "macOS | Build | Xcode | SDK |",
        "| --- | --- | --- | --- | --- | ---: | --- | --- | --- | --- |",
    ]
    for host in manifest["hosts"]:
        lines.append(
            "| "
            f"`{markdown_cell(host['host_id'])}` | "
            f"{markdown_cell(', '.join(host['roles']))} | "
            f"{markdown_cell(', '.join(host['hardware_classes']))} | "
            f"`{markdown_cell(host['model_identifier'])}` | "
            f"{markdown_cell(host['chip'])} | "
            f"{host['memory_bytes']} | "
            f"`{markdown_cell(host['os_version'])}` | "
            f"`{markdown_cell(host['os_build'])}` | "
            f"`{markdown_cell(host['xcode_version'])}` | "
            f"`{markdown_cell(host['sdk_version'])}` |"
        )

    preregistration = manifest["preregistration"]
    lines.extend(
        [
            "",
            "## Preregistration",
            "",
            f"- Record: `{preregistration['record']['path']}`",
            f"- Inputs: `{len(preregistration['inputs'])}`",
            f"- Fixtures: `{len(preregistration['fixtures'])}`",
            f"- Parameters: `{len(preregistration['parameters'])}`",
            f"- Metrics: `{len(preregistration['metrics'])}`",
            f"- Floors: `{len(preregistration['floors'])}`",
            f"- Stop rules: `{len(preregistration['stop_rules'])}`",
            f"- Disposition subjects: `{len(preregistration['disposition_subjects'])}`",
            "",
            "## Commands",
            "",
            "| ID | Host | Result | Exit | Invocation |",
            "| --- | --- | --- | ---: | --- |",
        ]
    )
    for command in manifest["commands"]:
        exit_status = (
            "—" if command["exit_status"] is None else command["exit_status"]
        )
        invocation = " ".join(command["argv"])
        lines.append(
            f"| `{markdown_cell(command['command_id'])}` | "
            f"`{markdown_cell(command['host_id'])}` | "
            f"`{markdown_cell(command['result'])}` | {exit_status} | "
            f"`{markdown_cell(invocation)}` |"
        )

    lines.extend(
        [
            "",
            "## Outputs",
            "",
            "| ID | Kind | Path | Bytes | SHA-256 |",
            "| --- | --- | --- | ---: | --- |",
        ]
    )
    for output in manifest["outputs"]:
        binding = output["binding"]
        lines.append(
            f"| `{markdown_cell(output['id'])}` | "
            f"`{markdown_cell(output['kind'])}` | "
            f"`{markdown_cell(binding['path'])}` | "
            f"{binding['size_bytes']} | `{binding['sha256']}` |"
        )

    lines.extend(["", "## Verification", ""])
    for check in manifest["verification"]["checks"]:
        reason = f" — {check['reason']}" if check["reason"] else ""
        required = "required" if check["required"] else "optional"
        lines.append(
            f"- `{check['id']}` (`{check['category']}`, {required}): "
            f"`{check['status']}`{reason}"
        )

    lines.extend(
        [
            "",
            "## Capability or Experimental Dispositions",
            "",
            "| Subject | Disposition | Reason |",
            "| --- | --- | --- |",
        ]
    )
    for disposition in result["dispositions"]:
        lines.append(
            f"| `{markdown_cell(disposition['subject_id'])}` | "
            f"`{markdown_cell(disposition['value'])}` | "
            f"{markdown_cell(disposition['reason'])} |"
        )

    lines.extend(
        [
            "",
            "## Result",
            "",
            result["summary"],
            "",
            "## Authorization State",
            "",
            "### Before",
            "",
        ]
    )
    for value in manifest["authorizations"]["before"]:
        lines.append(f"- `{value['id']}`: `{value['value']}`")
    lines.extend(["", "### After", ""])
    for value in manifest["authorizations"]["after"]:
        lines.append(f"- `{value['id']}`: `{value['value']}`")
    lines.extend(["", "### Proposed decisions", ""])
    proposed = manifest["authorizations"]["proposed_decisions"]
    if proposed:
        lines.extend(f"- {decision}" for decision in proposed)
    else:
        lines.append("- None")

    lines.extend(["", "## Limitations", ""])
    if manifest["limitations"]:
        lines.extend(f"- {limitation}" for limitation in manifest["limitations"])
    else:
        lines.append("- None recorded")
    return "\n".join(lines) + "\n"


class PhaseEvidenceVerifier:
    def __init__(
        self,
        root: Path,
        phase_id: str,
        *,
        manifest_path: Path | None = None,
        summary_path: Path | None = None,
        schema_path: Path | None = None,
    ) -> None:
        self.root = root.resolve()
        self.phase_id = phase_id.upper()
        phase_directory = self.root / "docs/roadmaps/evidence" / self.phase_id.lower()
        self.manifest_path = manifest_path or phase_directory / "phase-evidence.json"
        self.summary_path = summary_path or phase_directory / "phase-evidence.md"
        self.schema_path = schema_path or (
            self.root
            / "docs/roadmaps/evidence/schema/phase-evidence-manifest-v1.json"
        )
        self._bound_paths: dict[str, tuple[int, str]] = {}
        self._privacy_checked_paths: set[str] = set()
        self._source_commit: str | None = None
        self._canonical_roadmap: dict[str, Any] | None = None
        self._schema: dict[str, Any] | None = None

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

    @staticmethod
    def _exact_keys(
        value: object,
        expected: Iterable[str],
        context: str,
        errors: list[str],
    ) -> bool:
        if not isinstance(value, dict):
            errors.append(f"{context} must be an object")
            return False
        actual = tuple(value.keys())
        expected_tuple = tuple(expected)
        if set(actual) != set(expected_tuple):
            errors.append(
                f"{context} fields differ from the closed schema: "
                f"expected {expected_tuple!r}, found {actual!r}"
            )
            return False
        return True

    @staticmethod
    def _identifier(value: object, context: str, errors: list[str]) -> bool:
        if not isinstance(value, str) or IDENTIFIER_PATTERN.fullmatch(value) is None:
            errors.append(f"{context} must be a closed-form identifier")
            return False
        return True

    @staticmethod
    def _string(value: object, context: str, errors: list[str]) -> bool:
        if not isinstance(value, str) or not value:
            errors.append(f"{context} must be a non-empty string")
            return False
        return True

    @staticmethod
    def _unique_strings(
        value: object,
        context: str,
        errors: list[str],
        *,
        minimum: int = 0,
        identifiers: bool = False,
    ) -> list[str] | None:
        if not isinstance(value, list) or len(value) < minimum:
            errors.append(f"{context} must contain at least {minimum} values")
            return None
        if not all(isinstance(item, str) and item for item in value):
            errors.append(f"{context} must contain only non-empty strings")
            return None
        if len(value) != len(set(value)):
            errors.append(f"{context} must not contain duplicate values")
        if identifiers:
            for index, item in enumerate(value):
                if IDENTIFIER_PATTERN.fullmatch(item) is None:
                    errors.append(f"{context}[{index}] is not a valid identifier")
        return value

    @staticmethod
    def _safe_relative_path(value: object) -> PurePosixPath | None:
        if (
            not isinstance(value, str)
            or not value
            or "\\" in value
            or "\x00" in value
        ):
            return None
        path = PurePosixPath(value)
        if path.is_absolute() or any(part in ("", ".", "..") for part in path.parts):
            return None
        return path

    @staticmethod
    def _datetime(value: object, context: str, errors: list[str]) -> datetime | None:
        if not isinstance(value, str) or RFC3339_PATTERN.fullmatch(value) is None:
            errors.append(f"{context} must be an RFC 3339 timestamp")
            return None
        try:
            parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
        except ValueError:
            errors.append(f"{context} must be an RFC 3339 timestamp")
            return None
        if parsed.tzinfo is None:
            errors.append(f"{context} must include a timezone")
            return None
        return parsed

    def _check_schema(self, errors: list[str]) -> None:
        try:
            payload = self.schema_path.read_bytes()
            schema = read_json(self.schema_path)
        except (OSError, ValueError, json.JSONDecodeError) as error:
            errors.append(f"phase-evidence schema cannot be read: {error}")
            return
        if sha256_bytes(payload) != SCHEMA_SHA256:
            errors.append("phase-evidence schema SHA-256 differs from version 1.0")
            return
        if schema.get("$schema") != "https://json-schema.org/draft/2020-12/schema":
            errors.append("phase-evidence schema must use JSON Schema draft 2020-12")
        if schema.get("additionalProperties") is not False:
            errors.append("phase-evidence schema must close the top-level object")
        if tuple(schema.get("required", ())) != TOP_LEVEL_KEYS:
            errors.append("phase-evidence schema top-level keys/order differ")
        properties = schema.get("properties")
        if not isinstance(properties, dict):
            errors.append("phase-evidence schema properties must be an object")
        elif properties.get("schema_version") != {"const": SCHEMA_VERSION}:
            errors.append("phase-evidence schema version contract differs")
        if not errors:
            self._schema = schema

    def _check_source(self, value: object, errors: list[str]) -> None:
        if not self._exact_keys(value, SOURCE_KEYS, "source", errors):
            return
        assert isinstance(value, dict)
        commit = value["commit"]
        tree = value["tree"]
        if not isinstance(commit, str) or GIT_OBJECT_PATTERN.fullmatch(commit) is None:
            errors.append("source.commit must be a nonzero lowercase SHA-1 object ID")
            return
        if not isinstance(tree, str) or GIT_OBJECT_PATTERN.fullmatch(tree) is None:
            errors.append("source.tree must be a nonzero lowercase SHA-1 object ID")
            return
        commit_check = self.git("cat-file", "-e", f"{commit}^{{commit}}")
        if commit_check.returncode != 0:
            errors.append("source.commit is not an available commit")
            return
        tree_result = self.git("rev-parse", f"{commit}^{{tree}}")
        if tree_result.returncode != 0 or tree_result.stdout.strip() != tree:
            errors.append("source.tree does not match source.commit")
            return
        ancestor = self.git("merge-base", "--is-ancestor", commit, "HEAD")
        if ancestor.returncode != 0:
            errors.append("source.commit must be an ancestor of HEAD")
            return
        self._source_commit = commit
        roadmap_result = self.git_bytes(
            "show",
            f"{commit}:docs/roadmaps/Mirmir_Apple_Native_ASH_Roadmap_2026-07-18.json",
        )
        if roadmap_result.returncode != 0:
            errors.append("canonical roadmap is absent at source.commit")
            return
        try:
            roadmap_value = json.loads(roadmap_result.stdout.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            errors.append(f"canonical roadmap is invalid at source.commit: {error}")
            return
        if not isinstance(roadmap_value, dict):
            errors.append("canonical roadmap at source.commit must be an object")
            return
        self._canonical_roadmap = roadmap_value

    def _check_host(self, value: object, index: int, errors: list[str]) -> str | None:
        context = f"hosts[{index}]"
        if not self._exact_keys(value, HOST_KEYS, context, errors):
            return None
        assert isinstance(value, dict)
        host_id = value["host_id"]
        self._identifier(host_id, f"{context}.host_id", errors)
        self._unique_strings(
            value["roles"],
            f"{context}.roles",
            errors,
            minimum=1,
            identifiers=True,
        )
        hardware_classes = self._unique_strings(
            value["hardware_classes"],
            f"{context}.hardware_classes",
            errors,
            minimum=1,
            identifiers=True,
        )
        if hardware_classes is not None:
            unknown_classes = sorted(set(hardware_classes) - set(HARDWARE_CLASSES))
            if unknown_classes:
                errors.append(
                    f"{context}.hardware_classes are outside the closed vocabulary: "
                    f"{unknown_classes!r}"
                )
        for key in (
            "model_identifier",
            "chip",
            "os_version",
            "os_build",
            "xcode_version",
            "xcode_build",
            "sdk_version",
        ):
            self._string(value[key], f"{context}.{key}", errors)
        memory = value["memory_bytes"]
        if isinstance(memory, bool) or not isinstance(memory, int) or memory < 1:
            errors.append(f"{context}.memory_bytes must be a positive integer")
        source_commit = value["source_commit"]
        if (
            not isinstance(source_commit, str)
            or GIT_OBJECT_PATTERN.fullmatch(source_commit) is None
        ):
            errors.append(f"{context}.source_commit must be a Git commit ID")
        elif self._source_commit is not None:
            commit_check = self.git("cat-file", "-e", f"{source_commit}^{{commit}}")
            if commit_check.returncode != 0:
                errors.append(f"{context}.source_commit is not an available commit")
            elif self.git(
                "merge-base", "--is-ancestor", source_commit, self._source_commit
            ).returncode != 0:
                errors.append(
                    f"{context}.source_commit must be an ancestor of source.commit"
                )
        return host_id if isinstance(host_id, str) else None

    def _check_binding(
        self,
        value: object,
        context: str,
        errors: list[str],
    ) -> None:
        if not self._exact_keys(value, FILE_BINDING_KEYS, context, errors):
            return
        assert isinstance(value, dict)
        relative = self._safe_relative_path(value["path"])
        if relative is None:
            errors.append(f"{context}.path must be a safe repository-relative path")
            return
        size = value["size_bytes"]
        digest = value["sha256"]
        if isinstance(size, bool) or not isinstance(size, int) or size < 0:
            errors.append(f"{context}.size_bytes must be a nonnegative integer")
            return
        if size > MAX_EVIDENCE_FILE_BYTES:
            errors.append(f"{context} exceeds the 25 MiB evidence-file limit")
        if not isinstance(digest, str) or SHA256_PATTERN.fullmatch(digest) is None:
            errors.append(f"{context}.sha256 must be a nonzero lowercase SHA-256")
            return
        path_string = relative.as_posix()
        self_paths: set[str] = set()
        for protected_path in (self.manifest_path, self.summary_path):
            try:
                self_paths.add(protected_path.resolve().relative_to(self.root).as_posix())
            except (OSError, ValueError):
                continue
        if path_string in self_paths:
            errors.append(f"{context}.path cannot bind the manifest or generated summary")
            return
        previous = self._bound_paths.get(path_string)
        if previous is not None and previous != (size, digest):
            errors.append(f"{context} conflicts with another binding for {path_string}")
        self._bound_paths[path_string] = (size, digest)
        candidate = self.root / Path(*relative.parts)
        try:
            resolved = candidate.resolve(strict=True)
        except OSError:
            errors.append(f"{context}.path is absent: {path_string}")
            return
        if not resolved.is_relative_to(self.root):
            errors.append(f"{context}.path resolves outside the repository")
            return
        if candidate.is_symlink() or not candidate.is_file():
            errors.append(f"{context}.path must identify a regular repository file")
            return
        actual_size = candidate.stat().st_size
        if actual_size != size:
            errors.append(
                f"{context}.size_bytes differs: expected {size}, found {actual_size}"
            )
        actual_digest = sha256_file(candidate)
        if actual_digest != digest:
            errors.append(f"{context}.sha256 differs from repository file")
        self._check_bound_file_privacy(candidate, path_string, errors)
        if candidate.read_bytes().startswith(b"version https://git-lfs.github.com/spec/v1\n"):
            errors.append(f"{context}.path is a prohibited Git LFS pointer")
        if self._source_commit is not None:
            historical = self.git_bytes(
                "show", f"{self._source_commit}:{path_string}"
            )
            if historical.returncode != 0:
                errors.append(
                    f"{context}.path is absent at source.commit: {path_string}"
                )
            else:
                payload = historical.stdout
                if payload.startswith(b"version https://git-lfs.github.com/spec/v1\n"):
                    errors.append(f"{context}.path is a prohibited Git LFS pointer")
                if len(payload) != size or sha256_bytes(payload) != digest:
                    errors.append(
                        f"{context} does not match the file at source.commit"
                    )

    def _check_bound_file_privacy(
        self,
        path: Path,
        relative: str,
        errors: list[str],
    ) -> None:
        if relative in self._privacy_checked_paths:
            return
        self._privacy_checked_paths.add(relative)
        if path.suffix.lower() not in TEXT_EVIDENCE_SUFFIXES:
            return
        try:
            text = path.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError) as error:
            errors.append(f"bound text evidence cannot be read as UTF-8: {relative}: {error}")
            return
        if path.suffix.lower() == ".json":
            try:
                value = decode_json(text)
            except (ValueError, json.JSONDecodeError) as error:
                errors.append(f"bound JSON evidence is invalid: {relative}: {error}")
                return
            self._check_privacy(value, errors, f"bound evidence {relative}")
        else:
            self._check_privacy(text, errors, f"bound evidence {relative}")

    def _check_named_items(
        self,
        values: object,
        expected_keys: Iterable[str],
        context: str,
        errors: list[str],
        *,
        minimum: int = 0,
    ) -> list[dict[str, Any]]:
        if not isinstance(values, list) or len(values) < minimum:
            errors.append(f"{context} must contain at least {minimum} records")
            return []
        records: list[dict[str, Any]] = []
        identifiers: list[str] = []
        for index, record in enumerate(values):
            item_context = f"{context}[{index}]"
            if not self._exact_keys(record, expected_keys, item_context, errors):
                continue
            assert isinstance(record, dict)
            identifier = record.get("id")
            if identifier is not None:
                self._identifier(identifier, f"{item_context}.id", errors)
                if isinstance(identifier, str):
                    identifiers.append(identifier)
            records.append(record)
        if len(identifiers) != len(set(identifiers)):
            errors.append(f"{context} IDs must be unique")
        return records

    def _check_preregistration(
        self, value: object, errors: list[str]
    ) -> dict[str, set[str]]:
        if not self._exact_keys(
            value, PREREGISTRATION_KEYS, "preregistration", errors
        ):
            return {}
        assert isinstance(value, dict)
        self._check_binding(value["record"], "preregistration.record", errors)

        inputs = self._check_named_items(
            value["inputs"], INPUT_KEYS, "preregistration.inputs", errors
        )
        for index, item in enumerate(inputs):
            context = f"preregistration.inputs[{index}]"
            if item["kind"] not in INPUT_KINDS:
                errors.append(f"{context}.kind is outside the closed vocabulary")
            self._string(item["identity"], f"{context}.identity", errors)
            binding = item["binding"]
            if item["kind"] in ("repository_fixture", "external_receipt"):
                if binding is None:
                    errors.append(
                        f"{context}.binding is required for {item['kind']}"
                    )
            elif item["kind"] == "system_asset" and binding is not None:
                errors.append(f"{context}.binding must be null for system_asset")
            if binding is not None and item["kind"] != "system_asset":
                self._check_binding(binding, f"{context}.binding", errors)
            self._unique_strings(
                item["limitations"], f"{context}.limitations", errors
            )

        fixtures = self._check_named_items(
            value["fixtures"],
            FIXTURE_KEYS,
            "preregistration.fixtures",
            errors,
            minimum=1,
        )
        for index, fixture in enumerate(fixtures):
            context = f"preregistration.fixtures[{index}]"
            self._string(fixture["role"], f"{context}.role", errors)
            self._check_binding(fixture["binding"], f"{context}.binding", errors)
            if fixture["redistributable"] is not True:
                errors.append(f"{context}.redistributable must be true")

        parameters = self._check_named_items(
            value["parameters"],
            PARAMETER_KEYS,
            "preregistration.parameters",
            errors,
        )
        for index, parameter in enumerate(parameters):
            context = f"preregistration.parameters[{index}]"
            raw_value = parameter["value"]
            if raw_value is None or isinstance(raw_value, (list, dict)):
                errors.append(f"{context}.value must be a scalar")
            unit = parameter["unit"]
            if unit is not None and (not isinstance(unit, str) or not unit):
                errors.append(f"{context}.unit must be null or a non-empty string")

        metrics = self._check_named_items(
            value["metrics"],
            METRIC_KEYS,
            "preregistration.metrics",
            errors,
            minimum=1,
        )
        metric_ids = {
            metric["id"]
            for metric in metrics
            if isinstance(metric.get("id"), str)
        }
        for index, metric in enumerate(metrics):
            context = f"preregistration.metrics[{index}]"
            unit = metric["unit"]
            if unit is not None and (not isinstance(unit, str) or not unit):
                errors.append(f"{context}.unit must be null or a non-empty string")
            if metric["direction"] not in METRIC_DIRECTIONS:
                errors.append(f"{context}.direction is outside the closed vocabulary")
            self._string(metric["applicability"], f"{context}.applicability", errors)

        floors = self._check_named_items(
            value["floors"], FLOOR_KEYS, "preregistration.floors", errors
        )
        for index, floor in enumerate(floors):
            context = f"preregistration.floors[{index}]"
            metric_id = floor["metric_id"]
            self._identifier(metric_id, f"{context}.metric_id", errors)
            if isinstance(metric_id, str) and metric_id not in metric_ids:
                errors.append(f"{context}.metric_id does not reference a metric")
            if floor["comparison"] not in FLOOR_COMPARISONS:
                errors.append(f"{context}.comparison is outside the closed vocabulary")
            floor_value = floor["value"]
            if isinstance(floor_value, (list, dict)):
                errors.append(f"{context}.value must be a scalar or null")
            self._string(floor["scope"], f"{context}.scope", errors)

        stop_rules = self._check_named_items(
            value["stop_rules"],
            STATEMENT_KEYS,
            "preregistration.stop_rules",
            errors,
            minimum=1,
        )
        for index, rule in enumerate(stop_rules):
            self._string(
                rule["description"],
                f"preregistration.stop_rules[{index}].description",
                errors,
            )
        disposition_subjects = value["disposition_subjects"]
        if not isinstance(disposition_subjects, list):
            errors.append("preregistration.disposition_subjects must be an array")
            return {}
        subjects: dict[str, set[str]] = {}
        for index, subject in enumerate(disposition_subjects):
            context = f"preregistration.disposition_subjects[{index}]"
            if not self._exact_keys(
                subject, DISPOSITION_SUBJECT_KEYS, context, errors
            ):
                continue
            assert isinstance(subject, dict)
            subject_id = subject["subject_id"]
            if not self._identifier(subject_id, f"{context}.subject_id", errors):
                continue
            assert isinstance(subject_id, str)
            allowed_values = self._unique_strings(
                subject["allowed_values"],
                f"{context}.allowed_values",
                errors,
                minimum=1,
                identifiers=True,
            )
            if subject_id in subjects:
                errors.append("preregistration disposition subject IDs must be unique")
            elif allowed_values is not None:
                subjects[subject_id] = set(allowed_values)
        return subjects

    def _check_commands(
        self, value: object, host_ids: set[str], errors: list[str]
    ) -> dict[str, dict[str, Any]]:
        if not isinstance(value, list):
            errors.append("commands must be an array")
            return {}
        command_ids: list[str] = []
        command_records: dict[str, dict[str, Any]] = {}
        for index, command in enumerate(value):
            context = f"commands[{index}]"
            if not self._exact_keys(command, COMMAND_KEYS, context, errors):
                continue
            assert isinstance(command, dict)
            command_id = command["command_id"]
            if self._identifier(command_id, f"{context}.command_id", errors):
                assert isinstance(command_id, str)
                command_ids.append(command_id)
                command_records.setdefault(command_id, command)
            host_id = command["host_id"]
            if not isinstance(host_id, str) or host_id not in host_ids:
                errors.append(f"{context}.host_id does not reference a host")
            argv = command["argv"]
            if (
                not isinstance(argv, list)
                or not argv
                or not all(isinstance(item, str) and item for item in argv)
            ):
                errors.append(f"{context}.argv must contain non-empty arguments")
            elif self._source_commit is not None:
                repository_command: str | None = None
                direct_invocation = False
                if "/" in argv[0]:
                    repository_command = argv[0]
                    direct_invocation = True
                elif (
                    argv[0] == "python3"
                    and len(argv) > 1
                    and "/" in argv[1]
                ):
                    repository_command = argv[1]
                if repository_command is not None:
                    relative_command = self._safe_relative_path(repository_command)
                    if relative_command is None:
                        errors.append(
                            f"{context}.argv references an unsafe repository command"
                        )
                    else:
                        command_path = relative_command.as_posix()
                        tree_entry = self.git(
                            "ls-tree", self._source_commit, "--", command_path
                        )
                        if not tree_entry.stdout.strip():
                            errors.append(
                                f"{context}.argv repository command is absent at "
                                f"source.commit: {command_path}"
                            )
                        elif direct_invocation and not tree_entry.stdout.startswith(
                            "100755 blob "
                        ):
                            errors.append(
                                f"{context}.argv repository command is not executable "
                                f"at source.commit: {command_path}"
                            )
            environment_flags = command["environment_flags"]
            enabled_flags: dict[str, str] = {}
            if not isinstance(environment_flags, list):
                errors.append(f"{context}.environment_flags must be an array")
            else:
                for flag_index, flag in enumerate(environment_flags):
                    flag_context = f"{context}.environment_flags[{flag_index}]"
                    if not self._exact_keys(
                        flag, ENVIRONMENT_FLAG_KEYS, flag_context, errors
                    ):
                        continue
                    assert isinstance(flag, dict)
                    name = flag["name"]
                    if not self._identifier(name, f"{flag_context}.name", errors):
                        continue
                    assert isinstance(name, str)
                    if flag["value"] != "1":
                        errors.append(f"{flag_context}.value must equal '1'")
                    if name in enabled_flags:
                        errors.append(f"{context}.environment_flags names must be unique")
                    enabled_flags[name] = flag["value"]
                    upper = name.upper()
                    if any(
                        token in upper
                        for token in ("TOKEN", "PASSWORD", "SECRET", "CREDENTIAL")
                    ) or upper.endswith("PRIVATE_KEY"):
                        errors.append(
                            f"{context}.environment_flags contains a secret-bearing name"
                        )
                if (
                    "MIRMIR_R01_ALLOW_MODEL_ACQUISITION" in enabled_flags
                    and "MIRMIR_R01_LIVE_PROBES" not in enabled_flags
                ):
                    errors.append(
                        f"{context} enables R01 model acquisition without live probes"
                    )
            consent_receipt = command["consent_receipt"]
            acquisition_enabled = (
                "MIRMIR_R01_ALLOW_MODEL_ACQUISITION" in enabled_flags
            )
            if acquisition_enabled:
                if consent_receipt is None:
                    errors.append(
                        f"{context}.consent_receipt is required for model acquisition"
                    )
                else:
                    self._check_binding(
                        consent_receipt, f"{context}.consent_receipt", errors
                    )
            elif consent_receipt is not None:
                errors.append(
                    f"{context}.consent_receipt requires model acquisition"
                )
            started = self._datetime(command["started_at"], f"{context}.started_at", errors)
            ended = self._datetime(command["ended_at"], f"{context}.ended_at", errors)
            if started is not None and ended is not None and ended < started:
                errors.append(f"{context}.ended_at precedes started_at")
            result = command["result"]
            if result not in EXECUTION_STATUSES:
                errors.append(f"{context}.result is outside the closed vocabulary")
            exit_status = command["exit_status"]
            skip_reason = command["skip_reason"]
            if result == "skipped":
                if exit_status is not None:
                    errors.append(f"{context}.exit_status must be null when skipped")
                if not isinstance(skip_reason, str) or not skip_reason:
                    errors.append(f"{context}.skip_reason is required when skipped")
            else:
                if isinstance(exit_status, bool) or not isinstance(exit_status, int):
                    errors.append(f"{context}.exit_status must be an integer")
                if skip_reason is not None:
                    errors.append(f"{context}.skip_reason must be null when executed")
                if result == "passed" and exit_status != 0:
                    errors.append(f"{context} passed with a nonzero exit_status")
                if result == "failed" and exit_status == 0:
                    errors.append(f"{context} failed with a zero exit_status")
        if len(command_ids) != len(set(command_ids)):
            errors.append("command IDs must be unique")
        return command_records

    def _check_outputs(
        self, value: object, errors: list[str]
    ) -> dict[str, dict[str, Any]]:
        records = self._check_named_items(value, OUTPUT_KEYS, "outputs", errors)
        output_records: dict[str, dict[str, Any]] = {}
        seen_paths: set[str] = set()
        for index, output in enumerate(records):
            context = f"outputs[{index}]"
            if output["kind"] not in OUTPUT_KINDS:
                errors.append(f"{context}.kind is outside the closed vocabulary")
            self._check_binding(output["binding"], f"{context}.binding", errors)
            if not isinstance(output["generated_summary"], bool):
                errors.append(f"{context}.generated_summary must be boolean")
            if output["redistributable"] is not True:
                errors.append(f"{context}.redistributable must be true")
            if output["contains_holdout_pixels"] is not False:
                errors.append(f"{context}.contains_holdout_pixels must be false")
            if output["system_asset"] is not False:
                errors.append(f"{context}.system_asset must be false")
            output_id = output.get("id")
            binding = output.get("binding")
            if isinstance(output_id, str) and isinstance(binding, dict):
                path = binding.get("path")
                if isinstance(path, str):
                    normalized_path = self._safe_relative_path(path)
                    canonical_path = (
                        normalized_path.as_posix()
                        if normalized_path is not None
                        else path
                    )
                    output_records.setdefault(output_id, output)
                    if canonical_path in seen_paths:
                        errors.append("output paths must be unique")
                    seen_paths.add(canonical_path)
        return output_records

    @staticmethod
    def _command_matches_verification_category(
        command: dict[str, Any], category: str
    ) -> bool:
        argv = command.get("argv")
        if not isinstance(argv, list):
            return False
        guardrail = argv == ["Scripts/verify-mirmir-guardrails.sh"]
        if category == "json":
            return guardrail or argv[:3] == ["python3", "-m", "json.tool"]
        if category == "lint":
            return (
                len(argv) >= 3
                and argv[:2] == ["swiftlint", "lint"]
                and "--strict" in argv
            )
        if category == "unit_test":
            return argv[:3] == ["python3", "-m", "unittest"] or (
                argv and argv[0] == "xcodebuild" and "test" in argv
            )
        if category == "mutation_test":
            return (
                argv[:3] == ["python3", "-m", "unittest"]
                and any("test_phase_evidence" in item for item in argv[3:])
            )
        if category == "repository":
            return argv == ["git", "diff", "--check"]
        if category == "dependency_scan":
            return guardrail or argv[:3] == ["swift", "package", "show-dependencies"]
        if category == "project_generation":
            return argv[:2] == ["xcodegen", "generate"]
        if category == "build":
            return (
                argv
                and argv[0] == "xcodebuild"
                and "build" in argv
                and "-disableAutomaticPackageResolution" in argv
            )
        if category == "hosted_test":
            return guardrail or (
                argv
                and argv[0] == "xcodebuild"
                and any(item in argv for item in ("test", "test-without-building"))
            )
        if category == "smoke_test":
            return bool(argv) and argv[0] in ("open", "xcrun")
        if category == "runtime":
            return bool(argv) and argv[0] == "Scripts/run-r01-capability-probe.sh"
        if category == "evidence_integrity":
            return (
                len(argv) >= 4
                and argv[:2] == ["python3", "Scripts/phase_evidence.py"]
                and "--check" in argv
            )
        return False

    def _check_verification_artifact(
        self,
        output: dict[str, Any],
        category: str,
        command_ids: list[str],
        context: str,
        errors: list[str],
    ) -> None:
        binding = output.get("binding")
        path_value = binding.get("path") if isinstance(binding, dict) else None
        relative = self._safe_relative_path(path_value)
        if relative is None or relative.suffix.lower() != ".json":
            errors.append(f"{context} must reference a bound JSON verification artifact")
            return
        path = self.root / Path(*relative.parts)
        try:
            artifact = read_json(path)
        except (OSError, ValueError, json.JSONDecodeError) as error:
            errors.append(f"{context} verification artifact is invalid: {error}")
            return
        if not self._exact_keys(
            artifact, VERIFICATION_ARTIFACT_KEYS, f"{context}.artifact", errors
        ):
            return
        if artifact["schema_version"] != "1.0":
            errors.append(f"{context}.artifact.schema_version must equal 1.0")
        if artifact["category"] != category:
            errors.append(f"{context}.artifact.category differs from its check")
        if artifact["command_ids"] != command_ids:
            errors.append(f"{context}.artifact.command_ids differ from its check")
        if artifact["status"] != "passed" or artifact["exit_status"] != 0:
            errors.append(f"{context}.artifact does not record a passing zero-exit result")
        self._string(artifact["summary"], f"{context}.artifact.summary", errors)

    def _check_verification(
        self,
        value: object,
        command_records: dict[str, dict[str, Any]],
        output_records: dict[str, dict[str, Any]],
        errors: list[str],
    ) -> list[dict[str, Any]]:
        if not self._exact_keys(value, VERIFICATION_KEYS, "verification", errors):
            return []
        assert isinstance(value, dict)
        checks = value["checks"]
        if not isinstance(checks, list) or not checks:
            errors.append("verification.checks must contain at least one record")
            return []
        check_ids: list[str] = []
        valid_checks: list[dict[str, Any]] = []
        for index, check in enumerate(checks):
            context = f"verification.checks[{index}]"
            if not self._exact_keys(
                check, VERIFICATION_CHECK_KEYS, context, errors
            ):
                continue
            assert isinstance(check, dict)
            check_id = check["id"]
            if self._identifier(check_id, f"{context}.id", errors):
                check_ids.append(check_id)
            status = check["status"]
            if status not in EXECUTION_STATUSES:
                errors.append(f"{context}.status is outside the closed vocabulary")
            category = check["category"]
            category_is_valid = (
                isinstance(category, str) and category in VERIFICATION_CATEGORIES
            )
            if not category_is_valid:
                errors.append(f"{context}.category is outside the closed vocabulary")
            required = check["required"]
            if not isinstance(required, bool):
                errors.append(f"{context}.required must be boolean")
            if (
                status in EXECUTION_STATUSES
                and category_is_valid
                and isinstance(required, bool)
            ):
                valid_checks.append(check)
            references = self._unique_strings(
                check["command_ids"],
                f"{context}.command_ids",
                errors,
                identifiers=True,
            )
            if references is not None:
                missing = sorted(set(references) - set(command_records))
                if missing:
                    errors.append(f"{context}.command_ids are unknown: {missing!r}")
            output_references = self._unique_strings(
                check["output_ids"],
                f"{context}.output_ids",
                errors,
                identifiers=True,
            )
            if output_references is not None:
                missing_outputs = sorted(set(output_references) - set(output_records))
                if missing_outputs:
                    errors.append(
                        f"{context}.output_ids are unknown: {missing_outputs!r}"
                    )
            reason = check["reason"]
            if status == "passed" and reason is not None:
                errors.append(f"{context}.reason must be null when passed")
            if status in ("failed", "skipped") and (
                not isinstance(reason, str) or not reason
            ):
                errors.append(f"{context}.reason is required when {status}")
            if required is True and status == "passed":
                if not references:
                    errors.append(
                        f"{context} is required and passed but has no command evidence"
                    )
                else:
                    unsuccessful_commands = sorted(
                        command_id
                        for command_id in references
                        if command_id in command_records
                        and command_records[command_id].get("result") != "passed"
                    )
                    if unsuccessful_commands:
                        errors.append(
                            f"{context} references commands that did not pass: "
                            f"{unsuccessful_commands!r}"
                        )
                    appropriate_commands = [
                        command_records[command_id]
                        for command_id in references
                        if command_id in command_records
                        and category_is_valid
                        and self._command_matches_verification_category(
                            command_records[command_id], category
                        )
                    ]
                    if category_is_valid and not appropriate_commands:
                        errors.append(
                            f"{context} has no category-appropriate command"
                        )
                    if category == "build" and appropriate_commands:
                        configurations = {
                            command["argv"][command["argv"].index("-configuration") + 1]
                            for command in appropriate_commands
                            if "-configuration" in command.get("argv", [])
                            and command["argv"].index("-configuration") + 1
                            < len(command["argv"])
                        }
                        if configurations != {"Debug", "Release"}:
                            errors.append(
                                f"{context} must bind Debug and Release build commands"
                            )
                if not output_references:
                    errors.append(
                        f"{context} is required and passed but has no bound output evidence"
                    )
                elif category_is_valid:
                    expected_kinds = VERIFICATION_CATEGORY_OUTPUT_KINDS[category]
                    observed_kinds = {
                        output_records[output_id].get("kind")
                        for output_id in output_references
                        if output_id in output_records
                    }
                    if observed_kinds.isdisjoint(expected_kinds):
                        errors.append(
                            f"{context} lacks category-appropriate output evidence; "
                            f"expected one of {sorted(expected_kinds)!r}"
                        )
                    for output_id in output_references:
                        output = output_records.get(output_id)
                        if (
                            output is not None
                            and output.get("kind") in expected_kinds
                        ):
                            self._check_verification_artifact(
                                output,
                                category,
                                references or [],
                                context,
                                errors,
                            )
        if len(check_ids) != len(set(check_ids)):
            errors.append("verification check IDs must be unique")
        return valid_checks

    def _check_result(
        self,
        value: object,
        disposition_subjects: dict[str, set[str]],
        verification_checks: list[dict[str, Any]],
        errors: list[str],
    ) -> None:
        if not self._exact_keys(value, RESULT_KEYS, "result", errors):
            return
        assert isinstance(value, dict)
        status = value["status"]
        if status not in RESULT_STATUSES:
            errors.append("result.status is outside the closed vocabulary")
        disposition = value["disposition"]
        allowed_outcomes = (
            PHASE_OUTCOME_DISPOSITIONS.get(self.phase_id, {}).get(status)
            if isinstance(status, str)
            else None
        )
        if not isinstance(disposition, str) or (
            allowed_outcomes is None or disposition not in allowed_outcomes
        ):
            errors.append("result status/disposition pair is outside roadmap vocabulary")
        self._string(value["summary"], "result.summary", errors)
        phase_status_before = value["phase_status_before"]
        phase_status_after = value["phase_status_after"]
        if phase_status_before not in PHASE_STATUS_VALUES:
            errors.append("result.phase_status_before is outside the closed vocabulary")
        if phase_status_after not in PHASE_STATUS_VALUES:
            errors.append("result.phase_status_after is outside the closed vocabulary")
        canonical_status: object | None = None
        if self._canonical_roadmap is not None:
            phases = self._canonical_roadmap.get("phases")
            if isinstance(phases, list):
                matching = [
                    phase
                    for phase in phases
                    if isinstance(phase, dict) and phase.get("id") == self.phase_id
                ]
                if len(matching) == 1:
                    canonical_status = matching[0].get("status")
                else:
                    errors.append("phase is not uniquely defined in canonical roadmap")
            else:
                errors.append("canonical roadmap phases must be an array")
        if canonical_status is not None and phase_status_before != canonical_status:
            errors.append("result.phase_status_before differs from source roadmap")
        if status in ("passed", "diagnostic_only", "rejected"):
            if phase_status_before != "in_progress":
                errors.append(
                    "an accepted closure requires source phase status in_progress"
                )
            if phase_status_after != "passed":
                errors.append("a nonblocked accepted result must propose phase passed")
        elif status == "blocked" and phase_status_after != phase_status_before:
            errors.append(
                "a blocked result cannot invent an unspecified roadmap status transition"
            )
        result_dispositions = value["dispositions"]
        if not isinstance(result_dispositions, list):
            errors.append("result.dispositions must be an array")
        else:
            seen_subjects: set[str] = set()
            for index, record in enumerate(result_dispositions):
                context = f"result.dispositions[{index}]"
                if not self._exact_keys(
                    record, RESULT_DISPOSITION_KEYS, context, errors
                ):
                    continue
                assert isinstance(record, dict)
                subject_id = record["subject_id"]
                if not self._identifier(subject_id, f"{context}.subject_id", errors):
                    continue
                assert isinstance(subject_id, str)
                if subject_id in seen_subjects:
                    errors.append("result disposition subject IDs must be unique")
                seen_subjects.add(subject_id)
                allowed_values = disposition_subjects.get(subject_id)
                if allowed_values is None:
                    errors.append(f"{context}.subject_id was not preregistered")
                disposition_value = record["value"]
                if not self._identifier(
                    disposition_value, f"{context}.value", errors
                ):
                    continue
                assert isinstance(disposition_value, str)
                if allowed_values is not None and disposition_value not in allowed_values:
                    errors.append(f"{context}.value is outside the frozen vocabulary")
                self._string(record["reason"], f"{context}.reason", errors)
            if status != "blocked" and seen_subjects != set(disposition_subjects):
                errors.append(
                    "a nonblocked result must disposition every preregistered subject"
                )
        if status != "blocked" and any(
            check.get("required") is True and check.get("status") != "passed"
            for check in verification_checks
        ):
            errors.append("a nonblocked result requires every required check to pass")

    def _check_authorizations(self, value: object, errors: list[str]) -> None:
        if not self._exact_keys(
            value, AUTHORIZATION_KEYS, "authorizations", errors
        ):
            return
        assert isinstance(value, dict)
        records_by_side: dict[str, list[dict[str, Any]]] = {}
        for side in ("before", "after"):
            records = self._check_named_items(
                value[side],
                AUTHORIZATION_VALUE_KEYS,
                f"authorizations.{side}",
                errors,
            )
            records_by_side[side] = records
            for index, record in enumerate(records):
                self._string(
                    record["value"],
                    f"authorizations.{side}[{index}].value",
                    errors,
                )
        if self._canonical_roadmap is not None:
            canonical_authorizations = self._canonical_roadmap.get("authorizations")
            before = {
                item.get("id"): item.get("value")
                for item in records_by_side["before"]
                if isinstance(item.get("id"), str)
            }
            if before != canonical_authorizations:
                errors.append("authorizations.before differs from source roadmap")
            if value["before"] != value["after"]:
                errors.append(
                    "phase-evidence schema 1.0 does not authorize roadmap "
                    "authorization changes"
                )
            if value["before"] == value["after"] and value["proposed_decisions"]:
                errors.append(
                    "proposed authorization decisions require a bound "
                    "phase-specific authorization contract"
                )
        self._unique_strings(
            value["proposed_decisions"],
            "authorizations.proposed_decisions",
            errors,
        )

    def _check_phase_dependencies(
        self, result: object, authorizations: object, errors: list[str]
    ) -> None:
        if (
            self._canonical_roadmap is None
            or not isinstance(result, dict)
            or result.get("status") == "blocked"
        ):
            return
        phases = self._canonical_roadmap.get("phases")
        if not isinstance(phases, list):
            return
        statuses = {
            phase.get("id"): phase.get("status")
            for phase in phases
            if isinstance(phase, dict) and isinstance(phase.get("id"), str)
        }
        missing_predecessors = [
            phase_id
            for phase_id in PHASE_CLOSURE_PREDECESSORS.get(self.phase_id, ())
            if statuses.get(phase_id) != "passed"
        ]
        if missing_predecessors:
            errors.append(
                "phase closure predecessors are not passed: "
                f"{missing_predecessors!r}"
            )
        if self.phase_id == "R09" and isinstance(authorizations, dict):
            before = authorizations.get("before")
            before_map = {
                item.get("id"): item.get("value")
                for item in before
                if isinstance(before, list) and isinstance(item, dict)
            }
            if (
                before_map.get("core_ai_pixel_residual")
                != "authorized_for_r09_bounded_experiment"
            ):
                errors.append(
                    "R09 requires the accepted bounded-experiment authorization"
                )

    @staticmethod
    def _check_privacy(value: object, errors: list[str], context: str = "manifest") -> None:
        if isinstance(value, dict):
            for key, item in value.items():
                normalized_key = key.lower().replace("-", "_")
                if normalized_key in PRIVATE_EVIDENCE_KEYS:
                    errors.append(f"{context}.{key} is a prohibited private field")
                PhaseEvidenceVerifier._check_privacy(
                    item, errors, f"{context}.{key}"
                )
        elif isinstance(value, list):
            for index, item in enumerate(value):
                PhaseEvidenceVerifier._check_privacy(
                    item, errors, f"{context}[{index}]"
                )
        elif isinstance(value, str):
            if EMAIL_PATTERN.search(value):
                errors.append(f"{context} contains an email address")
            if PRIVATE_PATH_PATTERN.search(value):
                errors.append(f"{context} contains a private absolute path")
            if LABELED_PRIVATE_VALUE_PATTERN.search(value):
                errors.append(f"{context} contains a labeled private identifier")

    @staticmethod
    def _major_version(value: object) -> int | None:
        if not isinstance(value, str):
            return None
        match = re.match(r"^([0-9]+)(?:\.|$)", value)
        return int(match.group(1)) if match is not None else None

    def _check_r01_contract(
        self,
        manifest: dict[str, Any],
        disposition_subjects: dict[str, set[str]],
        command_records: dict[str, dict[str, Any]],
        output_paths: dict[str, str],
        verification_checks: list[dict[str, Any]],
        errors: list[str],
    ) -> None:
        hosts = manifest["hosts"] if isinstance(manifest["hosts"], list) else []
        host_source_commits = {
            host.get("source_commit")
            for host in hosts
            if isinstance(host, dict) and isinstance(host.get("source_commit"), str)
        }
        role_counts = {role: 0 for role in R01_ANCHOR_ROLES}
        role_hosts: dict[str, dict[str, Any]] = {}
        for host in hosts:
            if not isinstance(host, dict) or not isinstance(host.get("roles"), list):
                continue
            for role in host["roles"]:
                if not isinstance(role, str) or role not in role_counts:
                    errors.append(f"R01 host role is not a closed anchor: {role!r}")
                    continue
                role_counts[role] += 1
                role_hosts[role] = host
        duplicate_roles = sorted(
            role for role, count in role_counts.items() if count > 1
        )
        if duplicate_roles:
            errors.append(f"R01 anchor roles are assigned more than once: {duplicate_roles!r}")

        result = manifest["result"] if isinstance(manifest["result"], dict) else {}
        nonblocked = result.get("status") != "blocked"
        if nonblocked:
            if len(host_source_commits) != 1:
                errors.append(
                    "R01 anchor reports must share one published implementation commit"
                )
            missing_roles = sorted(
                role for role, count in role_counts.items() if count != 1
            )
            if missing_roles:
                errors.append(f"R01 is missing required anchor roles: {missing_roles!r}")

        oldest = role_hosts.get("oldest-supported")
        if oldest is not None:
            os_version = oldest.get("os_version")
            if not isinstance(os_version, str) or not (
                os_version == "15.4" or os_version.startswith("15.4.")
            ):
                errors.append("R01 oldest-supported anchor must run macOS 15.4")
            chip = oldest.get("chip")
            if not isinstance(chip, str) or not chip.startswith("Apple M"):
                errors.append("R01 oldest-supported anchor must be Apple Silicon")
            if "apple_silicon" not in oldest.get("hardware_classes", []):
                errors.append(
                    "R01 oldest-supported anchor must record apple_silicon hardware"
                )

        m3_air = role_hosts.get("m3-air")
        if m3_air is not None:
            if m3_air.get("chip") != "Apple M3":
                errors.append("R01 m3-air anchor must record chip Apple M3")
            if self._major_version(m3_air.get("os_version")) != 26:
                errors.append("R01 m3-air anchor must run macOS 26")
            if "macbook_air" not in m3_air.get("hardware_classes", []):
                errors.append("R01 m3-air anchor must record macbook_air hardware")

        pro_max = role_hosts.get("pro-max")
        if pro_max is not None:
            chip = pro_max.get("chip")
            if not isinstance(chip, str) or re.fullmatch(
                r"Apple M[0-9]+ (?:Pro|Max)", chip
            ) is None:
                errors.append("R01 pro-max anchor must record an Apple Pro/Max chip")
            if "pro_max_tier" not in pro_max.get("hardware_classes", []):
                errors.append("R01 pro-max anchor must record pro_max_tier hardware")

        core_ai = role_hosts.get("core-ai")
        if core_ai is not None:
            if (self._major_version(core_ai.get("os_version")) or 0) < 27:
                errors.append("R01 core-ai anchor must run macOS 27 or newer")
            if (self._major_version(core_ai.get("xcode_version")) or 0) < 27:
                errors.append("R01 core-ai anchor must run Xcode 27 or newer")
            if (self._major_version(core_ai.get("sdk_version")) or 0) < 27:
                errors.append("R01 core-ai anchor must use SDK 27 or newer")
            if "core_ai_capable" not in core_ai.get("hardware_classes", []):
                errors.append(
                    "R01 core-ai anchor must record core_ai_capable hardware"
                )

        if set(disposition_subjects) != set(R01_CAPABILITY_IDS):
            errors.append("R01 disposition subjects must be exactly A01-A18")
        for subject_id, allowed_values in disposition_subjects.items():
            if subject_id in R01_CAPABILITY_IDS and allowed_values != set(
                R01_CAPABILITY_DISPOSITIONS
            ):
                errors.append(
                    f"R01 {subject_id} disposition vocabulary differs from the handoff"
                )

        if nonblocked:
            missing_outputs = sorted(
                R01_REQUIRED_OUTPUT_PATHS - set(output_paths.values())
            )
            if missing_outputs:
                errors.append(f"R01 required outputs are missing: {missing_outputs!r}")
            for source_path in R01_REQUIRED_SOURCE_PATHS:
                source_result = self.git_bytes(
                    "show", f"{self._source_commit}:{source_path}"
                )
                if source_result.returncode != 0:
                    errors.append(
                        f"R01 required source deliverable is absent at source.commit: "
                        f"{source_path}"
                    )
            has_r01_check = any(
                command.get("argv")
                == ["python3", "Scripts/r01_capabilities.py", "--check"]
                and command.get("result") == "passed"
                for command in manifest["commands"]
                if isinstance(command, dict)
            )
            if not has_r01_check:
                errors.append(
                    "R01 requires a passing python3 Scripts/r01_capabilities.py --check command"
                )

        role_host_ids = {
            role: host.get("host_id")
            for role, host in role_hosts.items()
            if isinstance(host.get("host_id"), str)
        }
        for command_id, command in command_records.items():
            flags = {
                item.get("name"): item.get("value")
                for item in command.get("environment_flags", [])
                if isinstance(item, dict)
                and isinstance(item.get("name"), str)
            }
            live_enabled = flags.get("MIRMIR_R01_LIVE_PROBES") == "1"
            argv = command.get("argv")
            uses_runner = (
                isinstance(argv, list)
                and bool(argv)
                and argv[0] == "Scripts/run-r01-capability-probe.sh"
            )
            runner_invocation = (
                uses_runner
                and len(argv) == 5
                and argv[1] == "--anchor"
                and argv[3] == "--output"
            )
            if live_enabled and not runner_invocation:
                errors.append(
                    f"R01 live command {command_id!r} does not use the sole live runner"
                )
            if uses_runner and not runner_invocation:
                errors.append(
                    f"R01 runner command {command_id!r} has invalid arguments"
                )
            if uses_runner and not live_enabled:
                errors.append(
                    f"R01 runner command {command_id!r} lacks the live-probe flag"
                )
            if runner_invocation:
                anchor = argv[2]
                if anchor not in R01_ANCHOR_OUTPUT_PATHS:
                    errors.append(
                        f"R01 runner command {command_id!r} uses an invalid anchor"
                    )
                else:
                    if argv[4] != R01_ANCHOR_OUTPUT_PATHS[anchor]:
                        errors.append(
                            f"R01 runner command {command_id!r} uses the wrong output path"
                        )
                    if command.get("host_id") != role_host_ids.get(anchor):
                        errors.append(
                            f"R01 runner command {command_id!r} does not use the "
                            "assigned anchor host"
                        )

        if nonblocked:
            for anchor, output_path in R01_ANCHOR_OUTPUT_PATHS.items():
                expected_argv = [
                    "Scripts/run-r01-capability-probe.sh",
                    "--anchor",
                    anchor,
                    "--output",
                    output_path,
                ]
                matching_commands = [
                    command
                    for command in command_records.values()
                    if command.get("argv") == expected_argv
                    and command.get("host_id") == role_host_ids.get(anchor)
                    and command.get("result") == "passed"
                    and {
                        item.get("name"): item.get("value")
                        for item in command.get("environment_flags", [])
                        if isinstance(item, dict)
                    }.get("MIRMIR_R01_LIVE_PROBES")
                    == "1"
                ]
                if len(matching_commands) != 1:
                    errors.append(
                        f"R01 requires exactly one passing live-runner command for "
                        f"anchor {anchor!r} on its assigned host"
                    )

        required_passed_categories = {
            check.get("category")
            for check in verification_checks
            if check.get("required") is True and check.get("status") == "passed"
        }
        if nonblocked:
            missing_categories = sorted(
                COMMON_REQUIRED_VERIFICATION_CATEGORIES - required_passed_categories
            )
            if missing_categories:
                errors.append(
                    f"required verification categories are missing: {missing_categories!r}"
                )

    def _check_evidence_files(self, errors: list[str]) -> None:
        phase_slug = self.phase_id.lower()
        evidence_roots = (
            self.root / "docs/roadmaps/evidence" / phase_slug,
            self.root / "project-notes/evidence" / phase_slug,
        )
        exempt_paths: set[str] = set()
        for path in (self.manifest_path, self.summary_path):
            try:
                exempt_paths.add(path.resolve().relative_to(self.root).as_posix())
            except (OSError, ValueError):
                continue
        observed: dict[str, int] = {}
        for evidence_root in evidence_roots:
            if not evidence_root.exists():
                continue
            for path in evidence_root.rglob("*"):
                if path.is_dir():
                    continue
                relative = path.relative_to(self.root).as_posix()
                if path.is_symlink() or not path.is_file():
                    errors.append(f"phase evidence path is not a regular file: {relative}")
                    continue
                size = path.stat().st_size
                observed[relative] = size
                if size > MAX_EVIDENCE_FILE_BYTES:
                    errors.append(f"phase evidence file exceeds 25 MiB: {relative}")
                if path.read_bytes().startswith(
                    b"version https://git-lfs.github.com/spec/v1\n"
                ):
                    errors.append(f"phase evidence file is a Git LFS pointer: {relative}")
                if relative not in self._bound_paths and relative not in exempt_paths:
                    errors.append(f"phase evidence file is not manifest-bound: {relative}")
        for relative, (size, _) in self._bound_paths.items():
            observed.setdefault(relative, size)
        total_size = sum(observed.values())
        if total_size > MAX_PHASE_EVIDENCE_BYTES:
            errors.append("phase evidence exceeds the 100 MiB per-phase limit")

    def check(self, *, include_summary: bool = True) -> list[str]:
        errors: list[str] = []
        self._bound_paths = {}
        self._privacy_checked_paths = set()
        self._source_commit = None
        self._canonical_roadmap = None
        self._schema = None
        self._check_schema(errors)
        try:
            manifest = read_json(self.manifest_path)
        except (OSError, ValueError, json.JSONDecodeError) as error:
            errors.append(f"phase-evidence manifest cannot be read: {error}")
            return errors
        if not self._exact_keys(manifest, TOP_LEVEL_KEYS, "manifest", errors):
            return errors
        if self._schema is None:
            return errors
        schema_errors = validate_json_schema_instance(self._schema, manifest)
        if schema_errors:
            errors.extend(f"manifest schema error: {error}" for error in schema_errors)
            return errors
        self._check_privacy(manifest, errors)
        if manifest["schema_version"] != SCHEMA_VERSION:
            errors.append(f"schema_version must be {SCHEMA_VERSION}")
        if not isinstance(manifest["roadmap_version"], str) or SEMVER_PATTERN.fullmatch(
            manifest["roadmap_version"]
        ) is None:
            errors.append("roadmap_version must be a semantic version")
        if self.phase_id not in PHASE_IDS:
            errors.append(f"requested phase must be one of {PHASE_IDS!r}")
        if manifest["phase_id"] != self.phase_id:
            errors.append("manifest phase_id differs from --phase")
        self._check_source(manifest["source"], errors)
        if (
            self._canonical_roadmap is not None
            and manifest["roadmap_version"]
            != self._canonical_roadmap.get("roadmap_version")
        ):
            errors.append("roadmap_version differs from source roadmap")

        hosts = manifest["hosts"]
        host_ids: list[str] = []
        if not isinstance(hosts, list):
            errors.append("hosts must be an array")
        else:
            for index, host in enumerate(hosts):
                host_id = self._check_host(host, index, errors)
                if host_id is not None:
                    host_ids.append(host_id)
        if len(host_ids) != len(set(host_ids)):
            errors.append("host IDs must be unique")

        disposition_subjects = self._check_preregistration(
            manifest["preregistration"], errors
        )
        command_records = self._check_commands(
            manifest["commands"], set(host_ids), errors
        )
        output_records = self._check_outputs(manifest["outputs"], errors)
        output_paths = {
            output_id: PurePosixPath(output["binding"]["path"]).as_posix()
            for output_id, output in output_records.items()
            if isinstance(output.get("binding"), dict)
            and isinstance(output["binding"].get("path"), str)
        }
        verification_checks = self._check_verification(
            manifest["verification"], command_records, output_records, errors
        )
        self._check_result(
            manifest["result"], disposition_subjects, verification_checks, errors
        )
        self._check_authorizations(manifest["authorizations"], errors)
        self._check_phase_dependencies(
            manifest["result"], manifest["authorizations"], errors
        )
        self._unique_strings(manifest["limitations"], "limitations", errors)

        if self.phase_id == "R01":
            self._check_r01_contract(
                manifest,
                disposition_subjects,
                command_records,
                output_paths,
                verification_checks,
                errors,
            )

        result_status = (
            manifest["result"].get("status")
            if isinstance(manifest["result"], dict)
            else None
        )
        if result_status != "blocked":
            if not host_ids:
                errors.append("a nonblocked result requires at least one host")
            if not manifest["commands"]:
                errors.append("a nonblocked result requires at least one command")
            if not manifest["outputs"]:
                errors.append("a nonblocked result requires at least one output")

        self._check_evidence_files(errors)

        if include_summary and not errors:
            expected_summary = render_phase_evidence(manifest)
            try:
                actual_summary = self.summary_path.read_text(encoding="utf-8")
            except OSError as error:
                errors.append(f"generated phase-evidence summary cannot be read: {error}")
            else:
                if actual_summary != expected_summary:
                    errors.append("generated phase-evidence summary is stale")
        return errors


def parse_arguments(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--phase", required=True, help="Roadmap phase ID, e.g. R01")
    parser.add_argument("--root", type=Path, default=Path.cwd())
    parser.add_argument("--manifest", type=Path)
    parser.add_argument("--summary", type=Path)
    parser.add_argument("--schema", type=Path)
    actions = parser.add_mutually_exclusive_group(required=True)
    actions.add_argument("--check", action="store_true")
    actions.add_argument("--write-summary", action="store_true")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    arguments = parse_arguments(argv or sys.argv[1:])
    root = arguments.root.resolve()

    def resolve_override(path: Path | None) -> Path | None:
        if path is None:
            return None
        return path if path.is_absolute() else root / path

    verifier = PhaseEvidenceVerifier(
        root,
        arguments.phase,
        manifest_path=resolve_override(arguments.manifest),
        summary_path=resolve_override(arguments.summary),
        schema_path=resolve_override(arguments.schema),
    )
    errors = verifier.check(include_summary=not arguments.write_summary)
    if errors:
        for error in errors:
            print(f"ERROR: {error}", file=sys.stderr)
        return 1
    if arguments.write_summary:
        manifest = read_json(verifier.manifest_path)
        verifier.summary_path.parent.mkdir(parents=True, exist_ok=True)
        verifier.summary_path.write_text(
            render_phase_evidence(manifest), encoding="utf-8"
        )
        print(f"Wrote {verifier.summary_path.relative_to(root)}")
    else:
        print(f"{verifier.phase_id} phase evidence: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
