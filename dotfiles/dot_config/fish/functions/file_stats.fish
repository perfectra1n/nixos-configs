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
