#!/usr/bin/env bash
# Suite 20 — Aggregator/Oracle Bridge telemetry ingestion (REST + gRPC, DLMS).
# Cases live in this folder's test_*.py; this script is the suite entry point the
# orchestrator dispatches to. Skips gracefully when Oracle/Redis/Kafka are down.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../env.sh"
source "$HERE/../lib/assert.sh"
pytest_suite "$HERE"
