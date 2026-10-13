#!/bin/zsh
# Runs a disposable Ubuntu server in Docker for testing Termuctive cloud projects.
#
#   Scripts/cloud-test-server.sh up [admin-public-key-file]
#   Scripts/cloud-test-server.sh down
#   Scripts/cloud-test-server.sh reset [admin-public-key-file]
#
# The server listens on 127.0.0.1:${TERMUCTIVE_CLOUD_TEST_PORT:-2222} with an
# `admin` account (password `termuctive`) that can use sudo.
set -euo pipefail

name=termuctive-cloud-test
image=termuctive-cloud-test
port=${TERMUCTIVE_CLOUD_TEST_PORT:-2222}
repository=${0:A:h:h}

start() {
    docker build --quiet --tag "$image" "$repository/Tests/CloudE2E" >/dev/null
    docker rm --force "$name" >/dev/null 2>&1 || true
    docker run --detach --name "$name" --publish "127.0.0.1:$port:22" "$image" >/dev/null
    if [[ -n ${1:-} ]]; then
        docker exec --interactive "$name" sh -c '
            install -d -m 700 -o admin -g admin /home/admin/.ssh
            cat > /home/admin/.ssh/authorized_keys
            chown admin:admin /home/admin/.ssh/authorized_keys
            chmod 600 /home/admin/.ssh/authorized_keys
        ' < "$1"
    fi
    echo "Test server: admin@127.0.0.1 port $port (password: termuctive)"
}

case ${1:-} in
    up)
        start "${2:-}"
        ;;
    down)
        docker rm --force "$name" >/dev/null 2>&1 || true
        ;;
    reset)
        docker rm --force "$name" >/dev/null 2>&1 || true
        start "${2:-}"
        ;;
    *)
        echo "Usage: $0 up|down|reset [admin-public-key-file]" >&2
        exit 64
        ;;
esac
