#!/bin/zsh

set -euo pipefail

readonly SCRIPT_DIRECTORY="${0:A:h}"
readonly DEFAULT_REPOSITORY_ROOT="${SCRIPT_DIRECTORY:h}"
readonly LAUNCH_ARGUMENT="--mirmir-p08-native-evidence"

fail() {
    print -u2 -- "P08 native orchestration failed: $*"
    exit 2
}

usage() {
    print -u2 -- "Usage: $0 \\
  --run-id <id> \\
  --p06-artifact-root <absolute-directory> \\
  --p06-resource-root <absolute-six-file-directory> \\
  --selected-evaluation-file <absolute-file> \\
  --control-authorization-bundle-file <absolute-file> \\
  --best-fixed-selection-file <absolute-file> \\
  --direct-2x-fixture <absolute-file> \\
  --direct-3-over-2-fixture <absolute-file> \\
  --output-root <absent-absolute-directory> \\
  [--repository-root <absolute-directory>]"
    exit 2
}

require_option_value() {
    (( $# == 2 )) || usage
    [[ -n "$2" && "$2" != --* ]] || usage
}

typeset run_id=""
typeset p06_artifact_root=""
typeset p06_resource_root=""
typeset selected_evaluation_file=""
typeset control_authorization_bundle_file=""
typeset best_fixed_selection_file=""
typeset direct_2x_fixture=""
typeset direct_3_over_2_fixture=""
typeset output_root=""
typeset repository_root="$DEFAULT_REPOSITORY_ROOT"
typeset repository_root_supplied=0

while (( $# > 0 )); do
    case "$1" in
        --run-id)
            require_option_value "$1" "${2-}"
            [[ -z "$run_id" ]] || fail "--run-id was supplied more than once"
            run_id="$2"
            shift 2
            ;;
        --p06-artifact-root)
            require_option_value "$1" "${2-}"
            [[ -z "$p06_artifact_root" ]] || fail "--p06-artifact-root was supplied more than once"
            p06_artifact_root="$2"
            shift 2
            ;;
        --p06-resource-root)
            require_option_value "$1" "${2-}"
            [[ -z "$p06_resource_root" ]] || fail "--p06-resource-root was supplied more than once"
            p06_resource_root="$2"
            shift 2
            ;;
        --selected-evaluation-file)
            require_option_value "$1" "${2-}"
            [[ -z "$selected_evaluation_file" ]] || fail "--selected-evaluation-file was supplied more than once"
            selected_evaluation_file="$2"
            shift 2
            ;;
        --control-authorization-bundle-file)
            require_option_value "$1" "${2-}"
            [[ -z "$control_authorization_bundle_file" ]] || fail "--control-authorization-bundle-file was supplied more than once"
            control_authorization_bundle_file="$2"
            shift 2
            ;;
        --best-fixed-selection-file)
            require_option_value "$1" "${2-}"
            [[ -z "$best_fixed_selection_file" ]] || fail "--best-fixed-selection-file was supplied more than once"
            best_fixed_selection_file="$2"
            shift 2
            ;;
        --direct-2x-fixture)
            require_option_value "$1" "${2-}"
            [[ -z "$direct_2x_fixture" ]] || fail "--direct-2x-fixture was supplied more than once"
            direct_2x_fixture="$2"
            shift 2
            ;;
        --direct-3-over-2-fixture)
            require_option_value "$1" "${2-}"
            [[ -z "$direct_3_over_2_fixture" ]] || fail "--direct-3-over-2-fixture was supplied more than once"
            direct_3_over_2_fixture="$2"
            shift 2
            ;;
        --output-root)
            require_option_value "$1" "${2-}"
            [[ -z "$output_root" ]] || fail "--output-root was supplied more than once"
            output_root="$2"
            shift 2
            ;;
        --repository-root)
            require_option_value "$1" "${2-}"
            (( repository_root_supplied == 0 )) || fail "--repository-root was supplied more than once"
            repository_root="$2"
            repository_root_supplied=1
            shift 2
            ;;
        *)
            usage
            ;;
    esac
done

