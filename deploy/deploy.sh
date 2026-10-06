#!/usr/bin/env bash
# Activate a release on the streaming node (#11). Runs as the deploy user.
#
#   deploy.sh activate <bundle-dir> <git-sha>
#   deploy.sh rollback
#   deploy.sh status
#   deploy.sh compose <args>   docker compose with the active release's tags
#   deploy.sh apply-stations < stations.json   (station limits, no restart)
#
# Layout under $DEPLOY_ROOT (default /opt/tc-streaming):
#   .env                 secrets, written by the deploy workflow (0600)
#   compose.yaml         active Compose file
#   caddy/Caddyfile      active Caddy config (directory-mounted)
#   auth-stub/server.py  temporary auth stub (profile "stub")
#   stations.json        station limits (#8), from the control plane
#   releases/<sha>/      copy of each deployed bundle, for rollback; its
#                        release.env holds ICECAST_IMAGE_TAG and CADDY_IMAGE_TAG
#   CURRENT, PREVIOUS    "<git-sha> <icecast-image-tag>" of the active and
#                        prior release
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
    # Monitoring files (#10); older bundles do not have them.
    if [[ -f $bundle/icecast_exporter.py ]]; then
        install -d -m 0750 exporter alloy
        install -m 0644 "$bundle/icecast_exporter.py" exporter/icecast_exporter.py
        install -m 0644 "$bundle/config.alloy" alloy/config.alloy
    fi
    install -m 0750 "$bundle/deploy.sh" deploy.sh.new
    mv deploy.sh.new deploy.sh
}

# Export the image tags of a release. Releases from before release.env
# only pin the Icecast tag (their compose file uses the stock Caddy image).
load_release() {
    local sha=$1 fallback_tag=${2:-}
    unset ICECAST_IMAGE_TAG CADDY_IMAGE_TAG
    if [[ -f releases/$sha/release.env ]]; then
        ICECAST_IMAGE_TAG=$(sed -n 's/^ICECAST_IMAGE_TAG=//p' "releases/$sha/release.env")
        CADDY_IMAGE_TAG=$(sed -n 's/^CADDY_IMAGE_TAG=//p' "releases/$sha/release.env")
        export CADDY_IMAGE_TAG
    else
        ICECAST_IMAGE_TAG=$fallback_tag
    fi
    [[ -n $ICECAST_IMAGE_TAG ]] || { log "release $sha has no image tags"; exit 1; }
    export ICECAST_IMAGE_TAG
}

start() {
    local image_tag=$ICECAST_IMAGE_TAG
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
    running=$(compose ps -q caddy 2>/dev/null || true)
    if [[ -n $running && -n ${CADDY_IMAGE_TAG:-} ]] &&
        [[ $(docker inspect -f '{{.Config.Image}}' "$running") != *":$CADDY_IMAGE_TAG" ]]; then
        log "caddy image changes to $CADDY_IMAGE_TAG: all connections drop briefly"
    fi

    local caddy_before="" caddy_after=""
    caddy_before=$(caddy_started_at)

    # Bind-mounted into Icecast: it must exist before the container starts.
    [[ -f stations.json ]] || printf '{}\n' > stations.json

    log "starting services"
    compose up -d --wait --remove-orphans

    # Icecast may not have restarted; make it use the current limits.
    reload_stations

    # A Caddy container that this deploy started already runs the new
    # Caddyfile. Reloading it right away would interrupt its first
    # certificate requests.
    caddy_after=$(caddy_started_at)
    if [[ -n $caddy_before && $caddy_before == "$caddy_after" ]]; then
        # Pick up Caddyfile changes without dropping connections. Without
        # --force, Caddy does nothing when the config is unchanged.
        log "reloading caddy"
        local out
        if ! out=$(compose exec -T caddy caddy reload --config /etc/caddy/Caddyfile 2>&1); then
            printf '%s\n' "$out" | grep -v '"level":"info"' >&2
            log "caddy reload failed"
            return 1
        fi
    else
        log "caddy started with the new config"
    fi
}

