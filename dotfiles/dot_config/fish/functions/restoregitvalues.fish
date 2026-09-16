function restoregitvalues
    read -p "set_color green; echo -n 'What's the name of the repo that held the values? '; set_color normal; echo -n 'name: '" tempvar
    makegitvalues
    gitvalues remote add origin https://$MAIN_GITEA_HOST/perf3ct/$tempvar
    gitvalues fetch --all
    gitvalues reset --hard origin/master
end
