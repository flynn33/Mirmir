#!/usr/bin/env python3
"""Stage pre-G07 native P08 evidence or promote it after exact G07."""

from __future__ import annotations

import argparse
from pathlib import Path
import sys
from typing import Sequence


REPOSITORY_ROOT = Path(__file__).resolve().parents[3]
if str(REPOSITORY_ROOT) not in sys.path:
    sys.path.insert(0, str(REPOSITORY_ROOT))

from validation.calibration_v2.p08.evidence import P08EvidenceError  # noqa: E402
from validation.calibration_v2.p08.staging import (  # noqa: E402
    CAPTURE_ARCHIVES,
    PROFILE_ARCHIVES,
    XCTEST_ARCHIVES,
    promote_after_g07,
    stage_pre_g07,
)
from validation.quality.src.mirmir_quality.json_tools import (  # noqa: E402
    canonical_json_bytes,
)


def _absolute(path: Path) -> Path:
    return path if path.is_absolute() else Path.cwd() / path


def _arguments(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    pre = commands.add_parser("pre-g07")
    pre.add_argument("--repository-root", required=True, type=Path)
    pre.add_argument("--native-measurements", required=True, type=Path)
    pre.add_argument("--p06-release-root", required=True, type=Path)
    pre.add_argument("--release-app", required=True, type=Path)
    for role, name in XCTEST_ARCHIVES.items():
        pre.add_argument(f"--{role.replace('_', '-')}-xcresult", required=True, type=Path)
    for tool, route, _name in PROFILE_ARCHIVES:
        pre.add_argument(
            f"--{tool.replace('_', '-')}-{route.replace('_', '-')}-trace",
            required=True,
            type=Path,
        )
    for route, _name in CAPTURE_ARCHIVES:
        pre.add_argument(
            f"--{route.replace('_', '-')}-gputrace",
            required=True,
            type=Path,
        )
    promote = commands.add_parser("promote-after-g07")
    promote.add_argument("--repository-root", required=True, type=Path)
    promote.add_argument("--pre-g07-root", required=True, type=Path)
    promote.add_argument("--g07-publication", required=True, type=Path)
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    arguments = _arguments(argv)
    try:
        if arguments.command == "pre-g07":
            raw = {
                name: _absolute(getattr(arguments, f"{role}_xcresult"))
                for role, name in XCTEST_ARCHIVES.items()
            }
            raw.update(
                {
                    name: _absolute(getattr(arguments, f"{tool}_{route}_trace"))
                    for tool, route, name in PROFILE_ARCHIVES
                }
            )
            raw.update(
                {
                    name: _absolute(getattr(arguments, f"{route}_gputrace"))
                    for route, name in CAPTURE_ARCHIVES
                }
            )
            result = stage_pre_g07(
                repository_root=_absolute(arguments.repository_root),
                native_measurements=_absolute(arguments.native_measurements),
                p06_release_root=_absolute(arguments.p06_release_root),
                release_app=_absolute(arguments.release_app),
                raw_archives=raw,
            )
            sys.stdout.buffer.write(canonical_json_bytes(result) + b"\n")
            return 0 if result["available_checks_all_satisfied"] else 1
        gate = promote_after_g07(
            repository_root=_absolute(arguments.repository_root),
            pre_g07_root=_absolute(arguments.pre_g07_root),
            g07_publication=_absolute(arguments.g07_publication),
        )
        return 0 if gate["status"] == "pass" else 1
    except (OSError, P08EvidenceError, UnicodeError, ValueError) as error:
        print(f"P08 staging failed: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
