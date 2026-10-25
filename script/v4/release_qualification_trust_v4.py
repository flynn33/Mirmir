#!/usr/bin/env python3
"""Build the externally pinned trust root for final v4 qualification.

This builder is intentionally not part of the trust decision. An operator or
CI control plane reviews the described files, pins the printed manifest hash
outside the candidate/evidence tree, and supplies that hash to
``release_qualification_v4.py``. The evaluator independently recomputes every
descriptor before importing any replay helper.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
from typing import Any, Mapping, Sequence


SCHEMA = "mirmir-ash-v4-release-qualification-trust-root-v1"
HELPERS: tuple[tuple[str, str, str], ...] = (
    (
        "support_matrix_replay",
        "support_matrix_v4.py",
        "support_matrix_v4_for_release_qualification",
    ),
    (
        "cpu_metal_parity_replay",
        "cpu_metal_parity_v4.py",
        "cpu_metal_parity_v4_for_release_qualification",
    ),
    ("p05_baseline_replay", "p05_baseline_v4.py", "p05_baseline_v4"),
    (
        "quality_raw_plane_replay",
        "quality_gate_v4.py",
        "quality_gate_v4_for_release_qualification",
    ),
)

SCHEMA_PHASE2 = "mirmir-ash-v4-release-qualification-trust-root-v2"
CHROMA_HELPER = ("chroma_geometry_replay", "chroma_geometry_v4.py", "chroma_geometry_v4")
LEGACY_REPLAY_SOURCE_SHA256 = {'support_matrix_replay': '23c0d874e27b7eb37702d18612a969ede2cfda61ed0f968e7c078fd402511403', 'cpu_metal_parity_replay': 'ed0f88fd607268a817159554afbe39a60fca9d4ef8a7c74e44966dd0e2a10a3b', 'p05_baseline_replay': 'd79eff3f6bd7057460546b910cfa7654c9e846d4ff524e7b4ce78be78f6c929f', 'quality_raw_plane_replay': '2c5b0e5a40adc4f016d9346805f2db247ed1cd8a22e3abf26a2c87d3309ac4c8'}


def phase2_release_profile(contract: Mapping[str, Any]) -> bool:
    schemas = contract.get("evidenceSchemas", {})
    pair = (schemas.get("quality"), schemas.get("cpu_metal_parity"))
    if pair == ("mirmir-ash-v4-quality-report-v1", "mirmir-ash-v4-cpu-metal-parity-report-v2"):
        return False
    if pair == ("mirmir-ash-v4-quality-report-v2", "mirmir-ash-v4-cpu-metal-parity-report-v3"):
        return True
    raise ValueError("release quality/parity envelope profile is mixed or unsupported")


def trusted_helper_contract(contract: Mapping[str, Any]):
    return (CHROMA_HELPER, *HELPERS) if phase2_release_profile(contract) else HELPERS


VALIDATORS: Mapping[str, str] = {
    "quality": "validate_quality",
    "same_scope_performance": "validate_performance",
    "cpu_metal_parity": "validate_parity",
    "media_preservation": "validate_preservation",
    "recovery": "validate_recovery",
    "p06_reproduction": "validate_p06",
    "support_matrix": "validate_support",
    "notarized_smoke": "validate_smoke",
}
REPLAY_HELPERS: Mapping[str, tuple[str, ...]] = {
    "quality": ("p05_baseline_replay", "quality_raw_plane_replay"),
    "same_scope_performance": (),
    "cpu_metal_parity": ("cpu_metal_parity_replay",),
    "media_preservation": (),
    "recovery": (),
    "p06_reproduction": (),
    "support_matrix": ("support_matrix_replay",),
    "notarized_smoke": (),
}


def canonical_bytes(value: Any) -> bytes:
    return json.dumps(
        value,
        ensure_ascii=False,
        allow_nan=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def descriptor(path: Path, repository_relative_path: str) -> dict[str, Any]:
    resolved = path.expanduser().resolve(strict=True)
    if path.is_symlink() or not resolved.is_file():
        raise ValueError(f"trusted tool is not a regular non-symlink file: {path}")
    return {
        "repositoryRelativePath": repository_relative_path,
        "byteCount": resolved.stat().st_size,
        "sha256": sha256(resolved),
    }


def trusted_tool_set_sha(entries: Sequence[Mapping[str, Any]]) -> str:
    return sha256_bytes(
        b"mirmir-release-qualification-tool-set-v1\0"
        + canonical_bytes(list(entries))
    )


def build_trust_root(
    script_directory: Path,
    contract_path: Path,
) -> dict[str, Any]:
    script_directory = script_directory.expanduser().resolve(strict=True)
    contract_path = contract_path.expanduser().resolve(strict=True)
    contract = json.loads(contract_path.read_text(encoding="utf-8"))
    roles = contract.get("requiredEvidenceRoles")
    schemas = contract.get("evidenceSchemas")
    if (
        not isinstance(roles, list)
        or len(roles) != len(set(roles))
        or set(roles) != set(VALIDATORS)
        or not isinstance(schemas, dict)
        or set(schemas) != set(VALIDATORS)
    ):
        raise ValueError("release contract role/schema set is not exhaustive")

    evaluator = descriptor(
        script_directory / "release_qualification_v4.py",
        "script/v4/release_qualification_v4.py",
    )
    contract_descriptor = descriptor(
        contract_path,
        "script/v4/release-qualification-contract-v1.json",
    )
    phase2 = phase2_release_profile(contract)
    helper_contract = trusted_helper_contract(contract)
    helpers = [
        {
            "role": role,
            "moduleName": module_name,
            **descriptor(
                script_directory / filename,
                f"script/v4/{filename}",
            ),
        }
        for role, filename, module_name in helper_contract
    ]
    if not phase2 and any(row["sha256"] != LEGACY_REPLAY_SOURCE_SHA256[row["role"]] for row in helpers):
        raise ValueError("historical trust root requires its exact four-helper source closure")
    if phase2:
        by_role = {row["role"]: row["sha256"] for row in helpers}
        if (by_role["chroma_geometry_replay"] != contract["qualityLockedSources"]["chromaGeometryValidatorSHA256"]
                or by_role["chroma_geometry_replay"] != contract["parityLockedSources"]["chromaGeometryValidatorSHA256"]
                or by_role["quality_raw_plane_replay"] != contract["qualityLockedSources"]["metricToolSHA256"]
                or by_role["cpu_metal_parity_replay"] != contract["parityLockedSources"]["evaluatorSHA256"]):
            raise ValueError("fresh trust root helpers differ from release source locks")
    dispatch = [
        {
            "role": role,
            "validator": VALIDATORS[role],
            "evidenceSchema": schemas[role],
            "replayHelperRoles": (["chroma_geometry_replay"] if phase2 and role in {"quality", "cpu_metal_parity"} else []) + list(REPLAY_HELPERS[role]),
        }
        for role in roles
    ]
    tool_entries = [
        {"role": "qualification_evaluator", **evaluator},
        {"role": "release_contract", **contract_descriptor},
        *helpers,
    ]
    return {
        "schemaVersion": SCHEMA_PHASE2 if phase2 else SCHEMA,
        "hashAlgorithm": "sha256",
        "evaluator": evaluator,
        "contract": contract_descriptor,
        "helpers": helpers,
        "roleDispatch": dispatch,
        "trustedToolSetSHA256": trusted_tool_set_sha(tool_entries),
    }


def write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(value, indent=2, sort_keys=True, allow_nan=False) + "\n",
        encoding="utf-8",
    )


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--script-directory",
        type=Path,
        default=Path(__file__).resolve().parent,
    )
    parser.add_argument("--contract", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    trust_root = build_trust_root(
        arguments.script_directory,
        arguments.contract,
    )
    output = arguments.output.expanduser().resolve()
    write_json(output, trust_root)
    print(f"{sha256(output)}  {output}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, KeyError, TypeError, json.JSONDecodeError) as error:
        print(f"trust-root construction failed closed: {error}")
        raise SystemExit(2)
