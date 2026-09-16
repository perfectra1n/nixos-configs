# Stage an encrypted (age) secret file into the chezmoi source
function czaddsecret
    chezmoi add --encrypt $argv
end
