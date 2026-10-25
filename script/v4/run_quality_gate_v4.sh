#!/bin/sh
set -eu

usage() {
  echo "usage: $0 --output DIRECTORY --candidate CANDIDATE.json --application-archive Mirmir.zip --runtime ASH-P06.bundle --release-configuration Release.xcconfig --corpus-manifest FILE [--diagnostic-synthetic] [--contract FILE] [--keep-work]" >&2
  exit 64
}

OUTPUT=""
CANDIDATE=""
APPLICATION_ARCHIVE=""
RUNTIME=""
RELEASE_CONFIGURATION=""
CONTRACT=""
CORPUS_MANIFEST=""
KEEP_WORK=0
DIAGNOSTIC_SYNTHETIC=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --output) [ "$#" -ge 2 ] || usage; OUTPUT=$2; shift 2 ;;
    --candidate) [ "$#" -ge 2 ] || usage; CANDIDATE=$2; shift 2 ;;
    --application-archive) [ "$#" -ge 2 ] || usage; APPLICATION_ARCHIVE=$2; shift 2 ;;
    --runtime) [ "$#" -ge 2 ] || usage; RUNTIME=$2; shift 2 ;;
    --release-configuration) [ "$#" -ge 2 ] || usage; RELEASE_CONFIGURATION=$2; shift 2 ;;
    --contract) [ "$#" -ge 2 ] || usage; CONTRACT=$2; shift 2 ;;
    --corpus-manifest) [ "$#" -ge 2 ] || usage; CORPUS_MANIFEST=$2; shift 2 ;;
    --diagnostic-synthetic) DIAGNOSTIC_SYNTHETIC=1; shift ;;
    --keep-work) KEEP_WORK=1; shift ;;
    *) usage ;;
  esac
done
[ -n "$OUTPUT" ] && [ -n "$CANDIDATE" ] && [ -n "$APPLICATION_ARCHIVE" ] \
  && [ -n "$RUNTIME" ] && [ -n "$RELEASE_CONFIGURATION" ] || usage

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPOSITORY=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)
absolute_existing() {
  python3 -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).expanduser().resolve(strict=True))' "$1"
}
absolute_output() {
  python3 -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).expanduser().resolve())' "$1"
}
extract_candidate_archive() {
  repository=$1
  revision=$2
  destination=$3
  archive=$4
  git -C "$repository" archive --format=tar "$revision" >"$archive"
  tar -xf "$archive" -C "$destination"
}
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
RUNNER_SOURCE=$(absolute_existing "$0")
CANDIDATE=$(absolute_existing "$CANDIDATE")
APPLICATION_ARCHIVE=$(absolute_existing "$APPLICATION_ARCHIVE")
RUNTIME=$(absolute_existing "$RUNTIME")
RELEASE_CONFIGURATION=$(absolute_existing "$RELEASE_CONFIGURATION")
OUTPUT=$(absolute_output "$OUTPUT")
if [ -e "$OUTPUT" ]; then
  echo "refusing to overwrite quality evidence: $OUTPUT" >&2
  exit 65
fi
mkdir -p "$(dirname -- "$OUTPUT")"
if [ -z "$CONTRACT" ]; then
  if [ "$DIAGNOSTIC_SYNTHETIC" -eq 1 ]; then
    CONTRACT="$SCRIPT_DIR/quality-gate-contract-v2.json"
  else
    CONTRACT="$SCRIPT_DIR/quality-gate-release-contract-v2.json"
  fi
fi
CONTRACT=$(absolute_existing "$CONTRACT")
if [ "$DIAGNOSTIC_SYNTHETIC" -eq 1 ]; then
  DEFAULT_CONTRACT=$(absolute_existing "$SCRIPT_DIR/quality-gate-contract-v2.json")
else
  DEFAULT_CONTRACT=$(absolute_existing "$SCRIPT_DIR/quality-gate-release-contract-v2.json")
fi
cmp -s "$CONTRACT" "$DEFAULT_CONTRACT" || {
  echo "release quality contract differs from the candidate-locked contract" >&2
  exit 66
}
if [ -n "$CORPUS_MANIFEST" ]; then
  CORPUS_MANIFEST=$(absolute_existing "$CORPUS_MANIFEST")
