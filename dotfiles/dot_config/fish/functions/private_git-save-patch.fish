function git-save-patch
    # Set patch directory
    set patch_dir ~/patches

    # Create patch directory if it doesn't exist
    if not test -d $patch_dir
        mkdir -p $patch_dir
        echo "Created patches directory: $patch_dir"
    end

    # Generate readable timestamp (YYYY-MM-DD_HH-MM-SS)
    set timestamp (date +%Y-%m-%d_%H-%M-%S)
    set patch_file $patch_dir/latest_commit_$timestamp.patch

    # Generate the patch directly to file
    git format-patch HEAD^ --stdout > $patch_file 2>&1
    set git_status $status

    # Check if git command succeeded
    if test $git_status -ne 0
        echo "Error: Failed to generate patch"
        cat $patch_file
        rm -f $patch_file
        return 1
    end

    # Check if patch file is not empty
    if not test -s $patch_file
        echo "Error: Patch is empty (no changes to export)"
        rm -f $patch_file
        return 1
    end

    echo "Patch saved to: $patch_file"
    echo "Size: "(du -h $patch_file | cut -f1)
end
