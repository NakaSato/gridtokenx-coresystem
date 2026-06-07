#!/usr/bin/env python3
"""Doc-lint for the GridTokenX superproject.

Closes the "verify" gap in our docs harness: broken relative links and stale
`path:line` citations should fail CI, not rot silently (this is what let the
127.0.0.1 / deleted-file links survive before).

Checks, over superproject-tracked Markdown only:

  1. Broken relative links   — `[text](rel/path.md)` whose target file is missing.
  2. Stale path:line refs    — backtick refs `` `dir/file.rs:NN` `` (path contains
                               a slash) whose file is missing, or whose line number
                               is past end-of-file.
  3. §8 index drift          — every present `<component>/ARCHITECTURE.md` must be
                               linked in root `ARCHITECTURE.md` (the §8 component
                               index). Catches a doc added but never indexed.

Advisory (opt-in, never fails the build):
  - `--warn-stale DAYS` prints a note for any doc whose `Last reviewed: YYYY-MM-DD`
    is older than DAYS. A stale doc is a nudge, not a broken link — exit stays 0.

Deliberately out of scope (no false positives, no network):
  - http(s):// / mailto: / pure #anchor links, and `scheme://host:port` in backticks.
  - Links INTO a git submodule (file lives in the submodule, which CI's cheap lint
    job does not check out) — the submodule dir is verified to be registered instead.
  - Bare `file.rs:NN` with no path — unresolvable from prose, too noisy.
  - `.agents/**` — vendored third-party skill/agent bundle with its own link root;
    not part of this repo's architecture harness.
  - path:line refs whose file does not resolve in the superproject — assumed to be
    submodule shorthand (the file is real, just not checked out here).

Usage:
    scripts/lint-docs.py                       # all tracked superproject .md
    scripts/lint-docs.py FILE [FILE...]        # only these files
    scripts/lint-docs.py --root PATH           # lint a checked-out submodule
    scripts/lint-docs.py --warn-stale 180      # + advisory stale-review notes
Exit 0 = clean, 1 = findings (stale-review notes never affect the exit code).
"""

from __future__ import annotations

import datetime
import re
import subprocess
import sys
from pathlib import Path

# Repo root the linter resolves against. Defaults to this script's superproject;
# `--root PATH` retargets it so the SAME linter can lint a checked-out submodule
# (where its code-anchored `path:line` claims actually resolve). Reassigned in main().
REPO = Path(__file__).resolve().parent.parent

# Vendored skill/agent bundles with their own link conventions — not our harness.
EXCLUDE_PREFIXES = (".agents/",)

# `[text](target)` — capture target, ignore the title part `(url "t")` if any.
LINK_RE = re.compile(r"\[[^\]]*\]\(\s*<?([^)\s>]+)>?(?:\s+\"[^\"]*\")?\s*\)")
# Backtick code span containing a path with a slash and a :line suffix.
PATHLINE_RE = re.compile(r"`([^`\s]+/[^`\s]+\.[A-Za-z0-9_]+:\d+)`")
# Fenced code block fence (skip link/ref scanning inside code samples).
FENCE_RE = re.compile(r"^\s*(```|~~~)")
# A link target pointing at a one-level component ARCHITECTURE.md (root §8 index).
ARCH_LINK_RE = re.compile(r"\(([^)\s]+/ARCHITECTURE\.md)(?:#[^)]*)?\)")
# `Last reviewed: 2026-06-07` freshness marker (advisory).
REVIEW_RE = re.compile(r"Last reviewed:\s*(\d{4})-(\d{2})-(\d{2})")


def submodule_paths() -> set[str]:
    gm = REPO / ".gitmodules"
    if not gm.exists():
        return set()
    return set(re.findall(r"path\s*=\s*(.+)", gm.read_text()))


def tracked_md() -> list[Path]:
    out = subprocess.run(
        ["git", "-C", str(REPO), "ls-files", "*.md"],
        capture_output=True, text=True, check=True,
    ).stdout.split()
    subs = submodule_paths()
    files = []
    for rel in out:
        top = rel.split("/", 1)[0]
        if top in subs:
            continue  # md inside a submodule — that submodule lints its own
        if rel.startswith(EXCLUDE_PREFIXES):
            continue  # vendored bundle, own link root
        files.append(REPO / rel)
    return files


def in_submodule(rel_target: str, subs: set[str]) -> bool:
    top = rel_target.split("/", 1)[0]
    return top in subs


def line_count(p: Path) -> int:
    with p.open("rb") as f:
        return sum(1 for _ in f)


def check_arch_index() -> list[str]:
    """Every present `<component>/ARCHITECTURE.md` must be linked in root §8.

    Catches a component doc that was added but never indexed. Submodule docs are
    only visible when checked out, so a bare superproject run checks the in-tree
    components (apisix_conf, envoy_conf, gridtokenx-telemetry) and lint-docs-all /
    the recursive CI job extends the check to every submodule.
    """
    root_arch = REPO / "ARCHITECTURE.md"
    if not root_arch.exists():
        return []
    listed = {m.split("#", 1)[0] for m in ARCH_LINK_RE.findall(root_arch.read_text(errors="replace"))}
    findings = []
    for doc in sorted(REPO.glob("*/ARCHITECTURE.md")):
        rel = doc.relative_to(REPO).as_posix()
        if rel.startswith(EXCLUDE_PREFIXES):
            continue
        if rel not in listed:
            findings.append(f"ARCHITECTURE.md: component doc not indexed in §8 -> {rel}")
    return findings