# Re-render the per-station mounts and reload Icecast (SIGHUP): live
# listeners and sources stay connected.
reload_stations() {
    # Images before #8 ignore the argument and would start a second Icecast.
    if ! compose exec -T icecast grep -q reload-stations /usr/local/bin/docker-entrypoint.py; then
        log "this Icecast image has no station limits; skipping"
        return 0
    fi
    log "applying station limits"
    compose exec -T icecast python3 /usr/local/bin/docker-entrypoint.py reload-stations
}

caddy_started_at() {
    local id
    id=$(compose ps -q caddy 2>/dev/null || true)
    if [[ -n $id ]]; then
        docker inspect -f '{{.State.StartedAt}}' "$id" 2>/dev/null || true
    fi
}

record() {
    local sha=$1 image_tag=$2
    if [[ -f CURRENT ]] && [[ $(cut -d' ' -f1 CURRENT) != "$sha" ]]; then
        cp CURRENT PREVIOUS
    fi
    printf '%s %s\n' "$sha" "$image_tag" > CURRENT
    # Keep the newest releases plus whatever CURRENT and PREVIOUS point at.
    local protected
    protected=$(for f in CURRENT PREVIOUS; do
        if [[ -f $f ]]; then cut -d' ' -f1 "$f"; fi
    done | sort -u)
    # Release names are git SHAs, so ls is safe here.
    # shellcheck disable=SC2012
    ls -1t releases | tail -n +$((keep_releases + 1)) | while read -r old; do
        grep -qx "$old" <<<"$protected" || rm -rf "releases/$old"
    done
}

case ${1:-} in
activate)
    bundle=$2 sha=$3
    [[ $sha =~ ^[0-9a-f]{40}$ ]] || { log "invalid git sha: $sha"; exit 1; }
    [[ -f $bundle/release.env ]] || { log "bundle has no release.env"; exit 1; }
    install -d -m 0750 releases
    rm -rf "releases/$sha"
    cp -r "$bundle" "releases/$sha"
    load_release "$sha"
    install_bundle "releases/$sha"
    start
    record "$sha" "$ICECAST_IMAGE_TAG"
    log "active: $sha (icecast $ICECAST_IMAGE_TAG, caddy ${CADDY_IMAGE_TAG:-stock})"
    ;;
rollback)
    [[ -f PREVIOUS ]] || { log "no previous release recorded"; exit 1; }
    read -r sha image_tag < PREVIOUS
    [[ -d releases/$sha ]] || { log "release $sha no longer on disk"; exit 1; }
    load_release "$sha" "$image_tag"
    log "rolling back to $sha"
    install_bundle "releases/$sha"
    SKIP_PULL=${SKIP_PULL:-1} start
    record "$sha" "$ICECAST_IMAGE_TAG"
    log "active: $sha (icecast $ICECAST_IMAGE_TAG, caddy ${CADDY_IMAGE_TAG:-stock})"
    ;;
compose)
    if [[ -f CURRENT ]]; then
        read -r sha image_tag < CURRENT
        load_release "$sha" "$image_tag"
    fi
    shift
    compose "$@"
    ;;
apply-stations)
    # Validate before touching the live file; overwrite in place so the
    # bind mount sees the change.
    new=$(mktemp)
    cat > "$new"
    python3 -c 'import json, sys; json.load(open(sys.argv[1]))' "$new" ||
        { log "stations JSON is invalid"; rm -f "$new"; exit 1; }
    cat "$new" > stations.json
    rm -f "$new"
    if [[ -f CURRENT ]]; then
        read -r sha image_tag < CURRENT
        load_release "$sha" "$image_tag"
    fi
    reload_stations
    ;;
status)
    echo "current:  $(cat CURRENT 2>/dev/null || echo none)"
    echo "previous: $(cat PREVIOUS 2>/dev/null || echo none)"
    if [[ -f CURRENT ]]; then
        read -r sha image_tag < CURRENT
        load_release "$sha" "$image_tag"
    fi
    compose ps
    ;;
*)
    sed -n '2,8p' "$0"
    exit 2
    ;;
esac
