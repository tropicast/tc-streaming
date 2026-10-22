#!/usr/bin/env bash
# Deploy the Icecast + Caddy stack from GitLab CI (#117): the `deploy` job of
# .gitlab-ci.yml runs it. Same steps as .github/workflows/deploy.yml, which
# stays until the move to GitLab (tropicast/tc-devops#7).
#
# Deploys the pipeline's commit (a commit on main or a release tag). Each
# image is the one of the last main commit that changed its files, so a
# deploy that does not change Icecast does not restart it. Roll back by
# running the deploy job of an older pipeline again.
#
# Needs bash, ssh, curl, jq, python3, git and the docker CLI. Settings and
# secrets are CI/CD variables of the production environment
# (docs/runbook.md, GitLab CI); the optional ones have the defaults below.
set -euo pipefail

: "${CI_COMMIT_SHA:?}" "${CI_DEFAULT_BRANCH:?}" "${CI_JOB_ID:?}"
: "${CI_REGISTRY:?}" "${CI_REGISTRY_IMAGE:?}" "${CI_REGISTRY_USER:?}" "${CI_REGISTRY_PASSWORD:?}"
: "${DEPLOY_SERVER:=tc-stream-1}" "${ICECAST_SOURCE_AUTH_USER:=icecast}"
# The control plane accepts the node credentials of source auth on the playout endpoint.
: "${PLAYOUT_USER:=$ICECAST_SOURCE_AUTH_USER}" "${PLAYOUT_PASSWORD:=${ICECAST_SOURCE_AUTH_PASSWORD:-}}"
# shellcheck disable=SC2034 # read through ${!name} below
NODE_NAME=$DEPLOY_SERVER
REMOTE_ROOT=/opt/tc-streaming
export DEPLOY_SERVER

cd "$(dirname "$0")/.."
work=$(mktemp -d)
# Registry logins and the deploy key stay in this job's directory.
export DOCKER_CONFIG=$work/docker
ssh_node() { ssh -F "$work/ssh_config" node "$@"; }
log() { printf '\n==> %s\n' "$*"; }

