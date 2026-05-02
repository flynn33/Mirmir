#!/usr/bin/env bash
set -euo pipefail

DESTINATION_ROOT="$HOME/Library/Developer/Xcode/Templates/Project Templates/Forsetti"

if [[ -d "$DESTINATION_ROOT" ]]; then
  find "$DESTINATION_ROOT" -mindepth 1 -maxdepth 1 -name '*.xctemplate' -exec rm -rf {} +

  if [[ -z "$(find "$DESTINATION_ROOT" -mindepth 1 -maxdepth 1 2>/dev/null)" ]]; then
    rmdir "$DESTINATION_ROOT" 2>/dev/null || true
  fi

  echo "Removed Forsetti templates from: $DESTINATION_ROOT"
else
  echo "Forsetti templates not installed: $DESTINATION_ROOT"
fi
