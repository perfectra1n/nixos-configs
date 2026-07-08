#!/usr/bin/env python3
"""Render a PR-comment markdown summary of manifests/*.txt changes.

Reads a unified diff on stdin (git diff <base>...<head> -- 'manifests/*.txt'),
writes markdown to stdout. Pure text transform — no git, no network — so it's
testable locally:  git diff main -- manifests/ | ./scripts/manifest-pr-comment.py

Used by the manifest-comment job in .github/workflows/check.yaml to keep ONE
sticky comment per PR showing which packages changed version, per host (the
marker below is how the job finds its own comment to update).

Grouping: nix store names are <name>-<version> where the version starts at the
first dash-separated component beginning with a digit. A package present at
several versions at once (common for vendored deps) collapses to one row with
comma-joined version sets.
"""
import sys
import re
from collections import defaultdict

MARKER = "<!-- manifest-diff-comment -->"
MAX_ROWS = 200  # per host; keeps the comment under GitHub's 64 KiB body limit


def split_name_version(line: str):
    parts = line.split("-")
    for i in range(1, len(parts)):
        if parts[i][:1].isdigit():
            return "-".join(parts[:i]), "-".join(parts[i:])
    return line, ""


def main() -> None:
    hosts: dict[str, tuple[set, set]] = {}
    host = None
    for raw in sys.stdin.read().splitlines():
        m = re.match(r"^\+\+\+ b/manifests/(.+)\.txt$", raw)
        if m:
            host = m.group(1)
            hosts.setdefault(host, (set(), set()))
            continue
        if host is None or raw.startswith(("+++", "---", "@@")):
            continue
        if raw.startswith("-"):
            line = raw[1:].strip()
            if line and not line.startswith("#"):
                hosts[host][0].add(line)
        elif raw.startswith("+"):
            line = raw[1:].strip()
            if line and not line.startswith("#"):
                hosts[host][1].add(line)

    out = [MARKER, "## 📦 Package changes in this PR", ""]
    any_rows = False

    for host in sorted(hosts):
        removed, added = hosts[host]
        old, new = defaultdict(set), defaultdict(set)
        for line in removed - added:
            n, v = split_name_version(line)
            old[n].add(v)
        for line in added - removed:
            n, v = split_name_version(line)
            new[n].add(v)

        rows = []
        for name in sorted(set(old) | set(new)):
            before = ", ".join(sorted(old.get(name, ()))) or "—"
            after = ", ".join(sorted(new.get(name, ()))) or "—"
            if before != after:
                rows.append((name, before, after))
        if not rows:
            continue
        any_rows = True

        changed = sum(1 for _, b, a in rows if b != "—" and a != "—")
        added_n = sum(1 for _, b, _ in rows if b == "—")
        removed_n = sum(1 for _, _, a in rows if a == "—")
        out.append(
            f"<details><summary><b>{host}</b> — "
            f"{changed} changed, {added_n} added, {removed_n} removed</summary>"
        )
        out += ["", "| package | before | after |", "|---|---|---|"]
        for name, before, after in rows[:MAX_ROWS]:
            out.append(f"| `{name}` | {before} | {after} |")
        if len(rows) > MAX_ROWS:
            out.append(f"| …and {len(rows) - MAX_ROWS} more | | |")
        out += ["", "</details>", ""]

    if not any_rows:
        out.append("_No package-version changes in `manifests/` for this PR._")
    out += [
        "",
        "<sub>Generated from the committed `manifests/*.txt` diff. Same-version "
        "rebuilds don't appear here — see "
        "[docs/package-versioning.md](https://github.com/perfectra1n/nixos-configs/blob/main/docs/package-versioning.md).</sub>",
    ]
    print("\n".join(out))


if __name__ == "__main__":
    main()
