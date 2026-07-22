#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_FILE="Mirmir.xcodeproj"
SCHEME="Mirmir"
DESTINATION="platform=macOS"
DERIVED_DATA="${DERIVED_DATA:-/tmp/mirmir-guardrails-deriveddata}"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export DEVELOPER_DIR

cd "$REPO_ROOT"

build_scan_pattern() {
  local provider_01 provider_02 provider_03 provider_04 provider_05 provider_06
  local provider_07 provider_08 provider_09 provider_10 provider_11 provider_12
  local provider_13 provider_14 provider_15 provider_16 provider_17 provider_group
  local term_01 term_02 term_03 term_04 term_05 term_06 term_07 term_08
  local term_09 term_10 term_11 term_12 term_13 term_14 marker

  provider_01="clau""de"
  provider_02="copi""lot"
  provider_03="chat""g""pt"
  provider_04="g""pt"
  provider_05="anthro""pic"
  provider_06="open""ai"
  provider_07="aid""er"
  provider_08="cur""sor"
  provider_09="co""dex"
  provider_10="co""dy"
  provider_11="tab""nine"
  provider_12="gem""ini"
  provider_13="ba""rd"
  provider_14="git""hub[- ]${provider_02}"
  provider_15="l""lm"
  provider_16="gr""ok"
  provider_17="x""ai"
  provider_group="(${provider_01}|${provider_02}|${provider_03}|${provider_04}[-_ ]?[0-9]?|${provider_05}|${provider_06}|${provider_07}|${provider_08}|${provider_09}|${provider_10}|${provider_11}|${provider_12}|${provider_13}|${provider_14}|${provider_01}[- ]code|${provider_15}|${provider_16}|${provider_17})"

  term_01="co-authored""-by"
  term_02="generated"
  term_03="created"
  term_04="authored"
  term_05="written"
  term_06="assisted"
  term_07="AI""-assisted"
  term_08="AI"" generated"
  term_09="AI""-generated"
  term_10="${provider_15}""-generated"
  term_11="model""-generated"
  term_12="machine""-generated"
  term_13="ag""ent-generated"
  term_14="co-authored""-by:"
  marker="🤖[[:space:]]*generated[[:space:]]+(with|by)"

  printf '%s' "(${term_01}:[[:space:]]*[^<]*${provider_group})|(${term_14}[[:space:]]*[^<]*${provider_group})|(${term_02}[[:space:]]+(with|by)[[:space:]]+${provider_group})|(${term_03}[[:space:]]+by[[:space:]]+${provider_group})|(${term_04}[[:space:]]+by[[:space:]]+${provider_group})|(${term_05}[[:space:]]+by[[:space:]]+${provider_group})|(${term_06}[[:space:]]+by[[:space:]]+${provider_group})|(${term_07})|(${term_08})|(${term_09})|(${term_10})|(${term_11})|(${term_12})|(${term_13})|(${marker})|(noreply@${provider_05}\.com)|(${provider_01}\.ai/code)"
}

build_path_terms() {
  printf '%s\n' \
    "clau""de" \
    "chat""g""pt" \
    "open""ai" \
    "anthro""pic" \
    "co""dex" \
    "gr""ok" \
    "x""ai" \
    "l""lm" \
    "ag""entic"
}

echo "==> Checking repository diff whitespace..."
git diff --check

echo "==> Validating JSON files..."
find . \
  -path './.git' -prune -o \
  -path './.build' -prune -o \
  -path './.swiftpm' -prune -o \
  -path './Artifacts' -prune -o \
  -path './build' -prune -o \
  -name '*.json' -print0 |
  xargs -0 -n1 python3 -m json.tool >/dev/null

echo "==> Verifying roadmap alignment..."
python3 -m unittest \
  Scripts/tests/test_roadmap_alignment.py \
  Scripts/tests/test_r00_inventory.py \
  Scripts/tests/test_json_schema_validator.py \
  Scripts/tests/test_phase_evidence.py \
  Scripts/tests/test_r01_preregistration.py \
  Scripts/tests/test_r01_capabilities.py \
  Scripts/tests/test_r01_observation_waiver.py \
  Scripts/tests/test_r02_contracts.py \
  Scripts/tests/test_r03_contracts.py \
  Scripts/tests/test_r03_product_qualification.py \
  Scripts/tests/test_r03_phase_acceptance.py \
  Scripts/tests/test_r04_contracts.py \
  Scripts/tests/test_r05_contracts.py \
  Scripts/tests/test_r06_contracts.py \
  Scripts/tests/test_r07_contracts.py \
  Scripts/tests/test_r07_phase_acceptance.py \
  Scripts/tests/test_r08_contracts.py \
  Scripts/tests/test_r08_phase_acceptance.py
