#!/bin/bash

function installFish () {
    sudo add-apt-repository ppa:fish-shell/release-3
    sudo apt update
    sudo apt -y install fish
}

function installFishDebian10 () {
    echo 'deb http://download.opensuse.org/repositories/shells:/fish:/release:/3/Debian_10/ /' | sudo tee /etc/apt/sources.list.d/shells:fish:release:3.list
    curl -fsSL https://download.opensuse.org/repositories/shells:fish:release:3/Debian_10/Release.key | gpg --dearmor | sudo tee /etc/apt/trusted.gpg.d/shells_fish_release_3.gpg > /dev/null
    sudo apt update
    sudo apt install fish
}

function installFishDebian11 () {
    echo 'deb http://download.opensuse.org/repositories/shells:/fish:/release:/3/Debian_11/ /' | sudo tee /etc/apt/sources.list.d/shells:fish:release:3.list
    curl -fsSL https://download.opensuse.org/repositories/shells:fish:release:3/Debian_11/Release.key | gpg --dearmor | sudo tee /etc/apt/trusted.gpg.d/shells_fish_release_3.gpg > /dev/null
    sudo apt update
    sudo apt install fish
}

function setupReposDir () {
    mkdir -p ~/repos
}

function installFisher () {
    fish -c "curl -sL https://git.io/fisher | source && fisher install jorgebucaran/fisher"
}

function installFzfFishDeps () {
    sudo apt install -y fd-find bat
}

function installFzf () {
    git clone --depth 1 https://github.com/junegunn/fzf.git ~/repos/fzf
    ~/repos/fzf/install
}

function fixBat () {
    mkdir -p ~/.local/bin
    sudo ln -s /usr/bin/batcat ~/.local/bin/bat
}

function installStarship () {
    curl -fsSL https://starship.rs/install.sh | sh
}

function useFisherToInstallPlugins () {
    fish -c "fisher install jethrokuan/z"
    fish -c "fisher install PatrickF1/fzf.fish"
    fish -c "fisher install edc/bass"
}

installFish
setupReposDir
installFzf
installFzfFishDeps
fixBat
installStarship
useFisherToInstallPlugins