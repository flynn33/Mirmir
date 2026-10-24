#!/usr/bin/env python3
"""Replay the August 3 captures against their pinned historical source tree."""
from __future__ import annotations

import pathlib
import shutil
import subprocess
import sys
import tempfile

REPOSITORY_ROOT = pathlib.Path(__file__).resolve().parents[2]
CAPTURE_REVISION = "3a13049bdf3d41d362e2e53d289f4cff22ee8839"
EVIDENCE_DIRECTORY = pathlib.Path("docs/v4/evidence/m2-pixel-buffer-hot-path-2026-08-03")
VERIFIER = pathlib.Path("script/v4/verify_pixel_buffer_scaler_hot_path_repeatability.py")
REPLAY_SOURCES = (
    str(VERIFIER),
    "script/v4/evaluate_pixel_buffer_scaler_hot_path.py",
    "script/v4/PixelBufferScalerHotPathBenchmarkMain.swift",
    "script/v4/run_pixel_buffer_scaler_hot_path_benchmark.sh",
    "Mirmir/Modules/UpscalerEngine/RationalPresentationGeometryV4.swift",
    "Mirmir/Modules/UpscalerEngine/SpatialScalePlanV4.swift",
    "Mirmir/Modules/UpscalerEngine/FixedPointKernelV4.swift",
    "Mirmir/Modules/UpscalerEngine/FixedPointMetalExecutorV4.swift",
    "Mirmir/Modules/UpscalerEngine/FixedPointMetalKernelsV4.metal",
    "Mirmir/Modules/UpscalerEngine/PixelLayoutV4.swift",
    "Mirmir/Modules/UpscalerEngine/HDRMetadataV4.swift",
    "Mirmir/Modules/UpscalerEngine/AVFoundationHDRMetadataAdapterV4.swift",
    "Mirmir/Modules/UpscalerEngine/FixedPointPixelBufferScalerV4.swift",
)


def replay(evidence_directory: pathlib.Path, *, emit: bool = False) -> subprocess.CompletedProcess:
    # Use the exact original evaluator and verifier, including their own hash
    # checks. Comparing old captures to today's engine incorrectly rejects valid
    # historical evidence. The current-candidate evaluator remains unchanged.
    with tempfile.TemporaryDirectory(prefix="mirmir-historical-hot-path-") as directory:
        root = pathlib.Path(directory)
        for relative in REPLAY_SOURCES:
            contents = subprocess.run(
                ["git", "show", f"{CAPTURE_REVISION}:{relative}"],
                cwd=REPOSITORY_ROOT, capture_output=True, check=True,
            ).stdout
            destination = root / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(contents)
        git_directory = subprocess.run(
            ["git", "rev-parse", "--absolute-git-dir"],
            cwd=REPOSITORY_ROOT, capture_output=True, text=True, check=True,
        ).stdout.strip()
        # The original evaluator reads the baseline with git show. No checkout,
        # index, branch, or repository content is changed by this replay.
        (root / ".git").write_text(f"gitdir: {git_directory}\n")
        shutil.copytree(evidence_directory, root / EVIDENCE_DIRECTORY)
        return subprocess.run(
            [sys.executable, str(root / VERIFIER), *(["--emit"] if emit else [])],
            cwd=root, capture_output=True, text=True, check=False,
        )


def main() -> None:
    if sys.argv[1:] not in ([], ["--emit"]):
        raise SystemExit("usage: verify_pixel_buffer_scaler_hot_path_repeatability.py [--emit]")
    result = replay(REPOSITORY_ROOT / EVIDENCE_DIRECTORY, emit=sys.argv[1:] == ["--emit"])
    sys.stdout.write(result.stdout)
    sys.stderr.write(result.stderr)
    raise SystemExit(result.returncode)


if __name__ == "__main__":
    main()
