function openclaw
    kubectl exec -it -n openclaw sts/openclaw -c main -- node /app/dist/index.js $argv
end
