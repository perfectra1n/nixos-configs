function proxycli
    if test "$proxycli" = false; or test -z "$proxycli"
        set -xg proxycli true
        set -xg HTTP_PROXY "http://127.0.0.1:8080"
        set -xg http_proxy "http://127.0.0.1:8080"
        set -xg HTTPS_PROXY "http://127.0.0.1:8080"
        set -xg https_proxy "http://127.0.0.1:8080"
        echo (set_color green) "Proxied to localhost:8080"
    else
        set -g proxycli false
        set -e http_proxy
        set -e https_proxy
        set -e HTTP_PROXY
        set -e HTTPS_PROXY
        echo (set_color red) "Cleared proxy vars"
    end
end
