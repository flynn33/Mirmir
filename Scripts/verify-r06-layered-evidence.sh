#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
R06_EVIDENCE_ROOT="docs/roadmaps/evidence/r06"
R06_HISTORICAL_COMMIT="9ed01ea938a933f6406fd67e88edb74e7c84f5f4"
R06_HISTORICAL_TREE="32365e745dbf53d59213fe2294a6b63ba2642df7"

r06_temp_base_requested="${TMPDIR:-/tmp}"
if [[
  "$r06_temp_base_requested" != /* ||
  ! -d "$r06_temp_base_requested"
]]; then
  echo "R06 layered-evidence temporary base must be an existing absolute directory." >&2
  exit 1
fi
if ! r06_temp_base="$(
  cd -- "$r06_temp_base_requested" &&
    pwd -P
)"; then
  echo "R06 layered-evidence temporary base cannot be resolved physically." >&2
  exit 1
fi
if [[ "$r06_temp_base" != /* || ! -d "$r06_temp_base" ]]; then
  echo "R06 layered-evidence canonical temporary base is invalid." >&2
  exit 1
fi
readonly r06_temp_base

r06_validation_root="$(
  mktemp -d "$r06_temp_base/mirmir-r06-layered-evidence.XXXXXX"
)"
r06_source_worktree="$r06_validation_root/source"
r06_allowed_paths="$r06_validation_root/allowed-paths.txt"
r06_observed_paths="$r06_validation_root/observed-paths.txt"

cleanup_r06_layered_evidence() {
  if [[ -d "$r06_source_worktree" ]]; then
    git -C "$REPOSITORY_ROOT" worktree remove --force \
      "$r06_source_worktree" >/dev/null 2>&1 || true
  fi
  if [[ -d "$r06_validation_root" ]]; then
    rm -rf -- "$r06_validation_root"
  fi
}
trap cleanup_r06_layered_evidence EXIT

cd "$REPOSITORY_ROOT"

# The additive acceptance verifier binds the preserved historical bytes, the
# exact functional-acceptance record, and both later execution artifacts.
python3 Scripts/r06_phase_acceptance.py --check

{
  git ls-tree -r --name-only \
    "$R06_HISTORICAL_COMMIT" \
    -- "$R06_EVIDENCE_ROOT"
  printf '%s\n' \
    "docs/roadmaps/evidence/r06/records/functional-phase-acceptance.json" \
    "docs/roadmaps/evidence/r06/records/artifacts/functional-phase-acceptance/xcodebuild.log" \
    "docs/roadmaps/evidence/r06/records/artifacts/functional-phase-acceptance/xcresult-summary.json"
} | LC_ALL=C sort -u >"$r06_allowed_paths"

find "$R06_EVIDENCE_ROOT" -mindepth 1 ! -type d -print |
  LC_ALL=C sort >"$r06_observed_paths"

r06_unbound_paths="$(comm -23 "$r06_observed_paths" "$r06_allowed_paths")"
if [[ -n "$r06_unbound_paths" ]]; then
  echo "R06 evidence contains paths outside the historical and additive manifests:" >&2
  echo "$r06_unbound_paths" >&2
  exit 1
fi

# Validate the primary manifest with the exact verifier and repository shape
# that closed it. Later additive evidence remains outside this immutable view.
git worktree add --detach \
  "$r06_source_worktree" \
  "$R06_HISTORICAL_COMMIT"
(
  cd "$r06_source_worktree"
  git rev-parse HEAD | grep -Fx "$R06_HISTORICAL_COMMIT"
  git rev-parse HEAD^{tree} | grep -Fx "$R06_HISTORICAL_TREE"
  python3 Scripts/phase_evidence.py --phase R06 --check
)

git worktree remove --force "$r06_source_worktree"
rm -rf -- "$r06_validation_root"
trap - EXIT

echo "R06 layered historical and additive evidence: PASS"
