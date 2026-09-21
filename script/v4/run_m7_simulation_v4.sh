#!/bin/sh
set -eu

usage() {
  echo "usage: $0 --output DIRECTORY [--derived-data DIRECTORY] [--keep-work]" >&2
  exit 64
}

OUTPUT=""
DERIVED_DATA=""
KEEP_WORK=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --output) [ "$#" -ge 2 ] || usage; OUTPUT=$2; shift 2 ;;
    --derived-data) [ "$#" -ge 2 ] || usage; DERIVED_DATA=$2; shift 2 ;;
    --keep-work) KEEP_WORK=1; shift ;;
    *) usage ;;
  esac
done
[ -n "$OUTPUT" ] || usage

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPOSITORY=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)
OUTPUT=$(python3 -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).expanduser().resolve())' "$OUTPUT")
if [ -e "$OUTPUT" ]; then
  echo "refusing to overwrite M7 simulation evidence: $OUTPUT" >&2
  exit 65
fi
git -C "$REPOSITORY" diff --quiet --ignore-submodules -- || {
  echo "M7 simulation requires a clean tracked working tree" >&2
  exit 66
}
git -C "$REPOSITORY" diff --cached --quiet --ignore-submodules -- || {
  echo "M7 simulation requires a clean index" >&2
  exit 66
}
XCODE_VERSION=$(xcodebuild -version)
if [ -n "$DERIVED_DATA" ]; then
  DERIVED_DATA=$(python3 -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).expanduser().resolve())' "$DERIVED_DATA")
  if { [ -e "$DERIVED_DATA" ] && [ ! -d "$DERIVED_DATA" ]; } ||
    [ -L "$DERIVED_DATA" ] || {
    [ -d "$DERIVED_DATA" ] &&
    [ -n "$(find "$DERIVED_DATA" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ];
  }; then
    echo "M7 DerivedData must be absent or an empty regular directory: $DERIVED_DATA" >&2
    exit 65
  fi
fi

SOURCE_COMMIT=$(git -C "$REPOSITORY" rev-parse HEAD)
SOURCE_TREE_SHA=$(python3 - "$REPOSITORY" "$SOURCE_COMMIT" <<'PY'
from pathlib import Path
import hashlib
import subprocess
import sys

repository = Path(sys.argv[1])
revision = sys.argv[2]
listing = subprocess.run(
    ["git", "ls-tree", "-r", "-z", "--full-tree", revision],
    cwd=repository,
    check=True,
    stdout=subprocess.PIPE,
).stdout
print(hashlib.sha256(b"mirmir-source-tree-v1\0" + listing).hexdigest())
PY
)

WORK=$(mktemp -d "${TMPDIR:-/tmp}/mirmir-m7-simulation.XXXXXX")
cleanup() {
  if [ "$KEEP_WORK" -eq 1 ]; then
    echo "M7 simulation workspace retained at $WORK" >&2
  else
    case "$WORK" in
      */mirmir-m7-simulation.*) rm -rf "$WORK" ;;
      *) echo "refusing unsafe M7 workspace cleanup: $WORK" >&2 ;;
    esac
  fi
}
trap cleanup EXIT INT TERM

PROJECT="$WORK/project"
CORPUS="$WORK/corpus"
DISCOVERY_CORPUS="$WORK/discovery-corpus"
CAPTURE="$WORK/capture"
P05_DISCOVERY_OUTPUT="$WORK/p05-discovery"
P05_DISCOVERY="$WORK/p05-discovery.json"
P05_TOOLCHAIN_BINDING="$WORK/m7-p05-toolchain-binding.json"
CANDIDATE_LOG="$WORK/candidate-xcodebuild.log"
mkdir -p "$PROJECT" "$CAPTURE"
git -C "$REPOSITORY" archive --format=tar "$SOURCE_COMMIT" | tar -xf - -C "$PROJECT"

