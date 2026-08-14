#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
repo_root="${script_dir:h:h}"
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/mirmir-queue-v4.XXXXXX")"
trap 'rm -rf -- "$build_dir"' EXIT

sources=(
  "$repo_root/Mirmir/Domain/WorkflowJob.swift"
  "$repo_root/Mirmir/Domain/WorkflowEvent.swift"
  "$repo_root/Mirmir/Domain/WorkflowState.swift"
  "$repo_root/Mirmir/Persistence/WorkflowCanonicalCodec.swift"
  "$repo_root/Mirmir/Platform/WorkflowDurableFileSystem.swift"
  "$repo_root/Mirmir/Persistence/WorkflowEventJournal.swift"
  "$repo_root/Mirmir/Persistence/WorkflowDurableCoordinatorV4.swift"
  "$repo_root/Mirmir/Persistence/WorkflowPartialArtifactReconcilerV4.swift"
  "$repo_root/Mirmir/Persistence/WorkflowSecurityScopedBookmarkStoreV4.swift"
  "$repo_root/Mirmir/Persistence/WorkflowQueueDispatcherV4.swift"
  "$script_dir/WorkflowQueueDispatcherV4SelfTestMain.swift"
)

xcrun --sdk macosx swiftc \
  -swift-version 6 \
  -strict-concurrency=complete \
  -warnings-as-errors \
  -O \
  -target arm64-apple-macos15.0 \
  "${sources[@]}" \
  -o "$build_dir/workflow-queue-dispatcher-v4-selftest"

"$build_dir/workflow-queue-dispatcher-v4-selftest"
