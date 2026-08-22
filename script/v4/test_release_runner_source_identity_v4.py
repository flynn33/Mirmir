#!/usr/bin/env python3
"""Regression tests for release-runner commit and source-tree isolation."""

from __future__ import annotations

import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPT_DIRECTORY = Path(__file__).resolve().parent
P06_SPEC = importlib.util.spec_from_file_location(
    "capture_p06_reproduction_v4",
    SCRIPT_DIRECTORY / "capture_p06_reproduction_v4.py",
)
assert P06_SPEC is not None and P06_SPEC.loader is not None
p06 = importlib.util.module_from_spec(P06_SPEC)
P06_SPEC.loader.exec_module(p06)

ARCHIVE_SPEC = importlib.util.spec_from_file_location(
    "release_candidate_archive_v4",
    SCRIPT_DIRECTORY / "release_candidate_archive_v4.py",
)
assert ARCHIVE_SPEC is not None and ARCHIVE_SPEC.loader is not None
archive = importlib.util.module_from_spec(ARCHIVE_SPEC)
sys.modules[ARCHIVE_SPEC.name] = archive
ARCHIVE_SPEC.loader.exec_module(archive)


def run(*arguments: str | Path, cwd: Path) -> str:
    return subprocess.check_output(
        [str(argument) for argument in arguments], cwd=cwd, text=True
    ).strip()


def shell_function(source: str, name: str) -> str:
    marker = f"{name}() {{\n"
    start = source.index(marker)
    end = source.index("\n}\n", start) + len("\n}\n")
    return source[start:end]


class ReleaseRunnerSourceIdentityV4Tests(unittest.TestCase):
    def makeRepository(self, root: Path) -> tuple[Path, str]:
        repository = root / "repository"
        repository.mkdir()
        run("git", "init", "-q", cwd=repository)
        run("git", "config", "user.email", "runner-tests@example.invalid", cwd=repository)
        run("git", "config", "user.name", "Runner Tests", cwd=repository)
        (repository / "Mirmir").mkdir()
        (repository / "Mirmir/source.swift").write_text("let committed = 1\n")
        (repository / "locked.bin").write_bytes(b"committed\0bytes\n")
        run("git", "add", ".", cwd=repository)
        run("git", "commit", "-qm", "fixture", cwd=repository)
        return repository, run("git", "rev-parse", "HEAD", cwd=repository)

    def testAllReleaseSourceIdentityAlgorithmsMatchCanonicalIdentity(self) -> None:
        runners = (
            (SCRIPT_DIRECTORY / "run_performance_gate_v4.sh", "zsh"),
            (SCRIPT_DIRECTORY / "run_quality_gate_v4.sh", "sh"),
        )
        with tempfile.TemporaryDirectory(prefix="mirmir-runner-identity-") as temporary:
            root = Path(temporary)
            repository, commit = self.makeRepository(root)
            expected = p06.source_tree_identity(repository, commit)
            for runner, shell in runners:
                with self.subTest(runner=runner.name):
                    function = shell_function(runner.read_text(), "source_tree_identity")
                    probe = root / f"probe-{runner.stem}.sh"
                    probe.write_text(
                        f"#!/bin/{shell}\nset -eu\n{function}\n"
                        'source_tree_identity "$1" "$2"\n'
                    )
                    observed = run(shell, probe, repository, commit, cwd=root)
                    self.assertEqual(observed, expected)
            self.assertEqual(
                archive.source_tree_identity(repository, commit),
                expected,
            )

    def testQualityCandidateArchiveExcludesDirtyWorkingBytes(self) -> None:
        runner = SCRIPT_DIRECTORY / "run_quality_gate_v4.sh"
        function = shell_function(runner.read_text(), "extract_candidate_archive")
        with tempfile.TemporaryDirectory(prefix="mirmir-quality-archive-") as temporary:
            root = Path(temporary)
            repository, commit = self.makeRepository(root)
            (repository / "Mirmir/source.swift").write_text("let dirty = 2\n")
            (repository / "untracked.swift").write_text("let untracked = true\n")
            destination = root / "archive"
            destination.mkdir()
            probe = root / "archive-probe.sh"
            probe.write_text(
                f"#!/bin/sh\nset -eu\n{function}\n"
                'extract_candidate_archive "$1" "$2" "$3" "$4"\n'
            )
            run(
                "sh",
                probe,
                repository,
                commit,
                destination,
                root / "candidate.tar",
                cwd=root,
            )
            self.assertEqual(
                (destination / "Mirmir/source.swift").read_text(),
                "let committed = 1\n",
            )
            self.assertFalse((destination / "untracked.swift").exists())


if __name__ == "__main__":
    unittest.main()