def stale_notes(files: list[Path], days: int, today: datetime.date) -> list[str]:
    """Advisory: docs whose `Last reviewed:` date is older than `days`."""
    notes = []
    for md in files:
        if not md.exists():
            continue
        m = REVIEW_RE.search(md.read_text(errors="replace"))
        if not m:
            continue
        try:
            reviewed = datetime.date(int(m[1]), int(m[2]), int(m[3]))
        except ValueError:
            continue
        age = (today - reviewed).days
        if age > days:
            notes.append(f"{rel(md)}: reviewed {reviewed} ({age}d ago, > {days}d)")
    return notes


def check_file(md: Path, subs: set[str]) -> list[str]:
    findings: list[str] = []
    base = md.parent
    in_fence = False
    for n, line in enumerate(md.read_text(errors="replace").splitlines(), 1):
        if FENCE_RE.match(line):
            in_fence = not in_fence
            continue
        if in_fence:
            continue

        for target in LINK_RE.findall(line):
            t = target.strip()
            if (
                t.startswith(("http://", "https://", "mailto:", "#"))
                or t.startswith("<") and t.endswith(">")  # autolink/template
            ):
                continue
            path_part = t.split("#", 1)[0]  # drop #anchor fragment
            if not path_part:
                continue
            # Resolve relative to the md file; reject if it escapes via missing file.
            resolved = (base / path_part).resolve()
            try:
                rel_from_repo = resolved.relative_to(REPO).as_posix()
            except ValueError:
                rel_from_repo = ""
            if rel_from_repo and in_submodule(rel_from_repo, subs):
                # File lives in a submodule (not checked out in cheap lint) — only
                # confirm the submodule dir is registered, which it is by construction.
                continue
            if not resolved.exists():
                findings.append(
                    f"{rel(md)}:{n}: broken link -> {t}"
                )

        for ref in PATHLINE_RE.findall(line):
            if "://" in ref:
                continue  # scheme://host:port, not a path:line citation
            path_str, _, lineno_s = ref.rpartition(":")
            lineno = int(lineno_s)
            # Try repo-root-relative first, then md-relative.
            cand = REPO / path_str
            if not cand.is_file():
                cand = base / path_str
            if not cand.is_file():
                # Unresolvable in the superproject — assume submodule shorthand
                # (real file, not checked out in the cheap lint job). Don't flag:
                # we cannot distinguish "stale" from "lives in a submodule" here.
                continue
            lc = line_count(cand)
            if lineno > lc:
                findings.append(
                    f"{rel(md)}:{n}: stale path:line -> {ref} (file has {lc} lines)"
                )
    return findings


def rel(p: Path) -> str:
    try:
        return p.relative_to(REPO).as_posix()
    except ValueError:
        return str(p)


def main(argv: list[str]) -> int:
    global REPO
    warn_stale: int | None = None
    today: datetime.date | None = None
    positional: list[str] = []

    it = iter(argv)
    for a in it:
        if a == "--root":
            val = next(it, None)
            if val is None:
                print("doc-lint: --root needs a path", file=sys.stderr)
                return 2
            REPO = Path(val).resolve()
        elif a == "--warn-stale":
            val = next(it, None)
            if val is None or not val.isdigit():
                print("doc-lint: --warn-stale needs a day count", file=sys.stderr)
                return 2
            warn_stale = int(val)
        elif a == "--today":  # test hook; default is the real date
            val = next(it, None)
            try:
                today = datetime.date.fromisoformat(val or "")
            except ValueError:
                print("doc-lint: --today needs YYYY-MM-DD", file=sys.stderr)
                return 2
        else:
            positional.append(a)

    subs = submodule_paths()
    all_findings: list[str] = []
    if positional:
        files = [Path(a).resolve() for a in positional]
    else:
        files = tracked_md()
        # Index check only in full-tree mode (explicit-file runs target one doc).
        all_findings.extend(check_arch_index())

    for md in files:
        if not md.exists():
            continue
        all_findings.extend(check_file(md, subs))

    label = REPO.name

    if warn_stale is not None:
        notes = stale_notes(files, warn_stale, today or datetime.date.today())
        for note in notes:
            print(f"doc-lint [{label}] note: {note}", file=sys.stderr)
        if notes:
            print(f"doc-lint [{label}]: {len(notes)} stale-review note(s) (advisory)", file=sys.stderr)

    if all_findings:
        print(f"doc-lint [{label}]: {len(all_findings)} finding(s)\n", file=sys.stderr)
        for f in all_findings:
            print(f, file=sys.stderr)
        return 1
    print(f"doc-lint [{label}]: clean ({len(files)} files)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
