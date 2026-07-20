from __future__ import annotations

import copy
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPOSITORY_ROOT / "Scripts"))

from r01_observation_waiver import (  # noqa: E402
    ANCHORS,
    OUTPUT_JSON_PATH,
    OUTPUT_MARKDOWN_PATH,
    REQUIRED_SOURCE_PATHS,
    SCHEMA_PATH,
    build_matrix,
    canonical_json_bytes,
    main,
    render_markdown,
    semantic_errors,
    validate_outputs,
    validate_unassigned_inputs,
)
from r01_preregistration import (  # noqa: E402
    FIXTURE_CATALOG_PATH,
    PREREGISTRATION_PATH,
)


class R01ObservationWaiverTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary_directory.name)
        for relative in REQUIRED_SOURCE_PATHS + (
            PREREGISTRATION_PATH,
            FIXTURE_CATALOG_PATH,
        ):
            destination = self.root / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(REPOSITORY_ROOT / relative, destination)
        self.git("init", "-q")
        self.git("config", "user.name", "Mirmir Tests")
        self.git("config", "user.email", "mirmir-tests@example.invalid")
        self.git("add", ".")
        self.git("commit", "-q", "-m", "R01 not-observed source")
        self.commit = self.git("rev-parse", "HEAD").stdout.strip()
        self.timestamp = "2026-07-20T12:00:00Z"

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def git(self, *arguments: str) -> subprocess.CompletedProcess[str]:
        result = subprocess.run(
            ("git", *arguments),
            cwd=self.root,
            check=False,
            capture_output=True,
            text=True,
        )
        if result.returncode != 0:
            self.fail(
                f"git {' '.join(arguments)} failed: {result.stderr or result.stdout}"
            )
        return result

    def write_outputs(self, matrix: dict[str, object]) -> None:
        json_path = self.root / OUTPUT_JSON_PATH
        markdown_path = self.root / OUTPUT_MARKDOWN_PATH
        json_path.parent.mkdir(parents=True, exist_ok=True)
        json_path.write_bytes(canonical_json_bytes(matrix))
        markdown_path.write_text(render_markdown(matrix), encoding="utf-8")

    def test_builds_exact_unobserved_four_by_eighteen_matrix(self) -> None:
        matrix = build_matrix(self.root, self.commit, self.timestamp)
        self.assertEqual([value["anchor"] for value in matrix["anchors"]], list(ANCHORS))
        self.assertEqual(len(matrix["capabilities"]), 18)
        for capability in matrix["capabilities"]:
            self.assertEqual(
                [value["anchor"] for value in capability["anchor_records"]],
                list(ANCHORS),
            )
            self.assertTrue(
                all(
                    value["observation_status"] == "not_observed"
                    and value["runtime_disposition"] == "diagnostic_only"
                    and value["measurement_status"] == "not_measured"
                    and value["performance_claims"] == "forbidden"
                    for value in capability["anchor_records"]
                )
            )

    def test_write_and_check_need_no_host_report_model_or_simulator(self) -> None:
        self.assertEqual(
            main(
                [
                    "--write",
                    "--root",
                    str(self.root),
                    "--source-commit",
                    self.commit,
                    "--generated-at",
                    self.timestamp,
                ]
            ),
            0,
        )
        self.assertEqual(validate_outputs(self.root), [])
        self.assertEqual(main(["--check", "--root", str(self.root)]), 0)

    def test_generation_rejects_dirty_or_non_head_source(self) -> None:
        dirty = self.root / "untracked.txt"
        dirty.write_text("dirty\n", encoding="utf-8")
        self.assertEqual(
            main(
                [
                    "--write",
                    "--root",
                    str(self.root),
                    "--source-commit",
                    self.commit,
                    "--generated-at",
                    self.timestamp,
                ]
            ),
            1,
        )
        dirty.unlink()
        self.git("commit", "--allow-empty", "-q", "-m", "new head")
        self.assertEqual(
            main(
                [
                    "--write",
                    "--root",
                    str(self.root),
                    "--source-commit",
                    self.commit,
                    "--generated-at",
                    self.timestamp,
                ]
            ),
            1,
        )

    def test_model_identity_or_hash_claim_is_rejected(self) -> None:
        matrix = build_matrix(self.root, self.commit, self.timestamp)
        matrix["model_observation"]["identity"] = "invented-model"
        self.assertTrue(
            any("model_observation" in error for error in semantic_errors(self.root, matrix))
        )

    def test_performance_field_is_rejected(self) -> None:
        matrix = build_matrix(self.root, self.commit, self.timestamp)
        matrix["capabilities"][0]["anchor_records"][0]["measurements"] = {}
        errors = semantic_errors(self.root, matrix)
        self.assertTrue(any("measurements is forbidden" in error for error in errors), errors)

    def test_observed_runtime_mutation_is_rejected(self) -> None:
        matrix = build_matrix(self.root, self.commit, self.timestamp)
        record = matrix["capabilities"][0]["anchor_records"][0]
        record["runtime_disposition"] = "runnable"
        errors = semantic_errors(self.root, matrix)
        self.assertTrue(any("entirely unobserved" in error for error in errors), errors)

    def test_source_binding_mutation_is_rejected(self) -> None:
        matrix = build_matrix(self.root, self.commit, self.timestamp)
        matrix["preregistration_binding"]["sha256"] = "1" * 64
        errors = semantic_errors(self.root, matrix)
        self.assertTrue(any("preregistration_binding" in error for error in errors), errors)

    def test_assigned_host_source_is_rejected(self) -> None:
        path = self.root / PREREGISTRATION_PATH
        preregistration = json.loads(path.read_text(encoding="utf-8"))
        assignment = preregistration["anchor_assignments"][0]
        assignment["assignment_state"] = "assigned"
        assignment["host_profile"] = {"invented": "host"}
        path.write_text(
            json.dumps(preregistration, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        self.git("add", PREREGISTRATION_PATH.as_posix())
        self.git("commit", "-q", "-m", "assign host")
        commit = self.git("rev-parse", "HEAD").stdout.strip()
        errors = validate_unassigned_inputs(self.root, commit)
        self.assertTrue(any("must remain unassigned" in error for error in errors), errors)
        self.assertTrue(any("must not contain a host profile" in error for error in errors), errors)

    def test_markdown_drift_is_rejected(self) -> None:
        matrix = build_matrix(self.root, self.commit, self.timestamp)
        self.write_outputs(matrix)
        path = self.root / OUTPUT_MARKDOWN_PATH
        path.write_text("mutated\n", encoding="utf-8")
        errors = validate_outputs(self.root)
        self.assertTrue(any("differs from deterministic output" in error for error in errors))

    def test_matrix_drift_is_rejected(self) -> None:
        matrix = build_matrix(self.root, self.commit, self.timestamp)
        self.write_outputs(matrix)
        mutated = copy.deepcopy(matrix)
        mutated["anchors"][0]["hardware_observation"] = "observed"
        (self.root / OUTPUT_JSON_PATH).write_bytes(canonical_json_bytes(mutated))
        errors = validate_outputs(self.root)
        self.assertTrue(any("anchors differ" in error for error in errors), errors)


if __name__ == "__main__":
    unittest.main()
