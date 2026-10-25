#!/usr/bin/env python3
"""Replay historical release tests in their authenticated, separate source context."""
from __future__ import annotations

import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tarfile
from typing import Any


SCRIPT_DIRECTORY = Path(__file__).resolve().parent
HISTORICAL_COMMIT = "cc882c190fcfd9994b2c752d1753e52634ec6b5d"
HISTORICAL_TREE = "960bf3df3a554414781dc41fe122b375e93c020e"
SUITES = {
    "core": ("test_release_qualification_v4", 59),
    "index": ("test_assemble_release_evidence_index_v4", 17),
    "parity": ("test_cpu_metal_parity_v4", 44),
}
OVERLAYS = (
    "release_qualification_v4.py",
    "release_qualification_trust_v4.py",
    "assemble_release_evidence_index_v4.py",
    "test_release_qualification_v4.py",
    "test_assemble_release_evidence_index_v4.py",
    "test_cpu_metal_parity_v4.py",
)
PRESERVED = {
    "script/v4/packaged_candidate_evidence_v4.py": "5ea4b53d5d696714d1d0f00a1df22cb1a0b8f9769f2e70b133139cb05132f117",
    "Mirmir/App/MirmirApp.swift": "a934c527485552f752eed166972c2d02c536e1e05a6548c289dc17b881b057dc",
}

DRIVER = r'''
import importlib,json,sys,unittest
from pathlib import Path
source=Path(sys.argv[1]);module_name=sys.argv[2];expected=int(sys.argv[3]);output=Path(sys.argv[4])
sys.path.insert(0,str(source))
module=importlib.import_module(module_name)
suite=unittest.TestSuite()
for name,value in vars(module).items():
    if isinstance(value,type) and issubclass(value,unittest.TestCase) and value is not unittest.TestCase:
        if name!='CheckedInReleaseLockTests':
            suite.addTests(unittest.defaultTestLoader.loadTestsFromTestCase(value))
def identifiers(value):
    for item in value:
        if isinstance(item,unittest.TestSuite):yield from identifiers(item)
        else:yield item.id()
selected=list(identifiers(suite))
if len(selected)!=expected or len(set(selected))!=expected:
    raise SystemExit(f'test roster differs: expected {expected}, found {len(selected)}')
result=unittest.TextTestRunner(verbosity=2).run(suite)
record={'module':module_name,'expectedTestCount':expected,'selectedTestIDs':selected,
    'testsRun':result.testsRun,'failures':len(result.failures),'errors':len(result.errors),'skips':len(result.skipped)}
output.write_text(json.dumps(record,indent=2,sort_keys=True)+'\n')
raise SystemExit(not(result.wasSuccessful() and result.testsRun==expected and not result.skipped))
'''


class ContextError(ValueError):
    pass


