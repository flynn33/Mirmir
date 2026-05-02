#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$REPO_ROOT"

echo "==> Running Swift tests (includes architecture enforcement tests)..."
swift test --parallel --enable-code-coverage

echo "==> Running SwiftLint with Forsetti guardrails..."
if ! command -v swiftlint >/dev/null 2>&1; then
  echo "swiftlint is not installed. Install with: brew install swiftlint" >&2
  exit 1
fi

swiftlint lint --strict --config .swiftlint.yml

echo "==> Forsetti guardrails passed."
