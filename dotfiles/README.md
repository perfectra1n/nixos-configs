# dotfiles (chezmoi source)

Personal dotfiles managed with [chezmoi](https://www.chezmoi.io/), with secrets
encrypted at rest using [age](https://github.com/FiloSottile/age).

> **These live inside the [`nixos-configs`](../README.md) monorepo.** chezmoi finds this
> directory via the repo-root `.chezmoiroot`, and `modules/dotfiles.nix` pins chezmoi's
> `sourceDir` to the flake checkout. There is **no separate repo to clone or `chezmoi init`** —
> bootstrap is driven by the flake (`mise run apply`). See [Bootstrapping](#bootstrapping-a-new-machine)
> below and the top-level [README](../README.md) / [architecture doc](../docs/architecture.md).

- **Source of truth:** this repo's `dotfiles/` (chezmoi source), part of `nixos-configs`
- **Remote:** `https://github.com/perfectra1n/nixos-configs` (the monorepo)
- **Target:** your home directory (`$HOME`)
- **Encryption:** chezmoi's native `age` integration (see [Secrets & age / SOPS](#secrets--age--sops))

---

## Table of contents

1. [How it works](#how-it-works)
2. [What's managed (and what isn't)](#whats-managed-and-what-isnt)
3. [Prerequisites](#prerequisites)
4. [Bootstrapping a new machine](#bootstrapping-a-new-machine)
5. [Secrets & age / SOPS](#secrets--age--sops)
6. [Daily workflow & fish helpers](#daily-workflow--fish-helpers)
7. [Common tasks (examples)](#common-tasks-examples)
8. [chezmoi source-file naming reference](#chezmoi-source-file-naming-reference)
9. [Verifying no secrets leak](#verifying-no-secrets-leak)
10. [Troubleshooting](#troubleshooting)

---

## How it works

chezmoi keeps a **source directory** (this repo) that describes the desired
state of files in your home directory. Each source file maps to a target via a
naming convention (`dot_bashrc` → `~/.bashrc`). You edit the real files, run
`chezmoi add` (or `re-add`) to copy changes back into the source, then commit
and push. On another machine you `chezmoi apply` to recreate everything.

```
   edit ~/.config/fish/...          nixos-configs/dotfiles/          GitHub
   ──────────────────────►  add/re-add  ─────────────────►  commit + push  ─────►
   (your live home files)         (the source, in the monorepo)        (remote)

   ◄──────────────────────  apply  ◄─────────────────────  pull / update  ◄─────
```

Secrets never enter the repo as plaintext: they live in a single age-encrypted
file (`encrypted_private_secrets.fish.age`) that chezmoi decrypts on `apply`.

---

## What's managed (and what isn't)

### Managed

| Area | Paths |
|------|-------|
| Shells | `~/.bashrc`, `~/.bash_aliases` (zsh retired — `.chezmoiremove` evicts old copies) |
| Fish | all of `~/.config/fish/` (`config.fish`, `fishconfig.d/`, `conf.d/`, `functions/`, `completions/`, `scripts/`, `fish_plugins`) |
| Git / Vim | `~/.gitconfig`, `~/.vimrc` |
| Editors/tools | `~/.config/nvim`, `lazygit`, `lazydocker`, `k9s`, `mise`, `starship.toml` |
| Desktop | `~/.config/i3`, `hypr`, `waybar`, `polybar`, `picom`, `rofi`, `alacritty`, `btop` |
| Helm / gh | `~/.config/helm/repositories.yaml`, `~/.config/gh/config.yml` (prefs only) |
| **Secrets** | `~/.config/fish/fishconfig.d/secrets.fish` → stored encrypted |

### NOT managed — see [`.chezmoiignore`](.chezmoiignore)

- **Machine/tool state & caches:** `.cache`, `.npm`, `.cargo`, `.bun`, `.kube`,
  `.docker`, `.gnupg`, `.krew`, `.aws`, `.azure`, browser profiles, etc.
- **Shell histories** and `.git-credentials`.
- **`~/.config/fish/fish_variables`** — fish's machine-generated universal-variable
  store. It is intentionally ignored because it is auto-managed by fish *and* used
  to hold secrets (now relocated to the encrypted file).
- **Credential-bearing tool state** — regenerate these with each tool's own login
  command instead of syncing tokens:

  | Config | Regenerate with |
  |--------|-----------------|
  | `~/.config/gh/hosts.yml` | `gh auth login` |
  | `~/.config/tea/` | `tea login add` |
  | `~/.config/argocd/` | `argocd login <server>` |
  | `~/.config/kopia/` | `kopia repository connect ...` |

- **`README.md`** (this file) — ignored as a *target* so chezmoi never writes
  `~/README.md`.

---

## Prerequisites

| Tool | Why | Install |
|------|-----|---------|
| `chezmoi` (v2.70+) | the dotfile manager | `brew install chezmoi` |
| `age` / `age-keygen` | encrypt/decrypt secrets | `brew install age` |
| your **age private key** | decrypt secrets on this machine | see below |
| `fish` (optional) | the shell these configs target | `brew install fish` |

The age key is expected at **`~/.config/age/age.agekey`** (the same key referenced
by `$SOPS_AGE_KEY_FILE`). Keep it `chmod 600` and **never commit it**.

---

## Bootstrapping a new machine

These dotfiles ride along inside the `nixos-configs` monorepo, so there's **no separate clone
or `chezmoi init`** — the flake's bootstrap does it all (full walkthrough in the top-level
[README](../README.md)). In short, from a checkout of the monorepo:

```fish
# 1. Pull the ONE age key (decrypts both sops-nix and these dotfiles) from Bitwarden:
mise run secrets:key-bootstrap        # writes ~/.config/age/age.agekey (+ the root sops-nix copy)

# 2. Rebuild: this generates ~/.config/chezmoi/chezmoi.toml (sourceDir + age config, from
#    modules/dotfiles.nix) and then applies these dotfiles from ./dotfiles:
mise run apply

# 3. Re-authenticate the tools whose tokens are intentionally NOT synced:
gh auth login
tea login add
# argocd login <server> ; kopia repository connect ... (as needed)
```

You do **not** hand-write `~/.config/chezmoi/chezmoi.toml` anymore — `modules/dotfiles.nix`
generates it, pinning `sourceDir` to the monorepo checkout plus the `age` identity/recipient.
The age **public** recipient (`age1cmyz…`) is safe to share; the private key never leaves
Bitwarden + `~/.config/age/age.agekey` (keep it mode `600`, never commit it).

To preview/apply by hand once bootstrapped: `chezmoi diff` then `chezmoi apply` (or
`mise run dots-diff` / the `cz` helpers).

---

## Secrets & age / SOPS

### What's encrypted

Every var in `secrets.fish` — API keys/tokens, MCP endpoints, and the **private domains**
(`MAIN_GITEA_HOST`, `HOMELAB_SSH_DOMAIN`, `RESTIC_S3_ENDPOINT`) that fish functions splice
into URLs so no personal hostname appears in this public repo. All of them are
Bitwarden-backed: the authoritative list is the `FISHENV_MANIFEST` in
[`scripts/secrets-sync.py`](../scripts/secrets-sync.py) (print both channels with
`./scripts/secrets-sync.py inventory`), and `mise run secrets:pull` refreshes the lot.

`secrets.fish` is a plain fish script of `set -Ux NAME value` lines. chezmoi stores
it **only** as `dot_config/fish/fishconfig.d/encrypted_private_secrets.fish.age`
(age ciphertext). It is sourced near the top of `config.fish`:

```fish
# Secret env vars — decrypted from chezmoi-managed encrypted_private_secrets.fish.age
test -f $FISHCONFIG/secrets.fish; and source $FISHCONFIG/secrets.fish
```

These values were **removed from fish's universal scope** (`set -eU ...`), so the
encrypted file is the single source of truth — no stale plaintext copy lingers in
`fish_variables`.

### Relationship to SOPS

This repo does **not** use SOPS. It uses chezmoi's *built-in* age encryption, which
encrypts to the **same age key** your SOPS workflow uses
(`$SOPS_AGE_KEY_FILE` → `~/.config/age/age.agekey`). So you maintain one age
identity for both:

- **SOPS** (e.g. homelab / Kubernetes secrets) → `sops` CLI + `.sops.yaml`
- **chezmoi** (these dotfiles) → `chezmoi`'s `age` integration, configured in
  `~/.config/chezmoi/chezmoi.toml`

Both decrypt with the same private key; the public recipient is identical. If you
rotate the age key, update **both** the SOPS recipients and the chezmoi
`recipient`, then re-encrypt (`chezmoi re-add --encrypt ...` / `chezmoi apply`).

### Encrypting more secrets later

```fish
# add a new secret file encrypted
echo 'set -gx SOME_TOKEN abc123' > ~/.config/fish/fishconfig.d/morestuff.fish
chezmoi add --encrypt ~/.config/fish/fishconfig.d/morestuff.fish   # or: czaddsecret <path>

# edit an existing encrypted secret (decrypts to a temp file, re-encrypts on save)
chezmoi edit ~/.config/fish/fishconfig.d/secrets.fish              # or: czedit <path>

# view a decrypted secret without editing
chezmoi cat ~/.config/fish/fishconfig.d/secrets.fish              # or: chezmoi decrypt <source.age>
```

---

## Daily workflow & fish helpers

Helper functions live in `~/.config/fish/fishconfig.d/fish_functions.fish`:

| Function | Runs | Use for |
|----------|------|---------|
| `czadd <path>` | `chezmoi add` | stage a changed/new file into the source |
| `czaddsecret <path>` | `chezmoi add --encrypt` | stage a secret file (age-encrypted) |
| `czdiff` | `chezmoi diff` | preview what `apply` would change in `$HOME` |
| `czstatus` | `chezmoi status` | list files that differ from the source |
| `czapply` | `chezmoi apply` | write the source into `$HOME` |
| `czupdate` | `chezmoi update` | `git pull` in the source **and** apply |
| `czedit <path>` | `chezmoi edit` | edit a managed file (handles encrypted ones) |
| `czcd` | `cd (chezmoi source-path)` | jump into the source repo |
| `czpush` | `cpush` | re-add changed files, commit, and push |
| `cpush` *(legacy)* | `chezmoi re-add` + `chezmoi git add/commit/push` **scoped to `dotfiles/`** | push helper — scoped so the monorepo's Nix changes are never swept into a dotfiles commit |

> The old bare-repo helpers (`dotfiles`, `updatedotfiles`, `lazygitdotfiles`) and
> `~/repos/dotfiles` are **superseded** by chezmoi. They're left in place but inert.

### Typical loop

```fish
vim ~/.config/fish/fishconfig.d/fish_aliases.fish   # 1. edit a real file
czdiff                                               # 2. (optional) preview
czpush                                               # 3. re-add + commit + push
```

On another machine:

```fish
czupdate            # pull latest + apply
```

---

## Common tasks (examples)

**Add a brand-new dotfile to management**
```fish
czadd ~/.config/foo/config.toml
czpush
```

**Add an entire directory**
```fish
czadd ~/.config/newapp        # recursively adds all files (respects .chezmoiignore)
```

**Stop managing something**
```fish
chezmoi forget ~/.config/foo/config.toml   # removes from source, leaves the live file
# then add a matching line to .chezmoiignore if it shouldn't come back
```

**Preview before applying anything (dry run)**
```fish
chezmoi apply --dry-run --verbose
```

**Pick up a change you made directly in the source repo**
```fish
czcd
$EDITOR dot_gitconfig
chezmoi apply        # push the source change out to ~/.gitconfig
```

**See exactly which files chezmoi manages**
```fish
chezmoi managed | sort
```

---

## chezmoi source-file naming reference

Source filenames encode target attributes (you rarely type these by hand — `chezmoi
add` generates them):

| Prefix / suffix | Meaning | Example → target |
|-----------------|---------|------------------|
| `dot_` | leading `.` in the target | `dot_bashrc` → `~/.bashrc` |
| `private_` | target mode `0600` | `private_config.yml` |
| `executable_` | target mode `0755` | `executable_launch.sh` |
| `empty_` | keep even if file is empty | `empty_centos.fish` |
| `encrypted_` | stored as age ciphertext | `encrypted_private_secrets.fish.age` |
| `.tmpl` | rendered as a Go template on apply | `dot_gitconfig.tmpl` |
| `.keep` (file) | placeholder so an otherwise-empty dir is tracked | `themes/.keep` |

Special files: `.chezmoiignore` (targets to skip), `.chezmoi.toml.tmpl` (generates
config on `init`), `.chezmoiexternal.*` (pull external assets).

---

## Verifying no secrets leak

Before pushing, confirm only the `.age` blob contains anything sensitive:

```fish
cd (chezmoi source-path)              # → dotfiles/ inside the monorepo
git add -A -- .                       # stage just this dir, not the rest of the monorepo
# scan everything staged EXCEPT the encrypted blob — must print nothing:
git diff --cached -- . ':(exclude)**/encrypted_*.age' \
  | grep -iE 'sk-ant-|AWS_BEARER|CIRCLE_TOKEN|TURNSTILE|oauth_token|auth-token|ghp_|github_pat_|-----BEGIN'
```

The encrypted file itself begins with `-----BEGIN AGE ENCRYPTED FILE-----`; that's
ciphertext and is expected. A match **outside** that file means a secret is about to
be committed — stop and fix it.

---

## Troubleshooting

**`chezmoi apply` says it can't decrypt / "no identity matched"**
The age key is missing or the path in `~/.config/chezmoi/chezmoi.toml` is wrong.
Confirm `ls -l ~/.config/age/age.agekey` (mode `600`) and that
`age-keygen -y ~/.config/age/age.agekey` prints the same `recipient` as the config.

**Secrets aren't set in a new shell**
Open a *login* shell (`fish --login`) or `exec fish`. `config.fish` sources
`secrets.fish`; check it exists with `chezmoi apply` first, then
`echo $ANTHROPIC_API_KEY | string length` (should be non-zero).

**`chezmoi diff` shows permission-only changes (mode 0744 → 0755)**
chezmoi normalizes dir/script modes. Run `chezmoi apply` once to converge; it's
harmless.

**A tool says it's not authenticated after a fresh apply**
Expected — `gh`/`tea`/`argocd`/`kopia` tokens are intentionally not synced.
Re-run that tool's login command (see [What's managed](#whats-managed-and-what-isnt)).

**I edited the source repo directly and home didn't change**
`chezmoi apply` pushes source → home. `chezmoi add`/`re-add` goes the other way
(home → source). Don't mix them up.