def identity(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def write_json(path: Path, value: Any) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def checked_bytes(path: Path) -> bytes:
    if path.is_symlink() or not path.is_file():
        raise ContextError(f"missing or unsafe source input: {path}")
    return path.read_bytes()


def git(repository: Path, *arguments: str) -> bytes:
    result = subprocess.run(
        ["git", "-C", str(repository), *arguments], capture_output=True, check=False
    )
    if result.returncode:
        raise ContextError("required historical Git input is unavailable: " + result.stderr.decode(errors="replace").strip())
    return result.stdout


def verify_preserved(source: Path, manifest: dict[str, Any]) -> dict[str, str]:
    if manifest.get("sourceCommit") != HISTORICAL_COMMIT:
        raise ContextError("historical fixture commit differs")
    observed = {}
    for row in manifest["files"]:
        relative = row["path"]
        if row["gitMode"] not in {"100644", "100755"}:
            raise ContextError(f"invalid historical Git mode: {relative}")
        data = checked_bytes(source / relative)
        if len(data) != row["byteCount"] or identity(data) != row["sha256"]:
            raise ContextError(f"historical source closure differs: {relative}")
        observed[relative] = identity(data)
    for relative, expected in PRESERVED.items():
        data = checked_bytes(source / relative)
        if identity(data) != expected:
            raise ContextError(f"historical observer/package source differs: {relative}")
        observed[relative] = expected
    return observed


def extract_archive(data: bytes, destination: Path) -> None:
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:") as archive:
        members = archive.getmembers()
        if len(members) > 20_000 or sum(item.size for item in members) > 1024**3:
            raise ContextError("historical source archive exceeds bounds")
        for item in members:
            path = Path(item.name)
            if path.is_absolute() or ".." in path.parts or not (item.isfile() or item.isdir()):
                raise ContextError(f"historical archive has an unsafe member: {item.name}")
        archive.extractall(destination)


def run(arguments: argparse.Namespace) -> int:
    repository = arguments.historical_repository.expanduser().resolve(strict=True)
    output = arguments.output.expanduser().resolve()
    if output.exists():
        raise ContextError(f"refusing to overwrite historical test evidence: {output}")
    tree = git(repository, "rev-parse", HISTORICAL_COMMIT + "^{tree}").decode().strip()
    if tree != HISTORICAL_TREE:
        raise ContextError("historical Git tree differs")
    fixture_path = SCRIPT_DIRECTORY / "test-fixtures/phase1-release-v1/source-manifest.json"
    fixture_bytes = checked_bytes(fixture_path)
    fixture = json.loads(fixture_bytes)
    for row in fixture["files"]:
        entry = git(repository, "ls-tree", HISTORICAL_COMMIT, "--", row["path"]).decode().strip()
        if entry.split(" ", 1)[0] != row["gitMode"]:
            raise ContextError(f"historical Git mode differs: {row['path']}")
    archive_bytes = git(repository, "archive", "--format=tar", HISTORICAL_COMMIT)
    overlays = {name: checked_bytes(SCRIPT_DIRECTORY / name) for name in OVERLAYS}
    output.mkdir(parents=True, mode=0o700)
    source = output / "source-context"
    source.mkdir(mode=0o700)
    extract_archive(archive_bytes, source)
    preserved = verify_preserved(source, fixture)
    for name, data in overlays.items():
        (source / "script/v4" / name).write_bytes(data)
    if verify_preserved(source, fixture) != preserved:
        raise ContextError("a current overlay changed the historical helper/package closure")
    driver = output / "test-context-driver.py"
    driver.write_text(DRIVER)
    records = []
    for name in arguments.suites:
        module, count = SUITES[name]
        result_path = output / (name + "-result.json")
        command = [sys.executable, str(driver), str(source / "script/v4"), module, str(count), str(result_path)]
        environment = dict(os.environ)
        environment["PYTHONPATH"] = str(source / "script/v4")
        with (output / (name + ".log")).open("wb") as log:
            result = subprocess.run(command, cwd=source, env=environment, stdout=log, stderr=subprocess.STDOUT, check=False)
        record = json.loads(result_path.read_text()) if result_path.is_file() else {"module": module, "resultMissing": True}
        records.append({"suite": name, "exitStatus": result.returncode, "result": record})
        if verify_preserved(source, fixture) != preserved:
            raise ContextError("tests changed the authenticated historical source closure")
    for name, data in overlays.items():
        if checked_bytes(source / "script/v4" / name) != data:
            raise ContextError(f"tests changed current overlay source: {name}")
    passed = all(row["exitStatus"] == 0 for row in records)
    write_json(output / "receipt.json", {
        "schemaVersion": "mirmir-historical-release-test-context-v1",
        "historicalCommit": HISTORICAL_COMMIT, "historicalTree": HISTORICAL_TREE,
        "archiveSHA256": identity(archive_bytes), "fixtureManifestSHA256": identity(fixture_bytes),
        "runnerSHA256": identity(checked_bytes(Path(__file__))),
        "currentOverlaySHA256": {name: identity(data) for name, data in overlays.items()},
        "preservedHistoricalSourceSHA256": preserved, "suites": records,
        "allSelectedTestsPassedWithoutSkips": passed,
        "currentCheckedInTestsExecuted": False,
        "freshQualityParityTestsExecuted": False,
    })
    print(output / "receipt.json")
    return 0 if passed else 1


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--historical-repository", type=Path, default=SCRIPT_DIRECTORY.parent.parent)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--suites", nargs="+", choices=tuple(SUITES), default=list(SUITES))
    arguments = parser.parse_args()
    if len(set(arguments.suites)) != len(arguments.suites):
        raise ContextError("duplicate historical suite selection")
    return run(arguments)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (ContextError, OSError, ValueError, KeyError, tarfile.TarError) as error:
        print(f"historical release test context failed closed: {error}", file=sys.stderr)
        raise SystemExit(2)
