function maketararchive
    tar cf - . | pv | pigz >(basename (pwd)).tar.gz
    echo "Created (basename (pwd)).tar.gz, moving it a directory up now..."
    mv ../(basename (pwd)).tar.gz ..
end