fi
if [ "$DIAGNOSTIC_SYNTHETIC" -eq 0 ] && [ -z "$CORPUS_MANIFEST" ]; then
  echo "release quality qualification requires the locked natural corpus manifest" >&2
  exit 66
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/mirmir-v4-quality.XXXXXX")
cleanup() {
  if [ "$KEEP_WORK" -eq 1 ]; then
    echo "quality workspace retained at $WORK" >&2
  else
    rm -rf "$WORK"
  fi
}
trap cleanup EXIT INT TERM

CAPTURE="$WORK/capture"
CORPUS="$WORK/corpus"
PACKAGED="$WORK/packaged-candidate"
mkdir -p "$CAPTURE"

TOOL="$SCRIPT_DIR/quality_gate_v4.py"
PACKAGED_TOOL="$SCRIPT_DIR/packaged_candidate_evidence_v4.py"
P05_RUNNER="$SCRIPT_DIR/run_p05_quality_baseline_v4.sh"
P05_TOOL="$SCRIPT_DIR/p05_baseline_v4.py"
P05_CAPTURE_SOURCE="$SCRIPT_DIR/P05QualityBaselineCaptureTests.swift"
P05_SOURCE_MANIFEST="$SCRIPT_DIR/p05-baseline-source-manifest-v1.json"
OBSERVER_SOURCE="$REPOSITORY/Mirmir/App/MirmirApp.swift"

# The candidate commit must contain the exact harness that is executing now.
python3 - "$REPOSITORY" "$CANDIDATE" \
  "script/v4/run_quality_gate_v4.sh" \
  "script/v4/quality_gate_v4.py" \
  "script/v4/chroma_geometry_v4.py" \
  "script/v4/packaged_candidate_evidence_v4.py" \
  "script/v4/run_p05_quality_baseline_v4.sh" \
  "script/v4/p05_baseline_v4.py" \
  "script/v4/quality-gate-contract-v2.json" \
  "script/v4/quality-gate-release-contract-v2.json" \
  "script/v4/natural-quality-corpus-lock-v2.json" \
  "script/v4/natural-quality-sources-v1.json" \
  "script/v4/build_natural_quality_corpus.py" \
  "script/v4/release_candidate_archive_v4.py" \
  "script/v4/P05QualityBaselineCaptureTests.swift" \
  "script/v4/p05-baseline-source-manifest-v1.json" \
  "Mirmir/App/MirmirApp.swift" <<'PY'
from pathlib import Path
import json
import subprocess
import sys

repository = Path(sys.argv[1]).resolve(strict=True)
candidate = json.loads(Path(sys.argv[2]).read_text())
candidate = candidate.get("candidate", candidate)
commit = candidate.get("sourceCommit")
if not isinstance(commit, str) or len(commit) != 40:
    raise SystemExit("candidate source commit is invalid")
