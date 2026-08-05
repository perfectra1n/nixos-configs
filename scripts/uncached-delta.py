#!/usr/bin/env python3
"""Report packages that lost binary-cache coverage between two `nix build --dry-run` plans.

Reads the stderr of two dry-runs (base commit and PR head), writes markdown to stdout.
Pure text transform — no nix, no network — so it's testable locally:

    nix build --dry-run '.#nixosConfigurations.desktop...toplevel' 2>&1 > /tmp/head.txt
    ./scripts/uncached-delta.py --base /tmp/base.txt --head /tmp/head.txt

WHY THIS EXISTS
    `nix build --dry-run` (the Build-plan step in check.yaml) proves a host EVALUATES.
    It never enters a builder, so a package that evaluates fine but fails to COMPILE
    sails through. That is not a hypothetical: nixpkgs shipped glaze 8.0.0 on
    2026-08-04 while Hyprland 0.56.1 pins `find_package(glaze 7...<8)`, so hyprland
    stopped building — and CI was green. py-spy vs python 3.14 (2026-07-18) was the
    same shape.

    The signal was already in CI's own output and thrown away: to decide "will be
    built" vs "will be fetched", nix queries the substituters, so anything Hydra
    failed lands in the built list by construction. Diffing that list against the
    base commit turns it into something readable — a bare head-side list is ~900
    entries, of which nearly all are this repo's own permanently-uncached
    derivations (FHS envs, wrappers, unfree packages).

    Advisory only. A new entry means "you will compile this locally", whose cause is
    either a genuine Hydra failure or Hydra merely lagging; the two are
    indistinguishable from here, and only the former is worth acting on.
"""
import argparse
import re
import sys

# Derivations nix emits per output or per wrapper. These must survive normalization as
# part of the identity, NOT be collapsed into the bare package name. `hyprland-0.56.0_
# fish-completions` is generated locally and therefore uncached on EVERY commit; folding
# it to `hyprland` would put `hyprland` in the base's uncached set permanently, so the
# real hyprland falling out of the cache would diff to nothing. That masking is exactly
# the failure this script exists to catch — see test_hyprland_masking below.
OUTPUT_SUFFIXES = (
    "_fish-completions",
    "-fhsenv-profile",
    "-fhsenv-rootfs",
    "-bwrap",
    "-init",
    "-dev",
    "-man",
    "-debug",
    "-doc",
    "-info",
    "-dist",
)

# A nix store name is <pname>-<version>; the version starts at the first dash-separated
# component beginning with a digit and runs to the end (`0.1-unstable-2026-06-30`,
# `1.5.3+date=2026-07-27_069ddab`). Stripping it makes names stable across a bump, so
# only genuine cache-coverage changes survive the diff instead of every version bump.
VERSION_RE = re.compile(r"-[0-9][^-]*(?:-[A-Za-z0-9.+_=]+)*$")

BUILT_HEADER = re.compile(r"^(?:these \d+ derivations|this derivation) will be built:")
FETCH_HEADER = re.compile(r"^(?:these \d+ paths|this path) will be fetched")
STORE_DRV = re.compile(r"^\s+/nix/store/[a-z0-9]{32}-(.+)\.drv$")


def normalize(name: str) -> str:
    """`hyprland-0.56.1-dev` -> `hyprland-dev`; `foo-1.2_fish-completions` -> `foo_fish-completions`."""
    suffix = ""
    stripping = True
    while stripping:
        stripping = False
        for s in OUTPUT_SUFFIXES:
            if name.endswith(s) and len(name) > len(s):
                name = name[: -len(s)]
                suffix = s + suffix
                stripping = True
                break
    return VERSION_RE.sub("", name) + suffix


def parse_plan(text: str) -> set[str]:
    """Collect normalized names from a dry-run's `will be built:` section.

    Raises ValueError when the text is not a dry-run plan at all (a failed eval), so the
    caller can skip the comparison rather than report the entire head as newly uncached.
    """
    seen_header = False
    in_built = False
    names: set[str] = set()
    for line in text.splitlines():
        if BUILT_HEADER.match(line):
            seen_header, in_built = True, True
            continue
        if FETCH_HEADER.match(line):
            seen_header, in_built = True, False
            continue
        if in_built:
            m = STORE_DRV.match(line)
            if m:
                names.add(normalize(m.group(1)))
            else:
                in_built = False
    if not seen_header:
        raise ValueError("no `will be built:`/`will be fetched` section — not a dry-run plan")
    return names


def display_names(normalized: set[str]) -> list[str]:
    """Collapse per-output entries for reporting: hyprland{,-dev,-man} -> one `hyprland`."""
    out = set()
    for n in normalized:
        for s in OUTPUT_SUFFIXES:
            if n.endswith(s) and len(n) > len(s):
                n = n[: -len(s)]
                break
        out.add(n)
    return sorted(out)


