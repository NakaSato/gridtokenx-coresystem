#!/usr/bin/env bash
# GridTokenX E2E orchestrator.
#   tests/e2e/run.sh              # health gate -> run all suites -> summary
#   tests/e2e/run.sh 10_iam       # run a single suite dir
#
# Apple Silicon: raise file limit BEFORE any solana-test-validator load (CLAUDE.md caveat).
ulimit -n 65536 2>/dev/null || true

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
source "$HERE/env.sh"
source "$HERE/lib/assert.sh"

SUITE_FILTER="${1:-}"
SKIP_GATE="${SKIP_GATE:-0}"
ARTIFACTS="$HERE/artifacts/$E2E_RUN_ID"
mkdir -p "$ARTIFACTS"

# --- Health gate ---------------------------------------------------------
health_gate() {
    [ "$SKIP_GATE" == "1" ] && { log_warn "health gate skipped (SKIP_GATE=1)"; return 0; }
    log_info "Bring-up + health gate (app.sh doctor)..."
    if ! "$ROOT/scripts/app.sh" doctor > "$ARTIFACTS/doctor.log" 2>&1; then
        cat "$ARTIFACTS/doctor.log"
        die "health gate failed — run './scripts/app.sh start && ./scripts/app.sh init' first"
    fi
    log_success "all services healthy"
}

# --- Suite discovery / run ----------------------------------------------
# A suite = a numbered dir under tests/e2e/ that owns a run.sh entry point. That
# sub-script runs the suite's own cases (bash assertions and/or its test_*.py via
# the pytest_suite helper). The orchestrator only links to it — it does NOT reach
# into a suite to run pytest itself. Structure: run.sh -> NN_suite/run.sh -> cases.
run_suite() {
    local dir="$1" name; name="$(basename "$dir")"
    echo "=================================================="
    echo "▶ SUITE: $name"
    echo "=================================================="
    if [ ! -f "$dir/run.sh" ]; then
        log_warn "no run.sh in $name — skipping (every suite must own an entry point)"
        return 0
    fi
    local rc=0
    bash "$dir/run.sh" 2>&1 | tee "$ARTIFACTS/$name.log"
    rc=${PIPESTATUS[0]}
    return $rc
}

main() {
    health_gate
    local total_rc=0 ran=0
    for dir in "$HERE"/[0-9]*/; do
        [ -d "$dir" ] || continue
        local name; name="$(basename "$dir")"
        [ -n "$SUITE_FILTER" ] && [[ "$name" != *"$SUITE_FILTER"* ]] && continue
        run_suite "$dir" || total_rc=1
        ran=$((ran+1))
    done
    [ "$ran" -eq 0 ] && log_warn "no suites matched '${SUITE_FILTER}'"
    echo "=================================================="
    if [ "$total_rc" -eq 0 ]; then
        log_success "E2E run $E2E_RUN_ID PASSED ($ran suites). Artifacts: $ARTIFACTS"
    else
        log_fail "E2E run $E2E_RUN_ID had failures. Artifacts: $ARTIFACTS"
    fi
    exit $total_rc
}
main
