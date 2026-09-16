# Where am I across all 3 places? — REMOTE (Gitea) vs LOCAL (nixos-configs monorepo, dotfiles/)
# vs HOME ($HOME). Read-only: never fetches, applies, or commits anything.
function czstate --description "Show chezmoi state across remote / local / dotfiles"
    set -l src (chezmoi source-path)
    set -l g (set_color green); set -l y (set_color yellow)
    set -l d (set_color brblack); set -l b (set_color --bold); set -l n (set_color normal)

    # REMOTE — where pushes go / pulls come from.
    set -l remote (git -C $src remote get-url origin 2>/dev/null)
    test -z "$remote"; and set remote "(no 'origin' remote configured)"
    printf "%sREMOTE%s  %s%s%s\n" $b $n $d $remote $n

    # LOCAL — the source repo: how far ahead/behind the remote, and uncommitted work.
    # Counts reflect the LAST fetch (this command does not fetch). Run `git -C (chezmoi
    # source-path) fetch` first if you want them current.
    set -l ab (git -C $src rev-list --left-right --count '@{u}...HEAD' 2>/dev/null | string split \t)
    set -l dirty (git -C $src status --porcelain 2>/dev/null | count)
    set -l tokens
    if test (count $ab) -ne 2
        set tokens "no upstream set"
    else
        test $ab[1] -gt 0; and set tokens $tokens "↓$ab[1] to pull"
        test $ab[2] -gt 0; and set tokens $tokens "↑$ab[2] to push"
    end
    test $dirty -gt 0; and set tokens $tokens "$dirty uncommitted"
    set -l lcolor $g
    set -l lstate "in sync"
    if test (count $tokens) -gt 0
        set lcolor $y
        set lstate (string join ' · ' $tokens)
    end
    printf "%sLOCAL%s   %s%s%s\n         %sgit:%s %s%s%s\n" $b $n $d (string replace $HOME '~' $src) $n $d $lcolor $lstate $n

    # HOME — your live dotfiles: how many differ from what LOCAL would write.
    set -l diffcount (chezmoi status 2>/dev/null | count)
    if test $diffcount -gt 0
        printf "%sHOME%s    %s\$HOME%s\n         %schezmoi:%s%s %d file(s) differ from local — `cz apply` or `cz capture`%s\n" \
            $b $n $d $n $d $y " " $diffcount $n
    else
        printf "%sHOME%s    %s\$HOME%s\n         %schezmoi:%s%s in sync with local%s\n" \
            $b $n $d $n $d $g " " $n
    end
end
