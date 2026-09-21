#!/usr/bin/env python3

from __future__ import annotations

import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest import mock


SCRIPT_DIRECTORY = Path(__file__).resolve().parent
REPOSITORY_ROOT = SCRIPT_DIRECTORY.parent.parent
FIXED_REQUEST_LOCK = Path(
    "/private/tmp/mirmir-v4-performance-request-v2.lock"
)
SPEC = importlib.util.spec_from_file_location(
    "performance_gate_v4",
    SCRIPT_DIRECTORY / "performance_gate_v4.py",
)
assert SPEC is not None and SPEC.loader is not None
gate = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(gate)
FIXED_CANONICAL_ROOT = Path(gate.CANONICAL_PRODUCER_ROOT)


def write_json(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


class PerformanceGateTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.runner_path = self.root / "run_performance_gate_v4.sh"
        self.runner_path.write_text("#!/bin/zsh\nexit 0\n")
        self.underlying_swiftc = self.root / "toolchain/swift-frontend"
        self.underlying_swiftc.parent.mkdir()
        self.underlying_swiftc.write_text(
            "#!/usr/bin/python3\n"
            "import sys\n"
            "if sys.argv[1:] == ['--version']:\n"
            "    print('Swift fixture version 6.2.3')\n"
            "    raise SystemExit(0)\n"
            "raise SystemExit(64)\n"
        )
        self.underlying_swiftc.chmod(0o755)
        self.contract_path = self.root / "contract.json"
        contract = json.loads(
            (SCRIPT_DIRECTORY / "performance-gate-contract-v1.json").read_text()
        )
        contract["measurement"]["bootstrapIterations"] = 1200
        contract["capture"]["captureSourceSHA256"] = "1" * 64
        contract["capture"]["evaluatorSourceSHA256"] = "2" * 64
        contract["capture"]["runnerSourceSHA256"] = sha256(self.runner_path)
        self.locked_input = self.root / "fixtures/input.mov"
        self.locked_input.parent.mkdir()
        self.locked_input.write_bytes(b"locked performance input")
        contract["workload"]["input"]["repositoryPath"] = "fixtures/input.mov"
        contract["workload"]["input"]["sha256"] = sha256(self.locked_input)
        contract["workload"]["input"]["byteCount"] = self.locked_input.stat().st_size
        write_json(self.contract_path, contract)
        self.contract = contract
        self.contract_sha = sha256(self.contract_path)
        self.baseline = self._make_capture("baseline_p05", wall=100.0, engine=10.0)
        self.candidate = self._make_capture("candidate_p06", wall=50.0, engine=5.0)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def _environment(self) -> dict[str, object]:
        return {
            "schemaVersion": gate.ENVIRONMENT_SCHEMA,
            "stableIdentity": {
                "hardwareModel": "Mac-Test",
                "memoryBytes": 48 * 1024**3,
                "processor": "Apple Test",
                "gpuIdentity": ["Apple Test"],
                "macOSBuild": "25G72",
                "xcodeBuild": "17C52",
                "swiftCompiler": "6.2.3",
            },
            "power": {"identity": "power-identity", "source": "AC Power"},
            "thermal": {"accepted": True, "observationSHA256": "4" * 64},
        }

    def _projecting_swiftc(self) -> Path:
        compiler = self.root / "projecting-toolchain/swift-frontend"
        compiler.parent.mkdir(exist_ok=True)
        compiler.write_text(
            "#!/usr/bin/python3\n"
            "import json,os,pathlib,shlex,sys\n"
            "if sys.argv[1:] == ['--version']:\n"
            "    print('Swift projecting fixture version 6.2.3')\n"
            "    raise SystemExit(0)\n"
            "arguments = sys.argv[1:]\n"
            "if '-driver-print-jobs' in arguments:\n"
            "    projected=[]\n"
            "    frontend=None\n"
            "    index=0\n"
            "    while index < len(arguments):\n"
            "        if arguments[index] == '-driver-print-jobs':\n"
            "            index += 1\n"
            "        elif arguments[index] == '-driver-use-frontend-path':\n"
            "            frontend=arguments[index + 1]\n"
            "            index += 2\n"
            "        elif arguments[index] == '-save-temps':\n"
            "            index += 1\n"
            "        elif arguments[index] == '-j':\n"
            "            index += 2\n"
            "        elif arguments[index].startswith('-j'):\n"
            "            index += 1\n"
            "        elif arguments[index] == '-working-directory':\n"
            "            working=arguments[index + 1]\n"
            "            projected.extend(['-Xcc','-working-directory','-Xcc',working,'-file-compilation-dir',working])\n"
            "            index += 2\n"
            "        else:\n"
            "            projected.append(arguments[index])\n"
            "            index += 1\n"
            "    if frontend is None:\n"
            "        raise SystemExit(64)\n"
            "    temporary=pathlib.Path(os.environ['TMPDIR'])/'TemporaryDirectory.Abc123'\n"
            "    temporary.mkdir(mode=0o700)\n"
            "    raw_map=temporary/'supplementaryOutputs-1'\n"
            "    raw_map.write_text(json.dumps({\n"
            "        '/tmp/mirmir-v4-performance-producer-v2/baseline-project/Mirmir/App/MirmirApp.swift': {\n"
            "            'object': '/tmp/mirmir-v4-performance-producer-v2/DerivedData/baseline/Build/Objects/Mirmir.o'\n"
            "        }\n"
            "    }, sort_keys=True)+'\\n')\n"
            "    raw_map.chmod(0o644)\n"
            "    projected.extend(['-supplementary-output-file-map',str(raw_map),'-o','/tmp/mirmir-v4-performance-producer-v2/DerivedData/baseline/Build/Objects/Mirmir.o'])\n"
            "    mutation=os.environ.get('MIRMIR_TEST_PROJECTED_MUTATION')\n"
            "    if mutation == 'direct-working-directory':\n"
            "        projected.extend(['-working-directory','/tmp/mirmir-v4-performance-producer-v2/baseline-project'])\n"
            "    elif mutation == 'missing-file-compilation-dir':\n"
            "        pos=projected.index('-file-compilation-dir'); del projected[pos:pos+2]\n"
            "    elif mutation == 'duplicate-file-compilation-dir':\n"
            "        projected.extend(['-file-compilation-dir','/tmp/mirmir-v4-performance-producer-v2/baseline-project'])\n"
            "    elif mutation == 'substituted-xcc-working-directory':\n"
            "        pos=projected.index('-working-directory'); projected[pos+2]='/tmp/substituted-source'\n"
            "    elif mutation == 'outside-object-output':\n"
            "        projected[-1]='/tmp/outside.o'\n"
            "    elif mutation == 'wrong-frontend-executable':\n"
            "        frontend=str(pathlib.Path(__file__).resolve())\n"
            "    command=[frontend,'-frontend',*projected]\n"
            "    print(shlex.join(command))\n"
            "    raise SystemExit(0)\n"
            "destination=os.environ.get('MIRMIR_TEST_SWIFT_CAPTURE')\n"
            "if destination:\n"
            "    pathlib.Path(destination).write_text(json.dumps({\n"
            "        'arguments': arguments,\n"
            "        'deterministicHashing': os.environ.get('SWIFT_DETERMINISTIC_HASHING'),\n"
            "        'maximumDeterminism': os.environ.get('SWIFTC_MAXIMUM_DETERMINISM'),\n"
            "        'temporaryDirectory': os.environ.get('TMPDIR'),\n"
            "    }, sort_keys=True)+'\\n')\n"
            "raise SystemExit(0)\n"
        )
        compiler.chmod(0o755)
        return compiler

    def _swift_driver_arguments(self, module_name: str = "Mirmir") -> list[str]:
        prefix_maps = [
            gate.CANONICAL_SOURCE_ROOT + "=/mirmir-performance-p05",
            gate.CANONICAL_SOURCE_ROOT.replace("/private/tmp/", "/tmp/", 1)
            + "=/mirmir-performance-p05",
            gate.CANONICAL_DERIVED_DATA + "=/mirmir-performance-derived",
            gate.CANONICAL_DERIVED_DATA.replace("/private/tmp/", "/tmp/", 1)
            + "=/mirmir-performance-derived",
        ]
        arguments = [
            "-j",
            "14",
            "-j8",
            "@"
            + gate.CANONICAL_DERIVED_DATA.replace("/private/tmp/", "/tmp/", 1)
            + "/Build/Objects/Fixture.SwiftFileList",
            "-module-name",
            module_name,
            "-target",
            gate.SWIFT_DRIVER_REQUIRED_TARGET,
            "-c",
            "-num-threads",
            "1",
            "-Xllvm",
            "-rng-seed=1",
        ]
        for value in prefix_maps:
            arguments.extend(("-file-prefix-map", value))
        for value in prefix_maps:
            arguments.extend(("-debug-prefix-map", value))
        arguments.extend(
            (
                "-module-cache-path",
                gate.CANONICAL_MODULE_CACHE,
                "-working-directory",
                gate.CANONICAL_SOURCE_ROOT.replace("/private/tmp/", "/tmp/", 1),
            )
        )
        return arguments

    def _frontend_effective_arguments(self, module_name: str) -> list[str]:
        source_alias = gate.CANONICAL_SOURCE_ROOT.replace(
            "/private/tmp/", "/tmp/", 1
        )
        derived_alias = gate.CANONICAL_DERIVED_DATA.replace(
            "/private/tmp/", "/tmp/", 1
        )
        prefix_maps = [
            gate.CANONICAL_SOURCE_ROOT + "=/mirmir-performance-p05",
            source_alias + "=/mirmir-performance-p05",
            gate.CANONICAL_DERIVED_DATA + "=/mirmir-performance-derived",
            derived_alias + "=/mirmir-performance-derived",
        ]
        arguments = [
            "-frontend",
            "-c",
            f"{source_alias}/{module_name}/{module_name}.swift",
            "-module-name",
            module_name,
            "-target",
            gate.SWIFT_DRIVER_REQUIRED_TARGET,
            "-num-threads",
            "1",
            "-Xllvm",
            "-rng-seed=1",
        ]
        for value in prefix_maps:
            arguments.extend(("-file-prefix-map", value))
        for value in prefix_maps:
            arguments.extend(("-debug-prefix-map", value))
        arguments.extend(
            (
                "-module-cache-path",
                gate.CANONICAL_MODULE_CACHE,
                "-Xcc",
                "-working-directory",
                "-Xcc",
                source_alias,
                "-file-compilation-dir",
                source_alias,
                "-supplementary-output-file-map",
                f"{gate.CANONICAL_SWIFT_SUPPLEMENTARY_MAPS}/{module_name}.json",
                "-o",
                f"{derived_alias}/Build/Objects/{module_name}.o",
            )
        )
        return arguments

    def _write_frontend_fixture(
        self, label: str
    ) -> tuple[Path, Path, Path]:
        shim = self.root / f"swift-frontend-shim-{label}"
        shim.write_bytes(
            gate.swift_frontend_shim_bytes(
                self.underlying_swiftc.resolve(),
                Path(gate.CANONICAL_SWIFT_FRONTEND_AUDIT),
            )
        )
        shim.chmod(0o755)
        audit = self.root / f"swift-frontend-audit-{label}.jsonl"
        maps = self.root / f"swift-supplementary-maps-{label}"
        maps.mkdir(mode=0o700)
        records: list[dict[str, object]] = []
        source_alias = gate.CANONICAL_SOURCE_ROOT.replace(
            "/private/tmp/", "/tmp/", 1
        )
        derived_alias = gate.CANONICAL_DERIVED_DATA.replace(
            "/private/tmp/", "/tmp/", 1
        )
        for index, module_name in enumerate(gate.SWIFT_DRIVER_REQUIRED_MODULES):
            effective = self._frontend_effective_arguments(module_name)
            map_path = maps / f"{module_name}.json"
            map_path.write_text(
                json.dumps(
                    {
                        f"{source_alias}/{module_name}/{module_name}.swift": {
                            "object": f"{derived_alias}/Build/Objects/{module_name}.o"
                        }
                    },
                    indent=2,
                    sort_keys=True,
                )
                + "\n"
            )
            map_path.chmod(0o600)
            normalized = gate._normalize_frontend_argv(effective)
            transport_suffix = hashlib.sha256(
                f"{label}:{index}".encode("utf-8")
            ).hexdigest()[:6]
            records.append(
                {
                    "schemaVersion": gate.SWIFT_FRONTEND_JOB_AUDIT_SCHEMA,
                    "moduleName": module_name,
                    "target": gate.SWIFT_DRIVER_REQUIRED_TARGET,
                    "rawSupplementaryOutputFileMapPath": (
                        gate.CANONICAL_SWIFT_TEMPORARY
                        + f"/TemporaryDirectory.{transport_suffix}/supplementaryOutputs-1"
                    ),
                    "canonicalSupplementaryOutputFileMapPath": (
                        gate.CANONICAL_SWIFT_SUPPLEMENTARY_MAPS
                        + f"/{module_name}.json"
                    ),
                    "supplementaryOutputFileMapByteCount": map_path.stat().st_size,
                    "supplementaryOutputFileMapSHA256": sha256(map_path),
                    "rawSupplementaryOutputFileMapOwnerUID": os.getuid(),
                    "rawSupplementaryOutputFileMapUnixMode": 0o644,
                    "rawSupplementaryOutputFileMapLinkCount": 1,
                    "effectiveArgv": effective,
                    "effectiveArgvSHA256": hashlib.sha256(
                        gate.SWIFT_FRONTEND_JOB_AUDIT_DOMAIN
                        + b"effective\0"
                        + gate.canonical_json(effective)
                    ).hexdigest(),
                    "normalizedEffectiveArgv": normalized,
                    "normalizedEffectiveArgvSHA256": hashlib.sha256(
                        gate.SWIFT_FRONTEND_JOB_AUDIT_DOMAIN
                        + gate.canonical_json(normalized)
                    ).hexdigest(),
                    "objectOutputPathCount": 1,
                    "forcedEnvironment": {
                        "SWIFT_DETERMINISTIC_HASHING": "1",
                        "SWIFTC_MAXIMUM_DETERMINISM": "1",
                        "TMPDIR": gate.CANONICAL_SWIFT_TEMPORARY,
                    },
                }
            )
        audit.write_text(
            "".join(
                json.dumps(record, separators=(",", ":"), sort_keys=True) + "\n"
                for record in records
            )
        )
        audit.chmod(0o600)
        return shim, audit, maps

    def _driver_wrapper_fixture_bytes(
        self, underlying: Path, audit: Path, label: str
    ) -> tuple[bytes, Path, Path]:
        temporary = self.root / f"swift-temporary-{label}"
        temporary.mkdir(mode=0o700)
        frontend = self.root / f"swift-frontend-projection-{label}"
        frontend.write_text("#!/bin/zsh\nexit 0\n")
        frontend.chmod(0o755)
        return (
            gate.swift_driver_wrapper_bytes(
                underlying, audit, frontend, temporary
            ),
            frontend,
            temporary,
        )

    def _source_identity(self, variant: str) -> dict[str, object]:
        if variant == "baseline_p05":
            runtime = {
                "status": self.contract["baseline"]["runtimeStatus"],
                "runtimeID": None,
                "implementationVersions": self.contract["baseline"][
                    "implementationVersions"
                ],
                "manifestSHA256": None,
                "releaseQualified": False,
                "trustRootConfigured": False,
                "artifactsVerified": True,
            }
            revision = self.contract["baseline"]["sourceRevision"]
        else:
            runtime = {
                "status": "release_qualified",
                "runtimeID": "ash-p06-deterministic-v4",
                "implementationVersions": ["ash-p06-deterministic-v4"],
                "manifestSHA256": "5" * 64,
                "manifestSourceRevision": "b" * 64,
                "builderSourceSHA256": "6" * 64,
                "releaseQualified": True,
                "trustRootConfigured": True,
                "artifactsVerified": True,
            }
            revision = "a" * 40
        return {
            "schemaVersion": gate.SOURCE_IDENTITY_SCHEMA,
            "variant": variant,
            "sourceRevision": revision,
            "sourceTreeSHA256": "7" * 64,
            "runtime": runtime,
        }

    def _make_capture(
        self,
        variant: str,
        wall: float,
        engine: float,
        *,
        directory_name: str | None = None,
        producer_nonce: str = "a" * 64,
        producer_challenge: str = "b" * 64,
        peak_resident_bytes: int | None = None,
    ) -> Path:
        directory = self.root / (directory_name or variant)
        directory.mkdir(parents=True)
        source_identity = self._source_identity(variant)
        write_json(directory / "source-identity.json", source_identity)
        environment = self._environment()
        write_json(directory / "environment-before.json", environment)
        write_json(directory / "environment-after.json", environment)
        producer_log = (
            "xcodebuild.log"
            if variant == "baseline_p05"
            else "packaged-observer.log"
        )
        (directory / producer_log).write_text("Release capture succeeded\n")
        cases = []
        for case_index, case in enumerate(self.contract["workload"]["cases"]):
            verification = {
                "requestedBackendExecutedWithoutFallback": True,
                "allInputTracksAccounted": True,
                "exactEnabledVideoTrackCount": True,
                "exactEncodedDimensions": True,
                "exactCodec": True,
                "exactFrameCount": True,
                "exactPresentationTimestamps": True,
                "exactDuration": True,
                "bt709ColorContract": True,
                "decodedVisiblePixelSHA256": format(case_index + 8, "064x"),
                "semanticTrackManifestSHA256": format(case_index + 16, "064x"),
                "allRequiredChecksPassed": True,
            }
            engine_runs = []
            wall_runs = []
            for sample_index in range(10):
                jitter = sample_index * 0.001
                engine_runs.append(
                    {
                        "sampleIndex": sample_index,
                        "frameMilliseconds": [
                            engine + jitter,
                            engine + 0.01 + jitter,
                            engine + 0.02 + jitter,
                        ],
                        "processedFrameCount": 3,
                    }
                )
                wall_runs.append(
                    {
                        "sampleIndex": sample_index,
                        "wallMilliseconds": wall + case_index * 0.1 + jitter,
                        "peakResidentBytes": (
                            peak_resident_bytes
                            if peak_resident_bytes is not None
                            else (
                                100 * 1024**2
                                if variant == "baseline_p05"
                                else 110 * 1024**2
                            )
                        ),
                        "processedFrameCount": 3,
                        "verification": verification,
                    }
                )
            cases.append(
                {
                    **case,
                    "request": {
                        field: copy.deepcopy(
                            self.contract["workload"]["output"][field]
                        )
                        for field in gate.PERFORMANCE_REQUEST_FIELDS
                    },
                    "engineRuns": engine_runs,
                    "endToEndRuns": wall_runs,
                }
            )
        source_revision = source_identity["sourceRevision"]
        capture = {
            "schemaVersion": gate.CAPTURE_SCHEMA,
            "variant": variant,
            "contractSHA256": self.contract_sha,
            "captureSourceSHA256": self.contract["capture"][
                "captureSourceSHA256"
            ],
            "sourceIdentitySHA256": sha256(directory / "source-identity.json"),
            "sourceRevision": source_revision,
            "sourceTreeSHA256": source_identity["sourceTreeSHA256"],
            "buildConfiguration": "Release",
            "warmupCount": 5,
            "sampleCount": 10,
            "input": {
                **copy.deepcopy(self.contract["workload"]["input"]),
                "allRequiredChecksPassed": True,
            },
            "cases": cases,
        }
        if variant == "baseline_p05":
            capture["producerInvocationNonce"] = producer_nonce
            capture["producerChallenge"] = producer_challenge
        capture["input"].pop("repositoryPath")
        write_json(directory / "capture.json", capture)
        if variant == "baseline_p05":
            self._make_baseline_producer(directory, capture)
        else:
            gate.write_sample_transcripts(
                directory / "capture.json", directory / "sample-transcripts.json"
            )
        gate.seal_capture_directory(directory)
        return directory

    def _make_baseline_producer(
        self,
        directory: Path,
        capture: dict[str, object],
        *,
        nonce: str | None = None,
        challenge: str | None = None,
    ) -> dict[str, object]:
        nonce = nonce or str(capture["producerInvocationNonce"])
        challenge = challenge or str(capture["producerChallenge"])
        label = directory.relative_to(self.root).as_posix().replace("/", "-")
        producer = directory / "producer"
        result_bundle = producer / "baseline.xcresult"
        result_bundle.mkdir(parents=True)
        (result_bundle / "Info.plist").write_text("fixture xcresult\n")
        (producer / "test-summary.json").write_text(
            json.dumps(
                {
                    "schemaVersion": gate.TEST_SUMMARY_SCHEMA,
                    "testIdentifier": gate.BASELINE_TEST_IDENTIFIER,
                    "result": "Passed",
                    "passedTests": 1,
                    "failedTests": 0,
                    "skippedTests": 0,
                },
                indent=2,
                sort_keys=True,
            )
            + "\n"
        )
        products = self.root / f"products-{label}"
        products.mkdir(exist_ok=True)
        application = products / "Mirmir"
        application.write_bytes(b"\xcf\xfa\xed\xfeapplication")
        tests = products / "MirmirTests"
        tests.write_bytes(b"\xcf\xfa\xed\xfetests")
        capture_directory = str(directory.resolve())
        derived_data = gate.CANONICAL_DERIVED_DATA
        working_directory = gate.CANONICAL_SOURCE_ROOT
        environment = {
            "MIRMIR_V4_PERFORMANCE_CAPTURE_DIR": capture_directory,
            "MIRMIR_V4_PERFORMANCE_INPUT": str(self.locked_input.resolve()),
            "MIRMIR_V4_PERFORMANCE_VARIANT": "baseline_p05",
            "MIRMIR_V4_PERFORMANCE_CONTRACT_SHA256": self.contract_sha,
            "MIRMIR_V4_PERFORMANCE_CAPTURE_SOURCE_SHA256": self.contract["capture"]["captureSourceSHA256"],
            "MIRMIR_V4_PERFORMANCE_SOURCE_IDENTITY_SHA256": str(capture["sourceIdentitySHA256"]),
            "MIRMIR_V4_PERFORMANCE_SOURCE_REVISION": str(capture["sourceRevision"]),
            "MIRMIR_V4_PERFORMANCE_SOURCE_TREE_SHA256": str(capture["sourceTreeSHA256"]),
            "MIRMIR_V4_PERFORMANCE_WARMUPS": str(capture["warmupCount"]),
            "MIRMIR_V4_PERFORMANCE_SAMPLES": str(capture["sampleCount"]),
            "MIRMIR_V4_PERFORMANCE_PRODUCER_NONCE": nonce,
            "MIRMIR_V4_PERFORMANCE_PRODUCER_CHALLENGE": challenge,
            "SWIFT_DETERMINISTIC_HASHING": "1",
            "SWIFTC_MAXIMUM_DETERMINISM": "1",
            "TMPDIR": gate.CANONICAL_SWIFT_TEMPORARY,
        }
        skeleton = {
            "buildEnvironment": environment,
            "captureDirectory": capture_directory,
            "derivedDataPath": derived_data,
            "workingDirectory": working_directory,
        }
        command = gate._expected_baseline_build_command(skeleton)
        (directory / "xcodebuild.log").write_text(
            "Release fixture build completed successfully\n"
        )
        wrapper = self.root / f"swift-wrapper-{label}"
        wrapper.write_bytes(
            gate.swift_driver_wrapper_bytes(
                self.underlying_swiftc.resolve(), Path(gate.CANONICAL_SWIFT_AUDIT)
            )
        )
        wrapper.chmod(0o755)
        swift_audit = self.root / f"swift-audit-{label}.log"
        swift_audit.write_text(
            "\n".join(sorted(gate.SWIFT_DRIVER_JOB_AUDIT_MARKERS)) + "\n"
        )
        swift_audit.chmod(0o600)
        swift_frontend_shim, swift_frontend_audit, swift_maps = (
            self._write_frontend_fixture(label)
        )
        command_path = self.root / f"command-{label}.json"
        environment_path = self.root / f"environment-{label}.json"
        write_json(command_path, command)
        write_json(environment_path, environment)
        build_request_path = self.root / f"request-{label}.json"
        write_json(build_request_path, environment)
        capture["producerRequestSHA256"] = sha256(build_request_path)
        write_json(directory / "capture.json", capture)
        gate.write_sample_transcripts(
            directory / "capture.json", directory / "sample-transcripts.json"
        )
        return gate.seal_baseline_producer_receipt(
            directory=directory,
            contract_path=self.contract_path,
            runner_path=self.runner_path,
            invocation_nonce=nonce,
            challenge=challenge,
            started_ns=1_000,
            finished_ns=2_000,
            working_directory=working_directory,
            capture_directory=capture_directory,
            derived_data_path=derived_data,
            command_path=command_path,
            environment_path=environment_path,
            build_request_path=build_request_path,
            application_executable=application,
            test_executable=tests,
            locked_input=self.locked_input,
            result_bundle=result_bundle,
            swift_driver_wrapper=wrapper,
            swift_driver_audit=swift_audit,
            swift_frontend_shim=swift_frontend_shim,
            swift_frontend_audit=swift_frontend_audit,
            swift_supplementary_maps=swift_maps,
            underlying_swiftc=self.underlying_swiftc,
            allow_fixture_runtime=True,
        )

    def _rewrite_and_reseal(self, directory: Path, filename: str, value: object) -> None:
        write_json(directory / filename, value)
        if filename == "capture.json":
            gate.write_sample_transcripts(
                directory / "capture.json", directory / "sample-transcripts.json"
            )
        gate.seal_capture_directory(directory)

    def _recompute_receipt_seals(
        self,
        directory: Path,
        receipt: dict[str, object],
        *,
        recompute_compiler_audit: bool = True,
        recompute_stable_facts: bool = True,
    ) -> None:
        capture = json.loads((directory / "capture.json").read_text())
        write_json(
            directory / "producer/build-request.json",
            receipt["buildEnvironment"],
        )
        capture["producerRequestSHA256"] = sha256(
            directory / "producer/build-request.json"
        )
        write_json(directory / "capture.json", capture)
        gate.write_sample_transcripts(
            directory / "capture.json", directory / "sample-transcripts.json"
        )
        receipt["captureArtifact"] = gate.descriptor(
            directory / "capture.json", directory
        )
        receipt["buildRequestArtifact"] = gate.descriptor(
            directory / "producer/build-request.json", directory
        )
        receipt["sampleTranscriptArtifact"] = gate.descriptor(
            directory / "sample-transcripts.json", directory
        )
        receipt["sampleTranscriptSetSHA256"] = json.loads(
            (directory / "sample-transcripts.json").read_text()
        )["sampleTranscriptSetSHA256"]
        receipt["sampleMeasurementSetSHA256"] = gate.sample_measurement_set_sha256(
            capture
        )
        receipt["sampleWorkloadIdentitySHA256"] = (
            gate.sample_workload_identity_sha256(capture)
        )
        receipt["inputArtifact"] = gate.descriptor(
            directory / "producer/locked-input.mov", directory
        )
        receipt["applicationExecutableArtifact"] = gate.descriptor(
            directory / "producer/application-executable", directory
        )
        receipt["testExecutableArtifact"] = gate.descriptor(
            directory / "producer/test-executable", directory
        )
        receipt["normalizedTestSummaryArtifact"] = gate.descriptor(
            directory / "producer/test-summary.json", directory
        )
        receipt["buildLogArtifact"] = gate.descriptor(
            directory / "xcodebuild.log", directory
        )
        receipt["swiftDriverWrapperArtifact"] = gate.descriptor(
            directory / "producer/swiftc", directory
        )
        receipt["swiftDriverAuditArtifact"] = gate.descriptor(
            directory / "producer/swift-driver-effective-argv.log", directory
        )
        receipt["swiftFrontendShimArtifact"] = gate.descriptor(
            directory / "producer/swift-frontend", directory
        )
        receipt["swiftFrontendAuditArtifact"] = gate.descriptor(
            directory / "producer/swift-frontend-effective-argv.jsonl", directory
        )
        receipt["swiftFrontendSupplementaryMapArtifacts"] = {
            module_name: gate.descriptor(
                directory
                / f"producer/supplementary-output-maps/{module_name}.json",
                directory,
            )
            for module_name in gate.SWIFT_DRIVER_REQUIRED_MODULES
        }
        if recompute_compiler_audit:
            receipt["swiftDriverWrapperIdentity"] = gate._swift_wrapper_identity(
                directory / "producer/swiftc", self.underlying_swiftc
            )
            receipt["swiftFrontendShimIdentity"] = (
                gate._swift_frontend_shim_identity(
                    directory / "producer/swift-frontend", self.underlying_swiftc
                )
            )
            receipt["compilerControlAudit"] = gate._compiler_control_audit(
                directory, receipt, self.underlying_swiftc
            )
        summary = json.loads(
            (directory / "producer/test-summary.json").read_text()
        )
        if recompute_stable_facts:
            receipt["stableProducerFacts"] = gate._stable_producer_facts(
                receipt=receipt,
                capture=capture,
                application_sha256=receipt["applicationExecutableArtifact"]["sha256"],
                test_sha256=receipt["testExecutableArtifact"]["sha256"],
                input_sha256=receipt["inputArtifact"]["sha256"],
                workload_identity_sha256=receipt["sampleWorkloadIdentitySHA256"],
                test_summary=summary,
                toolchain_identity=gate._stable_toolchain_identity(directory),
                compiler_control_audit=receipt["compilerControlAudit"],
            )
            receipt["stableProducerIdentitySHA256"] = gate._stable_producer_identity(
                receipt["stableProducerFacts"]
            )
        receipt["causalBindingSHA256"] = gate._producer_causal_binding(receipt)
        write_json(directory / "producer/producer-receipt.json", receipt)
        gate.seal_capture_directory(directory)

    def _evaluate(self, candidate: Path | None = None) -> dict[str, object]:
        return gate.evaluate(
            self.contract_path,
            self.baseline,
            candidate or self.candidate,
            allow_fixture_runtime=True,
        )

    def _verify(self, report: object) -> dict[str, object]:
        return gate.verify_report(
            report,
            self.contract_path,
            allow_fixture_runtime=True,
        )

    def _prebuild_failure_runner(self) -> Path:
        repository = self.root / "prebuild-failure-repository"
        script_directory = repository / "script/v4"
        script_directory.mkdir(parents=True)
        for filename in (
            "PerformanceGateCaptureTests.swift",
            "performance_gate_v4.py",
            "run_performance_gate_v4.sh",
        ):
            shutil.copy2(SCRIPT_DIRECTORY / filename, script_directory / filename)
        contract = json.loads(
            (SCRIPT_DIRECTORY / "performance-gate-contract-v1.json").read_text()
        )
        contract["capture"]["captureSourceSHA256"] = sha256(
            script_directory / "PerformanceGateCaptureTests.swift"
        )
        contract["capture"]["evaluatorSourceSHA256"] = sha256(
            script_directory / "performance_gate_v4.py"
        )
        contract["capture"]["runnerSourceSHA256"] = sha256(
            script_directory / "run_performance_gate_v4.sh"
        )
        input_relative = Path(contract["workload"]["input"]["repositoryPath"])
        input_source = REPOSITORY_ROOT / input_relative
        input_destination = repository / input_relative
        input_destination.parent.mkdir(parents=True)
        shutil.copy2(input_source, input_destination)
        contract["workload"]["input"]["sha256"] = "0" * 64
        write_json(script_directory / "performance-gate-contract-v1.json", contract)
        return script_directory / "run_performance_gate_v4.sh"

    def test_paired_release_evidence_passes_and_verifies(self) -> None:
        report = self._evaluate()
        self.assertTrue(report["gatePass"])
        self.assertFalse(report["exactPackagedCandidatePass"])
        self.assertFalse(report["releaseEligible"])
        self.assertLess(report["metricGates"]["aggregateCorpusWall"]["ratio"], 0.51)
        self.assertLess(report["metricGates"]["engineFrameMedian"]["ratio"], 0.51)
        self.assertLess(report["metricGates"]["engineFrameP95"]["ratio"], 0.51)
        self.assertEqual(
            self._verify(report)["reportSHA256"],
            report["reportSHA256"],
        )

    def test_equivalent_roots_have_one_path_neutral_stable_producer_identity(self) -> None:
        first = self._make_capture(
            "baseline_p05",
            wall=100.0,
            engine=10.0,
            directory_name="equivalent-root-a/baseline",
            producer_nonce="c" * 64,
            producer_challenge="d" * 64,
        )
        second = self._make_capture(
            "baseline_p05",
            wall=107.0,
            engine=12.0,
            directory_name="equivalent-root-b/baseline",
            producer_nonce="e" * 64,
            producer_challenge="f" * 64,
            peak_resident_bytes=125 * 1024**2,
        )
        first_capture = json.loads((first / "capture.json").read_text())
        second_capture = json.loads((second / "capture.json").read_text())
        first_identity = gate.validate_baseline_producer_receipt(
            first, first_capture, self.contract, self.contract_sha, True
        )
        second_identity = gate.validate_baseline_producer_receipt(
            second, second_capture, self.contract, self.contract_sha, True
        )
        self.assertNotEqual(
            first_identity["producerReceiptSHA256"],
            second_identity["producerReceiptSHA256"],
        )
        self.assertNotEqual(
            first_identity["sampleTranscriptSetSHA256"],
            second_identity["sampleTranscriptSetSHA256"],
        )
        self.assertNotEqual(
            first_identity["sampleMeasurementSetSHA256"],
            second_identity["sampleMeasurementSetSHA256"],
        )
        self.assertEqual(
            first_identity["sampleWorkloadIdentitySHA256"],
            second_identity["sampleWorkloadIdentitySHA256"],
        )
        self.assertEqual(
            first_identity["applicationExecutableSHA256"],
            second_identity["applicationExecutableSHA256"],
        )
        self.assertEqual(
            first_identity["testExecutableSHA256"],
            second_identity["testExecutableSHA256"],
        )
        self.assertEqual(
            first_identity["producerStableFacts"],
            second_identity["producerStableFacts"],
        )
        self.assertEqual(
            first_identity["producerStableIdentitySHA256"],
            second_identity["producerStableIdentitySHA256"],
        )
        first_frontend_records = [
            json.loads(line)
            for line in (
                first / "producer/swift-frontend-effective-argv.jsonl"
            ).read_text().splitlines()
        ]
        second_frontend_records = [
            json.loads(line)
            for line in (
                second / "producer/swift-frontend-effective-argv.jsonl"
            ).read_text().splitlines()
        ]
        self.assertNotEqual(
            [record["rawSupplementaryOutputFileMapPath"] for record in first_frontend_records],
            [record["rawSupplementaryOutputFileMapPath"] for record in second_frontend_records],
        )
        self.assertNotIn(
            "TemporaryDirectory.",
            json.dumps(first_identity["producerStableFacts"], sort_keys=True),
        )

    def test_sample_workload_identity_excludes_measurements_but_covers_semantics(self) -> None:
        original = json.loads((self.baseline / "capture.json").read_text())
        workload_identity = gate.sample_workload_identity_sha256(original)
        measurement_identity = gate.sample_measurement_set_sha256(original)

        timing_only = copy.deepcopy(original)
        timing_only["cases"][0]["engineRuns"][0]["frameMilliseconds"][0] += 91.0
        timing_only["cases"][0]["endToEndRuns"][0]["wallMilliseconds"] += 137.0
        timing_only["cases"][0]["endToEndRuns"][0]["peakResidentBytes"] += 4096
        self.assertEqual(
            gate.sample_workload_identity_sha256(timing_only),
            workload_identity,
        )
        self.assertNotEqual(
            gate.sample_measurement_set_sha256(timing_only),
            measurement_identity,
        )

        mutations = []
        backend = copy.deepcopy(original)
        backend["cases"][0]["backendID"] = "substitutedBackend"
        mutations.append(("backend", backend))
        case_id = copy.deepcopy(original)
        case_id["cases"][0]["id"] = "substituted-case"
        mutations.append(("case", case_id))
        target = copy.deepcopy(original)
        target["cases"][0]["targetWidth"] += 1
        mutations.append(("target", target))
        request = copy.deepcopy(original)
        request["cases"][0]["request"]["codec"] = "hevc"
        mutations.append(("request", request))
        sample_count = copy.deepcopy(original)
        sample_count["cases"][0]["engineRuns"].pop()
        mutations.append(("sample-count", sample_count))
        frame_count = copy.deepcopy(original)
        frame_count["cases"][0]["engineRuns"][0]["frameMilliseconds"].pop()
        mutations.append(("frame-count", frame_count))
        semantic_hash = copy.deepcopy(original)
        semantic_hash["cases"][0]["endToEndRuns"][0]["verification"][
            "decodedVisiblePixelSHA256"
        ] = "f" * 64
        mutations.append(("semantic-output", semantic_hash))
        semantic_flag = copy.deepcopy(original)
        semantic_flag["cases"][0]["endToEndRuns"][0]["verification"][
            "exactFrameCount"
        ] = False
        mutations.append(("semantic-flag", semantic_flag))
        for label, mutation in mutations:
            with self.subTest(label=label):
                self.assertNotEqual(
                    gate.sample_workload_identity_sha256(mutation),
                    workload_identity,
                )

    def test_fixed_request_lock_contention_preserves_existing_owner(self) -> None:
        self.assertFalse(
            FIXED_REQUEST_LOCK.exists(),
            "a real performance producer owns the fixed request path",
        )
        FIXED_REQUEST_LOCK.mkdir(mode=0o700)
        sentinel = FIXED_REQUEST_LOCK / "existing-owner"
        sentinel.write_text("not-this-runner\n")
        try:
            process = subprocess.run(
                [
                    str(SCRIPT_DIRECTORY / "run_performance_gate_v4.sh"),
                    "--output",
                    str(self.root / "contention-output"),
                    "--baseline-only",
                ],
                cwd=REPOSITORY_ROOT,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                check=False,
            )
            self.assertEqual(process.returncode, 67, process.stderr)
            self.assertEqual(sentinel.read_text(), "not-this-runner\n")
        finally:
            if sentinel.exists():
                sentinel.unlink()
            if FIXED_REQUEST_LOCK.exists():
                FIXED_REQUEST_LOCK.rmdir()

    def test_fixed_request_lock_is_cleaned_after_prebuild_failure(self) -> None:
        self.assertFalse(
            FIXED_REQUEST_LOCK.exists(),
            "a real performance producer owns the fixed request path",
        )
        runner = self._prebuild_failure_runner()
        process = subprocess.run(
            [
                str(runner),
                "--output",
                str(self.root / "prebuild-failure-output"),
                "--baseline-only",
            ],
            cwd=runner.parents[2],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
        )
        self.assertEqual(process.returncode, 66, process.stderr)
        self.assertIn("locked input SHA-256 mismatch", process.stderr)
        self.assertFalse(FIXED_REQUEST_LOCK.exists())
        self.assertFalse(FIXED_CANONICAL_ROOT.exists())

    def test_fixed_roots_are_cleaned_after_xcodebuild_failure(self) -> None:
        self.assertFalse(
            FIXED_REQUEST_LOCK.exists(),
            "a real performance producer owns the fixed request path",
        )
        self.assertFalse(
            FIXED_CANONICAL_ROOT.exists(),
            "a real performance producer owns the canonical build root",
        )
        fake_bin = self.root / "failure-tools"
        fake_bin.mkdir()
        tools = {
            "system_profiler": (
                "#!/bin/zsh\n"
                "print '{\"SPDisplaysDataType\":[]}'\n"
            ),
            "pmset": (
                "#!/bin/zsh\n"
                "if [[ \"$*\" == '-g therm' ]]; then\n"
                "  print 'No thermal warning level has been recorded'\n"
                "  print 'No performance warning level has been recorded'\n"
                "elif [[ \"$*\" == '-g batt' ]]; then\n"
                "  print 'Now drawing from AC Power'\n"
                "else\n"
                "  print 'AC Power configuration'\n"
                "fi\n"
            ),
            "sysctl": (
                "#!/bin/zsh\n"
                "case \"${@: -1}\" in\n"
                "  hw.model) print 'Mac-Test' ;;\n"
                "  hw.memsize) print '51539607552' ;;\n"
                "  machdep.cpu.brand_string) print 'Apple Test' ;;\n"
                "  *) exit 64 ;;\n"
                "esac\n"
            ),
            "swift": (
                "#!/bin/zsh\n"
                "print 'Swift version 6.2.3'\n"
            ),
            "xcodebuild": (
                "#!/bin/zsh\n"
                "if [[ \"${1:-}\" == '-version' ]]; then\n"
                "  print 'Xcode 17.3'\n"
                "  print 'Build version 17C52'\n"
                "  exit 0\n"
                "fi\n"
                "print -u2 'intentional xcodebuild failure after fixed-root acquisition'\n"
                "exit 72\n"
            ),
        }
        for name, source in tools.items():
            executable = fake_bin / name
            executable.write_text(source)
            executable.chmod(0o755)
        output = self.root / "xcodebuild-failure-output"
        environment = dict(os.environ)
        environment["PATH"] = str(fake_bin) + os.pathsep + environment["PATH"]
        process = subprocess.run(
            [
                str(SCRIPT_DIRECTORY / "run_performance_gate_v4.sh"),
                "--output",
                str(output),
                "--baseline-only",
            ],
            cwd=REPOSITORY_ROOT,
            env=environment,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
        )
        self.assertEqual(process.returncode, 72, process.stderr)
        self.assertIn("intentional xcodebuild failure", process.stderr)
        self.assertTrue((output / "baseline/xcodebuild.log").is_file())
        rejected_wrapper = output / "baseline/producer/failure-diagnostics/swiftc"
        rejected_audit = (
            output
            / "baseline/producer/failure-diagnostics/swift-driver-effective-argv.log"
        )
        rejected_frontend = (
            output / "baseline/producer/failure-diagnostics/swift-frontend"
        )
        rejected_frontend_audit = (
            output
            / "baseline/producer/failure-diagnostics/swift-frontend-effective-argv.jsonl"
        )
        rejected_maps = (
            output
            / "baseline/producer/failure-diagnostics/SupplementaryOutputMaps"
        )
        rejected_temporary = (
            output / "baseline/producer/failure-diagnostics/Temporary"
        )
        self.assertTrue(rejected_wrapper.is_file())
        self.assertTrue(rejected_audit.is_file())
        self.assertTrue(rejected_frontend.is_file())
        self.assertTrue(rejected_frontend_audit.is_file())
        self.assertTrue(rejected_maps.is_dir())
        self.assertTrue(rejected_temporary.is_dir())
        self.assertEqual(rejected_wrapper.stat().st_mode & 0o777, 0o755)
        self.assertEqual(rejected_audit.stat().st_mode & 0o777, 0o600)
        self.assertEqual(rejected_frontend.stat().st_mode & 0o777, 0o755)
        self.assertEqual(rejected_frontend_audit.stat().st_mode & 0o777, 0o600)
        self.assertFalse(FIXED_REQUEST_LOCK.exists())
        self.assertFalse(FIXED_CANONICAL_ROOT.exists())

    def test_foreign_and_stale_canonical_roots_fail_closed_without_cleanup(self) -> None:
        self.assertFalse(
            FIXED_REQUEST_LOCK.exists(),
            "a real performance producer owns the fixed request path",
        )
        self.assertFalse(
            FIXED_CANONICAL_ROOT.exists(),
            "a real performance producer owns the canonical build root",
        )
        for owner_value in (None, "foreign-owner"):
            with self.subTest(owner=owner_value or "missing"):
                FIXED_CANONICAL_ROOT.mkdir(mode=0o700)
                sentinel = FIXED_CANONICAL_ROOT / "existing-content"
                sentinel.write_text("preserve-me\n")
                owner = FIXED_CANONICAL_ROOT / "owner-token"
                if owner_value is not None:
                    owner.write_text(owner_value + "\n")
                try:
                    process = subprocess.run(
                        [
                            str(SCRIPT_DIRECTORY / "run_performance_gate_v4.sh"),
                            "--output",
                            str(self.root / f"canonical-{owner_value or 'stale'}"),
                            "--baseline-only",
                        ],
                        cwd=REPOSITORY_ROOT,
                        stdout=subprocess.PIPE,
                        stderr=subprocess.PIPE,
                        text=True,
                        check=False,
                    )
                    self.assertEqual(process.returncode, 67, process.stderr)
                    self.assertIn("foreign or stale canonical", process.stderr)
                    self.assertEqual(sentinel.read_text(), "preserve-me\n")
                    self.assertFalse(FIXED_REQUEST_LOCK.exists())
                finally:
                    if owner.exists():
                        owner.unlink()
                    if sentinel.exists():
                        sentinel.unlink()
                    if FIXED_CANONICAL_ROOT.exists():
                        FIXED_CANONICAL_ROOT.rmdir()

    def test_swift_wrapper_forces_environment_and_terminal_single_job_control(self) -> None:
        underlying = self._projecting_swiftc().resolve()
        audit = self.root / "wrapper-effective-argv.log"
        audit.write_bytes(b"")
        audit.chmod(0o600)
        wrapper = self.root / "swiftc-wrapper"
        wrapper_bytes, frontend, temporary = self._driver_wrapper_fixture_bytes(
            underlying, audit, "happy"
        )
        wrapper.write_bytes(wrapper_bytes)
        wrapper.chmod(0o755)
        capture = self.root / "swift-wrapper-capture.json"
        environment = dict(os.environ)
        environment.update(
            {
                "SWIFT_DETERMINISTIC_HASHING": "0",
                "SWIFTC_MAXIMUM_DETERMINISM": "0",
                "MIRMIR_TEST_SWIFT_CAPTURE": str(capture),
            }
        )
        process = subprocess.run(
            [str(wrapper), *self._swift_driver_arguments()],
            env=environment,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
        )
        self.assertEqual(process.returncode, 0, process.stderr)
        observed = json.loads(capture.read_text())
        self.assertEqual(observed["deterministicHashing"], "1")
        self.assertEqual(observed["maximumDeterminism"], "1")
        arguments = observed["arguments"]
        self.assertEqual(
            [arguments[index + 1] for index, value in enumerate(arguments) if value == "-j"],
            ["1"],
        )
        self.assertFalse(
            any(value.startswith("-j") and value != "-j" for value in arguments)
        )
        self.assertEqual(
            [
                arguments[index + 1]
                for index, value in enumerate(arguments[:-1])
                if value == "-driver-use-frontend-path"
            ],
            [str(frontend)],
        )
        self.assertEqual(arguments.count("-save-temps"), 1)
        self.assertEqual(observed.get("temporaryDirectory"), str(temporary))
        self.assertEqual(audit.read_text(), gate._swift_driver_job_marker("Mirmir") + "\n")

        probe_audit = self.root / "target-info-audit.log"
        probe_audit.write_bytes(b"")
        probe_audit.chmod(0o600)
        probe_wrapper = self.root / "target-info-swiftc"
        probe_bytes, _, _ = self._driver_wrapper_fixture_bytes(
            underlying, probe_audit, "target-info"
        )
        probe_wrapper.write_bytes(probe_bytes)
        probe_wrapper.chmod(0o755)
        probe = subprocess.run(
            [
                str(probe_wrapper),
                "-print-target-info",
                "-target",
                gate.SWIFT_DRIVER_REQUIRED_TARGET,
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
        )
        self.assertEqual(probe.returncode, 0, probe.stderr)
        self.assertFalse(probe_audit.read_bytes())

    def test_locked_helper_writer_preserves_exact_bytes_mode_and_exclusivity(self) -> None:
        destination = self.root / "locked-helper"
        raw = b"exact locked helper bytes\n"
        gate._write_locked_file(destination, raw, 0o755)
        self.assertEqual(destination.read_bytes(), raw)
        self.assertEqual(destination.stat().st_mode & 0o777, 0o755)
        with self.assertRaisesRegex(gate.EvidenceError, "cannot create locked compiler helper"):
            gate._write_locked_file(destination, b"replacement", 0o600)
        self.assertEqual(destination.read_bytes(), raw)
        self.assertEqual(destination.stat().st_mode & 0o777, 0o755)

    def test_frontend_shim_consumes_canonical_copied_map_and_audits_actual_argv(self) -> None:
        temporary = self.root / "frontend-temporary"
        temporary.mkdir(mode=0o700)
        transport = temporary / "TemporaryDirectory.Abc123"
        transport.mkdir(mode=0o700)
        raw_map = transport / "supplementaryOutputs-1"
        source_alias = gate.CANONICAL_SOURCE_ROOT.replace(
            "/private/tmp/", "/tmp/", 1
        )
        derived_alias = gate.CANONICAL_DERIVED_DATA.replace(
            "/private/tmp/", "/tmp/", 1
        )
        raw_map.write_text(
            json.dumps(
                {
                    f"{source_alias}/Mirmir/Mirmir.swift": {
                        "object": f"{derived_alias}/Build/Objects/Mirmir.o"
                    }
                },
                sort_keys=True,
            )
            + "\n"
        )
        raw_map.chmod(0o644)
        supplementary = self.root / "frontend-supplementary"
        supplementary.mkdir(mode=0o700)
        audit = self.root / "frontend-effective-argv.jsonl"
        audit.write_bytes(b"")
        audit.chmod(0o600)
        capture = self.root / "frontend-launch.json"
        underlying = self.root / "frontend-underlying"
        underlying.write_text(
            "#!/usr/bin/python3\n"
            "import json,os,pathlib,sys\n"
            f"pathlib.Path({str(capture)!r}).write_text(json.dumps({{\n"
            "    'arguments': sys.argv[1:],\n"
            "    'deterministicHashing': os.environ.get('SWIFT_DETERMINISTIC_HASHING'),\n"
            "    'maximumDeterminism': os.environ.get('SWIFTC_MAXIMUM_DETERMINISM'),\n"
            "    'temporaryDirectory': os.environ.get('TMPDIR'),\n"
            "}, sort_keys=True)+'\\n')\n"
        )
        underlying.chmod(0o755)
        shim = self.root / "frontend-shim"
        shim.write_bytes(
            gate.swift_frontend_shim_bytes(
                underlying.resolve(), audit, temporary, supplementary
            )
        )
        shim.chmod(0o755)
        arguments = self._frontend_effective_arguments("Mirmir")
        map_index = arguments.index("-supplementary-output-file-map") + 1
        arguments[map_index] = str(raw_map)
        environment = dict(os.environ)
        environment.update(
            {
                "SWIFT_DETERMINISTIC_HASHING": "1",
                "SWIFTC_MAXIMUM_DETERMINISM": "1",
                "TMPDIR": str(temporary),
            }
        )
        process = subprocess.run(
            [str(shim), *arguments],
            env=environment,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
        )
        self.assertEqual(process.returncode, 0, process.stderr)
        canonical_map = supplementary / "Mirmir.json"
        self.assertEqual(canonical_map.read_bytes(), raw_map.read_bytes())
        self.assertEqual(canonical_map.stat().st_mode & 0o777, 0o600)
        launched = json.loads(capture.read_text())
        self.assertEqual(launched["arguments"][0], "-frontend")
        launched_map_index = launched["arguments"].index(
            "-supplementary-output-file-map"
        ) + 1
        self.assertEqual(launched["arguments"][launched_map_index], str(canonical_map))
        self.assertNotIn(str(raw_map), launched["arguments"])
        self.assertEqual(launched["deterministicHashing"], "1")
        self.assertEqual(launched["maximumDeterminism"], "1")
        self.assertEqual(launched["temporaryDirectory"], str(temporary))
        record = json.loads(audit.read_text())
        self.assertEqual(record["rawSupplementaryOutputFileMapPath"], str(raw_map))
        self.assertEqual(
            record["canonicalSupplementaryOutputFileMapPath"], str(canonical_map)
        )
        self.assertEqual(record["supplementaryOutputFileMapSHA256"], sha256(raw_map))
        self.assertEqual(record["effectiveArgv"], launched["arguments"])

        tests_transport = temporary / "TemporaryDirectory.Def456"
        tests_transport.mkdir(mode=0o700)
        tests_raw_map = tests_transport / "supplementaryOutputs-1"
        tests_raw_map.write_text(
            json.dumps(
                {
                    f"{source_alias}/MirmirTests/MirmirTests.swift": {
                        "object": f"{derived_alias}/Build/Objects/MirmirTests.o"
                    }
                },
                sort_keys=True,
            )
            + "\n"
        )
        tests_raw_map.chmod(0o644)
        tests_arguments = self._frontend_effective_arguments("MirmirTests")
        tests_map_index = tests_arguments.index(
            "-supplementary-output-file-map"
        ) + 1
        tests_arguments[tests_map_index] = str(tests_raw_map)
        tests_process = subprocess.run(
            [str(shim), *tests_arguments],
            env=environment,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
        )
        self.assertEqual(tests_process.returncode, 0, tests_process.stderr)
        tests_canonical_map = supplementary / "MirmirTests.json"
        self.assertEqual(tests_canonical_map.read_bytes(), tests_raw_map.read_bytes())
        self.assertEqual(tests_canonical_map.stat().st_mode & 0o777, 0o600)

        audit_text = audit.read_text()
        self.assertNotIn("\n\n", audit_text)
        self.assertEqual(audit_text.count("\n"), len(gate.SWIFT_DRIVER_REQUIRED_MODULES))
        audit_records = [json.loads(line) for line in audit_text.splitlines()]
        self.assertEqual(
            [record["moduleName"] for record in audit_records],
            list(gate.SWIFT_DRIVER_REQUIRED_MODULES),
        )
        for audit_record in audit_records:
            module_name = audit_record["moduleName"]
            effective = audit_record["effectiveArgv"]
            normalized = gate._normalize_frontend_argv(
                effective, str(supplementary)
            )
            self.assertEqual(audit_record["normalizedEffectiveArgv"], normalized)
            self.assertEqual(
                audit_record["effectiveArgvSHA256"],
                hashlib.sha256(
                    gate.SWIFT_FRONTEND_JOB_AUDIT_DOMAIN
                    + b"effective\0"
                    + gate.canonical_json(effective)
                ).hexdigest(),
                module_name,
            )
            self.assertEqual(
                audit_record["normalizedEffectiveArgvSHA256"],
                hashlib.sha256(
                    gate.SWIFT_FRONTEND_JOB_AUDIT_DOMAIN
                    + gate.canonical_json(normalized)
                ).hexdigest(),
                module_name,
            )

    def test_frontend_shim_rejects_map_bypass_duplicate_and_unsafe_parent(self) -> None:
        for label in ("outside-map", "duplicate-map", "symlink-parent"):
            with self.subTest(label=label):
                root = self.root / f"frontend-reject-{label}"
                root.mkdir()
                temporary = root / "Temporary"
                temporary.mkdir(mode=0o700)
                real_parent = root / "real-parent"
                real_parent.mkdir(mode=0o700)
                if label == "symlink-parent":
                    transport = temporary / "TemporaryDirectory.Abc123"
                    transport.symlink_to(real_parent, target_is_directory=True)
                    raw_map = real_parent / "supplementaryOutputs-1"
                else:
                    transport = temporary / "TemporaryDirectory.Abc123"
                    transport.mkdir(mode=0o700)
                    raw_map = transport / "supplementaryOutputs-1"
                raw_map.write_text(
                    json.dumps(
                        {
                            "/tmp/mirmir-v4-performance-producer-v2/baseline-project/Mirmir/Mirmir.swift": {
                                "object": "/tmp/mirmir-v4-performance-producer-v2/DerivedData/baseline/Build/Objects/Mirmir.o"
                            }
                        },
                        sort_keys=True,
                    )
                    + "\n"
                )
                raw_map.chmod(0o644)
                supplementary = root / "Supplementary"
                supplementary.mkdir(mode=0o700)
                audit = root / "audit.jsonl"
                audit.write_bytes(b"")
                audit.chmod(0o600)
                shim = root / "swift-frontend"
                shim.write_bytes(
                    gate.swift_frontend_shim_bytes(
                        self.underlying_swiftc.resolve(),
                        audit,
                        temporary,
                        supplementary,
                    )
                )
                shim.chmod(0o755)
                arguments = self._frontend_effective_arguments("Mirmir")
                index = arguments.index("-supplementary-output-file-map") + 1
                arguments[index] = str(raw_map)
                if label == "outside-map":
                    outside = root / "outside-map.json"
                    shutil.copy2(raw_map, outside)
                    arguments[index] = str(outside)
                elif label == "duplicate-map":
                    arguments.extend(("-supplementary-output-file-map", str(raw_map)))
                environment = dict(
                    os.environ,
                    SWIFT_DETERMINISTIC_HASHING="1",
                    SWIFTC_MAXIMUM_DETERMINISM="1",
                    TMPDIR=str(temporary),
                )
                process = subprocess.run(
                    [str(shim), *arguments],
                    env=environment,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    text=True,
                    check=False,
                )
                self.assertEqual(process.returncode, 64, process.stderr)
                self.assertFalse(audit.read_bytes())
                self.assertFalse((supplementary / "Mirmir.json").exists())

    def test_frontend_shim_rejects_unsafe_map_metadata_and_existing_output(self) -> None:
        for label in ("wrong-mode", "hardlink", "existing-canonical-map"):
            with self.subTest(label=label):
                root = self.root / f"frontend-metadata-reject-{label}"
                root.mkdir()
                temporary = root / "Temporary"
                temporary.mkdir(mode=0o700)
                transport = temporary / "TemporaryDirectory.Abc123"
                transport.mkdir(mode=0o700)
                raw_map = transport / "supplementaryOutputs-1"
                raw_bytes = (
                    json.dumps(
                        {
                            "/tmp/mirmir-v4-performance-producer-v2/baseline-project/Mirmir/Mirmir.swift": {
                                "object": "/tmp/mirmir-v4-performance-producer-v2/DerivedData/baseline/Build/Objects/Mirmir.o"
                            }
                        },
                        sort_keys=True,
                    )
                    + "\n"
                ).encode("utf-8")
                raw_map.write_bytes(raw_bytes)
                raw_map.chmod(0o644)
                if label == "wrong-mode":
                    raw_map.chmod(0o600)
                elif label == "hardlink":
                    os.link(raw_map, root / "raw-map-hardlink")

                supplementary = root / "Supplementary"
                supplementary.mkdir(mode=0o700)
                canonical_map = supplementary / "Mirmir.json"
                existing_bytes = b"preexisting canonical map must remain unchanged\n"
                if label == "existing-canonical-map":
                    canonical_map.write_bytes(existing_bytes)
                    canonical_map.chmod(0o600)

                audit = root / "audit.jsonl"
                audit.write_bytes(b"")
                audit.chmod(0o600)
                frontend_marker = root / "underlying-frontend-executed"
                underlying = root / "swift-frontend-underlying"
                underlying.write_text(
                    "#!/usr/bin/python3\n"
                    "from pathlib import Path\n"
                    f"Path({str(frontend_marker)!r}).write_text('executed\\n')\n"
                )
                underlying.chmod(0o755)
                shim = root / "swift-frontend"
                shim.write_bytes(
                    gate.swift_frontend_shim_bytes(
                        underlying.resolve(),
                        audit,
                        temporary,
                        supplementary,
                    )
                )
                shim.chmod(0o755)
                arguments = self._frontend_effective_arguments("Mirmir")
                index = arguments.index("-supplementary-output-file-map") + 1
                arguments[index] = str(raw_map)
                environment = dict(
                    os.environ,
                    SWIFT_DETERMINISTIC_HASHING="1",
                    SWIFTC_MAXIMUM_DETERMINISM="1",
                    TMPDIR=str(temporary),
                )
                process = subprocess.run(
                    [str(shim), *arguments],
                    env=environment,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    text=True,
                    check=False,
                )
                self.assertEqual(process.returncode, 64, process.stderr)
                self.assertFalse(frontend_marker.exists())
                self.assertFalse(audit.read_bytes())
                self.assertEqual(raw_map.read_bytes(), raw_bytes)
                if label == "existing-canonical-map":
                    self.assertEqual(canonical_map.read_bytes(), existing_bytes)
                    self.assertEqual(canonical_map.stat().st_mode & 0o777, 0o600)
                    self.assertIn(
                        "cannot create canonical supplementary-output map",
                        process.stderr,
                    )
                else:
                    self.assertFalse(canonical_map.exists())
                    self.assertIn(
                        "owner, mode, or link count differs",
                        process.stderr,
                    )

    def test_swift_wrapper_rejects_absent_underlying_and_control_substitution(self) -> None:
        underlying = self._projecting_swiftc().resolve()
        mutations = {
            "missing-job-control": lambda values: [
                value
                for index, value in enumerate(values)
                if not (
                    value.startswith("-j")
                    or (index > 0 and values[index - 1] == "-j")
                )
            ],
            "missing-threads": lambda values: values[: values.index("-num-threads")]
            + values[values.index("-num-threads") + 2 :],
            "substituted-threads": lambda values: [
                "8" if value == "1" and index == values.index("-num-threads") + 1 else value
                for index, value in enumerate(values)
            ],
            "duplicate-threads": lambda values: [
                *values,
                "-num-threads",
                "1",
            ],
            "missing-seed": lambda values: values[: values.index("-Xllvm")]
            + values[values.index("-Xllvm") + 2 :],
            "substituted-seed": lambda values: [
                "-rng-seed=2" if value == "-rng-seed=1" else value
                for value in values
            ],
            "duplicate-seed": lambda values: [
                *values,
                "-Xllvm",
                "-rng-seed=1",
            ],
            "missing-module-cache": lambda values: values[
                : values.index("-module-cache-path")
            ]
            + values[values.index("-module-cache-path") + 2 :],
            "substituted-module-cache": lambda values: [
                (
                    gate.CANONICAL_PRODUCER_ROOT + "/substituted-cache"
                    if index == values.index("-module-cache-path") + 1
                    else value
                )
                for index, value in enumerate(values)
            ],
            "duplicate-module-cache": lambda values: [
                *values,
                "-module-cache-path",
                gate.CANONICAL_MODULE_CACHE,
            ],
            "forbidden-scanner-cache": lambda values: [
                *values,
                "-clang-scanner-module-cache-path",
                gate.CANONICAL_MODULE_CACHE,
            ],
            "forbidden-sdk-cache": lambda values: [
                *values,
                "-sdk-module-cache-path",
                gate.CANONICAL_MODULE_CACHE,
            ],
            "incoming-frontend-override": lambda values: [
                *values,
                "-driver-use-frontend-path",
                "/tmp/substituted-frontend",
            ],
            "incoming-save-temps": lambda values: [*values, "-save-temps"],
            "duplicate-driver-working-directory": lambda values: [
                *values,
                "-working-directory",
                gate.CANONICAL_SOURCE_ROOT.replace("/private/tmp/", "/tmp/", 1),
            ],
            "outside-source-file-list": lambda values: [
                "@/tmp/substituted.SwiftFileList" if value.startswith("@") else value
                for value in values
            ],
        }
        for label, mutate in mutations.items():
            with self.subTest(label=label):
                audit = self.root / f"{label}-audit.log"
                audit.write_bytes(b"")
                audit.chmod(0o600)
                wrapper = self.root / f"{label}-swiftc"
                wrapper_bytes, _, _ = self._driver_wrapper_fixture_bytes(
                    underlying, audit, label
                )
                wrapper.write_bytes(wrapper_bytes)
                wrapper.chmod(0o755)
                process = subprocess.run(
                    [str(wrapper), *mutate(self._swift_driver_arguments())],
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    text=True,
                    check=False,
                )
                self.assertEqual(process.returncode, 64, process.stderr)
                self.assertFalse(audit.read_bytes())

        audit = self.root / "absent-underlying-audit.log"
        audit.write_bytes(b"")
        audit.chmod(0o600)
        wrapper = self.root / "absent-underlying-swiftc"
        wrapper_bytes, _, _ = self._driver_wrapper_fixture_bytes(
            self.root / "absent/swift-frontend", audit, "absent-underlying"
        )
        wrapper.write_bytes(wrapper_bytes)
        wrapper.chmod(0o755)
        process = subprocess.run(
            [str(wrapper), *self._swift_driver_arguments()],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
        )
        self.assertEqual(process.returncode, 64, process.stderr)
        self.assertIn("projection failed", process.stderr)

    def test_resealed_missing_substituted_and_duplicate_compiler_controls_are_rejected(self) -> None:
        cases = (
            ("missing-environment", "producer build environment keys differ"),
            ("missing-marker", "markers are missing, duplicated, or substituted"),
            ("substituted-marker", "markers are missing, duplicated, or substituted"),
            ("duplicate-marker", "markers are missing, duplicated, or substituted"),
            ("wrapper-bytes", "wrapper bytes or mode differ"),
            ("wrapper-mode", "wrapper bytes or mode differ"),
            ("wrapper-receipt", "wrapper identity differs"),
            ("frontend-missing-marker", "frontend audit invocation count differs"),
            ("frontend-duplicate-marker", "frontend audit invocation count differs"),
            ("frontend-shim-bytes", "frontend shim bytes or mode differ"),
            ("frontend-shim-mode", "frontend shim bytes or mode differ"),
            ("frontend-shim-receipt", "frontend shim identity differs"),
        )
        for index, (mutation, expected) in enumerate(cases):
            with self.subTest(mutation=mutation):
                directory = self._make_capture(
                    "baseline_p05",
                    wall=100.0,
                    engine=10.0,
                    directory_name=f"compiler-control-forgery-{index}/baseline",
                )
                receipt_path = directory / "producer/producer-receipt.json"
                receipt = json.loads(receipt_path.read_text())
                if mutation == "missing-environment":
                    receipt["buildEnvironment"].pop("SWIFT_DETERMINISTIC_HASHING")
                    receipt["buildCommand"] = [
                        token for token in receipt["buildCommand"]
                        if token != "SWIFT_DETERMINISTIC_HASHING=1"
                    ]
                elif mutation in (
                    "missing-marker",
                    "substituted-marker",
                    "duplicate-marker",
                ):
                    audit_path = directory / "producer/swift-driver-effective-argv.log"
                    lines = audit_path.read_text().splitlines()
                    if mutation == "missing-marker":
                        lines.pop()
                    elif mutation == "substituted-marker":
                        lines[0] = lines[0].replace(
                            gate.SWIFT_DRIVER_REQUIRED_TARGET,
                            "arm64-apple-macos15.3",
                        )
                    else:
                        lines.append(lines[0])
                    audit_path.write_text("\n".join(lines) + "\n")
                    audit_path.chmod(0o600)
                elif mutation == "wrapper-bytes":
                    with (directory / "producer/swiftc").open("ab") as stream:
                        stream.write(b"\n")
                elif mutation == "wrapper-mode":
                    (directory / "producer/swiftc").chmod(0o700)
                elif mutation == "wrapper-receipt":
                    receipt["swiftDriverWrapperIdentity"]["sha256"] = "f" * 64
                elif mutation.startswith("frontend-") and mutation.endswith("marker"):
                    audit_path = (
                        directory / "producer/swift-frontend-effective-argv.jsonl"
                    )
                    lines = audit_path.read_text().splitlines()
                    if mutation == "frontend-missing-marker":
                        lines.pop()
                    else:
                        lines.append(lines[0])
                    audit_path.write_text("\n".join(lines) + "\n")
                    audit_path.chmod(0o600)
                elif mutation == "frontend-shim-bytes":
                    with (directory / "producer/swift-frontend").open("ab") as stream:
                        stream.write(b"\n")
                elif mutation == "frontend-shim-mode":
                    (directory / "producer/swift-frontend").chmod(0o700)
                else:
                    receipt["swiftFrontendShimIdentity"]["sha256"] = "f" * 64
                self._recompute_receipt_seals(
                    directory,
                    receipt,
                    recompute_compiler_audit=False,
                    recompute_stable_facts=False,
                )
                with self.assertRaisesRegex(gate.EvidenceError, expected):
                    gate.validate_capture(
                        directory,
                        "baseline_p05",
                        self.contract,
                        self.contract_sha,
                        True,
                    )

    def test_driver_wrapper_rejects_projected_frontend_cwd_output_and_bypass_forgery(self) -> None:
        underlying = self._projecting_swiftc().resolve()
        mutations = (
            "direct-working-directory",
            "missing-file-compilation-dir",
            "duplicate-file-compilation-dir",
            "substituted-xcc-working-directory",
            "outside-object-output",
            "wrong-frontend-executable",
        )
        for mutation in mutations:
            with self.subTest(mutation=mutation):
                audit = self.root / f"projected-{mutation}-audit.log"
                audit.write_bytes(b"")
                audit.chmod(0o600)
                wrapper_bytes, _, _ = self._driver_wrapper_fixture_bytes(
                    underlying, audit, f"projected-{mutation}"
                )
                wrapper = self.root / f"projected-{mutation}-swiftc"
                wrapper.write_bytes(wrapper_bytes)
                wrapper.chmod(0o755)
                environment = dict(os.environ)
                environment["MIRMIR_TEST_PROJECTED_MUTATION"] = mutation
                process = subprocess.run(
                    [str(wrapper), *self._swift_driver_arguments()],
                    env=environment,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    text=True,
                    check=False,
                )
                self.assertEqual(process.returncode, 64, process.stderr)
                self.assertFalse(audit.read_bytes())

    def test_resealed_frontend_canonical_bypass_and_map_substitution_are_rejected(self) -> None:
        for index, mutation in enumerate(
            ("canonical-map-bypass", "outside-output", "copied-other-module-map")
        ):
            with self.subTest(mutation=mutation):
                directory = self._make_capture(
                    "baseline_p05",
                    wall=100.0,
                    engine=10.0,
                    directory_name=f"frontend-causal-forgery-{index}/baseline",
                )
                receipt_path = directory / "producer/producer-receipt.json"
                receipt = json.loads(receipt_path.read_text())
                audit_path = (
                    directory / "producer/swift-frontend-effective-argv.jsonl"
                )
                records = [
                    json.loads(line) for line in audit_path.read_text().splitlines()
                ]
                record = next(
                    value for value in records if value["moduleName"] == "Mirmir"
                )
                map_path = (
                    directory / "producer/supplementary-output-maps/Mirmir.json"
                )
                expected = "did not consume the canonical map"
                if mutation == "canonical-map-bypass":
                    arguments = record["effectiveArgv"]
                    map_index = arguments.index("-supplementary-output-file-map") + 1
                    arguments[map_index] = record[
                        "rawSupplementaryOutputFileMapPath"
                    ]
                    record["effectiveArgvSHA256"] = hashlib.sha256(
                        gate.SWIFT_FRONTEND_JOB_AUDIT_DOMAIN
                        + b"effective\0"
                        + gate.canonical_json(arguments)
                    ).hexdigest()
                    normalized = gate._normalize_frontend_argv(arguments)
                    record["normalizedEffectiveArgv"] = normalized
                    record["normalizedEffectiveArgvSHA256"] = hashlib.sha256(
                        gate.SWIFT_FRONTEND_JOB_AUDIT_DOMAIN
                        + gate.canonical_json(normalized)
                    ).hexdigest()
                else:
                    if mutation == "outside-output":
                        value = json.loads(map_path.read_text())
                        source = next(iter(value))
                        output_kind = next(iter(value[source]))
                        value[source][output_kind] = "/tmp/substituted-output"
                        expected = "escapes fixed DerivedData"
                        write_json(map_path, value)
                        map_path.chmod(0o600)
                    else:
                        other = (
                            directory
                            / "producer/supplementary-output-maps/MirmirTests.json"
                        )
                        shutil.copy2(other, map_path)
                        map_path.chmod(0o600)
                        expected = "source is not module-bound"
                    record["supplementaryOutputFileMapByteCount"] = (
                        map_path.stat().st_size
                    )
                    record["supplementaryOutputFileMapSHA256"] = sha256(map_path)
                audit_path.write_text(
                    "".join(
                        json.dumps(value, separators=(",", ":"), sort_keys=True)
                        + "\n"
                        for value in records
                    )
                )
                audit_path.chmod(0o600)
                self._recompute_receipt_seals(
                    directory,
                    receipt,
                    recompute_compiler_audit=False,
                    recompute_stable_facts=False,
                )
                with self.assertRaisesRegex(gate.EvidenceError, expected):
                    gate.validate_capture(
                        directory,
                        "baseline_p05",
                        self.contract,
                        self.contract_sha,
                        True,
                    )

    def test_resealed_copied_receipt_without_producer_rerun_is_rejected(self) -> None:
        copied_from = self._make_capture(
            "baseline_p05",
            wall=100.0,
            engine=10.0,
            directory_name="copied-source/baseline",
            producer_nonce="c" * 64,
            producer_challenge="d" * 64,
        )
        receipt = json.loads(
            (copied_from / "producer/producer-receipt.json").read_text()
        )
        self._recompute_receipt_seals(self.baseline, receipt)
        with self.assertRaisesRegex(
            gate.EvidenceError, "producer nonce is not capture-bound"
        ):
            gate.validate_capture(
                self.baseline,
                "baseline_p05",
                self.contract,
                self.contract_sha,
                True,
            )

    def test_resealed_synthetic_build_command_is_rejected(self) -> None:
        receipt_path = self.baseline / "producer/producer-receipt.json"
        receipt = json.loads(receipt_path.read_text())
        configuration_index = receipt["buildCommand"].index("Release")
        receipt["buildCommand"][configuration_index] = "Debug"
        self._recompute_receipt_seals(
            self.baseline,
            receipt,
            recompute_compiler_audit=False,
            recompute_stable_facts=False,
        )
        with self.assertRaisesRegex(
            gate.EvidenceError, "build command/configuration differs"
        ):
            gate.validate_capture(
                self.baseline,
                "baseline_p05",
                self.contract,
                self.contract_sha,
                True,
            )

    def test_resealed_synthetic_test_summary_is_rejected(self) -> None:
        summary_path = self.baseline / "producer/test-summary.json"
        summary = json.loads(summary_path.read_text())
        summary["result"] = "Succeeded"
        write_json(summary_path, summary)
        receipt_path = self.baseline / "producer/producer-receipt.json"
        receipt = json.loads(receipt_path.read_text())
        self._recompute_receipt_seals(self.baseline, receipt)
        with self.assertRaisesRegex(
            gate.EvidenceError, "exactly one successful test"
        ):
            gate.validate_capture(
                self.baseline,
                "baseline_p05",
                self.contract,
                self.contract_sha,
                True,
            )

    def test_resealed_sample_values_without_transcript_replay_are_rejected(self) -> None:
        capture_path = self.candidate / "capture.json"
        capture = json.loads(capture_path.read_text())
        capture["cases"][0]["engineRuns"][0]["frameMilliseconds"][0] += 1.0
        write_json(capture_path, capture)
        gate.seal_capture_directory(self.candidate)
        with self.assertRaisesRegex(
            gate.EvidenceError, "sample transcripts differ from the exact captured samples"
        ):
            self._evaluate()

    def test_resealed_self_consistent_environment_substitutions_are_rejected(self) -> None:
        mutations = (
            (
                "MIRMIR_V4_PERFORMANCE_SOURCE_IDENTITY_SHA256",
                "f" * 64,
                "source identity differs",
            ),
            ("MIRMIR_V4_PERFORMANCE_WARMUPS", "6", "warmup count differs"),
            ("MIRMIR_V4_PERFORMANCE_SAMPLES", "11", "sample count differs"),
            (
                "MIRMIR_V4_PERFORMANCE_INPUT",
                "/tmp/substituted.mov",
                "input path differs",
            ),
        )
        for index, (key, replacement, expected) in enumerate(mutations):
            with self.subTest(key=key):
                directory = self._make_capture(
                    "baseline_p05",
                    wall=100.0,
                    engine=10.0,
                    directory_name=f"environment-forgery-{index}/baseline",
                )
                receipt_path = directory / "producer/producer-receipt.json"
                receipt = json.loads(receipt_path.read_text())
                receipt["buildEnvironment"][key] = replacement
                receipt["buildCommand"] = gate._expected_baseline_build_command(
                    receipt
                )
                self._recompute_receipt_seals(directory, receipt)
                with self.assertRaisesRegex(gate.EvidenceError, expected):
                    gate.validate_capture(
                        directory,
                        "baseline_p05",
                        self.contract,
                        self.contract_sha,
                        True,
                    )

    def test_final_gate_rejects_unbound_candidate_capture(self) -> None:
        with mock.patch.object(
            gate,
            "normalized_test_summary",
            return_value=json.loads(
                (self.baseline / "producer/test-summary.json").read_text()
            ),
        ), self.assertRaisesRegex(
            gate.EvidenceError,
            "candidate capture omits exact packaged-candidate identities",
        ):
            gate.evaluate(self.contract_path, self.baseline, self.candidate)

    def test_packaged_archive_verification_failure_is_normative(self) -> None:
        candidate = json.loads((self.candidate / "capture.json").read_text())
        candidate.update({
            "evidenceRequestSHA256": "8" * 64,
            "observerSourceSHA256": "9" * 64,
            "packagedCandidateIdentity": {
                "applicationArchiveSHA256": "a" * 64,
                "applicationExecutableSHA256": "b" * 64,
                "runtimeManifestSHA256": "c" * 64,
                "runtimeArtifactSetSHA256": "d" * 64,
                "sourceTreeIdentitySHA256": "e" * 64,
            },
        })
        self._rewrite_and_reseal(self.candidate, "capture.json", candidate)
        verifier = mock.Mock()
        verifier.PackagedEvidenceError = ValueError
        verifier.validate_capture_binding.side_effect = ValueError(
            "candidate record differs from the verified application archive"
        )
        with mock.patch.object(
            gate,
            "normalized_test_summary",
            return_value=json.loads(
                (self.baseline / "producer/test-summary.json").read_text()
            ),
        ), mock.patch.object(
            gate, "packaged_evidence_module", return_value=verifier
        ), self.assertRaisesRegex(
            gate.EvidenceError, "verified application archive"
        ):
            gate.evaluate(
                self.contract_path,
                self.baseline,
                self.candidate,
                Path("packaged"),
                Path("repository"),
                Path("runtime"),
            )

    def test_artifact_tamper_is_rejected(self) -> None:
        with (self.candidate / "capture.json").open("a") as stream:
            stream.write(" ")
        with self.assertRaisesRegex(
            gate.EvidenceError,
            "byte count changed|SHA-256 changed",
        ):
            self._evaluate()

    def test_capture_seal_uses_the_only_accepted_manifest_schema(self) -> None:
        manifest_path = self.candidate / "artifact-manifest.json"
        manifest_path.unlink()
        manifest = gate.seal_capture_directory(self.candidate)
        self.assertEqual(manifest["schemaVersion"], gate.ARTIFACT_MANIFEST_SCHEMA)
        gate.verify_artifact_manifest(self.candidate)

    def test_capture_fails_closed_on_scope_identity_and_verification(self) -> None:
        mutations = (
            ("warmupCount", 4, "too few warmups"),
            ("sampleCount", 9, "too few measured runs"),
        )
        for field, replacement, message in mutations:
            with self.subTest(field=field):
                candidate = json.loads((self.candidate / "capture.json").read_text())
                original = candidate[field]
                candidate[field] = replacement
                self._rewrite_and_reseal(self.candidate, "capture.json", candidate)
                with self.assertRaisesRegex(gate.EvidenceError, message):
                    self._evaluate()
                candidate[field] = original
                self._rewrite_and_reseal(self.candidate, "capture.json", candidate)

        candidate = json.loads((self.candidate / "capture.json").read_text())
        candidate["cases"][0]["endToEndRuns"][0]["verification"][
            "allInputTracksAccounted"
        ] = False
        self._rewrite_and_reseal(self.candidate, "capture.json", candidate)
        with self.assertRaisesRegex(gate.EvidenceError, "allInputTracksAccounted failed"):
            self._evaluate()

    def test_unlocked_runtime_and_environment_mismatch_are_rejected(self) -> None:
        source = json.loads((self.candidate / "source-identity.json").read_text())
        source["runtime"]["releaseQualified"] = False
        self._rewrite_and_reseal(self.candidate, "source-identity.json", source)
        capture = json.loads((self.candidate / "capture.json").read_text())
        capture["sourceIdentitySHA256"] = sha256(
            self.candidate / "source-identity.json"
        )
        self._rewrite_and_reseal(self.candidate, "capture.json", capture)
        with self.assertRaisesRegex(gate.EvidenceError, "candidate release qualification"):
            self._evaluate()

        self.candidate = self._fresh_candidate()
        environment = json.loads(
            (self.candidate / "environment-after.json").read_text()
        )
        environment["stableIdentity"]["macOSBuild"] = "different"
        self._rewrite_and_reseal(
            self.candidate, "environment-after.json", environment
        )
        report = self._evaluate()
        self.assertFalse(report["environmentGate"]["pass"])
        self.assertFalse(report["gatePass"])
        with self.assertRaisesRegex(gate.EvidenceError, "did not pass"):
            self._verify(report)

    def test_candidate_provenance_revision_requires_40_or_64_hex(self) -> None:
        source = json.loads((self.candidate / "source-identity.json").read_text())
        self.assertEqual(len(source["runtime"]["manifestSourceRevision"]), 64)
        gate.validate_source_identity(source, "candidate_p06", self.contract)

        for invalid in ("b" * 39, "b" * 41, "B" * 40, "g" * 64):
            with self.subTest(value=invalid):
                mutated = copy.deepcopy(source)
                mutated["runtime"]["manifestSourceRevision"] = invalid
                with self.assertRaisesRegex(
                    gate.EvidenceError,
                    "40- or 64-character lowercase hexadecimal identity",
                ):
                    gate.validate_source_identity(
                        mutated,
                        "candidate_p06",
                        self.contract,
                    )

    def test_slow_candidate_and_report_tamper_fail_verification(self) -> None:
        candidate = json.loads((self.candidate / "capture.json").read_text())
        for case in candidate["cases"]:
            for run in case["engineRuns"]:
                run["frameMilliseconds"] = [12.0, 12.1, 12.2]
            for run in case["endToEndRuns"]:
                run["wallMilliseconds"] = 120.0
        self._rewrite_and_reseal(self.candidate, "capture.json", candidate)
        report = self._evaluate()
        self.assertFalse(report["gatePass"])
        with self.assertRaisesRegex(gate.EvidenceError, "did not pass"):
            self._verify(report)

        report = self._evaluate(self._fresh_candidate())
        report["metricGates"]["engineFrameMedian"]["ratio"] = 0.1
        with self.assertRaisesRegex(gate.EvidenceError, "report seal differs"):
            self._verify(report)

    def test_baseline_build_uses_xcode_single_thread_setting_once(self) -> None:
        receipt = json.loads(
            (self.baseline / "producer/producer-receipt.json").read_text()
        )
        command = gate._expected_baseline_build_command(receipt)
        self.assertEqual(command.count("SWIFT_NUM_THREADS=1"), 1)
        swift_flags = [
            value for value in command
            if value.startswith("OTHER_SWIFT_FLAGS=")
        ]
        self.assertEqual(len(swift_flags), 1)
        self.assertIn(" -j 1 ", swift_flags[0])
        self.assertNotIn("-num-threads", swift_flags[0])

    def test_locked_tools_and_runner_use_semantic_p06_manifest_identity(self) -> None:
        contract_path = SCRIPT_DIRECTORY / "performance-gate-contract-v1.json"
        runner = SCRIPT_DIRECTORY / "run_performance_gate_v4.sh"
        locked_contract = json.loads(
            contract_path.read_text()
        )
        self.assertEqual(contract_path.stat().st_size, 5_152)
        self.assertEqual(
            sha256(contract_path),
            "42cc36f29a385ba77c50a8aa673ea6808ef98eecf562e6f4742fc89a83729430",
        )
        locked_tools = {
            "captureSourceSHA256": (
                SCRIPT_DIRECTORY / "PerformanceGateCaptureTests.swift",
                30_267,
                "8a6acc0b976a5408e2d0ce496b6fb62972607c5ff80039c3e5b102c9a8b04a3b",
            ),
            "evaluatorSourceSHA256": (
                SCRIPT_DIRECTORY / "performance_gate_v4.py",
                187_072,
                "7e89bf754d6dde082d1cf506750d8912898489929b5a315f62229cad4c29f758",
            ),
            "runnerSourceSHA256": (
                runner,
                39_826,
                "ebec53b106ad04712f4e266f27ee29157938e28e1e649dd9df81c0a996aa08dc",
            ),
        }
        for field, (source, expected_size, expected_sha256) in (
            locked_tools.items()
        ):
            with self.subTest(field=field):
                self.assertEqual(source.stat().st_size, expected_size)
                self.assertEqual(sha256(source), expected_sha256)
                self.assertEqual(
                    locked_contract["capture"][field],
                    expected_sha256,
                )
        source = runner.read_text()
        self.assertIn('b"ash-p06-runtime-manifest-v4\\0"', source)
        self.assertIn("manifest_bytes != canonical_manifest_bytes", source)
        self.assertIn("/private/tmp/mirmir-v4-performance-request-v2.lock", source)
        self.assertIn("/private/tmp/mirmir-v4-performance-producer-v2", source)
        self.assertIn("SWIFT_DETERMINISTIC_HASHING=1", source)
        self.assertIn("SWIFTC_MAXIMUM_DETERMINISM=1", source)
        self.assertIn("write-swift-helpers", source)
        self.assertIn('SWIFT_EXEC=$canonical_swift_wrapper', source)
        self.assertIn("canonical_swift_frontend_shim", source)
        self.assertIn("canonical_swift_frontend_audit", source)
        self.assertIn("canonical_swift_supplementary_maps", source)
        self.assertIn('"TMPDIR=$canonical_swift_temporary"', source)
        self.assertIn("SWIFT_USE_INTEGRATED_DRIVER=NO", source)
        self.assertIn("path.removeprefix(\"/private\")", source)
        self.assertIn("-Xllvm -rng-seed=1", source)
        runner_flags = next(
            line for line in source.splitlines()
            if '"OTHER_SWIFT_FLAGS=' in line
        )
        self.assertIn("-j 1", runner_flags)
        self.assertNotIn("-num-threads", runner_flags)
        self.assertIn("SWIFT_NUM_THREADS=1", source)
        self.assertNotIn('${project_root/#\\/private\\/tmp/\\/tmp}', source)
        capture_source = (
            SCRIPT_DIRECTORY / "PerformanceGateCaptureTests.swift"
        ).read_text()
        self.assertIn("mirmir-v4-performance-request-v2.lock/request.json", capture_source)
        self.assertNotIn("__MIRMIR_V4_PERFORMANCE_", capture_source)

        manifest = {"runtimeID": "ash-p06-deterministic-v4", "version": 1}
        canonical = json.dumps(
            manifest,
            ensure_ascii=False,
            separators=(",", ":"),
            sort_keys=True,
        ).encode("utf-8")
        raw_identity = hashlib.sha256(canonical).hexdigest()
        semantic_identity = hashlib.sha256(
            b"ash-p06-runtime-manifest-v4\0" + canonical
        ).hexdigest()
        self.assertNotEqual(raw_identity, semantic_identity)

    def _fresh_candidate(self) -> Path:
        candidate = self.root / "candidate_p06"
        if candidate.exists():
            for child in candidate.iterdir():
                child.unlink()
            candidate.rmdir()
        return self._make_capture("candidate_p06", wall=50.0, engine=5.0)


if __name__ == "__main__":
    unittest.main()
