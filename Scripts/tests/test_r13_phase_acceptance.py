#!/usr/bin/env python3
"""Focused fixture and fail-closed tests for R13 acceptance evidence."""

from __future__ import annotations

import base64
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
from contextlib import redirect_stderr
import shutil
import stat
import subprocess
import tempfile
import unittest
from unittest import mock
import zipfile


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]

from Scripts import r13_phase_acceptance as r13  # noqa: E402


def _run_git(root: Path, *arguments: str) -> str:
    result = subprocess.run(
        ["/usr/bin/git", "-C", os.fspath(root), *arguments],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    return result.stdout.strip()


def _write(path: Path, payload: str | bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if isinstance(payload, bytes):
        path.write_bytes(payload)
    else:
        path.write_text(payload, encoding="utf-8")


def _tool(name: str) -> dict[str, str]:
    paths = {
        "swift": "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift",
        "swiftlint": "/opt/homebrew/bin/swiftlint",
        "xcodebuild": "/usr/bin/xcodebuild",
        "xcrun": "/usr/bin/xcrun",
    }
    return {
        "executable_path": paths[name],
        "executable_sha256": hashlib.sha256(name.encode("ascii")).hexdigest(),
        "name": name,
        "version": f"{name} fixture 1.0",
    }


class FixtureVerifier(r13.R13PhaseAcceptanceVerifier):
    """Uses real Git/checkpoint validation and deterministic command captures."""

    @classmethod
    def _tool_identity(cls, name: str) -> dict[str, str]:
        return _tool(name)

    def _canonical_predecessor_errors(self) -> list[str]:
        return []

    def _predecessor_bindings(
        self,
        source: dict[str, str],
    ) -> list[dict[str, object]]:
        return [
            {
                "acceptance_scope": r13.ACCEPTANCE_SCOPE,
                "accepted_source": dict(source),
                "functional_phase_acceptance": {
                    "path": (
                        "docs/roadmaps/evidence/"
                        f"{phase.lower()}/records/"
                        "functional-phase-acceptance.json"
                    ),
                    "sha256": hashlib.sha256(
                        phase.encode("ascii")
                    ).hexdigest(),
                    "size_bytes": len(phase),
                },
                "phase_id": phase,
                "phase_result": "passed",
            }
            for phase in ("R11", "R12")
        ]

    @staticmethod
    def _checkpoint(
        source: dict[str, str],
    ) -> dict[str, object]:
        return {
            "clean_after": True,
            "clean_before": True,
            "commit_after": source["commit"],
            "commit_before": source["commit"],
            "kind": r13._CHECKPOINT_KIND,
            "tree_after": source["tree"],
            "tree_before": source["tree"],
        }

    def _identity(
        self,
        *,
        source: dict[str, str],
        command_id: str,
        command: str,
        tool_name: str,
        argv: list[str],
    ) -> dict[str, object]:
        return {
            "argv": argv,
            "checkpoint": self._checkpoint(source),
            "command": command,
            "command_id": command_id,
            "exit_code": 0,
            "source": dict(source),
            "tool": _tool(tool_name),
        }

    def _log(
        self,
        identity: dict[str, object],
        body: str,
    ) -> bytes:
        return (
            self._execution_identity_header(identity) + "\n" + body
        ).encode("utf-8")

    @staticmethod
    def _app_and_archive() -> tuple[dict[str, object], bytes]:
        info_plist = plistlib.dumps(
            {
                "CFBundleExecutable": "Mirmir",
                "CFBundleIdentifier": "com.mirmir.fixture",
                "CFBundleShortVersionString": "1.0",
                "CFBundleVersion": "1",
            },
            fmt=plistlib.FMT_XML,
            sort_keys=True,
        )
        files = {
            "Contents/Info.plist": info_plist,
            "Contents/MacOS/Mirmir": b"fixture-executable",
        }
        modes = {
            "Contents/Info.plist": 0o644,
            "Contents/MacOS/Mirmir": 0o755,
        }
        manifest = [
            {
                "mode": modes[path],
                "path": path,
                "sha256": hashlib.sha256(payload).hexdigest(),
                "size_bytes": len(payload),
            }
            for path, payload in sorted(files.items())
        ]
        def binding(path: str) -> dict[str, object]:
            entry = next(item for item in manifest if item["path"] == path)
            return {
                "path": path,
                "sha256": entry["sha256"],
                "size_bytes": entry["size_bytes"],
            }
        app = {
            "bundle": {
                "build_version": "1",
                "bundle_identifier": "com.mirmir.fixture",
                "executable": binding("Contents/MacOS/Mirmir"),
                "executable_name": "Mirmir",
                "info_plist": binding("Contents/Info.plist"),
                "short_version": "1.0",
            },
            "bundle_path": (
                "<outside-repository>/DerivedData/"
                "Build/Products/Release/Mirmir.app"
            ),
            "file_count": len(manifest),
            "file_manifest": manifest,
            "frameworks": {
                "entries": [],
                "status": "none_embedded",
                "tree_sha256": hashlib.sha256(b"[]").hexdigest(),
            },
            "total_size_bytes": sum(
                int(item["size_bytes"]) for item in manifest
            ),
            "tree_sha256": hashlib.sha256(
                r13._canonical_compact_json(manifest)
            ).hexdigest(),
        }
        archive = r13.R13PhaseAcceptanceVerifier._canonical_candidate_archive_payload(
            [
                (path, modes[path], payload)
                for path, payload in sorted(files.items())
            ]
        )
        return app, archive

    def _run_checkpoint_commands(
        self,
        source: dict[str, str],
        tools: dict[str, dict[str, str]],
        inventory: r13.TestInventory,
    ) -> r13.CapturedExecution:
        del tools
        test_derived = "/private/tmp/r13-fixture/Test/DerivedData"
        release_derived = "/private/tmp/r13-fixture/Release/DerivedData"
        xctestrun = (
            test_derived + "/Build/Products/Mirmir_macosx.xctestrun"
        )
        build_identity = self._identity(
            source=source,
            command_id="build_for_testing",
            command=r13.BUILD_FOR_TESTING_COMMAND,
            tool_name="xcodebuild",
            argv=self._build_for_testing_arguments(
                _tool("xcodebuild")["executable_path"],
                source,
                test_derived,
            ),
        )
        test_identity = self._identity(
            source=source,
            command_id="targeted_tests",
            command=r13.TARGETED_TEST_COMMAND,
            tool_name="xcodebuild",
            argv=self._targeted_test_arguments(
                _tool("xcodebuild")["executable_path"],
                source,
                xctestrun,
                inventory,
            ),
        )
        release_identity = self._identity(
            source=source,
            command_id="release_app_build",
            command=r13.RELEASE_BUILD_COMMAND,
            tool_name="xcodebuild",
            argv=self._release_build_arguments(
                _tool("xcodebuild")["executable_path"],
                source,
                release_derived,
            ),
        )
        lint_identity = self._identity(
            source=source,
            command_id="swiftlint",
            command=r13.LINT_COMMAND,
            tool_name="swiftlint",
            argv=self._lint_arguments(
                _tool("swiftlint")["executable_path"]
            ),
        )
        reopen_identity = self._identity(
            source=source,
            command_id="output_reopen",
            command=r13.OUTPUT_REOPEN_COMMAND,
            tool_name="xcrun",
            argv=[
                _tool("xcrun")["executable_path"],
                "swift",
                "/private/tmp/r13-fixture/r13-output-reopen.swift",
                (
                    "/private/tmp/r13-fixture/"
                    "r13-output-reopen-fixture.mov"
                ),
            ],
        )
        test_lines: list[str] = []
        for identifier in inventory.identifiers:
            _, suite, method = identifier.split(".")
            test_lines.extend(
                [
                    f"Test Case '-[MirmirTests.{suite} {method}]' started.",
                    (
                        f"Test Case '-[MirmirTests.{suite} {method}]' "
                        "passed (0.001 seconds)."
                    ),
                ]
            )
        test_lines.extend(
            [
                (
                    "2026-07-23 21:52:29.160451-0500 "
                    "Mirmir[88121:33366368] [Connection] Unable to get "
                    "synchronousRemoteObjectProxy, error: Error "
                    "Domain=NSCocoaErrorDomain Code=4097 "
                    '"connection to service named '
                    'com.apple.linkd.autoShortcut" '
                    "UserInfo={NSDebugDescription=connection to service "
                    "named com.apple.linkd.autoShortcut}"
                ),
                (
                    "2026-07-23 21:52:29.160603-0500 "
                    "Mirmir[88121:33366368] [Connection] Unable to "
                    "re-register with Process Instance Registry, error: "
                    "Error Domain=NSCocoaErrorDomain Code=4097 "
                    '"connection to service named '
                    'com.apple.linkd.autoShortcut" '
                    "UserInfo={NSDebugDescription=connection to service "
                    "named com.apple.linkd.autoShortcut}"
                ),
                (
                    f"Executed {len(inventory.identifiers)} tests, with "
                    "0 failures (0 unexpected) in 0.1 seconds"
                ),
                "** TEST EXECUTE SUCCEEDED **",
                "Testing started",
            ]
        )
        metadata = [
            {"key": key, "value": f"fixture-{key}"}
            for key in sorted(r13.REQUIRED_RELEASE_METADATA_KEYS)
        ]
        for item in metadata:
            if item["key"] == "com.mirmir.release.model-status":
                item["value"] = "not_required"
            if item["key"] == "com.mirmir.release.fallback-history":
                item["value"] = "[]"
        media = b"fixture-product-output-mov"
        reopen = {
            "schema_version": "1.0.0",
            "roadmap_version": r13.ROADMAP_VERSION,
            "phase_id": "R13",
            "evidence_kind": "r13_output_reopen_receipt_v1",
            "source": dict(source),
            "status": "passed",
            "producer_test_identifier": r13.PRODUCT_OUTPUT_PRODUCER_TEST,
            "artifact_binding": self._file_binding(
                r13.OUTPUT_MEDIA_ARTIFACT_PATH, media
            ),
            "execution_identity": reopen_identity,
            "observed_media": {
                "container_type": "com.apple.quicktime-movie",
                "controlled_metadata": metadata,
                "duration_seconds": 1.0,
                "frame_count": 2,
                "height": 64,
                "video_track_count": 1,
                "width": 64,
            },
        }
        app, archive = self._app_and_archive()
        release_identity["release_app_tree_sha256"] = app["tree_sha256"]
        return r13.CapturedExecution(
            build_for_testing_log=self._log(
                build_identity, "** TEST BUILD SUCCEEDED **\n"
            ),
            targeted_test_log=self._log(
                test_identity, "\n".join(test_lines) + "\n"
            ),
            release_build_log=self._log(
                release_identity, "** BUILD SUCCEEDED **\n"
            ),
            lint_log=self._log(
                lint_identity,
                (
                    "Linting Swift files in current working directory\n"
                    "Linting 'A.swift' (1/2)\n"
                    "Linting 'B.swift' (2/2)\n"
                    "Done linting! Found 0 violations, 0 serious in 2 files.\n"
                ),
            ),
            app_identity=app,
            candidate_archive_payload=archive,
            output_media_payload=media,
            output_reopen_receipt=reopen,
        )


class R13Fixture:
    def __init__(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(
            prefix="mirmir-r13-unit-"
        )
        self.root = Path(self.temporary.name) / "repo"
        self.root.mkdir()
        _run_git(self.root, "init", "-q")
        _run_git(self.root, "config", "user.email", "r13@example.invalid")
        _run_git(self.root, "config", "user.name", "R13 Fixture")
        self._populate()
        self.commit = self.commit_all("R13 fixture implementation")

    def close(self) -> None:
        self.temporary.cleanup()

    def _copy(self, relative: Path) -> None:
        source = REPOSITORY_ROOT / relative
        destination = self.root / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, destination)

    def _populate(self) -> None:
        for path in r13.EXPLICIT_PRODUCT_SOURCE_PATHS:
            _write(
                self.root / path,
                f"// exact fixture product source: {path.as_posix()}\n",
            )
        _write(
            self.root
            / "Mirmir/Modules/Release/R13ReleaseIntegration.swift",
            "// exact fixture R13 integration source\n",
        )
        for class_name, area in r13.MANDATORY_SUITE_AREAS.items():
            del area
            methods = (
                sorted(
                    identifier.rsplit(".", 1)[1]
                    for identifier in r13.MANDATORY_INTEGRATION_IDENTIFIERS
                )
                if class_name == "R13ReleaseIntegrationTests"
                else (
                    [r13.MPS_PRODUCT_EXECUTION_TEST.rsplit(".", 1)[1]]
                    if class_name == "R13A11ProductBackendTests"
                    else [f"test{class_name.removesuffix('Tests')}Contract"]
                )
            )
            source = (
                "import XCTest\n\n"
                f"final class {class_name}: XCTestCase {{\n"
                + "".join(
                    f"    func {method}() {{}}\n" for method in methods
                )
                + "}\n"
            )
            _write(
                self.root / "MirmirTests" / f"{class_name}.swift",
                source,
            )
        for path in r13.EXPLICIT_EXISTING_TEST_PATHS:
            class_name = path.stem
            _write(
                self.root / path,
                (
                    "import XCTest\n\n"
                    f"final class {class_name}: XCTestCase {{\n"
                    f"    func test{class_name}FixtureContract() {{}}\n"
                    "}\n"
                ),
            )
        for path in r13.EXPLICIT_TEST_SUPPORT_PATHS:
            _write(
                self.root / path,
                f"// exact fixture test support: {path.as_posix()}\n",
            )
        _write(self.root / r13.PROJECT_PATH, "// fixture xcode project\n")
        for path in (
            r13.VALIDATOR_PATH,
            r13.VALIDATOR_TEST_PATH,
            r13.RELEASE_CANDIDATE_SCHEMA_PATH,
            r13.EXECUTION_SCHEMA_PATH,
            r13.ACCEPTANCE_SCHEMA_PATH,
        ):
            self._copy(path)
        roadmap = {
            "roadmap_version": r13.ROADMAP_VERSION,
            "phases": [
                {
                    "depends_on": ["R10"],
                    "exit": "fixture",
                    "id": "R11",
                    "name": "Evidence traceability and claim boundary",
                    "status": "passed",
                },
                {
                    "depends_on": ["R11"],
                    "exit": "fixture",
                    "id": "R12",
                    "name": "Format, route, and product expansion",
                    "status": "passed",
                },
                {
                    "depends_on": ["R11", "R12"],
                    "exit": "exact-app evidence and release-ready product",
                    "id": "R13",
                    "name": "Release hardening",
                    "status": "in_progress",
                },
            ],
        }
        _write(
            self.root / r13.ROADMAP_PATH,
            json.dumps(roadmap, indent=2, sort_keys=True) + "\n",
        )

    def commit_all(self, message: str) -> str:
        _run_git(self.root, "add", "-A")
        _run_git(self.root, "commit", "-q", "-m", message)
        return _run_git(self.root, "rev-parse", "HEAD")


class R13PhaseAcceptanceTests(unittest.TestCase):
    def setUp(self) -> None:
        self.fixture = R13Fixture()
        self.verifier = FixtureVerifier(self.fixture.root)

    def tearDown(self) -> None:
        self.fixture.close()

    def test_mandatory_r13_suite_catalog_matches_repository(self) -> None:
        classes: set[str] = set()
        for path in sorted(
            (REPOSITORY_ROOT / "MirmirTests").rglob("R13*Tests.swift")
        ):
            matches = r13._SWIFT_CLASS_PATTERN.findall(path.read_text())
            self.assertEqual(
                len(matches),
                1,
                f"Expected one XCTestCase class in {path}",
            )
            classes.add(matches[0])

        self.assertEqual(set(r13.MANDATORY_SUITE_AREAS), classes)

    def test_targeted_output_bridge_is_canonical_and_fail_closed(self) -> None:
        with tempfile.TemporaryDirectory(
            prefix="mirmir-r13-output-bridge-"
        ) as temporary:
            root = Path(temporary)
            media = b"fixture-media-bytes"
            encoded = base64.b64encode(media)
            output = root / "output.mov"
            payload = (
                b"before\n"
                + r13._OUTPUT_MEDIA_BASE64_PREFIX
                + encoded
                + b"\nafter\n"
            )

            observed = self.verifier._extract_product_output_from_test_log(
                payload,
                output,
            )

            self.assertEqual(observed, media)
            self.assertEqual(output.read_bytes(), media)
            with self.assertRaisesRegex(
                ValueError,
                "output bridge inventory differs",
            ):
                self.verifier._extract_product_output_from_test_log(
                    payload,
                    output,
                )
            with self.assertRaisesRegex(
                ValueError,
                "output bridge encoding differs",
            ):
                self.verifier._extract_product_output_from_test_log(
                    r13._OUTPUT_MEDIA_BASE64_PREFIX + b"not-base64!",
                    root / "invalid.mov",
                )
            with self.assertRaisesRegex(
                ValueError,
                "output bridge inventory differs",
            ):
                self.verifier._extract_product_output_from_test_log(
                    payload + r13._OUTPUT_MEDIA_BASE64_PREFIX + encoded,
                    root / "duplicate.mov",
                )

    def test_fixture_writer_generates_and_rechecks_closed_bundle(self) -> None:
        errors = self.verifier.write(self.fixture.commit)
        self.assertEqual(errors, [])
        self.assertEqual(self.verifier.check_generated(), [])
        expected = {
            r13.RELEASE_CANDIDATE_RECEIPT_PATH,
            r13.OUTPUT_REOPEN_RECEIPT_PATH,
            r13.EXECUTION_RECEIPT_PATH,
            r13.ACCEPTANCE_PATH,
            r13.BUILD_FOR_TESTING_LOG_PATH,
            r13.TARGETED_TEST_LOG_PATH,
            r13.RELEASE_BUILD_LOG_PATH,
            r13.LINT_LOG_PATH,
            r13.OUTPUT_MEDIA_ARTIFACT_PATH,
            r13.RELEASE_CANDIDATE_ARCHIVE_PATH,
        }
        self.assertTrue(
            all((self.fixture.root / path).is_file() for path in expected)
        )
        execution = json.loads(
            (self.fixture.root / r13.EXECUTION_RECEIPT_PATH).read_text()
        )
        self.assertEqual(
            execution["acceptance_basis"],
            "software_does_what_it_says_it_does",
        )
        self.assertEqual(execution["outcome"], "release_ready_candidate")
        self.assertEqual(len(execution["artifact_bindings"]), 8)
        self.assertEqual(
            execution["execution_boundary"],
            {
                "output_execution":
                    "debug_xctest_genuine_a11_mps_avfoundation",
                "release_app_execution": "not_observed",
                "release_app_produced_output": False,
            },
        )
        self.assertEqual(
            execution["distribution_boundary"][
                "distribution_authority"
            ],
            "not_authorized",
        )
        self.assertEqual(execution["claim_boundary"], r13.CLAIM_BOUNDARY)
        self.assertEqual(
            execution["comparison_policy"],
            r13.COMPARISON_POLICY,
        )
        self.assertEqual(
            execution["distribution_boundary"],
            r13.DISTRIBUTION_BOUNDARY,
        )
        self.assertEqual(execution["observations"], r13.OBSERVATIONS)
        self.assertEqual(
            execution["observations"][
                "debug_xctest_mps_lanczos_execution"
            ],
            "observed_both_product_routes",
        )
        self.assertEqual(
            execution["observations"]["gpu_profiling"],
            "not_observed",
        )
        self.assertEqual(
            execution["observations"]["hardware_qualification"],
            "not_observed",
        )
        self.assertEqual(
            execution["observations"][
                "release_candidate_gpu_execution"
            ],
            "not_observed",
        )
        candidate = json.loads(
            (
                self.fixture.root
                / r13.RELEASE_CANDIDATE_RECEIPT_PATH
            ).read_text()
        )
        self.assertEqual(
            candidate["candidate_archive"]["top_level"],
            "Mirmir.app",
        )
        self.assertEqual(
            candidate["execution_boundary"],
            execution["execution_boundary"],
        )
        self.assertEqual(candidate["mode_policy"], r13.MODE_POLICY)
        self.assertEqual(
            candidate["candidate_build_boundary"],
            {
                "default_metallib": "absent",
                "metal_source_compilation": "excluded",
                "release_candidate_gpu_execution": "not_observed",
            },
        )
        self.assertTrue(
            any(
                "genuine MPS Lanczos A11 backend" in limitation
                for limitation in candidate["limitations"]
            )
        )
        self.assertTrue(
            any(
                "retained MOV is produced by Debug XCTest through the genuine "
                "default A11 MPS Lanczos backend" in limitation
                for limitation in candidate["limitations"]
            )
        )
        self.assertFalse(
            any(
                "injected deterministic test backend" in limitation
                for limitation in candidate["limitations"]
            )
        )
        self.assertTrue(
            any(
                "not execution, of the exact clean Release app" in limitation
                for limitation in candidate["limitations"]
            )
        )
        release_identity = execution["execution_identities"][
            "release_app_build"
        ]
        self.assertEqual(
            release_identity["release_app_tree_sha256"],
            candidate["app_identity"]["tree_sha256"],
        )
        self.assertEqual(
            execution["verification"]["release_app_build"][
                "release_app_tree_sha256"
            ],
            candidate["app_identity"]["tree_sha256"],
        )
        acceptance = json.loads(
            (self.fixture.root / r13.ACCEPTANCE_PATH).read_text()
        )
        self.assertEqual(
            acceptance["execution_boundary"],
            execution["execution_boundary"],
        )
        bound_paths = {
            binding["path"] for binding in execution["source_bindings"]
        }
        self.assertTrue(
            {
                (
                    "Mirmir/Modules/UI/"
                    "MirmirViewModel+R13Diagnostics.swift"
                ),
                "Mirmir/Modules/UI/MirmirViewModel+R13Errors.swift",
                "Mirmir/Modules/UI/MirmirViewModel+R13Recovery.swift",
                (
                    "Mirmir/Modules/MediaPipeline/"
                    "OutputMediaVerificationTypes.swift"
                ),
                (
                    "Mirmir/Modules/MediaPipeline/"
                    "LocalAtomicMediaFileSystem.swift"
                ),
                (
                    "MirmirTests/"
                    "AtomicMediaOutputPublicationCleanupTests.swift"
                ),
                "MirmirTests/OutputMediaAACIdentityReaderTests.swift",
                "MirmirTests/OutputMediaVerifierTestSupport.swift",
                (
                    "MirmirTests/"
                    "R13ReleaseIntegrationFixtureSupport.swift"
                ),
                (
                    "MirmirTests/"
                    "R13ReleaseIntegrationHardeningSupport.swift"
                ),
                (
                    "MirmirTests/"
                    "R13ReleaseIntegrationMediaSupport.swift"
                ),
                (
                    "MirmirTests/"
                    "R13ReleaseUpscalerEngineTestSupport.swift"
                ),
            }.issubset(bound_paths)
        )

    def test_inventory_requires_shipping_service_integration_methods(self) -> None:
        path = (
            self.fixture.root
            / "MirmirTests/R13ReleaseIntegrationTests.swift"
        )
        text = path.read_text()
        text = text.replace(
            (
                "    func "
                "testShippingServiceUsesExactSourceFrameCountNotEstimatedFrameCount"
                "() {}\n"
            ),
            "",
        )
        path.write_text(text)
        revision = self.fixture.commit_all("remove integration contract")
        source = self.verifier.resolve_source(revision)
        inventory, errors = self.verifier._checkpoint_test_inventory(source)
        self.assertIsNone(inventory)
        self.assertTrue(
            any("shipping-service integration inventory differs" in error for error in errors)
        )

    def test_inventory_requires_observed_debug_mps_execution(self) -> None:
        path = (
            self.fixture.root
            / "MirmirTests/R13A11ProductBackendTests.swift"
        )
        text = path.read_text()
        method = r13.MPS_PRODUCT_EXECUTION_TEST.rsplit(".", 1)[1]
        text = text.replace(f"    func {method}() {{}}\n", "")
        path.write_text(text)
        revision = self.fixture.commit_all("remove Debug MPS execution")
        source = self.verifier.resolve_source(revision)
        inventory, errors = self.verifier._checkpoint_test_inventory(source)
        self.assertIsNone(inventory)
        self.assertTrue(
            any(
                "Debug MPS product execution inventory differs" in error
                for error in errors
            )
        )

    def test_inventory_requires_atomic_cleanup_regressions(self) -> None:
        path = (
            self.fixture.root
            / "MirmirTests/AtomicMediaOutputPublicationCleanupTests.swift"
        )
        path.unlink()
        revision = self.fixture.commit_all("remove atomic cleanup suite")
        source = self.verifier.resolve_source(revision)

        inventory, errors = self.verifier._checkpoint_test_inventory(source)

        self.assertIsNone(inventory)
        self.assertTrue(
            any(
                "required existing test source is absent" in error
                for error in errors
            )
        )

    def test_inventory_requires_restart_initialization_suite(self) -> None:
        path = (
            self.fixture.root
            / "MirmirTests/R13RestartJobInitializationTests.swift"
        )
        path.unlink()
        revision = self.fixture.commit_all(
            "remove restart initialization suite"
        )
        source = self.verifier.resolve_source(revision)

        inventory, errors = self.verifier._checkpoint_test_inventory(source)

        self.assertIsNone(inventory)
        self.assertTrue(
            any(
                "mandatory test suite inventory differs" in error
                for error in errors
            )
        )

    def test_execution_identity_mutation_fails_closed(self) -> None:
        source = self.verifier.resolve_source(self.fixture.commit)
        inventory, errors = self.verifier._checkpoint_test_inventory(source)
        self.assertEqual(errors, [])
        self.assertIsNotNone(inventory)
        captured = self.verifier._run_checkpoint_commands(
            source,
            {
                name: _tool(name)
                for name in ("swift", "swiftlint", "xcodebuild", "xcrun")
            },
            inventory,
        )
        first, body = captured.build_for_testing_log.split(b"\n", 1)
        identity = json.loads(
            first[len(r13._EXECUTION_IDENTITY_PREFIX) :].decode()
        )
        self.assertEqual(
            identity["argv"].count("ENABLE_TESTABILITY=YES"),
            1,
        )
        build_configuration_index = identity["argv"].index(
            "-configuration"
        )
        self.assertEqual(
            identity["argv"][build_configuration_index + 1],
            "Debug",
        )
        self.assertIn(
            "-configuration Debug",
            r13.BUILD_FOR_TESTING_COMMAND,
        )
        self.assertNotIn(
            "-configuration Release",
            r13.BUILD_FOR_TESTING_COMMAND,
        )
        self.assertTrue(
            r13.BUILD_FOR_TESTING_COMMAND.endswith(
                "ENABLE_TESTABILITY=YES"
            )
        )
        release_header = captured.release_build_log.split(b"\n", 1)[0]
        release_identity = json.loads(
            release_header[
                len(r13._EXECUTION_IDENTITY_PREFIX) :
            ].decode()
        )
        self.assertNotIn(
            "ENABLE_TESTABILITY=YES",
            release_identity["argv"],
        )
        release_configuration_index = release_identity["argv"].index(
            "-configuration"
        )
        self.assertEqual(
            release_identity["argv"][release_configuration_index + 1],
            "Release",
        )
        self.assertNotIn(
            "ENABLE_TESTABILITY=YES",
            r13.RELEASE_BUILD_COMMAND,
        )
        identity["argv"][-1] = "EXCLUDED_SOURCE_FILE_NAMES=mutated"
        mutated = (
            self.verifier._execution_identity_header(identity).encode()
            + b"\n"
            + body
        )
        parsed, parse_errors = self.verifier._build_log(
            mutated,
            source=source,
            inventory=inventory,
            release=False,
        )
        self.assertIsNone(parsed)
        self.assertTrue(
            any("argv differs" in error for error in parse_errors)
        )
        reopener = self.verifier._media_generator_source()
        self.assertEqual(
            self.verifier._media_reopener_source_errors(reopener),
            [],
        )
        self.assertIn("item.key as? String", reopener)
        self.assertIn("item.key as? NSString", reopener)
        self.assertNotIn("item.identifier", reopener)
        self.assertIn(
            "func isoBMFFContainerType(at url: URL) throws -> String",
            reopener,
        )
        self.assertIn('case "qt  ":', reopener)
        self.assertIn(
            "containerType = AVFileType.mov.rawValue",
            reopener,
        )
        self.assertIn(
            'case "isom", "iso2", "mp41", "mp42":',
            reopener,
        )
        self.assertIn(
            "containerType = AVFileType.mp4.rawValue",
            reopener,
        )
        self.assertIn(
            "let containerType = try isoBMFFContainerType(at: url)",
            reopener,
        )
        self.assertIn('"container_type": containerType,', reopener)
        self.assertNotIn(
            '"container_type": "com.apple.quicktime-movie"',
            reopener,
        )
        self.assertNotIn(
            '"container_type": "public.mpeg-4"',
            reopener,
        )
        identifier_mutation = reopener.replace(
            "guard let key = metadataKey(item),",
            "guard let key = item.identifier?.rawValue,",
        )
        self.assertEqual(
            self.verifier._media_reopener_source_errors(
                identifier_mutation
            ),
            [
                (
                    "R13 media reopener metadata-key "
                    "canonicalization differs"
                )
            ],
        )
        hard_coded_container_mutation = reopener.replace(
            '"container_type": containerType,',
            '"container_type": "com.apple.quicktime-movie",',
        )
        self.assertEqual(
            self.verifier._media_reopener_source_errors(
                hard_coded_container_mutation
            ),
            ["R13 media reopener container observation differs"],
        )
        mp4_brand_mutation = reopener.replace(
            'case "isom", "iso2", "mp41", "mp42":',
            'case "isom":',
        )
        self.assertEqual(
            self.verifier._media_reopener_source_errors(
                mp4_brand_mutation
            ),
            ["R13 media reopener container observation differs"],
        )

    def test_targeted_test_success_marker_must_be_terminal(self) -> None:
        source = self.verifier.resolve_source(self.fixture.commit)
        inventory, errors = self.verifier._checkpoint_test_inventory(source)
        self.assertEqual(errors, [])
        self.assertIsNotNone(inventory)
        captured = self.verifier._run_checkpoint_commands(
            source,
            {
                name: _tool(name)
                for name in ("swift", "swiftlint", "xcodebuild", "xcrun")
            },
            inventory,
        )
        mutated = (
            captured.targeted_test_log
            + (
                "Test Case '-[MirmirTests.R13ReleaseIntegrationTests "
                "testShippingServiceBindsExactReleaseIdentityAndReopens"
                "ControlledMetadata]' failed (0.001 seconds).\n"
            ).encode("utf-8")
        )
        identity, parse_errors = self.verifier._test_log(
            mutated,
            source=source,
            inventory=inventory,
        )
        self.assertIsNone(identity)
        self.assertTrue(
            any(
                "success marker differs" in error
                for error in parse_errors
            )
        )

    def test_targeted_test_log_rejects_nonexact_error_exceptions(
        self,
    ) -> None:
        source = self.verifier.resolve_source(self.fixture.commit)
        inventory, errors = self.verifier._checkpoint_test_inventory(source)
        self.assertEqual(errors, [])
        self.assertIsNotNone(inventory)
        captured = self.verifier._run_checkpoint_commands(
            source,
            {
                name: _tool(name)
                for name in ("swift", "swiftlint", "xcodebuild", "xcrun")
            },
            inventory,
        )
        identity, parse_errors = self.verifier._test_log(
            captured.targeted_test_log,
            source=source,
            inventory=inventory,
        )
        self.assertIsNotNone(identity)
        self.assertEqual(parse_errors, [])
        mutations = {
            "different_error_code": captured.targeted_test_log.replace(
                b"Code=4097",
                b"Code=4098",
                1,
            ),
            "different_service": captured.targeted_test_log.replace(
                b"com.apple.linkd.autoShortcut",
                b"com.apple.linkd.otherShortcut",
                1,
            ),
            "unrelated_error": captured.targeted_test_log.replace(
                b"** TEST EXECUTE SUCCEEDED **",
                b"error: unrelated failure\n** TEST EXECUTE SUCCEEDED **",
                1,
            ),
            "unicode_timestamp_digit": captured.targeted_test_log.replace(
                b"2026-07-23",
                "\u0662026-07-23".encode("utf-8"),
                1,
            ),
        }
        for name, mutation in mutations.items():
            with self.subTest(name=name):
                identity, parse_errors = self.verifier._test_log(
                    mutation,
                    source=source,
                    inventory=inventory,
                )
                self.assertIsNone(identity)
                self.assertIn(
                    "R13 targeted XCTest log contains a test error",
                    parse_errors,
                )

    def test_targeted_test_log_rejects_nonexact_success_epilogues(
        self,
    ) -> None:
        source = self.verifier.resolve_source(self.fixture.commit)
        inventory, errors = self.verifier._checkpoint_test_inventory(source)
        self.assertEqual(errors, [])
        self.assertIsNotNone(inventory)
        captured = self.verifier._run_checkpoint_commands(
            source,
            {
                name: _tool(name)
                for name in ("swift", "swiftlint", "xcodebuild", "xcrun")
            },
            inventory,
        )
        mutations = {
            "arbitrary": captured.targeted_test_log.replace(
                b"Testing started",
                b"arbitrary epilogue",
                1,
            ),
            "duplicate": captured.targeted_test_log.replace(
                b"Testing started",
                b"Testing started\nTesting started",
                1,
            ),
            "whitespace_padded": captured.targeted_test_log.replace(
                b"Testing started",
                b" Testing started ",
                1,
            ),
        }
        for name, mutation in mutations.items():
            with self.subTest(name=name):
                identity, parse_errors = self.verifier._test_log(
                    mutation,
                    source=source,
                    inventory=inventory,
                )
                self.assertIsNone(identity)
                self.assertIn(
                    "R13 targeted XCTest success marker differs",
                    parse_errors,
                )

    def test_output_metadata_rejects_auto_execution(self) -> None:
        source = self.verifier.resolve_source(self.fixture.commit)
        inventory, errors = self.verifier._checkpoint_test_inventory(source)
        self.assertEqual(errors, [])
        self.assertIsNotNone(inventory)
        captured = self.verifier._run_checkpoint_commands(
            source,
            {
                name: _tool(name)
                for name in ("swift", "swiftlint", "xcodebuild", "xcrun")
            },
            inventory,
        )
        for mode_key in (
            "com.mirmir.release.requested-mode",
            "com.mirmir.release.effective-mode",
        ):
            receipt = json.loads(
                json.dumps(captured.output_reopen_receipt)
            )
            for item in receipt["observed_media"]["controlled_metadata"]:
                if item["key"] == mode_key:
                    item["value"] = "Auto"
            observed_errors = self.verifier._output_reopen_errors(
                receipt,
                source=source,
                media_payload=captured.output_media_payload,
                inventory=inventory,
            )
            self.assertTrue(
                any(
                    "exact release metadata differs" in error
                    for error in observed_errors
                ),
                mode_key,
            )

    def test_candidate_archive_mutation_fails_reopen(self) -> None:
        app, archive = self.verifier._app_and_archive()
        self.assertEqual(
            self.verifier._candidate_archive_errors(archive, app), []
        )
        declared_identity_mutation = json.loads(json.dumps(app))
        declared_identity_mutation["bundle"][
            "bundle_identifier"
        ] = "com.example.falsified"
        self.assertTrue(
            any(
                "archived app bundle_identifier differs" in error
                for error in self.verifier._candidate_archive_errors(
                    archive,
                    declared_identity_mutation,
                )
            )
        )
        with zipfile.ZipFile(io.BytesIO(archive), "r") as candidate:
            self.assertTrue(
                all(
                    PurePosixPath(info.filename).parts[0] == "Mirmir.app"
                    for info in candidate.infolist()
                )
            )
        mutated_output = io.BytesIO()
        with zipfile.ZipFile(io.BytesIO(archive), "r") as source_archive:
            with zipfile.ZipFile(
                mutated_output,
                "w",
                compression=zipfile.ZIP_DEFLATED,
            ) as destination_archive:
                for info in source_archive.infolist():
                    payload = source_archive.read(info)
                    if (
                        info.filename
                        == "Mirmir.app/Contents/MacOS/Mirmir"
                    ):
                        payload += b"-mutated"
                    destination_archive.writestr(info, payload)
        self.assertNotEqual(
            self.verifier._candidate_archive_errors(
                mutated_output.getvalue(), app
            ),
            [],
        )
        wrong_top_level = io.BytesIO()
        with zipfile.ZipFile(io.BytesIO(archive), "r") as source_archive:
            with zipfile.ZipFile(wrong_top_level, "w") as destination:
                for info in source_archive.infolist():
                    info.filename = info.filename.removeprefix(
                        "Mirmir.app/"
                    )
                    destination.writestr(
                        info,
                        source_archive.read(
                            f"Mirmir.app/{info.filename}"
                        ),
                    )
        self.assertNotEqual(
            self.verifier._candidate_archive_errors(
                wrong_top_level.getvalue(), app
            ),
            [],
        )
        traversal = io.BytesIO()
        with zipfile.ZipFile(io.BytesIO(archive), "r") as source_archive:
            with zipfile.ZipFile(traversal, "w") as destination:
                for index, info in enumerate(source_archive.infolist()):
                    payload = source_archive.read(info.filename)
                    if index == 0:
                        info.filename = "Mirmir.app/../escape"
                    destination.writestr(info, payload)
        self.assertNotEqual(
            self.verifier._candidate_archive_errors(
                traversal.getvalue(), app
            ),
            [],
        )
        symlink = io.BytesIO()
        with zipfile.ZipFile(io.BytesIO(archive), "r") as source_archive:
            with zipfile.ZipFile(symlink, "w") as destination:
                for index, info in enumerate(source_archive.infolist()):
                    payload = source_archive.read(info.filename)
                    if index == 0:
                        info.external_attr = (
                            stat.S_IFLNK | 0o777
                        ) << 16
                    destination.writestr(info, payload)
        self.assertNotEqual(
            self.verifier._candidate_archive_errors(
                symlink.getvalue(), app
            ),
            [],
        )
        noncanonical_variants: list[bytes] = []
        with zipfile.ZipFile(io.BytesIO(archive), "r") as source_archive:
            source_entries = [
                (info, source_archive.read(info))
                for info in source_archive.infolist()
            ]
        stored = io.BytesIO()
        with zipfile.ZipFile(stored, "w") as destination:
            for original_info, entry_payload in source_entries:
                info = zipfile.ZipInfo(
                    original_info.filename,
                    (1980, 1, 1, 0, 0, 0),
                )
                info.compress_type = zipfile.ZIP_STORED
                info.create_system = 3
                info.external_attr = original_info.external_attr
                destination.writestr(info, entry_payload)
        noncanonical_variants.append(stored.getvalue())
        reordered = io.BytesIO()
        with zipfile.ZipFile(reordered, "w") as destination:
            for original_info, entry_payload in reversed(source_entries):
                destination.writestr(original_info, entry_payload)
        noncanonical_variants.append(reordered.getvalue())
        timestamped = io.BytesIO()
        with zipfile.ZipFile(timestamped, "w") as destination:
            for original_info, entry_payload in source_entries:
                info = zipfile.ZipInfo(
                    original_info.filename,
                    (2026, 1, 1, 0, 0, 0),
                )
                info.compress_type = zipfile.ZIP_DEFLATED
                info.create_system = 3
                info.external_attr = original_info.external_attr
                destination.writestr(info, entry_payload)
        noncanonical_variants.append(timestamped.getvalue())
        commented = io.BytesIO()
        with zipfile.ZipFile(commented, "w") as destination:
            destination.comment = b"not-canonical"
            for original_info, entry_payload in source_entries:
                destination.writestr(original_info, entry_payload)
        noncanonical_variants.append(commented.getvalue())
        extra_field = io.BytesIO()
        with zipfile.ZipFile(extra_field, "w") as destination:
            for original_info, entry_payload in source_entries:
                info = zipfile.ZipInfo(
                    original_info.filename,
                    (1980, 1, 1, 0, 0, 0),
                )
                info.compress_type = zipfile.ZIP_DEFLATED
                info.create_system = 3
                info.external_attr = original_info.external_attr
                info.extra = b"\x01\x00\x00\x00"
                destination.writestr(info, entry_payload)
        noncanonical_variants.append(extra_field.getvalue())
        for variant in noncanonical_variants:
            self.assertNotEqual(
                self.verifier._candidate_archive_errors(variant, app),
                [],
            )
        with mock.patch.object(
            r13,
            "_MAX_CANDIDATE_ARCHIVE_BYTES",
            len(archive) - 1,
        ):
            self.assertNotEqual(
                self.verifier._candidate_archive_errors(archive, app),
                [],
            )

    def test_candidate_rejects_test_products_and_default_metallib(self) -> None:
        app, _archive = self.verifier._app_and_archive()
        for forbidden in (
            "Contents/PlugIns/MirmirTests.xctest/Contents/MacOS/MirmirTests",
            "Contents/Resources/default.metallib",
        ):
            mutated = json.loads(json.dumps(app))
            mutated["file_manifest"][0]["path"] = forbidden
            mutated["file_manifest"].sort(key=lambda item: item["path"])
            mutated["tree_sha256"] = hashlib.sha256(
                r13._canonical_compact_json(mutated["file_manifest"])
            ).hexdigest()
            errors = self.verifier._app_identity_errors(mutated)
            self.assertTrue(
                any(
                    "test product or default.metallib" in error
                    for error in errors
                )
            )

    def test_release_tree_and_tool_identities_are_independently_bound(
        self,
    ) -> None:
        self.assertEqual(self.verifier.write(self.fixture.commit), [])
        candidate_path = (
            self.fixture.root / r13.RELEASE_CANDIDATE_RECEIPT_PATH
        )
        execution_path = self.fixture.root / r13.EXECUTION_RECEIPT_PATH
        candidate = json.loads(candidate_path.read_text())
        execution = json.loads(execution_path.read_text())
        release_identity = execution["execution_identities"][
            "release_app_build"
        ]
        self.assertEqual(
            self.verifier._release_tree_binding_errors(
                candidate,
                release_identity,
            ),
            [],
        )
        mutated_release_identity = dict(release_identity)
        mutated_release_identity["release_app_tree_sha256"] = "a" * 64
        self.assertNotEqual(
            self.verifier._release_tree_binding_errors(
                candidate,
                mutated_release_identity,
            ),
            [],
        )
        tools = {
            name: self.verifier._tool_identity(name)
            for name in ("swift", "swiftlint", "xcodebuild", "xcrun")
        }
        self.assertEqual(
            self.verifier._tool_binding_errors(
                execution["execution_identities"],
                tools,
            ),
            [],
        )
        mutated_identities = json.loads(
            json.dumps(execution["execution_identities"])
        )
        mutated_identities["output_reopen"]["tool"][
            "executable_path"
        ] = "/tmp/falsified-xcrun"
        self.assertNotEqual(
            self.verifier._tool_binding_errors(
                mutated_identities,
                tools,
            ),
            [],
        )
        mutated_candidate = json.loads(json.dumps(candidate))
        mutated_candidate["toolchain_identity"]["swift"][
            "name"
        ] = "xcodebuild"
        candidate_errors = self.verifier._release_candidate_errors(
            mutated_candidate,
            source=candidate["source"],
            candidate_archive_payload=(
                self.fixture.root
                / r13.RELEASE_CANDIDATE_ARCHIVE_PATH
            ).read_bytes(),
            output_reopen_payload=(
                self.fixture.root / r13.OUTPUT_REOPEN_RECEIPT_PATH
            ).read_bytes(),
            media_payload=(
                self.fixture.root / r13.OUTPUT_MEDIA_ARTIFACT_PATH
            ).read_bytes(),
            tools=tools,
        )
        self.assertTrue(
            any("swift identity differs" in error for error in candidate_errors)
        )

    def test_generated_receipt_tamper_is_rejected(self) -> None:
        self.assertEqual(self.verifier.write(self.fixture.commit), [])
        path = self.fixture.root / r13.RELEASE_CANDIDATE_RECEIPT_PATH
        os.chmod(path, 0o600)
        candidate = json.loads(path.read_text())
        candidate["execution_boundary"][
            "release_app_produced_output"
        ] = True
        path.write_text(
            json.dumps(candidate, indent=2, sort_keys=True) + "\n"
        )
        os.chmod(path, 0o400)
        errors = self.verifier.check_generated()
        self.assertTrue(
            any(
                "release-candidate execution_boundary differs" in error
                or "receipt differs" in error
                or "release-candidate schema" in error
                for error in errors
            )
        )

    def test_publication_rolls_back_without_overwrite(self) -> None:
        paths = {
            r13.RELEASE_CANDIDATE_RECEIPT_PATH,
            r13.OUTPUT_REOPEN_RECEIPT_PATH,
            r13.EXECUTION_RECEIPT_PATH,
            r13.ACCEPTANCE_PATH,
            r13.BUILD_FOR_TESTING_LOG_PATH,
            r13.TARGETED_TEST_LOG_PATH,
            r13.RELEASE_BUILD_LOG_PATH,
            r13.LINT_LOG_PATH,
            r13.OUTPUT_MEDIA_ARTIFACT_PATH,
            r13.RELEASE_CANDIDATE_ARCHIVE_PATH,
        }
        original = os.link
        calls = 0

        def bounded_failure(
            source: os.PathLike[str],
            destination: os.PathLike[str],
            *,
            follow_symlinks: bool,
        ) -> None:
            nonlocal calls
            calls += 1
            if calls == 3:
                raise OSError("fixture publication failure")
            original(
                source,
                destination,
                follow_symlinks=follow_symlinks,
            )

        with mock.patch.object(r13.os, "link", side_effect=bounded_failure):
            errors = self.verifier._write_bundle(
                {path: b"fixture" for path in paths}
            )
        self.assertTrue(
            any("publication failed" in error for error in errors)
        )
        self.assertTrue(
            all(not (self.fixture.root / path).exists() for path in paths)
        )

    def test_absent_evidence_is_nonblocking_incomplete(self) -> None:
        errors = self.verifier.check()
        self.assertEqual(
            errors,
            [
                (
                    "INCOMPLETE: R13 exact-source release-candidate "
                    "evidence has not been generated"
                )
            ],
        )
        self.assertEqual(r13.emit_errors(errors), 0)

    def test_schemas_are_recursively_closed(self) -> None:
        def inspect(value: object, path: str) -> None:
            if isinstance(value, dict):
                if value.get("type") == "object":
                    self.assertIs(
                        value.get("additionalProperties"),
                        False,
                        path,
                    )
                for key, child in value.items():
                    inspect(child, f"{path}/{key}")
            elif isinstance(value, list):
                for index, child in enumerate(value):
                    inspect(child, f"{path}/{index}")
        for schema_path in (
            r13.RELEASE_CANDIDATE_SCHEMA_PATH,
            r13.EXECUTION_SCHEMA_PATH,
            r13.ACCEPTANCE_SCHEMA_PATH,
        ):
            schema = json.loads(
                (REPOSITORY_ROOT / schema_path).read_text()
            )
            inspect(schema, schema_path.as_posix())

    def test_cli_is_bounded_and_write_requires_exact_oid(self) -> None:
        parser = r13.build_argument_parser()
        with redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit):
                parser.parse_args([])
            with self.assertRaises(SystemExit):
                parser.parse_args(["--check", "--check-generated"])
        self.assertNotEqual(self.verifier.write("HEAD"), [])


if __name__ == "__main__":
    unittest.main()
