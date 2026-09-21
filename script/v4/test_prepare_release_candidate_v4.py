#!/usr/bin/env python3
"""Tests for release-candidate archive provenance and identity derivation."""

from __future__ import annotations

import argparse
import copy
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
import zipfile


SCRIPT_DIRECTORY = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location(
    "prepare_release_candidate_v4",
    SCRIPT_DIRECTORY / "prepare_release_candidate_v4.py",
)
assert SPEC is not None and SPEC.loader is not None
candidate = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(candidate)
provenance = candidate.archive_provenance


def run(*arguments: str | Path, cwd: Path) -> str:
    process = subprocess.run(
        [str(argument) for argument in arguments],
        cwd=cwd,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        check=False,
    )
    if process.returncode != 0:
        raise AssertionError(
            f"command failed ({process.returncode}): {' '.join(map(str, arguments))}\n"
            + process.stdout
        )
    return process.stdout.strip()


def zip_directory(application: Path, output: Path) -> None:
    with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for path in [application, *sorted(application.rglob("*"))]:
            relative = path.relative_to(application.parent).as_posix()
            mode = stat.S_IMODE(path.stat().st_mode)
            if path.is_dir():
                info = zipfile.ZipInfo(relative + "/", date_time=(2026, 1, 1, 0, 0, 0))
                info.create_system = 3
                info.external_attr = (stat.S_IFDIR | mode) << 16
                archive.writestr(info, b"")
            else:
                info = zipfile.ZipInfo(relative, date_time=(2026, 1, 1, 0, 0, 0))
                info.create_system = 3
                info.external_attr = (stat.S_IFREG | mode) << 16
                info.compress_type = zipfile.ZIP_DEFLATED
                archive.writestr(info, path.read_bytes())


def rewrite_archive(
    source: Path,
    destination: Path,
    replacements: dict[str, bytes],
    *,
    omit: set[str] | None = None,
) -> None:
    omit = omit or set()
    with zipfile.ZipFile(source) as input_archive, zipfile.ZipFile(destination, "w") as output:
        for info in input_archive.infolist():
            normalized = info.filename[:-1] if info.filename.endswith("/") else info.filename
            if normalized in omit:
                continue
            data = replacements.get(normalized, input_archive.read(info))
            output.writestr(info, data)


def archive_bytes(path: Path, relative: str) -> bytes:
    with zipfile.ZipFile(path) as archive:
        return archive.read(relative)


def mutated_attestation(
    archive: Path,
    mutation: callable,
) -> bytes:
    value = json.loads(archive_bytes(archive, provenance.ATTESTATION_PATH))
    mutation(value)
    return provenance.canonical_bytes(value)


