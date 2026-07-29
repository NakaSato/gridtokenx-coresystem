#!/usr/bin/env bash
# Sync apisix_conf/apisix.yaml into the dev-only APISIX UI mirror.
#
# The real gateway runs file-driven standalone mode, which disables the Admin
# API — the embedded Dashboard cannot run there (apisix_conf/ARCHITECTURE.md §3).
# The `apisix-ui` compose service (profile `ui`) is a traditional-mode APISIX +
# throwaway etcd whose only job is to serve the Dashboard over a *mirror* of the
# declarative config. This script converts apisix.yaml to JSON (yq container —
# no host deps) and PUTs each resource through the mirror's Admin API.
#
#   docker compose --profile ui up -d          # start mirror + etcd
#   ./scripts/sync-apisix-ui.sh                # push current apisix.yaml
#   open http://localhost:8001/ui/             # key: gridtokenx-ui-admin-dev
#
# Idempotent — re-run after every apisix.yaml edit. The mirror's etcd has no
# volume, so a mirror restart starts empty: just re-run this. Edits made in the
# Dashboard touch only the mirror; apisix.yaml stays the single source of truth.
set -euo pipefail
cd "$(dirname "$0")/.."

ADMIN="${APISIX_UI_ADMIN:-http://127.0.0.1:8001}"
KEY="${APISIX_UI_ADMIN_KEY:-gridtokenx-ui-admin-dev}"

# Wait for the mirror's Admin API: etcd going healthy unblocks the container, but
# APISIX itself needs a few more seconds before it answers. Without this the sync
# races startup and dies on connection-refused.
for i in $(seq 1 30); do
  if curl -sf -o /dev/null -m 2 "$ADMIN/apisix/admin/routes" -H "X-API-KEY: $KEY"; then
    break
  fi
  if [ "$i" -eq 30 ]; then
    echo "Admin API at $ADMIN not responding after 30s." >&2
    echo "Is the mirror running?  docker compose --profile ui up -d apisix-ui apisix-ui-etcd" >&2
    exit 1
  fi
  sleep 1
done

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
# yq resolves the YAML anchors (e.g. the shared health-check block) into plain JSON.
docker run --rm -i mikefarah/yq eval -o=json - < apisix_conf/apisix.yaml > "$tmp"

ADMIN="$ADMIN" KEY="$KEY" TMP="$tmp" python3 <<'PY'
import json, os, sys, urllib.request, urllib.error

cfg = json.load(open(os.environ["TMP"]))
admin, key = os.environ["ADMIN"], os.environ["KEY"]

def put(path, obj):
    req = urllib.request.Request(
        f"{admin}/apisix/admin/{path}",
        data=json.dumps(obj).encode(),
        method="PUT",
        headers={"X-API-KEY": key, "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            return r.status, ""
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode(errors="replace")[:200]

failures = 0
# Referenced resources first so routes never point at ids that don't exist yet.
for section, id_field in [
    ("upstreams", "id"),
    ("plugin_configs", "id"),
    ("ssls", "id"),
    ("consumers", "username"),
    ("routes", "id"),
]:
    for item in cfg.get(section) or []:
        rid = item[id_field]
        status, err = put(f"{section}/{rid}", item)
        ok = 200 <= status < 300
        print(f"{'ok ' if ok else 'ERR'} {section}/{rid} -> {status}{(' ' + err) if err else ''}")
        failures += 0 if ok else 1

sys.exit(1 if failures else 0)
PY

echo "UI mirror synced from apisix_conf/apisix.yaml — browse $ADMIN/ui/"
