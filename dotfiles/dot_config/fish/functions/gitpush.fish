function gitpush --description "Push changes to a git repo."
    git add -A
    git commit -m "$argv"
    git pull
    git push
end
