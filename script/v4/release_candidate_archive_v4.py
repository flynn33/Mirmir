#!/usr/bin/env python3
"""Build and verify non-circular provenance for a v4 application archive.

The application carries source/configuration/runtime claims in its signed
Info.plist.  A canonical top-level archive attestation then binds those signed
claims to the final executable, CodeDirectories, designated requirement, and
every other archive entry.  The release-candidate record hashes the resulting
ZIP, which seals the attestation without requiring it to hash itself.
"""

from __future__ import annotations

from contextlib import contextmanager
import ctypes
from dataclasses import dataclass
from datetime import datetime, timezone
import errno
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import re
import shutil
import stat
import subprocess
import tarfile
import tempfile
from typing import Any, Callable, Iterable, Mapping, Sequence
import zipfile


ATTESTATION_PATH = "MirmirV4BuildAttestation.json"
ATTESTATION_SCHEMA = "mirmir-v4-release-build-attestation-v1"
EMBEDDED_CLAIMS_SCHEMA = "mirmir-v4-embedded-build-claims-v1"
MANIFEST_DOMAIN = b"ash-p06-runtime-manifest-v4\0"
PAYLOAD_DOMAIN = b"mirmir-v4-release-archive-payload-v1\0"
CLAIM_SET_DOMAIN = b"mirmir-v4-embedded-build-claim-set-v1\0"
CODE_DIRECTORY_SET_DOMAIN = b"mirmir-v4-code-directory-set-v1\0"
ENTITLEMENTS_DOMAIN = b"mirmir-v4-entitlements-v1\0"
REPRODUCIBLE_BUNDLE_DOMAIN = b"mirmir-v4-reproducible-bundle-content-v2\0"
TOOL_SET_DOMAIN = b"mirmir-v4-release-attestation-tool-set-v1\0"
CLEAN_SOURCE_MANIFEST_DOMAIN = b"mirmir-v4-clean-source-manifest-v1\0"
CLEAN_BUILD_RECEIPT_DOMAIN = b"mirmir-v4-clean-source-build-receipt-v1\0"
CLEAN_BUILD_RECEIPT_SCHEMA = "mirmir-v4-clean-source-build-receipt-v1"
METAL_SOURCE_SET_DOMAIN = b"mirmir-v4-metal-source-set-v1\0"
METAL_OUTPUT_SET_DOMAIN = b"mirmir-v4-metal-output-set-v1\0"
METAL_SYMBOL_SET_DOMAIN = b"mirmir-v4-metal-symbol-set-v1\0"
METAL_TOOL_SET_DOMAIN = b"mirmir-v4-metal-tool-set-v1\0"
METAL_RESOURCE_SET_DOMAIN = b"mirmir-v4-metal-resource-set-v1\0"
SWIFT_DRIVER_WRAPPER_DOMAIN = b"mirmir-v4-swift-driver-wrapper-v1\0"
SWIFT_DRIVER_JOB_AUDIT_DOMAIN = b"mirmir-v4-swift-driver-job-audit-v1\0"
CLEAN_SOURCE_MANIFEST_SCHEMA = "mirmir-v4-clean-source-manifest-v1"
REPRODUCIBLE_BUNDLE_SCHEMA = "mirmir-v4-reproducible-bundle-content-v2"
MAX_ARCHIVE_EXPANDED_BYTES = 4 * 1024 * 1024 * 1024
MAX_CONTROL_FILE_BYTES = 16 * 1024 * 1024
HEX = frozenset("0123456789abcdef")
TOOL_REPOSITORY_PATHS = (
    "script/v4/prepare_release_candidate_v4.py",
    "script/v4/release_candidate_archive_v4.py",
    "script/v4/seal_release_candidate_archive_v4.py",
)
CLAIM_KEYS = {
    "schemaVersion": "MirmirV4BuildProvenanceSchema",
    "buildConfiguration": "MirmirV4BuildConfiguration",
    "sourceCommit": "MirmirV4SourceCommit",
    "sourceTreeIdentitySHA256": "MirmirV4SourceTreeIdentitySHA256",
    "releaseConfigurationSHA256": "MirmirV4ReleaseConfigurationSHA256",
    "runtimeManifestSHA256": "MirmirV4RuntimeManifestSHA256",
    "runtimeManifestFileSHA256": "MirmirV4RuntimeManifestFileSHA256",
    "runtimeArtifactSetSHA256": "MirmirV4RuntimeArtifactSetSHA256",
    "runtimeSourceRevision": "MirmirV4RuntimeSourceRevision",
}
CLEAN_BUILD_PROJECT = "Mirmir.xcodeproj"
CLEAN_BUILD_SCHEME = "Mirmir"
CLEAN_BUILD_CONFIGURATION = "Release"
CLEAN_BUILD_DESTINATION = "generic/platform=macOS"
CLEAN_BUILD_PRODUCT = "Mirmir.app"
CLEAN_BUILD_BUNDLE_IDENTIFIER = "com.mirmir.app"
EXPECTED_APPLICATION_ARCHITECTURES = ("arm64", "x86_64")
CANONICAL_CLEAN_BUILD_ROOT = Path(
    "/private/tmp/com.mirmir.release-v4-canonical-build"
)
METAL_COMPONENT_NAME = "MetalToolchain"
METAL_TARGET_TRIPLE = "air64-apple-macos15.4"
METAL_LANGUAGE_STANDARD = "metal3.2"
METAL_OPTIMIZATION_LEVEL = "-O3"
METAL_ENTITLEMENTS_REPOSITORY_PATH = "Mirmir/Mirmir.entitlements"
DEFAULT_METAL_LIBRARY_RELATIVE_PATH = "Contents/Resources/default.metallib"
METAL_SOURCE_SPECS = (
    (
        "Mirmir/Modules/UpscalerEngine/ASH/ASHMetalSpatialKernelsV3.metal",
        "ASHMetalSpatialKernelsV3.air",
    ),
    (
        "Mirmir/Modules/UpscalerEngine/FixedPointMetalKernelsV4.metal",
        "FixedPointMetalKernelsV4.air",
    ),
)
METAL_UNDERLYING_EXECUTABLES = {
    "metal": "metal",
    "metallib": "air-lld",
    "metal-nm": "air-nm",
}
METAL_RESOURCE_MANIFEST_SCHEMA = "mirmir-v4-metal-resource-manifest-v1"
SWIFT_DRIVER_WRAPPER_SCHEMA = "mirmir-v4-swift-driver-wrapper-v1"
SWIFT_DRIVER_JOB_AUDIT_SCHEMA = "mirmir-v4-swift-driver-job-audit-v1"
SWIFT_DRIVER_JOB_AUDIT_PREFIX = "MIRMIR_V4_SWIFT_DRIVER_EFFECTIVE_ARGV"
SWIFT_DRIVER_REQUIRED_TARGETS = (
    "arm64-apple-macos15.4",
    "x86_64-apple-macos15.4",
)


def swift_driver_job_audit_marker(target: str) -> str:
    if target not in SWIFT_DRIVER_REQUIRED_TARGETS:
        raise ValueError("Swift driver audit target is outside release policy")
    return (
        f"{SWIFT_DRIVER_JOB_AUDIT_PREFIX} target={target} "
        "jobOptionCount=1 terminal=-j,1 "
        "numThreadsCount=1 numThreads=1 "
        "llvmRNGSeedCount=1 llvmRNGSeed=1 "
        "projectedFrontendJobCount=1 "
        "projectedNumThreadsCount=1 projectedNumThreads=1 "
        "projectedLLVMRNGSeedCount=1 projectedLLVMRNGSeed=1"
    )


SWIFT_DRIVER_JOB_AUDIT_MARKERS = tuple(
    swift_driver_job_audit_marker(target)
    for target in SWIFT_DRIVER_REQUIRED_TARGETS
)
REQUIRED_METAL_RESOURCE_PATHS = (
    "include/metal/metal_stdlib",
    "include/metal/module.modulemap",
    "lib/darwin/libmetal_rt_osx.a",
)
EXPECTED_METAL_SYMBOLS = (
    "ashFixedPointScaleV4",
    "ash_p08_fixed_reconstruct_chroma",
    "ash_p08_fixed_reconstruct_luma",
    "ash_v3_analyze_chroma_and_pack_state",
    "ash_v3_analyze_luma",
    "ash_v3_decode_dispatch",
    "ash_v3_descriptor_parity_probe",
    "ash_v3_finalize_reduction",
    "ash_v3_reconstruct_chroma",
    "ash_v3_reconstruct_luma",
    "ash_v3_state_pack_parity_probe",
)
CLEAN_REPLAY_BUILD_SETTINGS = {
    "CODE_SIGN_IDENTITY": "-",
    "CODE_SIGN_INJECT_BASE_ENTITLEMENTS": "NO",
    "CODE_SIGN_STYLE": "Manual",
    "ENABLE_TESTABILITY": "NO",
}
SIGNATURE_MODE_CODE_DIRECTORY_FLAGS = 0x00000002  # CS_ADHOC
HARDENED_RUNTIME_CODE_DIRECTORY_FLAGS = 0x00010000  # CS_RUNTIME

REPRODUCIBLE_SWIFT_BUILD_SETTINGS = {
    "CLANG_CACHE_FINE_GRAINED_OUTPUTS": "NO",
    "CLANG_ENABLE_EXPLICIT_MODULES": "YES",
    "COMPILATION_CACHE_ENABLE_CACHING": "NO",
    "DEBUG_INFORMATION_FORMAT": "",
    "EXCLUDED_SOURCE_FILE_NAMES": "$(inherited) *.metal",
    "GCC_GENERATE_DEBUGGING_SYMBOLS": "NO",
    "OTHER_SWIFT_FLAGS": (
        "$(inherited) -disable-incremental-imports "
        "-gnone -Xfrontend -enable-single-module-llvm-emission "
        "-j 1 -num-threads 1 -Xllvm -rng-seed=1 "
        "-Xfrontend -file-compilation-dir -Xfrontend /mirmir/source "
        "-file-prefix-map $(SRCROOT)=/mirmir/source "
        "-debug-prefix-map $(SRCROOT)=/mirmir/source"
    ),
    "SDK_STAT_CACHE_ENABLE": "NO",
    "SWIFT_COMPILATION_MODE": "wholemodule",
    "SWIFT_ENABLE_BATCH_MODE": "NO",
    "SWIFT_ENABLE_EXPLICIT_MODULES": "NO",
    "SWIFT_EAGER_MODULE_EMISSION_IN_WMO": "NO",
    "SWIFT_OPTIMIZATION_LEVEL": "-O",
    "SWIFT_SERIALIZE_DEBUGGING_OPTIONS": "NO",
    "SWIFT_USE_INTEGRATED_DRIVER": "NO",
    "SWIFT_USE_PARALLEL_WHOLE_MODULE_OPTIMIZATION": "NO",
    "SWIFT_USE_PARALLEL_WMO_TARGETS": "NO",
    "SWIFT_WHOLE_MODULE_OPTIMIZATION": "YES",
    "ZERO_AR_DATE": "YES",
}


CleanBuildRunner = Callable[
    [Mapping[str, str], Mapping[str, Any], Mapping[str, str]],
    dict[str, Any],
]


class ArchiveProvenanceError(ValueError):
    """The application archive cannot be tied to the declared release build."""


@dataclass(frozen=True)
class ArchiveEntry:
    info: zipfile.ZipInfo
    path: str
    kind: str
    unix_mode: int
    byte_count: int
    sha256: str

    def descriptor(self) -> dict[str, Any]:
        return {
            "byteCount": self.byte_count,
            "kind": self.kind,
            "path": self.path,
            "sha256": self.sha256,
            "unixMode": self.unix_mode,
        }


@dataclass(frozen=True)
class PublicationTarget:
    path: Path
    parent_identity: tuple[int, ...]


@dataclass(frozen=True)
class MetalToolchainResolution:
    component_root: Path
    metal: Path
    metallib: Path
    metal_nm: Path
    resource_root: Path
    receipt: dict[str, Any]


@dataclass(frozen=True)
class SwiftDriverWrapperInstallation:
    path: Path
    identity: tuple[int, ...]
    audit_path: Path
    audit_identity: tuple[int, ...]
    receipt: dict[str, Any]


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ArchiveProvenanceError(message)


