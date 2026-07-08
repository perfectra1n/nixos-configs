# docs/

Design notes and reference material for this NixOS + Home Manager flake. For the
*working rules* (chezmoi boundary, git-tracking gotcha, conventions) read the root
[`CLAUDE.md`](../CLAUDE.md) first; for install/host setup read the root
[`README.md`](../README.md). These docs go deeper on the *why* and act as a map of what's
installed where.

| Doc | What's in it |
|-----|--------------|
| [architecture.md](architecture.md) | Design decisions & rationale — why plain `mkHost`, the composition model, the chezmoi boundary + its fragment exceptions, secrets/facter/pinning, and why each flake input exists. |
| [packages.md](packages.md) | Categorized inventory of every package / program / service, which file owns it, and which hosts receive it. The "what's installed where" reference. |
| [host-matrix.md](host-matrix.md) | Hosts × modules matrix + per-host hardware/boot notes. |
| [gaming.md](gaming.md) | Gaming/latency tuning — what's enabled, the gamemode+scx overlap, A/B tweaks, and chezmoi/Steam-side options. |
| [chezmoi.md](chezmoi.md) | How chezmoi fits the monorepo — the four moving parts (`.chezmoiroot`, generated `chezmoi.toml`, `dotfiles/`, mise), machine lifecycle, the one-key/two-channel secrets model, and the clobber failure mode. |
| [operations.md](operations.md) | The mise task suite as the operator interface — `apply`'s self-healing preflights, the change loop, secrets values-vs-identity tasks, host lifecycle, maintenance. |
| [mcp-servers.md](mcp-servers.md) | Claude Code's HTTP MCP servers — the three-artifact pattern (`mcp.json` block + `secrets-sync.py` manifest row + Bitwarden item), the `--mcp-config` launch wiring, and the add/update/remove loops. |
| [desktop-scripts.md](desktop-scripts.md) | The custom `let`-binding tools — hypr-cheatsheet (live keybind overlay), the grim latency shim + HDR screenshot context, and the retired blurcam's still-relevant v4l2loopback lore. |
| [idle-watchdog.md](idle-watchdog.md) | The `dms-idle-inhibit-watchdog` idle-policy daemon — how it releases leaked ScreenSaver inhibits so monitors DPMS-off, the positive-signal design, and how to debug a stuck screen. |

## Keeping these current

These docs are hand-maintained, not generated. When you add a module, package, or host,
update [packages.md](packages.md) and [host-matrix.md](host-matrix.md) in the same change
— the modules under `modules/`, `home/`, and `flake.nix` are the source of truth; these
docs summarize them.
