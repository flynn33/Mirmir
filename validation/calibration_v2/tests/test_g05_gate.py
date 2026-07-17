from __future__ import annotations

import copy
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock

from validation.calibration_v2.g05.gate import (
    CANONICAL_RUN_RELATIVE_PATHS,
    EVIDENCE_FILENAMES,
    G03_ASSESSMENT_CRITERIA,
    G03_CURRENT_BINARY,
    G03_CURRENT_CONTRACT,
    G03_CURRENT_SOURCE_FILES,
    G03_EXHAUSTIVE_COUNTS,
    G03_VECTOR_COUNTS,
    G04_ASSESSMENT_CRITERIA,
    G05_COMMAND_IDS,
    G05GateError,
    LIVE_PREOPEN_RELATIVE_PATHS,
    build_g04_closure_attestation,
    build_g05_documents,
    build_g05_finding_register,
    build_g05_receipt,
    document_bytes,
    validate_g04_closure_attestation,
    validate_g05_evidence,
    validate_g05_receipt,
    validate_g05_upstream_bindings,
)
from validation.calibration_v2.g05 import gate as g05_gate
from validation.quality.src.mirmir_quality.json_tools import canonical_sha256


REPOSITORY_ROOT = Path(__file__).resolve().parents[3]
P05_RUNNER = REPOSITORY_ROOT / "validation/spatial_v2/run_p05_evidence.py"


def test_g04_closure_attestation_rejects_forged_counts_and_composite() -> None:
    manifest = {
        "schema_version": "2.0.0",
        "directories": ["analysis"],
        "artifacts": [
            {
                "path": "analysis/g04-gate-assessment.json",
                "sha256": "1" * 64,
                "size_bytes": 100,
            },
            {
                "path": "publication-transaction.json",
                "sha256": "2" * 64,
                "size_bytes": 300,
            },
            {
                "path": "test-results.json",
                "sha256": "3" * 64,
                "size_bytes": 200,
            },
        ],
    }
    manifest_sha256 = "4" * 64
    attestation = build_g04_closure_attestation(
        manifest=manifest,
        manifest_sha256=manifest_sha256,
    )
    validate_g04_closure_attestation(
        manifest=manifest,
        manifest_sha256=manifest_sha256,
        attestation=attestation,
    )
    mutations = (
        ("artifact_file_count", int(attestation["artifact_file_count"]) + 1),
        ("wrapper_file_count", int(attestation["wrapper_file_count"]) + 1),
        ("descendant_directory_count", 0),
        ("closure_composite_sha256", "0" * 64),
    )
    for field, value in mutations:
        forged = dict(attestation)
        forged[field] = value
        try:
            validate_g04_closure_attestation(
                manifest=manifest,
                manifest_sha256=manifest_sha256,
                attestation=forged,
            )
        except G05GateError as error:
            if "transitive closure attestation differs" not in str(error):
                raise
        else:
            raise AssertionError(f"forged G04 closure field was accepted: {field}")

    without_transaction = copy.deepcopy(manifest)
    without_transaction["artifacts"] = [
        row
        for row in without_transaction["artifacts"]
        if row["path"] != "publication-transaction.json"
    ]
    try:
        build_g04_closure_attestation(
            manifest=without_transaction,
            manifest_sha256=manifest_sha256,
        )
    except G05GateError as error:
        if "publication transaction" not in str(error):
            raise
    else:
        raise AssertionError("G04 closure without publication transaction was accepted")


def test_regular_file_reader_rejects_ctime_change(tmp_path: Path) -> None:
    path = tmp_path / "evidence.json"
    path.write_bytes(b"{}\n")
    observed = os.lstat(path)
    stable = SimpleNamespace(
        st_dev=observed.st_dev,
        st_ino=observed.st_ino,
        st_mode=observed.st_mode,
        st_size=observed.st_size,
        st_mtime_ns=observed.st_mtime_ns,
        st_ctime_ns=observed.st_ctime_ns,
        st_nlink=observed.st_nlink,
    )
    changed = SimpleNamespace(
        st_dev=observed.st_dev,
        st_ino=observed.st_ino,
        st_mode=observed.st_mode,
        st_size=observed.st_size,
        st_mtime_ns=observed.st_mtime_ns,
        st_ctime_ns=observed.st_ctime_ns + 1,
        st_nlink=observed.st_nlink,
    )
    with mock.patch.object(g05_gate.os, "fstat", side_effect=(stable, changed)):
        try:
            g05_gate._read_regular_file(path, "ctime mutation fixture")
        except G05GateError as error:
            if "changed while reading" not in str(error):
                raise
        else:
            raise AssertionError("reader accepted a ctime mutation")


def test_pinned_wrapper_context_survives_namespace_replacement(
    tmp_path: Path,
) -> None:
    root = tmp_path / "published-wrapper"
    nested = root / "evidence/run-a"
    nested.mkdir(parents=True)
    marker = nested / "marker.json"
    marker.write_bytes(b'{"identity":"original"}\n')
    metadata = os.lstat(root)
    original_cwd = Path.cwd()
    displaced = tmp_path / "displaced-wrapper"

    with g05_gate.pinned_wrapper_root(
        root,
        (metadata.st_dev, metadata.st_ino),
    ) as pinned:
        root.rename(displaced)
        replacement = root / "evidence/run-a"
        replacement.mkdir(parents=True)
        (replacement / "marker.json").write_bytes(
            b'{"identity":"replacement"}\n'
        )
        observed = g05_gate._directory(
            pinned / "evidence/run-a",
            "pinned run fixture",
        )
        assert g05_gate._read_regular_file(
            observed / "marker.json",
            "pinned marker fixture",
        ) == b'{"identity":"original"}\n'
        assert g05_gate._original_partial_root(pinned) == (
            tmp_path / ".published-wrapper.partial"
        )

    assert Path.cwd() == original_cwd


