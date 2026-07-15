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
set -gx MEMINI_SESSION_DIGEST 0
# Namespace prefix follows the working directory: Atvik work memories must land
# under the "atvik" tree, everything else under "jon/dev". conf.d only runs at
# shell startup, so a static set can't track cd — hook PWD instead. -gx (not -Ux)
# so each shell derives its own value and tmux-inherited stale globals get
# overwritten (same rationale as the secret env vars).
function __memini_namespace_prefix --on-variable PWD
    switch $PWD
        case "$HOME/repos/AtvikSecurity" "$HOME/repos/AtvikSecurity/*"
            set -gx MEMINI_NAMESPACE_PREFIX "atvik"
        case '*'
            set -gx MEMINI_NAMESPACE_PREFIX "jon/dev"
    end
end
__memini_namespace_prefix
