#!/usr/bin/env bash
# Activate a release on the streaming node (#11). Runs as the deploy user.
#
#   deploy.sh activate <bundle-dir> <git-sha> <image-tag>
#   deploy.sh rollback
#   deploy.sh status
#
# Layout under $DEPLOY_ROOT (default /opt/tc-streaming):
#   .env                 secrets, written by the deploy workflow (0600)
#   compose.yaml         active Compose file
#   caddy/Caddyfile      active Caddy config (directory-mounted)
#   auth-stub/server.py  temporary auth stub (profile "stub")
#   releases/<sha>/      copy of each deployed bundle, for rollback
#   CURRENT, PREVIOUS    "<git-sha> <image-tag>" of the active and prior release
#
# Registry login for the pull is done by the caller.
set -euo pipefail

root=${DEPLOY_ROOT:-/opt/tc-streaming}
keep_releases=5
cd "$root"

compose() {
    docker compose --project-directory "$root" -f "$root/compose.yaml" --env-file "$root/.env" "$@"
}

log() { printf '[deploy] %s\n' "$*"; }

install_bundle() {
    local bundle=$1
    install -d -m 0750 caddy auth-stub
    install -m 0640 "$bundle/compose.yaml" compose.yaml
    # Overwrite in place: some bind-mount setups (e.g. Docker Desktop) do
    # not show a file that was replaced by rename to the running container.
    cat "$bundle/Caddyfile" > caddy/Caddyfile
    chmod 0644 caddy/Caddyfile
    install -m 0644 "$bundle/server.py" auth-stub/server.py
    install -m 0750 "$bundle/deploy.sh" deploy.sh.new
    mv deploy.sh.new deploy.sh
}

start() {
    local image_tag=$1
    export ICECAST_IMAGE_TAG=$image_tag
    [[ -f .env ]] || { log "missing $root/.env"; exit 1; }
    compose config --quiet

    if [[ ${SKIP_PULL:-} != 1 ]]; then
        log "pulling images"
        compose pull --quiet
    fi

    local running=""
    running=$(compose ps -q icecast 2>/dev/null || true)
    if [[ -n $running ]] && [[ $(docker inspect -f '{{.Config.Image}}' "$running") != *":$image_tag" ]]; then
        log "icecast image changes to $image_tag: live listeners will reconnect"
    fi

    log "starting services"
    compose up -d --wait --remove-orphans

    # Pick up Caddyfile changes without dropping connections.
    log "reloading caddy"
    compose exec -T caddy caddy reload --config /etc/caddy/Caddyfile --force >/dev/null
}

record() {
    local sha=$1 image_tag=$2
    if [[ -f CURRENT ]] && [[ $(cut -d' ' -f1 CURRENT) != "$sha" ]]; then
        cp CURRENT PREVIOUS
    fi
    printf '%s %s\n' "$sha" "$image_tag" > CURRENT
    # Keep the newest releases plus whatever CURRENT and PREVIOUS point at.
    local protected
    protected=$(cat CURRENT PREVIOUS 2>/dev/null | cut -d' ' -f1 | sort -u)
    # Release names are git SHAs, so ls is safe here.
    # shellcheck disable=SC2012
    ls -1t releases | tail -n +$((keep_releases + 1)) | while read -r old; do
        grep -qx "$old" <<<"$protected" || rm -rf "releases/$old"
    done
}

case ${1:-} in
activate)
    bundle=$2 sha=$3 image_tag=$4
    [[ $sha =~ ^[0-9a-f]{40}$ ]] || { log "invalid git sha: $sha"; exit 1; }
    install -d -m 0750 releases
    rm -rf "releases/$sha"
    cp -r "$bundle" "releases/$sha"
    install_bundle "releases/$sha"
    start "$image_tag"
    record "$sha" "$image_tag"
    log "active: $sha ($image_tag)"
    ;;
rollback)
    [[ -f PREVIOUS ]] || { log "no previous release recorded"; exit 1; }
    read -r sha image_tag < PREVIOUS
    [[ -d releases/$sha ]] || { log "release $sha no longer on disk"; exit 1; }
    log "rolling back to $sha ($image_tag)"
    install_bundle "releases/$sha"
    SKIP_PULL=${SKIP_PULL:-1} start "$image_tag"
    record "$sha" "$image_tag"
    log "active: $sha ($image_tag)"
    ;;
status)
    echo "current:  $(cat CURRENT 2>/dev/null || echo none)"
    echo "previous: $(cat PREVIOUS 2>/dev/null || echo none)"
    ICECAST_IMAGE_TAG=$(cut -d' ' -f2 CURRENT 2>/dev/null || echo unknown) compose ps
    ;;
*)
    sed -n '2,8p' "$0"
    exit 2
    ;;
esac
