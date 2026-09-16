# Profiles usable as `claude --cpa <name>`: every <NAME>_CPA_TOKEN from secrets.fish that also
# has a matching _CPA_BASE_URL. Derived from the environment rather than a hand-kept list so a
# new gateway needs only its two FISHENV_MANIFEST rows — nothing here to forget to update.
function __claude_cpa_profiles --description "List CPA gateway profiles available in this shell"
    for v in (set --names)
        set -l m (string match -r '^(.+)_CPA_TOKEN$' -- $v)
        test (count $m) -eq 2; or continue
        set -q "$m[2]"_CPA_BASE_URL; and string lower -- $m[2]
    end
end
