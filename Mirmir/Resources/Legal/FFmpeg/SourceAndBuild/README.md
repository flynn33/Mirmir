# Temporary universal software import dependency preparation

Prepared entirely under `/private/tmp`; no Mirmir product dependency, source, Xcode project, UI, or release state was changed for this build.

## Artifacts and observed result

- `universal/`: optimized development package with five LGPL 2.1-or-later FFmpeg dylibs, matching headers, source license files, and direct C diagnostic programs.
- `strict-scalar/universal/`: second package from the same unmodified source, adding `--disable-asm` and `-ffp-contract=off`. This variant closes the observed video byte differences between arm64 and Rosetta for all five fixture cases. It is a useful next integration checkpoint; it does not establish all-format or complete cross-architecture determinism.
- Both packages contain arm64 and x86_64 slices with minimum macOS 15.4. Their dylib IDs are `@rpath/libNAME.MAJOR.dylib`; packaged symlinks resolve those IDs. All linked dependencies are packaged `@rpath` libraries or Apple system libraries/frameworks. No Homebrew dependency is present in load commands.
- Both runtime inventories report FFmpeg 8.1.2, 502 built-in decoders, 354 demuxers, 67 parsers, 49 bitstream filters, no encoders, no muxers, no input/output protocols, and `LGPL version 2.1 or later` from all five library license APIs. External `CONFIG_LIB*` entries are disabled. GPL, version3, nonfree, network, devices, filters, hardware acceleration, external package autodetection, programs, encoders, and muxers are disabled.
- Direct C integration ran the MKV/H264/AAC, WebM/VP9/Opus, ASF/WMV2/WMA, TS/MPEG2/MP2, and AVI/MPEG4-ASP/PCM fixtures in both architectures. Every run produced 72 display frames; source frame clocks, packet-origin mappings, and decoded sample counts match the retained initial probe. This is fixture integration evidence, not independent decoder correctness evidence: the original CLI oracle and this C probe share the same FFmpeg family of implementations.

`qualification-summary.json`, `strict-scalar/qualification-summary.json`, per-variant `qualification-results.json`, `config-audit.json`, and `package-audit.json` are the machine-readable evidence. Full runtime events, stderr, and raw decoded outputs remain in each `qualification/{arm64,x86_64}/CASE/` directory.

## Remaining byte differences

The optimized package differs across architectures in MPEG2 and MPEG4-ASP IDCT output and floating AAC/Opus/WMA audio. A separate C control probe selects `FF_IDCT_SIMPLE` and disables runtime CPU optimizations; that closes the five tested video comparisons without changing the libraries. `AV_CODEC_FLAG_BITEXACT` alone explicitly excludes (I)DCT in the official `libavcodec/avcodec.h:319` comment.

The strict scalar package's ordinary `AV_CODEC_FLAG_BITEXACT` path produces identical video bytes across architectures for the five fixtures. Its floating decoded audio still differs: AAC 19 of 144384 S32 samples, Opus 13 of 144000, and WMA 1488 of 143360; maximum absolute difference is 32 S32 units. Fixed-point AAC was also tested in a separate probe and differs in four samples; it is not silently substituted into the baseline. Counts, hashes, maximum differences, and RMS errors are retained under `strict-scalar/control-probes/results.json`. No universal audio-byte determinism claim is made.

No tolerance was used to mark unequal bytes equal. The reports keep failing byte comparisons, including differences from the original Homebrew-linked probe, even where the new output is internally consistent across architectures.

## Source authentication and provenance

Official source: https://ffmpeg.org/releases/ffmpeg-8.1.2.tar.xz

Official detached signature: https://ffmpeg.org/releases/ffmpeg-8.1.2.tar.xz.asc

Official release key: https://ffmpeg.org/ffmpeg-devel.asc; pinned fingerprint from https://ffmpeg.org/download.html:

`FCF986EA15E6E293A5644F10B4322F04D67658D8`

The detached SHA512 signature verified with that exact key. The authenticated 11710924-byte archive has computed SHA256:

`464beb5e7bf0c311e68b45ae2f04e9cc2af88851abb4082231742a74d97b524c`

No separate officially published SHA256 list was found on the release index. The computed hash binds the archive authenticated by its official signature; it is not represented as a separately published official checksum. `source-verification.json`, `.log`, `.stderr.log`, `download-manifest.json`, and the original archive/signature/key retain this boundary explicitly. `source-tree-audit.json` verifies all 10111 extracted source files against that authenticated archive, with zero added, missing, or changed files.

PGPy 0.6.0 and its verification-only dependencies are isolated in `verification-python/`; they are not linked into the dylibs or copied into either package. Exact installed versions and original installation output are retained in `verification-python-manifest.json` and `verification-python-install.log`.

## Reproduce the process

The scripts retain the exact configure, compiler, link, lipo, codesign, and runtime arguments in adjacent JSON files. Build inputs are the authenticated source, installed Apple command-line tools/Xcode SDK, Python, and Apple SDK zlib/bzip2/iconv support. Neither NASM nor YASM was available; the optimized x86_64 variant disables external x86 assembly, while the strict variant disables assembly for both architectures. The environment removes external include/library overrides and sets PATH to Apple system tool directories. The concrete SDK and environment are in `build-environment.json`.

After placing this directory and the retained C probe fixture directory at their recorded paths:

```sh
python3 download_release.py
python3 verify_release.py
python3 audit_source.py
python3 build.py
python3 package.py
python3 audit_config.py
python3 qualify.py
python3 control_probe.py
python3 strict-scalar/build.py
python3 strict-scalar/package.py
python3 strict-scalar/audit_config.py
python3 strict-scalar/qualify.py
python3 strict-scalar/control_probe.py
```

`verify_release.py` expects the isolated verification Python dependencies already retained here. A fresh environment can install the exact package versions listed in `verification-python-manifest.json` into `verification-python/`. A fresh source extraction uses the retained authenticated archive. This is a reproducible process description; identical signed binary bytes across different toolchains, SDKs, root paths, or signing runs were not tested.

The C probe and fixture baseline are retained at `/private/tmp/mirmir-software-input-probe-20261024/`; `qualify.py` deliberately records that source path. Its `probe.c`, `source-manifest.json`, `inputs/`, case event logs, and raw outputs remain available. Each qualification command records every absolute input/output path used.

## Build diagnostics and limits

The first optimized link attempt failed because the detected iconv support did not add `-liconv`; those logs/configurations are retained with `attempt1` names. The successful configurations explicitly link the Apple SDK iconv library. No source patch was made. Upstream compiler warnings and Apple's obsolete `-single_module` linker warning are retained in full build logs; these third-party builds are not described as warning free. The probe and inventory C programs compiled with `-Wall -Wextra -Werror` and empty compiler logs.

Dylibs carry ad hoc development signatures after universal assembly, and strict signature verification passes. This is not distribution signing, App Store acceptance, deployment validation on an Intel machine, a license compliance certification, or shipment. x86_64 execution was under Rosetta on this host. Full media-format coverage, malformed-input aggregate-memory guarantees, long-run performance, all decoder semantic equivalence, and application integration remain separate work. The five fixture cases and successful build do not close those requirements.
