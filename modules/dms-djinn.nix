{ config, lib, username, secrets, ... }:

# Djinn chat drawer for DankMaterialShell: a composite DMS plugin (daemon + bar pill) showing the
# conversation with the Djinn agent in a side drawer. It lives in plugins/dms/djinn of duck's
# Djinn repo — same plugin as duck's nix-config, delivered differently on purpose.
#
# WHY NOT A FLAKE INPUT (duck's way): Djinn is a PRIVATE repo, and this flake is public and must
# evaluate on a fresh checkout. A flake input is fetched at EVAL, so it would need forge
# credentials in CI and on every `nix flake check`, and put the forge hostname in flake.nix.
# Instead a home-manager activation step fetches it at SWITCH time, as the user, through the
# sops-rendered ~/.git-credentials (modules/git-credentials.nix). Eval only ever sees the pin
# below; the forge host is read at runtime from a render, never baked into the store.
#
# INTEGRITY: the tag is fetched, then refused unless it peels to `rev` — git's content addressing
# makes that as strong as a flake.lock pin. Bump by hand: set tag + rev (`git ls-remote <repo>
# refs/tags/<tag>^{}`, or the plain ref for a lightweight tag) and switch.
#
# INSTALL PATH: ~/.config/DankMaterialShell/plugins/djinn, a symlink to a per-rev copy under
# ~/.local/share/dms-djinn — DMS's own user-plugin dir (where its plugin browser installs too),
# not /etc/xdg/quickshell/dms-plugins, which the registry module owns as one store path. The
# per-switch qmlcache wipe in modules/hyprland.nix keeps a bump from running stale QML; restart
# DMS (or `dms ipc call plugins reload djinn`) to pick one up in a running session.
#
# SERVER URL: the plugin reads it only from plugin_settings.json, which on desktop is a chezmoi
# snapshot of a PUBLIC repo — so the chezmoi source is a .tmpl that pulls it from the render
# below (chezmoi refuses to silently de-template on `add`, `re-add` skips templates, and the
# leak gate backstops both). Other hosts: set it once in DMS Settings → Plugins → Djinn.
# Sign-in tokens land in ~/.local/state/DankMaterialShell, which nothing here manages.
let
  djinn = {
    repo = "aaldebs99/Djinn"; # owner/repo only — the host is a secret
    tag = "0.3.26";
    rev = "935406769d2916c605928950ff76960543117d9d";
  };

  # COUPLING: reuses the git/duck_forgejo_* placeholders git-credentials.nix declares, so it rides
  # the same gate (as forge-cli.nix does). Both hostnames are tried, in order: the creds have been
  # refused on one name and accepted on the other of the SAME Forgejo, and which is which drifts.
  declareFetch = secrets.has "git/github_token";
  declareUrl = secrets.has "djinn/server_host";

  ph = name: config.sops.placeholder.${name};
  hostsRender = "/run/secrets/rendered/djinn-forge-hosts";
in
lib.mkMerge [
  (lib.mkIf declareUrl {
    sops.secrets."djinn/server_host" = { };
    sops.templates."djinn-server-url" = {
      owner = username;
      mode = "0400";
      path = "/run/secrets/rendered/djinn-server-url"; # pinned: chezmoi's plugin_settings.json.tmpl reads it
      content = "https://${ph "djinn/server_host"}";
    };
  })

  (lib.mkIf declareFetch {
    sops.templates."djinn-forge-hosts" = {
      owner = username;
      mode = "0400";
      path = hostsRender;
      content = ''
        ${ph "git/duck_forgejo_host"}
        ${ph "git/duck_forgejo_alt_host"}
      '';
    };

    # Fail-soft like ensureRepos (home/common.nix): offline, no creds yet, or a moved tag only
    # warns, and the fetch retries on the next switch. A rev already on disk costs no network.
    home-manager.users.${username} = { lib, pkgs, ... }: {
      home.activation.djinnPlugin = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        store="$HOME/.local/share/dms-djinn"
        dest="$store/${djinn.rev}"
        link="$HOME/.config/DankMaterialShell/plugins/djinn"

        # HM runs activation under `set -eu -o pipefail`, and one failed command would abort EVERY
        # later HM step — so each step returns explicitly and the call site swallows the status.
        djinn_fetch() {
          local git=${pkgs.git}/bin/git tmp host got
          tmp=$(mktemp -d) || return 1
          while read -r host; do
            [ -n "$host" ] || continue
            rm -rf "$tmp/repo" "$tmp/out"
            $git init -q "$tmp/repo" || break
            GIT_TERMINAL_PROMPT=0 $git -C "$tmp/repo" fetch -q --depth 1 \
              "https://$host/${djinn.repo}" "refs/tags/${djinn.tag}" || continue
            got=$($git -C "$tmp/repo" rev-parse 'FETCH_HEAD^{commit}') || break
            if [ "$got" != "${djinn.rev}" ]; then
              echo "djinnPlugin: tag ${djinn.tag} is $got, pinned ${djinn.rev} — refusing (moved tag?)"
              break
            fi
            mkdir -p "$tmp/out" "$store" || break
            $git -C "$tmp/repo" archive FETCH_HEAD plugins/dms/djinn \
              | ${pkgs.gnutar}/bin/tar -x -C "$tmp/out" || break
            run mv "$tmp/out/plugins/dms/djinn" "$dest" || break
            break
          done < ${hostsRender}
          rm -rf "$tmp"
          [ -e "$dest/plugin.json" ]
        }

        if [ ! -e "$dest/plugin.json" ] && [ -r ${hostsRender} ]; then
          djinn_fetch \
            || echo "djinnPlugin: could not fetch Djinn ${djinn.tag} (offline? auth?) — will retry next switch"
        fi

        if [ -e "$dest/plugin.json" ]; then
          if [ -e "$link" ] && [ ! -L "$link" ]; then
            echo "djinnPlugin: $link is a real directory (manual install?) — leaving it; remove it to let Nix manage Djinn"
          else
            run mkdir -p "$(dirname "$link")" || true
            run ln -sfn "$dest" "$link" || true
            # Drop superseded revs; only the pinned one is ever linked.
            for old in "$store"/*; do
              [ "$old" = "$dest" ] || run rm -rf "$old" || true
            done
          fi
        fi
      '';
    };
  })
]
