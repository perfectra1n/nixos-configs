# `claude-cred` v3 — Python rewrite: setup tokens + exchange-at-use

Status: approved 2026-08-06. Supersedes the *implementation* described in the 2026-07-14 and
2026-07-23 specs; their **behavioral guarantees carry forward unchanged** and are re-stated here as
the test suite's contract.

## Problem

Three confirmed pains with the fish implementation:

1. **Dead refresh tokens.** Refresh tokens rotate; a profile goes stale whenever capture-on-swap
   doesn't happen perfectly (declined prompt, no TTY, another machine rotating the family). `use`
   splices the dead token blindly and the failure surfaces later, inside Claude Code, as
   "Not logged in" — a wedged session instead of an error.
2. **Unclear state.** Which profile is live, and whether a profile is healthy, requires running
   `doctor` and interpreting it.
3. **Pending-refresh limbo.** The placeholder mechanism's "start Claude Code to mint a token, then
   `claude-cred save`" two-step.

Separately, a large share of the 957-line fish function fights fish itself — command substitutions
dropping empty lines (one-jq-call-per-field), block scoping (`read --local` evaporation), globals as
return channels. Those hazards are structural to the language, not the problem domain.

## Decisions

- **Rewrite in Python, one shot.** Single stdlib-only file (`json`, `urllib.request`, `getpass`,
  `readline`, `argparse`). No `jq`/`curl` subprocesses — tokens never leave the process, retiring
  the whole never-on-argv hazard class. Packaged via `pkgs/claude-cred.nix`
  (`writers.writePython3Bin`, flake8-gated — the Python analog of the shell apps' shellcheck gate),
  exposed as `nix run .#claude-cred` and installed into PATH by `home/common.nix`. The fish function
  is deleted (source AND deployed copy — fish autoloaded functions shadow PATH binaries); the fish
  completions stay, updated for the new subcommands.
- **Exchange-at-use.** `use <name>` performs the OAuth refresh exchange *in-tool, before touching
  live credentials* — the swap becomes transactional. Success → full live creds (real access token,
  no placeholder, no limbo) and the rotated refresh token written back into the profile (profiles
  self-heal on every use). Definitively dead (HTTP 400/401/403) → abort with a clear reseed message,
  live creds untouched. Transient (network, 429, malformed 200) → today's placeholder splice, with
  the classified reason.
- **Setup-token profiles as equal citizens.** Profile v3 records `kind: "refresh" | "setup"`.
  Setup tokens (`claude setup-token`, `sk-ant-oat01-…`, ~1 year, **no rotation**) are stored via
  `add-setup-token` (silent paste or `--generate`) and consumed via `claude-cred run <name> [-- cmd…]`,
  which launches the child with `CLAUDE_CODE_OAUTH_TOKEN` set and **`ANTHROPIC_API_KEY` stripped**
  (a live API key in the env hijacks Claude Code auth — see the 2026-07-23 spec's hazard section).
  `use` on a setup-kind profile never touches `credentials.json`; it points at `run`.
- **Everything else ports 1:1**, including: email-verified identity as source of truth (`.active`
  is a prompt-default-only hint), capture-outgoing before any swap, mcpOAuth never touched,
  0600-before-content atomic writes, backup/undo (last 10), the rescue path
  (exchange-success/write-fail parks rotated tokens in a non-`.json` file), the anti-pollution
  overwrite guard, identity stickiness, offline/fixture modes (`CLAUDE_CRED_OFFLINE`,
  `CLAUDE_CRED_FILE`, `CLAUDE_CRED_ASSUME_TTY`), and the chezmoi `add --encrypt`/`re-add`
  round-trip with the public-repo git-add hint.

## Profile format v3

```json
{ "version": 3, "kind": "refresh", "email": "…", "accountUuid": "…", "organization": "…",
  "savedAt": "…", "claudeAiOauth": { … } }

{ "version": 3, "kind": "setup", "email": "…", "accountUuid": "…", "organization": "…",
  "savedAt": "…", "setupToken": "sk-ant-oat01-…" }
```

Detection stays structural (has `claudeAiOauth` / has `setupToken` / bare oauth = v1); a missing
`kind` means `refresh`. v1/v2 profiles remain readable forever and upgrade on next save. A setup
token IS a bearer token, so setup-kind profiles are identity-verifiable at any time — `doctor` can
always confirm ownership, which refresh tokens never allow (probing one consumes it).

## Command surface

```
show (default) · whoami · list · save [name] · use <name> · set-refresh [token]
add-setup-token [name] [--generate] · run <name> [-- cmd…] · doctor · undo
```

`set-refresh`'s access-token guard now disambiguates: an `sk-ant-oat01-…` paste is rejected with
"if this came from `claude setup-token`, run `claude-cred add-setup-token` instead".

## Testing

`scripts/claude_cred_test.py` (stdlib `unittest`, zero network — the HTTP transport is one
injectable function; fixture creds dirs via `CLAUDE_CRED_FILE`). Wired as a flake check like
`uncached-delta-selftest`, so `mise run verify` runs it. The guarantees under test (the carried-over
contract plus the new ones): mcpOAuth byte-for-byte preservation on every write path; placeholder
semantics (non-empty + `expiresAt: 0`); prefix guards before any side effect; exchange-at-use
abort-leaves-creds-byte-identical / success-rotates-both / transient-splices-placeholder; rescue
file never swept or restored; overwrite guard refuses non-interactively; identity stickiness;
v1/v2/v3 readability; 0600-from-birth and invalid-JSON refusal; non-TTY never hangs; undo verbatim;
`run` child env (token set, API key absent); rotated-refresh-token rule; 200-without-usable-fields
is a failure.

## Out of scope

Proactive migration of existing profiles (they upgrade on next save); changes to the `claude` fish
wrapper (mechanism unchanged); writing setup tokens into `credentials.json` (env-var launcher only).
