function venv
    if test -d venv
        source venv/bin/activate.fish
        echo "Found and activated virtualenv."
    else
        python3 -m venv venv
        source venv/bin/activate.fish
        pip install -r requirements.txt 
        echo "Created new virtualenv, activated it, and installed its dependencies listed in requirements.txt."
    end
end
