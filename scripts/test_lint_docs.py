#!/usr/bin/env python3
"""Self-verifying tests for scripts/lint-docs.py.

Black-box: drive the linter CLI over throwaway fixtures and assert exit code +
message. Stdlib `unittest` only — no pip, so CI can run it with bare python.

    python3 scripts/test_lint_docs.py        # or: python3 -m unittest
"""

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

LINTER = Path(__file__).resolve().parent / "lint-docs.py"


def run(*md_files: Path) -> subprocess.CompletedProcess:
    return subprocess.run(
        [sys.executable, str(LINTER), *map(str, md_files)],
        capture_output=True, text=True,
    )


class DocLintTest(unittest.TestCase):
    def _md(self, d: Path, body: str) -> Path:
        p = d / "doc.md"
        p.write_text(body)
        return p

    def test_clean_passes(self):
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            (d / "real.md").write_text("hi\n")
            md = self._md(d, "See [real](real.md) and [web](https://x.test).\n")
            r = run(md)
            self.assertEqual(r.returncode, 0, r.stderr)

    def test_broken_link_fails(self):
        with tempfile.TemporaryDirectory() as d:
            md = self._md(Path(d), "Dead [link](does-not-exist.md).\n")
            r = run(md)
            self.assertEqual(r.returncode, 1)
            self.assertIn("broken link", r.stderr)
            self.assertIn("does-not-exist.md", r.stderr)

    def test_anchor_and_fenced_links_ignored(self):
        with tempfile.TemporaryDirectory() as d:
            md = self._md(
                Path(d),
                "Jump [here](#section).\n\n```\n[fake](nope.md)\n```\n",
            )
            r = run(md)
            self.assertEqual(r.returncode, 0, r.stderr)

    def test_stale_pathline_fails(self):
        # path:line requires a slash in the path (bare names are skipped).
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            (d / "sub").mkdir()
            (d / "sub" / "src.rs").write_text("one\ntwo\n")  # 2 lines
            md = self._md(d, "Ref `sub/src.rs:99` is past EOF.\n")
            r = run(md)
            self.assertEqual(r.returncode, 1)
            self.assertIn("stale path:line", r.stderr)

    def test_in_range_pathline_passes(self):
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            (d / "sub").mkdir()
            (d / "sub" / "src.rs").write_text("one\ntwo\nthree\n")
            md = self._md(d, "Ref `sub/src.rs:2` is fine.\n")
            r = run(md)
            self.assertEqual(r.returncode, 0, r.stderr)

    def test_url_in_backticks_not_pathline(self):
        with tempfile.TemporaryDirectory() as d:
            md = self._md(Path(d), "Connect to `redis://127.0.0.1:6379`.\n")
            r = run(md)
            self.assertEqual(r.returncode, 0, r.stderr)

    def test_unresolvable_pathline_skipped(self):
        # Submodule shorthand: path not present here -> not flagged.
        with tempfile.TemporaryDirectory() as d:
            md = self._md(Path(d), "See `some/submodule/file.rs:100`.\n")
            r = run(md)
            self.assertEqual(r.returncode, 0, r.stderr)

    def test_arch_index_drift_flagged(self):
        # A component ARCHITECTURE.md present but absent from root §8 -> finding.
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            subprocess.run(["git", "init", "-q", str(d)], check=True)
            (d / "ARCHITECTURE.md").write_text(
                "# Root\n## 8. Components\n- [a](comp-a/ARCHITECTURE.md)\n"
            )
            for c in ("comp-a", "comp-b"):
                (d / c).mkdir()
                (d / c / "ARCHITECTURE.md").write_text("# " + c + "\n")
            subprocess.run(["git", "-C", str(d), "add", "-A"], check=True)
            # No file args -> full-tree mode, runs the index check.
            r = subprocess.run(
                [sys.executable, str(LINTER), "--root", str(d)],
                capture_output=True, text=True,
            )
            self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
            self.assertIn("not indexed in §8", r.stderr)
            self.assertIn("comp-b/ARCHITECTURE.md", r.stderr)
            self.assertNotIn("comp-a/ARCHITECTURE.md", r.stderr)

    def test_root_flag_retargets_and_labels(self):
        # --root sets the resolution base so a path:line resolves against it.
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            (d / "sub").mkdir()
            (d / "sub" / "x.rs").write_text("a\nb\n")  # 2 lines
            md = self._md(d, "Ref `sub/x.rs:50`.\n")
            r = subprocess.run(
                [sys.executable, str(LINTER), "--root", str(d), str(md)],
                capture_output=True, text=True,
            )
            self.assertEqual(r.returncode, 1)
            self.assertIn(f"[{d.name}]", r.stderr)
            self.assertIn("stale path:line", r.stderr)


if __name__ == "__main__":
    unittest.main()
