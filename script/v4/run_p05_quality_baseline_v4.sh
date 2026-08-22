#!/bin/sh
set -eu

usage() {
  echo "usage: $0 --repository DIRECTORY --output DIRECTORY --contract FILE --corpus-manifest FILE [--discover-executable] [--keep-build]" >&2
  exit 64
}

REPOSITORY=""
OUTPUT=""
CONTRACT=""
CORPUS_MANIFEST=""
DISCOVER_EXECUTABLE=0
KEEP_BUILD=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repository)
      [ "$#" -ge 2 ] || usage
      REPOSITORY=$2
      shift 2
      ;;
    --output)
      [ "$#" -ge 2 ] || usage
      OUTPUT=$2
      shift 2
      ;;
    --contract)
      [ "$#" -ge 2 ] || usage
      CONTRACT=$2
      shift 2
      ;;
    --corpus-manifest)
      [ "$#" -ge 2 ] || usage
      CORPUS_MANIFEST=$2
      shift 2
      ;;
    --discover-executable)
      DISCOVER_EXECUTABLE=1
      shift
      ;;
    --keep-build)
      KEEP_BUILD=1
      shift
      ;;
    *) usage ;;
  esac
done
[ -n "$REPOSITORY" ] && [ -n "$OUTPUT" ] && [ -n "$CONTRACT" ] && [ -n "$CORPUS_MANIFEST" ] || usage

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPOSITORY=$(python3 -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).resolve(strict=True))' "$REPOSITORY")
OUTPUT=$(python3 -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).expanduser().resolve())' "$OUTPUT")
CONTRACT=$(python3 -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).expanduser().resolve(strict=True))' "$CONTRACT")
CORPUS_MANIFEST=$(python3 -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).expanduser().resolve(strict=True))' "$CORPUS_MANIFEST")
IDENTITY_TOOL="$SCRIPT_DIR/p05_baseline_v4.py"
CORPUS_TOOL="$SCRIPT_DIR/quality_gate_v4.py"
SOURCE_MANIFEST="$SCRIPT_DIR/p05-baseline-source-manifest-v1.json"
CAPTURE_SOURCE="$SCRIPT_DIR/P05QualityBaselineCaptureTests.swift"
for path in "$IDENTITY_TOOL" "$CORPUS_TOOL" "$SOURCE_MANIFEST" "$CAPTURE_SOURCE"; do
  [ -f "$path" ] || {
    echo "P05 baseline harness file is absent: $path" >&2
    exit 66
  }
done
git -C "$REPOSITORY" rev-parse --git-dir >/dev/null 2>&1 || {
  echo "P05 baseline repository is not a git work tree: $REPOSITORY" >&2
  exit 66
}
if [ -e "$OUTPUT" ] && [ "$(find "$OUTPUT" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]; then
  echo "refusing to overwrite nonempty P05 output directory: $OUTPUT" >&2
  exit 65
fi
mkdir -p "$OUTPUT"

# The fixed source and DerivedData roots make the Release Mach-O identity a
# reproducible contract value. The lock directory prevents concurrent builds
# from sharing those paths.
BUILD_ROOT="${TMPDIR:-/tmp}/mirmir-p05-quality-baseline-v1"
LOCK_ROOT="${TMPDIR:-/tmp}/mirmir-p05-quality-baseline-v1.lock"
if ! mkdir "$LOCK_ROOT" 2>/dev/null; then
  echo "another frozen P05 quality build owns $LOCK_ROOT" >&2
  exit 75
fi
cleanup() {
  if [ "$KEEP_BUILD" -eq 1 ]; then
    echo "frozen P05 build retained at $BUILD_ROOT" >&2
  else
    case "$BUILD_ROOT" in
      */mirmir-p05-quality-baseline-v1) rm -rf "$BUILD_ROOT" ;;
      *) echo "refusing unsafe P05 build cleanup: $BUILD_ROOT" >&2 ;;
    esac
  fi
  rmdir "$LOCK_ROOT" 2>/dev/null || true
}
trap cleanup EXIT INT TERM
case "$BUILD_ROOT" in
  */mirmir-p05-quality-baseline-v1) rm -rf "$BUILD_ROOT" ;;
  *) echo "refusing unsafe P05 build preparation: $BUILD_ROOT" >&2; exit 70 ;;
esac
PROJECT="$BUILD_ROOT/project"
DERIVED_DATA="$BUILD_ROOT/DerivedData"
STAGED_CORPUS_ROOT="$BUILD_ROOT/corpus"
STAGED_CORPUS_MANIFEST="$STAGED_CORPUS_ROOT/corpus-manifest.json"
mkdir -p "$PROJECT"
mkdir -m 0700 "$STAGED_CORPUS_ROOT"