class Fixture:
    def __init__(self, root: Path) -> None:
        self.root = root
        self.repository = root / "repository"
        self.repository.mkdir()
        run("git", "init", "-q", cwd=self.repository)
        run("git", "config", "user.email", "candidate-tests@example.invalid", cwd=self.repository)
        run("git", "config", "user.name", "Candidate Tests", cwd=self.repository)

        scripts = self.repository / "script/v4"
        scripts.mkdir(parents=True)
        for name in (
            "prepare_release_candidate_v4.py",
            "release_candidate_archive_v4.py",
            "seal_release_candidate_archive_v4.py",
        ):
            shutil.copy2(SCRIPT_DIRECTORY / name, scripts / name)
        self.release_configuration = scripts / "release-candidate-v4.xcconfig"
        self.release_configuration.write_text(
            "SWIFT_OPTIMIZATION_LEVEL = -O\nENABLE_HARDENED_RUNTIME = YES\n",
            encoding="utf-8",
        )
        self.alternate_configuration = scripts / "alternate-release.xcconfig"
        self.alternate_configuration.write_text(
            "SWIFT_OPTIMIZATION_LEVEL = -Osize\nENABLE_HARDENED_RUNTIME = YES\n",
            encoding="utf-8",
        )
        self.runtime = self.make_runtime(
            self.repository / "Mirmir/Resources/ASH-P06.bundle",
            source_revision="a" * 64,
            artifact=b"primary-runtime",
        )
        self.alternate_runtime = self.make_runtime(
            self.repository / "Mirmir/Resources/ASH-P06-alternate.bundle",
            source_revision="b" * 64,
            artifact=b"alternate-runtime",
        )
        self.entitlements = self.repository / provenance.METAL_ENTITLEMENTS_REPOSITORY_PATH
        self.entitlements.parent.mkdir(parents=True, exist_ok=True)
        self.entitlements.write_bytes(
            plistlib.dumps(
                {
                    "com.apple.security.app-sandbox": True,
                    "com.apple.security.files.user-selected.read-write": True,
                },
                sort_keys=True,
            )
        )
        for relative, _ in provenance.METAL_SOURCE_SPECS:
            metal_source = self.repository / relative
            metal_source.parent.mkdir(parents=True, exist_ok=True)
            metal_source.write_text(
                "#include <metal_stdlib>\nusing namespace metal;\n",
                encoding="utf-8",
            )
        (self.repository / "source.txt").write_text("release source\n", encoding="utf-8")
        run("git", "add", ".", cwd=self.repository)
        run("git", "commit", "-qm", "release fixture", cwd=self.repository)
        self.commit = run("git", "rev-parse", "HEAD", cwd=self.repository)
        self.context = provenance.release_context(
            self.repository,
            self.commit,
            self.runtime,
            self.release_configuration,
        )
        self.tools = provenance.tool_descriptors(self.repository, self.commit)
        self.primary_executable = self.make_universal_executable(
            "fixture-primary",
            0,
        )
        self.alternate_executable = self.make_universal_executable(
            "fixture-alternate",
            1,
        )

    def make_universal_executable(self, name: str, exit_status: int) -> Path:
        source = self.root / f"{name}.c"
        output = self.root / name
        source.write_text(
            f"int main(void) {{ return {exit_status}; }}\n",
            encoding="utf-8",
        )
        run(
            "/usr/bin/clang",
            "-arch",
            "arm64",
            "-arch",
            "x86_64",
            source,
            "-o",
            output,
            cwd=self.root,
        )
        self.assert_universal_architectures(output)
        return output

    @staticmethod
    def assert_universal_architectures(executable: Path) -> None:
        observed = run("/usr/bin/lipo", "-archs", executable, cwd=executable.parent)
        if sorted(observed.split()) != sorted(
            provenance.EXPECTED_APPLICATION_ARCHITECTURES
        ):
            raise AssertionError(f"fixture executable has wrong slices: {observed}")

    def make_runtime(
        self,
        path: Path,
        *,
        source_revision: str,
        artifact: bytes,
    ) -> Path:
        path.mkdir(parents=True)
        artifact_path = path / "artifacts/runtime.bin"
        artifact_path.parent.mkdir()
        artifact_path.write_bytes(artifact)
        manifest = {
            "artifacts": [
                {
                    "byteCount": len(artifact),
                    "contentSHA256": provenance.sha256_bytes(artifact),
                    "relativePath": "artifacts/runtime.bin",
                    "role": "fixture",
                    "schemaID": "fixture.v1",
                }
            ],
            "provenance": {
                "builderSourceSHA256": "c" * 64,
                "sourceRevision": source_revision,
            },
            "releaseStatus": "release_qualified",
            "runtimeID": "ash-p06-deterministic-v4",
            "schemaID": "ash.p06.runtime-manifest.v1",
        }
        (path / "runtime-manifest.json").write_bytes(provenance.canonical_bytes(manifest))
        return path

    def make_application(
        self,
        directory: Path,
        *,
        executable_source: Path | None = None,
        context: dict[str, str] | None = None,
    ) -> Path:
        context = context or self.context
        executable_source = executable_source or self.primary_executable
        application = directory / "Mirmir.app"
        contents = application / "Contents"
        executable = contents / "MacOS/Mirmir"
        resources = contents / "Resources"
        executable.parent.mkdir(parents=True)
        resources.mkdir(parents=True)
        shutil.copyfile(executable_source, executable)
        executable.chmod(0o755)
        shutil.copytree(self.runtime, resources / "ASH-P06.bundle")
        (resources / "default.metallib").write_bytes(b"fixture-default-metallib")
        plist: dict[str, object] = {
            "CFBundleExecutable": "Mirmir",
            "CFBundleIdentifier": "com.mirmir.app",
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleName": "Mirmir",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "4.0",
            "CFBundleVersion": "400",
        }
        claims = provenance.expected_claims(context)
        for claim, plist_key in provenance.CLAIM_KEYS.items():
            plist[plist_key] = claims[claim]
        (contents / "Info.plist").write_bytes(plistlib.dumps(plist, sort_keys=True))
        run(
            "/usr/bin/codesign",
            "--force",
            "--deep",
            "--sign",
            "-",
            "--timestamp=none",
            "--options",
            "runtime",
            "--generate-entitlement-der",
            "--identifier",
            "com.mirmir.app",
            "--entitlements",
            self.entitlements,
            application,
            cwd=directory,
        )
        return application

    def make_sealed_archive(
        self,
        name: str,
        *,
        executable_source: Path | None = None,
        source_build_runner: provenance.CleanBuildRunner | None = None,
    ) -> Path:
        app_directory = self.root / f"{name}-app"
        app_directory.mkdir()
        application = self.make_application(
            app_directory,
            executable_source=executable_source,
        )
        unsealed = self.root / f"{name}-unsealed.zip"
        sealed = self.root / f"{name}-sealed.zip"
        zip_directory(application, unsealed)
        provenance.seal_archive(
            unsealed,
            sealed,
            self.context,
            self.tools,
            source_build_receipt=self.receipt_for_application(application),
            source_build_runner=source_build_runner or self.clean_build_runner,
        )
        return sealed

    def fixture_toolchain(self) -> dict[str, object]:
        descriptor = {
            "path": "/fixture/Xcode.app/Contents/Developer/usr/bin/tool",
            "sha256": "d" * 64,
            "version": ["fixture toolchain 1"],
        }
        component = {
            "assetIdentifier": "a" * 40 + ".asset",
            "buildVersion": "fixture-metal-1",
            "name": provenance.METAL_COMPONENT_NAME,
            "queryCommand": [
                "$XCODEBUILD",
                "-showComponent",
                provenance.METAL_COMPONENT_NAME,
                "-json",
            ],
            "status": "installed",
            "toolchainIdentifier": "fixture.metal.toolchain",
            "toolchainRelativePath": "Metal.xctoolchain",
        }
        metal = {
            "componentRelativePath": "usr/bin/metal",
            "lookupCommand": ["/usr/bin/xcrun", "--find", "metal"],
            "resolvedComponentRelativePath": "usr/bin/metal",
            "sha256": "1" * 64,
            "underlyingComponentRelativePath": "usr/metal/1/bin/metal",
            "underlyingSHA256": "3" * 64,
            "underlyingVersion": ["fixture underlying metal 1"],
            "underlyingVersionCommand": ["$UNDERLYING_METAL", "--version"],
            "version": ["fixture metal 1"],
            "versionCommand": ["$METAL", "--version"],
        }
        metallib = {
            "componentRelativePath": "usr/bin/metallib",
            "lookupCommand": ["/usr/bin/xcrun", "--find", "metallib"],
            "resolvedComponentRelativePath": "usr/bin/air-lld",
            "sha256": "4" * 64,
            "underlyingComponentRelativePath": "usr/metal/1/bin/air-lld",
            "underlyingSHA256": "5" * 64,
            "underlyingVersion": ["fixture underlying metallib 1"],
            "underlyingVersionCommand": [
                "$UNDERLYING_METALLIB",
                "--version",
            ],
            "version": ["fixture metallib 1"],
            "versionCommand": ["$METALLIB", "--version"],
        }
        metal_nm = {
            "componentRelativePath": "usr/bin/metal-nm",
            "lookupCommand": ["/usr/bin/xcrun", "--find", "metal-nm"],
            "resolvedComponentRelativePath": "usr/bin/air-nm",
            "sha256": "2" * 64,
            "underlyingComponentRelativePath": "usr/metal/1/bin/air-nm",
            "underlyingSHA256": "6" * 64,
            "underlyingVersion": ["fixture underlying metal-nm 1"],
            "underlyingVersionCommand": [
                "$UNDERLYING_METAL_NM",
                "--version",
            ],
            "version": ["fixture metal-nm 1"],
            "versionCommand": ["$METAL_NM", "--version"],
        }
        resource_entries = [
            {
                "byteCount": index + 1,
                "path": path,
                "sha256": f"{index + 7:x}" * 64,
                "unixMode": 0o644,
            }
            for index, path in enumerate(
                provenance.REQUIRED_METAL_RESOURCE_PATHS
            )
        ]
        resources = {
            "componentRelativePath": "usr/metal/1/lib/clang/fixture-1",
            "entries": resource_entries,
            "entryCount": len(resource_entries),
            "identitySHA256": provenance.sha256_bytes(
                provenance.METAL_RESOURCE_SET_DOMAIN
                + provenance.canonical_bytes(resource_entries)
            ),
            "queryCommand": [
                "$UNDERLYING_METAL",
                "-print-resource-dir",
            ],
            "schemaVersion": provenance.METAL_RESOURCE_MANIFEST_SCHEMA,
            "totalByteCount": sum(
                item["byteCount"] for item in resource_entries
            ),
        }
        metal_records = {
            "component": component,
            "metal": metal,
            "metallib": metallib,
            "metalNM": metal_nm,
            "resources": resources,
        }
        metal_toolchain = {
            **metal_records,
            "identitySHA256": provenance.sha256_bytes(
                provenance.METAL_TOOL_SET_DOMAIN
                + provenance.canonical_bytes(metal_records)
            ),
        }
        swiftc = {**descriptor}
        wrapper_records = {
            "auditPath": provenance.canonical_clean_build_layout()[
                "swiftDriverJobAudit"
            ],
            "interpreter": {
                "path": "/bin/zsh",
                "sha256": "b" * 64,
                "version": ["zsh fixture"],
            },
            "path": provenance.canonical_clean_build_layout()[
                "swiftDriverWrapper"
            ],
            "policy": {
                "effectiveJobArguments": ["-j", "1"],
                "effectiveJobArgumentsAreTerminal": True,
                "effectiveLLVMRNGSeedArguments": [
                    "-Xllvm",
                    "-rng-seed=1",
                ],
                "effectiveNumThreadsArguments": ["-num-threads", "1"],
                "projectedFrontendJobCountPerInvocation": 1,
                "projectedLLVMRNGSeedArguments": [
                    "-Xllvm",
                    "-rng-seed=1",
                ],
                "projectedNumThreadsArguments": ["-num-threads", "1"],
                "rejectMissingDuplicateOrSubstitutedControls": True,
                "underlyingArgv0": "swiftc",
                "rejectMalformedJobArguments": True,
                "removeEveryPriorJobArgument": True,
                "requiredTargets": list(
                    provenance.SWIFT_DRIVER_REQUIRED_TARGETS
                ),
            },
            "schemaVersion": provenance.SWIFT_DRIVER_WRAPPER_SCHEMA,
            "sha256": provenance.sha256_bytes(
                provenance.swift_driver_wrapper_bytes(
                    Path(swiftc["path"]),
                    Path(
                        provenance.canonical_clean_build_layout()[
                            "swiftDriverJobAudit"
                        ]
                    ),
                )
            ),
            "underlyingSwiftc": swiftc,
            "unixMode": 0o755,
        }
        swift_wrapper = {
            **wrapper_records,
            "identitySHA256": provenance.sha256_bytes(
                provenance.SWIFT_DRIVER_WRAPPER_DOMAIN
                + provenance.canonical_bytes(wrapper_records)
            ),
        }
        return {
            "clang": {**descriptor},
            "codesign": {**descriptor},
            "developerDirectory": "/fixture/Xcode.app/Contents/Developer",
            "git": {**descriptor},
            "lipo": {**descriptor},
            "macOSSDK": {
                "path": "/fixture/MacOSX.sdk",
                "settingsJSONSHA256": "e" * 64,
                "settingsPlistSHA256": "f" * 64,
                "version": "26.0",
            },
            "metal": metal_toolchain,
            "swiftc": swiftc,
            "swiftDriverWrapper": swift_wrapper,
            "xcodebuild": {**descriptor},
        }

    def fixture_swift_driver_job_audit(self) -> dict[str, object]:
        markers = sorted(provenance.SWIFT_DRIVER_JOB_AUDIT_MARKERS)
        invocation_count = len(markers)
        raw = ("\n".join(markers) + "\n").encode("utf-8")
        records = {
            "byteCount": len(raw),
            "effectiveJobArguments": ["-j", "1"],
            "effectiveJobArgumentsAreTerminal": True,
            "effectiveLLVMRNGSeedArguments": [
                "-Xllvm",
                "-rng-seed=1",
            ],
            "effectiveNumThreadsArguments": ["-num-threads", "1"],
            "invocationCount": invocation_count,
            "markers": markers,
            "path": provenance.canonical_clean_build_layout()[
                "swiftDriverJobAudit"
            ],
            "projectedFrontendJobCountPerInvocation": 1,
            "projectedLLVMRNGSeedArguments": [
                "-Xllvm",
                "-rng-seed=1",
            ],
            "projectedNumThreadsArguments": ["-num-threads", "1"],
            "requiredTargets": list(
                provenance.SWIFT_DRIVER_REQUIRED_TARGETS
            ),
            "schemaVersion": provenance.SWIFT_DRIVER_JOB_AUDIT_SCHEMA,
            "sha256": provenance.sha256_bytes(raw),
        }
        return {
            **records,
            "identitySHA256": provenance.sha256_bytes(
                provenance.SWIFT_DRIVER_JOB_AUDIT_DOMAIN
                + provenance.canonical_bytes(records)
            ),
        }

    def fixture_post_build(
        self,
        application: dict[str, object],
        toolchain: dict[str, object],
    ) -> dict[str, object]:
        sources = provenance.metal_source_descriptors(self.repository)
        compile_records: list[dict[str, object]] = []
        outputs: list[dict[str, object]] = []
        for index, source in enumerate(sources):
            command = provenance.metal_compile_command_template(source)
            raw_air = f"fixture-air-{index}".encode("utf-8")
            output = {
                "byteCount": len(raw_air),
                "path": f"$METAL_INTERMEDIATES/{source['airOutput']}",
                "sha256": provenance.sha256_bytes(raw_air),
                "unixMode": 0o644,
            }
            outputs.append(output)
            compile_records.append(
                {
                    "command": command,
                    "commandSHA256": provenance.sha256_bytes(
                        provenance.canonical_bytes(command)
                    ),
                    "exitStatus": 0,
                    "normalizedTranscriptSHA256": provenance.sha256_bytes(b""),
                    "output": output,
                    "sourceRepositoryRelativePath": source[
                        "repositoryRelativePath"
                    ],
                }
            )
        library = application["defaultMetalLibrary"]
        assert isinstance(library, dict)
        outputs.append(library)
        link_command = provenance.metal_link_command_template(sources)
        symbol_command = provenance.metal_symbol_command_template()
        symbols = sorted(provenance.EXPECTED_METAL_SYMBOLS)
        metal_receipt = {
            "compile": compile_records,
            "languageStandard": provenance.METAL_LANGUAGE_STANDARD,
            "link": {
                "command": link_command,
                "commandSHA256": provenance.sha256_bytes(
                    provenance.canonical_bytes(link_command)
                ),
                "exitStatus": 0,
                "normalizedTranscriptSHA256": provenance.sha256_bytes(b""),
                "output": library,
            },
            "optimizationLevel": provenance.METAL_OPTIMIZATION_LEVEL,
            "outputSetIdentitySHA256": provenance.sha256_bytes(
                provenance.METAL_OUTPUT_SET_DOMAIN
                + provenance.canonical_bytes(outputs)
            ),
            "sourceSetIdentitySHA256": provenance.sha256_bytes(
                provenance.METAL_SOURCE_SET_DOMAIN
                + provenance.canonical_bytes(sources)
            ),
            "sources": sources,
            "symbols": {
                "command": symbol_command,
                "commandSHA256": provenance.sha256_bytes(
                    provenance.canonical_bytes(symbol_command)
                ),
                "inventory": symbols,
                "inventorySHA256": provenance.sha256_bytes(
                    provenance.METAL_SYMBOL_SET_DOMAIN
                    + provenance.canonical_bytes(symbols)
                ),
            },
            "targetTriple": provenance.METAL_TARGET_TRIPLE,
            "toolSetIdentitySHA256": toolchain["metal"]["identitySHA256"],
        }
        signing_command = provenance.post_build_signing_command_template()
        signing_receipt = {
            "command": signing_command,
            "commandSHA256": provenance.sha256_bytes(
                provenance.canonical_bytes(signing_command)
            ),
            "entitlements": provenance._post_build_entitlements(self.repository),
            "exitStatus": 0,
            "normalizedTranscriptSHA256": provenance.sha256_bytes(b""),
            "policy": {
                "bundleIdentifier": provenance.CLEAN_BUILD_BUNDLE_IDENTIFIER,
                "generateDEREntitlements": True,
                "hardenedRuntime": True,
                "identity": "-",
                "mode": "ad-hoc",
                "timestamp": "none",
            },
        }
        return provenance.finalize_post_build_receipt(
            metal_receipt,
            signing_receipt,
            application,
        )

    def source_build_receipt(
        self,
        context: dict[str, str],
        application: dict[str, object],
        settings: dict[str, str],
    ) -> dict[str, object]:
        manifest = provenance.source_manifest_summary(
            provenance.committed_source_manifest(
                self.repository,
                context["sourceCommit"],
            )
        )
        normalized_overlay = provenance.build_settings_text(
            context,
            self.release_configuration,
        ).replace(str(self.repository), "$SOURCE_ROOT")
        toolchain = self.fixture_toolchain()
        return provenance.make_clean_build_receipt(
            context=context,
            source_manifest=manifest,
            settings=settings,
            toolchain=toolchain,
            build_environment={
                "CFFIXED_USER_HOME": provenance.canonical_clean_build_layout()[
                    "homeDirectory"
                ],
                "DEVELOPER_DIR": "/fixture/Xcode.app/Contents/Developer",
                "HOME": provenance.canonical_clean_build_layout()[
                    "homeDirectory"
                ],
                "LANG": "C",
                "LC_ALL": "C",
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "SWIFT_DETERMINISTIC_HASHING": "1",
                "SWIFTC_MAXIMUM_DETERMINISM": "1",
                "TMPDIR": provenance.canonical_clean_build_layout()[
                    "temporaryDirectory"
                ],
            },
            normalized_xcconfig_sha256=provenance.sha256_bytes(
                normalized_overlay.encode("utf-8")
            ),
            normalized_transcript_sha256=provenance.sha256_bytes(b"fixture build\n"),
            swift_driver_job_audit=self.fixture_swift_driver_job_audit(),
            application=application,
            post_build=self.fixture_post_build(application, toolchain),
        )

    def receipt_for_application(
        self,
        application: Path,
    ) -> dict[str, object]:
        observation = provenance.application_directory_observation(
            application,
            self.context,
        )
        return self.source_build_receipt(
            self.context,
            observation,
            provenance.CLEAN_REPLAY_BUILD_SETTINGS,
        )

    def clean_build_runner(
        self,
        context: dict[str, str],
        candidate_application: dict[str, object],
        settings: dict[str, str],
    ) -> dict[str, object]:
        with tempfile.TemporaryDirectory(
            prefix="reference-build-",
            dir=self.root,
        ) as temporary:
            reference = self.make_application(
                Path(temporary),
                executable_source=self.primary_executable,
                context=context,
            )
            observation = provenance.application_directory_observation(
                reference,
                context,
            )
        return self.source_build_receipt(context, observation, settings)

    def self_asserting_build_runner(
        self,
        context: dict[str, str],
        candidate_application: dict[str, object],
        settings: dict[str, str],
    ) -> dict[str, object]:
        return self.source_build_receipt(
            context,
            candidate_application,
            settings,
        )

    def prepare(
        self,
        archive: Path,
        *,
        source_commit: str | None = None,
        runtime: Path | None = None,
        release_configuration: Path | None = None,
    ) -> dict[str, object]:
        return candidate.make_candidate(
            self.arguments(
                archive,
                source_commit=source_commit,
                runtime=runtime,
                release_configuration=release_configuration,
            ),
            source_build_runner=self.clean_build_runner,
        )

    def arguments(
        self,
        archive: Path,
        *,
        source_commit: str | None = None,
        runtime: Path | None = None,
        release_configuration: Path | None = None,
    ) -> argparse.Namespace:
        return argparse.Namespace(
            repository=self.repository,
            source_commit=source_commit or self.commit,
            runtime=runtime or self.runtime,
            release_configuration=release_configuration or self.release_configuration,
            application_archive=archive,
            output=self.root / "candidate.json",
        )