CANONICAL_CONTRACT="$PROJECT/script/v4/quality-gate-contract-v1.json"
CONTRACT="$WORK/quality-gate-contract-v1.json"
SELECTION_CONTRACT="$PROJECT/script/v4/m7-simulation-selection-contract-v1.json"
QUALITY_TOOL="$PROJECT/script/v4/quality_gate_v4.py"
SELECTION_TOOL="$PROJECT/script/v4/select_simulated_candidate_v4.py"
DERIVE_TOOL="$PROJECT/script/v4/derive_m7_quality_contract_v4.py"
P05_RUNNER="$PROJECT/script/v4/run_p05_quality_baseline_v4.sh"
CANONICAL_CAPTURE_SOURCE="$PROJECT/script/v4/QualityGateCaptureTests.swift"
CAPTURE_SOURCE="$WORK/QualityGateCaptureTests.injected.swift"
CAPTURE_BINDING="$WORK/m7-capture-binding.json"
SIMULATOR_ENVIRONMENT="$WORK/simulator-environment.json"
for path in \
  "$CANONICAL_CONTRACT" \
  "$SELECTION_CONTRACT" \
  "$QUALITY_TOOL" \
  "$SELECTION_TOOL" \
  "$DERIVE_TOOL" \
  "$P05_RUNNER" \
  "$CANONICAL_CAPTURE_SOURCE"; do
  [ -f "$path" ] || {
    echo "M7 simulator input is absent: $path" >&2
    exit 66
  }
done
cp "$CANONICAL_CAPTURE_SOURCE" "$CAPTURE_SOURCE"

python3 - "$SIMULATOR_ENVIRONMENT" "$SOURCE_COMMIT" "$SOURCE_TREE_SHA" "$XCODE_VERSION" <<'PY'
from __future__ import annotations

from pathlib import Path
import json
import platform
import subprocess
import sys


def output(*arguments: str) -> str:
    return subprocess.run(arguments, check=True, text=True, stdout=subprocess.PIPE).stdout.strip()


