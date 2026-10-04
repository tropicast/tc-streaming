#!/usr/bin/env bash
# Give the CI runner temporary SSH access to the streaming node (#11).
#
#   ci-ssh-access.sh open <run-id>    attach a firewall allowing this runner's IPv4 on 22
#   ci-ssh-access.sh close <run-id>   detach and delete it
#
# The Terraform firewall only allows admin CIDRs on port 22. Hetzner applies
# the union of all firewalls on a server, so a second, temporary firewall
# opens 22 to one /32 without touching the Terraform-managed one.
#
# Needs HCLOUD_TOKEN and DEPLOY_SERVER (server name, e.g. tc-stream-1).
set -euo pipefail

api=${HCLOUD_API:-https://api.hetzner.cloud/v1}
: "${HCLOUD_TOKEN:?}" "${DEPLOY_SERVER:?}"
action=${1:?open or close} run_id=${2:?run id}
name="ci-deploy-$run_id"

hc() {
    local method=$1 path=$2
    shift 2
    curl -fsS -X "$method" -H "Authorization: Bearer $HCLOUD_TOKEN" \
        -H 'Content-Type: application/json' "$api$path" "$@"
}

wait_actions() {
    local id status
    for id in "$@"; do
        for _ in $(seq 1 60); do
            status=$(hc GET "/actions/$id" | jq -r .action.status)
            [[ $status == success ]] && break
            [[ $status == error ]] && { echo "Hetzner action $id failed" >&2; return 1; }
            sleep 2
        done
    done
}

server_id=$(hc GET "/servers?name=$DEPLOY_SERVER" | jq -r '.servers[0].id // empty')
[[ -n $server_id ]] || { echo "Server $DEPLOY_SERVER not found" >&2; exit 1; }

remove_firewall() {
    local fw_id=$1 actions
    actions=$(hc POST "/firewalls/$fw_id/actions/remove_from_resources" \
        -d "{\"remove_from\":[{\"type\":\"server\",\"server\":{\"id\":$server_id}}]}" 2>/dev/null |
        jq -r '.actions[].id' || true)
    # shellcheck disable=SC2086 # action IDs are numbers
    [[ -z $actions ]] || wait_actions $actions
    hc DELETE "/firewalls/$fw_id" >/dev/null
}

case $action in
open)
    # Remove leftovers from runs whose cleanup did not finish.
    for old in $(hc GET '/firewalls?label_selector=purpose%3Dci-deploy' | jq -r '.firewalls[].id'); do
        echo "Removing leftover CI firewall $old"
        remove_firewall "$old" || echo "Could not remove firewall $old" >&2
    done

    ip=$(curl -fsS -4 https://api.ipify.org)
    [[ $ip =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || { echo "Could not detect runner IPv4" >&2; exit 1; }
    body=$(jq -n --arg name "$name" --arg ip "$ip/32" --argjson server "$server_id" '{
        name: $name,
        labels: {purpose: "ci-deploy"},
        rules: [{direction: "in", protocol: "tcp", port: "22", source_ips: [$ip],
                 description: "Temporary CI deploy access"}],
        apply_to: [{type: "server", server: {id: $server}}]
    }')
    response=$(hc POST /firewalls -d "$body")
    # shellcheck disable=SC2046 # action IDs are numbers
    wait_actions $(jq -r '.actions[].id' <<<"$response")
    echo "Opened port 22 to $ip/32 with firewall $name"
    ;;
close)
    fw_id=$(hc GET "/firewalls?name=$name" | jq -r '.firewalls[0].id // empty')
    [[ -n $fw_id ]] || { echo "No firewall $name to remove"; exit 0; }
    remove_firewall "$fw_id"
    echo "Removed firewall $name"
    ;;
*)
    echo "usage: $0 open|close <run-id>" >&2
    exit 2
    ;;
esac
