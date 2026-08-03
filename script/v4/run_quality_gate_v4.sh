#!/bin/sh
set -eu

usage() {
  echo "usage: $0 --output DIRECTORY [--contract FILE] [--corpus-manifest FILE] [--derived-data DIRECTORY] [--keep-work]" >&2
  exit 64
}

OUTPUT=""
DERIVED_DATA=""
KEEP_WORK=0
CONTRACT=""
CORPUS_MANIFEST=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --output)
      [ "$#" -ge 2 ] || usage
      OUTPUT=$2
      shift 2
      ;;
    --derived-data)
      [ "$#" -ge 2 ] || usage
      DERIVED_DATA=$2
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
    --keep-work)
      KEEP_WORK=1
      shift
      ;;
    *) usage ;;
  esac
done
[ -n "$OUTPUT" ] || usage

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPOSITORY=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)
if [ -z "$CONTRACT" ]; then
  CONTRACT="$SCRIPT_DIR/quality-gate-contract-v1.json"
fi
CONTRACT=$(python3 -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).expanduser().resolve())' "$CONTRACT")
[ -f "$CONTRACT" ] || {
  echo "quality contract is not a regular file: $CONTRACT" >&2
  exit 66
}
if [ -n "$CORPUS_MANIFEST" ]; then
  CORPUS_MANIFEST=$(python3 -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).expanduser().resolve())' "$CORPUS_MANIFEST")
  [ -f "$CORPUS_MANIFEST" ] || {
    echo "corpus manifest is not a regular file: $CORPUS_MANIFEST" >&2
    exit 66
  }
