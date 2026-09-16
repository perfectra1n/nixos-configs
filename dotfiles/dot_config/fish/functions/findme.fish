function findme
    # Ignore the mnt_fullernas folder
    find . -type d -name fuller_nas -prune -o -name '*.json' -print
    find / -type f -name $argv
end
