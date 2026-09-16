function updatedotfiles
    echo "-------- Pulling updates from dotfiles repo --------"
    dotfiles pull
    dotfiles add -u

    # Test to see if there are any modified files
    if test (dotfiles status 2>&1 | grep -E 'modified:|new file:' | wc -l) -eq 0
        set_color red
        echo "No modified files, nothing to push, exiting..."
        return
    end

    # Now show the number of modified files
    echo ""
    echo "-------- Showing the modified files --------"
    echo "We found" (set_color green; dotfiles status 2>&1 | grep -E 'modified:|new file:' | wc -l; set_color normal) "changes to push"

    # Show the user the modified files in this scuffed format
    dotfiles status 2>&1 | grep -E 'modified:|new file:'
    echo ""
    read -p "set_color green; echo -n 'Push above changes? '; set_color normal; echo -n '[y/n] '" tempvar
    if test "$tempvar" = y; or test "$tempvar" = yes
        echo "-------- Committing and then pushing updates --------"
        dotfiles commit -m "$argv"
        dotfiles push
        set_color green
        echo "Pushed changes to remote repository :)"
    else
        set_color red
        echo "Input was not y, not pushing changes and exiting function..."
        return
        echo "-------- End of updating dotfiles --------"
    end
end