for relative in sys.argv[3:]:
    process = subprocess.run(
        ["git", "show", f"{commit}:{relative}"],
        cwd=repository,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    local = repository / relative
    if process.returncode != 0 or not local.is_file() or local.is_symlink():
        raise SystemExit(f"candidate omits quality harness input: {relative}")
    if process.stdout != local.read_bytes():
        raise SystemExit(f"executing quality harness differs from candidate: {relative}")
PY
cmp -s "$RUNNER_SOURCE" "$REPOSITORY/script/v4/run_quality_gate_v4.sh" || {
  echo "executing quality runner is not the candidate-bound repository file" >&2
  exit 66
}

if [ -z "$CORPUS_MANIFEST" ]; then
  python3 "$TOOL" generate --contract "$CONTRACT" --output "$CORPUS"
  CORPUS_MANIFEST="$CORPUS/corpus-manifest.json"
fi

python3 - \
  "$CORPUS_MANIFEST" \
  "$CONTRACT" \
  "$SCRIPT_DIR/natural-quality-corpus-lock-v2.json" \
  "$DIAGNOSTIC_SYNTHETIC" <<'PY'
from pathlib import Path
import hashlib,json,sys

manifest_path, contract_path, lock_path = map(Path, sys.argv[1:4])
diagnostic = sys.argv[4] == "1"
manifest = json.loads(manifest_path.read_text())
contract_sha = hashlib.sha256(contract_path.read_bytes()).hexdigest()
if manifest.get("contractSHA256") != contract_sha:
    raise SystemExit("quality corpus contract identity differs")
if diagnostic:
    if manifest.get("releaseEligible") is not False or manifest.get("corpusKind") != "synthetic_diagnostic":
        raise SystemExit("diagnostic quality mode requires the synthetic diagnostic corpus")
    raise SystemExit(0)
lock = json.loads(lock_path.read_text())
checks = {
    "manifestSHA256": hashlib.sha256(manifest_path.read_bytes()).hexdigest(),
    "manifestByteCount": manifest_path.stat().st_size,
    "artifactSetSHA256": manifest.get("artifactSetSHA256"),
    "caseCount": len(manifest.get("cases", [])),
    "clipCount": len({case.get("clipID") for case in manifest.get("cases", [])}),
    "corpusID": manifest.get("corpusID"),
    "qualityContractSHA256": contract_sha,
}
for field, observed in checks.items():
    if lock.get(field) != observed:
        raise SystemExit(f"locked natural quality corpus differs: {field}")
if (
    lock.get("releaseEligible") is not True
    or manifest.get("releaseEligible") is not True
    or manifest.get("corpusKind") != "locked_natural"
):
    raise SystemExit("quality corpus is not release-eligible locked natural media")
PY

"$P05_RUNNER" \
  --repository "$REPOSITORY" \
  --output "$CAPTURE" \
  --contract "$CONTRACT" \
  --corpus-manifest "$CORPUS_MANIFEST"

python3 "$PACKAGED_TOOL" capture \
  --repository "$REPOSITORY" \
  --candidate "$CANDIDATE" \
  --application-archive "$APPLICATION_ARCHIVE" \
  --runtime "$RUNTIME" \
  --release-configuration "$RELEASE_CONFIGURATION" \
  --lane quality \
  --contract "$CONTRACT" \
  --corpus-manifest "$CORPUS_MANIFEST" \
  --output "$PACKAGED"

python3 - "$PACKAGED/capture" "$CAPTURE" <<'PY'
from pathlib import Path, PurePosixPath
import json
import shutil
import sys

source = Path(sys.argv[1]).resolve(strict=True)
destination = Path(sys.argv[2]).resolve(strict=True)
manifest = json.loads((source / "candidate-capture-manifest.json").read_text())
for case in manifest.get("cases", []):
    for relative in case.get("outputs", {}).values():
        pure = PurePosixPath(relative)
        if pure.is_absolute() or any(part in ("", ".", "..") for part in pure.parts):
            raise SystemExit(f"unsafe packaged quality output: {relative}")
        input_path = source.joinpath(*pure.parts).resolve(strict=True)
        input_path.relative_to(source)
        output_path = destination.joinpath(*pure.parts)
        if output_path.exists():
            raise SystemExit(f"packaged quality output collision: {relative}")
        output_path.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(input_path, output_path)
shutil.copyfile(
    source / "candidate-capture-manifest.json",
    destination / "candidate-capture-manifest.json",
)
PY

python3 "$TOOL" merge \
  --contract "$CONTRACT" \
  --corpus "$CORPUS_MANIFEST" \
  --p05-capture "$CAPTURE/p05-capture-manifest.json" \
  --candidate-capture "$CAPTURE/candidate-capture-manifest.json" \
  --output "$CAPTURE/capture-manifest.json"

mkdir "$OUTPUT"
python3 "$TOOL" evaluate \
  --contract "$CONTRACT" \
  --corpus "$CORPUS_MANIFEST" \
  --capture "$CAPTURE/capture-manifest.json" \
  --packaged-evidence "$PACKAGED" \
  --repository "$REPOSITORY" \
  --runtime "$RUNTIME" \
  --output "$OUTPUT/quality-gate-report.json"

python3 - "$CORPUS_MANIFEST" "$CAPTURE/capture-manifest.json" "$OUTPUT" <<'PY'
from pathlib import Path, PurePosixPath
import hashlib
import json
import shutil
import sys

corpus_path = Path(sys.argv[1]).resolve(strict=True)
capture_path = Path(sys.argv[2]).resolve(strict=True)
output = Path(sys.argv[3]).resolve(strict=True)
corpus = json.loads(corpus_path.read_text())
capture = json.loads(capture_path.read_text())
copied: dict[str, str] = {}

def copy(root: Path, relative: object, label: str) -> None:
    if not isinstance(relative, str) or "\\" in relative:
        raise SystemExit(f"unsafe {label} path")
    pure = PurePosixPath(relative)
    if pure.is_absolute() or any(part in ("", ".", "..") for part in pure.parts):
        raise SystemExit(f"unsafe {label} path: {relative}")
    source = root.joinpath(*pure.parts).resolve(strict=True)
    source.relative_to(root.resolve())
    if source.is_symlink() or not source.is_file():
        raise SystemExit(f"unsafe {label} artifact: {relative}")
    destination = output.joinpath(*pure.parts)
    identity = hashlib.sha256(source.read_bytes()).hexdigest()
    if destination.exists():
        if copied.get(relative) != identity:
            raise SystemExit(f"quality artifact collision: {relative}")
        return
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source, destination)
    copied[relative] = identity

