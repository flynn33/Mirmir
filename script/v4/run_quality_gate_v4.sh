#!/bin/sh
set -eu

usage() {
  echo "usage: $0 --output DIRECTORY [--candidate-revision REVISION] [--contract FILE] [--corpus-manifest FILE] [--derived-data DIRECTORY] [--keep-work]" >&2
  exit 64
}

OUTPUT=""
DERIVED_DATA=""
KEEP_WORK=0
CONTRACT=""
CORPUS_MANIFEST=""
CANDIDATE_REVISION="HEAD"
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
    --candidate-revision)
      [ "$#" -ge 2 ] || usage
      CANDIDATE_REVISION=$2
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
RUNNER_SOURCE=$(python3 -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).resolve(strict=True))' "$0")
if [ -n "$CONTRACT" ]; then
  CONTRACT=$(python3 -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).expanduser().resolve())' "$CONTRACT")
  [ -f "$CONTRACT" ] || {
    echo "quality contract is not a regular file: $CONTRACT" >&2
    exit 66
  }
fi
if [ -n "$CORPUS_MANIFEST" ]; then
  CORPUS_MANIFEST=$(python3 -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).expanduser().resolve())' "$CORPUS_MANIFEST")
  [ -f "$CORPUS_MANIFEST" ] || {
    echo "corpus manifest is not a regular file: $CORPUS_MANIFEST" >&2
    exit 66
  }
fi
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

SOURCE_COMMIT=$(git -C "$REPOSITORY" rev-parse --verify "${CANDIDATE_REVISION}^{commit}")
CANDIDATE_ARCHIVE="$WORK/candidate.tar"
extract_candidate_archive() {
  repository=$1
  revision=$2
  destination=$3
  archive=$4
  git -C "$repository" archive --format=tar "$revision" >"$archive"
  tar -xf "$archive" -C "$destination"
}
extract_candidate_archive "$REPOSITORY" "$SOURCE_COMMIT" "$PROJECT" "$CANDIDATE_ARCHIVE"

for path in \
  script/v4/run_quality_gate_v4.sh \
  script/v4/run_p05_quality_baseline_v4.sh \
  script/v4/quality_gate_v4.py \
  script/v4/p05_baseline_v4.py \
  script/v4/QualityGateCaptureTests.swift \
  script/v4/P05QualityBaselineCaptureTests.swift \
  script/v4/p05-baseline-source-manifest-v1.json \
  script/v4/quality-gate-contract-v1.json; do
  [ -f "$PROJECT/$path" ] || {
    echo "candidate revision omits quality harness file: $path" >&2
    exit 66
  }
done
cmp -s "$RUNNER_SOURCE" "$PROJECT/script/v4/run_quality_gate_v4.sh" || {
  echo "candidate revision does not bind the executing quality runner" >&2
  exit 66
}

SEALED_TOOLS="$WORK/sealed-tools"
mkdir -p "$SEALED_TOOLS"
cp "$PROJECT/script/v4/quality_gate_v4.py" "$SEALED_TOOLS/quality_gate_v4.py"
cp "$PROJECT/script/v4/p05_baseline_v4.py" "$SEALED_TOOLS/p05_baseline_v4.py"
cp "$PROJECT/script/v4/QualityGateCaptureTests.swift" "$SEALED_TOOLS/QualityGateCaptureTests.swift"
cp "$PROJECT/script/v4/P05QualityBaselineCaptureTests.swift" "$SEALED_TOOLS/P05QualityBaselineCaptureTests.swift"
cp "$PROJECT/script/v4/p05-baseline-source-manifest-v1.json" "$SEALED_TOOLS/p05-baseline-source-manifest-v1.json"
cp "$PROJECT/script/v4/run_p05_quality_baseline_v4.sh" "$SEALED_TOOLS/run_p05_quality_baseline_v4.sh"
TOOL="$SEALED_TOOLS/quality_gate_v4.py"
CAPTURE_SOURCE="$SEALED_TOOLS/QualityGateCaptureTests.swift"
P05_CAPTURE_SOURCE="$SEALED_TOOLS/P05QualityBaselineCaptureTests.swift"
P05_IDENTITY_TOOL="$SEALED_TOOLS/p05_baseline_v4.py"
P05_SOURCE_MANIFEST="$SEALED_TOOLS/p05-baseline-source-manifest-v1.json"
P05_RUNNER="$SEALED_TOOLS/run_p05_quality_baseline_v4.sh"
if [ -z "$CONTRACT" ]; then
  CONTRACT="$PROJECT/script/v4/quality-gate-contract-v1.json"
