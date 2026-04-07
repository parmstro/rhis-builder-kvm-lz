#!/bin/bash

set -euo pipefail

usage() {
    cat <<'EOF'
Usage: ./run_aap.sh <scenario> [-u|--sshuser <user>]

Scenarios:
  build24-controller
  build24-hub
  build25-controller
  build25-hub
  configure-controller
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

inventory=""
playbook=""
limit="platform_installer"
extra_args=()

case "$scenario" in
    build24-controller)
        echo "Using rhis-builder-aap to build AAP 2.4 controller from default inventory"
        inventory="/rhis/vars/external_inventory/inventory"
        playbook="main.yml"
        ;;
    build24-hub)
        echo "Using rhis-builder-aap to build AAP 2.4 hub from standalone hub24 inventory"
        inventory="/rhis/vars/external_inventory/inventory_standalone_hub24"
        playbook="main.yml"
        ;;
    build25-controller)
        echo "Using rhis-builder-aap to build AAP 2.5 controller from standalone controller 2.5 inventory"
        inventory="/rhis/vars/external_inventory/inventory_standalone_controller25"
        playbook="main.yml"
        ;;
    build25-hub)
        echo "Using rhis-builder-aap to build AAP 2.5 hub from standalone hub25 inventory"
        inventory="/rhis/vars/external_inventory/inventory_standalone_hub25"
        playbook="main.yml"
        ;;
    configure-controller)
        echo "Using rhis-builder-aap to configure the AAP controller from default inventory"
        inventory="/rhis/vars/external_inventory/inventory"
        playbook="run_role.yml"
        extra_args+=(--extra-vars "role_name=platform_post")
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
                 "${extra_args[@]}" \
                 "$playbook"

duration=$SECONDS
printf "\n${GREEN}End Time: %(%T)T${NC}\n" -1
TZ=UTC0 printf "${GREEN}Elapsed Time: %(%T)T${NC}\n" "$duration"