def optional_output(*arguments: str) -> str | None:
    completed = subprocess.run(arguments, text=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    value = completed.stdout.strip()
    return value if completed.returncode == 0 and value else None


macos = {}
for line in output("sw_vers").splitlines():
    if ":" in line:
        key, value = line.split(":", 1)
        macos[key.strip()] = value.strip()

document = {
    "schemaVersion": "mirmir-ash-v4-m7-simulator-environment-v1",
    "sourceCommit": sys.argv[2],
    "sourceTreeIdentitySHA256": sys.argv[3],
    "xcodebuildVersion": sys.argv[4].splitlines(),
    "macOS": macos,
    "architecture": platform.machine(),
    "processor": platform.processor(),
    "hardware": {
        "model": optional_output("sysctl", "-n", "hw.model"),
        "cpuBrand": optional_output("sysctl", "-n", "machdep.cpu.brand_string"),
        "physicalCPUCount": optional_output("sysctl", "-n", "hw.physicalcpu"),
        "logicalCPUCount": optional_output("sysctl", "-n", "hw.logicalcpu"),
    },
    "executionScope": "headless native macOS XCTest frame simulator",
}
Path(sys.argv[1]).write_text(
    json.dumps(document, indent=2, sort_keys=True) + "\n",
    encoding="utf-8",
)
PY

python3 "$QUALITY_TOOL" generate \
  --contract "$CANONICAL_CONTRACT" \
  --output "$DISCOVERY_CORPUS"
"$P05_RUNNER" \
  --repository "$REPOSITORY" \
  --output "$P05_DISCOVERY_OUTPUT" \
  --contract "$CANONICAL_CONTRACT" \
  --corpus-manifest "$DISCOVERY_CORPUS/corpus-manifest.json" \
  --discover-executable >"$P05_DISCOVERY"
python3 "$DERIVE_TOOL" \
  --canonical "$CANONICAL_CONTRACT" \
  --discovery "$P05_DISCOVERY" \
  --output "$CONTRACT" \
  --binding "$P05_TOOLCHAIN_BINDING"

python3 "$QUALITY_TOOL" generate --contract "$CONTRACT" --output "$CORPUS"
CORPUS_MANIFEST="$CORPUS/corpus-manifest.json"
"$P05_RUNNER" \
  --repository "$REPOSITORY" \
  --output "$CAPTURE" \
  --contract "$CONTRACT" \
  --corpus-manifest "$CORPUS_MANIFEST"

python3 - "$PROJECT/Mirmir.xcodeproj/project.pbxproj" "$CAPTURE_SOURCE" <<'PY'
from pathlib import Path
import sys

project = Path(sys.argv[1])
source = Path(sys.argv[2]).resolve()
text = project.read_text(encoding="utf-8")
build_id = "C12000000000000000000001"
file_id = "C11000000000000000000001"
if build_id in text or file_id in text:
    raise SystemExit("M7 simulator PBX identifiers collide")
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
source_anchor = (
    "\t\t\t\t32000000000000000000004E "
    "/* DeterministicMetalBackendTests.swift in Sources */,\n"
)
if text.count(build_marker) != 1 or text.count(file_marker) != 1:
    raise SystemExit("cannot locate unique PBX sections")
if text.count(source_anchor) != 1:
    raise SystemExit("cannot locate the MirmirTests source phase")
text = text.replace(build_marker, build_line + build_marker)
text = text.replace(file_marker, file_line + file_marker)
text = text.replace(
    source_anchor,
    source_anchor + f"\t\t\t\t{build_id} /* QualityGateCaptureTests.swift in Sources */,\n",
)
project.write_text(text, encoding="utf-8")
PY
plutil -lint "$PROJECT/Mirmir.xcodeproj/project.pbxproj" >/dev/null

CONTRACT_SHA=$(shasum -a 256 "$CONTRACT" | awk '{print $1}')
python3 - \
  "$CAPTURE_SOURCE" \
  "$CANONICAL_CAPTURE_SOURCE" \
  "$CAPTURE_BINDING" \
  "$CAPTURE" \
  "$CORPUS_MANIFEST" \
  "$CONTRACT_SHA" \
  "$SOURCE_COMMIT" \
  "$SOURCE_TREE_SHA" <<'PY'
from pathlib import Path
import hashlib
import json
import sys

path = Path(sys.argv[1])
canonical_path = Path(sys.argv[2])
binding_path = Path(sys.argv[3])
values = {
    "__MIRMIR_V4_QUALITY_CAPTURE_DIR__": sys.argv[4],
    "__MIRMIR_V4_QUALITY_CORPUS_MANIFEST__": sys.argv[5],
    "__MIRMIR_V4_QUALITY_CONTRACT_SHA256__": sys.argv[6],
    "__MIRMIR_V4_QUALITY_SOURCE_COMMIT__": sys.argv[7],
    "__MIRMIR_V4_QUALITY_SOURCE_TREE_SHA256__": sys.argv[8],
}
canonical = canonical_path.read_text(encoding="utf-8")
text = canonical
for sentinel, value in values.items():
    quoted = json.dumps(sentinel)
    if text.count(quoted) != 1:
        raise SystemExit(f"capture sentinel is not unique: {sentinel}")
    text = text.replace(quoted, json.dumps(value))
path.write_text(text, encoding="utf-8")
binding = {
    "schemaVersion": "mirmir-ash-v4-m7-capture-binding-v1",
    "sourceCommit": sys.argv[7],
    "sourceTreeIdentitySHA256": sys.argv[8],
    "canonicalCaptureSourceSHA256": hashlib.sha256(canonical.encode()).hexdigest(),
    "injectedCaptureSourceSHA256": hashlib.sha256(text.encode()).hexdigest(),
    "injections": values,
    "timedVariantBaseOrder": [
        "candidate_v4",
        "uniform_priors",
        "randomized_state_message",
        "temporal_hysteresis_off",
        "motion_history_off",
    ],
    "timedVariantOrder": "left rotation by sorted-case ordinal modulo five",
    "warmupCountPerVariant": 5,
}
binding_path.write_text(
    json.dumps(binding, indent=2, sort_keys=True) + "\n",
    encoding="utf-8",
)
PY

if [ -z "$DERIVED_DATA" ]; then
  DERIVED_DATA="$WORK/DerivedData"
fi
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
) >"$CANDIDATE_LOG" 2>&1 || {
  tail -n 240 "$CANDIDATE_LOG" >&2
  exit 1
}
if [ "$(xcodebuild -version)" != "$XCODE_VERSION" ]; then
  echo "active Xcode changed during M7 simulation" >&2
  exit 69
fi

python3 - \
  "$CANDIDATE_LOG" \
  "$CAPTURE/p05-xcodebuild.log" \
  "$P05_DISCOVERY_OUTPUT/p05-xcodebuild.log" <<'PY'
from pathlib import Path
import re
import sys

home = str(Path.home())
path_export = re.compile(r"^(\s*)export PATH\\?=.*$", re.MULTILINE)
for argument in sys.argv[1:]:
    log = Path(argument)
    if not log.is_file() or log.is_symlink():
        raise SystemExit(f"unsafe Xcode log: {log}")
    text = log.read_text(encoding="utf-8")
    text = path_export.sub(r"\1export PATH=<redacted-host-path>", text)
    if home:
        text = text.replace(home, "<user-home>")
    if home and home in text:
        raise SystemExit(f"home path remains in Xcode log: {log}")
    log.write_text(text, encoding="utf-8")