fi

if [ -z "$CORPUS_MANIFEST" ]; then
  python3 "$TOOL" generate --contract "$CONTRACT" --output "$CORPUS"
  CORPUS_MANIFEST="$CORPUS/corpus-manifest.json"
fi

"$P05_RUNNER" \
  --repository "$REPOSITORY" \
  --output "$CAPTURE" \
  --contract "$CONTRACT" \
  --corpus-manifest "$CORPUS_MANIFEST"

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
source_tree_identity() {
  repository=$1
  revision=$2
  python3 - "$repository" "$revision" <<'PY'
import hashlib
import subprocess
import sys

repository, revision = sys.argv[1:]
process = subprocess.run(
    ["git", "ls-tree", "-r", "-z", "--full-tree", revision],
    cwd=repository,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    check=False,
)
if process.returncode != 0:
    raise SystemExit(
        "cannot resolve source tree: "
        + process.stderr.decode("utf-8", errors="replace").strip()
    )
print(hashlib.sha256(b"mirmir-source-tree-v1\0" + process.stdout).hexdigest())
PY
}
SOURCE_TREE_SHA=$(source_tree_identity "$REPOSITORY" "$SOURCE_COMMIT")

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

[ -f "$CAPTURE/candidate-capture-manifest.json" ] || {
  echo "candidate quality capture completed without a manifest" >&2
  exit 66
}
python3 "$TOOL" merge \
  --contract "$CONTRACT" \
  --corpus "$CORPUS_MANIFEST" \
  --p05-capture "$CAPTURE/p05-capture-manifest.json" \
  --candidate-capture "$CAPTURE/candidate-capture-manifest.json" \
  --output "$CAPTURE/capture-manifest.json"
python3 "$TOOL" evaluate \
  --contract "$CONTRACT" \
  --corpus "$CORPUS_MANIFEST" \
  --capture "$CAPTURE/capture-manifest.json" \
  --output "$OUTPUT/quality-gate-report.json"

python3 - "$CORPUS_MANIFEST" "$CAPTURE/capture-manifest.json" "$OUTPUT" <<'PY'
from pathlib import Path, PurePosixPath
import hashlib
import json
import shutil
import sys

corpus_manifest_input = Path(sys.argv[1])
capture_manifest_input = Path(sys.argv[2])
destination_root = Path(sys.argv[3]).resolve()

if corpus_manifest_input.is_symlink() or capture_manifest_input.is_symlink():
    raise SystemExit("quality manifests must not be symbolic links")
corpus_manifest_path = corpus_manifest_input.resolve(strict=True)
capture_manifest_path = capture_manifest_input.resolve(strict=True)

corpus = json.loads(corpus_manifest_path.read_text())
capture = json.loads(capture_manifest_path.read_text())
copied: dict[str, tuple[str, Path]] = {}


def checked_file(root: Path, relative: object, label: str) -> tuple[str, Path]:
    if not isinstance(relative, str) or "\\" in relative:
        raise SystemExit(f"{label} path is not canonical: {relative}")
    pure = PurePosixPath(relative)
    if pure.is_absolute() or not pure.parts or any(part in {"", ".", ".."} for part in pure.parts):
        raise SystemExit(f"{label} path escapes its artifact root: {relative}")
    candidate = root.joinpath(*pure.parts)
    try:
        resolved = candidate.resolve(strict=True)
        resolved.relative_to(root.resolve())
    except (OSError, ValueError) as error:
        raise SystemExit(f"{label} artifact is missing or escapes its root: {relative}") from error
    current = candidate
    while current != root:
        if current.is_symlink():
            raise SystemExit(f"{label} artifact path contains a symbolic link: {relative}")
        current = current.parent
    if not resolved.is_file():
        raise SystemExit(f"{label} artifact is not a regular file: {relative}")
    return pure.as_posix(), resolved


def copy_artifact(root: Path, relative: object, label: str) -> Path:
    canonical, source = checked_file(root, relative, label)
    previous = copied.get(canonical)
    if previous is not None:
        previous_label, previous_source = previous
        if previous_source != source:
            raise SystemExit(
                f"quality artifact path collision: {canonical} ({previous_label}, {label})"
            )
        return destination_root.joinpath(*PurePosixPath(canonical).parts)
    destination = destination_root.joinpath(*PurePosixPath(canonical).parts)
    if destination.exists():
        raise SystemExit(f"quality artifact would overwrite evidence: {canonical}")
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source, destination)
    copied[canonical] = (label, source)
    return destination


