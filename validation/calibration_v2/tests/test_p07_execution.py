from __future__ import annotations

import copy
from dataclasses import dataclass, replace
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import stat
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock

from validation.calibration_v2.p07.execution import (
    EXECUTION_RESULT_SCHEMA,
    P07ContextualError,
    P07DualFailure,
    P07ExecutionError,
    P07HoldoutExecutor,
    P07MediaContext,
    P07Preflight,
    SUPPORT_ROOT_IDS,
    _directory_tree_sha256,
    _manifest_hash,
    _publish_directory_exclusive,
    _open_directory_nofollow,
    _P07TransactionWorkspace,
    _RetainedAuthorizedFile,
    _snapshot_descriptor_tree,
    _rename_directory_exclusive_at,
    _validate_artifact_manifest,
    _validate_failure_publication,
    _write_artifact_manifest,
    _validate_schema,
    build_p07_frame_loader,
)
from validation.quality.src.mirmir_quality.json_tools import canonical_sha256
from validation.calibration_v2.p07 import execution as execution_module
from validation.calibration_v2.macos_code_identity import static_code_identity
from validation.calibration_v2.release_evidence import evidence_binding
from validation.calibration_v2.release_lock import _release_filesystem_closure
from validation.calibration_v2.production_providers import (
    production_writer_settings_document,
)
from validation.quality.src.mirmir_quality.json_tools import canonical_json_bytes


def _digest(value: object) -> str:
    return hashlib.sha256(repr(value).encode("utf-8")).hexdigest()


def _synthetic_code_binding(name: str) -> dict[str, object]:
    file_sha256 = _digest(("authorized-file", name))
    identity = {
        "schema_version": "1.0.0",
        "artifact_kind": "macos_code_identity_v1",
        "architecture": "arm64",
        "file_sha256": file_sha256,
        "unique_cdhash": hashlib.sha256(
            ("cdhash-" + name).encode("utf-8")
        ).hexdigest()[:40],
        "all_cdhashes": [
            hashlib.sha256(("cdhash-" + name).encode("utf-8")).hexdigest()[:40]
        ],
        "digest_algorithms": [2],
        "static_code_flags": 2,
        "signing_kind": "ad_hoc",
        "identifier": "org.mirmir.synthetic." + name,
    }
    return {
        "path": "/synthetic/" + name,
        "file_sha256": file_sha256,
        "code_identity": identity,
    }


def _synthetic_authorized_execution_bindings(
    *,
    release_manifest_sha256: str | None = None,
) -> dict[str, object]:
    mount = {
        "path": "/synthetic/mount-read-only.sh",
        "file_sha256": _digest("synthetic-mount-script"),
        "interpreter": _synthetic_code_binding("zsh"),
    }
    unmount = {
        "path": "/synthetic/unmount-provisioning.sh",
        "file_sha256": _digest("synthetic-unmount-script"),
        "interpreter": _synthetic_code_binding("zsh"),
    }
    document: dict[str, object] = {
        "schema_version": "1.0.0",
        "artifact_kind": "p07_authorized_execution_bindings",
        "status": "bound",
        "authorized_environment": {
            "LANG": "C",
            "LC_ALL": "C",
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "TMPDIR": "/private/tmp",
        },
        "authorized_spawn_policy_version": (
            "p07-mandatory-suspended-runtime-identity-v1"
        ),
        "direct_mount_template_sha256": _digest("synthetic-mount-template"),
        "direct_mount_template_digest_contract": (
            "SHA-256 of b'mount\\0' + mount-script bytes + "
            "b'\\0unmount\\0' + unmount-script bytes"
        ),
        "unavailable_reason": None,
        "loader": _synthetic_code_binding("loader"),
        "sampling_plan": {
            "path": "/synthetic/holdout-sampling-plan.json",
            "file_sha256": _digest("synthetic-sampling-plan"),
        },
        "mount_script": mount,
        "unmount_script": unmount,
        "key_helper": _synthetic_code_binding("key-access"),
        "mount_table": _synthetic_code_binding("mount"),
        "hdiutil": _synthetic_code_binding("hdiutil"),
        "production_execution_binding_fragment": (
            _synthetic_production_execution_fragment()
            if release_manifest_sha256 is None
            else _synthetic_production_execution_fragment(
                release_manifest_sha256=release_manifest_sha256
            )
        ),
    }
    document["manifest_sha256"] = _manifest_hash(document)
    return document


def _synthetic_production_execution_fragment(
    *,
    release_manifest_sha256: str | None = None,
) -> dict[str, object]:
    code_identities = {
        name: _synthetic_code_binding(name)["code_identity"]
        for name in (
            "production_swift_executable",
            "production_writer_executable",
            "p00_native_executable",
        )
    }
    core: dict[str, object] = {
        "schema_version": "1.0.0",
        "artifact_kind": "p07_authorized_execution_binding_fragment",
        "spawn_policy": {
            "policy_id": "macos-posix-spawn-suspended-gated-v1",
            "spawn_flags": {
                "set_process_group": 2,
                "start_suspended": 128,
                "close_on_exec_default": 16384,
            },
            "process_group_id": "child_pid",
            "identity_check_state": "stopped_before_sigcont",
            "gate_authorization_byte_hex": "a5",
            "environment_policy_id": "mirmir-authorized-env-v1",
            "environment": {
                "LANG": "C",
                "LC_ALL": "C",
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "TMPDIR": "/private/tmp",
            },
            "umask_octal": "077",
        },
        "cache_root_identity": {"device": 1, "inode": 2},
        "macos_code_identities": code_identities,
        "retained_fd_roles": {
            group: [
                {
                    "role": group + "_input",
                    "sha256": _digest((group, "input")),
                    "size_bytes": 1,
                }
            ]
            for group in (
                "production_swift",
                "p00_native",
                "production_writer",
            )
        },
        "production_writer": {
            "support_tree": {
                "id": "production_writer_tree",
                "root_id": "production_writer",
                "path": "synthetic-writer-tree",
                "kind": "directory_tree",
                "sha256": _digest("writer-tree"),
                "size_bytes": 1,
                "file_count": 1,
            },
            "settings_sha256": _digest("writer-settings"),
            "product_settings_source_sha256": _digest("writer-settings-source"),
            "executable_sha256": code_identities[
                "production_writer_executable"
            ]["file_sha256"],
        },
        "p06_release_bundle_manifest_sha256": (
            release_manifest_sha256
            if release_manifest_sha256 is not None
            else _digest("release-bundle")
        ),
    }
    core["fragment_sha256"] = _manifest_hash(
        core,
        field="fragment_sha256",
    )
    return core


def _write_canonical(path: Path, document: dict[str, object]) -> None:
    path.write_text(
        json.dumps(
            document,
            ensure_ascii=False,
            allow_nan=False,
            sort_keys=True,
            separators=(",", ":"),
        )
        + "\n",
        encoding="utf-8",
    )


def _static_production_fragment_inputs(
    root: Path,
) -> tuple[dict[str, object], dict[str, Path]]:
    repository = root / "repository"
    release = root / "release"
    writer_support = root / "writer-support"
    writer_root = writer_support / "writer-tree"
    cache = root / "p07-cache"
    for directory in (
        repository / "Mirmir/Modules/MediaPipeline",
        release / "bin",
        release / "sources",
        release / "evaluations",
        writer_root,
        cache,
    ):
        directory.mkdir(parents=True, exist_ok=True)
    (repository / "Mirmir/Modules/MediaPipeline/MediaTypes.swift").write_text(
        "enum SyntheticMediaTypes {}\n",
        encoding="utf-8",
    )
    release_executable = release / "bin/ash-calibration-cli"
    writer_executable = writer_root / "production-writer"
    p00_root = (
        cache
        / "current-source-extra-parity"
        / "p00"
        / _digest("current-p00-source-manifest")
    )
    p00_root.mkdir(parents=True)
    p00_executable = p00_root / "ash-p00-control-cli"
    for source, destination in (
        (Path("/bin/echo"), release_executable),
        (Path("/bin/ls"), writer_executable),
        (Path("/usr/bin/true"), p00_executable),
    ):
        shutil.copyfile(source, destination)
        destination.chmod(0o700)

    source_manifest = release / "sources/production-swift-source-manifest.json"
    source_manifest.write_text("{}\n", encoding="utf-8")
    configuration_id = "synthetic-static-p07-v1"
    selected_vector_sha256 = _digest("selected-vector")
    writer_settings_sha256 = canonical_sha256(
        production_writer_settings_document(
            executable_sha256=hashlib.sha256(
                writer_executable.read_bytes()
            ).hexdigest(),
            product_settings_source_sha256=hashlib.sha256(
                (
                    repository
                    / "Mirmir/Modules/MediaPipeline/MediaTypes.swift"
                ).read_bytes()
            ).hexdigest(),
        )
    )
    hash_bindings = {
        "mapping_sha256": _digest("mapping-binding"),
        "operator_bank_sha256": _digest("operator-binding"),
        "metric_policy_sha256": _digest("metric-binding"),
        "compiler_inputs_sha256": _digest("compiler-binding"),
        "calibration_plan_sha256": _digest("plan-binding"),
        "corpus_lock_bundle_sha256": _digest("corpus-bundle"),
    }
    documents: dict[str, tuple[str, object]] = {
        "calibration_selection": (
            "calibration-selection.json",
            {"selected_vector_sha256": selected_vector_sha256},
        ),
        "selected_evaluation": (
            "evaluations/{}.json".format(_digest("evaluation-path")),
            {"writer_settings_sha256": writer_settings_sha256},
        ),
        "calibration_run_ledger": ("calibration-run-ledger.json", {}),
        "live_holdout_preopen_verification": (
            "live-holdout-preopen-verification.json",
            {},
        ),
        "dispatch_measurement": ("dispatch-measurement.json", {}),
        "locked_mapping": (
            "locked-mapping.json",
            {"configuration_id": configuration_id},
        ),
        "locked_operator_bank": ("locked-operator-bank.json", {}),
        "locked_quality_policy": ("locked-quality-policy.json", {}),
        "locked_metric_policy": ("locked-metric-policy.json", {}),
        "locked_compiler_input": (
            "locked-compiler-input.json",
            {"hash_bindings": hash_bindings},
        ),
        "route_analysis_grid_selection": (
            "route-analysis-grid-selection.json",
            {},
        ),
        "native_parity_manifest": ("native-lut-parity-manifest.json", {}),
        "configuration_lock": (
            "configuration-lock.json",
            {"configuration_id": configuration_id},
        ),
    }
    for _, (relative, document) in documents.items():
        path = release.joinpath(*Path(relative).parts)
        path.parent.mkdir(parents=True, exist_ok=True)
        _write_canonical(path, dict(document))
    for name, payload in (
        ("direct2x.ashlut", b"synthetic-direct-2x-lut"),
        ("direct3over2.ashlut", b"synthetic-direct-3over2-lut"),
    ):
        (release / name).write_bytes(payload)

    def file_binding(identifier: str, relative: str) -> dict[str, object]:
        payload = release.joinpath(*Path(relative).parts).read_bytes()
        return {
            "id": identifier,
            "path": relative,
            "sha256": hashlib.sha256(payload).hexdigest(),
            "size_bytes": len(payload),
        }

    compiler_binding = file_binding(
        "locked_compiler_input",
        "locked-compiler-input.json",
    )
    route_rows = []
    for route, route_id, numerator, denominator, phases, entries, path in (
        ("direct_2x", 1, 2, 1, 4, 4096, "direct2x.ashlut"),
        ("direct_3_over_2", 2, 3, 2, 9, 9216, "direct3over2.ashlut"),
    ):
        payload = (release / path).read_bytes()
        route_rows.append(
            {
                "route": route,
                "route_id": route_id,
                "scale_numerator": numerator,
                "scale_denominator": denominator,
                "phase_count": phases,
                "context_count": 4,
                "valid_state_count": 256,
                "luma_coordinate_policy": "source_aligned_rational",
                "chroma_coordinate_policy": "source_aligned_rational",
                "analysis_grid_source_step": 1,
                "entry_count": entries,
                "parameter_count": 1,
                "path": path,
                "whole_file_size_bytes": len(payload),
                "whole_file_sha256": hashlib.sha256(payload).hexdigest(),
                "payload_sha256": _digest((route, "payload")),
                "header_crc32": "0x00000001",
                "payload_crc32": "0x00000002",
            }
        )
    lut_manifest = {
        "compiler_input": {
            "path": "locked-compiler-input.json",
            "sha256": compiler_binding["sha256"],
            "size_bytes": compiler_binding["size_bytes"],
        },
        "routes": route_rows,
    }
    _write_canonical(release / "lut-manifest.json", lut_manifest)

    code_identities = {
        "production_swift_executable": static_code_identity(
            release_executable
        ),
        "production_writer_executable": static_code_identity(
            writer_executable
        ),
        "p00_native_executable": static_code_identity(p00_executable),
    }
    auxiliary_implementation_rows = []
    for identifier in (
        "independent_python_source_manifest",
        "release_orchestrator_source",
        "production_calibration_cli_source",
    ):
        path = release / "implementation-evidence" / (identifier + ".txt")
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(identifier + "\n", encoding="utf-8")
        auxiliary_implementation_rows.append(
            evidence_binding(
                identifier=identifier,
                root_id="release",
                path=path,
                root=release,
            )
        )
    selected_control_rows = []
    for identifier in ("best_fixed", "conventional", "non_ash_selector"):
        path = release / "selected-control-evidence" / (identifier + ".json")
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("{}\n", encoding="utf-8")
        selected_control_rows.append(
            evidence_binding(
                identifier=identifier,
                root_id="release",
                path=path,
                root=release,
            )
        )
    test_evidence_rows = []
    for identifier in (
        "python_calibration_full_suite",
        "xcode_native_integration",
        "xcode_release_runtime",
        "swiftlint",
        "release_lock_unit_suite",
    ):
        path = release / "test-evidence" / identifier
        path.mkdir(parents=True)
        (path / "result.txt").write_text(identifier + "\n", encoding="utf-8")
        test_evidence_rows.append(
            evidence_binding(
                identifier=identifier,
                root_id="release",
                path=path,
                root=release,
            )
        )
    preserved_failure_path = release / "preserved-failures/p00.json"
    preserved_failure_path.parent.mkdir(parents=True)
    preserved_failure_path.write_text("{}\n", encoding="utf-8")

    def synthetic_tree(
        identifier: str,
        root_id: str,
    ) -> dict[str, object]:
        return {
            "id": identifier,
            "root_id": root_id,
            "path": "synthetic-tree",
            "kind": "directory_tree",
            "sha256": _digest((identifier, "tree")),
            "size_bytes": 1,
            "file_count": 1,
        }

    configuration_fields = (
        "mapping_sha256",
        "operator_bank_sha256",
        "quality_policy_sha256",
        "metric_policy_sha256",
        "metric_implementation_sha256",
        "metric_conformance_sha256",
        "degradation_policy_sha256",
        "actual_codec_fixture_sha256",
        "actual_codec_evidence_sha256",
        "quality_harness_implementation_manifest_sha256",
        "compiler_inputs_sha256",
        "route_luts_sha256",
        "corpus_manifest_sha256",
    )
    evidence_core: dict[str, object] = {
        "schema_version": "1.0.0",
        "artifact_kind": "p06_release_evidence_closure",
        "status": "locked_before_p07",
        "configuration_id": configuration_id,
        "input_bundle_sha256": _digest("input-bundle"),
        "corpus_lock_bundle_sha256": _digest("corpus-lock-bundle"),
        "configuration_bindings": [
            {
                "id": identifier,
                "root_id": "release",
                "path": "configuration-placeholder.json",
                "file_sha256": _digest((identifier, "file")),
                "size_bytes": 1,
                "digest_mode": "file_sha256",
                "manifest_hash_field": None,
                "digest_sha256": _digest((identifier, "digest")),
            }
            for identifier in configuration_fields
        ],
        "implementation_artifacts": [
            evidence_binding(
                identifier="production_swift_executable",
                root_id="release",
                path=release_executable,
                root=release,
            ),
            evidence_binding(
                identifier="production_swift_source_manifest",
                root_id="release",
                path=source_manifest,
                root=release,
            ),
            *auxiliary_implementation_rows,
        ],
        "macos_code_identities": code_identities,
        "selected_control_artifacts": selected_control_rows,
        "support_evidence_trees": [
            synthetic_tree("open_split_tree", "open_split"),
            synthetic_tree(
                "calibration_evidence_tree",
                "calibration_evidence",
            ),
            synthetic_tree("native_cache_tree", "native_cache"),
            evidence_binding(
                identifier="production_writer_tree",
                root_id="production_writer",
                path=writer_root,
                root=writer_support,
            ),
            synthetic_tree(
                "dispatch_measurement_tree",
                "dispatch_measurement",
            ),
        ],
        "test_evidence": test_evidence_rows,
        "preserved_failures": [
            evidence_binding(
                identifier="p00_pinned_lanczos_postcommit_handler",
                root_id="release",
                path=preserved_failure_path,
                root=release,
            )
        ],
        "calibration_run_tree": {
            "id": "complete_calibration_run_tree",
            "root_id": "calibration_run",
            "path": "synthetic-run",
            "kind": "directory_tree",
            "sha256": _digest("calibration-run-tree"),
            "size_bytes": 1,
            "file_count": 1,
        },
        "holdout_accessed": False,
    }
    evidence = {
        **evidence_core,
        "manifest_sha256": canonical_sha256(evidence_core),
    }
    _write_canonical(release / "p06-evidence-closure.json", evidence)

    artifact_paths = (
        ("calibration_selection", "calibration-selection.json"),
        (
            "selected_evaluation",
            documents["selected_evaluation"][0],
        ),
        ("calibration_run_ledger", "calibration-run-ledger.json"),
        (
            "live_holdout_preopen_verification",
            "live-holdout-preopen-verification.json",
        ),
        ("dispatch_measurement", "dispatch-measurement.json"),
        ("locked_mapping", "locked-mapping.json"),
        ("locked_operator_bank", "locked-operator-bank.json"),
        ("locked_quality_policy", "locked-quality-policy.json"),
        ("locked_metric_policy", "locked-metric-policy.json"),
        ("locked_compiler_input", "locked-compiler-input.json"),
        (
            "route_analysis_grid_selection",
            "route-analysis-grid-selection.json",
        ),
        ("direct2x_lut", "direct2x.ashlut"),
        ("direct3over2_lut", "direct3over2.ashlut"),
        ("native_parity_manifest", "native-lut-parity-manifest.json"),
        ("lut_manifest", "lut-manifest.json"),
        ("configuration_lock", "configuration-lock.json"),
        ("evidence_closure", "p06-evidence-closure.json"),
    )
    bundle_core: dict[str, object] = {
        "schema_version": "2.0.0",
        "bundle_id": "mirmir-p06-spatial-release-lock-v2",
        "status": "locked_before_p07",
        "configuration_id": configuration_id,
        "locked_utc": "2026-07-12T00:00:00Z",
        "input_bundle_sha256": evidence["input_bundle_sha256"],
        "corpus_lock_bundle_sha256": evidence[
            "corpus_lock_bundle_sha256"
        ],
        "release_fields_complete": True,
        "configuration_files_modified_after_lock": False,
        "holdout_accessed": False,
        "holdout_access_count": 0,
        "artifacts": [
            file_binding(identifier, relative)
            for identifier, relative in artifact_paths
        ],
        "filesystem_closure_rule": "all_entries_except_self_manifest_v1",
        "filesystem_closure": _release_filesystem_closure(
            release,
            excluded_paths=frozenset({"p06-release-bundle.json"}),
        ),
    }
    bundle = {
        **bundle_core,
        "manifest_sha256": canonical_sha256(bundle_core),
    }
    _write_canonical(release / "p06-release-bundle.json", bundle)

    configuration_lock = documents["configuration_lock"][1]
    runtime_identity = canonical_sha256(
        {
            "p06_release_bundle_manifest_sha256": bundle[
                "manifest_sha256"
            ],
            "configuration_sha256": canonical_sha256(configuration_lock),
            "selected_vector_sha256": selected_vector_sha256,
            "native_source_manifest_sha256": evidence[
                "implementation_artifacts"
            ][1]["sha256"],
        }
    )
    runtime_core = {
        "schema_version": "1.0.0",
        "manifest_id": "mirmir-ash-candidate-route-luts-v1",
        "status": "calibration_candidate",
        "configuration_id": configuration_id,
        "compiler_input": lut_manifest["compiler_input"],
        "hash_bindings": hash_bindings,
        "routes": route_rows,
        "swift_cli": {
            "executable_sha256": code_identities[
                "production_swift_executable"
            ]["file_sha256"],
            "source_manifest_sha256": evidence[
                "implementation_artifacts"
            ][1]["sha256"],
        },
        "native_parity_claimed": False,
    }
    runtime_manifest = {
        **runtime_core,
        "manifest_sha256": canonical_sha256(runtime_core),
    }
    runtime_path = (
        cache
        / "release-runtime"
        / runtime_identity
        / "release-runtime-envelope.json"
    )
    runtime_path.parent.mkdir(parents=True)
    runtime_path.write_bytes(canonical_json_bytes(runtime_manifest) + b"\n")
    return bundle, {
        "repository": repository,
        "release": release,
        "writer_support": writer_support,
        "cache": cache,
    }


