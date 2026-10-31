{ config, lib, username, secrets, ... }:

# Renders the hosts.toml of perfectra1n's forge CLIs — gea (Gitea) and fjo (Forgejo) — from sops,
# so every box gets the same logins without a `<cli> auth login` per host and without a
# plaintext token in a dotfile. Both CLIs share one hosts.toml schema, hence one module.
#
# WHY templates (not chezmoi .age files): the tokens are the SAME ones git-credentials.nix
# already declares — one Bitwarden item per forge feeds git, docker AND the CLIs, so a rotation
# is one `mise run secrets:pull`, not four. The hostnames are placeholders too (private domains
# must not appear in this public repo or the nix store).
#
# TWO DELIVERY MODES, because the two files are owned differently:
#   - gea: READ-ONLY. ~/.config/gea/hosts.toml is a chezmoi symlink_ to the render (gated in
#     .chezmoiignore until it exists). `gea auth login`/`switch` can't write it back — add a host
#     via its Bitwarden item + a block below.
#   - fjo: SEED, then fjo owns it. fjo writes hosts.toml itself — web sessions (`fjo web`,
#     `fjo project`, incl. a web-only second account) and OAuth refreshes — none of which belong
#     in sops. So the render is copied in only when the file is missing or holds no token at all;
#     after that a sops rotation does NOT propagate: `rm ~/.config/fjo/hosts.toml` and switch to
#     re-seed (re-run `fjo auth login --with-password` for any web session afterwards).
#
# COUPLING: reuses git/* placeholders declared in git-credentials.nix, so it must ride alongside
# that module (same as docker-credentials.nix). Same eval gate, too.
let
  declareSecret = secrets.has "git/github_token";

  ph = name: config.sops.placeholder.${name};

  # `user` is the forge LOGIN the CLI reports in `auth status`, not the Bitwarden username.
  hostBlock = host: user: token: ''
    [[hosts]]
    name = "${ph host}"
    url = "https://${ph host}"
    active_login = "${user}"
    credential_store = "file"

    [[hosts.logins]]
    user = "${user}"
    token = "${ph token}"
    kind = "pat"
  '';

  hostsToml = active: blocks: lib.concatStringsSep "\n" ([ ''active = "${ph active}"'' ] ++ blocks);

  fjoRender = "/run/secrets/rendered/fjo-hosts.toml";
in
lib.mkIf declareSecret {
  sops.templates."gea-hosts" = {
    owner = username;
    mode = "0400";
    path = "/run/secrets/rendered/gea-hosts.toml"; # pinned so the chezmoi symlink is stable
    content = hostsToml "git/main_gitea_host" [
      (hostBlock "git/main_gitea_host" "perf3ct" "git/main_gitea_token")
      (hostBlock "git/atvik_gitea_host" "perfectra1n" "git/atvik_gitea_token")
      (hostBlock "git/duck_gitea_host" "perfectra1n" "git/duck_gitea_token")
    ];
  };

  # Each Forgejo is listed under BOTH its hostnames: the CLI resolves the host from the git
  # remote, and remotes use either name.
  sops.templates."fjo-hosts" = {
    owner = username;
    mode = "0400";
    path = fjoRender;
    content = hostsToml "git/duck_forgejo_host" [
      (hostBlock "git/forgejo_host" "perfectra1n" "git/forgejo_token")
      (hostBlock "git/forgejo_alt_host" "perfectra1n" "git/forgejo_token")
      (hostBlock "git/duck_forgejo_host" "perfectra1n" "git/duck_forgejo_token")
      (hostBlock "git/duck_forgejo_alt_host" "perfectra1n" "git/duck_forgejo_token")
      # The Atvik Gitea answers enough of fjo's API that fjo is used there too.
      (hostBlock "git/atvik_gitea_host" "perfectra1n" "git/atvik_gitea_token")
    ];
  };

  # A home-manager activation step (runs as the user, after sops rendered at system activation)
  # rather than a tmpfiles `C` line: `C` would copy the render's 0400 mode, and could create a
  # missing ~/.config as root.
  home-manager.users.${username} = { lib, ... }: {
    home.activation.seedFjoHosts = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      dest="$HOME/.config/fjo/hosts.toml"
      if [ -r ${fjoRender} ] && ! grep -qs '^token = ' "$dest"; then
        run install -D -m 0600 ${fjoRender} "$dest"
      fi
    '';
  };
}
