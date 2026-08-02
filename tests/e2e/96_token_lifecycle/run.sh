#!/usr/bin/env bash
# Suite 96 — Token lifecycle: on-chain GRID/GRX balance deltas across the full
# mint -> trade -> settle path. Cases live in this folder's test_*.py.
#
# This entry point was missing until 2026-08-02, so the orchestrator warned and
# scored the suite as passed — it had never run under `just e2e`.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../env.sh"
source "$HERE/../lib/assert.sh"
pytest_suite "$HERE"
