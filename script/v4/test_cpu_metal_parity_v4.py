#!/usr/bin/env python3
"""Tamper and identity tests for the locked ASH v4 parity-v2 gate."""

from __future__ import annotations

import argparse
import base64
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


def encoded(value: bytes) -> str:
    return base64.b64encode(value).decode("ascii")


def time_record(value: int, timescale: int) -> dict[str, int]:
    return {"value": value, "timescale": timescale, "flags": 1, "epoch": 0}


def typed(kind: str, value: object) -> dict[str, object]:
    return {"kind": kind, "value": value}


class ParityEvidenceFixture:
    TOOL_NAMES = (
        "cpu-metal-parity-contract-v2.json",
        "ParityQualificationCaptureTests.swift",
        "cpu_metal_parity_v4.py",
        "run_cpu_metal_parity_v4.sh",
    )
    STORAGE_RAW = {
        "nv12_video_range_8": "nv12_video_range_8_bit",
        "nv12_full_range_8": "nv12_full_range_8_bit",
        "p010_video_range_10": "p010_video_range_10_bit",
        "p010_full_range_10": "p010_full_range_10_bit",
    }

    def __init__(
        self,
        root: Path,
        *,
        candidate: dict[str, object] | None = None,
        production_runtime: bool = False,
    ):
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
        observed_tools = {
            "captureSourceSHA256": parity.sha256_file(self.capture_source),
            "evaluatorSHA256": parity.sha256_file(self.evaluator),
            "runnerSHA256": parity.sha256_file(self.runner),
        }
        if self.contract["tools"] != observed_tools:
            raise AssertionError("checked-in parity tool identities are stale")
        self.contract_sha = parity.sha256_file(self.contract_path)
        if candidate is None:
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
            self.candidate = {
                "sourceCommit": self.source_revision,
                "sourceTreeIdentitySHA256": identity("fixture-source-tree"),
                "runtimeManifestSHA256": self.runtime["manifestSHA256"],
                "runtimeManifestFileSHA256": self.runtime["manifestFileSHA256"],
                "runtimeArtifactSetSHA256": identity("fixture-runtime-artifacts"),
                "runtimeSourceRevision": self.runtime["sourceRevision"],
                "releaseConfigurationSHA256": identity("fixture-release-config"),
                "appBundleSHA256": identity("fixture-app-bundle"),
                "bundleIdentifier": "com.mirmir.parity-tests",
                "productVersion": "4.0-test",
                "productBuild": "test",
            }
        else:
            if not production_runtime:
                raise AssertionError(
                    "an externally supplied candidate requires production runtime evidence"
                )
            self.candidate = copy.deepcopy(candidate)
            self.source_revision = str(candidate["sourceCommit"])
            self.runtime = {
                "mode": "production",
                "runtimeID": "ash-p06-deterministic-v4",
                "releaseStatus": "release_qualified",
                "manifestSHA256": candidate["runtimeManifestSHA256"],
                "manifestFileSHA256": candidate["runtimeManifestFileSHA256"],
                "sourceRevision": candidate["runtimeSourceRevision"],
                "builderSourceSHA256": identity("release-fixture-runtime-builder"),
                "trustRootConfigured": True,
                "bindingVerified": True,
            }
        self.capture_a = root / "capture-a"
        self.capture_b = root / "capture-b"
        self._build_capture(self.capture_a, "process-a")
        self._build_capture(self.capture_b, "process-b")
        self.candidate_path = root / "candidate-identity.json"
        parity.write_json(self.candidate_path, self.candidate)

    @staticmethod
    def _attachment(key: str, value: dict[str, object]) -> dict[str, object]:
        return {"key": key, "mode": "should_propagate", "value": value}

    def _source_attachments(
        self, frame: dict[str, object]
    ) -> list[dict[str, object]]:
        values = [
            self._attachment(
                "FixtureNested",
                typed(
                    "dictionary",
                    [
                        {"key": "array", "value": typed("array", [
                            typed("boolean", True),
                            typed("unsigned_integer", "7"),
                        ])},
                        {"key": "blob", "value": typed("data", encoded(b"ash"))},
                    ],
                ),
            )
        ]
        detail = frame["fieldDetail"]
        if detail != "none":
            values.extend([
                self._attachment(
                    parity.BOTTOM_FIELD_CHROMA_ATTACHMENT,
                    typed("string", "BottomField"),
                ),
                self._attachment(
                    parity.FIELD_COUNT_ATTACHMENT,
                    typed("signed_integer", "2"),
                ),
                self._attachment(
                    parity.FIELD_DETAIL_ATTACHMENT,
                    typed("string", detail),
                ),
            ])
        if frame["hdrProfile"] != "none":
            values.extend([
                self._attachment(
                    "HDRProfile", typed("string", frame["hdrProfile"])
                ),
                self._attachment(
                    "MasteringDisplayColorVolume",
                    typed("data", encoded(b"fixture-mastering-display")),
                ),
            ])
        return sorted(values, key=lambda item: str(item["key"]))

    def _output_attachments(
        self, frame: dict[str, object]
    ) -> list[dict[str, object]]:
        result = [
            copy.deepcopy(item)
            for item in self._source_attachments(frame)
            if item["key"] not in {
                parity.FIELD_DETAIL_ATTACHMENT,
                parity.BOTTOM_FIELD_CHROMA_ATTACHMENT,
            }
        ]
        for item in result:
            if item["key"] == parity.FIELD_COUNT_ATTACHMENT:
                item["value"] = typed("signed_integer", "1")
        return result

    @staticmethod
    def _default_interlaced_state(
        frame: dict[str, object]
    ) -> tuple[str, str, str]:
        bottom = frame["fieldDetail"] == "temporal_bottom_first"
        dominance = "bottom_field_first" if bottom else "top_field_first"
        cadence = (
            "interlaced_bff_double_rate" if bottom
            else "interlaced_tff_double_rate"
        )
        return dominance, "interlaced", cadence

    def _state(
        self, definition: dict[str, object], ordinal: int
    ) -> dict[str, object]:
        expectations = {
            item["inputOrdinal"]: item for item in definition["stateExpectations"]
        }
        outputs_per_input = (
            2 if definition["kind"] == "pixel_interlaced_temporal" else 1
        )
        generation = 0
        expectation_ordinals = sorted(expectations)
        for index in range(ordinal + 1):
            if index in expectations:
                next_generation = expectations[index]["historyGeneration"]
            else:
                future = next(
                    (value for value in expectation_ordinals if value > index),
                    None,
                )
                minimum_generation = 1
                if future is not None:
                    remaining_capacity = outputs_per_input * (future - index)
                    minimum_generation = max(
                        minimum_generation,
                        expectations[future]["historyGeneration"]
                        - remaining_capacity,
                    )
                next_generation = max(generation, minimum_generation)
            if not generation <= next_generation <= generation + outputs_per_input:
                raise AssertionError("fixture generation expectations are unreachable")
            generation = next_generation
        if ordinal in expectations:
            result = copy.deepcopy(expectations[ordinal])
            result["historyGeneration"] = generation
            return result
        if definition["scanMode"] == "progressive":
            return {
                "inputOrdinal": ordinal,
                "dominance": None,
                "classification": None,
                "cadenceID": "progressive",
                "historyGeneration": generation,
            }
        dominance, classification, cadence = self._default_interlaced_state(
            definition["frames"][ordinal]
        )
        for index in sorted(expectations):
            if index <= ordinal:
                observed = expectations[index]
                if observed["dominance"] == dominance:
                    classification = observed["classification"]
                    cadence = observed["cadenceID"]
        return {
            "inputOrdinal": ordinal,
            "dominance": dominance,
            "classification": classification,
            "cadenceID": cadence,
            "historyGeneration": generation,
        }

    def _checkpoint(
        self, definition: dict[str, object], ordinal: int
    ) -> bytes:
        state = self._state(definition, ordinal)
        outputs_per_input = (
            2 if definition["kind"] == "pixel_interlaced_temporal" else 1
        )
        output_ordinal = (ordinal + 1) * outputs_per_input - 1
        field_state = None
        previous_interlaced = None
        if definition["scanMode"] != "progressive":
            field_state = {
                "dominance": state["dominance"],
                "classification": state["classification"],
                "streamInputFrameCount": ordinal + 1,
                "inputFrameCount": ordinal + 1,
                "observations": [],
            }
            previous_interlaced = {"fixture": True}
        checkpoint = {
            "schemaID": "ash.prepared-temporal-checkpoint.v4.5",
            "planSHA256": identity(str(definition["id"]) + ":plan"),
            "runtimeManifestSHA256": self.runtime["manifestSHA256"],
            "formatIdentity": identity(str(definition["id"]) + ":format"),
            "sourceStorage": self.STORAGE_RAW[str(definition["storage"])],
            "sourceWidth": definition["sourceWidth"],
            "sourceHeight": definition["sourceHeight"],
            "scanModeID": {
                "progressive": "progressive",
                "interlaced_tff": "interlaced_tff_double_rate",
                "interlaced_bff": "interlaced_bff_double_rate",
            }[str(definition["scanMode"])],
            "lastCompletedInputOrdinal": ordinal,
            "nextOutputOrdinal": (ordinal + 1) * outputs_per_input,
            "lastCompletedOutputPresentationTime": {
                "numerator": output_ordinal,
                "denominator": 1,
            },
            "history": {
                "generation": state["historyGeneration"],
                "capacity": 1,
                "frames": [{
                    "ordinal": output_ordinal,
                    "cadenceID": state["cadenceID"],
                }],
            },
            "previousMeasurementHistory": {"fixture": True},
            "previousSourceLumaFrame": {"fixture": True},
            "previousMeasurementStateRawValue": 0,
        }
        if previous_interlaced is not None and field_state is not None:
            checkpoint["previousInterlacedFrame"] = previous_interlaced
            checkpoint["fieldCadenceState"] = field_state
        return parity.compact_canonical_json(checkpoint)

    def _checkpoint_set(self, definition: dict[str, object]) -> bytes:
        entries = []
        if definition["kind"] != "alpha_spatial":
            for ordinal in range(len(definition["frames"])):
                raw = self._checkpoint(definition, ordinal)
                entries.append({
                    "inputOrdinal": ordinal,
                    "canonicalDataBase64": encoded(raw),
                    "canonicalSHA256": parity.sha256_bytes(raw),
                })
        return parity.canonical_json({
            "schemaVersion": parity.CHECKPOINT_SET_SCHEMA,
            "caseID": definition["id"],
            "entries": entries,
        })

    def _semantics(self, definition: dict[str, object]) -> bytes:
        inputs = []
        next_output = 0
        previous_generation = 0
        for ordinal, frame in enumerate(definition["frames"]):
            detail = frame["fieldDetail"]
            if detail == "none":
                dominance = None
                output_times = [(
                    frame["presentationTime"]["value"],
                    frame["presentationTime"]["timescale"],
                    frame["duration"]["value"],
                    frame["duration"]["timescale"],
                )]
                source_fields = ["progressive"]
            else:
                dominance = (
                    "bottom_field_first"
                    if detail == "temporal_bottom_first"
                    else "top_field_first"
                )
                output_times = parity.expected_interlaced_times(frame)
                source_fields = (
                    ["bottom", "top"]
                    if dominance == "bottom_field_first"
                    else ["top", "bottom"]
                )
            state = self._state(definition, ordinal)
            final_generation = state["historyGeneration"]
            if len(output_times) == 1:
                output_generations = [final_generation]
            else:
                output_generations = [
                    max(1, previous_generation, final_generation - 1),
                    final_generation,
                ]
            outputs = []
            for timing, source_field, generation in zip(
                output_times, source_fields, output_generations
            ):
                outputs.append({
                    "outputOrdinal": next_output,
                    "presentationTime": time_record(timing[0], timing[1]),
                    "duration": time_record(timing[2], timing[3]),
                    "sourceField": source_field,
                    "cadenceID": state["cadenceID"],
                    "classification": state["classification"],
                    "historyGeneration": generation,
                    "attachments": self._output_attachments(frame),
                })
                next_output += 1
                previous_generation = generation
            inputs.append({
                "inputOrdinal": ordinal,
                "timing": {
                    "presentationTime": time_record(
                        frame["presentationTime"]["value"],
                        frame["presentationTime"]["timescale"],
                    ),
                    "duration": time_record(
                        frame["duration"]["value"],
                        frame["duration"]["timescale"],
                    ),
                },
                "effectiveDominance": dominance,
                "sourceAttachments": self._source_attachments(frame),
                "outputs": outputs,
            })
        return parity.canonical_json({
            "schemaVersion": parity.SEMANTICS_SCHEMA,
            "caseID": definition["id"],
            "inputs": inputs,
        })

    def _resume_set(
        self,
        definition: dict[str, object],
        visible: bytes,
        semantics: bytes,
    ) -> bytes:
        entries = []
        for boundary in definition["checkpointBoundaries"]:
            final_checkpoint = self._checkpoint(
                definition, len(definition["frames"]) - 1
            )
            entries.append({
                "boundaryInputOrdinal": boundary,
                "uninterruptedVisibleBase64": encoded(visible),
                "resumedVisibleBase64": encoded(visible),
                "uninterruptedSemanticsBase64": encoded(semantics),
                "resumedSemanticsBase64": encoded(semantics),
                "uninterruptedFinalCheckpointBase64": encoded(final_checkpoint),
                "resumedFinalCheckpointBase64": encoded(final_checkpoint),
            })
        return parity.canonical_json({
            "schemaVersion": parity.RESUME_SET_SCHEMA,
            "caseID": definition["id"],
            "entries": entries,
        })

    def _write_run(
        self,
        directory: Path,
        case_directory: Path,
        definition: dict[str, object],
        backend: str,
        run_name: str,
        artifacts: dict[str, bytes],
    ) -> dict[str, object]:
        result = {}
        extensions = {
            "visible": "bin",
            "semantics": "json",
            "checkpoints": "json",
            "resume": "json",
        }
        for key, data in artifacts.items():
            path = case_directory / f"{backend}-{run_name}-{key}.{extensions[key]}"
            path.write_bytes(data)
            result[key] = parity.descriptor(path, directory)
        return result

    def _build_capture(self, directory: Path, process_id: str) -> None:
        directory.mkdir(parents=True)
        cases = []
        for definition in self.contract["cases"]:
            case_id = definition["id"]
            case_directory = directory / "cases" / case_id
            case_directory.mkdir(parents=True)
            visible = ("visible:" + case_id).encode("utf-8")
            semantics = self._semantics(definition)
            artifacts = {
                "visible": visible,
                "semantics": semantics,
                "checkpoints": self._checkpoint_set(definition),
                "resume": self._resume_set(definition, visible, semantics),
            }
            backends = {}
            for backend in ("cpu", "metal"):
                canonical = self._write_run(
                    directory, case_directory, definition, backend,
                    "canonical", artifacts
                )
                repeat = self._write_run(
                    directory, case_directory, definition, backend,
                    "repeat", artifacts
                )
                schedules = []
                for schedule in self.contract["tileSchedules"]:
                    schedules.append({
                        "schedule": schedule,
                        "run": self._write_run(
                            directory, case_directory, definition, backend,
                            "schedule-" + schedule, artifacts
                        ),
                    })
                backends[backend] = {
                    "canonical": canonical,
                    "repeat": repeat,
                    "schedules": schedules,
                }
            metadata = {
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
            metadata_path = case_directory / "case-metadata.json"
            parity.write_json(metadata_path, metadata)
            cases.append({
                "id": case_id,
                "definition": copy.deepcopy(definition),
                "cpu": backends["cpu"],
                "metal": backends["metal"],
                "metadata": parity.descriptor(metadata_path, directory),
            })
        capture = {
            "schemaVersion": self.contract["captureSchemaVersion"],
            "contractSHA256": self.contract_sha,
            "captureSourceSHA256": self.contract["tools"]["captureSourceSHA256"],
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
        parity.write_json(manifest_path, {
            "schemaVersion": parity.CAPTURE_MANIFEST_SCHEMA,
            "artifacts": artifacts,
        })

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
        paths = {}
        for relative, data in replacements.items():
            path = directory / relative
            path.write_bytes(data)
            paths[relative] = path
        capture_path = directory / "capture.json"
        capture = parity.load_json(capture_path)
        self._replace_descriptors(capture, paths, directory)
        parity.write_json(capture_path, capture)
        self.reseal(directory)

    def artifact_relative(
        self, case_id: str, backend: str, run: str, key: str
    ) -> str:
        extension = "bin" if key == "visible" else "json"
        return f"cases/{case_id}/{backend}-{run}-{key}.{extension}"

    def mutate_json_artifact(
        self,
        case_id: str,
        backend: str,
        run: str,
        key: str,
        mutator,
        directory: Path | None = None,
    ) -> None:
        target = directory or self.capture_a
        relative = self.artifact_relative(case_id, backend, run, key)
        document = parity.load_json(target / relative)
        mutator(document)
        self.replace_and_rebind(target, {relative: parity.canonical_json(document)})

    def replace_visible_group(
        self, directory: Path, case_id: str, backends: tuple[str, ...], data: bytes
    ) -> None:
        replacements = {}
        runs = ["canonical", "repeat"] + [
            "schedule-" + item for item in self.contract["tileSchedules"]
        ]
        for backend in backends:
            for run in runs:
                replacements[self.artifact_relative(
                    case_id, backend, run, "visible"
                )] = data
        self.replace_and_rebind(directory, replacements)

    def mutate_capture(self, mutator, directory: Path | None = None) -> None:
        target = directory or self.capture_a
        path = target / "capture.json"
        capture = parity.load_json(path)
        mutator(capture)
        parity.write_json(path, capture)
        self.reseal(target)

    def publish(self) -> tuple[Path, Path]:
        report_path = self.root / "cpu-metal-parity-report.json"
        manifest_path = self.root / "artifact-manifest.json"
        parity.write_json(report_path, self.evaluate())
        parity.write_json(manifest_path, parity.make_root_manifest(
            self.root, manifest_path
        ))
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

    def case_with(self, coverage: str) -> str:
        return next(
            case["id"] for case in self.fixture.contract["cases"]
            if coverage in case["coverage"]
        )

    def test_fixture_smoke_recomputes_exact_v2_coverage(self) -> None:
        first = self.fixture.evaluate()
        second = self.fixture.evaluate()
        self.assertEqual(parity.canonical_json(first), parity.canonical_json(second))
        self.assertEqual(first["schemaVersion"], parity.REPORT_SCHEMA)
        self.assertEqual(first["coverage"], list(parity.REQUIRED_PARITY_COVERAGE))
        self.assertFalse(first["releaseEligible"])
        self.assertFalse(first["byteParityGatePass"])
        self.assertEqual(len(first["cases"]), len(self.fixture.contract["cases"]))

    def test_final_gate_rejects_fixture_runtime(self) -> None:
        with self.assertRaisesRegex(parity.ParityEvidenceError, "production runtime"):
            self.fixture.evaluate(allow_fixture_runtime=False)

    def test_evaluator_owned_coverage_cannot_be_removed_from_contract(self) -> None:
        contract = parity.load_json(self.fixture.contract_path)
        contract["parityCoverage"].remove("p010_full_range")
        parity.write_json(self.fixture.contract_path, contract)
        with self.assertRaisesRegex(parity.ParityEvidenceError, "evaluator-owned"):
            self.fixture.evaluate()

    def test_exact_case_matrix_requires_p010_full_case(self) -> None:
        contract = parity.load_json(self.fixture.contract_path)
        contract["cases"] = [
            case for case in contract["cases"]
            if "p010_full_range" not in case["coverage"]
        ]
        parity.write_json(self.fixture.contract_path, contract)
        with self.assertRaisesRegex(parity.ParityEvidenceError, "matrix is incomplete"):
            self.fixture.evaluate()

    def test_raw_artifact_tamper_is_rejected_by_nested_seal(self) -> None:
        case_id = self.fixture.contract["cases"][0]["id"]
        path = self.fixture.capture_a / self.fixture.artifact_relative(
            case_id, "cpu", "canonical", "visible"
        )
        path.write_bytes(path.read_bytes() + b"tamper")
        with self.assertRaisesRegex(parity.ParityEvidenceError, "byte count mismatch"):
            self.fixture.evaluate()

    def test_resealed_cpu_metal_visible_divergence_is_rejected(self) -> None:
        case_id = self.fixture.contract["cases"][0]["id"]
        self.fixture.replace_visible_group(
            self.fixture.capture_a,
            case_id,
            ("metal",),
            b"different-metal-pixels",
        )
        with self.assertRaisesRegex(parity.ParityEvidenceError, "CPU/Metal.*visible"):
            self.fixture.evaluate()

    def test_repeat_semantics_divergence_is_rejected(self) -> None:
        case_id = self.fixture.contract["cases"][0]["id"]
        self.fixture.mutate_json_artifact(
            case_id, "cpu", "repeat", "semantics",
            lambda document: document["inputs"][0]["outputs"][0].update(
                {"cadenceID": "changed"}
            ),
        )
        with self.assertRaisesRegex(parity.ParityEvidenceError, "cadenceID"):
            self.fixture.evaluate()

    def test_schedule_artifacts_must_use_distinct_paths(self) -> None:
        case_id = self.fixture.contract["cases"][0]["id"]

        def mutate(capture):
            case = next(item for item in capture["cases"] if item["id"] == case_id)
            case["cpu"]["schedules"][0]["run"] = copy.deepcopy(
                case["cpu"]["canonical"]
            )

        self.fixture.mutate_capture(mutate)
        with self.assertRaisesRegex(parity.ParityEvidenceError, "aliases"):
            self.fixture.evaluate()

    def test_schedule_set_and_order_are_exact(self) -> None:
        case_id = self.fixture.contract["cases"][0]["id"]

        def mutate(capture):
            case = next(item for item in capture["cases"] if item["id"] == case_id)
            case["metal"]["schedules"].pop()

        self.fixture.mutate_capture(mutate)
        with self.assertRaisesRegex(parity.ParityEvidenceError, "schedule set/order"):
            self.fixture.evaluate()

    def test_schedule_pixel_divergence_is_rejected(self) -> None:
        case_id = self.fixture.contract["cases"][0]["id"]
        relative = self.fixture.artifact_relative(
            case_id, "cpu", "schedule-reverse", "visible"
        )
        self.fixture.replace_and_rebind(
            self.fixture.capture_a, {relative: b"schedule-dependent"}
        )
        with self.assertRaisesRegex(parity.ParityEvidenceError, "schedule reverse.*visible"):
            self.fixture.evaluate()

    def test_cross_process_checkpoint_divergence_is_rejected(self) -> None:
        case_id = self.fixture.contract["cases"][0]["id"]

        def mutate(document):
            document["entries"][0]["canonicalSHA256"] = "0" * 64

        self.fixture.mutate_json_artifact(
            case_id, "cpu", "canonical", "checkpoints", mutate,
            directory=self.fixture.capture_b,
        )
        with self.assertRaisesRegex(parity.ParityEvidenceError, "checkpoint SHA"):
            self.fixture.evaluate()

    def test_raw_checkpoint_resealed_tamper_is_rejected(self) -> None:
        case_id = self.fixture.contract["cases"][0]["id"]

        def mutate(document):
            entry = document["entries"][0]
            checkpoint = json.loads(base64.b64decode(entry["canonicalDataBase64"]))
            checkpoint["nextOutputOrdinal"] += 1
            raw = parity.compact_canonical_json(checkpoint)
            entry["canonicalDataBase64"] = encoded(raw)
            entry["canonicalSHA256"] = parity.sha256_bytes(raw)

        self.fixture.mutate_json_artifact(
            case_id, "cpu", "canonical", "checkpoints", mutate
        )
        with self.assertRaisesRegex(parity.ParityEvidenceError, "output ordinal"):
            self.fixture.evaluate()

    def test_checkpoint_generation_claim_is_recomputed(self) -> None:
        case_id = self.case_with("scene_cut")

        def mutate(document):
            entry = document["entries"][-1]
            checkpoint = json.loads(base64.b64decode(entry["canonicalDataBase64"]))
            checkpoint["history"]["generation"] = 9
            raw = parity.compact_canonical_json(checkpoint)
            entry["canonicalDataBase64"] = encoded(raw)
            entry["canonicalSHA256"] = parity.sha256_bytes(raw)

        self.fixture.mutate_json_artifact(
            case_id, "cpu", "canonical", "checkpoints", mutate
        )
        with self.assertRaisesRegex(
            parity.ParityEvidenceError, "generation progression"
        ):
            self.fixture.evaluate()

    def test_unlisted_checkpoint_generation_cannot_skip_emitted_frames(self) -> None:
        case_id = self.case_with("interlaced_tff")

        def mutate(document):
            entry = document["entries"][1]
            checkpoint = json.loads(base64.b64decode(entry["canonicalDataBase64"]))
            checkpoint["history"]["generation"] = 5
            raw = parity.compact_canonical_json(checkpoint)
            entry["canonicalDataBase64"] = encoded(raw)
            entry["canonicalSHA256"] = parity.sha256_bytes(raw)

        self.fixture.mutate_json_artifact(
            case_id, "cpu", "canonical", "checkpoints", mutate
        )
        with self.assertRaisesRegex(
            parity.ParityEvidenceError, "generation progression"
        ):
            self.fixture.evaluate()

    def test_interlaced_output_generation_must_reach_its_checkpoint(self) -> None:
        case_id = self.case_with("interlaced_tff")
        self.fixture.mutate_json_artifact(
            case_id,
            "cpu",
            "canonical",
            "semantics",
            lambda document: document["inputs"][0]["outputs"][0].update(
                {"historyGeneration": 3}
            ),
        )
        with self.assertRaisesRegex(
            parity.ParityEvidenceError, "history generation progression"
        ):
            self.fixture.evaluate()

    def test_tff_source_field_order_is_recomputed(self) -> None:
        case_id = self.case_with("interlaced_tff")
        self.fixture.mutate_json_artifact(
            case_id, "cpu", "canonical", "semantics",
            lambda document: document["inputs"][0]["outputs"][0].update(
                {"sourceField": "bottom"}
            ),
        )
        with self.assertRaisesRegex(parity.ParityEvidenceError, "source field order"):
            self.fixture.evaluate()

    def test_bff_checkpoint_dominance_is_recomputed(self) -> None:
        case_id = self.case_with("interlaced_bff")

        def mutate(document):
            entry = document["entries"][0]
            checkpoint = json.loads(base64.b64decode(entry["canonicalDataBase64"]))
            checkpoint["fieldCadenceState"]["dominance"] = "top_field_first"
            raw = parity.compact_canonical_json(checkpoint)
            entry["canonicalDataBase64"] = encoded(raw)
            entry["canonicalSHA256"] = parity.sha256_bytes(raw)

        self.fixture.mutate_json_artifact(
            case_id, "cpu", "canonical", "checkpoints", mutate
        )
        with self.assertRaisesRegex(parity.ParityEvidenceError, "dominance"):
            self.fixture.evaluate()

    def test_cadence_classification_is_bound_to_checkpoint(self) -> None:
        case_id = self.case_with("telecine_3_2")
        self.fixture.mutate_json_artifact(
            case_id, "cpu", "canonical", "semantics",
            lambda document: document["inputs"][10]["outputs"][0].update(
                {"classification": "mixed"}
            ),
        )
        with self.assertRaisesRegex(parity.ParityEvidenceError, "classification"):
            self.fixture.evaluate()

    def test_resume_visible_semantics_and_final_checkpoint_are_exact(self) -> None:
        case_id = self.case_with("checkpoint_resume")
        self.fixture.mutate_json_artifact(
            case_id, "cpu", "canonical", "resume",
            lambda document: document["entries"][0].update(
                {"resumedVisibleBase64": encoded(b"different-resume")}
            ),
        )
        with self.assertRaisesRegex(parity.ParityEvidenceError, "resumed identity"):
            self.fixture.evaluate()

    def test_timing_value_scale_flags_and_epoch_are_exact(self) -> None:
        case_id = self.case_with("exact_timing_semantics")
        for key, value in (
            ("value", 99),
            ("timescale", 99),
            ("flags", 3),
            ("epoch", 1),
        ):
            with self.subTest(key=key):
                with tempfile.TemporaryDirectory() as temporary:
                    fixture = ParityEvidenceFixture(Path(temporary))
                    fixture.mutate_json_artifact(
                        case_id, "cpu", "canonical", "semantics",
                        lambda document, key=key, value=value: document["inputs"][0]
                        ["outputs"][0]["presentationTime"].update({key: value}),
                    )
                    with self.assertRaises(parity.ParityEvidenceError):
                        fixture.evaluate()

    def test_recursive_attachment_dictionary_order_is_canonical(self) -> None:
        case_id = self.case_with("exact_attachment_semantics")

        def mutate(document):
            nested = next(
                item for item in document["inputs"][0]["sourceAttachments"]
                if item["key"] == "FixtureNested"
            )
            nested["value"]["value"].reverse()

        self.fixture.mutate_json_artifact(
            case_id, "cpu", "canonical", "semantics", mutate
        )
        with self.assertRaisesRegex(parity.ParityEvidenceError, "not canonical"):
            self.fixture.evaluate()

    def test_progressive_output_cannot_retain_bottom_field_chroma(self) -> None:
        case_id = self.case_with("progressive_attachment_normalization")

        def mutate(document):
            output = document["inputs"][0]["outputs"][0]
            output["attachments"].append(
                self.fixture._attachment(
                    parity.BOTTOM_FIELD_CHROMA_ATTACHMENT,
                    typed("string", "BottomField"),
                )
            )
            output["attachments"].sort(key=lambda item: item["key"])

        self.fixture.mutate_json_artifact(
            case_id, "cpu", "canonical", "semantics", mutate
        )
        with self.assertRaisesRegex(parity.ParityEvidenceError, "bottom-field chroma"):
            self.fixture.evaluate()

    def test_hdr_attachment_payload_cannot_change(self) -> None:
        case_id = self.case_with("hdr_attachment_semantics")

        def mutate(document):
            output = document["inputs"][0]["outputs"][0]
            hdr = next(item for item in output["attachments"] if item["key"] == "HDRProfile")
            hdr["value"]["value"] = "changed"

        self.fixture.mutate_json_artifact(
            case_id, "cpu", "canonical", "semantics", mutate
        )
        with self.assertRaisesRegex(parity.ParityEvidenceError, "attachment semantics"):
            self.fixture.evaluate()

    def test_capture_manifest_must_be_complete_and_symlink_free(self) -> None:
        (self.fixture.capture_a / "unsealed.bin").write_bytes(b"unsealed")
        with self.assertRaisesRegex(parity.ParityEvidenceError, "not complete"):
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
        with self.assertRaisesRegex(parity.ParityEvidenceError, "runtime manifest"):
            self.fixture.evaluate()

    def test_duplicate_json_keys_are_rejected(self) -> None:
        self.fixture.candidate_path.write_text(
            '{"sourceCommit":"' + self.fixture.source_revision
            + '","sourceCommit":"' + self.fixture.source_revision + '"}\n',
            encoding="utf-8",
        )
        with self.assertRaisesRegex(parity.ParityEvidenceError, "duplicate JSON key"):
            self.fixture.evaluate()

    def test_published_report_and_root_seal_are_recomputed(self) -> None:
        report_path, manifest_path = self.fixture.publish()
        parity.command_verify(self.fixture.verify_arguments(report_path, manifest_path))
        report = parity.load_json(report_path)
        report["byteParityGatePass"] = True
        parity.write_json(report_path, report)
        with self.assertRaisesRegex(parity.ParityEvidenceError, "published parity report"):
            parity.command_verify(
                self.fixture.verify_arguments(report_path, manifest_path)
            )


if __name__ == "__main__":
    unittest.main()
