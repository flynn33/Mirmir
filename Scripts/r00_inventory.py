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
        "Git object IDs identify the exact file or tree at the source checkpoint.",
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
        lines.extend(
            [
                "",
                f"### {entry['id']} — {entry['name']}",
                "",
                "| Exact path | Git object type | Git object ID |",
                "| --- | --- | --- |",
            ]
        )
        for source in entry["sources"]:
            lines.append(
                f"| `{markdown_cell(source['path'])}` | "
                f"`{markdown_cell(source['object_type'])}` | "
                f"`{markdown_cell(source['git_object_id'])}` |"
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
        lines.append(f"- `{path}` — absent from the source checkpoint and local host")

    external = inventory["external_p06_evidence"]
    gib = int(external["size_bytes"]) / (1024**3)
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
            f"`{external['size_bytes']}` bytes ({gib:.2f} GiB), "
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
                f"- Tracked mounted value: `{str(verification['mounted']).lower()}`",
                f"- Tracked status: `{verification['status']}`",
                f"- Tracked access count: `{verification['access_count']}`",
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

    def check(self) -> list[str]:
        self.errors = []
        try:
            inventory = read_json(self.inventory_path)
        except (OSError, ValueError, json.JSONDecodeError) as exc:
            return [f"inventory JSON is invalid: {exc}"]

        checkpoint = inventory.get("source_checkpoint")
        if not isinstance(checkpoint, str) or not re.fullmatch(r"[0-9a-f]{40}", checkpoint):
            self.add_error("source_checkpoint must be a full lowercase 40-hex commit")
            checkpoint = ""
        elif self.git("cat-file", "-e", f"{checkpoint}^{{commit}}").returncode != 0:
            self.add_error(f"source checkpoint commit is unavailable: {checkpoint}")

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
        if checkpoint:
            tree = self.git("rev-parse", "--verify", f"{checkpoint}^{{tree}}")
            if tree.returncode != 0:
                self.add_error("source checkpoint tree cannot be resolved")
            elif inventory.get("source_tree_git_object_id") != tree.stdout.strip():
                self.add_error("source tree Git object ID differs from source checkpoint")

        expected_ids = self.policy["required_entry_ids"]
        entries = inventory.get("entries")
        if not isinstance(entries, list):
            self.add_error("entries must be an array")
            entries = []
        actual_ids = [entry.get("id") for entry in entries if isinstance(entry, dict)]
        if actual_ids != expected_ids:
            self.add_error(
                f"entry IDs/order must be exactly {expected_ids!r}; found {actual_ids!r}"
            )

        seen_paths: set[tuple[str, str]] = set()
        if checkpoint:
            for entry in entries:
                if not isinstance(entry, dict):
                    self.add_error("every inventory entry must be an object")
                    continue
                sources = entry.get("sources")
                if not isinstance(sources, list) or not sources:
                    self.add_error(f"{entry.get('id')}: sources must be a non-empty array")
                    continue
                for source in sources:
                    if not isinstance(source, dict):
                        self.add_error(f"{entry.get('id')}: every source must be an object")
                        continue
                    path = source.get("path")
                    if not self.valid_relative_path(path):
                        self.add_error(f"{entry.get('id')}: invalid relative source path {path!r}")
                        continue
                    key = (str(entry.get("id")), path)
                    if key in seen_paths:
                        self.add_error(f"{entry.get('id')}: duplicate source path {path}")
                    seen_paths.add(key)
                    actual = self.object_at(checkpoint, path)
                    if actual is None:
                        self.add_error(f"{entry.get('id')}: path is absent at checkpoint: {path}")
                        continue
                    expected_type = source.get("object_type")
                    expected_object = source.get("git_object_id")
                    if actual[0] != expected_type:
                        self.add_error(
                            f"{entry.get('id')}: object type differs for {path}: "
                            f"expected {expected_type!r}, found {actual[0]!r}"
                        )
                    if actual[1] != expected_object:
                        self.add_error(
                            f"{entry.get('id')}: Git object ID differs for {path}: "
                            f"expected {expected_object!r}, found {actual[1]!r}"
                        )

        expected_preservation = self.policy["historical_preservation"]
        if inventory.get("historical_preservation") != expected_preservation:
            self.add_error("historical preservation identities differ from policy")
        elif checkpoint:
            for item in expected_preservation:
                actual = self.object_at(checkpoint, item["path"])
                expected = (item["object_type"], item["git_object_id"])
                if actual != expected:
                    self.add_error(
                        f"historical preservation identity differs for {item['path']}"
                    )

        external = inventory.get("external_p06_evidence")
        expected_external = self.policy["external_p06_evidence"]
        if not isinstance(external, dict):
            self.add_error("external_p06_evidence must be an object")
        else:
            for key, value in expected_external.items():
                if external.get(key) != value:
                    self.add_error(f"external P06 evidence field differs: {key}")
            if external.get("local_tree_available") is not False:
                self.add_error("external P06 tree must not be claimed as locally available")
            if external.get("bytes_reopened_for_r00") is not False:
                self.add_error("external P06 bytes must not be claimed as reopened")
            if checkpoint and self.valid_relative_path(external.get("receipt_path")):
                receipt_actual = self.object_at(checkpoint, external["receipt_path"])
                if receipt_actual != ("blob", external.get("receipt_git_object_id")):
                    self.add_error("external P06 receipt Git object identity differs")
                try:
                    receipt = read_json(self.root / external["receipt_path"])
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
                    actual_receipt_hash = hashlib.sha256(
                        json.dumps(
                            payload,
                            sort_keys=True,
                            separators=(",", ":"),
                            ensure_ascii=False,
                        ).encode("utf-8")
                    ).hexdigest()
                    if actual_receipt_hash != expected_receipt_hash:
                        self.add_error("external P06 receipt self-hash is invalid")
                except (OSError, KeyError, TypeError, ValueError, json.JSONDecodeError) as exc:
                    self.add_error(f"external P06 receipt cannot be verified: {exc}")
                if self.object_at(checkpoint, external["external_root"]) is not None:
                    self.add_error("external P06 root is recorded unavailable but is tracked")

        if inventory.get("missing_roadmap_inputs") != self.policy["missing_roadmap_inputs"]:
            self.add_error("missing roadmap input list differs from policy")
        elif checkpoint:
            for path in self.policy["missing_roadmap_inputs"]:
                if self.object_at(checkpoint, path) is not None:
                    self.add_error(f"roadmap input is recorded missing but exists: {path}")

        resolutions = inventory.get("roadmap_input_resolutions")
        if resolutions != self.policy["roadmap_input_resolutions"]:
            self.add_error("roadmap input resolutions differ from policy")
        elif checkpoint:
            for item in resolutions:
                actual = self.object_at(checkpoint, item["tracked_path"])
                if actual != ("blob", item["git_object_id"]):
                    self.add_error(
                        f"roadmap input resolution differs for {item['tracked_path']}"
                    )

        absent_paths = inventory.get("absent_historical_paths")
        if absent_paths != self.policy["absent_historical_paths"]:
            self.add_error("absent historical path list differs from policy")
        elif checkpoint:
            for path in absent_paths:
                if self.object_at(checkpoint, path) is not None:
                    self.add_error(f"historical path is recorded absent but exists: {path}")

        status = inventory.get("status")
        if status not in self.policy["allowed_statuses"]:
            self.add_error(f"unsupported inventory status: {status!r}")
        if status == "baseline" and checkpoint != baseline_checkpoint:
            self.add_error("baseline inventory must use the baseline checkpoint")

        retire_or_replace = inventory.get("retire_or_replace")
        if not isinstance(retire_or_replace, list) or not retire_or_replace:
            self.add_error("retire_or_replace must be a non-empty array")
        elif checkpoint:
            for item in retire_or_replace:
                if not isinstance(item, dict) or not self.valid_relative_path(item.get("path")):
                    self.add_error("retire_or_replace contains an invalid path record")
                    continue
                if self.object_at(checkpoint, item["path"]) is None:
                    self.add_error(
                        f"retire_or_replace path is absent at checkpoint: {item['path']}"
                    )
        if status == "accepted":
            if inventory.get("holdout_verification") != self.policy["holdout_verification"]:
                self.add_error("accepted inventory holdout verification differs from policy")
            process_check = inventory.get("legacy_process_check")
            if not isinstance(process_check, dict):
                self.add_error("accepted inventory requires a legacy_process_check object")
            elif process_check.get("matching_process_count") != 0:
                self.add_error("accepted inventory requires zero matching legacy processes")

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
