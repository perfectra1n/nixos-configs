# Hyprland (modules/hyprland.nix, graphical hosts) stops building the moment nixpkgs ships glaze
# 8.x: `glaze: 7.9.1 -> 8.0.0` landed 2026-08-03 (nixpkgs 6c89db1) and our root pin picked it up.
#
# The error does NOT look like a version conflict, which is the whole reason this comment exists.
# Hyprland's CMakeLists.txt:133 asks for `find_package(glaze 7...<8 QUIET)` — a version RANGE that
# excludes 8 — and QUIET means a miss is silent: it falls straight through to FetchContent, which
# tries to `git clone` glaze v7.2.0. There is no network and no git in the Nix sandbox, so the
# build dies with `error: could not find git for clone of glaze`. The range check three lines up
# is the actual cause; the git message is just the fallback path failing.
#
# This is nixpkgs commit 266bfbb ("hyprland: fix build by relaxing glaze dependency", 2026-08-04)
# applied verbatim — dropping the range rather than pinning glaze 7 back, because the constraint
# was conservative rather than a real incompatibility, and matching upstream means this file
# disappears cleanly instead of diverging. Carried here only because the fix merged to master
# ~16h AFTER the current nixos-unstable channel head (e72e4f2, 2026-08-04 07:31), so no amount of
# `nix flake update nixpkgs` reaches it yet.
#
# Cost of doing it this way: hyprland compiles locally instead of coming from the binary cache,
# since any deviation from the channel misses Hydra by construction. That shows up as an advisory
# entry in the cache-coverage diff (scripts/uncached-delta.py) — expected, not a regression. The
# alternative was pinning root nixpkgs back before the glaze bump, which buys a cache hit at the
# price of reverting every other package by two days.
#
# Remove this file once the channel advances past 266bfbb. It fails LOUDLY when that happens
# rather than silently going stale: `--replace-fail` errors if the `glaze 7...<8` string is gone.
{
  nixpkgs.overlays = [
    (final: prev: {
      hyprland = prev.hyprland.overrideAttrs (old: {
        postPatch = ''
          substituteInPlace CMakeLists.txt start/CMakeLists.txt hyprpm/CMakeLists.txt \
            --replace-fail "glaze 7...<8" "glaze"
        ''
        + old.postPatch;
      });
    })
  ];
}
