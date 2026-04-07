#!/bin/bash

set -euo pipefail

usage() {
    cat <<'EOF'
Usage: ./run_idm.sh <scenario> [-u|--sshuser <user>]

Scenarios:
  primary
  replicas
EOF
}

[ "$#" -ge 1 ] || {
    usage
    exit 1
}

scenario="$1"
shift

GREEN='\033[0;32m'
NC='\033[0m'
printf "${GREEN}Start Time: %(%T)T${NC}\n" -1
SECONDS=0

sshuser="ansiblerunner"

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        -u|--sshuser)
            sshuser="$2"
            shift
            ;;
        *)
            echo "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
    shift
done

inventory="/rhis/vars/external_inventory/inventory"
playbook=""
limit=""

case "$scenario" in
    primary)
        echo "Using rhis-builder-idm to build idm_primary from default inventory"
        playbook="main.yml"
        limit="idm_primary"
        ;;
    replicas)
        echo "Using rhis-builder-idm to build idm_replicas from default inventory"
        playbook="replicas_main.yml"
        limit="idm_replicas"
        ;;
    *)
        echo "Unknown scenario: $scenario"
        usage
        exit 1
        ;;
esac

ansible-playbook --inventory "$inventory" \
                 --user "$sshuser" \
                 --ask-pass \
                 --ask-vault-pass \
                 --extra-vars "vault_dir=/rhis/vars/vault" \
                 --limit="$limit" \
                 "$playbook"

duration=$SECONDS
printf "\n${GREEN}End Time: %(%T)T${NC}\n" -1
TZ=UTC0 printf "${GREEN}Elapsed Time: %(%T)T${NC}\n" "$duration"
