from __future__ import annotations

import argparse
import copy
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
from types import SimpleNamespace
import tempfile
import unittest
from unittest import mock

from validation.calibration_v2.tools import run_g05_current_source as g05
from validation.quality.src.mirmir_quality.json_tools import canonical_json_bytes
from validation.spatial_v2 import run_p05_evidence as p05


SOURCE_COMMIT = "1" * 40
BASELINE_COMMIT = "2" * 40
RUN_ID = "12345678-1234-4123-8123-123456789abc"
STARTED_UTC = "2026-07-15T12:00:00Z"
CONFIGURATION_SHA256 = "3" * 64
SYNTHETIC_INPUT_SHA256 = "4" * 64
SYNTHETIC_TARGET_SHA256 = "5" * 64
_MISSING = object()


class G05CurrentSourceTests(unittest.TestCase):
    def test_p05_compiler_is_bound_to_explicit_macos_sdk(self) -> None:
        self.assertEqual(
            p05.SWIFT_COMPILER_COMMAND,
            ("/usr/bin/xcrun", "--sdk", "macosx", "swiftc"),
        )

    def setUp(self) -> None:
        repository_parent = Path(__file__).resolve().parents[4]
        self.temporary = tempfile.TemporaryDirectory(
            prefix="mirmir-g05-current-source-tests-",
            dir=repository_parent,
        )
        self.root = Path(self.temporary.name).resolve(strict=True)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    @staticmethod
    def _json_bytes(document: object) -> bytes:
        return (
            json.dumps(
                document,
                ensure_ascii=False,
                allow_nan=False,
                sort_keys=True,
                separators=(",", ":"),
            )
            + "\n"
        ).encode("utf-8")

    @classmethod
    def _write_json(cls, path: Path, document: object) -> bytes:
        path.parent.mkdir(parents=True, exist_ok=True)
        payload = cls._json_bytes(document)
        path.write_bytes(payload)
        return payload

    @staticmethod
    def _artifact_row(relative: str, payload: bytes) -> dict[str, object]:
        return {
            "path": relative,
            "sha256": hashlib.sha256(payload).hexdigest(),
            "size_bytes": len(payload),
        }

    @classmethod
    def _finalizer_artifact_row(
        cls,
        relative: str,
        payload: bytes,
    ) -> dict[str, object]:
        return {
            **cls._artifact_row(relative, payload),
            "producer": "G04 fixture",
            "gate_ids": ["G04"],
            "command": "fixture",
            "platform": "macOS",
            "machine": "arm64",
        }

    def _instruction_package(self, name: str = "instruction-package") -> Path:
        root = self.root / name
        (root / "config").mkdir(parents=True)
        (root / "tools").mkdir()
        self._write_json(root / "package_manifest.json", {"fixture": True})
        (root / "SHA256SUMS.txt").write_text(
            f"{'0' * 64}  package_manifest.json\n",
            encoding="utf-8",
        )
        (root / "config/attribution_policy.json").write_text(
            '{"scan_patterns":[]}\n',
            encoding="utf-8",
        )
        (root / "config/geometry_color_audio_policy.json").write_text(
            '{"fixture":"media-policy"}\n',
            encoding="utf-8",
        )
        (root / "tools/validate_instruction_package.py").write_text(
            "fixture\n",
            encoding="utf-8",
        )
        (root / "tools/scan_project_attribution.py").write_text(
            "fixture\n",
            encoding="utf-8",
        )
        return root

    @staticmethod
    def _toolchain() -> dict[str, object]:
        def tool(name: str) -> dict[str, str]:
            return {
                "executable": f"/usr/bin/{name}",
                "version": f"{name} fixture",
                "version_sha256": hashlib.sha256(
                    f"{name} fixture\n".encode("utf-8")
                ).hexdigest(),
            }

        return {
            "python": tool("python3"),
            "xcode": tool("xcodebuild"),
            "swift": tool("swiftc"),
            "macos_sdk": tool("macosx-sdk"),
            "swiftlint": tool("swiftlint"),
            "metal_device": {
                "applicable": False,
                "reason": "not_used_by_g05_synthetic_cpu_reference",
            },
        }

    @staticmethod
    def _baseline_binding() -> dict[str, object]:
        body: dict[str, object] = {
            "schema_version": "1.0.0",
            "status": "pass",
            "baseline_commit": BASELINE_COMMIT,
            "source_commit": SOURCE_COMMIT,
            "ancestry": "baseline_is_ancestor_of_source",
            "tracked_records": [
                {
                    "path": relative,
                    "sha256": hashlib.sha256(relative.encode("utf-8")).hexdigest(),
                    "size_bytes": len(relative.encode("utf-8")),
                }
                for relative in g05.P00_BASELINE_RECORDS
            ],
        }
        return {**body, "binding_sha256": g05.canonical_sha256(body)}

    def _identity_repository(self, name: str) -> tuple[Path, dict[str, str]]:
        repository = self.root / name
        mapping = repository / "Mirmir/Resources/ASH/ash_video_mapping_v2.seed.json"
        operator = repository / "Mirmir/Resources/ASH/operator_bank_v2.seed.json"
        metric = repository / "validation/quality/policies/metric-policy.json"
        quality_manifest = repository / g05.QUALITY_MANIFEST_RELATIVE
        spatial_preregistration = repository / g05.SPATIAL_PREREGISTRATION_RELATIVE
        mapping.parent.mkdir(parents=True)
        metric.parent.mkdir(parents=True)
        quality_manifest.parent.mkdir(parents=True, exist_ok=True)
        spatial_preregistration.parent.mkdir(parents=True, exist_ok=True)
        mapping.write_text('{"fixture":"mapping"}\n', encoding="utf-8")
        operator.write_text('{"fixture":"operator"}\n', encoding="utf-8")
        metric.write_text('{"fixture":"metric"}\n', encoding="utf-8")
        quality_manifest.write_text('{"fixture":"quality"}\n', encoding="utf-8")
        spatial_preregistration.write_text(
            '{"fixture":"spatial"}\n',
            encoding="utf-8",
        )
        return repository, {
            "Mirmir/Resources/ASH/ash_video_mapping_v2.seed.json": hashlib.sha256(
                mapping.read_bytes()
            ).hexdigest(),
            "Mirmir/Resources/ASH/operator_bank_v2.seed.json": hashlib.sha256(
                operator.read_bytes()
            ).hexdigest(),
        }

    def test_read_regular_rejects_post_read_path_identity_change(self) -> None:
        path = self.root / "source.json"
        path.write_bytes(b'{"fixture":true}\n')
        before = os.lstat(path)
        replaced = SimpleNamespace(
            st_dev=before.st_dev,
            st_ino=before.st_ino + 1,
            st_mode=before.st_mode,
            st_nlink=before.st_nlink,
            st_size=before.st_size,
            st_mtime_ns=before.st_mtime_ns,
            st_ctime_ns=before.st_ctime_ns,
        )
        with mock.patch.object(g05.os, "lstat", side_effect=(before, replaced)):
            with self.assertRaisesRegex(
                g05.G05CurrentSourceError,
                "path identity changed after reading",
            ):
                g05._read_regular(path, "synthetic source")

    def test_strict_reopen_rejects_postvalidation_namespace_replacement(self) -> None:
        final_root = self.root / "published-wrapper"
        final_root.mkdir()
        (final_root / "marker.json").write_bytes(b"original\n")
        metadata = os.lstat(final_root)
        expected_identity = (metadata.st_dev, metadata.st_ino)
        displaced = self.root / "displaced-wrapper"

        def replace_namespace(**arguments: object) -> None:
            pinned_root = Path(arguments["wrapper_root"])
            final_root.rename(displaced)
            final_root.mkdir()
            (final_root / "marker.json").write_bytes(b"replacement\n")
            self.assertEqual(
                (pinned_root / "marker.json").read_bytes(),
                b"original\n",
            )
            with mock.patch.object(g05, "_require_frozen"):
                self.assertEqual(
                    g05._collect_sealed_files(pinned_root),
                    ("marker.json",),
                )
            self.assertEqual(g05._collect_directories(pinned_root), ())

        with mock.patch.object(
            g05,
            "_strict_reopen_final_wrapper_pinned",
            side_effect=replace_namespace,
        ):
            with self.assertRaisesRegex(
                g05.G05CurrentSourceError,
                "namespace identity changed after pinned reopen",
            ):
                g05._strict_reopen_final_wrapper(
                    repository_root=self.root,
                    final_root=final_root,
                    instruction_package_root=self.root,
                    source_commit=SOURCE_COMMIT,
                    baseline_commit=BASELINE_COMMIT,
                    command_plan={},
                    expected_p05_closure={},
                    expected_root_identity=expected_identity,
                )

    def test_canonical_directory_and_preflight_reject_unsafe_topology(self) -> None:
        actual = self.root / "actual"
        child = actual / "child"
        child.mkdir(parents=True)
        linked = self.root / "linked"
        linked.symlink_to(actual, target_is_directory=True)
        with self.assertRaisesRegex(g05.G05SetupError, "not canonical"):
            g05._canonical_directory(linked / "child", "linked-parent fixture")
        with self.assertRaisesRegex(g05.G05SetupError, "lexically normalized"):
            g05._canonical_directory(
                actual / "child" / ".." / "child",
                "dot-dot fixture",
            )

        repository = self.root / "repository"
        artifact_parent = repository / "Artifacts" / "ASH"
        instruction_root = self._instruction_package()
        final_name = (
            "20260715-direct-both-synthetic-p05-current-source-"
            f"{CONFIGURATION_SHA256[:8]}-{RUN_ID}"
        )
        partial = artifact_parent / f".{final_name}.partial"
        partial.mkdir(parents=True)
        final = artifact_parent / final_name
        g03_root = self.root / "g03"
        g04_root = self.root / "g04"
        g03_root.mkdir()
        g04_root.mkdir()
        arguments = argparse.Namespace(
            repository_root=repository,
            partial_root=partial,
            final_root=final,
            expected_source_commit=SOURCE_COMMIT,
            g03_root=g03_root,
            g04_root=g04_root,
            instruction_package_root=instruction_root,
            run_id=RUN_ID,
            started_utc="2026-07-15T00:00:00Z",
            configuration_sha256=CONFIGURATION_SHA256,
            synthetic_input_sha256=SYNTHETIC_INPUT_SHA256,
            synthetic_target_sha256=SYNTHETIC_TARGET_SHA256,
            p00_baseline_commit=BASELINE_COMMIT,
        )
        with mock.patch.object(g05, "REPOSITORY_ROOT", repository), mock.patch.object(
            g05,
            "_validate_baseline_commit",
        ):
            self.assertEqual(
                g05._preflight(arguments),
                (
                    repository,
                    partial,
                    final,
                    g03_root,
                    g04_root,
                    instruction_root,
                ),
            )
            nested_g04 = g03_root / "nested-g04"
            nested_g04.mkdir()
            nested_arguments = argparse.Namespace(
                **{**vars(arguments), "g04_root": nested_g04}
            )
            with self.assertRaisesRegex(
                g05.G05SetupError,
                "must not contain one another",
            ):
                g05._preflight(nested_arguments)

            wrong_partial = artifact_parent / ".wrong.partial"
            wrong_partial.mkdir()
            wrong_arguments = argparse.Namespace(
                **{**vars(arguments), "partial_root": wrong_partial}
            )
            with self.assertRaisesRegex(
                g05.G05SetupError,
                "exact .<final-name>.partial sibling",
            ):
                g05._preflight(wrong_arguments)

            wrong_final = artifact_parent / "20260715-p05-current-source-bad"
            wrong_name_partial = artifact_parent / f".{wrong_final.name}.partial"
            wrong_name_partial.mkdir()
            wrong_name_arguments = argparse.Namespace(
                **{
                    **vars(arguments),
                    "partial_root": wrong_name_partial,
                    "final_root": wrong_final,
                }
            )
            with self.assertRaisesRegex(
                g05.G05SetupError,
                "canonical UTC-route-mode-config-UUID name",
            ):
                g05._preflight(wrong_name_arguments)

    def _upstream_case(
        self,
        name: str,
        g04_holdout_accessed: object,
    ) -> tuple[Path, Path, str, Path, str]:
        case = self.root / name
        partial = case / "partial"
        (partial / "inputs/g03").mkdir(parents=True)
        (partial / "inputs/g04").mkdir()
        g03_root = case / "g03"
        g04_root = case / "g04"
        g03_root.mkdir()
        g04_root.mkdir()

        g03_documents: dict[str, object] = {
            "conformance/g03-gate-assessment.json": {
                "status": "pass",
                "holdout_accessed": False,
            },
            "conformance/canonical-vectors.json": {"fixture": "vectors"},
            "conformance/p03-g03-canonical-core-evidence.json": {
                "fixture": "core"
            },
            "conformance/ash-core-v1.contract.json": {"fixture": "contract"},
        }
        g03_rows: list[dict[str, object]] = []
        for relative, document in g03_documents.items():
            payload = self._write_json(g03_root / relative, document)
            g03_rows.append(self._artifact_row(relative, payload))
        g03_manifest = self._write_json(
            g03_root / "artifact-manifest.json",
            {
                "working_tree_clean": True,
                "project_commit": "2" * 40,
                "artifacts": g03_rows,
            },
        )

        assessment: dict[str, object] = {
            "status": "pass",
            "project_commit": SOURCE_COMMIT,
        }
        if g04_holdout_accessed is not _MISSING:
            assessment["holdout_accessed"] = g04_holdout_accessed
        g04_documents: dict[str, object] = {
            "analysis/g04-gate-assessment.json": assessment,
            "test-results.json": {
                "status": "pass",
                "xcode_full": {
                    "status": "pass",
                    "failed": 0,
                    "errors": 0,
                    "skipped": 0,
                },
                "release_build": {
                    "status": "pass",
                    "warnings": 0,
                    "errors": 0,
                },
                "python": {
                    "status": "pass",
                    "failures": 0,
                    "errors": 0,
                    "skips": 0,
                },
            },
        }
        g04_rows: list[dict[str, object]] = []
        for relative, document in g04_documents.items():
            payload = self._write_json(g04_root / relative, document)
            g04_rows.append(self._finalizer_artifact_row(relative, payload))
        root_metadata = os.lstat(g04_root)
        transaction = {
            "schema_version": "1.0.0",
            "artifact_kind": "evidence_wrapper_publication_transaction",
            "transaction_token": "a" * 32,
            "created_utc": STARTED_UTC,
            "project_commit": SOURCE_COMMIT,
            "partial_name": ".g04.partial",
            "final_name": "g04",
            "failure_name": "g04.failed",
            "gate_ids": ["G04"],
            "root_device": root_metadata.st_dev,
            "root_inode": root_metadata.st_ino,
        }
        transaction_payload = self._write_json(
            g04_root / "publication-transaction.json",
            transaction,
        )
        g04_rows.append(
            self._finalizer_artifact_row(
                "publication-transaction.json",
                transaction_payload,
            )
        )
        g04_rows.sort(key=lambda row: str(row["path"]))
        g04_manifest = self._write_json(
            g04_root / "artifact-manifest.json",
            {
                "schema_version": "2.0.0",
                "created_utc": STARTED_UTC,
                "working_tree_clean": True,
                "project_commit": SOURCE_COMMIT,
                "directories": ["analysis"],
                "artifacts": g04_rows,
            },
        )
        return (
            partial,
            g03_root,
            hashlib.sha256(g03_manifest).hexdigest(),
            g04_root,
            hashlib.sha256(g04_manifest).hexdigest(),
        )

    @staticmethod
    def _g04_attestation(g04_root: Path) -> dict[str, object]:
        manifest_payload = (g04_root / "artifact-manifest.json").read_bytes()
        manifest = json.loads(manifest_payload)
        return dict(
            g05.build_g04_closure_attestation(
                manifest=manifest,
                manifest_sha256=hashlib.sha256(manifest_payload).hexdigest(),
            )
        )

    def test_g04_upstream_requires_explicit_holdout_false(self) -> None:
        for name, value in (("missing", _MISSING), ("null", None), ("true", True)):
            with self.subTest(value=name):
                partial, g03_root, g03_hash, g04_root, g04_hash = (
                    self._upstream_case(f"reject-{name}", value)
                )
                with mock.patch.object(g05, "_require_frozen"), mock.patch.object(
                    g05,
                    "_validate_finalized_g04_closure",
                    return_value=self._g04_attestation(g04_root),
                ):
                    with self.assertRaisesRegex(
                        g05.G05CurrentSourceError,
                        "same-source passing no-holdout",
                    ):
                        g05._validate_upstream(
                            partial_root=partial,
                            g03_root=g03_root,
                            expected_g03_manifest_sha256=g03_hash,
                            g04_root=g04_root,
                            expected_g04_manifest_sha256=g04_hash,
                            source_commit=SOURCE_COMMIT,
                        )

        partial, g03_root, g03_hash, g04_root, g04_hash = self._upstream_case(
            "accept-false",
            False,
        )
        with mock.patch.object(g05, "_require_frozen"), mock.patch.object(
            g05,
            "_validate_finalized_g04_closure",
            return_value=self._g04_attestation(g04_root),
        ):
            bindings = g05._validate_upstream(
                partial_root=partial,
                g03_root=g03_root,
                expected_g03_manifest_sha256=g03_hash,
                g04_root=g04_root,
                expected_g04_manifest_sha256=g04_hash,
                source_commit=SOURCE_COMMIT,
            )
        self.assertEqual(bindings["gates"]["G04"]["status"], "pass")
        copied_paths = [
            row["path"] for row in bindings["gates"]["G04"]["copied_files"]
        ]
        self.assertTrue(all(not Path(path).is_absolute() for path in copied_paths))
        self.assertTrue(all(path.startswith("inputs/g04/") for path in copied_paths))
        self.assertEqual(
            bindings["gates"]["G04"]["closure_attestation"],
            self._g04_attestation(g04_root),
        )

    def test_g04_finalized_snapshot_rejects_transitive_closure_mutations(self) -> None:
        _, _, _, g04_root, _ = self._upstream_case("closure-fixture", False)
        manifest_payload = (g04_root / "artifact-manifest.json").read_bytes()
        manifest = json.loads(manifest_payload)
        immutable = getattr(stat, "UF_IMMUTABLE", 0)
        self.assertNotEqual(immutable, 0)
        root_metadata = os.lstat(g04_root)

        def file_snapshot(relative: str, payload: bytes, inode: int) -> SimpleNamespace:
            return SimpleNamespace(
                path=relative,
                sha256=hashlib.sha256(payload).hexdigest(),
                size_bytes=len(payload),
                device=root_metadata.st_dev,
                inode=inode,
                mode=stat.S_IFREG | 0o444,
                flags=immutable,
            )

        files = [
            file_snapshot(
                "artifact-manifest.json",
                manifest_payload,
                root_metadata.st_ino + 1,
            )
        ]
        for index, row in enumerate(manifest["artifacts"], start=2):
            files.append(
                file_snapshot(
                    row["path"],
                    (g04_root / row["path"]).read_bytes(),
                    root_metadata.st_ino + index,
                )
            )
        files.sort(key=lambda item: item.path)
        directories = [
            SimpleNamespace(
                path="",
                device=root_metadata.st_dev,
                inode=root_metadata.st_ino,
                mode=stat.S_IFDIR | 0o555,
                flags=immutable,
            ),
            SimpleNamespace(
                path="analysis",
                device=root_metadata.st_dev,
                inode=root_metadata.st_ino + 100,
                mode=stat.S_IFDIR | 0o555,
                flags=immutable,
            ),
        ]
        snapshot = SimpleNamespace(
            files=tuple(files),
            directories=tuple(directories),
        )
        g05._validate_g04_snapshot_closure(
            manifest=manifest,
            manifest_payload=manifest_payload,
            snapshot=snapshot,
        )

        mutations: tuple[tuple[str, SimpleNamespace, str], ...] = ()
        missing = copy.deepcopy(snapshot)
        missing.files = tuple(
            item for item in missing.files if item.path != "test-results.json"
        )
        extra = copy.deepcopy(snapshot)
        extra.files = (
            *extra.files,
            file_snapshot("extra.bin", b"extra", root_metadata.st_ino + 200),
        )
        mutable = copy.deepcopy(snapshot)
        mutable.files[0].flags = 0
        mismatched = copy.deepcopy(snapshot)
        next(
            item
            for item in mismatched.files
            if item.path == "test-results.json"
        ).sha256 = "0" * 64
        missing_directory = copy.deepcopy(snapshot)
        missing_directory.directories = tuple(
            item for item in missing_directory.directories if item.path != "analysis"
        )
        mutations = (
            ("missing", missing, "file closure differs"),
            ("extra", extra, "file closure differs"),
            ("mutable", mutable, "file is mutable"),
            ("mismatched", mismatched, "descendant differs"),
            ("missing-directory", missing_directory, "directory closure differs"),
        )
        for name, changed, message in mutations:
            with self.subTest(mutation=name):
                with self.assertRaisesRegex(g05.G05CurrentSourceError, message):
                    g05._validate_g04_snapshot_closure(
                        manifest=manifest,
                        manifest_payload=manifest_payload,
                        snapshot=changed,
                    )

        transaction_payload = (g04_root / "publication-transaction.json").read_bytes()
        transaction = json.loads(transaction_payload)
        root_snapshot = g05._g04_snapshot_root(snapshot)
        g05._validate_g04_publication_transaction(
            document=transaction,
            payload=transaction_payload,
            root=g04_root,
            root_snapshot=root_snapshot,
            source_commit=SOURCE_COMMIT,
        )
        remounted = dict(transaction)
        remounted["root_device"] = int(transaction["root_device"]) + 1
        g05._validate_g04_publication_transaction(
            document=remounted,
            payload=self._json_bytes(remounted),
            root=g04_root,
            root_snapshot=root_snapshot,
            source_commit=SOURCE_COMMIT,
        )
        transaction_mutations = (
            ("commit", "project_commit", "0" * 40),
            ("gates", "gate_ids", ["G03"]),
            ("root", "root_inode", root_snapshot.inode + 1),
            ("device", "root_device", -1),
        )
        for name, field, value in transaction_mutations:
            with self.subTest(transaction=name):
                changed = dict(transaction)
                changed[field] = value
                with self.assertRaisesRegex(
                    g05.G05CurrentSourceError,
                    "publication transaction identity",
                ):
                    g05._validate_g04_publication_transaction(
                        document=changed,
                        payload=self._json_bytes(changed),
                        root=g04_root,
                        root_snapshot=root_snapshot,
                        source_commit=SOURCE_COMMIT,
                    )

    def test_g04_aliases_accept_only_declared_expected_skip(self) -> None:
        tests = {
            "status": "pass",
            "xcode_debug": {
                "status": "pass",
                "failures": 0,
                "errors": 0,
                "skipped": 1,
                "expected_non_g04_skip": "one unrelated declared skip",
            },
            "release_arm64": {
                "status": "pass",
                "warnings": 0,
                "errors": 0,
            },
            "python_quality": {
                "status": "pass",
                "failures": 0,
                "errors": 0,
                "skips": 0,
            },
        }
        g05._validate_g04_test_evidence(tests, {}, [])
        del tests["xcode_debug"]["expected_non_g04_skip"]
        with self.assertRaisesRegex(
            g05.G05CurrentSourceError,
            "unexpected skip",
        ):
            g05._validate_g04_test_evidence(tests, {}, [])

    def test_copy_binding_is_wrapper_relative_and_content_bound(self) -> None:
        wrapper = self.root / "wrapper"
        destination = wrapper / "inputs/copied.json"
        destination.parent.mkdir(parents=True)
        source = self.root / "external-source.json"
        payload = b'{"synthetic":true}\n'
        source.write_bytes(payload)
        binding = g05._copy_new(
            source,
            destination,
            "synthetic copy",
            binding_root=wrapper,
        )
        self.assertEqual(binding["path"], "inputs/copied.json")
        self.assertFalse(Path(binding["path"]).is_absolute())
        self.assertEqual(binding["sha256"], hashlib.sha256(payload).hexdigest())
        self.assertEqual(binding["size_bytes"], len(payload))
        self.assertEqual(destination.read_bytes(), payload)

    def _command_plan_case(
        self,
        name: str,
    ) -> tuple[Path, Path, Path, dict[str, object]]:
        partial = self.root / name
        inputs = partial / "inputs"
        outputs = partial / "outputs"
        inputs.mkdir(parents=True)
        outputs.mkdir()
        repository = self.root / f"{name}-repository"
        repository.mkdir()
        instruction_root = self._instruction_package(f"{name}-instructions")
        with mock.patch.object(g05.shutil, "which", return_value="/usr/bin/true"):
            contracts = g05._command_contracts(
                repository_root=repository,
                partial_root=partial,
                instruction_package_root=instruction_root,
                p00_baseline_commit=BASELINE_COMMIT,
            )
        commands = [dict(contracts[identifier]) for identifier in g05.COMMAND_IDS]
        for identifier in g05.RUN_NAMES:
            run_root = partial / "evidence" / identifier
            run_root.mkdir(parents=True)
            lines: list[str] = []
            for filename in g05.P05_OUTPUT_NAMES:
                payload = f"{filename}\n".encode("utf-8")
                (run_root / filename).write_bytes(payload)
                lines.append(f"{hashlib.sha256(payload).hexdigest()}  {filename}")
            (partial / f"outputs/{identifier}.log").write_text(
                "\n".join(lines) + "\n",
                encoding="utf-8",
            )
        for suffix in ("a", "b"):
            self._write_json(
                inputs / f"quality-harness-lock-{suffix}.json",
                {"manifest_sha256": "a" * 64},
            )
            (outputs / f"quality-lock-{suffix}.log").write_text(
                f"{'a' * 64}\n",
                encoding="utf-8",
            )
        (outputs / "swiftlint.log").write_text(
            "[\n\n]\n",
            encoding="utf-8",
        )
        self._write_json(
            outputs / "attribution.log",
            {
                "status": "pass",
                "base": BASELINE_COMMIT,
                "changed_file_count": 12,
                "findings": [],
            },
        )
        (outputs / "instruction-package.log").write_bytes(
            g05._instruction_validation_output(instruction_root)
        )
        (outputs / "diff-check.log").write_bytes(b"")
        plan: dict[str, object] = {
            "schema_version": "1.0.0",
            "artifact_kind": "g05_current_source_command_plan",
            "source_commit": SOURCE_COMMIT,
            "commands": commands,
        }
        self._write_json(inputs / "g05-command-plan.json", plan)
        return repository, partial, instruction_root, plan

    @staticmethod
    def _remove_owned_execution_artifacts(partial: Path) -> None:
        for identifier in g05.RUN_NAMES:
            shutil.rmtree(partial / "evidence" / identifier)
            (partial / "outputs" / f"{identifier}.log").unlink()
        for suffix in ("a", "b"):
            (partial / "inputs" / f"quality-harness-lock-{suffix}.json").unlink()
            (partial / "outputs" / f"quality-lock-{suffix}.log").unlink()

    @staticmethod
    def _mock_p05_success(argv: tuple[str, ...], **_: object) -> SimpleNamespace:
        output = Path(argv[argv.index("--output") + 1])
        output.mkdir(parents=True)
        lines: list[str] = []
        for filename in g05.P05_OUTPUT_NAMES:
            payload = f"{output.name}:{filename}\n".encode("utf-8")
            (output / filename).write_bytes(payload)
            lines.append(f"{hashlib.sha256(payload).hexdigest()}  {filename}")
        return SimpleNamespace(
            returncode=0,
            stdout=("\n".join(lines) + "\n").encode("utf-8"),
            stderr=b"",
        )

    def test_owned_execution_rejects_prestaged_p05_and_quality_results(self) -> None:
        repository, partial, instruction_root, _ = self._command_plan_case(
            "owned-execution-preconditions"
        )
        call = {
            "repository_root": repository,
            "partial_root": partial,
            "instruction_package_root": instruction_root,
            "source_commit": SOURCE_COMMIT,
            "p00_baseline_commit": BASELINE_COMMIT,
            "p05_output_required": False,
            "quality_output_required": False,
        }
        with self.assertRaisesRegex(
            g05.G05CurrentSourceError,
            "run-a evidence root was staged before execution",
        ):
            with mock.patch.object(g05.shutil, "which", return_value="/usr/bin/true"):
                g05._validate_command_plan(**call)

        for identifier in g05.RUN_NAMES:
            shutil.rmtree(partial / "evidence" / identifier)
            (partial / "outputs" / f"{identifier}.log").unlink()
        with self.assertRaisesRegex(
            g05.G05CurrentSourceError,
            "quality-lock-a generated manifest was staged before execution",
        ):
            with mock.patch.object(g05.shutil, "which", return_value="/usr/bin/true"):
                g05._validate_command_plan(**call)

        for suffix in ("a", "b"):
            (partial / "inputs" / f"quality-harness-lock-{suffix}.json").unlink()
            (partial / "outputs" / f"quality-lock-{suffix}.log").unlink()
        with mock.patch.object(g05.shutil, "which", return_value="/usr/bin/true"):
            g05._validate_command_plan(**call)

        (partial / "evidence/run-a").mkdir()
        with self.assertRaisesRegex(
            g05.G05CurrentSourceError,
            "run-a evidence root was staged before execution",
        ):
            with mock.patch.object(g05.shutil, "which", return_value="/usr/bin/true"):
                g05._validate_command_plan(**call)

    def test_bound_p05_and_quality_rows_execute_and_capture_real_results(self) -> None:
        repository, partial, instruction_root, plan = self._command_plan_case(
            "owned-execution-pass"
        )
        self._remove_owned_execution_artifacts(partial)
        with mock.patch.object(
            g05.subprocess,
            "run",
            side_effect=self._mock_p05_success,
        ) as run:
            g05._execute_bound_p05_runs(
                command_plan=plan,
                repository_root=repository,
                partial_root=partial,
                instruction_package_root=instruction_root,
                p00_baseline_commit=BASELINE_COMMIT,
            )
        self.assertEqual(run.call_count, 3)
        rows = {row["id"]: row for row in plan["commands"]}
        for invocation, identifier in zip(run.call_args_list, g05.RUN_NAMES):
            self.assertEqual(invocation.args[0], tuple(rows[identifier]["argv"]))
            self.assertEqual(invocation.kwargs["cwd"], repository)
            self.assertEqual(invocation.kwargs["env"], rows[identifier]["environment"])
            receipt = json.loads(
                (partial / "outputs" / f"{identifier}.result.json").read_bytes()
            )
            claimed = receipt.pop("receipt_sha256")
            self.assertEqual(claimed, g05.canonical_sha256(receipt))
            self.assertEqual(receipt["status"], "pass")
            self.assertEqual(receipt["actual_exit_status"], 0)
            self.assertEqual(receipt["command_id"], identifier)

        def quality_run(argv: tuple[str, ...], **_: object) -> SimpleNamespace:
            output = Path(argv[argv.index("--output") + 1])
            manifest = {"manifest_sha256": "a" * 64}
            self._write_json(output, manifest)
            return SimpleNamespace(
                returncode=0,
                stdout=f"{'a' * 64}\n".encode("ascii"),
                stderr=b"",
            )

        with mock.patch.object(
            g05.subprocess,
            "run",
            side_effect=quality_run,
        ) as quality_run_mock:
            g05._execute_bound_quality_locks(
                command_plan=plan,
                repository_root=repository,
                partial_root=partial,
                instruction_package_root=instruction_root,
                p00_baseline_commit=BASELINE_COMMIT,
            )
        self.assertEqual(quality_run_mock.call_count, 2)
        quality_ids = ("quality-lock-a", "quality-lock-b")
        for invocation, identifier in zip(
            quality_run_mock.call_args_list,
            quality_ids,
        ):
            self.assertEqual(invocation.args[0], tuple(rows[identifier]["argv"]))
            self.assertEqual(invocation.kwargs["cwd"], repository)
            self.assertEqual(invocation.kwargs["env"], rows[identifier]["environment"])
        for identifier in quality_ids:
            self.assertEqual(
                (partial / "outputs" / f"{identifier}.log").read_text(
                    encoding="ascii"
                ),
                f"{'a' * 64}\n",
            )
            self.assertEqual(
                (partial / "outputs" / f"{identifier}.stderr.log").read_bytes(),
                b"",
            )

    def test_second_and_third_p05_failures_preserve_command_receipts(self) -> None:
        for failure_index in (1, 2):
            with self.subTest(failure_index=failure_index):
                repository, partial, instruction_root, plan = self._command_plan_case(
                    f"owned-execution-failure-{failure_index}"
                )
                for identifier in g05.RUN_NAMES:
                    shutil.rmtree(partial / "evidence" / identifier)
                    (partial / "outputs" / f"{identifier}.log").unlink()
                calls = 0

                def execute(argv: tuple[str, ...], **kwargs: object) -> SimpleNamespace:
                    nonlocal calls
                    current = calls
                    calls += 1
                    if current == failure_index:
                        return SimpleNamespace(
                            returncode=7,
                            stdout=b"producer stdout before rejection\n",
                            stderr=b"producer rejected synthetic fixture\n",
                        )
                    return self._mock_p05_success(argv, **kwargs)

                with mock.patch.object(g05.subprocess, "run", side_effect=execute):
                    with self.assertRaisesRegex(
                        g05.G05CurrentSourceError,
                        "bound P05 command failed or emitted stderr",
                    ):
                        g05._execute_bound_p05_runs(
                            command_plan=plan,
                            repository_root=repository,
                            partial_root=partial,
                            instruction_package_root=instruction_root,
                            p00_baseline_commit=BASELINE_COMMIT,
                        )
                failed_identifier = g05.RUN_NAMES[failure_index]
                receipt = json.loads(
                    (
                        partial
                        / "outputs"
                        / f"{failed_identifier}.result.json"
                    ).read_bytes()
                )
                self.assertEqual(receipt["status"], "fail")
                self.assertEqual(receipt["actual_exit_status"], 7)
                self.assertEqual(
                    (
                        partial
                        / "outputs"
                        / f"{failed_identifier}.stderr.log"
                    ).read_bytes(),
                    b"producer rejected synthetic fixture\n",
                )
                for identifier in g05.RUN_NAMES[:failure_index]:
                    self.assertTrue(
                        (partial / "outputs" / f"{identifier}.result.json").is_file()
                    )
                for identifier in g05.RUN_NAMES[failure_index + 1 :]:
                    self.assertFalse(
                        os.path.lexists(
                            partial / "outputs" / f"{identifier}.result.json"
                        )
                    )

    def test_command_plan_enforces_contracts_and_result_contents(self) -> None:
        repository, partial, instruction_root, plan = self._command_plan_case(
            "command-plan"
        )
        call = {
            "repository_root": repository,
            "partial_root": partial,
            "instruction_package_root": instruction_root,
            "source_commit": SOURCE_COMMIT,
            "p00_baseline_commit": BASELINE_COMMIT,
        }
        with mock.patch.object(g05.shutil, "which", return_value="/usr/bin/true"):
            reopened = g05._validate_command_plan(**call)
        self.assertEqual(len(reopened["commands"]), 9)

        commands = plan["commands"]
        self.assertIsInstance(commands, list)
        swiftlint_command = next(
            command for command in commands if command["id"] == "swiftlint"
        )
        self.assertEqual(
            swiftlint_command["argv"][2:],
            ["--quiet", "--strict", "--reporter", "json", "--config", ".swiftlint.yml"],
        )
        (partial / "outputs/swiftlint.log").write_text(
            '[{"rule_id":"fixture"}]\n',
            encoding="utf-8",
        )
        with self.assertRaisesRegex(
            g05.G05CurrentSourceError,
            "empty violation array",
        ):
            with mock.patch.object(g05.shutil, "which", return_value="/usr/bin/true"):
                g05._validate_command_plan(**call)
        (partial / "outputs/swiftlint.log").write_text("[\n\n]\n", encoding="utf-8")
        original_argv = list(commands[0]["argv"])
        commands[0]["argv"] = [str(Path(g05.sys.executable).resolve()), "-V"]
        self._write_json(partial / "inputs/g05-command-plan.json", plan)
        with self.assertRaisesRegex(
            g05.G05CurrentSourceError,
            "canonical argv/cwd/environment/output contract",
        ):
            with mock.patch.object(g05.shutil, "which", return_value="/usr/bin/true"):
                g05._validate_command_plan(**call)

        commands[0]["argv"] = original_argv
        (partial / "outputs/run-a.log").write_text("forged pass\n", encoding="utf-8")
        self._write_json(partial / "inputs/g05-command-plan.json", plan)
        with self.assertRaisesRegex(
            g05.G05CurrentSourceError,
            "exact eight-file P05 result",
        ):
            with mock.patch.object(g05.shutil, "which", return_value="/usr/bin/true"):
                g05._validate_command_plan(**call)

    def test_command_plan_rejects_false_attribution_and_instruction_results(self) -> None:
        repository, partial, instruction_root, _ = self._command_plan_case(
            "command-result-rejection"
        )
        call = {
            "repository_root": repository,
            "partial_root": partial,
            "instruction_package_root": instruction_root,
            "source_commit": SOURCE_COMMIT,
            "p00_baseline_commit": BASELINE_COMMIT,
        }
        self._write_json(
            partial / "outputs/attribution.log",
            {
                "status": "pass",
                "base": BASELINE_COMMIT,
                "changed_file_count": 1,
                "findings": [{"scope": "fixture", "detail": "present"}],
            },
        )
        with self.assertRaisesRegex(
            g05.G05CurrentSourceError,
            "clean baseline-bound scan",
        ):
            with mock.patch.object(g05.shutil, "which", return_value="/usr/bin/true"):
                g05._validate_command_plan(**call)

        self._write_json(
            partial / "outputs/attribution.log",
            {
                "status": "pass",
                "base": BASELINE_COMMIT,
                "changed_file_count": 1,
                "findings": [],
            },
        )
        (partial / "outputs/instruction-package.log").write_text(
            "PASS\n",
            encoding="utf-8",
        )
        with self.assertRaisesRegex(
            g05.G05CurrentSourceError,
            "bound package closure",
        ):
            with mock.patch.object(g05.shutil, "which", return_value="/usr/bin/true"):
                g05._validate_command_plan(**call)

    def test_instruction_root_is_logical_and_attribution_includes_wrapper(self) -> None:
        repository, partial, instruction_root, plan = self._command_plan_case(
            "logical-instruction-root"
        )
        rows = {row["id"]: row for row in plan["commands"]}
        attribution = rows["attribution"]
        self.assertEqual(
            attribution["cwd"],
            g05.INSTRUCTION_PACKAGE_ROOT_TOKEN,
        )
        include_index = attribution["argv"].index("--include")
        self.assertEqual(
            attribution["argv"][include_index + 1],
            str(partial),
        )
        self.assertEqual(
            rows["instruction-package"]["cwd"],
            g05.INSTRUCTION_PACKAGE_ROOT_TOKEN,
        )
        raw_root = str(instruction_root).encode("utf-8")
        self.assertNotIn(raw_root, self._json_bytes(plan))

        paths = tuple(
            sorted((*g05._collect_files(partial), "inputs/provenance-map.json"))
        )
        provenance = g05._provenance_document(paths, plan)
        self.assertNotIn(raw_root, canonical_json_bytes(provenance))

        scan_payload = self._json_bytes(
            {
                "status": "pass",
                "base": BASELINE_COMMIT,
                "changed_file_count": 0,
                "findings": [],
            }
        )
        completed = SimpleNamespace(
            returncode=0,
            stdout=scan_payload,
            stderr=b"",
        )
        with mock.patch.object(g05.subprocess, "run", return_value=completed) as run:
            observed = g05._execute_bound_attribution(
                command_plan=plan,
                instruction_package_root=instruction_root,
                p00_baseline_commit=BASELINE_COMMIT,
            )
        self.assertEqual(observed, scan_payload)
        invocation = run.call_args
        self.assertEqual(invocation.kwargs["cwd"], instruction_root)
        self.assertIn("--include", invocation.args[0])
        self.assertIn(str(partial), invocation.args[0])

        replay_outputs = [
            (partial / "outputs/swiftlint.log").read_bytes(),
            (partial / "outputs/instruction-package.log").read_bytes(),
            (partial / "outputs/diff-check.log").read_bytes(),
        ]
        with mock.patch.object(
            g05,
            "_execute_captured_replay",
            side_effect=replay_outputs,
        ) as replay:
            g05._validate_live_command_replays(
                command_plan=plan,
                partial_root=partial,
                instruction_package_root=instruction_root,
                p00_baseline_commit=BASELINE_COMMIT,
            )
        self.assertEqual(
            [call.kwargs["identifier"] for call in replay.call_args_list],
            ["swiftlint", "instruction-package", "diff-check"],
        )
        with mock.patch.object(
            g05,
            "_execute_captured_replay",
            side_effect=g05.G05CurrentSourceError(
                "diff-check captured live replay differs or failed"
            ),
        ):
            with self.assertRaisesRegex(
                g05.G05CurrentSourceError,
                "captured live replay differs",
            ):
                g05._validate_live_command_replays(
                    command_plan=plan,
                    partial_root=partial,
                    instruction_package_root=instruction_root,
                    p00_baseline_commit=BASELINE_COMMIT,
                )

        rejected_scan = SimpleNamespace(
            returncode=1,
            stdout=self._json_bytes(
                {
                    "status": "fail",
                    "base": BASELINE_COMMIT,
                    "changed_file_count": 1,
                    "findings": [
                        {"scope": "content", "detail": "prohibited fixture"}
                    ],
                }
            ),
            stderr=b"",
        )
        with mock.patch.object(
            g05.subprocess,
            "run",
            return_value=rejected_scan,
        ):
            with self.assertRaisesRegex(
                g05.G05SetupError,
                "untrusted staged content",
            ):
                g05._execute_bound_attribution(
                    command_plan=plan,
                    instruction_package_root=instruction_root,
                    p00_baseline_commit=BASELINE_COMMIT,
                )

        for path in partial.rglob("*"):
            if path.is_file():
                self.assertNotIn(raw_root, path.read_bytes(), path)

    def test_run_identity_is_schema_bound_and_cross_checks_p05_components(self) -> None:
        repository, component_hashes = self._identity_repository(
            "identity-repository"
        )
        instruction_root = self._instruction_package("identity-instructions")
        partial = self.root / "identity-partial"
        self._write_json(
            partial / "inputs/upstream-bindings.json",
            {"fixture": "upstream"},
        )
        g05._copy_instruction_package_products(
            partial_root=partial,
            instruction_package_root=instruction_root,
        )
        arguments = argparse.Namespace(
            run_id=RUN_ID,
            started_utc=STARTED_UTC,
            configuration_sha256=CONFIGURATION_SHA256,
            synthetic_input_sha256=SYNTHETIC_INPUT_SHA256,
            synthetic_target_sha256=SYNTHETIC_TARGET_SHA256,
            p00_baseline_commit=BASELINE_COMMIT,
        )
        document = {
            "provenance": {
                "configuration_files": [
                    {"path": path, "sha256": digest}
                    for path, digest in component_hashes.items()
                ]
            }
        }
        closure = {
            "documents": {"state-fixtures.json": document},
            "provenance_manifest_sha256": {
                "configuration": CONFIGURATION_SHA256,
                "harness": SYNTHETIC_INPUT_SHA256,
            },
            "run_sha256": SYNTHETIC_TARGET_SHA256,
        }
        identity = g05._build_run_identity(
            arguments=arguments,
            repository_root=repository,
            partial_root=partial,
            instruction_package_root=instruction_root,
            source_commit=SOURCE_COMMIT,
            dirty_state_sha256=hashlib.sha256(b"").hexdigest(),
            toolchain=self._toolchain(),
            p00_baseline_binding=self._baseline_binding(),
            ended_utc="2026-07-15T12:30:00Z",
            outcome="pass",
            closure=closure,
        )
        self.assertEqual(identity["route"], "direct-both")
        self.assertEqual(
            identity["instruction_package"]["root"],
            g05.INSTRUCTION_PACKAGE_ROOT_TOKEN,
        )
        self.assertNotIn(
            str(instruction_root).encode("utf-8"),
            canonical_json_bytes(identity),
        )
        self.assertEqual(
            identity["routes_exercised"],
            ["direct_2x", "direct_3_over_2"],
        )
        self.assertEqual(
            identity["configuration_components"]["branch_lut"],
            {"status": "not_applicable_pre_g06", "sha256": None},
        )
        self.assertEqual(
            identity["identity_sha256"],
            g05.canonical_sha256(
                {key: value for key, value in identity.items() if key != "identity_sha256"}
            ),
        )

        altered = dict(closure)
        altered["provenance_manifest_sha256"] = {
            "configuration": "f" * 64,
            "harness": SYNTHETIC_INPUT_SHA256,
        }
        with self.assertRaisesRegex(
            g05.G05CurrentSourceError,
            "configuration hash differs",
        ):
            g05._build_run_identity(
                arguments=arguments,
                repository_root=repository,
                partial_root=partial,
                instruction_package_root=instruction_root,
                source_commit=SOURCE_COMMIT,
                dirty_state_sha256=hashlib.sha256(b"").hexdigest(),
                toolchain=self._toolchain(),
                p00_baseline_binding=self._baseline_binding(),
                ended_utc="2026-07-15T12:30:00Z",
                outcome="pass",
                closure=altered,
            )

    def test_gate_failure_uses_failed_finalizer_transaction_and_neutral_paths(self) -> None:
        repository, _ = self._identity_repository("failure-repository")
        instruction_root = self._instruction_package("failure-instructions")
        artifact_parent = repository / "Artifacts/ASH"
        artifact_parent.mkdir(parents=True)
        final = artifact_parent / (
            "20260715-direct-both-synthetic-p05-current-source-"
            f"{CONFIGURATION_SHA256[:8]}-{RUN_ID}"
        )
        partial = artifact_parent / f".{final.name}.partial"
        (partial / "inputs").mkdir(parents=True)
        (partial / "outputs").mkdir()
        preserved_result = b'{"fixture":"second-run-failure"}\n'
        (partial / "outputs/run-b.result.json").write_bytes(preserved_result)
        g03_root = self.root / "failure-g03"
        g04_root = self.root / "failure-g04"
        g03_root.mkdir()
        g04_root.mkdir()
        arguments = argparse.Namespace(
            repository_root=repository,
            partial_root=partial,
            final_root=final,
            expected_source_commit=SOURCE_COMMIT,
            g03_root=g03_root,
            g04_root=g04_root,
            instruction_package_root=instruction_root,
            run_id=RUN_ID,
            started_utc="2026-07-15T00:00:00Z",
            configuration_sha256=CONFIGURATION_SHA256,
            synthetic_input_sha256=SYNTHETIC_INPUT_SHA256,
            synthetic_target_sha256=SYNTHETIC_TARGET_SHA256,
            p00_baseline_commit=BASELINE_COMMIT,
        )

        def rename(source: Path, destination: Path, *, require_directory: bool) -> None:
            self.assertTrue(require_directory)
            source.rename(destination)

        failure = g05.G05CurrentSourceError(
            f"synthetic rejection at {instruction_root}"
        )
        output_paths = {
            "run-a": "outputs/run-a.log",
            "run-b": "outputs/run-b.log",
            "independent-run": "outputs/independent-run.log",
            "quality-lock-a": "outputs/quality-lock-a.log",
            "quality-lock-b": "outputs/quality-lock-b.log",
            "swiftlint": "outputs/swiftlint.log",
            "attribution": "outputs/attribution.log",
            "instruction-package": "outputs/instruction-package.log",
            "diff-check": "outputs/diff-check.log",
        }
        command_plan = {
            "commands": [
                {
                    "id": identifier,
                    "argv": [identifier],
                    "cwd": "{fixture-cwd}",
                    "environment": {},
                    "output_path": output_paths[identifier],
                }
                for identifier in g05.COMMAND_IDS
            ]
        }
        scan_payload = self._json_bytes(
            {
                "status": "pass",
                "base": BASELINE_COMMIT,
                "changed_file_count": 0,
                "findings": [],
            }
        )
        expected_failure = final.with_name(final.name + ".failed")
        expected_partial = expected_failure.parent / f".{expected_failure.name}.partial"

        def captured_attribution(**_: object) -> bytes:
            (partial / "outputs/attribution.log").write_bytes(scan_payload)
            (partial / "outputs/attribution.stderr.log").write_bytes(b"")
            self._write_json(
                partial / "outputs/attribution.result.json",
                {"fixture": "captured-attribution"},
            )
            return scan_payload

        def supplemental(**kwargs: object) -> tuple[dict[str, object], tuple[()]]:
            return (
                {"wrapper_paths": list(kwargs["wrapper_paths"])},
                (),
            )

        with mock.patch.object(
            g05,
            "_preflight",
            return_value=(
                repository,
                partial,
                final,
                g03_root,
                g04_root,
                instruction_root,
            ),
        ), mock.patch.object(
            g05,
            "_validate_repository_state",
            return_value=hashlib.sha256(b"").hexdigest(),
        ), mock.patch.object(
            g05,
            "_validate_baseline_commit",
            return_value=self._baseline_binding(),
        ), mock.patch.object(
            g05,
            "_toolchain_identity",
            return_value=self._toolchain(),
        ), mock.patch.object(
            g05,
            "_validate_command_plan",
            return_value=command_plan,
        ), mock.patch.object(
            g05,
            "_execute_captured_replay",
            side_effect=captured_attribution,
        ) as captured, mock.patch.object(
            g05,
            "_execute_bound_attribution",
            return_value=scan_payload,
        ) as scanner, mock.patch.object(
            g05,
            "_build_supplemental_scan_evidence",
            side_effect=supplemental,
        ), mock.patch.object(
            g05,
            "_validate_supplemental_wrapper_scan",
        ), \
        mock.patch.object(
            g05,
            "_validate_attribution_payload",
        ), mock.patch.object(
            g05,
            "_rename_owned_entry",
            side_effect=rename,
        ), mock.patch.object(
            g05,
            "finalize_evidence_wrapper",
            return_value=expected_failure,
        ) as finalizer, mock.patch.object(
            g05,
            "_strict_reopen_failure_wrapper",
        ) as strict_reopen:
            published = g05._publish_gate_failure(arguments, failure)

        self.assertEqual(published, expected_failure)
        finalizer.assert_called_once()
        strict_reopen.assert_called_once()
        self.assertEqual(finalizer.call_args.kwargs["partial"], expected_partial)
        self.assertEqual(finalizer.call_args.kwargs["final"], expected_failure)
        captured.assert_called_once()
        scanner.assert_called_once()
        classification = json.loads(
            (expected_partial / "g05-failure-classification.json").read_bytes()
        )
        self.assertEqual(classification["status"], "fail")
        self.assertEqual(
            classification["transaction"]["failure_namespace"],
            expected_failure.name,
        )
        self.assertNotIn(
            str(instruction_root),
            classification["error"]["message"],
        )
        identity = json.loads((expected_partial / "run-identity.json").read_bytes())
        self.assertEqual(identity["outcome"], "fail")
        self.assertEqual(
            identity["instruction_package"]["root"],
            g05.INSTRUCTION_PACKAGE_ROOT_TOKEN,
        )
        self.assertTrue((expected_partial / "inputs/provenance-map.json").is_file())
        self.assertEqual(
            json.loads((expected_partial / "outputs/attribution.log").read_bytes())[
                "status"
            ],
            "pass",
        )
        self.assertEqual(
            (expected_partial / "outputs/run-b.result.json").read_bytes(),
            preserved_result,
        )
        raw_root = str(instruction_root).encode("utf-8")
        for path in expected_partial.rglob("*"):
            if path.is_file():
                self.assertNotIn(raw_root, path.read_bytes(), path)

    def test_provenance_map_exactly_covers_and_includes_itself(self) -> None:
        _, partial, _, plan = self._command_plan_case("provenance")
        provenance_relative = "inputs/provenance-map.json"
        paths_before = g05._collect_files(partial)
        self.assertNotIn(provenance_relative, paths_before)
        expected = tuple(sorted((*paths_before, provenance_relative)))
        document = g05._provenance_document(expected, plan)
        payload = canonical_json_bytes(document) + b"\n"
        (partial / provenance_relative).write_bytes(payload)

        final_paths = g05._collect_files(partial)
        selectors = [row["exact_path"] for row in document["rules"]]
        self.assertEqual(final_paths, expected)
        self.assertEqual(selectors, list(expected))
        self.assertEqual(selectors.count(provenance_relative), 1)
        self.assertEqual(len(selectors), len(set(selectors)))
        self.assertTrue(all("path_prefix" not in row for row in document["rules"]))
        self.assertEqual(
            json.loads((partial / provenance_relative).read_bytes()),
            document,
        )
        with self.assertRaisesRegex(
            g05.G05CurrentSourceError,
            "no exact producer provenance exists",
        ):
            g05._provenance_document(("unknown/success-artifact.json",), plan)

    def test_supplemental_scan_covers_python_names_and_log_content(self) -> None:
        fragment = "".join(("open", "ai"))
        patterns = (
            g05.re.compile(g05.re.escape(fragment), flags=g05.re.IGNORECASE),
        )
        with self.assertRaisesRegex(
            g05.G05SetupError,
            "filename scan rejected",
        ):
            g05._supplemental_match(
                logical_path="validation/" + fragment + ".py",
                payload=b"synthetic fixture\n",
                patterns=patterns,
            )
        with self.assertRaisesRegex(
            g05.G05SetupError,
            "text scan rejected",
        ):
            g05._supplemental_match(
                logical_path="outputs/synthetic.log",
                payload=("marker=" + fragment + "\n").encode("utf-8"),
                patterns=patterns,
            )
        with self.assertRaisesRegex(
            g05.G05SetupError,
            "filename scan rejected",
        ):
            g05._supplemental_match(
                logical_path="validation/" + fragment + ".py",
                payload=b"\0binary",
                patterns=patterns,
            )

    def test_diff_replay_executes_and_records_zero_byte_streams(self) -> None:
        _, partial, instruction_root, plan = self._command_plan_case(
            "captured-diff-replay"
        )
        row = g05._command_row(plan, "diff-check")
        completed = SimpleNamespace(returncode=0, stdout=b"", stderr=b"")
        ended_utc = "2026-07-15T12:00:01Z"
        with mock.patch.object(
            g05.subprocess,
            "run",
            return_value=completed,
        ) as run, mock.patch.object(
            g05,
            "_utc_now",
            side_effect=(STARTED_UTC, ended_utc),
        ):
            observed = g05._execute_captured_replay(
                command_plan=plan,
                partial_root=partial,
                instruction_package_root=instruction_root,
                p00_baseline_commit=BASELINE_COMMIT,
                identifier="diff-check",
                stdout_must_exist=True,
            )
        self.assertEqual(observed, b"")
        self.assertEqual(run.call_args.args[0], tuple(row["argv"]))
        self.assertEqual(run.call_args.kwargs["cwd"], Path(row["cwd"]))
        receipt = json.loads(
            (partial / "outputs/diff-check.result.json").read_bytes()
        )
        self.assertEqual(receipt["status"], "pass")
        self.assertEqual(receipt["started_utc"], STARTED_UTC)
        self.assertEqual(receipt["ended_utc"], ended_utc)
        self.assertEqual(receipt["actual_exit_status"], 0)
        self.assertEqual(receipt["stdout"]["size_bytes"], 0)
        self.assertEqual(receipt["stderr"]["size_bytes"], 0)

    def test_command_aggregate_binds_zero_streams_and_rejects_omission_or_hash_change(
        self,
    ) -> None:
        _, partial, instruction_root, plan = self._command_plan_case(
            "command-aggregate"
        )
        g05._copy_instruction_package_products(
            partial_root=partial,
            instruction_package_root=instruction_root,
        )
        self._write_json(
            partial / "run-identity.json",
            {
                "started_utc": STARTED_UTC,
                "ended_utc": "2026-07-15T12:00:20Z",
            },
        )
        for index, identifier in enumerate(g05.COMMAND_IDS):
            row = g05._command_row(plan, identifier)
            stderr_path = partial / "outputs" / f"{identifier}.stderr.log"
            stderr_path.write_bytes(b"")
            products = [
                g05._artifact_binding(
                    partial,
                    partial.joinpath(*Path(relative).parts),
                    f"{identifier} fixture product",
                )
                for relative in g05._expected_command_products(identifier)
            ]
            g05._write_command_result_receipt(
                partial_root=partial,
                row=row,
                identifier=identifier,
                started_utc=f"2026-07-15T12:00:{index:02d}Z",
                ended_utc=f"2026-07-15T12:00:{index:02d}Z",
                actual_exit_status=int(row["exit_status"]),
                status="pass",
                stdout_path=partial / str(row["output_path"]),
                stderr_path=stderr_path,
                produced_artifacts=products,
            )
        aggregate = g05._build_command_execution_aggregate(
            partial_root=partial,
            command_plan=plan,
            source_commit=SOURCE_COMMIT,
        )
        aggregate_path = partial / g05.COMMAND_AGGREGATE_RELATIVE
        self._write_json(aggregate_path, aggregate)
        g05._validate_command_execution_aggregate(
            wrapper_root=partial,
            command_plan=plan,
            source_commit=SOURCE_COMMIT,
        )

        result_path = partial / "outputs/diff-check.result.json"
        result_payload = result_path.read_bytes()
        result_path.unlink()
        with self.assertRaises((OSError, g05.G05CurrentSourceError)):
            g05._validate_command_execution_aggregate(
                wrapper_root=partial,
                command_plan=plan,
                source_commit=SOURCE_COMMIT,
            )
        result_path.write_bytes(result_payload)

        changed = copy.deepcopy(aggregate)
        diff_row = next(
            row for row in changed["commands"] if row["id"] == "diff-check"
        )
        diff_row["stderr"]["sha256"] = "f" * 64
        changed_body = dict(changed)
        changed_body.pop("aggregate_sha256")
        changed["aggregate_sha256"] = g05.canonical_sha256(changed_body)
        self._write_json(aggregate_path, changed)
        with self.assertRaisesRegex(
            g05.G05CurrentSourceError,
            "diff-check stderr binding differs",
        ):
            g05._validate_command_execution_aggregate(
                wrapper_root=partial,
                command_plan=plan,
                source_commit=SOURCE_COMMIT,
            )

    def test_authoritative_baseline_records_and_ancestry_are_both_required(self) -> None:
        repository = self.root / "baseline-repository"
        (repository / "validation/calibration_v2/native_adapter").mkdir(parents=True)
        self._write_json(
            repository / "audit-result.json",
            {"attribution_scan": {"base": BASELINE_COMMIT}},
        )
        (repository / "local-work-plan.md").write_text(
            f"Baseline commit: `{BASELINE_COMMIT}`\n",
            encoding="utf-8",
        )
        (repository / "validation/calibration_v2/production_evaluator.py").write_text(
            f'P00_COMMIT = "{BASELINE_COMMIT}"\n',
            encoding="utf-8",
        )
        (repository / "validation/calibration_v2/native_adapter/factory.py").write_text(
            f'_P00_COMMIT = "{BASELINE_COMMIT}"\n',
            encoding="utf-8",
        )
        with mock.patch.object(g05, "_run_git", return_value=b"") as git:
            binding = g05._validate_baseline_commit(
                repository,
                BASELINE_COMMIT,
                SOURCE_COMMIT,
            )
        self.assertEqual(binding["status"], "pass")
        self.assertEqual(len(binding["tracked_records"]), 4)
        self.assertIn(
            ("merge-base", "--is-ancestor", BASELINE_COMMIT, SOURCE_COMMIT),
            [call.args[1] for call in git.call_args_list],
        )

        mismatch = "6" * 40
        (repository / "validation/calibration_v2/native_adapter/factory.py").write_text(
            f'_P00_COMMIT = "{mismatch}"\n',
            encoding="utf-8",
        )
        with mock.patch.object(g05, "_run_git", return_value=b""):
            with self.assertRaisesRegex(
                g05.G05SetupError,
                "differs from current tracked baseline records",
            ):
                g05._validate_baseline_commit(
                    repository,
                    BASELINE_COMMIT,
                    SOURCE_COMMIT,
                )

        (repository / "validation/calibration_v2/native_adapter/factory.py").write_text(
            f'_P00_COMMIT = "{BASELINE_COMMIT}"\n',
            encoding="utf-8",
        )

        def reject_ancestry(_: Path, arguments: tuple[str, ...]) -> bytes:
            if arguments[:2] == ("merge-base", "--is-ancestor"):
                raise g05.G05SetupError("synthetic ancestry rejection")
            return b""

        with mock.patch.object(g05, "_run_git", side_effect=reject_ancestry):
            with self.assertRaisesRegex(
                g05.G05SetupError,
                "synthetic ancestry rejection",
            ):
                g05._validate_baseline_commit(
                    repository,
                    BASELINE_COMMIT,
                    SOURCE_COMMIT,
                )

    def test_live_preopen_failure_sanitizes_paths_and_does_not_claim_unopened(
        self,
    ) -> None:
        live_path = self.root / "caller-private" / "live-ledger.json"
        arguments = argparse.Namespace(
            run_id=RUN_ID,
            live_ledger_path=live_path,
        )
        observed_error: BaseException
        try:
            raise g05.LiveHoldoutPreopenError(
                "verification failed at " + str(live_path)
            )
        except g05.LiveHoldoutPreopenError as error:
            observed_error = error
        classification = g05._failure_classification(
            arguments=arguments,
            partial_root=self.root / ".failure.partial",
            final_root=self.root / "failure",
            instruction_package_root=self.root / "instructions",
            error=observed_error,
            ended_utc=STARTED_UTC,
        )
        self.assertIsNone(classification["holdout_accessed"])
        self.assertEqual(
            classification["holdout_access_status"],
            "unknown_not_proven_unopened",
        )
        self.assertFalse(classification["assessor_pixel_accessed"])
        serialized = canonical_json_bytes(classification)
        self.assertNotIn(str(live_path).encode("utf-8"), serialized)
        self.assertIn(b"{live-ledger-path}", serialized)

    def _finalized_g05_contract_case(
        self,
        name: str,
    ) -> tuple[
        Path,
        dict[str, object],
        tuple[str, ...],
        tuple[str, ...],
        dict[str, object],
        dict[str, object],
    ]:
        _, root, _, plan = self._command_plan_case(name)
        provenance_relative = "inputs/provenance-map.json"
        expected_pre_final = tuple(
            sorted((*g05._collect_files(root), provenance_relative))
        )
        provenance = g05._provenance_document(expected_pre_final, plan)
        self._write_json(root / provenance_relative, provenance)
        expected_directories = g05._collect_directories(root)
        root_metadata = os.lstat(root)
        transaction: dict[str, object] = {
            "schema_version": "1.0.0",
            "artifact_kind": "evidence_wrapper_publication_transaction",
            "transaction_token": "a" * 32,
            "created_utc": STARTED_UTC,
            "project_commit": SOURCE_COMMIT,
            "partial_name": f".{root.name}.partial",
            "final_name": root.name,
            "failure_name": f"{root.name}.failed",
            "gate_ids": ["G05", "P05"],
            "root_device": root_metadata.st_dev,
            "root_inode": root_metadata.st_ino,
        }
        transaction_payload = self._write_json(
            root / "publication-transaction.json",
            transaction,
        )
        provenance_by_path = {
            str(rule["exact_path"]): rule for rule in provenance["rules"]
        }
        rows: list[dict[str, object]] = []
        for relative in expected_pre_final:
            payload = (root / relative).read_bytes()
            rule = provenance_by_path[relative]
            rows.append(
                {
                    **self._artifact_row(relative, payload),
                    "producer": rule["producer"],
                    "gate_ids": rule["gate_ids"],
                    "command": rule["command"],
                    "platform": rule["platform"],
                    "machine": rule["machine"],
                }
            )
        rows.append(
            {
                **self._artifact_row(
                    "publication-transaction.json",
                    transaction_payload,
                ),
                "producer": "Mirmir evidence-wrapper recovery",
                "gate_ids": ["G05", "P05"],
                "command": "finalize_evidence_wrapper transaction recovery",
                "platform": g05.platform.platform(),
                "machine": g05.platform.node()
                or g05.platform.machine()
                or "unknown-machine",
            }
        )
        rows.sort(key=lambda row: str(row["path"]))
        manifest: dict[str, object] = {
            "schema_version": "2.0.0",
            "created_utc": STARTED_UTC,
            "project_commit": SOURCE_COMMIT,
            "working_tree_clean": True,
            "directories": list(expected_directories),
            "artifacts": rows,
        }
        self._write_json(root / "artifact-manifest.json", manifest)
        return (
            root,
            plan,
            expected_pre_final,
            expected_directories,
            transaction,
            manifest,
        )

    def test_finalized_g05_contract_authenticates_manifest_and_transaction(
        self,
    ) -> None:
        for name in ("final-contract", "final-contract.failed"):
            with self.subTest(namespace=name):
                root, plan, paths, directories, _, _ = (
                    self._finalized_g05_contract_case(name)
                )
                root_metadata = os.lstat(root)
                self.assertEqual(
                    g05._validate_g05_finalized_manifest_and_transaction(
                        root=root,
                        publication_name=root.name,
                        source_commit=SOURCE_COMMIT,
                        expected_pre_final=paths,
                        expected_directories=directories,
                        expected_root_identity=(
                            root_metadata.st_dev,
                            root_metadata.st_ino,
                        ),
                        expected_command_plan=plan,
                        label="fixture G05 wrapper",
                    ),
                    plan,
                )

        root, plan, paths, directories, transaction, manifest = (
            self._finalized_g05_contract_case("final-contract-mutations")
        )
        transaction_path = root / "publication-transaction.json"
        manifest_path = root / "artifact-manifest.json"
        root_metadata = os.lstat(root)
        root_identity = (root_metadata.st_dev, root_metadata.st_ino)

        def validate(
            *,
            expected_root_identity: tuple[int, int] = root_identity,
            expected_command_plan: dict[str, object] | None = plan,
        ) -> None:
            g05._validate_g05_finalized_manifest_and_transaction(
                root=root,
                publication_name=root.name,
                source_commit=SOURCE_COMMIT,
                expected_pre_final=paths,
                expected_directories=directories,
                expected_root_identity=expected_root_identity,
                expected_command_plan=expected_command_plan,
                label="fixture G05 wrapper",
            )

        def write_transaction(
            document: dict[str, object],
            *,
            payload: bytes | None = None,
        ) -> None:
            transaction_payload = payload or self._write_json(
                transaction_path,
                document,
            )
            if payload is not None:
                transaction_path.write_bytes(payload)
            rebound_manifest = copy.deepcopy(manifest)
            transaction_row = next(
                row
                for row in rebound_manifest["artifacts"]
                if row["path"] == "publication-transaction.json"
            )
            transaction_row["sha256"] = hashlib.sha256(
                transaction_payload
            ).hexdigest()
            transaction_row["size_bytes"] = len(transaction_payload)
            self._write_json(manifest_path, rebound_manifest)

        with self.assertRaisesRegex(
            g05.G05CurrentSourceError,
            "transaction identity, commit, gates, or root differs",
        ):
            validate(
                expected_root_identity=(root_identity[0], root_identity[1] + 1)
            )

        manifest_path.write_bytes(
            json.dumps(manifest, indent=2, sort_keys=True).encode("utf-8")
        )
        with self.assertRaisesRegex(
            g05.G05CurrentSourceError,
            "manifest is not canonical JSON",
        ):
            validate()

        for name, mutate, message in (
            (
                "schema",
                lambda value: value.pop("schema_version"),
                "manifest schema validation failed",
            ),
            (
                "directories",
                lambda value: value.update({"directories": []}),
                "directory, or artifact closure differs",
            ),
            (
                "path-provenance",
                lambda value: value["artifacts"][0].update(
                    {"producer": "forged producer"}
                ),
                "binding or provenance differs",
            ),
            (
                "transaction-provenance",
                lambda value: next(
                    row
                    for row in value["artifacts"]
                    if row["path"] == "publication-transaction.json"
                ).update({"command": "forged finalizer"}),
                "transaction manifest binding or provenance differs",
            ),
        ):
            with self.subTest(manifest=name):
                changed = copy.deepcopy(manifest)
                mutate(changed)
                self._write_json(manifest_path, changed)
                with self.assertRaisesRegex(g05.G05CurrentSourceError, message):
                    validate()

        self._write_json(transaction_path, transaction)
        self._write_json(manifest_path, manifest)
        forged_plan = copy.deepcopy(plan)
        forged_plan["source_commit"] = "0" * 40
        forged_plan_payload = self._write_json(
            root / "inputs/g05-command-plan.json",
            forged_plan,
        )
        rebound_manifest = copy.deepcopy(manifest)
        plan_row = next(
            row
            for row in rebound_manifest["artifacts"]
            if row["path"] == "inputs/g05-command-plan.json"
        )
        plan_row["sha256"] = hashlib.sha256(forged_plan_payload).hexdigest()
        plan_row["size_bytes"] = len(forged_plan_payload)
        self._write_json(manifest_path, rebound_manifest)
        with self.assertRaisesRegex(
            g05.G05CurrentSourceError,
            "command plan source commit",
        ):
            validate(expected_command_plan=None)
        self._write_json(root / "inputs/g05-command-plan.json", plan)
        self._write_json(manifest_path, manifest)

        transaction_mutations = (
            ("token", "transaction_token", "not-a-token"),
            ("commit", "project_commit", "0" * 40),
            ("partial", "partial_name", ".forged.partial"),
            ("final", "final_name", "forged-final"),
            ("failure", "failure_name", "forged.failed"),
            ("gates", "gate_ids", ["G05"]),
            ("negative-device", "root_device", -1),
            (
                "positive-device",
                "root_device",
                int(transaction["root_device"]) + 1,
            ),
            ("inode", "root_inode", int(transaction["root_inode"]) + 1),
        )
        for name, field, value in transaction_mutations:
            with self.subTest(transaction=name):
                changed = dict(transaction)
                changed[field] = value
                write_transaction(changed)
                with self.assertRaisesRegex(
                    g05.G05CurrentSourceError,
                    "transaction identity, commit, gates, or root differs",
                ):
                    validate()

        noncanonical_transaction = json.dumps(
            transaction,
            indent=2,
            sort_keys=True,
        ).encode("utf-8")
        write_transaction(transaction, payload=noncanonical_transaction)
        with self.assertRaisesRegex(
            g05.G05CurrentSourceError,
            "transaction identity, commit, gates, or root differs",
        ):
            validate()

    def test_strict_sealed_reopen_rejects_late_semantic_mutation(self) -> None:
        final_root = self.root / "sealed-reopen"
        (final_root / "inputs").mkdir(parents=True)
        (final_root / "outputs").mkdir()
        expected_pre_final = tuple(
            sorted(
                (
                    g05.SEMANTIC_BINDINGS_RELATIVE,
                    "inputs/g05-command-plan.json",
                    "inputs/upstream-bindings.json",
                    "outputs/supplemental-content-scan.json",
                    "receipt.json",
                    "run-identity.json",
                )
            )
        )
        plan = {"fixture": "command-plan"}
        upstream = {"live_preopen_metadata": {"fixture": "metadata"}}
        supplemental = {"fixture": "supplemental"}
        identity_body = {
            "source_commit": SOURCE_COMMIT,
            "p00_baseline": {"baseline_commit": BASELINE_COMMIT},
        }
        identity = {
            **identity_body,
            "identity_sha256": g05.canonical_sha256(identity_body),
        }
        self._write_json(final_root / "inputs/g05-command-plan.json", plan)
        self._write_json(final_root / "inputs/upstream-bindings.json", upstream)
        self._write_json(
            final_root / "outputs/supplemental-content-scan.json",
            supplemental,
        )
        self._write_json(final_root / "receipt.json", {"fixture": "receipt"})
        self._write_json(final_root / "run-identity.json", identity)
        (final_root / "publication-transaction.json").write_bytes(
            b'{"status":"pass"}\n'
        )
        with mock.patch.object(
            g05,
            "_success_wrapper_paths",
            return_value=expected_pre_final,
        ):
            snapshot = g05._build_semantic_bindings_snapshot(
                partial_root=final_root,
                source_commit=SOURCE_COMMIT,
                expected_paths=expected_pre_final,
                candidate_files={},
            )
        self._write_json(
            final_root / g05.SEMANTIC_BINDINGS_RELATIVE,
            snapshot,
        )
        expected_final = tuple(
            sorted(
                (
                    *expected_pre_final,
                    "artifact-manifest.json",
                    "publication-transaction.json",
                )
            )
        )

        def manifest_document() -> dict[str, object]:
            rows: list[dict[str, object]] = []
            for relative in expected_final:
                if relative == "artifact-manifest.json":
                    continue
                payload = (final_root / relative).read_bytes()
                rows.append(
                    {
                        "path": relative,
                        "sha256": hashlib.sha256(payload).hexdigest(),
                        "size_bytes": len(payload),
                        "gate_ids": ["G05", "P05"],
                    }
                )
            return {
                "project_commit": SOURCE_COMMIT,
                "working_tree_clean": True,
                "artifacts": rows,
            }

        manifest_path = final_root / "artifact-manifest.json"
        self._write_json(manifest_path, manifest_document())
        patches = (
            mock.patch.object(g05, "_success_wrapper_paths", return_value=expected_pre_final),
            mock.patch.object(g05, "_collect_sealed_files", return_value=expected_final),
            mock.patch.object(g05, "_validate_schema_document"),
            mock.patch.object(g05, "_validate_command_execution_aggregate"),
            mock.patch.object(g05, "validate_g05_receipt"),
            mock.patch.object(g05, "validate_g05_upstream_bindings"),
            mock.patch.object(g05, "_validate_live_metadata_closure"),
            mock.patch.object(g05, "validate_g05_evidence", return_value={}),
            mock.patch.object(g05, "_validate_quality_locks", return_value={"status": "pass"}),
            mock.patch.object(
                g05,
                "_build_supplemental_scan_evidence",
                return_value=(supplemental, ()),
            ),
            mock.patch.object(
                g05,
                "_validate_g05_finalized_manifest_and_transaction",
                return_value=plan,
            ),
        )
        with patches[0], patches[1], patches[2], patches[3], patches[4], patches[5], patches[6], patches[7], patches[8], patches[9], patches[10]:
            g05._strict_reopen_final_wrapper(
                repository_root=self.root,
                final_root=final_root,
                instruction_package_root=self.root,
                source_commit=SOURCE_COMMIT,
                baseline_commit=BASELINE_COMMIT,
                command_plan=plan,
                expected_p05_closure={},
                expected_root_identity=(
                    os.lstat(final_root).st_dev,
                    os.lstat(final_root).st_ino,
                ),
            )
            self._write_json(
                final_root / "receipt.json",
                {"fixture": "late-semantic-mutation"},
            )
            self._write_json(manifest_path, manifest_document())
            with self.assertRaisesRegex(
                g05.G05CurrentSourceError,
                "semantic file binding differs for receipt.json",
            ):
                g05._strict_reopen_final_wrapper(
                    repository_root=self.root,
                    final_root=final_root,
                    instruction_package_root=self.root,
                    source_commit=SOURCE_COMMIT,
                    baseline_commit=BASELINE_COMMIT,
                    command_plan=plan,
                    expected_p05_closure={},
                    expected_root_identity=(
                        os.lstat(final_root).st_dev,
                        os.lstat(final_root).st_ino,
                    ),
                )

    def _live_metadata_case(
        self,
        name: str,
    ) -> tuple[argparse.Namespace, dict[str, str], tuple[bytes, ...]]:
        source_root = self.root / f"{name}-sources"
        source_root.mkdir()
        payloads = (
            b'{"kind":"live-ledger","events":[]}\n',
            b'{"kind":"preopen-receipt","access_count":0}\n',
            b'{"kind":"sealed-copy","events":[]}\n',
            b'{"kind":"attestation","pixel_content_included":false}\n',
        )
        paths = (
            source_root / "holdout-access-ledger.p06-spatial-v2.json",
            source_root / "holdout-preopen-receipt.p06-spatial-v2.json",
            source_root / "repository-sealed-holdout-access-ledger.json",
            source_root / "repository-holdout-seal-attestation.json",
        )
        for path, payload in zip(paths, payloads):
            path.write_bytes(payload)
        arguments = argparse.Namespace(
            live_preopen_version_id="p06-spatial-v2",
            live_ledger_path=paths[0],
            live_preopen_receipt_path=paths[1],
            repository_sealed_copy_path=paths[2],
            repository_attestation_path=paths[3],
        )
        verification = {
            "live_ledger_sha256": hashlib.sha256(payloads[0]).hexdigest(),
            "live_preopen_receipt_sha256": hashlib.sha256(payloads[1]).hexdigest(),
            "repository_sealed_copy_sha256": hashlib.sha256(payloads[2]).hexdigest(),
            "repository_attestation_sha256": hashlib.sha256(payloads[3]).hexdigest(),
        }
        return arguments, verification, payloads

    def test_live_metadata_copy_binds_verified_hashes_and_rejects_mutation(self) -> None:
        arguments, verification, payloads = self._live_metadata_case("live-pass")
        partial = self.root / "live-pass-wrapper"
        (partial / "inputs/live-preopen").mkdir(parents=True)
        copied = g05._copy_live_metadata(arguments, partial, verification)
        self.assertTrue(copied["metadata_only"])
        self.assertFalse(copied["pixel_content_included"])
        self.assertEqual(len(copied["bindings"]), 4)
        for binding, payload in zip(copied["bindings"], payloads):
            self.assertFalse(Path(binding["path"]).is_absolute())
            self.assertTrue(binding["path"].startswith("inputs/live-preopen/"))
            self.assertEqual(binding["sha256"], hashlib.sha256(payload).hexdigest())
            self.assertEqual(binding["size_bytes"], len(payload))
        g05._validate_live_metadata_closure(copied, partial)
        first_copy = partial / copied["bindings"][0]["path"]
        first_copy.write_bytes(b'{"kind":"live-ledger","events":["changed"]}\n')
        with self.assertRaisesRegex(
            g05.G05CurrentSourceError,
            "differs from its copied file",
        ):
            g05._validate_live_metadata_closure(copied, partial)

        changed_arguments, changed_verification, _ = self._live_metadata_case(
            "live-mutated"
        )
        changed_arguments.live_ledger_path.write_bytes(
            b'{"kind":"live-ledger","events":["changed"]}\n'
        )
        changed_partial = self.root / "live-mutated-wrapper"
        (changed_partial / "inputs/live-preopen").mkdir(parents=True)
        with self.assertRaisesRegex(
            g05.G05CurrentSourceError,
            "differs from the verified preopen snapshot",
        ):
            g05._copy_live_metadata(
                changed_arguments,
                changed_partial,
                changed_verification,
            )


if __name__ == "__main__":
    unittest.main()