fi
TOOL="$SCRIPT_DIR/quality_gate_v4.py"
CAPTURE_SOURCE="$SCRIPT_DIR/QualityGateCaptureTests.swift"
OUTPUT=$(python3 -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).expanduser().resolve())' "$OUTPUT")
if [ -e "$OUTPUT" ] && [ "$(find "$OUTPUT" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]; then
  echo "refusing to overwrite nonempty output directory: $OUTPUT" >&2
  exit 65
fi
mkdir -p "$OUTPUT"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/mirmir-v4-quality.XXXXXX")
cleanup() {
  if [ "$KEEP_WORK" -eq 1 ]; then
    echo "ephemeral quality workspace retained at $WORK" >&2
  else
    rm -rf "$WORK"
  fi
}
trap cleanup EXIT INT TERM

PROJECT="$WORK/project"
CORPUS="$WORK/corpus"
CAPTURE="$WORK/capture"
mkdir -p "$PROJECT" "$CAPTURE"
rsync -a \
  --exclude '.git/' \
  --exclude 'output/' \
  --exclude 'DerivedData/' \
  --exclude 'docs/v4/evidence/m3-quality-calibration-*' \
  "$REPOSITORY/" "$PROJECT/"

if [ -z "$CORPUS_MANIFEST" ]; then
  python3 "$TOOL" generate --contract "$CONTRACT" --output "$CORPUS"
  CORPUS_MANIFEST="$CORPUS/corpus-manifest.json"
fi

python3 - "$PROJECT/Mirmir.xcodeproj/project.pbxproj" "$PROJECT/script/v4/QualityGateCaptureTests.swift" <<'PY'
from pathlib import Path
import sys

project = Path(sys.argv[1])
source = Path(sys.argv[2]).resolve()
text = project.read_text()
build_id = "C12000000000000000000001"
file_id = "C11000000000000000000001"
build_line = (
    f"\t\t{build_id} /* QualityGateCaptureTests.swift in Sources */ = "
    f"{{isa = PBXBuildFile; fileRef = {file_id} /* QualityGateCaptureTests.swift */; }};\n"
)
file_line = (
    f"\t\t{file_id} /* QualityGateCaptureTests.swift */ = "
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
    raise SystemExit("cannot locate unique PBX sections")
phase_start = text.find(source_phase_id)
if phase_start < 0:
    raise SystemExit("cannot locate unique MirmirTests source phase")
files_start = text.find("files = (", phase_start)
files_end = text.find(");", files_start)
if files_start < 0 or files_end < 0:
    raise SystemExit("cannot locate MirmirTests source files")
source_files = text[files_start:files_end]
if source_files.count(source_token) != 1:
    raise SystemExit("cannot locate MirmirTests source anchor")
if "\n" in source_files:
    insertion = f"\n\t\t\t\t{build_id} /* QualityGateCaptureTests.swift in Sources */,"
else:
    insertion = f" {build_id} /* QualityGateCaptureTests.swift in Sources */,"
text = text[:files_end] + insertion + text[files_end:]
text = text.replace(build_marker, build_line + build_marker)
text = text.replace(file_marker, file_line + file_marker)
project.write_text(text)
PY
plutil -lint "$PROJECT/Mirmir.xcodeproj/project.pbxproj" >/dev/null

CONTRACT_SHA=$(shasum -a 256 "$CONTRACT" | awk '{print $1}')
CORPUS_SHA=$(shasum -a 256 "$CORPUS_MANIFEST" | awk '{print $1}')
SOURCE_COMMIT=$(git -C "$REPOSITORY" rev-parse HEAD)
SOURCE_TREE_SHA=$(python3 - "$PROJECT" <<'PY'
from pathlib import Path
import hashlib
import sys

root = Path(sys.argv[1]).resolve()
digest = hashlib.sha256()
digest.update(b"mirmir-v4-quality-source-tree-v1\0")
paths = sorted(
    path for path in root.rglob("*")
    if path.is_file()
    and path.suffix in {".swift", ".metal", ".json", ".sh", ".py"}
    and "/docs/v4/evidence/" not in str(path)
)
for path in paths:
    relative = path.relative_to(root).as_posix()
    digest.update(relative.encode())
    digest.update(b"\0")
    digest.update(hashlib.sha256(path.read_bytes()).digest())
print(digest.hexdigest())
PY
)

python3 - \
  "$PROJECT/script/v4/QualityGateCaptureTests.swift" \
  "$CAPTURE" \
  "$CORPUS_MANIFEST" \
  "$CONTRACT_SHA" \
  "$SOURCE_COMMIT" \
  "$SOURCE_TREE_SHA" <<'PY'
from pathlib import Path
import json
import sys

path = Path(sys.argv[1])
values = {
    "__MIRMIR_V4_QUALITY_CAPTURE_DIR__": sys.argv[2],
    "__MIRMIR_V4_QUALITY_CORPUS_MANIFEST__": sys.argv[3],
    "__MIRMIR_V4_QUALITY_CONTRACT_SHA256__": sys.argv[4],
    "__MIRMIR_V4_QUALITY_SOURCE_COMMIT__": sys.argv[5],
    "__MIRMIR_V4_QUALITY_SOURCE_TREE_SHA256__": sys.argv[6],
}
text = path.read_text()
for sentinel, value in values.items():
    quoted = json.dumps(sentinel)
    if text.count(quoted) != 1:
        raise SystemExit(f"capture sentinel is not unique: {sentinel}")
    text = text.replace(quoted, json.dumps(value))
path.write_text(text)
PY

if [ -z "$DERIVED_DATA" ]; then
  DERIVED_DATA="$WORK/DerivedData"
fi
BUILD_LOG="$OUTPUT/xcodebuild.log"
(
  cd "$PROJECT"
  MIRMIR_V4_QUALITY_CAPTURE_DIR="$CAPTURE" \
  MIRMIR_V4_QUALITY_CORPUS_MANIFEST="$CORPUS_MANIFEST" \
  MIRMIR_V4_QUALITY_CONTRACT_SHA256="$CONTRACT_SHA" \
  MIRMIR_V4_QUALITY_SOURCE_COMMIT="$SOURCE_COMMIT" \
  MIRMIR_V4_QUALITY_SOURCE_TREE_SHA256="$SOURCE_TREE_SHA" \
  xcodebuild \
    -project Mirmir.xcodeproj \
    -scheme Mirmir \
    -configuration Release \
    -destination platform=macOS \
    -derivedDataPath "$DERIVED_DATA" \
    -parallel-testing-enabled NO \
    test \
    -only-testing:MirmirTests/ASHV4QualityGateCaptureTests/testCapturePreregisteredQualityCorpusWhenRequested \
    CODE_SIGNING_ALLOWED=NO \
    ENABLE_TESTABILITY=YES \
    ONLY_ACTIVE_ARCH=YES \
    "MIRMIR_V4_QUALITY_CAPTURE_DIR=$CAPTURE" \
    "MIRMIR_V4_QUALITY_CORPUS_MANIFEST=$CORPUS_MANIFEST" \
    "MIRMIR_V4_QUALITY_CONTRACT_SHA256=$CONTRACT_SHA" \
    "MIRMIR_V4_QUALITY_SOURCE_COMMIT=$SOURCE_COMMIT" \
    "MIRMIR_V4_QUALITY_SOURCE_TREE_SHA256=$SOURCE_TREE_SHA"
) >"$BUILD_LOG" 2>&1 || {
  tail -n 240 "$BUILD_LOG" >&2
  exit 1
}

[ -f "$CAPTURE/capture-manifest.json" ] || {
  echo "quality capture completed without a capture manifest" >&2
  exit 66
}
python3 "$TOOL" evaluate \
  --contract "$CONTRACT" \
  --corpus "$CORPUS_MANIFEST" \
  --capture "$CAPTURE/capture-manifest.json" \
  --output "$OUTPUT/quality-gate-report.json"
python3 "$TOOL" verify \
  --contract "$CONTRACT" \
  --report "$OUTPUT/quality-gate-report.json"

cp "$CONTRACT" "$OUTPUT/quality-gate-contract-v1.json"
cp "$CORPUS_MANIFEST" "$OUTPUT/corpus-manifest.json"
cp "$CAPTURE/capture-manifest.json" "$OUTPUT/capture-manifest.json"
python3 - "$OUTPUT" <<'PY'
from pathlib import Path
import hashlib
import json
import sys

root = Path(sys.argv[1]).resolve()
artifacts = []
for path in sorted(root.iterdir()):
    if path.is_file() and path.name != "artifact-manifest.json":
        artifacts.append({
            "path": path.name,
            "byteCount": path.stat().st_size,
            "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
        })
(root / "artifact-manifest.json").write_text(
    json.dumps(
        {"schemaVersion": "mirmir-ash-v4-quality-evidence-manifest-v1", "artifacts": artifacts},
        indent=2,
        sort_keys=True,
    ) + "\n"
)
PY

echo "$OUTPUT"
