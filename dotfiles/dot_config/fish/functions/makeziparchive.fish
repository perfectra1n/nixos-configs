function makeziparchive
    zip -r ../(basename (pwd)).zip .
    echo "Created (basename (pwd)).tar.gz, moving it a directory up now..."
    mv ../(basename (pwd)).zip ..
end
