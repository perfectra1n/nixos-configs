# `claude-cred` — swap Claude Code credentials from fish

**Date:** 2026-07-14
**Status:** implemented — `dotfiles/dot_config/fish/functions/claude-cred.fish`
(+ completions, + three `.chezmoiignore` entries)

## Problem

`~/.claude/.credentials.json` (mode `0600`) holds the Claude Code login. Swapping accounts
today means hand-editing that file, which is easy to get wrong in ways that fail silently.
We want a fish command that injects a provided refresh token, snapshots the account it
replaces, and can switch back.

The file has two independent top-level sections:

| Section | Contents | Relationship to the Claude login |
| --- | --- | --- |
| `claudeAiOauth` | `accessToken`, `refreshToken`, `expiresAt`, `refreshTokenExpiresAt`, `scopes`, `subscriptionType`, `rateLimitTier` | **This is the login.** The only thing we touch. |
| `mcpOAuth` | per-MCP-server tokens, keyed `plugin:name\|hash` (currently Datadog, memini) | Unrelated to which Claude account you are. **Never touched.** |

## Why the naive swap is wrong

Three fields make "just replace the refresh token" produce a working-looking but incorrect
state. Each is a silent failure:

1. **`accessToken` outlives the swap** — but must NOT be blanked. It stays valid until `expiresAt`,
   so leaving the old one means Claude Code keeps talking to the API as the *old* account. The
   obvious fix — set it to `""` — is **wrong**, and shipping it caused a real
   `Not logged in · Please run /login`. CC's credential getter is:

   ```js
   let o = read()?.claudeAiOauth;
   if (o?.accessToken) return o;   // empty string is falsy
   return null;                     // → "Not logged in"
   ```

   An empty `accessToken` reads as *"no credentials at all"*, and CC never looks at the refresh
   token. The dispatch below it is:

   ```js
   if (accessToken && expiresAt && expiresAt > Date.now())        → use the access token
   else if (refreshToken && checkAndRefreshOAuthTokenIfNeeded())  → REFRESH   ← the goal
   ```

   `expiresAt = 0` is already falsy, so it alone fails the "use it" test and falls through to the
   refresh branch. The access token therefore only needs to be **non-empty and dead**.
   → We write a placeholder (`sk-ant-oat01-PENDING-REFRESH-claude-cred`) and set `expiresAt = 0`.
   The placeholder is never sent (the expiry check rejects it first), and if some path ever did send
   it, a 401 beats silently authenticating as the wrong account.

2. **`refreshTokenExpiresAt` belongs to the outgoing account.** Leave it and you've paired
   token B with account A's expiry clock; if that timestamp is in the past, Claude Code can
   decide you're logged out before it ever tries the new token. A bare refresh token tells us
   nothing about its own expiry, so we **delete the key** and let the refresh response
   repopulate it.

3. **`mcpOAuth` is collateral damage of any whole-file rewrite.** A `jq` filter that rebuilds
   the document instead of patching `.claudeAiOauth` will drop the Datadog/memini tokens.

### Refresh-token rotation

We assume Anthropic rotates the refresh token on each refresh (OAuth 2.1 standard practice;
the distinct `refreshTokenExpiresAt` field implies they track it). If so, a profile saved at
time T is **stale the moment that account is next used**, and a naive profile store slowly
fills with dead tokens.

**Mitigation, and a load-bearing part of this design:** `use <name>` re-saves the *outgoing*
account before splicing in the incoming one. Switching is therefore atomic — capture whatever
token the active account currently holds (rotated or not), swap in the new one, record the new
active profile. Rotation stops being something the user has to remember. It also means the
encrypted blobs accumulating in git history are *superseded* tokens, which shrinks the blast
radius if the age key ever leaked.

Rotation itself is **not** verified — but the refresh token's lifetime is: an observed live login
had `expiresAt` ~3h out and `refreshTokenExpiresAt` **~4 weeks** out. That gap is what makes the
`refreshTokenExpiresAt` deletion load-bearing: carrying a stale one across a swap can easily leave a
timestamp in the past. If Anthropic turns out *not* to rotate refresh tokens, the design still holds
— the outgoing re-save is simply a no-op write.

## Ownership decisions

