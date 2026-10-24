#!/usr/bin/env python3
"""Exercise real deterministic workflows; any failed input fails this QA gate.

Requires a Release build-for-testing, Xcode, ffmpeg and ffprobe. Fixtures are
synthetic. FFmpeg is a test oracle and fixture generator, not an app dependency.
Artifacts are retained for diagnosis. This is functional QA, not a benchmark.
"""

from __future__ import annotations

import argparse
from array import array
import hashlib
import json
import math
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import time


CASES = {
    "h264-mp4": ("mp4", ["-c:v", "libx264", "-pix_fmt", "yuv420p"], "aac"),
    "h264-m4v": ("m4v", ["-c:v", "libx264", "-pix_fmt", "yuv420p", "-f", "mp4"], "aac"),
    "h264-mkv": ("mkv", ["-c:v", "libx264", "-pix_fmt", "yuv420p"], "aac"),
    "h264-avi": ("avi", ["-c:v", "libx264", "-pix_fmt", "yuv420p"], "pcm_s16le"),
    "mpeg4-mov": ("mov", ["-c:v", "mpeg4", "-q:v", "3"], "aac"),
    "mpeg4-mp4": ("mp4", ["-c:v", "mpeg4", "-q:v", "3"], "aac"),
    "mpeg4-avi": ("avi", ["-c:v", "mpeg4", "-q:v", "3"], "pcm_s16le"),
    "mjpeg-mov": ("mov", ["-c:v", "mjpeg", "-pix_fmt", "yuvj420p", "-q:v", "3"], "pcm_s16le"),
    "mjpeg-avi": ("avi", ["-c:v", "mjpeg", "-pix_fmt", "yuvj420p", "-q:v", "3"], "pcm_s16le"),
    "mjpeg422-mov": ("mov", ["-c:v", "mjpeg", "-pix_fmt", "yuvj422p", "-q:v", "3"], "pcm_s16le"),
    "mjpeg444-mov": ("mov", ["-c:v", "mjpeg", "-pix_fmt", "yuvj444p", "-q:v", "3"], "pcm_s16le"),
    "mpeg2-ts": ("ts", ["-c:v", "mpeg2video", "-pix_fmt", "yuv420p"], "mp2"),
    "vp9-webm": ("webm", ["-c:v", "libvpx-vp9", "-deadline", "realtime", "-cpu-used", "8"], "libopus"),
    "wmv-asf": ("asf", ["-c:v", "wmv2"], "wmav2"),
}
BACKENDS = {
    "cpu": "mirmirDeterministicCPU",
    "metal": "mirmirDeterministicMetal",
}


def require(condition: bool, reason: str) -> None:
    if not condition:
        raise ValueError(reason)


