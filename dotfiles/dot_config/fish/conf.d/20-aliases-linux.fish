# Linux-only aliases (any Linux, WSL included): GNU-only flags and hardcoded Linux paths. Loads
# after 10-aliases.fish, so an entry here wins over a portable one of the same name.
string match -q 'linux*' -- $__platform; or return

alias ls 'ls --color'
alias editconfig "vim /home/perf3ct/.config/i3/config"
alias john '/home/perf3ct/repos/john/run/john'
alias ysoserial 'java -jar /home/perf3ct/repos/ysoserial/build/ysoserial.jar'
alias xclip "xclip -selection c"
alias updatecustomgitea "sudo cp -r /home/perf3ct/gitea-custom/ /home/git/; sudo chown -R git:git /home/git/gitea-custom; sudo systemctl restart gitea"
alias clearcache "sudo sh -c '/usr/bin/echo 3 > /proc/sys/vm/drop_caches'"
alias piagui "/opt/piavpn/bin/pia-client"
