# memini plugin — pin every project to ONE shared memory namespace ("default")
# instead of the per-project name resolveProject() derives from the git remote /
# dir. This var is the FIRST thing resolveProject() checks (_shared.mjs), and BOTH
# the lifecycle hooks and the MCP headersHelper read it — so capture and recall
# always agree on the namespace. Non-secret (the literal "default"), so it lives
# here in the public config, not the age-encrypted secrets.fish.
set -gx MEMINI_NAMESPACE default
