#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Supacode custom status page — prototype contract (snapshot mode, v0).

Every project defines its own page: Supacode does not prescribe the content,
it just renders whatever HTML this script emits for the repository it lives
in. This instance is supacode's own page — dev-environment status for
hacking on supacode itself.

Detection:  Supacode looks for `customcode.py` at the repository root.
Invocation: `uv run --script customcode.py` with the working directory set to
            the worktree root. uv resolves the inline metadata above, so the
            script's only host dependency is uv itself.
Output:     a complete, self-contained HTML document on stdout (inline CSS,
            no external resources) and exit code 0. A nonzero exit or empty
            output means "show an error state", not "render this".
Refresh:    Supacode re-runs the script on worktree selection and on its
            debounced files-changed events. Finish fast (well under 2s).
Sizing:     rendered in a right-hand sidebar column, roughly the same width
            as the left sidebar (~220-320pt) — design narrow.
Theme:      honor `prefers-color-scheme` for light/dark.
"""

from __future__ import annotations

import html
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path


@dataclass
class Row:
  """One status line: a state dot, a label, and an optional detail value."""

  state: str  # "good" | "warn" | "bad" | "none"
  label: str
  detail: str = ""


class Shell:
  @staticmethod
  def run(*args: str) -> str | None:
    try:
      result = subprocess.run(list(args), capture_output=True, text=True, timeout=5, check=False)
    except (OSError, subprocess.TimeoutExpired):
      return None
    return result.stdout.strip() if result.returncode == 0 else None


class SupacodeStatus:
  """Collects the dev-environment facts this project's page reports."""

  @staticmethod
  def branch() -> str:
    branch = Shell.run("git", "rev-parse", "--abbrev-ref", "HEAD")
    if branch is None:
      return "unknown"
    if branch == "HEAD":
      short = Shell.run("git", "rev-parse", "--short", "HEAD")
      return f"detached @ {short}" if short else "detached HEAD"
    return branch

  @staticmethod
  def head_subject() -> str | None:
    return Shell.run("git", "log", "-1", "--pretty=%s")

  @staticmethod
  def version_tag() -> str | None:
    return Shell.run("git", "describe", "--tags", "--abbrev=0")

  @staticmethod
  def ghostty_framework() -> Row:
    framework = Path("Frameworks/GhosttyKit.xcframework")
    if not framework.is_dir():
      return Row("bad", "GhosttyKit", "not built")
    age_days = max(0, int((time.time() - framework.stat().st_mtime) // 86400))
    detail = "built today" if age_days == 0 else f"built {age_days}d ago"
    return Row("good", "GhosttyKit", detail)

  @staticmethod
  def submodules() -> Row:
    listing = Shell.run("git", "config", "--file", ".gitmodules", "--get-regexp", "path")
    if listing is None:
      return Row("warn", "Submodules", "none declared")
    paths = [line.split(" ", 1)[1] for line in listing.splitlines() if " " in line]
    missing = [Path(p).name for p in paths if not (Path(p) / ".git").exists()]
    if missing:
      return Row("bad", "Submodules", f"missing: {', '.join(missing)}")
    return Row("good", "Submodules", f"{len(paths)} initialized")

  @staticmethod
  def patches() -> Row:
    count = len(list(Path("patches").glob("*.patch"))) if Path("patches").is_dir() else 0
    return Row("none", "Ghostty patches", f"{count} carried")

  @staticmethod
  def working_tree() -> Row:
    status = Shell.run("git", "status", "--porcelain")
    if status is None:
      return Row("warn", "Working tree", "unavailable")
    changes = len(status.splitlines())
    if changes == 0:
      return Row("good", "Working tree", "clean")
    return Row("warn", "Working tree", f"{changes} pending change{'s' if changes != 1 else ''}")

  @classmethod
  def rows(cls) -> list[Row]:
    rows = [cls.working_tree(), cls.ghostty_framework(), cls.submodules(), cls.patches()]
    if tag := cls.version_tag():
      rows.append(Row("none", "Latest release", tag))
    return rows


class Page:
  CSS = """
    :root {
      color-scheme: light dark;
      --surface: #fcfcfb; --ink: #0b0b0b; --ink-2: #52514e; --ink-muted: #898781;
      --hairline: #e1e0d9; --ring: rgba(11, 11, 11, 0.10);
      --good: #0ca30c; --warn: #fab219; --bad: #d03b3b;
    }
    @media (prefers-color-scheme: dark) {
      :root {
        --surface: #1a1a19; --ink: #ffffff; --ink-2: #c3c2b7;
        --hairline: #2c2c2a; --ring: rgba(255, 255, 255, 0.10);
      }
    }
    * { margin: 0; padding: 0; box-sizing: border-box; }
    body {
      background: var(--surface); color: var(--ink);
      font: 12px/1.45 system-ui, -apple-system, "Segoe UI", sans-serif;
      padding: 12px; overflow-x: hidden;
    }
    .title { font-size: 13px; font-weight: 600; }
    .branch {
      font-family: ui-monospace, monospace; font-size: 11px; color: var(--ink-2);
      margin-top: 2px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis;
    }
    .head { color: var(--ink-muted); font-size: 11px; margin-top: 2px;
      white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
    ul { list-style: none; margin-top: 10px; }
    li {
      display: flex; align-items: baseline; gap: 7px; padding: 5px 0;
      border-top: 1px solid var(--hairline); min-width: 0;
    }
    li:first-child { border-top: none; }
    .dot { width: 7px; height: 7px; border-radius: 50%; flex: none; align-self: center; }
    .dot.good { background: var(--good); }
    .dot.warn { background: var(--warn); box-shadow: 0 0 0 1px var(--ring); }
    .dot.bad  { background: var(--bad); }
    .dot.none { background: transparent; box-shadow: inset 0 0 0 1px var(--ink-muted); }
    .label { flex: none; }
    .detail {
      flex: 1; text-align: right; color: var(--ink-2);
      white-space: nowrap; overflow: hidden; text-overflow: ellipsis;
    }
    footer { margin-top: 12px; font-size: 10px; color: var(--ink-muted); }
  """

  @classmethod
  def render(cls, project: str, branch: str, head: str | None, rows: list[Row]) -> str:
    e = html.escape
    items = "".join(
      f'<li><span class="dot {row.state}"></span><span class="label">{e(row.label)}</span>'
      f'<span class="detail">{e(row.detail)}</span></li>'
      for row in rows
    )
    head_line = f'<div class="head">{e(head)}</div>' if head else ""
    stamp = time.strftime("%H:%M:%S")
    return (
      "<!doctype html>\n"
      '<html lang="en"><head><meta charset="utf-8">'
      f"<title>{e(project)} status</title>"
      f"<style>{cls.CSS}</style></head><body>"
      f'<div class="title">{e(project)}</div>'
      f'<div class="branch">{e(branch)}</div>'
      f"{head_line}"
      f"<ul>{items}</ul>"
      f"<footer>customcode.py &middot; updated {stamp}</footer>"
      "</body></html>"
    )


def main() -> int:
  page = Page.render(
    project=Path.cwd().name,
    branch=SupacodeStatus.branch(),
    head=SupacodeStatus.head_subject(),
    rows=SupacodeStatus.rows(),
  )
  sys.stdout.write(page)
  return 0


if __name__ == "__main__":
  sys.exit(main())
