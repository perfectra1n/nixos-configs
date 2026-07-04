#!/usr/bin/env bash
#
# ci-status.sh — forge-agnostic CI snapshot for the shepherd-ci skill.
#
# Detects which git forge the current repo lives on (GitHub / Gitea / GitLab /
# unknown), resolves owner/repo/host/branch/head-sha WITHOUT leaking any
# credential embedded in the remote URL, then asks the matching adapter "what is
# CI doing for this commit?" and prints a normalized report ending in a single
# machine-readable VERDICT line the skill loop keys off of.
#
# Usage:
#   ci-status.sh [REF]
#     REF   optional branch/PR ref. Defaults to the current branch. On GitHub a
#           bare number is treated as a PR number.
#
# VERDICT contract (last line of output):
#   VERDICT: GREEN                         all runs for this head succeeded, none pending
#   VERDICT: FAILING count=<n> <names...>  >=1 run failed (act now; may also have pending)
#   VERDICT: PENDING count=<n>             runs still queued/running, none failed yet
#   VERDICT: NO_CI                         no CI runs found for this head (not configured / not triggered yet)
#   VERDICT: UNKNOWN <reason>              couldn't determine (no adapter, auth error, detached HEAD)
#
# Exit code mirrors the verdict class only loosely; parse the VERDICT line, not $?.
#
# Adapters are best-effort and degrade gracefully: if the forge's native CLI
# (gh/tea/glab) is missing or unauthenticated, the script falls back to the
# universal commit-status API when a token is discoverable, else UNKNOWN.

set -uo pipefail

REF="${1:-}"

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
have() { command -v "$1" >/dev/null 2>&1; }
say()  { printf '%s\n' "$*"; }
err()  { printf '%s\n' "$*" >&2; }

# Strip any user:pass@ credential and trailing .git from a remote URL, then emit
# "HOST\tOWNER/REPO". Handles both https and scp-style ssh remotes.
parse_remote() {
  local url="$1" host path
  case "$url" in
    ssh://*)
      # ssh://git@host[:port]/owner/repo(.git) — a colon here is a PORT, not the path.
      url="${url#ssh://}"
      url="${url#*@}"           # drop user@
      host="${url%%[:/]*}"      # up to first : or /
      path="${url#*/}"          # everything after the first / (drops any :<port>/)
      ;;
    git@*:*|*@*:*/*)
      # scp-style git@host:owner/repo(.git) — the colon IS the path separator.
      url="${url#*@}"           # drop user@
      host="${url%%:*}"
      path="${url#*:}"
      ;;
    http://*|https://*)
      url="${url#*://}"
      url="${url#*@}"           # drop any user:token@
      host="${url%%/*}"
      host="${host%%:*}"        # drop :port
      path="${url#*/}"
      ;;
    *)
      host=""; path="$url"
      ;;
  esac
  path="${path%.git}"
  path="${path%/}"
  printf '%s\t%s\n' "$host" "$path"
}

# ---------------------------------------------------------------------------
# resolve git context
# ---------------------------------------------------------------------------
if ! git rev-parse --git-dir >/dev/null 2>&1; then
  say "Not inside a git repository."
  say "VERDICT: UNKNOWN not_a_git_repo"
  exit 0
fi

REMOTE_URL="$(git remote get-url origin 2>/dev/null || true)"
if [ -z "$REMOTE_URL" ]; then
  # fall back to the first configured remote
  first_remote="$(git remote 2>/dev/null | head -1)"
  [ -n "$first_remote" ] && REMOTE_URL="$(git remote get-url "$first_remote" 2>/dev/null || true)"
fi

BRANCH="$REF"
if [ -z "$BRANCH" ]; then
  BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
fi
if [ "$BRANCH" = "HEAD" ] || [ -z "$BRANCH" ]; then
  say "Detached HEAD or no branch; pass a REF explicitly."
  say "VERDICT: UNKNOWN detached_head"
  exit 0
fi

HEAD_SHA="$(git rev-parse HEAD 2>/dev/null || true)"

HOST=""; SLUG=""
if [ -n "$REMOTE_URL" ]; then
  IFS=$'\t' read -r HOST SLUG < <(parse_remote "$REMOTE_URL")
fi
OWNER="${SLUG%%/*}"
REPO="${SLUG#*/}"

# ---------------------------------------------------------------------------
# detect forge
# ---------------------------------------------------------------------------
# github.com or a GitHub Enterprise host gh is authenticated against -> github
# host listed in `tea logins` -> gitea
# host contains gitlab, or glab knows it -> gitlab
# else unknown (universal commit-status fallback if a token exists)
FORGE="unknown"
case "$HOST" in
  github.com|*.github.com) FORGE="github" ;;
  gitlab.com|*.gitlab.*|gitlab.*) FORGE="gitlab" ;;
esac

if [ "$FORGE" = "unknown" ] && have tea; then
  if tea logins list 2>/dev/null | grep -qiF "$HOST"; then
    FORGE="gitea"
  fi
