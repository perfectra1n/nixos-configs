function sshhomelab
    # Domain comes from the encrypted fish env channel (secrets.fish)
    ssh -i ~/.ssh/vesemirkey perf3ct@$argv[1].$HOMELAB_SSH_DOMAIN
end
