function getuniquewordsfromfile
    bat $argv[1] | sed 's/[^a-zA-Z0-9]/ /g' | tr ' ' '\n' | sort | uniq
end