fi
if [ "$FORGE" = "unknown" ] && have gh; then
  # gh knows about GHE hosts it's logged into
  if gh auth status 2>&1 | grep -qiF "$HOST"; then
    FORGE="github"
  fi
fi
if [ "$FORGE" = "unknown" ] && have glab; then
  if glab auth status 2>&1 | grep -qiF "$HOST"; then
    FORGE="gitlab"
  fi
fi

say "repo:    ${SLUG:-<unknown>}"
say "host:    ${HOST:-<none>}"
say "forge:   $FORGE"
say "branch:  $BRANCH"
say "head:    ${HEAD_SHA:0:12}"
say ""

# ---------------------------------------------------------------------------
# adapters
# ---------------------------------------------------------------------------
adapter_github() {
  if ! have gh; then err "gh not installed"; return 3; fi
  if ! gh auth status >/dev/null 2>&1; then err "gh not authenticated"; return 3; fi

  # PR-number ref? use pr checks; else use run list for the branch head.
  local runs
  runs="$(gh run list --branch "$BRANCH" --limit 40 \
            --json databaseId,workflowName,status,conclusion,headSha 2>/dev/null || true)"
  if [ -z "$runs" ] || [ "$runs" = "[]" ]; then return 2; fi

  # Keep only runs for the current head SHA (or all if head unknown).
  local filtered
  filtered="$(printf '%s' "$runs" | jq -c --arg sha "$HEAD_SHA" \
    'map(select($sha=="" or .headSha==$sha))')"
  if [ "$filtered" = "[]" ]; then return 2; fi

  local failing pending
  failing="$(printf '%s' "$filtered" | jq -r \
    '.[] | select(.conclusion=="failure" or .conclusion=="timed_out" or .conclusion=="startup_failure") | "\(.databaseId)\t\(.workflowName)"')"
  pending="$(printf '%s' "$filtered" | jq -r \
    '.[] | select(.status!="completed") | .workflowName')"

  if [ -n "$failing" ]; then
    say "FAILING runs (id  workflow):"
    printf '%s\n' "$failing" | sed 's/^/  /'
    say ""
    say "Fetch failed logs:  gh run view <id> --log-failed"
    local names; names="$(printf '%s' "$failing" | cut -f2 | paste -sd, -)"
    local n;     n="$(printf '%s\n' "$failing" | grep -c .)"
    say "VERDICT: FAILING count=$n $names"
    return 0
  fi
  if [ -n "$pending" ]; then
    local n; n="$(printf '%s\n' "$pending" | grep -c .)"
    say "PENDING runs:"; printf '%s\n' "$pending" | sort -u | sed 's/^/  /'
    say "VERDICT: PENDING count=$n"
    return 0
  fi
  say "VERDICT: GREEN"
  return 0
}

