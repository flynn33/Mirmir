"""Apple H.264 common-writer bridge for active-row video-range NV12 frames."""

from __future__ import annotations

from dataclasses import dataclass
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
from typing import Any, Mapping, Optional, Sequence, Tuple

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


@dataclass(frozen=True)
class IsolatedProductionWriterCaseResult:
    case_id: str
    result: CommonWriterResult


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


def run_production_writer_locked(
    *,
    source_path: Path,
    source_lock_path: Path,
    output_directory: Path,
    output_name: str = "production-writer",
    executable: Path,
) -> CommonWriterResult:
    """Run the product-settings HEVC bridge for an existing locked source."""

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
    validate_schema(report, SCHEMA_ROOT / "production-writer.schema.json")
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
    )


def run_isolated_production_writer_cases(
    *,
    frames: Sequence[CommonWriterInputFrame],
    width: int,
    height: int,
    output_directory: Path,
    source_id: str,
    executable: Path,
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
