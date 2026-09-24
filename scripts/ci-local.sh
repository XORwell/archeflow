#!/usr/bin/env bash
# ci-local.sh — Run the bats suite in a clean Ubuntu 24.04 container (same packages as CI),
# so tests that depend on the host (git default branch, locale, yq, jq version) fail locally too.
#
# Usage: ./scripts/ci-local.sh [bats-args...]   (needs podman or docker)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENGINE="$(command -v podman || command -v docker || true)"
[[ -n "$ENGINE" ]] || { echo "ERROR: podman or docker required" >&2; exit 1; }

# XDG_CONFIG_HOME is set like on GitHub runners so tests that leak host env fail here too.
"$ENGINE" run --rm -e XDG_CONFIG_HOME=/root/.config -v "$ROOT":/src:ro,Z docker.io/library/ubuntu:24.04 bash -c '
  set -e
  apt-get update -qq >/dev/null
  apt-get install -y -qq --no-install-recommends bats jq git shellcheck ca-certificates >/dev/null
  mkdir /work && cp -a /src/. /work/ && cd /work
  git config --global user.email ci@example.com
  git config --global user.name ci
  ./scripts/run-tests.sh "$@"
' _ "$@"
