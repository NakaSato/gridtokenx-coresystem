#!/usr/bin/env bash
# Suite 65 — ERP Bridge (:5050 HTTP): safety gates, outbox, reconciliation classes.
#
# Numbered 65, not 60: suite 60 is the Notification Service. The design spec
# named this suite `60_erp_bridge`, which would have collided.
#
# Cases live in this folder's test_*.py.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../env.sh"
source "$HERE/../lib/assert.sh"
pytest_suite "$HERE"