def _minimal_publication(directory: Path) -> None:
    directory.mkdir()
    configuration_sha256 = _digest("publication-configuration")
    sampling_sha256 = _digest("publication-sampling")
    extraction: dict[str, object] = {
        "sampling_plan_manifest_sha256": sampling_sha256,
    }
    extraction["manifest_sha256"] = canonical_sha256(extraction)
    snapshot_files = [
        {
            "path": "preopen.json",
            "sha256": _digest("preopen-file"),
            "size_bytes": 1,
        }
    ]
    cache_snapshot = {
        "file_count": 1,
        "size_bytes": 1,
        "tree_sha256": canonical_sha256(snapshot_files),
        "files": snapshot_files,
    }
    runtime: dict[str, object] = {
        "configuration_sha256": configuration_sha256,
        "p06_release_bundle_manifest_sha256": _digest("publication-release"),
        "sampling_plan_manifest_sha256": sampling_sha256,
        "frame_extraction_manifest_sha256": extraction["manifest_sha256"],
        "measurement_core_sha256": canonical_sha256(
            {"configuration_sha256": configuration_sha256}
        ),
        "preopen_cache_snapshot_before": cache_snapshot,
        "preopen_cache_snapshot_after": cache_snapshot,
        "preopen_cache_unchanged": True,
        "loader_preopen_verification": {
            "build": {"executable_sha256": _digest("publication-loader")},
            "reproducibility_build": {
                "executable_sha256": _digest("publication-loader")
            },
            "builds_byte_identical": True,
            "self_tests": [{"pass": True}, {"pass": True}],
            "self_tests_byte_identical": True,
        },
    }
    runtime["manifest_sha256"] = canonical_sha256(runtime)
    measurement: dict[str, object] = {
        "configuration_sha256": configuration_sha256,
        "runtime_evidence_manifest_sha256": runtime["manifest_sha256"],
    }
    measurement["measurement_sha256"] = canonical_sha256(measurement)

    gate_documents = {}
    for name in (
        "spatial-holdout-results.json",
        "paired-bootstrap-results.json",
        "ablation-results.json",
        "g07-decision.json",
    ):
        document: dict[str, object] = {
            "measurement_sha256": measurement["measurement_sha256"],
        }
        if name == "g07-decision.json":
            document["evidence"] = {"pass": True}
        document["manifest_sha256"] = canonical_sha256(document)
        gate_documents[name] = document

    _write_canonical(
        directory / "spatial-holdout-measurements.json",
        measurement,
    )
    _write_canonical(directory / "frame-extraction.json", extraction)
    _write_canonical(directory / "p07-runtime-evidence.json", runtime)
    for name, document in gate_documents.items():
        _write_canonical(directory / name, document)
    gate_bindings = {
        name: hashlib.sha256((directory / name).read_bytes()).hexdigest()
        for name in gate_documents
    }
    publication: dict[str, object] = {
        "artifact_kind": "p07_g07_publication",
        "status": "pass",
        "gate_pass": True,
        "artifact_file_sha256": gate_bindings,
    }
    publication["manifest_sha256"] = canonical_sha256(publication)
    _write_canonical(directory / "evaluation-result.json", publication)
    authorized_execution = _synthetic_authorized_execution_bindings(
        release_manifest_sha256=runtime[
            "p06_release_bundle_manifest_sha256"
        ]
    )
    _write_canonical(
        directory / "authorized-execution-bindings.json",
        authorized_execution,
    )
    authorized_execution_file_sha256 = hashlib.sha256(
        (directory / "authorized-execution-bindings.json").read_bytes()
    ).hexdigest()
    execution: dict[str, object] = {
        "artifact_kind": "p07_locked_holdout_execution",
        "configuration_id": "synthetic-p07-v1",
        "configuration_sha256": configuration_sha256,
        "release_bundle_manifest_sha256": runtime[
            "p06_release_bundle_manifest_sha256"
        ],
        "direct_input_bindings": [
            {
                "id": "synthetic",
                "path": "direct-input.json",
                "sha256": _digest("direct-input"),
                "size_bytes": 1,
            }
        ],
        "sampling_plan_manifest_sha256": sampling_sha256,
        "loader_executable_sha256": runtime["loader_preopen_verification"][
            "build"
        ]["executable_sha256"],
        "authorized_execution_bindings_file_sha256": (
            authorized_execution_file_sha256
        ),
        "authorized_execution_bindings_manifest_sha256": (
            authorized_execution["manifest_sha256"]
        ),
        "evaluation_sha256": measurement["measurement_sha256"],
        "runtime_evidence_manifest_sha256": runtime["manifest_sha256"],
        "g07_gate_pass": True,
        "holdout_access_consumed": True,
        "holdout_access_state": "completed",
        "holdout_access_evidence_source": "live_guard_ledger",
        "holdout_access_ledger_file_sha256": _digest("publication-ledger"),
        "holdout_access_ledger_tip_sha256": _digest("publication-tip"),
        "holdout_access_ledger_event_count": 4,
        "holdout_access_ledger_event_order": [
            "sealed",
            "open_intent",
            "opened",
            "completed",
        ],
        "holdout_access_configuration_sha256": configuration_sha256,
        "holdout_access_immutable_anchor_file_sha256": _digest(
            "publication-anchor"
        ),
        "holdout_access_open_intent_linked": True,
        "holdout_access_ledger_verification_error_sha256": None,
    }
    execution["manifest_sha256"] = canonical_sha256(execution)
    _write_canonical(directory / "p07-execution-result.json", execution)
    _write_artifact_manifest(
        directory,
        status="complete",
        publication_kind="g07_evidence",
        configuration_id="synthetic-p07-v1",
        configuration_sha256=configuration_sha256,
        release_bundle_manifest_sha256=runtime[
            "p06_release_bundle_manifest_sha256"
        ],
        sampling_plan_manifest_sha256=sampling_sha256,
        holdout_accessed=True,
        holdout_access_consumed=True,
        command="python3 -m pytest test_p07_execution.py",
        platform="synthetic macOS arm64",
    )


def _ledger_event(
    sequence: int,
    event: str,
    previous: str,
    details: dict[str, object],
) -> dict[str, object]:
    row: dict[str, object] = {
        "sequence": sequence,
        "event": event,
        "occurred_utc": "2026-07-11T00:00:{:02d}Z".format(sequence),
        "previous_entry_sha256": previous,
        "details": details,
    }
    row["entry_sha256"] = canonical_sha256(row)
    return row


def _completed_ledger(
    path: Path,
    anchor_path: Path,
    configuration_sha256: str,
    *,
    seal_anchor: bool,
) -> tuple[str, str, str]:
    corpus_sha256 = _digest("corpus")
    anchor = {
        "schema_version": "1.0.0",
        "artifact_kind": "holdout_access_anchor",
        "corpus_manifest_sha256": corpus_sha256,
        "configuration_sha256": configuration_sha256,
        "open_intent_utc": "2026-07-11T00:00:01Z",
        "persistence": "macos-user-immutable-v1",
        "threat_boundary": "synthetic-test",
    }
    _write_canonical(anchor_path, anchor)
    anchor_sha256 = hashlib.sha256(anchor_path.read_bytes()).hexdigest()
    if seal_anchor:
        os.chflags(anchor_path, stat.UF_IMMUTABLE)
    events = []
    previous = "0" * 64
    details_by_name = {
        "sealed": {"corpus_manifest_sha256": corpus_sha256},
        "open_intent": {
            "configuration_sha256": configuration_sha256,
            "external_anchor_sha256": anchor_sha256,
        },
        "opened": {"receipt": "persisted before loader delegation"},
        "completed": {"post_loader_bindings_reverified": True},
    }
    for name in ("sealed", "open_intent", "opened", "completed"):
        event = _ledger_event(len(events), name, previous, details_by_name[name])
        events.append(event)
        previous = str(event["entry_sha256"])
    document = {
        "schema_version": "1.0.0",
        "corpus_manifest_sha256": corpus_sha256,
        "state": "completed",
        "open_intent_utc": "2026-07-11T00:00:01Z",
        "opened_utc": "2026-07-11T00:00:02Z",
        "completed_utc": "2026-07-11T00:00:03Z",
        "events": events,
    }
    _write_canonical(path, document)
    return hashlib.sha256(path.read_bytes()).hexdigest(), previous, anchor_sha256


class _CompletedGuard:
    def __init__(
        self,
        ledger_path: Path,
        anchor_path: Path,
        *,
        seal_anchor: bool = True,
    ) -> None:
        self.ledger_path = ledger_path
        self.anchor_path = anchor_path
        self.seal_anchor = seal_anchor
        self.calls = 0

    def read_once(self, configuration: dict[str, object], loader: object) -> object:
        self.calls += 1
        result = loader()
        _completed_ledger(
            self.ledger_path,
            self.anchor_path,
            canonical_sha256(configuration),
            seal_anchor=self.seal_anchor,
        )
        return result

    def unseal(self) -> None:
        if self.anchor_path.exists() and self.seal_anchor:
            os.chflags(self.anchor_path, 0)


class _CountingGuard:
    def __init__(self) -> None:
        self.calls = 0

    def read_once(self, configuration: dict[str, object], loader: object) -> object:
        del configuration, loader
        self.calls += 1
        raise AssertionError("overlap rejection occurred after guard intent")


@dataclass
class _Fixture:
    executor: "_PostGuardFailureExecutor"
    preflight: P07Preflight
    configuration: dict[str, object]
    guard: _CompletedGuard


