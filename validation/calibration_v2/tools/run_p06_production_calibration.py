#!/usr/bin/env python3
"""Historical P06 V1 utility; never an authorizing production entry point."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import stat
import sys


REPOSITORY_ROOT = Path(__file__).resolve().parents[3]
if str(REPOSITORY_ROOT) not in sys.path:
    sys.path.insert(0, str(REPOSITORY_ROOT))

from validation.calibration_v2.runner import (  # noqa: E402
    LiveHoldoutPreopenBinding,
)


def _read_regular(path: Path) -> bytes:
    try:
        before = os.stat(path, follow_symlinks=False)
    except OSError as error:
        raise ValueError(f"required anchor file is absent: {path}") from error
    if path.is_symlink() or not stat.S_ISREG(before.st_mode):
        raise ValueError(f"required anchor path is not a regular file: {path}")
    flags = os.O_RDONLY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = os.open(path, flags)
    try:
        opened = os.fstat(descriptor)
        if (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino):
            raise ValueError("anchor file changed while opening")
        chunks = []
        while True:
            chunk = os.read(descriptor, 1024 * 1024)
            if not chunk:
                break
            chunks.append(chunk)
        after = os.fstat(descriptor)
    finally:
        os.close(descriptor)
    if (
        (after.st_dev, after.st_ino) != (before.st_dev, before.st_ino)
        or after.st_size != before.st_size
        or after.st_mtime_ns != before.st_mtime_ns
    ):
        raise ValueError("anchor file changed while reading")
    return b"".join(chunks)


def _sha256_file(path: Path) -> str:
    return hashlib.sha256(_read_regular(path)).hexdigest()


def _require_sha256(value: object, label: str) -> str:
    if (
        not isinstance(value, str)
        or len(value) != 64
        or any(character not in "0123456789abcdef" for character in value)
    ):
        raise ValueError(f"{label} must be one lowercase SHA-256")
    return value


def _reject_duplicate_pairs(
    pairs: list[tuple[str, object]],
) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"live preopen receipt has duplicate key: {key}")
        result[key] = value
    return result


def _receipt(path: Path) -> tuple[dict[str, object], str]:
    payload = _read_regular(path)
    try:
        value = json.loads(
            payload,
            object_pairs_hook=_reject_duplicate_pairs,
            parse_constant=lambda token: (_ for _ in ()).throw(
                ValueError(f"live preopen receipt has non-finite value: {token}")
            ),
        )
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ValueError("live preopen receipt is invalid JSON") from error
    if not isinstance(value, dict):
        raise ValueError("live preopen receipt is not an object")
    required = (
        "live_ledger_root_identity_sha256",
        "live_anchor_root_identity_sha256",
        "repository_sealed_copy_sha256",
        "repository_attestation_sha256",
    )
    for field in required:
        if not isinstance(value.get(field), str):
            raise ValueError("live preopen receipt lacks required hashes")
        _require_sha256(value[field], f"live preopen receipt {field}")
    return value, hashlib.sha256(payload).hexdigest()


def _arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Validate historical V1 preopen anchors without executing calibration "
            "or publishing a release. Production P06 uses the V2 command."
        )
    )
    parser.add_argument("--repository-root", required=True, type=Path)
    parser.add_argument("--open-split-root", required=True, type=Path)
    parser.add_argument("--calibration-output-root", required=True, type=Path)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--release-root", required=True, type=Path)
    parser.add_argument("--evidence-root", required=True, type=Path)
    parser.add_argument("--native-cache-root", required=True, type=Path)
    parser.add_argument("--writer-root", required=True, type=Path)
    parser.add_argument("--dispatch-measurement-root", required=True, type=Path)
    parser.add_argument("--p04-quality-root", required=True, type=Path)
    parser.add_argument(
        "--locked-utc",
        help=(
            "explicit UTC lock timestamp for a controlled replay; normal production "
            "runs derive this immediately after calibration"
        ),
    )
    parser.add_argument("--live-ledger-path", required=True, type=Path)
    parser.add_argument("--live-anchor-path", required=True, type=Path)
    parser.add_argument("--live-preopen-receipt-path", required=True, type=Path)
    parser.add_argument(
        "--expected-live-ledger-root-identity-sha256",
        required=True,
    )
    parser.add_argument(
        "--expected-live-anchor-root-identity-sha256",
        required=True,
    )
    parser.add_argument(
        "--expected-live-preopen-receipt-sha256",
        required=True,
    )
    parser.add_argument("--repository-sealed-copy-path", required=True, type=Path)
    parser.add_argument(
        "--expected-repository-sealed-copy-sha256",
        required=True,
    )
    parser.add_argument("--repository-attestation-path", required=True, type=Path)
    parser.add_argument(
        "--expected-repository-attestation-sha256",
        required=True,
    )
    parser.add_argument(
        "--test-evidence",
        required=True,
        action="append",
        metavar="ID=PATH",
    )
    parser.add_argument(
        "--preserved-failure-evidence",
        required=True,
        action="append",
        metavar="ID=PATH",
    )
    parser.add_argument("--timeout-seconds", type=float, default=900.0)
    return parser.parse_args()


def _named_paths(values: list[str], label: str) -> dict[str, Path]:
    result: dict[str, Path] = {}
    for value in values:
        identifier, separator, path = value.partition("=")
        if not separator or not identifier or not path or identifier in result:
            raise ValueError(f"{label} must contain unique ID=PATH values")
        result[identifier] = Path(path)
    return result


def _live_holdout_preopen_binding(
    arguments: argparse.Namespace,
) -> LiveHoldoutPreopenBinding:
    expected = {
        "live_ledger_root_identity_sha256": _require_sha256(
            arguments.expected_live_ledger_root_identity_sha256,
            "expected live ledger-root identity",
        ),
        "live_anchor_root_identity_sha256": _require_sha256(
            arguments.expected_live_anchor_root_identity_sha256,
            "expected live anchor-root identity",
        ),
        "live_preopen_receipt_sha256": _require_sha256(
            arguments.expected_live_preopen_receipt_sha256,
            "expected live preopen receipt file hash",
        ),
        "repository_sealed_copy_sha256": _require_sha256(
            arguments.expected_repository_sealed_copy_sha256,
            "expected repository sealed-copy hash",
        ),
        "repository_attestation_sha256": _require_sha256(
            arguments.expected_repository_attestation_sha256,
            "expected repository attestation hash",
        ),
    }
    receipt, actual_receipt_sha256 = _receipt(
        arguments.live_preopen_receipt_path
    )
    if actual_receipt_sha256 != expected["live_preopen_receipt_sha256"]:
        raise ValueError("live preopen receipt differs from its explicit expected hash")
    for field in (
        "live_ledger_root_identity_sha256",
        "live_anchor_root_identity_sha256",
        "repository_sealed_copy_sha256",
        "repository_attestation_sha256",
    ):
        if receipt.get(field) != expected[field]:
            raise ValueError(
                f"live preopen receipt differs from explicit expected anchor: {field}"
            )
    actual_sealed_copy_sha256 = _sha256_file(
        arguments.repository_sealed_copy_path
    )
    if actual_sealed_copy_sha256 != expected["repository_sealed_copy_sha256"]:
        raise ValueError(
            "repository sealed copy differs from its explicit expected hash"
        )
    actual_attestation_sha256 = _sha256_file(
        arguments.repository_attestation_path
    )
    if actual_attestation_sha256 != expected["repository_attestation_sha256"]:
        raise ValueError(
            "repository attestation differs from its explicit expected hash"
        )
    return LiveHoldoutPreopenBinding(
        live_ledger_path=arguments.live_ledger_path,
        live_anchor_path=arguments.live_anchor_path,
        live_preopen_receipt_path=arguments.live_preopen_receipt_path,
        expected_live_ledger_root_identity_sha256=expected[
            "live_ledger_root_identity_sha256"
        ],
        expected_live_anchor_root_identity_sha256=expected[
            "live_anchor_root_identity_sha256"
        ],
        expected_live_preopen_receipt_sha256=expected[
            "live_preopen_receipt_sha256"
        ],
        repository_sealed_copy_path=arguments.repository_sealed_copy_path,
        expected_repository_sealed_copy_sha256=expected[
            "repository_sealed_copy_sha256"
        ],
        repository_attestation_path=arguments.repository_attestation_path,
        expected_repository_attestation_sha256=expected[
            "repository_attestation_sha256"
        ],
    )


def main() -> int:
    arguments = _arguments()
    # Retain historical anchor validation for offline receipt diagnostics, but
    # never construct a candidate, execute calibration, or publish a release.
    _live_holdout_preopen_binding(arguments)
    print(
        "error: this historical V1 runner is non-authorizing; use "
        "validation/calibration_v2/tools/"
        "run_p06_production_calibration_v2.py for production P06",
        file=sys.stderr,
    )
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