def closed_files(root: Path, manifest_path: Path, expected: set[Path], label: str) -> None:
    actual: set[Path] = set()
    for path in root.rglob("*"):
        if path.is_symlink():
            raise SystemExit(f"{label} tree contains a symbolic link: {path}")
        if path.is_file():
            actual.add(path.resolve())
    expected_with_manifest = set(expected)
    expected_with_manifest.add(manifest_path)
    if actual != expected_with_manifest:
        missing = sorted(path.as_posix() for path in expected_with_manifest - actual)
        unexpected = sorted(path.as_posix() for path in actual - expected_with_manifest)
        raise SystemExit(
            f"{label} artifact tree is not closed; missing={missing}, unexpected={unexpected}"
        )


corpus_root = corpus_manifest_path.parent.resolve()
corpus_sources: set[Path] = set()
for index, artifact in enumerate(corpus.get("artifacts", [])):
    if not isinstance(artifact, dict):
        raise SystemExit(f"quality corpus artifact[{index}] is invalid")
    destination = copy_artifact(corpus_root, artifact.get("path"), f"corpus[{index}]")
    source = copied[destination.relative_to(destination_root).as_posix()][1]
    if source.stat().st_size != artifact.get("byteCount"):
        raise SystemExit(f"quality corpus artifact[{index}] byte count differs")
    if hashlib.sha256(source.read_bytes()).hexdigest() != artifact.get("sha256"):
        raise SystemExit(f"quality corpus artifact[{index}] SHA-256 differs")
    corpus_sources.add(source)
closed_files(corpus_root, corpus_manifest_path, corpus_sources, "quality corpus")

capture_root = capture_manifest_path.parent.resolve()
capture_sources: set[Path] = set()
cases = capture.get("cases")
if not isinstance(cases, list) or not cases:
    raise SystemExit("quality capture cases are absent")
for case_index, case in enumerate(cases):
    outputs = case.get("outputs") if isinstance(case, dict) else None
    if not isinstance(outputs, dict):
        raise SystemExit(f"quality capture case[{case_index}] outputs are invalid")
    for variant, relative in outputs.items():
        destination = copy_artifact(
            capture_root, relative, f"capture[{case_index}].{variant}"
        )
        capture_sources.add(
            copied[destination.relative_to(destination_root).as_posix()][1]
        )
for relative in (
    "candidate-capture-manifest.json",
    "p05-capture-manifest.json",
    "p05-xcodebuild.log",
):
    destination = copy_artifact(capture_root, relative, f"capture-provenance.{relative}")
    capture_sources.add(
        copied[destination.relative_to(destination_root).as_posix()][1]
    )
closed_files(capture_root, capture_manifest_path, capture_sources, "quality capture")

shutil.copyfile(corpus_manifest_path, destination_root / "corpus-manifest.json")
shutil.copyfile(capture_manifest_path, destination_root / "capture-manifest.json")
PY

cp "$CONTRACT" "$OUTPUT/quality-gate-contract-v1.json"
mkdir -p "$OUTPUT/bindings"
cp "$TOOL" "$OUTPUT/bindings/quality_gate_v4.py"
cp "$P05_IDENTITY_TOOL" "$OUTPUT/bindings/p05_baseline_v4.py"
cp "$CAPTURE_SOURCE" "$OUTPUT/bindings/QualityGateCaptureTests.swift"
cp "$P05_CAPTURE_SOURCE" "$OUTPUT/bindings/P05QualityBaselineCaptureTests.swift"
cp "$P05_SOURCE_MANIFEST" "$OUTPUT/bindings/p05-baseline-source-manifest-v1.json"
cp "$P05_RUNNER" "$OUTPUT/bindings/run_p05_quality_baseline_v4.sh"
cp "$RUNNER_SOURCE" "$OUTPUT/bindings/run_quality_gate_v4.sh"

python3 - "$OUTPUT" <<'PY'
from pathlib import Path
import hashlib
import json
import sys

root = Path(sys.argv[1]).resolve()
artifacts = []
for path in sorted(root.rglob("*"), key=lambda value: value.relative_to(root).as_posix()):
    if path.is_symlink():
        raise SystemExit(f"quality evidence contains a symbolic link: {path}")
    if path.is_file() and path != root / "artifact-manifest.json":
        artifacts.append({
            "path": path.relative_to(root).as_posix(),
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

python3 "$TOOL" verify \
  --contract "$OUTPUT/quality-gate-contract-v1.json" \
  --report "$OUTPUT/quality-gate-report.json"

echo "$OUTPUT"
