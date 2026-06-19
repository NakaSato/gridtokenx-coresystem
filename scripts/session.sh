#!/usr/bin/env bash
#
# session.sh - Launch Claude Code session(s) in a terminal at a project path,
#              remembering the last-used path so a no-arg call reopens it.
#
# Usage:
#   scripts/session.sh                 # reuse last session path (or cwd on first run)
#   scripts/session.sh <path|service> # open at <path> OR a known service name, save as last
#   scripts/session.sh --here          # run in the CURRENT shell (no new window)
#   scripts/session.sh --last          # print the saved last path and exit
#   scripts/session.sh --list          # list known service names and exit
#   scripts/session.sh --pick          # numbered menu, multi-select (e.g. 1-4 or 1,2,4,5)
#   scripts/session.sh --pick 1-4,6    # non-interactive multi-select
#   scripts/session.sh --help
#
# A bare name matching a known service resolves against the repo root, e.g.
#   scripts/session.sh gridtokenx-iam-service
#   scripts/session.sh iam-service          # gridtokenx- prefix optional
#
# Multi-select syntax (--pick): comma list and/or ranges, e.g.
#   1,2,4,5        # services 1,2,4,5
#   1-4            # services 1,2,3,4
#   1-3,6,9-10     # mixed
# Each selected service opens in its own new terminal window.
#
# Config:
#   CLAUDE_SESSION_DIR  (default: ~/.claude/gridtokenx-sessions)  - state dir
#   TERM_APP            (default: iTerm)  - macOS terminal app: iTerm | Terminal
#   CLAUDE_BIN          (default: claude)    - claude binary
#   CLAUDE_FLAGS        (default: --dangerously-skip-permissions)
#
set -euo pipefail

# Repo root = parent of this script's dir, so service names resolve from anywhere.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Known service submodules (selectable by short name or menu number).
SERVICES=(
    gridtokenx-aggregator-bridge
    gridtokenx-anchor
    gridtokenx-blockchain-core
    gridtokenx-chain-bridge
    gridtokenx-explorer
    gridtokenx-iam-service
    gridtokenx-meter-service
    gridtokenx-noti-service
    gridtokenx-smartmeter-simulator
    gridtokenx-telemetry
    gridtokenx-trading
    gridtokenx-trading-service
)

CONFIG_DIR="${CLAUDE_SESSION_DIR:-${HOME}/.claude/gridtokenx-sessions}"
LAST_PATH_FILE="${CONFIG_DIR}/last_path"
CLAUDE_BIN="${CLAUDE_BIN:-claude}"
CLAUDE_FLAGS="${CLAUDE_FLAGS:---dangerously-skip-permissions}"
TERM_APP="${TERM_APP:-iTerm}"
# Multi-select layout (iTerm): windows = one window per service, tabs = one window N tabs.
SESSION_LAYOUT="${SESSION_LAYOUT:-windows}"
# Fullscreen each iTerm window (native fullscreen = own Space). Set false for windowed.
ITERM_FULLSCREEN="${ITERM_FULLSCREEN:-true}"
# Window size when NOT fullscreen (x1 y1 x2 y2).
ITERM_BOUNDS="${ITERM_BOUNDS:-140, 90, 1340, 880}"

mkdir -p "$CONFIG_DIR"

# Resolve a bare service name (with/without gridtokenx- prefix) to an abs path.
resolve_service() {
    local name="$1" svc
    for svc in "${SERVICES[@]}"; do
        if [[ "$svc" == "$name" || "$svc" == "gridtokenx-$name" ]]; then
            printf '%s\n' "${REPO_ROOT}/${svc}"
            return 0
        fi
    done
    return 1
}

# Print the numbered service menu to stderr.
print_menu() {
    local i
    echo "Select service(s) — e.g. 1-4 or 1,2,4,5 :" >&2
    for i in "${!SERVICES[@]}"; do
        printf '%2d) %s\n' "$((i + 1))" "${SERVICES[$i]}" >&2
    done
}

# Expand a selection string like "1-3,6,9-10" into 1-based indices (one per line).
# Validates against the SERVICES count; bad tokens abort.
expand_selection() {
    local spec="$1" tok lo hi i n="${#SERVICES[@]}"
    local out=()
    spec="${spec// /}"
    IFS=',' read -ra toks <<< "$spec"
    for tok in "${toks[@]}"; do
        [[ -z "$tok" ]] && continue
        if [[ "$tok" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            lo="${BASH_REMATCH[1]}"; hi="${BASH_REMATCH[2]}"
        elif [[ "$tok" =~ ^([0-9]+)$ ]]; then
            lo="$tok"; hi="$tok"
        else
            echo "Bad selection token: '$tok'" >&2; return 1
        fi
        (( lo <= hi )) || { local t="$lo"; lo="$hi"; hi="$t"; }
        for (( i = lo; i <= hi; i++ )); do
            (( i >= 1 && i <= n )) || { echo "Out of range: $i (have 1-$n)" >&2; return 1; }
            out+=("$i")
        done
    done
    # Emit only after the whole spec validates (atomic — no partial launch).
    printf '%s\n' "${out[@]}"
}

# Launch one Claude session at an abs path. Honors run_here + TERM_APP.
launch_session() {
    local target="$1"
    printf '%s\n' "$target" > "$LAST_PATH_FILE"
    echo "Session path: $target"

    if [[ "$run_here" == true ]]; then
        cd "$target"
        exec "$CLAUDE_BIN" $CLAUDE_FLAGS
    fi

    local launch_cmd
    launch_cmd="cd $(printf '%q' "$target") && exec $(printf '%q' "$CLAUDE_BIN") ${CLAUDE_FLAGS}"

    case "$(uname -s)" in
        Darwin)
            case "$TERM_APP" in
                iTerm|iTerm2)
                    local geom
                    if [[ "$ITERM_FULLSCREEN" == true ]]; then
                        # Native fullscreen — each window gets its own Space.
                        geom="tell newWindow to set fullscreen to true"
                    else
                        geom="set bounds of newWindow to {${ITERM_BOUNDS}}"
                    fi
                    osascript <<OSA
tell application "iTerm"
    activate
    set newWindow to (create window with default profile)
    tell current session of newWindow to write text "${launch_cmd}"
    ${geom}
end tell
OSA
                    ;;
                *)
                    osascript <<OSA
