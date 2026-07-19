#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="Mirmir"
BUNDLE_ID="com.mirmir.app"
SCHEME="Mirmir"
CONFIGURATION="${CONFIGURATION:-Debug}"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export DEVELOPER_DIR

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/Mirmir.xcodeproj"
DERIVED_DATA_PATH="$ROOT_DIR/.build/mirmir-derived-data"
APP_BUNDLE="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"

usage() {
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
}

case "$MODE" in
    run|--debug|debug|--logs|logs|--telemetry|telemetry|--verify|verify)
        ;;
    *)
        usage
        exit 2
        ;;
esac

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "error: Mirmir requires macOS and Xcode." >&2
    exit 1
fi

for tool in xcodebuild open pgrep pkill; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "error: required tool '$tool' is unavailable." >&2
        exit 1
    fi
done

if [[ ! -d "$PROJECT_PATH" ]]; then
    echo "error: Xcode project not found at $PROJECT_PATH" >&2
    exit 1
fi

pkill -x "$APP_NAME" >/dev/null 2>&1 || true

BUILD_ARGUMENTS=(
    -project "$PROJECT_PATH"
    -scheme "$SCHEME"
    -configuration "$CONFIGURATION"
    -destination "platform=macOS"
    -derivedDataPath "$DERIVED_DATA_PATH"
    -disableAutomaticPackageResolution
    build
)

# This opt-in is useful on unsigned CI hosts. The default intentionally keeps
# project signing and entitlements active so local sandbox behavior is tested.
if [[ "${MIRMIR_DISABLE_CODE_SIGNING:-0}" == "1" ]]; then
    BUILD_ARGUMENTS+=(CODE_SIGNING_ALLOWED=NO)
fi

xcodebuild "${BUILD_ARGUMENTS[@]}"

if [[ ! -d "$APP_BUNDLE" || ! -x "$APP_BINARY" ]]; then
    echo "error: build completed without a runnable app at $APP_BUNDLE" >&2
    exit 1
fi

open_app() {
    /usr/bin/open -n "$APP_BUNDLE"
}

verify_process() {
    local attempt
    for attempt in {1..40}; do
        if pgrep -x "$APP_NAME" >/dev/null; then
            return 0
        fi
        sleep 0.25
    done
    echo "error: $APP_NAME did not remain running after launch." >&2
    return 1
}

case "$MODE" in
    run)
        open_app
        ;;
    --debug|debug)
        if ! command -v lldb >/dev/null 2>&1; then
            echo "error: lldb is unavailable. Install the Xcode command-line tools." >&2
            exit 1
        fi
        lldb -- "$APP_BINARY"
        ;;
    --logs|logs)
        open_app
        verify_process
        /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
        ;;
    --telemetry|telemetry)
        open_app
        verify_process
        /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
        ;;
    --verify|verify)
        open_app
        verify_process
        ;;
esac