CORPUS_SHA=$(shasum -a 256 "$CORPUS_MANIFEST" | awk '{print $1}')
python3 - "$CORPUS_MANIFEST" "$STAGED_CORPUS_ROOT" "$CORPUS_SHA" "$SCRIPT_DIR" <<'PY'
from pathlib import Path
import hashlib
import json
import os
import re
import shutil
import stat
import sys

source_manifest = Path(sys.argv[1])
destination_root = Path(sys.argv[2])
expected_manifest_sha = sys.argv[3]
sys.path.insert(0, sys.argv[4])
import quality_gate_v4 as quality

sha_pattern = re.compile(r"^[0-9a-f]{64}$")


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


manifest_information = os.lstat(source_manifest)
require(
    stat.S_ISREG(manifest_information.st_mode)
    and not stat.S_ISLNK(manifest_information.st_mode),
    "corpus manifest is not a regular non-symlink file",
)
manifest_bytes = source_manifest.read_bytes()
manifest_sha = hashlib.sha256(manifest_bytes).hexdigest()
require(sha_pattern.fullmatch(expected_manifest_sha), "invalid expected corpus SHA-256")
require(manifest_sha == expected_manifest_sha, "corpus manifest changed during staging")
try:
    manifest = json.loads(manifest_bytes)
except (UnicodeDecodeError, json.JSONDecodeError) as error:
    raise SystemExit("corpus manifest is not canonical JSON input") from error
require(
    manifest.get("schemaVersion") == "mirmir-ash-v4-quality-corpus-v1",
    "unsupported corpus manifest schema",
)
artifacts = manifest.get("artifacts")
cases = manifest.get("cases")
require(isinstance(artifacts, list) and artifacts, "corpus artifact inventory is empty")
require(isinstance(cases, list) and cases, "corpus case inventory is empty")
require(manifest.get("caseCount") == len(cases), "corpus case count differs")

declared_paths: list[str] = []
for artifact in artifacts:
    require(
        isinstance(artifact, dict)
        and set(artifact) == {"path", "byteCount", "sha256"},
        "corpus artifact descriptor field set differs",
    )
    relative_text = artifact["path"]
    quality.checked_relative(source_manifest.parent, relative_text)
    require(
        isinstance(artifact["byteCount"], int) and artifact["byteCount"] >= 0,
        f"invalid corpus artifact byte count: {relative_text}",
    )
    require(
        isinstance(artifact["sha256"], str)
        and sha_pattern.fullmatch(artifact["sha256"]),
        f"invalid corpus artifact SHA-256: {relative_text}",
    )
    declared_paths.append(relative_text)
require(len(declared_paths) == len(set(declared_paths)), "duplicate corpus artifact path")
require(declared_paths == sorted(declared_paths), "corpus artifact inventory is not ordered")

referenced_paths: list[str] = []
for record in cases:
    require(isinstance(record, dict), "corpus case is not an object")
    for field in ("sourceFile", "referenceFile"):
        relative = record.get(field)
        require(isinstance(relative, str), f"corpus case {field} is not a string")
        quality.checked_relative(source_manifest.parent, relative)
        referenced_paths.append(relative)
require(
    len(referenced_paths) == len(set(referenced_paths)),
    "corpus cases reuse an artifact path",
)
require(
    sorted(referenced_paths) == declared_paths,
    "corpus case paths differ from the exact artifact inventory",
)

require(
    quality.artifact_set_sha(
        (artifact["path"], artifact["sha256"]) for artifact in artifacts
    ) == manifest.get("artifactSetSHA256"),
    "corpus artifact-set identity mismatch",
)

source_root = source_manifest.parent.resolve(strict=True)
quality.validate_artifacts(source_root, artifacts)
require(destination_root.is_dir(), "staged corpus root is absent")
require(
    stat.S_IMODE(destination_root.stat().st_mode) == 0o700,
    "staged corpus root is not mode 0700",
)
for artifact in artifacts:
    source = quality.checked_relative(source_root, artifact["path"])
    destination = destination_root / artifact["path"]
    destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(destination.parent, 0o700)
    shutil.copyfile(source, destination, follow_symlinks=False)
    os.chmod(destination, 0o600)

staged_manifest = destination_root / "corpus-manifest.json"
staged_manifest.write_bytes(manifest_bytes)
os.chmod(staged_manifest, 0o600)
quality.validate_artifacts(destination_root, artifacts)
require(staged_manifest.read_bytes() == manifest_bytes, "staged corpus manifest bytes differ")
for artifact in artifacts:
    source = quality.checked_relative(source_root, artifact["path"])
    destination = quality.checked_relative(destination_root, artifact["path"])
    require(destination.read_bytes() == source.read_bytes(), f"staged bytes differ: {artifact['path']}")
