function makegitvalues
    mv .git .gittemp
    git init .
    mv .git .gitvalues
    mv .gittemp .git
end
