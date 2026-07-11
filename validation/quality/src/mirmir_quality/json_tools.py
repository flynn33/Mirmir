"""Canonical JSON, hashing, and project-owned schema validation."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
from typing import Any, Dict, Mapping

import jsonschema


def canonical_json_bytes(value: Any) -> bytes:
    return json.dumps(
        value,
        ensure_ascii=False,
        allow_nan=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")


def canonical_sha256(value: Any) -> str:
    return hashlib.sha256(canonical_json_bytes(value)).hexdigest()


def manifest_sha256(value: Mapping[str, Any], field: str = "manifest_sha256") -> str:
    payload = dict(value)
    payload.pop(field, None)
    return canonical_sha256(payload)


def read_json(path: Path) -> Any:
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    encoded = json.dumps(
        value,
        ensure_ascii=False,
        allow_nan=False,
        sort_keys=True,
        indent=2,
    )
    path.write_text(encoded + "\n", encoding="utf-8")


def validate_schema(instance: Any, schema_path: Path) -> None:
    schema = read_json(schema_path)
    validator = jsonschema.Draft202012Validator(
        schema,
        format_checker=jsonschema.FormatChecker(),
    )
    errors = sorted(validator.iter_errors(instance), key=lambda error: list(error.absolute_path))
    if errors:
        descriptions = []
        for error in errors:
            location = "/".join(str(item) for item in error.absolute_path) or "<root>"
            descriptions.append(f"{location}: {error.message}")
        raise ValueError("schema validation failed: " + "; ".join(descriptions))
