#!/usr/bin/env python3
"""Compile and run the Apple-native actual-codec fixture verifier."""

from __future__ import annotations

import argparse
from pathlib import Path
import subprocess
import tempfile


QUALITY_ROOT = Path(__file__).resolve().parents[1]
FIXTURE_ROOT = QUALITY_ROOT / "fixtures" / "actual-h264-software-nv12-v1"
SWIFT_ROOT = QUALITY_ROOT / "tools" / "actual_codec_fixture"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output-directory", type=Path, required=True)
    parser.add_argument("--source", type=Path, default=FIXTURE_ROOT / "source.nv12")
    parser.add_argument("--source-lock", type=Path, default=FIXTURE_ROOT / "source-lock.json")
    args = parser.parse_args()
    args.output_directory.mkdir(parents=True, exist_ok=True)

    swift_sources = [
        SWIFT_ROOT / "ActualCodecFixtureTypes.swift",
        SWIFT_ROOT / "ActualCodecFixtureMedia.swift",
        SWIFT_ROOT / "ActualCodecFixturePixelIO.swift",
        SWIFT_ROOT / "ActualCodecFixtureSoftwareDecode.swift",
        SWIFT_ROOT / "ActualCodecFixtureProductRoute.swift",
        SWIFT_ROOT / "ActualCodecFixtureMain.swift",
    ]
    with tempfile.TemporaryDirectory(prefix="mirmir-actual-codec-build-") as temporary:
        executable = Path(temporary) / "actual-codec-fixture"
        compile_command = [
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
        subprocess.run(compile_command, check=True, cwd=QUALITY_ROOT.parents[1])
        fixture = args.output_directory / "actual-h264-software-nv12-v1.mp4"
        report = args.output_directory / "actual-codec-fixture-lock.json"
        run_command = [
            str(executable),
            "--source",
            str(args.source),
            "--source-lock",
            str(args.source_lock),
            "--fixture",
            str(fixture),
            "--report",
            str(report),
        ]
        return subprocess.run(run_command, cwd=QUALITY_ROOT.parents[1]).returncode


if __name__ == "__main__":
    raise SystemExit(main())
