#!/bin/zsh
set -euo pipefail

usage() {
    print -u2 "usage: $0 --output EVIDENCE_ROOT/recovery --candidate CANDIDATE.json --application-archive Mirmir.zip --release-configuration Release.xcconfig [--candidate-revision REV] [--derived-data DIR] [--keep-work]"
    print -u2 "       $0 --compile-only [--candidate-revision REV] [--derived-data DIR] [--keep-work]"
    exit 64
}

script_directory="${0:A:h}"
repository_root="${script_directory:h:h}"
contract_source="${script_directory}/recovery-qualification-contract-v1.json"
capture_source="${script_directory}/RecoveryQualificationCaptureTests.swift"
evaluator_source="${script_directory}/recovery_qualification_v4.py"
runner_source="${0:A}"
archive_provenance_source="${script_directory}/release_candidate_archive_v4.py"
packaged_evidence_source="${script_directory}/packaged_candidate_evidence_v4.py"

output_directory=""
candidate_source=""
application_archive=""
release_configuration=""
candidate_revision="HEAD"
derived_data=""
keep_work=0
compile_only=0

bound_git() {
    GIT_ATTR_NOSYSTEM=1 \
    GIT_CONFIG_GLOBAL=/dev/null \
    GIT_CONFIG_NOSYSTEM=1 \
    GIT_CONFIG_SYSTEM=/dev/null \
    LANG=C \
    LC_ALL=C \
    PATH=/usr/bin:/bin:/usr/sbin:/sbin \
        /usr/bin/git --no-replace-objects -C "${repository_root}" "$@"
}

while (( $# > 0 )); do
    case "$1" in
        --output)
            (( $# >= 2 )) || usage
            output_directory="$2"
            shift 2
            ;;
        --candidate)
            (( $# >= 2 )) || usage
            candidate_source="$2"
            shift 2
            ;;
        --application-archive)
            (( $# >= 2 )) || usage
            application_archive="$2"
            shift 2
            ;;
        --release-configuration)
            (( $# >= 2 )) || usage
            release_configuration="$2"
            shift 2
            ;;
        --candidate-revision)
            (( $# >= 2 )) || usage
            candidate_revision="$2"
            shift 2
            ;;
        --derived-data)
            (( $# >= 2 )) || usage
            derived_data="$2"
            shift 2
            ;;
        --keep-work)
            keep_work=1
            shift
            ;;
        --compile-only)
            compile_only=1
            shift
            ;;
        *) usage ;;
    esac
done

work_directory="$(
    mktemp -d "${TMPDIR:-/tmp}/mirmir-v4-recovery.XXXXXX"
)"
cleanup_recovery_work() {
    if (( keep_work == 1 )); then
        print -u2 "ephemeral recovery workspace retained at ${work_directory}"
        return
    fi
    case "${work_directory}" in
        */mirmir-v4-recovery.*) rm -rf -- "${work_directory}" ;;
        *) print -u2 "refusing to clean unexpected path: ${work_directory}" ;;
    esac
}
trap cleanup_recovery_work EXIT INT TERM

project_root="${work_directory}/project"
mkdir -p -- "${project_root}"
source_export_manifest="${work_directory}/source-export.json"
python3 "${evaluator_source}" export-source \
    --repository "${repository_root}" \
    --revision "${candidate_revision}" \
    --destination "${project_root}" \
    > "${source_export_manifest}"
candidate_revision="$(
    python3 -c \
        'import json,sys; print(json.load(open(sys.argv[1]))["sourceCommit"])' \
        "${source_export_manifest}"
)"
candidate_source_tree_identity="$(
    python3 -c \
        'import json,sys; print(json.load(open(sys.argv[1]))["sourceTreeIdentitySHA256"])' \
        "${source_export_manifest}"
)"

# Keep qualification-only code outside the shipping repository targets. The
# committed capture is appended only after every exported byte and executable
# mode has been verified against the exact candidate commit.
python3 - \
    "${project_root}/MirmirTests/WorkflowEventJournalTests.swift" \
    "${capture_source}" <<'PY'
