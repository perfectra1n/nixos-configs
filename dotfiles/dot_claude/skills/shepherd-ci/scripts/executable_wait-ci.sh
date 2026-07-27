#!/usr/bin/env bash
#
# wait-ci.sh — forge-agnostic "block until CI settles" for the shepherd-ci skill.
#
# Repeatedly calls ci-status.sh until the verdict is no longer PENDING, or a hard
# time cap is hit. Works on any forge because it only consumes ci-status.sh's
# normalized VERDICT line — no native watch required (gh's --watch is GitHub-only,
# and unreliable besides).
#
# Fail-fast: ci-status.sh already ranks FAILING above PENDING, so the moment one
# job fails this returns even with other jobs still running. You start fixing at
# the first failure instead of waiting out the longest job in the pipeline.
#
# Responsiveness: the poll interval is ADAPTIVE rather than fixed. Most failures
# (fmt, lint, fast unit suites) surface in the first couple of minutes, so poll
# tight then and relax afterwards — a 30-minute pipeline does not deserve 180
# polls, and a 40-second lint failure does not deserve a 60-second detection lag.
#
#   0-3 min   -> every 10s
#   3-10 min  -> every 20s
#   10 min+   -> every 45s
#
# Run this in the BACKGROUND from the skill loop so it never blocks the agent, and
# trust the hard cap: a stuck/queued pipeline can never wedge the loop forever.
#
# Usage:
#   wait-ci.sh [REF] [--interval SECONDS] [--timeout SECONDS] [--settle N]
#     REF         branch/PR ref passed through to ci-status.sh (default: current branch)
#     --interval  force a FIXED interval, disabling the adaptive ladder
#     --timeout   hard cap in seconds (default 1800 = 30m); exits 124 like `timeout`
#     --settle    consecutive identical verdicts required before returning GREEN or
#                 NO_CI (default 2). Guards the post-push window where jobs have not
#                 registered yet and an empty pipeline looks green.
#
# Final line is the last VERDICT seen. Exit codes:
#   0   settled (GREEN | FAILING | NO_CI | UNKNOWN)
#   124 timed out while still PENDING (matches coreutils `timeout`)
#
# Parse the VERDICT line, not $?.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REF=""; INTERVAL=""; TIMEOUT=1800; SETTLE=2

while [ $# -gt 0 ]; do
  case "$1" in
    --interval) INTERVAL="$2"; shift 2 ;;
    --timeout)  TIMEOUT="$2";  shift 2 ;;
    --settle)   SETTLE="$2";   shift 2 ;;
    # Header block verbatim, stopping at the first non-comment line.
    -h|--help)  awk 'NR>1 { if (/^#/) print; else exit }' "$0"; exit 0 ;;
    *)          REF="$1";      shift ;;
  esac
done

interval_for() {
  local e=$1
  [ -n "$INTERVAL" ] && { echo "$INTERVAL"; return; }
  if   [ "$e" -lt 180 ]; then echo 10
  elif [ "$e" -lt 600 ]; then echo 20
  else                        echo 45
  fi
}

start=$(date +%s)
deadline=$(( start + TIMEOUT ))
prev_verdict=""
repeat=0
pending_since=""
prev_pending=""

while :; do
  out="$("$HERE/ci-status.sh" $REF 2>/dev/null)"
  verdict="$(printf '%s' "$out" | grep '^VERDICT:' | tail -1)"
  kind="${verdict#VERDICT: }"; kind="${kind%% *}"
  elapsed=$(( $(date +%s) - start ))

  if [ "$verdict" = "$prev_verdict" ]; then repeat=$(( repeat + 1 )); else repeat=0; fi
  prev_verdict="$verdict"

  case "$kind" in
    PENDING)
      # A PENDING count that never moves is the signature of an unavailable
      # runner fleet rather than slow CI. Surface it instead of silently
      # burning the whole timeout window.
      count="$(printf '%s' "$verdict" | grep -o 'count=[0-9]*' | cut -d= -f2)"
      if [ "$count" = "$prev_pending" ]; then
        [ -z "$pending_since" ] && pending_since=$elapsed
        stuck=$(( elapsed - pending_since ))
        if [ "$stuck" -ge 600 ]; then
          printf 'wait-ci: t+%ss PENDING count=%s unchanged for %ss — check whether any runner is online.\n' \
            "$elapsed" "$count" "$stuck"
          pending_since=$elapsed   # warn at most once per 10-minute window
        fi
      else
        pending_since=""; prev_pending="$count"
      fi
      ;;
    FAILING)
      # Fail fast: act on the first failure, do not wait for the rest.
      printf '%s\n' "$out"
      exit 0
      ;;
    GREEN|NO_CI)
      # Jobs register progressively after a push, so a single green (or a single
      # "no runs found") can be the empty window before CI starts rather than a
      # real terminal state. Require the same verdict N times running.
      if [ "$repeat" -ge $(( SETTLE - 1 )) ]; then
        printf '%s\n' "$out"
        exit 0
      fi
      printf 'wait-ci: t+%ss %s (%s/%s confirmations) — reconfirming\n' \
        "$elapsed" "$kind" "$(( repeat + 1 ))" "$SETTLE"
      ;;
    *)
      # UNKNOWN and anything unrecognised: settled as far as we can tell.
      printf '%s\n' "$out"
      exit 0
      ;;
  esac

  if [ "$(date +%s)" -ge "$deadline" ]; then
    printf '%s\n' "$out"
    printf 'wait-ci: timed out after %ss still %s\n' "$TIMEOUT" "$kind"
    exit 124
  fi
  sleep "$(interval_for "$elapsed")"
done
