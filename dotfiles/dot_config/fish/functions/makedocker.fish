function makedocker --description "Builds and pushes a Docker image to a repo. First arg is where to push to image to, second arg is where the Dockerfile is. e.g. 'makedocker $MAIN_GITEA_HOST/perf3ct/(basename (pwd)) ./build/exporter/Dockerfile'"
    set REPO $argv[1]
    docker build -t $REPO:(git log -1 --pretty=format:"%h") -t $REPO:latest -f $argv[2] . && \
    docker push $REPO:(git log -1 --pretty=format:"%h") && \
    docker push $REPO:latest
end
