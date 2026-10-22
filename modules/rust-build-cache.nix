{ config, pkgs, lib, username, ... }:

# Machine-wide Rust build sharing for every repo the user builds (mise's cargo, rust-analyzer,
# agent worktrees). Two parts, each picked over a tempting alternative:
#
# - sccache as cargo's rustc-wrapper — ONE compiled-crate cache across all projects, so
#   serde/tokio/syn compile once machine-wide, not once per repo. NOT a shared
#   `build.build-dir`: that dedups disk too, but on stable cargo it holds a single lock for the
#   whole build, so every cargo/rust-analyzer run on the box queues behind every other one
#   (fine-grain locking is nightly-only and still deadlocks — rust-lang/cargo#17508).
#   Incremental stays ON: sccache can't cache incremental crates, but those are only your own
#   workspace members in debug builds; dependencies never build incrementally, and they're the
#   part worth sharing.
# - NO linker override (mold was tried and dropped): since Rust 1.90 this target already links
#   with the bundled rust-lld, and rustc appends its own `-fuse-ld=lld` after any linker shim's
#   flag. Getting mold back needs the `-Clinker-features=-lld` rustflag, and a global
#   target.<triple>.rustflags silently REPLACES each project's own build.rustflags (e.g.
#   `--cfg tokio_unstable`) — too sharp an edge for mold's small win over lld.
# - a weekly `cargo clean-all` — sccache caps its own dir (SCCACHE_CACHE_SIZE, LRU), but each
#   repo's target/ still grows until something deletes it.
# - a scratch root for one-off CARGO_TARGET_DIRs ($CARGO_SCRATCH_TARGETS/<name>). Agent sessions
#   isolate builds that way, and cargo-clean-all can't see those dirs (it finds projects, not
#   bare target dirs) — ~630G of them once piled up under ~/.cache on the root disk unnoticed.
let
  # $CARGO_HOME/config.toml — the lowest-precedence config file, so any repo's own
  # .cargo/config.toml (or a RUSTC_WRAPPER env, e.g. a devShell) still overrides it.
  cargoConfig = (pkgs.formats.toml { }).generate "cargo-config.toml" {
    build.rustc-wrapper = lib.getExe pkgs.sccache;
  };

  home = config.users.users.${username}.home;
  scratchTargets = config.environment.sessionVariables.CARGO_SCRATCH_TARGETS;

  # Whole-dir granularity on purpose: deleting only the old files inside a live target dir
  # would leave fingerprints pointing at missing artifacts. ~/.cache is swept too, for strays
  # pointed there by hand — matched by cargo's per-profile .fingerprint dir so uv/pip caches
  # (which also carry CACHEDIR.TAG) are never candidates.
  pruneScratchTargets = pkgs.writeShellApplication {
    name = "prune-scratch-targets";
    runtimeInputs = [ pkgs.coreutils pkgs.findutils ];
    text = ''
      prune() {
        [ -d "$1" ] || return 0
        if [ -z "$(find "$1" -mtime -30 -print -quit)" ]; then
          echo "removing $1 ($(du -sh "$1" | cut -f1))"
          rm -rf --one-file-system "$1"
        fi
      }
      for d in ${lib.escapeShellArg scratchTargets}/*/; do prune "$d"; done
      for d in ${home}/.cache/*/ ${home}/.cache/*/*/; do
        if [ -d "$d/debug/.fingerprint" ] || [ -d "$d/release/.fingerprint" ]; then prune "$d"; fi
      done
    '';
  };
in
{
  # NixOS-level (not home.sessionVariables) so fish sees it — same reason as PKG_CONFIG_PATH in
  # modules/common.nix. A host with a roomier disk overrides these (see hosts/desktop).
  environment.sessionVariables.SCCACHE_CACHE_SIZE = lib.mkDefault "30G";
  environment.sessionVariables.CARGO_SCRATCH_TARGETS = lib.mkDefault "${home}/.cache/cargo-targets";

  home-manager.users.${username} = {
    # Flake-owned (not chezmoi) because it embeds store paths; ~/.cargo is already in
    # dotfiles/.chezmoiignore, so the two can't collide.
    home.file.".cargo/config.toml".source = cargoConfig;

    home.packages = [ pkgs.sccache ]; # `sccache --show-stats` / `--stop-server`

    # Only projects not built in 30 days — anything active keeps its target/, and a cleaned one
    # rebuilds mostly from sccache. `cargo clean-all -i` stays the manual, pick-by-hand tool.
    # config.system.path is the systemPackages env, where modules/common.nix installs it.
    systemd.user.services.cargo-clean-all = {
      Unit.Description = "Delete Rust target dirs (~/repos projects + scratch targets) untouched for 30 days";
      Service = {
        Type = "oneshot";
        ExecStart = [
          "${config.system.path}/bin/cargo-clean-all --yes --keep-days 30 %h/repos"
          (lib.getExe pruneScratchTargets)
        ];
        Nice = 19;
        IOSchedulingClass = "idle";
      };
    };
    systemd.user.timers.cargo-clean-all = {
      Timer = {
        OnCalendar = "weekly";
        Persistent = true; # catch up after the box was off at the scheduled time
      };
      Install.WantedBy = [ "timers.target" ];
    };
  };
}
