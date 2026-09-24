#!/usr/bin/env bash
# Extract the latest version from CHANGELOG.md (first "## [x.y.z]" heading).
# Portable: uses sed -E instead of GNU-only grep -P; quits at the first match
# (no "| head -1", which can SIGPIPE sed under pipefail).
set -euo pipefail
ARCHEFLOW_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
sed -nE '/^## \[[0-9]+\.[0-9]+\.[0-9]+\]/{s/^## \[([0-9]+\.[0-9]+\.[0-9]+)\].*/\1/p;q;}' "$ARCHEFLOW_ROOT/CHANGELOG.md"