Both follow from CLAUDE.md's decision tree rather than from taste.

**A chezmoi fish function, not a flake app.** `dotfiles/dot_config/fish/functions/claude-cred.fish`.
CLAUDE.md: all other `~/.config/*` user config → chezmoi. The standing preference for flake apps
covers *repo ops tooling* (`gen-manifests`, `secrets-sync`) — things that operate on this repo. This
operates on `~/.claude` on whatever box you're on, wants autoloading and completions, and would
otherwise need a `git add` + rebuild per tweak. It sits next to `reload-secrets.fish`, the same
species of tool.

**chezmoi + age, not sops.** `modules/dotfiles.nix`: *"User secrets stay age-encrypted at rest in
./dotfiles; system secrets stay in sops-nix."* Claude profiles are a user secret consumed by a user
shell function, not a NixOS module reading `/run/secrets`. chezmoi has no sops backend anyway
(`.chezmoi.config.encryption` = `age`), and the age identity **is the same key as sops-nix**, so
nothing is lost. Routing profiles through sops would mean a `secrets/claude-profiles.yaml` that Nix
never reads — sops-shaped, load-bearing nowhere.

**Applied to `$HOME`, matching the existing model.** All three existing encrypted secrets
(`dot_talos/encrypted_private_config.age`, `private_dot_kube/encrypted_private_config.age`,
`dot_config/fish/fishconfig.d/encrypted_private_secrets.fish.age`) are encrypted in source and
**applied** by chezmoi into `$HOME` as plaintext `0600`; `chezmoi managed` confirms it. A
ciphertext-only store that chezmoi never materializes was considered and rejected: it would be a
fourth secret-handling model in this repo, invented to avoid an exposure already accepted for the
kubeconfig and Talos config.

## Data model

Two concepts, deliberately not merged.

### Profiles — named accounts, encrypted, portable

Store **only the `claudeAiOauth` object**, never the whole file, so a restore can never roll back
`mcpOAuth` to stale Datadog/memini tokens.

```
dotfiles/dot_claude/private_cred-profiles/encrypted_private_<name>.json.age
        │           │                     │
        │           │                     └─ age-encrypted at rest; public-repo safe
        │           └─ 0700 directory (mirrors private_dot_kube)
        └─ already exists (settings.json, skills/)

        ↓ chezmoi apply

~/.claude/cred-profiles/<name>.json     0600, plaintext, one claudeAiOauth object
~/.claude/cred-profiles/.active         name of the profile currently live (chezmoi-ignored)
```

`save`/`use` go through chezmoi's own mechanisms — `chezmoi add --encrypt` for a new profile,
`chezmoi re-add` to update an existing one. No shelling out to `age`, no temp plaintext outside
the target path.

### Auto-backups — local undo buffer

`~/.claude/cred-backups/<utc-timestamp>.json`, mode `0600` in a `0700` dir. **Verbatim copies of
the entire file** (including `mcpOAuth`) taken before *any* mutation. Being verbatim is the point:
this is the "oh no" button and `undo` restores byte-for-byte. Keep the last 10. Never committed,
never chezmoi-managed — pure churn.

## Commands

```
claude-cred show                # active account, redacted: token fingerprints, expiry as a date
claude-cred set-refresh [token] # inject a refresh token; prompts silently if omitted
claude-cred save [name]         # snapshot current claudeAiOauth as a profile (default: active)
claude-cred use <name>          # re-save outgoing account, splice in <name>, mark it active
claude-cred list                # profiles (+ which is active) and recent backups
claude-cred undo                # restore the most recent auto-backup, verbatim
```

`set-refresh` writes:

```
.claudeAiOauth.refreshToken      = <new token>
.claudeAiOauth.accessToken       = "sk-ant-oat01-PENDING-REFRESH-claude-cred"
                                           # NON-EMPTY (empty ⇒ CC reports "Not logged in") but dead
.claudeAiOauth.expiresAt         = 0       # falsy ⇒ fails the "use it" test ⇒ CC refreshes
del(.claudeAiOauth.refreshTokenExpiresAt)  # unknown for B; the refresh response will set it
# mcpOAuth, scopes, subscriptionType, rateLimitTier: untouched
```

