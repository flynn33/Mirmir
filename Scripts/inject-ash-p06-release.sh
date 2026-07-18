#!/bin/sh
set -eu

readonly VARIABLE_NAME="MIRMIR_P08_P06_RELEASE_ROOT"
readonly DESTINATION="${TARGET_BUILD_DIR:?}/${UNLOCALIZED_RESOURCES_FOLDER_PATH:?}/ASH/LockedV3"
readonly STAGING="${TARGET_TEMP_DIR:?}/ASH-LockedV3"
readonly FILENAMES="
lut-manifest-v3.json
locked-compiler-input-v2.json
locked-mapping.json
direct2x.ashlut
direct3over2.ashlut
native-lut-parity-manifest-v3.json
"

case "$DESTINATION" in
    "${TARGET_BUILD_DIR}"/*/ASH/LockedV3) ;;
    *)
        echo "error: refusing unsafe ASH release destination: $DESTINATION" >&2
        exit 1
        ;;
esac

remove_injected_resources() {
    /bin/rm -rf "$DESTINATION" "$STAGING"
}

cleanup_failed_injection() {
    result=$?
    trap - 0 1 2 15
    if [ "$result" -ne 0 ]; then
        remove_injected_resources
    fi
    exit "$result"
}

cleanup_interrupted_injection() {
    trap - 0 1 2 15
    remove_injected_resources
    exit 1
}

# Install cleanup only after the destination has passed the scoped safety check.
# Any later validation, staging, or verification failure must not leave stale
# authorized bytes in the app bundle.
trap cleanup_failed_injection 0
trap cleanup_interrupted_injection 1 2 15

SOURCE_ROOT="${MIRMIR_P08_P06_RELEASE_ROOT:-}"
if [ -z "$SOURCE_ROOT" ]; then
    remove_injected_resources
    exit 0
fi

case "$SOURCE_ROOT" in
    /*) ;;
    *)
        echo "error: $VARIABLE_NAME must be an absolute path" >&2
        exit 1
        ;;
esac

if [ ! -d "$SOURCE_ROOT" ] || [ -L "$SOURCE_ROOT" ]; then
    echo "error: $VARIABLE_NAME must identify a non-symlink directory" >&2
    exit 1
fi

for filename in $FILENAMES; do
    source_file="$SOURCE_ROOT/$filename"
    if [ ! -f "$source_file" ] || [ -L "$source_file" ]; then
        echo "error: authorized ASH release member is absent, non-regular, or a symlink: $filename" >&2
        exit 1
    fi
    if [ "$(/usr/bin/stat -f '%l' "$source_file")" -ne 1 ]; then
        echo "error: authorized ASH release member has multiple hard links: $filename" >&2
        exit 1
    fi
done

entry_count=0
for entry in "$SOURCE_ROOT"/* "$SOURCE_ROOT"/.[!.]* "$SOURCE_ROOT"/..?*; do
    if [ ! -e "$entry" ] && [ ! -L "$entry" ]; then
        continue
    fi
    entry_count=$((entry_count + 1))
    name=${entry##*/}
    authorized=false
    for filename in $FILENAMES; do
        if [ "$name" = "$filename" ]; then
            authorized=true
            break
        fi
    done
    if [ "$authorized" != true ]; then
        echo "error: unauthorized member in ASH release root: $name" >&2
        exit 1
    fi
done

if [ "$entry_count" -ne 6 ]; then
    echo "error: ASH release root must contain exactly six members; observed $entry_count" >&2
    exit 1
fi

remove_injected_resources
/bin/mkdir -p "$STAGING"
for filename in $FILENAMES; do
    /bin/cp "$SOURCE_ROOT/$filename" "$STAGING/$filename"
    if ! /usr/bin/cmp -s "$SOURCE_ROOT/$filename" "$STAGING/$filename"; then
        echo "error: byte verification failed while staging $filename" >&2
        exit 1
    fi
done

/bin/mkdir -p "${DESTINATION%/LockedV3}"
/bin/mv "$STAGING" "$DESTINATION"

for filename in $FILENAMES; do
    if ! /usr/bin/cmp -s "$SOURCE_ROOT/$filename" "$DESTINATION/$filename"; then
        echo "error: bundled ASH release member differs after copy: $filename" >&2
        exit 1
    fi
done

trap - 0 1 2 15
