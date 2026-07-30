#!/usr/bin/env bash
# GridTokenX E2E — bash assertion + logging helpers.
# Source after env.sh:  source "$(dirname "$0")/../lib/assert.sh"

GREEN='\033[0;32m'; BLUE='\033[0;34m'; RED='\033[0;31m'; YELLOW='\033[0;33m'; NC='\033[0m'

# Per-suite counters
E2E_PASS=0
E2E_FAIL=0

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
suite_summary() {
    echo "--------------------------------------------------"
    echo -e "Suite result: ${GREEN}${E2E_PASS} passed${NC}, ${RED}${E2E_FAIL} failed${NC}"
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
    ( cd "$dir/.." && uv run --no-project --with-requirements "$reqs" python -m pytest "$dir" -v )
}
