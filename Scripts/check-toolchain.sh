#!/usr/bin/env bash
# Verifies that the tools required for local development are installed and recent enough.
set -euo pipefail

readonly REQUIRED_SWIFT_MAJOR=6
readonly REQUIRED_SWIFT_MINOR=2

fail() {
  echo "error: $*" >&2
  exit 1
}

command -v swift >/dev/null || fail "swift is not installed (see https://www.swift.org/install)"

swift_version="$(swift --version 2>&1 | sed -n 's/.*Swift version \([0-9]*\)\.\([0-9]*\).*/\1 \2/p' | head -n 1)"
read -r swift_major swift_minor <<<"${swift_version}"

if (( swift_major < REQUIRED_SWIFT_MAJOR )) \
  || (( swift_major == REQUIRED_SWIFT_MAJOR && swift_minor < REQUIRED_SWIFT_MINOR )); then
  fail "Swift ${REQUIRED_SWIFT_MAJOR}.${REQUIRED_SWIFT_MINOR}+ is required, found ${swift_major}.${swift_minor}"
fi
echo "swift   ${swift_major}.${swift_minor}"

command -v docker >/dev/null || fail "docker is not installed (needed for PostgreSQL and the container image)"
docker compose version >/dev/null 2>&1 || fail "the docker compose plugin is not installed"
echo "docker  $(docker --version | sed 's/Docker version \([^,]*\),.*/\1/')"

if command -v swiftlint >/dev/null; then
  echo "swiftlint $(swiftlint --version)"
else
  echo "warning: swiftlint is not installed; 'make lint' falls back to its container image" >&2
fi
