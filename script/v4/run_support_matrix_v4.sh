#!/bin/zsh
set -euo pipefail

usage() {
    print -u2 "usage: $0 --output EVIDENCE_ROOT/support_matrix --candidate CANDIDATE.json --application-archive Mirmir.zip [--repository REPOSITORY] [--contract CONTRACT.json]"
    exit 64
}

script_directory="${0:A:h}"
repository_root="${script_directory:h:h}"
contract="${script_directory}/support-matrix-contract-v1.json"
capture="${script_directory}/capture_support_matrix_v4.py"
evaluator="${script_directory}/support_matrix_v4.py"
output_directory=""
candidate=""
application_archive=""

while (( $# > 0 )); do
    case "$1" in
        --output)
            (( $# >= 2 )) || usage
            output_directory="$2"
            shift 2
            ;;
        --candidate)
            (( $# >= 2 )) || usage
            candidate="$2"
            shift 2
            ;;
        --application-archive)
            (( $# >= 2 )) || usage
            application_archive="$2"
            shift 2
            ;;
        --repository)
            (( $# >= 2 )) || usage
            repository_root="$2"
            shift 2
            ;;
        --contract)
            (( $# >= 2 )) || usage
            contract="$2"
            shift 2
            ;;
        *) usage ;;
    esac
done

[[ -n "${output_directory}" && -n "${candidate}" && -n "${application_archive}" ]] || usage
repository_root="$(python3 -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).expanduser().resolve(strict=True))' "${repository_root}")"
contract="$(python3 -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).expanduser().resolve(strict=True))' "${contract}")"
candidate="$(python3 -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).expanduser().resolve(strict=True))' "${candidate}")"
application_archive="$(python3 -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).expanduser().resolve(strict=True))' "${application_archive}")"
output_directory="$(python3 -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).expanduser().resolve())' "${output_directory}")"

[[ -d "${repository_root}/.git" || -f "${repository_root}/.git" ]] || {
    print -u2 "support repository is not a Git worktree: ${repository_root}"
    exit 65
}
[[ "${output_directory:t}" == "support_matrix" ]] || {
    print -u2 "support output directory must be named support_matrix"
    exit 65
}
[[ ! -e "${output_directory}" ]] || {
    print -u2 "refusing to overwrite support evidence: ${output_directory}"
    exit 65
}

python3 - "${contract}" "${capture}" "${evaluator}" "${0:A}" <<'PY'
import hashlib,json,pathlib,sys
contract_path,capture_path,evaluator_path,runner_path = map(pathlib.Path,sys.argv[1:])
contract = json.loads(contract_path.read_text())
actual = {
    "captureSourceSHA256": hashlib.sha256(capture_path.read_bytes()).hexdigest(),
    "evaluatorSHA256": hashlib.sha256(evaluator_path.read_bytes()).hexdigest(),
    "runnerSHA256": hashlib.sha256(runner_path.read_bytes()).hexdigest(),
}
if contract.get("tools") != actual:
    raise SystemExit(f"support tool identity mismatch: expected={contract.get('tools')} actual={actual}")
PY

python3 "${capture}" \
    --repository "${repository_root}" \
    --candidate "${candidate}" \
    --application-archive "${application_archive}" \
    --contract "${contract}" \
    --output "${output_directory}"

python3 "${evaluator}" verify --evidence "${output_directory}"
print -r -- "Support-matrix evidence: ${output_directory}/report.json"
