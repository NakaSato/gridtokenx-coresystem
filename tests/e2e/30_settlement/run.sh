#!/usr/bin/env bash
# Suite 30 — Surplus mint provenance. The bridge mints surplus DIRECTLY via Chain
# Bridge over NATS `chain.tx.mint` when a closed billing window has net generation
# (former "Path B"/SettlementEngine AND the meter.reading forward to meter-service
# were both removed). Cases: surplus window mints to the registry-resolved owner
# wallet with the right shape / non-surplus window mints nothing / dev envelope is
# unsigned (test_surplus_mint.py — skips loudly if minting is off, never green-by-
# silence), plus the fail-closed unregistered-meter ingress reject
# (test_unregistered_meter_rejected.py).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../env.sh"
source "$HERE/../lib/assert.sh"
pytest_suite "$HERE"