from pathlib import Path
import sys
target, capture = map(Path, sys.argv[1:])
target.write_bytes(target.read_bytes() + b"\n" + capture.read_bytes())
PY

if [[ -z "${derived_data}" ]]; then
    derived_data="${work_directory}/DerivedData"
else
    derived_data="$(
        python3 -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).expanduser().resolve())' \
            "${derived_data}"
    )"
fi

if (( compile_only == 1 )); then
    [[ -z "${output_directory}" && -z "${candidate_source}" \
        && -z "${application_archive}" \
        && -z "${release_configuration}" ]] || usage
    # This testability-enabled product exists only to host the fault-injection
    # XCTest. It is compiled from the candidate source tree, but it is not the
    # archived executable. Package identity is independently derived from the
    # supplied clean Release archive and rejects this build as a substitute.
    xcodebuild build-for-testing \
        -project "${project_root}/Mirmir.xcodeproj" \
        -scheme Mirmir \
        -configuration Release \
        -destination 'platform=macOS' \
        -derivedDataPath "${derived_data}" \
        CODE_SIGNING_ALLOWED=NO \
        ENABLE_TESTABILITY=YES \
        SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
        GCC_TREAT_WARNINGS_AS_ERRORS=YES
    print -r -- "recovery capture source compiled in Release"
    exit 0
fi

[[ -n "${output_directory}" && -n "${candidate_source}" \
    && -n "${application_archive}" \
    && -n "${release_configuration}" ]] || usage
output_directory="$(
    python3 -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).expanduser().resolve())' \
        "${output_directory}"
)"
candidate_source="$(
    python3 -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).expanduser().resolve(strict=True))' \
        "${candidate_source}"
)"
application_archive="$(
    python3 -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).expanduser().resolve(strict=True))' \
        "${application_archive}"
)"
release_configuration="$(
    python3 -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).expanduser().resolve(strict=True))' \
        "${release_configuration}"
)"
[[ "${output_directory:t}" == "recovery" ]] || {
    print -u2 "output directory must be named recovery"
    exit 65
}
if [[ -e "${output_directory}" ]] \
    && [[ -n "$(find "${output_directory}" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
    print -u2 "refusing to overwrite nonempty recovery output: ${output_directory}"
    exit 65
fi
mkdir -p -- "${output_directory}"
evidence_root="${output_directory:h}"

for bound_path in \
    script/v4/recovery-qualification-contract-v1.json \
    script/v4/RecoveryQualificationCaptureTests.swift \
    script/v4/release_candidate_archive_v4.py \
    script/v4/packaged_candidate_evidence_v4.py \
    script/v4/recovery_qualification_v4.py \
    script/v4/run_recovery_qualification_v4.sh; do
    bound_git cat-file -e \
        "${candidate_revision}:${bound_path}" || {
        print -u2 "candidate revision omits recovery harness: ${bound_path}"
        exit 66
    }
    committed_hash="$(
        bound_git show "${candidate_revision}:${bound_path}" \
            | shasum -a 256 | awk '{print $1}'
    )"
    working_hash="$(
        shasum -a 256 "${repository_root}/${bound_path}" | awk '{print $1}'
    )"
    [[ "${committed_hash}" == "${working_hash}" ]] || {
        print -u2 "candidate revision does not bind executing recovery harness: ${bound_path}"
        exit 66
    }
done

binding_directory="${output_directory}/bindings"
mkdir -p -- "${binding_directory}"
cp -- "${contract_source}" \
    "${binding_directory}/recovery-qualification-contract-v1.json"
cp -- "${capture_source}" \
    "${binding_directory}/RecoveryQualificationCaptureTests.swift"
cp -- "${archive_provenance_source}" \
    "${binding_directory}/release_candidate_archive_v4.py"
cp -- "${packaged_evidence_source}" \
    "${binding_directory}/packaged_candidate_evidence_v4.py"
cp -- "${evaluator_source}" \
    "${binding_directory}/recovery_qualification_v4.py"
cp -- "${runner_source}" \
    "${binding_directory}/run_recovery_qualification_v4.sh"
