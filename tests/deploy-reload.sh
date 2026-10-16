#!/usr/bin/env bash
# deploy.sh restarts Alloy and the exporter when a release changes their
# bind-mounted file, unless Compose already recreated them; an unchanged
# file restarts nothing. Runs deploy.sh against a fake docker: no
# containers, no network. Needs bash and python3.
set -euo pipefail

cd "$(dirname "$0")/.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
root=$work/root
bin=$work/bin
mkdir -p "$root" "$bin"
printf 'X=1\n' > "$root/.env"

# Fake docker: start times in $root/started.<service>; "compose up" bumps the
# services listed in $RECREATE; every call is logged.
cat > "$bin/docker" <<'SH'
#!/usr/bin/env bash
state=${FAKE_STATE:?}
echo "$*" >> "$state/calls"
if [[ $1 == compose ]]; then
    shift
    while [[ $1 == --* || $1 == -f ]]; do shift 2; done
    case $1 in
        ps) [[ -f $state/started.${3:-} ]] && echo "id-$3" ;;
        config) [[ ${2:-} == --services ]] && printf 'icecast\ncaddy\nicecast-exporter\nalloy\n' ;;
        up) for s in ${RECREATE:-}; do date +%s%N > "$state/started.$s"; done ;;
        exec) [[ $* == *"grep -q reload-stations"* ]] && exit 1 ;;
    esac
    exit 0
fi
if [[ $1 == inspect ]]; then
    service=${*: -1}; service=${service#id-}
    case $3 in
        *StartedAt*) cat "$state/started.$service" ;;
        *Image*) echo "image:tag" ;;
    esac
fi
SH
chmod +x "$bin/docker"

bundle() {
    local dir=$work/bundle-$1
    mkdir -p "$dir"
    cp deploy/compose.yaml deploy/deploy.sh "$dir/"
    printf '{}\n' > "$dir/Caddyfile"
    printf '# stub\n' > "$dir/server.py"
    printf '# exporter %s\n' "$2" > "$dir/icecast_exporter.py"
    printf '// alloy %s\n' "$3" > "$dir/config.alloy"
    printf 'ICECAST_IMAGE_TAG=t\nCADDY_IMAGE_TAG=t\nRELEASE_VERSION=0.0.0\n' > "$dir/release.env"
    echo "$dir"
}

# $1 sha digit, $2 exporter version, $3 alloy version, $4 services Compose recreates.
deploy() {
    : > "$root/calls"
    PATH="$bin:$PATH" FAKE_STATE=$root RECREATE=${4:-} DEPLOY_ROOT=$root SKIP_PULL=1 \
        bash deploy/deploy.sh activate "$(bundle "$1" "$2" "$3")" "$(printf "$1%.0s" {1..40})" > "$root/out"
}

restarted() { grep -o 'compose .* restart [a-z-]*' "$root/calls" | awk '{print $NF}' | sort | xargs; }

failures=0
check() {
    if [[ $2 == "$3" ]]; then
        echo "ok   - $1"
    else
        echo "FAIL - $1: expected '$2', got '$3'"
        failures=$((failures + 1))
    fi
}

for s in icecast caddy icecast-exporter alloy; do date +%s%N > "$root/started.$s"; done
mkdir -p "$root/exporter" "$root/alloy"

deploy 1 v1 v1
check "first install: both files are new, neither container was recreated" "alloy icecast-exporter" "$(restarted)"

deploy 2 v1 v1
check "same files: nothing restarts" "" "$(restarted)"

deploy 3 v1 v2
check "only config.alloy changed: only Alloy restarts" "alloy" "$(restarted)"
check "the restart is logged" yes "$(grep -q "alloy file changed: restarting it" "$root/out" && echo yes || echo no)"

deploy 4 v2 v3 "alloy icecast-exporter"
check "both changed but Compose recreated both: no second restart" "" "$(restarted)"

deploy 5 v3 v3 "alloy"
check "exporter changed, only Alloy recreated: the exporter restarts" "icecast-exporter" "$(restarted)"

[[ $failures -eq 0 ]] || exit 1
