"""Apple H.264 common-writer bridge for active-row video-range NV12 frames."""

from __future__ import annotations

from dataclasses import dataclass
import copy
import hashlib
import json
import os
from pathlib import Path
import subprocess
import stat
import tempfile
from typing import Any, Callable, Mapping, Optional, Sequence, Tuple

import jsonschema

from .json_tools import read_json, validate_schema


QUALITY_ROOT = Path(__file__).resolve().parents[2]
SCHEMA_ROOT = QUALITY_ROOT / "schemas"
FIXTURE_SWIFT_ROOT = QUALITY_ROOT / "tools" / "actual_codec_fixture"
COMMON_WRITER_SWIFT_ROOT = QUALITY_ROOT / "tools" / "common_writer"
PRODUCTION_WRITER_SWIFT_ROOT = QUALITY_ROOT / "tools" / "production_writer"
PRODUCT_MEDIA_TYPES_PATH = (
    QUALITY_ROOT.parents[1] / "Mirmir" / "Modules" / "MediaPipeline" / "MediaTypes.swift"
)


@dataclass(frozen=True)
class RationalTime:
    value: int
    timescale: int = 600

    def as_json(self) -> Mapping[str, int]:
        return {"value": self.value, "timescale": self.timescale}


@dataclass(frozen=True)
class CommonWriterInputFrame:
    case_id: str
    nv12: bytes
    presentation_time: RationalTime
    duration: RationalTime


@dataclass(frozen=True)
class CommonWriterResult:
    report: Mapping[str, Any]
    decoded_frames: Tuple[bytes, ...]
    source_path: Path
    source_lock_path: Path
    encoded_path: Path
    report_path: Path
    decoded_directory: Path
    report_payload_sha256: Optional[str] = None
    source_payload_sha256: Optional[str] = None
    source_lock_sha256: Optional[str] = None
    encoded_payload_sha256: Optional[str] = None


@dataclass(frozen=True)
class IsolatedProductionWriterCaseResult:
    case_id: str
    result: CommonWriterResult


@dataclass(frozen=True)
class ProductionWriterAuthorizedExecution:
    """Retained executable/settings FDs plus a mandatory authorized runner."""

    executable_descriptor: int
    product_settings_source_descriptor: int
    run_process: Callable[
        [Sequence[str], int, Sequence[int]],
        subprocess.CompletedProcess[bytes],
    ]


class CommonWriterExecutionError(RuntimeError):
    """A native bridge failure with preserved evidence paths."""

    def __init__(
        self,
        message: str,
        *,
        failure_paths: Sequence[Path],
        stdout: str,
        stderr: str,
    ) -> None:
        super().__init__(message)
        self.failure_paths = tuple(failure_paths)
        self.stdout = stdout
        self.stderr = stderr


