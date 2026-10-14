#!/usr/bin/env bash
# Store the monitoring values in GitHub after checking each one against
# the service it belongs to (docs/how-to/set-up-monitoring.md, step 4).
# Run from the tc-streaming folder, logged in with `gh`.
#
# Values (see the guide's worksheet):
#   A  Grafana Prometheus push URL     -> variable GRAFANA_CLOUD_PROM_URL
#   B  Grafana Prometheus username     -> variable GRAFANA_CLOUD_PROM_USER
#   C  Grafana token, metrics: Write   -> secret   GRAFANA_CLOUD_TOKEN
#      and logs: Write
#   F  Grafana Loki push URL           -> variable GRAFANA_CLOUD_LOKI_URL
#   G  Grafana Loki username           -> variable GRAFANA_CLOUD_LOKI_USER
#   E  Hetzner token, permission Read  -> secret   HCLOUD_READ_TOKEN
set -euo pipefail

server=${DEPLOY_SERVER:-tc-stream-1}

ask() {  # ask <prompt> [secret]: read a line, without echo for secrets
    local value
    if [[ ${2:-} == secret ]]; then
        read -rsp "$1: " value
        echo >&2
    else
        read -rp "$1: " value
    fi
    printf '%s' "${value//[[:space:]]/}"
}

fail() { echo "  ✗ $*" >&2; exit 1; }
ok() { echo "  ✓ $*" >&2; }

echo "A. Grafana Prometheus push URL (Remote Write Endpoint, ends in /api/prom/push)"
url=$(ask "   A")
[[ $url =~ ^https://prometheus-[A-Za-z0-9.-]+\.grafana\.net/api/prom/push$ ]] ||
    fail "Not a Grafana Cloud push URL. It looks like https://prometheus-prod-XX-....grafana.net/api/prom/push"
ok "URL format"

echo "B. Grafana Prometheus username / instance ID (digits only)"
user=$(ask "   B")
[[ $user =~ ^[0-9]+$ ]] || fail "The username is a number, e.g. 1234567"
ok "username format"

echo "F. Grafana Loki push URL (Loki card, URL + /loki/api/v1/push)"
loki_url=$(ask "   F")
[[ $loki_url =~ ^https://logs-[A-Za-z0-9.-]+\.grafana\.net/loki/api/v1/push$ ]] ||
    fail "Not a Grafana Cloud Loki push URL. It looks like https://logs-prod-XXX.grafana.net/loki/api/v1/push"
ok "Loki URL format"

echo "G. Grafana Loki username / user ID (digits only, differs from B)"
loki_user=$(ask "   G")
[[ $loki_user =~ ^[0-9]+$ ]] || fail "The Loki username is a number, e.g. 987654"
ok "Loki username format"

echo "C. Grafana token with scopes metrics: Write and logs: Write (starts with glc_)"
metrics_token=$(ask "   C" secret)
[[ $metrics_token == glc_* ]] || fail "Grafana Cloud tokens start with glc_. Did you paste the Hetzner token?"
# An empty push is rejected as bad input when the credentials are right,
# and with 401/403 when they are wrong.
code=$(curl -s -o /dev/null -w '%{http_code}' -u "$user:$metrics_token" \
    -H 'Content-Type: application/x-protobuf' -H 'Content-Encoding: snappy' \
    --data-binary '' "$url" || true)
case $code in
    401 | 403) fail "Grafana Cloud rejected value B + C (HTTP $code). Check the username and that the token has metrics: Write." ;;
    000) fail "Could not reach $url" ;;
esac
ok "Grafana Cloud accepts the token (HTTP $code on an empty test push)"
# An empty stream list is accepted (204) or rejected as bad input (400) when
# the URL and credentials are right; anything else is a failure.
code=$(curl -s -o /dev/null -w '%{http_code}' -u "$loki_user:$metrics_token" \
    -H 'Content-Type: application/json' --data-binary '{"streams":[]}' "$loki_url" || true)
case $code in
    204 | 400) ;;
    401 | 403) fail "Grafana Cloud Logs rejected value G + C (HTTP $code). Check the Loki username and that the token's policy has logs: Write." ;;
    000) fail "Could not reach $loki_url" ;;
    *) fail "Unexpected answer from $loki_url (HTTP $code). Check value F (wrong stack or region?) and try again." ;;
esac
ok "Grafana Cloud Logs accepts the token (HTTP $code on an empty test push)"

echo "E. Hetzner Cloud API token with permission Read (from the Hetzner Console, NOT Grafana)"
hetzner_token=$(ask "   E" secret)
[[ $hetzner_token != glc_* ]] || fail "This is a Grafana token (glc_...). Create a Read token in the Hetzner Console: project > Security > API tokens."
code=$(curl -s -o /tmp/hcloud-check.$$ -w '%{http_code}' -H "Authorization: Bearer $hetzner_token" \
    "https://api.hetzner.cloud/v1/servers?name=$server" || true)
found=$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1])).get("servers", [])))' /tmp/hcloud-check.$$ 2>/dev/null || echo 0)
rm -f /tmp/hcloud-check.$$
[[ $code == 200 ]] || fail "Hetzner rejected the token (HTTP $code)."
[[ $found == 1 ]] || fail "The token works but cannot see server $server. Was it created in the right Hetzner project?"
# A read-only token must not be able to write. An empty body is invalid
# input, so even a read-write token creates nothing.
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "Authorization: Bearer $hetzner_token" \
    -H 'Content-Type: application/json' -d '{}' https://api.hetzner.cloud/v1/ssh_keys || true)
[[ $code == 403 ]] || fail "This token can write (HTTP $code). Create a token with permission Read only."
ok "Hetzner token is read-only and sees $server"

echo "Storing in GitHub..."
gh variable set GRAFANA_CLOUD_PROM_URL --body "$url" >/dev/null
gh variable set GRAFANA_CLOUD_PROM_USER --body "$user" >/dev/null
gh variable set GRAFANA_CLOUD_LOKI_URL --body "$loki_url" >/dev/null
gh variable set GRAFANA_CLOUD_LOKI_USER --body "$loki_user" >/dev/null
printf '%s' "$metrics_token" | gh secret set GRAFANA_CLOUD_TOKEN >/dev/null
printf '%s' "$hetzner_token" | gh secret set HCLOUD_READ_TOKEN >/dev/null
profiles=$(gh variable get COMPOSE_PROFILES 2>/dev/null || true)
if [[ ,$profiles, != *,monitoring,* ]]; then
    profiles=${profiles:+$profiles,}monitoring
    gh variable set COMPOSE_PROFILES --body "$profiles" >/dev/null
fi
ok "Stored. COMPOSE_PROFILES=$profiles"
echo "Next: deploy (step 5)."
