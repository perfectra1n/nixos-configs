# Disable per-turn capture. The plugin's Stop hook (plugin/scripts/stop.mjs)
# otherwise POSTs every user->assistant turn to the server as an episodic
# "turn-capture" memory. That only pays off when the server has a chat LLM to
# distill turns into facts and drop the residue ("drop-when-no-fact") — but our
# memini deployment is embeddings-only (qwen3-embedding via ollama-proxy, no
# MEMINI_LLM_*), so captured turns just sit for their 30-day TTL and get
# vector-searched into recall. Measured 2026-07-10: 86% of turn captures were
# never recalled, and the highest-access ones were <task-notification> noise.
# This is a CLIENT-side hook var (the Go server never reads it), non-secret, so
# it lives here next to MEMINI_NAMESPACE. Re-enable by removing this / setting 1
# once an LLM is wired up for distillation.
set -gx MEMINI_CAPTURE_TURNS 0