corpus_root = corpus_path.parent.resolve()
for index, artifact in enumerate(corpus.get("artifacts", [])):
    copy(corpus_root, artifact.get("path"), f"corpus[{index}]")
capture_root = capture_path.parent.resolve()
for index, case in enumerate(capture.get("cases", [])):
    for variant, relative in case.get("outputs", {}).items():
        copy(capture_root, relative, f"capture[{index}].{variant}")
for relative in (
    "candidate-capture-manifest.json",
    "p05-capture-manifest.json",
    "p05-xcodebuild.log",
):
    copy(capture_root, relative, f"capture provenance {relative}")
shutil.copyfile(corpus_path, output / "corpus-manifest.json")
shutil.copyfile(capture_path, output / "capture-manifest.json")
PY

cp -R "$PACKAGED" "$OUTPUT/packaged-candidate"
cp "$CONTRACT" "$OUTPUT/quality-gate-contract-v2.json"
mkdir "$OUTPUT/bindings"
cp "$TOOL" "$OUTPUT/bindings/quality_gate_v4.py"
cp "$SCRIPT_DIR/chroma_geometry_v4.py" "$OUTPUT/bindings/chroma_geometry_v4.py"
cp "$PACKAGED_TOOL" "$OUTPUT/bindings/packaged_candidate_evidence_v4.py"
cp "$P05_TOOL" "$OUTPUT/bindings/p05_baseline_v4.py"
cp "$P05_CAPTURE_SOURCE" "$OUTPUT/bindings/P05QualityBaselineCaptureTests.swift"
cp "$P05_SOURCE_MANIFEST" "$OUTPUT/bindings/p05-baseline-source-manifest-v1.json"
cp "$P05_RUNNER" "$OUTPUT/bindings/run_p05_quality_baseline_v4.sh"
cp "$OBSERVER_SOURCE" "$OUTPUT/bindings/MirmirApp.swift"
cp "$RUNNER_SOURCE" "$OUTPUT/bindings/run_quality_gate_v4.sh"
cp "$SCRIPT_DIR/natural-quality-corpus-lock-v2.json" \
  "$OUTPUT/bindings/natural-quality-corpus-lock-v2.json"
cp "$SCRIPT_DIR/build_natural_quality_corpus.py" \
  "$OUTPUT/bindings/build_natural_quality_corpus.py"
cp "$SCRIPT_DIR/natural-quality-sources-v1.json" \
  "$OUTPUT/bindings/natural-quality-sources-v1.json"

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

if [ "$DIAGNOSTIC_SYNTHETIC" -eq 0 ]; then
  python3 "$TOOL" verify \
    --contract "$OUTPUT/quality-gate-contract-v2.json" \
    --report "$OUTPUT/quality-gate-report.json" \
    --repository "$REPOSITORY" \
    --runtime "$RUNTIME" \
    --require-release
else
  python3 "$TOOL" verify \
    --contract "$OUTPUT/quality-gate-contract-v2.json" \
    --report "$OUTPUT/quality-gate-report.json" \
    --repository "$REPOSITORY" \
    --runtime "$RUNTIME"
fi

echo "$OUTPUT"