class _PostGuardFailureExecutor(P07HoldoutExecutor):
    def __init__(
        self,
        *,
        preflight: P07Preflight,
        configuration_path: Path,
        archive_failure: bool,
    ) -> None:
        self.synthetic_preflight = preflight
        self.configuration_path = configuration_path
        self.archive_failure = archive_failure
        self.bound = SimpleNamespace(
            bundle_sha256=preflight.input_bundle_sha256,
            records=tuple(preflight.input_records),
        )
        root = configuration_path.parent
        self.holdout_root = root
        self.live_holdout_preopen_binding = SimpleNamespace(
            live_ledger_path=root / "synthetic-ledger.json",
            live_anchor_path=root / "synthetic-anchor.json",
            live_preopen_receipt_path=root / "synthetic-preopen-receipt.json",
            expected_live_ledger_root_identity_sha256=_digest("ledger-root"),
            expected_live_anchor_root_identity_sha256=_digest("anchor-root"),
            expected_live_preopen_receipt_sha256=_digest("preopen-receipt"),
        )

    def preflight(self) -> P07Preflight:
        return self.synthetic_preflight

    def _artifact_path(self, bundle: object, artifact_id: str) -> Path:
        del bundle
        if artifact_id != "configuration_lock":
            raise AssertionError(artifact_id)
        return self.configuration_path

    def _verify_preflight_files(self, preflight: P07Preflight) -> None:
        del preflight

    def _verify_direct_input_files(self, preflight: P07Preflight) -> None:
        del preflight

    def _validate_release_and_inputs(self) -> tuple[object, object]:
        return self.synthetic_preflight.release_bundle, self.bound

    def _prepare_authorized_execution(
        self,
        preflight: P07Preflight,
    ) -> P07Preflight:
        return replace(
            preflight,
            authorized_execution_bindings=(
                _synthetic_authorized_execution_bindings()
            ),
        )

    def _authorized_observe_mount(self, mount_root: Path) -> object:
        del mount_root
        return SimpleNamespace(mounted=False, read_only=False, record="")

    def _bind_production_execution_fragment(
        self,
        *,
        preflight: P07Preflight,
        evaluator: object,
    ) -> P07Preflight:
        del evaluator
        fragment = preflight.authorized_execution_bindings[
            "production_execution_binding_fragment"
        ]
        self._persisted_production_execution_binding_fragment = fragment
        return preflight

    def _close_authorized_execution(self) -> None:
        return None

    def _validate_guard_binding(self, guard: object, *, corpus_manifest_sha256: str) -> None:
        del guard, corpus_manifest_sha256

    def _validate_terminal_invocation_binding(
        self,
        *,
        directory: Path,
        configuration_lock: object,
        guard: object,
    ) -> None:
        del guard
        document_path = (
            directory / "p07-execution-result.json"
            if (directory / "p07-execution-result.json").exists()
            else directory / "failed-version-archive.json"
        )
        document = json.loads(document_path.read_text(encoding="utf-8"))
        if document.get("configuration_sha256") != canonical_sha256(
            configuration_lock
        ):
            raise P07ExecutionError(
                "terminal P07 publication uses another configuration"
            )

    def _recover_mount_from_intent(self, intent: object) -> None:
        del intent

    def _validate_workspace_intent_for_invocation(
        self,
        *,
        workspace: object,
        output_directory: Path,
        configuration_lock: object,
        guard: object,
    ) -> None:
        del guard
        intent = workspace.intent
        if intent.get("configuration_sha256") != canonical_sha256(
            configuration_lock
        ):
            raise P07ExecutionError(
                "P07 workspace intent differs from the current invocation"
            )
        terminal_directory, terminal = (
            self._terminal_document_for_workspace_crosscheck(
                output_directory
            )
        )
        if terminal_directory is None or terminal is None:
            return
        for field in (
            "configuration_id",
            "configuration_sha256",
            "release_bundle_manifest_sha256",
            "input_bundle_sha256",
            "direct_input_bindings",
            "corpus_lock_bundle_sha256",
            "sampling_plan_file_sha256",
            "sampling_plan_manifest_sha256",
            "no_pixel_attestation_file_sha256",
            "loader_executable_sha256",
            "p07_preopen_cache_tree_sha256",
        ):
            if terminal.get(field) != intent.get(field):
                raise P07ExecutionError(
                    "P07 terminal publication and workspace intent differ"
                )

    def _authorized_evaluation(self, **kwargs: object) -> dict[str, object]:
        publication_directory = kwargs["publication_directory"]
        extraction_directory = kwargs["extraction_directory"]
        assert isinstance(publication_directory, Path)
        assert isinstance(extraction_directory, Path)
        (extraction_directory / "synthetic-crop.nv12").write_bytes(b"raw")
        scratch = publication_directory.with_name("synthetic-publication-base")
        _minimal_publication(scratch)
        for child in scratch.iterdir():
            child.rename(publication_directory / child.name)
        scratch.rmdir()
        extraction = json.loads(
            (publication_directory / "frame-extraction.json").read_text(
                encoding="utf-8"
            )
        )
        measurement = json.loads(
            (
                publication_directory / "spatial-holdout-measurements.json"
            ).read_text(encoding="utf-8")
        )
        runtime = json.loads(
            (publication_directory / "p07-runtime-evidence.json").read_text(
                encoding="utf-8"
            )
        )
        (publication_directory / "artifact-manifest.json").unlink()
        (publication_directory / "p07-execution-result.json").unlink()
        (
            publication_directory / "authorized-execution-bindings.json"
        ).unlink()
        return {
            "inventory_sha256": _digest("inventory"),
            "frame_extraction_manifest_sha256": extraction["manifest_sha256"],
            "evaluation_sha256": measurement["measurement_sha256"],
            "runtime_evidence_manifest_sha256": runtime["manifest_sha256"],
            "gate_pass": True,
        }

    def _validate_publication(self, directory: Path) -> object:
        del directory
        raise P07ExecutionError("injected post-guard validation failure")

    def _publish_failure(self, **kwargs: object) -> None:
        if self.archive_failure:
            raise OSError("injected archive publication failure")
        super()._publish_failure(**kwargs)


class _SyntheticSuccessExecutor(_PostGuardFailureExecutor):
    def __init__(self, **kwargs: object) -> None:
        super().__init__(**kwargs)
        self.tamper_ledger_before_replace = False
        self.ledger_path: Path | None = None

    def _validate_publication(self, directory: Path) -> object:
        execution_path = directory / "p07-execution-result.json"
        if self.tamper_ledger_before_replace:
            if self.ledger_path is None:
                raise AssertionError("synthetic ledger path is absent")
            self.ledger_path.write_bytes(self.ledger_path.read_bytes() + b" ")
        return {
            "p07-execution-result.json": hashlib.sha256(
                execution_path.read_bytes()
            ).hexdigest()
        }


