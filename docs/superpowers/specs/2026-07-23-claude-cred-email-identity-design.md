# `claude-cred` v2 — email-verified identity

**Date:** 2026-07-23
**Status:** implemented — supersedes the identity-blind parts of
[2026-07-14-claude-cred-swap-design.md](2026-07-14-claude-cred-swap-design.md); everything that
spec says about atomic writes, mcpOAuth preservation, the placeholder access token, backups,
chezmoi + age ownership, and `.chezmoiignore` still holds and is not repeated here.

## Problem — the 2026-07-22 incident

Two flaws compounded into scrambled profiles and a forced re-login:

1. **`set-refresh` accepted a wrong-type token with only a warning.** An `sk-ant-oat01-…`
   *access* token was passed where an `sk-ant-ort01-…` *refresh* token belongs. The function
   noted the odd prefix and wrote it anyway; Claude Code then tried to use an access token as a
   refresh token, failed, and reported "Not logged in".
2. **Every mutation silently saved the live login into whatever `.active` named.**
   `__claude_cred_capture_active` trusted a *local pointer file* to know *which account* is live.
   Pointers go stale; tokens don't lie. Two capture events wrote two different accounts' tokens
   into profiles chosen only by pointer state, so profile *names* stopped matching their
   *accounts* — and there was no way to tell, because a profile was just a bare token blob.

Root cause, generalized: **the tool had no concept of account identity.** Fix: make the email
address the source of truth, verified against Anthropic's own API whenever a usable access token
exists, and never write a profile whose identity can't be either verified or explicitly
confirmed by the human.

## Verified API facts (tested live 2026-07-23)

- `GET https://api.anthropic.com/api/oauth/profile` with headers
  `Authorization: Bearer <accessToken>` and `anthropic-beta: oauth-2025-04-20` returns
  `.account.email`, `.account.uuid`, `.account.has_claude_max` / `has_claude_pro`,
  `.organization.name`, and `.application.uuid = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"` —
  Claude Code's own OAuth client_id (a public identifier shipped in the CC binary).
  Expired/revoked token → 401.
- `GET …/api/oauth/usage` (same headers) returns rate-limit utilization only — **no identity**.
  Not used.
- Token exchange: `POST https://console.anthropic.com/v1/oauth/token` with JSON body
  `{"grant_type":"refresh_token","refresh_token":…,"client_id":"9d1c250a-…"}` →
  `{access_token, refresh_token, expires_in, scope?}`. The returned `refresh_token` is the
  **rotated** one — writing the injected token after a successful exchange would store a token
  the server may already have retired. Endpoint is unofficial: every caller must degrade
  gracefully to the placeholder mechanism when it fails. **Endpoint + request shape confirmed
  live 2026-07-23** (a malformed-token / throttled request returns a well-formed
  `{"error":{"type":…}}`, proving the route parses our body); the exchange is rate-limited
  per-client with HTTP 429, distinct from the account's usage cap.

  Because 429 (retry) and 400/`invalid_grant` (dead token, reseed) demand opposite user actions,
  `__claude_cred_oauth_refresh` does **not** use `curl --fail` — it reads the HTTP status and error
  body and classifies the failure into `$__claude_cred_exchange_reason`, which the fallback message
  surfaces verbatim.

## Decisions

- **A — hard-reject wrong tokens.** `set-refresh` validates the prefix *before any side effect*
  (no capture, no backup, no write). `sk-ant-oat01-…` gets a targeted error ("that's an ACCESS
  token — copy the `refreshToken` field from the source machine's
  `~/.claude/.credentials.json`"); anything else non-`ort01` is rejected generically. The prefix
  is Anthropic's to change — but post-incident, re-editing this file beats accepting a
  wrong-type token. No `set-access` command.
- **B — verify the outgoing login, else prompt; never silently trust `.active`.**
  Replacing `capture_active`: identify the outgoing account via `/api/oauth/profile`. Email
  matches exactly one profile's stored email → auto-save there (announced — correct by
  construction). Token expired / offline / no match → interactive prompt with a *default
  suggestion* (`.active` or the email localpart), empty answer = skip. Non-TTY → skip with a
  warning; never hang, never guess.
- **C — `set-refresh` logs in fully when online.** It performs the token exchange itself: real
  `accessToken`, **rotated** `refreshToken`, computed `expiresAt`, then resolves the email and
  matches/prompts the profile name on the spot. Exchange failure → the 2026-07-14 placeholder +
  `expiresAt = 0` fallback, `.active` cleared, name resolved later at `save`.
- **D — `doctor` + guided repair.** A strictly read-only audit that labels each profile with the
  identity its token can prove, cross-checks against the live login, and flags an unsaved live
  login or a stale `.active`.

## Profile format v2

```json
{
  "version": 2,
  "email": "alice@example.com",
  "accountUuid": "…",
  "organization": "…",
  "savedAt": "2026-07-23T18:00:00Z",
  "claudeAiOauth": { }
}
```

- Identity fields are `null` when saved offline with nothing known. Emails/uuids live **only**
  inside these files — age-encrypted in the repo, `0600` plaintext locally — never elsewhere in
  git (public repo).
- **Detection is structural, everywhere:** `has("claudeAiOauth")` → v2, else v1 (a bare
  `claudeAiOauth` object). The `version` field exists for future migrations; nothing keys off it.