PY

CANDIDATE_CAPTURE="$CAPTURE/candidate-capture-manifest.json"
[ -f "$CANDIDATE_CAPTURE" ] || {
  echo "candidate simulation completed without a capture manifest" >&2
  exit 66
}
python3 - "$CANDIDATE_CAPTURE" <<'PY'
from pathlib import Path
import json
import sys

path = Path(sys.argv[1])
value = json.loads(path.read_text(encoding="utf-8"))
for field in (
    "evidenceRequestSHA256",
    "observerSourceSHA256",
    "packagedCandidateIdentity",
):
    if field in value:
        raise SystemExit(f"candidate simulation unexpectedly contains {field}")
    value[field] = None
path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY

python3 "$QUALITY_TOOL" merge \
  --contract "$CONTRACT" \
  --corpus "$CORPUS_MANIFEST" \
  --p05-capture "$CAPTURE/p05-capture-manifest.json" \
  --candidate-capture "$CANDIDATE_CAPTURE" \
  --output "$CAPTURE/capture-manifest.json"

mkdir -p "$OUTPUT"
python3 "$QUALITY_TOOL" evaluate \
  --contract "$CONTRACT" \
  --corpus "$CORPUS_MANIFEST" \
  --capture "$CAPTURE/capture-manifest.json" \
  --output "$OUTPUT/quality-gate-report.json"

python3 - "$CORPUS_MANIFEST" "$CAPTURE/capture-manifest.json" "$CANDIDATE_LOG" "$OUTPUT" <<'PY'
from pathlib import Path, PurePosixPath
import hashlib
import json
import shutil
import sys

corpus_path = Path(sys.argv[1]).resolve(strict=True)
capture_path = Path(sys.argv[2]).resolve(strict=True)
candidate_log = Path(sys.argv[3]).resolve(strict=True)
output = Path(sys.argv[4]).resolve(strict=True)
corpus = json.loads(corpus_path.read_text(encoding="utf-8"))
capture = json.loads(capture_path.read_text(encoding="utf-8"))
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
            raise SystemExit(f"simulation artifact collision: {relative}")
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
shutil.copyfile(candidate_log, output / "candidate-xcodebuild.log")
PY

cp "$CONTRACT" "$OUTPUT/quality-gate-contract-v1.json"
cp "$CANONICAL_CONTRACT" "$OUTPUT/quality-gate-canonical-contract-v1.json"
cp "$SELECTION_CONTRACT" "$OUTPUT/m7-simulation-selection-contract-v1.json"
mkdir "$OUTPUT/bindings"
for relative in \
  derive_m7_quality_contract_v4.py \
  quality_gate_v4.py \
  p05_baseline_v4.py \
  P05QualityBaselineCaptureTests.swift \
  p05-baseline-source-manifest-v1.json \
  run_p05_quality_baseline_v4.sh \
  select_simulated_candidate_v4.py \
  run_m7_simulation_v4.sh; do
  cp "$PROJECT/script/v4/$relative" "$OUTPUT/bindings/$relative"
done
cp "$CANONICAL_CAPTURE_SOURCE" "$OUTPUT/bindings/QualityGateCaptureTests.swift"
cp "$CAPTURE_SOURCE" "$OUTPUT/bindings/QualityGateCaptureTests.injected.swift"
cp "$CAPTURE_BINDING" "$OUTPUT/m7-capture-binding.json"
cp "$SIMULATOR_ENVIRONMENT" "$OUTPUT/simulator-environment.json"
cp "$P05_DISCOVERY" "$OUTPUT/p05-discovery.json"
cp "$P05_TOOLCHAIN_BINDING" "$OUTPUT/m7-p05-toolchain-binding.json"
cp "$P05_DISCOVERY_OUTPUT/p05-xcodebuild.log" "$OUTPUT/p05-discovery-xcodebuild.log"

write_seal() {
  python3 - "$OUTPUT" <<'PY'
from pathlib import Path
import hashlib
import json
import sys

root = Path(sys.argv[1]).resolve(strict=True)
artifacts = []
for path in sorted(root.rglob("*"), key=lambda value: value.relative_to(root).as_posix()):
    if path.is_symlink():
        raise SystemExit(f"simulation evidence contains a symbolic link: {path}")
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
    ) + "\n",
    encoding="utf-8",
)
PY
}

