#!/usr/bin/env python3
"""Read-only closure inspection for a failed P06 calibration archive."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys


REPOSITORY_ROOT = Path(__file__).resolve().parents[3]
if str(REPOSITORY_ROOT) not in sys.path:
    sys.path.insert(0, str(REPOSITORY_ROOT))

from validation.calibration_v2.corrective_preregistration import (  # noqa: E402
    verify_attempt_ledger_payload,
)
from validation.calibration_v2.tools import (  # noqa: E402
    run_p06_corrective_diagnostics as core,
)


def _arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Reopen the failed-run core files and every ledger-referenced "
            "evaluation/control JSON, then print exact hashes and counts."
        )
    )
    parser.add_argument("--failed-run-root", required=True, type=Path)
    parser.add_argument("--attempt-ledger-path", required=True, type=Path)
    parser.add_argument("--failure-record-path", required=True, type=Path)
    parser.add_argument("--input-bindings-path", required=True, type=Path)
    parser.add_argument("--transaction-intent-path", required=True, type=Path)
    return parser.parse_args()


def inspect(arguments: argparse.Namespace) -> dict[str, object]:
    root = core._PinnedDirectory(arguments.failed_run_root, "failed run root")
    try:
        for path in (
            arguments.attempt_ledger_path,
            arguments.failure_record_path,
            arguments.input_bindings_path,
            arguments.transaction_intent_path,
        ):
            absolute = core._lexical_absolute(path, "archive core file")
            try:
                absolute.relative_to(root.path)
            except ValueError as error:
                raise core.CorrectiveDiagnosticCLIError(
                    "archive core file is outside the failed-run root"
                ) from error
            core._require(
                absolute.suffix in {".json", ".ndjson"},
                "archive inspector refuses non-JSON core input",
            )
        core_files = {
            "attempt_ledger": core._RegularSnapshot.capture(
                arguments.attempt_ledger_path,
                "archived attempt ledger",
            ),
            "failure_record": core._RegularSnapshot.capture(
                arguments.failure_record_path,
                "archived failure record",
            ),
            "input_bindings": core._RegularSnapshot.capture(
                arguments.input_bindings_path,
                "archived input bindings",
            ),
            "transaction_intent": core._RegularSnapshot.capture(
                arguments.transaction_intent_path,
                "archived transaction intent",
            ),
        }
        records = verify_attempt_ledger_payload(
            core_files["attempt_ledger"].payload
        )
        closure, referenced = core._archive_closure(
            failed_root=root,
            records=records,
            core_files=core_files,
        )
        for snapshot in core_files.values():
            snapshot.verify("archive core file")
        for snapshot, label in referenced:
            snapshot.verify(label)
        root.verify()
        return {
            "schema_version": "1.0.0",
            "status": "archive_closure_verified",
            "failed_run_root": root.binding(),
            "core_files": {
                name: snapshot.binding()
                for name, snapshot in sorted(core_files.items())
            },
            "attempt_count": len(records),
            "tail_record_sha256": records[-1]["record_sha256"],
            **closure,
            "pixel_content_accessed": False,
        }
    finally:
        root.close()


def main() -> int:
    print(
        json.dumps(
            inspect(_arguments()),
            ensure_ascii=False,
            allow_nan=False,
            sort_keys=True,
            separators=(",", ":"),
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