cp -- "${release_configuration}" \
    "${binding_directory}/release-candidate-v4.xcconfig"
cp -- "${application_archive}" \
    "${binding_directory}/application-archive.zip"

contract="${binding_directory}/recovery-qualification-contract-v1.json"
capture="${binding_directory}/RecoveryQualificationCaptureTests.swift"
archive_provenance="${binding_directory}/release_candidate_archive_v4.py"
packaged_evidence="${binding_directory}/packaged_candidate_evidence_v4.py"
evaluator="${binding_directory}/recovery_qualification_v4.py"
runner="${binding_directory}/run_recovery_qualification_v4.sh"
bound_application_archive="${binding_directory}/application-archive.zip"
bound_release_configuration="${binding_directory}/release-candidate-v4.xcconfig"
runtime_root="${project_root}/Mirmir/Resources/ASH-P06.bundle"
runtime_manifest="${runtime_root}/runtime-manifest.json"
cp -- "${runtime_manifest}" "${binding_directory}/runtime-manifest.json"
bound_runtime_manifest="${binding_directory}/runtime-manifest.json"

python3 - \
    "${contract}" "${capture}" "${archive_provenance}" \
    "${packaged_evidence}" "${evaluator}" "${runner}" <<'PY'
import hashlib,json,pathlib,sys
(
    contract_path,
    capture_path,
    archive_provenance_path,
    packaged_evidence_path,
    evaluator_path,
    runner_path,
) = map(pathlib.Path,sys.argv[1:])
contract = json.loads(contract_path.read_text())
observed = {
    "archiveProvenanceSourceSHA256": hashlib.sha256(archive_provenance_path.read_bytes()).hexdigest(),
    "captureSourceSHA256": hashlib.sha256(capture_path.read_bytes()).hexdigest(),
    "evaluatorSourceSHA256": hashlib.sha256(evaluator_path.read_bytes()).hexdigest(),
    "packagedEvidenceSourceSHA256": hashlib.sha256(packaged_evidence_path.read_bytes()).hexdigest(),
    "runnerSourceSHA256": hashlib.sha256(runner_path.read_bytes()).hexdigest(),
}
for key,value in observed.items():
    if contract.get("capture", {}).get(key) != value:
        raise SystemExit(f"recovery tool identity mismatch for {key}: {value}")
PY

candidate="${binding_directory}/candidate.json"
python3 - \
    "${candidate_source}" "${candidate}" "${candidate_revision}" \
    "${candidate_source_tree_identity}" \
    "${runtime_root}" "${release_configuration}" \
    "${project_root}/Mirmir/Upscaling/Deterministic/DeterministicEngineV4Support.swift" <<'PY'
import hashlib,json,pathlib,re,sys

source_path,output_path,revision,source_tree_identity,runtime_text,release_text,trust_text = sys.argv[1:]
document = json.loads(pathlib.Path(source_path).read_text())
candidate = document.get("candidate", document)
fields = {
    "sourceCommit", "sourceTreeIdentitySHA256", "runtimeManifestSHA256",
    "runtimeManifestFileSHA256", "runtimeArtifactSetSHA256",
    "runtimeSourceRevision", "releaseConfigurationSHA256", "appBundleSHA256",
    "bundleIdentifier", "productVersion", "productBuild",
}
if not isinstance(candidate, dict) or set(candidate) != fields:
    raise SystemExit("recovery candidate field set differs")
if candidate.get("sourceCommit") != revision:
    raise SystemExit("recovery candidate source revision differs")
if candidate.get("sourceTreeIdentitySHA256") != source_tree_identity:
    raise SystemExit("recovery candidate source-tree identity differs")
if candidate.get("releaseConfigurationSHA256") != hashlib.sha256(
    pathlib.Path(release_text).read_bytes()
).hexdigest():
    raise SystemExit("recovery candidate Release configuration differs")

runtime = pathlib.Path(runtime_text)
if not runtime.is_dir() or runtime.is_symlink():
    raise SystemExit("release-qualified P06 runtime is missing or unsafe")
