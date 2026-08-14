#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
repo_root="${script_dir:h:h}"
derived_data="$(mktemp -d "${TMPDIR:-/tmp}/mirmir-segment-v4.XXXXXX")"
trap 'rm -rf -- "$derived_data"' EXIT

xcodebuild -quiet \
  -project "$repo_root/Mirmir.xcodeproj" \
  -scheme Mirmir \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$derived_data" \
  CODE_SIGNING_ALLOWED=NO \
  test \
  -only-testing:MirmirTests/WorkflowSegmentCheckpointStoreV4Tests
