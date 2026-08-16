#!/usr/bin/env bash
# GridTokenX E2E — bash assertion + logging helpers.
# Source after env.sh:  source "$(dirname "$0")/../lib/assert.sh"

GREEN='\033[0;32m'; BLUE='\033[0;34m'; RED='\033[0;31m'; YELLOW='\033[0;33m'; NC='\033[0m'

# Per-suite counters
E2E_PASS=0
E2E_FAIL=0
# Pytest cases skipped in this suite. Tracked because a skip is NOT a pass:
# `suite_summary` used to print only passed/failed, so a suite that skipped every
# case looked exactly like one that verified something.
E2E_SKIP=0

log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_success() { echo -e "${GREEN}[PASS]${NC} $1"; E2E_PASS=$((E2E_PASS+1)); }
# Soft fail: records failure, keeps suite running.
log_fail()    { echo -e "${RED}[FAIL]${NC} $1"; E2E_FAIL=$((E2E_FAIL+1)); }
# Hard fail: aborts suite immediately (use for unrecoverable preconditions).
# Writes to stderr so it never pollutes captured command-substitution output.
die()         { echo -e "${RED}[FATAL]${NC} $1" >&2; exit 1; }

# assert_eq <actual> <expected> <msg>
assert_eq() {
    if [ "$1" == "$2" ]; then log_success "$3"; else log_fail "$3 (got '$1', want '$2')"; fi
}

# assert_nonempty <value> <msg>
assert_nonempty() {
    if [ -n "$1" ]; then log_success "$2"; else log_fail "$2 (empty)"; fi
}

# assert_contains <haystack> <needle> <msg>
assert_contains() {
    if [[ "$1" == *"$2"* ]]; then log_success "$3"; else log_fail "$3 (missing '$2')"; fi
}

# assert_status <actual_code> <expected_code> <msg>
assert_status() {
    if [ "$1" == "$2" ]; then log_success "$3 [$1]"; else log_fail "$3 (got $1, want $2)"; fi
}

# retry_until <timeout_s> <interval_s> <cmd...> — succeeds when cmd exits 0 within timeout.
retry_until() {
    local timeout=$1 interval=$2; shift 2
    local elapsed=0
    while [ "$elapsed" -lt "$timeout" ]; do
        if "$@"; then return 0; fi
        sleep "$interval"; elapsed=$((elapsed+interval))
    done
    return 1
}

# suite_summary — print counts, exit nonzero if any failure. Call at end of each suite.
# Skips are reported but never fail the suite: a service that is genuinely not
# running is a legitimate skip, and failing on it would make a partial stack
# unusable. The point is only that a skip stops being invisible.
suite_summary() {
    echo "--------------------------------------------------"
    local skip_note=""
    [ "${E2E_SKIP:-0}" -gt 0 ] && skip_note=", ${YELLOW}${E2E_SKIP} skipped${NC}"
    echo -e "Suite result: ${GREEN}${E2E_PASS} passed${NC}, ${RED}${E2E_FAIL} failed${NC}${skip_note}"
    [ "$E2E_FAIL" -eq 0 ] || exit 1
}

# pytest_suite [dir] — run this suite folder's pytest files via the project venv.
# Returns 0 (no-op) when the folder has no test_*.py. Otherwise returns pytest's
# exit code. cwd is tests/e2e so conftest.py (sys.path) + .venv resolve correctly.
# Centralizes the `uv run --no-project` incantation for every suite's run.sh.
pytest_suite() {
    local dir="${1:-$HERE}"
    ls "$dir"/test_*.py >/dev/null 2>&1 || return 0
    # `--no-project` deliberately isolates from the repo's Python projects, which
    # also means NOTHING is installed — pytest included. tests/e2e/requirements.txt
    # already declares the full set (pytest, requests, grpcio, solders, redis,
    # nats-py, …) but was referenced nowhere, so every pytest suite died on
    # "No module named pytest". Worse, only 10_iam reported that as a failure:
    # 60_noti and 65_erp_bridge printed the same error and still summarised
    # "0 passed, 0 failed", which reads as "no cases" rather than "could not run".
    # Feeding the requirements file to uv keeps the isolation and the single
    # source of truth for the dep set.
    local reqs="$dir/../requirements.txt"
    [ -f "$reqs" ] || reqs="$(cd "$dir/.." && pwd)/requirements.txt"

    # Capture while still streaming, so the skip tally can be read off pytest's
    # own summary line without hiding output from the operator.
    local out rc name
    name="$(basename "$dir")"
    out="$(mktemp)"
    ( cd "$dir/.." && uv run --no-project --with-requirements "$reqs" python -m pytest "$dir" -v ) 2>&1 | tee "$out"
    rc=${PIPESTATUS[0]}

    # A suite that runs and skips EVERY case reports the same green as one that
    # verified something — the no-entry-point failure this script already guards
    # against, wearing a disguise. It has bitten three times: a skip predicate
    # that silently inverted, an http/https probe mismatch that skipped 21 cases,
    # and a legacy test that "passed" by asserting a vulnerability still worked.
    # Warn, don't fail: a service that is genuinely down is a legitimate skip.
    local summary skipped
    summary="$(grep -E '^=+.*(passed|failed|skipped|error).*=+$' "$out" | tail -1)"
    skipped="$(printf '%s' "$summary" | grep -oE '[0-9]+ skipped' | grep -oE '^[0-9]+')"
    if [ -n "$skipped" ]; then
        E2E_SKIP=$((E2E_SKIP + skipped))
        if printf '%s' "$summary" | grep -qE '[0-9]+ (passed|failed)'; then
            log_warn "$name: $skipped case(s) skipped — partial coverage, check why."
        else
            log_warn "$name: ALL $skipped case(s) SKIPPED — this suite asserted NOTHING."
            log_warn "  A fully-skipped suite is not a pass. Read the skip reason above:"
            log_warn "  a wrong probe (scheme/port/host) looks identical to a service being down."
        fi
    fi

    rm -f "$out"
    return $rc
}