# --- Release ------------------------------------------------------------------
sha=$CI_COMMIT_SHA
git fetch --quiet origin "$CI_DEFAULT_BRANCH"
git merge-base --is-ancestor "$sha" FETCH_HEAD || { echo "$sha is not on $CI_DEFAULT_BRANCH." >&2; exit 1; }
# The image only changes when its inputs change. Reusing the tag of the last
# main commit that touched them avoids restarting Icecast (and dropping
# listeners) on deploys that do not change it. Keep these lists identical to
# the image jobs' in .gitlab-ci.yml.
icecast_sha=$(git log -1 --first-parent --format=%H "$sha" -- Dockerfile docker-entrypoint.py icecast.xml .dockerignore)
caddy_sha=$(git log -1 --first-parent --format=%H "$sha" -- caddy/Dockerfile caddy/.dockerignore)
# AutoDJ playout (#63); empty for commits before it.
playout_sha=$(git log -1 --first-parent --format=%H "$sha" -- playout)
icecast_tag=sha-$icecast_sha caddy_tag=sha-$caddy_sha playout_tag=${playout_sha:+sha-$playout_sha}
# The release version (#59), reported by the exporter: the tag on this commit, else
# "<last tag>-<commits>-g<sha>" from git describe, else 0.0.0+<sha> before the first tag.
if described=$(git describe --tags --match 'v[0-9]*' "$sha" 2>/dev/null); then
    version=${described#v}
else
    version="0.0.0+$(git rev-parse --short=12 "$sha")"
fi
log "deploying $version ($sha): icecast:$icecast_tag, caddy:$caddy_tag, playout:${playout_tag:-none}"

printf '%s' "$CI_REGISTRY_PASSWORD" | docker login "$CI_REGISTRY" -u "$CI_REGISTRY_USER" --password-stdin >/dev/null
docker manifest inspect "$CI_REGISTRY_IMAGE/icecast:$icecast_tag" >/dev/null
docker manifest inspect "$CI_REGISTRY_IMAGE/caddy:$caddy_tag" >/dev/null
if [[ -n $playout_tag ]]; then
    docker manifest inspect "$CI_REGISTRY_IMAGE/playout:$playout_tag" >/dev/null
fi
docker logout "$CI_REGISTRY" >/dev/null

# --- SSH ----------------------------------------------------------------------
# The node's firewall only allows admin CIDRs on SSH. Open port 22 to this
# runner alone for the length of the job; closed again on exit.
cleanup() {
    status=$?
    deploy/ci-ssh-access.sh close "$CI_JOB_ID" || status=1
    # Never leave the deploy key or a registry login behind.
    rm -rf "$work"
    exit "$status"
}
trap cleanup EXIT
deploy/ci-ssh-access.sh open "$CI_JOB_ID"

: "${DEPLOY_HOST:?Set the DEPLOY_HOST variable}"
: "${DEPLOY_SSH_KEY:?Set the DEPLOY_SSH_KEY variable}"
: "${DEPLOY_KNOWN_HOSTS:?Set the DEPLOY_KNOWN_HOSTS variable}"
(umask 077 && printf '%s\n' "$DEPLOY_SSH_KEY" >"$work/id_ed25519")
printf '%s\n' "$DEPLOY_KNOWN_HOSTS" >"$work/known_hosts"
cat >"$work/ssh_config" <<CFG
Host node
  HostName $DEPLOY_HOST
  User deploy
  IdentityFile $work/id_ed25519
  IdentitiesOnly yes
  UserKnownHostsFile $work/known_hosts
  StrictHostKeyChecking yes
  BatchMode yes
  ConnectTimeout 10
CFG
# The firewall change can take a few seconds to reach the node.
for attempt in $(seq 1 12); do
    ssh_node true && break
    ((attempt < 12)) || exit 1
    echo "SSH not reachable yet (attempt $attempt)"
    sleep 5
done

# --- Secrets ------------------------------------------------------------------
log "writing secrets to the node"
required=(ICECAST_SOURCE_PASSWORD ICECAST_ADMIN_PASSWORD ICECAST_RELAY_PASSWORD
          ICECAST_SOURCE_AUTH_PASSWORD ICECAST_SOURCE_AUTH_URL LISTEN_HOST
          INGEST_HOST ACME_EMAIL)
for name in "${required[@]}"; do
    [[ -n ${!name:-} ]] || { echo "Missing variable: $name" >&2; exit 1; }
done
# Compose accepts "stub, monitoring": compare without spaces.
profiles=,${COMPOSE_PROFILES:-},
profiles=${profiles//[[:space:]]/}
# Alloy starts without them, but its pushes fail: warn instead of blocking the deploy.
if [[ $profiles == *,monitoring,* ]]; then
    for name in GRAFANA_CLOUD_PROM_URL GRAFANA_CLOUD_PROM_USER GRAFANA_CLOUD_LOKI_URL GRAFANA_CLOUD_LOKI_USER GRAFANA_CLOUD_TOKEN; do
        [[ -n ${!name:-} ]] || echo "WARNING $name is not set: monitoring cannot push (docs/how-to/set-up-monitoring.md, step 4)"
    done
fi
if [[ $profiles == *,autodj,* ]]; then
    for name in PLAYOUT_URL PLAYOUT_PASSWORD; do
        [[ -n ${!name:-} ]] || { echo "Missing variable: $name (COMPOSE_PROFILES has autodj)" >&2; exit 1; }
    done
fi
names=("${required[@]}" ICECAST_SOURCE_AUTH_USER COMPOSE_PROFILES STUB_STATIONS
       PLAYOUT_URL PLAYOUT_USER PLAYOUT_PASSWORD PLAYOUT_CPUS PLAYOUT_MEMORY
       GRAFANA_CLOUD_PROM_URL GRAFANA_CLOUD_PROM_USER GRAFANA_CLOUD_LOKI_URL
       GRAFANA_CLOUD_LOKI_USER GRAFANA_CLOUD_TOKEN
       HCLOUD_READ_TOKEN NODE_NAME PRIVATE_IP)
# Sent over stdin, never on a command line.
for name in "${names[@]}"; do
    printf '%s=%s\n' "$name" "${!name:-}"
done | ssh_node "umask 077 && cat > $REMOTE_ROOT/.env.new && mv $REMOTE_ROOT/.env.new $REMOTE_ROOT/.env"

# Station limits (#8). The control plane pushes them (tc-dashboard#8); until
# it does, STATION_LIMITS sets them. Unset: keep the node's file, so a deploy
# never overwrites what the control plane applied.
if [[ -n ${STATION_LIMITS:-} ]]; then
    log "writing station limits to the node"
    printf '%s\n' "$STATION_LIMITS" | python3 -m json.tool >/dev/null
    printf '%s\n' "$STATION_LIMITS" | ssh_node "cat > $REMOTE_ROOT/stations.json"
fi

# --- Bundle and activation ----------------------------------------------------
log "uploading the release bundle"
bundle=$work/bundle
mkdir "$bundle"
cp deploy/compose.yaml deploy/deploy.sh caddy/Caddyfile auth-stub/server.py \
    exporter/icecast_exporter.py deploy/alloy/config.alloy "$bundle/"
printf 'ICECAST_IMAGE_TAG=%s\nCADDY_IMAGE_TAG=%s\nPLAYOUT_IMAGE_TAG=%s\nRELEASE_VERSION=%s\nSTREAMING_REGISTRY=%s\n' \
    "$icecast_tag" "$caddy_tag" "$playout_tag" "$version" "$CI_REGISTRY_IMAGE" >"$bundle/release.env"
tar -C "$bundle" -cz . |
    ssh_node "rm -rf $REMOTE_ROOT/incoming && install -d -m 0750 $REMOTE_ROOT/incoming && tar -xz -C $REMOTE_ROOT/incoming"

log "activating"
# Short-lived registry login: the job token expires when the job ends.
printf '%s' "$CI_REGISTRY_PASSWORD" |
    ssh_node "docker login '$CI_REGISTRY' -u '$CI_REGISTRY_USER' --password-stdin" >/dev/null
status=0
ssh_node "bash $REMOTE_ROOT/incoming/deploy.sh activate $REMOTE_ROOT/incoming $sha" || status=$?
ssh_node "docker logout '$CI_REGISTRY'" >/dev/null || true
((status == 0)) || exit "$status"

# --- Public endpoints ---------------------------------------------------------
log "checking the public endpoints"
# The first deploy may wait for Let's Encrypt; retry for ~2 minutes.
check() {
    local url=$1 expected=$2 code
    for _ in $(seq 1 24); do
        code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$url" || true)
        [[ $code == "$expected" ]] && { echo "ok   $url -> $code"; return 0; }
        sleep 5
    done
    echo "FAIL $url -> $code (expected $expected)" >&2
    return 1
}
# The ingest host passes only PUT/SOURCE to Icecast and closes any other
# connection (#6). A valid TLS handshake followed by a closed connection is
# curl exit 52; certificate or TLS errors exit 35/60.
check_ingest() {
    local url=$1 status
    for _ in $(seq 1 24); do
        status=0
        curl -sS -o /dev/null --max-time 5 "$url" 2>/dev/null || status=$?
        [[ $status == 52 ]] && { echo "ok   $url -> TLS ok, connection closed"; return 0; }
        sleep 5
    done
    echo "FAIL $url -> curl exit $status (expected 52: TLS ok, connection closed)" >&2
    return 1
}
check "https://$LISTEN_HOST/admin/stats.xml" 404
check "https://$LISTEN_HOST/status-json.xsl" 404
check_ingest "https://$INGEST_HOST/stations/0/live.mp3"
log "deployed $version ($sha) to $DEPLOY_HOST"
