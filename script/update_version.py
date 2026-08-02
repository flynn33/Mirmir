#!/usr/bin/env python3
"""Keep the repository and Xcode marketing versions synchronized."""

from __future__ import annotations

import argparse
import os
import plistlib
import re
import sys
from pathlib import Path
from typing import Iterable


VERSION_PATTERN = re.compile(
    r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$"
)
MARKETING_VERSION_PATTERN = re.compile(
    r"(?m)^([ \t]*MARKETING_VERSION = )([^;\r\n]+)(;[ \t]*)$"
)
VALID_BUMPS = ("release", "feature-release", "patch/hotfix", "none")


class VersionError(RuntimeError):
    """Raised when repository version state is invalid."""


def parse_version(value: str) -> tuple[int, int, int]:
    match = VERSION_PATTERN.fullmatch(value.strip())
    if match is None:
        raise VersionError(
            f"Invalid version {value!r}; expected release.feature.patch integers."
        )
    return tuple(int(component) for component in match.groups())


def format_version(components: Iterable[int]) -> str:
    return ".".join(str(component) for component in components)


def increment_version(base_version: str, bump: str) -> str:
    release, feature, patch = parse_version(base_version)
    if bump == "release":
        return format_version((release + 1, 0, 0))
    if bump == "feature-release":
        return format_version((release, feature + 1, 0))
    if bump == "patch/hotfix":
        return format_version((release, feature, patch + 1))
    if bump == "none":
        return format_version((release, feature, patch))
    raise VersionError(
        f"Unknown increment {bump!r}; expected one of {', '.join(VALID_BUMPS)}."
    )


def repository_paths(root: Path) -> tuple[Path, Path, Path]:
    return (
        root / "VERSION",
        root / "Mirmir.xcodeproj" / "project.pbxproj",
        root / "Mirmir" / "Info.plist",
    )


def atomic_write_text(path: Path, contents: str) -> None:
    temporary = path.with_name(f".{path.name}.version-update")
    temporary.write_text(contents, encoding="utf-8")
    os.replace(temporary, path)


def configured_marketing_versions(project_contents: str) -> list[str]:
    versions = [
        match.group(2).strip()
        for match in MARKETING_VERSION_PATTERN.finditer(project_contents)
    ]
    if not versions:
        raise VersionError("The Xcode project has no MARKETING_VERSION settings.")
    for version in versions:
        parse_version(version)
    return versions


def validate_info_plist(info_path: Path) -> None:
    with info_path.open("rb") as stream:
        info = plistlib.load(stream)
    if info.get("CFBundleShortVersionString") != "$(MARKETING_VERSION)":
        raise VersionError(
            "CFBundleShortVersionString must use $(MARKETING_VERSION)."
        )
    if info.get("CFBundleVersion") != "$(CURRENT_PROJECT_VERSION)":
        raise VersionError("CFBundleVersion must use $(CURRENT_PROJECT_VERSION).")


def check_repository(root: Path) -> str:
    version_path, project_path, info_path = repository_paths(root)
    canonical_version = version_path.read_text(encoding="utf-8").strip()
    parse_version(canonical_version)

    project_contents = project_path.read_text(encoding="utf-8")
    configured_versions = configured_marketing_versions(project_contents)
    mismatches = sorted(
        {version for version in configured_versions if version != canonical_version}
    )
    if mismatches:
        rendered = ", ".join(mismatches)
        raise VersionError(
            f"VERSION is {canonical_version}, but Xcode also contains: {rendered}."
        )

    validate_info_plist(info_path)
    return canonical_version


def set_repository_version(root: Path, target_version: str) -> str:
    target_version = format_version(parse_version(target_version))
    version_path, project_path, info_path = repository_paths(root)
    validate_info_plist(info_path)

    project_contents = project_path.read_text(encoding="utf-8")
    configured_marketing_versions(project_contents)
    updated_project = MARKETING_VERSION_PATTERN.sub(
        lambda match: f"{match.group(1)}{target_version}{match.group(3)}",
        project_contents,
    )

    expected_version_contents = f"{target_version}\n"
    if version_path.read_text(encoding="utf-8") != expected_version_contents:
        atomic_write_text(version_path, expected_version_contents)
    if updated_project != project_contents:
        atomic_write_text(project_path, updated_project)

    checked_version = check_repository(root)
    if checked_version != target_version:
        raise VersionError("Version update did not produce the requested value.")
    return checked_version


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--root",
        type=Path,
        default=Path(__file__).resolve().parent.parent,
        help="Repository root (defaults to the parent of this script directory).",
    )
    parser.add_argument("--check", action="store_true", help="Validate version state.")
    parser.add_argument("--set-version", help="Set an exact release.feature.patch value.")
    parser.add_argument("--base-version", help="Base version used for an increment.")
    parser.add_argument("--bump", choices=VALID_BUMPS, help="Increment to apply.")
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    root = arguments.root.resolve()
    requested_actions = sum(
        (
            bool(arguments.check),
            arguments.set_version is not None,
            arguments.base_version is not None or arguments.bump is not None,
        )
    )
    if requested_actions != 1:
        raise VersionError(
            "Choose exactly one of --check, --set-version, or "
            "--base-version with --bump."
        )

    if arguments.check:
        result = check_repository(root)
    elif arguments.set_version is not None:
        result = set_repository_version(root, arguments.set_version)
    else:
        if arguments.base_version is None or arguments.bump is None:
            raise VersionError("--base-version and --bump must be used together.")
        target = increment_version(arguments.base_version, arguments.bump)
        result = set_repository_version(root, target)

    print(result)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, plistlib.InvalidFileException, VersionError) as error:
        print(f"version error: {error}", file=sys.stderr)
        raise SystemExit(1)