write_seal
python3 "$QUALITY_TOOL" verify \
  --contract "$OUTPUT/quality-gate-contract-v1.json" \
  --report "$OUTPUT/quality-gate-report.json"
python3 "$SELECTION_TOOL" select \
  --contract "$OUTPUT/m7-simulation-selection-contract-v1.json" \
  --quality-contract "$OUTPUT/quality-gate-contract-v1.json" \
  --quality-report "$OUTPUT/quality-gate-report.json" \
  --capture-binding "$OUTPUT/m7-capture-binding.json" \
  --canonical-quality-contract "$OUTPUT/quality-gate-canonical-contract-v1.json" \
  --p05-discovery "$OUTPUT/p05-discovery.json" \
  --p05-binding "$OUTPUT/m7-p05-toolchain-binding.json" \
  --output "$OUTPUT/m7-simulation-selection-report.json"
python3 - "$OUTPUT/m7-simulation-selection-report.json" "$OUTPUT/README.md" <<'PY'
from pathlib import Path
import json
import sys

report = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
selected = report.get("selectedCandidateID") or "none"
status = "PASS" if report.get("m7Satisfied") is True else "NO ELIGIBLE CANDIDATE"
lines = [
    "# M7 simulator selection evidence",
    "",
    f"- Result: **{status}**",
    f"- Source commit: `{report['sourceCommit']}`",
    f"- Selected policy candidate: `{selected}`",
    f"- Corpus: `{report['corpus']['corpusID']}` ({report['corpus']['caseCount']} cases)",
    "",
    "| Rank | Candidate | Eligible | Quality index | 95% lower bound | Total ratio | Median ratio | p95 ratio |",
    "| ---: | --- | :---: | ---: | ---: | ---: | ---: | ---: |",
]
for candidate in report["candidates"]:
    quality = candidate["quality"]
    timing = candidate["timing"]
    lines.append(
        "| {rank} | `{candidate}` | {eligible} | {quality:.6f} | {lower:.6f} | "
        "{total:.6f} | {median:.6f} | {p95:.6f} |".format(
            rank=candidate["rank"],
            candidate=candidate["candidateID"],
            eligible="yes" if candidate["eligible"] else "no",
            quality=quality["index"],
            lower=quality["pairedBootstrap95PercentCI"]["lower"],
            total=timing["totalRatioVersusP05"],
            median=timing["medianRatioVersusP05"],
            p95=timing["p95RatioVersusP05"],
        )
    )
lines.extend([
    "",
    "This is simulator model-selection evidence only. It does not assert device qualification, notarization, shipping, or distribution.",
])
Path(sys.argv[2]).write_text("\n".join(lines) + "\n", encoding="utf-8")
PY
write_seal
python3 "$QUALITY_TOOL" verify \
  --contract "$OUTPUT/quality-gate-contract-v1.json" \
  --report "$OUTPUT/quality-gate-report.json"
python3 "$SELECTION_TOOL" verify \
  --contract "$OUTPUT/m7-simulation-selection-contract-v1.json" \
  --quality-contract "$OUTPUT/quality-gate-contract-v1.json" \
  --quality-report "$OUTPUT/quality-gate-report.json" \
  --capture-binding "$OUTPUT/m7-capture-binding.json" \
  --canonical-quality-contract "$OUTPUT/quality-gate-canonical-contract-v1.json" \
  --p05-discovery "$OUTPUT/p05-discovery.json" \
  --p05-binding "$OUTPUT/m7-p05-toolchain-binding.json" \
  --output "$OUTPUT/m7-simulation-selection-report.json"
python3 "$DERIVE_TOOL" \
  --canonical "$OUTPUT/quality-gate-canonical-contract-v1.json" \
  --discovery "$OUTPUT/p05-discovery.json" \
  --output "$OUTPUT/quality-gate-contract-v1.json" \
  --binding "$OUTPUT/m7-p05-toolchain-binding.json" \
  --verify

if ! python3 - "$OUTPUT/m7-simulation-selection-report.json" <<'PY'
from pathlib import Path
import json
import sys

report = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
if report.get("m7Satisfied") is not True or not isinstance(report.get("selectedCandidateID"), str):
    raise SystemExit(2)
PY
then
  echo "$OUTPUT"
  echo "M7 simulation completed without an eligible candidate; sealed evidence was preserved" >&2
  exit 2
fi

echo "$OUTPUT"
