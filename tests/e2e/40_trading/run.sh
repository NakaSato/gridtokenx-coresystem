#!/usr/bin/env bash
# Suite 40 — Trading Service (:4020): order lifecycle, CDA matching, settlement metrics.
# Cases live in this folder's test_*.py.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../env.sh"
source "$HERE/../lib/assert.sh"
pytest_suite "$HERE"
