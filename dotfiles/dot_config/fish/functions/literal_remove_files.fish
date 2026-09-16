# Function: remove_files
# Description: Recursively removes a directory or file and displays a progress bar.
# Parameters:
#   - dir_or_file_name: The name of the directory or file to be removed.
function remove_files -a dir_or_file_name
    rm -rv $dir_or_file_name | pv -l -s (du -a $dir_or_file_name | wc -l) > /dev/null
end