python3 Scripts/roadmap_alignment.py --check
python3 Scripts/r00_inventory.py --check
python3 Scripts/r01_preregistration.py --check
python3 Scripts/r01_preregistration.py --check-fixtures
python3 Scripts/r02_contracts.py --check-preregistration
python3 Scripts/r02_contracts.py --check-fixtures
if [[ -f docs/roadmaps/evidence/r02/records/conformance.json ]]; then
  python3 Scripts/r02_contracts.py --check-conformance
fi
python3 Scripts/r03_contracts.py --check-preregistration
python3 Scripts/r03_contracts.py --check-fixtures
if [[ -f docs/roadmaps/evidence/r03/records/baseline-conformance.json ]]; then
  python3 Scripts/r03_contracts.py --check-conformance
fi
python3 Scripts/r03_product_qualification.py --check-preregistration
python3 Scripts/r03_product_qualification.py --check-fixtures
python3 Scripts/r03_product_qualification.py --check-receipt
python3 Scripts/r03_product_qualification.py --check-decision
python3 Scripts/r03_phase_acceptance.py --check
python3 Scripts/r04_contracts.py --check-preregistration
python3 Scripts/r04_contracts.py --check-fixtures
if [[ -f docs/roadmaps/evidence/r04/records/integration-conformance.json ]]; then
  python3 Scripts/r04_contracts.py --check-conformance
fi
python3 Scripts/r05_contracts.py --check-preregistration
python3 Scripts/r05_contracts.py --check-fixtures
if [[ -f docs/roadmaps/evidence/r05/records/suitability-conformance.json ]]; then
  python3 Scripts/r05_contracts.py --check-conformance
fi
python3 Scripts/r06_contracts.py --check-preregistration
python3 Scripts/r06_contracts.py --check-fixtures
if [[ -f docs/roadmaps/evidence/r06/records/orchestration-conformance.json ]]; then
  python3 Scripts/r06_contracts.py --check-conformance
fi
python3 Scripts/r07_contracts.py --check-preregistration
python3 Scripts/r07_contracts.py --check-fixtures
if [[ -f docs/roadmaps/evidence/r07/records/temporal-artifact-conformance.json ]]; then
  python3 Scripts/r07_contracts.py --check-conformance
fi
python3 Scripts/r07_phase_acceptance.py --check
python3 Scripts/r08_contracts.py --check-preregistration
python3 Scripts/r08_contracts.py --check-fixtures
python3 Scripts/r08_phase_acceptance.py --check

if git ls-files -- '.r01-local-assets' | grep -q .; then
  echo "R01 local system/model assets must never be tracked." >&2
  exit 1
fi

r01_evidence_present=false
for r01_evidence_path in \
  project-notes/evidence/r01/hosts/anchor-oldest-supported.json \
  project-notes/evidence/r01/hosts/anchor-m3-air.json \
  project-notes/evidence/r01/hosts/anchor-pro-max.json \
  project-notes/evidence/r01/hosts/anchor-core-ai.json \
  project-notes/apple-upscale-capabilities.json \
  project-notes/apple-upscale-capability-report.md; do
  if [ -e "$r01_evidence_path" ] || [ -L "$r01_evidence_path" ]; then
    r01_evidence_present=true
  fi
done
if [ "$r01_evidence_present" = true ]; then
  if [ -f project-notes/apple-upscale-capabilities.json ] && \
    grep -q '"evidence_kind": "operator_observation_waiver"' \
      project-notes/apple-upscale-capabilities.json; then
    python3 Scripts/r01_observation_waiver.py --check
  else
    python3 Scripts/r01_capabilities.py --check
  fi
fi

while IFS= read -r manifest_path; do
  phase_id="$(basename "$(dirname "$manifest_path")" | tr '[:lower:]' '[:upper:]')"
  echo "==> Verifying ${phase_id} phase evidence..."
  python3 Scripts/phase_evidence.py --phase "$phase_id" --check
done < <(find docs/roadmaps/evidence \
  -type f -name 'phase-evidence.json' -print | sort)

echo "==> Checking text and path hygiene..."
scan_pattern="$(build_scan_pattern)"
if rg -n "$scan_pattern" --hidden \
  --glob '!.git/**' \
  --glob '!.build/**' \
  --glob '!.swiftpm/**' \
  --glob '!Artifacts/**' \
  --glob '!build/**' .; then
  echo "Repository text contains prohibited attribution." >&2
  exit 1
fi

if git log -1 --format='%an <%ae>%n%cn <%ce>%n%s%n%b' | grep -iqE "$scan_pattern"; then
  echo "Latest commit metadata contains prohibited attribution." >&2
  exit 1
fi

