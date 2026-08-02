#!/usr/bin/env fish
# This is for Fish functions
function nvm
    bass source ~/.nvm/nvm.sh --no-use ';' nvm $argv
end


function ssh

    if set -q TMUX
        #                   s/[[:space:]]*\(\( | spaces before options
        #     \(-[46AaCfGgKkMNnqsTtVvXxYy]\)\| | option without parameter
        #                     \(-[^[:space:]]* | option
        # \([[:space:]]\+[^[:space:]]*\)\?\)\) | parameter
        #                      [[:space:]]*\)* | spaces between options
        #                        [[:space:]]\+ | spaces before destination
        #                \([^-][^[:space:]]*\) | destination
        #                                   .* | command
        #                                 /\6/ | replace with destination
        tmux rename-window (echo $argv | sed 's/[[:space:]]*\(\(\(-[46AaCfGgKkMNnqsTtVvXxYy]\)\|\(-[^[:space:]]*\([[:space:]]\+[^[:space:]]*\)\?\)\)[[:space:]]*\)*[[:space:]]\+\([^-][^[:space:]]*\).*/\6/')
        command ssh $argv
        tmux set-window-option automatic-rename on 1>/dev/null
    else
        command ssh $argv
    end
end

function try_until_success
    while true
        # Execute the command passed as arguments to this function
        if eval $argv
            echo "Command succeeded."
            return 0
        end
        # Wait for 1 second before retrying
        sleep 1
    end
end

function cpush
    # Scoped: `cpush ~/.config/foo` re-adds just that path. Bare `cpush` pushes only what you
    # already staged with czadd. Deliberately NO blanket `chezmoi re-add` — it recaptures
    # EVERY managed file from $HOME (incl. runtime/stale copies) and silently reverts other
    # machines' changes (that's what produced the bad "Update of dotfiles" commit 56e63d5).
    test (count $argv) -gt 0; and chezmoi re-add $argv
    # Source is now the nixos-configs MONOREPO, so scope add/commit to dotfiles/ — a bare
    # `git add -- .` here would sweep uncommitted Nix changes into a "dotfiles" commit + push them.
    chezmoi git add -- dotfiles/
    chezmoi git commit -- -m "Update of dotfiles through Chezmoi" -- dotfiles/
    chezmoi git push
end

function fixcolorcodes --description "Strip text file of ANSI color codes."
    echo 'Make sure to include the text file at the end of the command.'
    perl -pe 's/\e[\[\(][0-9;]*[mGKFB]//g' $argv >fixed_output.txt
    echo 'The fixed output should be under `fixed_output.txt`.'
end

function proxycli
    if test "$proxycli" = false; or test -z "$proxycli"
        set -xg proxycli true
        set -xg HTTP_PROXY "http://127.0.0.1:8080"
        set -xg http_proxy "http://127.0.0.1:8080"
        set -xg HTTPS_PROXY "http://127.0.0.1:8080"
        set -xg https_proxy "http://127.0.0.1:8080"
        echo (set_color green) "Proxied to localhost:8080"
    else
        set -g proxycli false
        set -e http_proxy
        set -e https_proxy
        set -e HTTP_PROXY
        set -e HTTPS_PROXY
        echo (set_color red) "Cleared proxy vars"
    end
end

function maketararchive
    tar cf - . | pv | pigz >(basename (pwd)).tar.gz
    echo "Created (basename (pwd)).tar.gz, moving it a directory up now..."
    mv ../(basename (pwd)).tar.gz ..
end

function makeziparchive
    zip -r ../(basename (pwd)).zip .
    echo "Created (basename (pwd)).tar.gz, moving it a directory up now..."
    mv ../(basename (pwd)).zip ..
end


function venv
    if test -d venv
        source venv/bin/activate.fish
        echo "Found and activated virtualenv."
    else
        python3 -m venv venv
        source venv/bin/activate.fish
        pip install -r requirements.txt 
        echo "Created new virtualenv, activated it, and installed its dependencies listed in requirements.txt."
    end
