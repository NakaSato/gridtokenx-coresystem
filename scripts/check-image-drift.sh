#!/usr/bin/env bash
# check-image-drift.sh — flag running service containers whose image predates the
# source it was built from (the "deploy drift" class: a running container built days
# before the current code).
#
# Three of the seven blockers in the Path B settlement debug were exactly this — IAM
# and Chain Bridge containers running binaries built before a blockchain-core rename,
# so committed-correct code behaved like a bug at runtime.
#
# For each locally-built compose service it:
#   1. reads the Dockerfile COPY lines to find the source submodules it is built from
#      (this captures cross-submodule deps — e.g. aggregator-bridge is built from
#      blockchain-core/iam-service/telemetry too, not just its own dir);
#   2. compares the running image's build time against each source submodule's HEAD
#      commit time, and checks for uncommitted changes in those submodules.
#
# A service is STALE if its image is older than a source commit (rebuild to pick it
# up) or DIRTY if a source submodule has uncommitted changes (the image cannot
# contain them). Exit non-zero if any drift is found (so CI / app.sh doctor can gate).
#
# Usage:
#   bash scripts/check-image-drift.sh            # report only
#   bash scripts/check-image-drift.sh --fix      # rebuild + recreate stale/dirty services
#   bash scripts/check-image-drift.sh --json      # machine-readable report
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
COMPOSE_FILE="$ROOT/docker-compose.yml"

FIX=0
JSON=0
for arg in "$@"; do
  case "$arg" in
    --fix) FIX=1 ;;
    --json) JSON=1 ;;
    *) echo "unknown arg: $arg" >&2; exit 2 ;;
  esac
done

# ISO-8601 -> epoch seconds, portably (BSD/GNU date differ; python3 is everywhere here).
iso2epoch() { python3 -c 'import sys,datetime;print(int(datetime.datetime.fromisoformat(sys.argv[1].replace("Z","+00:00").split(".")[0]+"+00:00").timestamp()))' "$1"; }

# Emit "service|context|dockerfile|container_name" for every build: stanza in compose.
parse_built_services() {
  awk '
    /^  [a-zA-Z0-9_-]+:[[:space:]]*$/ { svc=$1; sub(/:$/,"",svc); inbuild=0; ctx=""; df=""; cname="" }
    /^    build:[[:space:]]*$/        { inbuild=1 }
    inbuild && /^      context:/      { ctx=$2 }
    inbuild && /^      dockerfile:/   { df=$2 }
    /^    container_name:/            { cname=$2; if (df!="") { print svc "|" ctx "|" df "|" cname } }
  ' "$COMPOSE_FILE"
}

# Given context + dockerfile + a COPY source, return the top-level gridtokenx-* dir it
# lives under (the submodule root), or empty if none.
submodule_root_of() {
  local ctx="$1" src="$2"
  local p="${ctx#./}/${src}"
  p="${p#/}"
  # first path segment that looks like a submodule
  IFS='/' read -ra parts <<< "$p"
  for seg in "${parts[@]}"; do
    [[ "$seg" == gridtokenx-* ]] && { echo "$seg"; return; }
  done
}

drift_found=0
declare -a STALE_SVCS=()
[[ "$JSON" == 1 ]] && echo "["
first_json=1

while IFS='|' read -r svc ctx df cname; do
  [[ -z "$df" ]] && continue
  # Resolve the Dockerfile path from repo root.
  local_ctx="${ctx#./}"
  if [[ -z "$local_ctx" || "$local_ctx" == "." ]]; then
    dfpath="$df"
  else
    dfpath="$local_ctx/$df"
  fi
  [[ -f "$dfpath" ]] || { echo "⚠️  $cname: Dockerfile not found ($dfpath), skipping" >&2; continue; }

  # Source submodules = the gridtokenx-* dirs the Dockerfile COPYs (excl. --from stages).
  # Newline-separated, deduped via sort -u (macOS bash 3.2 has no associative arrays).
  roots=""
  while read -r cpsrc; do
    r="$(submodule_root_of "$ctx" "$cpsrc")"
    [[ -n "$r" && -d "$r" ]] && roots="${roots}${r}"$'\n'
  done < <(grep -E '^[[:space:]]*COPY[[:space:]]' "$dfpath" | grep -v -- '--from' | awk '{print $2}')
  # Fallback: if no COPY source resolved, use the submodule the Dockerfile lives in.
  if [[ -z "$roots" ]]; then
    r="$(submodule_root_of "" "$dfpath")"
    [[ -n "$r" ]] && roots="${r}"$'\n'
  fi
  roots="$(printf '%s' "$roots" | sort -u | grep -v '^$' || true)"

  # Running container's image + build time.
  if ! img="$(docker inspect "$cname" --format '{{.Config.Image}}' 2>/dev/null)"; then
    echo "⚪ $cname: not running — skip (start it, or it cannot drift)"; continue
  fi
  created_iso="$(docker image inspect "$img" --format '{{.Created}}' 2>/dev/null || true)"
  [[ -z "$created_iso" ]] && { echo "⚠️  $cname: image $img not found locally, skipping" >&2; continue; }
  img_epoch="$(iso2epoch "$created_iso")"

  reasons=()
  while IFS= read -r root; do
    [[ -z "$root" ]] && continue
    commit_epoch="$(git -C "$root" log -1 --format=%ct 2>/dev/null || echo 0)"
    short_sha="$(git -C "$root" rev-parse --short HEAD 2>/dev/null || echo '?')"
    if [[ "$commit_epoch" -gt "$img_epoch" ]]; then
      reasons+=("source committed after image build: $root@$short_sha")
    fi
    if [[ -n "$(git -C "$root" status --porcelain 2>/dev/null)" ]]; then
      reasons+=("uncommitted changes in $root (not in image)")
    fi
  done <<< "$roots"

  if [[ ${#reasons[@]} -gt 0 ]]; then
    drift_found=1
    STALE_SVCS+=("$svc")
    if [[ "$JSON" == 1 ]]; then
      [[ "$first_json" == 0 ]] && echo ","; first_json=0
      printf '  {"service":"%s","container":"%s","image_built":"%s","reasons":[%s]}' \
        "$svc" "$cname" "$created_iso" "$(printf '"%s",' "${reasons[@]}" | sed 's/,$//')"
    else
      echo "🔴 STALE  $cname  (image built $created_iso)"
      for rsn in "${reasons[@]}"; do echo "          └─ $rsn"; done
    fi
  else
    [[ "$JSON" == 1 ]] || echo "🟢 fresh  $cname"
  fi
  unset roots
done < <(parse_built_services)

[[ "$JSON" == 1 ]] && { echo; echo "]"; }

if [[ "$drift_found" == 1 && "$FIX" == 1 ]]; then
  echo ""
  echo "🔧 Rebuilding ${#STALE_SVCS[@]} stale service(s): ${STALE_SVCS[*]}"
  docker compose build "${STALE_SVCS[@]}"
  docker compose up -d "${STALE_SVCS[@]}"
  echo "✅ Rebuilt + recreated. Re-run without --fix to confirm clean."
  exit 0
fi

if [[ "$drift_found" == 1 ]]; then
  [[ "$JSON" == 1 ]] || echo -e "\nDrift found. Run 'just rebuild-stale' (or this script with --fix) to rebuild."
  exit 1
fi
[[ "$JSON" == 1 ]] || echo -e "\nAll running service images are in sync with their source. ✅"
exit 0
