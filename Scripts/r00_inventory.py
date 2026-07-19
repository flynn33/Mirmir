#!/usr/bin/env python3
"""Validate and render the R00 exact-source inventory."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys
from typing import Any


DEFAULT_POLICY_PATH = Path(".github/roadmap-alignment-policy.json")


def read_json(path: Path) -> dict[str, Any]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError("top-level JSON value must be an object")
    return value


def canonical_json_sha256(value: object) -> str:
    payload = json.dumps(
        value,
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=False,
    ).encode("utf-8")
    return hashlib.sha256(payload).hexdigest()


def markdown_cell(value: object) -> str:
    return str(value).replace("|", "\\|").replace("\n", " ")


def render_inventory(inventory: dict[str, Any]) -> str:
    lines = [
        "# R00 Current-Source Inventory",
        "",
        f"- **Inventory status:** `{inventory['status']}`",
        f"- **Roadmap version:** `{inventory['roadmap_version']}`",
        f"- **Recorded date:** `{inventory['recorded_date']}`",
        f"- **Git object format:** `{inventory['git_object_format']}`",
        f"- **Baseline checkpoint:** `{inventory['baseline_checkpoint']}`",
        f"- **Baseline tree:** `{inventory['baseline_tree_git_object_id']}`",
        f"- **Source checkpoint:** `{inventory['source_checkpoint']}`",
        f"- **Source tree:** `{inventory['source_tree_git_object_id']}`",
        f"- **Checkpoint role:** {inventory['source_checkpoint_role']}",
        "",
        "This summary is generated from `r00-current-source-inventory.json`. "
        "Baseline Git object IDs resolve at the baseline checkpoint; R00 checkpoint "
        "IDs resolve at the exact PR 2 merge commit.",
        "",
        "## C01-C11 Classification",
        "",
        "| ID | Capability | Disposition | Retained role | Future phase |",
        "| --- | --- | --- | --- | --- |",
    ]
    for entry in inventory["entries"]:
        lines.append(
            "| "
            f"`{markdown_cell(entry['id'])}` | "
            f"{markdown_cell(entry['name'])} | "
            f"`{markdown_cell(entry['disposition'])}` | "
            f"{markdown_cell(entry['retained_role'])} | "
            f"`{markdown_cell(entry['future_phase'])}` |"
        )
    for entry in inventory["entries"]:
        baseline_sources = entry["baseline_sources"]
        current_sources = entry["sources"]
        baseline_by_path = {source["path"]: source for source in baseline_sources}
        current_by_path = {source["path"]: source for source in current_sources}
        ordered_paths = [source["path"] for source in baseline_sources]
        ordered_paths.extend(
            source["path"]
            for source in current_sources
            if source["path"] not in baseline_by_path
        )
        lines.extend(
            [
                "",
                f"### {entry['id']} — {entry['name']}",
                "",
                "| Exact path | Transition | Baseline object | R00 checkpoint object |",
                "| --- | --- | --- | --- |",
            ]
        )
        for path in ordered_paths:
            baseline = baseline_by_path.get(path)
            current = current_by_path.get(path)
            if baseline is None:
                transition = "added"
            elif current is None:
                transition = "removed"
            elif baseline == current:
                transition = "unchanged"
            else:
                transition = "changed"
            baseline_object = (
                f"`{baseline['object_type']} {baseline['git_object_id']}`"
                if baseline is not None
                else "—"
            )
            current_object = (
                f"`{current['object_type']} {current['git_object_id']}`"
                if current is not None
                else "—"
            )
            lines.append(
                f"| `{markdown_cell(path)}` | `{transition}` | "
                f"{baseline_object} | {current_object} |"
            )

    lines.extend(
        [
            "",
            "## Retire or Replace",
            "",
            "| Exact path | Rationale | Phase |",
            "| --- | --- | --- |",
        ]
    )
    for item in inventory["retire_or_replace"]:
        lines.append(
            f"| `{markdown_cell(item['path'])}` | "
            f"{markdown_cell(item['reason'])} | `{markdown_cell(item['phase'])}` |"
        )

    lines.extend(["", "## Missing Roadmap Inputs", ""])
    for path in inventory["missing_roadmap_inputs"]:
        lines.append(f"- `{path}` — absent from the source checkpoint")

    lines.extend(["", "## Roadmap Input Resolutions", ""])
    for item in inventory["roadmap_input_resolutions"]:
        lines.append(
            f"- `{item['roadmap_reference']}` resolves to "
            f"`{item['tracked_path']}` at Git object `{item['git_object_id']}` "
            f"(`{item['resolution']}`)."
        )
    lines.extend(
        [
            "",
            "## Official Evidence Boundary",
            "",
            inventory["official_evidence_boundary"],
        ]
    )
    lines.extend(["", "## Other Absent Historical Paths", ""])
    for path in inventory["absent_historical_paths"]:
        lines.append(f"- `{path}` — absent from the source checkpoint")

    external = inventory["external_p06_evidence"]
    gib = int(external["size_bytes"]) / (1024**3)
    gb = int(external["size_bytes"]) / 1_000_000_000
    lines.extend(
        [
            "",
            "## External P06 Evidence Boundary",
            "",
            external["boundary"],
            "",
            f"- Receipt: `{external['receipt_path']}`",
            f"- Receipt Git object: `{external['receipt_git_object_id']}`",
            f"- Receipt-bound external root: `{external['external_root']}`",
            f"- Receipt-bound tree: `{external['file_count']}` files, "
            f"`{external['size_bytes']}` bytes ({gb:.2f} GB decimal; {gib:.2f} GiB), "
            f"SHA-256 `{external['tree_sha256']}`",
            f"- Local tree available: `{str(external['local_tree_available']).lower()}`",
            f"- Bytes reopened for R00: `{str(external['bytes_reopened_for_r00']).lower()}`",
            "",
            "## Historical Preservation Identities",
            "",
            "| Exact path | Git object type | Git object ID |",
            "| --- | --- | --- |",
        ]
    )
    for item in inventory["historical_preservation"]:
        lines.append(
            f"| `{markdown_cell(item['path'])}` | "
            f"`{markdown_cell(item['object_type'])}` | "
            f"`{markdown_cell(item['git_object_id'])}` |"
        )

    holdout = inventory["holdout_boundary"]
    lines.extend(
        [
            "",
            "## Holdout Boundary",
            "",
            f"- Pixel access authorized: `{str(holdout['pixel_access_authorized']).lower()}`",
            f"- Verification scope: {holdout['verification_scope']}",
            f"- Physical sparsebundle verified: `{str(holdout['physical_sparsebundle_verified']).lower()}`",
            f"- Keychain item verified: `{str(holdout['keychain_item_verified']).lower()}`",
        ]
    )
    if "holdout_verification" in inventory:
        verification = inventory["holdout_verification"]
        lines.extend(
            [
                f"- Sealed-ledger path: `{verification['sealed_ledger_path']}`",
                f"- Attestation path: `{verification['attestation_path']}`",
                f"- Tracked mounted value: `{str(verification['mounted']).lower()}`",
                f"- Tracked status: `{verification['status']}`",
                f"- Tracked access count: `{verification['access_count']}`",
                f"- Pixel content included: `{str(verification['pixel_content_included']).lower()}`",
                f"- Sealed-ledger SHA-256: `{verification['sealed_ledger_sha256']}`",
                f"- Attestation SHA-256: `{verification['attestation_sha256']}`",
            ]
        )
    if "legacy_process_check" in inventory:
        process_check = inventory["legacy_process_check"]
        lines.extend(
            [
                "",
                "## Legacy Process Check",
                "",
                f"- Checked at: `{process_check['checked_at']}`",
                f"- Method: {process_check['method']}",
                "- Command patterns:",
            ]
        )
        for pattern in process_check["command_patterns"]:
            lines.append(f"  - `{pattern}`")
        lines.extend(
            [
                f"- Matching processes: `{process_check['matching_process_count']}`",
                f"- Scope: {process_check['scope']}",
            ]
        )
    return "\n".join(lines) + "\n"


class InventoryVerifier:
    def __init__(
        self,
        root: Path,
        policy_path: Path = DEFAULT_POLICY_PATH,
        inventory_path: Path | None = None,
        markdown_path: Path | None = None,
    ) -> None:
        self.root = root.resolve()
        self.policy_path = self._resolve(policy_path)
        self.policy = read_json(self.policy_path)["r00_inventory"]
        self.inventory_path = self._resolve(
            inventory_path or Path(self.policy["json_path"])
        )
        self.markdown_path = self._resolve(
            markdown_path or Path(self.policy["markdown_path"])
        )
        self.errors: list[str] = []

    def _resolve(self, path: Path) -> Path:
        return path if path.is_absolute() else self.root / path

    def add_error(self, message: str) -> None:
        self.errors.append(message)

    def git(self, *arguments: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["git", *arguments],
            cwd=self.root,
            check=False,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )

    def git_bytes(self, *arguments: str) -> subprocess.CompletedProcess[bytes]:
        return subprocess.run(
            ["git", *arguments],
            cwd=self.root,
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )

    @staticmethod
    def valid_relative_path(value: object) -> bool:
        if not isinstance(value, str) or not value or "\x00" in value:
            return False
        path = PurePosixPath(value)
        return not path.is_absolute() and ".." not in path.parts and not value.startswith("-")

    def object_at(self, commit: str, path: str) -> tuple[str, str] | None:
        resolved = self.git("rev-parse", "--verify", f"{commit}:{path}")
        if resolved.returncode != 0:
            return None
        object_id = resolved.stdout.strip()
        object_type = self.git("cat-file", "-t", object_id)
        if object_type.returncode != 0:
            return None
        return object_type.stdout.strip(), object_id

    def blob_at(self, commit: str, path: str) -> bytes | None:
        completed = self.git_bytes("show", f"{commit}:{path}")
        return completed.stdout if completed.returncode == 0 else None

    def json_blob_at(self, commit: str, path: str) -> dict[str, Any] | None:
        payload = self.blob_at(commit, path)
        if payload is None:
            return None
        try:
            value = json.loads(payload.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            return None
        return value if isinstance(value, dict) else None

    def verify_checkpoint(
        self,
        *,
        label: str,
        commit: object,
        recorded_tree: object,
    ) -> tuple[str, str] | None:
        if not isinstance(commit, str) or not re.fullmatch(r"[0-9a-f]{40}", commit):
            self.add_error(f"{label} checkpoint must be a full lowercase 40-hex commit")
            return None
        if self.git("cat-file", "-e", f"{commit}^{{commit}}").returncode != 0:
            self.add_error(f"{label} checkpoint commit is unavailable: {commit}")
            return None
        tree = self.git("rev-parse", "--verify", f"{commit}^{{tree}}")
        if tree.returncode != 0:
            self.add_error(f"{label} checkpoint tree cannot be resolved")
            return None
        actual_tree = tree.stdout.strip()
        if recorded_tree != actual_tree:
            self.add_error(f"{label} tree Git object ID differs from {label} checkpoint")
        return commit, actual_tree

    def verify_sources(
        self,
        *,
        entries: list[object],
        source_key: str,
        checkpoint: str,
        label: str,
    ) -> None:
        seen_paths: set[tuple[str, str]] = set()
        for entry in entries:
            if not isinstance(entry, dict):
                self.add_error("every inventory entry must be an object")
                continue
            entry_id = str(entry.get("id"))
            sources = entry.get(source_key)
            if not isinstance(sources, list) or not sources:
                self.add_error(f"{entry_id}: {source_key} must be a non-empty array")
                continue
            for source in sources:
                if not isinstance(source, dict):
                    self.add_error(f"{entry_id}: every {label} source must be an object")
                    continue
                if set(source) != {"path", "object_type", "git_object_id"}:
                    self.add_error(
                        f"{entry_id}: {label} source records must contain only path, "
                        "object_type, and git_object_id"
                    )
                path = source.get("path")
                if not self.valid_relative_path(path):
                    self.add_error(f"{entry_id}: invalid relative {label} source path {path!r}")
                    continue
                key = (entry_id, path)
                if key in seen_paths:
                    self.add_error(f"{entry_id}: duplicate {label} source path {path}")
                seen_paths.add(key)
                actual = self.object_at(checkpoint, path)
                if actual is None:
                    self.add_error(f"{entry_id}: path is absent at {label} checkpoint: {path}")
                    continue
                expected_type = source.get("object_type")
                expected_object = source.get("git_object_id")
                if actual[0] != expected_type:
                    self.add_error(
                        f"{entry_id}: {label} object type differs for {path}: "
                        f"expected {expected_type!r}, found {actual[0]!r}"
                    )
                if actual[1] != expected_object:
                    self.add_error(
                        f"{entry_id}: {label} Git object ID differs for {path}: "
                        f"expected {expected_object!r}, found {actual[1]!r}"
                    )

    def check(self) -> list[str]:
        self.errors = []
        try:
            inventory = read_json(self.inventory_path)
        except (OSError, ValueError, json.JSONDecodeError) as exc:
            return [f"inventory JSON is invalid: {exc}"]

        required_top_level_keys = set(self.policy["required_top_level_keys"])
        if set(inventory) != required_top_level_keys:
            self.add_error(
                "inventory top-level fields differ from the closed schema: "
                f"expected {sorted(required_top_level_keys)!r}, "
                f"found {sorted(inventory)!r}"
            )
        if inventory.get("schema_version") != self.policy["inventory_schema_version"]:
            self.add_error("inventory schema version differs from policy")
        if inventory.get("inventory_id") != self.policy["inventory_id"]:
            self.add_error("inventory ID differs from policy")
        if inventory.get("recorded_date") != self.policy["recorded_date"]:
            self.add_error("inventory recorded date differs from policy")
        if inventory.get("roadmap_version") != self.policy["roadmap_version"]:
            self.add_error("inventory roadmap version differs from policy")
        if inventory.get("git_object_format") != self.policy["git_object_format"]:
            self.add_error("Git object format differs from policy")
        baseline_checkpoint = inventory.get("baseline_checkpoint")
        if baseline_checkpoint != self.policy["baseline_checkpoint"]:
            self.add_error("baseline checkpoint differs from policy")
        if (
            inventory.get("baseline_tree_git_object_id")
            != self.policy["baseline_tree_git_object_id"]
        ):
            self.add_error("baseline tree Git object ID differs from policy")

        baseline = self.verify_checkpoint(
            label="baseline",
            commit=baseline_checkpoint,
            recorded_tree=inventory.get("baseline_tree_git_object_id"),
        )
        source = self.verify_checkpoint(
            label="source",
            commit=inventory.get("source_checkpoint"),
            recorded_tree=inventory.get("source_tree_git_object_id"),
        )

        status = inventory.get("status")
        if status not in self.policy["allowed_statuses"]:
            self.add_error(f"unsupported inventory status: {status!r}")
        if status == "baseline":
            if source is not None and source[0] != baseline_checkpoint:
                self.add_error("baseline inventory must use the baseline checkpoint")
            if inventory.get("source_checkpoint_role") != "pre-R00 implementation baseline":
                self.add_error("baseline inventory checkpoint role is invalid")
        elif status == "accepted":
            accepted = self.policy["accepted_checkpoint"]
            if inventory.get("source_checkpoint") != accepted["commit"]:
                self.add_error("accepted inventory source checkpoint differs from policy")
            if inventory.get("source_tree_git_object_id") != accepted["tree_git_object_id"]:
                self.add_error("accepted inventory source tree differs from policy")
            if inventory.get("source_checkpoint_role") != accepted["role"]:
                self.add_error("accepted inventory checkpoint role differs from policy")

        expected_ids = self.policy["required_entry_ids"]
        entries = inventory.get("entries")
        if not isinstance(entries, list):
            self.add_error("entries must be an array")
            entries = []
        required_entry_keys = set(self.policy["required_entry_keys"])
        for entry in entries:
            if isinstance(entry, dict) and set(entry) != required_entry_keys:
                self.add_error(
                    f"{entry.get('id')}: entry fields differ from the closed schema"
                )
        actual_ids = [entry.get("id") for entry in entries if isinstance(entry, dict)]
        if actual_ids != expected_ids:
            self.add_error(
                f"entry IDs/order must be exactly {expected_ids!r}; found {actual_ids!r}"
            )

        if baseline is not None:
            self.verify_sources(
                entries=entries,
                source_key="baseline_sources",
                checkpoint=baseline[0],
                label="baseline",
            )
        if source is not None:
            self.verify_sources(
                entries=entries,
                source_key="sources",
                checkpoint=source[0],
                label="source",
            )

        baseline_source_payload = [
            {
                "id": entry.get("id"),
                "sources": entry.get("baseline_sources"),
            }
            for entry in entries
            if isinstance(entry, dict)
        ]
        if (
            canonical_json_sha256(baseline_source_payload)
            != self.policy["baseline_sources_sha256"]
        ):
            self.add_error("baseline source inventory hash differs from policy")

        classification_payload = [
            {
                key: entry.get(key)
                for key in (
                    "id",
                    "name",
                    "disposition",
                    "retained_role",
                    "future_phase",
                )
            }
            for entry in entries
            if isinstance(entry, dict)
        ]
        if (
            canonical_json_sha256(classification_payload)
            != self.policy["classification_sha256"]
        ):
            self.add_error("C01-C11 classification hash differs from policy")

        if status == "accepted":
            required_paths = self.policy["required_accepted_source_paths_by_entry"]
            for entry in entries:
                if not isinstance(entry, dict):
                    continue
                entry_id = entry.get("id")
                sources = entry.get("sources")
                actual_paths = (
                    [item.get("path") for item in sources if isinstance(item, dict)]
                    if isinstance(sources, list)
                    else []
                )
                if actual_paths != required_paths.get(entry_id):
                    self.add_error(
                        f"{entry_id}: accepted source paths/order differ from policy"
                    )

        if source is not None:
            for entry in entries:
                if not isinstance(entry, dict):
                    continue
                baseline_sources = entry.get("baseline_sources")
                current_sources = entry.get("sources")
                if not isinstance(baseline_sources, list) or not isinstance(
                    current_sources, list
                ):
                    continue
                current_paths = {
                    item.get("path") for item in current_sources if isinstance(item, dict)
                }
                for item in baseline_sources:
                    if not isinstance(item, dict):
                        continue
                    path = item.get("path")
                    if not self.valid_relative_path(path):
                        continue
                    if self.object_at(source[0], path) is not None and path not in current_paths:
                        self.add_error(
                            f"{entry.get('id')}: retained baseline path is missing from "
                            f"accepted sources: {path}"
                        )

        expected_preservation = self.policy["historical_preservation"]
        if inventory.get("historical_preservation") != expected_preservation:
            self.add_error("historical preservation identities differ from policy")
        else:
            for checkpoint_label, resolved in (("baseline", baseline), ("source", source)):
                if resolved is None:
                    continue
                for item in expected_preservation:
                    actual = self.object_at(resolved[0], item["path"])
                    expected = (item["object_type"], item["git_object_id"])
                    if actual != expected:
                        self.add_error(
                            f"historical preservation identity differs at "
                            f"{checkpoint_label} for {item['path']}"
                        )
                    if checkpoint_label == "source":
                        unchanged = self.git(
                            "diff",
                            "--quiet",
                            resolved[0],
                            "--",
                            item["path"],
                        )
                        if unchanged.returncode != 0:
                            self.add_error(
                                "historical preservation path differs from the source "
                                f"checkpoint in the candidate tree: {item['path']}"
                            )

        external = inventory.get("external_p06_evidence")
        expected_external = self.policy["external_p06_evidence"]
        if not isinstance(external, dict):
            self.add_error("external_p06_evidence must be an object")
        else:
            if external != expected_external:
                self.add_error("external P06 evidence record differs from policy")
            if external.get("local_tree_available") is not False:
                self.add_error("external P06 tree must not be claimed as locally available")
            if external.get("bytes_reopened_for_r00") is not False:
                self.add_error("external P06 bytes must not be claimed as reopened")
            if source and self.valid_relative_path(external.get("receipt_path")):
                receipt_actual = self.object_at(source[0], external["receipt_path"])
                if receipt_actual != ("blob", external.get("receipt_git_object_id")):
                    self.add_error("external P06 receipt Git object identity differs")
                try:
                    receipt = self.json_blob_at(source[0], external["receipt_path"])
                    if receipt is None:
                        raise ValueError("committed receipt is not a UTF-8 JSON object")
                    terminal = receipt["terminal_archive"]
                    tree = terminal["tree"]
                    if terminal.get("root_path") != external.get("external_root"):
                        self.add_error("external P06 receipt root differs from inventory")
                    if tree.get("file_count") != external.get("file_count"):
                        self.add_error("external P06 receipt file count differs from inventory")
                    if tree.get("size_bytes") != external.get("size_bytes"):
                        self.add_error("external P06 receipt byte size differs from inventory")
                    if tree.get("sha256") != external.get("tree_sha256"):
                        self.add_error("external P06 receipt tree hash differs from inventory")
                    expected_receipt_hash = receipt.get("receipt_sha256")
                    payload = dict(receipt)
                    payload.pop("receipt_sha256", None)
                    actual_receipt_hash = canonical_json_sha256(payload)
                    if actual_receipt_hash != expected_receipt_hash:
                        self.add_error("external P06 receipt self-hash is invalid")
                except (KeyError, TypeError, ValueError) as exc:
                    self.add_error(f"external P06 receipt cannot be verified: {exc}")
                if self.object_at(source[0], external["external_root"]) is not None:
                    self.add_error("external P06 root is recorded unavailable but is tracked")

        if inventory.get("missing_roadmap_inputs") != self.policy["missing_roadmap_inputs"]:
            self.add_error("missing roadmap input list differs from policy")
        elif source:
            for path in self.policy["missing_roadmap_inputs"]:
                if self.object_at(source[0], path) is not None:
                    self.add_error(f"roadmap input is recorded missing but exists: {path}")

        resolutions = inventory.get("roadmap_input_resolutions")
        if resolutions != self.policy["roadmap_input_resolutions"]:
            self.add_error("roadmap input resolutions differ from policy")
        elif source:
            for item in resolutions:
                actual = self.object_at(source[0], item["tracked_path"])
                if actual != ("blob", item["git_object_id"]):
                    self.add_error(
                        f"roadmap input resolution differs for {item['tracked_path']}"
                    )

        absent_paths = inventory.get("absent_historical_paths")
        if absent_paths != self.policy["absent_historical_paths"]:
            self.add_error("absent historical path list differs from policy")
        elif source:
            for path in absent_paths:
                if self.object_at(source[0], path) is not None:
                    self.add_error(f"historical path is recorded absent but exists: {path}")

        retire_or_replace = inventory.get("retire_or_replace")
        if not isinstance(retire_or_replace, list) or not retire_or_replace:
            self.add_error("retire_or_replace must be a non-empty array")
        elif source:
            if (
                canonical_json_sha256(retire_or_replace)
                != self.policy["retire_or_replace_sha256"]
            ):
                self.add_error("retire_or_replace contract hash differs from policy")
            for item in retire_or_replace:
                if not isinstance(item, dict) or not self.valid_relative_path(item.get("path")):
                    self.add_error("retire_or_replace contains an invalid path record")
                    continue
                if self.object_at(source[0], item["path"]) is None:
                    self.add_error(
                        f"retire_or_replace path is absent at checkpoint: {item['path']}"
                    )

        if (
            inventory.get("official_evidence_boundary")
            != self.policy["official_evidence_boundary"]
        ):
            self.add_error("official evidence boundary differs from policy")

        holdout_boundary = inventory.get("holdout_boundary")
        if holdout_boundary != self.policy["holdout_boundary"]:
            self.add_error("holdout boundary differs from policy")
        elif not isinstance(holdout_boundary, dict):
            self.add_error("holdout boundary must be an object")
        else:
            if holdout_boundary.get("pixel_access_authorized") is not False:
                self.add_error("holdout pixel access must remain unauthorized")
            if holdout_boundary.get("physical_sparsebundle_verified") is not False:
                self.add_error("physical holdout sparsebundle must remain unverified")
            if holdout_boundary.get("keychain_item_verified") is not False:
                self.add_error("holdout keychain item must remain unverified")
            if holdout_boundary.get("verification_scope") != "tracked no-pixel metadata only":
                self.add_error("holdout verification scope must remain no-pixel metadata only")

        if status == "accepted":
            holdout = inventory.get("holdout_verification")
            expected_holdout = self.policy["holdout_verification"]
            if holdout != expected_holdout:
                self.add_error("accepted inventory holdout verification differs from policy")
            elif source:
                ledger_path = holdout["sealed_ledger_path"]
                attestation_path = holdout["attestation_path"]
                ledger_bytes = self.blob_at(source[0], ledger_path)
                attestation_bytes = self.blob_at(source[0], attestation_path)
                if ledger_bytes is None or attestation_bytes is None:
                    self.add_error("tracked holdout no-pixel records are unavailable at checkpoint")
                else:
                    if (
                        hashlib.sha256(ledger_bytes).hexdigest()
                        != holdout["sealed_ledger_sha256"]
                    ):
                        self.add_error("sealed-ledger SHA-256 differs from committed bytes")
                    if (
                        hashlib.sha256(attestation_bytes).hexdigest()
                        != holdout["attestation_sha256"]
                    ):
                        self.add_error("attestation SHA-256 differs from committed bytes")
                    ledger_identity = self.object_at(source[0], ledger_path)
                    attestation_identity = self.object_at(source[0], attestation_path)
                    if ledger_identity != (
                        "blob",
                        holdout["sealed_ledger_git_object_id"],
                    ):
                        self.add_error("sealed-ledger Git object identity differs")
                    if attestation_identity != (
                        "blob",
                        holdout["attestation_git_object_id"],
                    ):
                        self.add_error("attestation Git object identity differs")
                    for protected_path in (ledger_path, attestation_path):
                        unchanged = self.git(
                            "diff",
                            "--quiet",
                            source[0],
                            "--",
                            protected_path,
                        )
                        if unchanged.returncode != 0:
                            self.add_error(
                                "tracked holdout no-pixel record differs from the "
                                f"source checkpoint in the candidate tree: {protected_path}"
                            )
                    try:
                        ledger_document = json.loads(ledger_bytes.decode("utf-8"))
                        attestation_document = json.loads(
                            attestation_bytes.decode("utf-8")
                        )
                        evaluation = attestation_document["evaluation_access"]
                        if ledger_document.get("status") != holdout["status"]:
                            self.add_error("sealed-ledger status differs from inventory")
                        if evaluation.get("status") != holdout["status"]:
                            self.add_error("attestation status differs from inventory")
                        if (
                            ledger_document.get("evaluation_access_count")
                            != holdout["access_count"]
                        ):
                            self.add_error("sealed-ledger access count differs from inventory")
                        if (
                            evaluation.get("evaluation_access_count")
                            != holdout["access_count"]
                        ):
                            self.add_error("attestation access count differs from inventory")
                        if (
                            attestation_document["container"].get("mounted")
                            != holdout["mounted"]
                        ):
                            self.add_error("attestation mounted value differs from inventory")
                        if (
                            attestation_document.get("pixel_content_included")
                            != holdout["pixel_content_included"]
                        ):
                            self.add_error("attestation pixel-content value differs from inventory")
                        recorded_ledger_hash = attestation_document[
                            "outer_record_hashes"
                        ].get("evaluation_access_ledger_sealed_copy")
                        if recorded_ledger_hash != holdout["sealed_ledger_sha256"]:
                            self.add_error("attestation ledger hash binding differs from inventory")
                    except (
                        KeyError,
                        TypeError,
                        UnicodeDecodeError,
                        json.JSONDecodeError,
                    ) as exc:
                        self.add_error(f"tracked holdout metadata cannot be verified: {exc}")

            process_check = inventory.get("legacy_process_check")
            expected_process_check = self.policy["legacy_process_check"]
            if process_check != expected_process_check:
                self.add_error("accepted inventory legacy process check differs from policy")
            elif not isinstance(process_check, dict):
                self.add_error("accepted inventory requires a legacy_process_check object")
            else:
                checked_at = process_check.get("checked_at")
                if not isinstance(checked_at, str) or not re.fullmatch(
                    r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z", checked_at
                ):
                    self.add_error("legacy process check timestamp is invalid")
                if type(process_check.get("matching_process_count")) is not int:
                    self.add_error("legacy process match count must be an integer")
                elif process_check["matching_process_count"] != 0:
                    self.add_error("accepted inventory requires zero matching legacy processes")
                if process_check.get("matching_processes") != []:
                    self.add_error("accepted inventory requires an empty legacy process match list")

        if self.markdown_path.is_file():
            expected_markdown = render_inventory(inventory)
            actual_markdown = self.markdown_path.read_text(encoding="utf-8")
            if actual_markdown != expected_markdown:
                self.add_error(
                    "generated Markdown summary is stale; run "
                    "`python3 Scripts/r00_inventory.py --write-markdown`"
                )
        else:
            self.add_error("generated Markdown summary is missing")
        return sorted(set(self.errors))

    def write_markdown(self) -> None:
        inventory = read_json(self.inventory_path)
        self.markdown_path.parent.mkdir(parents=True, exist_ok=True)
        self.markdown_path.write_text(render_inventory(inventory), encoding="utf-8")


def repository_root_from_script() -> Path:
    return Path(__file__).resolve().parent.parent


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    operation = parser.add_mutually_exclusive_group()
    operation.add_argument("--check", action="store_true", help="verify inventory")
    operation.add_argument(
        "--write-markdown",
        action="store_true",
        help="regenerate the Markdown summary from canonical inventory JSON",
    )
    parser.add_argument("--root", type=Path, default=repository_root_from_script())
    parser.add_argument("--policy", type=Path, default=DEFAULT_POLICY_PATH)
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    try:
        verifier = InventoryVerifier(args.root, args.policy)
        if args.write_markdown:
            verifier.write_markdown()
            print("R00 inventory Markdown updated from canonical JSON.")
            return 0
        errors = verifier.check()
    except (OSError, ValueError, KeyError, json.JSONDecodeError) as exc:
        print(f"R00 inventory configuration error: {exc}", file=sys.stderr)
        return 2
    if errors:
        for message in errors:
            print(f"R00 inventory error: {message}", file=sys.stderr)
        return 1
    print("R00 inventory: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
