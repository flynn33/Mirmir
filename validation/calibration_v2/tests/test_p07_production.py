from __future__ import annotations

import copy
import json
import os
from pathlib import Path
import select
import signal
from types import SimpleNamespace
import tempfile
from typing import Mapping
import unittest
from unittest.mock import MagicMock, patch

import numpy as np

from validation.calibration_v2.native_adapter.factory import (
    NativeConfiguration,
    NativeExecutable,
)
from validation.calibration_v2.p07.production import (
    P07LockedReleaseInputs,
    P07ProductionError,
    P07ProductionEvaluator,
    _RetainedCacheDirectory,
    _adapter_lifetime,
    _append_compile_journal,
    _archive_completed_compiler_transaction,
    _close_adapter,
    _compiler_journal_event,
    _configuration_hashes,
    _corpus_media_context,
    _corpus_metrics,
    _make_release_adapter,
    _profile_matrix,
    _quarantine_interrupted_compiler_transaction,
    _read_compile_journal,
    _selected_aliases,
    _tree_snapshot,
    _validate_loader_verification,
    _validate_route_lut_semantics,
    _validate_selected_vector_runtime,
    derive_production_authorized_execution_binding_fragment,
)
from validation.calibration_v2.production_providers import (
    production_writer_settings_document,
)
from validation.calibration_v2.release_evidence import evidence_binding
from validation.calibration_v2.p07.execution import (
    P07DualFailure,
    _directory_file_snapshot,
)
from validation.calibration_v2.production_evaluator import (
    fixed_control_request,
)
from validation.calibration_v2.runner import (
    candidate_vector_sha256,
)
from validation.calibration_v2.tools.run_p07_locked_holdout import (
    _validate_cache_before_write,
    _validate_cache_output_isolation,
    _validate_source_tree_direction,
    _run_selected_mode,
)
from validation.quality.src.mirmir_quality.arrays import PlanarFrame
from validation.quality.src.mirmir_quality.json_tools import canonical_sha256
from validation.quality.src.mirmir_quality.json_tools import manifest_sha256
from validation.quality.src.mirmir_quality.json_tools import validate_schema


REPOSITORY_ROOT = Path(__file__).resolve().parents[3]


def _kill_child_at_checkpoint(
    pid: int,
    read_descriptor: int,
    expected: bytes,
) -> None:
    reaped = False
    try:
        readable, _, _ = select.select([read_descriptor], [], [], 10.0)
        if not readable:
            raise AssertionError("child did not reach crash checkpoint")
        observed = os.read(read_descriptor, 4096)
        if observed != expected:
            raise AssertionError(
                "child crash checkpoint differs: {!r}".format(observed)
            )
        os.kill(pid, signal.SIGKILL)
        _, status = os.waitpid(pid, 0)
        reaped = True
        if not os.WIFSIGNALED(status) or os.WTERMSIG(status) != signal.SIGKILL:
            raise AssertionError("child did not terminate by literal SIGKILL")
    finally:
        if not reaped:
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            try:
                os.waitpid(pid, 0)
            except ChildProcessError:
                pass
        os.close(read_descriptor)


def _digest(value: object) -> str:
    return canonical_sha256({"value": value})


def _self_hashed(document: dict[str, object]) -> dict[str, object]:
    result = copy.deepcopy(document)
    result["manifest_sha256"] = canonical_sha256(result)
    return result


def _profiles() -> list[dict[str, object]]:
    return [
        {
            "id": "{}-{}".format(route, kind),
            "target_route": route,
            "kind": kind,
        }
        for route in ("direct-2x", "direct-3over2")
        for kind in (
            "lowpass_decimate",
            "camera_blur_decimate",
            "codec_quantized_proxy",
        )
    ]


def _loader_record() -> dict[str, object]:
    build = _self_hashed(
        {
            "schema_version": "1.0.0",
            "artifact_kind": "p07_holdout_frame_loader_build",
            "status": "pass",
            "source_path": "validation/calibration_v2/p07/P07HoldoutFrameLoader.swift",
            "source_sha256": _digest("loader-source"),
            "executable_sha256": _digest("loader-executable"),
            "compiler_version": "synthetic-swiftc",
            "command": ["xcrun", "swiftc", "<output>"],
            "mach_o_uuid": "1" * 32,
            "mach_o_uuid_contract": (
                "sha256_first_128_bits_after_zeroing_lc_uuid_rfc4122_v3_variant"
            ),
            "code_signing": "deterministic_ad_hoc_fixed_identifier_no_timestamp",
            "code_signing_identifier": "local.mirmir.p07-holdout-frame-loader",
            "holdout_accessed": False,
        }
    )
    self_test = _self_hashed(
        {
            "schema_version": "1.0.0",
            "artifact_kind": "p07_holdout_frame_loader_self_test",
            "status": "pass",
            "input_dimensions": {"width": 328, "height": 196},
            "crop": {"x": 2, "y": 2, "width": 324, "height": 192},
            "nv12_size_bytes": 93_312,
            "nv12_sha256": _digest("self-test"),
            "repeat_byte_identical": True,
            "presentation_order_monotonicity_checked": True,
            "midpoint_tie_selects_first": True,
            "descending_presentation_time_rejected": True,
            "holdout_accessed": False,
        }
    )
    return {
        "build": build,
        "reproducibility_build": copy.deepcopy(build),
        "builds_byte_identical": True,
        "self_tests": [self_test, copy.deepcopy(self_test)],
        "self_tests_byte_identical": True,
    }


