#!/usr/bin/env python3
"""Print one canonical P08 file, tree, or clean-repository identity binding."""

from __future__ import annotations

import argparse
from pathlib import Path
import sys
from typing import Sequence


REPOSITORY_ROOT = Path(__file__).resolve().parents[3]
if str(REPOSITORY_ROOT) not in sys.path:
    sys.path.insert(0, str(REPOSITORY_ROOT))

from validation.calibration_v2.p08.evidence import (  # noqa: E402
    P08EvidenceError,
    file_binding,
    repository_identity,
    tree_binding,
)
from validation.quality.src.mirmir_quality.json_tools import (  # noqa: E402
    canonical_json_bytes,
)


def _supplied_absolute(path: Path) -> Path:
    return path if path.is_absolute() else Path.cwd() / path


def _arguments(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="kind", required=True)
    for name in ("file", "tree"):
        child = subparsers.add_parser(name)
        child.add_argument("--path", required=True, type=Path)
        child.add_argument("--relative-path", required=True)
    repository = subparsers.add_parser("repository")
    repository.add_argument("--repository-root", required=True, type=Path)
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    arguments = _arguments(argv)
    try:
        if arguments.kind == "file":
            result = file_binding(
                _supplied_absolute(arguments.path),
                relative_path=arguments.relative_path,
            )
        elif arguments.kind == "tree":
            result = tree_binding(
                _supplied_absolute(arguments.path),
                relative_path=arguments.relative_path,
            )
        else:
            result = repository_identity(
                _supplied_absolute(arguments.repository_root)
            )
    except (OSError, P08EvidenceError, UnicodeError, ValueError) as error:
        print(f"P08 evidence binding failed: {error}", file=sys.stderr)
        return 2
    sys.stdout.buffer.write(canonical_json_bytes(result) + b"\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
