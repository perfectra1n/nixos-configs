#!/usr/bin/env bash
#
# wait-ci.sh — forge-agnostic "block until CI settles" for the shepherd-ci skill.
#
# Repeatedly calls ci-status.sh until the verdict is no longer PENDING, or a hard
# time cap is hit. Works on any forge because it only consumes ci-status.sh's
# normalized VERDICT line — no native watch required (gh's --watch is GitHub-only).
#
# Run this in the BACKGROUND from the skill loop so it never blocks the agent, and
# trust the hard cap: a stuck/queued pipeline can never wedge the loop forever.
#
# Usage:
#   wait-ci.sh [REF] [--interval SECONDS] [--timeout SECONDS]
#     REF         branch/PR ref passed through to ci-status.sh (default: current branch)
#     --interval  seconds between polls (default 60)
#     --timeout   hard cap in seconds (default 1800 = 30m); exits 124 like `timeout`
#
# Final line is the last VERDICT seen. Exit codes:
#   0   settled (GREEN | FAILING | NO_CI | UNKNOWN)
#   124 timed out while still PENDING (matches coreutils `timeout`)

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REF=""; INTERVAL=60; TIMEOUT=1800

while [ $# -gt 0 ]; do
  case "$1" in
    --interval) INTERVAL="$2"; shift 2 ;;
    --timeout)  TIMEOUT="$2";  shift 2 ;;
    *)          REF="$1";      shift ;;
  esac
done

deadline=$(( $(date +%s) + TIMEOUT ))
last=""
while :; do
  out="$("$HERE/ci-status.sh" $REF 2>/dev/null)"
  verdict="$(printf '%s' "$out" | grep '^VERDICT:' | tail -1)"
  last="$verdict"
  case "$verdict" in
    VERDICT:\ PENDING*)
      : ;;  # keep waiting
    *)
      printf '%s\n' "$out"
      exit 0 ;;
  esac
  if [ "$(date +%s)" -ge "$deadline" ]; then
    printf '%s\n' "$out"
    printf 'wait-ci: timed out after %ss still PENDING\n' "$TIMEOUT"
    exit 124
  fi
  sleep "$INTERVAL"
done