def reject_duplicate_pairs(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    value: dict[str, Any] = {}
    for key, item in pairs:
        require(key not in value, f"duplicate JSON key: {key}")
        value[key] = item
    return value


def reject_nonfinite(value: str) -> None:
    raise ArchiveProvenanceError(f"non-finite JSON value is forbidden: {value}")


def load_json_bytes(raw: bytes, label: str) -> Any:
    try:
        return json.loads(
            raw,
            object_pairs_hook=reject_duplicate_pairs,
            parse_constant=reject_nonfinite,
        )
    except (UnicodeError, json.JSONDecodeError) as error:
        raise ArchiveProvenanceError(f"cannot decode {label}: {error}") from error


def canonical_bytes(value: Any) -> bytes:
    return json.dumps(
        value,
        ensure_ascii=False,
        allow_nan=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    try:
        with path.open("rb") as stream:
            for block in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(block)
    except OSError as error:
        raise ArchiveProvenanceError(f"cannot hash {path}: {error}") from error
    return digest.hexdigest()


def _stable_node_identity(metadata: os.stat_result) -> tuple[int, ...]:
    return (
        metadata.st_dev,
        metadata.st_ino,
        metadata.st_mode,
        metadata.st_uid,
    )


def publication_target(raw_path: Path, label: str) -> PublicationTarget:
    """Resolve and hold the directory identity used for final publication."""

    raw_path = raw_path.expanduser()
    require(
        raw_path.name not in {"", ".", ".."}
        and not raw_path.parent.is_symlink(),
        f"{label} output path or parent is unsafe",
    )
    try:
        parent = raw_path.parent.resolve(strict=True)
        metadata = os.lstat(parent)
    except OSError as error:
        raise ArchiveProvenanceError(
            f"cannot inspect {label} output parent: {error}"
        ) from error
    require(
        stat.S_ISDIR(metadata.st_mode),
        f"{label} output parent is not a directory",
    )
    return PublicationTarget(
        path=parent / raw_path.name,
        parent_identity=_stable_node_identity(metadata),
    )


def _publish_no_clobber(
    source: Path,
    target: PublicationTarget,
    label: str,
) -> Path:
    """Atomically publish within a held parent without replacing any entry."""

    parent = target.path.parent
    flags = (
        os.O_RDONLY
        | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_DIRECTORY", 0)
        | getattr(os, "O_NOFOLLOW", 0)
    )
    try:
        parent_descriptor = os.open(parent, flags)
    except OSError as error:
        raise ArchiveProvenanceError(
            f"cannot hold {label} output parent: {error}"
        ) from error
    try:
        held_parent = os.fstat(parent_descriptor)
        path_parent = os.stat(parent, follow_symlinks=False)
        require(
            _stable_node_identity(held_parent)
            == _stable_node_identity(path_parent)
            == target.parent_identity
            and stat.S_ISDIR(held_parent.st_mode),
            f"{label} output parent changed before publication",
        )
        try:
            relative_source = source.relative_to(parent)
        except ValueError as error:
            raise ArchiveProvenanceError(
                f"{label} staging path is outside its output parent"
            ) from error
        require(
            relative_source.parts
            and all(part not in {"", ".", ".."} for part in relative_source.parts),
            f"{label} staging path is unsafe",
        )
        source_metadata = os.stat(
            relative_source.as_posix(),
            dir_fd=parent_descriptor,
            follow_symlinks=False,
        )
        require(
            _stable_node_identity(source_metadata)
            == _stable_node_identity(os.lstat(source)),
            f"{label} staging entry changed before publication",
        )
        renameatx_np = ctypes.CDLL(None, use_errno=True).renameatx_np
        renameatx_np.argtypes = (
            ctypes.c_int,
            ctypes.c_char_p,
            ctypes.c_int,
            ctypes.c_char_p,
            ctypes.c_uint,
        )
        renameatx_np.restype = ctypes.c_int
        result = renameatx_np(
            parent_descriptor,
            os.fsencode(relative_source.as_posix()),
            parent_descriptor,
            os.fsencode(target.path.name),
            0x00000004,  # RENAME_EXCL
        )
        if result != 0:
            error_number = ctypes.get_errno()
            if error_number == errno.EEXIST:
                raise ArchiveProvenanceError(
                    f"refusing to overwrite {label}: {target.path}"
                )
            raise ArchiveProvenanceError(
                f"cannot publish {label}: {os.strerror(error_number)}"
            )
        require(
            _stable_node_identity(os.fstat(parent_descriptor))
            == _stable_node_identity(os.stat(parent, follow_symlinks=False))
            == target.parent_identity,
            f"{label} output parent changed during publication",
        )
        published = os.stat(
            target.path.name,
            dir_fd=parent_descriptor,
            follow_symlinks=False,
        )
        require(
            _stable_node_identity(published)
            == _stable_node_identity(source_metadata),
            f"{label} published entry differs from its staging entry",
        )
        return target.path
    except OSError as error:
        raise ArchiveProvenanceError(
            f"cannot publish {label}: {error}"
        ) from error
    finally:
        os.close(parent_descriptor)


def write_bytes_no_clobber(
    raw_output: Path,
    content: bytes,
    *,
    label: str,
    mode: int = 0o644,
) -> Path:
    target = publication_target(raw_output, label)
    temporary_path: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(
            prefix=f".{target.path.name}.",
            suffix=".tmp",
            dir=target.path.parent,
            delete=False,
        ) as temporary:
            temporary_path = Path(temporary.name)
            temporary.write(content)
            temporary.flush()
            os.fsync(temporary.fileno())
        temporary_path.chmod(mode)
        return _publish_no_clobber(temporary_path, target, label)
    finally:
        if temporary_path is not None:
            temporary_path.unlink(missing_ok=True)


def load_canonical_json_file(path: Path, label: str) -> Any:
    """Read canonical JSON once from a held no-follow regular-file handle."""

    raw_path = path.expanduser()
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(raw_path, flags)
    except OSError as error:
        raise ArchiveProvenanceError(f"cannot open {label}: {error}") from error
    try:
        with os.fdopen(descriptor, "rb", closefd=True) as stream:
            descriptor = -1
            before = os.fstat(stream.fileno())
            require(
                stat.S_ISREG(before.st_mode)
                and 0 < before.st_size <= MAX_CONTROL_FILE_BYTES,
                f"{label} is not a bounded regular file",
            )
            raw = stream.read(MAX_CONTROL_FILE_BYTES + 1)
            after = os.fstat(stream.fileno())
        path_after = os.stat(raw_path, follow_symlinks=False)
        require(
            len(raw) == before.st_size
            and _archive_file_identity(before)
            == _archive_file_identity(after)
            == _archive_file_identity(path_after),
            f"{label} changed while it was read",
        )
    except BaseException:
        if descriptor >= 0:
            os.close(descriptor)
        raise
    value = load_json_bytes(raw, label)
    require(raw == canonical_bytes(value), f"{label} is not canonical JSON")
    return value


def _archive_file_identity(metadata: os.stat_result) -> tuple[int, ...]:
    return (
        metadata.st_dev,
        metadata.st_ino,
        metadata.st_mode,
        metadata.st_size,
        metadata.st_mtime_ns,
        metadata.st_ctime_ns,
    )


def _snapshot_archive(path: Path) -> tuple[Any, str]:
    """Copy one held regular-file descriptor into an anonymous snapshot."""

    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(path, flags)
    snapshot = tempfile.TemporaryFile(prefix="mirmir-v4-archive-snapshot-")
    try:
        with os.fdopen(descriptor, "rb", closefd=True) as source:
            descriptor = -1
            before = os.fstat(source.fileno())
            require(
                stat.S_ISREG(before.st_mode),
                "application archive descriptor is not a regular file",
            )
            digest = hashlib.sha256()
            for block in iter(lambda: source.read(1024 * 1024), b""):
                digest.update(block)
                snapshot.write(block)
            after = os.fstat(source.fileno())
        path_after = os.stat(path, follow_symlinks=False)
        require(
            _archive_file_identity(before)
            == _archive_file_identity(after)
            == _archive_file_identity(path_after),
            "application archive changed while it was snapshotted",
        )
        snapshot.flush()
        snapshot.seek(0)
        return snapshot, digest.hexdigest()
    except BaseException:
        snapshot.close()
        if descriptor >= 0:
            os.close(descriptor)
        raise


def require_hex(value: Any, lengths: Sequence[int], label: str) -> str:
    require(
        isinstance(value, str)
        and len(value) in lengths
        and set(value) <= HEX,
        f"{label} is not lowercase hexadecimal",
    )
    return value


def artifact_set_sha(entries: Iterable[tuple[str, str]]) -> str:
    digest = hashlib.sha256()
    digest.update(b"mirmir-artifact-set-v1\0")
    for relative, identity in sorted(entries):
        digest.update(relative.encode("utf-8"))
        digest.update(b"\0")
        digest.update(identity.encode("ascii"))
        digest.update(b"\n")
    return digest.hexdigest()


def git_environment() -> dict[str, str]:
    return {
        "GIT_ATTR_NOSYSTEM": "1",
        "GIT_CONFIG_GLOBAL": "/dev/null",
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_CONFIG_SYSTEM": "/dev/null",
        "LANG": "C",
        "LC_ALL": "C",
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
    }


def git_output(repository: Path, arguments: Sequence[str], *, binary: bool = False) -> Any:
    process = subprocess.run(
        ["/usr/bin/git", "--no-replace-objects", *arguments],
        cwd=repository,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=git_environment(),
        check=False,
    )
    if process.returncode != 0:
        raise ArchiveProvenanceError(
            f"git {' '.join(arguments)} failed: "
            + process.stderr.decode("utf-8", errors="replace").strip()
        )
    return process.stdout if binary else process.stdout.decode("utf-8").strip()


def source_tree_identity(repository: Path, commit: str) -> str:
    tree = git_output(
        repository,
        ["ls-tree", "-r", "-z", "--full-tree", commit],
        binary=True,
    )
    return sha256_bytes(b"mirmir-source-tree-v1\0" + tree)


def regular_files(root: Path) -> list[Path]:
    require(root.is_dir() and not root.is_symlink(), f"unsafe directory: {root}")
    files: list[Path] = []
    for path in root.rglob("*"):
        require(not path.is_symlink(), f"symbolic links are forbidden: {path}")
        if path.is_file():
            files.append(path)
        else:
            require(path.is_dir(), f"special filesystem entries are forbidden: {path}")
    return sorted(files, key=lambda item: item.relative_to(root).as_posix())


def bundle_entries(root: Path) -> list[tuple[str, str]]:
    return [
        (path.relative_to(root).as_posix(), sha256_file(path))
        for path in regular_files(root)
    ]


def committed_file_set(repository: Path, commit: str, relative_root: str) -> list[str]:
    output = git_output(
        repository,
        ["ls-tree", "-r", "--name-only", "-z", commit, "--", relative_root],
        binary=True,
    )
    return sorted(item.decode("utf-8") for item in output.split(b"\0") if item)


def require_committed_tree(
    repository: Path,
    commit: str,
    local_root: Path,
    repository_relative_root: str,
) -> None:
    local_paths = regular_files(local_root)
    expected = [
        f"{repository_relative_root}/{path.relative_to(local_root).as_posix()}"
        for path in local_paths
    ]
    observed = committed_file_set(repository, commit, repository_relative_root)
    require(
        expected == observed,
        "committed runtime file set differs from the supplied bundle; "
        f"missing={sorted(set(expected) - set(observed))}, "
        f"unexpected={sorted(set(observed) - set(expected))}",
    )
    for local_path, relative_path in zip(local_paths, expected):
        committed = git_output(
            repository,
            ["show", f"{commit}:{relative_path}"],
            binary=True,
        )
        require(
            committed == local_path.read_bytes(),
            f"release input differs from candidate commit: {relative_path}",
        )


def require_committed_file(
    repository: Path,
    commit: str,
    local_path: Path,
    repository_relative_path: str,
) -> None:
    require(local_path.is_file() and not local_path.is_symlink(), f"unsafe release input: {local_path}")
    committed = git_output(
        repository,
        ["show", f"{commit}:{repository_relative_path}"],
        binary=True,
    )
    require(
        committed == local_path.read_bytes(),
        f"release input differs from candidate commit: {repository_relative_path}",
    )


def release_context(
    repository: Path,
    source_commit: str,
    runtime: Path,
    release_configuration: Path,
) -> dict[str, str]:
    repository = repository.expanduser()
    runtime = runtime.expanduser()
    release_configuration = release_configuration.expanduser()
    require(not repository.is_symlink(), "repository cannot be a symbolic link")
    require(not runtime.is_symlink(), "runtime cannot be a symbolic link")
    require(
        not release_configuration.is_symlink(),
        "Release configuration cannot be a symbolic link",
    )
    repository = repository.resolve(strict=True)
    runtime = runtime.resolve(strict=True)
    release_configuration = release_configuration.resolve(strict=True)
    commit = git_output(repository, ["rev-parse", f"{source_commit}^{{commit}}"])
    require_hex(commit, (40,), "source commit")
    try:
        runtime_relative = runtime.relative_to(repository).as_posix()
        release_relative = release_configuration.relative_to(repository).as_posix()
    except ValueError as error:
        raise ArchiveProvenanceError("runtime and Release configuration must be inside the repository") from error
    require_committed_tree(repository, commit, runtime, runtime_relative)
    require_committed_file(repository, commit, release_configuration, release_relative)

    manifest_path = runtime / "runtime-manifest.json"
    raw_manifest = manifest_path.read_bytes()
    manifest = load_json_bytes(raw_manifest, "runtime manifest")
    require(isinstance(manifest, dict), "runtime manifest is not an object")
    require(raw_manifest == canonical_bytes(manifest), "runtime manifest is not canonical JSON")
    provenance = manifest.get("provenance")
    require(isinstance(provenance, dict), "P06 runtime provenance is missing")
    runtime_source = require_hex(
        provenance.get("sourceRevision"), (40, 64), "runtime source revision"
    )
    return {
        "repositoryAbsolutePath": str(repository),
        "sourceCommit": commit,
        "sourceTreeIdentitySHA256": source_tree_identity(repository, commit),
        "runtimeManifestSHA256": sha256_bytes(MANIFEST_DOMAIN + canonical_bytes(manifest)),
        "runtimeManifestFileSHA256": sha256_bytes(raw_manifest),
        "runtimeArtifactSetSHA256": artifact_set_sha(bundle_entries(runtime)),
        "runtimeSourceRevision": runtime_source,
        "releaseConfigurationSHA256": sha256_file(release_configuration),
        "runtimeRepositoryRelativePath": runtime_relative,
        "releaseConfigurationRepositoryRelativePath": release_relative,
    }


def tool_descriptors(repository: Path, commit: str) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for relative in TOOL_REPOSITORY_PATHS:
        local = repository / relative
        require_committed_file(repository, commit, local, relative)
        tree_row = git_output(
            repository,
            ["ls-tree", commit, "--", relative],
        )
        match = re.fullmatch(
            r"(100644|100755) blob [0-9a-f]+\t" + re.escape(relative),
            tree_row,
        )
        require(match is not None, f"attestation tool has an invalid git mode: {relative}")
        git_mode = match.group(1)
        local_executable = bool(local.stat().st_mode & 0o111)
        require(
            local_executable == (git_mode == "100755"),
            f"attestation tool executable mode differs from candidate commit: {relative}",
        )
        rows.append(
            {
                "byteCount": local.stat().st_size,
                "gitMode": git_mode,
                "repositoryRelativePath": relative,
                "sha256": sha256_file(local),
            }
        )
    return rows


def normalize_clean_build_settings(
    values: Mapping[str, str] | None,
) -> dict[str, str]:
    supplied = dict(values or {})
    require(
        not supplied or supplied == CLEAN_REPLAY_BUILD_SETTINGS,
        "clean replay signing settings are fixed and cannot be overridden",
    )
    return dict(CLEAN_REPLAY_BUILD_SETTINGS)


def _canonical_repository_path(value: str, label: str) -> str:
    require(value and "\\" not in value, f"{label} is not a canonical path: {value!r}")
    path = PurePosixPath(value)
    require(
        not path.is_absolute()
        and all(component not in {"", ".", ".."} for component in path.parts)
        and path.as_posix() == value,
        f"{label} is not a safe repository-relative path: {value!r}",
    )
    return value


def committed_source_manifest(repository: Path, commit: str) -> dict[str, Any]:
    raw_tree = git_output(
        repository,
        ["ls-tree", "-r", "-z", "--full-tree", commit],
        binary=True,
    )
    tree_entries: list[tuple[str, str, str]] = []
    for raw_row in raw_tree.split(b"\0"):
        if not raw_row:
            continue
        try:
            metadata, raw_path = raw_row.split(b"\t", 1)
            mode, object_type, object_identity = metadata.decode("ascii").split(" ")
            relative = raw_path.decode("utf-8")
        except (UnicodeError, ValueError) as error:
            raise ArchiveProvenanceError("candidate commit has an undecodable tree entry") from error
        relative = _canonical_repository_path(relative, "candidate tree path")
        require(
            mode in {"100644", "100755"} and object_type == "blob",
            f"candidate source contains a link, submodule, or special entry: {relative}",
        )
        require(
            re.fullmatch(r"[0-9a-f]+", object_identity) is not None,
            f"candidate tree object identity is invalid: {relative}",
        )
        tree_entries.append((relative, mode, object_identity))
    tree_entries.sort(key=lambda item: item[0])
    descriptors: list[dict[str, Any]] = []
    total_byte_count = 0
    process = subprocess.Popen(
        ["/usr/bin/git", "--no-replace-objects", "cat-file", "--batch"],
        cwd=repository,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=git_environment(),
    )
    require(
        process.stdin is not None and process.stdout is not None,
        "cannot open git object reader",
    )
    try:
        for relative, mode, object_identity in tree_entries:
            process.stdin.write(object_identity.encode("ascii") + b"\n")
            process.stdin.flush()
            header = process.stdout.readline()
            try:
                observed_identity, object_type, raw_size = header.decode("ascii").strip().split(" ")
                byte_count = int(raw_size)
            except (UnicodeError, ValueError) as error:
                raise ArchiveProvenanceError(
                    f"cannot read committed source object: {relative}"
                ) from error
            require(
                observed_identity == object_identity
                and object_type == "blob"
                and byte_count >= 0,
                f"candidate source object differs from its tree entry: {relative}",
            )
            total_byte_count += byte_count
            require(
                total_byte_count <= MAX_ARCHIVE_EXPANDED_BYTES,
                "candidate source tree expands beyond 4 GiB",
            )
            content = process.stdout.read(byte_count)
            separator = process.stdout.read(1)
            require(
                len(content) == byte_count and separator == b"\n",
                f"candidate source object is truncated: {relative}",
            )
            descriptors.append(
                {
                    "byteCount": byte_count,
                    "gitMode": mode,
                    "path": relative,
                    "sha256": sha256_bytes(content),
                }
            )
        process.stdin.close()
        return_code = process.wait()
        error_output = (
            process.stderr.read().decode("utf-8", errors="replace").strip()
            if process.stderr is not None
            else ""
        )
        require(return_code == 0, f"git object inspection failed: {error_output}")
    finally:
        if process.stdin is not None and not process.stdin.closed:
            process.stdin.close()
        if process.poll() is None:
            process.kill()
            process.wait()
        if process.stdout is not None:
            process.stdout.close()
        if process.stderr is not None:
            process.stderr.close()
    require(descriptors, "candidate commit has no regular source files")
    return {
        "entryCount": len(descriptors),
        "identitySHA256": sha256_bytes(
            CLEAN_SOURCE_MANIFEST_DOMAIN + canonical_bytes(descriptors)
        ),
        "schemaVersion": CLEAN_SOURCE_MANIFEST_SCHEMA,
        "totalByteCount": sum(item["byteCount"] for item in descriptors),
        "_entries": descriptors,
    }


def source_manifest_summary(manifest: Mapping[str, Any]) -> dict[str, Any]:
    return {
        key: manifest[key]
        for key in (
            "schemaVersion",
            "entryCount",
            "totalByteCount",
            "identitySHA256",
        )
    }


def clean_source_export_command(commit: str, output: str) -> list[str]:
    return [
        "/usr/bin/git",
        "--no-replace-objects",
        "-c",
        "tar.umask=0022",
        "archive",
        "--format=tar",
        f"--output={output}",
        commit,
    ]


def verified_git_archive_source(
    context: Mapping[str, str],
    destination: Path,
) -> dict[str, Any]:
    repository = Path(context["repositoryAbsolutePath"]).resolve(strict=True)
    destination = destination.expanduser()
    require(
        destination.is_dir()
        and not destination.is_symlink()
        and next(destination.iterdir(), None) is None,
        "clean source destination must be an existing empty non-symlink directory",
    )
    destination = destination.resolve(strict=True)
    manifest = committed_source_manifest(repository, context["sourceCommit"])
    expected = {item["path"]: item for item in manifest["_entries"]}
    archive_path = destination.parent / "clean-source.tar"
    require(not archive_path.exists(), "clean source archive path already exists")
    process = subprocess.run(
        clean_source_export_command(context["sourceCommit"], str(archive_path)),
        cwd=repository,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=git_environment(),
        check=False,
    )
    require(
        process.returncode == 0,
        "git archive failed: "
        + process.stderr.decode("utf-8", errors="replace").strip(),
    )
    observed: set[str] = set()
    seen_paths: set[str] = set()
    directory_modes: list[tuple[Path, int]] = []
    try:
        with tarfile.open(archive_path, mode="r:") as archive:
            for member in archive:
                relative = _canonical_repository_path(member.name, "git archive path")
                require(relative not in seen_paths, f"git archive repeats path: {relative}")
                seen_paths.add(relative)
                if member.isdir():
                    target = destination.joinpath(*PurePosixPath(relative).parts)
                    target.mkdir(parents=True, exist_ok=True)
                    directory_modes.append((target, member.mode & 0o777))
                    continue
                require(member.isfile(), f"git archive contains a link or special entry: {relative}")
                require(relative in expected, f"git archive contains an uncommitted file: {relative}")
                observed.add(relative)
                descriptor = expected[relative]
                expected_mode = 0o755 if descriptor["gitMode"] == "100755" else 0o644
                require(
                    member.mode & 0o777 == expected_mode,
                    f"git archive mode differs from candidate commit: {relative}",
                )
                require(
                    member.size == descriptor["byteCount"],
                    f"git archive size differs from candidate commit: {relative}",
                )
                source = archive.extractfile(member)
                require(source is not None, f"cannot read git archive entry: {relative}")
                target = destination.joinpath(*PurePosixPath(relative).parts)
                target.parent.mkdir(parents=True, exist_ok=True)
                digest = hashlib.sha256()
                byte_count = 0
                with source, target.open("xb") as output:
                    for block in iter(lambda: source.read(1024 * 1024), b""):
                        byte_count += len(block)
                        digest.update(block)
                        output.write(block)
                require(
                    byte_count == descriptor["byteCount"]
                    and digest.hexdigest() == descriptor["sha256"],
                    f"git archive content differs from candidate commit: {relative}",
                )
                target.chmod(expected_mode)
    except (OSError, tarfile.TarError) as error:
        raise ArchiveProvenanceError(f"cannot extract clean git archive: {error}") from error
    finally:
        archive_path.unlink(missing_ok=True)
    require(
        observed == set(expected),
        "git archive file set differs from candidate commit; "
        f"missing={sorted(set(expected) - observed)}, "
        f"unexpected={sorted(observed - set(expected))}",
    )
    for directory, mode in sorted(
        directory_modes,
        key=lambda item: len(item[0].parts),
        reverse=True,
    ):
        directory.chmod(mode)
    return source_manifest_summary(manifest)


def expected_claims(context: Mapping[str, str]) -> dict[str, str]:
    return {
        "schemaVersion": EMBEDDED_CLAIMS_SCHEMA,
        "buildConfiguration": "Release",
        **{
            key: context[key]
            for key in (
                "sourceCommit",
                "sourceTreeIdentitySHA256",
                "releaseConfigurationSHA256",
                "runtimeManifestSHA256",
                "runtimeManifestFileSHA256",
                "runtimeArtifactSetSHA256",
                "runtimeSourceRevision",
            )
        },
    }


def claims_from_plist(plist: Mapping[str, Any]) -> dict[str, str]:
    claims: dict[str, str] = {}
    for output_key, plist_key in CLAIM_KEYS.items():
        value = plist.get(plist_key)
        require(isinstance(value, str) and value, f"application Info.plist omits {plist_key}")
        claims[output_key] = value
    return claims


def _entry_path(info: zipfile.ZipInfo) -> tuple[str, bool]:
    raw = info.filename
    is_directory = info.is_dir() or raw.endswith("/")
    value = raw[:-1] if is_directory and raw.endswith("/") else raw
    require(value != "" and "\\" not in value, f"archive contains a non-canonical path: {raw}")
    pure = PurePosixPath(value)
    require(
        not pure.is_absolute()
        and all(component not in {"", ".", ".."} for component in pure.parts)
        and pure.as_posix() == value,
        f"archive contains an unsafe path: {raw}",
    )
    return value, is_directory


def _is_appledouble_path(path: str) -> bool:
    parts = PurePosixPath(path).parts
    return "__MACOSX" in parts or any(part.startswith("._") for part in parts)


def _entry_digest(value: zipfile.ZipFile, info: zipfile.ZipInfo) -> str:
    digest = hashlib.sha256()
    with value.open(info, "r") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def inspect_entries(value: zipfile.ZipFile) -> list[ArchiveEntry]:
    entries: list[ArchiveEntry] = []
    seen: set[str] = set()
    total = 0
    for info in value.infolist():
        path, is_directory = _entry_path(info)
        require(path not in seen, f"archive repeats path: {path}")
        seen.add(path)
        require(
            not _is_appledouble_path(path),
            f"archive contains unsupported AppleDouble metadata: {path}",
        )
        require(info.flag_bits & 0x1 == 0, f"archive entry is encrypted: {path}")
        file_type = (info.external_attr >> 16) & 0o170000
        allowed = (0, stat.S_IFDIR) if is_directory else (0, stat.S_IFREG)
        require(file_type in allowed, f"archive contains a link or special entry: {path}")
        require(info.file_size >= 0, f"archive entry has an invalid size: {path}")
        total += info.file_size
        require(total <= MAX_ARCHIVE_EXPANDED_BYTES, "application archive expands beyond 4 GiB")
        if is_directory:
            require(info.file_size == 0, f"archive directory contains data: {path}")
            kind = "directory"
            identity = sha256_bytes(b"")
            default_mode = 0o755
        else:
            kind = "file"
            identity = _entry_digest(value, info)
            default_mode = 0o644
        encoded_mode = (info.external_attr >> 16) & 0o7777
        require(
            encoded_mode & 0o7000 == 0,
            f"archive entry has unsafe special mode bits: {path}",
        )
        unix_mode = encoded_mode or default_mode
        require(
            unix_mode & 0o022 == 0,
            f"archive entry is group/world writable: {path}",
        )
        entries.append(
            ArchiveEntry(
                info=info,
                path=path,
                kind=kind,
                unix_mode=unix_mode,
                byte_count=info.file_size,
                sha256=identity,
            )
        )
    require(entries, "application archive is empty")
    return entries


def payload_descriptors(entries: Sequence[ArchiveEntry]) -> list[dict[str, Any]]:
    return [
        entry.descriptor()
        for entry in sorted(entries, key=lambda item: item.path)
        if entry.path != ATTESTATION_PATH
    ]


def payload_identity(entries: Sequence[ArchiveEntry]) -> str:
    return sha256_bytes(PAYLOAD_DOMAIN + canonical_bytes(payload_descriptors(entries)))


def _is_signature_managed_bundle_path(
    relative_path: str,
    executable_relative_path: str,
) -> bool:
    parts = PurePosixPath(relative_path).parts
    return (
        relative_path == executable_relative_path
        or relative_path == "Contents/CodeResources"
        or (
            len(parts) >= 2
            and parts[0] == "Contents"
            and parts[1] == "_CodeSignature"
        )
    )


def _reproducible_bundle_summary(
    descriptors: Sequence[Mapping[str, Any]],
) -> dict[str, Any]:
    ordered = sorted((dict(item) for item in descriptors), key=lambda item: item["path"])
    require(ordered, "application has no reproducible bundle content")
    return {
        "entryCount": len(ordered),
        "identitySHA256": sha256_bytes(
            REPRODUCIBLE_BUNDLE_DOMAIN + canonical_bytes(ordered)
        ),
        "schemaVersion": REPRODUCIBLE_BUNDLE_SCHEMA,
        "totalByteCount": sum(item["byteCount"] for item in ordered),
    }


def _reproducible_bundle_from_archive(
    entries: Sequence[ArchiveEntry],
    application_root: str,
    executable_path: str,
) -> dict[str, Any]:
    prefix = application_root + "/"
    executable_relative = executable_path.removeprefix(prefix)
    descriptors = []
    for entry in entries:
        if not entry.path.startswith(prefix):
            continue
        relative = entry.path.removeprefix(prefix)
        if _is_signature_managed_bundle_path(relative, executable_relative):
            continue
        descriptors.append(
            {
                "byteCount": entry.byte_count,
                "kind": entry.kind,
                "path": relative,
                "sha256": entry.sha256,
                "unixMode": entry.unix_mode & 0o777,
            }
        )
    return _reproducible_bundle_summary(descriptors)


def _reproducible_bundle_from_directory(
    application: Path,
    executable: Path,
) -> dict[str, Any]:
    executable_relative = executable.relative_to(application).as_posix()
    descriptors = []
    for path in sorted(
        application.rglob("*"),
        key=lambda item: item.relative_to(application).as_posix(),
    ):
        require(not path.is_symlink(), f"symbolic links are forbidden: {path}")
        relative = path.relative_to(application).as_posix()
        if _is_signature_managed_bundle_path(relative, executable_relative):
            continue
        require(
            path.is_file() or path.is_dir(),
            f"special filesystem entries are forbidden: {path}",
        )
        mode = stat.S_IMODE(path.stat().st_mode) & 0o777
        require(
            mode & 0o022 == 0,
            f"clean-build bundle entry is group/world writable: {relative}",
        )
        is_file = path.is_file()
        descriptors.append(
            {
                "byteCount": path.stat().st_size if is_file else 0,
                "kind": "file" if is_file else "directory",
                "path": relative,
                "sha256": sha256_file(path) if is_file else sha256_bytes(b""),
                "unixMode": mode,
            }
        )
    return _reproducible_bundle_summary(descriptors)


def _default_metal_library_from_directory(application: Path) -> dict[str, Any]:
    library = application.joinpath(
        *PurePosixPath(DEFAULT_METAL_LIBRARY_RELATIVE_PATH).parts
    )
    require(
        library.is_file() and not library.is_symlink(),
        "application omits its deterministic default Metal library",
    )
    mode = stat.S_IMODE(library.stat().st_mode) & 0o777
    require(
        library.stat().st_size > 0 and mode & 0o022 == 0,
        "application default Metal library is empty or group/world writable",
    )
    return {
        "byteCount": library.stat().st_size,
        "path": DEFAULT_METAL_LIBRARY_RELATIVE_PATH,
        "sha256": sha256_file(library),
        "unixMode": mode,
    }


def _default_metal_library_from_archive(
    entries: Sequence[ArchiveEntry],
    application_root: str,
) -> dict[str, Any]:
    archive_path = f"{application_root}/{DEFAULT_METAL_LIBRARY_RELATIVE_PATH}"
    entry = _entry_by_path(entries, archive_path)
    require(
        entry.byte_count > 0 and entry.unix_mode & 0o022 == 0,
        "archived default Metal library is empty or group/world writable",
    )
    return {
        "byteCount": entry.byte_count,
        "path": DEFAULT_METAL_LIBRARY_RELATIVE_PATH,
        "sha256": entry.sha256,
        "unixMode": entry.unix_mode & 0o777,
    }


def _entry_by_path(entries: Sequence[ArchiveEntry], path: str) -> ArchiveEntry:
    matches = [entry for entry in entries if entry.path == path]
    require(len(matches) == 1 and matches[0].kind == "file", f"archive omits file: {path}")
    return matches[0]


def _read_control_file(
    value: zipfile.ZipFile,
    entries: Sequence[ArchiveEntry],
    path: str,
) -> bytes:
    entry = _entry_by_path(entries, path)
    require(entry.byte_count <= MAX_CONTROL_FILE_BYTES, f"control file is too large: {path}")
    raw = value.read(entry.info)
    require(len(raw) == entry.byte_count and sha256_bytes(raw) == entry.sha256, f"control file changed: {path}")
    return raw


def _application_root(entries: Sequence[ArchiveEntry]) -> str:
    roots = {
        PurePosixPath(entry.path).parts[0]
        for entry in entries
        if entry.path != ATTESTATION_PATH
    }
    require(len(roots) == 1, "application archive must contain one top-level payload root")
    root = next(iter(roots))
    require(root.endswith(".app"), "application archive payload root is not an app bundle")
    prefix = root + "/"
    require(
        all(entry.path == root or entry.path.startswith(prefix) for entry in entries if entry.path != ATTESTATION_PATH),
        "application archive contains data outside the app bundle",
    )
    return root


def _runtime_identity_from_archive(
    value: zipfile.ZipFile,
    entries: Sequence[ArchiveEntry],
    application_root: str,
) -> dict[str, str]:
    prefix = f"{application_root}/Contents/Resources/ASH-P06.bundle/"
    runtime_files = [
        entry for entry in entries if entry.kind == "file" and entry.path.startswith(prefix)
    ]
    require(runtime_files, "application archive omits the P06 runtime bundle")
    relative_entries = [
        (entry.path.removeprefix(prefix), entry.sha256) for entry in runtime_files
    ]
    manifest_path = prefix + "runtime-manifest.json"
    raw_manifest = _read_control_file(value, entries, manifest_path)
    manifest = load_json_bytes(raw_manifest, "archived runtime manifest")
    require(isinstance(manifest, dict), "archived runtime manifest is not an object")
    require(raw_manifest == canonical_bytes(manifest), "archived runtime manifest is not canonical JSON")
    provenance = manifest.get("provenance")
    require(isinstance(provenance, dict), "archived runtime provenance is missing")
    return {
        "runtimeManifestSHA256": sha256_bytes(MANIFEST_DOMAIN + canonical_bytes(manifest)),
        "runtimeManifestFileSHA256": sha256_bytes(raw_manifest),
        "runtimeArtifactSetSHA256": artifact_set_sha(relative_entries),
        "runtimeSourceRevision": require_hex(
            provenance.get("sourceRevision"), (40, 64), "archived runtime source revision"
        ),
    }


def _extract_payload(
    value: zipfile.ZipFile,
    entries: Sequence[ArchiveEntry],
    destination: Path,
) -> None:
    destination = destination.resolve()
    for entry in sorted(entries, key=lambda item: (item.path.count("/"), item.path)):
        if entry.path == ATTESTATION_PATH:
            continue
        target = destination.joinpath(*PurePosixPath(entry.path).parts)
        resolved_parent = target.parent.resolve()
        require(
            resolved_parent == destination or destination in resolved_parent.parents,
            f"archive extraction escapes destination: {entry.path}",
        )
        if entry.kind == "directory":
            target.mkdir(parents=True, exist_ok=True)
            target.chmod(entry.unix_mode & 0o777)
            continue
        target.parent.mkdir(parents=True, exist_ok=True)
        require(not target.exists(), f"archive extraction repeats output: {entry.path}")
        digest = hashlib.sha256()
        byte_count = 0
        with value.open(entry.info, "r") as source, target.open("xb") as output:
            for block in iter(lambda: source.read(1024 * 1024), b""):
                byte_count += len(block)
                digest.update(block)
                output.write(block)
        require(
            byte_count == entry.byte_count and digest.hexdigest() == entry.sha256,
            f"archive extraction mismatch: {entry.path}",
        )
        target.chmod(entry.unix_mode & 0o777)


def _run(command: Sequence[str], label: str) -> str:
    environment = os.environ.copy()
    environment.update({"LANG": "C", "LC_ALL": "C"})
    process = subprocess.run(
        list(command),
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        env=environment,
        check=False,
    )
    output = process.stdout.decode("utf-8", errors="replace").strip()
    require(process.returncode == 0, f"{label} failed: {output}")
    return output


def _entitlements_observation(
    executable: Path,
    architecture: str,
) -> tuple[str, dict[str, Any]]:
    environment = os.environ.copy()
    environment.update({"LANG": "C", "LC_ALL": "C"})
    process = subprocess.run(
        [
            "/usr/bin/codesign",
            "--display",
            "--arch",
            architecture,
            "--entitlements",
            ":-",
            str(executable),
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=environment,
        check=False,
    )
    require(
        process.returncode == 0,
        f"application entitlement inspection failed for {architecture}: "
        + process.stderr.decode("utf-8", errors="replace").strip(),
    )
    raw = process.stdout
    if raw:
        try:
            entitlements = plistlib.loads(raw)
        except plistlib.InvalidFileException as error:
            raise ArchiveProvenanceError(
                f"cannot decode application entitlements: {error}"
            ) from error
        require(
            isinstance(entitlements, dict),
            "application entitlements are not a dictionary",
        )
    else:
        entitlements = {}
    normalized = plistlib.dumps(
        entitlements,
        fmt=plistlib.FMT_BINARY,
        sort_keys=True,
    )
    require(
        not bool(entitlements.get("com.apple.security.get-task-allow", False)),
        f"application enables get-task-allow for {architecture}",
    )
    return sha256_bytes(ENTITLEMENTS_DOMAIN + normalized), entitlements


def _signing_identity(application: Path, executable: Path) -> dict[str, Any]:
    _run(
        ["/usr/bin/codesign", "--verify", "--deep", "--strict", "--verbose=4", str(application)],
        "application code-signature verification",
    )
    architectures = _run(["/usr/bin/lipo", "-archs", str(executable)], "Mach-O architecture inspection").split()
    require(
        architectures
        and len(architectures) == len(set(architectures))
        and all(re.fullmatch(r"[A-Za-z0-9_]+", item) for item in architectures),
        "application executable has an invalid architecture set",
    )
    require(
        sorted(architectures) == sorted(EXPECTED_APPLICATION_ARCHITECTURES),
        "application executable must contain exactly arm64 and x86_64; "
        f"observed={sorted(architectures)}",
    )
    code_directories: list[dict[str, str]] = []
    code_directory_policy_flags: list[dict[str, str]] = []
    designated_requirements: list[dict[str, str]] = []
    entitlements_by_architecture: list[dict[str, str]] = []
    entitlement_identities: set[str] = set()
    identifiers: set[str] = set()
    signature_modes: set[bool] = set()
    non_ad_hoc_requirements: set[str] = set()
    for architecture in sorted(architectures):
        display = _run(
            [
                "/usr/bin/codesign",
                "--display",
                "--verbose=4",
                "--arch",
                architecture,
                str(executable),
            ],
            f"CodeDirectory inspection for {architecture}",
        )
        matches = re.findall(r"^CandidateCDHashFull sha256=([0-9a-f]{64})$", display, re.MULTILINE)
        require(len(matches) == 1, f"CodeDirectory SHA-256 is absent or repeated for {architecture}")
        code_directories.append({"architecture": architecture, "sha256": matches[0]})
        cdhash_matches = re.findall(
            r"^CandidateCDHash sha256=([0-9a-f]{40})$",
            display,
            re.MULTILINE,
        )
        require(
            len(cdhash_matches) == 1,
            f"CodeDirectory cdhash is absent or repeated for {architecture}",
        )
        identifier_matches = re.findall(r"^Identifier=(.+)$", display, re.MULTILINE)
        require(
            len(identifier_matches) == 1 and identifier_matches[0].strip(),
            f"code-signing identifier is absent or repeated for {architecture}",
        )
        identifiers.add(identifier_matches[0].strip())
        flag_matches = re.findall(
            r"^CodeDirectory .+ flags=(0x[0-9a-f]+)(?:\([^)]*\))? .+$",
            display,
            re.MULTILINE,
        )
        require(
            len(flag_matches) == 1,
            f"CodeDirectory flags are absent or repeated for {architecture}",
        )
        raw_flags = int(flag_matches[0], 16)
        is_ad_hoc = bool(raw_flags & SIGNATURE_MODE_CODE_DIRECTORY_FLAGS)
        signature_modes.add(is_ad_hoc)
        policy_flags = raw_flags & ~SIGNATURE_MODE_CODE_DIRECTORY_FLAGS
        code_directory_policy_flags.append(
            {
                "architecture": architecture,
                "flags": f"0x{policy_flags:08x}",
            }
        )
        entitlement_identity, _ = _entitlements_observation(
            executable,
            architecture,
        )
        entitlement_identities.add(entitlement_identity)
        entitlements_by_architecture.append(
            {
                "architecture": architecture,
                "sha256": entitlement_identity,
            }
        )
        requirement_output = _run(
            [
                "/usr/bin/codesign",
                "--display",
                "--arch",
                architecture,
                "--requirements",
                "-",
                str(executable),
            ],
            f"designated-requirement inspection for {architecture}",
        )
        requirements = []
        for line in requirement_output.splitlines():
            match = re.fullmatch(
                r"(?:# )?(designated => .+)",
                line.strip(),
            )
            if match is not None:
                requirements.append(match.group(1))
        require(
            len(requirements) == 1,
            "application designated requirement is absent or repeated for "
            + architecture,
        )
        designated = requirements[0]
        expression = designated.split("=>", 1)[1].strip()
        require(
            expression,
            f"application designated requirement is empty for {architecture}",
        )
        if is_ad_hoc:
            require(
                expression == f'cdhash H"{cdhash_matches[0]}"',
                "ad-hoc application slice uses a custom designated requirement "
                f"for {architecture}",
            )
        else:
            non_ad_hoc_requirements.add(designated)
        _run(
            [
                "/usr/bin/codesign",
                "--verify",
                "--strict",
                "--arch",
                architecture,
                f"-R={expression}",
                str(executable),
            ],
            f"designated-requirement verification for {architecture}",
        )
        designated_requirements.append(
            {
                "architecture": architecture,
                "requirement": designated,
                "sha256": sha256_bytes(designated.encode("utf-8")),
            }
        )
    require(len(identifiers) == 1, "application architectures use different signing identifiers")
    require(
        len(signature_modes) == 1,
        "application architectures mix ad-hoc and identity-backed signatures",
    )
    require(
        next(iter(signature_modes)) or len(non_ad_hoc_requirements) == 1,
        "identity-backed application architectures use different designated requirements",
    )
    require(
        len(entitlement_identities) == 1,
        "application architectures use different entitlements",
    )
    code_identifier = next(iter(identifiers))
    designated = designated_requirements[0]["requirement"]
    with tempfile.TemporaryDirectory(prefix="mirmir-v4-unsigned-executable-") as temporary:
        unsigned_executable = Path(temporary) / executable.name
        shutil.copyfile(executable, unsigned_executable)
        unsigned_executable.chmod(0o755)
        _run(
            ["/usr/bin/codesign", "--remove-signature", str(unsigned_executable)],
            "executable signature normalization",
        )
        unsigned_identity = sha256_file(unsigned_executable)
        unsigned_slices = []
        for architecture in sorted(architectures):
            slice_path = Path(temporary) / f"{executable.name}-{architecture}"
            _run(
                [
                    "/usr/bin/lipo",
                    str(unsigned_executable),
                    "-thin",
                    architecture,
                    "-output",
                    str(slice_path),
                ],
                f"unsigned executable extraction for {architecture}",
            )
            require(
                _run(
                    ["/usr/bin/lipo", "-archs", str(slice_path)],
                    f"unsigned executable architecture inspection for {architecture}",
                ).split()
                == [architecture],
                f"unsigned executable extraction produced another architecture for {architecture}",
            )
            unsigned_slices.append(
                {
                    "architecture": architecture,
                    "byteCount": slice_path.stat().st_size,
                    "sha256": sha256_file(slice_path),
                }
            )
    executable_mode = stat.S_IMODE(executable.stat().st_mode) & 0o777
    require(
        executable_mode & 0o022 == 0,
        "application executable is group/world writable",
    )
    return {
        "codeDirectories": code_directories,
        "codeDirectorySetSHA256": sha256_bytes(
            CODE_DIRECTORY_SET_DOMAIN + canonical_bytes(code_directories)
        ),
        "codeDirectoryPolicyFlags": code_directory_policy_flags,
        "codeIdentifier": code_identifier,
        "designatedRequirement": designated,
        "designatedRequirementSHA256": sha256_bytes(designated.encode("utf-8")),
        "designatedRequirements": designated_requirements,
        "entitlementsByArchitecture": entitlements_by_architecture,
        "entitlementsSHA256": next(iter(entitlement_identities)),
        "executableUnixMode": executable_mode,
        "executableSHA256": sha256_file(executable),
        "unsignedExecutableSHA256": unsigned_identity,
        "unsignedExecutableSlices": unsigned_slices,
    }


def _runtime_identity_from_directory(application: Path) -> dict[str, str]:
    runtime = application / "Contents/Resources/ASH-P06.bundle"
    require(
        runtime.is_dir() and not runtime.is_symlink(),
        "clean build omits the P06 runtime bundle",
    )
    manifest_path = runtime / "runtime-manifest.json"
    require(
        manifest_path.is_file() and not manifest_path.is_symlink(),
        "clean build omits the P06 runtime manifest",
    )
    raw_manifest = manifest_path.read_bytes()
    manifest = load_json_bytes(raw_manifest, "clean-build runtime manifest")
    require(isinstance(manifest, dict), "clean-build runtime manifest is not an object")
    require(
        raw_manifest == canonical_bytes(manifest),
        "clean-build runtime manifest is not canonical JSON",
    )
    provenance = manifest.get("provenance")
    require(isinstance(provenance, dict), "clean-build runtime provenance is missing")
    return {
        "runtimeManifestSHA256": sha256_bytes(
            MANIFEST_DOMAIN + canonical_bytes(manifest)
        ),
        "runtimeManifestFileSHA256": sha256_bytes(raw_manifest),
        "runtimeArtifactSetSHA256": artifact_set_sha(bundle_entries(runtime)),
        "runtimeSourceRevision": require_hex(
            provenance.get("sourceRevision"),
            (40, 64),
            "clean-build runtime source revision",
        ),
    }


def application_directory_observation(
    application: Path,
    context: Mapping[str, str],
) -> dict[str, Any]:
    application = application.expanduser()
    require(
        application.is_dir()
        and not application.is_symlink()
        and application.name == CLEAN_BUILD_PRODUCT,
        "clean build product is not the expected Mirmir.app bundle",
    )
    application = application.resolve(strict=True)
    plist_path = application / "Contents/Info.plist"
    require(
        plist_path.is_file() and not plist_path.is_symlink(),
        "clean build omits its Info.plist",
    )
    raw_plist = plist_path.read_bytes()
    try:
        plist = plistlib.loads(raw_plist)
    except plistlib.InvalidFileException as error:
        raise ArchiveProvenanceError(
            f"cannot decode clean-build Info.plist: {error}"
        ) from error
    require(isinstance(plist, dict), "clean-build Info.plist is not a dictionary")
    claims = claims_from_plist(plist)
    require(
        claims == expected_claims(context),
        "clean build does not contain the exact committed-source claims",
    )
    executable_name = plist.get("CFBundleExecutable")
    require(
        isinstance(executable_name, str)
        and executable_name
        and "/" not in executable_name
        and "\\" not in executable_name,
        "clean-build Info.plist has an invalid CFBundleExecutable",
    )
    executable = application / "Contents/MacOS" / executable_name
    require(
        executable.is_file() and not executable.is_symlink(),
        "clean build omits its executable",
    )
    bundle_keys = {
        "bundleIdentifier": "CFBundleIdentifier",
        "productVersion": "CFBundleShortVersionString",
        "productBuild": "CFBundleVersion",
    }
    bundle_identity: dict[str, str] = {}
    for output_key, plist_key in bundle_keys.items():
        item = plist.get(plist_key)
        require(
            isinstance(item, str) and item.strip(),
            f"clean-build Info.plist omits {plist_key}",
        )
        bundle_identity[output_key] = item
    runtime = _runtime_identity_from_directory(application)
    expected_runtime = {
        key: context[key]
        for key in (
            "runtimeManifestSHA256",
            "runtimeManifestFileSHA256",
            "runtimeArtifactSetSHA256",
            "runtimeSourceRevision",
        )
    }
    require(runtime == expected_runtime, "clean build embeds another P06 runtime")
    signing = _signing_identity(application, executable)
    require(
        signing["codeIdentifier"] == bundle_identity["bundleIdentifier"],
        "clean-build signing identifier differs from its bundle identifier",
    )
    return {
        **bundle_identity,
        "bundleRoot": CLEAN_BUILD_PRODUCT,
        "codeDirectories": signing["codeDirectories"],
        "codeDirectorySetSHA256": signing["codeDirectorySetSHA256"],
        "codeDirectoryPolicyFlags": signing["codeDirectoryPolicyFlags"],
        "codeIdentifier": signing["codeIdentifier"],
        "designatedRequirement": signing["designatedRequirement"],
        "designatedRequirementSHA256": signing["designatedRequirementSHA256"],
        "designatedRequirements": signing["designatedRequirements"],
        "defaultMetalLibrary": _default_metal_library_from_directory(application),
        "embeddedClaimSetSHA256": sha256_bytes(
            CLAIM_SET_DOMAIN + canonical_bytes(claims)
        ),
        "entitlementsByArchitecture": signing["entitlementsByArchitecture"],
        "entitlementsSHA256": signing["entitlementsSHA256"],
        "executablePath": f"{CLEAN_BUILD_PRODUCT}/Contents/MacOS/{executable_name}",
        "executableSHA256": signing["executableSHA256"],
        "executableUnixMode": signing["executableUnixMode"],
        "unsignedExecutableSHA256": signing["unsignedExecutableSHA256"],
        "unsignedExecutableSlices": signing["unsignedExecutableSlices"],
        "infoPlistPath": f"{CLEAN_BUILD_PRODUCT}/Contents/Info.plist",
        "infoPlistSHA256": sha256_bytes(raw_plist),
        "reproducibleBundleContent": _reproducible_bundle_from_directory(
            application,
            executable,
        ),
        "runtime": runtime,
    }


def _checked_output(
    command: Sequence[str],
    label: str,
    *,
    environment: Mapping[str, str] | None = None,
) -> str:
    process = subprocess.run(
        list(command),
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        env=dict(environment) if environment is not None else None,
        check=False,
    )
    output = process.stdout.decode("utf-8", errors="replace").strip()
    require(process.returncode == 0, f"{label} failed: {output}")
    return output


def canonical_clean_build_layout() -> dict[str, str]:
    root = CANONICAL_CLEAN_BUILD_ROOT
    return {
        "buildRoot": str(root),
        "derivedData": str(root / "DerivedData"),
        "homeDirectory": str(root / "home"),
        "metalIntermediates": str(root / "Metal"),
        "provenanceXCConfig": str(root / "release-provenance.xcconfig"),
        "sourceRoot": str(root / "source"),
        "swiftDriverJobAudit": str(root / "swift-driver-effective-argv.log"),
        "swiftDriverWrapper": str(root / "swiftc"),
        "temporaryDirectory": str(root / "tmp"),
    }


def _canonical_root_identity(metadata: os.stat_result) -> tuple[int, ...]:
    return _stable_node_identity(metadata)


def _require_canonical_build_root(
    root: Path,
    expected_identity: tuple[int, ...],
) -> None:
    metadata = os.lstat(root)
    require(
        _canonical_root_identity(metadata) == expected_identity
        and stat.S_ISDIR(metadata.st_mode)
        and metadata.st_uid == os.geteuid()
        and stat.S_IMODE(metadata.st_mode) == 0o700
        and root.resolve(strict=True) == root,
        "canonical clean-build root changed ownership, mode, identity, or path",
    )


@contextmanager
def canonical_clean_build_workspace() -> Iterable[Path]:
    """Create the one physical compiler root used by candidate and replay.

    A pre-existing root is never reused or emptied.  This makes crash residue
    and namespace substitution explicit operator-visible failures instead of
    silently compiling through attacker-controlled or stale paths.
    """

    root = CANONICAL_CLEAN_BUILD_ROOT
    parent = root.parent
    require(
        parent.resolve(strict=True) == Path("/private/tmp"),
        "canonical clean-build parent does not resolve to /private/tmp",
    )
    try:
        os.mkdir(root, 0o700)
    except FileExistsError as error:
        raise ArchiveProvenanceError(
            f"canonical clean-build root already exists: {root}"
        ) from error
    except OSError as error:
        raise ArchiveProvenanceError(
            f"cannot create canonical clean-build root {root}: {error}"
        ) from error
    identity = _canonical_root_identity(os.lstat(root))
    _require_canonical_build_root(root, identity)
    try:
        yield root
    finally:
        _require_canonical_build_root(root, identity)
        shutil.rmtree(root)


def clean_build_environment(build_root: Path) -> dict[str, str]:
    require(
        build_root == CANONICAL_CLEAN_BUILD_ROOT,
        "clean build must use the canonical physical build root",
    )
    developer_directory = _checked_output(
        ["/usr/bin/xcode-select", "-p"],
        "Xcode developer-directory inspection",
        environment={
            "LANG": "C",
            "LC_ALL": "C",
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        },
    )
    developer = Path(developer_directory).resolve(strict=True)
    require(
        (developer / "usr/bin/xcodebuild").is_file(),
        "selected Xcode omits xcodebuild",
    )
    home = build_root / "home"
    temporary = build_root / "tmp"
    home.mkdir(mode=0o700)
    temporary.mkdir(mode=0o700)
    return {
        "CFFIXED_USER_HOME": str(home),
        "DEVELOPER_DIR": str(developer),
        "HOME": str(home),
        "LANG": "C",
        "LC_ALL": "C",
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "SWIFT_DETERMINISTIC_HASHING": "1",
        "SWIFTC_MAXIMUM_DETERMINISM": "1",
        "TMPDIR": str(temporary),
    }


def _normalize_metal_tool_output(value: str, component_root: Path) -> str:
    aliases = {str(component_root)}
    if str(component_root).startswith("/private/"):
        aliases.add(str(component_root).removeprefix("/private"))
    normalized = value
    for alias in sorted(aliases, key=len, reverse=True):
        normalized = normalized.replace(alias, "$METAL_TOOLCHAIN")
    return normalized.strip()


def _metal_tool_descriptor(
    name: str,
    placeholder: str,
    component_root: Path,
    environment: Mapping[str, str],
) -> tuple[Path, dict[str, Any]]:
    lookup_command = ["/usr/bin/xcrun", "--find", name]
    raw = _checked_output(
        lookup_command,
        f"{name} component lookup",
        environment=environment,
    )
    require("\n" not in raw and "\r" not in raw, f"{name} lookup returned multiple paths")
    raw_path = Path(raw)
    require(raw_path.is_absolute(), f"{name} lookup returned a relative path")
    try:
        metadata = os.lstat(raw_path)
    except OSError as error:
        raise ArchiveProvenanceError(f"cannot inspect {name} component tool: {error}") from error
    require(
        stat.S_ISREG(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode),
        f"{name} component tool is not a file or internal link",
    )
    logical = raw_path.parent.resolve(strict=True) / raw_path.name
    resolved = raw_path.resolve(strict=True)
    require(
        resolved.is_file() and os.access(resolved, os.X_OK),
        f"{name} component tool is not executable",
    )
    try:
        logical_relative = logical.relative_to(component_root).as_posix()
        resolved_relative = resolved.relative_to(component_root).as_posix()
    except ValueError as error:
        raise ArchiveProvenanceError(
            f"{name} lookup escaped the installed Metal component"
        ) from error
    require(
        logical_relative == f"usr/bin/{name}",
        f"{name} lookup returned an unsupported component-relative path",
    )
    expected_underlying_name = METAL_UNDERLYING_EXECUTABLES[name]
    require(
        resolved_relative == f"usr/bin/{expected_underlying_name}",
        f"{name} component dispatcher resolves to another executable",
    )
    current_toolchain = component_root / "usr/metal/current"
    try:
        current_metadata = os.lstat(current_toolchain)
        versioned_toolchain = current_toolchain.resolve(strict=True)
        versioned_relative = versioned_toolchain.relative_to(
            component_root
        ).as_posix()
    except (OSError, ValueError) as error:
        raise ArchiveProvenanceError(
            f"cannot resolve {name} underlying component toolchain"
        ) from error
    require(
        stat.S_ISLNK(current_metadata.st_mode)
        and re.fullmatch(r"usr/metal/[0-9]+", versioned_relative) is not None,
        f"{name} underlying component toolchain has an unsupported layout",
    )
    underlying = (
        versioned_toolchain / "bin" / expected_underlying_name
    ).resolve(
        strict=True
    )
    require(
        underlying.is_file()
        and os.access(underlying, os.X_OK)
        and underlying != resolved,
        f"{name} underlying component executable is absent",
    )
    try:
        underlying_relative = underlying.relative_to(component_root).as_posix()
    except ValueError as error:
        raise ArchiveProvenanceError(
            f"{name} underlying component executable escaped its toolchain"
        ) from error
    require(
        underlying_relative.startswith(versioned_relative + "/bin/")
        and underlying_relative.endswith("/" + expected_underlying_name),
        f"{name} underlying component executable has an unsupported path",
    )
    version = _checked_output(
        [str(raw_path), "--version"],
        f"{name} version inspection",
        environment=environment,
    )
    normalized_version = _normalize_metal_tool_output(version, component_root)
    require(normalized_version, f"{name} version output is empty")
    underlying_version = _checked_output(
        [str(underlying), "--version"],
        f"{name} underlying version inspection",
        environment=environment,
    )
    normalized_underlying_version = _normalize_metal_tool_output(
        underlying_version,
        component_root,
    )
    require(
        normalized_underlying_version,
        f"{name} underlying version output is empty",
    )
    # The legacy-compatible linker selects its metallib mode from argv[0].
    # Keep that inspected component entry point for linking while executing the
    # versioned frontend and symbol reader directly.
    execution = logical if name == "metallib" else underlying
    return execution, {
        "componentRelativePath": logical_relative,
        "lookupCommand": lookup_command,
        "resolvedComponentRelativePath": resolved_relative,
        "sha256": sha256_file(resolved),
        "underlyingComponentRelativePath": underlying_relative,
        "underlyingSHA256": sha256_file(underlying),
        "underlyingVersion": normalized_underlying_version.splitlines(),
        "underlyingVersionCommand": ["$UNDERLYING_" + name.upper().replace("-", "_"), "--version"],
        "version": normalized_version.splitlines(),
        "versionCommand": [placeholder, "--version"],
    }


def _metal_resource_tree_descriptor(
    resource_root: Path,
    component_root: Path,
) -> dict[str, Any]:
    require(
        resource_root.is_dir()
        and not resource_root.is_symlink(),
        "Metal compiler resource directory is absent or linked",
    )
    try:
        relative_root = resource_root.relative_to(component_root).as_posix()
    except ValueError as error:
        raise ArchiveProvenanceError(
            "Metal compiler resource directory escaped its component"
        ) from error
    require(
        re.fullmatch(
            r"usr/metal/[0-9]+/lib/clang/[A-Za-z0-9._-]+",
            relative_root,
        )
        is not None,
        "Metal compiler resource directory has an unsupported layout",
    )
    entries: list[dict[str, Any]] = []
    for node in sorted(resource_root.rglob("*")):
        try:
            metadata = os.lstat(node)
        except OSError as error:
            raise ArchiveProvenanceError(
                f"cannot inspect Metal compiler resource: {node}"
            ) from error
        require(
            not stat.S_ISLNK(metadata.st_mode)
            and (stat.S_ISDIR(metadata.st_mode) or stat.S_ISREG(metadata.st_mode)),
            f"Metal compiler resource tree contains a special entry: {node}",
        )
        if stat.S_ISDIR(metadata.st_mode):
            continue
        relative = node.relative_to(resource_root).as_posix()
        mode = stat.S_IMODE(metadata.st_mode) & 0o777
        require(
            metadata.st_size > 0
            and mode in {0o644, 0o755},
            f"Metal compiler resource has an unsupported size or mode: {relative}",
        )
        entries.append(
            {
                "byteCount": metadata.st_size,
                "path": relative,
                "sha256": sha256_file(node),
                "unixMode": mode,
            }
        )
    require(
        entries
        and set(REQUIRED_METAL_RESOURCE_PATHS).issubset(
            {entry["path"] for entry in entries}
        ),
        "Metal compiler resource tree omits a required header or runtime",
    )
    return {
        "componentRelativePath": relative_root,
        "entries": entries,
        "entryCount": len(entries),
        "identitySHA256": sha256_bytes(
            METAL_RESOURCE_SET_DOMAIN + canonical_bytes(entries)
        ),
        "queryCommand": ["$UNDERLYING_METAL", "-print-resource-dir"],
        "schemaVersion": METAL_RESOURCE_MANIFEST_SCHEMA,
        "totalByteCount": sum(entry["byteCount"] for entry in entries),
    }


def resolve_metal_toolchain(
    environment: Mapping[str, str],
) -> MetalToolchainResolution:
    developer = Path(environment["DEVELOPER_DIR"])
    xcodebuild = (developer / "usr/bin/xcodebuild").resolve(strict=True)
    query_command = [
        str(xcodebuild),
        "-showComponent",
        METAL_COMPONENT_NAME,
        "-json",
    ]
    raw_component = _checked_output(
        query_command,
        "Metal component inspection",
        environment=environment,
    )
    component = load_json_bytes(
        raw_component.encode("utf-8"),
        "Metal component inspection",
    )
    require(
        isinstance(component, dict)
        and set(component)
        == {
            "assetPath",
            "buildVersion",
            "status",
            "toolchainIdentifier",
            "toolchainSearchPath",
        },
        "installed Metal component has an unsupported description",
    )
    build_version = component.get("buildVersion")
    identifier = component.get("toolchainIdentifier")
    require(
        component.get("status") == "installed"
        and isinstance(build_version, str)
        and re.fullmatch(r"[A-Za-z0-9._-]+", build_version) is not None
        and isinstance(identifier, str)
        and re.fullmatch(r"[A-Za-z0-9._-]+", identifier) is not None,
        "Metal component is absent or has an invalid build identity",
    )
    asset_value = component.get("assetPath")
    search_value = component.get("toolchainSearchPath")
    require(
        isinstance(asset_value, str)
        and Path(asset_value).is_absolute()
        and isinstance(search_value, str)
        and Path(search_value).is_absolute(),
        "Metal component paths are invalid",
    )
    asset_path = Path(asset_value).resolve(strict=True)
    search_path = Path(search_value).resolve(strict=True)
    require(
        asset_path.is_dir()
        and asset_path.name == "AssetData"
        and re.fullmatch(r"[0-9a-f]{40}\.asset", asset_path.parent.name) is not None,
        "Metal component asset identity is invalid",
    )
    require(search_path.is_dir(), "Metal component search path is absent")
    component_root = (search_path / "Metal.xctoolchain").resolve(strict=True)
    require(component_root.is_dir(), "Metal component toolchain is absent")
    metal, metal_descriptor = _metal_tool_descriptor(
        "metal",
        "$METAL",
        component_root,
        environment,
    )
    metallib, metallib_descriptor = _metal_tool_descriptor(
        "metallib",
        "$METALLIB",
        component_root,
        environment,
    )
    metal_nm, metal_nm_descriptor = _metal_tool_descriptor(
        "metal-nm",
        "$METAL_NM",
        component_root,
        environment,
    )
    resource_output = _checked_output(
        [str(metal), "-print-resource-dir"],
        "Metal compiler resource-directory inspection",
        environment=environment,
    )
    require(
        "\n" not in resource_output and "\r" not in resource_output,
        "Metal compiler returned multiple resource directories",
    )
    resource_root = Path(resource_output).resolve(strict=True)
    resources = _metal_resource_tree_descriptor(
        resource_root,
        component_root,
    )
    stable_component = {
        "assetIdentifier": asset_path.parent.name,
        "buildVersion": build_version,
        "name": METAL_COMPONENT_NAME,
        "queryCommand": [
            "$XCODEBUILD",
            "-showComponent",
            METAL_COMPONENT_NAME,
            "-json",
        ],
        "status": "installed",
        "toolchainIdentifier": identifier,
        "toolchainRelativePath": "Metal.xctoolchain",
    }
    tool_records = {
        "component": stable_component,
        "metal": metal_descriptor,
        "metallib": metallib_descriptor,
        "metalNM": metal_nm_descriptor,
        "resources": resources,
    }
    receipt = {
        **tool_records,
        "identitySHA256": sha256_bytes(
            METAL_TOOL_SET_DOMAIN + canonical_bytes(tool_records)
        ),
    }
    return MetalToolchainResolution(
        component_root=component_root,
        metal=metal,
        metallib=metallib,
        metal_nm=metal_nm,
        resource_root=resource_root,
        receipt=receipt,
    )


def revalidate_metal_toolchain(
    expected: MetalToolchainResolution,
    environment: Mapping[str, str],
    stage: str,
) -> MetalToolchainResolution:
    """Fail closed if a resolved Metal component changes during execution."""

    current = resolve_metal_toolchain(environment)
    require(
        current == expected,
        f"installed Metal component changed during {stage}",
    )
    return current


def _swiftc_descriptor(environment: Mapping[str, str]) -> dict[str, Any]:
    swiftc = Path(
        _checked_output(
            ["/usr/bin/xcrun", "--find", "swiftc"],
            "Swift compiler inspection",
            environment=environment,
        )
    ).resolve(strict=True)
    require(
        swiftc.is_file() and os.access(swiftc, os.X_OK),
        "Swift compiler is absent or not executable",
    )
    return {
        "path": str(swiftc),
        "sha256": sha256_file(swiftc),
        "version": _checked_output(
            [str(swiftc), "--version"],
            "Swift compiler version inspection",
            environment=environment,
        ).splitlines(),
    }


def _zsh_descriptor(environment: Mapping[str, str]) -> dict[str, Any]:
    interpreter = Path("/bin/zsh").resolve(strict=True)
    require(
        interpreter == Path("/bin/zsh")
        and interpreter.is_file()
        and os.access(interpreter, os.X_OK),
        "Swift driver wrapper interpreter is absent or linked",
    )
    return {
        "path": str(interpreter),
        "sha256": sha256_file(interpreter),
        "version": _checked_output(
            [str(interpreter), "--version"],
            "Swift driver wrapper interpreter inspection",
            environment=environment,
        ).splitlines(),
    }


def _zsh_single_quoted(value: str) -> str:
    require(
        value and "\0" not in value and "\n" not in value and "\r" not in value,
        "Swift driver wrapper path contains an unsupported character",
    )
    return "'" + value.replace("'", "'\\''") + "'"


def swift_driver_wrapper_bytes(swiftc: Path, audit_path: Path) -> bytes:
    require(
        swiftc.is_absolute() and audit_path.is_absolute(),
        "Swift driver wrapper paths must be absolute",
    )
    swiftc_literal = _zsh_single_quoted(str(swiftc))
    audit_literal = _zsh_single_quoted(str(audit_path))
    marker_prefix_literal = _zsh_single_quoted(
        SWIFT_DRIVER_JOB_AUDIT_PREFIX
    )
    target_pattern = "|".join(
        _zsh_single_quoted(target)
        for target in SWIFT_DRIVER_REQUIRED_TARGETS
    )
    return (
        "#!/bin/zsh\n"
        "set -eu\n"
        "umask 077\n"
        "typeset -a effective_arguments\n"
        "typeset -i consume_job_value=0\n"
        "typeset -i saw_job_option=0\n"
        "for argument in \"$@\"; do\n"
        "  if (( consume_job_value )); then\n"
        "    if [[ \"$argument\" != <-> ]]; then\n"
        "      print -ru2 -- 'invalid separated Swift driver -j value'\n"
        "      exit 64\n"
        "    fi\n"
        "    consume_job_value=0\n"
        "    continue\n"
        "  fi\n"
        "  if [[ \"$argument\" == '-j' ]]; then\n"
        "    consume_job_value=1\n"
        "    saw_job_option=1\n"
        "  elif [[ \"$argument\" == -j* ]]; then\n"
        "    job_value=\"${argument#-j}\"\n"
        "    if [[ \"$job_value\" != <-> ]]; then\n"
        "      print -ru2 -- 'invalid joined Swift driver -j value'\n"
        "      exit 64\n"
        "    fi\n"
        "    saw_job_option=1\n"
        "  else\n"
        "    effective_arguments+=(\"$argument\")\n"
        "  fi\n"
        "done\n"
        "if (( consume_job_value )); then\n"
        "  print -ru2 -- 'missing separated Swift driver -j value'\n"
        "  exit 64\n"
        "fi\n"
        "if (( saw_job_option )); then\n"
        "  effective_arguments+=('-j' '1')\n"
        "  typeset -i argument_index=1\n"
        "  typeset -i argument_count=${#effective_arguments[@]}\n"
        "  typeset -i num_threads_count=0\n"
        "  typeset -i llvm_rng_seed_count=0\n"
        "  typeset -i target_count=0\n"
        "  typeset driver_target=''\n"
        "  while (( argument_index <= argument_count )); do\n"
        "    argument=\"${effective_arguments[argument_index]}\"\n"
        "    if [[ \"$argument\" == '-num-threads' ]]; then\n"
        "      if (( argument_index >= argument_count )); then\n"
        "        print -ru2 -- 'missing Swift frontend thread-count value'\n"
        "        exit 64\n"
        "      fi\n"
        "      num_threads_count=$((num_threads_count + 1))\n"
        "      value=\"${effective_arguments[argument_index + 1]}\"\n"
        "      if [[ \"$value\" != '1' ]]; then\n"
        "        print -ru2 -- 'Swift frontend thread count differs from 1'\n"
        "        exit 64\n"
        "      fi\n"
        "      argument_index=$((argument_index + 2))\n"
        "      continue\n"
        "    elif [[ \"$argument\" == -num-threads* ]]; then\n"
        "      print -ru2 -- 'unsupported joined Swift frontend thread count'\n"
        "      exit 64\n"
        "    elif [[ \"$argument\" == '-Xllvm' ]]; then\n"
        "      if (( argument_index >= argument_count )); then\n"
        "        print -ru2 -- 'missing Swift LLVM option value'\n"
        "        exit 64\n"
        "      fi\n"
        "      value=\"${effective_arguments[argument_index + 1]}\"\n"
        "      if [[ \"$value\" == -rng-seed* ]]; then\n"
        "        llvm_rng_seed_count=$((llvm_rng_seed_count + 1))\n"
        "        if [[ \"$value\" != '-rng-seed=1' ]]; then\n"
        "          print -ru2 -- 'Swift LLVM RNG seed differs from 1'\n"
        "          exit 64\n"
        "        fi\n"
        "      fi\n"
        "      argument_index=$((argument_index + 2))\n"
        "      continue\n"
        "    elif [[ \"$argument\" == '-target' ]]; then\n"
        "      if (( argument_index >= argument_count )); then\n"
        "        print -ru2 -- 'missing Swift target value'\n"
        "        exit 64\n"
        "      fi\n"
        "      target_count=$((target_count + 1))\n"
        "      driver_target=\"${effective_arguments[argument_index + 1]}\"\n"
        "      argument_index=$((argument_index + 2))\n"
        "      continue\n"
        "    elif [[ \"$argument\" == -target=* ]]; then\n"
        "      print -ru2 -- 'unsupported joined Swift target'\n"
        "      exit 64\n"
        "    fi\n"
        "    argument_index=$((argument_index + 1))\n"
        "  done\n"
        "  if (( num_threads_count != 1 )); then\n"
        "    print -ru2 -- 'Swift frontend thread-count control is missing or duplicated'\n"
        "    exit 64\n"
        "  fi\n"
        "  if (( llvm_rng_seed_count != 1 )); then\n"
        "    print -ru2 -- 'Swift LLVM RNG-seed control is missing or duplicated'\n"
        "    exit 64\n"
        "  fi\n"
        "  if (( target_count != 1 )); then\n"
        "    print -ru2 -- 'Swift target control is missing or duplicated'\n"
        "    exit 64\n"
        "  fi\n"
        "  case \"$driver_target\" in\n"
        f"    {target_pattern}) ;;\n"
        "    *) print -ru2 -- 'Swift target is outside release policy'; exit 64 ;;\n"
        "  esac\n"
        "  typeset driver_projection=''\n"
        f"  if driver_projection=\"$(ARGV0=swiftc {swiftc_literal} \"${{effective_arguments[@]}}\" '-driver-print-jobs')\"; then\n"
        "    :\n"
        "  else\n"
        "    print -ru2 -- 'Swift driver job projection failed'\n"
        "    exit 64\n"
        "  fi\n"
        "  typeset -a projected_lines\n"
        "  projected_lines=(\"${(@f)driver_projection}\")\n"
        "  if (( ${#projected_lines[@]} != 1 )); then\n"
        "    print -ru2 -- 'Swift driver projected an unsupported frontend job count'\n"
        "    exit 64\n"
        "  fi\n"
        "  typeset -a projected_arguments\n"
        "  projected_arguments=(\"${(z)projected_lines[1]}\")\n"
        "  if (( ${#projected_arguments[@]} < 2 )) \\\n"
        f"    || [[ \"${{(Q)projected_arguments[1]}}\" != {swiftc_literal} ]] \\\n"
        "    || [[ \"${(Q)projected_arguments[2]}\" != '-frontend' ]]; then\n"
        "    print -ru2 -- 'Swift driver projected another frontend executable'\n"
        "    exit 64\n"
        "  fi\n"
        "  typeset -i projected_index=1\n"
        "  typeset -i projected_count=${#projected_arguments[@]}\n"
        "  typeset -i projected_num_threads_count=0\n"
        "  typeset -i projected_llvm_rng_seed_count=0\n"
        "  typeset -i projected_target_count=0\n"
        "  typeset projected_target=''\n"
        "  while (( projected_index <= projected_count )); do\n"
        "    projected_argument=\"${(Q)projected_arguments[projected_index]}\"\n"
        "    if [[ \"$projected_argument\" == '-num-threads' ]]; then\n"
        "      if (( projected_index >= projected_count )); then\n"
        "        print -ru2 -- 'projected Swift frontend thread count lacks a value'\n"
        "        exit 64\n"
        "      fi\n"
        "      projected_num_threads_count=$((projected_num_threads_count + 1))\n"
        "      value=\"${(Q)projected_arguments[projected_index + 1]}\"\n"
        "      if [[ \"$value\" != '1' ]]; then\n"
        "        print -ru2 -- 'projected Swift frontend thread count differs from 1'\n"
        "        exit 64\n"
        "      fi\n"
        "      projected_index=$((projected_index + 2))\n"
        "      continue\n"
        "    elif [[ \"$projected_argument\" == -num-threads* ]]; then\n"
        "      print -ru2 -- 'projected Swift frontend uses a joined thread count'\n"
        "      exit 64\n"
        "    elif [[ \"$projected_argument\" == '-Xllvm' ]]; then\n"
        "      if (( projected_index >= projected_count )); then\n"
        "        print -ru2 -- 'projected Swift LLVM option lacks a value'\n"
        "        exit 64\n"
        "      fi\n"
        "      value=\"${(Q)projected_arguments[projected_index + 1]}\"\n"
        "      if [[ \"$value\" == -rng-seed* ]]; then\n"
        "        projected_llvm_rng_seed_count=$((projected_llvm_rng_seed_count + 1))\n"
        "        if [[ \"$value\" != '-rng-seed=1' ]]; then\n"
        "          print -ru2 -- 'projected Swift LLVM RNG seed differs from 1'\n"
        "          exit 64\n"
        "        fi\n"
        "      fi\n"
        "      projected_index=$((projected_index + 2))\n"
        "      continue\n"
        "    elif [[ \"$projected_argument\" == '-target' ]]; then\n"
        "      if (( projected_index >= projected_count )); then\n"
        "        print -ru2 -- 'projected Swift target lacks a value'\n"
        "        exit 64\n"
        "      fi\n"
        "      projected_target_count=$((projected_target_count + 1))\n"
        "      projected_target=\"${(Q)projected_arguments[projected_index + 1]}\"\n"
        "      projected_index=$((projected_index + 2))\n"
        "      continue\n"
        "    elif [[ \"$projected_argument\" == -target=* ]]; then\n"
        "      print -ru2 -- 'projected Swift frontend uses a joined target'\n"
        "      exit 64\n"
        "    elif [[ \"$projected_argument\" == '-j' || \"$projected_argument\" == -j* ]]; then\n"
        "      print -ru2 -- 'projected Swift frontend retains a driver job option'\n"
        "      exit 64\n"
        "    fi\n"
        "    projected_index=$((projected_index + 1))\n"
        "  done\n"
        "  if (( projected_num_threads_count != 1 )); then\n"
        "    print -ru2 -- 'projected Swift frontend thread-count control is missing or duplicated'\n"
        "    exit 64\n"
        "  fi\n"
        "  if (( projected_llvm_rng_seed_count != 1 )); then\n"
        "    print -ru2 -- 'projected Swift LLVM RNG-seed control is missing or duplicated'\n"
        "    exit 64\n"
        "  fi\n"
        "  if (( projected_target_count != 1 )) || [[ \"$projected_target\" != \"$driver_target\" ]]; then\n"
        "    print -ru2 -- 'projected Swift target differs from the driver target'\n"
        "    exit 64\n"
        "  fi\n"
        f"  print -r -- {marker_prefix_literal}\" target=${{driver_target}} jobOptionCount=1 terminal=-j,1 numThreadsCount=1 numThreads=1 llvmRNGSeedCount=1 llvmRNGSeed=1 projectedFrontendJobCount=1 projectedNumThreadsCount=1 projectedNumThreads=1 projectedLLVMRNGSeedCount=1 projectedLLVMRNGSeed=1\" >> {audit_literal}\n"
        "fi\n"
        f"exec -a swiftc {swiftc_literal} \"${{effective_arguments[@]}}\"\n"
    ).encode("utf-8")


def _create_locked_file(path: Path, raw: bytes, mode: int) -> tuple[int, ...]:
    require(
        path.is_absolute() and path.parent.is_dir(),
        "locked build helper has an invalid destination",
    )
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(path, flags, mode)
    except OSError as error:
        raise ArchiveProvenanceError(
            f"cannot create locked build helper {path}: {error}"
        ) from error
    try:
        os.fchmod(descriptor, mode)
        with os.fdopen(descriptor, "wb", closefd=False) as output:
            output.write(raw)
            output.flush()
        metadata = os.fstat(descriptor)
    finally:
        os.close(descriptor)
    require(
        stat.S_ISREG(metadata.st_mode)
        and stat.S_IMODE(metadata.st_mode) == mode
        and metadata.st_size == len(raw),
        "locked build helper has an unsupported mode, kind, or size",
    )
    return _stable_node_identity(metadata)


def install_swift_driver_wrapper(
    build_root: Path,
    toolchain: Mapping[str, Any],
    environment: Mapping[str, str],
) -> SwiftDriverWrapperInstallation:
    require(
        build_root == CANONICAL_CLEAN_BUILD_ROOT,
        "Swift driver wrapper must use the canonical build root",
    )
    swiftc = toolchain.get("swiftc")
    require(
        isinstance(swiftc, dict)
        and set(swiftc) == {"path", "sha256", "version"},
        "Swift driver wrapper omits the inspected Swift compiler",
    )
    path = Path(canonical_clean_build_layout()["swiftDriverWrapper"])
    audit_path = Path(canonical_clean_build_layout()["swiftDriverJobAudit"])
    require(
        path.parent == build_root
        and audit_path.parent == build_root
        and not path.exists()
        and not path.is_symlink()
        and not audit_path.exists()
        and not audit_path.is_symlink(),
        "Swift driver wrapper or audit destination already exists",
    )
    raw = swift_driver_wrapper_bytes(Path(swiftc["path"]), audit_path)
    audit_identity = _create_locked_file(audit_path, b"", 0o600)
    identity = _create_locked_file(path, raw, 0o755)
    records = {
        "auditPath": str(audit_path),
        "interpreter": _zsh_descriptor(environment),
        "path": str(path),
        "policy": {
            "effectiveJobArguments": ["-j", "1"],
            "effectiveJobArgumentsAreTerminal": True,
            "effectiveLLVMRNGSeedArguments": ["-Xllvm", "-rng-seed=1"],
            "effectiveNumThreadsArguments": ["-num-threads", "1"],
            "projectedFrontendJobCountPerInvocation": 1,
            "projectedLLVMRNGSeedArguments": ["-Xllvm", "-rng-seed=1"],
            "projectedNumThreadsArguments": ["-num-threads", "1"],
            "rejectMissingDuplicateOrSubstitutedControls": True,
            "underlyingArgv0": "swiftc",
            "rejectMalformedJobArguments": True,
            "removeEveryPriorJobArgument": True,
            "requiredTargets": list(SWIFT_DRIVER_REQUIRED_TARGETS),
        },
        "schemaVersion": SWIFT_DRIVER_WRAPPER_SCHEMA,
        "sha256": sha256_bytes(raw),
        "underlyingSwiftc": dict(swiftc),
        "unixMode": 0o755,
    }
    receipt = {
        **records,
        "identitySHA256": sha256_bytes(
            SWIFT_DRIVER_WRAPPER_DOMAIN + canonical_bytes(records)
        ),
    }
    return SwiftDriverWrapperInstallation(
        path=path,
        identity=identity,
        audit_path=audit_path,
        audit_identity=audit_identity,
        receipt=receipt,
    )


def revalidate_swift_driver_wrapper(
    installation: SwiftDriverWrapperInstallation,
    toolchain: Mapping[str, Any],
    environment: Mapping[str, str],
) -> None:
    wrapper_metadata = os.lstat(installation.path)
    audit_metadata = os.lstat(installation.audit_path)
    require(
        _stable_node_identity(wrapper_metadata) == installation.identity
        and stat.S_ISREG(wrapper_metadata.st_mode)
        and stat.S_IMODE(wrapper_metadata.st_mode) == 0o755
        and not installation.path.is_symlink()
        and sha256_file(installation.path)
        == installation.receipt["sha256"],
        "Swift driver wrapper changed during the clean build",
    )
    require(
        _stable_node_identity(audit_metadata) == installation.audit_identity
        and stat.S_ISREG(audit_metadata.st_mode)
        and stat.S_IMODE(audit_metadata.st_mode) == 0o600
        and not installation.audit_path.is_symlink(),
        "Swift driver job audit changed identity or mode during the clean build",
    )
    require(
        _swiftc_descriptor(environment) == toolchain.get("swiftc")
        and _zsh_descriptor(environment)
        == installation.receipt.get("interpreter"),
        "Swift driver wrapper dependency changed during the clean build",
    )


def swift_driver_job_audit(
    installation: SwiftDriverWrapperInstallation,
) -> dict[str, Any]:
    raw = installation.audit_path.read_bytes()
    require(
        0 < len(raw) <= 1024 * 1024
        and raw.endswith(b"\n"),
        "Swift driver job audit is absent, empty, or oversized",
    )
    try:
        lines = raw.decode("utf-8").splitlines()
    except UnicodeError as error:
        raise ArchiveProvenanceError(
            f"Swift driver job audit is not UTF-8: {error}"
        ) from error
    expected_lines = sorted(SWIFT_DRIVER_JOB_AUDIT_MARKERS)
    require(
        sorted(lines) == expected_lines,
        "Swift driver job audit omits, duplicates, or substitutes a release target or control",
    )
    normalized_raw = (
        "\n".join(expected_lines) + "\n"
    ).encode("utf-8")
    records = {
        "byteCount": len(normalized_raw),
        "effectiveJobArguments": ["-j", "1"],
        "effectiveJobArgumentsAreTerminal": True,
        "effectiveLLVMRNGSeedArguments": ["-Xllvm", "-rng-seed=1"],
        "effectiveNumThreadsArguments": ["-num-threads", "1"],
        "invocationCount": len(lines),
        "markers": expected_lines,
        "path": str(installation.audit_path),
        "projectedFrontendJobCountPerInvocation": 1,
        "projectedLLVMRNGSeedArguments": ["-Xllvm", "-rng-seed=1"],
        "projectedNumThreadsArguments": ["-num-threads", "1"],
        "requiredTargets": list(SWIFT_DRIVER_REQUIRED_TARGETS),
        "schemaVersion": SWIFT_DRIVER_JOB_AUDIT_SCHEMA,
        "sha256": sha256_bytes(normalized_raw),
    }
    return {
        **records,
        "identitySHA256": sha256_bytes(
            SWIFT_DRIVER_JOB_AUDIT_DOMAIN + canonical_bytes(records)
        ),
    }


def clean_build_toolchain(
    environment: Mapping[str, str],
    metal_resolution: MetalToolchainResolution | None = None,
) -> dict[str, Any]:
    developer = Path(environment["DEVELOPER_DIR"])
    xcodebuild = (developer / "usr/bin/xcodebuild").resolve(strict=True)
    metal_resolution = metal_resolution or resolve_metal_toolchain(environment)
    swiftc = _swiftc_descriptor(environment)
    clang = Path(
        _checked_output(
            ["/usr/bin/xcrun", "--find", "clang"],
            "Clang compiler inspection",
            environment=environment,
        )
    ).resolve(strict=True)
    sdk_path = Path(
        _checked_output(
            ["/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-path"],
            "macOS SDK path inspection",
            environment=environment,
        )
    ).resolve(strict=True)
    return {
        "clang": {
            "path": str(clang),
            "sha256": sha256_file(clang),
            "version": _checked_output(
                [str(clang), "--version"],
                "Clang version inspection",
                environment=environment,
            ).splitlines(),
        },
        "codesign": {
            "path": "/usr/bin/codesign",
            "sha256": sha256_file(Path("/usr/bin/codesign")),
            "version": ["macOS build " + _checked_output(
                ["/usr/bin/sw_vers", "-buildVersion"],
                "macOS build-version inspection",
                environment=environment,
            )],
        },
        "developerDirectory": str(developer),
        "git": {
            "path": "/usr/bin/git",
            "sha256": sha256_file(Path("/usr/bin/git")),
            "version": _checked_output(
                ["/usr/bin/git", "--version"],
                "Git version inspection",
                environment=environment,
            ).splitlines(),
        },
        "macOSSDK": {
            "path": str(sdk_path),
            "settingsJSONSHA256": sha256_file(sdk_path / "SDKSettings.json"),
            "settingsPlistSHA256": sha256_file(sdk_path / "SDKSettings.plist"),
            "version": _checked_output(
                ["/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-version"],
                "macOS SDK version inspection",
                environment=environment,
            ),
        },
        "lipo": {
            "path": "/usr/bin/lipo",
            "sha256": sha256_file(Path("/usr/bin/lipo")),
            "version": _checked_output(
                [str(xcodebuild), "-version"],
                "lipo Xcode version inspection",
                environment=environment,
            ).splitlines(),
        },
        "metal": dict(metal_resolution.receipt),
        "swiftc": {
            **swiftc,
        },
        "xcodebuild": {
            "path": str(xcodebuild),
            "sha256": sha256_file(xcodebuild),
            "version": _checked_output(
                [str(xcodebuild), "-version"],
                "Xcode version inspection",
                environment=environment,
            ).splitlines(),
        },
    }


def metal_source_descriptors(source_root: Path) -> list[dict[str, Any]]:
    descriptors: list[dict[str, Any]] = []
    for relative, air_output in METAL_SOURCE_SPECS:
        source = source_root.joinpath(*PurePosixPath(relative).parts)
        require(
            source.is_file() and not source.is_symlink(),
            f"clean source omits deterministic Metal input: {relative}",
        )
        mode = stat.S_IMODE(source.stat().st_mode) & 0o777
        require(
            mode == 0o644 and source.stat().st_size > 0,
            f"deterministic Metal input has an unsupported mode or size: {relative}",
        )
        descriptors.append(
            {
                "airOutput": air_output,
                "byteCount": source.stat().st_size,
                "gitMode": "100644",
                "repositoryRelativePath": relative,
                "sha256": sha256_file(source),
            }
        )
    return descriptors


def metal_compile_command_template(source: Mapping[str, Any]) -> list[str]:
    return [
        "$UNDERLYING_METAL",
        "-c",
        f"-std={METAL_LANGUAGE_STANDARD}",
        METAL_OPTIMIZATION_LEVEL,
        "-target",
        METAL_TARGET_TRIPLE,
        "-isysroot",
        "$SDKROOT",
        "-fmetal-math-mode=safe",
        "-fmetal-math-fp32-functions=precise",
        "-o",
        f"$METAL_INTERMEDIATES/{source['airOutput']}",
        f"$SOURCE_ROOT/{source['repositoryRelativePath']}",
    ]


def metal_link_command_template(sources: Sequence[Mapping[str, Any]]) -> list[str]:
    return [
        "$METALLIB",
        "-o",
        f"$APPLICATION/{DEFAULT_METAL_LIBRARY_RELATIVE_PATH}",
        *[
            f"$METAL_INTERMEDIATES/{source['airOutput']}"
            for source in sources
        ],
    ]


def metal_symbol_command_template() -> list[str]:
    return [
        "$UNDERLYING_METAL_NM",
        f"$APPLICATION/{DEFAULT_METAL_LIBRARY_RELATIVE_PATH}",
    ]


def post_build_signing_command_template() -> list[str]:
    return [
        "$CODESIGN",
        "--force",
        "--sign",
        "-",
        "--timestamp=none",
        "--options",
        "runtime",
        "--generate-entitlement-der",
        "--identifier",
        CLEAN_BUILD_BUNDLE_IDENTIFIER,
        "--entitlements",
        f"$SOURCE_ROOT/{METAL_ENTITLEMENTS_REPOSITORY_PATH}",
        "$APPLICATION",
    ]


def _materialize_build_command(
    command: Sequence[str],
    replacements: Mapping[str, Path],
) -> list[str]:
    output: list[str] = []
    for argument in command:
        changed = argument
        for placeholder, resolved in sorted(
            replacements.items(),
            key=lambda item: len(item[0]),
            reverse=True,
        ):
            if changed == placeholder:
                changed = str(resolved)
                break
            prefix = placeholder + "/"
            if changed.startswith(prefix):
                changed = str(resolved.joinpath(*PurePosixPath(changed[len(prefix):]).parts))
                break
        require("$" not in changed, f"build command retains an unresolved placeholder: {changed}")
        output.append(changed)
    return output


def _run_locked_build_command(
    command: Sequence[str],
    label: str,
    environment: Mapping[str, str],
    *,
    cwd: Path,
) -> str:
    process = subprocess.run(
        list(command),
        cwd=cwd,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        env=dict(environment),
        check=False,
    )
    output = process.stdout.decode("utf-8", errors="replace").strip()
    require(process.returncode == 0, f"{label} failed: {output}")
    return output


def _metal_output_descriptor(path: Path, stable_path: str) -> dict[str, Any]:
    require(
        path.is_file() and not path.is_symlink(),
        f"deterministic Metal output is absent: {stable_path}",
    )
    path.chmod(0o644)
    require(path.stat().st_size > 0, f"deterministic Metal output is empty: {stable_path}")
    return {
        "byteCount": path.stat().st_size,
        "path": stable_path,
        "sha256": sha256_file(path),
        "unixMode": 0o644,
    }


def _metal_symbol_inventory(
    raw_output: str,
) -> list[str]:
    symbols: list[str] = []
    for line in raw_output.splitlines():
        match = re.fullmatch(r"[0-9A-Fa-f]+\s+T\s+([A-Za-z_][A-Za-z0-9_]*)", line.strip())
        require(match is not None, f"Metal symbol inventory has an unsupported row: {line!r}")
        symbols.append(match.group(1))
    require(
        len(symbols) == len(set(symbols)),
        "Metal symbol inventory repeats an exported function",
    )
    ordered = sorted(symbols)
    require(
        ordered == sorted(EXPECTED_METAL_SYMBOLS),
        "default Metal library exports another function set; "
        f"observed={ordered}",
    )
    return ordered


def compile_external_metal_library(
    *,
    source_root: Path,
    application: Path,
    intermediates: Path,
    expected_sources: Sequence[Mapping[str, Any]],
    toolchain: Mapping[str, Any],
    metal_resolution: MetalToolchainResolution,
    environment: Mapping[str, str],
) -> dict[str, Any]:
    sources = metal_source_descriptors(source_root)
    require(
        sources == [dict(item) for item in expected_sources],
        "deterministic Metal inputs changed after committed-source verification",
    )
    require(
        metal_resolution.receipt == toolchain.get("metal"),
        "resolved Metal component differs from the recorded toolchain",
    )
    require(
        not intermediates.exists(),
        "deterministic Metal intermediate directory already exists",
    )
    intermediates.mkdir(mode=0o700)
    resources = application / "Contents/Resources"
    require(
        resources.is_dir()
        and not resources.is_symlink()
        and resources.resolve(strict=True).parent.parent == application.resolve(strict=True),
        "application Resources directory is absent or escapes its bundle",
    )
    library = resources / "default.metallib"
    require(
        not library.exists() and not library.is_symlink(),
        "xcodebuild unexpectedly produced a default Metal library",
    )
    replacements = {
        "$APPLICATION": application,
        "$METAL_INTERMEDIATES": intermediates,
        "$SDKROOT": Path(toolchain["macOSSDK"]["path"]),
        "$SOURCE_ROOT": source_root,
        "$UNDERLYING_METAL": metal_resolution.metal,
        "$METALLIB": metal_resolution.metallib,
        "$UNDERLYING_METAL_NM": metal_resolution.metal_nm,
    }
    compile_records: list[dict[str, Any]] = []
    outputs: list[dict[str, Any]] = []
    for source in sources:
        template = metal_compile_command_template(source)
        actual = _materialize_build_command(template, replacements)
        transcript = _run_locked_build_command(
            actual,
            f"deterministic Metal compile for {source['repositoryRelativePath']}",
            environment,
            cwd=source_root,
        )
        output = _metal_output_descriptor(
            intermediates / source["airOutput"],
            f"$METAL_INTERMEDIATES/{source['airOutput']}",
        )
        outputs.append(output)
        compile_records.append(
            {
                "command": template,
                "commandSHA256": sha256_bytes(canonical_bytes(template)),
                "exitStatus": 0,
                "normalizedTranscriptSHA256": sha256_bytes(
                    _normalize_metal_tool_output(
                        transcript,
                        metal_resolution.component_root,
                    ).encode("utf-8")
                ),
                "output": output,
                "sourceRepositoryRelativePath": source[
                    "repositoryRelativePath"
                ],
            }
        )
    link_template = metal_link_command_template(sources)
    link_actual = _materialize_build_command(link_template, replacements)
    link_transcript = _run_locked_build_command(
        link_actual,
        "deterministic Metal library link",
        environment,
        cwd=source_root,
    )
    library_output = _metal_output_descriptor(
        library,
        DEFAULT_METAL_LIBRARY_RELATIVE_PATH,
    )
    outputs.append(library_output)
    symbol_template = metal_symbol_command_template()
    symbol_actual = _materialize_build_command(symbol_template, replacements)
    raw_symbols = _run_locked_build_command(
        symbol_actual,
        "deterministic Metal symbol inspection",
        environment,
        cwd=source_root,
    )
    symbols = _metal_symbol_inventory(raw_symbols)
    return {
        "compile": compile_records,
        "languageStandard": METAL_LANGUAGE_STANDARD,
        "link": {
            "command": link_template,
            "commandSHA256": sha256_bytes(canonical_bytes(link_template)),
            "exitStatus": 0,
            "normalizedTranscriptSHA256": sha256_bytes(
                _normalize_metal_tool_output(
                    link_transcript,
                    metal_resolution.component_root,
                ).encode("utf-8")
            ),
            "output": library_output,
        },
        "outputSetIdentitySHA256": sha256_bytes(
            METAL_OUTPUT_SET_DOMAIN + canonical_bytes(outputs)
        ),
        "optimizationLevel": METAL_OPTIMIZATION_LEVEL,
        "sourceSetIdentitySHA256": sha256_bytes(
            METAL_SOURCE_SET_DOMAIN + canonical_bytes(sources)
        ),
        "sources": sources,
        "symbols": {
            "command": symbol_template,
            "commandSHA256": sha256_bytes(canonical_bytes(symbol_template)),
            "inventory": symbols,
            "inventorySHA256": sha256_bytes(
                METAL_SYMBOL_SET_DOMAIN + canonical_bytes(symbols)
            ),
        },
        "targetTriple": METAL_TARGET_TRIPLE,
        "toolSetIdentitySHA256": toolchain["metal"]["identitySHA256"],
    }


def _post_build_entitlements(source_root: Path) -> dict[str, Any]:
    entitlements = source_root.joinpath(
        *PurePosixPath(METAL_ENTITLEMENTS_REPOSITORY_PATH).parts
    )
    require(
        entitlements.is_file() and not entitlements.is_symlink(),
        "clean source omits declared application entitlements",
    )
    raw = entitlements.read_bytes()
    try:
        value = plistlib.loads(raw)
    except plistlib.InvalidFileException as error:
        raise ArchiveProvenanceError(
            f"cannot decode declared application entitlements: {error}"
        ) from error
    require(
        isinstance(value, dict)
        and not bool(value.get("com.apple.security.get-task-allow", False)),
        "declared application entitlements are invalid or enable get-task-allow",
    )
    normalized = plistlib.dumps(value, fmt=plistlib.FMT_BINARY, sort_keys=True)
    return {
        "byteCount": len(raw),
        "normalizedSHA256": sha256_bytes(ENTITLEMENTS_DOMAIN + normalized),
        "repositoryRelativePath": METAL_ENTITLEMENTS_REPOSITORY_PATH,
        "sha256": sha256_bytes(raw),
    }


def post_build_sign_application(
    *,
    source_root: Path,
    application: Path,
    toolchain: Mapping[str, Any],
    environment: Mapping[str, str],
) -> dict[str, Any]:
    entitlements = _post_build_entitlements(source_root)
    info_plist = application / "Contents/Info.plist"
    require(
        info_plist.is_file() and not info_plist.is_symlink(),
        "application omits Info.plist before deterministic signing",
    )
    try:
        plist = plistlib.loads(info_plist.read_bytes())
    except plistlib.InvalidFileException as error:
        raise ArchiveProvenanceError(
            f"cannot decode application Info.plist before signing: {error}"
        ) from error
    require(
        isinstance(plist, dict)
        and plist.get("CFBundleIdentifier") == CLEAN_BUILD_BUNDLE_IDENTIFIER,
        "application bundle identifier differs before deterministic signing",
    )
    template = post_build_signing_command_template()
    actual = _materialize_build_command(
        template,
        {
            "$APPLICATION": application,
            "$CODESIGN": Path(toolchain["codesign"]["path"]),
            "$SOURCE_ROOT": source_root,
        },
    )
    transcript = _run_locked_build_command(
        actual,
        "deterministic application ad-hoc signing",
        environment,
        cwd=source_root,
    )
    return {
        "command": template,
        "commandSHA256": sha256_bytes(canonical_bytes(template)),
        "entitlements": entitlements,
        "exitStatus": 0,
        "normalizedTranscriptSHA256": sha256_bytes(
            transcript.encode("utf-8")
        ),
        "policy": {
            "bundleIdentifier": CLEAN_BUILD_BUNDLE_IDENTIFIER,
            "generateDEREntitlements": True,
            "hardenedRuntime": True,
            "identity": "-",
            "mode": "ad-hoc",
            "timestamp": "none",
        },
    }


def finalize_post_build_receipt(
    metal: Mapping[str, Any],
    signing: Mapping[str, Any],
    application: Mapping[str, Any],
) -> dict[str, Any]:
    require(
        metal.get("link", {}).get("output")
        == application.get("defaultMetalLibrary"),
        "signed application contains another default Metal library",
    )
    expected_policy_flags = [
        {
            "architecture": architecture,
            "flags": f"0x{HARDENED_RUNTIME_CODE_DIRECTORY_FLAGS:08x}",
        }
        for architecture in sorted(EXPECTED_APPLICATION_ARCHITECTURES)
    ]
    require(
        application.get("codeDirectoryPolicyFlags") == expected_policy_flags,
        "post-build signature does not use only the hardened-runtime policy",
    )
    finalized_signing = {
        **dict(signing),
        "observed": {
            "codeDirectoryPolicyFlags": application["codeDirectoryPolicyFlags"],
            "codeIdentifier": application["codeIdentifier"],
            "entitlementsByArchitecture": application[
                "entitlementsByArchitecture"
            ],
            "entitlementsSHA256": application["entitlementsSHA256"],
        },
    }
    require(
        finalized_signing["entitlements"]["normalizedSHA256"]
        == application["entitlementsSHA256"],
        "signed application entitlements differ from the declared file",
    )
    return {
        "metal": dict(metal),
        "signing": finalized_signing,
    }


def directory_source_manifest(root: Path) -> dict[str, Any]:
    descriptors = []
    for path in regular_files(root):
        mode = "100755" if path.stat().st_mode & 0o111 else "100644"
        descriptors.append(
            {
                "byteCount": path.stat().st_size,
                "gitMode": mode,
                "path": path.relative_to(root).as_posix(),
                "sha256": sha256_file(path),
            }
        )
    return {
        "entryCount": len(descriptors),
        "identitySHA256": sha256_bytes(
            CLEAN_SOURCE_MANIFEST_DOMAIN + canonical_bytes(descriptors)
        ),
        "schemaVersion": CLEAN_SOURCE_MANIFEST_SCHEMA,
        "totalByteCount": sum(item["byteCount"] for item in descriptors),
    }


def clean_build_command_template(
    toolchain: Mapping[str, Any],
    settings: Mapping[str, str],
) -> list[str]:
    return [
        toolchain["xcodebuild"]["path"],
        "-quiet",
        "-project",
        CLEAN_BUILD_PROJECT,
        "-scheme",
        CLEAN_BUILD_SCHEME,
        "-configuration",
        CLEAN_BUILD_CONFIGURATION,
        "-destination",
        CLEAN_BUILD_DESTINATION,
        "-jobs",
        "1",
        "-derivedDataPath",
        "$DERIVED_DATA",
        "-xcconfig",
        "$PROVENANCE_XCCONFIG",
        *[f"{key}={value}" for key, value in sorted(settings.items())],
        "build",
    ]


def make_clean_build_receipt(
    *,
    context: Mapping[str, str],
    source_manifest: Mapping[str, Any],
    settings: Mapping[str, str],
    toolchain: Mapping[str, Any],
    build_environment: Mapping[str, str],
    normalized_xcconfig_sha256: str,
    normalized_transcript_sha256: str,
    swift_driver_job_audit: Mapping[str, Any],
    application: Mapping[str, Any],
    post_build: Mapping[str, Any],
) -> dict[str, Any]:
    command = clean_build_command_template(toolchain, settings)
    source_export_command = clean_source_export_command(
        context["sourceCommit"],
        "$CLEAN_SOURCE_TAR",
    )
    return {
        "application": source_build_application_identity(application),
        "build": {
            "canonicalLayout": canonical_clean_build_layout(),
            "command": command,
            "commandSHA256": sha256_bytes(canonical_bytes(command)),
            "configuration": CLEAN_BUILD_CONFIGURATION,
            "destination": CLEAN_BUILD_DESTINATION,
            "environment": dict(build_environment),
            "exitStatus": 0,
            "normalizedTranscriptSHA256": normalized_transcript_sha256,
            "project": CLEAN_BUILD_PROJECT,
            "provenanceXCConfigSHA256": normalized_xcconfig_sha256,
            "scheme": CLEAN_BUILD_SCHEME,
            "settings": dict(settings),
            "swiftDriverJobAudit": dict(swift_driver_job_audit),
        },
        "cleanSource": {
            "commit": context["sourceCommit"],
            "environment": git_environment(),
            "exportCommand": source_export_command,
            "exportCommandSHA256": sha256_bytes(
                canonical_bytes(source_export_command)
            ),
            "manifest": dict(source_manifest),
            "treeIdentitySHA256": context["sourceTreeIdentitySHA256"],
        },
        "postBuild": dict(post_build),
        "schemaVersion": CLEAN_BUILD_RECEIPT_SCHEMA,
        "toolchain": dict(toolchain),
    }


def source_build_application_identity(
    application: Mapping[str, Any],
) -> dict[str, Any]:
    """Return the signer-independent application identity for source replay.

    The archive independently verifies and binds the final signature, raw
    executable, CodeDirectories, and designated requirement. Those objects
    cannot be reproduced with an unrelated signer because the requirement and
    signature allocation affect the CodeDirectory. Source replay instead binds
    the exact signature-stripped executable, all non-signature resources,
    semantic entitlements, signing identifier, and signature-policy flags.
    """

    require(
        "executableSHA256" in application
        and "unsignedExecutableSHA256" in application
        and "unsignedExecutableSlices" in application
        and "reproducibleBundleContent" in application,
        "application observation omits executable identities",
    )
    keys = (
        "bundleIdentifier",
        "bundleRoot",
        "codeDirectoryPolicyFlags",
        "codeIdentifier",
        "defaultMetalLibrary",
        "embeddedClaimSetSHA256",
        "entitlementsByArchitecture",
        "entitlementsSHA256",
        "executablePath",
        "executableUnixMode",
        "infoPlistPath",
        "infoPlistSHA256",
        "productBuild",
        "productVersion",
        "reproducibleBundleContent",
        "runtime",
        "unsignedExecutableSHA256",
        "unsignedExecutableSlices",
    )
    require(
        all(key in application for key in keys),
        "application observation omits signer-independent provenance",
    )
    return {key: application[key] for key in keys}


def normalized_build_transcript(
    transcript: str,
    *,
    root: Path,
    source: Path,
    derived_data: Path,
    overlay: Path,
) -> str:
    aliases = {
        str(root): "$BUILD_ROOT",
        str(source): "$SOURCE_ROOT",
        str(derived_data): "$DERIVED_DATA",
        str(overlay): "$PROVENANCE_XCCONFIG",
    }
    if str(root).startswith("/private/tmp/"):
        for path, replacement in list(aliases.items()):
            aliases[path.removeprefix("/private")] = replacement
    normalized = transcript
    for path, replacement in sorted(
        aliases.items(),
        key=lambda item: len(item[0]),
        reverse=True,
    ):
        normalized = normalized.replace(path, replacement)
    lines = sorted(line.rstrip() for line in normalized.splitlines() if line.strip())
    return "\n".join(lines) + ("\n" if lines else "")


def _copy_clean_application(
    application: Path,
    observation: Mapping[str, Any],
    context: Mapping[str, str],
    raw_output: Path,
) -> Path:
    target = publication_target(raw_output, "clean application")
    output = target.path
    require(
        output.name == CLEAN_BUILD_PRODUCT,
        f"clean application output must be named {CLEAN_BUILD_PRODUCT}",
    )
    staging_root = Path(
        tempfile.mkdtemp(
            prefix=f".{CLEAN_BUILD_PRODUCT}.",
            dir=output.parent,
        )
    )
    staged = staging_root / CLEAN_BUILD_PRODUCT
    try:
        shutil.copytree(application, staged, copy_function=shutil.copy2)
        copied = application_directory_observation(staged, context)
        require(
            copied == observation,
            "copied clean application differs from the canonical build product",
        )
        _publish_no_clobber(staged, target, "clean application")
        staging_root.rmdir()
        return output
    finally:
        if staging_root.exists():
            shutil.rmtree(staging_root)


def _execute_clean_source_build(
    context: Mapping[str, str],
    requested_settings: Mapping[str, str],
    *,
    candidate_application: Mapping[str, Any] | None,
    output_application: Path | None,
) -> dict[str, Any]:
    settings = normalize_clean_build_settings(requested_settings)
    with canonical_clean_build_workspace() as root:
        source = root / "source"
        derived_data = root / "DerivedData"
        source.mkdir(mode=0o700)
        source_manifest = verified_git_archive_source(context, source)
        release_configuration = source.joinpath(
            *PurePosixPath(
                context["releaseConfigurationRepositoryRelativePath"]
            ).parts
        )
        require(
            release_configuration.is_file()
            and not release_configuration.is_symlink()
            and sha256_file(release_configuration)
            == context["releaseConfigurationSHA256"],
            "clean source contains another Release configuration",
        )
        environment = clean_build_environment(root)
        metal_resolution = resolve_metal_toolchain(environment)
        toolchain = clean_build_toolchain(environment, metal_resolution)
        swift_driver = install_swift_driver_wrapper(
            root,
            toolchain,
            environment,
        )
        toolchain = {
            **toolchain,
            "swiftDriverWrapper": dict(swift_driver.receipt),
        }
        overlay = root / "release-provenance.xcconfig"
        overlay_text = build_settings_text(context, release_configuration)
        overlay.write_text(overlay_text, encoding="utf-8")
        normalized_overlay = overlay_text.replace(str(source), "$SOURCE_ROOT")
        expected_metal_sources = metal_source_descriptors(source)
        command_template = clean_build_command_template(toolchain, settings)
        command = [
            str(derived_data) if item == "$DERIVED_DATA" else str(overlay) if item == "$PROVENANCE_XCCONFIG" else item
            for item in command_template
        ]
        process = subprocess.run(
            command,
            cwd=source,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            env=environment,
            check=False,
        )
        transcript = process.stdout.decode("utf-8", errors="replace")
        normalized_transcript = normalized_build_transcript(
            transcript,
            root=root,
            source=source,
            derived_data=derived_data,
            overlay=overlay,
        )
        require(
            process.returncode == 0,
            "clean committed-source xcodebuild failed: " + transcript[-8000:].strip(),
        )
        revalidate_swift_driver_wrapper(
            swift_driver,
            toolchain,
            environment,
        )
        swift_job_audit = swift_driver_job_audit(swift_driver)
        require(
            directory_source_manifest(source) == source_manifest,
            "xcodebuild modified the verified clean source tree",
        )
        application = (
            derived_data
            / "Build/Products"
            / CLEAN_BUILD_CONFIGURATION
            / CLEAN_BUILD_PRODUCT
        )
        refreshed_metal = revalidate_metal_toolchain(
            metal_resolution,
            environment,
            "the clean Xcode build",
        )
        metal_post_build = compile_external_metal_library(
            source_root=source,
            application=application,
            intermediates=root / "Metal",
            expected_sources=expected_metal_sources,
            toolchain=toolchain,
            metal_resolution=refreshed_metal,
            environment=environment,
        )
        revalidate_metal_toolchain(
            refreshed_metal,
            environment,
            "deterministic Metal compilation and linking",
        )
        signing_post_build = post_build_sign_application(
            source_root=source,
            application=application,
            toolchain=toolchain,
            environment=environment,
        )
        revalidate_metal_toolchain(
            refreshed_metal,
            environment,
            "deterministic application signing",
        )
        observation = application_directory_observation(application, context)
        post_build = finalize_post_build_receipt(
            metal_post_build,
            signing_post_build,
            observation,
        )
        require(
            directory_source_manifest(source) == source_manifest,
            "post-build Metal or signing stages modified the verified clean source tree",
        )
        if candidate_application is not None:
            require(
                source_build_application_identity(observation)
                == source_build_application_identity(candidate_application),
                "candidate executable, resources, entitlements, or signing policy "
                "does not match the clean committed-source build",
            )
        if output_application is not None:
            _copy_clean_application(
                application,
                observation,
                context,
                output_application,
            )
        return make_clean_build_receipt(
            context=context,
            source_manifest=source_manifest,
            settings=settings,
            toolchain=toolchain,
            build_environment=environment,
            normalized_xcconfig_sha256=sha256_bytes(
                normalized_overlay.encode("utf-8")
            ),
            normalized_transcript_sha256=sha256_bytes(
                normalized_transcript.encode("utf-8")
            ),
            swift_driver_job_audit=swift_job_audit,
            application=observation,
            post_build=post_build,
        )


def clean_source_build(
    context: Mapping[str, str],
    candidate_application: Mapping[str, Any],
    requested_settings: Mapping[str, str],
) -> dict[str, Any]:
    return _execute_clean_source_build(
        context,
        requested_settings,
        candidate_application=candidate_application,
        output_application=None,
    )


def build_candidate_application(
    context: Mapping[str, str],
    output_application: Path,
) -> dict[str, Any]:
    """Build and export the candidate from the canonical physical root."""

    return _execute_clean_source_build(
        context,
        CLEAN_REPLAY_BUILD_SETTINGS,
        candidate_application=None,
        output_application=output_application,
    )


def build_candidate_xcarchive(
    context: Mapping[str, str],
    output_archive: Path,
    *,
    signing_identity: str = "-",
) -> dict[str, Any]:
    """Construct an xcarchive only from the canonical verified clean product."""

    raw_output = output_archive.expanduser()
    require(
        raw_output.suffix == ".xcarchive",
        "candidate xcarchive output must use the .xcarchive suffix",
    )
    target = publication_target(raw_output, "candidate xcarchive")
    output = target.path
    staging_root = Path(
        tempfile.mkdtemp(prefix=f".{output.name}.", dir=output.parent)
    )
    staged_archive = staging_root / output.name
    products = staged_archive / "Products/Applications"
    products.mkdir(parents=True, mode=0o755)
    application = products / CLEAN_BUILD_PRODUCT
    try:
        receipt = build_candidate_application(context, application)
        observation = application_directory_observation(application, context)
        require(
            receipt["application"] == source_build_application_identity(observation),
            "candidate xcarchive app differs from its canonical clean-build receipt",
        )
        if signing_identity != "-":
            require(
                signing_identity.strip() == signing_identity
                and signing_identity
                and "\n" not in signing_identity
                and "\r" not in signing_identity,
                "candidate signing identity is invalid",
            )
            executable_relative = PurePosixPath(
                observation["executablePath"]
            ).relative_to(PurePosixPath(observation["bundleRoot"]))
            executable = application.joinpath(*executable_relative.parts)
            _, entitlements = _entitlements_observation(executable, "arm64")
            command = ["/usr/bin/codesign", "--force", "--deep"]
            policy_flags = {
                int(item["flags"], 16)
                for item in observation["codeDirectoryPolicyFlags"]
            }
            if any(value & 0x00010000 for value in policy_flags):
                command.extend(("--options", "runtime"))
            if entitlements:
                entitlement_path = staging_root / "candidate-entitlements.plist"
                entitlement_path.write_bytes(
                    plistlib.dumps(
                        entitlements,
                        fmt=plistlib.FMT_XML,
                        sort_keys=True,
                    )
                )
                command.extend(("--entitlements", str(entitlement_path)))
            command.extend(
                ("--timestamp", "--sign", signing_identity, str(application))
            )
            _run(command, "identity-backed candidate signing")
            signed_observation = application_directory_observation(
                application,
                context,
            )
            require(
                source_build_application_identity(signed_observation)
                == source_build_application_identity(observation),
                "identity-backed signing changed signer-independent application bytes",
            )
            observation = signed_observation
        repository = Path(context["repositoryAbsolutePath"])
        commit_time = (
            datetime.fromisoformat(
                git_output(
                    repository,
                    ["show", "-s", "--format=%cI", context["sourceCommit"]],
                )
            )
            .astimezone(timezone.utc)
            .replace(tzinfo=None)
        )
        archive_info = {
            "ApplicationProperties": {
                "ApplicationPath": f"Products/Applications/{CLEAN_BUILD_PRODUCT}",
                "Architectures": list(EXPECTED_APPLICATION_ARCHITECTURES),
                "CFBundleIdentifier": observation["bundleIdentifier"],
                "CFBundleShortVersionString": observation["productVersion"],
                "CFBundleVersion": observation["productBuild"],
                "SigningIdentity": signing_identity,
            },
            "ArchiveVersion": 2,
            "CreationDate": commit_time,
            "Name": "Mirmir",
            "SchemeName": CLEAN_BUILD_SCHEME,
        }
        (staged_archive / "Info.plist").write_bytes(
            plistlib.dumps(archive_info, fmt=plistlib.FMT_XML, sort_keys=True)
        )
        (staged_archive / "MirmirV4CanonicalBuildReceipt.json").write_bytes(
            canonical_bytes(receipt)
        )
        _publish_no_clobber(staged_archive, target, "candidate xcarchive")
        staging_root.rmdir()
        return {
            "application": observation,
            "sourceBuild": receipt,
        }
    finally:
        if staging_root.exists():
            shutil.rmtree(staging_root)


def _validate_metal_toolchain_receipt(value: Any) -> dict[str, Any]:
    require(
        isinstance(value, dict)
        and set(value)
        == {
            "component",
            "identitySHA256",
            "metal",
            "metallib",
            "metalNM",
            "resources",
        },
        "clean-source Metal toolchain has an unsupported shape",
    )
    component = value.get("component")
    require(
        isinstance(component, dict)
        and set(component)
        == {
            "assetIdentifier",
            "buildVersion",
            "name",
            "queryCommand",
            "status",
            "toolchainIdentifier",
            "toolchainRelativePath",
        }
        and component.get("name") == METAL_COMPONENT_NAME
        and component.get("status") == "installed"
        and component.get("toolchainRelativePath") == "Metal.xctoolchain"
        and component.get("queryCommand")
        == [
            "$XCODEBUILD",
            "-showComponent",
            METAL_COMPONENT_NAME,
            "-json",
        ]
        and isinstance(component.get("assetIdentifier"), str)
        and re.fullmatch(r"[0-9a-f]{40}\.asset", component["assetIdentifier"])
        is not None
        and isinstance(component.get("buildVersion"), str)
        and re.fullmatch(r"[A-Za-z0-9._-]+", component["buildVersion"])
        is not None
        and isinstance(component.get("toolchainIdentifier"), str)
        and re.fullmatch(r"[A-Za-z0-9._-]+", component["toolchainIdentifier"])
        is not None,
        "clean-source Metal component descriptor is invalid",
    )
    underlying_tool_versions: set[str] = set()
    for key, name, placeholder, underlying_name in (
        ("metal", "metal", "$METAL", "metal"),
        ("metallib", "metallib", "$METALLIB", "air-lld"),
        ("metalNM", "metal-nm", "$METAL_NM", "air-nm"),
    ):
        descriptor = value.get(key)
        require(
            isinstance(descriptor, dict)
            and set(descriptor)
            == {
                "componentRelativePath",
                "lookupCommand",
                "resolvedComponentRelativePath",
                "sha256",
                "underlyingComponentRelativePath",
                "underlyingSHA256",
                "underlyingVersion",
                "underlyingVersionCommand",
                "version",
                "versionCommand",
            }
            and descriptor.get("componentRelativePath") == f"usr/bin/{name}"
            and descriptor.get("lookupCommand")
            == ["/usr/bin/xcrun", "--find", name]
            and descriptor.get("versionCommand") == [placeholder, "--version"]
            and descriptor.get("underlyingVersionCommand")
            == [
                "$UNDERLYING_" + name.upper().replace("-", "_"),
                "--version",
            ]
            and isinstance(descriptor.get("resolvedComponentRelativePath"), str)
            and descriptor["resolvedComponentRelativePath"]
            == _canonical_repository_path(
                descriptor["resolvedComponentRelativePath"],
                f"clean-source {name} resolved component path",
            )
            and descriptor["resolvedComponentRelativePath"]
            == f"usr/bin/{underlying_name}"
            and isinstance(
                descriptor.get("underlyingComponentRelativePath"),
                str,
            )
            and re.fullmatch(
                rf"usr/metal/[0-9]+/bin/{re.escape(underlying_name)}",
                descriptor["underlyingComponentRelativePath"],
            )
            is not None
            and isinstance(descriptor.get("version"), list)
            and descriptor["version"]
            and all(
                isinstance(item, str)
                and item
                and "/com.apple.MobileAsset.MetalToolchain-" not in item
                for item in descriptor["version"]
            ),
            f"clean-source {name} descriptor is invalid",
        )
        require(
            isinstance(descriptor.get("underlyingVersion"), list)
            and descriptor["underlyingVersion"]
            and all(
                isinstance(item, str)
                and item
                and "/com.apple.MobileAsset.MetalToolchain-" not in item
                for item in descriptor["underlyingVersion"]
            ),
            f"clean-source {name} underlying descriptor is invalid",
        )
        require_hex(
            descriptor.get("sha256"),
            (64,),
            f"clean-source {name} tool",
        )
        require_hex(
            descriptor.get("underlyingSHA256"),
            (64,),
            f"clean-source {name} underlying tool",
        )
        underlying_tool_versions.add(
            descriptor["underlyingComponentRelativePath"].split("/", 3)[2]
        )
    tool_records = {
        key: value[key]
        for key in (
            "component",
            "metal",
            "metallib",
            "metalNM",
            "resources",
        )
    }
    resources = value.get("resources")
    require(
        isinstance(resources, dict)
        and set(resources)
        == {
            "componentRelativePath",
            "entries",
            "entryCount",
            "identitySHA256",
            "queryCommand",
            "schemaVersion",
            "totalByteCount",
        }
        and resources.get("schemaVersion") == METAL_RESOURCE_MANIFEST_SCHEMA
        and resources.get("queryCommand")
        == ["$UNDERLYING_METAL", "-print-resource-dir"]
        and isinstance(resources.get("componentRelativePath"), str)
        and re.fullmatch(
            r"usr/metal/[0-9]+/lib/clang/[A-Za-z0-9._-]+",
            resources["componentRelativePath"],
        )
        is not None,
        "clean-source Metal compiler resource manifest is invalid",
    )
    resource_entries = resources.get("entries")
    require(
        isinstance(resource_entries, list)
        and resource_entries
        and resources.get("entryCount") == len(resource_entries)
        and resources.get("totalByteCount")
        == sum(
            entry.get("byteCount", -1)
            for entry in resource_entries
            if isinstance(entry, dict)
        ),
        "clean-source Metal compiler resource inventory is invalid",
    )
    resource_paths: list[str] = []
    for entry in resource_entries:
        require(
            isinstance(entry, dict)
            and set(entry) == {"byteCount", "path", "sha256", "unixMode"}
            and isinstance(entry.get("byteCount"), int)
            and entry["byteCount"] > 0
            and isinstance(entry.get("path"), str)
            and entry["path"]
            == _canonical_repository_path(
                entry["path"],
                "clean-source Metal compiler resource path",
            )
            and entry.get("unixMode") in {0o644, 0o755},
            "clean-source Metal compiler resource entry is invalid",
        )
        require_hex(
            entry.get("sha256"),
            (64,),
            "clean-source Metal compiler resource",
        )
        resource_paths.append(entry["path"])
    require(
        resource_paths == sorted(set(resource_paths))
        and set(REQUIRED_METAL_RESOURCE_PATHS).issubset(resource_paths)
        and len(underlying_tool_versions) == 1
        and resources["componentRelativePath"].split("/", 3)[2]
        == next(iter(underlying_tool_versions))
        and resources.get("identitySHA256")
        == sha256_bytes(
            METAL_RESOURCE_SET_DOMAIN + canonical_bytes(resource_entries)
        ),
        "clean-source Metal compiler resource identity differs",
    )
    require(
        value.get("identitySHA256")
        == sha256_bytes(METAL_TOOL_SET_DOMAIN + canonical_bytes(tool_records)),
        "clean-source Metal tool-set identity differs",
    )
    return value


def _validate_metal_output_descriptor(
    value: Any,
    expected_path: str,
    label: str,
) -> dict[str, Any]:
    require(
        isinstance(value, dict)
        and set(value) == {"byteCount", "path", "sha256", "unixMode"}
        and isinstance(value.get("byteCount"), int)
        and value["byteCount"] > 0
        and value.get("path") == expected_path
        and value.get("unixMode") == 0o644,
        f"{label} descriptor is invalid",
    )
    require_hex(value.get("sha256"), (64,), label)
    return value


def validate_post_build_receipt(
    value: Any,
    toolchain: Mapping[str, Any],
    application: Mapping[str, Any],
) -> dict[str, Any]:
    require(
        isinstance(value, dict) and set(value) == {"metal", "signing"},
        "clean-source post-build receipt has an unsupported shape",
    )
    metal = value.get("metal")
    require(
        isinstance(metal, dict)
        and set(metal)
        == {
            "compile",
            "languageStandard",
            "link",
            "optimizationLevel",
            "outputSetIdentitySHA256",
            "sourceSetIdentitySHA256",
            "sources",
            "symbols",
            "targetTriple",
            "toolSetIdentitySHA256",
        }
        and metal.get("targetTriple") == METAL_TARGET_TRIPLE
        and metal.get("languageStandard") == METAL_LANGUAGE_STANDARD
        and metal.get("optimizationLevel") == METAL_OPTIMIZATION_LEVEL
        and metal.get("toolSetIdentitySHA256")
        == toolchain["metal"]["identitySHA256"],
        "clean-source deterministic Metal receipt has an unsupported shape",
    )
    sources = metal.get("sources")
    require(
        isinstance(sources, list) and len(sources) == len(METAL_SOURCE_SPECS),
        "clean-source deterministic Metal source set is invalid",
    )
    for source, (expected_path, expected_air) in zip(
        sources,
        METAL_SOURCE_SPECS,
    ):
        require(
            isinstance(source, dict)
            and set(source)
            == {
                "airOutput",
                "byteCount",
                "gitMode",
                "repositoryRelativePath",
                "sha256",
            }
            and source.get("airOutput") == expected_air
            and source.get("repositoryRelativePath") == expected_path
            and source.get("gitMode") == "100644"
            and isinstance(source.get("byteCount"), int)
            and source["byteCount"] > 0,
            "clean-source deterministic Metal source descriptor is invalid",
        )
        require_hex(
            source.get("sha256"),
            (64,),
            f"clean-source Metal input {expected_path}",
        )
    require(
        metal.get("sourceSetIdentitySHA256")
        == sha256_bytes(METAL_SOURCE_SET_DOMAIN + canonical_bytes(sources)),
        "clean-source deterministic Metal source-set identity differs",
    )
    compile_records = metal.get("compile")
    require(
        isinstance(compile_records, list)
        and len(compile_records) == len(sources),
        "clean-source deterministic Metal compile records are invalid",
    )
    outputs: list[dict[str, Any]] = []
    for record, source in zip(compile_records, sources):
        require(
            isinstance(record, dict)
            and set(record)
            == {
                "command",
                "commandSHA256",
                "exitStatus",
                "normalizedTranscriptSHA256",
                "output",
                "sourceRepositoryRelativePath",
            }
            and record.get("exitStatus") == 0
            and record.get("sourceRepositoryRelativePath")
            == source["repositoryRelativePath"],
            "clean-source deterministic Metal compile record is invalid",
        )
        command = metal_compile_command_template(source)
        require(
            record.get("command") == command
            and record.get("commandSHA256")
            == sha256_bytes(canonical_bytes(command)),
            "clean-source deterministic Metal compile command differs",
        )
        require_hex(
            record.get("normalizedTranscriptSHA256"),
            (64,),
            "clean-source deterministic Metal compile transcript",
        )
        outputs.append(
            _validate_metal_output_descriptor(
                record.get("output"),
                f"$METAL_INTERMEDIATES/{source['airOutput']}",
                "clean-source deterministic AIR output",
            )
        )
    link = metal.get("link")
    require(
        isinstance(link, dict)
        and set(link)
        == {
            "command",
            "commandSHA256",
            "exitStatus",
            "normalizedTranscriptSHA256",
            "output",
        }
        and link.get("exitStatus") == 0,
        "clean-source deterministic Metal link record is invalid",
    )
    link_command = metal_link_command_template(sources)
    require(
        link.get("command") == link_command
        and link.get("commandSHA256")
        == sha256_bytes(canonical_bytes(link_command)),
        "clean-source deterministic Metal link command differs",
    )
    require_hex(
        link.get("normalizedTranscriptSHA256"),
        (64,),
        "clean-source deterministic Metal link transcript",
    )
    library = _validate_metal_output_descriptor(
        link.get("output"),
        DEFAULT_METAL_LIBRARY_RELATIVE_PATH,
        "clean-source default Metal library",
    )
    require(
        library == application.get("defaultMetalLibrary"),
        "clean-source Metal output differs from the signed application",
    )
    outputs.append(library)
    require(
        metal.get("outputSetIdentitySHA256")
        == sha256_bytes(METAL_OUTPUT_SET_DOMAIN + canonical_bytes(outputs)),
        "clean-source deterministic Metal output-set identity differs",
    )
    symbols = metal.get("symbols")
    symbol_command = metal_symbol_command_template()
    expected_symbols = sorted(EXPECTED_METAL_SYMBOLS)
    require(
        isinstance(symbols, dict)
        and set(symbols)
        == {"command", "commandSHA256", "inventory", "inventorySHA256"}
        and symbols.get("command") == symbol_command
        and symbols.get("commandSHA256")
        == sha256_bytes(canonical_bytes(symbol_command))
        and symbols.get("inventory") == expected_symbols
        and symbols.get("inventorySHA256")
        == sha256_bytes(
            METAL_SYMBOL_SET_DOMAIN + canonical_bytes(expected_symbols)
        ),
        "clean-source deterministic Metal symbol inventory differs",
    )
    signing = value.get("signing")
    require(
        isinstance(signing, dict)
        and set(signing)
        == {
            "command",
            "commandSHA256",
            "entitlements",
            "exitStatus",
            "normalizedTranscriptSHA256",
            "observed",
            "policy",
        }
        and signing.get("exitStatus") == 0,
        "clean-source post-build signing record is invalid",
    )
    signing_command = post_build_signing_command_template()
    require(
        signing.get("command") == signing_command
        and signing.get("commandSHA256")
        == sha256_bytes(canonical_bytes(signing_command)),
        "clean-source post-build signing command differs",
    )
    require_hex(
        signing.get("normalizedTranscriptSHA256"),
        (64,),
        "clean-source post-build signing transcript",
    )
    entitlements = signing.get("entitlements")
    require(
        isinstance(entitlements, dict)
        and set(entitlements)
        == {
            "byteCount",
            "normalizedSHA256",
            "repositoryRelativePath",
            "sha256",
        }
        and isinstance(entitlements.get("byteCount"), int)
        and entitlements["byteCount"] > 0
        and entitlements.get("repositoryRelativePath")
        == METAL_ENTITLEMENTS_REPOSITORY_PATH
        and entitlements.get("normalizedSHA256")
        == application.get("entitlementsSHA256"),
        "clean-source post-build entitlements descriptor differs",
    )
    require_hex(
        entitlements.get("normalizedSHA256"),
        (64,),
        "clean-source normalized entitlements",
    )
    require_hex(
        entitlements.get("sha256"),
        (64,),
        "clean-source entitlements file",
    )
    require(
        signing.get("policy")
        == {
            "bundleIdentifier": CLEAN_BUILD_BUNDLE_IDENTIFIER,
            "generateDEREntitlements": True,
            "hardenedRuntime": True,
            "identity": "-",
            "mode": "ad-hoc",
            "timestamp": "none",
        },
        "clean-source post-build signing policy differs",
    )
    require(
        signing.get("observed")
        == {
            "codeDirectoryPolicyFlags": application[
                "codeDirectoryPolicyFlags"
            ],
            "codeIdentifier": application["codeIdentifier"],
            "entitlementsByArchitecture": application[
                "entitlementsByArchitecture"
            ],
            "entitlementsSHA256": application["entitlementsSHA256"],
        },
        "clean-source post-build signing observation differs",
    )
    require(
        application.get("codeDirectoryPolicyFlags")
        == [
            {
                "architecture": architecture,
                "flags": f"0x{HARDENED_RUNTIME_CODE_DIRECTORY_FLAGS:08x}",
            }
            for architecture in sorted(EXPECTED_APPLICATION_ARCHITECTURES)
        ],
        "clean-source application lacks the locked hardened-runtime signature policy",
    )
    return value


def _validate_swift_driver_wrapper_receipt(
    value: Any,
    swiftc: Mapping[str, Any],
) -> dict[str, Any]:
    require(
        isinstance(value, dict)
        and set(value)
        == {
            "auditPath",
            "identitySHA256",
            "interpreter",
            "path",
            "policy",
            "schemaVersion",
            "sha256",
            "underlyingSwiftc",
            "unixMode",
        }
        and value.get("schemaVersion") == SWIFT_DRIVER_WRAPPER_SCHEMA
        and value.get("path")
        == canonical_clean_build_layout()["swiftDriverWrapper"]
        and value.get("auditPath")
        == canonical_clean_build_layout()["swiftDriverJobAudit"]
        and value.get("unixMode") == 0o755
        and value.get("underlyingSwiftc") == swiftc
        and value.get("policy")
        == {
            "effectiveJobArguments": ["-j", "1"],
            "effectiveJobArgumentsAreTerminal": True,
            "effectiveLLVMRNGSeedArguments": ["-Xllvm", "-rng-seed=1"],
            "effectiveNumThreadsArguments": ["-num-threads", "1"],
            "projectedFrontendJobCountPerInvocation": 1,
            "projectedLLVMRNGSeedArguments": ["-Xllvm", "-rng-seed=1"],
            "projectedNumThreadsArguments": ["-num-threads", "1"],
            "rejectMissingDuplicateOrSubstitutedControls": True,
            "underlyingArgv0": "swiftc",
            "rejectMalformedJobArguments": True,
            "removeEveryPriorJobArgument": True,
            "requiredTargets": list(SWIFT_DRIVER_REQUIRED_TARGETS),
        },
        "clean-source Swift driver wrapper descriptor is invalid",
    )
    interpreter = value.get("interpreter")
    require(
        isinstance(interpreter, dict)
        and set(interpreter) == {"path", "sha256", "version"}
        and interpreter.get("path") == "/bin/zsh"
        and isinstance(interpreter.get("version"), list)
        and interpreter["version"]
        and all(isinstance(item, str) and item for item in interpreter["version"]),
        "clean-source Swift driver wrapper interpreter is invalid",
    )
    require_hex(
        interpreter.get("sha256"),
        (64,),
        "clean-source Swift driver wrapper interpreter",
    )
    expected_raw = swift_driver_wrapper_bytes(
        Path(swiftc["path"]),
        Path(value["auditPath"]),
    )
    require(
        value.get("sha256") == sha256_bytes(expected_raw),
        "clean-source Swift driver wrapper bytes differ from policy",
    )
    records = {key: item for key, item in value.items() if key != "identitySHA256"}
    require(
        value.get("identitySHA256")
        == sha256_bytes(SWIFT_DRIVER_WRAPPER_DOMAIN + canonical_bytes(records)),
        "clean-source Swift driver wrapper identity differs",
    )
    return value


def _validate_swift_driver_job_audit(value: Any) -> dict[str, Any]:
    require(
        isinstance(value, dict)
        and set(value)
        == {
            "byteCount",
            "effectiveJobArguments",
            "effectiveJobArgumentsAreTerminal",
            "effectiveLLVMRNGSeedArguments",
            "effectiveNumThreadsArguments",
            "identitySHA256",
            "invocationCount",
            "markers",
            "path",
            "projectedFrontendJobCountPerInvocation",
            "projectedLLVMRNGSeedArguments",
            "projectedNumThreadsArguments",
            "requiredTargets",
            "schemaVersion",
            "sha256",
        }
        and value.get("schemaVersion") == SWIFT_DRIVER_JOB_AUDIT_SCHEMA
        and value.get("path")
        == canonical_clean_build_layout()["swiftDriverJobAudit"]
        and value.get("markers")
        == sorted(SWIFT_DRIVER_JOB_AUDIT_MARKERS)
        and value.get("requiredTargets")
        == list(SWIFT_DRIVER_REQUIRED_TARGETS)
        and value.get("effectiveJobArguments") == ["-j", "1"]
        and value.get("effectiveJobArgumentsAreTerminal") is True
        and value.get("effectiveNumThreadsArguments")
        == ["-num-threads", "1"]
        and value.get("effectiveLLVMRNGSeedArguments")
        == ["-Xllvm", "-rng-seed=1"]
        and value.get("projectedFrontendJobCountPerInvocation") == 1
        and value.get("projectedNumThreadsArguments")
        == ["-num-threads", "1"]
        and value.get("projectedLLVMRNGSeedArguments")
        == ["-Xllvm", "-rng-seed=1"]
        and isinstance(value.get("invocationCount"), int)
        and value["invocationCount"] == len(SWIFT_DRIVER_REQUIRED_TARGETS),
        "clean-source Swift driver job audit is invalid",
    )
    expected_raw = (
        "\n".join(sorted(SWIFT_DRIVER_JOB_AUDIT_MARKERS)) + "\n"
    ).encode("utf-8")
    require(
        value.get("byteCount") == len(expected_raw)
        and value.get("sha256") == sha256_bytes(expected_raw),
        "clean-source Swift driver job-audit bytes differ",
    )
    records = {key: item for key, item in value.items() if key != "identitySHA256"}
    require(
        value.get("identitySHA256")
        == sha256_bytes(SWIFT_DRIVER_JOB_AUDIT_DOMAIN + canonical_bytes(records)),
        "clean-source Swift driver job-audit identity differs",
    )
    return value


def validate_clean_build_receipt(
    value: Any,
    context: Mapping[str, str],
    candidate_application: Mapping[str, Any],
) -> dict[str, Any]:
    require(isinstance(value, dict), "clean-source build receipt is not an object")
    require(
        set(value) == {
            "application",
            "build",
            "cleanSource",
            "postBuild",
            "schemaVersion",
            "toolchain",
        }
        and value.get("schemaVersion") == CLEAN_BUILD_RECEIPT_SCHEMA,
        "clean-source build receipt has an unsupported shape",
    )
    application = value.get("application")
    require(
        isinstance(application, dict)
        and application == source_build_application_identity(candidate_application),
        "clean-source build receipt identifies another application",
    )
    clean_source = value.get("cleanSource")
    require(
        isinstance(clean_source, dict)
        and set(clean_source)
        == {
            "commit",
            "environment",
            "exportCommand",
            "exportCommandSHA256",
            "manifest",
            "treeIdentitySHA256",
        }
        and clean_source.get("commit") == context["sourceCommit"]
        and clean_source.get("treeIdentitySHA256")
        == context["sourceTreeIdentitySHA256"],
        "clean-source build receipt identifies another source tree",
    )
    export_command = clean_source_export_command(
        context["sourceCommit"],
        "$CLEAN_SOURCE_TAR",
    )
    require(
        clean_source.get("environment") == git_environment()
        and clean_source.get("exportCommand") == export_command
        and clean_source.get("exportCommandSHA256")
        == sha256_bytes(canonical_bytes(export_command)),
        "clean-source export command or environment is not locked",
    )
    manifest = clean_source.get("manifest")
    require(
        isinstance(manifest, dict)
        and set(manifest)
        == {
            "entryCount",
            "identitySHA256",
            "schemaVersion",
            "totalByteCount",
        }
        and manifest.get("schemaVersion") == CLEAN_SOURCE_MANIFEST_SCHEMA
        and isinstance(manifest.get("entryCount"), int)
        and manifest["entryCount"] > 0
        and isinstance(manifest.get("totalByteCount"), int)
        and manifest["totalByteCount"] > 0,
        "clean-source build manifest has an unsupported shape",
    )
    require_hex(
        manifest.get("identitySHA256"),
        (64,),
        "clean-source manifest identity",
    )
    toolchain = value.get("toolchain")
    require(
        isinstance(toolchain, dict)
        and set(toolchain)
        == {
            "clang",
            "codesign",
            "developerDirectory",
            "git",
            "lipo",
            "macOSSDK",
            "metal",
            "swiftc",
            "swiftDriverWrapper",
            "xcodebuild",
        },
        "clean-source build toolchain has an unsupported shape",
    )
    require(
        isinstance(toolchain.get("developerDirectory"), str)
        and toolchain["developerDirectory"].startswith("/"),
        "clean-source build developer directory is invalid",
    )
    for name in ("clang", "codesign", "git", "lipo", "swiftc", "xcodebuild"):
        descriptor = toolchain.get(name)
        require(
            isinstance(descriptor, dict)
            and set(descriptor) == {"path", "sha256", "version"}
            and isinstance(descriptor.get("path"), str)
            and descriptor["path"].startswith("/")
            and isinstance(descriptor.get("version"), list)
            and descriptor["version"]
            and all(isinstance(item, str) and item for item in descriptor["version"]),
            f"clean-source build {name} descriptor is invalid",
        )
        require_hex(descriptor.get("sha256"), (64,), f"clean-source build {name}")
    _validate_metal_toolchain_receipt(toolchain.get("metal"))
    _validate_swift_driver_wrapper_receipt(
        toolchain.get("swiftDriverWrapper"),
        toolchain["swiftc"],
    )
    sdk = toolchain.get("macOSSDK")
    require(
        isinstance(sdk, dict)
        and set(sdk)
        == {"path", "settingsJSONSHA256", "settingsPlistSHA256", "version"}
        and isinstance(sdk.get("path"), str)
        and sdk["path"].startswith("/")
        and isinstance(sdk.get("version"), str)
        and sdk["version"],
        "clean-source build SDK descriptor is invalid",
    )
    require_hex(
        sdk.get("settingsJSONSHA256"),
        (64,),
        "clean-source build SDKSettings.json",
    )
    require_hex(
        sdk.get("settingsPlistSHA256"),
        (64,),
        "clean-source build SDKSettings.plist",
    )
    build = value.get("build")
    require(isinstance(build, dict), "clean-source build invocation is not an object")
    require(
        set(build)
        == {
            "canonicalLayout",
            "command",
            "commandSHA256",
            "configuration",
            "destination",
            "environment",
            "exitStatus",
            "normalizedTranscriptSHA256",
            "project",
            "provenanceXCConfigSHA256",
            "scheme",
            "settings",
            "swiftDriverJobAudit",
        }
        and build.get("configuration") == CLEAN_BUILD_CONFIGURATION
        and build.get("destination") == CLEAN_BUILD_DESTINATION
        and build.get("exitStatus") == 0
        and build.get("project") == CLEAN_BUILD_PROJECT
        and build.get("scheme") == CLEAN_BUILD_SCHEME,
        "clean-source build invocation has an unsupported shape",
    )
    require(
        build.get("canonicalLayout") == canonical_clean_build_layout(),
        "clean-source build does not use the canonical physical layout",
    )
    settings_value = build.get("settings")
    require(isinstance(settings_value, dict), "clean-source build settings are not an object")
    settings = normalize_clean_build_settings(settings_value)
    require(settings == settings_value, "clean-source build settings are not canonical")
    command = clean_build_command_template(toolchain, settings)
    require(
        build.get("command") == command
        and build.get("commandSHA256") == sha256_bytes(canonical_bytes(command)),
        "clean-source xcodebuild command differs from the locked invocation",
    )
    build_environment = build.get("environment")
    require(
        isinstance(build_environment, dict)
        and set(build_environment)
        == {
            "CFFIXED_USER_HOME",
            "DEVELOPER_DIR",
            "HOME",
            "LANG",
            "LC_ALL",
            "PATH",
            "SWIFT_DETERMINISTIC_HASHING",
            "SWIFTC_MAXIMUM_DETERMINISM",
            "TMPDIR",
        }
        and build_environment.get("DEVELOPER_DIR")
        == toolchain["developerDirectory"]
        and build_environment.get("CFFIXED_USER_HOME")
        == canonical_clean_build_layout()["homeDirectory"]
        and build_environment.get("HOME")
        == canonical_clean_build_layout()["homeDirectory"]
        and build_environment.get("LANG") == "C"
        and build_environment.get("LC_ALL") == "C"
        and build_environment.get("PATH") == "/usr/bin:/bin:/usr/sbin:/sbin"
        and build_environment.get("SWIFT_DETERMINISTIC_HASHING") == "1"
        and build_environment.get("SWIFTC_MAXIMUM_DETERMINISM") == "1"
        and build_environment.get("TMPDIR")
        == canonical_clean_build_layout()["temporaryDirectory"],
        "clean-source xcodebuild environment differs from the locked environment",
    )
    for key in (
        "normalizedTranscriptSHA256",
        "provenanceXCConfigSHA256",
    ):
        require_hex(build.get(key), (64,), f"clean-source build {key}")
    _validate_swift_driver_job_audit(build.get("swiftDriverJobAudit"))
    validate_post_build_receipt(
        value.get("postBuild"),
        toolchain,
        application,
    )
    return value


def _tool_set_identity(tools: Sequence[Mapping[str, Any]]) -> str:
    return sha256_bytes(TOOL_SET_DOMAIN + canonical_bytes(list(tools)))


def _application_attestation_record(
    *,
    context: Mapping[str, str],
    entries: Sequence[ArchiveEntry],
    application_root: str,
    info_plist_path: str,
    info_plist_sha256: str,
    claims: Mapping[str, str],
    executable_path: str,
    signing: Mapping[str, Any],
    bundle_identity: Mapping[str, str],
) -> dict[str, Any]:
    return {
        "bundleIdentifier": bundle_identity["bundleIdentifier"],
        "bundleRoot": application_root,
        "codeDirectories": signing["codeDirectories"],
        "codeDirectorySetSHA256": signing["codeDirectorySetSHA256"],
        "codeDirectoryPolicyFlags": signing["codeDirectoryPolicyFlags"],
        "codeIdentifier": signing["codeIdentifier"],
        "designatedRequirement": signing["designatedRequirement"],
        "designatedRequirementSHA256": signing["designatedRequirementSHA256"],
        "designatedRequirements": signing["designatedRequirements"],
        "defaultMetalLibrary": _default_metal_library_from_archive(
            entries,
            application_root,
        ),
        "embeddedClaimSetSHA256": sha256_bytes(
            CLAIM_SET_DOMAIN + canonical_bytes(dict(claims))
        ),
        "entitlementsByArchitecture": signing["entitlementsByArchitecture"],
        "entitlementsSHA256": signing["entitlementsSHA256"],
        "executablePath": executable_path,
        "executableSHA256": signing["executableSHA256"],
        "executableUnixMode": signing["executableUnixMode"],
        "unsignedExecutableSHA256": signing["unsignedExecutableSHA256"],
        "unsignedExecutableSlices": signing["unsignedExecutableSlices"],
        "infoPlistPath": info_plist_path,
        "infoPlistSHA256": info_plist_sha256,
        "productBuild": bundle_identity["productBuild"],
        "productVersion": bundle_identity["productVersion"],
        "reproducibleBundleContent": _reproducible_bundle_from_archive(
            entries,
            application_root,
            executable_path,
        ),
        "runtime": {
            key: context[key]
            for key in (
                "runtimeManifestSHA256",
                "runtimeManifestFileSHA256",
                "runtimeArtifactSetSHA256",
                "runtimeSourceRevision",
            )
        },
    }


def _expected_attestation(
    *,
    context: Mapping[str, str],
    tools: Sequence[Mapping[str, Any]],
    entries: Sequence[ArchiveEntry],
    application_root: str,
    info_plist_path: str,
    info_plist_sha256: str,
    claims: Mapping[str, str],
    executable_path: str,
    signing: Mapping[str, Any],
    bundle_identity: Mapping[str, str],
    source_build_receipt: Mapping[str, Any],
) -> dict[str, Any]:
    return {
        "application": _application_attestation_record(
            context=context,
            entries=entries,
            application_root=application_root,
            info_plist_path=info_plist_path,
            info_plist_sha256=info_plist_sha256,
            claims=claims,
            executable_path=executable_path,
            signing=signing,
            bundle_identity=bundle_identity,
        ),
        "archivePayload": {
            "entryCount": len(payload_descriptors(entries)),
            "identitySHA256": payload_identity(entries),
        },
        "buildConfiguration": "Release",
        "hashAlgorithm": "sha256",
        "releaseConfiguration": {
            "repositoryRelativePath": context[
                "releaseConfigurationRepositoryRelativePath"
            ],
            "sha256": context["releaseConfigurationSHA256"],
        },
        "runtime": {
            "artifactSetSHA256": context["runtimeArtifactSetSHA256"],
            "bundleRepositoryRelativePath": context[
                "runtimeRepositoryRelativePath"
            ],
            "manifestFileSHA256": context["runtimeManifestFileSHA256"],
            "manifestSHA256": context["runtimeManifestSHA256"],
            "sourceRevision": context["runtimeSourceRevision"],
        },
        "schemaVersion": ATTESTATION_SCHEMA,
        "source": {
            "commit": context["sourceCommit"],
            "treeIdentitySHA256": context["sourceTreeIdentitySHA256"],
        },
        "sourceBuild": dict(source_build_receipt),
        "sourceBuildReceiptSHA256": sha256_bytes(
            CLEAN_BUILD_RECEIPT_DOMAIN + canonical_bytes(dict(source_build_receipt))
        ),
        "tools": list(tools),
        "toolSetIdentitySHA256": _tool_set_identity(tools),
    }


def _inspect_archive_snapshot(
    archive_snapshot: Any,
    archive_sha256: str,
    context: Mapping[str, str],
    tools: Sequence[Mapping[str, Any]],
    *,
    require_attestation: bool,
    verify_source_build: bool = False,
    source_build_runner: CleanBuildRunner | None = None,
    clean_build_settings: Mapping[str, str] | None = None,
    supplied_source_build_receipt: Mapping[str, Any] | None = None,
) -> dict[str, Any]:
    """Inspect the exact bytes in one held archive snapshot."""

    archive_snapshot.seek(0)
    try:
        with zipfile.ZipFile(archive_snapshot) as value:
            entries = inspect_entries(value)
            attestation_entries = [entry for entry in entries if entry.path == ATTESTATION_PATH]
            require(
                len(attestation_entries) == (1 if require_attestation else 0),
                "application archive attestation is missing or repeated"
                if require_attestation
                else "unsealed application archive already contains an attestation",
            )
            application_root = _application_root(entries)
            info_plist_path = f"{application_root}/Contents/Info.plist"
            raw_plist = _read_control_file(value, entries, info_plist_path)
            try:
                plist = plistlib.loads(raw_plist)
            except plistlib.InvalidFileException as error:
                raise ArchiveProvenanceError(f"cannot decode application Info.plist: {error}") from error
            require(isinstance(plist, dict), "application Info.plist is not a dictionary")
            claims = claims_from_plist(plist)
            require(claims == expected_claims(context), "signed application build claims differ from release inputs")
            archived_runtime = _runtime_identity_from_archive(value, entries, application_root)
            expected_runtime = {
                key: context[key]
                for key in (
                    "runtimeManifestSHA256",
                    "runtimeManifestFileSHA256",
                    "runtimeArtifactSetSHA256",
                    "runtimeSourceRevision",
                )
            }
            require(archived_runtime == expected_runtime, "application embeds another P06 runtime")

            executable_name = plist.get("CFBundleExecutable")
            require(
                isinstance(executable_name, str)
                and executable_name
                and "/" not in executable_name
                and "\\" not in executable_name,
                "application Info.plist has an invalid CFBundleExecutable",
            )
            executable_path = f"{application_root}/Contents/MacOS/{executable_name}"
            _entry_by_path(entries, executable_path)
            bundle_keys = {
                "bundleIdentifier": "CFBundleIdentifier",
                "productVersion": "CFBundleShortVersionString",
                "productBuild": "CFBundleVersion",
            }
            bundle_identity: dict[str, str] = {}
            for output_key, plist_key in bundle_keys.items():
                item = plist.get(plist_key)
                require(isinstance(item, str) and item.strip(), f"application Info.plist omits {plist_key}")
                bundle_identity[output_key] = item

            with tempfile.TemporaryDirectory(prefix="mirmir-v4-candidate-app-") as temporary:
                extraction_root = Path(temporary)
                _extract_payload(value, entries, extraction_root)
                application = extraction_root / application_root
                executable = extraction_root.joinpath(*PurePosixPath(executable_path).parts)
                signing = _signing_identity(application, executable)
            require(
                signing["codeIdentifier"] == bundle_identity["bundleIdentifier"],
                "application signing identifier differs from its bundle identifier",
            )

            candidate_application = _application_attestation_record(
                context=context,
                entries=entries,
                application_root=application_root,
                info_plist_path=info_plist_path,
                info_plist_sha256=sha256_bytes(raw_plist),
                claims=claims,
                executable_path=executable_path,
                signing=signing,
                bundle_identity=bundle_identity,
            )
            runner = source_build_runner or clean_source_build
            if require_attestation:
                require(
                    supplied_source_build_receipt is None,
                    "a source-build receipt cannot replace a sealed attestation receipt",
                )
                raw_attestation = _read_control_file(value, entries, ATTESTATION_PATH)
                observed = load_json_bytes(raw_attestation, "release build attestation")
                require(isinstance(observed, dict), "release build attestation is not an object")
                require(
                    raw_attestation == canonical_bytes(observed),
                    "release build attestation is not canonical JSON",
                )
                source_build_receipt = validate_clean_build_receipt(
                    observed.get("sourceBuild"),
                    context,
                    candidate_application,
                )
                if verify_source_build:
                    reproduced_receipt = runner(
                        context,
                        candidate_application,
                        source_build_receipt["build"]["settings"],
                    )
                    validate_clean_build_receipt(
                        reproduced_receipt,
                        context,
                        candidate_application,
                    )
                    require(
                        reproduced_receipt == source_build_receipt,
                        "clean committed-source build receipt is not reproducible",
                    )
            else:
                require(
                    verify_source_build,
                    "an unsealed archive requires clean committed-source build verification",
                )
                require(
                    supplied_source_build_receipt is not None,
                    "an unsealed archive requires its original source-build receipt",
                )
                source_build_receipt = validate_clean_build_receipt(
                    supplied_source_build_receipt,
                    context,
                    candidate_application,
                )
                settings = normalize_clean_build_settings(
                    source_build_receipt["build"]["settings"]
                )
                require(
                    clean_build_settings is None
                    or normalize_clean_build_settings(clean_build_settings) == settings,
                    "sealing build settings differ from the original source-build receipt",
                )
                reproduced_receipt = runner(
                    context,
                    candidate_application,
                    settings,
                )
                validate_clean_build_receipt(
                    reproduced_receipt,
                    context,
                    candidate_application,
                )
                require(
                    reproduced_receipt == source_build_receipt,
                    "sealing replay differs from the original source-build receipt",
                )

            expected_attestation = _expected_attestation(
                context=context,
                tools=tools,
                entries=entries,
                application_root=application_root,
                info_plist_path=info_plist_path,
                info_plist_sha256=sha256_bytes(raw_plist),
                claims=claims,
                executable_path=executable_path,
                signing=signing,
                bundle_identity=bundle_identity,
                source_build_receipt=source_build_receipt,
            )
            if require_attestation:
                require(observed == expected_attestation, "release build attestation differs from archive provenance")
            else:
                raw_attestation = canonical_bytes(expected_attestation)
    except (OSError, zipfile.BadZipFile, RuntimeError) as error:
        if isinstance(error, ArchiveProvenanceError):
            raise
        raise ArchiveProvenanceError(f"cannot inspect application archive: {error}") from error
    return {
        **bundle_identity,
        "appBundleSHA256": archive_sha256,
        "attestation": expected_attestation,
        "attestationSHA256": sha256_bytes(raw_attestation),
    }


def inspect_archive(
    archive: Path,
    context: Mapping[str, str],
    tools: Sequence[Mapping[str, Any]],
    *,
    require_attestation: bool,
    verify_source_build: bool = False,
    source_build_runner: CleanBuildRunner | None = None,
    clean_build_settings: Mapping[str, str] | None = None,
    supplied_source_build_receipt: Mapping[str, Any] | None = None,
) -> dict[str, Any]:
    archive = archive.expanduser()
    require(
        archive.is_file() and not archive.is_symlink(),
        "application archive must be a regular non-symlink file",
    )
    archive = archive.resolve(strict=True)
    archive_snapshot, archive_sha256 = _snapshot_archive(archive)
    try:
        return _inspect_archive_snapshot(
            archive_snapshot,
            archive_sha256,
            context,
            tools,
            require_attestation=require_attestation,
            verify_source_build=verify_source_build,
            source_build_runner=source_build_runner,
            clean_build_settings=clean_build_settings,
            supplied_source_build_receipt=supplied_source_build_receipt,
        )
    finally:
        archive_snapshot.close()


def extract_verified_application(
    archive: Path,
    destination: Path,
    context: Mapping[str, str],
    tools: Sequence[Mapping[str, Any]],
) -> tuple[Path, Path, dict[str, Any]]:
    """Validate and safely extract the exact sealed app for an observer lane.

    The supplied destination must be an existing empty non-symlink directory.
    Signature and executable identities are checked again after extraction so a
    caller never observes bytes that were merely validated in an earlier temp
    directory.
    """

    archive = archive.expanduser()
    destination = destination.expanduser()
    require(
        archive.is_file() and not archive.is_symlink(),
        "application archive must be a regular non-symlink file",
    )
    require(
        destination.is_dir() and not destination.is_symlink(),
        "verified application destination must be a non-symlink directory",
    )
    require(
        next(destination.iterdir(), None) is None,
        "verified application destination must be empty",
    )
    archive = archive.resolve(strict=True)
    destination = destination.resolve(strict=True)
    archive_snapshot, archive_sha256 = _snapshot_archive(archive)
    try:
        inspection = _inspect_archive_snapshot(
            archive_snapshot,
            archive_sha256,
            context,
            tools,
            require_attestation=True,
        )
        archive_snapshot.seek(0)
        with zipfile.ZipFile(archive_snapshot) as value:
            entries = inspect_entries(value)
            require(
                payload_identity(entries)
                == inspection["attestation"]["archivePayload"]["identitySHA256"],
                "archive payload changed before verified extraction",
            )
            _extract_payload(value, entries, destination)
    except (OSError, zipfile.BadZipFile, RuntimeError) as error:
        if isinstance(error, ArchiveProvenanceError):
            raise
        raise ArchiveProvenanceError(
            f"cannot extract verified application archive: {error}"
        ) from error
    finally:
        archive_snapshot.close()

    application_record = inspection["attestation"]["application"]
    application = destination.joinpath(
        *PurePosixPath(application_record["bundleRoot"]).parts
    )
    executable = destination.joinpath(
        *PurePosixPath(application_record["executablePath"]).parts
    )
    observed_signing = _signing_identity(application, executable)
    for key in (
        "codeDirectories",
        "codeDirectorySetSHA256",
        "codeDirectoryPolicyFlags",
        "codeIdentifier",
        "designatedRequirement",
        "designatedRequirementSHA256",
        "designatedRequirements",
        "entitlementsByArchitecture",
        "entitlementsSHA256",
        "executableSHA256",
        "executableUnixMode",
        "unsignedExecutableSHA256",
        "unsignedExecutableSlices",
    ):
        require(
            observed_signing[key] == application_record[key],
            f"extracted application signing identity changed: {key}",
        )
    return application, executable, inspection


def seal_archive(
    input_archive: Path,
    output_archive: Path,
    context: Mapping[str, str],
    tools: Sequence[Mapping[str, Any]],
    *,
    source_build_receipt: Mapping[str, Any] | None = None,
    source_build_runner: CleanBuildRunner | None = None,
    clean_build_settings: Mapping[str, str] | None = None,
) -> dict[str, Any]:
    input_archive = input_archive.expanduser()
    target = publication_target(output_archive, "sealed application archive")
    output_archive = target.path
    require(
        input_archive.is_file() and not input_archive.is_symlink(),
        "input application archive must be a regular file",
    )
    input_archive = input_archive.resolve(strict=True)
    descriptor = zipfile.ZipInfo(ATTESTATION_PATH, date_time=(1980, 1, 1, 0, 0, 0))
    descriptor.create_system = 3
    descriptor.external_attr = (stat.S_IFREG | 0o644) << 16
    descriptor.compress_type = zipfile.ZIP_DEFLATED
    temporary_path: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(
            prefix=f".{output_archive.name}.",
            suffix=".tmp",
            dir=output_archive.parent,
            delete=False,
        ) as temporary:
            temporary_path = Path(temporary.name)
        shutil.copyfile(input_archive, temporary_path)
        inspection = inspect_archive(
            temporary_path,
            context,
            tools,
            require_attestation=False,
            verify_source_build=True,
            source_build_runner=source_build_runner,
            clean_build_settings=clean_build_settings,
            supplied_source_build_receipt=source_build_receipt,
        )
        with zipfile.ZipFile(temporary_path, "a") as output:
            output.writestr(descriptor, canonical_bytes(inspection["attestation"]))
        sealed = inspect_archive(
            temporary_path,
            context,
            tools,
            require_attestation=True,
        )
        _publish_no_clobber(
            temporary_path,
            target,
            "sealed application archive",
        )
        temporary_path = None
        return sealed
    finally:
        if temporary_path is not None:
            temporary_path.unlink(missing_ok=True)


def build_settings_text(
    context: Mapping[str, str],
    release_configuration: Path,
) -> str:
    path = str(release_configuration.expanduser().resolve(strict=True))
    require("\n" not in path and "\r" not in path, "Release configuration path contains a newline")
    quoted_path = path.replace("\\", "\\\\").replace('"', '\\"')
    values = expected_claims(context)
    settings = {
        **REPRODUCIBLE_SWIFT_BUILD_SETTINGS,
        "SWIFT_EXEC": canonical_clean_build_layout()["swiftDriverWrapper"],
        "MIRMIR_V4_BUILD_PROVENANCE_SCHEMA": values["schemaVersion"],
        "MIRMIR_V4_BUILD_CONFIGURATION": values["buildConfiguration"],
        "MIRMIR_V4_SOURCE_COMMIT": values["sourceCommit"],
        "MIRMIR_V4_SOURCE_TREE_IDENTITY_SHA256": values[
            "sourceTreeIdentitySHA256"
        ],
        "MIRMIR_V4_RELEASE_CONFIGURATION_SHA256": values[
            "releaseConfigurationSHA256"
        ],
        "MIRMIR_V4_RUNTIME_MANIFEST_SHA256": values["runtimeManifestSHA256"],
        "MIRMIR_V4_RUNTIME_MANIFEST_FILE_SHA256": values[
            "runtimeManifestFileSHA256"
        ],
        "MIRMIR_V4_RUNTIME_ARTIFACT_SET_SHA256": values[
            "runtimeArtifactSetSHA256"
        ],
        "MIRMIR_V4_RUNTIME_SOURCE_REVISION": values["runtimeSourceRevision"],
    }
    lines = [
        "// Generated deterministic-engine-v4 release provenance overlay.",
        f'#include "{quoted_path}"',
    ]
    lines.extend(f"{key} = {value}" for key, value in settings.items())
    return "\n".join(lines) + "\n"
