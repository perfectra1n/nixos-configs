{ pkgs, fetchEnv ? "/run/secrets/rendered/kanbot-fetch.env" }:

# kanbot — our forge inbox + board + Claude Code session orchestrator. Its daemon runs in the
# cluster (homelab-ops); this box only runs `kanbot runner` (modules/kanbot-runner.nix), which
# hosts the sessions. Not in nixpkgs.
#
# ── Why a launcher that installs at FIRST USE, not a fetchurl derivation ──
# kanbot's Gitea sets REQUIRE_SIGNIN_VIEW: git, release downloads and the container registry
# all answer 401/sign-in without credentials. The credential and the Gitea's hostname live in
# sops (the hostname is kept out of this public repo, same as nix-cache.nix's substituter URL),
# and sops only renders them at ACTIVATION — after Nix has already built the system. A
# build-time fetch would therefore fail on the very switch that introduces the credential, and
# on every fresh host. So what's pinned here is the version + the release tarball's sha256, and
# the download happens when `kanbot` first runs: verified against that sha256, patchelf'ed
# (glibc + libgcc_s only, like sofka in modules/common.nix), then cached per version. Same
# bytes as a fixed-output derivation would give; `nix flake check` never touches the network.
#
# Bump (keep it in step with the cluster's chart — `kanbot runner` refuses a server of an
# incompatible version): set `version`, and `sha256` from that release's SHA256SUMS asset.
let
  version = "0.2.0";
  sha256 = "f5a75ce0c21fecc1da0248fd8a00c2158bfa7652be8873f3c2273f7b6679ceba";
  asset = "kanbot-${version}-x86_64-unknown-linux-gnu";

  interpreter = pkgs.stdenv.cc.bintools.dynamicLinker;
  rpath = pkgs.lib.makeLibraryPath [ pkgs.glibc pkgs.stdenv.cc.cc.lib ];
in
pkgs.writeShellApplication {
  name = "kanbot";
  runtimeInputs = with pkgs; [ coreutils curl gnutar gzip patchelf util-linux ];
  text = ''
    cache="''${XDG_CACHE_HOME:-$HOME/.cache}/kanbot-bin"
    bin="$cache/${version}/kanbot"

    install_release() {
      if [ ! -r ${fetchEnv} ]; then
        echo "kanbot: ${version} is not installed yet, and ${fetchEnv} is missing." >&2
        echo "kanbot: it is rendered by sops at activation (modules/kanbot-runner.nix)." >&2
        exit 1
      fi
      # Read the two values without exporting them: the exec'd kanbot (and every session it
      # starts) must not inherit the Gitea credential.
      local host auth tmp
      host=$(sed -n 's/^KANBOT_FETCH_HOST=//p' ${fetchEnv})
      auth=$(sed -n 's/^KANBOT_FETCH_AUTH=//p' ${fetchEnv})
      tmp=$(mktemp -d "$cache/.install.XXXXXX")
      # A failed download or checksum leaves nothing half-installed behind.
      trap 'rm -rf -- "$tmp"' EXIT
      curl -fsSL --retry 3 -H "Authorization: Basic $auth" \
        -o "$tmp/release.tar.gz" \
        "https://$host/perf3ct/kanbot/releases/download/${version}/${asset}.tar.gz"
      echo "${sha256}  $tmp/release.tar.gz" | sha256sum -c --quiet -
      tar -xzf "$tmp/release.tar.gz" -C "$tmp" "${asset}/kanbot"
      patchelf --set-interpreter ${interpreter} --set-rpath ${rpath} "$tmp/${asset}/kanbot"
      mkdir -p "$cache/${version}"
      mv -f "$tmp/${asset}/kanbot" "$bin.new"
      mv -f "$bin.new" "$bin"
      rm -r "$tmp"
      # Older versions are dead weight once this one is in place.
      find "$cache" -mindepth 1 -maxdepth 1 -type d ! -name '${version}' ! -name '.install.*' \
        -exec rm -r {} +
    }

    if [ ! -x "$bin" ]; then
      mkdir -p "$cache"
      # The runner service and an interactive `kanbot` may both start cold at once.
      exec 9>"$cache/.lock"
      flock 9
      [ -x "$bin" ] || install_release
      exec 9>&-
    fi
    exec "$bin" "$@"
  '';
  meta.description = "kanbot ${version}, fetched from its Gitea release on first use";
}
