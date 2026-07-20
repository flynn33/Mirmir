#!/bin/bash -p

set -euo pipefail

run_closed() {
  /usr/bin/env -i \
    GIT_CONFIG_GLOBAL=/dev/null \
    GIT_CONFIG_NOSYSTEM=1 \
    GIT_NO_REPLACE_OBJECTS=1 \
    LANG=C \
    LC_ALL=C \
    PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    TMPDIR=/private/tmp \
    "$@"
}

run_python_tool() {
  local tool="$1"
  shift
  run_closed /usr/bin/python3 -I -c \
    'import importlib.util, runpy, sys; phase=sys.argv[1]; tool=sys.argv[2]; spec=importlib.util.spec_from_file_location("phase_evidence", phase); module=importlib.util.module_from_spec(spec); sys.modules["phase_evidence"]=module; spec.loader.exec_module(module); sys.argv=[tool]+sys.argv[3:]; runpy.run_path(tool, run_name="__main__")' \
    "$repository_root/Scripts/phase_evidence.py" "$tool" "$@"
}

usage() {
  echo "Usage: Scripts/run-r01-capability-probe.sh --anchor <anchor> --output <path>" >&2
}

fail() {
  echo "ERROR: $1" >&2
  exit 1
}

anchor=""
output=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --anchor)
      [[ $# -ge 2 ]] || { usage; fail "--anchor requires a value"; }
      [[ -z "$anchor" ]] || fail "--anchor may be specified only once"
      anchor="$2"
      shift 2
      ;;
    --output)
      [[ $# -ge 2 ]] || { usage; fail "--output requires a value"; }
      [[ -z "$output" ]] || fail "--output may be specified only once"
      output="$2"
      shift 2
      ;;
    *)
      usage
      fail "unknown argument: $1"
      ;;
  esac
done

[[ -n "$anchor" ]] || { usage; fail "--anchor is required"; }
[[ -n "$output" ]] || { usage; fail "--output is required"; }

case "$anchor" in
  oldest-supported|m3-air|pro-max|core-ai)
    ;;
  *)
    fail "invalid anchor: $anchor"
    ;;
esac

script_directory="$(CDPATH= cd -- "$(run_closed /usr/bin/dirname -- "$0")" && pwd -P)"
repository_root="$(CDPATH= cd -- "$script_directory/.." && pwd -P)"
relative_output="project-notes/evidence/r01/hosts/anchor-$anchor.json"
canonical_output="$repository_root/$relative_output"

[[ "$output" == "$relative_output" ]] || fail "output must be exactly $relative_output"

path_component="$repository_root"
for component in project-notes evidence r01 hosts "anchor-$anchor.json"; do
  path_component="$path_component/$component"
  [[ ! -L "$path_component" ]] || fail "output path contains a symbolic link: $path_component"
done

[[ ! -e "$canonical_output" ]] || fail "refusing to overwrite existing evidence: $canonical_output"
[[ "${MIRMIR_R01_LIVE_PROBES:-}" == "1" ]] || \
  fail "live probes require MIRMIR_R01_LIVE_PROBES=1"

case "${MIRMIR_R01_ALLOW_MODEL_ACQUISITION:-}" in
  "")
    ;;
  1)
    fail "model acquisition is not implemented or authorized by a closed consent-receipt contract"
    ;;
  *)
    fail "MIRMIR_R01_ALLOW_MODEL_ACQUISITION must be absent or exactly 1"
    ;;
esac

preregistration_tool="$repository_root/Scripts/r01_preregistration.py"
[[ -f "$preregistration_tool" && ! -L "$preregistration_tool" ]] || \
  fail "missing regular preregistration tool: $preregistration_tool"

run_closed /usr/bin/git -C "$repository_root" diff-index --quiet HEAD -- || \
  fail "tracked worktree must exactly match HEAD before a live probe"
source_commit="$(run_closed /usr/bin/git -C "$repository_root" \
  rev-parse --verify 'HEAD^{commit}')"
source_tree="$(run_closed /usr/bin/git -C "$repository_root" \
  rev-parse --verify 'HEAD^{tree}')"
[[ "$source_commit" =~ ^[0-9a-f]{40}$ && ! "$source_commit" =~ ^0{40}$ ]] || \
  fail "HEAD did not resolve to a closed commit identity"
[[ "$source_tree" =~ ^[0-9a-f]{40}$ && ! "$source_tree" =~ ^0{40}$ ]] || \
  fail "HEAD did not resolve to a closed tree identity"
published_refs="$(run_closed /usr/bin/git -C "$repository_root" for-each-ref \
  --format='%(refname)' --contains "$source_commit" refs/remotes/origin)"
[[ "$published_refs" == *"refs/remotes/origin/"* ]] || \
  fail "HEAD is not contained by an origin remote-tracking ref"