adapter_gitea() {
  if ! have tea; then err "tea not installed"; return 3; fi

  # This tea/Gitea version's JSON has no commit-SHA field and reports every
  # finished run's `status` as "completed" (no success/failure conclusion). The
  # real conclusion is only reachable via the server-side `--status` filter, and
  # an empty result prints plaintext (not "[]"). So: anchor to the newest run id
  # on the branch, then ask the server which recent runs failed / are pending /
  # succeeded. WINDOW covers the several runs a single push fans out into.
  local WINDOW=8
  # tea_runs <extra-args...> -> prints a JSON array ("[]" if tea returned no JSON)
  tea_runs() {
    local out
    out="$(tea actions runs list --branch "$BRANCH" --remote origin --limit 40 \
             --output json "$@" 2>/dev/null || true)"
    case "$out" in
      \[*|\{*) printf '%s' "$out" ;;
      *)       printf '[]' ;;
    esac
  }
  # newest run id on the branch (across all statuses)
  local latest_id
  latest_id="$(tea_runs | jq -r '(if type=="array" then . else (.workflowRuns // .runs // []) end) | (.[0].id // .[0].index // 0) | tonumber? // 0' 2>/dev/null)"
  latest_id="${latest_id:-0}"
  if [ "$latest_id" -eq 0 ]; then return 2; fi
  local floor=$(( latest_id > WINDOW ? latest_id - WINDOW : 0 ))

  # runs of a given conclusion whose id is within [floor, latest_id]
  gitea_pick() {  # $1=status filter
    tea_runs --status "$1" | jq -r --argjson f "$floor" '
      (if type=="array" then . else (.workflowRuns // .runs // []) end)[]
      | ((.id // .index // 0) | tonumber? // 0) as $i
      | select($i >= $f)
      | "\(.id // .index)\t\(.workflow // .name // .displayTitle // "run")"' 2>/dev/null || true
  }

  local failing pending
  failing="$(gitea_pick failure)"
  if [ -n "$failing" ]; then
    say "FAILING runs (id  title):"
    printf '%s\n' "$failing" | sed 's/^/  /'
    say ""
    say "Fetch logs:  tea actions runs logs <id> --remote origin   (add --job <id> to scope)"
    say "View jobs:   tea actions runs view <id> --jobs --remote origin"
    local names; names="$(printf '%s' "$failing" | cut -f2 | paste -sd, -)"
    local n;     n="$(printf '%s\n' "$failing" | grep -c .)"
    say "VERDICT: FAILING count=$n $names"
    return 0
  fi
  pending="$( { gitea_pick pending; gitea_pick queued; gitea_pick in_progress; } | sort -u)"
  if [ -n "$pending" ]; then
    local n; n="$(printf '%s\n' "$pending" | grep -c .)"
    say "PENDING runs (id  title):"; printf '%s\n' "$pending" | sed 's/^/  /'
    say "VERDICT: PENDING count=$n"
    return 0
  fi
  # newest run is neither failing nor pending -> the branch head is green.
  if [ -n "$(gitea_pick success)" ]; then
    say "VERDICT: GREEN"
    return 0
  fi
  return 2
}

adapter_gitlab() {
  if ! have glab; then err "glab not installed"; return 3; fi
  local out
  out="$(glab ci status --branch "$BRANCH" 2>/dev/null || glab ci list --branch "$BRANCH" 2>/dev/null || true)"
  if [ -z "$out" ]; then return 2; fi
  say "$out"
  say ""
  say "Inspect:  glab ci view --branch $BRANCH   |   trace a job:  glab ci trace"
  if printf '%s' "$out" | grep -qiE 'failed'; then
    local names; names="$(printf '%s' "$out" | grep -iE 'failed' | sed 's/^[[:space:]]*//' | paste -sd, -)"
    say "VERDICT: FAILING count=1 ${names:-pipeline}"
    return 0
  fi
  if printf '%s' "$out" | grep -qiE 'running|pending|created|manual|scheduled'; then
    say "VERDICT: PENDING count=1"
    return 0
  fi
  if printf '%s' "$out" | grep -qiE 'success|passed'; then
    say "VERDICT: GREEN"
    return 0
  fi
  return 2
}

# Universal fallback: combined commit-status API. Works for any forge that
# implements the GitHub/Gitea-style status endpoint, provided a token is
# discoverable from the environment (no token is ever printed).
adapter_commit_status() {
  [ -n "$HOST" ] && [ -n "$OWNER" ] && [ -n "$REPO" ] && [ -n "$HEAD_SHA" ] || return 3
  have curl || return 3

  local token="" base path auth=()
  # Gitea/GitHub-style API bases + endpoints.
  case "$FORGE" in
    gitea)
      token="${GITEA_TOKEN:-${TEA_TOKEN:-}}"
      base="https://$HOST/api/v1"
      path="/repos/$OWNER/$REPO/commits/$HEAD_SHA/status"
      ;;
    github)
      token="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
      base="https://api.github.com"; [ "$HOST" != "github.com" ] && base="https://$HOST/api/v3"
      path="/repos/$OWNER/$REPO/commits/$HEAD_SHA/status"
      ;;
    *)
      # best guess: try Gitea layout (most self-hosted forges the user hits)
      token="${FORGE_TOKEN:-${GITEA_TOKEN:-}}"
      base="https://$HOST/api/v1"
      path="/repos/$OWNER/$REPO/commits/$HEAD_SHA/status"
      ;;
  esac
  [ -n "$token" ] && auth=(-H "Authorization: token $token")

  local json
  json="$(curl -fsSL "${auth[@]}" "$base$path" 2>/dev/null || true)"
  [ -n "$json" ] || return 3

  local state
  state="$(printf '%s' "$json" | jq -r '.state // .status // empty' 2>/dev/null)"
  case "$state" in
    success) say "commit status: success"; say "VERDICT: GREEN"; return 0 ;;
    pending) say "commit status: pending"; say "VERDICT: PENDING count=1"; return 0 ;;
    failure|error)
      say "commit status: $state"
      printf '%s' "$json" | jq -r '(.statuses // [])[] | select(.state=="failure" or .state=="error") | "  \(.context): \(.target_url // "")"' 2>/dev/null
      say "VERDICT: FAILING count=1 commit-status"
      return 0 ;;
    *) return 3 ;;
  esac
}

# ---------------------------------------------------------------------------
# dispatch
# ---------------------------------------------------------------------------
rc=2
case "$FORGE" in
  github) adapter_github; rc=$? ;;
  gitea)  adapter_gitea;  rc=$? ;;
  gitlab) adapter_gitlab; rc=$? ;;
esac

# If the native adapter couldn't answer (rc 2=no runs, rc 3=no tool/auth), try
# the universal commit-status fallback before giving up.
if [ "$rc" -ne 0 ]; then
  if adapter_commit_status; then
    exit 0
  fi
fi

if [ "$rc" -eq 2 ]; then
  say "No CI runs found for this head via the $FORGE adapter."
  say "VERDICT: NO_CI"
  exit 0
fi
if [ "$rc" -eq 3 ]; then
  say "No usable adapter for forge='$FORGE' host='$HOST' (missing/unauthenticated CLI, no token)."
  say "VERDICT: UNKNOWN no_adapter"
  exit 0
fi
exit 0