branch_name="$(git branch --show-current || true)"
while IFS= read -r term; do
  [ -z "$term" ] && continue
  if [ -n "$branch_name" ] && printf '%s\n' "$branch_name" | grep -iqF "$term"; then
    echo "Current branch name contains prohibited attribution." >&2
    exit 1
  fi
  if find . \
    -path './.git' -prune -o \
    -path './.build' -prune -o \
    -path './.swiftpm' -prune -o \
    -path './Artifacts' -prune -o \
    -path './build' -prune -o \
    -type f -print | grep -iqF "$term"; then
    echo "Repository paths contain prohibited attribution." >&2
    exit 1
  fi
done < <(build_path_terms)

echo "==> Running SwiftLint..."
if ! command -v swiftlint >/dev/null 2>&1; then
  echo "swiftlint is not installed. Install it and rerun this script." >&2
  exit 1
fi
swiftlint lint --strict --config .swiftlint.yml

echo "==> Checking project metadata..."
xcodebuild -list -json -project "$PROJECT_FILE" >/tmp/mirmir-xcode-list.json
xcodebuild -showdestinations -project "$PROJECT_FILE" -scheme "$SCHEME" >/tmp/mirmir-xcode-destinations.txt

if [ -f Package.swift ]; then
  echo "==> Running Swift Package checks..."
  swift package resolve
  swift package dump-package >/dev/null
  swift package show-dependencies
  swift test --parallel --enable-code-coverage
else
  echo "==> Swift Package checks are not applicable; no app-owned Package.swift exists."
fi

echo "==> Building R01 isolated capability worker..."
xcodebuild \
  -project "$PROJECT_FILE" \
  -scheme R01CapabilityWorker \
  -configuration Debug \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED_DATA" \
  -disableAutomaticPackageResolution \
  CODE_SIGNING_ALLOWED=NO \
  build

echo "==> Building Debug..."
xcodebuild \
  -project "$PROJECT_FILE" \
  -scheme "$SCHEME" \
  -configuration Debug \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED_DATA" \
  -disableAutomaticPackageResolution \
  build

hosted_test_shard_one=(
  "MirmirTests/ASHAnalysisGridV2Tests"
  "MirmirTests/ASHAssetConformanceTests"
  "MirmirTests/ASHBackendInputValidationTests"
  "MirmirTests/ASHBackendIntegrationTests"
  "MirmirTests/ASHBitwiseCoreTests"
  "MirmirTests/ASHCoordinateDiagnosticRuntimeV3Tests"
  "MirmirTests/ASHCoordinateModelContractV3Tests"
  "MirmirTests/ASHCoreConformanceTests"
  "MirmirTests/ASHCorrectiveCLITests"
  "MirmirTests/ASHFeatureBranchReconstructionTests"
  "MirmirTests/ASHFrameCompletionIntegrationTests"
  "MirmirTests/ASHGenericPhaseCompilerDiagnosticV3Tests"
  "MirmirTests/ASHInternalAlphaTests"
  "MirmirTests/ASHLUTBinaryFormatV2Tests"
  "MirmirTests/ASHLUTCompilerV2Tests"
  "MirmirTests/ASHLUTFormat12V3Tests"
)
shard_one_arguments=()
shard_two_arguments=()
for test_class in "${hosted_test_shard_one[@]}"; do
  shard_one_arguments+=("-only-testing:$test_class")
  shard_two_arguments+=("-skip-testing:$test_class")
done

# Keep the app-host lifetime below the macOS foreground-hang termination window
# while preserving serial execution and exact, non-overlapping target coverage.
echo "==> Testing Debug shard 1 of 2..."
xcodebuild \
  -project "$PROJECT_FILE" \
  -scheme "$SCHEME" \
  -configuration Debug \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED_DATA" \
  -disableAutomaticPackageResolution \
  "${shard_one_arguments[@]}" \
  test

echo "==> Testing Debug shard 2 of 2..."
xcodebuild \
  -project "$PROJECT_FILE" \
  -scheme "$SCHEME" \
  -configuration Debug \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED_DATA" \
  -disableAutomaticPackageResolution \
  "${shard_two_arguments[@]}" \
  test

echo "==> Building Release..."
xcodebuild \
  -project "$PROJECT_FILE" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED_DATA" \
  -disableAutomaticPackageResolution \
  build

echo "==> Checking built app dependency boundary..."
for configuration in Debug Release; do
  app_bundle="$DERIVED_DATA/Build/Products/$configuration/Mirmir.app"
  app_binary="$app_bundle/Contents/MacOS/Mirmir"
  if [ ! -x "$app_binary" ]; then
    echo "Missing built app binary: $app_binary" >&2
    exit 1
  fi
  if find "$app_bundle" -iname '*forsetti*' -print -quit | grep -q .; then
    echo "Built $configuration app contains a Forsetti-named path." >&2
    exit 1
  fi
  if otool -L "$app_binary" | grep -qi 'forsetti'; then
    echo "Built $configuration app links a Forsetti product." >&2
    exit 1
  fi
done

echo "==> Mirmir guardrails passed."