[[ -n "$run_id" ]] || usage
[[ -n "$p06_artifact_root" ]] || usage
[[ -n "$p06_resource_root" ]] || usage
[[ -n "$selected_evaluation_file" ]] || usage
[[ -n "$control_authorization_bundle_file" ]] || usage
[[ -n "$best_fixed_selection_file" ]] || usage
[[ -n "$direct_2x_fixture" ]] || usage
[[ -n "$direct_3_over_2_fixture" ]] || usage
[[ -n "$output_root" ]] || usage
[[ "$run_id" =~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$' ]] \
    || fail "--run-id violates the preregistered identifier grammar"

require_directory() {
    local label="$1"
    local path="$2"
    [[ "$path" == /* && "${path:A}" == "$path" && -d "$path" && ! -L "$path" ]] \
        || fail "$label must be an absolute normalized non-linked directory: $path"
}

require_file() {
    local label="$1"
    local path="$2"
    [[ "$path" == /* && "${path:A}" == "$path" && -f "$path" && ! -L "$path" ]] \
        || fail "$label must be an absolute normalized non-linked regular file: $path"
    [[ "$(/usr/bin/stat -f '%l' "$path")" == "1" ]] \
        || fail "$label must have exactly one hard link: $path"
}

require_directory "repository root" "$repository_root"
require_directory "P06 artifact root" "$p06_artifact_root"
require_directory "P06 resource root" "$p06_resource_root"
require_file "selected evaluation" "$selected_evaluation_file"
require_file "control authorization bundle" "$control_authorization_bundle_file"
require_file "best-fixed selection" "$best_fixed_selection_file"
require_file "direct-2x fixture" "$direct_2x_fixture"
require_file "direct-3-over-2 fixture" "$direct_3_over_2_fixture"

[[ "$repository_root" == "$DEFAULT_REPOSITORY_ROOT" ]] \
    || fail "--repository-root must identify the repository containing this script"
[[ "$selected_evaluation_file" == "$p06_artifact_root"/* ]] \
    || fail "selected evaluation is outside the P06 artifact root"
[[ "$control_authorization_bundle_file" == "$p06_artifact_root"/* ]] \
    || fail "control authorization bundle is outside the P06 artifact root"
[[ "$best_fixed_selection_file" == "$p06_artifact_root"/* ]] \
    || fail "best-fixed selection is outside the P06 artifact root"

readonly p06_release_bundle_file="$p06_artifact_root/p06-release-bundle.json"
require_file "P06 release bundle" "$p06_release_bundle_file"

[[ "$output_root" == /* && "$output_root" != */../* && "$output_root" != */./* ]] \
    || fail "--output-root must be absolute and lexically normalized"
[[ ! -e "$output_root" && ! -L "$output_root" ]] \
    || fail "--output-root must be absent"
readonly output_parent="${output_root:h}"
require_directory "output parent" "$output_parent"
[[ "$output_root" != "$repository_root" && "$output_root" != "$repository_root"/* ]] \
    || fail "--output-root must remain outside the source repository"

readonly project="$repository_root/Mirmir.xcodeproj"
readonly collector="$repository_root/validation/calibration_v2/tools/collect_p08_evidence_binding.py"
readonly stager="$repository_root/validation/calibration_v2/tools/stage_p08_native_evidence.py"
require_directory "Xcode project" "$project"
require_file "P08 identity collector" "$collector"
require_file "P08 pre-G07 stager" "$stager"

readonly observed_git_root="$(git -C "$repository_root" rev-parse --show-toplevel)"
[[ "$observed_git_root" == "$repository_root" ]] \
    || fail "repository root differs from the Git top level"

readonly source_identity="$(
    /usr/bin/python3 "$collector" repository --repository-root "$repository_root"
)"
readonly source_commit="$(
    print -r -- "$source_identity" \
        | /usr/bin/plutil -extract source_commit raw -o - -- -
)"
readonly source_tree_sha256="$(
    print -r -- "$source_identity" \
        | /usr/bin/plutil -extract source_tree_sha256 raw -o - -- -
)"

/bin/mkdir "$output_root"
readonly build_root="$output_root/build"
readonly test_derived_data="$build_root/P08TestDerivedData"
readonly production_derived_data="$build_root/ProductionDerivedData"
readonly package_cache="$build_root/SourcePackages"
readonly fragments="$output_root/fragments"
readonly raw="$output_root/raw"
readonly scratch="$output_root/scratch"
readonly native="$output_root/native"
/bin/mkdir "$build_root" "$fragments" "$raw" "$scratch" "$native"

print -- "Building the independent unhosted P08 test bundle before the measured app..."
xcodebuild \
    -project "$project" \
    -scheme "Mirmir P08" \
    -configuration Release \
    -destination "platform=macOS" \
    -derivedDataPath "$test_derived_data" \
    -clonedSourcePackagesDirPath "$package_cache" \
    -skipPackageUpdates \
    build-for-testing

print -- "Building the ordinary Release app once with the exact six-file P06 injection..."
/usr/bin/env \
    "MIRMIR_P08_P06_RELEASE_ROOT=$p06_resource_root" \
    xcodebuild \
        -project "$project" \
        -scheme Mirmir \
        -configuration Release \
        -destination "platform=macOS" \
        -derivedDataPath "$production_derived_data" \
        -clonedSourcePackagesDirPath "$package_cache" \
        -skipPackageUpdates \
        build

readonly app="$production_derived_data/Build/Products/Release/Mirmir.app"
readonly executable="$app/Contents/MacOS/Mirmir"
require_directory "ordinary Release app" "$app"
require_file "ordinary Release executable" "$executable"
[[ ! -e "$app/Contents/PlugIns" && ! -L "$app/Contents/PlugIns" ]] \
    || fail "ordinary Release app contains a hosted test PlugIns directory"

app_tree_sha256() {
    local binding
    binding="$(
        /usr/bin/python3 "$collector" tree \
            --path "$app" \
            --relative-path Mirmir.app
    )"
    print -r -- "$binding" \
        | /usr/bin/plutil -extract tree_sha256 raw -o - -- -
}

readonly production_app_tree_sha256="$(app_tree_sha256)"

typeset -a common_environment
common_environment=(
    "MIRMIR_P08_RUN_ID=$run_id"
    "MIRMIR_P08_SOURCE_COMMIT=$source_commit"
    "MIRMIR_P08_SOURCE_TREE_SHA256=$source_tree_sha256"
    "MIRMIR_P08_PRODUCTION_APP_TREE_SHA256=$production_app_tree_sha256"
    "MIRMIR_P08_P06_RELEASE_ROOT=$p06_resource_root"
    "MIRMIR_P08_P06_RELEASE_BUNDLE_FILE=$p06_release_bundle_file"
    "MIRMIR_P08_SELECTED_EVALUATION_FILE=$selected_evaluation_file"
    "MIRMIR_P08_CONTROL_AUTHORIZATION_BUNDLE_FILE=$control_authorization_bundle_file"
    "MIRMIR_P08_BEST_FIXED_SELECTION_FILE=$best_fixed_selection_file"
    "MIRMIR_P08_DIRECT2X_FIXTURE=$direct_2x_fixture"
    "MIRMIR_P08_DIRECT3OVER2_FIXTURE=$direct_3_over_2_fixture"
    "MIRMIR_P08_SCRATCH_ROOT=$scratch"
    "MTL_CAPTURE_ENABLED=1"
)

typeset -a xctestrun_candidates
xctestrun_candidates=(
    "$test_derived_data"/Build/Products/*.xctestrun(N)
)
(( ${#xctestrun_candidates[@]} == 1 )) \
    || fail "independent P08 build produced an ambiguous .xctestrun closure"
readonly base_xctestrun="${xctestrun_candidates[1]}"
readonly configured_xctestrun="${base_xctestrun:h}/P08-configured.xctestrun"
/bin/cp -p "$base_xctestrun" "$configured_xctestrun"

set_xctestrun_environment() {
    local file="$1"
    local name="$2"
    local value="$3"
    local key_path="MirmirP08Tests.EnvironmentVariables.$name"
    if /usr/bin/plutil -extract "$key_path" raw -o - "$file" >/dev/null 2>&1; then
        /usr/bin/plutil -replace "$key_path" -string "$value" "$file"
    else
        /usr/bin/plutil -insert "$key_path" -string "$value" "$file"
    fi
}

typeset environment_entry
for environment_entry in "${common_environment[@]}"; do
    set_xctestrun_environment \
        "$configured_xctestrun" \
        "${environment_entry%%=*}" \
        "${environment_entry#*=}"
done
set_xctestrun_environment "$configured_xctestrun" MIRMIR_P08_ENABLE_EXECUTION 1
set_xctestrun_environment "$configured_xctestrun" MIRMIR_P08_APP_BUNDLE "$app"

run_tree_bound() {
    local label="$1"
    shift
    local before="$(app_tree_sha256)"
    [[ "$before" == "$production_app_tree_sha256" ]] \
        || fail "$label was not launched from the bound Release app tree"
    "$@"
    local after="$(app_tree_sha256)"
    [[ "$after" == "$before" && "$after" == "$production_app_tree_sha256" ]] \
        || fail "$label changed the bound Release app tree"
}

run_xctest_slice() {
    local role="$1"
    local test_name="$2"
    local fragment="$3"
    local result_bundle="$4"
    local slice_xctestrun="${base_xctestrun:h}/P08-$role.xctestrun"
    /bin/cp -p "$configured_xctestrun" "$slice_xctestrun"
    set_xctestrun_environment \
        "$slice_xctestrun" \
        "MIRMIR_P08_${role}_FRAGMENT" \
        "$fragment"
    xcodebuild \
        -xctestrun "$slice_xctestrun" \
        -destination "platform=macOS" \
        -resultBundlePath "$result_bundle" \
        -only-testing:"MirmirP08Tests/ASHP08LauncherTests/$test_name" \
        test-without-building
}

readonly metal_parity_fragment="$fragments/metal-parity.json"
readonly performance_fragment="$fragments/performance.json"
readonly resource_ring_fragment="$fragments/resource-ring.json"

print -- "Running the three independent XCTest producer slices without rebuilding..."
run_tree_bound \
    "metal-parity XCTest producer" \
    run_xctest_slice \
    METAL_PARITY \
    testMetalParityProducer \
    "$metal_parity_fragment" \
    "$raw/metal-parity.xcresult"
run_tree_bound \
    "performance XCTest producer" \
    run_xctest_slice \
    PERFORMANCE \
    testPerformanceProducer \
    "$performance_fragment" \
    "$raw/performance.xcresult"
run_tree_bound \
    "resource-ring XCTest producer" \
    run_xctest_slice \
    RESOURCE_RING \
    testResourceRingProducer \
    "$resource_ring_fragment" \
    "$raw/resource-ring.xcresult"

profile_mode() {
    case "$1" in
        direct_2x) print -- "profile-direct-2x" ;;
        direct_3_over_2) print -- "profile-direct-3-over-2" ;;
        *) fail "unknown profile route: $1" ;;
    esac
}

profile_template() {
    case "$1" in
        time_profiler) print -- "Time Profiler" ;;
        allocations) print -- "Allocations" ;;
        metal_system_trace) print -- "Metal System Trace" ;;
        *) fail "unknown profile tool: $1" ;;
    esac
}

run_profile() {
    local tool="$1"
    local route="$2"
    local fragment="$fragments/profile-$tool-$route.json"
    local archive="$raw/$tool-$route.trace"
    local mode="$(profile_mode "$route")"
    local template="$(profile_template "$tool")"
    typeset -a trace_environment
    trace_environment=()
    local entry
    for entry in "${common_environment[@]}"; do
        trace_environment+=(--env "$entry")
    done
    trace_environment+=(
        --env "MIRMIR_P08_APP_MODE=$mode"
        --env "MIRMIR_P08_SLICE_OUTPUT=$fragment"
    )
    xcrun xctrace record \
        --template "$template" \
        --output "$archive" \
        "${trace_environment[@]}" \
        --launch -- \
        "$executable" "$LAUNCH_ARGUMENT"
}

print -- "Recording six route/tool Instruments profiles over the immutable app..."
typeset -a profile_tools=(time_profiler allocations metal_system_trace)
typeset -a routes=(direct_2x direct_3_over_2)
typeset tool
typeset route
for tool in "${profile_tools[@]}"; do
    for route in "${routes[@]}"; do
        run_tree_bound "$tool/$route Instruments profile" run_profile "$tool" "$route"
    done
done

for route in "${routes[@]}"; do
    /usr/bin/cmp -s \
        "$fragments/profile-time_profiler-$route.json" \
        "$fragments/profile-allocations-$route.json" \
        || fail "$route profile observations differ by tool"
    /usr/bin/cmp -s \
        "$fragments/profile-time_profiler-$route.json" \
        "$fragments/profile-metal_system_trace-$route.json" \
        || fail "$route profile observations differ by tool"
done

capture_mode() {
    case "$1" in
        direct_2x) print -- "capture-direct-2x" ;;
        direct_3_over_2) print -- "capture-direct-3-over-2" ;;
        *) fail "unknown capture route: $1" ;;
    esac
}

run_capture() {
    local route="$1"
    local mode="$(capture_mode "$route")"
    /usr/bin/env \
        "${common_environment[@]}" \
        "MIRMIR_P08_APP_MODE=$mode" \
        "MIRMIR_P08_SLICE_OUTPUT=$fragments/capture-$route.json" \
        "MIRMIR_P08_GPU_CAPTURE_OUTPUT=$raw/$route.gputrace" \
        "$executable" "$LAUNCH_ARGUMENT"
}

print -- "Recording two exhaustive MTLCapture route archives..."
for route in "${routes[@]}"; do
    run_tree_bound "$route MTLCapture producer" run_capture "$route"
done

readonly xctrace_version="$(xcrun xctrace version 2>&1)"
readonly native_measurements="$native/p08-native-measurements.json"

run_assemble() {
    /usr/bin/env \
        "${common_environment[@]}" \
        "MIRMIR_P08_APP_MODE=assemble" \
        "MIRMIR_P08_METAL_PARITY_FRAGMENT=$metal_parity_fragment" \
        "MIRMIR_P08_PERFORMANCE_FRAGMENT=$performance_fragment" \
        "MIRMIR_P08_RESOURCE_RING_FRAGMENT=$resource_ring_fragment" \
        "MIRMIR_P08_PROFILE_DIRECT2X_FRAGMENT=$fragments/profile-time_profiler-direct_2x.json" \
        "MIRMIR_P08_PROFILE_DIRECT3OVER2_FRAGMENT=$fragments/profile-time_profiler-direct_3_over_2.json" \
        "MIRMIR_P08_CAPTURE_DIRECT2X_FRAGMENT=$fragments/capture-direct_2x.json" \
        "MIRMIR_P08_CAPTURE_DIRECT3OVER2_FRAGMENT=$fragments/capture-direct_3_over_2.json" \
        "MIRMIR_P08_XCTRACE_VERSION=$xctrace_version" \
        "MIRMIR_P08_NATIVE_MEASUREMENTS_OUTPUT=$native_measurements" \
        "$executable" "$LAUNCH_ARGUMENT"
}

print -- "Assembling the native measurements envelope..."
run_tree_bound "native measurements assembly" run_assemble
[[ "$(app_tree_sha256)" == "$production_app_tree_sha256" ]] \
    || fail "Release app tree changed before pre-G07 staging"

print -- "Staging and validating the complete immutable pre-G07 P08 closure..."
/usr/bin/python3 "$stager" pre-g07 \
    --repository-root "$repository_root" \
    --native-measurements "$native_measurements" \
    --p06-release-root "$p06_artifact_root" \
    --release-app "$app" \
    --metal-parity-xcresult "$raw/metal-parity.xcresult" \
    --performance-xcresult "$raw/performance.xcresult" \
    --resource-ring-xcresult "$raw/resource-ring.xcresult" \
    --time-profiler-direct-2x-trace "$raw/time_profiler-direct_2x.trace" \
    --time-profiler-direct-3-over-2-trace "$raw/time_profiler-direct_3_over_2.trace" \
    --allocations-direct-2x-trace "$raw/allocations-direct_2x.trace" \
    --allocations-direct-3-over-2-trace "$raw/allocations-direct_3_over_2.trace" \
    --metal-system-trace-direct-2x-trace "$raw/metal_system_trace-direct_2x.trace" \
    --metal-system-trace-direct-3-over-2-trace "$raw/metal_system_trace-direct_3_over_2.trace" \
    --direct-2x-gputrace "$raw/direct_2x.gputrace" \
    --direct-3-over-2-gputrace "$raw/direct_3_over_2.gputrace"

print -- "P08 native execution and pre-G07 staging completed."
print -- "Native measurements: $native_measurements"
print -- "Pre-G07 seal: $repository_root/Artifacts/ASH/.$run_id.p08-pre-g07"