required_source_paths=(
  Scripts/r01_capabilities.py
  Scripts/r01_preregistration.py
  Scripts/phase_evidence.py
  Scripts/run-r01-capability-probe.sh
  R01CapabilityWorker/main.swift
  Mirmir/Modules/UpscalerEngine/AppleUpscaleCapabilityProbe.swift
  Mirmir/Modules/UpscalerEngine/AppleUpscaleCapabilitySupportProbe.swift
  Mirmir/Modules/UpscalerEngine/AppleUpscaleCapabilityCompileProbe.swift
  Mirmir/Modules/UpscalerEngine/AppleUpscaleCapabilityExecutor.swift
  Mirmir/Modules/UpscalerEngine/AppleUpscaleCapabilityFixtureContract.swift
  Mirmir/Modules/UpscalerEngine/AppleUpscaleCapabilityLiveContext.swift
  Mirmir/Modules/UpscalerEngine/AppleUpscaleCapabilityLiveErrors.swift
  Mirmir/Modules/UpscalerEngine/AppleUpscaleCapabilityNativeAdapters.swift
  Mirmir/Modules/UpscalerEngine/AppleUpscaleCapabilityRawReport.swift
  Mirmir/Modules/UpscalerEngine/AppleUpscaleCapabilityReportModels.swift
  Mirmir/Modules/UpscalerEngine/AppleUpscaleCapabilityLegacyAdapters.swift
  Mirmir/Modules/UpscalerEngine/AppleUpscaleCapabilityReportWriter.swift
  Mirmir/Modules/UpscalerEngine/AppleUpscaleCapabilityLiveProducer.swift
  Mirmir/Modules/UpscalerEngine/AppleUpscaleCapabilityWorker.swift
  MirmirTests/AppleUpscaleCapabilityProbeTests.swift
  MirmirTests/AppleUpscaleCapabilityLiveProbeTests.swift
  project.yml
  Mirmir.xcodeproj/project.pbxproj
  docs/roadmaps/evidence/schema/r01-host-report-v1.json
  docs/roadmaps/evidence/schema/r01-capability-aggregate-v1.json
  docs/roadmaps/evidence/schema/r01-preregistration-v1.json
  docs/roadmaps/evidence/schema/r01-fixture-catalog-v1.json
)
for source_path in "${required_source_paths[@]}"; do
  absolute_source="$repository_root/$source_path"
  [[ -f "$absolute_source" && ! -L "$absolute_source" ]] || \
    fail "missing regular producer source: $source_path"
  run_closed /usr/bin/git -C "$repository_root" \
    ls-files --error-unmatch "$source_path" >/dev/null || \
    fail "producer source is not tracked: $source_path"
  run_closed /usr/bin/git -C "$repository_root" \
    diff --quiet "$source_commit" -- "$source_path" || \
    fail "producer source differs from published HEAD: $source_path"
done

run_python_tool "$preregistration_tool" --check-live-readiness --anchor "$anchor"
run_python_tool "$preregistration_tool" --check-fixtures

live_test_source="$repository_root/MirmirTests/AppleUpscaleCapabilityLiveProbeTests.swift"
[[ -f "$live_test_source" && ! -L "$live_test_source" ]] || \
  fail "authoritative fixture-and-metrics live probe implementation is not present"

output_directory="$repository_root/project-notes/evidence/r01/hosts"
run_closed /bin/mkdir -p "$output_directory"
[[ -d "$output_directory" && ! -L "$output_directory" ]] || \
  fail "output parent is not a regular directory: $output_directory"

temporary_root="/private/tmp"
[[ -d "$temporary_root" && ! -L "$temporary_root" ]] || \
  fail "temporary root is not a regular directory: $temporary_root"
temporary_root="$(CDPATH= cd -- "$temporary_root" && pwd -P)"
derived_data="$(run_closed /usr/bin/mktemp -d \
  "$temporary_root/mirmir-r01-derived-data.XXXXXX")"
case "$derived_data" in
  "$temporary_root"/mirmir-r01-derived-data.*)
    ;;
  *)
    fail "mktemp returned an unexpected derived-data path: $derived_data"
    ;;
esac
[[ -d "$derived_data" && ! -L "$derived_data" ]] || \
  fail "derived-data path is not a regular directory: $derived_data"

cleanup() {
  if [[ -d "$derived_data" && ! -L "$derived_data" ]]; then
    case "$derived_data" in
      "$temporary_root"/mirmir-r01-derived-data.*)
        run_closed /bin/rm -rf -- "$derived_data"
        ;;
    esac
  fi
}
trap cleanup EXIT

run_closed /usr/bin/xcodebuild \
  -project "$repository_root/Mirmir.xcodeproj" \
  -scheme R01CapabilityWorker \
  -configuration Debug \
  -destination "platform=macOS" \
  -derivedDataPath "$derived_data" \
  -disableAutomaticPackageResolution \
  CODE_SIGNING_ALLOWED=NO \
  build

worker_executable="$derived_data/Build/Products/Debug/R01CapabilityWorker"
[[ -f "$worker_executable" && ! -L "$worker_executable" && -x "$worker_executable" ]] || \
  fail "isolated capability worker was not built as a regular executable"
worker_digest_line="$(run_closed /usr/bin/shasum -a 256 "$worker_executable")"
worker_sha256="${worker_digest_line%% *}"
[[ "$worker_sha256" =~ ^[0-9a-f]{64}$ ]] || \
  fail "isolated capability worker did not produce a closed SHA-256 identity"
run_closed \
  MIRMIR_R01_LIVE_PROBES=1 \
  MIRMIR_R01_ANCHOR="$anchor" \
  MIRMIR_R01_OUTPUT="$canonical_output" \
  MIRMIR_R01_SOURCE_COMMIT="$source_commit" \
  MIRMIR_R01_SOURCE_TREE="$source_tree" \
  MIRMIR_R01_WORKER_EXECUTABLE="$worker_executable" \
  MIRMIR_R01_WORKER_SHA256="$worker_sha256" \
  /usr/bin/xcodebuild \
  -project "$repository_root/Mirmir.xcodeproj" \
  -scheme Mirmir \
  -destination "platform=macOS" \
  -derivedDataPath "$derived_data" \
  -disableAutomaticPackageResolution \
  -only-testing:MirmirTests/AppleUpscaleCapabilityLiveProbeTests/testProduceAuthoritativeRawReport \
  CODE_SIGNING_ALLOWED=NO \
  test

[[ -f "$canonical_output" && ! -L "$canonical_output" ]] || \
  fail "live probe did not produce a regular raw report: $canonical_output"