end

function getuniquewordsfromfile
    bat $argv[1] | sed 's/[^a-zA-Z0-9]/ /g' | tr ' ' '\n' | sort | uniq
end

function makedocker --description "Builds and pushes a Docker image to a repo. First arg is where to push to image to, second arg is where the Dockerfile is. e.g. 'makedocker $MAIN_GITEA_HOST/perf3ct/(basename (pwd)) ./build/exporter/Dockerfile'"
    set REPO $argv[1]
    docker build -t $REPO:(git log -1 --pretty=format:"%h") -t $REPO:latest -f $argv[2] . && \
    docker push $REPO:(git log -1 --pretty=format:"%h") && \
    docker push $REPO:latest
end

function setupgitrepo
    # Gitea host comes from the encrypted fish env channel (secrets.fish) — guard so a
    # fresh box doesn't silently create a remote named "https://perf3ct/..."
    set -q MAIN_GITEA_HOST; or begin; echo "MAIN_GITEA_HOST unset — run 'mise run secrets:pull'"; return 1; end
    git init .
    touch README.md
    git add .
    git commit -m "Initial commit to setup repo via Fish"
    git remote add origin https://$MAIN_GITEA_HOST/perf3ct/(basename (pwd))
    git push --set-upstream origin master
end

function fixvolsyncrestic --description "Fix a Restic repo that has been locked."
    set APP $argv[1]
    restic --repo s3://$RESTIC_S3_ENDPOINT/volsync-backups/apps/$APP unlock --remove-all
    restic --repo s3://$RESTIC_S3_ENDPOINT/volsync-backups/apps/$APP cache --cleanup
    restic --repo s3://$RESTIC_S3_ENDPOINT/volsync-backups/apps/$APP prune
end

#### Everything beneath here was from Chris Titus Zsh github
# # ex - archive extractor
# # usage: ex <file>
function ex -d "Extract most known archives with one command, I think this expands it in the current directory."
    if test -f $argv[1]
        switch $argv[1]
            case *.tar.bz2
                tar xjf $argv[1]
            case *.tar.gz
                tar xzf $argv[1]
            case *.tar.xz
                tar xJf $argv[1]
            case *.bz2
                bunzip2 $argv[1]
            case *.rar
                unrar x $argv[1]
            case *.gz
                gunzip $argv[1]
            case *.tar
                tar xf $argv[1]
            case *.tbz2
                tar xjf $argv[1]
            case *.tgz
                tar xzf $argv[1]
            case *.zip
                unzip $argv[1]
            case *.Z
                uncompress $argv[1]
            case *.7z
                7z x $argv[1]
            case *
                echo "'$argv[1]' cannot be extracted via ex()"
        end
    else
        echo "'$argv[1]' is not a valid file"
    end
end

function makegitvalues
    mv .git .gittemp
    git init .
    mv .git .gitvalues
    mv .gittemp .git
end

function gitpush --description "Push changes to a git repo."
    git add -A
    git commit -m "$argv"
    git pull
    git push
end

function gitpushupdated --description "Push only updated files to a git repo."
    git add -u
    git commit -m "$argv"
    git pull
    git push
end

function gitcommit --description "Commit changes to a git repo."
    git commit -m "$argv"
end

function chnamespace
    kubectl config set-context --current --namespace="$argv[1]"
end

function findme
    # Ignore the mnt_fullernas folder
    find . -type d -name fuller_nas -prune -o -name '*.json' -print
    find / -type f -name $argv
end

function findmehere
    find . -type f -name $argv
end

function gitvalues
    git --git-dir=".gitvalues/" $argv
end

function lazygitdotfiles
    lazygit --git-dir="$REPO_DIR/dotfiles/.git/" --work-tree=$HOME
end

