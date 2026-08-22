#!/bin/zsh
set -euo pipefail

usage() {
    print -u2 "usage: $0 --repository REPOSITORY --candidate CANDIDATE.json --runtime ASH-P06.bundle --release-configuration Release.xcconfig --output EVIDENCE_DIRECTORY [--contract CONTRACT.json]"
    exit 64
}

script_directory="${0:A:h}"
repository=""
candidate=""
runtime=""
release_configuration=""
output=""
contract="${script_directory}/p06-reproduction-contract-v2.json"

while (( $# > 0 )); do
    case "$1" in
        --repository)
            (( $# >= 2 )) || usage
            repository="$2"
            shift 2
            ;;
        --candidate)
            (( $# >= 2 )) || usage
            candidate="$2"
            shift 2
            ;;
        --runtime)
            (( $# >= 2 )) || usage
            runtime="$2"
            shift 2
            ;;
        --release-configuration)
            (( $# >= 2 )) || usage
            release_configuration="$2"
            shift 2
            ;;
        --output)
            (( $# >= 2 )) || usage
            output="$2"
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

[[ -n "$repository" && -n "$candidate" && -n "$runtime" \
    && -n "$release_configuration" && -n "$output" ]] || usage

repository="${repository:A}"
candidate="${candidate:A}"
runtime="${runtime:A}"
release_configuration="${release_configuration:A}"
output="${output:A}"
contract="${contract:A}"

repository_runner="${repository}/script/v4/run_p06_reproduction_v4.sh"
[[ -f "${repository_runner}" && ! -L "${repository_runner}" ]] || {
    print -u2 "candidate repository omits the P06 runner"
    exit 66
}
/usr/bin/cmp -s -- "${0:A}" "${repository_runner}" || {
    print -u2 "executing P06 runner differs from the candidate repository file"
    exit 66
}

for required_file in "$candidate" "$release_configuration" "$contract"; do
    [[ -f "$required_file" && ! -L "$required_file" ]] || {
        print -u2 "required P06 input is absent or unsafe: $required_file"
        exit 65
    }
done
[[ -d "$repository" && -d "$runtime" && ! -L "$runtime" ]] || {
    print -u2 "repository or runtime bundle is absent or unsafe"
    exit 65
}
[[ ! -e "$output" ]] || {
    print -u2 "refusing to overwrite P06 evidence: $output"
    exit 65
}

python3 "${script_directory}/capture_p06_reproduction_v4.py" \
    --repository "$repository" \
    --candidate "$candidate" \
    --runtime "$runtime" \
    --release-configuration "$release_configuration" \
    --contract "$contract" \
    --output "$output"

python3 "${script_directory}/p06_reproduction_v4.py" verify \
    --evidence "$output" \
    --candidate "$candidate" \
    --contract "$contract"