class ReleaseCandidateTests(unittest.TestCase):
    def test_build_transcript_normalization_is_path_and_order_stable(self) -> None:
        root = provenance.CANONICAL_CLEAN_BUILD_ROOT
        source = root / "source"
        derived = root / "DerivedData"
        overlay = root / "release-provenance.xcconfig"
        first = (
            f"remark: {source}/A.swift -> {derived}/A.o\n"
            f"remark: {overlay}\n"
        )
        second = (
            f"remark: {str(overlay).removeprefix('/private')}\n"
            f"remark: {str(source).removeprefix('/private')}/A.swift -> "
            f"{str(derived).removeprefix('/private')}/A.o\n"
        )
        self.assertEqual(
            provenance.normalized_build_transcript(
                first,
                root=root,
                source=source,
                derived_data=derived,
                overlay=overlay,
            ),
            provenance.normalized_build_transcript(
                second,
                root=root,
                source=source,
                derived_data=derived,
                overlay=overlay,
            ),
        )

    def test_clean_replay_signing_policy_is_fixed_and_credential_free(self) -> None:
        self.assertEqual(
            provenance.normalize_clean_build_settings(None),
            provenance.CLEAN_REPLAY_BUILD_SETTINGS,
        )
        self.assertEqual(
            provenance.CLEAN_REPLAY_BUILD_SETTINGS["ENABLE_TESTABILITY"],
            "NO",
        )
        with self.assertRaisesRegex(
            provenance.ArchiveProvenanceError,
            "fixed and cannot be overridden",
        ):
            provenance.normalize_clean_build_settings(
                {
                    "CODE_SIGN_IDENTITY": "Developer ID Application",
                    "CODE_SIGN_STYLE": "Manual",
                }
            )

    def test_clean_replay_uses_external_whole_module_determinism_gate(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mirmir-candidate-") as temporary:
            fixture = Fixture(Path(temporary))
            command = provenance.clean_build_command_template(
                fixture.fixture_toolchain(),
                provenance.CLEAN_REPLAY_BUILD_SETTINGS,
            )
            overlay_text = provenance.build_settings_text(
                fixture.context,
                fixture.release_configuration,
            )
        jobs_index = command.index("-jobs")
        self.assertEqual(command[jobs_index + 1], "1")
        self.assertIn("ENABLE_TESTABILITY=NO", command)
        flags = provenance.REPRODUCIBLE_SWIFT_BUILD_SETTINGS[
            "OTHER_SWIFT_FLAGS"
        ]
        self.assertNotIn("-enable-deterministic-check", flags)
        self.assertNotIn("-enable-misched=false", flags)
        self.assertNotIn("-enable-post-misched=false", flags)
        self.assertIn("-enable-single-module-llvm-emission", flags)
        self.assertEqual(flags.count("-j 1"), 1)
        self.assertNotIn("-num-threads", flags)
        self.assertEqual(flags.count("-Xllvm -rng-seed=1"), 1)
        self.assertEqual(
            provenance.REPRODUCIBLE_SWIFT_BUILD_SETTINGS[
                "SWIFT_NUM_THREADS"
            ],
            "1",
        )
        self.assertEqual(
            provenance.REPRODUCIBLE_SWIFT_BUILD_SETTINGS[
                "SWIFT_COMPILATION_MODE"
            ],
            "wholemodule",
        )
        self.assertEqual(
            provenance.REPRODUCIBLE_SWIFT_BUILD_SETTINGS[
                "SWIFT_EAGER_MODULE_EMISSION_IN_WMO"
            ],
            "NO",
        )
        self.assertEqual(
            provenance.REPRODUCIBLE_SWIFT_BUILD_SETTINGS[
                "SWIFT_USE_INTEGRATED_DRIVER"
            ],
            "NO",
        )
        self.assertEqual(
            provenance.REPRODUCIBLE_SWIFT_BUILD_SETTINGS[
                "SWIFT_ENABLE_EXPLICIT_MODULES"
            ],
            "NO",
        )
        self.assertEqual(
            provenance.REPRODUCIBLE_SWIFT_BUILD_SETTINGS[
                "COMPILATION_CACHE_ENABLE_CACHING"
            ],
            "NO",
        )
        self.assertEqual(
            provenance.REPRODUCIBLE_SWIFT_BUILD_SETTINGS[
                "EXCLUDED_SOURCE_FILE_NAMES"
            ],
            "$(inherited) *.metal",
        )
        self.assertIn(
            "SWIFT_EXEC = "
            + provenance.canonical_clean_build_layout()["swiftDriverWrapper"],
            overlay_text,
        )
        sources = [
            {
                "airOutput": air,
                "repositoryRelativePath": relative,
            }
            for relative, air in provenance.METAL_SOURCE_SPECS
        ]
        for source in sources:
            metal_command = provenance.metal_compile_command_template(source)
            self.assertEqual(metal_command[0], "$UNDERLYING_METAL")
            self.assertIn("-O3", metal_command)
            self.assertIn("-std=metal3.2", metal_command)
            self.assertIn(provenance.METAL_TARGET_TRIPLE, metal_command)
        link_command = provenance.metal_link_command_template(sources)
        self.assertEqual(link_command[0], "$METALLIB")
        self.assertNotIn("$UNDERLYING_METAL", link_command)
        self.assertNotIn("-target", link_command)

    def test_swift_driver_wrapper_rewrites_every_job_option_to_one_terminal_pair(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mirmir-swift-wrapper-") as temporary:
            root = Path(temporary)
            audit = root / "audit.log"
            audit.write_bytes(b"")
            audit.chmod(0o600)
            wrapper = root / "swiftc"
            wrapper.write_bytes(
                provenance.swift_driver_wrapper_bytes(
                    Path("/usr/bin/python3"),
                    audit,
                )
            )
            wrapper.chmod(0o755)
            program = (
                "import json,os,sys\n"
                "args=sys.argv[1:]\n"
                "if '-driver-print-jobs' in args:\n"
                "    target=args[args.index('-target')+1]\n"
                "    mode=os.environ.get('MIRMIR_TEST_PROJECTION','valid')\n"
                "    rng=['-Xllvm','-rng-seed=1']\n"
                "    threads=['-num-threads','1']\n"
                "    if mode == 'missing-rng': rng=[]\n"
                "    elif mode == 'duplicate-rng': rng += rng\n"
                "    elif mode == 'substituted-rng': rng[1]='-rng-seed=2'\n"
                "    elif mode == 'missing-threads': threads=[]\n"
                "    elif mode == 'duplicate-threads': threads += threads\n"
                "    elif mode == 'substituted-threads': threads[1]='2'\n"
                "    print(' '.join(['/usr/bin/python3','-frontend','-target',target,'-target-sdk-version','26.2','-target-sdk-name','macosx26.2']+rng+threads))\n"
                "else:\n"
                "    print(json.dumps(args))\n"
            )
            target = provenance.SWIFT_DRIVER_REQUIRED_TARGETS[0]
            process = subprocess.run(
                [
                    str(wrapper),
                    "-c",
                    program,
                    "before",
                    "-num-threads",
                    "1",
                    "-Xllvm",
                    "-rng-seed=1",
                    "-target",
                    target,
                    "-j",
                    "8",
                    "middle",
                    "-j14",
                    "after",
                ],
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                check=False,
            )
            self.assertEqual(process.returncode, 0, process.stdout)
            self.assertEqual(
                json.loads(process.stdout),
                [
                    "before",
                    "-num-threads",
                    "1",
                    "-Xllvm",
                    "-rng-seed=1",
                    "-target",
                    target,
                    "middle",
                    "after",
                    "-j",
                    "1",
                ],
            )
            self.assertEqual(
                audit.read_text(encoding="utf-8"),
                provenance.swift_driver_job_audit_marker(target) + "\n",
            )
            control_variants = {
                "missing-threads": ["-Xllvm", "-rng-seed=1"],
                "duplicate-threads": [
                    "-num-threads",
                    "1",
                    "-num-threads",
                    "1",
                    "-Xllvm",
                    "-rng-seed=1",
                ],
                "substituted-threads": [
                    "-num-threads",
                    "2",
                    "-Xllvm",
                    "-rng-seed=1",
                ],
                "missing-rng": ["-num-threads", "1"],
                "duplicate-rng": [
                    "-num-threads",
                    "1",
                    "-Xllvm",
                    "-rng-seed=1",
                    "-Xllvm",
                    "-rng-seed=1",
                ],
                "substituted-rng": [
                    "-num-threads",
                    "1",
                    "-Xllvm",
                    "-rng-seed=2",
                ],
            }
            for name, controls in control_variants.items():
                with self.subTest(driver_control=name):
                    rejected = subprocess.run(
                        [
                            str(wrapper),
                            "-c",
                            program,
                            *controls,
                            "-target",
                            target,
                            "-j14",
                        ],
                        stdout=subprocess.PIPE,
                        stderr=subprocess.STDOUT,
                        text=True,
                        check=False,
                    )
                    self.assertEqual(rejected.returncode, 64, rejected.stdout)
            for mode in (
                "missing-threads",
                "duplicate-threads",
                "substituted-threads",
                "missing-rng",
                "duplicate-rng",
                "substituted-rng",
            ):
                with self.subTest(projected_control=mode):
                    environment = os.environ.copy()
                    environment["MIRMIR_TEST_PROJECTION"] = mode
                    rejected = subprocess.run(
                        [
                            str(wrapper),
                            "-c",
                            program,
                            "-num-threads",
                            "1",
                            "-Xllvm",
                            "-rng-seed=1",
                            "-target",
                            target,
                            "-j14",
                        ],
                        stdout=subprocess.PIPE,
                        stderr=subprocess.STDOUT,
                        text=True,
                        env=environment,
                        check=False,
                    )
                    self.assertEqual(rejected.returncode, 64, rejected.stdout)
            malformed = subprocess.run(
                [str(wrapper), "-c", program, "-jbad"],
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                check=False,
            )
            self.assertEqual(malformed.returncode, 64)

    def test_swift_driver_job_audit_requires_both_targets_and_normalizes_order(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mirmir-swift-audit-") as temporary:
            root = Path(temporary)
            audit = root / "audit.log"
            markers = list(reversed(provenance.SWIFT_DRIVER_JOB_AUDIT_MARKERS))
            audit.write_text("\n".join(markers) + "\n", encoding="utf-8")
            installation = provenance.SwiftDriverWrapperInstallation(
                path=root / "swiftc",
                identity=(),
                audit_path=audit,
                audit_identity=(),
                receipt={},
            )
            receipt = provenance.swift_driver_job_audit(installation)
            normalized = (
                "\n".join(sorted(provenance.SWIFT_DRIVER_JOB_AUDIT_MARKERS))
                + "\n"
            ).encode("utf-8")
            self.assertEqual(
                receipt["requiredTargets"],
                list(provenance.SWIFT_DRIVER_REQUIRED_TARGETS),
            )
            self.assertEqual(receipt["invocationCount"], 2)
            self.assertEqual(receipt["sha256"], provenance.sha256_bytes(normalized))
            invalid_lines = {
                "missing": markers[:1],
                "duplicate": [markers[0], markers[0]],
                "substituted": [
                    markers[0],
                    markers[1].replace(
                        "llvmRNGSeed=1",
                        "llvmRNGSeed=2",
                        1,
                    ),
                ],
            }
            for name, lines in invalid_lines.items():
                with self.subTest(name=name):
                    audit.write_text("\n".join(lines) + "\n", encoding="utf-8")
                    with self.assertRaises(provenance.ArchiveProvenanceError):
                        provenance.swift_driver_job_audit(installation)

    def test_clean_build_uses_isolated_canonical_home(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mirmir-clean-home-") as temporary:
            build_root = Path(temporary) / "canonical-build"
            build_root.mkdir(mode=0o700)
            developer = Path(
                "/Applications/Xcode.app/Contents/Developer"
            ).resolve(strict=True)
            with mock.patch.object(
                provenance,
                "CANONICAL_CLEAN_BUILD_ROOT",
                build_root,
            ), mock.patch.object(
                provenance,
                "_checked_output",
                return_value=str(developer),
            ):
                environment = provenance.clean_build_environment(build_root)
                layout = provenance.canonical_clean_build_layout()
            home = build_root / "home"
            self.assertEqual(environment["HOME"], str(home))
            self.assertEqual(environment["CFFIXED_USER_HOME"], str(home))
            self.assertEqual(environment["SWIFT_DETERMINISTIC_HASHING"], "1")
            self.assertEqual(environment["SWIFTC_MAXIMUM_DETERMINISM"], "1")
            self.assertEqual(layout["homeDirectory"], str(home))
            self.assertNotEqual(environment["HOME"], os.environ.get("HOME"))
            self.assertEqual(stat.S_IMODE(home.stat().st_mode), 0o700)
            self.assertEqual(list(home.iterdir()), [])
            self.assertEqual(
                stat.S_IMODE((build_root / "tmp").stat().st_mode),
                0o700,
            )

    def test_outputs_are_atomically_published_without_clobbering_races(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mirmir-candidate-") as temporary:
            fixture = Fixture(Path(temporary))
            actual_publish = provenance._publish_no_clobber

            settings_output = fixture.root / "race-settings.xcconfig"

            def race_file(
                source: Path,
                target: provenance.PublicationTarget,
                label: str,
            ) -> Path:
                target.path.write_bytes(b"competing file")
                return actual_publish(source, target, label)

            with mock.patch.object(
                provenance,
                "_publish_no_clobber",
                side_effect=race_file,
            ), self.assertRaisesRegex(
                provenance.ArchiveProvenanceError,
                "refusing to overwrite",
            ):
                provenance.write_bytes_no_clobber(
                    settings_output,
                    b"generated settings",
                    label="build-settings output",
                )
            self.assertEqual(settings_output.read_bytes(), b"competing file")

            app_directory = fixture.root / "publication-app"
            app_directory.mkdir()
            application = fixture.make_application(app_directory)
            observation = provenance.application_directory_observation(
                application,
                fixture.context,
            )

            def race_directory(
                source: Path,
                target: provenance.PublicationTarget,
                label: str,
            ) -> Path:
                target.path.mkdir()
                (target.path / "competing.txt").write_text("preserve me\n")
                return actual_publish(source, target, label)

            clean_parent = fixture.root / "clean-output"
            clean_parent.mkdir()
            clean_output = clean_parent / "Mirmir.app"
            with mock.patch.object(
                provenance,
                "_publish_no_clobber",
                side_effect=race_directory,
            ), self.assertRaisesRegex(
                provenance.ArchiveProvenanceError,
                "refusing to overwrite",
            ):
                provenance._copy_clean_application(
                    application,
                    observation,
                    fixture.context,
                    clean_output,
                )
            self.assertEqual(
                (clean_output / "competing.txt").read_text(),
                "preserve me\n",
            )

            xcarchive_output = fixture.root / "race.xcarchive"

            def fake_candidate_build(
                context: dict[str, str],
                output: Path,
            ) -> dict[str, object]:
                shutil.copytree(application, output, copy_function=shutil.copy2)
                copied = provenance.application_directory_observation(
                    output,
                    context,
                )
                return fixture.source_build_receipt(
                    context,
                    copied,
                    provenance.CLEAN_REPLAY_BUILD_SETTINGS,
                )

            with mock.patch.object(
                provenance,
                "build_candidate_application",
                side_effect=fake_candidate_build,
            ), mock.patch.object(
                provenance,
                "_publish_no_clobber",
                side_effect=race_directory,
            ), self.assertRaisesRegex(
                provenance.ArchiveProvenanceError,
                "refusing to overwrite",
            ):
                provenance.build_candidate_xcarchive(
                    fixture.context,
                    xcarchive_output,
                )
            self.assertEqual(
                (xcarchive_output / "competing.txt").read_text(),
                "preserve me\n",
            )

            unsealed = fixture.root / "race-unsealed.zip"
            zip_directory(application, unsealed)
            sealed_output = fixture.root / "race-sealed.zip"
            with mock.patch.object(
                provenance,
                "_publish_no_clobber",
                side_effect=race_file,
            ), self.assertRaisesRegex(
                provenance.ArchiveProvenanceError,
                "refusing to overwrite",
            ):
                provenance.seal_archive(
                    unsealed,
                    sealed_output,
                    fixture.context,
                    fixture.tools,
                    source_build_receipt=fixture.receipt_for_application(
                        application
                    ),
                    source_build_runner=fixture.self_asserting_build_runner,
                )
            self.assertEqual(sealed_output.read_bytes(), b"competing file")

    def test_candidate_record_rejects_symlink_and_competing_output_races(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mirmir-candidate-output-") as temporary:
            root = Path(temporary)
            sample = {
                "appBundleSHA256": "1" * 64,
                "bundleIdentifier": "com.mirmir.app",
                "productBuild": "1",
                "productVersion": "1.0",
                "releaseConfigurationSHA256": "2" * 64,
                "runtimeArtifactSetSHA256": "3" * 64,
                "runtimeManifestFileSHA256": "4" * 64,
                "runtimeManifestSHA256": "5" * 64,
                "runtimeSourceRevision": "6" * 64,
                "sourceCommit": "7" * 40,
                "sourceTreeIdentitySHA256": "8" * 64,
            }
            expected = root / "expected.json"
            candidate.p06.write_json(expected, sample)
            self.assertEqual(
                candidate.candidate_json_bytes(sample),
                expected.read_bytes(),
            )

            victim = root / "victim.json"
            victim.write_bytes(b"preserve victim")
            symlink_output = root / "candidate-symlink.json"
            symlink_output.symlink_to(victim)
            arguments = argparse.Namespace(output=symlink_output)
            with mock.patch.object(
                candidate,
                "parse_arguments",
                return_value=arguments,
            ), mock.patch.object(
                candidate,
                "make_candidate",
                return_value=sample,
            ), self.assertRaisesRegex(
                provenance.ArchiveProvenanceError,
                "refusing to overwrite",
            ):
                candidate.main()
            self.assertTrue(symlink_output.is_symlink())
            self.assertEqual(victim.read_bytes(), b"preserve victim")

            competing_output = root / "candidate-race.json"
            actual_publish = provenance._publish_no_clobber

            def race_file(
                source: Path,
                target: provenance.PublicationTarget,
                label: str,
            ) -> Path:
                target.path.write_bytes(b"preserve competitor")
                return actual_publish(source, target, label)

            arguments = argparse.Namespace(output=competing_output)
            with mock.patch.object(
                candidate,
                "parse_arguments",
                return_value=arguments,
            ), mock.patch.object(
                candidate,
                "make_candidate",
                return_value=sample,
            ), mock.patch.object(
                provenance,
                "_publish_no_clobber",
                side_effect=race_file,
            ), self.assertRaisesRegex(
                provenance.ArchiveProvenanceError,
                "refusing to overwrite",
            ):
                candidate.main()
            self.assertEqual(
                competing_output.read_bytes(),
                b"preserve competitor",
            )

    def test_application_requires_exact_arm64_and_x86_64_slices(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mirmir-candidate-") as temporary:
            fixture = Fixture(Path(temporary))
            app_directory = fixture.root / "single-slice-app"
            app_directory.mkdir()
            application = fixture.make_application(app_directory)
            executable = application / "Contents/MacOS/Mirmir"
            thin = fixture.root / "Mirmir-x86_64"
            run(
                "/usr/bin/lipo",
                executable,
                "-thin",
                "x86_64",
                "-output",
                thin,
                cwd=fixture.root,
            )
            os.replace(thin, executable)
            executable.chmod(0o755)
            self._resign_application(fixture, application)
            with self.assertRaisesRegex(
                provenance.ArchiveProvenanceError,
                "exactly arm64 and x86_64",
            ):
                provenance.application_directory_observation(
                    application,
                    fixture.context,
                )

    def test_per_architecture_entitlements_and_requirements_fail_closed(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mirmir-candidate-") as temporary:
            fixture = Fixture(Path(temporary))
            app_directory = fixture.root / "per-architecture-app"
            app_directory.mkdir()
            application = fixture.make_application(app_directory)
            executable = application / "Contents/MacOS/Mirmir"

            actual_entitlements = provenance._entitlements_observation

            def divergent_entitlements(
                path: Path,
                architecture: str,
            ) -> tuple[str, dict[str, object]]:
                identity, entitlements = actual_entitlements(path, architecture)
                if architecture == "x86_64":
                    identity = "f" * 64
                return identity, entitlements

            with mock.patch.object(
                provenance,
                "_entitlements_observation",
                side_effect=divergent_entitlements,
            ):
                with self.assertRaisesRegex(
                    provenance.ArchiveProvenanceError,
                    "different entitlements",
                ):
                    provenance._signing_identity(application, executable)

            actual_run = provenance._run

            def divergent_requirements(
                command: list[str],
                label: str,
            ) -> str:
                if label.startswith("designated-requirement verification"):
                    return ""
                output = actual_run(command, label)
                if label.startswith("CodeDirectory inspection"):
                    return output.replace(
                        "flags=0x10002(adhoc,runtime)",
                        "flags=0x10000(runtime)",
                    )
                if label.startswith("designated-requirement inspection"):
                    architecture = command[command.index("--arch") + 1]
                    suffix = "arm" if architecture == "arm64" else "intel"
                    return f'designated => identifier "com.mirmir.app.{suffix}"'
                return output

            with mock.patch.object(
                provenance,
                "_run",
                side_effect=divergent_requirements,
            ):
                with self.assertRaisesRegex(
                    provenance.ArchiveProvenanceError,
                    "different designated requirements",
                ):
                    provenance._signing_identity(application, executable)

            def custom_ad_hoc_requirement(
                command: list[str],
                label: str,
            ) -> str:
                if label.startswith("designated-requirement verification"):
                    return ""
                output = actual_run(command, label)
                if label == "designated-requirement inspection for x86_64":
                    return 'designated => identifier "com.mirmir.app"'
                return output

            with mock.patch.object(
                provenance,
                "_run",
                side_effect=custom_ad_hoc_requirement,
            ):
                with self.assertRaisesRegex(
                    provenance.ArchiveProvenanceError,
                    "custom designated requirement for x86_64",
                ):
                    provenance._signing_identity(application, executable)

    def test_get_task_allow_is_rejected_on_each_slice(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mirmir-candidate-") as temporary:
            fixture = Fixture(Path(temporary))
            thin = fixture.root / "get-task-allow-arm64"
            run(
                "/usr/bin/lipo",
                fixture.primary_executable,
                "-thin",
                "arm64",
                "-output",
                thin,
                cwd=fixture.root,
            )
            entitlements = fixture.root / "get-task-allow.plist"
            entitlements.write_bytes(
                plistlib.dumps(
                    {"com.apple.security.get-task-allow": True},
                    sort_keys=True,
                )
            )
            run(
                "/usr/bin/codesign",
                "--force",
                "--sign",
                "-",
                "--entitlements",
                entitlements,
                thin,
                cwd=fixture.root,
            )
            with self.assertRaisesRegex(
                provenance.ArchiveProvenanceError,
                "enables get-task-allow for arm64",
            ):
                provenance._entitlements_observation(thin, "arm64")

    def test_nested_resource_codesignature_name_remains_source_bound(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mirmir-candidate-") as temporary:
            fixture = Fixture(Path(temporary))
            app_directory = fixture.root / "nested-signature-name-app"
            app_directory.mkdir()
            application = fixture.make_application(app_directory)
            nested = (
                application
                / "Contents/Resources/_CodeSignature/unsourced-resource.bin"
            )
            nested.parent.mkdir()
            nested.write_bytes(b"must remain source-bound")
            self._resign_application(fixture, application)
            unsealed = fixture.root / "nested-signature-name-unsealed.zip"
            sealed = fixture.root / "nested-signature-name-sealed.zip"
            zip_directory(application, unsealed)
            provenance.seal_archive(
                unsealed,
                sealed,
                fixture.context,
                fixture.tools,
                source_build_receipt=fixture.receipt_for_application(application),
                source_build_runner=fixture.self_asserting_build_runner,
            )
            with self.assertRaisesRegex(
                provenance.ArchiveProvenanceError,
                "identifies another application|executable, resources, entitlements, or signing policy",
            ):
                fixture.prepare(sealed)

    def test_archive_snapshot_and_modes_fail_closed(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mirmir-candidate-") as temporary:
            fixture = Fixture(Path(temporary))

            writable_directory = fixture.root / "writable-app"
            writable_directory.mkdir()
            writable = fixture.make_application(writable_directory)
            (writable / "Contents/MacOS/Mirmir").chmod(0o777)
            writable_archive = fixture.root / "writable.zip"
            zip_directory(writable, writable_archive)
            with self.assertRaisesRegex(
                provenance.ArchiveProvenanceError,
                "group/world writable",
            ):
                provenance.seal_archive(
                    writable_archive,
                    fixture.root / "writable-sealed.zip",
                    fixture.context,
                    fixture.tools,
                    source_build_receipt=fixture.receipt_for_application(writable),
                    source_build_runner=fixture.self_asserting_build_runner,
                )

            mode_directory = fixture.root / "mode-replay-app"
            mode_directory.mkdir()
            mode_application = fixture.make_application(mode_directory)
            (mode_application / "Contents/Info.plist").chmod(0o600)
            (mode_application / "Contents/Resources").chmod(0o700)
            mode_unsealed = fixture.root / "mode-replay-unsealed.zip"
            mode_sealed = fixture.root / "mode-replay-sealed.zip"
            zip_directory(mode_application, mode_unsealed)
            provenance.seal_archive(
                mode_unsealed,
                mode_sealed,
                fixture.context,
                fixture.tools,
                source_build_receipt=fixture.receipt_for_application(
                    mode_application
                ),
                source_build_runner=fixture.self_asserting_build_runner,
            )
            with self.assertRaisesRegex(
                provenance.ArchiveProvenanceError,
                "identifies another application|executable, resources, entitlements, or signing policy",
            ):
                fixture.prepare(mode_sealed)

            snapshot_directory = fixture.root / "snapshot-app"
            snapshot_directory.mkdir()
            snapshot_application = fixture.make_application(snapshot_directory)
            snapshot_unsealed = fixture.root / "snapshot-unsealed.zip"
            snapshot_sealed = fixture.root / "snapshot-sealed.zip"
            zip_directory(snapshot_application, snapshot_unsealed)
            actual_snapshot = provenance._snapshot_archive
            replaced = False

            def replace_after_snapshot(path: Path) -> tuple[object, str]:
                nonlocal replaced
                snapshot, identity = actual_snapshot(path)
                if not replaced:
                    Path(path).write_bytes(b"replacement after held-fd snapshot")
                    replaced = True
                return snapshot, identity

            with mock.patch.object(
                provenance,
                "_snapshot_archive",
                side_effect=replace_after_snapshot,
            ):
                with self.assertRaises(provenance.ArchiveProvenanceError):
                    provenance.seal_archive(
                        snapshot_unsealed,
                        snapshot_sealed,
                        fixture.context,
                        fixture.tools,
                        source_build_receipt=fixture.receipt_for_application(
                            snapshot_application
                        ),
                        source_build_runner=fixture.self_asserting_build_runner,
                    )
            self.assertTrue(replaced)
            self.assertFalse(snapshot_sealed.exists())

    def test_canonical_ditto_archive_omits_unsupported_appledouble_metadata(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mirmir-candidate-") as temporary:
            fixture = Fixture(Path(temporary))
            app_directory = fixture.root / "ditto-app"
            app_directory.mkdir()
            application = fixture.make_application(app_directory)

            metadata_archive = fixture.root / "metadata.zip"
            run(
                "/usr/bin/ditto",
                "-c",
                "-k",
                "--keepParent",
                application,
                metadata_archive,
                cwd=fixture.root,
            )
            with self.assertRaisesRegex(
                provenance.ArchiveProvenanceError,
                "unsupported AppleDouble metadata",
            ):
                provenance.inspect_archive(
                    metadata_archive,
                    fixture.context,
                    fixture.tools,
                    require_attestation=False,
                    verify_source_build=True,
                    source_build_runner=fixture.clean_build_runner,
                )

            canonical_archive = fixture.root / "canonical.zip"
            run(
                "/usr/bin/ditto",
                "-c",
                "-k",
                "--norsrc",
                "--noextattr",
                "--noacl",
                "--noqtn",
                "--keepParent",
                application,
                canonical_archive,
                cwd=fixture.root,
            )
            sealed = fixture.root / "canonical-sealed.zip"
            provenance.seal_archive(
                canonical_archive,
                sealed,
                fixture.context,
                fixture.tools,
                source_build_receipt=fixture.receipt_for_application(application),
                source_build_runner=fixture.clean_build_runner,
            )
            self.assertTrue(sealed.is_file())

    def test_sealing_requires_and_reproduces_original_build_receipt(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mirmir-candidate-") as temporary:
            fixture = Fixture(Path(temporary))
            app_directory = fixture.root / "receipt-app"
            app_directory.mkdir()
            application = fixture.make_application(app_directory)
            unsealed = fixture.root / "receipt-unsealed.zip"
            zip_directory(application, unsealed)
            with self.assertRaisesRegex(
                provenance.ArchiveProvenanceError,
                "requires its original source-build receipt",
            ):
                provenance.seal_archive(
                    unsealed,
                    fixture.root / "missing-receipt.zip",
                    fixture.context,
                    fixture.tools,
                    source_build_runner=fixture.self_asserting_build_runner,
                )

            receipt = fixture.receipt_for_application(application)
            mismatched = copy.deepcopy(receipt)
            mismatched["build"]["normalizedTranscriptSHA256"] = "0" * 64
            with self.assertRaisesRegex(
                provenance.ArchiveProvenanceError,
                "sealing replay differs from the original source-build receipt",
            ):
                provenance.seal_archive(
                    unsealed,
                    fixture.root / "mismatched-receipt.zip",
                    fixture.context,
                    fixture.tools,
                    source_build_receipt=mismatched,
                    source_build_runner=fixture.self_asserting_build_runner,
                )

            sealed = fixture.root / "receipt-sealed.zip"
            provenance.seal_archive(
                unsealed,
                sealed,
                fixture.context,
                fixture.tools,
                source_build_receipt=receipt,
                source_build_runner=fixture.self_asserting_build_runner,
            )
            inspection = provenance.inspect_archive(
                sealed,
                fixture.context,
                fixture.tools,
                require_attestation=True,
            )
            self.assertEqual(
                inspection["attestation"]["sourceBuild"],
                receipt,
            )
            self.assertEqual(
                inspection["attestation"]["sourceBuildReceiptSHA256"],
                provenance.sha256_bytes(
                    provenance.CLEAN_BUILD_RECEIPT_DOMAIN
                    + provenance.canonical_bytes(receipt)
                ),
            )

    def test_build_settings_cli_and_verified_function_chain(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mirmir-candidate-") as temporary:
            fixture = Fixture(Path(temporary))
            settings = fixture.root / "provenance.xcconfig"
            run(
                sys.executable,
                SCRIPT_DIRECTORY / "seal_release_candidate_archive_v4.py",
                "build-settings",
                "--repository",
                fixture.repository,
                "--source-commit",
                fixture.commit,
                "--runtime",
                fixture.runtime,
                "--release-configuration",
                fixture.release_configuration,
                "--output",
                settings,
                cwd=fixture.repository,
            )
            self.assertIn(fixture.context["sourceCommit"], settings.read_text())

            app_directory = fixture.root / "cli-app"
            app_directory.mkdir()
            app = fixture.make_application(app_directory)
            unsealed = fixture.root / "cli-unsealed.zip"
            sealed = fixture.root / "cli-sealed.zip"
            zip_directory(app, unsealed)
            with mock.patch.object(
                provenance,
                "clean_source_build",
                side_effect=fixture.clean_build_runner,
            ) as sealer_replay:
                provenance.seal_archive(
                    unsealed,
                    sealed,
                    fixture.context,
                    fixture.tools,
                    source_build_receipt=fixture.receipt_for_application(app),
                )
            sealer_replay.assert_called_once()
            with mock.patch.object(
                provenance,
                "clean_source_build",
                side_effect=fixture.clean_build_runner,
            ) as preparer_replay:
                observed = candidate.make_candidate(fixture.arguments(sealed))
            preparer_replay.assert_called_once()
            self.assertEqual(observed["sourceCommit"], fixture.commit)
            self.assertEqual(
                observed["appBundleSHA256"], provenance.sha256_file(sealed)
            )

    def test_preparation_verifies_signed_attestation_and_exact_archive(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mirmir-candidate-") as temporary:
            fixture = Fixture(Path(temporary))
            archive = fixture.make_sealed_archive("primary")
            identity = fixture.prepare(archive)
            self.assertEqual(identity["sourceCommit"], fixture.commit)
            self.assertEqual(identity["sourceTreeIdentitySHA256"], fixture.context["sourceTreeIdentitySHA256"])
            self.assertEqual(identity["appBundleSHA256"], provenance.sha256_file(archive))
            self.assertEqual(identity["bundleIdentifier"], "com.mirmir.app")
            inspection = provenance.inspect_archive(
                archive,
                fixture.context,
                fixture.tools,
                require_attestation=True,
            )
            self.assertEqual(
                inspection["attestation"]["application"]["executableSHA256"],
                provenance.sha256_bytes(
                    archive_bytes(archive, "Mirmir.app/Contents/MacOS/Mirmir")
                ),
            )
            self.assertTrue(
                inspection["attestation"]["application"]["codeDirectories"]
            )
            slices = inspection["attestation"]["application"][
                "unsignedExecutableSlices"
            ]
            self.assertEqual(
                [item["architecture"] for item in slices],
                ["arm64", "x86_64"],
            )
            self.assertTrue(all(item["byteCount"] > 0 for item in slices))
            self.assertTrue(all(len(item["sha256"]) == 64 for item in slices))

    def test_missing_attestation_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mirmir-candidate-") as temporary:
            fixture = Fixture(Path(temporary))
            app_directory = fixture.root / "app"
            app_directory.mkdir()
            app = fixture.make_application(app_directory)
            archive = fixture.root / "unsealed.zip"
            zip_directory(app, archive)
            with self.assertRaisesRegex(
                provenance.ArchiveProvenanceError,
                "attestation is missing",
            ):
                fixture.prepare(archive)

    def test_source_commit_swap_fails_signed_claim_check(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mirmir-candidate-") as temporary:
            fixture = Fixture(Path(temporary))
            archive = fixture.make_sealed_archive("primary")
            (fixture.repository / "later.txt").write_text("another commit\n")
            run("git", "add", ".", cwd=fixture.repository)
            run("git", "commit", "-qm", "later source", cwd=fixture.repository)
            later = run("git", "rev-parse", "HEAD", cwd=fixture.repository)
            with self.assertRaisesRegex(
                provenance.ArchiveProvenanceError,
                "signed application build claims differ",
            ):
                fixture.prepare(archive, source_commit=later)

    def test_release_configuration_swap_fails_signed_claim_check(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mirmir-candidate-") as temporary:
            fixture = Fixture(Path(temporary))
            archive = fixture.make_sealed_archive("primary")
            with self.assertRaisesRegex(
                provenance.ArchiveProvenanceError,
                "signed application build claims differ",
            ):
                fixture.prepare(
                    archive,
                    release_configuration=fixture.alternate_configuration,
                )

    def test_runtime_swap_fails_signed_claim_check(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mirmir-candidate-") as temporary:
            fixture = Fixture(Path(temporary))
            archive = fixture.make_sealed_archive("primary")
            with self.assertRaisesRegex(
                provenance.ArchiveProvenanceError,
                "signed application build claims differ",
            ):
                fixture.prepare(archive, runtime=fixture.alternate_runtime)

    def test_executable_swap_fails_payload_or_signature_verification(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mirmir-candidate-") as temporary:
            fixture = Fixture(Path(temporary))
            archive = fixture.make_sealed_archive("primary")
            swapped = fixture.root / "executable-swapped.zip"
            rewrite_archive(
                archive,
                swapped,
                {
                    "Mirmir.app/Contents/MacOS/Mirmir":
                        fixture.alternate_executable.read_bytes()
                },
            )
            with self.assertRaises(provenance.ArchiveProvenanceError):
                fixture.prepare(swapped)

    def test_same_plist_application_from_another_build_cannot_reuse_attestation(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mirmir-candidate-") as temporary:
            fixture = Fixture(Path(temporary))
            first = fixture.make_sealed_archive(
                "first",
                executable_source=fixture.primary_executable,
            )
            second = fixture.make_sealed_archive(
                "second",
                executable_source=fixture.alternate_executable,
                source_build_runner=fixture.self_asserting_build_runner,
            )
            self.assertEqual(
                archive_bytes(first, "Mirmir.app/Contents/Info.plist"),
                archive_bytes(second, "Mirmir.app/Contents/Info.plist"),
            )
            mixed = fixture.root / "same-plist-other-build.zip"
            rewrite_archive(
                second,
                mixed,
                {
                    provenance.ATTESTATION_PATH: archive_bytes(
                        first, provenance.ATTESTATION_PATH
                    )
                },
            )
            with self.assertRaisesRegex(
                provenance.ArchiveProvenanceError,
                "identifies another application",
            ):
                fixture.prepare(mixed)

    def test_modified_source_build_with_fresh_matching_attestation_fails_replay(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mirmir-candidate-") as temporary:
            fixture = Fixture(Path(temporary))
            app_directory = fixture.root / "modified-source-app"
            app_directory.mkdir()
            application = fixture.make_application(
                app_directory,
                executable_source=fixture.alternate_executable,
            )
            unsealed = fixture.root / "modified-source-unsealed.zip"
            zip_directory(application, unsealed)

            rejected = fixture.root / "modified-source-rejected.zip"
            with self.assertRaisesRegex(
                provenance.ArchiveProvenanceError,
                "identifies another application",
            ):
                provenance.seal_archive(
                    unsealed,
                    rejected,
                    fixture.context,
                    fixture.tools,
                    source_build_receipt=fixture.receipt_for_application(
                        application
                    ),
                    source_build_runner=fixture.clean_build_runner,
                )
            self.assertFalse(rejected.exists())

            forged = fixture.root / "modified-source-fresh-attestation.zip"
            provenance.seal_archive(
                unsealed,
                forged,
                fixture.context,
                fixture.tools,
                source_build_receipt=fixture.receipt_for_application(application),
                source_build_runner=fixture.self_asserting_build_runner,
            )
            provenance.inspect_archive(
                forged,
                fixture.context,
                fixture.tools,
                require_attestation=True,
            )
            with self.assertRaisesRegex(
                provenance.ArchiveProvenanceError,
                "identifies another application",
            ):
                fixture.prepare(forged)

    def test_unsourced_resource_entitlement_and_signing_policy_fail_replay(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mirmir-candidate-") as temporary:
            fixture = Fixture(Path(temporary))
            mutations: dict[str, callable] = {
                "resource": lambda application: (
                    application / "Contents/Resources/unsourced.txt"
                ).write_text("not in committed source\n", encoding="utf-8"),
                "entitlement": lambda application: self._resign_application(
                    fixture,
                    application,
                    entitlements={"com.example.unsourced-capability": True},
                ),
                "signing-policy": lambda application: self._resign_application(
                    fixture,
                    application,
                    options=None,
                ),
            }
            for name, mutation in mutations.items():
                with self.subTest(name=name):
                    app_directory = fixture.root / f"{name}-app"
                    app_directory.mkdir()
                    application = fixture.make_application(app_directory)
                    mutation(application)
                    if name == "resource":
                        self._resign_application(fixture, application)
                    if name in {"entitlement", "signing-policy"}:
                        expected = (
                            "entitlements differ"
                            if name == "entitlement"
                            else "hardened-runtime policy"
                        )
                        with self.assertRaisesRegex(
                            provenance.ArchiveProvenanceError,
                            expected,
                        ):
                            fixture.receipt_for_application(application)
                        continue
                    unsealed = fixture.root / f"{name}-unsealed.zip"
                    sealed = fixture.root / f"{name}-sealed.zip"
                    zip_directory(application, unsealed)
                    provenance.seal_archive(
                        unsealed,
                        sealed,
                        fixture.context,
                        fixture.tools,
                        source_build_receipt=fixture.receipt_for_application(
                            application
                        ),
                        source_build_runner=fixture.self_asserting_build_runner,
                    )
                    with self.assertRaisesRegex(
                        provenance.ArchiveProvenanceError,
                        "identifies another application|executable, resources, entitlements, or signing policy",
                    ):
                        fixture.prepare(sealed)

    @staticmethod
    def _resign_application(
        fixture: Fixture,
        application: Path,
        *,
        entitlements: dict[str, object] | None = None,
        options: str | None = "runtime",
    ) -> None:
        command: list[str | Path] = [
            "/usr/bin/codesign",
            "--force",
            "--deep",
            "--sign",
            "-",
            "--identifier",
            "com.mirmir.app",
        ]
        if entitlements is None:
            entitlements = plistlib.loads(fixture.entitlements.read_bytes())
            assert isinstance(entitlements, dict)
        if entitlements:
            entitlements_path = fixture.root / "unsourced.entitlements"
            entitlements_path.write_bytes(
                plistlib.dumps(entitlements, sort_keys=True)
            )
            command.extend(("--entitlements", entitlements_path))
        if options is not None:
            command.extend(("--options", options))
        command.append(application)
        run(*command, cwd=fixture.root)

    def test_source_identity_excludes_only_signer_dependent_fields(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mirmir-candidate-") as temporary:
            fixture = Fixture(Path(temporary))
            app_directory = fixture.root / "identity-app"
            app_directory.mkdir()
            application = fixture.make_application(app_directory)
            observed = provenance.application_directory_observation(
                application,
                fixture.context,
            )
            alternate_signer = copy.deepcopy(observed)
            alternate_signer["codeDirectories"][0]["sha256"] = "0" * 64
            alternate_signer["codeDirectorySetSHA256"] = "1" * 64
            alternate_signer["designatedRequirement"] = "designated => false"
            alternate_signer["designatedRequirementSHA256"] = "2" * 64
            alternate_signer["executableSHA256"] = "3" * 64
            self.assertEqual(
                provenance.source_build_application_identity(observed),
                provenance.source_build_application_identity(alternate_signer),
            )
            alternate_signer["entitlementsSHA256"] = "4" * 64
            self.assertNotEqual(
                provenance.source_build_application_identity(observed),
                provenance.source_build_application_identity(alternate_signer),
            )
            alternate_slice = copy.deepcopy(observed)
            alternate_slice["unsignedExecutableSlices"][0]["sha256"] = "5" * 64
            self.assertNotEqual(
                provenance.source_build_application_identity(observed),
                provenance.source_build_application_identity(alternate_slice),
            )

    def test_code_directory_and_requirement_swaps_fail_closed(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mirmir-candidate-") as temporary:
            fixture = Fixture(Path(temporary))
            archive = fixture.make_sealed_archive("primary")
            mutations = {
                "code-directory": lambda value: value["application"]["codeDirectories"][0].update(
                    {"sha256": "0" * 64}
                ),
                "requirement": lambda value: value["application"].update(
                    {
                        "designatedRequirement": 'designated => identifier "other.app"',
                        "designatedRequirementSHA256": "0" * 64,
                    }
                ),
                "archive-payload": lambda value: value["archivePayload"].update(
                    {"identitySHA256": "0" * 64}
                ),
            }
            for name, mutation in mutations.items():
                with self.subTest(name=name):
                    changed = fixture.root / f"{name}.zip"
                    rewrite_archive(
                        archive,
                        changed,
                        {
                            provenance.ATTESTATION_PATH: mutated_attestation(
                                archive, mutation
                            )
                        },
                    )
                    with self.assertRaisesRegex(
                        provenance.ArchiveProvenanceError,
                        "attestation differs",
                    ):
                        fixture.prepare(changed)

    def test_clean_source_receipt_manifest_command_and_toolchain_swaps_fail_closed(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mirmir-candidate-") as temporary:
            fixture = Fixture(Path(temporary))
            archive = fixture.make_sealed_archive("primary")
            mutations = {
                "source-manifest": lambda value: value["sourceBuild"]["cleanSource"][
                    "manifest"
                ].update({"identitySHA256": "0" * 64}),
                "xcodebuild-command": lambda value: value["sourceBuild"]["build"][
                    "command"
                ].append("UNLOCKED=YES"),
                "toolchain": lambda value: value["sourceBuild"]["toolchain"][
                    "xcodebuild"
                ].update({"sha256": "0" * 64}),
                "canonical-layout": lambda value: value["sourceBuild"]["build"][
                    "canonicalLayout"
                ].update({"sourceRoot": "/tmp/unlocked-source"}),
            }
            for name, mutation in mutations.items():
                with self.subTest(name=name):
                    changed = fixture.root / f"clean-build-{name}.zip"
                    rewrite_archive(
                        archive,
                        changed,
                        {
                            provenance.ATTESTATION_PATH: mutated_attestation(
                                archive,
                                mutation,
                            )
                        },
                    )
                    with self.assertRaises(provenance.ArchiveProvenanceError):
                        fixture.prepare(changed)

    def test_external_metal_receipt_mutations_and_mount_paths_fail_closed(self) -> None:
        first_root = Path(
            "/private/var/run/com.apple.security.cryptexd/mnt/"
            "com.apple.MobileAsset.MetalToolchain-v17.3.fixture.A/Metal.xctoolchain"
        )
        second_root = Path(
            "/private/var/run/com.apple.security.cryptexd/mnt/"
            "com.apple.MobileAsset.MetalToolchain-v17.3.fixture.B/Metal.xctoolchain"
        )
        first = provenance._normalize_metal_tool_output(
            f"InstalledDir: {first_root}/usr/metal/current/bin",
            first_root,
        )
        second = provenance._normalize_metal_tool_output(
            f"InstalledDir: {second_root}/usr/metal/current/bin",
            second_root,
        )
        self.assertEqual(first, second)
        self.assertEqual(
            first,
            "InstalledDir: $METAL_TOOLCHAIN/usr/metal/current/bin",
        )

        with tempfile.TemporaryDirectory(prefix="mirmir-candidate-") as temporary:
            fixture = Fixture(Path(temporary))
            app_root = fixture.root / "metal-receipt-app"
            app_root.mkdir()
            application = fixture.make_application(app_root)
            observation = provenance.application_directory_observation(
                application,
                fixture.context,
            )
            receipt = fixture.receipt_for_application(application)
            mutations: dict[str, callable] = {
                "missing-tool": lambda value: value["toolchain"]["metal"].pop(
                    "metalNM"
                ),
                "missing-metallib": lambda value: value["toolchain"][
                    "metal"
                ].pop("metallib"),
                "tampered-tool": lambda value: value["toolchain"]["metal"][
                    "metal"
                ].update({"sha256": "0" * 64}),
                "tampered-metallib-dispatcher": lambda value: value[
                    "toolchain"
                ]["metal"]["metallib"].update({"sha256": "0" * 64}),
                "tampered-metallib-underlying": lambda value: value[
                    "toolchain"
                ]["metal"]["metallib"].update(
                    {"underlyingSHA256": "0" * 64}
                ),
                "substituted-metallib-underlying": lambda value: value[
                    "toolchain"
                ]["metal"]["metallib"].update(
                    {
                        "underlyingComponentRelativePath":
                        "usr/metal/1/bin/metal"
                    }
                ),
                "missing-resource": lambda value: value["toolchain"][
                    "metal"
                ]["resources"]["entries"].pop(),
                "tampered-resource": lambda value: value["toolchain"][
                    "metal"
                ]["resources"]["entries"][0].update(
                    {"sha256": "0" * 64}
                ),
                "substituted-resource-root": lambda value: value[
                    "toolchain"
                ]["metal"]["resources"].update(
                    {
                        "componentRelativePath":
                        "usr/metal/2/lib/clang/fixture-1"
                    }
                ),
                "missing-source": lambda value: value["postBuild"]["metal"][
                    "sources"
                ].pop(),
                "tampered-source": lambda value: value["postBuild"]["metal"][
                    "sources"
                ][0].update({"sha256": "0" * 64}),
                "tampered-output": lambda value: value["postBuild"]["metal"][
                    "link"
                ]["output"].update({"sha256": "0" * 64}),
                "missing-receipt": lambda value: value.pop("postBuild"),
                "tampered-symbols": lambda value: value["postBuild"]["metal"][
                    "symbols"
                ]["inventory"].pop(),
                "tampered-signing-command": lambda value: value["postBuild"][
                    "signing"
                ]["command"].append("--unlocked"),
                "randomized-mount-bound": lambda value: value["toolchain"][
                    "metal"
                ]["metal"]["version"].append(
                    "/var/run/com.apple.MobileAsset.MetalToolchain-random"
                ),
                "tampered-swift-wrapper": lambda value: value["toolchain"][
                    "swiftDriverWrapper"
                ].update({"sha256": "0" * 64}),
                "substituted-wrapper-swiftc": lambda value: value[
                    "toolchain"
                ]["swiftDriverWrapper"]["underlyingSwiftc"].update(
                    {"path": "/fixture/substituted/swiftc"}
                ),
                "tampered-swift-job-audit": lambda value: value[
                    "build"
                ]["swiftDriverJobAudit"].update(
                    {"effectiveJobArgumentsAreTerminal": False}
                ),
                "missing-swift-thread-control": lambda value: value[
                    "build"
                ]["swiftDriverJobAudit"].pop(
                    "effectiveNumThreadsArguments"
                ),
                "duplicated-swift-thread-control": lambda value: value[
                    "build"
                ]["swiftDriverJobAudit"].update(
                    {
                        "effectiveNumThreadsArguments": [
                            "-num-threads",
                            "1",
                            "-num-threads",
                            "1",
                        ]
                    }
                ),
                "substituted-swift-rng-control": lambda value: value[
                    "build"
                ]["swiftDriverJobAudit"].update(
                    {
                        "effectiveLLVMRNGSeedArguments": [
                            "-Xllvm",
                            "-rng-seed=2",
                        ]
                    }
                ),
                "missing-projected-swift-thread-control": lambda value: value[
                    "build"
                ]["swiftDriverJobAudit"].update(
                    {"projectedNumThreadsArguments": []}
                ),
                "duplicated-projected-swift-rng-control": lambda value: value[
                    "build"
                ]["swiftDriverJobAudit"].update(
                    {
                        "projectedLLVMRNGSeedArguments": [
                            "-Xllvm",
                            "-rng-seed=1",
                            "-Xllvm",
                            "-rng-seed=1",
                        ]
                    }
                ),
                "substituted-projected-swift-target": lambda value: value[
                    "build"
                ]["swiftDriverJobAudit"]["markers"].__setitem__(
                    0,
                    value["build"]["swiftDriverJobAudit"]["markers"][0]
                    .replace("arm64-apple", "armv7-apple"),
                ),
            }
            for name, mutation in mutations.items():
                with self.subTest(name=name):
                    changed = copy.deepcopy(receipt)
                    mutation(changed)
                    with self.assertRaises(provenance.ArchiveProvenanceError):
                        provenance.validate_clean_build_receipt(
                            changed,
                            fixture.context,
                            observation,
                        )

    def test_external_metal_source_snapshot_rejects_missing_or_tampered_inputs(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mirmir-metal-source-") as temporary:
            root = Path(temporary)
            source_root = root / "source"
            for relative, _ in provenance.METAL_SOURCE_SPECS:
                source = source_root / relative
                source.parent.mkdir(parents=True, exist_ok=True)
                source.write_text(
                    "#include <metal_stdlib>\nusing namespace metal;\n",
                    encoding="utf-8",
                )
            expected = provenance.metal_source_descriptors(source_root)
            dummy = provenance.MetalToolchainResolution(
                component_root=root,
                metal=root / "metal",
                metallib=root / "metallib",
                metal_nm=root / "metal-nm",
                resource_root=root / "resources",
                receipt={},
            )
            application = root / "Mirmir.app"
            (application / "Contents/Resources").mkdir(parents=True)

            first_source = source_root / provenance.METAL_SOURCE_SPECS[0][0]
            original = first_source.read_bytes()
            first_source.write_bytes(original + b"// tampered\n")
            with self.assertRaisesRegex(
                provenance.ArchiveProvenanceError,
                "inputs changed",
            ):
                provenance.compile_external_metal_library(
                    source_root=source_root,
                    application=application,
                    intermediates=root / "tampered-intermediates",
                    expected_sources=expected,
                    toolchain={"metal": {}, "macOSSDK": {"path": "/fixture/sdk"}},
                    metal_resolution=dummy,
                    environment={},
                )
            first_source.write_bytes(original)
            (source_root / provenance.METAL_SOURCE_SPECS[1][0]).unlink()
            with self.assertRaisesRegex(
                provenance.ArchiveProvenanceError,
                "omits deterministic Metal input",
            ):
                provenance.compile_external_metal_library(
                    source_root=source_root,
                    application=application,
                    intermediates=root / "missing-intermediates",
                    expected_sources=expected,
                    toolchain={"metal": {}, "macOSSDK": {"path": "/fixture/sdk"}},
                    metal_resolution=dummy,
                    environment={},
                )

    def test_external_metal_execution_revalidation_rejects_substitution(self) -> None:
        expected = provenance.MetalToolchainResolution(
            component_root=Path("/fixture/Metal.xctoolchain"),
            metal=Path("/fixture/Metal.xctoolchain/usr/metal/1/bin/metal"),
            metallib=Path("/fixture/Metal.xctoolchain/usr/metal/1/bin/air-lld"),
            metal_nm=Path("/fixture/Metal.xctoolchain/usr/metal/1/bin/air-nm"),
            resource_root=Path(
                "/fixture/Metal.xctoolchain/usr/metal/1/lib/clang/fixture"
            ),
            receipt={"identitySHA256": "1" * 64},
        )
        with mock.patch.object(
            provenance,
            "resolve_metal_toolchain",
            return_value=expected,
        ):
            self.assertEqual(
                provenance.revalidate_metal_toolchain(
                    expected,
                    {},
                    "fixture execution",
                ),
                expected,
            )

        substituted = provenance.MetalToolchainResolution(
            component_root=expected.component_root,
            metal=expected.metal,
            metallib=Path(
                "/fixture/Metal.xctoolchain/usr/metal/2/bin/air-lld"
            ),
            metal_nm=expected.metal_nm,
            resource_root=expected.resource_root,
            receipt=expected.receipt,
        )
        with mock.patch.object(
            provenance,
            "resolve_metal_toolchain",
            return_value=substituted,
        ), self.assertRaisesRegex(
            provenance.ArchiveProvenanceError,
            "changed during fixture execution",
        ):
            provenance.revalidate_metal_toolchain(
                expected,
                {},
                "fixture execution",
            )

        tampered_receipt = provenance.MetalToolchainResolution(
            component_root=expected.component_root,
            metal=expected.metal,
            metallib=expected.metallib,
            metal_nm=expected.metal_nm,
            resource_root=expected.resource_root,
            receipt={"identitySHA256": "0" * 64},
        )
        with mock.patch.object(
            provenance,
            "resolve_metal_toolchain",
            return_value=tampered_receipt,
        ), self.assertRaises(provenance.ArchiveProvenanceError):
            provenance.revalidate_metal_toolchain(
                expected,
                {},
                "fixture execution",
            )

    def test_external_metal_three_run_bytes_are_identical(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mirmir-metal-repeat-") as temporary:
            root = Path(temporary)
            home = root / "home"
            task_tmp = root / "tmp"
            home.mkdir(mode=0o700)
            task_tmp.mkdir(mode=0o700)
            developer = run("/usr/bin/xcode-select", "-p", cwd=root)
            environment = {
                "CFFIXED_USER_HOME": str(home),
                "DEVELOPER_DIR": developer,
                "HOME": str(home),
                "LANG": "C",
                "LC_ALL": "C",
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "SWIFT_DETERMINISTIC_HASHING": "1",
                "SWIFTC_MAXIMUM_DETERMINISM": "1",
                "TMPDIR": str(task_tmp),
            }
            resolution = provenance.resolve_metal_toolchain(environment)
            sdk = run(
                "/usr/bin/xcrun",
                "--sdk",
                "macosx",
                "--show-sdk-path",
                cwd=root,
            )
            toolchain = {
                "macOSSDK": {"path": sdk},
                "metal": resolution.receipt,
            }
            repository = SCRIPT_DIRECTORY.parent.parent
            sources = provenance.metal_source_descriptors(repository)
            records: list[dict[str, object]] = []
            libraries: list[bytes] = []
            for index in range(3):
                application = root / f"run-{index}/Mirmir.app"
                (application / "Contents/Resources").mkdir(parents=True)
                record = provenance.compile_external_metal_library(
                    source_root=repository,
                    application=application,
                    intermediates=root / f"run-{index}/Metal",
                    expected_sources=sources,
                    toolchain=toolchain,
                    metal_resolution=resolution,
                    environment=environment,
                )
                records.append(record)
                libraries.append(
                    (
                        application
                        / provenance.DEFAULT_METAL_LIBRARY_RELATIVE_PATH
                    ).read_bytes()
                )
            self.assertEqual(records[0], records[1])
            self.assertEqual(records[0], records[2])
            self.assertEqual(libraries[0], libraries[1])
            self.assertEqual(libraries[0], libraries[2])

    def test_verified_git_archive_uses_commit_not_dirty_working_tree(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mirmir-candidate-") as temporary:
            fixture = Fixture(Path(temporary))
            (fixture.repository / "source.txt").write_text(
                "modified uncommitted source\n",
                encoding="utf-8",
            )
            replacement = fixture.root / "replacement-source.txt"
            replacement.write_text("replacement-object source\n", encoding="utf-8")
            original_object = run(
                "git",
                "rev-parse",
                f"{fixture.commit}:source.txt",
                cwd=fixture.repository,
            )
            replacement_object = run(
                "git",
                "hash-object",
                "-w",
                replacement,
                cwd=fixture.repository,
            )
            run(
                "git",
                "replace",
                original_object,
                replacement_object,
                cwd=fixture.repository,
            )
            destination = fixture.root / "clean-source"
            destination.mkdir()
            manifest = provenance.verified_git_archive_source(
                fixture.context,
                destination,
            )
            self.assertEqual(
                (destination / "source.txt").read_text(encoding="utf-8"),
                "release source\n",
            )
            expected = provenance.source_manifest_summary(
                provenance.committed_source_manifest(
                    fixture.repository,
                    fixture.commit,
                )
            )
            self.assertEqual(manifest, expected)

    def test_verified_extraction_rechecks_final_executable_and_signing(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mirmir-candidate-") as temporary:
            fixture = Fixture(Path(temporary))
            archive = fixture.make_sealed_archive("primary")
            destination = fixture.root / "extracted"
            destination.mkdir()
            application, executable, inspection = provenance.extract_verified_application(
                archive,
                destination,
                fixture.context,
                fixture.tools,
            )
            self.assertEqual(application, (destination / "Mirmir.app").resolve())
            self.assertEqual(executable, application / "Contents/MacOS/Mirmir")
            self.assertEqual(
                provenance.sha256_file(executable),
                inspection["attestation"]["application"]["executableSHA256"],
            )

    def test_verified_extraction_consumes_held_snapshot_after_path_swap(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mirmir-candidate-") as temporary:
            fixture = Fixture(Path(temporary))
            archive = fixture.make_sealed_archive("held-snapshot")
            original_sha256 = provenance.sha256_file(archive)
            destination = fixture.root / "held-snapshot-extracted"
            destination.mkdir()
            actual_inspection = provenance._inspect_archive_snapshot
            replaced = False

            def replace_path_after_inspection(*args: object, **kwargs: object) -> dict[str, object]:
                nonlocal replaced
                observed = actual_inspection(*args, **kwargs)
                archive.write_bytes(b"replacement after exact snapshot inspection")
                replaced = True
                return observed

            with mock.patch.object(
                provenance,
                "_inspect_archive_snapshot",
                side_effect=replace_path_after_inspection,
            ):
                application, executable, inspection = provenance.extract_verified_application(
                    archive,
                    destination,
                    fixture.context,
                    fixture.tools,
                )

            self.assertTrue(replaced)
            self.assertEqual(inspection["appBundleSHA256"], original_sha256)
            self.assertNotEqual(provenance.sha256_file(archive), original_sha256)
            self.assertEqual(application, (destination / "Mirmir.app").resolve())
            self.assertEqual(
                provenance.sha256_file(executable),
                inspection["attestation"]["application"]["executableSHA256"],
            )

    def test_generated_build_settings_bind_every_signed_claim(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mirmir-candidate-") as temporary:
            fixture = Fixture(Path(temporary))
            text = provenance.build_settings_text(
                fixture.context,
                fixture.release_configuration,
            )
            self.assertIn(
                f'#include "{fixture.release_configuration.resolve()}"',
                text,
            )
            for value in provenance.expected_claims(fixture.context).values():
                self.assertIn(f" = {value}\n", text)
            for key, value in provenance.REPRODUCIBLE_SWIFT_BUILD_SETTINGS.items():
                self.assertIn(f"{key} = {value}\n", text)
            self.assertEqual(
                provenance.canonical_clean_build_layout()["buildRoot"],
                str(provenance.CANONICAL_CLEAN_BUILD_ROOT),
            )

    def test_archive_path_escape_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mirmir-candidate-") as temporary:
            root = Path(temporary)
            archive = root / "unsafe.zip"
            with zipfile.ZipFile(archive, "w") as value:
                value.writestr("../Mirmir.app/Contents/Info.plist", b"invalid")
            with self.assertRaisesRegex(
                provenance.ArchiveProvenanceError,
                "unsafe path",
            ):
                provenance.inspect_archive(
                    archive,
                    {},
                    [],
                    require_attestation=True,
                )


if __name__ == "__main__":
    unittest.main()