`use <name>` applies the same normalization: a restored profile whose `accessToken` is empty gets the
placeholder instead. (A profile's *expired* access token needs no special handling — non-empty plus a
past expiry is exactly the state that routes CC to the refresh branch.)

## Guard rails

**Secrets must not leak into fish history.** `claude-cred set-refresh sk-ant-ort01-…` writes the
token verbatim into `~/.local/share/fish/fish_history`, in plaintext, forever. So the argument is
**optional**: bare `set-refresh` prompts via `read --silent`, which never touches history. An inline
argument still works (for scripting) but warns that the token was just logged.

**A running Claude Code does NOT clobber the swap** — an earlier draft of this spec claimed it did,
and blocked on `pgrep -x claude` with a confirmation prompt. That was wrong, and reading the shipped
CC binary (2.1.209) disproves it:

- every credential write goes through `mutate(u => ({...u, claudeAiOauth: {…}}))` — a
  read-modify-write against the *current* file, so unrelated keys (`mcpOAuth`) are preserved;
- the invalid-grant path is a **compare-and-swap**: `if (y.refreshToken !== c) return g` — it
  explicitly declines to write when the on-disk token is no longer the one it was holding;
- there is cache invalidation plus a path that notices the on-disk `accessToken` differs from its
  in-memory copy and adopts the newer one;
- writes land via `renameSync` (atomic).

That is a credential store built for concurrent sessions — as it must be, since several `claude`
processes routinely share this one file. Blocking on it was noise, and it fired on every single
invocation for anyone who keeps Claude Code open.

What remains true, and is what the tool now prints as a **non-blocking note**: a session that is
already running keeps using the OLD account's in-memory access token until it refreshes or restarts.
The swap is on disk; the running process simply hasn't noticed. **Restart Claude Code to pick it up.**

**Atomic, never-world-readable writes.** Write to a temp file *in the same directory*, `touch`ed and
`chmod 600`'d **before** any content lands in it (a redirect into an existing file does not reset its
mode), then `mv -f` — an atomic rename within one filesystem. There is no instant where the refresh
token is world-readable, and no partial-write state where the file is invalid JSON.

**Validation.** Refuse to run if `.credentials.json` is missing, is not valid JSON, or has no
`.claudeAiOauth` — with a message pointing at `claude` login, not a jq stack trace. Warn (do not
hard-fail) if the token does not look like `sk-ant-ort01-…`; that prefix is Anthropic's to change.

**`CLAUDE_CRED_FILE`** overrides the target path, purely so the whole thing is testable against a
fixture instead of live credentials.

**Git churn is the user's call.** Every `save`/`use` dirties `dotfiles/`, and per CLAUDE.md a *new*
profile is invisible to the flake until `git add`. The script prints the commit command; it does
**not** commit. This is a public repo — the human decides when tokens land in history.

## `.chezmoiignore` additions

Under the existing *"Credential-bearing tool state"* block:

```
.claude/.credentials.json      # live, rotating — the tool owns this; must never be committed
.claude/cred-backups           # local undo buffer, pure churn
.claude/cred-profiles/.active  # per-machine pointer; boxes can be on different accounts
```

The first is independently worth having: today a stray `chezmoi add ~/.claude` would commit live
tokens to a public repo.

## Testing

Drive the function against a fixture via `CLAUDE_CRED_FILE`, asserting the failures that would
otherwise be silent:

- `set-refresh` leaves `mcpOAuth` byte-for-byte identical
- `set-refresh` sets `refreshToken`, blanks `accessToken`, sets `expiresAt = 0`, and removes
  `refreshTokenExpiresAt`
- the credentials file is still mode `0600` afterwards, and still valid JSON
- `save` → `set-refresh` → `use` round-trips the original `claudeAiOauth` back exactly
- `use` re-saves the outgoing account (the rotation guard) before swapping
- `undo` restores the pre-mutation file verbatim
- a missing / malformed / `claudeAiOauth`-less file produces a clear error, not a jq trace

## Out of scope

- Managing `mcpOAuth` entries (Datadog/memini re-auth through their own OAuth flows).
- Obtaining refresh tokens. The script consumes a token you already have; it does not log in.
- Encrypting the live `.credentials.json`. Claude Code owns that file and expects plaintext.
