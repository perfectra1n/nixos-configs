# MCP servers for Claude Code

How this repo gives Claude Code a set of **HTTP MCP servers** that follow you onto
every machine, with their bearer tokens kept out of the (publishable) repo and out of
`~/.claude.json`. This is a thin layer on top of the [one-key / two-channel secrets
model](chezmoi.md#secrets-one-key-two-encryption-systems) — read that first if the `secrets.fish` / age plumbing is
unfamiliar; this doc covers only the MCP-specific wiring and the add/update/remove loops.

## The three moving parts

An MCP server is fully defined by **three artifacts that must agree**. Miss one and it
half-works — the classic failure is a token synced into `secrets.fish` but no `mcp.json`
block (or vice-versa), so nothing loads.

| Artifact | Owner | Holds | File |
|----------|-------|-------|------|
| **Server block** | git (plaintext) | transport + URL + headers, as `${VAR}` refs — **no secrets** | [`dotfiles/dot_config/claude/mcp.json`](../dotfiles/dot_config/claude/mcp.json) |
| **Manifest rows** | git (plaintext) | which Bitwarden item/field each `${VAR}` pulls from | `FISHENV_MANIFEST` in [`scripts/secrets-sync.py`](../scripts/secrets-sync.py) |
| **The secret** | Bitwarden → age | the actual URL + bearer, synced into `secrets.fish` | `dot_config/fish/fishconfig.d/encrypted_private_secrets.fish.age` |

## How it wires together at launch

```
 SECRET CHANNEL
   Bitwarden item ──(secrets-sync.py, FISHENV_MANIFEST)──▶ encrypted_private_secrets.fish.age  (git)
      "Memini MCP"                                                    │ chezmoi apply
      fields: mcp_url, mcp_bearer                                     ▼
                                              ~/.config/fish/.../secrets.fish
                                              set -Ux MEMINI_MCP_URL '…'
                                              set -Ux MEMINI_MCP_BEARER '…'
                                                                      │ sourced by config.fish
                                                                      ▼  (universal, exported env)
 CONFIG CHANNEL                                                       │
   dotfiles/dot_config/claude/mcp.json  (git source, ${VAR} refs)     │
      │ chezmoi apply                                                 │
      ▼                                                               │
   ~/.config/claude/mcp.json  (rendered — what Claude reads)          │
      │                                                               │
      └──────────────┐                        ┌─────────────────────┘
                     ▼                         ▼
   claude (fish wrapper) ── --mcp-config=~/.config/claude/mcp.json ──▶ claude expands
                                                                        ${MEMINI_MCP_URL} etc.
```

**Both** git-tracked files reach `$HOME` only through `chezmoi apply` — the encrypted `secrets.fish.age`
*and* `mcp.json`. Editing either in the repo is inert until applied. That is the single most common
"why won't it load" (the source has the block, the rendered file doesn't).

Two load-bearing details:

- **The `claude` fish wrapper** (in [`fish_functions.fish`](../dotfiles/dot_config/fish/fishconfig.d/fish_functions.fish))
  launches `command claude --mcp-config=~/.config/claude/mcp.json`. Servers defined this way are
  **not** written to `~/.claude.json` and **do not** appear in `claude mcp list` — that subcommand
  only shows *persisted* (user/project/local) servers. They load into the session regardless; the
  proof is their `mcp__<server>__*` tools being available, not the list.
- **`claude` itself expands `${VAR}`** in the `--mcp-config` file from its environment at launch.
  That is why the secret lives in `secrets.fish` as a `set -Ux` (universal + exported) var and never
  as literal text in `mcp.json`. Keep the repo copy of `mcp.json` `${VAR}`-only — a pasted token
  there would be committed in plaintext.

### Two header shapes

Most servers need only a bearer (one `mcp_url` + one `mcp_bearer`). A few need extra headers —
the Trilium servers add `X-Trilium-Url` / `X-Trilium-Token`, which is just more `${VAR}`s in the
block backed by more manifest rows and more Bitwarden fields. Same pattern, more rows.

```jsonc
// simple bearer (kubesearch, protondb, memini)
"memini": {
  "type": "http",
  "url": "${MEMINI_MCP_URL}",
  "headers": { "Authorization": "Bearer ${MEMINI_MCP_BEARER}" }
}
```

---

## Add a server

Worked example: **memini** (an agent-memory service). Do all four, then commit the three
tracked files together.

**1 — Bitwarden item.** Create one login item named `<Thing> MCP` (e.g. `Memini MCP`) with two
**custom fields**, matching the sibling convention exactly:

| Field | Type | Value |
|-------|------|-------|
| `mcp_url` | text | the full endpoint, e.g. `https://memini.example.internal/mcp` |
| `mcp_bearer` | hidden | the bearer token |

`bw sync` after creating it (the CLI caches; a fresh item is invisible until you sync).

**2 — Manifest rows.** Add to `FISHENV_MANIFEST` in `scripts/secrets-sync.py`, grouped with the
other MCP vars (`(dest_var, bw_item, kind, field)`):

```python
("MEMINI_MCP_URL",    "Memini MCP", "field", "mcp_url"),
("MEMINI_MCP_BEARER", "Memini MCP", "field", "mcp_bearer"),
```

**3 — Server block.** Add the block to `dotfiles/dot_config/claude/mcp.json` (see the shape above).
`${VAR}` refs only — no secret. Note this file is a **chezmoi source**: editing it does *not* change
what Claude reads (`~/.config/claude/mcp.json`) until `chezmoi apply` renders it — see step 4.

**4 — Sync + apply.** Pull the new vars from Bitwarden into the encrypted `secrets.fish`, then render
**both** changed dotfiles (`mcp.json` *and* `secrets.fish`) into `$HOME`:

```fish
mise run secrets:pull-env   # resolves manifest → re-encrypts secrets.fish.age → commits + pushes it
mise run apply              # (or: chezmoi apply) renders mcp.json + secrets.fish into $HOME
```

Then start a **new** shell so `secrets.fish` re-sets the `set -Ux` vars, and a **new** `claude`
session so it reads the freshly rendered `~/.config/claude/mcp.json`.

**5 — Commit the two code files** (the `.age` was already committed by `secrets:pull-env`):

```fish
git add dotfiles/dot_config/claude/mcp.json scripts/secrets-sync.py
git commit -m "feat(mcp): add memini MCP server"
```

**6 — Verify** in a **new** `claude` session (see [Verify](#verify)).

> The three artifacts are independent commits' worth of change but **one logical unit** — land them
> together. A manifest row without an `mcp.json` block leaves an orphan env var; a block without a
> row means `${VAR}` expands to empty and the server 401s or fails to connect.

## Update a server (rotate a token / change the URL)

The secret lives in **Bitwarden**, so:

1. Edit the field (`mcp_bearer` or `mcp_url`) on the Bitwarden item.
2. `mise run secrets:pull-env` — re-resolves the manifest, re-encrypts `secrets.fish.age`, commits it.
3. `mise run apply` (or `chezmoi apply`) and start a **new** shell so `secrets.fish` re-sets the
   `set -Ux` var to the new value.

No `mcp.json` change is needed for a rotation — the block references `${VAR}`, not the value.
Only touch `mcp.json` if the **header shape** changes (new/renamed header), which also means new
manifest rows and Bitwarden fields.

## Remove a server

There's a **gotcha**: `secrets-sync.py`'s `merge_fishenv()` only rewrites/append *managed* vars and
**preserves any line it doesn't recognize verbatim**. So deleting the manifest rows does *not*
delete the `set -Ux` lines already in `secrets.fish` — they become orphans that linger. Full removal
is four steps:

1. Delete the server block from `dotfiles/dot_config/claude/mcp.json`.
2. Delete the rows from `FISHENV_MANIFEST` in `scripts/secrets-sync.py`.
3. Delete the `set -Ux <VAR> …` lines from the encrypted file and re-encrypt:
   ```fish
   czedit ~/.config/fish/fishconfig.d/secrets.fish   # = chezmoi edit; decrypts → edit → re-encrypts
   ```
4. Purge the values already in the universal store (they persist until unset), and delete the
   Bitwarden item if it's truly retired:
   ```fish
   set -eU MEMINI_MCP_URL MEMINI_MCP_BEARER
   ```

Then commit `mcp.json`, `secrets-sync.py`, and the `.age`. Start a new shell to confirm the vars
are gone.

---

## Verify

```fish
# 1. env vars resolved (masked)
echo $MEMINI_MCP_URL
set -q MEMINI_MCP_BEARER; and echo "bearer: set ("(string length $MEMINI_MCP_BEARER)" chars)"

# 2. both channels know the server
./scripts/secrets-sync.py inventory | grep -i memini     # manifest rows present
grep -A4 '"memini"' dotfiles/dot_config/claude/mcp.json  # server block present

# 3. the endpoint actually answers with the token (200 on initialize; 401 without)
curl -s -o /dev/null -w '%{http_code}\n' -X POST "$MEMINI_MCP_URL" \
  -H "Authorization: Bearer $MEMINI_MCP_BEARER" \
  -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"probe","version":"1"}}}'

# 4. real proof: start a NEW claude session and confirm its mcp__memini__* tools are available.
#    (`claude mcp list` will NOT show it — --mcp-config servers never appear there.)
```

## Gotchas

- **`claude mcp add` is the wrong tool here.** It writes to `~/.claude.json` with the **literal**
  token — untracked, and it won't survive a redeploy. Use the three-artifact pattern above so the
  server is version-controlled and the secret stays in Bitwarden/age. (If you ever `claude mcp add`
  one by reflex, `claude mcp remove <name> -s user` and redo it the tracked way.)
- **Edited `mcp.json` but the server won't load?** It's a chezmoi *source* — Claude reads the
  *rendered* `~/.config/claude/mcp.json`. Run `chezmoi apply ~/.config/claude/mcp.json` (or
  `mise run apply`); `chezmoi diff ~/.config/claude/mcp.json` shows if they've drifted.
- **Fresh item invisible?** `bw sync` — the CLI caches the vault; `secrets-sync.py` syncs on unlock,
  but a manual `bw get` before that misses new items.
- **Half-applied = silent failure.** All three artifacts must agree. `./scripts/secrets-sync.py
  inventory` lists every managed var across both channels — the manifest *is* the source of truth.
- **`--mcp-config` servers are invisible to `claude mcp list`.** Judge success by whether the
  `mcp__<server>__*` tools load, not by the list.
- **Internal-only endpoints.** Servers like memini bind to a LAN-only route on purpose (its admin UI
  embeds the API key). They resolve/connect only on the home network or VPN — expect connect
  failures off-LAN, that's the trust boundary, not a misconfig.
