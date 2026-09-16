# WSL extras on top of 30-os-linux.fish, which also loads on linux-wsl (this file used to
# `source linux.fish` itself for that).
test "$__platform" = linux-wsl; or return

#Specific to WSL
fish_add_path /mnt/c/Windows
fish_add_path /mnt/d/Programs/VSCode/bin
fish_add_path /mnt/c/"Program Files"/Docker/Docker/resources/bin

function cmd
    set CMD $argv[1]
    set ARGS $argv[2..-1]
    set WIN_PWD (wslpath -w (pwd))
    echo $WIN_PWD
    cmd.exe /c "pushd $WIN_PWD && $CMD $ARGS"
end

function savesecrets
    set target_dir /mnt/c/Users/perf3ct/Nextcloud/Configs/repos/(basename (pwd))
    if not test -d $target_dir
        mkdir -p $target_dir
    end
    cp secrets.json $target_dir/secrets.json
    echo "Saved secrets.json to $target_dir/secrets.json"
end
