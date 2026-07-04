#!/usr/bin/env fish
function testing
    echo "Running the testing function"

    if test "$argv[1]" = "something"
        echo "what the"
    end
end

testing $argv