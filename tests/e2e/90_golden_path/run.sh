#!/usr/bin/env bash
# Suite 90 — Golden path: full cross-service flow (register -> telemetry -> mint -> trade).
# Cases live in this folder's test_*.py.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../env.sh"
source "$HERE/../lib/assert.sh"
pytest_suite "$HERE"
