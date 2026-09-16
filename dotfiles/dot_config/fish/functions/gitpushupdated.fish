function gitpushupdated --description "Push only updated files to a git repo."
    git add -u
    git commit -m "$argv"
    git pull
    git push
end
