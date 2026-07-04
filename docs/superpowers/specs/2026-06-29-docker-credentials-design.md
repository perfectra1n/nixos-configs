# sops-managed Docker registry auth

**Date:** 2026-06-29
**Status:** Design — approved pending implementation

## Goal

Manage `~/.docker/config.json` registry authentication declaratively via sops, mirroring
the existing `modules/git-credentials.nix` pattern, so `docker pull/push` to private
registries works non-interactively without a plaintext token ever living on disk.

Target registries: **main Gitea**, **duck Gitea**, **ghcr.io**,
and **Docker Hub** (`https://index.docker.io/v1/`). AWS ECR is deliberately excluded — its
tokens are short-lived (`aws ecr get-login-password`, ~12h) and stay with the existing
`aws`-login alias, not static sops.

> **Docker Hub registry key gotcha:** Docker stores the Hub credential under the magic key
> `https://index.docker.io/v1/`, not `hub.docker.com` or `docker.io`. The `auths` entry must
> use that exact string or the auth silently won't apply.

## Background — how git does it, and why Docker differs

`modules/git-credentials.nix` declares `git/*` token + host secrets in sops and uses
`sops.templates` to interpolate them into `/run/secrets/rendered/git-credentials`
(tmpfs, `0400`, owner=user, never on persistent disk, never in the nix store). The
chezmoi-owned gitconfig points git at that file with one line
(`credential.helper = store --file /run/secrets/rendered/git-credentials`).

Docker has two wrinkles git does not:

1. **base64 auth field.** `~/.docker/config.json` stores
   `auths.<registry>.auth = base64("username:token")`. We cannot base64-encode at Nix
   eval time, because a sops *placeholder* is not the real secret value until sops does
   textual substitution at **activation**. base64-ing a placeholder then asking sops to
   find it inside the encoded string does not work.
   **Resolution:** store the already-base64'd `username:token` blob as the sops secret
   value. It is no more sensitive than the raw token.

2. **Docker writes to its config dir.** Unlike git (which only *reads* the helper file),
   `docker build` (buildx) writes state under `$DOCKER_CONFIG/`. So we must NOT repoint
   `DOCKER_CONFIG` at the read-only `/run/secrets` dir — that would break `docker build`
   and the `makedocker` fish function. Instead `~/.docker/` stays a real writable dir and
   only `config.json` becomes a pointer (symlink) to the rendered secret.

## Design

### New secrets — `secrets/secrets.yaml`, driven by the manifest

New `docker:` top-level key. Each value is the pre-base64'd `username:token` blob:

```yaml
docker:
    main_gitea_auth: <base64("perf3ct:<main gitea token>")>
    duck_gitea_auth: <base64("perf3ct:<duck gitea token>")>
    ghcr_auth:       <base64("perfectra1n:<github token>")>
    dockerhub_auth:  <base64("<hub username>:<hub access token>")>
```

These are **not hand-set** — they are derived from tokens the manifest already manages, so
they must regenerate in lockstep when a token rotates. Two changes to the secrets machinery
make that automatic (see `scripts/secrets-sync.sh` and `mise.toml`):

1. **New `basicauth` manifest kind.** Existing kinds (`field`, `host`) emit raw values;
   `basicauth` emits `base64("<user>:<field value>")` — exactly docker's `auths.<reg>.auth`.
   Selector is `<user>:<field name>`, split on the first colon. Three manifest rows point at
   the **same Bitwarden items + token fields** the `git/*` rows use (no new vault entries):
   ```
   docker/main_gitea_auth | Main Gitea                 | basicauth | perf3ct:Personal Access Token 1
   docker/duck_gitea_auth | Duck Gitea                 | basicauth | perf3ct:API Key (Main)
   docker/ghcr_auth       | Github                     | basicauth | perfectra1n:Updated Super Token (API key)
   docker/dockerhub_auth  | Dockerhub / hub.docker.com | basicauth | @:Access Token
   ```
   So a `mise run secrets:pull` after a token rotation refreshes both the git credential and
   the docker blob in one pass — no stale-blob drift. The Docker Hub row uses `<user>=@`, which
   resolves the username from the Bitwarden item (login *Username*, else a custom `User Name`/
   `Username` field) rather than hardcoding it.

