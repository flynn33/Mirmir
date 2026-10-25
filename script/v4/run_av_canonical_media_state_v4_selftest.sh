#!/bin/zsh
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/mirmir-av-canonical-v4.XXXXXX")"
trap 'rm -rf "$test_root"' EXIT

xcrun swiftc \
    -target "$(uname -m)-apple-macos15.4" \
    -warnings-as-errors \
    -O \
    -o "$test_root/av-canonical-media-state-v4-selftest" \
    "$repo_root/Mirmir/Modules/UpscalerEngine/RationalPresentationGeometryV4.swift" \
    "$repo_root/Mirmir/Modules/UpscalerEngine/ASH/ASHCanonicalJSONV4.swift" \
    "$repo_root/Mirmir/Domain/CanonicalMediaStateV4.swift" \
    "$repo_root/Mirmir/Modules/UpscalerEngine/PixelLayoutV4.swift" \
    "$repo_root/Mirmir/Modules/UpscalerEngine/HDRMetadataV4.swift" \
    "$repo_root/Mirmir/Modules/UpscalerEngine/AVFoundationHDRMetadataAdapterV4.swift" \
    "$repo_root/Mirmir/MediaIO/CanonicalMediaAVFoundationSupportV4.swift" \
    "$repo_root/Mirmir/MediaIO/AVCanonicalMediaStateAdapterV4.swift" \
    "$repo_root/Mirmir/MediaIO/NativeAVICompressedPresentationClockV4.swift" \
    "$repo_root/Mirmir/MediaIO/NativeAVIMPEG4PresentationOrderV4.swift" \
    "$repo_root/Mirmir/MediaIO/NativeMediaInputAssetResolverV4.swift" \
    "$repo_root/Mirmir/MediaIO/NativeMediaInputVerificationV4.swift" \
    "$repo_root/Mirmir/MediaIO/UniformPCMSampleBufferV4.swift" \
    "$repo_root/Mirmir/MediaIO/MOViTunesGaplessMetadataV4.swift" \
    "$repo_root/script/v4/AVCanonicalMediaStateAdapterV4SelfTestMain.swift"

"$test_root/av-canonical-media-state-v4-selftest"