def _write_canonical_json(path: Path, document: Mapping[str, object]) -> bytes:
    payload = json.dumps(
        document,
        ensure_ascii=False,
        allow_nan=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8") + b"\n"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(payload)
    return payload


def _synthetic_code_identity(
    payload: bytes,
    *,
    identifier: str,
    cdhash_character: str,
) -> dict[str, object]:
    return {
        "schema_version": "1.0.0",
        "artifact_kind": "macos_code_identity_v1",
        "architecture": "arm64",
        "file_sha256": __import__("hashlib").sha256(payload).hexdigest(),
        "unique_cdhash": cdhash_character * 40,
        "all_cdhashes": [cdhash_character * 40],
        "digest_algorithms": [2],
        "static_code_flags": 2,
        "signing_kind": "ad_hoc",
        "identifier": identifier,
    }


def _build_fragment_derivation_fixture(root: Path) -> dict[str, object]:
    release_root = root / "release"
    repository_root = root / "repository"
    writer_support_root = root / "writer-support"
    writer_root = writer_support_root / "writer-tree"
    cache_root = root / "cache"
    for directory in (
        release_root,
        repository_root,
        writer_root,
        cache_root,
    ):
        directory.mkdir(parents=True)

    native_path = release_root / "bin" / "ash-calibration-cli"
    native_source_path = (
        release_root
        / "sources"
        / "production-swift-source-manifest.json"
    )
    writer_path = writer_root / "production-writer"
    p00_path = (
        cache_root
        / "current-source-extra-parity"
        / "p00"
        / ("d" * 64)
        / "ash-p00-control-cli"
    )
    media_types_path = (
        repository_root
        / "Mirmir"
        / "Modules"
        / "MediaPipeline"
        / "MediaTypes.swift"
    )
    executable_payloads = {
        native_path: b"synthetic-native-mach-o",
        writer_path: b"synthetic-writer-mach-o",
        p00_path: b"synthetic-p00-mach-o",
    }
    for path, payload in executable_payloads.items():
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(payload)
        os.chmod(path, 0o700)
    native_source_path.parent.mkdir(parents=True, exist_ok=True)
    native_source_path.write_bytes(b"synthetic-native-source-manifest")
    media_types_path.parent.mkdir(parents=True, exist_ok=True)
    media_types_path.write_bytes(b"synthetic-media-types-source")

    identities = {
        "production_swift_executable": _synthetic_code_identity(
            executable_payloads[native_path],
            identifier="local.synthetic.native",
            cdhash_character="a",
        ),
        "production_writer_executable": _synthetic_code_identity(
            executable_payloads[writer_path],
            identifier="local.synthetic.writer",
            cdhash_character="b",
        ),
        "p00_native_executable": _synthetic_code_identity(
            executable_payloads[p00_path],
            identifier="local.synthetic.p00",
            cdhash_character="c",
        ),
    }
    source_sha256 = __import__("hashlib").sha256(
        native_source_path.read_bytes()
    ).hexdigest()
    writer_source_sha256 = __import__("hashlib").sha256(
        media_types_path.read_bytes()
    ).hexdigest()
    writer_settings_sha256 = canonical_sha256(
        production_writer_settings_document(
            executable_sha256=str(
                identities["production_writer_executable"]["file_sha256"]
            ),
            product_settings_source_sha256=writer_source_sha256,
        )
    )
    selected_vector_sha256 = _digest("selected-vector")
    configuration_id = "synthetic-configuration"
    documents: dict[str, tuple[str, object]] = {
        "calibration_selection": (
            "calibration-selection.json",
            {"selected_vector_sha256": selected_vector_sha256},
        ),
        "selected_evaluation": (
            "selected-evaluation.json",
            {"writer_settings_sha256": writer_settings_sha256},
        ),
        "locked_mapping": (
            "locked-mapping.json",
            {"configuration_id": configuration_id},
        ),
        "locked_operator_bank": (
            "locked-operator-bank.json",
            {"configuration_id": configuration_id},
        ),
        "locked_compiler_input": (
            "locked-compiler-input.json",
            {"hash_bindings": {"compiler_inputs_sha256": _digest("compiler")}},
        ),
        "lut_manifest": (
            "lut-manifest.json",
            {"compiler_input": {"path": "locked-compiler-input.json"}, "routes": []},
        ),
        "configuration_lock": (
            "configuration-lock.json",
            {"configuration_id": configuration_id},
        ),
        "direct2x_lut": ("direct2x.ashlut", b"direct-2x-lut"),
        "direct3over2_lut": ("direct3over2.ashlut", b"direct-3over2-lut"),
    }
    artifact_rows = []
    for identifier, (relative, value) in documents.items():
        path = release_root / relative
        payload = (
            _write_canonical_json(path, value)
            if isinstance(value, dict)
            else bytes(value)
        )
        if not isinstance(value, dict):
            path.write_bytes(payload)
        artifact_rows.append(
            {
                "id": identifier,
                "path": relative,
                "sha256": __import__("hashlib").sha256(payload).hexdigest(),
                "size_bytes": len(payload),
            }
        )

    writer_tree = evidence_binding(
        identifier="production_writer_tree",
        root_id="production_writer",
        path=writer_root,
        root=writer_support_root,
    )
    implementations = [
        evidence_binding(
            identifier="production_swift_executable",
            root_id="release",
            path=native_path,
            root=release_root,
        ),
        evidence_binding(
            identifier="production_swift_source_manifest",
            root_id="release",
            path=native_source_path,
            root=release_root,
        ),
    ]
    closure: dict[str, object] = {
        "schema_version": "1.0.0",
        "artifact_kind": "p06_release_evidence_closure",
        "status": "locked_before_p07",
        "configuration_id": configuration_id,
        "input_bundle_sha256": _digest("input-bundle"),
        "corpus_lock_bundle_sha256": _digest("corpus-bundle"),
        "configuration_bindings": [],
        "implementation_artifacts": implementations,
        "macos_code_identities": identities,
        "selected_control_artifacts": [],
        "support_evidence_trees": [writer_tree],
        "test_evidence": [],
        "preserved_failures": [],
        "calibration_run_tree": {},
        "holdout_accessed": False,
    }
    closure["manifest_sha256"] = manifest_sha256(closure)
    closure_path = release_root / "p06-evidence-closure.json"
    closure_payload = _write_canonical_json(closure_path, closure)
    artifact_rows.append(
        {
            "id": "evidence_closure",
            "path": closure_path.name,
            "sha256": __import__("hashlib").sha256(closure_payload).hexdigest(),
            "size_bytes": len(closure_payload),
        }
    )
    bundle: dict[str, object] = {
        "schema_version": "1.0.0",
        "bundle_id": "mirmir-p06-spatial-release-lock-v1",
        "status": "locked_before_p07",
        "configuration_id": configuration_id,
        "input_bundle_sha256": closure["input_bundle_sha256"],
        "corpus_lock_bundle_sha256": closure["corpus_lock_bundle_sha256"],
        "artifacts": artifact_rows,
    }
    bundle["manifest_sha256"] = canonical_sha256(bundle)
    _write_canonical_json(release_root / "p06-release-bundle.json", bundle)

    mapping = documents["locked_mapping"][1]
    compiler_input = documents["locked_compiler_input"][1]
    lut_manifest = documents["lut_manifest"][1]
    configuration_lock = documents["configuration_lock"][1]
    assert isinstance(mapping, dict)
    assert isinstance(compiler_input, dict)
    assert isinstance(lut_manifest, dict)
    assert isinstance(configuration_lock, dict)
    runtime_identity = canonical_sha256(
        {
            "p06_release_bundle_manifest_sha256": bundle["manifest_sha256"],
            "configuration_sha256": canonical_sha256(configuration_lock),
            "selected_vector_sha256": selected_vector_sha256,
            "native_source_manifest_sha256": source_sha256,
        }
    )
    runtime_core = {
        "schema_version": "1.0.0",
        "manifest_id": "mirmir-ash-candidate-route-luts-v1",
        "status": "calibration_candidate",
        "configuration_id": mapping["configuration_id"],
        "compiler_input": lut_manifest["compiler_input"],
        "hash_bindings": compiler_input["hash_bindings"],
        "routes": lut_manifest["routes"],
        "swift_cli": {
            "executable_sha256": identities[
                "production_swift_executable"
            ]["file_sha256"],
            "source_manifest_sha256": source_sha256,
        },
        "native_parity_claimed": False,
    }
    runtime_manifest = {
        **runtime_core,
        "manifest_sha256": canonical_sha256(runtime_core),
    }
    _write_canonical_json(
        cache_root
        / "release-runtime"
        / runtime_identity
        / "release-runtime-envelope.json",
        runtime_manifest,
    )

    def static_identity(path: Path) -> Mapping[str, object]:
        payload_hash = __import__("hashlib").sha256(path.read_bytes()).hexdigest()
        matches = [
            identity
            for identity in identities.values()
            if identity["file_sha256"] == payload_hash
        ]
        if len(matches) != 1:
            raise AssertionError("synthetic static identity is not singular")
        return copy.deepcopy(matches[0])

    return {
        "release_root": release_root,
        "release_bundle": bundle,
        "production_writer_support_root": writer_support_root,
        "repository_root": repository_root,
        "p07_cache_root": cache_root,
        "expected_cache_root_identity": (
            cache_root.stat().st_dev,
            cache_root.stat().st_ino,
        ),
        "closure": closure,
        "closure_path": closure_path,
        "writer_root": writer_root,
        "writer_path": writer_path,
        "p00_path": p00_path,
        "media_types_path": media_types_path,
        "static_identity": static_identity,
    }


def _selective_derivation_schema_validation(
    document: Mapping[str, object],
    schema_path: Path,
) -> None:
    if Path(schema_path).name in {
        "p06-release-bundle-v1.schema.json",
        "p06-evidence-closure-v1.schema.json",
        "candidate-lut-runtime-manifest-v1.schema.json",
    }:
        return
    validate_schema(document, schema_path)


class P07ProductionLockTests(unittest.TestCase):
    def test_selected_vector_runtime_substitution_fails(self) -> None:
        plan = json.loads(
            (REPOSITORY_ROOT / "validation/calibration_v2/contracts/calibration-plan-v1.json")
            .read_text(encoding="utf-8")
        )
        vector = copy.deepcopy(plan["search"]["initial_vector_values"])
        vector_sha256 = candidate_vector_sha256(vector, plan)
        runtime = {
            "candidate_vector": vector,
            "serialized_candidate_vector_sha256": vector_sha256,
        }
        selection = {
            "selected_vector": vector,
            "selected_vector_sha256": vector_sha256,
        }
        evaluation = {
            "candidate_vector_sha256": vector_sha256,
            "runtime_evidence": runtime,
            "adapter_configuration_sha256": canonical_sha256(runtime),
        }
        reopened, digest, reopened_runtime = _validate_selected_vector_runtime(
            plan=plan,
            selection=selection,
            evaluation=evaluation,
        )
        self.assertEqual(reopened, vector)
        self.assertEqual(digest, vector_sha256)
        self.assertEqual(reopened_runtime, runtime)

        forged = copy.deepcopy(selection)
        forged["selected_vector"]["detail_gain_q12"] = 512
        with self.assertRaisesRegex(P07ProductionError, "selected vector"):
            _validate_selected_vector_runtime(
                plan=plan,
                selection=forged,
                evaluation=evaluation,
            )

    def test_release_lut_and_payload_substitutions_fail(self) -> None:
        direct2 = b"direct2"
        direct3 = b"direct3"
        bundle = {
            "artifacts": [
                {
                    "id": "direct2x_lut",
                    "sha256": __import__("hashlib").sha256(direct2).hexdigest(),
                    "size_bytes": len(direct2),
                },
                {
                    "id": "direct3over2_lut",
                    "sha256": __import__("hashlib").sha256(direct3).hexdigest(),
                    "size_bytes": len(direct3),
                },
            ]
        }
        routes = [
            {
                "route": "direct_2x",
                "whole_file_sha256": bundle["artifacts"][0]["sha256"],
                "whole_file_size_bytes": len(direct2),
                "payload_sha256": _digest("payload-2"),
                "luma_coordinate_policy": "source_aligned_rational",
                "chroma_coordinate_policy": "half_pixel_center",
                "analysis_grid_source_step": 1,
            },
            {
                "route": "direct_3_over_2",
                "whole_file_sha256": bundle["artifacts"][1]["sha256"],
                "whole_file_size_bytes": len(direct3),
                "payload_sha256": _digest("payload-3"),
                "luma_coordinate_policy": "half_pixel_center",
                "chroma_coordinate_policy": "source_aligned_rational",
                "analysis_grid_source_step": 2,
            },
        ]
        runtime = {
            "route_luts": {
                "direct-2x": {
                    key: routes[0][key]
                    for key in (
                        "payload_sha256",
                        "luma_coordinate_policy",
                        "chroma_coordinate_policy",
                        "analysis_grid_source_step",
                    )
                },
                "direct-3over2": {
                    key: routes[1][key]
                    for key in (
                        "payload_sha256",
                        "luma_coordinate_policy",
                        "chroma_coordinate_policy",
                        "analysis_grid_source_step",
                    )
                },
            }
        }
        self.assertEqual(
            len(_validate_route_lut_semantics(
                bundle=bundle,
                lut_manifest={"routes": routes},
                selected_runtime=runtime,
            )),
            2,
        )
        forged = copy.deepcopy(runtime)
        forged["route_luts"]["direct-2x"]["payload_sha256"] = _digest("forged")
        with self.assertRaisesRegex(P07ProductionError, "LUT binding"):
            _validate_route_lut_semantics(
                bundle=bundle,
                lut_manifest={"routes": routes},
                selected_runtime=forged,
            )
        for field in ("luma_coordinate_policy", "chroma_coordinate_policy"):
            forged = copy.deepcopy(runtime)
            forged["route_luts"]["direct-2x"][field] = (
                "half_pixel_center"
                if runtime["route_luts"]["direct-2x"][field]
                == "source_aligned_rational"
                else "source_aligned_rational"
            )
            with self.assertRaisesRegex(P07ProductionError, "LUT binding"):
                _validate_route_lut_semantics(
                    bundle=bundle,
                    lut_manifest={"routes": routes},
                    selected_runtime=forged,
                )
        forged_routes = copy.deepcopy(routes)
        forged_routes[1]["whole_file_sha256"] = _digest("forged-whole")
        with self.assertRaisesRegex(P07ProductionError, "LUT binding"):
            _validate_route_lut_semantics(
                bundle=bundle,
                lut_manifest={"routes": forged_routes},
                selected_runtime=runtime,
            )

    def test_control_profile_and_crop_substitutions_fail(self) -> None:
        fixed_document = {"chosen_descriptor_id": 3}
        conventional_document = {"chosen_algorithm_id": "lanczos3-separable-v1"}
        locked = SimpleNamespace(
            fixed_selection={
                "sha256": canonical_sha256(fixed_document),
                "document": fixed_document,
            },
            conventional_selection={
                "sha256": canonical_sha256(conventional_document),
                "document": conventional_document,
            },
            selection={
                "selected_controls": {
                    "best_fixed": {"descriptor_id": 3},
                    "conventional": {"algorithm_id": "lanczos3-separable-v1"},
                }
            },
        )
        self.assertEqual(
            _selected_aliases(locked),
            {
                "best_fixed": "fixed_descriptor_03",
                "conventional": "conventional_lanczos3_separable_v1",
            },
        )
        locked.selection["selected_controls"]["best_fixed"]["descriptor_id"] = 4
        with self.assertRaisesRegex(P07ProductionError, "aliases"):
            _selected_aliases(locked)

        self.assertEqual(len(_profile_matrix({"profiles": _profiles()})), 6)
        duplicate = _profiles() + [copy.deepcopy(_profiles()[0])]
        with self.assertRaisesRegex(P07ProductionError, "not singular"):
            _profile_matrix({"profiles": duplicate})

        instance = object.__new__(P07ProductionEvaluator)
        instance.locked = SimpleNamespace(
            sampling_plan={
                "assets": [
                    {
                        "ordinal": index,
                        "asset_id": "asset-{}".format(index),
                        "source_asset_id": "source-{}".format(index),
                        "source_family_id": "family-{}".format(index),
                        "target_route": "direct-3over2" if index == 0 else "direct-2x",
                        "crop": {"x": 0, "y": 0, "width": 324, "height": 192},
                    }
                    for index in range(3)
                ]
            },
            corpus_lock={
                "assets": [
                    {
                        "split": "holdout",
                        "source_asset_id": "source-{}".format(index),
                        "source_family_id": "family-{}".format(index),
                        "target_routes": ["direct-3over2" if index == 0 else "direct-2x"],
                        "categories": ["synthetic_detail"],
                    }
                    for index in range(3)
                ]
            },
        )
        extraction = {
            "assets": [
                {
                    **copy.deepcopy(instance.locked.sampling_plan["assets"][index]),
                    "crop_nv12_filename": "{:02d}-asset.nv12".format(index),
                    "crop_nv12_sha256": _digest(("crop", index)),
                    "crop_nv12_size_bytes": 93_312,
                    "selected_presentation_time": {
                        "value": index,
                        "timescale": 30,
                    },
                }
                for index in range(3)
            ]
        }
        bindings = instance._source_bindings(extraction)
        self.assertEqual(len(bindings), 3)
        self.assertEqual(bindings[1]["sampling_ordinal"], 1)
        self.assertEqual(
            bindings[1]["selected_presentation_time"],
            {"value": 1, "timescale": 30},
        )
        context = _corpus_media_context(bindings[1], "corpus:source-1:test")
        self.assertEqual(context.asset_id, "asset-1")
        self.assertIsNone(context.frame_index)
        self.assertEqual(
            context.presentation_timestamp,
            {"value": 1, "timescale": 30},
        )
        forged_extraction = copy.deepcopy(extraction)
        forged_extraction["assets"][0]["crop"]["x"] = 2
        with self.assertRaisesRegex(P07ProductionError, "binding differs"):
            instance._source_bindings(forged_extraction)


class P07ProductionRuntimeTests(unittest.TestCase):
    def _derive_fragment_fixture(
        self,
        fixture: Mapping[str, object],
    ) -> Mapping[str, object]:
        with patch(
            "validation.calibration_v2.p07.production.validate_schema",
            side_effect=_selective_derivation_schema_validation,
        ), patch(
            "validation.calibration_v2.p07.production.static_code_identity",
            side_effect=fixture["static_identity"],
        ), patch(
            "validation.calibration_v2.p07.production._run_checked",
            side_effect=AssertionError("pure derivation attempted child execution"),
        ), patch(
            "validation.calibration_v2.p07.production.subprocess.Popen",
            side_effect=AssertionError("pure derivation attempted Popen"),
        ), patch(
            "validation.calibration_v2.p07.production.subprocess.run",
            side_effect=AssertionError("pure derivation attempted subprocess.run"),
        ):
            return derive_production_authorized_execution_binding_fragment(
                release_root=fixture["release_root"],
                release_bundle=fixture["release_bundle"],
                production_writer_support_root=fixture[
                    "production_writer_support_root"
                ],
                repository_root=fixture["repository_root"],
                p07_cache_root=fixture["p07_cache_root"],
                expected_cache_root_identity=fixture[
                    "expected_cache_root_identity"
                ],
            )

    def test_pure_fragment_derivation_matches_pre_guard_property_without_spawn(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory(dir="/private/tmp") as name:
            fixture = _build_fragment_derivation_fixture(Path(name))
            derived = self._derive_fragment_fixture(fixture)

            class FakeInputs:
                def __init__(self, rows):
                    self.values = {
                        row["role"]: SimpleNamespace(record=dict(row))
                        for row in rows
                    }

                def verify(self):
                    return None

            evaluator = object.__new__(P07ProductionEvaluator)
            evaluator.locked = SimpleNamespace(
                evidence_closure={
                    "support_evidence_trees": [
                        copy.deepcopy(
                            derived["production_writer"]["support_tree"]
                        )
                    ]
                },
                macos_code_identities=copy.deepcopy(
                    derived["macos_code_identities"]
                ),
                release_bundle_manifest_sha256=derived[
                    "p06_release_bundle_manifest_sha256"
                ],
            )
            evaluator._cache_guard = SimpleNamespace(
                root_identity=(
                    derived["cache_root_identity"]["device"],
                    derived["cache_root_identity"]["inode"],
                )
            )
            evaluator._retained_native_runtime = SimpleNamespace(
                native_inputs=FakeInputs(
                    derived["retained_fd_roles"]["production_swift"]
                ),
                p00_inputs=FakeInputs(
                    derived["retained_fd_roles"]["p00_native"]
                ),
            )
            evaluator._writer_inputs = FakeInputs(
                derived["retained_fd_roles"]["production_writer"]
            )
            evaluator._expected_writer_settings_sha256 = derived[
                "production_writer"
            ]["settings_sha256"]
            evaluator._writer_settings_source_sha256 = derived[
                "production_writer"
            ]["product_settings_source_sha256"]
            evaluator._runtime_guard = None
            with patch(
                "validation.calibration_v2.p07.production.validate_schema",
                side_effect=_selective_derivation_schema_validation,
            ):
                observed = evaluator.authorized_execution_binding_fragment
            evaluator._retained_native_runtime = None
            evaluator._writer_inputs = None
            evaluator._cache_guard = None
            self.assertEqual(observed, derived)

    def test_pure_fragment_derivation_rejects_cache_and_p00_substitution(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory(dir="/private/tmp") as name:
            fixture = _build_fragment_derivation_fixture(Path(name))
            expected = fixture["expected_cache_root_identity"]
            assert isinstance(expected, tuple)
            fixture["expected_cache_root_identity"] = (
                expected[0],
                expected[1] + 1,
            )
            with self.assertRaisesRegex(
                P07ProductionError,
                "cache-root identity",
            ):
                self._derive_fragment_fixture(fixture)

        for mutation in ("missing", "duplicate"):
            with self.subTest(mutation=mutation):
                with tempfile.TemporaryDirectory(dir="/private/tmp") as name:
                    fixture = _build_fragment_derivation_fixture(Path(name))
                    p00_path = fixture["p00_path"]
                    assert isinstance(p00_path, Path)
                    if mutation == "missing":
                        p00_path.unlink()
                    else:
                        duplicate = (
                            fixture["p07_cache_root"]
                            / "current-source-extra-parity"
                            / "p00"
                            / ("e" * 64)
                            / "ash-p00-control-cli"
                        )
                        duplicate.parent.mkdir(parents=True)
                        duplicate.write_bytes(p00_path.read_bytes())
                        os.chmod(duplicate, 0o700)
                    with self.assertRaisesRegex(
                        P07ProductionError,
                        "P00 executable identity is not singular",
                    ):
                        self._derive_fragment_fixture(fixture)

    def test_pure_fragment_derivation_rejects_release_and_role_substitution(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory(dir="/private/tmp") as name:
            fixture = _build_fragment_derivation_fixture(Path(name))
            substituted = copy.deepcopy(fixture["release_bundle"])
            substituted["terminal_rehash"] = _digest("terminal")
            substituted["manifest_sha256"] = canonical_sha256(
                {
                    key: value
                    for key, value in substituted.items()
                    if key != "manifest_sha256"
                }
            )
            fixture["release_bundle"] = substituted
            with self.assertRaisesRegex(
                P07ProductionError,
                "differs from the release root",
            ):
                self._derive_fragment_fixture(fixture)

        with tempfile.TemporaryDirectory(dir="/private/tmp") as name:
            fixture = _build_fragment_derivation_fixture(Path(name))
            bundle = fixture["release_bundle"]
            assert isinstance(bundle, dict)
            binding = next(
                row
                for row in bundle["artifacts"]
                if row["id"] == "direct2x_lut"
            )
            path = fixture["release_root"] / binding["path"]
            path.write_bytes(b"changed-role-bytes")
            with self.assertRaisesRegex(
                P07ProductionError,
                "artifact bytes changed",
            ):
                self._derive_fragment_fixture(fixture)

    def test_pure_fragment_derivation_rejects_writer_drift_and_duplicate(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory(dir="/private/tmp") as name:
            fixture = _build_fragment_derivation_fixture(Path(name))
            media_types_path = fixture["media_types_path"]
            assert isinstance(media_types_path, Path)
            media_types_path.write_bytes(b"changed-product-settings-source")
            with self.assertRaisesRegex(
                P07ProductionError,
                "production-writer settings differ",
            ):
                self._derive_fragment_fixture(fixture)

        with tempfile.TemporaryDirectory(dir="/private/tmp") as name:
            fixture = _build_fragment_derivation_fixture(Path(name))
            writer_root = fixture["writer_root"]
            assert isinstance(writer_root, Path)
            (writer_root / "tree-drift.txt").write_bytes(b"drift")
            with self.assertRaisesRegex(
                P07ProductionError,
                "support tree differs",
            ):
                self._derive_fragment_fixture(fixture)

        with tempfile.TemporaryDirectory(dir="/private/tmp") as name:
            fixture = _build_fragment_derivation_fixture(Path(name))
            writer_root = fixture["writer_root"]
            writer_path = fixture["writer_path"]
            assert isinstance(writer_root, Path)
            assert isinstance(writer_path, Path)
            duplicate = writer_root / "duplicate-production-writer"
            duplicate.write_bytes(writer_path.read_bytes())
            os.chmod(duplicate, 0o700)
            closure = fixture["closure"]
            assert isinstance(closure, dict)
            closure["support_evidence_trees"] = [
                evidence_binding(
                    identifier="production_writer_tree",
                    root_id="production_writer",
                    path=writer_root,
                    root=fixture["production_writer_support_root"],
                )
            ]
            closure["manifest_sha256"] = manifest_sha256(closure)
            closure_path = fixture["closure_path"]
            assert isinstance(closure_path, Path)
            closure_payload = _write_canonical_json(closure_path, closure)
            bundle = fixture["release_bundle"]
            assert isinstance(bundle, dict)
            closure_binding = next(
                row
                for row in bundle["artifacts"]
                if row["id"] == "evidence_closure"
            )
            closure_binding["sha256"] = __import__("hashlib").sha256(
                closure_payload
            ).hexdigest()
            closure_binding["size_bytes"] = len(closure_payload)
            bundle["manifest_sha256"] = canonical_sha256(
                {
                    key: value
                    for key, value in bundle.items()
                    if key != "manifest_sha256"
                }
            )
            _write_canonical_json(
                fixture["release_root"] / "p06-release-bundle.json",
                bundle,
            )
            with self.assertRaisesRegex(
                P07ProductionError,
                "production-writer executable identity is not singular",
            ):
                self._derive_fragment_fixture(fixture)

    def test_pure_fragment_derivation_rejects_post_role_read_mutation(
        self,
    ) -> None:
        from validation.calibration_v2.p07 import production as production_module

        with tempfile.TemporaryDirectory(dir="/private/tmp") as name:
            fixture = _build_fragment_derivation_fixture(Path(name))
            media_types_path = fixture["media_types_path"]
            assert isinstance(media_types_path, Path)
            real_builder = (
                production_module._production_authorized_execution_binding_fragment
            )

            def mutate_after_role_read(**kwargs):
                media_types_path.write_bytes(b"post-role-read-mutation")
                return real_builder(**kwargs)

            with patch(
                "validation.calibration_v2.p07.production."
                "_production_authorized_execution_binding_fragment",
                side_effect=mutate_after_role_read,
            ):
                with self.assertRaisesRegex(
                    P07ProductionError,
                    "retained input changed|bound tree changed",
                ):
                    self._derive_fragment_fixture(fixture)

    def test_corpus_metrics_preserve_exact_chroma_and_reject_exact_y(self) -> None:
        yy, xx = np.indices((64, 64), dtype=np.float64)
        target = PlanarFrame(
            y=(xx + yy) / 126.0,
            cb=np.zeros((32, 32), dtype=np.float64),
            cr=np.zeros((32, 32), dtype=np.float64),
        )
        candidate = PlanarFrame(
            y=np.clip(target.y * 0.99 + 0.002, 0.0, 1.0),
            cb=target.cb.copy(),
            cr=target.cr.copy(),
        )
        bundle = _corpus_metrics(
            target,
            candidate,
            writer_y_psnr_contribution_db=None,
        )
        self.assertFalse(bundle["y_psnr_db"]["exact_match"])
        self.assertEqual(
            bundle["cb_psnr_db"],
            {"mse": 0.0, "value": None, "exact_match": True},
        )
        with self.assertRaisesRegex(P07ProductionError, "Y cannot be exact"):
            _corpus_metrics(
                target,
                target,
                writer_y_psnr_contribution_db=None,
            )

    def test_loader_build_and_self_test_substitution_fails(self) -> None:
        record = _loader_record()
        expected = record["build"]["executable_sha256"]
        self.assertEqual(
            _validate_loader_verification(
                record,
                expected_executable_sha256=expected,
            ),
            record,
        )
        forged = copy.deepcopy(record)
        forged["self_tests"][1]["midpoint_tie_selects_first"] = False
        with self.assertRaisesRegex(P07ProductionError, "build/self-test"):
            _validate_loader_verification(
                forged,
                expected_executable_sha256=expected,
            )

    def test_cache_overlap_symlink_and_mutation_are_detected(self) -> None:
        with tempfile.TemporaryDirectory(dir="/private/tmp") as name:
            root = Path(name)
            protected = root / "protected"
            protected.mkdir()
            safe = root / "safe"
            safe.mkdir()
            _validate_cache_before_write(
                cache_root=safe,
                protected_roots=[protected],
            )
            repository = root / "repository"
            repository.mkdir()
            artifact_cache = repository / "Artifacts" / "ASH" / "p07-cache"
            artifact_cache.mkdir(parents=True)
            _validate_cache_before_write(
                cache_root=artifact_cache,
                protected_roots=[protected],
            )
            with self.assertRaisesRegex(ValueError, "strictly outside"):
                _validate_source_tree_direction(
                    cache_root=artifact_cache,
                    source_root=repository,
                )
            _validate_source_tree_direction(
                cache_root=safe,
                source_root=repository,
            )
            _validate_cache_output_isolation(
                cache_root=safe,
                output_directory=root / "publication",
            )
            with self.assertRaisesRegex(ValueError, "overlaps the output"):
                _validate_cache_output_isolation(
                    cache_root=safe,
                    output_directory=safe / "publication",
                )
            nested = protected / "cache"
            nested.mkdir()
            with self.assertRaisesRegex(ValueError, "overlaps"):
                _validate_cache_before_write(
                    cache_root=nested,
                    protected_roots=[protected],
                )
            link = root / "link"
            link.symlink_to(safe, target_is_directory=True)
            with self.assertRaisesRegex(Exception, "symbolic link"):
                _validate_cache_before_write(
                    cache_root=link,
                    protected_roots=[protected],
                )
            (protected / "z.bin").write_bytes(b"root")
            nested_directory = protected / "a"
            nested_directory.mkdir()
            (nested_directory / "x.bin").write_bytes(b"nested")
            before = _tree_snapshot(protected)
            self.assertEqual(
                [row["path"] for row in before["files"]],
                ["a/x.bin", "z.bin"],
            )
            self.assertEqual(
                before,
                _directory_file_snapshot(protected, "test cache"),
            )
            (protected / "changed.bin").write_bytes(b"changed")
            after = _tree_snapshot(protected)
            self.assertNotEqual(before, after)

    def test_retained_cache_rejects_protected_overlap_and_root_symlink(self) -> None:
        with tempfile.TemporaryDirectory(dir="/private/tmp") as name:
            parent = Path(name)
            protected = parent / "protected"
            protected.mkdir()
            nested = protected / "cache"
            nested.mkdir()
            with self.assertRaisesRegex(P07ProductionError, "overlaps"):
                _RetainedCacheDirectory.open(
                    nested,
                    protected_roots=(protected,),
                )

            safe = parent / "safe"
            safe.mkdir()
            link = parent / "cache-link"
            link.symlink_to(safe, target_is_directory=True)
            with self.assertRaisesRegex(P07ProductionError, "symbolic link"):
                _RetainedCacheDirectory.open(link, protected_roots=())

    def test_retained_cache_detects_real_directory_and_symlink_root_swaps(self) -> None:
        for replacement_kind in ("directory", "symlink"):
            with self.subTest(replacement_kind=replacement_kind):
                with tempfile.TemporaryDirectory(dir="/private/tmp") as name:
                    parent = Path(name)
                    cache = parent / "cache"
                    cache.mkdir()
                    guard = _RetainedCacheDirectory.open(
                        cache,
                        protected_roots=(),
                    )
                    try:
                        guard.write_or_verify(cache / "artifact.bin", b"locked")
                        guard.freeze()
                        displaced = parent / "displaced"
                        cache.rename(displaced)
                        if replacement_kind == "directory":
                            cache.mkdir()
                            (cache / "artifact.bin").write_bytes(b"locked")
                        else:
                            cache.symlink_to(displaced, target_is_directory=True)
                        with self.assertRaisesRegex(
                            P07ProductionError,
                            "root.*(identity changed|symbolic link)",
                        ):
                            guard.verify_frozen()
                    finally:
                        guard.close()

    def test_retained_cache_detects_real_directory_and_symlink_child_swaps(self) -> None:
        for replacement_kind in ("directory", "symlink"):
            with self.subTest(replacement_kind=replacement_kind):
                with tempfile.TemporaryDirectory(dir="/private/tmp") as name:
                    parent = Path(name)
                    cache = parent / "cache"
                    child = cache / "child"
                    child.mkdir(parents=True)
                    (child / "artifact.bin").write_bytes(b"locked")
                    guard = _RetainedCacheDirectory.open(
                        cache,
                        protected_roots=(),
                    )
                    try:
                        guard.freeze()
                        displaced = parent / "displaced-child"
                        child.rename(displaced)
                        if replacement_kind == "directory":
                            child.mkdir()
                            (child / "artifact.bin").write_bytes(b"locked")
                        else:
                            child.symlink_to(displaced, target_is_directory=True)
                        with self.assertRaisesRegex(
                            P07ProductionError,
                            "(child identity changed|symbolic link)",
                        ):
                            guard.verify_frozen()
                    finally:
                        guard.close()

    def test_retained_cache_publication_reopen_and_file_substitutions(self) -> None:
        with tempfile.TemporaryDirectory(dir="/private/tmp") as name:
            parent = Path(name)
            cache = parent / "cache"
            cache.mkdir()
            artifact = cache / "artifact.bin"
            guard = _RetainedCacheDirectory.open(cache, protected_roots=())
            try:
                guard.write_or_verify(artifact, b"locked")
                guard.write_or_verify(artifact, b"locked")
                self.assertEqual(guard.read_regular(artifact), b"locked")
                with self.assertRaisesRegex(
                    P07ProductionError,
                    "content-addressed artifact changed",
                ):
                    guard.write_or_verify(artifact, b"different")
                guard.freeze()

                replacement = parent / "replacement.bin"
                replacement.write_bytes(b"locked")
                os.replace(replacement, artifact)
                with self.assertRaisesRegex(
                    P07ProductionError,
                    "(identity|frozen).*changed|changed.*(identity|frozen)",
                ):
                    guard.verify_frozen()
            finally:
                guard.close()

        with tempfile.TemporaryDirectory(dir="/private/tmp") as name:
            cache = Path(name)
            artifact = cache / "artifact.bin"
            alias = cache / "artifact-alias.bin"
            guard = _RetainedCacheDirectory.open(cache, protected_roots=())
            try:
                guard.write_or_verify(artifact, b"locked")
                os.link(artifact, alias)
                with self.assertRaisesRegex(P07ProductionError, "hard link"):
                    guard.read_regular(artifact)
            finally:
                guard.close()

        with tempfile.TemporaryDirectory(dir="/private/tmp") as name:
            cache = Path(name)
            artifact = cache / "artifact.bin"
            guard = _RetainedCacheDirectory.open(cache, protected_roots=())
            try:
                guard.write_or_verify(artifact, b"locked")
                guard.freeze()
                artifact.write_bytes(b"mutate")
                with self.assertRaisesRegex(P07ProductionError, "changed"):
                    guard.verify_frozen()
            finally:
                guard.close()

    def test_retained_cache_rejects_swap_between_publication_and_reopen(self) -> None:
        with tempfile.TemporaryDirectory(dir="/private/tmp") as name:
            parent = Path(name)
            cache = parent / "cache"
            cache.mkdir()
            artifact = cache / "race.bin"
            replacement = parent / "replacement.bin"
            replacement.write_bytes(b"attacker")
            guard = _RetainedCacheDirectory.open(cache, protected_roots=())
            real_open = os.open
            opens = 0

            def swapping_open(path, flags, mode=0o777, *, dir_fd=None):
                nonlocal opens
                if path == "race.bin":
                    opens += 1
                    if opens == 1:
                        os.replace(replacement, artifact)
                return real_open(path, flags, mode, dir_fd=dir_fd)

            try:
                with patch(
                    "validation.calibration_v2.p07.production.os.open",
                    side_effect=swapping_open,
                ):
                    with self.assertRaisesRegex(
                        P07ProductionError,
                        "publication identity changed",
                    ):
                        guard.write_or_verify(artifact, b"locked")
                self.assertEqual(artifact.read_bytes(), b"attacker")
            finally:
                guard.close()

    def test_retained_cache_publication_recovers_after_literal_sigkill(self) -> None:
        with tempfile.TemporaryDirectory(dir="/private/tmp") as name:
            cache = Path(name) / "cache"
            cache.mkdir()
            artifact = cache / "artifact.bin"
            read_descriptor, write_descriptor = os.pipe()
            pid = os.fork()
            if pid == 0:
                os.close(read_descriptor)
                guard = None
                try:
                    guard = _RetainedCacheDirectory.open(
                        cache,
                        protected_roots=(),
                    )
                    real_link = os.link

                    def stop_before_link(*args, **kwargs):
                        os.write(write_descriptor, b"before-link")
                        os.kill(os.getpid(), signal.SIGSTOP)
                        return real_link(*args, **kwargs)

                    with patch(
                        "validation.calibration_v2.p07.production.os.link",
                        side_effect=stop_before_link,
                    ):
                        guard.write_or_verify(artifact, b"durable-payload")
                except BaseException as error:
                    os.write(
                        write_descriptor,
                        "child-error:{!r}".format(error).encode("utf-8"),
                    )
                finally:
                    if guard is not None:
                        guard.close()
                    os.close(write_descriptor)
                    os._exit(1)

            os.close(write_descriptor)
            _kill_child_at_checkpoint(pid, read_descriptor, b"before-link")
            guard = _RetainedCacheDirectory.open(cache, protected_roots=())
            try:
                guard.write_or_verify(artifact, b"durable-payload")
                self.assertEqual(
                    guard.read_regular(artifact),
                    b"durable-payload",
                )
                self.assertFalse(
                    any(
                        ".p07-uncommitted-" in child.name
                        for child in cache.iterdir()
                    )
                )
                guard.advance_monotonic()
            finally:
                guard.close()

    def test_retained_cache_linked_publication_recovers_after_literal_sigkill(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory(dir="/private/tmp") as name:
            cache = Path(name) / "cache"
            cache.mkdir()
            artifact = cache / "artifact.bin"
            read_descriptor, write_descriptor = os.pipe()
            pid = os.fork()
            if pid == 0:
                os.close(read_descriptor)
                guard = None
                try:
                    guard = _RetainedCacheDirectory.open(
                        cache,
                        protected_roots=(),
                    )
                    real_unlink = os.unlink

                    def stop_after_link(path, *args, **kwargs):
                        if str(path).startswith(
                            ".artifact.bin.p07-uncommitted-"
                        ):
                            os.write(write_descriptor, b"after-link")
                            os.kill(os.getpid(), signal.SIGSTOP)
                        return real_unlink(path, *args, **kwargs)

                    with patch(
                        "validation.calibration_v2.p07.production.os.unlink",
                        side_effect=stop_after_link,
                    ):
                        guard.write_or_verify(artifact, b"linked-payload")
                except BaseException as error:
                    os.write(
                        write_descriptor,
                        "child-error:{!r}".format(error).encode("utf-8"),
                    )
                finally:
                    if guard is not None:
                        guard.close()
                    os.close(write_descriptor)
                    os._exit(1)

            os.close(write_descriptor)
            _kill_child_at_checkpoint(pid, read_descriptor, b"after-link")
            linked_identity = artifact.stat()
            self.assertEqual(linked_identity.st_nlink, 2)
            guard = _RetainedCacheDirectory.open(cache, protected_roots=())
            try:
                guard.write_or_verify(artifact, b"linked-payload")
                recovered = artifact.stat()
                self.assertEqual(
                    (recovered.st_dev, recovered.st_ino),
                    (linked_identity.st_dev, linked_identity.st_ino),
                )
                self.assertEqual(recovered.st_nlink, 1)
                self.assertEqual(guard.read_regular(artifact), b"linked-payload")
                self.assertFalse(
                    any(
                        ".p07-uncommitted-" in child.name
                        for child in cache.iterdir()
                    )
                )
            finally:
                guard.close()

    def test_retained_cache_winning_inode_swap_with_same_bytes_fails(self) -> None:
        with tempfile.TemporaryDirectory(dir="/private/tmp") as name:
            parent = Path(name)
            cache = parent / "cache"
            cache.mkdir()
            artifact = cache / "same-bytes.bin"
            replacement = parent / "replacement.bin"
            replacement.write_bytes(b"locked")
            os.chmod(replacement, 0o644)
            guard = _RetainedCacheDirectory.open(cache, protected_roots=())
            real_open = os.open
            reopened = False

            def swapping_open(path, flags, mode=0o777, *, dir_fd=None):
                nonlocal reopened
                if path == "same-bytes.bin" and not reopened:
                    reopened = True
                    os.replace(replacement, artifact)
                return real_open(path, flags, mode, dir_fd=dir_fd)

            try:
                with patch(
                    "validation.calibration_v2.p07.production.os.open",
                    side_effect=swapping_open,
                ):
                    with self.assertRaisesRegex(
                        P07ProductionError,
                        "publication identity changed",
                    ):
                        guard.write_or_verify(artifact, b"locked")
                self.assertEqual(artifact.read_bytes(), b"locked")
                self.assertEqual(artifact.stat().st_mode & 0o777, 0o644)
            finally:
                guard.close()

    def test_compiler_staging_quarantines_after_literal_sigkill(self) -> None:
        transaction_id = "1" * 32
        staging_name = ".compiler-staging-{}".format(transaction_id)
        event = _compiler_journal_event(
            phase="started",
            transaction_id=transaction_id,
            staging_name=staging_name,
        )
        with tempfile.TemporaryDirectory(dir="/private/tmp") as name:
            cache = Path(name) / "cache"
            cache.mkdir()
            recompile_root = cache / "independent-recompile"
            journal_root = recompile_root / "compile-transaction-journal"
            read_descriptor, write_descriptor = os.pipe()
            pid = os.fork()
            if pid == 0:
                os.close(read_descriptor)
                guard = None
                partial_descriptor = -1
                try:
                    guard = _RetainedCacheDirectory.open(
                        cache,
                        protected_roots=(),
                    )
                    guard.ensure_directory(recompile_root)
                    guard.ensure_directory(journal_root)
                    _append_compile_journal(
                        guard,
                        journal_root,
                        event,
                    )
                    recompile_descriptor = (
                        guard.retained_directory_descriptor(recompile_root)
                    )
                    os.mkdir(
                        staging_name,
                        0o700,
                        dir_fd=recompile_descriptor,
                    )
                    staging_descriptor = os.open(
                        staging_name,
                        os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                        dir_fd=recompile_descriptor,
                    )
                    try:
                        partial_descriptor = os.open(
                            "direct2x.ashlut",
                            os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                            0o600,
                            dir_fd=staging_descriptor,
                        )
                        os.write(partial_descriptor, b"partial-compiler-output")
                        os.fsync(partial_descriptor)
                        os.close(partial_descriptor)
                        partial_descriptor = -1
                        os.fsync(staging_descriptor)
                        os.fsync(recompile_descriptor)
                    finally:
                        os.close(staging_descriptor)
                    os.write(write_descriptor, b"partial-staging")
                    os.kill(os.getpid(), signal.SIGSTOP)
                except BaseException as error:
                    os.write(
                        write_descriptor,
                        "child-error:{!r}".format(error).encode("utf-8"),
                    )
                finally:
                    if partial_descriptor >= 0:
                        os.close(partial_descriptor)
                    if guard is not None:
                        guard.close()
                    os.close(write_descriptor)
                    os._exit(1)

            os.close(write_descriptor)
            _kill_child_at_checkpoint(
                pid,
                read_descriptor,
                b"partial-staging",
            )
            guard = _RetainedCacheDirectory.open(cache, protected_roots=())
            try:
                guard.ensure_directory(recompile_root)
                guard.ensure_directory(journal_root)
                journal = _read_compile_journal(guard, journal_root)
                self.assertEqual([row["phase"] for row in journal], ["started"])
                _quarantine_interrupted_compiler_transaction(
                    cache_guard=guard,
                    recompile_root=recompile_root,
                    journal_root=journal_root,
                    event=journal[-1],
                )
                reopened = _read_compile_journal(guard, journal_root)
                self.assertEqual(
                    [row["phase"] for row in reopened],
                    ["started", "quarantined"],
                )
                self.assertFalse((recompile_root / staging_name).exists())
                quarantined = (
                    recompile_root
                    / "quarantine"
                    / transaction_id
                    / "direct2x.ashlut"
                )
                self.assertEqual(
                    quarantined.read_bytes(),
                    b"partial-compiler-output",
                )
                self.assertFalse(
                    any(
                        ".p07-uncommitted-" in child.name
                        for child in journal_root.iterdir()
                    )
                )
                guard.advance_monotonic()
            finally:
                guard.close()

    def test_completed_compiler_staging_is_archived_and_chain_bound(self) -> None:
        transaction_id = "2" * 32
        staging_name = ".compiler-staging-{}".format(transaction_id)
        with tempfile.TemporaryDirectory(dir="/private/tmp") as name:
            cache = Path(name) / "cache"
            cache.mkdir()
            recompile_root = cache / "independent-recompile"
            journal_root = recompile_root / "compile-transaction-journal"
            staging_root = recompile_root / staging_name
            guard = _RetainedCacheDirectory.open(cache, protected_roots=())
            try:
                guard.ensure_directory(recompile_root)
                guard.ensure_directory(journal_root)
                _append_compile_journal(
                    guard,
                    journal_root,
                    _compiler_journal_event(
                        phase="started",
                        transaction_id=transaction_id,
                        staging_name=staging_name,
                    ),
                )
                staging_root.mkdir()
                payloads = {
                    "compile-summary.json": b"summary\n",
                    "direct2x.ashlut": b"direct-2x",
                    "direct3over2.ashlut": b"direct-3over2",
                }
                for filename, payload in payloads.items():
                    (staging_root / filename).write_bytes(payload)
                hashes = {
                    filename: __import__("hashlib").sha256(payload).hexdigest()
                    for filename, payload in payloads.items()
                }
                _append_compile_journal(
                    guard,
                    journal_root,
                    _compiler_journal_event(
                        phase="validated",
                        transaction_id=transaction_id,
                        staging_name=staging_name,
                        hashes=hashes,
                    ),
                )
                _archive_completed_compiler_transaction(
                    cache_guard=guard,
                    recompile_root=recompile_root,
                    journal_root=journal_root,
                    transaction_id=transaction_id,
                    staging_name=staging_name,
                    expected_hashes=hashes,
                    append_complete=True,
                )
                self.assertFalse(staging_root.exists())
                completed = recompile_root / "completed" / transaction_id
                self.assertTrue(completed.is_dir())
                journal = _read_compile_journal(guard, journal_root)
                self.assertEqual(
                    [row["sequence"] for row in journal],
                    [0, 1, 2],
                )
                self.assertEqual(
                    [row["phase"] for row in journal],
                    ["started", "validated", "complete"],
                )
                self.assertIsNone(journal[0]["previous_event_sha256"])
                self.assertEqual(
                    journal[1]["previous_event_sha256"],
                    journal[0]["event_sha256"],
                )
                self.assertEqual(
                    journal[2]["previous_event_sha256"],
                    journal[1]["event_sha256"],
                )
                guard.advance_monotonic()
            finally:
                guard.close()

            first = journal_root / "event-00000000.json"
            last = journal_root / "event-00000002.json"
            first_payload = first.read_bytes()
            last_payload = last.read_bytes()
            first.write_bytes(last_payload)
            last.write_bytes(first_payload)
            guard = _RetainedCacheDirectory.open(cache, protected_roots=())
            try:
                with self.assertRaisesRegex(
                    P07ProductionError,
                    "journal event differs",
                ):
                    _read_compile_journal(guard, journal_root)
            finally:
                guard.close()

    def test_retained_cache_freeze_rejects_entry_addition_and_deletion(self) -> None:
        for mutation in ("addition", "deletion"):
            with self.subTest(mutation=mutation):
                with tempfile.TemporaryDirectory(dir="/private/tmp") as name:
                    cache = Path(name)
                    artifact = cache / "artifact.bin"
                    guard = _RetainedCacheDirectory.open(
                        cache,
                        protected_roots=(),
                    )
                    try:
                        guard.write_or_verify(artifact, b"locked")
                        guard.freeze()
                        if mutation == "addition":
                            (cache / "added.bin").write_bytes(b"added")
                        else:
                            artifact.unlink()
                        with self.assertRaisesRegex(P07ProductionError, "changed|disappeared"):
                            guard.verify_frozen()
                    finally:
                        guard.close()

    def test_locked_release_executable_cannot_be_replaced_by_builder(self) -> None:
        with tempfile.TemporaryDirectory(dir="/private/tmp") as name:
            root = Path(name)
            release_path = root / "released-cli"
            release_path.write_bytes(b"released")
            source_path = root / "released-sources.json"
            source_path.write_bytes(b"{}")
            release_executable = NativeExecutable(
                path=release_path,
                sha256=_digest("released-cli"),
                source_manifest_path=source_path,
                source_manifest_sha256=_digest("released-sources"),
                compiled_now=False,
            )
            locked = SimpleNamespace(
                release_native_executable=release_executable,
                release_bundle_manifest_sha256=_digest("release"),
            )
            configuration = {"configuration_id": "synthetic-release"}
            native = NativeConfiguration(
                root=root,
                compiler_input_path=root / "compiler.json",
                mapping_path=root / "mapping.json",
                operator_bank_path=root / "operator.json",
                runtime_manifest_path=root / "runtime.json",
                route_paths={},
                configuration=configuration,
            )
            p00 = SimpleNamespace(
                executable=SimpleNamespace(identity={}, path=root / "p00")
            )
            factory = SimpleNamespace(
                builder=SimpleNamespace(
                    executable=NativeExecutable(
                        path=root / "forged-builder",
                        sha256=_digest("forged-builder"),
                        source_manifest_path=root / "forged-sources",
                        source_manifest_sha256=_digest("forged-sources"),
                        compiled_now=False,
                    )
                ),
                timeout_seconds=1.0,
                p00_builder=p00,
                bound=SimpleNamespace(
                    record=lambda identifier: {"sha256": _digest(identifier)}
                ),
            )
            observed = {}

            class FakeSession:
                def __init__(
                    self,
                    executable,
                    native_configuration,
                    *,
                    timeout_seconds,
                    pass_fds=(),
                    execution_authorizer=None,
                    authorized_environment=None,
                ):
                    observed["executable"] = executable
                    observed["pass_fds"] = pass_fds
                    observed["execution_authorizer"] = execution_authorizer
                    observed["authorized_environment"] = authorized_environment
                    self.configuration = native_configuration

                def close(self):
                    pass

            with patch(
                "validation.calibration_v2.p07.production.NativeSwiftSession",
                FakeSession,
            ):
                adapter = _make_release_adapter(
                    locked=locked,
                    native_factory=factory,
                    native_configuration=native,
                    split="p07_holdout_analytic",
                    artifact_root=root / "artifacts",
                    analytic_fixture_manifest_sha256=_digest("analytic"),
                    retained_native_executable=release_executable,
                    native_retained_fds=(41,),
                    p00_retained_fds=(42,),
                    native_execution_authorizer=lambda pid: None,
                    p00_execution_authorizer=lambda pid: None,
                    authorized_environment={"test": "retained"},
                )
            self.assertIs(observed["executable"], release_executable)
            self.assertIsNot(observed["executable"], factory.builder.executable)
            self.assertEqual(observed["pass_fds"], (41,))
            self.assertTrue(callable(observed["execution_authorizer"]))
            adapter.callable.close()

    def test_constructor_requires_and_retains_recompile_evidence(self) -> None:
        degradation = {"profiles": _profiles()}
        locked = SimpleNamespace(degradation_policy=degradation)
        recompile = {"status": "pass"}
        with tempfile.TemporaryDirectory(dir="/private/tmp") as name:
            cache = Path(name)
            guard = _RetainedCacheDirectory.open(cache, protected_roots=())
            snapshot = guard.freeze()
            instance = P07ProductionEvaluator(
                locked=locked,
                native_factory=SimpleNamespace(),
                native_configuration=SimpleNamespace(),
                release_lut_recompile=recompile,
                p07_cache_root=cache,
                cache_guard=guard,
                preopen_cache_snapshot=snapshot,
                selected_aliases={},
                configuration_hashes={},
                analytic_rows=(),
                analytic_runtime_cases=(),
                analytic_comparison={},
                p00_continuity={},
                loader_verification={},
                writer_inputs=SimpleNamespace(close=MagicMock()),
                writer_execution=SimpleNamespace(),
                writer_settings_source_sha256=_digest("writer-source"),
                expected_writer_settings_sha256=_digest("writer-settings"),
                retained_native_runtime=SimpleNamespace(close=MagicMock()),
            )
            self.assertEqual(instance.release_lut_recompile, recompile)
            instance.close()

    def test_adapter_close_commits_callable_not_only_session(self) -> None:
        callable_close = MagicMock()
        session_close = MagicMock()
        adapter = SimpleNamespace(
            callable=SimpleNamespace(
                close=callable_close,
                session=SimpleNamespace(close=session_close),
            )
        )
        _close_adapter(adapter)
        callable_close.assert_called_once_with()
        session_close.assert_not_called()

    def test_adapter_lifetime_preserves_primary_and_close_failures(self) -> None:
        primary = ValueError("primary evaluation failure")
        cleanup = RuntimeError("deferred durability failure")

        def fail_close() -> None:
            raise cleanup

        adapter = SimpleNamespace(
            callable=SimpleNamespace(close=fail_close),
        )
        with self.assertRaises(P07DualFailure) as caught:
            with _adapter_lifetime(adapter):
                raise primary
        self.assertIs(caught.exception.primary_error, primary)
        self.assertIs(caught.exception.cleanup_error, cleanup)

    def test_preopen_mode_returns_before_guard_live_runner(self) -> None:
        evaluator = SimpleNamespace(
            locked=SimpleNamespace(
                configuration_sha256=_digest("configuration"),
                release_bundle_manifest_sha256=_digest("release"),
                release_native_executable=SimpleNamespace(
                    sha256=_digest("native"),
                    source_manifest_sha256=_digest("sources"),
                ),
            ),
            release_lut_recompile={"status": "pass"},
            loader_verification={"status": "pass"},
            p00_continuity={"status": "pass"},
            analytic_rows=tuple({"row": index} for index in range(28)),
            analytic_runtime_cases=tuple(
                {"case": index} for index in range(14)
            ),
            analytic_comparison={"status": "pass"},
            preopen_cache_snapshot={"tree_sha256": _digest("tree")},
        )
        live_runner = MagicMock(side_effect=AssertionError("guard constructed"))
        result = _run_selected_mode(
            preopen_verify_only=True,
            evaluator=evaluator,
            live_runner=live_runner,
        )
        live_runner.assert_not_called()
        self.assertEqual(result["status"], "pass")
        self.assertFalse(result["holdout_guard_constructed"])
        self.assertFalse(result["holdout_accessed"])
        self.assertEqual(
            result["manifest_sha256"],
            canonical_sha256(
                {
                    key: value
                    for key, value in result.items()
                    if key != "manifest_sha256"
                }
            ),
        )


if __name__ == "__main__":
    unittest.main()