2. **`apply` auto-pulls newly-added manifest keys.** `apply`'s existing preflight only runs
   `secrets:init` when `secrets.yaml` is still the placeholder, so new rows on an
   already-initialized box would never get pulled (and the gated module would stay silently
   inert). A cheap **local** check (sops keeps keys in plaintext) compares manifest paths to
   the keys present in `secrets.yaml`; if any are missing it runs `secrets:pull`. Bitwarden is
   unlocked only when something is genuinely absent, so day-to-day applies never prompt.

### `modules/docker-credentials.nix` (system module)

A near-exact structural copy of `modules/git-credentials.nix`:

- **Eval gate** identical to git-credentials: read `../secrets/secrets.yaml`, require it is
  not the placeholder stub (`secretsReady`) and that the docker keys are present
  (`lib.hasInfix "main_gitea_auth"`). The module is fully inert until secrets are
  populated, so a fresh checkout stays CI-green.
- **Declares** `docker/main_gitea_auth`, `docker/duck_gitea_auth`, `docker/ghcr_auth`.
- **Reuses** the existing `git/main_gitea_host` and `git/duck_gitea_host` placeholders for
  the two Gitea registry keys (keeps the duck host encrypted, consistent with
  git-credentials). `ghcr.io` is a literal (already public).
- `sops.templates."docker-config"` renders, with `owner = username`, `mode = "0400"`,
  `path = "/run/secrets/rendered/docker-config.json"`:

  ```json
  {
    "auths": {
      "${ph "git/main_gitea_host"}": { "auth": "${ph "docker/main_gitea_auth"}" },
      "${ph "git/duck_gitea_host"}": { "auth": "${ph "docker/duck_gitea_auth"}" },
      "ghcr.io": { "auth": "${ph "docker/ghcr_auth"}" },
      "https://index.docker.io/v1/": { "auth": "${ph "docker/dockerhub_auth"}" }
    }
  }
  ```

- **Coupling note** in the header: this module reuses `git/*_host` placeholders, so it must
  be loaded alongside `git-credentials.nix`. Both target desktop + laptop, so this holds.

### `home/docker.nix` (home-manager module)

The pointer. Gated on the same secrets-present check (via `builtins.readFile
../secrets/secrets.yaml`) so a real machine that has not yet run `secrets:pull` does not
get a dangling symlink:

```nix
home.file.".docker/config.json".source =
  config.lib.file.mkOutOfStoreSymlink "/run/secrets/rendered/docker-config.json";
```

`~/.docker/` itself stays a real writable directory (home-manager only manages the one
named file as a symlink), so buildx state under `~/.docker/buildx/` and `docker build`
keep working. No chezmoi collision: `.docker` is already in `dotfiles/.chezmoiignore`.

### Wiring — `flake.nix`

Add to **desktop** and **laptop** only (matching git-credentials):

- `extraModules`: `./modules/docker-credentials.nix`
- `homeModules`: `./home/docker.nix`

Server and wsl are out of scope (no interactive registry pushes; can be added later by
listing the same two modules).

## What the user does

Because the manifest + `apply` preflight do the work, it collapses to one command on an
already-set-up box:

```sh
mise run apply
```

This detects the three `docker/*` keys missing from `secrets.yaml`, runs `secrets:pull`
(one Bitwarden unlock — fetches the tokens, base64-encodes them, commits), rebuilds (the
gated module de-inerts and renders `config.json`), then `chezmoi apply`. No new Bitwarden
items are needed; the manifest reuses the existing Gitea/Github items and token fields.

## Verification

```sh
git add -A
nix flake check --no-build
for h in desktop laptop server wsl; do
  nix build --dry-run ".#nixosConfigurations.$h.config.system.build.toplevel"
done
```

On a real host after rebuild + `secrets:pull`:

```sh
readlink ~/.docker/config.json          # → /run/secrets/rendered/docker-config.json
docker pull <main-gitea-host>/<...>  # non-interactive, no docker login
docker build -t test .                   # buildx still writes ~/.docker/buildx — must succeed
```

## Out of scope / non-goals

- AWS ECR (dynamic tokens — stays with the `aws` alias).
- `docker login` writing back to config.json (intentionally read-only; creds are
  declarative, exactly like git-credentials `0400`).
- Non-auth Docker config (CLI plugin settings, buildx config) — left to Docker's own
  writable `~/.docker/`.
