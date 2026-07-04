# Neovim starter config — LazyVim drop-in

**Date:** 2026-06-30
**Status:** implemented

## Goal

Replace the near-empty nvim config (`dotfiles/dot_config/nvim/init.vim`, two cursor
lines) with a real, maintained starter so `nvim` is a usable IDE-grade editor.

## Decision

Use the official **[LazyVim starter](https://github.com/LazyVim/starter)**. The repo
already committed to LazyVim implicitly: `home/common.nix:39` is commented
`"neovim + LazyVim deps"` and installs the full toolchain (`gcc`, `nodejs`,
`lua-language-server`, `stylua`, `tree-sitter`), plus `fd`/`ripgrep`/`lazygit`/`fzf`.
So **no flake changes are needed** — this is purely a chezmoi dotfiles change.

LazyVim chosen over kickstart.nvim (more batteries-included, honors existing intent)
and NvChad (less abstraction; matches the existing deps comment).

## Boundary placement (per CLAUDE.md)

- **Config → chezmoi:** lives in `dotfiles/dot_config/nvim/` → `~/.config/nvim`.
- **Toolchain → flake:** already present in `home/common.nix`. Untouched.
- nvim uses its own colorscheme (tokyonight), outside the DMS/matugen theming boundary.

## Files

Copied from the upstream starter into `dotfiles/dot_config/nvim/` (chezmoi `dot_`
prefix for leading-dot files):

```
init.lua                 lua/config/lazy.lua      lua/config/options.lua
lua/config/keymaps.lua   lua/config/autocmds.lua  lua/plugins/example.lua
stylua.toml              dot_neoconf.json   (→ .neoconf.json)
```

Starter `LICENSE`, `README.md`, `.gitignore` deliberately NOT copied (repo cruft; the
`.gitignore` would also wrongly ignore `lazy-lock.json`).

## Three handled details

1. **`init.vim` deleted.** Neovim errors when both `init.vim` and `init.lua` exist. Its
   only content — `set guicursor=` — is ported to `lua/config/options.lua` as
   `vim.opt.guicursor = ""`.
2. **`lazy-lock.json` is a writable snapshot, not a lock.** It is generated on first
   launch, not shipped here. Capture later via `chezmoi add` at `0644` so `:Lazy update`
   can rewrite it. Never `readonly_`/`0444` (matches the DMS-config snapshot pattern).
3. **`dot_vimrc` untouched** — that's the separate plain-`vim` config; nvim and vim stay
   independent.

## Out of scope (YAGNI)

No flake edits, no custom plugins/colorscheme up front, no `lazyvim.extras` language
packs seeded — add those later via the LazyVim extras UI (`:LazyExtras`) and re-capture
with `chezmoi add`.

## Verification

1. `git add` the new files (chezmoi sees source files directly, but keep the tree tracked).
2. `chezmoi diff` → confirms a clean write of `~/.config/nvim` with no clobber.
3. `chezmoi apply`, then launch `nvim` once → `lazy.nvim` installs plugins.
4. `:checkhealth` / `:LazyHealth` green; `:Lazy` shows plugins loaded.
5. `chezmoi add ~/.config/nvim/lazy-lock.json` to pin versions; commit.
