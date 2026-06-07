#!/usr/bin/env bash
# Lint the docs harness across the superproject AND every checked-out submodule.
#
# The superproject linter skips links/citations that point INTO a submodule
# (the file lives there, not here). This runner closes that gap: it re-runs the
# SAME linter with --root set to each submodule, so code-anchored `path:line`
# claims (e.g. `crates/.../main.rs:150`) are validated against the tree where
# the file actually exists — the drift class that let 127.0.0.1 survive before.
#
# Submodules that are not checked out (empty gitlink dir) are skipped with a
# notice. Exit 1 if any root has findings.
#
# Usage: scripts/lint-docs-all.sh        (or: just lint-docs-all)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LINTER="$ROOT/scripts/lint-docs.py"
rc=0

# Superproject first.
python3 "$LINTER" || rc=1

# Each submodule, against its own tree.
while IFS= read -r p; do
  dir="$ROOT/$p"
  if [ ! -d "$dir" ] || [ -z "$(ls -A "$dir" 2>/dev/null)" ]; then
    echo "doc-lint [$p]: skipped (submodule not checked out)"
    continue
  fi
  python3 "$LINTER" --root "$dir" || rc=1
done < <(grep -E '^[[:space:]]*path[[:space:]]*=' "$ROOT/.gitmodules" | sed 's/.*=[[:space:]]*//')

exit $rc