class G05GateTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.workspace = Path(
            tempfile.mkdtemp(
                prefix="mirmir-g05-gate-tests-",
                dir=str(REPOSITORY_ROOT.parent),
            )
        )
        cls.seed = cls.workspace / "seed"
        subprocess.run(
            ["python3", str(P05_RUNNER), "--output", str(cls.seed)],
            cwd=REPOSITORY_ROOT,
            check=True,
            capture_output=True,
            text=True,
        )
        cls.source_commit = subprocess.run(
            ["git", "rev-parse", "HEAD"],
            cwd=REPOSITORY_ROOT,
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()

    @classmethod
    def tearDownClass(cls) -> None:
        shutil.rmtree(cls.workspace)

    def _case_root(self, name: str) -> Path:
        root = self.workspace / f"{name}-{next(tempfile._get_candidate_names())}"
        root.mkdir()
        self.addCleanup(shutil.rmtree, root, True)
        return root

    def _runs(self, name: str = "case") -> tuple[Path, Path, Path]:
        root = self._case_root(name)
        runs = tuple(root / f"run-{index}" for index in range(1, 4))
        for run in runs:
            shutil.copytree(self.seed, run)
        return runs

    @staticmethod
    def _write_same_document(
        runs: tuple[Path, Path, Path],
        filename: str,
        mutate: object,
    ) -> None:
        document = json.loads((runs[0] / filename).read_text(encoding="utf-8"))
        mutate(document)
        payload = (
            json.dumps(document, ensure_ascii=False, allow_nan=False, sort_keys=True, indent=2)
            + "\n"
        ).encode("utf-8")
        for run in runs:
            (run / filename).write_bytes(payload)

    @classmethod
    def _write_all_provenance(
        cls,
        runs: tuple[Path, Path, Path],
        mutate: object,
    ) -> None:
        for filename in EVIDENCE_FILENAMES:
            cls._write_same_document(runs, filename, lambda document: mutate(document["provenance"]))

    def _documents_and_wrapper(
        self,
        runs: tuple[Path, Path, Path],
    ) -> tuple[
        dict[str, object],
        dict[str, object],
        Path,
        tuple[Path, Path, Path],
        Path,
        Path,
        Path,
    ]:
        wrapper_parent = self._case_root("wrapper-parent")
        final_name = f"g05-{next(tempfile._get_candidate_names())}"
        wrapper = wrapper_parent / f".{final_name}.partial"
        wrapper.mkdir()
        canonical_runs = tuple(wrapper / relative for relative in CANONICAL_RUN_RELATIVE_PATHS)
        for source, destination in zip(runs, canonical_runs):
            shutil.copytree(source, destination)
        assessment, register = build_g05_documents(
            repository_root=REPOSITORY_ROOT,
            run_roots=canonical_runs,
            source_commit=self.source_commit,
        )
        assessment_path = wrapper / "analysis/g05-gate-assessment.json"
        register_path = wrapper / "analysis/g05-scoped-finding-register.json"
        assessment_path.parent.mkdir()
        assessment_path.write_bytes(document_bytes(assessment))
        register_path.write_bytes(document_bytes(register))
        upstream_path = self._write_upstream_bindings(wrapper)
        self._write_command_execution_aggregate(wrapper)
        return (
            dict(assessment),
            dict(register),
            wrapper,
            canonical_runs,
            assessment_path,
            register_path,
            upstream_path,
        )

    def _write_command_execution_aggregate(self, wrapper: Path) -> Path:
        closure = validate_g05_evidence(
            REPOSITORY_ROOT,
            tuple(wrapper / relative for relative in CANONICAL_RUN_RELATIVE_PATHS),
        )
        baseline = json.loads(
            (REPOSITORY_ROOT / "audit-result.json").read_text(encoding="utf-8")
        )["attribution_scan"]["base"]
        p00_body = {
            "schema_version": "1.0.0",
            "status": "pass",
            "baseline_commit": baseline,
            "source_commit": self.source_commit,
            "ancestry": "baseline_is_ancestor_of_source",
            "tracked_records": [
                {
                    "path": relative,
                    "sha256": hashlib.sha256(
                        (REPOSITORY_ROOT / relative).read_bytes()
                    ).hexdigest(),
                    "size_bytes": (REPOSITORY_ROOT / relative).stat().st_size,
                }
                for relative in (
                    "audit-result.json",
                    "local-work-plan.md",
                    "validation/calibration_v2/production_evaluator.py",
                    "validation/calibration_v2/native_adapter/factory.py",
                )
            ],
        }
        p00_binding = {
            **p00_body,
            "binding_sha256": canonical_sha256(p00_body),
        }
        partial_root = wrapper
        python_executable = os.fspath(Path(sys.executable).resolve(strict=True))
        swiftlint = shutil.which(
            "swiftlint",
            path="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin",
        )
        if swiftlint is None:
            raise AssertionError("SwiftLint fixture executable is absent")
        swiftlint_executable = os.fspath(Path(swiftlint).resolve(strict=True))
        python_environment = {
            "HOME": os.environ.get("HOME", ""),
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin",
            "LANG": "C",
            "LC_ALL": "C",
            "PYTHONDONTWRITEBYTECODE": "1",
            "PYTHONPATH": os.fspath(REPOSITORY_ROOT),
        }
        native_environment = {
            key: value
            for key, value in python_environment.items()
            if key not in {"PYTHONDONTWRITEBYTECODE", "PYTHONPATH"}
        }
        command_rows: list[dict[str, object]] = []
        for identifier in G05_COMMAND_IDS[:3]:
            command_rows.append(
                {
                    "id": identifier,
                    "argv": [
                        python_executable,
                        "validation/spatial_v2/run_p05_evidence.py",
                        "--output",
                        os.fspath(partial_root / "evidence" / identifier),
                    ],
                    "cwd": os.fspath(REPOSITORY_ROOT),
                    "environment": python_environment,
                    "exit_status": 0,
                    "output_path": f"outputs/{identifier}.log",
                }
            )
        for identifier, suffix in (("quality-lock-a", "a"), ("quality-lock-b", "b")):
            command_rows.append(
                {
                    "id": identifier,
                    "argv": [
                        python_executable,
                        "validation/quality/tools/"
                        "build_quality_harness_implementation_manifest.py",
                        "--repository-root",
                        os.fspath(REPOSITORY_ROOT),
                        "--output",
                        os.fspath(
                            partial_root / f"inputs/quality-harness-lock-{suffix}.json"
                        ),
                    ],
                    "cwd": os.fspath(REPOSITORY_ROOT),
                    "environment": python_environment,
                    "exit_status": 0,
                    "output_path": f"outputs/{identifier}.log",
                }
            )
        command_rows.extend(
            (
                {
                    "id": "swiftlint",
                    "argv": [
                        swiftlint_executable,
                        "lint",
                        "--quiet",
                        "--strict",
                        "--config",
                        ".swiftlint.yml",
                    ],
                    "cwd": os.fspath(REPOSITORY_ROOT),
                    "environment": native_environment,
                    "exit_status": 0,
                    "output_path": "outputs/swiftlint.log",
                },
                {
                    "id": "attribution",
                    "argv": [
                        python_executable,
                        "tools/scan_project_attribution.py",
                        os.fspath(REPOSITORY_ROOT),
                        "--policy",
                        "config/attribution_policy.json",
                        "--base",
                        baseline,
                        "--include",
                        os.fspath(partial_root),
                    ],
                    "cwd": "{instruction-package-root}",
                    "environment": python_environment,
                    "exit_status": 0,
                    "output_path": "outputs/attribution.log",
                },
                {
                    "id": "instruction-package",
                    "argv": [python_executable, "tools/validate_instruction_package.py"],
                    "cwd": "{instruction-package-root}",
                    "environment": python_environment,
                    "exit_status": 0,
                    "output_path": "outputs/instruction-package.log",
                },
                {
                    "id": "diff-check",
                    "argv": ["/usr/bin/git", "diff", "--check"],
                    "cwd": os.fspath(REPOSITORY_ROOT),
                    "environment": native_environment,
                    "exit_status": 0,
                    "output_path": "outputs/diff-check.log",
                },
            )
        )
        command_plan_path = wrapper / "inputs/g05-command-plan.json"
        command_plan_path.parent.mkdir(parents=True, exist_ok=True)
        command_plan_path.write_bytes(
            document_bytes(
                {
                    "schema_version": "1.0.0",
                    "artifact_kind": "g05_current_source_command_plan",
                    "source_commit": self.source_commit,
                    "commands": command_rows,
                }
            )
        )
        media_policy_sha256 = "d" * 64
        instruction_directory = wrapper / "inputs/instruction-package"
        instruction_directory.mkdir()
        instruction_manifest = {
            "schema_version": "1.1.0",
            "package": "fixture instruction package",
            "created_utc": "2026-07-15T11:00:00Z",
            "total_package_file_count": 3,
            "payload_file_count": 1,
            "checksum_entry_count": 2,
            "payload_exclusions": ["SHA256SUMS.txt", "package_manifest.json"],
            "files": [
                {
                    "path": "config/geometry_color_audio_policy.json",
                    "sha256": media_policy_sha256,
                    "size_bytes": 1,
                }
            ],
        }
        instruction_manifest_payload = document_bytes(instruction_manifest)
        instruction_manifest_path = instruction_directory / "package_manifest.json"
        instruction_manifest_path.write_bytes(instruction_manifest_payload)
        instruction_checksum_payload = (
            f"{media_policy_sha256}  config/geometry_color_audio_policy.json\n"
            f"{hashlib.sha256(instruction_manifest_payload).hexdigest()}  "
            "package_manifest.json\n"
        ).encode("ascii")
        instruction_checksum_path = instruction_directory / "SHA256SUMS.txt"
        instruction_checksum_path.write_bytes(instruction_checksum_payload)
        upstream_sha256 = hashlib.sha256(
            (wrapper / "inputs/upstream-bindings.json").read_bytes()
        ).hexdigest()
        def sha(relative: str) -> str:
            return hashlib.sha256((REPOSITORY_ROOT / relative).read_bytes()).hexdigest()

        def tool(executable: str) -> dict[str, object]:
            return {
                "executable": executable,
                "version": "fixture-version",
                "version_sha256": "a" * 64,
            }
        identity_body = {
            "schema_version": "1.0.0",
            "artifact_kind": "g05_current_source_run_identity",
            "run_id": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            "started_utc": "2026-07-15T11:59:59Z",
            "ended_utc": "2026-07-15T12:00:20Z",
            "outcome": "pass",
            "source_commit": self.source_commit,
            "p00_baseline": p00_binding,
            "working_tree": {
                "clean": True,
                "dirty_state_sha256": hashlib.sha256(b"").hexdigest(),
            },
            "route": "direct-both",
            "routes_exercised": ["direct_2x", "direct_3_over_2"],
            "mode": "synthetic-p05-current-source",
            "configuration_sha256": closure["provenance_manifest_sha256"][
                "configuration"
            ],
            "configuration_components": {
                "mapping": {
                    "kind": "ash_video_mapping_v2_seed",
                    "sha256": sha(
                        "Mirmir/Resources/ASH/ash_video_mapping_v2.seed.json"
                    ),
                },
                "operator_bank": {
                    "kind": "operator_bank_v2_seed",
                    "sha256": sha(
                        "Mirmir/Resources/ASH/operator_bank_v2.seed.json"
                    ),
                },
                "branch_lut": {
                    "status": "not_applicable_pre_g06",
                    "sha256": None,
                },
                "metric_policy": {
                    "kind": "development_metric_policy",
                    "sha256": sha("validation/quality/policies/metric-policy.json"),
                },
                "media_policy": {
                    "kind": "instruction_geometry_color_audio_policy",
                    "sha256": media_policy_sha256,
                },
            },
            "coordinate_policies": ["half_pixel_center", "source_aligned_rational"],
            "analysis_granularity": "synthetic_fixture_cell",
            "temporal_mode": (
                "spatial_reference_with_state_causality_controls_no_temporal_reconstruction"
            ),
            "comparison_domain": (
                "raw_engine_synthetic_cpu_reference_no_container_decode"
            ),
            "evidence_context": {
                "quality_harness_manifest": {
                    "kind": "quality_harness_implementation_manifest",
                    "sha256": sha(
                        "validation/quality/locks/"
                        "quality-harness-implementation-manifest.json"
                    ),
                },
                "spatial_preregistration": {
                    "kind": "p05_spatial_semantics_preregistration",
                    "sha256": sha(
                        "validation/calibration_v2/contracts/"
                        "spatial-semantics-preregistration-v2.json"
                    ),
                },
                "upstream_bindings": {
                    "status": "bound_in_wrapper",
                    "sha256": upstream_sha256,
                },
            },
            "synthetic_input": {
                "kind": "p05_synthetic_harness_manifest",
                "sha256": closure["provenance_manifest_sha256"]["harness"],
            },
            "synthetic_target": {
                "kind": "p05_reference_evidence_closure",
                "sha256": closure["run_sha256"],
            },
            "instruction_package": {
                "root": "{instruction-package-root}",
                "package_manifest_sha256": hashlib.sha256(
                    instruction_manifest_payload
                ).hexdigest(),
                "checksum_index_sha256": hashlib.sha256(
                    instruction_checksum_payload
                ).hexdigest(),
                "p00_baseline_commit": baseline,
            },
            "toolchain": {
                "python": tool(python_executable),
                "xcode": tool("/usr/bin/xcodebuild"),
                "swift": tool("/usr/bin/xcrun"),
                "macos_sdk": tool("/usr/bin/xcrun"),
                "swiftlint": tool(swiftlint_executable),
                "metal_device": {
                    "applicable": False,
                    "reason": "not_used_by_g05_synthetic_cpu_reference",
                },
            },
            "platform": {
                "os": "Darwin",
                "release": "fixture",
                "machine": "arm64",
                "node": "fixture",
            },
            "holdout_accessed": False,
            "holdout_access_status": "proven_unopened",
            "assessor_pixel_accessed": False,
        }
        run_identity_path = wrapper / "run-identity.json"
        run_identity_path.write_bytes(
            document_bytes(
                {
                    **identity_body,
                    "identity_sha256": canonical_sha256(identity_body),
                }
            )
        )
        quality_payload = (
            REPOSITORY_ROOT
            / "validation/quality/locks/quality-harness-implementation-manifest.json"
        ).read_bytes()
        for suffix in ("a", "b"):
            (wrapper / f"inputs/quality-harness-lock-{suffix}.json").write_bytes(
                quality_payload
            )
        output_root = wrapper / "outputs"
        output_root.mkdir()
        stdout_payloads: dict[str, bytes] = {}
        for identifier in G05_COMMAND_IDS[:3]:
            stdout_payloads[identifier] = b"".join(
                (
                    f"{hashlib.sha256((wrapper / f'evidence/{identifier}/{name}').read_bytes()).hexdigest()}  "
                    f"{name}\n"
                ).encode("utf-8")
                for name in EVIDENCE_FILENAMES
            )
        quality_document = json.loads(quality_payload)
        for identifier in ("quality-lock-a", "quality-lock-b"):
            stdout_payloads[identifier] = (
                f"{quality_document['manifest_sha256']}\n".encode("ascii")
            )
        stdout_payloads.update(
            {
                "swiftlint": b"Found 0 violations, 0 serious in 42 files.\n",
                "attribution": document_bytes(
                    {
                        "status": "pass",
                        "base": baseline,
                        "changed_file_count": 0,
                        "findings": [],
                    }
                ),
                "instruction-package": (
                    "PASS\n"
                    "total_files=3\n"
                    "payload_files=1\n"
                    "checksum_entries=2\n"
                    f"{media_policy_sha256}  config/geometry_color_audio_policy.json\n"
                ).encode("ascii"),
                "diff-check": b"",
            }
        )
        rows: list[dict[str, object]] = []
        for command_index, (identifier, command_row) in enumerate(
            zip(G05_COMMAND_IDS, command_rows)
        ):
            stdout_path = output_root / f"{identifier}.log"
            stderr_path = output_root / f"{identifier}.stderr.log"
            result_path = output_root / f"{identifier}.result.json"
            stdout_path.write_bytes(stdout_payloads[identifier])
            stderr_path.write_bytes(b"")
            if identifier in G05_COMMAND_IDS[:3]:
                products = [
                    self._binding(wrapper, wrapper / f"evidence/{identifier}/{name}")
                    for name in EVIDENCE_FILENAMES
                ]
            elif identifier in {"quality-lock-a", "quality-lock-b"}:
                products = [
                    self._binding(
                        wrapper,
                        wrapper / f"inputs/quality-harness-lock-{identifier[-1]}.json",
                    )
                ]
            elif identifier == "instruction-package":
                products = [
                    self._binding(wrapper, instruction_manifest_path),
                    self._binding(wrapper, instruction_checksum_path),
                ]
            else:
                products = []
            result_body = {
                "schema_version": "1.0.0",
                "artifact_kind": "g05_bound_command_result",
                "command_id": identifier,
                "status": "pass",
                "started_utc": f"2026-07-15T12:00:{command_index * 2:02d}Z",
                "ended_utc": f"2026-07-15T12:00:{command_index * 2 + 1:02d}Z",
                "expected_exit_status": 0,
                "actual_exit_status": 0,
                "command_plan_row_sha256": canonical_sha256(command_row),
                "stdout": self._binding(wrapper, stdout_path),
                "stderr": self._binding(wrapper, stderr_path),
                "produced_artifacts": products,
            }
            result_path.write_bytes(
                document_bytes(
                    {
                        **result_body,
                        "receipt_sha256": canonical_sha256(result_body),
                    }
                )
            )
            rows.append(
                {
                    "id": identifier,
                    "stdout": self._binding(wrapper, stdout_path),
                    "stderr": self._binding(wrapper, stderr_path),
                    "result": self._binding(wrapper, result_path),
                }
            )
        aggregate_body = {
            "schema_version": "1.0.0",
            "artifact_kind": "g05_command_execution_aggregate",
            "status": "pass",
            "source_commit": self.source_commit,
            "command_plan": self._binding(wrapper, command_plan_path),
            "run_identity": self._binding(wrapper, run_identity_path),
            "commands": rows,
        }
        path = wrapper / "inputs/command-execution-aggregate.json"
        path.write_bytes(
            document_bytes(
                {
                    **aggregate_body,
                    "aggregate_sha256": canonical_sha256(aggregate_body),
                }
            )
        )
        return path

    def _binding(self, wrapper: Path, path: Path) -> dict[str, object]:
        payload = path.read_bytes()
        return {
            "path": path.relative_to(wrapper).as_posix(),
            "sha256": hashlib.sha256(payload).hexdigest(),
            "size_bytes": len(payload),
        }

    def _reseal_upstream_copied_file(
        self,
        *,
        wrapper: Path,
        upstream_path: Path,
        gate_id: str,
        source_path: str,
        copied_path: Path,
    ) -> None:
        manifest_path = wrapper / f"inputs/{gate_id.lower()}/artifact-manifest.json"
        manifest = json.loads(manifest_path.read_bytes())
        changed = self._binding(wrapper, copied_path)
        row = next(row for row in manifest["artifacts"] if row["path"] == source_path)
        row["sha256"] = changed["sha256"]
        row["size_bytes"] = changed["size_bytes"]
        manifest_path.write_bytes(document_bytes(manifest))
        upstream = json.loads(upstream_path.read_bytes())
        gate = upstream["gates"][gate_id]
        gate["manifest_file_sha256"] = hashlib.sha256(
            manifest_path.read_bytes()
        ).hexdigest()
        for index, binding in enumerate(gate["copied_files"]):
            if binding["path"] == changed["path"]:
                gate["copied_files"][index] = changed
        gate["copied_files"][0] = self._binding(wrapper, manifest_path)
        if gate_id == "G04":
            gate["closure_attestation"] = build_g04_closure_attestation(
                manifest=manifest,
                manifest_sha256=gate["manifest_file_sha256"],
            )
        upstream_path.write_bytes(document_bytes(upstream))

    def _reseal_receipt_upstream(
        self,
        *,
        wrapper: Path,
        upstream_path: Path,
        receipt: dict[str, object],
    ) -> None:
        receipt["upstream_bindings"] = self._binding(wrapper, upstream_path)
        receipt.pop("receipt_sha256", None)
        receipt["receipt_sha256"] = canonical_sha256(receipt)

    def _reseal_command_execution(
        self,
        *,
        wrapper: Path,
        receipt: dict[str, object],
    ) -> None:
        aggregate_path = wrapper / "inputs/command-execution-aggregate.json"
        aggregate = json.loads(aggregate_path.read_bytes())
        aggregate["command_plan"] = self._binding(
            wrapper,
            wrapper / "inputs/g05-command-plan.json",
        )
        aggregate["run_identity"] = self._binding(
            wrapper,
            wrapper / "run-identity.json",
        )
        for row in aggregate["commands"]:
            identifier = row["id"]
            stdout_path = wrapper / f"outputs/{identifier}.log"
            stderr_path = wrapper / f"outputs/{identifier}.stderr.log"
            result_path = wrapper / f"outputs/{identifier}.result.json"
            result = json.loads(result_path.read_bytes())
            result["stdout"] = self._binding(wrapper, stdout_path)
            result["stderr"] = self._binding(wrapper, stderr_path)
            result["produced_artifacts"] = [
                self._binding(wrapper, wrapper / binding["path"])
                for binding in result["produced_artifacts"]
            ]
            result.pop("receipt_sha256", None)
            result["receipt_sha256"] = canonical_sha256(result)
            result_path.write_bytes(document_bytes(result))
            row["stdout"] = self._binding(wrapper, stdout_path)
            row["stderr"] = self._binding(wrapper, stderr_path)
            row["result"] = self._binding(wrapper, result_path)
        aggregate.pop("aggregate_sha256", None)
        aggregate["aggregate_sha256"] = canonical_sha256(aggregate)
        aggregate_path.write_bytes(document_bytes(aggregate))
        receipt["command_execution"] = self._binding(wrapper, aggregate_path)
        receipt.pop("receipt_sha256", None)
        receipt["receipt_sha256"] = canonical_sha256(receipt)

    def _receipt_case(
        self,
        name: str,
    ) -> tuple[Path, tuple[Path, Path, Path], Path, dict[str, object]]:
        runs = self._runs(name)
        (
            _,
            _,
            wrapper,
            canonical_runs,
            assessment_path,
            register_path,
            upstream_path,
        ) = self._documents_and_wrapper(runs)
        receipt = dict(
            build_g05_receipt(
                repository_root=REPOSITORY_ROOT,
                wrapper_root=wrapper,
                source_commit=self.source_commit,
                run_roots=canonical_runs,
                assessment_path=assessment_path,
                finding_register_path=register_path,
                upstream_bindings_path=upstream_path,
            )
        )
        return wrapper, canonical_runs, upstream_path, receipt

    def _write_upstream_bindings(self, wrapper: Path) -> Path:
        contract_payload = (REPOSITORY_ROOT / G03_CURRENT_CONTRACT).read_bytes()
        contract = json.loads(contract_payload)
        binary_payload = (REPOSITORY_ROOT / G03_CURRENT_BINARY).read_bytes()
        contract_sha256 = hashlib.sha256(contract_payload).hexdigest()
        binary_sha256 = hashlib.sha256(binary_payload).hexdigest()
        source_hashes = {
            relative: hashlib.sha256((REPOSITORY_ROOT / relative).read_bytes()).hexdigest()
            for relative in G03_CURRENT_SOURCE_FILES
        }
        assessment = {
            "schema_version": "1.0.0",
            "gate_id": "G03",
            "status": "pass",
            "defects": [],
            "criteria": [
                {"count": 512, "criterion": G03_ASSESSMENT_CRITERIA[0], "status": "pass"},
                {"count": 256, "criterion": G03_ASSESSMENT_CRITERIA[1], "status": "pass"},
                {"count": 16, "criterion": G03_ASSESSMENT_CRITERIA[2], "status": "pass"},
                {"count": 36864, "criterion": G03_ASSESSMENT_CRITERIA[3], "status": "pass"},
                {"count": 147456, "criterion": G03_ASSESSMENT_CRITERIA[4], "status": "pass"},
                {"criterion": G03_ASSESSMENT_CRITERIA[5], "sha256": binary_sha256, "status": "pass"},
                {"branch": "unchanged_from_p00", "criterion": G03_ASSESSMENT_CRITERIA[6], "status": "pass"},
            ],
        }
        vectors = {
            "schema_version": "1.0.0",
            "format": "ASHCORE1",
            "decoder_radius": 1,
            "byte_order": "little_endian",
            "coordinate_order": "coordinate_1_is_packed_bit_8_coordinate_9_is_packed_bit_0",
            "comparison": "byte_for_byte_and_sha256_equal",
            "contract_mutation_rejection": "generator_row_and_decoder_radius_rejected_by_both_implementations",
            "payload": "ash-core-v1.bin",
            "payload_sha256": binary_sha256,
            "payload_size_bytes": len(binary_payload),
            "shared_contract": "ash-core-v1.contract.json",
            "shared_contract_repository_path": G03_CURRENT_CONTRACT,
            "shared_contract_sha256": contract_sha256,
            "records": dict(G03_VECTOR_COUNTS),
        }
        binary = contract["binary"]
        core = contract["core"]
        header = {
            "magic": "ASHCORE1",
            "schema_version": 1,
            "header_size": binary["header_size"],
            "state_bits": core["state_bits"],
            "payload_bits": core["payload_bits"],
            "message_bits": core["message_bits"],
            "bit_order_code": binary["bit_order_code"],
            "endianness_code": binary["endianness_code"],
            "decoder_radius": binary["decoder_radius"],
            "raw_state_record_size": binary["record_sizes"]["raw_state"],
            "codeword_record_size": binary["record_sizes"]["codeword"],
            "affine_record_size": binary["record_sizes"]["affine"],
            "raw_state_count": 512,
            "codeword_count": 16,
            "valid_anchor_count": 256,
            "exact_affine_count": 4096,
            "one_bit_affine_count": 36864,
            "two_bit_affine_count": 147456,
            "raw_state_offset": binary["section_offsets"]["raw_state"],
            "codeword_offset": binary["section_offsets"]["codeword"],
            "affine_offset": binary["section_offsets"]["affine"],
            "file_size": len(binary_payload),
        }
        detailed = {
            "schema_version": "1.0.0",
            "gate_id": "G03",
            "phase_id": "P03",
            "document_status": "final",
            "overall_technical_assessment": "pass",
            "binary_contract": {
                "magic_ascii": "ASHCORE1",
                "schema_version": 1,
                "endianness": "little",
                "implicit_padding": False,
                "file_size_bytes": len(binary_payload),
                "sha256": binary_sha256,
                "header_fields": [
                    {"name": name, "value": value}
                    for name, value in header.items()
                ],
            },
            "shared_contract": {
                "path": G03_CURRENT_CONTRACT,
                "retained_evidence_path": "conformance/ash-core-v1.contract.json",
                "sha256": contract_sha256,
            },
            "byte_hash_agreement": {
                "reference_check_result": "pass",
                "production_xctest_result": "passed",
                "reference_check_bytes": len(binary_payload),
                "reference_check_sha256": binary_sha256,
            },
            "exhaustive_counts": [
                {"domain": "raw_states", "count": 512, "result": "checked"},
                {"domain": "valid_anchors", "count": 256, "result": "checked"},
                {"domain": "codewords", "count": 16, "result": "checked"},
                {"domain": "exact_affine", "count": 4096, "result": "exact"},
                {"domain": "one_bit_affine", "count": 36864, "result": "corrected"},
                {"domain": "two_bit_affine", "count": 147456, "result": "rejected"},
            ],
            "gate_criteria": [
                {
                    "criterion": criterion,
                    "result": "pass",
                    **({"count": 36864} if index == 3 else {}),
                    **({"count": 147456} if index == 4 else {}),
                    **({"branch": "unchanged"} if index == 6 else {}),
                }
                for index, criterion in enumerate(G03_ASSESSMENT_CRITERIA)
            ],
            "source_file_hashes": [
                {"path": path, "sha256": digest}
                for path, digest in {
                    **source_hashes,
                    G03_CURRENT_CONTRACT: contract_sha256,
                    G03_CURRENT_BINARY: binary_sha256,
                }.items()
            ],
            "canonical_core": {
                "decoder_radius": 1,
                "coordinate_1_packed_bit": 8,
                "coordinate_9_packed_bit": 0,
                "baseline_preservation": [
                    {
                        "path": path,
                        "current_sha256": digest,
                        "p00_sha256": digest,
                        "unchanged": True,
                    }
                    for path, digest in source_hashes.items()
                    if path in G03_CURRENT_SOURCE_FILES[:2]
                ],
            },
        }
        gates: dict[str, object] = {}
        g03_root = wrapper / "inputs/g03"
        g03_root.mkdir(parents=True)
        g03_sources = (
            "conformance/g03-gate-assessment.json",
            "conformance/canonical-vectors.json",
            "conformance/p03-g03-canonical-core-evidence.json",
            "conformance/ash-core-v1.contract.json",
        )
        g03_destinations = tuple(g03_root / Path(path).name for path in g03_sources)
        for path, document in zip(g03_destinations[:3], (assessment, vectors, detailed)):
            path.write_bytes(document_bytes(document))
        g03_destinations[3].write_bytes(contract_payload)
        g03_artifacts = []
        for source_path, destination in zip(g03_sources, g03_destinations):
            row = self._binding(wrapper, destination)
            g03_artifacts.append(
                {"path": source_path, "sha256": row["sha256"], "size_bytes": row["size_bytes"]}
            )
        g03_manifest_path = g03_root / "artifact-manifest.json"
        g03_manifest_path.write_bytes(
            document_bytes(
                {
                    "schema_version": "1.0.0",
                    "project_commit": self.source_commit,
                    "working_tree_clean": False,
                    "artifacts": g03_artifacts,
                }
            )
        )
        gates["G03"] = {
            "status": "pass",
            "source_commit": self.source_commit,
            "manifest_file_sha256": hashlib.sha256(g03_manifest_path.read_bytes()).hexdigest(),
            "copied_files": [
                self._binding(wrapper, path)
                for path in (g03_manifest_path, *g03_destinations)
            ],
        }

        g04_assessment = {
            "schema_version": "1.0.0",
            "gate": "G04",
            "status": "pass",
            "project_commit": self.source_commit,
            "holdout_accessed": False,
            "algorithm_quality_claimed": False,
            "criteria": [
                {"criterion": criterion, "pass": True}
                for criterion in G04_ASSESSMENT_CRITERIA
            ],
            "evidence": [
                "test-results.json",
                "analysis/production-run-verification.json",
                "analysis/data-access-attestation.json",
                "inputs/lock-hashes.json",
                "production-run/production-prechange/artifact-manifest.json",
            ],
        }
        g04_tests = {
            "schema_version": "1.0.0",
            "status": "pass",
            "xcode_full": {
                "status": "passed",
                "total": 2,
                "passed": 2,
                "failed": 0,
                "skipped": 0,
                "summary": "xcode/full-tests-summary.json",
                "coverage": "xcode/full-coverage.json",
                "result_bundle": "xcode/full-tests.xcresult",
            },
            "release_build": {
                "status": "succeeded",
                "warnings": 0,
                "errors": 0,
                "analyzer_warnings": 0,
                "summary": "xcode/release-build-summary.json",
                "result_bundle": "xcode/release-build.xcresult",
            },
            "python": {
                "status": "pass",
                "test_count": 3,
                "failures": 0,
                "skips": 0,
                "log": "tests/python-unittest.log",
            },
            "production_dry_run": {
                "status": "pass",
                "holdout_accessed": False,
                "case_count": 2,
                "writer_run_count": 2,
                "injected_failure_preserved": True,
                "resume_recomputed": True,
                "verification": "analysis/production-run-verification.json",
            },
            "metric_oracle": {"status": "pass", "log": "tests/metric-oracle.log"},
            "actual_codec_cli": {
                "status": "pass",
                "log": "tests/actual-codec-cli.log",
                "evidence_sha256": "a" * 64,
            },
            "static_validation": {"status": "pass", "log": "tests/python-compile.log"},
            "instruction_package": {
                "status": "pass",
                "log": "tests/instruction-package-validation.log",
            },
            "attribution_scan": {"status": "pass", "findings": 0, "path": "attribution-scan.json"},
            "swiftlint": {"status": "pass", "violations": 0, "log": "tests/swiftlint.log"},
        }
        g04_root = wrapper / "inputs/g04"
        g04_root.mkdir()
        g04_assessment_path = g04_root / "g04-gate-assessment.json"
        g04_tests_path = g04_root / "test-results.json"
        g04_assessment_path.write_bytes(document_bytes(g04_assessment))
        g04_tests_path.write_bytes(document_bytes(g04_tests))

        def g04_artifact(
            path: str,
            sha256: str,
            size_bytes: int,
        ) -> dict[str, object]:
            return {
                "path": path,
                "sha256": sha256,
                "size_bytes": size_bytes,
                "producer": "G04 fixture",
                "gate_ids": ["G04"],
                "command": "fixture",
                "platform": "macOS",
                "machine": "arm64",
            }

        g04_artifacts = []
        for source_path, destination in (
            ("analysis/g04-gate-assessment.json", g04_assessment_path),
            ("test-results.json", g04_tests_path),
        ):
            row = self._binding(wrapper, destination)
            g04_artifacts.append(
                g04_artifact(
                    source_path,
                    str(row["sha256"]),
                    int(row["size_bytes"]),
                )
            )
        referenced_files = {
            *g04_assessment["evidence"],
            "xcode/full-tests-summary.json",
            "xcode/full-coverage.json",
            "xcode/release-build-summary.json",
            "tests/python-unittest.log",
            "analysis/production-run-verification.json",
            "tests/metric-oracle.log",
            "tests/actual-codec-cli.log",
            "tests/python-compile.log",
            "tests/instruction-package-validation.log",
            "attribution-scan.json",
            "tests/swiftlint.log",
        }
        present = {row["path"] for row in g04_artifacts}
        g04_artifacts.extend(
            g04_artifact(path, "f" * 64, 1)
            for path in sorted(referenced_files - present)
        )
        g04_artifacts.append(
            g04_artifact("publication-transaction.json", "e" * 64, 1)
        )
        g04_artifacts.sort(key=lambda row: str(row["path"]))
        g04_manifest_path = g04_root / "artifact-manifest.json"
        g04_manifest = {
            "schema_version": "2.0.0",
            "created_utc": "2026-07-15T12:00:00Z",
            "project_commit": self.source_commit,
            "working_tree_clean": True,
            "directories": [
                "analysis",
                "inputs",
                "production-run",
                "production-run/production-prechange",
                "tests",
                "xcode",
                "xcode/full-tests.xcresult",
                "xcode/release-build.xcresult",
            ],
            "artifacts": g04_artifacts,
        }
        g04_manifest_path.write_bytes(document_bytes(g04_manifest))
        gates["G04"] = {
            "status": "pass",
            "source_commit": self.source_commit,
            "manifest_file_sha256": hashlib.sha256(g04_manifest_path.read_bytes()).hexdigest(),
            "copied_files": [
                self._binding(wrapper, path)
                for path in (g04_manifest_path, g04_assessment_path, g04_tests_path)
            ],
            "closure_attestation": build_g04_closure_attestation(
                manifest=g04_manifest,
                manifest_sha256=hashlib.sha256(
                    g04_manifest_path.read_bytes()
                ).hexdigest(),
            ),
        }

        repository_sealed = (
            REPOSITORY_ROOT
            / "validation/quality/locks/holdout-access-ledger.sealed-copy.json"
        ).read_bytes()
        repository_attestation = (
            REPOSITORY_ROOT
            / "validation/quality/locks/holdout-seal-attestation.no-pixel.json"
        ).read_bytes()
        attestation_document = json.loads(repository_attestation)
        corpus_sha256 = attestation_document["production_corpus_lock"][
            "manifest_sha256"
        ]
        event = {
            "sequence": 0,
            "event": "sealed",
            "occurred_utc": "2026-07-15T12:00:00Z",
            "previous_entry_sha256": "0" * 64,
            "details": {"corpus_manifest_sha256": corpus_sha256},
        }
        event["entry_sha256"] = canonical_sha256(event)
        ledger = {
            "schema_version": "1.0.0",
            "corpus_manifest_sha256": corpus_sha256,
            "state": "sealed",
            "open_intent_utc": None,
            "opened_utc": None,
            "completed_utc": None,
            "events": [event],
        }
        live_paths = tuple(wrapper / relative for relative in LIVE_PREOPEN_RELATIVE_PATHS)
        for path in live_paths:
            path.parent.mkdir(parents=True, exist_ok=True)
        live_paths[0].write_bytes(document_bytes(ledger))
        live_paths[2].write_bytes(repository_sealed)
        live_paths[3].write_bytes(repository_attestation)
        receipt = {
            "schema_version": "1.0.0",
            "artifact_kind": "live_holdout_preopen_receipt",
            "version_id": "p06-spatial-v2",
            "created_utc": "2026-07-15T12:00:00Z",
            "state": "sealed",
            "access_count": 0,
            "open_intent_anchor_present": False,
            "pixel_content_included": False,
            "corpus_manifest_sha256": corpus_sha256,
            "live_ledger_sha256": hashlib.sha256(live_paths[0].read_bytes()).hexdigest(),
            "live_ledger_root_identity_sha256": "b" * 64,
            "live_anchor_root_identity_sha256": "c" * 64,
            "repository_sealed_copy_sha256": hashlib.sha256(repository_sealed).hexdigest(),
            "repository_attestation_sha256": hashlib.sha256(repository_attestation).hexdigest(),
            "persistence": "macos-user-immutable-v1",
            "threat_boundary": (
                "cooperating-processes-v1; deliberate owner-or-administrator flag clearing, "
                "direct media access, code bypass, and filesystem rollback are outside scope"
            ),
            "hash_scope": "canonical document excluding receipt_sha256",
        }
        receipt["receipt_sha256"] = canonical_sha256(receipt)
        live_paths[1].write_bytes(document_bytes(receipt))
        live_bindings = [self._binding(wrapper, path) for path in live_paths]
        live = {
            "status": "pass",
            "version_id": "p06-spatial-v2",
            "metadata_only": True,
            "pixel_content_included": False,
            "open_intent_anchor_present": False,
            "bindings": live_bindings,
        }
        upstream_path = wrapper / "inputs/upstream-bindings.json"
        upstream_path.write_bytes(
            document_bytes(
                {
                    "schema_version": "1.0.0",
                    "gates": gates,
                    "live_preopen_metadata": live,
                }
            )
        )
        return upstream_path

    def test_current_source_closure_builds_deterministic_bound_documents(self) -> None:
        runs = self._runs("passing")
        closure = validate_g05_evidence(REPOSITORY_ROOT, runs)
        self.assertEqual(len(closure["document_bindings"]), 8)
        first = build_g05_documents(
            repository_root=REPOSITORY_ROOT,
            run_roots=runs,
            source_commit=self.source_commit,
        )
        second = build_g05_documents(
            repository_root=REPOSITORY_ROOT,
            run_roots=runs,
            source_commit=self.source_commit,
        )
        self.assertEqual(first, second)
        (
            assessment,
            register,
            wrapper,
            canonical_runs,
            assessment_path,
            register_path,
            upstream_path,
        ) = self._documents_and_wrapper(runs)
        self.assertEqual(assessment["status"], "pass")
        self.assertEqual(len(assessment["mandatory_criteria"]), 8)
        self.assertEqual(assessment["finding_register_sha256"], register["register_sha256"])
        self.assertEqual(register["open_counts"], {"severity_1": 0, "severity_2": 0})
        self.assertEqual(document_bytes(assessment), document_bytes(assessment).strip() + b"\n")
        receipt = build_g05_receipt(
            repository_root=REPOSITORY_ROOT,
            wrapper_root=wrapper,
            source_commit=self.source_commit,
            run_roots=canonical_runs,
            assessment_path=assessment_path,
            finding_register_path=register_path,
            upstream_bindings_path=upstream_path,
        )
        self.assertFalse(receipt["holdout_accessed"])
        self.assertEqual(
            [row["path"] for row in receipt["evidence_runs"]],
            list(CANONICAL_RUN_RELATIVE_PATHS),
        )
        self.assertEqual(receipt["upstream_bindings"]["path"], "inputs/upstream-bindings.json")
        self.assertEqual(receipt["assessment"]["path"], "analysis/g05-gate-assessment.json")
        self.assertNotIn("status", receipt["assessment"])
        reopened = validate_g05_receipt(
            repository_root=REPOSITORY_ROOT,
            wrapper_root=wrapper,
            receipt=receipt,
        )
        self.assertEqual(reopened.assessment, assessment)
        self.assertEqual(reopened.finding_register, register)
        self.assertEqual(len(reopened.reopened_relative_paths), 73)

    def test_receipt_rejects_omitted_zero_byte_execution_stream(self) -> None:
        wrapper, _, _, receipt = self._receipt_case("zero-stream-binding")
        stream = wrapper / "outputs/diff-check.stderr.log"
        self.assertEqual(stream.read_bytes(), b"")
        stream.unlink()
        with self.assertRaisesRegex(G05GateError, "cannot be inspected"):
            validate_g05_receipt(
                repository_root=REPOSITORY_ROOT,
                wrapper_root=wrapper,
                receipt=receipt,
            )

    def test_receipt_rejects_rehashed_command_plan_forgery(self) -> None:
        wrapper, _, _, receipt = self._receipt_case("command-plan-forgery")
        path = wrapper / "inputs/g05-command-plan.json"
        plan = json.loads(path.read_bytes())
        plan["commands"][0]["argv"][1] = "validation/spatial_v2/forged_runner.py"
        path.write_bytes(document_bytes(plan))
        self._reseal_command_execution(wrapper=wrapper, receipt=receipt)
        with self.assertRaisesRegex(G05GateError, "canonical contract"):
            validate_g05_receipt(
                repository_root=REPOSITORY_ROOT,
                wrapper_root=wrapper,
                receipt=receipt,
            )

    def test_receipt_rejects_rehashed_result_and_stream_forgeries(self) -> None:
        cases = (
            (
                "product-omission",
                "produced-artifact closure differs",
                lambda wrapper: self._mutate_result(
                    wrapper,
                    "instruction-package",
                    lambda result: result["produced_artifacts"].pop(),
                ),
            ),
            (
                "stdout-forgery",
                "stdout P05 hash closure differs",
                lambda wrapper: (wrapper / "outputs/run-a.log").write_bytes(b"forged\n"),
            ),
            (
                "timestamp-forgery",
                "outside the run-identity interval",
                lambda wrapper: self._mutate_result(
                    wrapper,
                    "run-a",
                    lambda result: result.__setitem__(
                        "started_utc",
                        "2026-07-15T12:00:21Z",
                    ),
                ),
            ),
            (
                "command-order-forgery",
                "outside the run-identity interval",
                lambda wrapper: self._mutate_result(
                    wrapper,
                    "run-b",
                    lambda result: result.__setitem__(
                        "started_utc",
                        "2026-07-15T12:00:00Z",
                    ),
                ),
            ),
        )
        for name, message, mutate in cases:
            with self.subTest(name=name):
                wrapper, _, _, receipt = self._receipt_case(name)
                mutate(wrapper)
                self._reseal_command_execution(wrapper=wrapper, receipt=receipt)
                with self.assertRaisesRegex(G05GateError, message):
                    validate_g05_receipt(
                        repository_root=REPOSITORY_ROOT,
                        wrapper_root=wrapper,
                        receipt=receipt,
                    )

    @staticmethod
    def _mutate_result(
        wrapper: Path,
        identifier: str,
        mutate: object,
    ) -> None:
        path = wrapper / f"outputs/{identifier}.result.json"
        result = json.loads(path.read_bytes())
        mutate(result)
        result.pop("receipt_sha256", None)
        result["receipt_sha256"] = canonical_sha256(result)
        path.write_bytes(document_bytes(result))

    def test_receipt_rejects_arbitrary_instruction_package_identity_hash(self) -> None:
        wrapper, _, _, receipt = self._receipt_case("package-identity-forgery")
        path = wrapper / "run-identity.json"
        identity = json.loads(path.read_bytes())
        identity["instruction_package"]["package_manifest_sha256"] = "f" * 64
        identity.pop("identity_sha256")
        identity["identity_sha256"] = canonical_sha256(identity)
        path.write_bytes(document_bytes(identity))
        self._reseal_command_execution(wrapper=wrapper, receipt=receipt)
        with self.assertRaisesRegex(G05GateError, "products do not bind the run identity"):
            validate_g05_receipt(
                repository_root=REPOSITORY_ROOT,
                wrapper_root=wrapper,
                receipt=receipt,
            )

    def test_receipt_rejects_relocated_semantic_documents(self) -> None:
        cases = (
            ("assessment", "analysis/g05-gate-assessment.json"),
            ("finding_register", "analysis/g05-scoped-finding-register.json"),
            ("upstream_bindings", "inputs/upstream-bindings.json"),
        )
        for field, original in cases:
            with self.subTest(field=field):
                wrapper, _, _, receipt = self._receipt_case(f"relocated-{field}")
                source = wrapper / original
                relocated = wrapper / "relocated" / source.name
                relocated.parent.mkdir()
                source.rename(relocated)
                receipt[field] = self._binding(wrapper, relocated)
                receipt.pop("receipt_sha256")
                receipt["receipt_sha256"] = canonical_sha256(receipt)
                with self.assertRaisesRegex(G05GateError, "schema validation failed"):
                    validate_g05_receipt(
                        repository_root=REPOSITORY_ROOT,
                        wrapper_root=wrapper,
                        receipt=receipt,
                    )

    def test_direct_route_criterion_rejects_duplicate_missing_pair(self) -> None:
        documents = {
            filename: json.loads((self.seed / filename).read_bytes())
            for filename in (
                "cpu-reference-results.json",
                "cpu-reference-vectors.json",
                "coordinate-comparison.json",
            )
        }
        records = documents["coordinate-comparison.json"]["data"][
            "route_policy_records"
        ]
        records[1] = copy.deepcopy(records[0])
        with self.assertRaisesRegex(G05GateError, "route-policy pair closure differs"):
            g05_gate._criterion_direct_routes(documents)

    def test_exact_three_run_eight_file_byte_closure_is_enforced(self) -> None:
        runs = self._runs("closure")
        with self.assertRaisesRegex(G05GateError, "exactly three"):
            validate_g05_evidence(REPOSITORY_ROOT, runs[:2])
        (runs[0] / EVIDENCE_FILENAMES[0]).unlink()
        with self.assertRaisesRegex(G05GateError, "eight-file closure"):
            validate_g05_evidence(REPOSITORY_ROOT, runs)

        runs = self._runs("extra")
        (runs[0] / "extra.json").write_text("{}\n", encoding="utf-8")
        with self.assertRaisesRegex(G05GateError, "eight-file closure"):
            validate_g05_evidence(REPOSITORY_ROOT, runs)

        runs = self._runs("bytes")
        path = runs[1] / EVIDENCE_FILENAMES[0]
        path.write_bytes(path.read_bytes() + b"\n")
        with self.assertRaisesRegex(G05GateError, "bytes differ"):
            validate_g05_evidence(REPOSITORY_ROOT, runs)

    def test_symlink_hardlink_and_symlinked_parent_are_rejected(self) -> None:
        runs = self._runs("links")
        path = runs[0] / EVIDENCE_FILENAMES[0]
        path.unlink()
        path.symlink_to(self.seed / EVIDENCE_FILENAMES[0])
        with self.assertRaisesRegex(G05GateError, "symbolic link"):
            validate_g05_evidence(REPOSITORY_ROOT, runs)

        runs = self._runs("hardlink")
        target = runs[0].parent / "hard-target.json"
        shutil.copy2(self.seed / EVIDENCE_FILENAMES[0], target)
        path = runs[0] / EVIDENCE_FILENAMES[0]
        path.unlink()
        os.link(target, path)
        with self.assertRaisesRegex(G05GateError, "exactly one link"):
            validate_g05_evidence(REPOSITORY_ROOT, runs)

        runs = self._runs("parent-link")
        alias = runs[0].parent.parent / "linked-parent"
        alias.symlink_to(runs[0].parent, target_is_directory=True)
        linked_root = alias / runs[0].name
        with self.assertRaisesRegex(G05GateError, "traverses a symbolic link"):
            validate_g05_evidence(REPOSITORY_ROOT, (linked_root, runs[1], runs[2]))

    def test_draft_2020_12_schema_validation_is_mandatory(self) -> None:
        runs = self._runs("schema")
        self._write_same_document(
            runs,
            "development-mapping.json",
            lambda document: document.__setitem__("status", "fail"),
        )
        with self.assertRaisesRegex(G05GateError, "schema validation failed"):
            validate_g05_evidence(REPOSITORY_ROOT, runs)

    def test_current_repository_provenance_and_composite_are_enforced(self) -> None:
        runs = self._runs("provenance-sha")
        self._write_all_provenance(
            runs,
            lambda provenance: provenance["production_sources"][0].__setitem__("sha256", "0" * 64),
        )
        with self.assertRaisesRegex(G05GateError, "provenance SHA-256 differs"):
            validate_g05_evidence(REPOSITORY_ROOT, runs)

        runs = self._runs("provenance-composite")
        self._write_all_provenance(
            runs,
            lambda provenance: provenance.__setitem__("harness_manifest_sha256", "0" * 64),
        )
        with self.assertRaisesRegex(G05GateError, "harness_manifest_sha256 differs"):
            validate_g05_evidence(REPOSITORY_ROOT, runs)

    def test_all_eight_gate_criteria_are_independently_enforced(self) -> None:
        mutations = (
            (
                "state-fixtures.json",
                lambda document: document["data"]["controlled_fixtures"][0].__setitem__("target_coordinate", 2),
                "target coordinates",
            ),
            (
                "state-fixtures.json",
                lambda document: document["data"]["orientation_fixtures"][0].__setitem__("edge_tangent_radians", 0.1),
                "normal/tangent relation",
            ),
            (
                "cpu-reference-vectors.json",
                lambda document: document["data"]["vectors"][0].__setitem__("route", "direct_3_over_2"),
                "coverage differs",
            ),
            (
                "operator-distinctness.json",
                lambda document: document["data"]["descriptors"][1].update(
                    {key: document["data"]["descriptors"][0][key] for key in ("base_kernel", "support", "detail", "limiter")}
                ),
                "semantics are not distinct",
            ),
            (
                "cpu-reference-results.json",
                lambda document: next(
                    row for row in document["data"]["tests"] if row["id"] == "nearest_not_reconstruction_substrate"
                ).__setitem__("observed", True),
                "nearest or runtime tree",
            ),
            (
                "state-causality-results.json",
                lambda document: [row.__setitem__("primary_descriptor", 0) for row in document["data"]["state_dispatch_records"]],
                "dispatch is constant",
            ),
            (
                "state-causality-results.json",
                lambda document: [row.__setitem__("primary_descriptor", 0) for row in document["data"]["first_frame_records"]],
                "first-frame top operator",
            ),
            (
                "state-causality-results.json",
                lambda document: document["data"]["state_disabled_control"].__setitem__(
                    "enabled_output_sha256",
                    document["data"]["state_disabled_control"]["disabled_output_sha256"],
                ),
                "controlled delta",
            ),
        )
        for index, (filename, mutate, message) in enumerate(mutations):
            with self.subTest(criterion=index + 1):
                runs = self._runs(f"criterion-{index}")
                self._write_same_document(runs, filename, mutate)
                with self.assertRaisesRegex(G05GateError, message):
                    validate_g05_evidence(REPOSITORY_ROOT, runs)

    def test_structural_criterion_and_development_only_boundaries_are_enforced(self) -> None:
        runs = self._runs("criterion-closure")
        self._write_same_document(
            runs,
            "state-fixtures.json",
            lambda document: document["criteria"][0].__setitem__("id", "substitute"),
        )
        with self.assertRaisesRegex(G05GateError, "criterion closure"):
            validate_g05_evidence(REPOSITORY_ROOT, runs)

        runs = self._runs("release-selection")
        self._write_same_document(
            runs,
            "coordinate-comparison.json",
            lambda document: document["data"].__setitem__("release_policy_selected", True),
        )
        with self.assertRaisesRegex(G05GateError, "development-only evidence"):
            validate_g05_evidence(REPOSITORY_ROOT, runs)

        runs = self._runs("holdout-path")
        holdout = runs[0].parent / "holdout-run"
        runs[0].rename(holdout)
        with self.assertRaisesRegex(G05GateError, "holdout boundary"):
            validate_g05_evidence(REPOSITORY_ROOT, (holdout, runs[1], runs[2]))

    def test_finding_register_is_derived_zero_only_and_self_hashed(self) -> None:
        register = build_g05_finding_register(
            repository_root=REPOSITORY_ROOT,
            source_commit=self.source_commit,
        )
        payload = dict(register)
        digest = payload.pop("register_sha256")
        self.assertEqual(digest, canonical_sha256(payload))
        with self.assertRaisesRegex(G05GateError, "actual finding"):
            build_g05_finding_register(
                repository_root=REPOSITORY_ROOT,
                source_commit=self.source_commit,
                findings=({"severity": 3},),
            )

    def test_receipt_reopens_bindings_and_survives_wrapper_finalization(self) -> None:
        runs = self._runs("receipt")
        (
            assessment,
            register,
            partial,
            canonical_runs,
            assessment_path,
            register_path,
            upstream_path,
        ) = self._documents_and_wrapper(runs)
        receipt = build_g05_receipt(
            repository_root=REPOSITORY_ROOT,
            wrapper_root=partial,
            source_commit=self.source_commit,
            run_roots=canonical_runs,
            assessment_path=assessment_path,
            finding_register_path=register_path,
            upstream_bindings_path=upstream_path,
        )
        self.assertTrue(partial.name.startswith(".") and partial.name.endswith(".partial"))
        final = partial.with_name(partial.name[1 : -len(".partial")])
        partial.rename(final)
        reopened = validate_g05_receipt(
            repository_root=REPOSITORY_ROOT,
            wrapper_root=final,
            receipt=receipt,
        )
        self.assertEqual(reopened.assessment, assessment)
        self.assertEqual(reopened.finding_register, register)
        final_metadata = os.lstat(final)
        with g05_gate.pinned_wrapper_root(
            final,
            (final_metadata.st_dev, final_metadata.st_ino),
        ) as pinned:
            pinned_reopen = validate_g05_receipt(
                repository_root=REPOSITORY_ROOT,
                wrapper_root=pinned,
                receipt=receipt,
            )
        self.assertEqual(pinned_reopen, reopened)

        bound_assessment = final / receipt["assessment"]["path"]
        bound_assessment.write_bytes(bound_assessment.read_bytes() + b"\n")
        with self.assertRaisesRegex(G05GateError, "binding SHA-256 differs"):
            validate_g05_receipt(
                repository_root=REPOSITORY_ROOT,
                wrapper_root=final,
                receipt=receipt,
            )

    def test_receipt_cross_checks_register_self_hash_binding(self) -> None:
        runs = self._runs("register-binding")
        (
            assessment,
            register,
            wrapper,
            canonical_runs,
            assessment_path,
            register_path,
            upstream_path,
        ) = self._documents_and_wrapper(runs)
        assessment["finding_register_sha256"] = "0" * 64
        assessment_without_hash = dict(assessment)
        assessment_without_hash.pop("assessment_sha256")
        assessment["assessment_sha256"] = canonical_sha256(assessment_without_hash)
        assessment_path.write_bytes(document_bytes(assessment))
        with self.assertRaisesRegex(G05GateError, "self-hash binding differs"):
            build_g05_receipt(
                repository_root=REPOSITORY_ROOT,
                wrapper_root=wrapper,
                source_commit=self.source_commit,
                run_roots=canonical_runs,
                assessment_path=assessment_path,
                finding_register_path=register_path,
                upstream_bindings_path=upstream_path,
            )

    def test_receipt_reopens_every_run_file_and_cross_checks_assessment_counts(self) -> None:
        runs = self._runs("receipt-evidence-mutation")
        (
            _,
            _,
            wrapper,
            canonical_runs,
            assessment_path,
            register_path,
            upstream_path,
        ) = self._documents_and_wrapper(runs)
        receipt = dict(
            build_g05_receipt(
                repository_root=REPOSITORY_ROOT,
                wrapper_root=wrapper,
                source_commit=self.source_commit,
                run_roots=canonical_runs,
                assessment_path=assessment_path,
                finding_register_path=register_path,
                upstream_bindings_path=upstream_path,
            )
        )
        (canonical_runs[2] / EVIDENCE_FILENAMES[-1]).unlink()
        with self.assertRaisesRegex(G05GateError, "exact eight-file closure"):
            validate_g05_receipt(
                repository_root=REPOSITORY_ROOT,
                wrapper_root=wrapper,
                receipt=receipt,
            )

        runs = self._runs("receipt-assessment-mutation")
        (
            _,
            _,
            wrapper,
            canonical_runs,
            assessment_path,
            register_path,
            upstream_path,
        ) = self._documents_and_wrapper(runs)
        receipt = dict(
            build_g05_receipt(
                repository_root=REPOSITORY_ROOT,
                wrapper_root=wrapper,
                source_commit=self.source_commit,
                run_roots=canonical_runs,
                assessment_path=assessment_path,
                finding_register_path=register_path,
                upstream_bindings_path=upstream_path,
            )
        )
        assessment = json.loads(assessment_path.read_bytes())
        assessment["mandatory_criteria"][0]["verified_assertion_count"] += 1
        assessment.pop("assessment_sha256")
        assessment["assessment_sha256"] = canonical_sha256(assessment)
        assessment_path.write_bytes(document_bytes(assessment))
        receipt["assessment"] = self._binding(wrapper, assessment_path)
        receipt.pop("receipt_sha256")
        receipt["receipt_sha256"] = canonical_sha256(receipt)
        with self.assertRaisesRegex(G05GateError, "criterion closure differs"):
            validate_g05_receipt(
                repository_root=REPOSITORY_ROOT,
                wrapper_root=wrapper,
                receipt=receipt,
            )

    def test_receipt_derives_upstream_gate_semantics_from_bound_evidence(self) -> None:
        runs = self._runs("receipt-upstream-mutation")
        (
            _,
            _,
            wrapper,
            canonical_runs,
            assessment_path,
            register_path,
            upstream_path,
        ) = self._documents_and_wrapper(runs)
        receipt = dict(
            build_g05_receipt(
                repository_root=REPOSITORY_ROOT,
                wrapper_root=wrapper,
                source_commit=self.source_commit,
                run_roots=canonical_runs,
                assessment_path=assessment_path,
                finding_register_path=register_path,
                upstream_bindings_path=upstream_path,
            )
        )
        g04_assessment_path = wrapper / "inputs/g04/g04-gate-assessment.json"
        g04_assessment = json.loads(g04_assessment_path.read_bytes())
        g04_assessment["status"] = "fail"
        g04_assessment_path.write_bytes(document_bytes(g04_assessment))

        g04_manifest_path = wrapper / "inputs/g04/artifact-manifest.json"
        g04_manifest = json.loads(g04_manifest_path.read_bytes())
        changed_binding = self._binding(wrapper, g04_assessment_path)
        assessment_row = next(
            row
            for row in g04_manifest["artifacts"]
            if row["path"] == "analysis/g04-gate-assessment.json"
        )
        assessment_row["sha256"] = changed_binding["sha256"]
        assessment_row["size_bytes"] = changed_binding["size_bytes"]
        g04_manifest_path.write_bytes(document_bytes(g04_manifest))

        upstream = json.loads(upstream_path.read_bytes())
        upstream["gates"]["G04"]["copied_files"][0] = self._binding(
            wrapper,
            g04_manifest_path,
        )
        upstream["gates"]["G04"]["copied_files"][1] = changed_binding
        upstream["gates"]["G04"]["manifest_file_sha256"] = hashlib.sha256(
            g04_manifest_path.read_bytes()
        ).hexdigest()
        upstream["gates"]["G04"]["closure_attestation"] = (
            build_g04_closure_attestation(
                manifest=g04_manifest,
                manifest_sha256=upstream["gates"]["G04"][
                    "manifest_file_sha256"
                ],
            )
        )
        upstream_path.write_bytes(document_bytes(upstream))
        receipt["upstream_bindings"] = self._binding(wrapper, upstream_path)
        receipt.pop("receipt_sha256")
        receipt["receipt_sha256"] = canonical_sha256(receipt)

        with self.assertRaisesRegex(G05GateError, "G04 assessment"):
            validate_g05_receipt(
                repository_root=REPOSITORY_ROOT,
                wrapper_root=wrapper,
                receipt=receipt,
            )

    def test_live_preopen_metadata_is_mandatory_and_semantically_closed(self) -> None:
        wrapper, _, upstream_path, receipt = self._receipt_case("live-omission")
        upstream = json.loads(upstream_path.read_bytes())
        upstream.pop("live_preopen_metadata")
        upstream_path.write_bytes(document_bytes(upstream))
        self._reseal_receipt_upstream(
            wrapper=wrapper,
            upstream_path=upstream_path,
            receipt=receipt,
        )
        with self.assertRaisesRegex(G05GateError, "upstream binding fields differ"):
            validate_g05_receipt(
                repository_root=REPOSITORY_ROOT,
                wrapper_root=wrapper,
                receipt=receipt,
            )

        wrapper, _, upstream_path, receipt = self._receipt_case("live-flag")
        upstream = json.loads(upstream_path.read_bytes())
        upstream["live_preopen_metadata"]["metadata_only"] = False
        upstream_path.write_bytes(document_bytes(upstream))
        self._reseal_receipt_upstream(
            wrapper=wrapper,
            upstream_path=upstream_path,
            receipt=receipt,
        )
        with self.assertRaisesRegex(G05GateError, "unopened semantics differ"):
            validate_g05_receipt(
                repository_root=REPOSITORY_ROOT,
                wrapper_root=wrapper,
                receipt=receipt,
            )

    def test_live_preopen_rejects_self_consistently_rehashed_content(self) -> None:
        wrapper, _, upstream_path, receipt = self._receipt_case("live-rehash")
        ledger_path = wrapper / LIVE_PREOPEN_RELATIVE_PATHS[0]
        preopen_path = wrapper / LIVE_PREOPEN_RELATIVE_PATHS[1]
        ledger = json.loads(ledger_path.read_bytes())
        ledger["corpus_manifest_sha256"] = "0" * 64
        ledger["events"][0]["details"] = {"corpus_manifest_sha256": "0" * 64}
        event = dict(ledger["events"][0])
        event.pop("entry_sha256")
        ledger["events"][0]["entry_sha256"] = canonical_sha256(event)
        ledger_path.write_bytes(document_bytes(ledger))
        preopen = json.loads(preopen_path.read_bytes())
        preopen["corpus_manifest_sha256"] = "0" * 64
        preopen["live_ledger_sha256"] = hashlib.sha256(
            ledger_path.read_bytes()
        ).hexdigest()
        preopen.pop("receipt_sha256")
        preopen["receipt_sha256"] = canonical_sha256(preopen)
        preopen_path.write_bytes(document_bytes(preopen))
        upstream = json.loads(upstream_path.read_bytes())
        upstream["live_preopen_metadata"]["bindings"][0] = self._binding(
            wrapper,
            ledger_path,
        )
        upstream["live_preopen_metadata"]["bindings"][1] = self._binding(
            wrapper,
            preopen_path,
        )
        upstream_path.write_bytes(document_bytes(upstream))
        self._reseal_receipt_upstream(
            wrapper=wrapper,
            upstream_path=upstream_path,
            receipt=receipt,
        )
        with self.assertRaisesRegex(G05GateError, "attestation cross-bindings differ"):
            validate_g05_receipt(
                repository_root=REPOSITORY_ROOT,
                wrapper_root=wrapper,
                receipt=receipt,
            )

    def test_g03_rejects_self_consistently_rehashed_semantic_mutations(self) -> None:
        mutations = (
            (
                "contract",
                "conformance/ash-core-v1.contract.json",
                "ash-core-v1.contract.json",
                lambda document: document["core"].__setitem__("state_bits", 8),
                "copied contract differs",
            ),
            (
                "vectors",
                "conformance/canonical-vectors.json",
                "canonical-vectors.json",
                lambda document: document["records"].__setitem__("exact_affine", 4095),
                "canonical vectors",
            ),
            (
                "criterion",
                "conformance/g03-gate-assessment.json",
                "g03-gate-assessment.json",
                lambda document: document["criteria"][0].__setitem__("count", 511),
                "seven canonical criteria",
            ),
            (
                "detail",
                "conformance/p03-g03-canonical-core-evidence.json",
                "p03-g03-canonical-core-evidence.json",
                lambda document: document["source_file_hashes"][0].__setitem__("sha256", "0" * 64),
                "source-file hashes differ",
            ),
        )
        for name, source_path, copied_name, mutate, message in mutations:
            with self.subTest(mutation=name):
                wrapper, _, upstream_path, receipt = self._receipt_case(
                    f"g03-{name}"
                )
                copied_path = wrapper / "inputs/g03" / copied_name
                document = json.loads(copied_path.read_bytes())
                mutate(document)
                copied_path.write_bytes(document_bytes(document))
                self._reseal_upstream_copied_file(
                    wrapper=wrapper,
                    upstream_path=upstream_path,
                    gate_id="G03",
                    source_path=source_path,
                    copied_path=copied_path,
                )
                self._reseal_receipt_upstream(
                    wrapper=wrapper,
                    upstream_path=upstream_path,
                    receipt=receipt,
                )
                with self.assertRaisesRegex(G05GateError, message):
                    validate_g05_receipt(
                        repository_root=REPOSITORY_ROOT,
                        wrapper_root=wrapper,
                        receipt=receipt,
                    )

    def test_g04_requires_exact_criteria_and_explicit_zero_counts(self) -> None:
        mutations = (
            (
                "status-only",
                lambda document: document.__setitem__("xcode_full", {"status": "passed"}),
                "Xcode counts",
            ),
            (
                "omitted-zero",
                lambda document: document["release_build"].pop("analyzer_warnings"),
                "release-build zero-count",
            ),
            (
                "boolean-zero",
                lambda document: document["release_build"].__setitem__("warnings", False),
                "release-build zero-count",
            ),
        )
        for name, mutate, message in mutations:
            with self.subTest(mutation=name):
                wrapper, _, upstream_path, receipt = self._receipt_case(
                    f"g04-{name}"
                )
                tests_path = wrapper / "inputs/g04/test-results.json"
                tests = json.loads(tests_path.read_bytes())
                mutate(tests)
                tests_path.write_bytes(document_bytes(tests))
                self._reseal_upstream_copied_file(
                    wrapper=wrapper,
                    upstream_path=upstream_path,
                    gate_id="G04",
                    source_path="test-results.json",
                    copied_path=tests_path,
                )
                self._reseal_receipt_upstream(
                    wrapper=wrapper,
                    upstream_path=upstream_path,
                    receipt=receipt,
                )
                with self.assertRaisesRegex(G05GateError, message):
                    validate_g05_receipt(
                        repository_root=REPOSITORY_ROOT,
                        wrapper_root=wrapper,
                        receipt=receipt,
                    )

        wrapper, _, upstream_path, receipt = self._receipt_case("g04-criteria")
        assessment_path = wrapper / "inputs/g04/g04-gate-assessment.json"
        assessment = json.loads(assessment_path.read_bytes())
        assessment["criteria"][0]["pass"] = False
        assessment_path.write_bytes(document_bytes(assessment))
        self._reseal_upstream_copied_file(
            wrapper=wrapper,
            upstream_path=upstream_path,
            gate_id="G04",
            source_path="analysis/g04-gate-assessment.json",
            copied_path=assessment_path,
        )
        self._reseal_receipt_upstream(
            wrapper=wrapper,
            upstream_path=upstream_path,
            receipt=receipt,
        )
        with self.assertRaisesRegex(G05GateError, "seven-criterion pass"):
            validate_g05_receipt(
                repository_root=REPOSITORY_ROOT,
                wrapper_root=wrapper,
                receipt=receipt,
            )


def test_g04_upstream_rejects_forged_closure_attestation(tmp_path: Path) -> None:
    case = G05GateTests(
        methodName="test_current_source_closure_builds_deterministic_bound_documents"
    )
    case.source_commit = subprocess.run(
        ["git", "rev-parse", "HEAD"],
        cwd=REPOSITORY_ROOT,
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()
    upstream_path = case._write_upstream_bindings(tmp_path)
    upstream = json.loads(upstream_path.read_bytes())
    validate_g05_upstream_bindings(
        repository_root=REPOSITORY_ROOT,
        wrapper_root=tmp_path,
        document=upstream,
        source_commit=case.source_commit,
    )
    attestation = upstream["gates"]["G04"]["closure_attestation"]
    attestation["wrapper_file_count"] += 1
    try:
        validate_g05_upstream_bindings(
            repository_root=REPOSITORY_ROOT,
            wrapper_root=tmp_path,
            document=upstream,
            source_commit=case.source_commit,
        )
    except G05GateError as error:
        if "transitive closure attestation differs" not in str(error):
            raise
    else:
        raise AssertionError("forged G04 upstream closure count was accepted")


if __name__ == "__main__":
    unittest.main()