def verify_media(bundle: Path, source: Path, directory: Path,
                 ffmpeg: str, ffprobe: str) -> dict:
    directory.mkdir()
    subprocess.run([
        "xcrun", "xcresulttool", "export", "attachments", "--path", str(bundle),
        "--output-path", str(directory),
    ], check=True, capture_output=True)
    attachments = [a for t in json.loads((directory / "manifest.json").read_text())
                   for a in t["attachments"]]
    movies = [directory / a["exportedFileName"] for a in attachments
              if a["suggestedHumanReadableName"].startswith("durable-workflow-output")]
    require(len(movies) == 1, "Expected exactly one completed output attachment")
    output = movies[0]

    def probe(path: Path) -> dict:
        return json.loads(subprocess.check_output([
            ffprobe, "-v", "error", "-count_frames", "-show_streams", "-show_format",
            "-of", "json", str(path),
        ]))

    def audio(path: Path) -> tuple[dict, bytes]:
        data = subprocess.check_output([
            ffmpeg, "-nostdin", "-v", "error", "-i", str(path), "-map", "0:a:0",
            "-c:a", "pcm_s32le", "-f", "s32le", "-",
        ])
        return {"bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}, data

    before, after = probe(source), probe(output)
    source_video = [s for s in before["streams"] if s["codec_type"] == "video"]
    output_video = [s for s in after["streams"] if s["codec_type"] == "video"]
    require(len(source_video) == len(output_video) == 1, "Video track count changed")
    require(sum(s["codec_type"] == "audio" for s in before["streams"])
            == sum(s["codec_type"] == "audio" for s in after["streams"]) == 1,
            "Audio track count changed")
    original, video = source_video[0], output_video[0]
    require(int(original["nb_read_frames"]) == int(video["nb_read_frames"]) == 72,
            "Expected all 72 source and output frames to decode")
    require((video["width"], video["height"]) == (320, 192), "Output raster differs")
    # Native XCTest also compares exact decoded/track clocks; source container
    # header duration is not authoritative (AVI and transport streams differ).
    require(after["format"]["duration"] == "3.000000", "Output timeline differs")
    source_audio, source_pcm = audio(source)
    output_audio, output_pcm = audio(output)
    source_stream = next(s for s in before["streams"] if s["codec_type"] == "audio")
    output_stream = next(s for s in after["streams"] if s["codec_type"] == "audio")
    audio_mode = "preserved"
    if source_stream["codec_name"] == output_stream["codec_name"]:
        require(source_audio == output_audio, "Decoded audio bytes changed")
    else:
        # The existing whole-asset contract permits incompatible audio to be
        # transcoded to AAC. Do not demand lossless bytes from that lossy route.
        require(source_stream["codec_name"] in {"mp2", "opus", "wmav2"}
                and output_stream["codec_name"] == "aac", "Unexpected audio conversion")
        require(source_stream["sample_rate"] == output_stream["sample_rate"]
                and source_stream["channels"] == output_stream["channels"]
                and len(source_pcm) == len(output_pcm), "Audio timeline/layout changed")
        original_pcm, converted_pcm = array("i"), array("i")
        original_pcm.frombytes(source_pcm)
        converted_pcm.frombytes(output_pcm)
        if sys.byteorder != "little":
            original_pcm.byteswap()
            converted_pcm.byteswap()
        signal = sum(x * x for x in original_pcm)
        converted = sum(x * x for x in converted_pcm)
        require(signal > 0 and converted > 0, "Synthetic tone was lost")
        correlation = sum(x * y for x, y in zip(original_pcm, converted_pcm)) / math.sqrt(signal * converted)
        # A bounded regression check for this 440 Hz fixture, not a general
        # perceptual audio-quality qualification or a lossless-audio claim.
        require(correlation > 0.99 and 0.9 < math.sqrt(converted / signal) < 1.1,
                "Transcoding corrupted the synthetic tone")
        audio_mode = "transcoded"
        output_audio["sourceCorrelation"] = correlation
    subprocess.run([
        ffmpeg, "-nostdin", "-v", "error", "-i", str(output), "-map", "0:v:0",
        "-map", "0:a", "-f", "null", "-",
    ], check=True, capture_output=True)
    (directory / "output-ffprobe.json").write_text(json.dumps(after, indent=2) + "\n")
    return {"output": str(output), "decodedFrames": 72, "durationSeconds": 3,
            "outputSize": [320, 192], "sourceAudio": source_audio,
            "outputAudio": output_audio, "audioMode": audio_mode,
            "fullDecodePassed": True}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--test-run", required=True, type=Path)
    parser.add_argument("--destination", required=True,
                        help="Explicit xcodebuild platform=macOS,id=...,arch=... destination")
    parser.add_argument("--sandbox-evidence-root", required=True, type=Path,
                        help="New path writable by the chosen test app's sandbox")
    parser.add_argument("--output", required=True, type=Path,
                        help="New evidence directory; existing directories are refused")
    parser.add_argument("--case", action="append", choices=CASES)
    parser.add_argument("--backend", action="append", choices=BACKENDS)
    args = parser.parse_args()
    for selection in [args.case, args.backend]:
        require(selection is None or len(set(selection)) == len(selection),
                "Duplicate cases or backends would overwrite evidence")
    ffmpeg, ffprobe = shutil.which("ffmpeg"), shutil.which("ffprobe")
    require(ffmpeg is not None and ffprobe is not None, "ffmpeg and ffprobe must be installed")
    test_run = args.test_run.resolve(strict=True)
    base = plistlib.loads(test_run.read_bytes())
    require("MirmirTests" in base, "Expected the MirmirTests XCTest test-run entry")
    require(args.sandbox_evidence_root.is_absolute(), "Sandbox evidence path must be absolute")
    output = args.output.absolute()
    output.mkdir(parents=True, exist_ok=False)
    fixtures = Path(tempfile.mkdtemp(prefix="mirmir-format-qa-"))
    rows: list[dict] = []
    for name in args.case or CASES:
        suffix, video, audio = CASES[name]
        source = fixtures / f"{name}.{suffix}"
        generated = subprocess.run([
            ffmpeg, "-nostdin", "-v", "error", "-f", "lavfi", "-i",
            "testsrc2=size=160x96:rate=24:duration=3", "-f", "lavfi", "-i",
            "sine=frequency=440:sample_rate=48000:duration=3", *video,
            "-c:a", audio, "-shortest", str(source),
        ], capture_output=True, text=True)
        for backend in args.backend or BACKENDS:
            key = f"{backend}-{name}"
            row = {"name": key, "source": str(source), "backend": BACKENDS[backend],
                   "passed": False}
            start = time.monotonic()
            try:
                require(generated.returncode == 0, "Fixture generation failed: " + generated.stderr)
                row["sourceSHA256"] = hashlib.sha256(source.read_bytes()).hexdigest()
                plan = plistlib.loads(plistlib.dumps(base))
                # Put the plan beside the original so __TESTROOT__ stays correct.
                with tempfile.NamedTemporaryFile(prefix="FormatQA-", suffix=".xctestrun",
                                                 dir=test_run.parent, delete=False) as handle:
                    plan_path = Path(handle.name)
                    plan["MirmirTests"].setdefault("EnvironmentVariables", {}).update({
                        "MIRMIR_REAL_SOURCE_PATH": str(source),
                        "MIRMIR_REAL_SOURCE_EVIDENCE_DIR": str(args.sandbox_evidence_root / key),
                        "MIRMIR_REAL_SOURCE_BACKEND": BACKENDS[backend],
                        "MIRMIR_REAL_SOURCE_OUTPUT_CODEC": "hevc",
                        "MIRMIR_REAL_SOURCE_TARGET_WIDTH": "320",
                        "MIRMIR_REAL_SOURCE_TARGET_HEIGHT": "192",
                    })
                    handle.write(plistlib.dumps(plan))
                bundle = output / f"{key}.xcresult"
                command = [
                    "xcodebuild", "test-without-building", "-xctestrun", str(plan_path),
                    "-destination", args.destination, "-parallel-testing-enabled", "NO",
                    "-only-testing:MirmirTests/WorkflowApplicationQueueV4Tests/"
                    "testExternalSourceCompletesProductionDurableWorkflowWhenRequested",
                    "-resultBundlePath", str(bundle),
                ]
                row["command"] = command
                with (output / f"{key}.log").open("w") as log:
                    result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT)
                row["testExit"] = result.returncode
                require(result.returncode == 0, "Production workflow test failed; see log and xcresult")
                row["verification"] = verify_media(
                    bundle, source, output / f"{key}-attachments", ffmpeg, ffprobe
                )
                row["passed"] = True
            except (ValueError, OSError, KeyError, subprocess.SubprocessError) as error:
                row["error"] = str(error)
            row["elapsedSeconds"] = time.monotonic() - start
            rows.append(row)
            (output / "results.json").write_text(json.dumps(rows, indent=2) + "\n")
            print(f"{key}: {'PASS' if row['passed'] else 'FAIL'}", flush=True)
    return 0 if all(row["passed"] for row in rows) else 1


if __name__ == "__main__":
    raise SystemExit(main())
