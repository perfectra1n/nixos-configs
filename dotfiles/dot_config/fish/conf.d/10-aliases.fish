# Aliases that are the same on every OS. Platform-specific ones live in 20-aliases-<platform>.fish
# (fish sources conf.d/ alphabetically, so those load after this and can override).
#
# `temp`, `dockerstop`, `gitpatch` and `ocrpdfs` are single-quoted ON PURPOSE: inside double quotes
# fish expands $var and $(cmd) when the alias is DEFINED — i.e. at every shell start — which is how
# `dockerstop` was freezing a `docker ps` snapshot into its body and `temp` was minting a fresh
# tmpdir per shell (and always cd'ing to the first one). Single quotes defer that to call time.
alias sudo 'sudo '
alias myip "dig +short myip.opendns.com @resolver1.opendns.com"

set -gx EDITOR vim

alias ll 'ls -l'
alias l 'ls -lFh'
alias la 'ls -lAFh'
alias lr 'ls -tRFh'
alias lt 'ls -ltFh'
alias ldot 'ls -ld .*'
alias lS 'ls -1FSsh'
alias lart 'ls -1Fcart'
alias lrt 'ls -1Fcrt'

alias grep 'grep --color'
alias sgrep 'grep -R -n -H -C 5 --exclude-dir=(.git .svn CVS)'

alias t 'tail -f'

alias dud 'du -d 1 -h'
alias duf 'du -sh *'
alias fd 'find . -type d -name'
alias ff 'find . -type f -name'

alias h 'history'
alias help 'man'
alias p 'ps -f'
alias unexport 'unset'

alias vim 'vim'
alias gp gitpush
alias gpu gitpushupdated
alias gc gitcommit

alias gitupdatesubmodules "git submodule update --remote"

alias pip "pip3"
alias python "python3"
alias k "kubectl"

alias nnn "nnn -d -e -H"

alias validateyaml "python -c 'import yaml, sys; print(yaml.safe_load(sys.stdin))'"

alias setupgit "git config --global credential.helper store"
alias startpyenv "set -Ux PYENV_ROOT $HOME/.pyenv; fish_add_path $PYENV_ROOT/bin; pyenv init - | source"
alias customcommands "functions -a | grep -v fish_"
alias newgitrepo "setupgitrepo"
alias pia "piactl"
alias uuid "uuidgen"
#alias genpass '< /dev/urandom tr -dc _A-Z-a-z-0-9 | head -c${1:-16};echo;'

alias randomstring "openssl rand -hex 16"
alias genpass "randomstring"


alias savetmuxpane "save_tmux_history"
alias convertsvg "convert -size 1000x1000"
alias idk "gp (curl -L -s whatthecommit.com/index.txt)"
alias get-active-kubernetes-bgp-addresses "kubectl get services --all-namespaces -o custom-columns=NAMESPACE:.metadata.namespace,NAME:.metadata.name,BGP-IP:.status.loadBalancer.ingress[0].ip |awk  '!/none/'"
alias ocrpdfs 'for file in *; ocrmypdf --optimize 3 --force-ocr --deskew $file $file; end;'
alias temp 'cd $(mktemp -d)'
alias k9s "k9s -n all"
alias gitpatch 'git diff --no-color > ~/(basename $PWD)_(date +%Y-%m-%d-%H-%M).patch'
alias cdr "cd ~/repos"
alias savetotrilium "trilium-note"
alias dockerstop 'docker stop $(docker ps -q)'