- `save` always writes v2, so touching a v1 profile upgrades it. An offline re-save of a v2
  profile **carries the previous identity fields over** (identity is sticky; `doctor` catches
  drift) but refreshes `savedAt`.
- `use` splices only the `claudeAiOauth` part; metadata never reaches `.credentials.json`.

## Command semantics (changes only)

| Command | Change |
| --- | --- |
| `set-refresh [token]` | Hard validation first (decision A). Then: capture outgoing (B) → backup → exchange (C). On exchange success: write full real creds, resolve email, save/match profile, set `.active`. On failure: placeholder fallback, clear `.active`. Non-TTY with no arg → error, never hangs. |
| `use <name>` | Capture outgoing (B) *before* the already-active check, which now keys on the **verified email**, not `.active` (offline keeps the cheap `.active` early-return, annotated). Splice is v1/v2-aware. No exchange on the incoming side — CC's refresh branch handles a stale access token, and `use` must stay offline-capable. |
| `save [name]` | Name resolution: verified email matching exactly one profile → that name, no prompt; no match → prompt with localpart suggestion; unverifiable → prompt with `.active` default. **Mismatch guard:** overwriting a v2 profile whose stored email differs from the live verified email requires interactive confirmation (non-TTY refuses). Writes v2. Internally accepts a pre-fetched identity JSON so callers don't double-fetch. |
| `show` | New `account:` line — skips the network when the access token is the placeholder or past expiry ("restart Claude Code to refresh"), otherwise live-verifies. |
| `list` | Shows each profile's stored email; v1 profiles show "(unknown — re-save to record identity)". |
| `whoami` *(new)* | Live identity, scriptable exit code. |
| `doctor` *(new)* | Read-only: live identity; per-profile format/email/savedAt/mode checks; live-verifies only profiles whose stored access token is non-placeholder and unexpired (flags stored-vs-verified mismatch); cross-checks live email ↔ profiles ↔ `.active`. |

### `set-refresh` failure containment

Capture and backup both precede any write, so an abort at any pre-write step costs nothing and
everything after the backup is `undo`-recoverable. One new edge: if the creds **write** fails
*after* a successful exchange, the rotated refresh token exists only in memory — losing it can
strand the account. The tool writes a rescue file (`cred-backups/rescue-<ts>.json`, `0600`,
minted `claudeAiOauth` object) and says so; only if that also fails does it print the token to
stderr with a banner (a TTY echo is not fish history; losing the token is worse).

## Hazard: never mint via `claude -p` when `ANTHROPIC_API_KEY` is set

Do **not** try to refresh a swapped-in login by launching `claude -p …`. When `ANTHROPIC_API_KEY`
is present in the environment, headless Claude Code takes the API-key auth path instead of OAuth;
if that key is rejected it **rewrites `~/.claude/.credentials.json` and drops the entire
`.claudeAiOauth` section** (leaving only `mcpOAuth`), bricking the login. Recover with
`claude-cred undo`. This is exactly why `set-refresh` performs the exchange itself with curl
(decision C): the tool's self-exchange is independent of `ANTHROPIC_API_KEY` and never hands the
file to a process that might clear it.

## Offline / test-mode semantics

- `CLAUDE_CRED_FILE` (fixture mode) now also forces **offline**: tests never hit the network and
  deterministically exercise every fallback/prompt path.
- `CLAUDE_CRED_OFFLINE=1` — airplane-mode escape hatch for live use.
- `CLAUDE_CRED_ASSUME_TTY=1` — bypasses the isatty guard so tests can pipe prompt answers.
- Every prompt is isatty-guarded: non-interactive callers get a skip-with-warning (captures) or a
  hard error (token entry), never a hang.
- Tokens never appear on a process command line: the Authorization header travels via
  `curl --config -` and the exchange body via `curl --json @-`, both fed from fish builtins.

## Testing

Offline suite against a `CLAUDE_CRED_FILE` fixture (fake tokens, sentinel `mcpOAuth`):

- `set-refresh` with an `oat01`/garbage token → hard error, file checksum unchanged, **no backup
  created** (validation precedes side effects)
- `set-refresh` with an `ort01` token (offline ⇒ fallback path) → placeholder + `expiresAt = 0`,
  `refreshTokenExpiresAt` deleted, `mcpOAuth` byte-identical, mode `0600`, `.active` cleared
- `save` → v2 shape with null identity; v1 profile `use` → splice + placeholder normalization;
  `save a` → `use p0` → `use a` round-trips `claudeAiOauth` exactly (`jq -S`)
- `doctor` makes zero writes (tree checksum before/after); `undo` restores byte-for-byte
- non-TTY: `use` completes with the not-saved warning; bare `set-refresh` errors — neither hangs

Live read-only: `show` / `whoami` / `doctor` against the real `~/.claude`, verifying no file
changes.

## Out of scope

- `use` performing the exchange for the incoming account (offline-capable switching matters
  more; CC refreshes on next launch anyway).
- A `rename`/`rm` subcommand for profiles (plain `rm` + `chezmoi forget` suffices).
- Managing `mcpOAuth`, obtaining first refresh tokens, encrypting the live `.credentials.json` —
  unchanged from the 2026-07-14 spec.