# Set up function to backup dotfiles
# This assumes that you have a ~/repos/dotfiles directory
function dotfiles
    git --git-dir="$REPO_DIR/dotfiles/.git/" --work-tree=$HOME $argv
end

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

function sshhomelab
    # Domain comes from the encrypted fish env channel (secrets.fish)
    ssh -i ~/.ssh/vesemirkey perf3ct@$argv[1].$HOMELAB_SSH_DOMAIN
end

function sudo --description "Replacement for Bash 'sudo !!' command to run last command using sudo."
    if test "$argv" = !!
        echo sudo $history[1]
        eval command sudo $history[1]
    else
        command sudo $argv
    end
end

function restoregitvalues
    read -p "set_color green; echo -n 'What's the name of the repo that held the values? '; set_color normal; echo -n 'name: '" tempvar
    makegitvalues
    gitvalues remote add origin https://$MAIN_GITEA_HOST/perf3ct/$tempvar
    gitvalues fetch --all
    gitvalues reset --hard origin/master
end

function removepath
    if set -l index (contains -i $argv[1] $PATH)
        set --erase --universal fish_user_paths[$index]
        echo "Updated PATH: $PATH"
    else
        echo "$argv[1] not found in PATH: $PATH"
    end
end

# Function: remove_files
# Description: Recursively removes a directory or file and displays a progress bar.
# Parameters:
#   - dir_or_file_name: The name of the directory or file to be removed.
function remove_files -a dir_or_file_name
    rm -rv $dir_or_file_name | pv -l -s (du -a $dir_or_file_name | wc -l) > /dev/null
end

function save_tmux_history
    set -l file $argv[1]
    if test -z "$file"
        echo "Please provide a filename."
        return 1
    end
    if not type tmux > /dev/null
        echo "Tmux is not installed."
        return 1
    end
    if not tmux list-panes > /dev/null
        echo "No active tmux sessions."
        return 1
    end

    tmux capture-pane -pS - > $file
    echo "Tmux history saved to $file."
end

function n --wraps nnn --description 'support nnn quit and change directory'
    # Block nesting of nnn in subshells
    if test -n "$NNNLVL" -a "$NNNLVL" -ge 1
        echo "nnn is already running"
        return
    end

    # The behaviour is set to cd on quit (nnn checks if NNN_TMPFILE is set)
    # If NNN_TMPFILE is set to a custom path, it must be exported for nnn to
    # see. To cd on quit only on ^G, remove the "-x" from both lines below,
    # without changing the paths.
    if test -n "$XDG_CONFIG_HOME"
        set -x NNN_TMPFILE "$XDG_CONFIG_HOME/nnn/.lastd"
    else
        set -x NNN_TMPFILE "$HOME/.config/nnn/.lastd"
    end

    # Unmask ^Q (, ^V etc.) (if required, see `stty -a`) to Quit nnn
    # stty start undef
    # stty stop undef
    # stty lwrap undef
    # stty lnext undef

    # The command function allows one to alias this function to `nnn` without
    # making an infinitely recursive alias
    command nnn $argv

    if test -e $NNN_TMPFILE
        source $NNN_TMPFILE
        rm $NNN_TMPFILE
    end
end

