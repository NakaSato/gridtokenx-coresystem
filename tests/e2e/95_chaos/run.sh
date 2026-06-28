#!/usr/bin/env bash
# Suite 95 — Resilience / fault-injection (chaos). Proves documented degrade-
# gracefully invariants by actually breaking a dependency mid-run and asserting the
# critical path still serves.
#
# OFF by default (gate E2E_RUN_CHAOS=1) — these stop/start real containers, so they
# are invasive and must never run in the default pass. Each case restores what it
# broke (pytest fixtures with teardown), but a hard-killed run can leave a dependency
# stopped — `docker compose up -d` to recover.
#
# Scope note: cases here only break dependencies that are ISOLATED to one service
# (e.g. the aggregator's dedicated InfluxDB). Shared infra (Redis, NATS, Kafka,
# validator) is deliberately NOT torn down — it would break sibling suites and the
# blast radius isn't a single-service degrade. Those degrade paths are covered at the
# unit/integration tier inside each service (e.g. influxdb.rs record_drops_* tests,
# noti rabbitmq_dlx.rs).
#
# Run: E2E_RUN_CHAOS=1 bash tests/e2e/95_chaos/run.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../env.sh"
source "$HERE/../lib/assert.sh"

echo "=== Chaos / Resilience Suite | run $E2E_RUN_ID ==="

if [ "${E2E_RUN_CHAOS:-0}" != "1" ]; then
    log_warn "Chaos suite skipped (set E2E_RUN_CHAOS=1 — invasive: stops/starts real containers)"
    suite_summary; exit 0
fi

if ! command -v docker >/dev/null || ! docker info >/dev/null 2>&1; then
    log_warn "docker daemon unreachable — skipping chaos suite"
    suite_summary; exit 0
fi

pytest_suite "$HERE" || E2E_FAIL=$((E2E_FAIL+1))
suite_summary