def render(host: str, delta: list[str]) -> str:
    head = f"### Cache coverage — `{host}`\n"
    if not delta:
        return head + "\nNo new from-source builds versus the base commit.\n"
    return head + (
        f"\n**{len(delta)}** package(s) will build from source that the base commit "
        f"fetched from the binary cache:\n\n"
        + ", ".join(f"`{n}`" for n in delta)
        + "\n\nA nixpkgs package here means you will compile it locally. Either Hydra "
        "failed to build it (worth acting on — check the package's CMake/test constraints "
        "against a freshly bumped dependency) or Hydra has not caught up yet (re-run later "
        "to tell them apart).\n"
    )


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--base", help="file holding the base commit's dry-run output")
    ap.add_argument("--head", help="file holding the PR head's dry-run output")
    ap.add_argument("--host", default="", help="host name, for the report heading")
    ap.add_argument("--names-out", help="write the comma-joined delta here when non-empty")
    ap.add_argument("--self-test", action="store_true", help="run unit tests and exit")
    args = ap.parse_args()

    if args.self_test:
        return self_test()
    if not (args.base and args.head):
        ap.error("--base and --head are required unless --self-test is given")

    try:
        base = parse_plan(open(args.base, encoding="utf-8", errors="replace").read())
        head = parse_plan(open(args.head, encoding="utf-8", errors="replace").read())
    except (OSError, ValueError) as e:
        print(f"### Cache coverage — `{args.host}`\n\nSkipped: {e}\n")
        return 0

    delta = display_names(head - base)
    print(render(args.host, delta))
    if delta and args.names_out:
        with open(args.names_out, "w", encoding="utf-8") as fh:
            fh.write(", ".join(delta))
    return 0


def self_test() -> int:
    failures = []

    def check(label, actual, expected):
        if actual != expected:
            failures.append(f"{label}: got {actual!r}, want {expected!r}")

    # Normalization: the version goes, the output suffix stays.
    check("plain", normalize("hyprland-0.56.1"), "hyprland")
    check("dev", normalize("hyprland-0.56.1-dev"), "hyprland-dev")
    check("completions", normalize("hyprland-0.56.1_fish-completions"), "hyprland_fish-completions")
    check("fhs", normalize("burpsuite-2026.7.2-fhsenv-rootfs"), "burpsuite-fhsenv-rootfs")
    check("unstable", normalize("grimblast-0.1-unstable-2026-06-30"), "grimblast")
    check("date+rev", normalize("dms-shell-1.5.3+date=2026-07-27_069ddab"), "dms-shell")
    check("py-dist", normalize("python3.12-httplib2-0.32.0-dist"), "python3.12-httplib2-dist")
    check("system", normalize("nixos-system-desktop-26.11.20260804.e72e4f2"), "nixos-system-desktop")
    check("no version", normalize("boost.pc"), "boost.pc")

    # A plan with no built section is still a valid plan (fully cached closure).
    check("fetch-only", parse_plan("these 3 paths will be fetched (1 MiB)\n  /nix/store/x\n"), set())

    # A failed eval must raise, not read as "everything is newly uncached".
    try:
        parse_plan("error: attribute 'foo' missing\n")
        failures.append("garbage input: expected ValueError")
    except ValueError:
        pass

    # REGRESSION (2026-08-04): base has only the locally-generated fish-completions
    # derivation for hyprland; head has that AND hyprland itself, because nixpkgs'
    # glaze 8.0.0 broke the build so Hydra never cached it. Collapsing outputs to the
    # bare pname makes this diff empty — the bug this whole check exists to catch.
    base_plan = (
        "these 2 derivations will be built:\n"
        "  /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-hyprland-0.56.0_fish-completions.drv\n"
        "  /nix/store/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-steam-1.0.0.87.drv\n"
        "these 9 paths will be fetched (1 MiB)\n"
    )
    head_plan = (
        "these 4 derivations will be built:\n"
        "  /nix/store/cccccccccccccccccccccccccccccccc-hyprland-0.56.1_fish-completions.drv\n"
        "  /nix/store/dddddddddddddddddddddddddddddddd-hyprland-0.56.1.drv\n"
        "  /nix/store/eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee-hyprland-0.56.1-man.drv\n"
        "  /nix/store/ffffffffffffffffffffffffffffffff-steam-1.0.0.87.drv\n"
        "these 9 paths will be fetched (1 MiB)\n"
    )
    delta = display_names(parse_plan(head_plan) - parse_plan(base_plan))
    check("hyprland masking regression", delta, ["hyprland"])

    if failures:
        print("uncached-delta self-test FAILED:", file=sys.stderr)
        for f in failures:
            print(f"  {f}", file=sys.stderr)
        return 1
    print("uncached-delta self-test OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
