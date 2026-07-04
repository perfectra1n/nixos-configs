# nixos-configs

Multi-host NixOS + Home Manager flake. Plain `mkHost` factory (no framework), with
[sops-nix](https://github.com/Mic92/sops-nix) for secrets and
[nixos-facter](https://github.com/nix-community/nixos-facter) for hardware detection.

## Hosts

|    name   | Machine          | Desktop            | GPU    | Extras                         |
|-----------|------------------|--------------------|--------|--------------------------------|
| `desktop` | bare-metal       | Wayland + Hyprland | NVIDIA | gaming, GUI apps               |
| `laptop`  | bare-metal       | Wayland + Hyprland | AMD    | gaming, GUI apps, power mgmt   |
| `server`  | bare-metal / VM  | none (headless)    | —      | SSH-hardened, docker/services  |
| `wsl`     | WSL2             | none (headless)    | —      | CLI/dev only                   |

The config name matches `networking.hostName`, so on the box itself you can drop the
`#name` from `nixos-rebuild`.

## First: set your username

`flake.nix` has one `username` binding near the top (currently `perf3ct`). Set it to your
login name **before** the first build. Create the **same** name at install time so the
install-seeded password survives the first flake switch.

## Layout

```
flake.nix              # inputs + mkHost factory + the nixosConfigurations
modules/
  common.nix           # universal base — every host (+ sops wiring)
  facter.nix           # nixos-facter report + detected.* flags
  desktop-base.nix     # graphical common (audio, fonts, networkmanager) — graphical hosts
  hyprland.nix         # Wayland + Hyprland stack — desktop, laptop
  nvidia.nix           # NVIDIA driver — desktop
  amd.nix              # AMD driver — laptop
  gaming.nix           # Steam/gamescope/gamemode/proton-ge — desktop, laptop
  laptop.nix           # power-profiles-daemon, lid, firmware — laptop
  server.nix           # headless baseline (ssh hardening) — server
  desktop-apps.nix     # slack/discord/etc — desktop, laptop
home/
  common.nix           # CLI/dev home — every host
  gui.nix              # GUI apps — graphical hosts only
hosts/
  desktop/{default.nix, hardware-configuration.nix}   # NVIDIA — hardware is a PLACEHOLDER
  laptop/{default.nix, hardware-configuration.nix}    # AMD    — hardware is a PLACEHOLDER
  server/{default.nix, hardware-configuration.nix}    #        — hardware is a PLACEHOLDER
  wsl/default.nix      # NixOS-WSL; no hardware-configuration.nix needed
secrets/secrets.yaml   # sops-encrypted (PLACEHOLDER stub)
.sops.yaml             # sops keys + creation rules
```

## Installing from scratch (bare-metal: desktop / laptop / server)

Install a baseline NixOS the normal way, boot it, then let `mise run apply` do the rest.
The heavy flake build happens *after* reboot on the real disk. (`wsl` differs — see the end.)

1. **Install a baseline NixOS** (graphical or minimal ISO). Create your user with the
   **same name `flake.nix` uses** (`perf3ct`) and set its password — it stays machine-local;
   the flake then owns groups/shell/sudo. Reboot into the installed system.
2. **Pull this flake.** Nothing's installed yet on a minimal box, so grab the tools in one
   throwaway `nix-shell` and **do everything below inside it** — `bw`'s session lives in a
   single `BW_SESSION` env var, so the unlock and the later `mise run` must share one
   subshell (exit it and you'd have to unlock again). `nix-shell` drops you into
   bash, so the `export` syntax works even though the login shell is fish.
    ```sh
    nix-shell -p jq mise git bitwarden-cli

    # Unlock once and capture the session, so every later `bw` (and mise's tasks) inherit it.
    # --raw prints only the session key (prompts go to the tty); `|| bw unlock --raw` covers
    # an already-logged-in-but-locked box.
    bw config server <server-url>
    export BW_SESSION=$(bw login --raw || bw unlock --raw)
    ```
   Bootstrap clone — the repo is public, so no token dance is needed (pushes later ride
   the sops-rendered `~/.git-credentials`):
   ```sh
   git clone https://github.com/perfectra1n/nixos-configs.git ~/nixos-configs
   cd ~/nixos-configs
   ```
3. **Confirm the `boot.loader` block** in `hosts/<HOST>/default.nix` matches the
   firmware (UEFI systemd-boot vs BIOS GRUB) — `apply` is about to switch.
4. **Apply.** Still in the same `nix-shell` (so `BW_SESSION` is live), one command takes a
   fresh box all the way to a running, dotfiled system:
   ```sh
   mise run apply        # (first run on a minimal box: `mise trust && mise run apply`)
   ```
   On a fresh box this, in order:
   - pulls the **one age key** from Bitwarden → sops-nix + chezmoi (`secrets:key-bootstrap`;
     prompts for the vault server URL; no-op if the key is already present),
   - **prompts you to pick the host** — the installer hostname is still `nixos`, which
     matches no config (override non-interactively with `HOST=laptop mise run apply`),
   - **captures + commits** this machine's real `hardware-configuration.nix` (the shipped
     one is a placeholder with fake disk UUIDs — switching on it would be unbootable),
   - runs `nixos-rebuild switch --flake .#<HOST>`, then
   - `chezmoi apply`s your dotfiles — they live in this repo under `dotfiles/` (no separate clone),
     and the `secrets:key-bootstrap` step above wrote the chezmoi age key so `secrets.fish` etc. decrypt.

   This drives `nixos-rebuild switch`, **not** `nixos-install` (that's the ISO tool, which
   targets `/mnt`). Optionally generate a facter report too (see **Facter** below).

### WSL (no ISO)

Install the NixOS-WSL rootfs tarball on Windows, then from inside it:
```sh
sudo nixos-rebuild switch --flake git+<this-repo-url>#wsl
```

## Facter (hardware detection)

`modules/facter.nix` wires [nixos-facter](https://github.com/nix-community/nixos-facter).
On a real host, generate a report once:
```sh
sudo nixos-facter -o hosts/<HOST>/facter.json
git add hosts/<HOST>/facter.json
```
When present, `modules/facter.nix` loads it and exposes `config.detected.{isLaptop,
isDesktop,nvidia,amd,wireless}` for modules to key off (see the examples in
`modules/laptop.nix` / `modules/nvidia.nix`). When absent, facter stays dormant and the
host falls back to `hardware-configuration.nix` — so a fresh checkout still evaluates.
facter does **not** detect partitions; keep `fileSystems` in `hardware-configuration.nix`.

## Secrets

**Single-key model:** ONE age key decrypts every secret on every host. The private key
lives in Bitwarden; a fresh box pulls it down with `mise run secrets:key-bootstrap`, so it
decrypts on the first rebuild with no per-host enrollment. Nothing is decrypted until you
declare a `sops.secrets.*` entry, so the wiring is inert on a fresh checkout.

### Where secrets live (three channels, one key)

| Channel | At rest (in this repo, encrypted) | Decrypts to | Update with |
|---|---|---|---|
| **System (sops-nix)** | `secrets/secrets.yaml` | `/run/secrets/*` (tmpfs) at rebuild | `mise run secrets:pull` — every key is Bitwarden-backed |
| **Shell env (fish)** | `dotfiles/.../encrypted_private_secrets.fish.age` | `~/.config/fish/fishconfig.d/secrets.fish` via `chezmoi apply` | `mise run secrets:pull` (or `secrets:pull-env` for this channel alone) |
| **File snapshots** | standalone `.age` files in `dotfiles/` (kubeconfig, talosconfig) | their target paths via `chezmoi apply` | `chezmoi add --encrypt <target>` after the live file changes — cluster-generated artifacts, deliberately NOT in Bitwarden |

Bitwarden is the source of truth for the first two channels: **every** sops key and
**every** fish env var (API keys, MCP endpoints, and the private hostnames this public
repo must not contain) maps to a vault item via the two manifests at the top of
`scripts/secrets-sync.py` (`SOPS_MANIFEST`, `FISHENV_MANIFEST`). Adding a secret is one
manifest row + one vault item. See the full map without touching the vault:
```sh
./scripts/secrets-sync.py inventory    # channel, key/var, Bitwarden item, kind
```
Rotate/change a value in Bitwarden, then `mise run secrets:pull` refreshes BOTH channels
in a single vault unlock (surgical per-key updates — unrelated ciphertext doesn't churn).

Other tasks in the `secrets:` mise namespace (`mise tasks | grep secrets`):
`secrets:init` (first-time populate), `secrets:edit` (manual sops edit — out-of-band
experiments only; `secrets:pull` overwrites manifest-backed keys), `secrets:list`,
`secrets:status`, `secrets:get KEY=…`, plus the age-key tasks
`secrets:key-{bootstrap,install,enroll}` and `secrets:updatekeys`.

1. Generate the key once, fill its public half into `.sops.yaml`, and store the private
   half in Bitwarden — full steps are in the comments at the top of `.sops.yaml`.
2. On a fresh host, pull the key:
   ```sh
   BW_SERVER=https://vault.example.com mise run secrets:key-bootstrap
   ```
   (writes `/var/lib/sops-nix/key.txt` for sops-nix + `~/.config/age/age.agekey` for chezmoi).
3. Populate the manifest-backed secrets from Bitwarden (or `mise run secrets:edit` to add
   one by hand):
   ```sh
   mise run secrets:init               # encrypts + commits secrets/secrets.yaml
   ```
   Then set `sops.validateSopsFiles = true;` back in `modules/common.nix`.
4. To manage the user password declaratively: store a hash under `passwords/<username>`,
   uncomment `hashedPasswordFile` + `users.mutableUsers = false` in `modules/common.nix`.

## Applying changes / day-to-day

```sh
cd ~/nixos-configs
# …edit…
git add -A                              # flakes only see git-TRACKED files
sudo nixos-rebuild switch --flake .#<HOST>
```
Verbs: `switch` (now + boot default) · `test` (now, not persisted) · `boot` (next reboot) ·
`build` (build only). Update inputs: `nix flake update` then rebuild. Recover:
`sudo nixos-rebuild switch --rollback` or pick an older generation at boot.

## Boundary

- **One repo, two peer tools.** This repo holds both the Nix flake and the chezmoi dotfiles
  source (`dotfiles/`). Neither tool applies the other's tree — a `.chezmoiroot` redirect scopes
  chezmoi to `dotfiles/`, and the flake never renders it.
- **The Nix half** (everything outside `dotfiles/`) owns packages, services, system state.
  Edit + `nixos-rebuild`.
- **The chezmoi half** (`dotfiles/`) owns `~/.config/*` (hypr, waybar, nvim, fish, …). The two
  never touch the same file. GPU/monitor *fragments* the flake writes (e.g. `hypr/gpu.conf`) are
  sourced by the chezmoi `hyprland.conf`.
- **Secrets live in two separate systems that never overlap.** The flake's **sops-nix**
  (`secrets/secrets.yaml`) holds *system* secrets → decrypted at activation into
  `/run/secrets`. chezmoi's **age** encryption holds *user/shell* dotfile secrets →
  decrypted at `chezmoi apply` into `~/.config`. They share the **same** age key (one
  Bitwarden item, written to both `/var/lib/sops-nix/key.txt` and
  `~/.config/age/age.agekey`) but stay separate encryption systems — don't move a secret
  across the line.

## CI

`.github/workflows/check.yaml` dry-run-builds every host on push/PR (and gates Renovate's
`flake.lock` bumps). It evaluates with the placeholder hardware stubs, so it stays green
before any machine is installed.
