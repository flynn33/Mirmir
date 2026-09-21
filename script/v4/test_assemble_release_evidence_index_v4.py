#!/usr/bin/env python3
"""Tamper and aggregate round-trip tests for the release evidence assembler."""

from __future__ import annotations

import contextlib
import copy
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import tempfile
import unittest
from unittest import mock


SCRIPT_DIRECTORY = Path(__file__).resolve().parent


def load_module(name: str, filename: str):
    specification = importlib.util.spec_from_file_location(name, SCRIPT_DIRECTORY / filename)
    assert specification is not None and specification.loader is not None
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


assembler = load_module(
    "assemble_release_evidence_index_v4_for_tests",
    "assemble_release_evidence_index_v4.py",
)
fixture_module = load_module(
    "release_qualification_fixture_for_index_tests",
    "test_release_qualification_v4.py",
)


def write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(value, allow_nan=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


class ReleaseEvidenceIndexAssemblerV4Tests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="mirmir-index-assembler-")
        self.external = tempfile.TemporaryDirectory(prefix="mirmir-index-external-")
        self.root = Path(self.temporary.name)
        self.external_root = Path(self.external.name)
        self.fixture = fixture_module.EvidenceFixture(self.root)
        self.fixture.index_path.unlink()
        external_contract = (
            self.external_root / "release-qualification-contract-v1.json"
        )
        self.fixture.contract_path.replace(external_contract)
        self.fixture.contract_path = external_contract
        self.suites = {
            role: self.root / role for role in assembler.EXPECTED_ROLES
        }
        self.candidate_path = self.external_root / "candidate-identity.json"
        write_json(self.candidate_path, self.fixture.candidate)
        self.output = self.root / "release-candidate-evidence.json"

    def tearDown(self) -> None:
        self.external.cleanup()
        self.temporary.cleanup()

    def assemble(self, **overrides):
        values = {
            "candidate_path": self.candidate_path,
            "evidence_root": self.root,
            "suite_roots": self.suites,
            "contract_path": self.fixture.contract_path,
            "output_path": self.output,
        }
        values.update(overrides)
        return assembler.assemble_index(**values)

    def reseal(self, role: str) -> None:
        self.fixture.reseal_role(role)
        self.fixture.index_path.unlink(missing_ok=True)

    def report_path(self, role: str) -> Path:
        return self.root / self.fixture.entry(role)["path"]

    def mutate_report(self, role: str, mutator) -> None:
        path = self.report_path(role)
        value = json.loads(path.read_text())
        mutator(value)
        write_json(path, value)
        self.reseal(role)

    def seal_path(self, role: str) -> Path:
        return self.root / role / "sealed-manifest.json"

    def test_cli_is_deterministic_and_round_trips_through_existing_aggregator(self) -> None:
        first_model = self.assemble()
        second_model = self.assemble()
        self.assertEqual(
            assembler.canonical_bytes(first_model),
            assembler.canonical_bytes(second_model),
        )
        arguments = [
            "--candidate",
            str(self.candidate_path),
            "--evidence-root",
            str(self.root),
            "--contract",
            str(self.fixture.contract_path),
        ]
        for role in assembler.EXPECTED_ROLES:
            arguments.extend(("--suite", f"{role}={self.suites[role]}"))
        arguments.extend(("--output", str(self.output)))
        stdout = io.StringIO()
        with contextlib.redirect_stdout(stdout):
            self.assertEqual(assembler.main(arguments), 0)
        index = json.loads(self.output.read_text())
        self.assertEqual(self.output.read_bytes(), assembler.canonical_bytes(index) + b"\n")
        self.assertEqual(index["schemaVersion"], assembler.INDEX_SCHEMA)
        self.assertEqual(index["candidate"], self.fixture.candidate)
        self.assertEqual(index["waivers"], [])
        self.assertEqual(
            [entry["role"] for entry in index["evidence"]],
            list(assembler.EXPECTED_ROLES),
        )
        self.assertIn(assembler.sha256(self.output), stdout.getvalue())

        trust_path = self.external_root / "release-trust-root.json"
        fixture_module.trust_builder.write_json(
            trust_path,
            fixture_module.trust_builder.build_trust_root(
                SCRIPT_DIRECTORY,
                self.fixture.contract_path,
            ),
        )
        trust_identity = fixture_module.trust_builder.sha256(trust_path)
        media_replay = mock.Mock()
        media_replay.EvidenceError = ValueError
        media_replay.verify_evidence.side_effect = lambda root: json.loads(
            (root / "report.json").read_text()
        )
        normalized_summary = {
            "schemaVersion": fixture_module.performance_gate.TEST_SUMMARY_SCHEMA,
            "testIdentifier": (
                fixture_module.performance_gate.BASELINE_TEST_IDENTIFIER
            ),
            "result": "Passed",
            "passedTests": 1,
            "failedTests": 0,
            "skippedTests": 0,
        }
        with mock.patch.object(
            fixture_module.qualification,
            "load_locked_performance_evaluator",
            return_value=fixture_module.performance_gate,
        ), mock.patch.object(
            fixture_module.performance_gate,
            "normalized_test_summary",
            return_value=normalized_summary,
        ), mock.patch.object(
            fixture_module.qualification,
            "load_locked_media_evaluator",
            return_value=media_replay,
        ):
            first = fixture_module.qualification.evaluate_candidate(
                self.output,
                self.root,
                self.fixture.contract_path,
                trust_root_path=trust_path,
                expected_trust_root_sha256=trust_identity,
            )
            second = fixture_module.qualification.evaluate_candidate(
                self.output,
                self.root,
                self.fixture.contract_path,
                trust_root_path=trust_path,
                expected_trust_root_sha256=trust_identity,
            )
        self.assertEqual(first, second)
        self.assertTrue(first["releaseQualified"])
        self.assertTrue(all(first["gates"].values()))

    def test_recovery_runner_emits_the_assembler_admitted_top_level_seal(self) -> None:
        runner = (SCRIPT_DIRECTORY / "run_recovery_qualification_v4.sh").read_text()
        emitted_names = re.findall(
            r'--sealed-manifest "\$\{output_directory\}/([^\"]+)"',
            runner,
        )
        self.assertEqual(emitted_names, ["sealed-manifest.json"] * 2)
        self.assertNotIn("recovery-evidence-manifest.json", runner)

        index = self.assemble()
        entry = next(
            item for item in index["evidence"] if item["role"] == "recovery"
        )
        self.assertEqual(
            Path(entry["sealedManifest"]["path"]).name,
            emitted_names[0],
        )

    def test_recovery_candidate_projection_is_recomputed_from_both_captures(self) -> None:
        self.mutate_report(
            "recovery",
            lambda report: report["execution"].update(
                {"sourceCommit": "0" * len(self.fixture.candidate["sourceCommit"])}
            ),
        )
        with self.assertRaisesRegex(
            assembler.AssemblyError,
            r"recovery\.execution\.sourceCommit differs",
        ):
            self.assemble()

        self.tearDown()
        self.setUp()
        self.mutate_report(
            "recovery",
            lambda report: report["captures"][1].update(
                {"applicationArchiveSHA256": "0" * 64}
            ),
        )
        with self.assertRaisesRegex(
            assembler.AssemblyError,
            r"recovery\.captures\[1\]\.applicationArchiveSHA256 differs",
        ):
            self.assemble()

    def test_every_binding_is_derived_from_an_actual_file_and_contract_pointer(self) -> None:
        index = self.assemble()
        contract = json.loads(self.fixture.contract_path.read_text())
        for entry in index["evidence"]:
            role = entry["role"]
            report = json.loads((self.root / entry["path"]).read_text())
            expected = contract["identityBindings"][role]
            self.assertEqual(
                [binding["jsonPointer"] for binding in entry["identityBindings"]],
                expected,
            )
            for binding in entry["identityBindings"]:
                path = self.root / binding["path"]
                self.assertTrue(path.is_file())
                self.assertEqual(binding["byteCount"], path.stat().st_size)
                self.assertEqual(binding["sha256"], assembler.sha256(path))
                self.assertEqual(
                    binding["sha256"],
                    assembler.json_pointer(report, binding["jsonPointer"], "test binding"),
                )

    def test_missing_duplicate_and_unexpected_roles_fail_closed(self) -> None:
        missing = dict(self.suites)
        missing.pop("quality")
        with self.assertRaisesRegex(assembler.AssemblyError, "suite role set mismatch"):
            self.assemble(suite_roots=missing)
        unexpected = dict(self.suites)
        unexpected["unexpected"] = self.suites["quality"]
        with self.assertRaisesRegex(assembler.AssemblyError, "suite role set mismatch"):
            self.assemble(suite_roots=unexpected)
        arguments = [
            "--candidate",
            str(self.candidate_path),
            "--evidence-root",
            str(self.root),
            "--contract",
            str(self.fixture.contract_path),
            "--output",
            str(self.output),
        ]
        for role in assembler.EXPECTED_ROLES:
            arguments.extend(("--suite", f"{role}={self.suites[role]}"))
        arguments.extend(("--suite", f"quality={self.suites['quality']}"))
        with self.assertRaisesRegex(assembler.AssemblyError, "duplicate suite role"):
            assembler.main(arguments)

    def test_candidate_shape_duplicate_key_and_hash_tampering_fail_closed(self) -> None:
        malformed = self.external_root / "malformed.json"
        malformed.write_text('{"sourceCommit":"' + "a" * 40 + '","sourceCommit":"' + "b" * 40 + '"}\n')
        with self.assertRaisesRegex(assembler.AssemblyError, "duplicate JSON key"):
            self.assemble(candidate_path=malformed)

        for name, mutator, message in (
            ("missing", lambda value: value.pop("productBuild"), "field set mismatch"),
            ("unexpected", lambda value: value.update({"extra": True}), "field set mismatch"),
            ("bad-hash", lambda value: value.update({"sourceCommit": "A" * 40}), "lowercase hexadecimal"),
        ):
            with self.subTest(name=name):
                path = self.external_root / f"candidate-{name}.json"
                value = copy.deepcopy(self.fixture.candidate)
                mutator(value)
                write_json(path, value)
                with self.assertRaisesRegex(assembler.AssemblyError, message):
                    self.assemble(candidate_path=path)

    def test_full_quality_and_performance_candidate_drift_fail_closed(self) -> None:
        self.mutate_report(
            "media_preservation",
            lambda report: report["candidate"].update({"sourceCommit": "0" * 40}),
        )
        with self.assertRaisesRegex(assembler.AssemblyError, "media_preservation report candidate differs"):
            self.assemble()

        self.tearDown()
        self.setUp()
        self.mutate_report(
            "quality",
            lambda report: report["identities"].update({"runtimeSourceRevision": "0" * 64}),
        )
        with self.assertRaisesRegex(assembler.AssemblyError, "quality.identities.runtimeSourceRevision differs"):
            self.assemble()

        self.tearDown()
        self.setUp()
        self.mutate_report(
            "same_scope_performance",
            lambda report: report["candidate"]["packagedCandidateIdentity"].update(
                {"applicationArchiveSHA256": "0" * 64}
            ),
        )
        with self.assertRaisesRegex(
            assembler.AssemblyError,
            "performance packaged candidate.applicationArchiveSHA256 differs",
        ):
            self.assemble()

    def test_report_schema_ambiguity_and_unsealed_report_tamper_fail_closed(self) -> None:
        quality_report = self.report_path("quality")
        duplicate = self.root / "quality" / "duplicate-report.json"
        duplicate.write_bytes(quality_report.read_bytes())
        self.reseal("quality")
        with self.assertRaisesRegex(assembler.AssemblyError, "exactly one.*report; found 2"):
            self.assemble()

        self.tearDown()
        self.setUp()
        path = self.report_path("support_matrix")
        value = json.loads(path.read_text())
        value["schemaVersion"] = "wrong-schema"
        write_json(path, value)
        self.reseal("support_matrix")
        with self.assertRaisesRegex(assembler.AssemblyError, "exactly one.*report; found 0"):
            self.assemble()

        self.tearDown()
        self.setUp()
        path = self.report_path("recovery")
        path.write_bytes(path.read_bytes() + b"\n")
        with self.assertRaisesRegex(assembler.AssemblyError, "exactly one complete top-level seal"):
            self.assemble()

    def test_seal_duplicate_path_escape_and_unsealed_file_fail_closed(self) -> None:
        seal = self.seal_path("quality")
        value = json.loads(seal.read_text())
        value["artifacts"].append(copy.deepcopy(value["artifacts"][0]))
        write_json(seal, value)
        with self.assertRaisesRegex(assembler.AssemblyError, "repeats artifact path"):
            self.assemble()

        self.tearDown()
        self.setUp()
        seal = self.seal_path("media_preservation")
        value = json.loads(seal.read_text())
        value["artifacts"][0]["path"] = "../escape"
        write_json(seal, value)
        with self.assertRaisesRegex(assembler.AssemblyError, "safe canonical relative path"):
            self.assemble()

        self.tearDown()
        self.setUp()
        (self.root / "p06_reproduction" / "unsealed.bin").write_bytes(b"unsealed")
        with self.assertRaisesRegex(assembler.AssemblyError, "exactly one complete top-level seal"):
            self.assemble()

    def test_producer_artifact_set_algorithms_are_verified(self) -> None:
        media_seal = self.seal_path("media_preservation")
        media = json.loads(media_seal.read_text())
        media["artifactSetSHA256"] = assembler.media_artifact_set_sha(
            media["artifacts"]
        )
        write_json(media_seal, media)
        self.assemble()
        media["artifactSetSHA256"] = "0" * 64
        write_json(media_seal, media)
        with self.assertRaisesRegex(assembler.AssemblyError, "artifact-set identity differs"):
            self.assemble()

        self.tearDown()
        self.setUp()
        smoke_seal = self.seal_path("notarized_smoke")
        smoke = json.loads(smoke_seal.read_text())
        smoke["artifactCount"] = len(smoke["artifacts"])
        smoke["artifactSetSHA256"] = hashlib.sha256(
            assembler.canonical_bytes(smoke["artifacts"])
        ).hexdigest()
        write_json(smoke_seal, smoke)
        self.assemble()
        smoke["artifactCount"] += 1
        write_json(smoke_seal, smoke)
        with self.assertRaisesRegex(assembler.AssemblyError, "artifact count differs"):
            self.assemble()

    def test_symlink_hardlink_and_suite_root_alias_fail_closed(self) -> None:
        source = self.report_path("quality")
        (self.root / "quality" / "report-link.json").symlink_to(source)
        with self.assertRaisesRegex(assembler.AssemblyError, "symbolic link"):
            self.assemble()

        self.tearDown()
        self.setUp()
        source = self.report_path("recovery")
        os.link(source, self.root / "recovery" / "report-hardlink.json")
        with self.assertRaisesRegex(assembler.AssemblyError, "hard-linked"):
            self.assemble()

        self.tearDown()
        self.setUp()
        alias = self.external_root / "quality-alias"
        alias.symlink_to(self.suites["quality"], target_is_directory=True)
        suites = dict(self.suites)
        suites["quality"] = alias
        with self.assertRaisesRegex(assembler.AssemblyError, "symbolic link"):
            self.assemble(suite_roots=suites)

    def test_missing_binding_artifact_and_contract_binding_weakening_fail_closed(self) -> None:
        self.mutate_report(
            "quality",
            lambda report: report["identities"].update({"metricToolSHA256": "0" * 64}),
        )
        with self.assertRaisesRegex(assembler.AssemblyError, "has no sealed role artifact"):
            self.assemble()

        self.tearDown()
        self.setUp()
        contract = json.loads(self.fixture.contract_path.read_text())
        contract["identityBindings"]["quality"].append(
            contract["identityBindings"]["quality"][0]
        )
        path = self.external_root / "weakened-contract.json"
        write_json(path, contract)
        with self.assertRaisesRegex(assembler.AssemblyError, "contains duplicates"):
            self.assemble(contract_path=path)

        self.tearDown()
        self.setUp()
        contract = json.loads(self.fixture.contract_path.read_text())
        contract["hashAlgorithm"] = "sha512"
        path = self.external_root / "wrong-hash-contract.json"
        write_json(path, contract)
        with self.assertRaisesRegex(assembler.AssemblyError, "hash algorithm"):
            self.assemble(contract_path=path)

    def test_cross_lane_hash_match_cannot_replace_a_missing_role_binding(self) -> None:
        entry = self.fixture.entry("media_preservation")
        binding = next(
            item
            for item in entry["identityBindings"]
            if item["jsonPointer"] == "/candidate/runtimeManifestFileSHA256"
        )
        (self.root / binding["path"]).unlink()
        self.reseal("media_preservation")
        with self.assertRaisesRegex(assembler.AssemblyError, "has no sealed role artifact"):
            self.assemble()

    def test_invalid_json_pointer_escape_in_contract_fails_closed(self) -> None:
        contract = json.loads(self.fixture.contract_path.read_text())
        contract["identityBindings"]["quality"].append("/bad~2token")
        path = self.external_root / "invalid-pointer-contract.json"
        write_json(path, contract)
        with self.assertRaisesRegex(assembler.AssemblyError, "invalid escape"):
            self.assemble(contract_path=path)

    def test_unexpected_root_file_overwrite_and_output_escape_fail_closed(self) -> None:
        (self.root / "unexpected.bin").write_bytes(b"outside suites")
        with self.assertRaisesRegex(assembler.AssemblyError, "unexpected file outside"):
            self.assemble()

        self.tearDown()
        self.setUp()
        self.output.write_bytes(b"existing")
        with self.assertRaisesRegex(assembler.AssemblyError, "output already exists"):
            self.assemble()

        self.tearDown()
        self.setUp()
        with self.assertRaisesRegex(assembler.AssemblyError, "direct child of the evidence root"):
            self.assemble(output_path=self.external_root / "escaped.json")

    def test_atomic_publication_never_overwrites_a_racing_output(self) -> None:
        index = self.assemble()
        self.output.write_bytes(b"racing publisher")
        with self.assertRaises(FileExistsError):
            assembler.write_index(self.output, index)
        self.assertEqual(self.output.read_bytes(), b"racing publisher")
        self.assertFalse(
            (self.root / f".{self.output.name}.assembling").exists()
        )

    def test_parity_layout_selects_the_locked_source_artifacts(self) -> None:
        index = self.assemble()
        entry = next(
            item for item in index["evidence"] if item["role"] == "cpu_metal_parity"
        )
        names = {
            binding["jsonPointer"]: Path(binding["path"]).name
            for binding in entry["identityBindings"]
        }
        self.assertEqual(names["/contractSHA256"], "cpu-metal-parity-contract-v2.json")
        self.assertEqual(names["/identities/captureSourceSHA256"], "MirmirApp.swift")
        self.assertEqual(names["/identities/evaluatorSHA256"], "cpu_metal_parity_v4.py")
        self.assertEqual(names["/identities/runnerSHA256"], "run_cpu_metal_parity_v4.sh")


if __name__ == "__main__":
    unittest.main()
