#!/usr/bin/env fish
# This is for Fish functions
function nvm
    bass source ~/.nvm/nvm.sh --no-use ';' nvm $argv
end