PY

SOURCE_REVISION="d3a4de55c08391ea8a08c00beb766b5650dc9f58"
ARCHIVE="$BUILD_ROOT/source.tar"
git -C "$REPOSITORY" archive --format=tar "$SOURCE_REVISION" >"$ARCHIVE"
tar -xf "$ARCHIVE" -C "$PROJECT"
python3 "$IDENTITY_TOOL" verify-source-manifest \
  --repository "$REPOSITORY" \
  --manifest "$SOURCE_MANIFEST" \
  --archive-root "$PROJECT" >/dev/null

mkdir -p "$PROJECT/script/v4"
cp "$CAPTURE_SOURCE" "$PROJECT/script/v4/P05QualityBaselineCaptureTests.swift"
python3 - "$PROJECT/Mirmir.xcodeproj/project.pbxproj" "$PROJECT/script/v4/P05QualityBaselineCaptureTests.swift" <<'PY'
from pathlib import Path
import sys

project = Path(sys.argv[1])
source = Path(sys.argv[2]).resolve()
text = project.read_text()
build_id = "C12000000000000000000005"
file_id = "C11000000000000000000005"
build_line = (
    f"\t\t{build_id} /* P05QualityBaselineCaptureTests.swift in Sources */ = "
    f"{{isa = PBXBuildFile; fileRef = {file_id} /* P05QualityBaselineCaptureTests.swift */; }};\n"
)
file_line = (
    f"\t\t{file_id} /* P05QualityBaselineCaptureTests.swift */ = "
    f"{{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; "
    f"path = \"{source}\"; sourceTree = \"<absolute>\"; }};\n"
)
build_marker = "/* End PBXBuildFile section */"
file_marker = "/* End PBXFileReference section */"
source_phase_id = "400000000000000000000004 /* Sources */ = {"
source_token = (
    "32000000000000000000004E "
    "/* DeterministicMetalBackendTests.swift in Sources */"
)
if text.count(build_marker) != 1 or text.count(file_marker) != 1:
    raise SystemExit("cannot locate unique P05 PBX sections")
phase_start = text.find(source_phase_id)
if phase_start < 0:
    raise SystemExit("cannot locate P05 test source phase")
files_start = text.find("files = (", phase_start)
files_end = text.find(");", files_start)
if files_start < 0 or files_end < 0:
    raise SystemExit("cannot locate P05 test source files")
source_files = text[files_start:files_end]
if source_files.count(source_token) != 1:
    raise SystemExit("cannot locate P05 test source anchor")
insertion = f"\n\t\t\t\t{build_id} /* P05QualityBaselineCaptureTests.swift in Sources */,"
if "\n" not in source_files:
    insertion = f" {build_id} /* P05QualityBaselineCaptureTests.swift in Sources */,"
text = text[:files_end] + insertion + text[files_end:]
text = text.replace(build_marker, build_line + build_marker)
text = text.replace(file_marker, file_line + file_marker)
project.write_text(text)
PY
plutil -lint "$PROJECT/Mirmir.xcodeproj/project.pbxproj" >/dev/null

BUILD_LOG="$OUTPUT/p05-xcodebuild.log"
(
  cd "$PROJECT"
  xcodebuild \
    -project Mirmir.xcodeproj \
    -scheme Mirmir \
    -configuration Release \
    -destination platform=macOS \
    -derivedDataPath "$DERIVED_DATA" \
    -parallel-testing-enabled NO \
    build-for-testing \
    CODE_SIGNING_ALLOWED=NO \
    ENABLE_TESTABILITY=YES \
    ONLY_ACTIVE_ARCH=YES
) >"$BUILD_LOG" 2>&1 || {
  tail -n 240 "$BUILD_LOG" >&2
  exit 1
}

P05_EXECUTABLE="$DERIVED_DATA/Build/Products/Release/Mirmir.app/Contents/MacOS/Mirmir"
P05_TEST_EXECUTABLE="$DERIVED_DATA/Build/Products/Release/Mirmir.app/Contents/PlugIns/MirmirTests.xctest/Contents/MacOS/MirmirTests"
[ -f "$P05_EXECUTABLE" ] || {
  echo "frozen P05 application executable is absent" >&2
  exit 66
}
[ -f "$P05_TEST_EXECUTABLE" ] || {
  echo "frozen P05 capture executable is absent" >&2
  exit 66
}
EXECUTABLE_SHA=$(shasum -a 256 "$P05_EXECUTABLE" | awk '{print $1}')
TEST_EXECUTABLE_SHA=$(shasum -a 256 "$P05_TEST_EXECUTABLE" | awk '{print $1}')
SOURCE_TREE_SHA=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["sourceTreeIdentitySHA256"])' "$SOURCE_MANIFEST")
SOURCE_MANIFEST_SHA=$(shasum -a 256 "$SOURCE_MANIFEST" | awk '{print $1}')
CAPTURE_SOURCE_SHA=$(shasum -a 256 "$CAPTURE_SOURCE" | awk '{print $1}')

