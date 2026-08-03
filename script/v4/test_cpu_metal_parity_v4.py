#!/usr/bin/env python3
"""Tamper and identity tests for the locked ASH v4 CPU/Metal parity gate."""

from __future__ import annotations

import argparse
import copy
import importlib.util
import json
from pathlib import Path
import shutil
import tempfile
import unittest


SCRIPT_DIRECTORY = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location(
    "cpu_metal_parity_v4", SCRIPT_DIRECTORY / "cpu_metal_parity_v4.py"
)
assert SPEC is not None and SPEC.loader is not None
parity = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(parity)


def identity(label: str) -> str:
    return parity.sha256_bytes(label.encode("utf-8"))


class ParityEvidenceFixture:
    TOOL_NAMES = (
        "cpu-metal-parity-contract-v1.json",
        "ParityQualificationCaptureTests.swift",
        "cpu_metal_parity_v4.py",
        "run_cpu_metal_parity_v4.sh",
    )

    def __init__(self, root: Path):
        self.root = root
        self.tools = root / "sealed-tools"
        self.tools.mkdir(parents=True)
        for name in self.TOOL_NAMES:
            shutil.copy2(SCRIPT_DIRECTORY / name, self.tools / name)
        self.contract_path = self.tools / self.TOOL_NAMES[0]
        self.capture_source = self.tools / self.TOOL_NAMES[1]
        self.evaluator = self.tools / self.TOOL_NAMES[2]
        self.runner = self.tools / self.TOOL_NAMES[3]
        self.contract = parity.load_json(self.contract_path)
        self.contract_sha = parity.sha256_file(self.contract_path)
        self.source_revision = "1" * 40
        self.runtime = {
            "mode": "fixture",
            "runtimeID": "ash-p06-deterministic-v4",
            "releaseStatus": "release_qualified",
            "manifestSHA256": identity("fixture-runtime-manifest-canonical"),
            "manifestFileSHA256": identity("fixture-runtime-manifest-file"),
            "sourceRevision": "2" * 40,
            "builderSourceSHA256": identity("fixture-runtime-builder"),
            "trustRootConfigured": False,
            "bindingVerified": True,
        }
        self.capture_a = root / "capture-a"
        self.capture_b = root / "capture-b"
        self._build_capture(self.capture_a, "process-a")
        self._build_capture(self.capture_b, "process-b")
        self.candidate_path = root / "candidate-identity.json"
        self.candidate = {
            "sourceCommit": self.source_revision,
            "sourceTreeIdentitySHA256": identity("fixture-source-tree"),
            "runtimeManifestSHA256": self.runtime["manifestSHA256"],
            "runtimeManifestFileSHA256": self.runtime["manifestFileSHA256"],
            "runtimeArtifactSetSHA256": identity("fixture-runtime-artifacts"),
            "runtimeSourceRevision": self.runtime["sourceRevision"],
            "releaseConfigurationSHA256": identity("fixture-release-configuration"),
            "appBundleSHA256": identity("fixture-app-bundle"),
            "bundleIdentifier": "com.mirmir.parity-tests",
            "productVersion": "4.0-test",
            "productBuild": "test",
        }
        parity.write_json(self.candidate_path, self.candidate)

    def _build_capture(self, directory: Path, process_id: str) -> None:
        directory.mkdir(parents=True)
        cases: list[dict[str, object]] = []
        for definition in self.contract["cases"]:
            case_id = definition["id"]
            case_directory = directory / "cases" / case_id
            case_directory.mkdir(parents=True)
            visible = ("visible:" + case_id).encode("utf-8")
            attachments = parity.canonical_json(
                {"schemaVersion": "fixture-attachments-v1", "id": case_id}
            )
            backends: dict[str, object] = {}
            for backend in ("cpu", "metal"):
                visible_path = case_directory / f"{backend}-visible.bin"
                repeat_visible_path = (
                    case_directory / f"{backend}-repeat-visible.bin"
                )
                attachments_path = (
                    case_directory / f"{backend}-attachments.json"
                )
                repeat_attachments_path = (
                    case_directory / f"{backend}-repeat-attachments.json"
                )
                for path in (visible_path, repeat_visible_path):
                    path.write_bytes(visible)
                for path in (attachments_path, repeat_attachments_path):
                    path.write_bytes(attachments)
                schedules: list[dict[str, object]] = []
                for schedule in self.contract["tileSchedules"]:
                    path = case_directory / f"{backend}-tile-{schedule}.bin"
                    path.write_bytes(visible)
                    schedules.append(
                        {
                            "schedule": schedule,
                            "artifact": parity.descriptor(path, directory),
                        }
                    )
                backends[backend] = {
                    "visible": parity.descriptor(visible_path, directory),
                    "attachments": parity.descriptor(attachments_path, directory),
                    "repeatVisible": parity.descriptor(
                        repeat_visible_path, directory
                    ),
                    "repeatAttachments": parity.descriptor(
                        repeat_attachments_path, directory
                    ),
                    "tileSchedules": schedules,
                }
            coverage = set(definition["coverage"])
            metadata: dict[str, object] = {
                "id": case_id,
                "sourceWidth": definition["sourceWidth"],
                "sourceHeight": definition["sourceHeight"],
                "targetWidth": definition["targetWidth"],
                "targetHeight": definition["targetHeight"],
                "horizontalUniquePhaseCount": definition["targetWidth"],
                "verticalUniquePhaseCount": definition["targetHeight"],
                "spatialPlanSHA256": identity(case_id + ":spatial-plan"),
                "kernelIRSHA256": identity(case_id + ":kernel-ir"),
                "cpuSourcePaddingByteCount": 17,
                "cpuDestinationPaddingByteCount": 23,
                "metalSourcePaddingByteCount": 17,
                "metalDestinationPaddingByteCount": 23,
                "cpuPaddingSentinelPreserved": True,
                "metalPaddingSentinelPreserved": True,
            }
            temporal = bool(
                coverage & {"temporal_history", "temporal_reset", "scene_cut"}
            )
            if temporal:
                metadata["temporal"] = {
                    "generations": [1, 1, 2],
                    "historyFrameCounts": [1, 2, 1],
                    "continuousFrameDiffersFromReset": True,
                    "sceneCutEqualsSpatialReset": True,
                    "checkpointsCanonical": True,
                }
            metadata_path = case_directory / "case-metadata.json"
            parity.write_json(metadata_path, metadata)
            cases.append(
                {
                    "id": case_id,
                    "definition": copy.deepcopy(definition),
                    "cpu": backends["cpu"],
                    "metal": backends["metal"],
                    "metadata": parity.descriptor(metadata_path, directory),
                    "repeatRunIdentityPass": True,
                    "withinProcessCPUAndMetalPass": True,
                    "tileScheduleIdentityPass": True,
                    "temporalHistoryExercised": "temporal_history" in coverage,
                    "temporalResetExercised": "temporal_reset" in coverage,
                    "sceneCutExercised": "scene_cut" in coverage,
                    "stridePaddingAdversaryExercised": (
                        "stride_padding_adversary" in coverage
                    ),
                    "arbitraryRationalPhaseExercised": (
                        "arbitrary_rational_phase" in coverage
                    ),
                }
            )
        capture = {
            "schemaVersion": self.contract["captureSchemaVersion"],
            "contractSHA256": self.contract_sha,
            "captureSourceSHA256": self.contract["tools"][
                "captureSourceSHA256"
            ],
            "sourceRevision": self.source_revision,
            "buildConfiguration": "Release",
            "processRunID": process_id,
            "runtime": copy.deepcopy(self.runtime),
            "cases": cases,
        }
        parity.write_json(directory / "capture.json", capture)
        self.reseal(directory)

    def reseal(self, directory: Path) -> None:
        manifest_path = directory / "artifact-manifest.json"
        artifacts = [
            parity.descriptor(path, directory)
            for path in sorted(directory.rglob("*"))
            if path.is_file() and path != manifest_path
        ]
        parity.write_json(
            manifest_path,
            {
                "schemaVersion": parity.CAPTURE_MANIFEST_SCHEMA,
                "artifacts": artifacts,
            },
        )

    def evaluate(self, allow_fixture_runtime: bool = True) -> dict[str, object]:
        return parity.evaluate(
            self.contract_path,
            self.capture_a,
            self.capture_b,
            self.candidate_path,
            self.capture_source,
            self.evaluator,
            self.runner,
            self.root,
            allow_fixture_runtime,
        )

    def _replace_descriptors(
        self, value: object, replacements: dict[str, Path], directory: Path
    ) -> None:
        if isinstance(value, dict):
            relative = value.get("path")
            if isinstance(relative, str) and relative in replacements:
                value.clear()
                value.update(parity.descriptor(replacements[relative], directory))
                return
            for nested in value.values():
                self._replace_descriptors(nested, replacements, directory)
        elif isinstance(value, list):
            for nested in value:
                self._replace_descriptors(nested, replacements, directory)

    def replace_and_rebind(
        self, directory: Path, replacements: dict[str, bytes]
    ) -> None:
        paths: dict[str, Path] = {}
        for relative, data in replacements.items():
            path = directory / relative
            path.write_bytes(data)
            paths[relative] = path
        capture_path = directory / "capture.json"
        capture = parity.load_json(capture_path)
        self._replace_descriptors(capture, paths, directory)
        parity.write_json(capture_path, capture)
        self.reseal(directory)

    def replace_visible_group(
        self,
        directory: Path,
        case_id: str,
        backends: tuple[str, ...],
        data: bytes,
    ) -> None:
        replacements: dict[str, bytes] = {}
        for backend in backends:
            prefix = f"cases/{case_id}/{backend}"
            replacements[f"{prefix}-visible.bin"] = data
            replacements[f"{prefix}-repeat-visible.bin"] = data
            for schedule in self.contract["tileSchedules"]:
                replacements[f"{prefix}-tile-{schedule}.bin"] = data
        self.replace_and_rebind(directory, replacements)

    def mutate_metadata(self, case_id: str, key: str, value: object) -> None:
        relative = f"cases/{case_id}/case-metadata.json"
        path = self.capture_a / relative
        metadata = parity.load_json(path)
        metadata[key] = value
        self.replace_and_rebind(
            self.capture_a, {relative: parity.canonical_json(metadata)}
        )

    def publish(self) -> tuple[Path, Path]:
        report_path = self.root / "cpu-metal-parity-report.json"
        manifest_path = self.root / "artifact-manifest.json"
        parity.write_json(report_path, self.evaluate())
        parity.write_json(
            manifest_path,
            parity.make_root_manifest(self.root, manifest_path),
        )
        return report_path, manifest_path

    def verify_arguments(self, report: Path, manifest: Path) -> argparse.Namespace:
        return argparse.Namespace(
            contract=self.contract_path,
            capture_a=self.capture_a,
            capture_b=self.capture_b,
            candidate=self.candidate_path,
            capture_source=self.capture_source,
            evaluator=self.evaluator,
            runner=self.runner,
            evidence_root=self.root,
            report=report,
            manifest=manifest,
            allow_fixture_runtime=True,
        )


class CPUMetalParityQualificationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.fixture = ParityEvidenceFixture(self.root)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def test_fixture_smoke_is_deterministic_but_never_release_eligible(self) -> None:
        first = self.fixture.evaluate()
        second = self.fixture.evaluate()
        self.assertEqual(parity.canonical_json(first), parity.canonical_json(second))
        self.assertEqual(first["schemaVersion"], parity.REPORT_SCHEMA)
        self.assertFalse(first["releaseEligible"])
        self.assertFalse(first["byteParityGatePass"])
        self.assertEqual(first["identities"], self.fixture.contract["tools"])
        self.assertEqual(
            {case["id"] for case in first["cases"]},
            {case["id"] for case in self.fixture.contract["cases"]},
        )

    def test_final_gate_rejects_fixture_runtime(self) -> None:
        with self.assertRaisesRegex(
            parity.ParityEvidenceError,
            "requires the production runtime",
        ):
            self.fixture.evaluate(allow_fixture_runtime=False)

    def test_raw_artifact_tamper_is_rejected_by_nested_seal(self) -> None:
        case_id = self.fixture.contract["cases"][0]["id"]
        path = self.fixture.capture_a / f"cases/{case_id}/cpu-visible.bin"
        path.write_bytes(path.read_bytes() + b"tamper")
        with self.assertRaisesRegex(parity.ParityEvidenceError, "byte count mismatch"):
            self.fixture.evaluate()

    def test_resealed_cpu_metal_visible_divergence_is_rejected(self) -> None:
        case_id = self.fixture.contract["cases"][0]["id"]
        self.fixture.replace_visible_group(
            self.fixture.capture_a, case_id, ("metal",), b"different-metal-pixels"
        )
        with self.assertRaisesRegex(parity.ParityEvidenceError, "CPU/Metal visible"):
            self.fixture.evaluate()

    def test_resealed_attachment_divergence_is_rejected(self) -> None:
        case_id = self.fixture.contract["cases"][1]["id"]
        prefix = f"cases/{case_id}/metal"
        data = parity.canonical_json({"attachment": "changed"})
        self.fixture.replace_and_rebind(
            self.fixture.capture_a,
            {
                f"{prefix}-attachments.json": data,
                f"{prefix}-repeat-attachments.json": data,
            },
        )
        with self.assertRaisesRegex(parity.ParityEvidenceError, "attachments differ"):
            self.fixture.evaluate()

    def test_resealed_repeat_divergence_is_rejected(self) -> None:
        case_id = self.fixture.contract["cases"][2]["id"]
        relative = f"cases/{case_id}/cpu-repeat-visible.bin"
        self.fixture.replace_and_rebind(
            self.fixture.capture_a, {relative: b"different-repeat"}
        )
        with self.assertRaisesRegex(parity.ParityEvidenceError, "repeat visible"):
            self.fixture.evaluate()

    def test_resealed_tile_schedule_divergence_is_rejected(self) -> None:
        case_id = self.fixture.contract["cases"][3]["id"]
        relative = f"cases/{case_id}/cpu-tile-reverse.bin"
        self.fixture.replace_and_rebind(
            self.fixture.capture_a, {relative: b"schedule-dependent"}
        )
        with self.assertRaisesRegex(parity.ParityEvidenceError, "tile schedule reverse"):
            self.fixture.evaluate()

    def test_resealed_cross_process_divergence_is_rejected(self) -> None:
        case_id = self.fixture.contract["cases"][4]["id"]
        self.fixture.replace_visible_group(
            self.fixture.capture_b,
            case_id,
            ("cpu", "metal"),
            b"different-second-process",
        )
        with self.assertRaisesRegex(parity.ParityEvidenceError, "cross-process mismatch"):
            self.fixture.evaluate()

    def test_temporal_generation_claim_is_recomputed(self) -> None:
        case_id = next(
            case["id"]
            for case in self.fixture.contract["cases"]
            if "temporal_history" in case["coverage"]
        )
        path = self.fixture.capture_a / f"cases/{case_id}/case-metadata.json"
        metadata = parity.load_json(path)
        metadata["temporal"]["generations"] = [1, 2, 3]
        self.fixture.replace_and_rebind(
            self.fixture.capture_a,
            {
                f"cases/{case_id}/case-metadata.json": parity.canonical_json(
                    metadata
                )
            },
        )
        with self.assertRaisesRegex(parity.ParityEvidenceError, "generation evidence"):
            self.fixture.evaluate()

    def test_stride_padding_claim_is_recomputed(self) -> None:
        case_id = next(
            case["id"]
            for case in self.fixture.contract["cases"]
            if "stride_padding_adversary" in case["coverage"]
        )
        self.fixture.mutate_metadata(case_id, "cpuSourcePaddingByteCount", 0)
        with self.assertRaisesRegex(parity.ParityEvidenceError, "padded stride"):
            self.fixture.evaluate()

    def test_capture_manifest_must_be_complete(self) -> None:
        (self.fixture.capture_a / "unsealed.bin").write_bytes(b"unsealed")
        with self.assertRaisesRegex(parity.ParityEvidenceError, "not complete"):
            self.fixture.evaluate()

    def test_symbolic_links_are_rejected(self) -> None:
        target = self.fixture.capture_a / "capture.json"
        (self.fixture.capture_a / "capture-alias.json").symlink_to(target)
        with self.assertRaisesRegex(parity.ParityEvidenceError, "symbolic link"):
            self.fixture.evaluate()

    def test_locked_evaluator_identity_is_enforced(self) -> None:
        self.fixture.evaluator.write_bytes(
            self.fixture.evaluator.read_bytes() + b"\n# modified\n"
        )
        with self.assertRaisesRegex(parity.ParityEvidenceError, "evaluatorSHA256"):
            self.fixture.evaluate()

    def test_candidate_runtime_binding_is_enforced(self) -> None:
        candidate = copy.deepcopy(self.fixture.candidate)
        candidate["runtimeManifestSHA256"] = identity("stale-runtime")
        parity.write_json(self.fixture.candidate_path, candidate)
        with self.assertRaisesRegex(parity.ParityEvidenceError, "runtime manifest identity"):
            self.fixture.evaluate()

    def test_duplicate_json_keys_are_rejected(self) -> None:
        self.fixture.candidate_path.write_text(
            '{"sourceCommit":"' + self.fixture.source_revision
            + '","sourceCommit":"' + self.fixture.source_revision + '"}\n',
            encoding="utf-8",
        )
        with self.assertRaisesRegex(parity.ParityEvidenceError, "duplicate JSON key"):
            self.fixture.evaluate()

    def test_published_report_tamper_is_rejected(self) -> None:
        report_path, manifest_path = self.fixture.publish()
        parity.command_verify(
            self.fixture.verify_arguments(report_path, manifest_path)
        )
        report = parity.load_json(report_path)
        report["byteParityGatePass"] = True
        parity.write_json(report_path, report)
        with self.assertRaisesRegex(parity.ParityEvidenceError, "published parity report"):
            parity.command_verify(
                self.fixture.verify_arguments(report_path, manifest_path)
            )

    def test_root_seal_rejects_new_or_changed_evidence(self) -> None:
        _, manifest_path = self.fixture.publish()
        (self.root / "late-artifact.bin").write_bytes(b"not sealed")
        with self.assertRaisesRegex(parity.ParityEvidenceError, "root seal differs"):
            parity.verify_root_manifest(self.root, manifest_path)


if __name__ == "__main__":
    unittest.main()
