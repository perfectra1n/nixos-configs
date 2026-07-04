# How chezmoi fits this repo

The monorepo-integration view: how one repo serves two peer tools without either seeing the
other's tree. The [architecture doc](architecture.md#the-chezmoi-boundary) explains *why* the
boundary exists and what goes on which side; [`dotfiles/README.md`](../dotfiles/README.md) is the
dotfiles-side manual (naming conventions, fish helpers, leak checks). This doc covers the piece
neither of those owns: the **wiring and lifecycle** that make the two halves one system.

## Peers, not nested

Nix and chezmoi share this repo but **neither applies or templates the other's tree**:

```
nixos-configs/                      ← the flake sees everything git-tracked…
├── flake.nix, modules/, hosts/     ← …but chezmoi never scans these
├── .chezmoiroot                    ← one line: "dotfiles" — redirects chezmoi
└── dotfiles/                       ← chezmoi SOURCE; the flake never renders it
    ├── dot_config/…                ← flat chezmoi naming (dot_config/fish → ~/.config/fish)
    ├── .chezmoiignore              ← targets chezmoi must never manage (caches, histories, creds)
    └── .chezmoiremove              ← targets chezmoi actively DELETES on apply (retired files)
```

## The four moving parts

| Artifact | Owner | Job |
|----------|-------|-----|
| [`.chezmoiroot`](../.chezmoiroot) | repo root | One line (`dotfiles`) — scopes chezmoi to the subtree so it never sees `flake.nix` |
| `~/.config/chezmoi/chezmoi.toml` | **generated** by [`modules/dotfiles.nix`](../modules/dotfiles.nix) | Pins `sourceDir` to this checkout + the age identity/recipient. chezmoi never writes its own config, so Nix owning this is NOT a boundary violation — it's machine-local plumbing, not a managed dotfile |
| [`dotfiles/`](../dotfiles/README.md) | chezmoi | The source tree; `chezmoi edit`/`add` land here, `chezmoi apply` renders it into `$HOME` |
| [`mise.toml`](../mise.toml) | repo root | Orchestration — `mise run apply` = rebuild **then** `chezmoi apply` (see [operations.md](operations.md)) |

**Load-bearing path:** `modules/dotfiles.nix` bakes the checkout location
(`~/repos/nixos-configs`) into `sourceDir`. Move the checkout and `chezmoi apply` silently reads a
stale source (or nothing) until the next rebuild regenerates the toml. It's the one deliberate
coupling cost of the monorepo model — a single binding, in the spirit of `username` in `flake.nix`.

## Lifecycle

### Fresh machine (three commands)

```sh
mise run secrets:key-bootstrap   # 1. pull the ONE age key from Bitwarden →
                                 #    /var/lib/sops-nix/key.txt (system) + ~/.config/age/age.agekey (user)
mise run apply                   # 2. rebuild (generates chezmoi.toml) → chezmoi apply (renders dotfiles/)
gh auth login ; tea login add    # 3. re-auth the tools whose tokens are deliberately NOT synced
```

No `chezmoi init`, no separate clone — the flake checkout *is* the chezmoi source. Step 2's
preflights self-heal a blank box (missing key, placeholder hardware config, placeholder
secrets.yaml) — see [operations.md](operations.md#apply--the-self-healing-entry-point).

### Daily edit loop

```
edit ~/.config/…  →  czpush (chezmoi re-add + commit + push, SCOPED to dotfiles/)
                                          │
other machine:  czupdate (chezmoi update) ┘  = git pull the whole monorepo + apply dotfiles only
```

Two asymmetries worth internalizing:

- **`chezmoi update` pulls the whole monorepo** (the source dir is the repo checkout) but only
  *applies* dotfiles — pulled Nix changes just sit until the next `mise run apply`. Cheap dotfile
  sync without a rebuild.
- **`cpush`/`czpush` is scoped to `dotfiles/`** on purpose, so a dotfiles commit never sweeps up
  in-flight Nix changes elsewhere in the monorepo.

⚠️ `chezmoi apply` **overwrites uncommitted edits under `dotfiles/`** (it renders source → home,
and `re-add` goes home → source) — commit WIP in the source tree before applying.

## Secrets: one key, two encryption systems

The same age identity (`~/.config/age/age.agekey`, private half in Bitwarden) decrypts both
channels — but the channels never mix:

| Channel | Encrypted with | Files | Decrypted |
|---------|---------------|-------|-----------|
| System secrets | **sops-nix** | `secrets/secrets.yaml` | at *activation* → `/run/secrets/*` |
| User dotfile secrets | **chezmoi's native age** | `dotfiles/**/*.age` | at *apply* → plaintext in `$HOME` |

The `.age` files currently in the source (all `encrypted_` + age ciphertext at rest, so the repo
stays publishable):

- `dot_config/fish/fishconfig.d/encrypted_private_secrets.fish.age` — env-var secrets
  (`ANTHROPIC_API_KEY`, …), sourced by `config.fish`. Refreshed from Bitwarden via
  `mise run secrets:pull-env`.
- `private_dot_kube/encrypted_private_config.age` → `~/.kube/config` (mode 600).
- `dot_talos/encrypted_private_config.age` → `~/.talos/config`.

Add a new one with `chezmoi add --encrypt <path>` (or the `czaddsecret` helper); edit in place with
`chezmoi edit <target>` — it decrypts to a temp file and re-encrypts on save. Rotating the key
means updating **both** the `.sops.yaml` recipients and the `recipient` in `modules/dotfiles.nix`,
then re-encrypting both channels.

## `.chezmoiignore` vs `.chezmoiremove`

Easy to conflate, opposite jobs:

- **`.chezmoiignore`** — targets chezmoi must *never manage or write*: caches, shell histories,
  credentials, `fish_variables` (machine-generated *and* used to hold secrets), browser profiles,
  and re-auth-instead-of-sync tool state (`gh hosts.yml`, `tea`, `argocd`, `kopia`).
- **`.chezmoiremove`** — targets chezmoi *actively deletes* on every apply. Used to retire files
  fleet-wide: the stray Hyprland-generated `hyprland.lua` (which would silently take precedence
  over `hyprland.conf`), the retired `screenshot-hdr.sh`, the pre-LazyVim `nvim/init.vim`.
  Declarative cleanup — a deleted source file alone does NOT remove the deployed copy from
  machines that already have it.

## The failure mode to know

A chezmoi↔home-manager **collision** on any `~/.config` file makes
`home-manager-<user>.service` fail with *"would be clobbered"* — and that **silently stops ALL HM
file updates** (every `xdg.configFile`, not just the colliding one) until resolved. This is why
the boundary is a hard rule: the flake writes only the sanctioned `hypr/*.conf` fragments that the
chezmoi `hyprland.conf` `source`s (see [architecture.md](architecture.md#the-chezmoi-boundary)),
and app-owned config (DMS `settings.json`) is managed as a writable chezmoi *snapshot*, never a
lock.

Diagnose with `systemctl --user status home-manager-*.service`; fix by moving the file to exactly
one owner.

## Related

- [architecture.md §The chezmoi boundary](architecture.md) — the why + the ownership decision tree.
- [`dotfiles/README.md`](../dotfiles/README.md) — the dotfiles-side manual: naming reference,
  fish `cz*` helpers, secret-leak verification, troubleshooting.
- [operations.md](operations.md) — the mise tasks that orchestrate all of the above.