tell application "Terminal"
    activate
    do script "${launch_cmd}"
end tell
OSA
                    ;;
            esac
            ;;
        Linux)
            local t
            for t in x-terminal-emulator gnome-terminal konsole xterm; do
                if command -v "$t" >/dev/null 2>&1; then
                    "$t" -e bash -lc "${launch_cmd}" &
                    return 0
                fi
            done
            echo "No terminal emulator found; running in current shell." >&2
            cd "$target"; exec "$CLAUDE_BIN" $CLAUDE_FLAGS
            ;;
        *)
            echo "Unsupported OS; running in current shell." >&2
            cd "$target"; exec "$CLAUDE_BIN" $CLAUDE_FLAGS
            ;;
    esac
}

# Open many sessions as TABS in a single (non-fullscreen) iTerm window.
# Args: abs paths. Updates last-path to the final one.
launch_iterm_tabs() {
    local p cmd body=""
    for p in "$@"; do
        printf '%s\n' "$p" > "$LAST_PATH_FILE"
        echo "Session path (tab): $p"
        cmd="cd $(printf '%q' "$p") && exec $(printf '%q' "$CLAUDE_BIN") ${CLAUDE_FLAGS}"
        if [[ -z "$body" ]]; then
            # First tab = the window's initial session.
            body="    set w to (create window with default profile)
    set bounds of w to {${ITERM_BOUNDS}}
    tell current session of w to write text \"${cmd}\""
        else
            body="${body}
    tell w
        set t to (create tab with default profile)
        tell current session of t to write text \"${cmd}\"
    end tell"
        fi
    done
    osascript <<OSA
tell application "iTerm"
    activate
${body}
end tell
OSA
}

usage() {
    grep '^#' "$0" | sed 's/^# \{0,1\}//' | sed '1d'
    exit "${1:-0}"
}

run_here=false
target=""
pick=false
pick_spec=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h) usage 0 ;;
        --here)    run_here=true; shift ;;
        --last)
            if [[ -f "$LAST_PATH_FILE" ]]; then cat "$LAST_PATH_FILE"; else echo "(none)"; fi
            exit 0 ;;
        --list)
            printf '%s\n' "${SERVICES[@]}"
            exit 0 ;;
        --pick)
            pick=true; shift
            # Optional inline spec: --pick 1-4,6
            if [[ $# -gt 0 && "$1" != --* ]]; then pick_spec="$1"; shift; fi
            ;;
        --*) echo "Unknown flag: $1" >&2; usage 1 ;;
        *)   target="$1"; shift ;;
    esac
done

# --pick: build a target list from a multi-select spec, launch each.
if [[ "$pick" == true ]]; then
    if [[ -z "$pick_spec" ]]; then
        print_menu
        printf '#? ' >&2
        read -r pick_spec
    fi
    idxs=()
    while IFS= read -r line; do idxs+=("$line"); done < <(expand_selection "$pick_spec")
    [[ "${#idxs[@]}" -gt 0 ]] || { echo "No selection or bad spec." >&2; exit 1; }

    # Multiple targets cannot share the current shell.
    if [[ "$run_here" == true && "${#idxs[@]}" -gt 1 ]]; then
        echo "--here cannot run multiple sessions; pick one." >&2; exit 1
    fi

    paths=()
    for i in "${idxs[@]}"; do
        paths+=("${REPO_ROOT}/${SERVICES[$((i - 1))]}")
    done

    # iTerm + multiple + tabs layout = one non-fullscreen window, N tabs.
    if [[ "$run_here" != true && "${#paths[@]}" -gt 1 \
          && "$TERM_APP" =~ ^iTerm && "$SESSION_LAYOUT" == "tabs" ]]; then
        launch_iterm_tabs "${paths[@]}"
    else
        for p in "${paths[@]}"; do
            launch_session "$p"
            # Let macOS finish the fullscreen→new-Space transition before the next
            # window, else rapid launches land on the same Space.
            [[ "${#paths[@]}" -gt 1 && "$ITERM_FULLSCREEN" == true ]] && sleep 1.2
        done
    fi
    exit 0
fi

# A bare service name resolves to its submodule path under the repo root.
if [[ -n "$target" && ! -d "$target" ]]; then
    if resolved="$(resolve_service "$target")"; then
        target="$resolved"
    fi
fi

# Resolve target path: explicit arg > saved last path > current dir.
if [[ -z "$target" ]]; then
    if [[ -f "$LAST_PATH_FILE" ]]; then
        target="$(cat "$LAST_PATH_FILE")"
    else
        target="$(pwd)"
    fi
fi

if [[ ! -d "$target" ]]; then
    echo "Path not a directory: $target" >&2
    exit 1
fi

# Canonicalize to absolute path and launch.
target="$(cd "$target" && pwd)"
launch_session "$target"
