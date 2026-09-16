# ---- chezmoi helpers (cz*) -----------------------------------------------
# Manage dotfiles with chezmoi (source: this nixos-configs monorepo's dotfiles/ -> Gitea).
# The legacy bare-repo `dotfiles`/`updatedotfiles`/`lazygitdotfiles` and `cpush` functions
# are left in place; the cz* family is the day-to-day chezmoi workflow.
# Static explainer: how chezmoi's verbs map onto your 3-places mental model.
# Pure output, no side effects. Doubles as the legend for the `cz` menu.
function czhelp --description "Explain chezmoi in remote/local/dotfiles terms"
    set -l b (set_color --bold); set -l c (set_color cyan); set -l n (set_color normal)
    set -l d (set_color brblack)
    echo ""
    printf "%schezmoi = keeping 3 places in sync%s\n" $b $n
    echo ""
    printf "  %sREMOTE git repo%s        %sLOCAL git repo%s            %sYOUR DOTFILES%s\n" $b $n $b $n $b $n
    printf "  %s(Gitea backup)%s         %snixos-configs/dotfiles%s    %s\$HOME (~/.config, …)%s\n" $d $n $d $n $d $n
    printf "  %sthe off-machine copy%s   %s\"the source\" of truth%s     %sthe files apps read%s\n" $d $n $d $n $d $n
    echo ""
    printf "        %s└── push ──►%s  LOCAL  %s└── apply ──►%s  HOME\n" $c $n $c $n
    printf "        %s◄── pull ───┘%s         %s◄── capture ─┘%s\n" $c $n $c $n
    echo ""
    printf "%sMove changes between two places:%s\n" $b $n
    printf "  %sHOME → LOCAL%s     I edited a real dotfile, save it     cz capture   (czadd / re-add)\n" $c $n
    printf "  %sHOME → LOCAL%s     manage a brand-new dotfile           cz new       (czadd)\n" $c $n
    printf "  %sLOCAL → HOME%s     write the source onto my files       cz apply     (czapply)\n" $c $n
    printf "  %sLOCAL → HOME%s     edit the managed copy, apply it      cz edit      (czedit)\n" $c $n
    printf "  %sLOCAL → REMOTE%s   back up / sync my source repo        cz push      (czpush)\n" $c $n
    printf "  %sREMOTE→LOCAL→HOME%s pull latest and refresh my files    cz pull      (czupdate)\n" $c $n
    echo ""
    printf "%sLook, don't move:%s\n" $b $n
    printf "  what's different right now?   cz status   (czstate)\n"
    printf "  jump to the source repo       cz cd       (czcd)\n"
    echo ""
    printf "%sRule of thumb:%s capture/add = HOME→LOCAL, apply = LOCAL→HOME, push/pull = LOCAL↔REMOTE.\n" $d $n
    echo ""
end
