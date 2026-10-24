#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
repo_root="${script_dir:h:h}"
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/mirmir-workflow-selftest.XXXXXX")"
trap 'rm -rf -- "$build_dir"' EXIT

# Use the app target's complete dependency graph, including diagnostics.
# The original self-test scenarios and assertions run in the XCTest host.
xcodebuild test \
  -project "$repo_root/Mirmir.xcodeproj" \
  -scheme Mirmir \
  -configuration Debug \
  -destination "platform=macOS,arch=$(uname -m)" \
  -derivedDataPath "${MIRMIR_SELFTEST_DERIVED_DATA:-$build_dir/DerivedData}" \
  -parallel-testing-enabled NO \
  -only-testing:MirmirTests/WorkflowQueueDispatcherV4SelfTests/testStandaloneScenarios \
  "$@"