function find_and_delete_released_wp_pvs
    # Parse command-line flags
    set -l delete_flag 0
    for arg in $argv
        if test "$arg" = "--delete"
            set delete_flag 1
        end
    end

    # Find released PVs with wp- claims
    set -l pvs_to_process (kubectl get pv -o json | jq -c '.items[] | 
        select(
            .status.phase == "Released" and 
            (.spec.claimRef.name | test("^wp-"))
        ) | {
            name: .metadata.name, 
            claim_name: .spec.claimRef.name
        }')

    # Check if any PVs were found
    if test (echo $pvs_to_process | jq -s 'length') -eq 0
        echo "No released PVs with wp- claims found."
        return 0
    end

    # List found PVs
    echo "Found the following released PVs:"
    echo $pvs_to_process | jq -r '.name'

    # Delete PVs if delete flag is set
    if test $delete_flag -eq 1
        echo "Deleting the following PVs:"
        for pv in (echo $pvs_to_process | jq -r '.name')
            echo "Deleting PV: $pv"
            kubectl delete pv $pv
        end
    end
end

function gityeet --description "Reset and clean a git repo."
    git clean -fd
    git reset --hard
end

function trilium-note --description "Create a Trilium note from piped input or editor"
    # Check for required dependencies
    for cmd in curl jq file
        if not command -sq $cmd
            echo "Error: Required command '$cmd' not found. Please install it first."
            return 1
        end
    end
    
    # Configuration variables
    set -l trilium_url "$TRILIUM_PERSONAL_URL/etapi" # Default Trilium server URL (base from the encrypted fish env channel)
    set -l auth_token "" # Your ETAPI auth token
    set -l parent_note_id "pfrpbjovkqMj" # Default parent note ID
    
    # Parse arguments
    argparse --name=trilium-note 'h/help' 'u/url=' 't/token=' 'p/parent=' 'T/title=' 'P/password=' -- $argv
    or return 1
    
    if set -q _flag_help
        echo "Usage: trilium-note [OPTIONS] [TITLE]"
        echo "Create a note in Trilium using piped input or your preferred text editor"
        echo
        echo "Options:"
        echo "  -h, --help           Show this help message"
        echo "  -u, --url URL        Trilium server URL (default: http://localhost:37740/etapi)"
        echo "  -t, --token TOKEN    ETAPI authentication token"
        echo "  -P, --password PASS  Trilium password (to obtain a token if none provided)"
        echo "  -p, --parent ID      Parent note ID (default: root)"
        echo "  -T, --title TITLE    Note title (alternative to providing as argument)"
        echo
        echo "Examples:"
        echo "  echo 'Note content' | trilium-note 'My Title'"
        echo "  trilium-note 'My Title'  # Opens editor for content"
        return 0
    end
    
    # Override defaults with provided options
    if set -q _flag_url
        set trilium_url $_flag_url
    end
    
    # Handle authentication
    if set -q _flag_token
        set auth_token $_flag_token
    else if set -q TRILIUM_TOKEN
        set auth_token $TRILIUM_TOKEN
    else if set -q _flag_password
        # Obtain token using password
        echo "Obtaining ETAPI token using password..."
        set -l login_response (echo "{\"password\": \"$_flag_password\"}" | curl -s -X POST "$trilium_url/auth/login" \
            -H "Content-Type: application/json" \
            -d @-)
        
        if echo $login_response | grep -q "\"authToken\""
            set auth_token (echo $login_response | jq -r '.authToken')
            echo "Token obtained successfully."
        else
            echo "Error obtaining token: $login_response"
            return 1
        end
    else
        echo "Error: ETAPI token is required. Provide it with -t/--token, set TRILIUM_TOKEN environment variable, or use -P/--password."
        return 1
    end
    
    if set -q _flag_parent
        set parent_note_id $_flag_parent
    end
    
    # Get title from arguments or flag
    set -l title ""
    if set -q _flag_title
        set title $_flag_title
    else if test (count $argv) -gt 0
        set title $argv[1]
    else
        # If no title provided, prompt for one
        read -P "Enter note title: " title
        if test -z "$title"
            echo "Error: Note title is required."
            return 1
        end
    end
    
    # Check if input is piped or coming from stdin
    set -l temp_input ""
    set -l detected_mime ""
    if not isatty stdin
        # Read piped input to a temp file for safety
        set temp_input (mktemp /tmp/trilium-input.XXXXXX)
        cat > $temp_input
        
        # Check if file has content
        if test ! -s $temp_input
            echo "Error: No content received from pipe."
            rm $temp_input
            return 1
        end
        
        # Detect MIME type
        set detected_mime (file --mime-type -b $temp_input)
    else
        # No piped input, use editor
        set temp_input (mktemp /tmp/trilium-note.XXXXXX)
        
        # Open editor
        if set -q EDITOR
            eval $EDITOR $temp_input
        else if command -sq vim
            vim $temp_input
        else if command -sq nano
            nano $temp_input
        else
            echo "Error: No text editor found. Set the EDITOR environment variable."
            rm $temp_input
            return 1
        end
        
        # Check if file has content
        if test ! -s $temp_input
            echo "Note creation cancelled - empty content."
            rm $temp_input
            return 1
        end
        
        # Detect MIME type
        set detected_mime (file --mime-type -b $temp_input)
    end
    
    # Create JSON payload - pipe directly from file to preserve formatting
    set -l json_payload ""
    set -l note_type "text"
    
    # Determine note type based on MIME type
    switch $detected_mime
        case "text/x-shellscript" "text/x-python" "text/x-c" "text/x-c++" "text/x-java" "text/x-ruby" "text/x-perl" "application/javascript" "application/json" "application/xml" "text/css"
            # Programming languages should be code type with MIME
            set note_type "code"
            set json_payload (cat $temp_input | jq -Rs --arg parent "$parent_note_id" --arg title "$title" --arg ntype "$note_type" --arg mime "$detected_mime" '{parentNoteId: $parent, title: $title, type: $ntype, content: ., mime: $mime}')
            if test $status -ne 0
                echo "Error: Failed to create JSON payload"
                rm $temp_input
                return 1
            end
        case "text/html"
            # HTML can be rendered
            set note_type "render"
            set json_payload (cat $temp_input | jq -Rs --arg parent "$parent_note_id" --arg title "$title" --arg ntype "$note_type" '{parentNoteId: $parent, title: $title, type: $ntype, content: ., mime: "text/html"}')
            if test $status -ne 0
                echo "Error: Failed to create JSON payload"
                rm $temp_input
                return 1
            end
        case "text/plain"
            # Enhanced markdown detection - check file extension or content patterns
            set -l is_markdown 0
            
            # Check if title suggests markdown file
            if string match -q "*.md" "$title"; or string match -q "*.markdown" "$title"
                set is_markdown 1
            # Check content for markdown patterns (more comprehensive)
            else if cat $temp_input | head -30 | grep -qE '^#{1,6}\s|^\*\s|^\-\s|^\d+\.\s|^\[.+\]\(.+\)|^```|^\|.*\|.*\|'
                set is_markdown 1
            end
            
            if test $is_markdown -eq 1
                # Markdown should be text type for proper rendering in Trilium
                set note_type "text"
                set json_payload (cat $temp_input | jq -Rs --arg parent "$parent_note_id" --arg title "$title" --arg ntype "$note_type" '{parentNoteId: $parent, title: $title, type: $ntype, content: .}')
                if test $status -ne 0
                    echo "Error: Failed to create JSON payload"
                    rm $temp_input
                    return 1
                end
            else
                # Plain text
                set json_payload (cat $temp_input | jq -Rs --arg parent "$parent_note_id" --arg title "$title" --arg ntype "$note_type" '{parentNoteId: $parent, title: $title, type: $ntype, content: .}')
                if test $status -ne 0
                    echo "Error: Failed to create JSON payload"
                    rm $temp_input
                    return 1
                end
            end
        case "image/*"
            # Images - skip for now as binary handling needs base64 encoding
            echo "Error: Image files are not yet supported. Please upload directly in Trilium."
            rm $temp_input
            return 1
        case '*'
            # Default case - treat as text
            set json_payload (cat $temp_input | jq -Rs --arg parent "$parent_note_id" --arg title "$title" --arg ntype "$note_type" '{parentNoteId: $parent, title: $title, type: $ntype, content: .}')
            if test $status -ne 0
                echo "Error: Failed to create JSON payload"
                rm $temp_input
                return 1
            end
    end
    
    # Clean up temp file
    rm $temp_input
    
    # Send request to Trilium API with authentication
    set -l response (curl -s -X POST "$trilium_url/create-note" \
        -H "Authorization: $auth_token" \
        -H "Content-Type: application/json" \
        -d "$json_payload")
    
    # Check response
    if echo $response | grep -q "\"noteId\""
        set -l note_id (echo $response | jq -r '.note.noteId')
        echo "Note created successfully with ID: $note_id"
        return 0
    else
        echo "Error creating note: $response"
        return 1
    end
end

function gitstash --description "fast way to stash"
    git stash save $argv
end

function gitpop --description "fast way to pop a git stash by name"
    if test (count $argv) -eq 0
        echo "Usage: gitpop <stash-name>"
        return 1
    end
    git stash pop stash^{/"$argv"}
end

function gittag --description "create and push a git tag"
	git tag $argv
	git push origin $argv
end

function updateollama --description "update ollama models"
    for model in (ollama list | tail -n +2 | awk '{print $1}')
        ollama pull $model
    end
end

function file_stats
    # Parse arguments
    set -l depth ""
    set -l search_dir "."
    
    # Parse command line arguments
    set -l i 1
    while test $i -le (count $argv)
        switch $argv[$i]
            case -h --help
                echo "Usage: file_stats [-d depth] [directory]"
                echo "  -d depth: maximum directory depth to search (default: unlimited)"
                echo "  directory: starting directory (default: current directory)"
                echo ""
                echo "Examples:"
                echo "  file_stats                    # Search current dir, unlimited depth"
                echo "  file_stats ~/projects         # Search ~/projects, unlimited depth"
                echo "  file_stats -d 3 ~/projects    # Search ~/projects, max depth 3"
                return 0
            case -d
                set i (math $i + 1)
                if test $i -le (count $argv)
                    set depth $argv[$i]
                else
                    echo "Error: -d requires a depth value"
                    return 1
                end
            case '*'
                set search_dir $argv[$i]
        end
        set i (math $i + 1)
    end
    
    # Validate depth is a number if provided
    if test -n "$depth"
        if not string match -qr '^[0-9]+$' $depth
            echo "Error: depth must be a positive number"
            return 1
        end
    end
    
    # Validate directory exists
    if not test -d $search_dir
        echo "Error: directory '$search_dir' does not exist"
        return 1
    end
    
    # Check if we're in a git repository and should respect .gitignore
    set -l use_git no
    set -l original_dir (pwd)
    if cd $search_dir 2>/dev/null
        if git rev-parse --git-dir >/dev/null 2>&1
            set use_git yes
        end
        cd $original_dir
    end
    
    # Print header
    if test -n "$depth"
        echo "Searching in: $search_dir (max depth: $depth)"
    else
        echo "Searching in: $search_dir (unlimited depth)"
    end
    if test "$use_git" = yes
        echo "Respecting .gitignore rules"
    end
    echo ""
    printf "│ %-45s │ %8s │ %8s │\n" "FILE PATH" "LINES" "WORDS"
    echo "├"(string repeat -n 47 "─")"┼"(string repeat -n 10 "─")"┼"(string repeat -n 10 "─")"┤"
    
    # Find all files and get their stats
    set -l file_count 0
    set -l files_list
    
    if test "$use_git" = yes
        # Use git to list files, respecting .gitignore
        cd $search_dir
        if test -n "$depth"
            # Git doesn't have maxdepth, so we filter with awk
            set files_list (git ls-files --cached --others --exclude-standard 2>/dev/null | \
                awk -F/ -v depth=$depth 'NF <= depth' | sort)
        else
            set files_list (git ls-files --cached --others --exclude-standard 2>/dev/null | sort)
        end
        cd $original_dir
        # Prepend search_dir to relative paths if not current dir
        if test "$search_dir" != "."
            set files_list (printf '%s\n' $files_list | sed "s|^|$search_dir/|")
        end
    else
        # Use regular find command with optional depth limit
        set -l find_cmd find $search_dir
        if test -n "$depth"
            set find_cmd $find_cmd -maxdepth $depth
        end
        set find_cmd $find_cmd -type f
        set files_list (eval $find_cmd 2>/dev/null | sort)
    end
    
    # Collect all file data first for sorting
    set -l file_data_list
    
    for file in $files_list
        # Get line count and word count
        set -l lines (wc -l < $file 2>/dev/null | string trim)
        set -l words (wc -w < $file 2>/dev/null | string trim)
        
        # Handle binary files or read errors
        if test -z "$lines"
            set lines "N/A"
        end
        if test -z "$words"
            set words "N/A"
        end
        
        # Store data as "lines|words|filepath"
        set file_data_list $file_data_list "$lines|$words|$file"
        set file_count (math $file_count + 1)
    end
    
    # Sort by line count (descending), treating N/A as -1 for sorting
    set -l sorted_data (printf '%s\n' $file_data_list | \
        awk -F'|' '{
            if ($1 == "N/A") lines = -1; else lines = $1;
            print lines"|"$0
        }' | \
        sort -t'|' -k1,1nr | \
        cut -d'|' -f2-)
    
    # Display sorted results
    for data in $sorted_data
        set -l parts (string split '|' $data)
        set -l lines $parts[1]
        set -l words $parts[2]
        set -l file $parts[3]
        
        # Truncate path if too long (keep last 3 parts)
        set -l display_path $file
        if test (string length $file) -gt 45
            # Split path and take last 3 components
            set -l path_parts (string split / $file)
            set -l num_parts (count $path_parts)
            if test $num_parts -gt 3
                set display_path "..."(string join / $path_parts[(math $num_parts - 2)..$num_parts])
            end
        end
        
        # Print formatted output with table borders
        printf "│ %-45s │ %8s │ %8s │\n" $display_path $lines $words
    end
    
    # Print footer
    echo "└"(string repeat -n 47 "─")"┴"(string repeat -n 10 "─")"┴"(string repeat -n 10 "─")"┘"
    echo "Total files: $file_count"
end

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

function claude
    # MCP servers live in a chezmoi-managed, ${VAR}-templated file (secrets stay out of the
    # publishable repo and out of ~/.claude.json); `claude` expands the ${VAR}s from the env
    # at launch — they come from secrets.fish. `=` form so the variadic flag takes only the
    # path and doesn't swallow $argv; guarded so a box without the file (fresh chezmoi) still runs.
    set -l mcp_args
    test -f "$HOME/.config/claude/mcp.json"
    and set mcp_args --mcp-config="$HOME/.config/claude/mcp.json"

    # `claude --cpa <name>` routes through a CLIProxyAPI gateway instead of the claude.ai OAuth
    # login (ANTHROPIC_AUTH_TOKEN overrides it entirely, so the two can't be combined — plain
    # `claude` still uses whatever account `claude-cred` last selected). Credentials come from
    # secrets.fish as <NAME>_CPA_BASE_URL/_CPA_TOKEN. Model ids are NOT secret, so they live here
    # in the open where they're greppable and fixable in one place.
    set -l cpa_env
    set -l i (contains -i -- --cpa $argv)
    if test -n "$i"
        set -l name $argv[(math $i + 1)]
        set -l base_var (string upper -- "$name")_CPA_BASE_URL
        set -l token_var (string upper -- "$name")_CPA_TOKEN
        # Fail loudly on a bad/missing name. Falling through to the OAuth login would hand you a
        # perfectly working session billed to the WRONG account, and Claude Code surfaces no hint
        # of which auth source won — so the mistake would be invisible until the bill arrives.
        if test -z "$name"; or not set -q $base_var; or not set -q $token_var
            echo "claude: unknown --cpa profile '$name'" >&2
            echo "claude: available profiles: "(__claude_cpa_profiles | string join ', ') >&2
            return 1
        end
        # `env` rather than `set -gx`: the token reaches only this process tree, not every
        # command you run afterwards in this shell.
        set cpa_env ANTHROPIC_BASE_URL=$$base_var ANTHROPIC_AUTH_TOKEN=$$token_var \
            ANTHROPIC_DEFAULT_OPUS_MODEL=claude-opus-5 \
            ANTHROPIC_DEFAULT_SONNET_MODEL=claude-sonnet-5 \
            ANTHROPIC_DEFAULT_HAIKU_MODEL=claude-haiku-4-5-20251001
        # Drop the flag and its value so they never reach the binary. Higher index first —
        # removing $i would shift the value down into its slot.
        set -e argv[(math $i + 1)]
        set -e argv[$i]
    end

    if set -q cpa_env[1]
        # `env` resolves `claude` from PATH to the real binary, so this can't recurse into
        # this function the way a bare `claude` would.
        IS_SANDBOX=1 env $cpa_env claude $mcp_args $argv
    else
        IS_SANDBOX=1 command claude $mcp_args $argv
    end
end

# Set tmux window title to the command being executed
function __tmux_preexec --on-event fish_preexec
    if set -q TMUX
        # Extract the command name, skipping any leading VAR=value assignments
        set -l cmd
        for word in (string split ' ' -- $argv[1])
            if not string match -qr '^[A-Za-z_][A-Za-z0-9_]*=' -- $word
                set cmd $word
                break
            end
        end
        test -z "$cmd"; and return
        # For claude code, show the directory name instead of the binary
        set -l cmd_base (basename "$cmd")
        if test "$cmd_base" = claude -o "$cmd_base" = claude-edge
            printf '\ek%s\e\\' (basename $PWD)
        else
            # Send escape sequence to set tmux window name
            printf '\ek%s\e\\' $cmd
        end
    end
end

# Reset window title to directory after command completes
function __tmux_postexec --on-event fish_postexec
    if set -q TMUX
        # Show directory name when back at prompt
        printf '\ek%s\e\\' (basename $PWD)
    end
end


function openclaw
    kubectl exec -it -n openclaw sts/openclaw -c main -- node /app/dist/index.js $argv
end


# ---- chezmoi helpers -----------------------------------------------------
# Manage dotfiles with chezmoi (source: this nixos-configs monorepo's dotfiles/ -> Gitea).
# Legacy bare-repo `dotfiles`/`updatedotfiles`/`lazygitdotfiles` and `cpush`
# above are left in place; these are the day-to-day chezmoi workflow.

# Stage a file/dir into the chezmoi source (e.g. czadd ~/.config/fish)
function czadd
    chezmoi add $argv
end

# Stage an encrypted (age) secret file into the chezmoi source
function czaddsecret
    chezmoi add --encrypt $argv
end

# Show what `chezmoi apply` would change in your home dir
function czdiff
    chezmoi diff $argv
end

# Show files that differ between source and home (managed status)
function czstatus
    chezmoi status $argv
end

# Apply the chezmoi source to your home dir
function czapply
    chezmoi apply $argv
end

# Pull latest from the remote and apply (sync this machine)
function czupdate
    chezmoi update $argv
end

# Edit a managed file in the chezmoi source (handles encrypted files)
function czedit
    chezmoi edit $argv
end

# Jump into the chezmoi source directory
function czcd
    cd (chezmoi source-path)
end

# Commit & push your STAGED source changes (use czadd <file> to capture a home edit first)
function czpush
    cpush
end

# Pull the latest dotfiles from the remote and apply them to THIS machine — the mirror of
# czpush. In git terms: `git pull` (refresh the source repo) + materialize it into your
# home (`chezmoi apply`), in one step. (Same as czupdate; named to match push/pull.)
function czpull
    chezmoi update $argv
end

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