if [ "$DISCOVER_EXECUTABLE" -eq 1 ]; then
  python3 - "$EXECUTABLE_SHA" "$TEST_EXECUTABLE_SHA" "$SOURCE_TREE_SHA" "$SOURCE_MANIFEST_SHA" "$CAPTURE_SOURCE_SHA" <<'PY'
import json
import sys
print(json.dumps({
    "executableSHA256": sys.argv[1],
    "captureExecutableSHA256": sys.argv[2],
    "sourceTreeIdentitySHA256": sys.argv[3],
    "sourceManifestSHA256": sys.argv[4],
    "captureSourceSHA256": sys.argv[5],
}, indent=2, sort_keys=True))
PY
  exit 0
fi

python3 - "$CONTRACT" "$SCRIPT_DIR" "$EXECUTABLE_SHA" "$TEST_EXECUTABLE_SHA" <<'PY'
from pathlib import Path
import json
import sys

sys.path.insert(0, sys.argv[2])
import p05_baseline_v4 as p05

contract = json.loads(Path(sys.argv[1]).read_text())
identity = p05.frozen_identity(contract)
if identity["executableSHA256"] != sys.argv[3]:
    raise SystemExit("frozen P05 executable identity mismatch")
if identity["captureExecutableSHA256"] != sys.argv[4]:
    raise SystemExit("frozen P05 capture-executable identity mismatch")
PY

CONTRACT_SHA=$(shasum -a 256 "$CONTRACT" | awk '{print $1}')
python3 - \
  "$BUILD_ROOT/capture-config.json" \
  "$OUTPUT" \
  "$STAGED_CORPUS_MANIFEST" \
  "$CONTRACT_SHA" \
  "$SOURCE_REVISION" \
  "$SOURCE_TREE_SHA" \
  "$SOURCE_MANIFEST_SHA" \
  "$CAPTURE_SOURCE_SHA" \
  "$EXECUTABLE_SHA" \
  "$TEST_EXECUTABLE_SHA" <<'PY'
from pathlib import Path
import json
import sys

keys = (
    "captureDirectory",
    "corpusManifest",
    "contractSHA256",
    "sourceRevision",
    "sourceTreeIdentitySHA256",
    "sourceManifestSHA256",
    "captureSourceSHA256",
    "executableSHA256",
    "captureExecutableSHA256",
)
Path(sys.argv[1]).write_text(
    json.dumps(dict(zip(keys, sys.argv[2:])), indent=2, sort_keys=True) + "\n"
)
PY
(
  cd "$PROJECT"
  xcodebuild \
    -project Mirmir.xcodeproj \
    -scheme Mirmir \
    -configuration Release \
    -destination platform=macOS \
    -derivedDataPath "$DERIVED_DATA" \
    -parallel-testing-enabled NO \
    test-without-building \
    -only-testing:MirmirTests/ASHP05QualityBaselineCaptureTests/testCaptureFrozenP05QualityCorpusWhenRequested \
    CODE_SIGNING_ALLOWED=NO \
    ENABLE_TESTABILITY=YES \
    ONLY_ACTIVE_ARCH=YES
) >>"$BUILD_LOG" 2>&1 || {
  tail -n 240 "$BUILD_LOG" >&2
  exit 1
}
[ -f "$OUTPUT/p05-capture-manifest.json" ] || {
  echo "frozen P05 capture completed without a manifest" >&2
  exit 66
}
python3 - "$OUTPUT/p05-capture-manifest.json" "$CONTRACT" "$SCRIPT_DIR" "$CORPUS_SHA" <<'PY'
from pathlib import Path
import json
import sys

sys.path.insert(0, sys.argv[3])
import p05_baseline_v4 as p05

manifest = json.loads(Path(sys.argv[1]).read_text())
contract = json.loads(Path(sys.argv[2]).read_text())
p05.require(manifest.get("schemaVersion") == "mirmir-ash-v4-quality-p05-capture-v1", "unsupported P05 capture")
p05.require(manifest.get("corpusManifestSHA256") == sys.argv[4], "P05 capture corpus identity mismatch")
p05.require_observed_identity(contract, manifest.get("baselineIdentity"))
PY

echo "$OUTPUT/p05-capture-manifest.json"
