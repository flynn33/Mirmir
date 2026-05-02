#!/usr/bin/env bash
set -euo pipefail

# Forsetti Xcode Template Installer
# Usage: ./Scripts/install-forsetti-xcode-template.sh
# Installs all Forsetti project templates (App, UI Module, Service Module, Manifest).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SOURCE_TEMPLATES_DIR="$REPO_ROOT/XcodeTemplates/Project Templates/Forsetti"
DESTINATION_ROOT="$HOME/Library/Developer/Xcode/Templates/Project Templates/Forsetti"

if [[ ! -d "$SOURCE_TEMPLATES_DIR" ]]; then
  echo "Error: Source templates directory not found at: $SOURCE_TEMPLATES_DIR" >&2
  echo "Make sure you are running this from the Forsetti repository." >&2
  exit 1
fi

mkdir -p "$DESTINATION_ROOT"

# Remove existing Forsetti templates to avoid stale files from prior versions.
find "$DESTINATION_ROOT" -mindepth 1 -maxdepth 1 -name '*.xctemplate' -exec rm -rf {} +

cp -R "$SOURCE_TEMPLATES_DIR"/. "$DESTINATION_ROOT"/

echo ""
echo "Forsetti Xcode templates installed successfully."
echo "Location: $DESTINATION_ROOT"
echo ""
echo "Installed templates:"
find "$DESTINATION_ROOT" -mindepth 1 -maxdepth 1 -name '*.xctemplate' -type d -exec basename {} \; | sort | sed 's/^/  - /'
echo ""
echo "Next steps:"
echo "  1. Quit and relaunch Xcode."
echo "  2. File > New > Project > Multiplatform."
echo "  3. Choose one of the Forsetti templates and add the ForsettiFramework package."
echo ""