def _sha256(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def _sha256_path(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _active_hashes(frame: bytes, width: int, height: int) -> Mapping[str, str]:
    luma_size = width * height
    luma = frame[:luma_size]
    chroma = frame[luma_size:]
    return {
        "Y": _sha256(luma),
        "Cb": _sha256(chroma[0::2]),
        "Cr": _sha256(chroma[1::2]),
    }


def _write_new_bytes(path: Path, payload: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("xb") as handle:
        handle.write(payload)


def _write_new_json(path: Path, value: Mapping[str, Any]) -> None:
    encoded = json.dumps(
        value,
        ensure_ascii=False,
        allow_nan=False,
        sort_keys=True,
        indent=2,
    ).encode("utf-8") + b"\n"
    _write_new_bytes(path, encoded)


def _validate_frames(
    frames: Sequence[CommonWriterInputFrame],
    width: int,
    height: int,
) -> None:
    if width <= 0 or height <= 0 or width % 2 or height % 2:
        raise ValueError("common-writer dimensions must be positive even integers")
    if not frames:
        raise ValueError("common writer requires at least one frame")
    expected_size = width * height * 3 // 2
    case_ids = set()
    previous_time: Optional[RationalTime] = None
    for index, frame in enumerate(frames):
        if not frame.case_id or frame.case_id in case_ids:
            raise ValueError(f"frame {index} has an empty or duplicate case ID")
        case_ids.add(frame.case_id)
        if len(frame.nv12) != expected_size:
            raise ValueError(
                f"frame {index} has {len(frame.nv12)} bytes; expected {expected_size}"
            )
        if frame.presentation_time.timescale <= 0 or frame.presentation_time.value < 0:
            raise ValueError(f"frame {index} has invalid presentation timing")
        if frame.duration.timescale <= 0 or frame.duration.value <= 0:
            raise ValueError(f"frame {index} has invalid duration")
        if previous_time is not None:
            left = frame.presentation_time.value * previous_time.timescale
            right = previous_time.value * frame.presentation_time.timescale
            if left <= right:
                raise ValueError("frame presentation times must be strictly increasing")
        previous_time = frame.presentation_time


def write_common_writer_source(
    *,
    frames: Sequence[CommonWriterInputFrame],
    width: int,
    height: int,
    source_path: Path,
    source_lock_path: Path,
    source_id: str,
) -> Mapping[str, Any]:
    """Write a new byte-bound source payload and lock without replacing files."""

    if not source_id:
        raise ValueError("source_id must be nonempty")
    _validate_frames(frames, width, height)
    payload = b"".join(frame.nv12 for frame in frames)
    frame_records = []
    for index, frame in enumerate(frames):
        frame_records.append(
            {
                "case_id": frame.case_id,
                "index": index,
                "presentation_time": frame.presentation_time.as_json(),
                "duration": frame.duration.as_json(),
                "active_row_sha256": _active_hashes(frame.nv12, width, height),
                "frame_nv12_sha256": _sha256(frame.nv12),
            }
        )
    source_lock = {
        "schema_version": "1.0.0",
        "artifact_kind": "common_writer_source_lock",
        "source_id": source_id,
        "payload_path": source_path.name,
        "pixel_layout": {
            "pixel_format": "420v",
            "range": "video",
            "color_primaries": "ITU_R_709_2",
            "transfer_function": "ITU_R_709_2",
            "ycbcr_matrix": "ITU_R_709_2",
            "chroma_location_top_field": "Left",
            "chroma_location_bottom_field": "Left",
            "width": width,
            "height": height,
        },
        "frame_count": len(frames),
        "frames": frame_records,
        "payload_size_bytes": len(payload),
        "payload_sha256": _sha256(payload),
    }
    validate_schema(source_lock, SCHEMA_ROOT / "common-writer-source.schema.json")
    if source_path.exists() or source_lock_path.exists():
        raise FileExistsError("refusing to overwrite common-writer source or lock")
    _write_new_bytes(source_path, payload)
    _write_new_json(source_lock_path, source_lock)
    return source_lock


def compile_common_writer(executable: Path) -> Path:
    """Compile the bridge against the committed actual-codec media helpers."""

    if executable.exists():
        raise FileExistsError(f"refusing to overwrite executable {executable}")
    executable.parent.mkdir(parents=True, exist_ok=True)
    swift_sources = [
        FIXTURE_SWIFT_ROOT / "ActualCodecFixtureTypes.swift",
        FIXTURE_SWIFT_ROOT / "ActualCodecFixtureMedia.swift",
        FIXTURE_SWIFT_ROOT / "ActualCodecFixturePixelIO.swift",
        FIXTURE_SWIFT_ROOT / "ActualCodecFixtureProductRoute.swift",
        COMMON_WRITER_SWIFT_ROOT / "CommonWriterTypes.swift",
        COMMON_WRITER_SWIFT_ROOT / "CommonWriterMain.swift",
    ]
    command = [
        "/usr/bin/xcrun",
        "swiftc",
        "-parse-as-library",
        "-O",
        "-warnings-as-errors",
        *(str(path) for path in swift_sources),
        "-framework",
        "AVFoundation",
        "-framework",
        "CoreMedia",
        "-framework",
        "CoreVideo",
        "-framework",
        "CryptoKit",
        "-framework",
        "VideoToolbox",
        "-o",
        str(executable),
    ]
    subprocess.run(
        command,
        check=True,
        cwd=QUALITY_ROOT.parents[1],
        capture_output=True,
        text=True,
    )
    return executable


def compile_production_writer(executable: Path) -> Path:
    """Compile the HEVC bridge with the product's shared output settings source."""

    if executable.exists():
        raise FileExistsError(f"refusing to overwrite executable {executable}")
    executable.parent.mkdir(parents=True, exist_ok=True)
    swift_sources = [
        FIXTURE_SWIFT_ROOT / "ActualCodecFixtureTypes.swift",
        FIXTURE_SWIFT_ROOT / "ActualCodecFixtureMedia.swift",
        FIXTURE_SWIFT_ROOT / "ActualCodecFixturePixelIO.swift",
        FIXTURE_SWIFT_ROOT / "ActualCodecFixtureProductRoute.swift",
        COMMON_WRITER_SWIFT_ROOT / "CommonWriterTypes.swift",
        PRODUCT_MEDIA_TYPES_PATH,
        PRODUCTION_WRITER_SWIFT_ROOT / "ProductionWriterTypes.swift",
        PRODUCTION_WRITER_SWIFT_ROOT / "ProductionWriterMain.swift",
    ]
    command = [
        "/usr/bin/xcrun",
        "swiftc",
        "-parse-as-library",
        "-O",
        "-warnings-as-errors",
        *(str(path) for path in swift_sources),
        "-framework",
        "AVFoundation",
        "-framework",
        "CoreMedia",
        "-framework",
        "CoreVideo",
        "-framework",
        "CryptoKit",
        "-framework",
        "VideoToolbox",
        "-o",
        str(executable),
    ]
    subprocess.run(
        command,
        check=True,
        cwd=QUALITY_ROOT.parents[1],
        capture_output=True,
        text=True,
    )
    return executable


def _execute_locked_source(
    *,
    source_path: Path,
    source_lock_path: Path,
    output_directory: Path,
    output_name: str,
    executable: Path,
) -> CommonWriterResult:
    if not output_name or Path(output_name).name != output_name:
        raise ValueError("output_name must be a nonempty filename stem")
    source_lock = read_json(source_lock_path)
    validate_schema(source_lock, SCHEMA_ROOT / "common-writer-source.schema.json")
    output_directory.mkdir(parents=True, exist_ok=True)
    encoded_path = output_directory / f"{output_name}.mp4"
    report_path = output_directory / f"{output_name}-report.json"
    decoded_directory = output_directory / f"{output_name}-decoded"
    command = [
        str(executable),
        "--source",
        str(source_path),
        "--source-lock",
        str(source_lock_path),
        "--encoded",
        str(encoded_path),
        "--report",
        str(report_path),
        "--decoded-directory",
        str(decoded_directory),
    ]
    process = subprocess.run(
        command,
        cwd=QUALITY_ROOT.parents[1],
        capture_output=True,
        text=True,
    )
    if process.returncode != 0:
        failures = sorted(output_directory.glob(f"{output_name}-report.failed-*.json"))
        for failure_path in failures:
            validate_schema(
                read_json(failure_path),
                SCHEMA_ROOT / "common-writer-failure.schema.json",
            )
        raise CommonWriterExecutionError(
            f"common writer exited with status {process.returncode}",
            failure_paths=failures,
            stdout=process.stdout,
            stderr=process.stderr,
        )
    report = read_json(report_path)
    validate_schema(report, SCHEMA_ROOT / "common-writer.schema.json")
    if _sha256_path(source_path) != report["source"]["payload_sha256"]:
        raise ValueError("generated report source payload binding failed")
    if _sha256_path(source_lock_path) != report["source"]["source_lock_sha256"]:
        raise ValueError("generated report source-lock binding failed")
    if _sha256_path(encoded_path) != report["encoded"]["sha256"]:
        raise ValueError("generated report encoded-file binding failed")
    decoded_frames = []
    for frame in report["decoder"]["frames"]:
        path = decoded_directory / frame["payload_path"]
        payload = path.read_bytes()
        if (
            len(payload) != frame["payload_size_bytes"]
            or _sha256(payload) != frame["payload_sha256"]
        ):
            raise ValueError(f"decoded payload binding failed for frame {frame['index']}")
        decoded_frames.append(payload)
    return CommonWriterResult(
        report=report,
        decoded_frames=tuple(decoded_frames),
        source_path=source_path,
        source_lock_path=source_lock_path,
        encoded_path=encoded_path,
        report_path=report_path,
        decoded_directory=decoded_directory,
    )


def run_common_writer_locked(
    *,
    source_path: Path,
    source_lock_path: Path,
    output_directory: Path,
    output_name: str = "common-writer",
    executable: Optional[Path] = None,
) -> CommonWriterResult:
    """Run the native bridge for an existing source payload and source lock."""

    if executable is not None:
        return _execute_locked_source(
            source_path=source_path,
            source_lock_path=source_lock_path,
            output_directory=output_directory,
            output_name=output_name,
            executable=executable,
        )
    with tempfile.TemporaryDirectory(prefix="mirmir-common-writer-build-") as temporary:
        compiled = compile_common_writer(Path(temporary) / "common-writer")
        return _execute_locked_source(
            source_path=source_path,
            source_lock_path=source_lock_path,
            output_directory=output_directory,
            output_name=output_name,
            executable=compiled,
        )


def run_common_writer(
    *,
    frames: Sequence[CommonWriterInputFrame],
    width: int,
    height: int,
    output_directory: Path,
    source_id: str,
    output_name: str = "common-writer",
    executable: Optional[Path] = None,
) -> CommonWriterResult:
    """Lock, encode, reopen, decode, export, and verify an NV12 frame sequence."""

    output_directory.mkdir(parents=True, exist_ok=True)
    source_path = output_directory / f"{output_name}-source.nv12"
    source_lock_path = output_directory / f"{output_name}-source-lock.json"
    write_common_writer_source(
        frames=frames,
        width=width,
        height=height,
        source_path=source_path,
        source_lock_path=source_lock_path,
        source_id=source_id,
    )
    return run_common_writer_locked(
        source_path=source_path,
        source_lock_path=source_lock_path,
        output_directory=output_directory,
        output_name=output_name,
        executable=executable,
    )


def _descriptor_record(descriptor: int) -> Tuple[int, ...]:
    metadata = os.fstat(descriptor)
    return (
        metadata.st_dev,
        metadata.st_ino,
        metadata.st_mode,
        metadata.st_nlink,
        metadata.st_size,
        metadata.st_mtime_ns,
        metadata.st_ctime_ns,
    )


def _read_descriptor(descriptor: int) -> bytes:
    before = _descriptor_record(descriptor)
    if stat.S_IFMT(before[2]) != stat.S_IFREG or before[3] != 1:
        raise ValueError("retained writer descriptor is not singular regular data")
    os.lseek(descriptor, 0, os.SEEK_SET)
    chunks = []
    while True:
        try:
            chunk = os.read(descriptor, 1024 * 1024)
        except InterruptedError:
            continue
        if not chunk:
            break
        chunks.append(chunk)
    after = _descriptor_record(descriptor)
    os.lseek(descriptor, 0, os.SEEK_SET)
    if after != before:
        raise ValueError("retained writer descriptor changed while reading")
    return b"".join(chunks)


def _verify_descriptor_path(
    descriptor: int,
    path: Path,
    *,
    expected_record: Optional[Tuple[int, ...]] = None,
) -> None:
    opened = _descriptor_record(descriptor)
    linked = os.stat(path, follow_symlinks=False)
    if (
        stat.S_ISLNK(linked.st_mode)
        or (linked.st_dev, linked.st_ino) != (opened[0], opened[1])
        or (expected_record is not None and opened != expected_record)
    ):
        raise ValueError("retained writer descriptor/path identity differs")


def _validate_production_report(
    report: Mapping[str, Any],
    expected_dimensions: Optional[Tuple[int, int]],
) -> None:
    if expected_dimensions is None:
        validate_schema(report, SCHEMA_ROOT / "production-writer.schema.json")
        return
    width, height = expected_dimensions
    if width <= 0 or height <= 0 or width % 2 or height % 2:
        raise ValueError("P06 production-writer geometry must be positive and even")
    schema = copy.deepcopy(read_json(SCHEMA_ROOT / "production-writer.schema.json"))
    schema["$id"] = (
        "https://mirmir.local/validation/calibration-v2/"
        "p06-variable-geometry-production-writer-v1.schema.json"
    )
    definitions = schema["$defs"]
    definitions["pixelLayout"]["properties"]["width"] = {"const": width}
    definitions["pixelLayout"]["properties"]["height"] = {"const": height}
    definitions["encoded"]["properties"]["width"] = {"const": width}
    definitions["encoded"]["properties"]["height"] = {"const": height}
    definitions["decodedFrame"]["properties"]["width"] = {"const": width}
    definitions["decodedFrame"]["properties"]["height"] = {"const": height}
    definitions["decodedFrame"]["properties"]["payload_size_bytes"] = {
        "const": width * height * 3 // 2
    }
    validator = jsonschema.Draft202012Validator(
        schema,
        format_checker=jsonschema.FormatChecker(),
    )
    errors = sorted(
        validator.iter_errors(report),
        key=lambda error: list(error.absolute_path),
    )
    if errors:
        raise ValueError(
            "P06 variable-geometry production report validation failed: "
            + "; ".join(error.message for error in errors)
        )


def _run_production_writer_locked_authorized(
    *,
    source_path: Path,
    source_lock_path: Path,
    output_directory: Path,
    output_name: str,
    executable: Path,
    expected_dimensions: Optional[Tuple[int, int]],
    execution: ProductionWriterAuthorizedExecution,
) -> CommonWriterResult:
    if not output_name or Path(output_name).name != output_name:
        raise ValueError("output_name must be a nonempty filename stem")
    output_directory = output_directory.absolute()
    if source_path.parent.absolute() != output_directory or (
        source_lock_path.parent.absolute() != output_directory
    ):
        raise ValueError("authorized writer inputs must be inside its case directory")
    root_descriptor = os.open(
        output_directory,
        os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
    )
    descriptors = [root_descriptor]
    encoded_path = output_directory / f"{output_name}.mp4"
    report_path = output_directory / f"{output_name}-report.json"
    failure_path = output_directory / f"{output_name}-report.failed-authorized.json"
    decoded_directory = output_directory / f"{output_name}-decoded"
    staging_directory = output_directory / f".{output_name}-encoded-staging"
    try:
        root_metadata = os.fstat(root_descriptor)
        linked_root = os.stat(output_directory, follow_symlinks=False)
        if (
            not stat.S_ISDIR(root_metadata.st_mode)
            or stat.S_ISLNK(linked_root.st_mode)
            or (root_metadata.st_dev, root_metadata.st_ino)
            != (linked_root.st_dev, linked_root.st_ino)
        ):
            raise ValueError("authorized writer case directory identity differs")
        source_descriptor = os.open(
            source_path.name,
            os.O_RDONLY | os.O_NOFOLLOW,
            dir_fd=root_descriptor,
        )
        source_lock_descriptor = os.open(
            source_lock_path.name,
            os.O_RDONLY | os.O_NOFOLLOW,
            dir_fd=root_descriptor,
        )
        encoded_descriptor = os.open(
            encoded_path.name,
            os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
            0o600,
            dir_fd=root_descriptor,
        )
        report_descriptor = os.open(
            report_path.name,
            os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
            0o600,
            dir_fd=root_descriptor,
        )
        failure_descriptor = os.open(
            failure_path.name,
            os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
            0o600,
            dir_fd=root_descriptor,
        )
        os.mkdir(decoded_directory.name, 0o700, dir_fd=root_descriptor)
        decoded_descriptor = os.open(
            decoded_directory.name,
            os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
            dir_fd=root_descriptor,
        )
        os.mkdir(staging_directory.name, 0o700, dir_fd=root_descriptor)
        staging_descriptor = os.open(
            staging_directory.name,
            os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
            dir_fd=root_descriptor,
        )
        descriptors.extend(
            (
                source_descriptor,
                source_lock_descriptor,
                encoded_descriptor,
                report_descriptor,
                failure_descriptor,
                decoded_descriptor,
                staging_descriptor,
            )
        )
        fixed_descriptors = (
            execution.executable_descriptor,
            execution.product_settings_source_descriptor,
        )
        fixed_records = tuple(_descriptor_record(value) for value in fixed_descriptors)
        source_records = (
            _descriptor_record(source_descriptor),
            _descriptor_record(source_lock_descriptor),
        )
        for descriptor in fixed_descriptors:
            os.lseek(descriptor, 0, os.SEEK_SET)
        command = [
            str(executable),
            "--source",
            str(source_path),
            "--source-lock",
            str(source_lock_path),
            "--encoded",
            str(encoded_path),
            "--encoded-staging-directory",
            str(staging_directory),
            "--report",
            str(report_path),
            "--decoded-directory",
            str(decoded_directory),
            "--product-settings-source",
            str(PRODUCT_MEDIA_TYPES_PATH),
            "--failure-report",
            str(failure_path),
        ]
        roles = (
            ("source", source_descriptor),
            ("source-lock", source_lock_descriptor),
            ("encoded", encoded_descriptor),
            ("encoded-staging-directory", staging_descriptor),
            ("report", report_descriptor),
            ("failure-report", failure_descriptor),
            ("decoded-directory", decoded_descriptor),
            (
                "product-settings-source",
                execution.product_settings_source_descriptor,
            ),
        )
        for role, descriptor in roles:
            command.extend((f"--{role}-fd", str(descriptor)))
        pass_fds = tuple(
            dict.fromkeys(
                (
                    execution.executable_descriptor,
                    *(descriptor for _, descriptor in roles),
                )
            )
        )
        process = execution.run_process(command, root_descriptor, pass_fds)
        for descriptor, expected in zip(fixed_descriptors, fixed_records):
            if _descriptor_record(descriptor) != expected:
                raise ValueError("authorized writer fixed input changed")
            os.lseek(descriptor, 0, os.SEEK_SET)
        _verify_descriptor_path(
            execution.executable_descriptor,
            executable,
            expected_record=fixed_records[0],
        )
        _verify_descriptor_path(
            execution.product_settings_source_descriptor,
            PRODUCT_MEDIA_TYPES_PATH,
            expected_record=fixed_records[1],
        )
        _verify_descriptor_path(
            source_descriptor,
            source_path,
            expected_record=source_records[0],
        )
        _verify_descriptor_path(
            source_lock_descriptor,
            source_lock_path,
            expected_record=source_records[1],
        )
        stdout = process.stdout.decode("utf-8", "replace")
        stderr = process.stderr.decode("utf-8", "replace")
        if process.returncode != 0:
            failure_payload = _read_descriptor(failure_descriptor)
            failure_paths = ()
            if failure_payload:
                failure_document = json.loads(failure_payload)
                validate_schema(
                    failure_document,
                    SCHEMA_ROOT / "common-writer-failure.schema.json",
                )
                failure_paths = (failure_path,)
            raise CommonWriterExecutionError(
                f"production writer exited with status {process.returncode}",
                failure_paths=failure_paths,
                stdout=stdout,
                stderr=stderr,
            )
        report_payload = _read_descriptor(report_descriptor)
        report = json.loads(report_payload)
        if not isinstance(report, dict):
            raise ValueError("authorized production report is not an object")
        _validate_production_report(report, expected_dimensions)
        source_payload = _read_descriptor(source_descriptor)
        source_lock_payload = _read_descriptor(source_lock_descriptor)
        encoded_payload = _read_descriptor(encoded_descriptor)
        if _sha256(source_payload) != report["source"]["payload_sha256"]:
            raise ValueError("production report source payload binding failed")
        if _sha256(source_lock_payload) != report["source"]["source_lock_sha256"]:
            raise ValueError("production report source-lock binding failed")
        if _sha256(_read_descriptor(execution.product_settings_source_descriptor)) != report[
            "encoder"
        ]["product_settings_source"]["sha256"]:
            raise ValueError("production report shared-settings source binding failed")
        if _sha256(encoded_payload) != report["encoded"]["sha256"]:
            raise ValueError("production report encoded-file binding failed")
        decoded_frames = []
        for frame in report["decoder"]["frames"]:
            name = frame["payload_path"]
            if not isinstance(name, str) or Path(name).name != name:
                raise ValueError("production decoded payload path is invalid")
            descriptor = os.open(
                name,
                os.O_RDONLY | os.O_NOFOLLOW,
                dir_fd=decoded_descriptor,
            )
            try:
                payload = _read_descriptor(descriptor)
            finally:
                os.close(descriptor)
            if (
                len(payload) != frame["payload_size_bytes"]
                or _sha256(payload) != frame["payload_sha256"]
            ):
                raise ValueError(
                    f"production decoded payload binding failed for frame {frame['index']}"
                )
            decoded_frames.append(payload)
        if os.listdir(staging_descriptor):
            raise ValueError("authorized writer staging directory was not cleaned")
        staging_metadata = os.fstat(staging_descriptor)
        if (
            stat.S_IMODE(staging_metadata.st_mode) != 0o700
            or staging_metadata.st_flags & getattr(stat, "UF_IMMUTABLE", 0)
        ):
            raise ValueError("authorized writer staging state was not restored")
        if _descriptor_record(failure_descriptor)[4] != 0:
            raise ValueError("authorized writer failure endpoint is not empty")
        os.unlink(failure_path.name, dir_fd=root_descriptor)
        os.rmdir(staging_directory.name, dir_fd=root_descriptor)
        return CommonWriterResult(
            report=report,
            decoded_frames=tuple(decoded_frames),
            source_path=source_path,
            source_lock_path=source_lock_path,
            encoded_path=encoded_path,
            report_path=report_path,
            decoded_directory=decoded_directory,
            report_payload_sha256=_sha256(report_payload),
            source_payload_sha256=_sha256(source_payload),
            source_lock_sha256=_sha256(source_lock_payload),
            encoded_payload_sha256=_sha256(encoded_payload),
        )
    finally:
        for descriptor in reversed(descriptors):
            try:
                os.close(descriptor)
            except OSError:
                pass


def run_production_writer_locked(
    *,
    source_path: Path,
    source_lock_path: Path,
    output_directory: Path,
    output_name: str = "production-writer",
    executable: Path,
    expected_dimensions: Optional[Tuple[int, int]] = None,
    authorized_execution: Optional[ProductionWriterAuthorizedExecution] = None,
) -> CommonWriterResult:
    """Run the product-settings HEVC bridge for an existing locked source."""

    if authorized_execution is not None:
        return _run_production_writer_locked_authorized(
            source_path=source_path,
            source_lock_path=source_lock_path,
            output_directory=output_directory,
            output_name=output_name,
            executable=executable,
            expected_dimensions=expected_dimensions,
            execution=authorized_execution,
        )

    if not output_name or Path(output_name).name != output_name:
        raise ValueError("output_name must be a nonempty filename stem")
    source_lock = read_json(source_lock_path)
    validate_schema(source_lock, SCHEMA_ROOT / "common-writer-source.schema.json")
    output_directory.mkdir(parents=True, exist_ok=True)
    encoded_path = output_directory / f"{output_name}.mp4"
    report_path = output_directory / f"{output_name}-report.json"
    decoded_directory = output_directory / f"{output_name}-decoded"
    command = [
        str(executable),
        "--source",
        str(source_path),
        "--source-lock",
        str(source_lock_path),
        "--encoded",
        str(encoded_path),
        "--report",
        str(report_path),
        "--decoded-directory",
        str(decoded_directory),
        "--product-settings-source",
        str(PRODUCT_MEDIA_TYPES_PATH),
    ]
    process = subprocess.run(
        command,
        cwd=QUALITY_ROOT.parents[1],
        capture_output=True,
        text=True,
    )
    if process.returncode != 0:
        failures = sorted(output_directory.glob(f"{output_name}-report.failed-*.json"))
        for failure_path in failures:
            validate_schema(
                read_json(failure_path),
                SCHEMA_ROOT / "common-writer-failure.schema.json",
            )
        raise CommonWriterExecutionError(
            f"production writer exited with status {process.returncode}",
            failure_paths=failures,
            stdout=process.stdout,
            stderr=process.stderr,
        )
    report = read_json(report_path)
    if expected_dimensions is None:
        validate_schema(report, SCHEMA_ROOT / "production-writer.schema.json")
    else:
        width, height = expected_dimensions
        if width <= 0 or height <= 0 or width % 2 or height % 2:
            raise ValueError("P06 production-writer geometry must be positive and even")
        schema = copy.deepcopy(
            read_json(SCHEMA_ROOT / "production-writer.schema.json")
        )
        schema["$id"] = (
            "https://mirmir.local/validation/calibration-v2/"
            "p06-variable-geometry-production-writer-v1.schema.json"
        )
        definitions = schema["$defs"]
        definitions["pixelLayout"]["properties"]["width"] = {"const": width}
        definitions["pixelLayout"]["properties"]["height"] = {"const": height}
        definitions["encoded"]["properties"]["width"] = {"const": width}
        definitions["encoded"]["properties"]["height"] = {"const": height}
        definitions["decodedFrame"]["properties"]["width"] = {"const": width}
        definitions["decodedFrame"]["properties"]["height"] = {"const": height}
        definitions["decodedFrame"]["properties"]["payload_size_bytes"] = {
            "const": width * height * 3 // 2
        }
        validator = jsonschema.Draft202012Validator(
            schema,
            format_checker=jsonschema.FormatChecker(),
        )
        errors = sorted(
            validator.iter_errors(report),
            key=lambda error: list(error.absolute_path),
        )
        if errors:
            raise ValueError(
                "P06 variable-geometry production report validation failed: "
                + "; ".join(error.message for error in errors)
            )
    if _sha256_path(source_path) != report["source"]["payload_sha256"]:
        raise ValueError("production report source payload binding failed")
    if _sha256_path(source_lock_path) != report["source"]["source_lock_sha256"]:
        raise ValueError("production report source-lock binding failed")
    if _sha256_path(PRODUCT_MEDIA_TYPES_PATH) != report["encoder"][
        "product_settings_source"
    ]["sha256"]:
        raise ValueError("production report shared-settings source binding failed")
    if _sha256_path(encoded_path) != report["encoded"]["sha256"]:
        raise ValueError("production report encoded-file binding failed")
    decoded_frames = []
    for frame in report["decoder"]["frames"]:
        path = decoded_directory / frame["payload_path"]
        payload = path.read_bytes()
        if (
            len(payload) != frame["payload_size_bytes"]
            or _sha256(payload) != frame["payload_sha256"]
        ):
            raise ValueError(
                f"production decoded payload binding failed for frame {frame['index']}"
            )
        decoded_frames.append(payload)
    return CommonWriterResult(
        report=report,
        decoded_frames=tuple(decoded_frames),
        source_path=source_path,
        source_lock_path=source_lock_path,
        encoded_path=encoded_path,
        report_path=report_path,
        decoded_directory=decoded_directory,
    )


def run_production_writer(
    *,
    frames: Sequence[CommonWriterInputFrame],
    width: int,
    height: int,
    output_directory: Path,
    source_id: str,
    output_name: str = "production-writer",
    executable: Path,
    expected_dimensions: Optional[Tuple[int, int]] = None,
    authorized_execution: Optional[ProductionWriterAuthorizedExecution] = None,
) -> CommonWriterResult:
    """Lock, HEVC encode with product settings, reopen, decode, and verify."""

    output_directory.mkdir(parents=True, exist_ok=True)
    source_path = output_directory / f"{output_name}-source.nv12"
    source_lock_path = output_directory / f"{output_name}-source-lock.json"
    write_common_writer_source(
        frames=frames,
        width=width,
        height=height,
        source_path=source_path,
        source_lock_path=source_lock_path,
        source_id=source_id,
    )
    return run_production_writer_locked(
        source_path=source_path,
        source_lock_path=source_lock_path,
        output_directory=output_directory,
        output_name=output_name,
        executable=executable,
        expected_dimensions=expected_dimensions,
        authorized_execution=authorized_execution,
    )


def run_isolated_production_writer_cases(
    *,
    frames: Sequence[CommonWriterInputFrame],
    width: int,
    height: int,
    output_directory: Path,
    source_id: str,
    executable: Path,
    expected_dimensions: Optional[Tuple[int, int]] = None,
    authorized_execution: Optional[ProductionWriterAuthorizedExecution] = None,
) -> Tuple[IsolatedProductionWriterCaseResult, ...]:
    """Encode every metric case in a separate one-frame product HEVC container."""

    if not source_id:
        raise ValueError("source_id must be nonempty")
    normalized_frames = tuple(
        CommonWriterInputFrame(
            case_id=frame.case_id,
            nv12=frame.nv12,
            presentation_time=RationalTime(position * 20, 600),
            duration=frame.duration,
        )
        for position, frame in enumerate(frames)
    )
    _validate_frames(normalized_frames, width, height)
    if output_directory.exists():
        raise FileExistsError(
            f"refusing to reuse isolated production output {output_directory}"
        )
    results = []
    for position, frame in enumerate(normalized_frames):
        output_name = f"case-{position:06d}"
        isolated_frame = CommonWriterInputFrame(
            case_id=frame.case_id,
            nv12=frame.nv12,
            presentation_time=RationalTime(0, 600),
            duration=frame.duration,
        )
        result = run_production_writer(
            frames=(isolated_frame,),
            width=width,
            height=height,
            output_directory=output_directory / output_name,
            source_id=f"{source_id}-{output_name}",
            output_name=output_name,
            executable=executable,
            expected_dimensions=expected_dimensions,
            authorized_execution=authorized_execution,
        )
        decoded_case_ids = [
            item.get("case_id")
            for item in result.report.get("decoder", {}).get("frames", [])
            if isinstance(item, dict)
        ]
        if decoded_case_ids != [frame.case_id] or len(result.decoded_frames) != 1:
            raise ValueError("isolated production writer did not preserve one case")
        results.append(
            IsolatedProductionWriterCaseResult(
                case_id=frame.case_id,
                result=result,
            )
        )
    return tuple(results)