class P07ExecutionFailureTests(unittest.TestCase):
    def test_executor_requires_exact_six_p06_support_roots(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            expected = {
                "open_split",
                "calibration_evidence",
                "native_cache",
                "production_writer",
                "dispatch_measurement",
                "calibration_run",
            }
            self.assertEqual(set(SUPPORT_ROOT_IDS), expected)
            support_roots = {
                identifier: root / identifier for identifier in expected
            }
            arguments = {
                "repository_root": root / "repository",
                "holdout_root": root / "holdout",
                "sampling_plan_path": root / "sampling-plan.json",
                "expected_sampling_plan_sha256": "1" * 64,
                "no_pixel_attestation_path": root / "attestation.json",
                "expected_no_pixel_attestation_sha256": "2" * 64,
                "loader_executable": root / "loader",
                "expected_loader_sha256": "3" * 64,
                "p06_release_root": root / "release",
                "p06_release_manifest_path": root / "release/p06-release-bundle.json",
                "p07_cache_root": root / "cache",
                "live_holdout_preopen_binding": mock.sentinel.live_binding,
            }
            executor = P07HoldoutExecutor(
                **arguments,
                support_evidence_roots=support_roots,
            )
            self.assertEqual(set(executor.support_evidence_roots), expected)

            missing = dict(support_roots)
            del missing["calibration_run"]
            with self.assertRaisesRegex(P07ExecutionError, "not exact"):
                P07HoldoutExecutor(
                    **arguments,
                    support_evidence_roots=missing,
                )

            extra = dict(support_roots)
            extra["unbound_tree"] = root / "unbound"
            with self.assertRaisesRegex(P07ExecutionError, "not exact"):
                P07HoldoutExecutor(
                    **arguments,
                    support_evidence_roots=extra,
                )

    def _fixture(self, root: Path, *, archive_failure: bool) -> _Fixture:
        configuration = {"synthetic_configuration": "locked"}
        configuration_path = root / "configuration-lock.json"
        _write_canonical(configuration_path, configuration)
        release_bundle = {
            "configuration_id": "synthetic-p07-v1",
            "manifest_sha256": _digest("release-bundle"),
        }
        unmount_script = root / "unmount.sh"
        unmount_script.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        unmount_sha256 = hashlib.sha256(unmount_script.read_bytes()).hexdigest()
        direct_input = root / "direct-input.json"
        direct_input.write_text("{}\n", encoding="utf-8")
        preflight = P07Preflight(
            plan={"manifest_sha256": _digest("sampling-plan")},
            plan_file_sha256=_digest("sampling-plan-file"),
            attestation={
                "inner_inventory": {"sha256": _digest("inventory")},
                "read_only_provisioning_workflow": {
                    "unmount_script_sha256": unmount_sha256,
                },
            },
            attestation_file_sha256=_digest("attestation-file"),
            corpus_lock={"manifest_sha256": _digest("corpus-manifest")},
            corpus_lock_file_sha256=_digest("corpus-file"),
            degradation_policy={},
            analytic_fixture_manifest={},
            outer_wrapper={"manifest_sha256": _digest("outer-wrapper")},
            outer_wrapper_file_sha256=_digest("outer-wrapper-file"),
            release_bundle=release_bundle,
            workflow_paths={"unmount_script_path": unmount_script},
            mount_root=root,
            loader_sha256=_digest("loader"),
            p07_cache_tree_sha256=_digest("preopen-cache"),
            input_bundle_sha256=_digest("input-bundle"),
            corpus_lock_bundle_sha256=_digest("corpus-bundle"),
            input_records=(
                {
                    "id": "synthetic",
                    "path": "direct-input.json",
                    "sha256": hashlib.sha256(direct_input.read_bytes()).hexdigest(),
                    "size_bytes": direct_input.stat().st_size,
                },
            ),
            authorized_execution_bindings=(
                _synthetic_authorized_execution_bindings()
            ),
        )
        executor = _PostGuardFailureExecutor(
            preflight=preflight,
            configuration_path=configuration_path,
            archive_failure=archive_failure,
        )
        guard = _CompletedGuard(
            root / "holdout-access-ledger.json",
            root / "holdout-access-anchor.json",
        )
        executor.live_holdout_preopen_binding = SimpleNamespace(
            live_ledger_path=guard.ledger_path,
            live_anchor_path=guard.anchor_path,
            live_preopen_receipt_path=root / "preopen-receipt.json",
            expected_live_ledger_root_identity_sha256=_digest("ledger-root"),
            expected_live_anchor_root_identity_sha256=_digest("anchor-root"),
            expected_live_preopen_receipt_sha256=_digest("preopen-receipt"),
        )
        return _Fixture(executor, preflight, configuration, guard)

    def test_post_guard_validation_failure_publishes_hash_bound_archive(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            fixture = self._fixture(root, archive_failure=False)
            output = root / "p07-output"
            with mock.patch(
                "validation.calibration_v2.p07.execution.corpus_lock_bundle_sha256",
                return_value=fixture.preflight.corpus_lock_bundle_sha256,
            ):
                with self.assertRaisesRegex(
                    P07ExecutionError,
                    "injected post-guard validation failure",
                ):
                    fixture.executor.execute_once(
                        configuration_lock=fixture.configuration,
                        guard=fixture.guard,
                        evaluator=lambda *arguments: {},
                        output_directory=output,
                    )
            fixture.guard.unseal()
            self.assertEqual(fixture.guard.calls, 1)
            archive_path = output / "failed-version-archive.json"
            archive = json.loads(archive_path.read_text(encoding="utf-8"))
            ledger_sha256 = hashlib.sha256(
                fixture.guard.ledger_path.read_bytes()
            ).hexdigest()
            ledger = json.loads(
                fixture.guard.ledger_path.read_text(encoding="utf-8")
            )
            ledger_tip = ledger["events"][-1]["entry_sha256"]
            anchor_sha256 = hashlib.sha256(
                fixture.guard.anchor_path.read_bytes()
            ).hexdigest()
            self.assertEqual(archive["failure_stage"], "post_guard_publication")
            self.assertTrue(archive["holdout_access_consumed"])
            self.assertEqual(archive["holdout_access_state"], "completed")
            self.assertEqual(
                archive["holdout_access_evidence_source"],
                "live_guard_ledger",
            )
            self.assertEqual(
                archive["holdout_access_ledger_file_sha256"], ledger_sha256
            )
            self.assertEqual(
                archive["holdout_access_ledger_tip_sha256"], ledger_tip
            )
            self.assertEqual(archive["holdout_access_ledger_event_count"], 4)
            self.assertEqual(
                archive["holdout_access_ledger_event_order"],
                ["sealed", "open_intent", "opened", "completed"],
            )
            self.assertEqual(
                archive["holdout_access_immutable_anchor_file_sha256"],
                anchor_sha256,
            )
            self.assertTrue(archive["holdout_access_open_intent_linked"])
            self.assertEqual(archive["manifest_sha256"], _manifest_hash(archive))
            self.assertFalse(archive["result_reusable_for_same_version"])
            self.assertEqual(
                sorted(path.name for path in output.iterdir()),
                [
                    "artifact-manifest.json",
                    "authorized-execution-bindings.json",
                    "failed-version-archive.json",
                    "failure-log.json",
                ],
            )
            failure_log = json.loads(
                (output / "failure-log.json").read_text(encoding="utf-8")
            )
            self.assertEqual(
                archive["failure_message"],
                "injected post-guard validation failure",
            )
            self.assertEqual(
                failure_log["failure_message"], archive["failure_message"]
            )
            self.assertIn(
                "injected post-guard validation failure",
                archive["failure_traceback"],
            )
            self.assertIsNone(archive["frame_index"])
            self.assertIsNone(archive["presentation_timestamp"])
            self.assertFalse(archive["media_context_available"])
            self.assertEqual(
                archive["failure_log_file_sha256"],
                hashlib.sha256(
                    (output / "failure-log.json").read_bytes()
                ).hexdigest(),
            )
            bindings = _validate_failure_publication(output)
            self.assertEqual(set(bindings), set(path.name for path in output.iterdir()))

    def test_archive_publication_failure_is_explicit_and_chained(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            fixture = self._fixture(root, archive_failure=True)
            with mock.patch(
                "validation.calibration_v2.p07.execution.corpus_lock_bundle_sha256",
                return_value=fixture.preflight.corpus_lock_bundle_sha256,
            ):
                with self.assertRaises(P07ExecutionError) as raised:
                    fixture.executor.execute_once(
                        configuration_lock=fixture.configuration,
                        guard=fixture.guard,
                        evaluator=lambda *arguments: {},
                        output_directory=root / "p07-output",
                    )
            fixture.guard.unseal()
            message = str(raised.exception)
            self.assertIn("post_guard_publication", message)
            self.assertIn("injected archive publication failure", message)
            self.assertIsInstance(raised.exception.__cause__, OSError)

    def test_pre_guard_failure_archives_proven_nonconsumption(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            fixture = self._fixture(root, archive_failure=False)
            executor = fixture.executor
            executor.p06_release_manifest_path = root / "missing-release.json"
            executor.sampling_plan_path = root / "missing-plan.json"
            executor.expected_sampling_plan_sha256 = fixture.preflight.plan_file_sha256
            executor.no_pixel_attestation_path = root / "missing-attestation.json"
            executor.expected_no_pixel_attestation_sha256 = (
                fixture.preflight.attestation_file_sha256
            )
            executor.expected_loader_sha256 = fixture.preflight.loader_sha256
            executor.p07_cache_root = root / "missing-cache"
            output = root / "pre-guard-failure"
            with mock.patch.object(
                executor,
                "_validated_pre_guard_preflight",
                side_effect=P07ExecutionError("injected pre-guard validation"),
            ):
                with self.assertRaisesRegex(
                    P07ExecutionError,
                    "injected pre-guard validation",
                ):
                    executor.execute_once(
                        configuration_lock=fixture.configuration,
                        guard=fixture.guard,
                        evaluator=lambda *arguments: {},
                        output_directory=output,
                    )
            self.assertEqual(fixture.guard.calls, 0)
            archive = json.loads(
                (output / "failed-version-archive.json").read_text(
                    encoding="utf-8"
                )
            )
            self.assertEqual(archive["failure_stage"], "pre_guard_validation")
            self.assertFalse(archive["holdout_access_consumed"])
            self.assertEqual(archive["holdout_access_state"], "sealed")
            self.assertEqual(
                archive["holdout_access_evidence_source"],
                "pre_guard_validation",
            )
            _validate_failure_publication(output)

    def test_staged_failure_recovers_without_second_guard_call(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            fixture = self._fixture(root, archive_failure=False)
            executor = fixture.executor
            output = root / "recoverable-failure"
            original_publish = _publish_directory_exclusive

            with mock.patch(
                "validation.calibration_v2.p07.execution."
                "corpus_lock_bundle_sha256",
                return_value=fixture.preflight.corpus_lock_bundle_sha256,
            ), mock.patch(
                "validation.calibration_v2.p07.execution."
                "_publish_directory_exclusive",
                side_effect=OSError("injected rename outage"),
            ):
                with self.assertRaisesRegex(
                    P07ExecutionError,
                    "failure archive publication also failed",
                ):
                    executor.execute_once(
                        configuration_lock=fixture.configuration,
                        guard=fixture.guard,
                        evaluator=lambda *arguments: {},
                        output_directory=output,
                    )
            self.assertEqual(fixture.guard.calls, 1)
            with mock.patch(
                "validation.calibration_v2.p07.execution."
                "corpus_lock_bundle_sha256",
                return_value=fixture.preflight.corpus_lock_bundle_sha256,
            ), mock.patch(
                "validation.calibration_v2.p07.execution."
                "_publish_directory_exclusive",
                wraps=original_publish,
            ):
                with self.assertRaisesRegex(
                    P07ExecutionError,
                    "recovered and validated",
                ):
                    executor.execute_once(
                        configuration_lock=fixture.configuration,
                        guard=fixture.guard,
                        evaluator=lambda *arguments: {},
                        output_directory=output,
                    )
            self.assertEqual(fixture.guard.calls, 1)
            _validate_failure_publication(output)
            archive = json.loads(
                (output / "failed-version-archive.json").read_text(
                    encoding="utf-8"
                )
            )
            tertiary = archive["archive_publication_failure"]
            self.assertEqual(archive["failure_type"], "P07ExecutionError")
            self.assertEqual(tertiary["failure_type"], "OSError")
            self.assertIn("injected rename outage", tertiary["failure_message"])
            self.assertEqual(
                tertiary["failure_message_sha256"],
                hashlib.sha256(
                    tertiary["failure_message"].encode("utf-8")
                ).hexdigest(),
            )
            self.assertEqual(
                tertiary["failure_traceback_sha256"],
                hashlib.sha256(
                    tertiary["failure_traceback"].encode("utf-8")
                ).hexdigest(),
            )
            self.assertIn("status", archive["cleanup_result"])

    def test_partial_disk_failure_rebuilds_from_emergency_seed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            fixture = self._fixture(root, archive_failure=False)
            output = root / "partial-disk-failure"
            from validation.calibration_v2.p07 import execution as execution_module

            original_write = execution_module._write_json

            def fail_archive_write(path: Path, document: object) -> None:
                if path.name == "failed-version-archive.json":
                    raise OSError("injected failure archive disk outage")
                original_write(path, document)

            with mock.patch(
                "validation.calibration_v2.p07.execution."
                "corpus_lock_bundle_sha256",
                return_value=fixture.preflight.corpus_lock_bundle_sha256,
            ), mock.patch(
                "validation.calibration_v2.p07.execution._write_json",
                side_effect=fail_archive_write,
            ):
                with self.assertRaisesRegex(
                    P07ExecutionError,
                    "failure archive publication also failed",
                ):
                    fixture.executor.execute_once(
                        configuration_lock=fixture.configuration,
                        guard=fixture.guard,
                        evaluator=lambda *arguments: {},
                        output_directory=output,
                    )
            self.assertEqual(fixture.guard.calls, 1)
            self.assertTrue(any(root.glob(".p07-transaction-*")))
            with mock.patch(
                "validation.calibration_v2.p07.execution."
                "corpus_lock_bundle_sha256",
                return_value=fixture.preflight.corpus_lock_bundle_sha256,
            ):
                with self.assertRaisesRegex(
                    P07ExecutionError,
                    "recovered and validated",
                ):
                    fixture.executor.execute_once(
                        configuration_lock=fixture.configuration,
                        guard=fixture.guard,
                        evaluator=lambda *arguments: {},
                        output_directory=output,
                    )
            self.assertEqual(fixture.guard.calls, 1)
            _validate_failure_publication(output)
            archive = json.loads(
                (output / "failed-version-archive.json").read_text(
                    encoding="utf-8"
                )
            )
            tertiary = archive["archive_publication_failure"]
            self.assertEqual(tertiary["failure_type"], "OSError")
            self.assertIn(
                "injected failure archive disk outage",
                tertiary["failure_message"],
            )
            self.assertIn(
                "injected failure archive disk outage",
                tertiary["failure_traceback"],
            )

    def test_post_rename_validation_failure_recovers_tertiary_archive(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            fixture = self._fixture(root, archive_failure=False)
            output = root / "post-rename-validation-failure"
            validation_calls = 0

            def fail_after_rename(directory: Path) -> object:
                nonlocal validation_calls
                validation_calls += 1
                if validation_calls == 2:
                    raise OSError("injected post-rename validation outage")
                return _validate_failure_publication(directory)

            with mock.patch(
                "validation.calibration_v2.p07.execution."
                "corpus_lock_bundle_sha256",
                return_value=fixture.preflight.corpus_lock_bundle_sha256,
            ), mock.patch(
                "validation.calibration_v2.p07.execution."
                "_validate_failure_publication",
                side_effect=fail_after_rename,
            ):
                with self.assertRaisesRegex(
                    P07ExecutionError,
                    "failure archive publication also failed",
                ):
                    fixture.executor.execute_once(
                        configuration_lock=fixture.configuration,
                        guard=fixture.guard,
                        evaluator=lambda *arguments: {},
                        output_directory=output,
                    )
            self.assertTrue(output.is_dir())
            self.assertTrue(any(root.glob(".p07-transaction-*")))
            with mock.patch(
                "validation.calibration_v2.p07.execution."
                "corpus_lock_bundle_sha256",
                return_value=fixture.preflight.corpus_lock_bundle_sha256,
            ):
                with self.assertRaisesRegex(
                    P07ExecutionError,
                    "archive-publication failure beside",
                ):
                    fixture.executor.execute_once(
                        configuration_lock=fixture.configuration,
                        guard=fixture.guard,
                        evaluator=lambda *arguments: {},
                        output_directory=output,
                    )
            recovered = output.with_name(output.name + ".failed")
            _validate_failure_publication(recovered)
            archive = json.loads(
                (recovered / "failed-version-archive.json").read_text(
                    encoding="utf-8"
                )
            )
            tertiary = archive["archive_publication_failure"]
            self.assertEqual(tertiary["failure_type"], "OSError")
            self.assertIn(
                "injected post-rename validation outage",
                tertiary["failure_message"],
            )
            self.assertEqual(fixture.guard.calls, 1)

    def test_success_destination_race_preserves_competitor_and_uses_failure_sibling(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            fixture = self._fixture(root, archive_failure=False)
            executor = _SyntheticSuccessExecutor(
                preflight=fixture.preflight,
                configuration_path=fixture.executor.configuration_path,
                archive_failure=False,
            )
            executor.ledger_path = fixture.guard.ledger_path
            output = root / "p07-raced"
            original_publish = _publish_directory_exclusive

            def racing_publish(
                source: Path,
                destination: Path,
                *,
                progress: dict[str, object] | None = None,
                destination_parent_pin: object = None,
            ) -> None:
                if destination == output:
                    output.mkdir()
                    (output / "competitor.json").write_text(
                        '{"owner":"competitor"}\n',
                        encoding="utf-8",
                    )
                    raise FileExistsError("injected destination race")
                original_publish(
                    source,
                    destination,
                    progress=progress,
                    destination_parent_pin=destination_parent_pin,
                )

            with mock.patch(
                "validation.calibration_v2.p07.execution."
                "corpus_lock_bundle_sha256",
                return_value=fixture.preflight.corpus_lock_bundle_sha256,
            ), mock.patch(
                "validation.calibration_v2.p07.execution."
                "_publish_directory_exclusive",
                side_effect=racing_publish,
            ):
                with self.assertRaisesRegex(
                    P07ExecutionError,
                    "exclusive P07 publication destination already exists",
                ):
                    executor.execute_once(
                        configuration_lock=fixture.configuration,
                        guard=fixture.guard,
                        evaluator=lambda *arguments: {},
                        output_directory=output,
                    )
            fixture.guard.unseal()
            self.assertEqual(
                (output / "competitor.json").read_text(encoding="utf-8"),
                '{"owner":"competitor"}\n',
            )
            failure = output.with_name(output.name + ".failed")
            self.assertTrue(failure.is_dir())
            self.assertEqual(
                set(path.name for path in failure.iterdir()),
                {
                    "artifact-manifest.json",
                    "authorized-execution-bindings.json",
                    "failed-version-archive.json",
                    "failure-log.json",
                },
            )
            _validate_failure_publication(failure)

    def test_success_binds_completed_authoritative_ledger_and_anchor(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            fixture = self._fixture(root, archive_failure=False)
            executor = _SyntheticSuccessExecutor(
                preflight=fixture.preflight,
                configuration_path=fixture.executor.configuration_path,
                archive_failure=False,
            )
            executor.ledger_path = fixture.guard.ledger_path
            output = root / "p07-success"
            with mock.patch(
                "validation.calibration_v2.p07.execution.corpus_lock_bundle_sha256",
                return_value=fixture.preflight.corpus_lock_bundle_sha256,
            ):
                result = executor.execute_once(
                    configuration_lock=fixture.configuration,
                    guard=fixture.guard,
                    evaluator=lambda *arguments: {},
                    output_directory=output,
                )
            fixture.guard.unseal()
            execution = json.loads(
                (output / "p07-execution-result.json").read_text(encoding="utf-8")
            )
            self.assertEqual(execution["holdout_access_state"], "completed")
            self.assertEqual(
                execution["holdout_access_ledger_event_order"],
                ["sealed", "open_intent", "opened", "completed"],
            )
            self.assertTrue(execution["holdout_access_open_intent_linked"])
            self.assertEqual(
                execution["holdout_access_configuration_sha256"],
                execution["configuration_sha256"],
            )
            self.assertEqual(
                result["holdout_access_immutable_anchor_file_sha256"],
                execution["holdout_access_immutable_anchor_file_sha256"],
            )
            manifest = json.loads(
                (output / "artifact-manifest.json").read_text(encoding="utf-8")
            )
            self.assertEqual(manifest["status"], "complete")
            self.assertEqual(manifest["publication_kind"], "g07_evidence")
            self.assertEqual(
                manifest["exact_file_names"],
                sorted(path.name for path in output.iterdir()),
            )
            self.assertEqual(manifest["manifest_sha256"], _manifest_hash(manifest))
            forged = dict(execution)
            forged["extraneous_field"] = True
            forged["manifest_sha256"] = _manifest_hash(forged)
            with self.assertRaisesRegex(P07ExecutionError, "schema validation"):
                _validate_schema(
                    forged,
                    EXECUTION_RESULT_SCHEMA,
                    "forged P07 execution result",
                )

    def test_terminal_success_reopens_without_second_guard_call(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            fixture = self._fixture(root, archive_failure=False)
            executor = _SyntheticSuccessExecutor(
                preflight=fixture.preflight,
                configuration_path=fixture.executor.configuration_path,
                archive_failure=False,
            )
            executor.ledger_path = fixture.guard.ledger_path
            output = root / "idempotent-success"
            evaluator_calls = 0

            def unreachable_evaluator(*arguments: object) -> object:
                nonlocal evaluator_calls
                del arguments
                evaluator_calls += 1
                raise AssertionError(
                    "terminal recovery invoked the evaluator callback"
                )

            with mock.patch(
                "validation.calibration_v2.p07.execution."
                "corpus_lock_bundle_sha256",
                return_value=fixture.preflight.corpus_lock_bundle_sha256,
            ):
                first = executor.execute_once(
                    configuration_lock=fixture.configuration,
                    guard=fixture.guard,
                    evaluator=lambda *arguments: {},
                    output_directory=output,
                )
                second = executor.execute_once(
                    configuration_lock=fixture.configuration,
                    guard=fixture.guard,
                    evaluator=unreachable_evaluator,
                    output_directory=output,
                )
            self.assertEqual(fixture.guard.calls, 1)
            self.assertEqual(evaluator_calls, 0)
            self.assertEqual(
                first["manifest_sha256"],
                second["manifest_sha256"],
            )
            fixture.guard.unseal()

    def test_intent_fragment_is_persisted_without_reading_terminal_evaluator(self) -> None:
        declared = _synthetic_authorized_execution_bindings()
        production_fragment = declared[
            "production_execution_binding_fragment"
        ]
        verification_calls = 0

        class FakeAuthorizedExecutionContext:
            def __init__(self) -> None:
                self.production_execution_binding_fragment = production_fragment

            def verify(self) -> None:
                nonlocal verification_calls
                verification_calls += 1

            def binding_document(self) -> object:
                return declared

        executor = object.__new__(P07HoldoutExecutor)
        executor._authorized_execution_context = (
            FakeAuthorizedExecutionContext()
        )
        executor._active_evaluator = lambda *arguments: (_ for _ in ()).throw(
            AssertionError("unreachable evaluator fragment was read")
        )
        executor._persisted_production_execution_binding_fragment = None
        with mock.patch.object(
            execution_module,
            "_AuthorizedExecutionContext",
            FakeAuthorizedExecutionContext,
        ):
            executor._prepare_authorized_execution_from_intent(
                {"authorized_execution_bindings": declared}
            )
        self.assertEqual(verification_calls, 1)
        self.assertEqual(
            executor._persisted_production_execution_binding_fragment,
            production_fragment,
        )

    def test_terminal_workspace_mismatch_rejects_before_mount_cleanup(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            fixture = self._fixture(root, archive_failure=False)
            executor = _SyntheticSuccessExecutor(
                preflight=fixture.preflight,
                configuration_path=fixture.executor.configuration_path,
                archive_failure=False,
            )
            executor.ledger_path = fixture.guard.ledger_path
            output = root / "terminal-a-workspace-b"
            with mock.patch(
                "validation.calibration_v2.p07.execution."
                "corpus_lock_bundle_sha256",
                return_value=fixture.preflight.corpus_lock_bundle_sha256,
            ):
                executor.execute_once(
                    configuration_lock=fixture.configuration,
                    guard=fixture.guard,
                    evaluator=lambda *arguments: {},
                    output_directory=output,
                )
            intent = execution_module._transaction_intent_document(
                output_directory=output,
                configuration_lock=fixture.configuration,
                preflight=fixture.preflight,
                live_binding=executor.live_holdout_preopen_binding,
                command="synthetic mismatched recovery",
                platform="synthetic macOS arm64",
            )
            intent["release_bundle_manifest_sha256"] = _digest(
                "workspace-b-release"
            )
            intent["manifest_sha256"] = _manifest_hash(intent)
            parent_descriptor, parent_identity = _open_directory_nofollow(
                output.parent,
                "synthetic terminal/workspace parent",
            )
            try:
                workspace, created = _P07TransactionWorkspace.open_or_create(
                    output_directory=output,
                    parent_descriptor=parent_descriptor,
                    parent_identity=parent_identity,
                    intent=intent,
                )
                self.assertTrue(created)
                workspace.close()
            finally:
                os.close(parent_descriptor)
            cleanup = mock.MagicMock()
            executor._recover_mount_from_intent = cleanup
            evaluator_calls = 0

            def unreachable(*arguments: object) -> object:
                nonlocal evaluator_calls
                del arguments
                evaluator_calls += 1
                raise AssertionError("mismatched recovery invoked evaluator")

            with self.assertRaisesRegex(
                P07ExecutionError,
                "terminal publication and workspace intent differ",
            ):
                executor.execute_once(
                    configuration_lock=fixture.configuration,
                    guard=fixture.guard,
                    evaluator=unreachable,
                    output_directory=output,
                )
            cleanup.assert_not_called()
            self.assertEqual(evaluator_calls, 0)
            self.assertEqual(fixture.guard.calls, 1)
            self.assertTrue(
                execution_module._transaction_directory_path(output).is_dir()
            )
            fixture.guard.unseal()

    def test_terminal_success_and_failure_reject_another_configuration(
        self,
    ) -> None:
        for terminal_kind in ("success", "failure"):
            with self.subTest(terminal_kind=terminal_kind), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary).resolve()
                fixture = self._fixture(root, archive_failure=False)
                executor: _PostGuardFailureExecutor
                if terminal_kind == "success":
                    success_executor = _SyntheticSuccessExecutor(
                        preflight=fixture.preflight,
                        configuration_path=fixture.executor.configuration_path,
                        archive_failure=False,
                    )
                    success_executor.ledger_path = fixture.guard.ledger_path
                    executor = success_executor
                else:
                    executor = fixture.executor
                output = root / "configuration-bound-terminal"
                with mock.patch(
                    "validation.calibration_v2.p07.execution."
                    "corpus_lock_bundle_sha256",
                    return_value=fixture.preflight.corpus_lock_bundle_sha256,
                ):
                    if terminal_kind == "success":
                        executor.execute_once(
                            configuration_lock=fixture.configuration,
                            guard=fixture.guard,
                            evaluator=lambda *arguments: {},
                            output_directory=output,
                        )
                    else:
                        with self.assertRaisesRegex(
                            P07ExecutionError,
                            "injected post-guard validation failure",
                        ):
                            executor.execute_once(
                                configuration_lock=fixture.configuration,
                                guard=fixture.guard,
                                evaluator=lambda *arguments: {},
                                output_directory=output,
                            )
                    with self.assertRaisesRegex(
                        P07ExecutionError,
                        "workspace intent differs from the current invocation|"
                        "terminal P07 publication uses another configuration",
                    ):
                        executor.execute_once(
                            configuration_lock={
                                "synthetic_configuration": "different"
                            },
                            guard=fixture.guard,
                            evaluator=lambda *arguments: {},
                            output_directory=output,
                        )
                self.assertEqual(fixture.guard.calls, 1)
                fixture.guard.unseal()

    def test_completed_ledger_toctou_is_rejected_before_publication(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            fixture = self._fixture(root, archive_failure=False)
            executor = _SyntheticSuccessExecutor(
                preflight=fixture.preflight,
                configuration_path=fixture.executor.configuration_path,
                archive_failure=False,
            )
            executor.ledger_path = fixture.guard.ledger_path
            executor.tamper_ledger_before_replace = True
            output = root / "p07-tampered-ledger"
            with mock.patch(
                "validation.calibration_v2.p07.execution.corpus_lock_bundle_sha256",
                return_value=fixture.preflight.corpus_lock_bundle_sha256,
            ):
                with self.assertRaisesRegex(
                    P07ExecutionError,
                    "changed before publication",
                ):
                    executor.execute_once(
                        configuration_lock=fixture.configuration,
                        guard=fixture.guard,
                        evaluator=lambda *arguments: {},
                        output_directory=output,
                    )
            fixture.guard.unseal()
            self.assertTrue((output / "failed-version-archive.json").is_file())
            self.assertFalse((output / "p07-execution-result.json").exists())

    def test_unsealed_anchor_is_rejected_before_success_publication(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            fixture = self._fixture(root, archive_failure=False)
            fixture.guard = _CompletedGuard(
                root / "unsealed-ledger.json",
                root / "unsealed-anchor.json",
                seal_anchor=False,
            )
            executor = _SyntheticSuccessExecutor(
                preflight=fixture.preflight,
                configuration_path=fixture.executor.configuration_path,
                archive_failure=False,
            )
            executor.ledger_path = fixture.guard.ledger_path
            output = root / "p07-unsealed-anchor"
            with mock.patch(
                "validation.calibration_v2.p07.execution.corpus_lock_bundle_sha256",
                return_value=fixture.preflight.corpus_lock_bundle_sha256,
            ):
                with self.assertRaisesRegex(
                    P07ExecutionError,
                    "completed guard ledger or immutable anchor evidence is invalid",
                ):
                    executor.execute_once(
                        configuration_lock=fixture.configuration,
                        guard=fixture.guard,
                        evaluator=lambda *arguments: {},
                        output_directory=output,
                    )
            archive = json.loads(
                (output / "failed-version-archive.json").read_text(encoding="utf-8")
            )
            self.assertEqual(archive["holdout_access_state"], "unavailable")
            self.assertIsNotNone(
                archive["holdout_access_ledger_verification_error_sha256"]
            )

    def test_swift_loader_build_and_self_test_are_deterministic(self) -> None:
        repository_root = Path(__file__).resolve().parents[3]
        source = (
            repository_root
            / "validation/calibration_v2/p07/P07HoldoutFrameLoader.swift"
        )
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            executable = root / "p07-frame-loader"
            build = build_p07_frame_loader(
                source_path=source,
                output_path=executable,
                repository_root=repository_root,
            )
            reproducibility_executable = root / "p07-frame-loader-reproducibility"
            reproducibility_build = build_p07_frame_loader(
                source_path=source,
                output_path=reproducibility_executable,
                repository_root=repository_root,
            )
            self.assertEqual(build, reproducibility_build)
            self.assertEqual(
                executable.read_bytes(),
                reproducibility_executable.read_bytes(),
            )
            outputs = []
            crop_hashes = []
            for index in range(2):
                output_directory = root / "self-test-{}".format(index)
                output_directory.mkdir()
                completed = subprocess.run(
                    [
                        str(executable),
                        "self-test",
                        "--output-directory",
                        str(output_directory),
                    ],
                    check=False,
                    capture_output=True,
                    timeout=30,
                )
                self.assertEqual(
                    completed.returncode,
                    0,
                    completed.stderr.decode("utf-8", "replace"),
                )
                document = json.loads(completed.stdout.decode("utf-8"))
                self.assertFalse(document["holdout_accessed"])
                self.assertTrue(document["presentation_order_monotonicity_checked"])
                self.assertTrue(document["midpoint_tie_selects_first"])
                self.assertTrue(document["descending_presentation_time_rejected"])
                self.assertEqual(document["manifest_sha256"], _manifest_hash(document))
                outputs.append(document)
                crop_hashes.append(
                    hashlib.sha256(
                        (output_directory / "self-test.nv12").read_bytes()
                    ).hexdigest()
                )
            self.assertEqual(outputs[0], outputs[1])
            self.assertEqual(crop_hashes[0], crop_hashes[1])
            self.assertEqual(build["executable_sha256"], hashlib.sha256(
                executable.read_bytes()
            ).hexdigest())
            self.assertFalse(build["holdout_accessed"])
            gated_output = root / "gated-self-test"
            gated_output.mkdir()
            gate_read, gate_write = os.pipe()
            environment = dict(os.environ)
            environment["MIRMIR_EXECUTION_GATE_FD"] = str(gate_read)
            process = subprocess.Popen(
                [
                    str(executable),
                    "self-test",
                    "--output-directory",
                    str(gated_output),
                ],
                pass_fds=(gate_read,),
                env=environment,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            os.close(gate_read)
            try:
                with self.assertRaises(subprocess.TimeoutExpired):
                    process.wait(timeout=0.1)
                self.assertEqual(list(gated_output.iterdir()), [])
                self.assertEqual(os.write(gate_write, b"\xA5"), 1)
                os.close(gate_write)
                gate_write = -1
                stdout, stderr = process.communicate(timeout=30)
            finally:
                if gate_write >= 0:
                    os.close(gate_write)
                if process.poll() is None:
                    process.kill()
                    process.wait(timeout=30)
            self.assertEqual(
                process.returncode,
                0,
                stderr.decode("utf-8", "replace"),
            )
            gated_document = json.loads(stdout.decode("utf-8"))
            self.assertFalse(gated_document["holdout_accessed"])
            rejected_output = root / "rejected-gate-self-test"
            rejected_output.mkdir()
            rejected_read, rejected_write = os.pipe()
            rejected_environment = dict(os.environ)
            rejected_environment["MIRMIR_EXECUTION_GATE_FD"] = str(
                rejected_read
            )
            rejected = subprocess.Popen(
                [
                    str(executable),
                    "self-test",
                    "--output-directory",
                    str(rejected_output),
                ],
                pass_fds=(rejected_read,),
                env=rejected_environment,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            os.close(rejected_read)
            self.assertEqual(os.write(rejected_write, b"\x00"), 1)
            os.close(rejected_write)
            _, rejected_stderr = rejected.communicate(timeout=30)
            self.assertNotEqual(rejected.returncode, 0)
            self.assertIn(b"invalid command arguments", rejected_stderr)
            self.assertEqual(list(rejected_output.iterdir()), [])

    def test_loader_execution_gate_precedes_command_line_access(self) -> None:
        source = (
            Path(__file__).resolve().parents[3]
            / "validation/calibration_v2/p07/P07HoldoutFrameLoader.swift"
        ).read_text(encoding="utf-8")
        main = source.index("static func main() async")
        gate = source.index("try waitForMirmirExecutionGate()", main)
        umask = source.index("Darwin.umask(0o077)", main)
        arguments = source.index("CommandLine.arguments", main)
        self.assertLess(gate, umask)
        self.assertLess(umask, arguments)
        gate_function = source[
            source.index("private func waitForMirmirExecutionGate") : main
        ]
        self.assertIn("errno == EINTR", gate_function)
        self.assertIn("authorization == 0xA5", gate_function)

    def test_retained_authorized_file_rejects_named_path_replacement(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            executable = root / "authorized-tool"
            executable.write_bytes(b"original")
            executable.chmod(0o700)
            retained = _RetainedAuthorizedFile.open(
                executable,
                expected_sha256=hashlib.sha256(b"original").hexdigest(),
                executable=True,
                label="synthetic authorized tool",
            )
            try:
                displaced = root / "displaced-tool"
                executable.rename(displaced)
                executable.write_bytes(b"replacement")
                executable.chmod(0o700)
                with self.assertRaisesRegex(
                    P07ExecutionError,
                    "retained or named identity changed",
                ):
                    retained.verify()
            finally:
                retained.close()

    def test_mount_observation_parser_rejects_ambiguous_records(self) -> None:
        mount_root = Path("/private/tmp/synthetic-holdout")
        read_only = P07HoldoutExecutor._mount_observation_from_output(
            mount_root,
            b"/dev/disk9 on /private/tmp/synthetic-holdout (apfs, read-only)\n",
        )
        self.assertTrue(read_only.mounted)
        self.assertTrue(read_only.read_only)
        with self.assertRaisesRegex(
            P07ExecutionError,
            "multiple mount records",
        ):
            P07HoldoutExecutor._mount_observation_from_output(
                mount_root,
                (
                    b"/dev/disk9 on /private/tmp/synthetic-holdout "
                    b"(apfs, read-only)\n"
                    b"/dev/disk10 on /private/tmp/synthetic-holdout "
                    b"(apfs, read-only)\n"
                ),
            )
        with self.assertRaisesRegex(P07ExecutionError, "ambiguous"):
            P07HoldoutExecutor._mount_observation_from_output(
                mount_root,
                b"not-a-device on /private/tmp/synthetic-holdout (apfs)\n",
            )

    def test_direct_mount_template_preserves_attested_line_continuations(self) -> None:
        holdout_root = Path("/synthetic/holdout")
        mount_payload = b"""#!/bin/zsh
set -euo pipefail

root=${0:A:h:h}
container="$root/container/holdout.sparsebundle"
mount_point="$root/mount-v2"
key_helper="$root/tools/bin/key-access"

[[ -d "$container" ]]
[[ -x "$key_helper" ]]
if /sbin/mount | /usr/bin/grep -Fq " on $mount_point "; then
  print -u2 'holdout volume is already mounted'
  exit 1
fi
/bin/mkdir -p "$mount_point"
"$key_helper" emit-v2 | /usr/bin/hdiutil attach \\
  "$container" \\
  -stdinpass \\
  -readonly \\
  -nobrowse \\
  -mountpoint "$mount_point"
/sbin/mount | /usr/bin/grep -F " on $mount_point "
"""
        unmount_payload = b"""#!/bin/zsh
set -euo pipefail

root=${0:A:h:h}
mount_point="$root/mount-v2"
device=$(/sbin/mount | /usr/bin/awk -v target="$mount_point" '$0 ~ " on " target " " {print $1}')
[[ -n "$device" ]]
/usr/bin/hdiutil detach "$device"
if /sbin/mount | /usr/bin/grep -Fq " on $mount_point "; then
  print -u2 'holdout volume remains mounted'
  exit 1
fi
"""

        def script_binding(payload: bytes, label: str) -> object:
            script = SimpleNamespace(
                identity=SimpleNamespace(st_size=len(payload)),
                label=label,
                read_prefix=lambda maximum: payload[:maximum],
            )
            return SimpleNamespace(
                script=script,
                interpreter=SimpleNamespace(
                    file=SimpleNamespace(path=Path("/bin/zsh"))
                ),
            )

        executor = object.__new__(P07HoldoutExecutor)
        executor.holdout_root = holdout_root
        digest = executor._validate_direct_mount_script_contract(
            preflight=SimpleNamespace(
                attestation={
                    "container": {
                        "relative_path": "container/holdout.sparsebundle"
                    }
                },
                mount_root=holdout_root / "mount-v2",
                workflow_paths={
                    "key_helper_path": holdout_root / "tools/bin/key-access"
                },
            ),
            mount_script=script_binding(mount_payload, "mount template"),
            unmount_script=script_binding(
                unmount_payload,
                "unmount template",
            ),
        )
        self.assertEqual(
            digest,
            hashlib.sha256(
                b"mount\x00"
                + mount_payload
                + b"\x00unmount\x00"
                + unmount_payload
            ).hexdigest(),
        )

    def test_authorized_mount_uses_secret_kernel_pipeline_and_exact_bindings(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            holdout_root = Path(temporary).resolve()
            container = holdout_root / "container" / "holdout.sparsebundle"
            mount_root = holdout_root / "mount-v2"
            container.mkdir(parents=True)
            mount_root.mkdir()
            key_helper_path = holdout_root / "key-access"
            hdiutil_path = holdout_root / "hdiutil"
            key_helper_path.write_bytes(b"key-helper")
            hdiutil_path.write_bytes(b"hdiutil")
            key_descriptor = os.open(key_helper_path, os.O_RDONLY)
            hdiutil_descriptor = os.open(hdiutil_path, os.O_RDONLY)
            try:
                verification_calls: list[str] = []
                key_identity = {"identifier": "synthetic-key"}
                hdiutil_identity = {"identifier": "synthetic-hdiutil"}
                context = SimpleNamespace(
                    key_helper=SimpleNamespace(
                        file=SimpleNamespace(
                            path=key_helper_path,
                            descriptor=key_descriptor,
                        ),
                        code_identity=key_identity,
                    ),
                    hdiutil=SimpleNamespace(
                        file=SimpleNamespace(
                            path=hdiutil_path,
                            descriptor=hdiutil_descriptor,
                        ),
                        code_identity=hdiutil_identity,
                    ),
                    mount_script=SimpleNamespace(script=object()),
                    unmount_script=SimpleNamespace(script=object()),
                    direct_mount_template_sha256=_digest("template"),
                    verify=lambda: verification_calls.append("verify"),
                )
                executor = object.__new__(P07HoldoutExecutor)
                executor.holdout_root = holdout_root
                executor._required_authorized_execution_context = lambda: context
                preflight = SimpleNamespace(
                    attestation={
                        "container": {
                            "relative_path": "container/holdout.sparsebundle"
                        }
                    },
                    mount_root=mount_root,
                )
                authorizations: list[tuple[int, object]] = []
                pipeline_result = SimpleNamespace(
                    producer_returncode=0,
                    producer_stderr=b"",
                    consumer_returncode=0,
                    consumer_stdout=b"attached\n",
                    consumer_stderr=b"",
                )

                def run_pipeline(
                    producer_command: list[str],
                    consumer_command: list[str],
                    **kwargs: object,
                ) -> object:
                    self.assertEqual(
                        producer_command,
                        [str(key_helper_path), "emit-v2"],
                    )
                    self.assertEqual(
                        consumer_command,
                        [
                            str(hdiutil_path),
                            "attach",
                            str(container),
                            "-stdinpass",
                            "-readonly",
                            "-nobrowse",
                            "-mountpoint",
                            str(mount_root),
                        ],
                    )
                    self.assertEqual(
                        kwargs["producer_pass_fds"],
                        (key_descriptor,),
                    )
                    self.assertEqual(
                        kwargs["consumer_pass_fds"],
                        (hdiutil_descriptor,),
                    )
                    self.assertEqual(kwargs["max_output_bytes"], 1024 * 1024)
                    self.assertEqual(kwargs["timeout_seconds"], 300.0)
                    self.assertEqual(
                        kwargs["producer_authorized_environment"],
                        {
                            "LANG": "C",
                            "LC_ALL": "C",
                            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                            "TMPDIR": "/private/tmp",
                        },
                    )
                    self.assertEqual(
                        kwargs["consumer_authorized_environment"],
                        kwargs["producer_authorized_environment"],
                    )
                    kwargs["producer_execution_authorizer"](101)
                    kwargs["consumer_execution_authorizer"](202)
                    return pipeline_result

                with mock.patch.object(
                    execution_module,
                    "run_authorized_pipeline",
                    side_effect=run_pipeline,
                ), mock.patch.object(
                    execution_module,
                    "authorize_running_code",
                    side_effect=lambda pid, identity: authorizations.append(
                        (pid, identity)
                    ),
                ), mock.patch.object(
                    execution_module,
                    "_direct_mount_template_sha256",
                    return_value=context.direct_mount_template_sha256,
                ):
                    executor._authorized_mount(preflight)
                self.assertEqual(
                    authorizations,
                    [(101, key_identity), (202, hdiutil_identity)],
                )
                self.assertEqual(verification_calls, ["verify", "verify"])
                self.assertFalse(hasattr(pipeline_result, "producer_stdout"))
            finally:
                os.close(key_descriptor)
                os.close(hdiutil_descriptor)

    def test_loader_uses_retained_plan_output_and_mount_descriptors(self) -> None:
        executor = object.__new__(P07HoldoutExecutor)
        sampling = SimpleNamespace(descriptor=41)
        loader = object()
        context = SimpleNamespace(
            loader=loader,
            sampling_plan=sampling,
        )
        executor._required_authorized_execution_context = lambda: context
        calls: list[tuple[object, tuple[str, ...], dict[str, object]]] = []

        def run_binding(
            binding: object,
            arguments: tuple[str, ...],
            **kwargs: object,
        ) -> subprocess.CompletedProcess[bytes]:
            calls.append((binding, arguments, kwargs))
            return subprocess.CompletedProcess([], 0, b"{}", b"")

        executor._run_authorized_binding = run_binding
        executor._validate_extraction = lambda **kwargs: {"validated": True}
        preflight = SimpleNamespace(plan_file_sha256=_digest("plan"))
        self.assertEqual(
            executor._run_extraction(
                preflight=preflight,
                output_descriptor=43,
                mount_descriptor=47,
            ),
            {"validated": True},
        )
        self.assertEqual(len(calls), 1)
        binding, arguments, kwargs = calls[0]
        self.assertIs(binding, loader)
        self.assertEqual(
            arguments,
            (
                "extract",
                "--plan-fd",
                "41",
                "--plan-sha256",
                preflight.plan_file_sha256,
                "--mount-root",
                ".",
                "--output-directory-fd",
                "43",
            ),
        )
        self.assertEqual(kwargs["cwd_descriptor"], 47)
        self.assertEqual(kwargs["additional_files"], (sampling,))
        self.assertEqual(kwargs["additional_descriptors"], (43,))

    def test_restart_mount_recovery_prepares_persisted_authorized_closure(self) -> None:
        executor = object.__new__(P07HoldoutExecutor)
        executor.holdout_root = Path("/private/tmp/synthetic-holdout-root")
        executor.repository_root = Path("/private/tmp/synthetic-repository")
        executor._transaction_context = {}
        order: list[str] = []
        observations = iter(
            (
                SimpleNamespace(mounted=True),
                SimpleNamespace(mounted=False),
            )
        )
        executor._prepare_authorized_execution_from_intent = (
            lambda intent: order.append("prepare")
        )
        executor._authorized_observe_mount = lambda mount_root: (
            order.append("observe") or next(observations)
        )
        executor._authorized_unmount = lambda mount_root: order.append("unmount")
        executor._support_aware_release_validation = lambda: order.append("release")
        executor._validate_cache_isolation = lambda: order.append("cache")
        executor._recover_mount_from_intent({"direct_input_bindings": []})
        self.assertEqual(
            order,
            ["prepare", "observe", "unmount", "observe", "release", "cache"],
        )
        self.assertEqual(
            executor._transaction_context["cleanup_result"]["status"],
            "passed",
        )

    def test_preopen_cache_tree_hash_detects_mutation_and_rejects_symlink(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            cache = root / "cache"
            nested = cache / "nested"
            nested.mkdir(parents=True)
            (nested / "evidence.json").write_text("{}\n", encoding="utf-8")
            first = _directory_tree_sha256(cache, "synthetic P07 cache")
            self.assertEqual(
                first,
                _directory_tree_sha256(cache, "synthetic P07 cache"),
            )
            (nested / "evidence.json").write_text(
                '{"changed":true}\n',
                encoding="utf-8",
            )
            self.assertNotEqual(
                first,
                _directory_tree_sha256(cache, "synthetic P07 cache"),
            )
            (cache / "unsafe-link").symlink_to(nested / "evidence.json")
            with self.assertRaisesRegex(P07ExecutionError, "symbolic link"):
                _directory_tree_sha256(cache, "synthetic P07 cache")

    def test_output_overlap_is_rejected_before_guard_intent(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            executor = object.__new__(P07HoldoutExecutor)
            executor.p07_cache_root = root / "preopen-cache"
            executor.p06_release_root = root / "p06-release"
            executor.holdout_root = root / "holdout"
            executor.support_evidence_roots = {
                "support": root / "support",
            }
            ledger_root = root / "ledger-root"
            anchor_root = root / "anchor-root"
            for directory in (
                executor.p07_cache_root,
                executor.p06_release_root,
                executor.holdout_root,
                executor.holdout_root / "mount-v2",
                *executor.support_evidence_roots.values(),
                ledger_root,
                anchor_root,
            ):
                directory.mkdir(parents=True, exist_ok=True)
            executor.live_holdout_preopen_binding = SimpleNamespace(
                live_ledger_path=ledger_root / "holdout-access-ledger.json",
                live_anchor_path=anchor_root / "holdout-access-anchor.json",
                live_preopen_receipt_path=anchor_root / "preopen-receipt.json",
            )
            guard = _CountingGuard()
            with self.assertRaisesRegex(P07ExecutionError, "overlaps protected"):
                executor.execute_once(
                    configuration_lock={},
                    guard=guard,
                    evaluator=lambda *arguments: {},
                    output_directory=executor.p07_cache_root / "publication",
                )
            self.assertEqual(guard.calls, 0)

    def test_output_isolation_allows_sibling_but_rejects_inside_or_ancestor(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            artifacts = root / "Artifacts" / "ASH"
            artifacts.mkdir(parents=True)
            executor = object.__new__(P07HoldoutExecutor)
            executor.p07_cache_root = root / "cache"
            executor.p06_release_root = artifacts / "p06"
            executor.holdout_root = root / "holdout"
            executor.support_evidence_roots = {
                "support": root / "support",
            }
            ledger_root = root / "ledger"
            anchor_root = root / "anchor"
            for directory in (
                executor.p07_cache_root,
                executor.p06_release_root,
                executor.holdout_root,
                executor.holdout_root / "mount-v2",
                *executor.support_evidence_roots.values(),
                ledger_root,
                anchor_root,
            ):
                directory.mkdir(parents=True, exist_ok=True)
            executor.live_holdout_preopen_binding = SimpleNamespace(
                live_ledger_path=ledger_root / "ledger.json",
                live_anchor_path=anchor_root / "anchor.json",
                live_preopen_receipt_path=anchor_root / "receipt.json",
            )
            executor._validate_output_isolation(artifacts / "p07")
            with self.assertRaisesRegex(P07ExecutionError, "overlaps protected"):
                executor._validate_output_isolation(artifacts)
            with self.assertRaisesRegex(P07ExecutionError, "overlaps protected"):
                executor._validate_output_isolation(
                    executor.p06_release_root / "p07"
                )

    def test_runtime_publication_is_required_and_cross_linked(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            complete = root / "complete"
            _minimal_publication(complete)
            executor = object.__new__(P07HoldoutExecutor)
            with mock.patch(
                "validation.calibration_v2.p07.execution._validate_schema"
            ), mock.patch(
                "validation.calibration_v2.p07.execution._validate_runtime_case_records"
            ):
                bindings = executor._validate_publication(complete)
            self.assertIn("p07-runtime-evidence.json", bindings)

            missing = root / "missing"
            shutil.copytree(complete, missing)
            (missing / "p07-runtime-evidence.json").unlink()
            with mock.patch(
                "validation.calibration_v2.p07.execution._validate_schema"
            ), mock.patch(
                "validation.calibration_v2.p07.execution._validate_runtime_case_records"
            ):
                with self.assertRaisesRegex(P07ExecutionError, "file set"):
                    executor._validate_publication(missing)

            tampered = root / "tampered"
            shutil.copytree(complete, tampered)
            runtime_path = tampered / "p07-runtime-evidence.json"
            runtime = json.loads(runtime_path.read_text(encoding="utf-8"))
            runtime["configuration_sha256"] = _digest("tampered-runtime")
            _write_canonical(runtime_path, runtime)
            with mock.patch(
                "validation.calibration_v2.p07.execution._validate_schema"
            ), mock.patch(
                "validation.calibration_v2.p07.execution._validate_runtime_case_records"
            ):
                with self.assertRaisesRegex(
                    P07ExecutionError,
                    "artifact-manifest|runtime evidence",
                ):
                    executor._validate_publication(tampered)

            substituted = root / "substituted"
            shutil.copytree(complete, substituted)
            runtime_path = substituted / "p07-runtime-evidence.json"
            runtime = json.loads(runtime_path.read_text(encoding="utf-8"))
            runtime["substitution_marker"] = True
            runtime["manifest_sha256"] = canonical_sha256(
                {
                    key: value
                    for key, value in runtime.items()
                    if key != "manifest_sha256"
                }
            )
            _write_canonical(runtime_path, runtime)
            with mock.patch(
                "validation.calibration_v2.p07.execution._validate_schema"
            ), mock.patch(
                "validation.calibration_v2.p07.execution._validate_runtime_case_records"
            ):
                with self.assertRaisesRegex(
                    P07ExecutionError,
                    "artifact-manifest|runtime evidence",
                ):
                    executor._validate_publication(substituted)

    def test_rehashed_manifest_top_level_contradiction_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            publication = root / "publication"
            _minimal_publication(publication)
            manifest_path = publication / "artifact-manifest.json"
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            manifest["configuration_sha256"] = _digest("contradictory-config")
            manifest["manifest_sha256"] = canonical_sha256(
                {
                    key: value
                    for key, value in manifest.items()
                    if key != "manifest_sha256"
                }
            )
            _write_canonical(manifest_path, manifest)
            executor = object.__new__(P07HoldoutExecutor)
            with mock.patch(
                "validation.calibration_v2.p07.execution._validate_schema"
            ), mock.patch(
                "validation.calibration_v2.p07.execution."
                "_validate_runtime_case_records"
            ):
                with self.assertRaisesRegex(
                    P07ExecutionError,
                    "invalid or stale",
                ):
                    executor._validate_publication(publication)

    def test_authorized_execution_substitution_is_rejected_after_rehash(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            publication = root / "publication"
            _minimal_publication(publication)
            authorized_path = publication / "authorized-execution-bindings.json"
            authorized = json.loads(authorized_path.read_text(encoding="utf-8"))
            authorized["loader"]["code_identity"]["identifier"] = (
                "org.mirmir.synthetic.substituted-loader"
            )
            authorized["manifest_sha256"] = _manifest_hash(authorized)
            _write_canonical(authorized_path, authorized)
            (publication / "artifact-manifest.json").unlink()
            _write_artifact_manifest(
                publication,
                status="complete",
                publication_kind="g07_evidence",
                configuration_id="synthetic-p07-v1",
                configuration_sha256=_digest("publication-configuration"),
                release_bundle_manifest_sha256=_digest("publication-release"),
                sampling_plan_manifest_sha256=_digest("publication-sampling"),
                holdout_accessed=True,
                holdout_access_consumed=True,
                command="python3 -m pytest test_p07_execution.py",
                platform="synthetic macOS arm64",
            )
            executor = object.__new__(P07HoldoutExecutor)
            with mock.patch(
                "validation.calibration_v2.p07.execution._validate_schema"
            ), mock.patch(
                "validation.calibration_v2.p07.execution."
                "_validate_runtime_case_records"
            ):
                with self.assertRaisesRegex(
                    P07ExecutionError,
                    "invalid or stale",
                ):
                    executor._validate_publication(publication)

    def test_terminal_recovery_rejects_rehashed_production_fd_role_substitution(self) -> None:
        with tempfile.TemporaryDirectory(dir="/private/tmp") as temporary:
            root = Path(temporary).resolve()
            release_bundle, paths = _static_production_fragment_inputs(root)
            holdout = root / "holdout"
            holdout.mkdir()
            (holdout / "mount-v2").mkdir()
            support_roots = {
                identifier: root / "support" / identifier
                for identifier in SUPPORT_ROOT_IDS
            }
            for path in support_roots.values():
                path.mkdir(parents=True, exist_ok=True)
            support_roots["production_writer"] = paths["writer_support"]
            live = root / "live"
            live.mkdir()
            executor = P07HoldoutExecutor(
                repository_root=paths["repository"],
                holdout_root=holdout,
                sampling_plan_path=paths["repository"] / "sampling-plan.json",
                expected_sampling_plan_sha256=_digest("sampling-plan"),
                no_pixel_attestation_path=paths["repository"] / "no-pixel.json",
                expected_no_pixel_attestation_sha256=_digest("no-pixel"),
                loader_executable=paths["cache"] / "loader",
                expected_loader_sha256=_digest("loader"),
                p06_release_root=paths["release"],
                p06_release_manifest_path=(
                    paths["release"] / "p06-release-bundle.json"
                ),
                support_evidence_roots=support_roots,
                p07_cache_root=paths["cache"],
                live_holdout_preopen_binding=SimpleNamespace(
                    live_ledger_path=live / "ledger.json",
                    live_anchor_path=live / "anchor.json",
                    live_preopen_receipt_path=live / "receipt.json",
                ),
                release_validator=lambda **unused: release_bundle,
            )
            executor._required_authorized_execution_context = lambda: object()
            current = executor._current_production_execution_fragment()
            substituted = copy.deepcopy(current)
            substituted["retained_fd_roles"]["production_swift"][0][
                "sha256"
            ] = _digest("substituted-production-input")
            substituted["fragment_sha256"] = _manifest_hash(
                substituted,
                field="fragment_sha256",
            )
            with self.assertRaisesRegex(
                P07ExecutionError,
                "production execution fragment differs",
            ):
                executor._validate_terminal_authorized_execution_closure(
                    authorized_document={
                        "production_execution_binding_fragment": substituted
                    },
                    terminal_document={
                        "release_bundle_manifest_sha256": release_bundle[
                            "manifest_sha256"
                        ]
                    },
                )
            descriptor = getattr(executor, "_p07_cache_descriptor", None)
            if isinstance(descriptor, int):
                os.close(descriptor)
                executor._p07_cache_descriptor = None

    def test_workspace_rejects_rehashed_production_fragment_against_current_files(self) -> None:
        with tempfile.TemporaryDirectory(dir="/private/tmp") as temporary:
            root = Path(temporary).resolve()
            release_bundle, paths = _static_production_fragment_inputs(root)
            holdout = root / "holdout"
            (holdout / "mount-v2").mkdir(parents=True)
            support_roots = {
                identifier: root / "support" / identifier
                for identifier in SUPPORT_ROOT_IDS
            }
            for path in support_roots.values():
                path.mkdir(parents=True, exist_ok=True)
            support_roots["production_writer"] = paths["writer_support"]
            live = root / "live"
            live.mkdir()
            live_binding = SimpleNamespace(
                live_ledger_path=live / "ledger.json",
                live_anchor_path=live / "anchor.json",
                live_preopen_receipt_path=live / "receipt.json",
                expected_live_ledger_root_identity_sha256=_digest(
                    "ledger-root"
                ),
                expected_live_anchor_root_identity_sha256=_digest(
                    "anchor-root"
                ),
                expected_live_preopen_receipt_sha256=_digest("receipt"),
            )
            sampling_path = paths["repository"] / "sampling-plan.json"
            corpus_path = paths["repository"] / "corpus-lock.json"
            no_pixel_path = paths["repository"] / "no-pixel.json"
            loader_path = paths["cache"] / "loader"
            unmount_path = holdout / "unmount.sh"
            corpus_core = {"artifact_kind": "synthetic-corpus-lock"}
            corpus = {
                **corpus_core,
                "manifest_sha256": canonical_sha256(corpus_core),
            }
            sampling_core = {
                "corpus_manifest_sha256": corpus["manifest_sha256"]
            }
            sampling = {
                **sampling_core,
                "manifest_sha256": canonical_sha256(sampling_core),
            }
            _write_canonical(corpus_path, corpus)
            _write_canonical(sampling_path, sampling)
            no_pixel_path.write_text("{}\n", encoding="utf-8")
            loader_path.write_bytes(b"synthetic-loader")
            unmount_path.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            executor = P07HoldoutExecutor(
                repository_root=paths["repository"],
                holdout_root=holdout,
                sampling_plan_path=sampling_path,
                expected_sampling_plan_sha256=hashlib.sha256(
                    sampling_path.read_bytes()
                ).hexdigest(),
                no_pixel_attestation_path=no_pixel_path,
                expected_no_pixel_attestation_sha256=hashlib.sha256(
                    no_pixel_path.read_bytes()
                ).hexdigest(),
                loader_executable=loader_path,
                expected_loader_sha256=hashlib.sha256(
                    loader_path.read_bytes()
                ).hexdigest(),
                p06_release_root=paths["release"],
                p06_release_manifest_path=(
                    paths["release"] / "p06-release-bundle.json"
                ),
                support_evidence_roots=support_roots,
                p07_cache_root=paths["cache"],
                live_holdout_preopen_binding=live_binding,
                release_validator=lambda **unused: release_bundle,
            )
            current = executor._current_production_execution_fragment()
            substituted = copy.deepcopy(current)
            substituted["retained_fd_roles"]["production_writer"][1][
                "sha256"
            ] = _digest("substituted-writer-settings-source")
            substituted["fragment_sha256"] = _manifest_hash(
                substituted,
                field="fragment_sha256",
            )
            authorized = _synthetic_authorized_execution_bindings(
                release_manifest_sha256=str(
                    release_bundle["manifest_sha256"]
                )
            )
            authorized["loader"] = {
                **authorized["loader"],
                "path": os.fspath(loader_path),
                "file_sha256": hashlib.sha256(
                    loader_path.read_bytes()
                ).hexdigest(),
            }
            authorized["loader"]["code_identity"]["file_sha256"] = (
                authorized["loader"]["file_sha256"]
            )
            authorized["sampling_plan"] = {
                "path": os.fspath(sampling_path),
                "file_sha256": hashlib.sha256(
                    sampling_path.read_bytes()
                ).hexdigest(),
            }
            authorized["unmount_script"]["path"] = os.fspath(unmount_path)
            authorized["unmount_script"]["file_sha256"] = hashlib.sha256(
                unmount_path.read_bytes()
            ).hexdigest()
            authorized["production_execution_binding_fragment"] = substituted
            authorized["manifest_sha256"] = _manifest_hash(authorized)
            configuration_lock = json.loads(
                (paths["release"] / "configuration-lock.json").read_text(
                    encoding="utf-8"
                )
            )
            corpus_payload = corpus_path.read_bytes()
            intent = {
                "requested_output_directory": os.fspath(root / "output"),
                "configuration_id": release_bundle["configuration_id"],
                "configuration_sha256": canonical_sha256(configuration_lock),
                "release_bundle_manifest_sha256": release_bundle[
                    "manifest_sha256"
                ],
                "input_bundle_sha256": release_bundle["input_bundle_sha256"],
                "corpus_lock_bundle_sha256": release_bundle[
                    "corpus_lock_bundle_sha256"
                ],
                "sampling_plan_file_sha256": hashlib.sha256(
                    sampling_path.read_bytes()
                ).hexdigest(),
                "sampling_plan_manifest_sha256": sampling["manifest_sha256"],
                "corpus_manifest_sha256": corpus["manifest_sha256"],
                "no_pixel_attestation_file_sha256": hashlib.sha256(
                    no_pixel_path.read_bytes()
                ).hexdigest(),
                "loader_executable_sha256": hashlib.sha256(
                    loader_path.read_bytes()
                ).hexdigest(),
                "unmount_script_path": os.fspath(unmount_path),
                "unmount_script_sha256": hashlib.sha256(
                    unmount_path.read_bytes()
                ).hexdigest(),
                "live_ledger_path": os.fspath(live_binding.live_ledger_path),
                "live_anchor_path": os.fspath(live_binding.live_anchor_path),
                "live_preopen_receipt_path": os.fspath(
                    live_binding.live_preopen_receipt_path
                ),
                "expected_live_ledger_root_identity_sha256": (
                    live_binding.expected_live_ledger_root_identity_sha256
                ),
                "expected_live_anchor_root_identity_sha256": (
                    live_binding.expected_live_anchor_root_identity_sha256
                ),
                "expected_live_preopen_receipt_sha256": (
                    live_binding.expected_live_preopen_receipt_sha256
                ),
                "direct_input_bindings": [
                    {
                        "id": "corpus_lock",
                        "path": corpus_path.relative_to(
                            paths["repository"]
                        ).as_posix(),
                        "sha256": hashlib.sha256(corpus_payload).hexdigest(),
                        "size_bytes": len(corpus_payload),
                    }
                ],
                "authorized_execution_bindings": authorized,
            }
            executor._validate_guard_binding = lambda *args, **kwargs: None
            with self.assertRaisesRegex(
                P07ExecutionError,
                "workspace production execution fragment differs",
            ):
                executor._validate_workspace_intent_for_invocation(
                    workspace=SimpleNamespace(intent=intent),
                    output_directory=root / "output",
                    configuration_lock=configuration_lock,
                    guard=object(),
                )
            descriptor = getattr(executor, "_p07_cache_descriptor", None)
            if isinstance(descriptor, int):
                os.close(descriptor)
                executor._p07_cache_descriptor = None

    def test_pre_guard_binding_captures_canonical_production_fragment(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = self._fixture(
                Path(temporary).resolve(),
                archive_failure=False,
            )
            release_sha256 = fixture.preflight.release_bundle[
                "manifest_sha256"
            ]
            fragment = _synthetic_production_execution_fragment(
                release_manifest_sha256=release_sha256
            )
            verification_calls = 0

            class FakeContext:
                production_execution_binding_fragment = None

                def verify(self) -> None:
                    nonlocal verification_calls
                    verification_calls += 1

                def binding_document(self) -> object:
                    document = _synthetic_authorized_execution_bindings(
                        release_manifest_sha256=release_sha256
                    )
                    document[
                        "production_execution_binding_fragment"
                    ] = self.production_execution_binding_fragment
                    document["manifest_sha256"] = _manifest_hash(document)
                    return document

            context = FakeContext()
            executor = object.__new__(P07HoldoutExecutor)
            executor._required_authorized_execution_context = lambda: context
            captured = executor._bind_production_execution_fragment(
                preflight=fixture.preflight,
                evaluator=SimpleNamespace(
                    authorized_execution_binding_fragment=fragment
                ),
            )
            self.assertEqual(verification_calls, 1)
            self.assertEqual(
                captured.authorized_execution_bindings[
                    "production_execution_binding_fragment"
                ],
                fragment,
            )
            self.assertEqual(
                executor._persisted_production_execution_binding_fragment,
                fragment,
            )

    def test_contextual_failure_persists_asset_case_frame_and_pts(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            fixture = self._fixture(root, archive_failure=False)
            executor = fixture.executor
            executor._transaction_context = {
                "phase": "authorized_evaluation",
                "guard_returned": False,
                "publication_validated": False,
                "publication_renamed": False,
                "parent_directory_synced": False,
                "cleanup_result": {
                    "status": "passed",
                    "mount_invoked": True,
                    "mount_detached": True,
                    "support_revalidation": "passed",
                },
                "temporary_run_path": os.fspath(root / "transaction"),
            }
            contextual = P07ContextualError(
                "injected contextual evaluator failure",
                media_context=P07MediaContext(
                    asset_id="asset-context",
                    case_id="corpus:asset-context:compression",
                    frame_index=7,
                    presentation_timestamp={"value": 1001, "timescale": 30000},
                ),
            )
            executor._capture_error_media_context(contextual)
            evidence = executor._guard_access_evidence(
                fixture.guard,
                known_consumed=True,
                configuration_sha256=canonical_sha256(fixture.configuration),
            )
            output = root / "contextual-failure"
            executor._publish_failure(
                output_directory=output,
                preflight=fixture.preflight,
                configuration_lock=fixture.configuration,
                error=contextual,
                failure_stage="guard_or_authorized_execution",
                access_evidence=evidence,
            )
            archive = json.loads(
                (output / "failed-version-archive.json").read_text(
                    encoding="utf-8"
                )
            )
            self.assertEqual(archive["media_asset_id"], "asset-context")
            self.assertEqual(
                archive["media_case_id"],
                "corpus:asset-context:compression",
            )
            self.assertEqual(archive["frame_index"], 7)
            self.assertEqual(
                archive["presentation_timestamp"],
                {"value": 1001, "timescale": 30000},
            )

    def test_dual_failure_archive_preserves_both_tracebacks(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            fixture = self._fixture(root, archive_failure=False)
            try:
                raise ValueError("primary evaluation detail")
            except ValueError as primary:
                try:
                    raise OSError("cleanup unmount detail")
                except OSError as cleanup:
                    dual = P07DualFailure(primary, cleanup)
            fixture.executor._transaction_context = {
                "phase": "mount_cleanup_and_revalidation",
                "guard_returned": False,
                "publication_validated": False,
                "publication_renamed": False,
                "parent_directory_synced": False,
                "cleanup_result": {
                    "status": "failed",
                    "mount_invoked": True,
                    "mount_detached": False,
                    "support_revalidation": "failed",
                },
            }
            evidence = fixture.executor._guard_access_evidence(
                fixture.guard,
                known_consumed=True,
                configuration_sha256=canonical_sha256(fixture.configuration),
            )
            output = root / "dual-failure"
            fixture.executor._publish_failure(
                output_directory=output,
                preflight=fixture.preflight,
                configuration_lock=fixture.configuration,
                error=dual,
                failure_stage="guard_or_authorized_execution",
                access_evidence=evidence,
            )
            archive = json.loads(
                (output / "failed-version-archive.json").read_text(
                    encoding="utf-8"
                )
            )
            self.assertEqual(archive["failure_type"], "ValueError")
            self.assertIn("primary evaluation detail", archive["failure_traceback"])
            self.assertEqual(
                archive["secondary_failure"]["failure_type"],
                "OSError",
            )
            self.assertIn(
                "cleanup unmount detail",
                archive["secondary_failure"]["failure_traceback"],
            )

    def test_artifact_manifest_rejects_extra_or_changed_file(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            publication = root / "publication"
            _minimal_publication(publication)
            bindings = _validate_artifact_manifest(
                publication,
                expected_status="complete",
                expected_publication_kind="g07_evidence",
            )
            self.assertEqual(set(bindings), set(path.name for path in publication.iterdir()))

            (publication / "unexpected.json").write_text("{}\n", encoding="utf-8")
            with self.assertRaisesRegex(P07ExecutionError, "exact file set"):
                _validate_artifact_manifest(
                    publication,
                    expected_status="complete",
                    expected_publication_kind="g07_evidence",
                )

    def test_exclusive_publication_preserves_existing_destination(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            transaction = root / "transaction"
            transaction.mkdir()
            source = transaction / "publication"
            source.mkdir()
            (source / "source.json").write_text("{}\n", encoding="utf-8")
            destination = root / "published"
            destination.mkdir()
            (destination / "competitor.json").write_text(
                '{"owner":"competitor"}\n',
                encoding="utf-8",
            )

            with self.assertRaises(FileExistsError):
                _publish_directory_exclusive(source, destination)

            self.assertTrue((source / "source.json").is_file())
            self.assertEqual(
                (destination / "competitor.json").read_text(encoding="utf-8"),
                '{"owner":"competitor"}\n',
            )

    def test_destination_creation_race_cannot_replace_competitor(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            transaction = root / "transaction"
            transaction.mkdir()
            source = transaction / "publication"
            source.mkdir()
            (source / "source.json").write_text("{}\n", encoding="utf-8")
            destination = root / "published"
            original = _rename_directory_exclusive_at

            def racing_rename(
                source_parent: int,
                source_name: str,
                destination_parent: int,
                destination_name: str,
            ) -> None:
                os.mkdir(destination_name, 0o700, dir_fd=destination_parent)
                descriptor = os.open(
                    destination_name,
                    os.O_RDONLY | os.O_DIRECTORY,
                    dir_fd=destination_parent,
                )
                try:
                    marker = os.open(
                        "competitor.json",
                        os.O_WRONLY | os.O_CREAT | os.O_EXCL,
                        0o600,
                        dir_fd=descriptor,
                    )
                    os.write(marker, b'{"owner":"competitor"}\n')
                    os.close(marker)
                finally:
                    os.close(descriptor)
                original(
                    source_parent,
                    source_name,
                    destination_parent,
                    destination_name,
                )

            with mock.patch(
                "validation.calibration_v2.p07.execution."
                "_rename_directory_exclusive_at",
                side_effect=racing_rename,
            ):
                with self.assertRaises(FileExistsError):
                    _publish_directory_exclusive(source, destination)

            self.assertTrue((source / "source.json").is_file())
            self.assertEqual(
                (destination / "competitor.json").read_bytes(),
                b'{"owner":"competitor"}\n',
            )

    def test_publication_syncs_every_file_and_directory(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            transaction = root / "transaction"
            transaction.mkdir()
            source = transaction / "publication"
            nested = source / "nested"
            nested.mkdir(parents=True)
            (source / "root.json").write_text("{}\n", encoding="utf-8")
            (nested / "nested.json").write_text("{}\n", encoding="utf-8")
            destination = root / "published"
            synchronized_modes: list[int] = []
            real_fsync = os.fsync

            def recording_fsync(descriptor: int) -> None:
                synchronized_modes.append(os.fstat(descriptor).st_mode)
                real_fsync(descriptor)

            with mock.patch(
                "validation.calibration_v2.p07.execution.os.fsync",
                side_effect=recording_fsync,
            ):
                _publish_directory_exclusive(source, destination)

            self.assertGreaterEqual(
                sum(stat.S_ISREG(mode) for mode in synchronized_modes),
                2,
            )
            self.assertGreaterEqual(
                sum(stat.S_ISDIR(mode) for mode in synchronized_modes),
                4,
            )
            self.assertTrue((destination / "nested" / "nested.json").is_file())

    def test_file_sync_failure_occurs_before_exclusive_rename(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            transaction = root / "transaction"
            transaction.mkdir()
            source = transaction / "publication"
            source.mkdir()
            (source / "evidence.json").write_text("{}\n", encoding="utf-8")
            destination = root / "published"
            real_fsync = os.fsync

            def failing_fsync(descriptor: int) -> None:
                if stat.S_ISREG(os.fstat(descriptor).st_mode):
                    raise OSError("injected file fsync failure")
                real_fsync(descriptor)

            with mock.patch(
                "validation.calibration_v2.p07.execution.os.fsync",
                side_effect=failing_fsync,
            ):
                with self.assertRaisesRegex(OSError, "injected file fsync"):
                    _publish_directory_exclusive(source, destination)

            self.assertTrue((source / "evidence.json").is_file())
            self.assertFalse(destination.exists())

    def test_publication_snapshot_rejects_file_mutation_before_rename(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            transaction = root / "transaction"
            transaction.mkdir()
            source = transaction / "publication"
            source.mkdir()
            (source / "evidence.json").write_text("{}\n", encoding="utf-8")
            destination = root / "published"
            from validation.calibration_v2.p07 import execution as execution_module

            original = execution_module._sync_descriptor_tree_durable

            def mutate_after_sync(descriptor: int, label: str) -> None:
                original(descriptor, label)
                child = os.open(
                    "evidence.json",
                    os.O_WRONLY | os.O_TRUNC,
                    dir_fd=descriptor,
                )
                try:
                    os.write(child, b'{"changed":true}\n')
                    os.fsync(child)
                finally:
                    os.close(child)

            with mock.patch(
                "validation.calibration_v2.p07.execution."
                "_sync_descriptor_tree_durable",
                side_effect=mutate_after_sync,
            ):
                with self.assertRaisesRegex(P07ExecutionError, "tree changed"):
                    _publish_directory_exclusive(source, destination)
            self.assertFalse(destination.exists())
            self.assertTrue(source.exists())

    def test_publication_snapshot_rejects_nested_symlink_and_directory_swap(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            transaction = root / "transaction"
            transaction.mkdir()
            source = transaction / "publication"
            nested = source / "nested"
            nested.mkdir(parents=True)
            (nested / "evidence.json").write_text("{}\n", encoding="utf-8")
            (source / "unsafe").symlink_to(nested, target_is_directory=True)
            with self.assertRaisesRegex(P07ExecutionError, "symbolic link"):
                _publish_directory_exclusive(source, root / "symlink-output")
            (source / "unsafe").unlink()

            from validation.calibration_v2.p07 import execution as execution_module

            original = execution_module._sync_descriptor_tree_durable

            def swap_after_sync(descriptor: int, label: str) -> None:
                original(descriptor, label)
                os.rename(
                    "nested",
                    "nested-original",
                    src_dir_fd=descriptor,
                    dst_dir_fd=descriptor,
                )
                os.mkdir("nested", 0o700, dir_fd=descriptor)

            with mock.patch(
                "validation.calibration_v2.p07.execution."
                "_sync_descriptor_tree_durable",
                side_effect=swap_after_sync,
            ):
                with self.assertRaisesRegex(P07ExecutionError, "tree changed"):
                    _publish_directory_exclusive(source, root / "swapped-output")
            self.assertFalse((root / "swapped-output").exists())

    def test_post_parent_sync_snapshot_detects_published_child_change(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            transaction = root / "transaction"
            transaction.mkdir()
            source = transaction / "publication"
            source.mkdir()
            (source / "evidence.json").write_text("{}\n", encoding="utf-8")
            destination = root / "published"
            original = _snapshot_descriptor_tree

            def mutate_before_final_snapshot(
                descriptor: int,
                label: str,
            ) -> object:
                if label == "P07 durable published tree":
                    child = os.open(
                        "evidence.json",
                        os.O_WRONLY | os.O_TRUNC,
                        dir_fd=descriptor,
                    )
                    try:
                        os.write(child, b'{"late":true}\n')
                        os.fsync(child)
                    finally:
                        os.close(child)
                return original(descriptor, label)

            with mock.patch(
                "validation.calibration_v2.p07.execution."
                "_snapshot_descriptor_tree",
                side_effect=mutate_before_final_snapshot,
            ):
                with self.assertRaisesRegex(
                    P07ExecutionError,
                    "changed after parent durability sync",
                ):
                    _publish_directory_exclusive(source, destination)
            self.assertTrue(destination.is_dir())

    def test_pinned_output_parent_replacement_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            output_parent = root / "output-parent"
            output_parent.mkdir()
            parent_descriptor, parent_identity = _open_directory_nofollow(
                output_parent,
                "test output parent",
            )
            transaction = root / "transaction"
            transaction.mkdir()
            source = transaction / "publication"
            source.mkdir()
            (source / "evidence.json").write_text("{}\n", encoding="utf-8")
            original_parent = root / "original-output-parent"
            output_parent.rename(original_parent)
            output_parent.mkdir()
            try:
                with self.assertRaisesRegex(P07ExecutionError, "identity changed"):
                    _publish_directory_exclusive(
                        source,
                        output_parent / "published",
                        destination_parent_pin=(parent_descriptor, parent_identity),
                    )
            finally:
                os.close(parent_descriptor)
            self.assertTrue(source.exists())
            self.assertFalse((output_parent / "published").exists())

    def test_sigkill_leaves_recognized_durable_pre_guard_transaction(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            output = root / "p07-output"
            script = r'''
import os
import signal
import sys
import uuid
from pathlib import Path
from validation.calibration_v2.p07.execution import (
    _P07TransactionWorkspace,
    _manifest_hash,
    _open_directory_nofollow,
)
root = Path(sys.argv[1]).resolve()
output = Path(sys.argv[2]).resolve()
digest = "1" * 64
intent = {
    "schema_version": "1.0.0",
    "artifact_kind": "p07_durable_transaction_intent",
    "transaction_id": str(uuid.uuid4()),
    "transaction_state": "pre_guard",
    "requested_output_directory": str(output),
    "configuration_id": "synthetic-sigkill",
    "configuration_sha256": digest,
    "release_bundle_manifest_sha256": digest,
    "input_bundle_sha256": digest,
    "corpus_lock_bundle_sha256": digest,
    "corpus_manifest_sha256": digest,
    "sampling_plan_file_sha256": digest,
    "sampling_plan_manifest_sha256": digest,
    "no_pixel_attestation_file_sha256": digest,
    "outer_wrapper_file_sha256": digest,
    "outer_wrapper_manifest_sha256": digest,
    "loader_executable_sha256": digest,
    "authorized_execution_bindings": None,
    "p07_preopen_cache_tree_sha256": digest,
    "inner_inventory_sha256": digest,
    "direct_input_bindings": [{
        "id": "synthetic",
        "path": "input.json",
        "sha256": digest,
        "size_bytes": 1,
    }],
    "unmount_script_path": str(root / "unmount.sh"),
    "unmount_script_sha256": digest,
    "live_ledger_path": str(root / "ledger.json"),
    "live_anchor_path": str(root / "anchor.json"),
    "live_preopen_receipt_path": str(root / "receipt.json"),
    "expected_live_ledger_root_identity_sha256": digest,
    "expected_live_anchor_root_identity_sha256": digest,
    "expected_live_preopen_receipt_sha256": digest,
    "command": "synthetic SIGKILL transaction",
    "platform": "synthetic-test-platform",
}
intent["manifest_sha256"] = _manifest_hash(intent)
parent_fd, parent_identity = _open_directory_nofollow(root, "test parent")
workspace, created = _P07TransactionWorkspace.open_or_create(
    output_directory=output,
    parent_descriptor=parent_fd,
    parent_identity=parent_identity,
    intent=intent,
)
assert created
os.kill(os.getpid(), signal.SIGKILL)
'''
            completed = subprocess.run(
                [sys.executable, "-c", script, str(root), str(output)],
                cwd=Path(__file__).resolve().parents[3],
                check=False,
                capture_output=True,
                timeout=30,
            )
            self.assertEqual(completed.returncode, -9, completed.stderr.decode())
            parent_descriptor, parent_identity = _open_directory_nofollow(
                root,
                "test recovery parent",
            )
            workspace = _P07TransactionWorkspace.open_existing(
                output_directory=output,
                parent_descriptor=parent_descriptor,
                parent_identity=parent_identity,
            )
            self.assertIsNotNone(workspace)
            assert workspace is not None
            self.assertEqual(
                workspace.intent["transaction_state"],
                "pre_guard",
            )
            workspace.destroy()
            os.close(parent_descriptor)

    def test_sigkill_after_anchor_before_ledger_transition_is_consumed(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            script = r'''
import os
import signal
import stat
import sys
from pathlib import Path
from validation.calibration_v2.tests.test_p07_execution import (
    P07ExecutionFailureTests,
    _digest,
    _ledger_event,
    _write_canonical,
)
from validation.quality.src.mirmir_quality.json_tools import canonical_sha256
root = Path(sys.argv[1]).resolve()
fixture = P07ExecutionFailureTests()._fixture(root, archive_failure=False)
configuration_sha256 = canonical_sha256(fixture.configuration)
corpus_sha256 = _digest("corpus")
sealed_event = _ledger_event(
    0,
    "sealed",
    "0" * 64,
    {"corpus_manifest_sha256": corpus_sha256},
)
ledger = {
    "schema_version": "1.0.0",
    "corpus_manifest_sha256": corpus_sha256,
    "state": "sealed",
    "open_intent_utc": None,
    "opened_utc": None,
    "completed_utc": None,
    "events": [sealed_event],
}
_write_canonical(fixture.guard.ledger_path, ledger)
ledger_descriptor = os.open(fixture.guard.ledger_path, os.O_RDONLY)
os.fsync(ledger_descriptor)
os.close(ledger_descriptor)
anchor = {
    "schema_version": "1.0.0",
    "artifact_kind": "holdout_access_anchor",
    "corpus_manifest_sha256": corpus_sha256,
    "configuration_sha256": configuration_sha256,
    "open_intent_utc": "2026-07-11T00:00:01Z",
    "persistence": "macos-user-immutable-v1",
    "threat_boundary": "synthetic-test",
}
_write_canonical(fixture.guard.anchor_path, anchor)
anchor_descriptor = os.open(fixture.guard.anchor_path, os.O_RDONLY)
os.fsync(anchor_descriptor)
os.close(anchor_descriptor)
os.chflags(fixture.guard.anchor_path, stat.UF_IMMUTABLE)
parent_descriptor = os.open(root, os.O_RDONLY)
os.fsync(parent_descriptor)
os.close(parent_descriptor)
os.kill(os.getpid(), signal.SIGKILL)
'''
            completed = subprocess.run(
                [sys.executable, "-c", script, str(root)],
                cwd=Path(__file__).resolve().parents[3],
                check=False,
                capture_output=True,
                timeout=30,
            )
            self.assertEqual(completed.returncode, -9, completed.stderr.decode())
            fixture = self._fixture(root, archive_failure=False)
            try:
                evidence = fixture.executor._guard_access_evidence(
                    fixture.guard,
                    known_consumed=None,
                    configuration_sha256=canonical_sha256(
                        fixture.configuration
                    ),
                )
                self.assertTrue(evidence["holdout_access_consumed"])
                self.assertEqual(evidence["holdout_access_state"], "anchor_only")
                self.assertEqual(
                    evidence["holdout_access_evidence_source"],
                    "anchor_only_guard_evidence",
                )
                self.assertFalse(evidence["holdout_access_open_intent_linked"])
                output = root / "anchor-only-failure"
                fixture.executor._publish_failure(
                    output_directory=output,
                    preflight=fixture.preflight,
                    configuration_lock=fixture.configuration,
                    error=P07ExecutionError("synthetic interrupted transition"),
                    failure_stage="restart_recovery",
                    access_evidence=evidence,
                )
                archive = json.loads(
                    (output / "failed-version-archive.json").read_text(
                        encoding="utf-8"
                    )
                )
                artifact = json.loads(
                    (output / "artifact-manifest.json").read_text(
                        encoding="utf-8"
                    )
                )
                self.assertTrue(archive["holdout_access_consumed"])
                self.assertEqual(archive["holdout_access_state"], "anchor_only")
                self.assertTrue(artifact["holdout_accessed"])
                _validate_failure_publication(output)
            finally:
                fixture.guard.unseal()

    def test_sigkill_during_opened_extraction_recovers_without_raw_crop(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            output = root / "p07-output"
            script = r'''
import json
import os
import signal
import sys
from pathlib import Path
from validation.calibration_v2.tests.test_p07_execution import (
    P07ExecutionFailureTests,
    _CompletedGuard,
    _completed_ledger,
    _write_canonical,
)
from validation.calibration_v2.p07 import execution as execution_module
from validation.quality.src.mirmir_quality.json_tools import canonical_sha256
root = Path(sys.argv[1]).resolve()
output = Path(sys.argv[2]).resolve()
fixture = P07ExecutionFailureTests()._fixture(root, archive_failure=False)
execution_module.corpus_lock_bundle_sha256 = (
    lambda bound: fixture.preflight.corpus_lock_bundle_sha256
)

class KillingGuard(_CompletedGuard):
    def read_once(self, configuration, loader):
        self.calls += 1
        _completed_ledger(
            self.ledger_path,
            self.anchor_path,
            canonical_sha256(configuration),
            seal_anchor=True,
        )
        ledger = json.loads(self.ledger_path.read_text(encoding="utf-8"))
        ledger["events"] = ledger["events"][:3]
        ledger["state"] = "opened"
        ledger["completed_utc"] = None
        _write_canonical(self.ledger_path, ledger)
        return loader()

guard = KillingGuard(fixture.guard.ledger_path, fixture.guard.anchor_path)

def kill_during_extraction(**kwargs):
    extraction = kwargs["extraction_directory"]
    (extraction / "interrupted-crop.nv12").write_bytes(b"raw-holdout-crop")
    os.kill(os.getpid(), signal.SIGKILL)

fixture.executor._authorized_evaluation = kill_during_extraction
fixture.executor.execute_once(
    configuration_lock=fixture.configuration,
    guard=guard,
    evaluator=lambda *arguments: {},
    output_directory=output,
)
'''
            completed = subprocess.run(
                [sys.executable, "-c", script, str(root), str(output)],
                cwd=Path(__file__).resolve().parents[3],
                check=False,
                capture_output=True,
                timeout=30,
            )
            self.assertEqual(completed.returncode, -9, completed.stderr.decode())
            self.assertTrue(any(root.rglob("*.nv12")))
            fixture = self._fixture(root, archive_failure=False)
            with self.assertRaisesRegex(
                P07ExecutionError,
                "ended after the one-use guard entered state opened",
            ):
                fixture.executor.execute_once(
                    configuration_lock=fixture.configuration,
                    guard=fixture.guard,
                    evaluator=lambda *arguments: {},
                    output_directory=output,
                )
            self.assertEqual(fixture.guard.calls, 0)
            self.assertFalse(any(root.rglob("*.nv12")))
            _validate_failure_publication(output)
            fixture.guard.unseal()

    def test_sigkill_around_success_rename_recovers_without_second_guard(self) -> None:
        for boundary in ("before_rename", "after_rename", "after_parent_fsync"):
            with self.subTest(boundary=boundary), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary).resolve()
                output = root / "p07-output"
                script = r'''
import os
import signal
import sys
from pathlib import Path
from validation.calibration_v2.p07 import execution as execution_module
from validation.calibration_v2.tests.test_p07_execution import (
    P07ExecutionFailureTests,
    _SyntheticSuccessExecutor,
)
root = Path(sys.argv[1]).resolve()
output = Path(sys.argv[2]).resolve()
boundary = sys.argv[3]
fixture = P07ExecutionFailureTests()._fixture(root, archive_failure=False)
executor = _SyntheticSuccessExecutor(
    preflight=fixture.preflight,
    configuration_path=fixture.executor.configuration_path,
    archive_failure=False,
)
executor.ledger_path = fixture.guard.ledger_path
execution_module.corpus_lock_bundle_sha256 = (
    lambda bound: fixture.preflight.corpus_lock_bundle_sha256
)
if boundary == "before_rename":
    execution_module._publish_directory_exclusive = (
        lambda *args, **kwargs: os.kill(os.getpid(), signal.SIGKILL)
    )
elif boundary == "after_rename":
    original = execution_module._rename_directory_exclusive_at
    def kill_after_rename(*args, **kwargs):
        original(*args, **kwargs)
        os.kill(os.getpid(), signal.SIGKILL)
    execution_module._rename_directory_exclusive_at = kill_after_rename
else:
    original = execution_module._snapshot_descriptor_tree
    def kill_after_parent_fsync(descriptor, label):
        if label == "P07 durable published tree":
            os.kill(os.getpid(), signal.SIGKILL)
        return original(descriptor, label)
    execution_module._snapshot_descriptor_tree = kill_after_parent_fsync
executor.execute_once(
    configuration_lock=fixture.configuration,
    guard=fixture.guard,
    evaluator=lambda *arguments: {},
    output_directory=output,
)
'''
                completed = subprocess.run(
                    [
                        sys.executable,
                        "-c",
                        script,
                        str(root),
                        str(output),
                        boundary,
                    ],
                    cwd=Path(__file__).resolve().parents[3],
                    check=False,
                    capture_output=True,
                    timeout=30,
                )
                self.assertEqual(
                    completed.returncode,
                    -9,
                    completed.stderr.decode(),
                )
                fixture = self._fixture(root, archive_failure=False)
                executor = _SyntheticSuccessExecutor(
                    preflight=fixture.preflight,
                    configuration_path=fixture.executor.configuration_path,
                    archive_failure=False,
                )
                executor.ledger_path = fixture.guard.ledger_path
                with mock.patch(
                    "validation.calibration_v2.p07.execution."
                    "corpus_lock_bundle_sha256",
                    return_value=fixture.preflight.corpus_lock_bundle_sha256,
                ):
                    result = executor.execute_once(
                        configuration_lock=fixture.configuration,
                        guard=fixture.guard,
                        evaluator=lambda *arguments: {},
                        output_directory=output,
                    )
                self.assertEqual(fixture.guard.calls, 0)
                self.assertEqual(result["status"], "complete")
                self.assertTrue(output.is_dir())
                self.assertFalse(any(root.glob(".p07-transaction-*")))
                self.assertFalse(any(root.rglob("*.nv12")))
                fixture.guard.unseal()


if __name__ == "__main__":
    unittest.main()
