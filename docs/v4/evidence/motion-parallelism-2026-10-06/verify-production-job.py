#!/usr/bin/env python3
"""Independently decode and validate the retained 66-frame NTSC production run."""
import argparse
import hashlib
import json
import shutil
import subprocess
from datetime import datetime, timezone
from fractions import Fraction
from pathlib import Path

NOMINAL = Fraction(1001, 24000)
EXPECTED_FRAMES = 66
EXPECTED_AUDIO_SAMPLES = EXPECTED_FRAMES * 2002


def sha256_file(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def fraction_json(value):
    return {"numerator": value.numerator, "denominator": value.denominator}


def probe(command, retained_path):
    result = subprocess.run(command, capture_output=True, text=True)
    retained_path.with_suffix(".stderr.txt").write_text(result.stderr)
    if result.returncode:
        raise RuntimeError(f"ffprobe failed ({result.returncode}): {result.stderr}")
    retained_path.write_text(result.stdout)
    return json.loads(result.stdout)


def frame_pts(frame, time_base):
    key = "pts" if "pts" in frame else "best_effort_timestamp"
    if key not in frame:
        raise ValueError("A decoded frame has no integer presentation timestamp")
    return int(frame[key]) * time_base


def immediate_clock_representations(exact, tick):
    ticks = exact / tick
    floor = ticks.numerator // ticks.denominator
    ceiling = -((-ticks.numerator) // ticks.denominator)
    return {floor * tick, ceiling * tick}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--evidence-dir", type=Path, required=True)
    args = parser.parse_args()
    ffprobe = shutil.which("ffprobe")
    ffmpeg = shutil.which("ffmpeg")
    if not ffprobe or not ffmpeg:
        raise SystemExit("ffprobe and ffmpeg must be installed")
    for path in [args.source, args.output]:
        if not path.is_file():
            raise SystemExit(f"Required retained media does not exist: {path}")
    args.evidence_dir.mkdir(parents=True, exist_ok=True)
    checks = []
    observations = {}

    def check(name, passed, observed, expected):
        checks.append({"name": name, "passed": bool(passed), "observed": observed, "expected": expected})

    inventories = {}
    for label, path in [("source", args.source), ("output", args.output)]:
        metadata = probe([ffprobe, "-v", "error", "-count_frames", "-show_streams", "-show_format", "-of", "json", str(path)], args.evidence_dir / f"{label}-streams.json")
        video_tracks = [s for s in metadata["streams"] if s["codec_type"] == "video"]
        audio_tracks = [s for s in metadata["streams"] if s["codec_type"] == "audio"]
        check(f"{label} track inventory", len(video_tracks) == 1 and len(audio_tracks) == 1 and len(metadata["streams"]) == 2, {"video": len(video_tracks), "audio": len(audio_tracks), "all": len(metadata["streams"])}, {"video": 1, "audio": 1, "all": 2})
        if len(video_tracks) != 1 or len(audio_tracks) != 1:
            raise RuntimeError(f"Cannot select unambiguous {label} tracks")
        video, audio = video_tracks[0], audio_tracks[0]
        video_frames = probe([ffprobe, "-v", "error", "-select_streams", "v:0", "-show_frames", "-show_entries", "frame=pts,best_effort_timestamp,duration,pkt_duration,width,height,color_range,color_space,color_transfer,color_primaries", "-of", "json", str(path)], args.evidence_dir / f"{label}-video-frames.json")["frames"]
        audio_frames = probe([ffprobe, "-v", "error", "-select_streams", "a:0", "-show_frames", "-show_entries", "frame=pts,best_effort_timestamp,duration,pkt_duration,nb_samples,sample_rate,channels", "-of", "json", str(path)], args.evidence_dir / f"{label}-audio-frames.json")["frames"]
        tick = Fraction(video["time_base"])
        pts = [frame_pts(frame, tick) for frame in video_frames]
        check(f"{label} video codec", video.get("codec_name") == "h264", video.get("codec_name"), "h264")
        check(f"{label} video begins at zero", bool(pts) and pts[0] == 0, fraction_json(pts[0]) if pts else None, fraction_json(Fraction(0)))
        check(f"{label} actual decoded video count", len(pts) == EXPECTED_FRAMES and int(video["nb_read_frames"]) == EXPECTED_FRAMES, {"decoded": len(pts), "count_frames": int(video["nb_read_frames"])}, EXPECTED_FRAMES)
        check(f"{label} monotonic video PTS", all(b > a for a, b in zip(pts, pts[1:])), [fraction_json(x) for x in pts], "strictly increasing")
        pts_lattice = [value in immediate_clock_representations(index * NOMINAL, tick) for index, value in enumerate(pts)]
        check(f"{label} all NTSC frame timestamps", all(pts_lattice) and len(pts_lattice) == EXPECTED_FRAMES, {"matching": sum(pts_lattice), "total": len(pts_lattice), "tick": fraction_json(tick)}, "Every decoded PTS is exactly the floor or ceiling of its 1001/24000 ordinal on its declared clock")
        end = (int(video.get("start_pts", 0)) + int(video["duration_ts"])) * tick
        exact_end = EXPECTED_FRAMES * NOMINAL
        check(f"{label} terminal clock boundary", end in immediate_clock_representations(exact_end, tick), fraction_json(end), {"exact_ntsc_end": fraction_json(exact_end), "allowed_clock_boundaries": [fraction_json(x) for x in sorted(immediate_clock_representations(exact_end, tick))]})
        expected_size = (1920, 1080) if label == "source" else (3840, 2160)
        check(f"{label} decoded geometry", all((int(f["width"]), int(f["height"])) == expected_size for f in video_frames) and (int(video["width"]), int(video["height"])) == expected_size, {"stream": [int(video["width"]), int(video["height"])], "decoded_rasters": sorted({(int(f["width"]), int(f["height"])) for f in video_frames})}, list(expected_size))
        check(f"{label} BT709 matrix and range", video.get("color_space") == "bt709" and video.get("color_range") == "tv", {"matrix": video.get("color_space"), "range": video.get("color_range")}, {"matrix": "bt709", "range": "tv"})
        check(f"{label} progressive geometry", video.get("field_order") == "progressive", video.get("field_order"), "progressive")
        # Record observed color values and require every declared source tag
        # to be preserved, without inventing values for absent metadata.
        observations[f"{label}_color_metadata"] = {k: video.get(k) for k in ["color_space", "color_range", "color_transfer", "color_primaries", "sample_aspect_ratio", "display_aspect_ratio"]}
        check(f"{label} PCM format", audio.get("codec_name") == "pcm_s16le" and int(audio["sample_rate"]) == 48000 and int(audio["channels"]) == 1 and int(audio["bits_per_sample"]) == 16, {k: audio.get(k) for k in ["codec_name", "sample_rate", "channels", "bits_per_sample"]}, {"codec_name": "pcm_s16le", "sample_rate": "48000", "channels": 1, "bits_per_sample": 16})
        sample_count = sum(int(f["nb_samples"]) for f in audio_frames)
        check(f"{label} actual decoded PCM sample count", sample_count == EXPECTED_AUDIO_SAMPLES, sample_count, EXPECTED_AUDIO_SAMPLES)
        audio_tick = Fraction(audio["time_base"])
        cumulative = 0
        audio_continuous = True
        for frame in audio_frames:
            audio_continuous &= frame_pts(frame, audio_tick) == Fraction(cumulative, 48000)
            duration = frame.get("duration", frame.get("pkt_duration"))
            audio_continuous &= duration is not None and int(duration) * audio_tick == Fraction(int(frame["nb_samples"]), 48000)
            cumulative += int(frame["nb_samples"])
        audio_end = (int(audio.get("start_pts", 0)) + int(audio["duration_ts"])) * audio_tick
        check(f"{label} continuous audio timeline", audio_continuous and audio_end == Fraction(EXPECTED_AUDIO_SAMPLES, 48000), {"continuous_from_zero": bool(audio_continuous), "end": fraction_json(audio_end)}, fraction_json(Fraction(EXPECTED_AUDIO_SAMPLES, 48000)))
        raw_path = args.evidence_dir / f"{label}-decoded-audio.s16le"
        command = [ffmpeg, "-nostdin", "-v", "error", "-y", "-i", str(path), "-map", "0:a:0", "-vn", "-sn", "-dn", "-c:a", "pcm_s16le", "-f", "s16le", str(raw_path)]
        decoded = subprocess.run(command, capture_output=True, text=True)
        (args.evidence_dir / f"{label}-audio-decode.stderr.txt").write_text(decoded.stderr)
        if decoded.returncode:
            raise RuntimeError(f"ffmpeg PCM decode failed ({decoded.returncode}): {decoded.stderr}")
        check(f"{label} decoded PCM byte count", raw_path.stat().st_size == EXPECTED_AUDIO_SAMPLES * 2, raw_path.stat().st_size, EXPECTED_AUDIO_SAMPLES * 2)
        inventories[label] = {"path": str(path.resolve()), "file_sha256": sha256_file(path), "file_bytes": path.stat().st_size, "video_pts": pts, "video_tick": tick, "video_end": end, "audio_sha256": sha256_file(raw_path), "audio_bytes": raw_path.stat().st_size, "video": video, "audio": audio}

    source, output = inventories["source"], inventories["output"]
    check("preserved PCM payload", source["audio_sha256"] == output["audio_sha256"] and source["audio_bytes"] == output["audio_bytes"], {"source": source["audio_sha256"], "output": output["audio_sha256"]}, "identical decoded PCM samples and bytes")
    equal_pts = [a == b for a, b in zip(source["video_pts"], output["video_pts"])]
    observations["raw_source_output_pts"] = {"exact_rational_matches": sum(equal_pts), "total": len(equal_pts), "differences": [{"ordinal": i, "source": fraction_json(a), "output": fraction_json(b), "output_minus_source": fraction_json(b - a)} for i, (a, b) in enumerate(zip(source["video_pts"], output["video_pts"])) if a != b]}
    canonical_pairs = [
        a in immediate_clock_representations(i * NOMINAL, source["video_tick"])
        and b in immediate_clock_representations(i * NOMINAL, output["video_tick"])
        for i, (a, b) in enumerate(zip(source["video_pts"], output["video_pts"]))
    ]
    check("normalized source/output NTSC ordinal times", len(canonical_pairs) == EXPECTED_FRAMES and all(canonical_pairs), {"canonical_rational_matches": sum(canonical_pairs), "total": len(canonical_pairs), "first_source_pts": fraction_json(source["video_pts"][0]), "first_output_pts": fraction_json(output["video_pts"][0])}, "Both observed streams independently validate every same source ordinal against the exact 1001/24000 lattice; no observed timestamps are rewritten")
    check("preserved video duration", source["video_end"] == output["video_end"], {"source": fraction_json(source["video_end"]), "output": fraction_json(output["video_end"])}, "exact rational equality")
    for key in ["color_space", "color_range", "color_transfer", "color_primaries", "sample_aspect_ratio", "display_aspect_ratio"]:
        if source["video"].get(key) is not None:
            check(f"preserved {key}", source["video"].get(key) == output["video"].get(key), output["video"].get(key), source["video"].get(key))
    result = {"schema": "mirmir-independent-production-media-validation-v1", "generated_at": datetime.now(timezone.utc).isoformat(), "passed": all(c["passed"] for c in checks), "checks": checks, "observations": observations, "artifacts": {label: {key: value for key, value in inventory.items() if key in ["path", "file_sha256", "file_bytes", "audio_sha256", "audio_bytes"]} for label, inventory in inventories.items()}, "limits": ["Video encoding is lossy H264; file and decoded video hashes are not compared to source as an accuracy test.", "Serial/parallel deterministic field parity and CPU/Metal video parity are established by the separate Xcode tests.", "This verifies the retained short production source, not the unfinished full-length feature-film job."]}
    (args.evidence_dir / "validation.json").write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    print(json.dumps({"passed": result["passed"], "checks": len(checks), "failed_checks": [c["name"] for c in checks if not c["passed"]], "report": str(args.evidence_dir / "validation.json")}, indent=2))
    return 0 if result["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
