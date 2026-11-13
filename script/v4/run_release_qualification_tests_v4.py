#!/usr/bin/env python3
"""Run current and historical release-verifier tests in separate source contexts."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys


SCRIPT_DIRECTORY = Path(__file__).resolve().parent
CURRENT_CONTEXTS = {
    "current-locks": ["test_release_qualification_v4.CheckedInReleaseLockTests"],
    "fresh-lanes": ["test_release_chroma_phase_v4"],
    "trust-boundaries": ["test_phase2_trust_closure_v4"],
    "current-readers": [
        "test_quality_contract_phase2_v4", "test_natural_quality_corpus",
        "test_chroma_geometry_v4", "test_quality_gate_v4",
        "test_select_simulated_candidate_v4", "test_derive_m7_quality_contract_v4",
    ],
    "packaged-runner": [
        "test_packaged_candidate_evidence_v4", "test_release_runner_source_identity_v4",
    ],
}
CONTEXTS = (*CURRENT_CONTEXTS, "historical")
DRIVER = r'''
import json,sys,unittest
from pathlib import Path
result_path=Path(sys.argv[1]);names=sys.argv[2:]
suite=unittest.defaultTestLoader.loadTestsFromNames(names)
def identifiers(value):
    for item in value:
        if isinstance(item,unittest.TestSuite):yield from identifiers(item)
        else:yield item.id()
selected=list(identifiers(suite))
if not selected or len(selected)!=len(set(selected)):raise SystemExit('invalid current test roster')
result=unittest.TextTestRunner(verbosity=2).run(suite)
record={'selectedTestIDs':selected,'testsRun':result.testsRun,'failures':len(result.failures),
    'errors':len(result.errors),'skips':len(result.skipped)}
result_path.write_text(json.dumps(record,indent=2,sort_keys=True)+'\n')
raise SystemExit(not(result.wasSuccessful() and result.testsRun==len(selected) and not result.skipped))
'''


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--historical-repository", type=Path, default=SCRIPT_DIRECTORY.parent.parent)
    parser.add_argument("--contexts", nargs="+", choices=CONTEXTS, default=list(CONTEXTS))
    arguments = parser.parse_args()
    if len(arguments.contexts) != len(set(arguments.contexts)):
        parser.error("duplicate test context")
    output = arguments.output.expanduser().resolve()
    if output.exists() or arguments.output.is_symlink():
        parser.error("refusing to overwrite existing verification evidence")
    output.mkdir(parents=True, mode=0o700)
    driver = output / "current-test-context-driver.py"
    driver.write_text(DRIVER)
    environment = dict(os.environ)
    environment["PYTHONPATH"] = str(SCRIPT_DIRECTORY)
    contexts = []
    for name in arguments.contexts:
        result_path = output / (name + "-result.json")
        if name == "historical":
            command = [
                sys.executable, str(SCRIPT_DIRECTORY / "run_historical_release_tests_v4.py"),
                "--historical-repository", str(arguments.historical_repository),
                "--output", str(output / "historical"),
            ]
        else:
            command = [sys.executable, str(driver), str(result_path), *CURRENT_CONTEXTS[name]]
        with (output / (name + ".log")).open("wb") as log:
            process = subprocess.run(
                command, cwd=SCRIPT_DIRECTORY.parent.parent, env=environment,
                stdout=log, stderr=subprocess.STDOUT, check=False,
            )
        contexts.append({
            "context": name, "command": command, "exitStatus": process.returncode,
            "resultPath": str((output / "historical/receipt.json") if name == "historical" else result_path),
        })
    passed = all(context["exitStatus"] == 0 for context in contexts)
    receipt = {
        "schemaVersion": "mirmir-release-verifier-test-contexts-v2",
        "scope": "verification-tool regression tests; application/release acceptance is separate",
        "sourceDirectory": str(SCRIPT_DIRECTORY), "runnerSHA256": sha256(Path(__file__)),
        "contexts": contexts, "allSelectedContextsPassedWithoutSkips": passed,
    }
    (output / "receipt.json").write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n")
    print(output / "receipt.json")
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
