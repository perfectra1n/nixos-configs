{ config, pkgs, lib, secrets, ... }:

# LAN attic binary cache — every host PULLS from it and PUSHES what it builds back.
#
# The cache URL is a private hostname and this repo is public with a gitleaks gate, so the
# URL lives in sops and reaches nix.conf only via a fragment rendered to /run/secrets at
# activation; the committed nix.conf carries one constant `!include` line. `!include` is
# Nix's OPTIONAL include: a missing file is silently skipped, so fresh installs and the
# nix.checkConfig sandbox stay green. Flip side: fragment contents are never build-checked
# — a typo in the fragment surfaces only as a runtime `nix` warning.
#
# Appending forms (extra-substituters / extra-trusted-public-keys) on purpose: chaotic
# emits a hard `substituters =` line on desktop — the overriding form would clobber it and
# force local kernel compiles. Query ORDER is priority-sorted, not config-ordered; the LAN
# cache goes first via the `?priority=10` param inside the secret URL (cache.nixos.org is
# 40, and the server also advertises Priority: 10 in nix-cache-info).
#
# Off-LAN (laptop): connect-timeout=5 bounds the first contact, then Nix disables the
# substituter for the invocation; fallback=true turns a broken NAR download into a local
# build instead of an abort.
#
# Push: `attic watch-store` uploads every NEW store path; it skips paths signed by the
# cache's upstream keys (cache.nixos.org-1 + chaotic's, registered server-side) and asks
# the server what's missing before uploading — no loops, no nixpkgs re-uploads. It only
# sees paths created while RUNNING; seed once after activation with
#   sudo XDG_CONFIG_HOME=/run/secrets/rendered/attic-xdg attic push main /run/current-system
# Standing caveat: anything that lands in /nix/store gets pushed — one more reason no
# secret may ever enter the store (this repo's sops model already guarantees that).
#
# EVAL GATE (same as git-credentials.nix): declare secrets/templates only once secrets.yaml
# actually holds the keys, so a fresh checkout evaluates green and a host that rebuilds
# before `mise run secrets:pull` doesn't brick sops activation.
let
  declareSecret = secrets.has "nix/cache_substituter_url"
    && secrets.has "nix/attic_endpoint"
    && secrets.has "nix/attic_push_token";

  ph = name: config.sops.placeholder.${name};

  # From bootstrap: `attic cache info main`. Signature VERIFICATION key — public by
  # definition, safe to commit.
  cachePublicKey = "main:egPSFc54+IvINBwTbrn6VX8xxksMB/II88IR+AmfnSY=";

  # attic has no --config flag and no token env var: it reads exactly
  # $XDG_CONFIG_HOME/attic/config.toml, so the rendered file must sit in that shape.
  xdgDir = "/run/secrets/rendered/attic-xdg";
  atticConfig = "${xdgDir}/attic/config.toml";
in
lib.mkIf declareSecret {
  sops.secrets = {
    "nix/cache_substituter_url" = { };
    "nix/attic_endpoint" = { };
    "nix/attic_push_token" = { };
  };

  # ── pull: nix.conf fragment ──
  # 0444, not the 0400 default: non-root nix tools parse /etc/nix/nix.conf too, and Nix
  # SILENTLY skips an unreadable include — 0400 would leave user-side `nix config show`
  # disagreeing with the root daemon. The URL is "secret" only in the sense of
  # not-committable-to-a-public-repo; every local user may see it. /run/secrets dirs are
  # 0751 (traversable), so the exact world-readable path stays reachable.
  sops.templates."nix-substituters.conf" = {
    mode = "0444";
    # The !include line in nix.conf never changes, so NixOS's own nix.conf restart
    # trigger can't see a rotated URL — restart the daemon when the FRAGMENT changes.
    restartUnits = [ "nix-daemon.service" ];
    content = ''
      extra-substituters = ${ph "nix/cache_substituter_url"}
      extra-trusted-public-keys = ${cachePublicKey}
      connect-timeout = 5
      fallback = true
    '';
  };

  nix.extraOptions = "!include /run/secrets/rendered/nix-substituters.conf";

  # ── push: attic client config + watch-store service ──
  # Token inline via placeholder rather than a token-file: both would sit root-0400 on
  # the same tmpfs — zero security delta for one more moving part. Template NAMES must
  # not contain slashes (the default `file = writeText <name>` would be an invalid drv
  # name); the nested location comes from `path`, which sops-install-secrets MkdirAll's.
  sops.templates."attic-config.toml" = {
    path = atticConfig;
    mode = "0400"; # holds the push token; the service runs as root
    restartUnits = [ "attic-watch-store.service" ];
    content = ''
      default-server = "main"

      [servers.main]
      endpoint = "${ph "nix/attic_endpoint"}"
      token = "${ph "nix/attic_push_token"}"
    '';
  };

  # One-off pushes/cache admin (root only, wrapped in the XDG env):
  #   sudo XDG_CONFIG_HOME=/run/secrets/rendered/attic-xdg attic push main <path>
  environment.systemPackages = [ pkgs.attic-client ];

  systemd.services.attic-watch-store = {
    description = "Push new nix store paths to the LAN attic cache";
    wants = [ "network-online.target" ];
    after = [ "network-online.target" "nix-daemon.service" ];
    wantedBy = [ "multi-user.target" ];
    # Secret not pulled yet -> unit SKIPPED (condition unmet), not failed.
    unitConfig.ConditionPathExists = atticConfig;
    environment.XDG_CONFIG_HOME = xdgDir;
    serviceConfig = {
      # Root on purpose: reads the root-0400 config, and as root talks to the local
      # store directly. It only ever READS the store.
      ExecStart = "${pkgs.attic-client}/bin/attic watch-store main";
      Restart = "on-failure";
      RestartSec = "30s";
    };
    # Don't hammer a dead endpoint / bad token forever: a few quick retries, then stay
    # stopped until the next activation or manual start. The off-LAN laptop lives here
    # happily — the unit fails out and the machine keeps building via cache.nixos.org.
    startLimitIntervalSec = 600;
    startLimitBurst = 5;
  };
}