files = []
for path in sorted(runtime.rglob("*")):
    if path.is_symlink():
        raise SystemExit(f"P06 runtime contains a symbolic link: {path}")
    if path.is_file():
        files.append(path)
manifest_path = runtime / "runtime-manifest.json"
manifest_bytes = manifest_path.read_bytes()
manifest = json.loads(manifest_bytes)
canonical = json.dumps(
    manifest, ensure_ascii=False, allow_nan=False, sort_keys=True,
    separators=(",", ":"),
).encode("utf-8")
if manifest_bytes != canonical:
    raise SystemExit("P06 runtime manifest is not canonical")
if hashlib.sha256(manifest_bytes).hexdigest() != candidate.get("runtimeManifestFileSHA256"):
    raise SystemExit("recovery candidate runtime-manifest file differs")
semantic = hashlib.sha256(b"ash-p06-runtime-manifest-v4\0" + canonical).hexdigest()
if semantic != candidate.get("runtimeManifestSHA256"):
    raise SystemExit("recovery candidate runtime-manifest semantic identity differs")
if manifest.get("schemaID") != "ash.p06.runtime-manifest.v1" \
        or manifest.get("runtimeID") != "ash-p06-deterministic-v4" \
        or manifest.get("releaseStatus") != "release_qualified":
    raise SystemExit("recovery candidate runtime is not release-qualified P06")
if manifest.get("provenance", {}).get("sourceRevision") != candidate.get("runtimeSourceRevision"):
    raise SystemExit("recovery candidate runtime source revision differs")
artifact_digest = hashlib.sha256(b"mirmir-artifact-set-v1\0")
for path in files:
    relative = path.relative_to(runtime).as_posix()
    identity = hashlib.sha256(path.read_bytes()).hexdigest()
    artifact_digest.update(relative.encode("utf-8"))
    artifact_digest.update(b"\0")
    artifact_digest.update(identity.encode("ascii"))
    artifact_digest.update(b"\n")
if artifact_digest.hexdigest() != candidate.get("runtimeArtifactSetSHA256"):
    raise SystemExit("recovery candidate runtime artifact set differs")

trust = pathlib.Path(trust_text).read_text()
def unique(pattern, label):
    values = re.findall(pattern, trust)
    if len(values) != 1:
        raise SystemExit(f"code-owned P06 {label} trust root is not unique")
    return values[0]
trusted_manifest = unique(
    r'manifestSHA256\s*=\s*try!\s*ASHSHA256V4\(\s*"([0-9a-f]{64})"\s*\)',
    "manifest",
)
trusted_source = unique(
    r'sourceRevision\s*=\s*"((?:[0-9a-f]{40}|[0-9a-f]{64}))"',
    "source",
)
trusted_builder = unique(
    r'builderSourceSHA256\s*=\s*try!\s*ASHSHA256V4\(\s*"([0-9a-f]{64})"\s*\)',
    "builder",
)
if trusted_manifest != candidate.get("runtimeManifestSHA256") \
        or trusted_source != candidate.get("runtimeSourceRevision") \
        or trusted_builder != manifest.get("provenance", {}).get("builderSourceSHA256"):
    raise SystemExit("code-owned P06 trust roots differ from the recovery candidate")
pathlib.Path(output_path).write_text(
    json.dumps(candidate, indent=2, sort_keys=True, ensure_ascii=False, allow_nan=False)
    + "\n"
)
PY

contract_sha256="$(shasum -a 256 "${contract}" | awk '{print $1}')"
capture_sha256="$(shasum -a 256 "${capture}" | awk '{print $1}')"
source_tree_sha256="$(
    python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["sourceTreeIdentitySHA256"])' \
        "${candidate}"
)"
xcode_version="$(xcodebuild -version | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
capture_directory="${output_directory}/capture"
mkdir -p -- "${capture_directory}"

python3 - \
    "${project_root}/MirmirTests/WorkflowEventJournalTests.swift" \
    "${capture_directory}" "${evidence_root}" "${contract}" \
    "${contract_sha256}" "${capture_sha256}" "${candidate_revision}" \
    "${source_tree_sha256}" "${xcode_version}" <<'PY'
