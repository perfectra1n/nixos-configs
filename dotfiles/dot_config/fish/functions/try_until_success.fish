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
