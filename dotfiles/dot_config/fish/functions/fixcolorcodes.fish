function fixcolorcodes --description "Strip text file of ANSI color codes."
    echo 'Make sure to include the text file at the end of the command.'
    perl -pe 's/\e[\[\(][0-9;]*[mGKFB]//g' $argv >fixed_output.txt
    echo 'The fixed output should be under `fixed_output.txt`.'
end