from pathlib import Path
import json,sys
path = Path(sys.argv[1])
values = sys.argv[2:]
sentinels = (
    "MIRMIR_V4_RECOVERY_CAPTURE_DIR",
    "MIRMIR_V4_RECOVERY_EVIDENCE_ROOT",
    "MIRMIR_V4_RECOVERY_CONTRACT",
    "MIRMIR_V4_RECOVERY_CONTRACT_SHA256",
    "MIRMIR_V4_RECOVERY_CAPTURE_SOURCE_SHA256",
    "MIRMIR_V4_RECOVERY_SOURCE_COMMIT",
    "MIRMIR_V4_RECOVERY_SOURCE_TREE_SHA256",
    "MIRMIR_V4_RECOVERY_XCODE_VERSION",
)
text = path.read_text()
for name,value in zip(sentinels, values):
    token = f"__{name}__"
    if text.count(token) != 1:
        raise SystemExit(f"recovery capture sentinel is absent or repeated: {token}")
    text = text.replace(token, json.dumps(value)[1:-1])
path.write_text(text)
PY

# The fault-injection host is source-bound to the candidate and intentionally
# testable. It is not the archived executable and never supplies the application
# identity recorded by the packaged-candidate binding below.
result_bundle="${work_directory}/recovery-capture.xcresult"
xcodebuild test \
    -project "${project_root}/Mirmir.xcodeproj" \
    -scheme Mirmir \
    -configuration Release \
    -destination 'platform=macOS' \
    -derivedDataPath "${derived_data}" \
    -resultBundlePath "${result_bundle}" \
    -only-testing:MirmirTests/DeterministicEngineV4RecoveryQualificationCaptureTests/testCaptureRecoveryQualificationWhenRequested \
    CODE_SIGNING_ALLOWED=NO \
    ENABLE_TESTABILITY=YES \
    ONLY_ACTIVE_ARCH=YES \
    SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
    GCC_TREAT_WARNINGS_AS_ERRORS=YES \
    2>&1 | tee "${capture_directory}/xcodebuild.log"

[[ -f "${capture_directory}/capture.json" ]] || {
    print -u2 "recovery capture did not publish capture.json"
    exit 67
}

report="${output_directory}/recovery-report.json"
capture_manifest="${capture_directory}/artifact-manifest.json"
sealed_manifest="${output_directory}/artifact-manifest.json"
package_identity="${binding_directory}/package-identity.json"
attestation="${binding_directory}/MirmirV4ReleaseBuildAttestation.json"
provenance_runtime_root="${repository_root}/Mirmir/Resources/ASH-P06.bundle"
python3 "${evaluator}" evaluate \
    --repository "${repository_root}" \
    --contract "${contract}" \
    --capture "${capture_directory}/capture.json" \
    --candidate "${candidate}" \
    --application-archive "${bound_application_archive}" \
    --runtime "${provenance_runtime_root}" \
    --runtime-manifest-artifact "${bound_runtime_manifest}" \
    --release-configuration "${release_configuration}" \
    --release-configuration-artifact "${bound_release_configuration}" \
    --package-identity "${package_identity}" \
    --attestation "${attestation}" \
    --evidence-root "${evidence_root}" \
    --capture-manifest "${capture_manifest}" \
    --sealed-manifest "${sealed_manifest}" \
    --output "${report}"
python3 "${evaluator}" verify \
    --repository "${repository_root}" \
    --contract "${contract}" \
    --capture "${capture_directory}/capture.json" \
    --candidate "${candidate}" \
    --application-archive "${bound_application_archive}" \
    --runtime "${provenance_runtime_root}" \
    --runtime-manifest-artifact "${bound_runtime_manifest}" \
    --release-configuration "${release_configuration}" \
    --release-configuration-artifact "${bound_release_configuration}" \
    --package-identity "${package_identity}" \
    --attestation "${attestation}" \
    --evidence-root "${evidence_root}" \
    --capture-manifest "${capture_manifest}" \
    --sealed-manifest "${sealed_manifest}" \
    --report "${report}"

print -r -- "recovery evidence: ${report}"
