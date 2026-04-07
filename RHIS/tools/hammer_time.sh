#!/usr/bin/env bash
# =============================================================================
# hammer_time.sh — Standalone Satellite post-install configuration via Hammer
# =============================================================================
# Mirrors the full rhis-builder-satellite Ansible role sequence using the
# hammer CLI directly on the Satellite host or from a controller with hammer
# installed and ~/.hammer/cli_config.yml configured.
#
# Variable source priority (highest → lowest):
#   1. Environment variables set before calling this script
#   2. ~/.ansible/conf/env.yml  (ansible-vault encrypted — uses vault pass file)
#   3. Hard-coded defaults matching the RHIS content profile
#
# Usage:
#   ./tools/hammer_time.sh [--step <name>] [--dry-run] [--help]
#
# Steps (run in order by default — mirrors rhis-builder-satellite main.yml):
#   configure_hammer        Write ~/.hammer/cli_config.yml (respects SUDO_USER)
#   health_check            Ping Satellite API / satellite-maintain
#   organizations           Ensure the REDHAT org exists
#   locations               Ensure the CORE location exists
#   lifecycle_environments  Create DEV/TEST/PROD for RHEL 9 and RHEL 10
#   scp_manifest            Copy ~/Downloads/manifest*.zip from installer host → Satellite
#   import_manifest         Upload subscription manifest ZIP via hammer subscription upload
#   content_credentials     Import Red Hat GPG release key
#   repository_sets         Enable RHEL 9/10 BaseOS + AppStream repo sets
#   sync_repos              Kick off product sync + attach daily sync plan (async)
#   content_views           Create CVs for RHEL 9 and RHEL 10
#   publish_content_views   Publish (or force-publish) CVs to Library
#   installation_media      Register RHEL 9/10 kickstart installation media paths
#   partition_tables        Scope built-in kickstart partition tables to org/loc
#   provisioning_templates  Scope and lock built-in PXE/Kickstart/Grub2 templates
#   activation_keys         Create per-lifecycle activation keys
#   operating_systems       Register RHEL 9 and RHEL 10 OS records
#   smart_proxy             Ensure local proxy features (TFTP/DNS/DHCP/HTTPBoot)
#   pxe_setup               Install TFTP packages + build PXELinux and Grub2 defaults
#   realms                  Register IdM/Kerberos realm with Satellite
#   domains                 Configure the Satellite DNS domain
#   subnets                 Configure provisioning subnet (PXE/UEFI/DHCP/DNS proxies)
#   compute_resources       Register libvirt compute resource
#   compute_resource_images Register libvirt base images for image-based provisioning
#   compute_profiles        Create RHIS_Standard VM sizing profile
#   settings                Apply global Satellite settings via hammer
#   global_parameters       Set Foreman global parameters
#   hostgroups              Create RHEL9 / RHEL10 / Satellite hostgroups
#   discovery_rules         Auto-provision rules mapping discovered hosts to hostgroups
#   user_roles              Create RBAC roles (viewer, manager)
#   user_groups             Create Satellite user groups mapped to IdM groups
#   user_groups_external    Link Satellite user groups to IdM LDAP groups
#   users                   Ensure the admin user account
#   insights_satellite      Register the Satellite host to Red Hat Insights via rhc
#   insights_nodes          Enable Insights + RHC on all provisioned nodes via rex
#
# Flags:
#   --step <name>   Run only the named step (repeatable)
#   --dry-run       Print hammer commands without executing them
#   --help          Print this message and exit
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# When invoked via sudo, HOME becomes /root but the vault/env files live under
# the real user's home. Prefer SUDO_USER; if running as root with no SUDO_USER
# (e.g. direct sudo sh), fall back to 'admin'.
_real_user="${SUDO_USER:-${USER}}"
# Force real user to sgallego only on the installer host (not when already running on Satellite)
if [ "${_real_user}" = "root" ] && [ "${HAMMER_REMOTE_EXEC:-0}" -eq 0 ]; then
    _real_user="sgallego"
fi
REAL_HOME="$(eval echo ~"${_real_user}" 2>/dev/null || getent passwd "${_real_user}" | cut -d: -f6 2>/dev/null || echo "/home/${_real_user}")"
ENV_FILE="${ANSIBLE_ENV_FILE:-${REAL_HOME}/.ansible/conf/env.yml}"
VAULT_PASS_FILE="${ANSIBLE_VAULT_PASS_FILE:-${REAL_HOME}/.ansible/conf/.vaultpass.txt}"
HAMMER_HOME="${REAL_HOME}/.hammer"
DRY_RUN=0
SELECTED_STEPS=()

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log()  { printf '[hammer_time] %s\n' "$*" >&2; }
ok()   { printf '[hammer_time] ✓ %s\n' "$*" >&2; }
warn() { printf '[hammer_time] ⚠  %s\n' "$*" >&2; }
die()  { printf '[hammer_time] ✗ ERROR: %s\n' "$*" >&2; exit 1; }

h() {
    # Execute a hammer command — or print it in dry-run mode.
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '  [DRY-RUN] hammer %s\n' "$*"
        return 0
    fi
    hammer "$@"
}

usage() {
    sed -n '/^# Usage:/,/^# =====\+$/p' "${BASH_SOURCE[0]}" | head -n -1 | sed 's/^# //'
    exit 0
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)   DRY_RUN=1; shift ;;
        --step)      SELECTED_STEPS+=("$2"); shift 2 ;;
        --local)     HAMMER_LOCAL=1; shift ;;
        --help|-h)   usage ;;
        *) die "Unknown argument: $1 (try --help)" ;;
    esac
done
HAMMER_LOCAL="${HAMMER_LOCAL:-0}"

# ---------------------------------------------------------------------------
# Load variables from ansible-vault env.yml
# ---------------------------------------------------------------------------
load_env_yml() {
    [ -f "$ENV_FILE" ] || return 0
    log "Loading credentials from $ENV_FILE"

    local vault_pass_arg=""
    if [ -f "$VAULT_PASS_FILE" ]; then
        vault_pass_arg="--vault-password-file $VAULT_PASS_FILE"
    elif command -v ansible-vault &>/dev/null; then
        vault_pass_arg="--ask-vault-pass"
    fi

    local plain
    if command -v ansible-vault &>/dev/null && [ -n "$vault_pass_arg" ]; then
        # shellcheck disable=SC2086
        plain="$(ansible-vault view $vault_pass_arg "$ENV_FILE" 2>/dev/null)" || plain=""
    else
        plain="$(cat "$ENV_FILE")"
    fi

    [ -z "$plain" ] && return 0

    _load_yml_key() {
        local var="$1" key="$2" val
        # Only set if not already set from the environment
        [ -n "${!var:-}" ] && return 0
        # || true: grep exits 1 when the key is absent; don't let pipefail kill us
        val="$(printf '%s\n' "$plain" | grep -E "^${key}:" \
            | sed -E "s/^${key}:[[:space:]]*['\"]?//;s/['\"]?[[:space:]]*$//" | head -1)" || true
        # [ -n ... ] && ... returns 1 when val is empty — guard with || true so
        # set -e doesn't kill the script on keys that aren't in env.yml
        [ -n "$val" ] && printf -v "$var" '%s' "$val" || true
    }

    _load_yml_key SAT_HOSTNAME       sat_hostname
    _load_yml_key SAT_IP             sat_ip
    _load_yml_key SAT_ORG           sat_org
    _load_yml_key SAT_LOC           sat_loc
    _load_yml_key SAT_DOMAIN        sat_domain
    _load_yml_key ADMIN_USER         admin_user
    _load_yml_key ADMIN_PASS         admin_pass
    _load_yml_key SAT_ADMIN_PASS     sat_admin_pass
    _load_yml_key GLOBAL_ADMIN_PASS  global_admin_password
    _load_yml_key DOMAIN             domain
    _load_yml_key REALM              realm
    _load_yml_key INTERNAL_NETWORK   internal_network
    _load_yml_key NETMASK            netmask
    _load_yml_key INTERNAL_GW        internal_gw
    _load_yml_key SAT_RHEL10_BASEOS_REPO  sat_rhel10_baseos_repo
    _load_yml_key SAT_RHEL10_APPSTREAM_REPO sat_rhel10_appstream_repo
    _load_yml_key SAT_RHEL9_BASEOS_REPO  sat_rhel9_baseos_repo
    _load_yml_key SAT_RHEL9_APPSTREAM_REPO sat_rhel9_appstream_repo
    _load_yml_key SAT_PROVISIONING_SUBNET sat_provisioning_subnet
    _load_yml_key SAT_PROVISIONING_NETMASK sat_provisioning_netmask
    _load_yml_key SAT_PROVISIONING_GW sat_provisioning_gw
    _load_yml_key SAT_PROVISIONING_DHCP_START sat_provisioning_dhcp_start
    _load_yml_key SAT_PROVISIONING_DHCP_END sat_provisioning_dhcp_end
    _load_yml_key SAT_PROVISIONING_DNS_PRIMARY sat_provisioning_dns_primary
    _load_yml_key SAT_PROVISIONING_DNS_SECONDARY sat_provisioning_dns_secondary
    _load_yml_key SAT_DNS_ZONE       sat_dns_zone
    _load_yml_key SAT_MANIFEST_PATH  sat_manifest_path
    _load_yml_key IDM_HOSTNAME       idm_hostname
    _load_yml_key IDM_IP             idm_ip
    _load_yml_key LIBVIRT_RHEL9_IMAGE  libvirt_rhel9_image
    _load_yml_key LIBVIRT_RHEL10_IMAGE libvirt_rhel10_image
}

load_env_yml

# ---------------------------------------------------------------------------
# Resolve runtime values (env.yml → defaults)
# ---------------------------------------------------------------------------
# Connection                                    # env.yml key
SAT_URL="${SAT_URL:-https://${SAT_HOSTNAME:-${SAT_IP:-10.168.128.1}}}"
SAT_USER="${SAT_USER:-${ADMIN_USER:-admin}}"
SAT_PASS="${SAT_PASS:-${SAT_ADMIN_PASS:-${GLOBAL_ADMIN_PASS:-${ADMIN_PASS:-}}}}"
ORG="${ORG:-${SAT_ORG:-REDHAT}}"               # sat_org
LOC="${LOC:-${SAT_LOC:-CORE}}"                 # sat_loc
DOMAIN="${DOMAIN:-prod.spg}"                    # domain / sat_domain

# Repository labels                             # env.yml key
RHEL10_BASEOS="${SAT_RHEL10_BASEOS_REPO:-rhel-10-for-x86_64-baseos-rpms}"
RHEL10_APPSTREAM="${SAT_RHEL10_APPSTREAM_REPO:-rhel-10-for-x86_64-appstream-rpms}"
RHEL9_BASEOS="${SAT_RHEL9_BASEOS_REPO:-rhel-9-for-x86_64-baseos-rpms}"
RHEL9_APPSTREAM="${SAT_RHEL9_APPSTREAM_REPO:-rhel-9-for-x86_64-appstream-rpms}"

# Provisioning network                          # env.yml key
PROV_SUBNET="${SAT_PROVISIONING_SUBNET:-${INTERNAL_NETWORK:-10.168.0.0}}"
PROV_NETMASK="${SAT_PROVISIONING_NETMASK:-${NETMASK:-255.255.0.0}}"
PROV_GW="${SAT_PROVISIONING_GW:-${INTERNAL_GW:-10.168.0.1}}"
PROV_DHCP_START="${SAT_PROVISIONING_DHCP_START:-10.168.130.1}"
PROV_DHCP_END="${SAT_PROVISIONING_DHCP_END:-10.168.255.254}"
PROV_DNS_PRIMARY="${SAT_PROVISIONING_DNS_PRIMARY:-${SAT_IP:-10.168.128.1}}"
PROV_DNS_SECONDARY="${SAT_PROVISIONING_DNS_SECONDARY:-8.8.8.8}"
DNS_ZONE="${SAT_DNS_ZONE:-${DOMAIN}}"           # sat_dns_zone
SAT_IP_ADDR="${SAT_IP:-10.168.128.1}"           # sat_ip
IDM_IP_ADDR="${IDM_IP:-10.168.128.3}"           # idm_ip
IDM_FQDN="${IDM_HOSTNAME:-idm.${DOMAIN}}"       # idm_hostname
MANIFEST_PATH="${SAT_MANIFEST_PATH:-}"          # sat_manifest_path

# If SAT_MANIFEST_PATH is not set, auto-discover the newest manifest ZIP in the real user's Downloads
# Skip discovery on the remote (MANIFEST_REMOTE_PATH is already injected as an env var)
if [ -z "$MANIFEST_PATH" ] && [ "${HAMMER_REMOTE_EXEC:-0}" -eq 0 ]; then
    # Pick the most recently modified manifest*.zip from the installer host home dir
    # || true: ls exits 1 when no files match — don't let pipefail kill the script
    _discovered="$(ls -t "${REAL_HOME}/Downloads/"manifest*.zip 2>/dev/null | head -1)" || true
    [ -n "$_discovered" ] && MANIFEST_PATH="$_discovered"
elif [ -z "$MANIFEST_PATH" ] && [ "${HAMMER_REMOTE_EXEC:-0}" -eq 1 ]; then
    # On the remote, MANIFEST_REMOTE_PATH is the local path to the manifest
    MANIFEST_PATH="${MANIFEST_REMOTE_PATH:-}"
fi

# Satellite SSH connection used by scp_manifest to copy the file before importing
MANIFEST_SCP_USER="${MANIFEST_SCP_USER:-root}"
MANIFEST_SCP_HOST="${MANIFEST_SCP_HOST:-${SAT_IP_ADDR}}"
MANIFEST_SCP_KEY="${MANIFEST_SCP_KEY:-${REAL_HOME}/.ssh/rhis-installer/id_rsa}"
# Destination path on the Satellite host
MANIFEST_REMOTE_PATH="${MANIFEST_REMOTE_PATH:-/root/manifest.zip}"

# Libvirt base image UUIDs for image-based provisioning      # env.yml key
# Set to the volume name (e.g. rhel9-base.qcow2) in the libvirt storage pool
LIBVIRT_RHEL9_IMAGE="${LIBVIRT_RHEL9_IMAGE:-}"             # libvirt_rhel9_image
LIBVIRT_RHEL10_IMAGE="${LIBVIRT_RHEL10_IMAGE:-}"           # libvirt_rhel10_image
LIBVIRT_STORAGE_POOL="${LIBVIRT_STORAGE_POOL:-default}"    # libvirt_storage_pool
LIBVIRT_NETWORK="${LIBVIRT_NETWORK:-default}"              # libvirt_network

[ -z "$SAT_PASS" ] && die "SAT_PASS / sat_admin_pass / admin_pass is not set. Set it via env.yml or export SAT_PASS=..."

# ---------------------------------------------------------------------------
# Remote dispatch — if hammer is not installed locally, SCP this script to the
# Satellite and run it there with all resolved credentials as env vars.
# Skip when --local is passed or when HAMMER_REMOTE_EXEC=1 (already on remote).
# ---------------------------------------------------------------------------
if [ "${HAMMER_LOCAL:-0}" -eq 0 ] \
   && [ "${HAMMER_REMOTE_EXEC:-0}" -eq 0 ] \
   && ! command -v hammer &>/dev/null; then

    _remote_user="${MANIFEST_SCP_USER:-root}"
    _remote_host="${SAT_IP_ADDR}"
    _ssh_key_arg=""
    [ -f "${MANIFEST_SCP_KEY}" ] && _ssh_key_arg="-i ${MANIFEST_SCP_KEY}"
    _remote_script="/root/hammer_time.sh"

    log "hammer not found locally — dispatching to ${_remote_user}@${_remote_host}"

    # Copy the script to the Satellite
    # shellcheck disable=SC2086
    scp -q -o StrictHostKeyChecking=no -o ForwardX11=no \
        ${_ssh_key_arg} \
        "${BASH_SOURCE[0]}" \
        "${_remote_user}@${_remote_host}:${_remote_script}" \
        || die "Failed to SCP hammer_time.sh to ${_remote_user}@${_remote_host}"

    # Copy the manifest ZIP to the Satellite if it exists locally
    if [ -n "${MANIFEST_PATH:-}" ] && [ -f "${MANIFEST_PATH}" ]; then
        log "Copying manifest $(basename "${MANIFEST_PATH}") → ${_remote_user}@${_remote_host}:${MANIFEST_REMOTE_PATH}"
        # shellcheck disable=SC2086
        scp -q -o StrictHostKeyChecking=no -o ForwardX11=no \
            ${_ssh_key_arg} \
            "${MANIFEST_PATH}" \
            "${_remote_user}@${_remote_host}:${MANIFEST_REMOTE_PATH}" \
            || warn "Could not SCP manifest to ${_remote_host} — import_manifest may fail."
    fi

    # Build --step flags to forward
    _step_flags=""
    for _s in "${SELECTED_STEPS[@]+${SELECTED_STEPS[@]}}"; do
        _step_flags+="--step ${_s} "
    done
    [ "${DRY_RUN}" -eq 1 ] && _step_flags+="--dry-run "

    log "Executing ${_remote_script} on ${_remote_user}@${_remote_host}"
    # Run without TTY (-T) to avoid xauth/X11 noise; env vars carry all credentials.
    # ServerAliveInterval keeps the connection alive across long-running hammer tasks.
    # shellcheck disable=SC2029,SC2086
    ssh -T -o StrictHostKeyChecking=no -o ForwardX11=no \
        -o ServerAliveInterval=30 -o ServerAliveCountMax=10 \
        ${_ssh_key_arg} \
        "${_remote_user}@${_remote_host}" \
        "HAMMER_REMOTE_EXEC=1 \
         SAT_URL='${SAT_URL}' \
         SAT_USER='${SAT_USER}' \
         SAT_PASS='${SAT_PASS}' \
         ORG='${ORG}' \
         LOC='${LOC}' \
         DOMAIN='${DOMAIN}' \
         REALM='${REALM:-}' \
         MANIFEST_REMOTE_PATH='${MANIFEST_REMOTE_PATH}' \
         bash ${_remote_script} --local ${_step_flags}"
    exit $?
fi

# ---------------------------------------------------------------------------
# Step registry
# ---------------------------------------------------------------------------
ALL_STEPS=(
    configure_hammer
    health_check
    organizations
    locations
    lifecycle_environments
    scp_manifest
    import_manifest
    content_credentials
    repository_sets
    sync_repos
    content_views
    publish_content_views
    installation_media
    partition_tables
    provisioning_templates
    activation_keys
    operating_systems
    smart_proxy
    pxe_setup
    realms
    domains
    subnets
    compute_resources
    compute_resource_images
    compute_profiles
    settings
    global_parameters
    hostgroups
    discovery_rules
    user_roles
    user_groups
    user_groups_external
    users
    insights_satellite
    insights_nodes
)

run_step() {
    local name="$1"
    if [ "${#SELECTED_STEPS[@]}" -eq 0 ]; then
        return 0   # no filter → run all
    fi
    for s in "${SELECTED_STEPS[@]}"; do
        [ "$s" = "$name" ] && return 0
    done
    return 1
}

# =============================================================================
# STEP: organizations
# Mirror: roles/organizations/tasks/ensure_organization.yml
# Ensures the primary Satellite organization exists before any content work.
# =============================================================================
step_organizations() {
    log "=== organizations ==="
    log "Ensuring organization: ${ORG}"
    h organization create \
        --name "$ORG" \
        --label "$ORG" \
        --description "RHIS primary organization" 2>/dev/null \
        || warn "Organization ${ORG} may already exist — continuing."
    ok "organization ${ORG}"
}

# =============================================================================
# STEP: locations
# Mirror: roles/locations/tasks/ensure_location.yml
# Ensures the primary Satellite location exists.
# =============================================================================
step_locations() {
    log "=== locations ==="
    log "Ensuring location: ${LOC}"
    h location create \
        --name "$LOC" \
        --description "RHIS primary location" 2>/dev/null \
        || warn "Location ${LOC} may already exist — continuing."
    # Attach org to location
    h location add-organization --name "$LOC" --organization "$ORG" 2>/dev/null || true
    ok "location ${LOC}"
}

# =============================================================================
# STEP: configure_hammer
# Mirror: tasks/configure_hammer.yml
# Writes ${HAMMER_HOME}/cli_config.yml so subsequent hammer calls are auth-free
# =============================================================================
step_configure_hammer() {
    log "=== configure_hammer ==="
    if [ "$DRY_RUN" -eq 1 ]; then
        log "[DRY-RUN] Would write ${HAMMER_HOME}/cli_config.yml for host=${SAT_URL}, user=${SAT_USER}"
        return 0
    fi

    install -d -m 0700 "${HAMMER_HOME}" 2>/dev/null || true
    cat > "${HAMMER_HOME}/cli_config.yml" <<HAMMER_CFG
:foreman:
  :host: '${SAT_URL}'
  :username: '${SAT_USER}'
  :password: '${SAT_PASS}'
  :ssl_verify: false
:log_dir: '/var/log/foreman'
:log_level: 'error'
HAMMER_CFG
    chmod 0600 "${HAMMER_HOME}/cli_config.yml"
    ok "Hammer config written to ${HAMMER_HOME}/cli_config.yml"
}

# =============================================================================
# STEP: health_check
# Mirror: tasks/configure_hammer.yml (post-config ping)
# =============================================================================
step_health_check() {
    log "=== health_check ==="
    log "Pinging Satellite API at ${SAT_URL}/api/status ..."
    local status_code
    status_code="$(curl -sk -o /dev/null -w '%{http_code}' "${SAT_URL}/api/status")"
    if [[ "$status_code" =~ ^(200|401|403)$ ]]; then
        ok "Satellite API reachable (HTTP ${status_code})"
    else
        die "Satellite API returned HTTP ${status_code} — is Satellite running?"
    fi

    if command -v satellite-maintain &>/dev/null; then
        h ping --server "${SAT_URL}" 2>/dev/null || warn "satellite-maintain ping reported issues; continuing."
    fi
}

# =============================================================================
# STEP: lifecycle_environments
# Mirror: roles/lifecycle_environments/tasks/
# Creates: Library → DEV → TEST → PROD for RHEL 9 and RHEL 10
# =============================================================================
step_lifecycle_environments() {
    log "=== lifecycle_environments ==="

    # Each entry: "name|prior"
    local -a envs=(
        "DEV_RHEL_10_x86_64|Library"
        "TEST_RHEL_10_x86_64|DEV_RHEL_10_x86_64"
        "PROD_RHEL_10_x86_64|TEST_RHEL_10_x86_64"
        "DEV_RHEL_9_x86_64|Library"
        "TEST_RHEL_9_x86_64|DEV_RHEL_9_x86_64"
        "PROD_RHEL_9_x86_64|TEST_RHEL_9_x86_64"
    )

    for entry in "${envs[@]}"; do
        local env_name prior
        env_name="${entry%%|*}"
        prior="${entry##*|}"
        log "Ensuring lifecycle environment: ${env_name} (prior: ${prior})"
        h lifecycle-environment create \
            --organization "$ORG" \
            --name "$env_name" \
            --label "$env_name" \
            --prior "$prior" 2>/dev/null \
            || h lifecycle-environment update \
                --organization "$ORG" \
                --name "$env_name" \
                --description "RHIS managed lifecycle environment" 2>/dev/null \
            || warn "lifecycle-environment ${env_name} may already exist — continuing."
        ok "lifecycle-environment ${env_name}"
    done
}

# =============================================================================
# STEP: scp_manifest
# Copies ~/Downloads/manifest*.zip from the installer host to the Satellite.
# Runs before import_manifest so hammer can reference a local path on Satellite.
#
# Override variables:
#   MANIFEST_PATH          Local path to the ZIP (auto-discovered from ~/Downloads/)
#   MANIFEST_SCP_USER      SSH user on Satellite      (default: admin / admin_user)
#   MANIFEST_SCP_HOST      Satellite IP/hostname       (default: sat_ip)
#   MANIFEST_SCP_KEY       SSH private key path        (default: ~/.ssh/rhis-installer/id_rsa)
#   MANIFEST_REMOTE_PATH   Destination path on SAT     (default: /root/manifest.zip)
#
# Skipped automatically when:
#   - MANIFEST_PATH is empty AND no manifest*.zip found in ~/Downloads/
#   - The script is already running ON the Satellite (MANIFEST_SCP_HOST matches
#     a local address / hostname)
# =============================================================================
step_scp_manifest() {
    log "=== scp_manifest ==="

    if [ -z "${MANIFEST_PATH:-}" ]; then
        warn "No manifest ZIP found — skipping scp_manifest."
        warn "Put a manifest*.zip in ~/Downloads/ or set SAT_MANIFEST_PATH."
        return 0
    fi

    if [ ! -f "$MANIFEST_PATH" ]; then
        warn "Manifest file not found at ${MANIFEST_PATH} — skipping scp_manifest."
        return 0
    fi

    # Detect if we are already running on the Satellite itself; if so, skip SCP
    # and just set MANIFEST_REMOTE_PATH to the local path.
    local local_hostname
    local_hostname="$(hostname -f 2>/dev/null || hostname)"
    if [ "${HAMMER_REMOTE_EXEC:-0}" -eq 1 ] || \
       [[ "$local_hostname" == *"${MANIFEST_SCP_HOST}"* ]] || \
       [[ "${MANIFEST_SCP_HOST}" == "127.0.0.1" ]] || \
       [[ "${MANIFEST_SCP_HOST}" == "localhost" ]]; then
        MANIFEST_REMOTE_PATH="$MANIFEST_PATH"
        ok "Running on Satellite — using local path: ${MANIFEST_REMOTE_PATH}"
        return 0
    fi

    log "Copying ${MANIFEST_PATH} → ${MANIFEST_SCP_USER}@${MANIFEST_SCP_HOST}:${MANIFEST_REMOTE_PATH}"

    local scp_opts=(
        -o StrictHostKeyChecking=no
        -o ConnectTimeout=15
        -q
    )
    [ -f "$MANIFEST_SCP_KEY" ] && scp_opts+=( -i "$MANIFEST_SCP_KEY" )

    if [ "$DRY_RUN" -eq 1 ]; then
        log "[DRY-RUN] scp ${scp_opts[*]} ${MANIFEST_PATH} ${MANIFEST_SCP_USER}@${MANIFEST_SCP_HOST}:${MANIFEST_REMOTE_PATH}"
        return 0
    fi

    scp "${scp_opts[@]}" \
        "$MANIFEST_PATH" \
        "${MANIFEST_SCP_USER}@${MANIFEST_SCP_HOST}:${MANIFEST_REMOTE_PATH}" \
        || die "scp failed — check SSH access to ${MANIFEST_SCP_HOST} as ${MANIFEST_SCP_USER}"
    ok "Manifest copied to ${MANIFEST_SCP_HOST}:${MANIFEST_REMOTE_PATH}"
}

# =============================================================================
# STEP: import_manifest
# Mirror: roles/subscription_manifests / redhat_manifests / tasks/import_manifest.yml
# Runs hammer subscription upload using the path that scp_manifest staged on SAT.
# If running directly on the Satellite, MANIFEST_REMOTE_PATH == MANIFEST_PATH.
# =============================================================================
step_import_manifest() {
    log "=== import_manifest ==="

    # Prefer the remote-staged path (populated by scp_manifest); fall back to
    # the original local path when running directly on the Satellite.
    local upload_path="${MANIFEST_REMOTE_PATH:-${MANIFEST_PATH:-}}"

    if [ -z "$upload_path" ]; then
        warn "No manifest path available — skipping import."
        warn "Run scp_manifest first, or set SAT_MANIFEST_PATH / MANIFEST_REMOTE_PATH."
        return 0
    fi

    log "Uploading manifest ${upload_path} to organization ${ORG}"
    local _out _rc
    _out="$(h subscription upload --organization "$ORG" --file "$upload_path" 2>&1)" && _rc=0 || _rc=$?
    if [ $_rc -eq 0 ]; then
        ok "Manifest uploaded from ${upload_path}"
    elif echo "$_out" | grep -qiE "already.imported|MANIFEST_OLD|older than existing"; then
        warn "Manifest already imported or older than existing data — skipping. (${_out##*$'\n'})"
        ok "Manifest already present in org ${ORG}"
    else
        printf '%s\n' "$_out" >&2
        die "Manifest upload failed (exit ${_rc})"
    fi
}

# =============================================================================
# STEP: content_credentials
# Mirror: roles/content_credentials/tasks/ensure_content_credential.yml
# Imports the Red Hat release GPG key so Satellite can verify package signatures.
# The key is downloaded from access.redhat.com if not already present locally.
# =============================================================================
step_content_credentials() {
    log "=== content_credentials ==="
    local gpg_key_name="RPM-GPG-KEY-redhat-release"
    local gpg_key_url="https://www.redhat.com/security/team/key/RPM-GPG-KEY-redhat-release"
    local gpg_key_file="/tmp/RPM-GPG-KEY-redhat-release"

    if [ "$DRY_RUN" -eq 1 ]; then
        log "[DRY-RUN] Would import GPG key '${gpg_key_name}' into org ${ORG}"
        return 0
    fi

    if [ ! -f "$gpg_key_file" ]; then
        log "Downloading ${gpg_key_name} from ${gpg_key_url}"
        curl -skL "$gpg_key_url" -o "$gpg_key_file" \
            || die "Failed to download Red Hat GPG key — check network/CDN reachability."
    fi

    h content-credentials create \
        --organization "$ORG" \
        --name "$gpg_key_name" \
        --content-type gpg_key \
        --path "$gpg_key_file" 2>/dev/null \
        || h content-credentials update \
            --organization "$ORG" \
            --name "$gpg_key_name" \
            --path "$gpg_key_file" 2>/dev/null \
        || warn "content-credential ${gpg_key_name} — could not create or update."
    ok "content-credential ${gpg_key_name}"
}

# =============================================================================
# STEP: repository_sets
# Mirror: roles/repository_sets/tasks/ensure_repository_set.yml
# Enables RHEL 9 and RHEL 10 BaseOS + AppStream repo sets
# =============================================================================
step_repository_sets() {
    log "=== repository_sets ==="

    # Each entry: "product|repo_set_label|repo_name"
    local -a repos=(
        "Red Hat Enterprise Linux for x86_64|${RHEL10_BASEOS}|Red Hat Enterprise Linux 10 for x86_64 - BaseOS (RPMs)"
        "Red Hat Enterprise Linux for x86_64|${RHEL10_APPSTREAM}|Red Hat Enterprise Linux 10 for x86_64 - AppStream (RPMs)"
        "Red Hat Enterprise Linux for x86_64|${RHEL9_BASEOS}|Red Hat Enterprise Linux 9 for x86_64 - BaseOS (RPMs)"
        "Red Hat Enterprise Linux for x86_64|${RHEL9_APPSTREAM}|Red Hat Enterprise Linux 9 for x86_64 - AppStream (RPMs)"
    )

    for entry in "${repos[@]}"; do
        IFS='|' read -r product label set_name <<< "$entry"
        log "Enabling repository set: ${label}"
        h repository-set enable \
            --organization "$ORG" \
            --product "$product" \
            --name "$set_name" \
            --basearch x86_64 2>/dev/null \
            || warn "repo-set ${label} may already be enabled — continuing."
        ok "repository-set enabled: ${label}"
    done
}

# =============================================================================
# STEP: sync_repos
# Mirror: roles/sync_plans + tasks/sync_product.yml
# Triggers an immediate product sync (background — does not wait for completion)
# =============================================================================
step_sync_repos() {
    log "=== sync_repos ==="

    local -a products=(
        "Red Hat Enterprise Linux for x86_64"
    )

    for product in "${products[@]}"; do
        log "Synchronizing product: ${product}"
        h product synchronize \
            --organization "$ORG" \
            --name "$product" \
            --async 2>/dev/null \
            || warn "Sync request for '${product}' may have failed — check Satellite UI."
        ok "Sync triggered (async): ${product}"
    done

    # Create a daily sync plan and attach it
    log "Ensuring daily sync plan: RHIS_Daily_Sync"
    h sync-plan create \
        --organization "$ORG" \
        --name "RHIS_Daily_Sync" \
        --interval daily \
        --sync-date "$(date +%Y-%m-%dT02:00:00)" \
        --enabled true 2>/dev/null \
        || warn "Sync plan RHIS_Daily_Sync may already exist — continuing."

    for product in "${products[@]}"; do
        h product set-sync-plan \
            --organization "$ORG" \
            --name "$product" \
            --sync-plan "RHIS_Daily_Sync" 2>/dev/null \
            || warn "Could not attach sync plan to ${product}"
    done
    ok "Sync plan attached"
}

# =============================================================================
# STEP: content_views
# Mirror: roles/content_views/tasks/create_cv.yml
# =============================================================================
step_content_views() {
    log "=== content_views ==="

    # Format: "cv_name|repo1,repo2,..."
    local -a cvs=(
        "rhel-10-for-x86_64|${RHEL10_BASEOS},${RHEL10_APPSTREAM}"
        "rhel-9-for-x86_64|${RHEL9_BASEOS},${RHEL9_APPSTREAM}"
    )

    for entry in "${cvs[@]}"; do
        local cv_name repos_csv
        cv_name="${entry%%|*}"
        repos_csv="${entry##*|}"

        log "Ensuring content view: ${cv_name}"
        h content-view create \
            --organization "$ORG" \
            --name "$cv_name" \
            --label "$cv_name" \
            --description "RHIS managed content view" 2>/dev/null \
            || warn "content-view ${cv_name} may already exist — continuing."

        IFS=',' read -ra repos <<< "$repos_csv"
        for repo in "${repos[@]}"; do
            log "  Adding repository ${repo} → ${cv_name}"
            h content-view add-repository \
                --organization "$ORG" \
                --name "$cv_name" \
                --repository "$repo" 2>/dev/null \
                || warn "  Repository ${repo} may already be in ${cv_name} — continuing."
        done
        ok "content-view ${cv_name} configured"
    done
}

# =============================================================================
# STEP: publish_content_views
# Mirror: roles/content_views/tasks/publish_cv_version.yml
# =============================================================================
step_publish_content_views() {
    log "=== publish_content_views ==="

    local -a cvs=("rhel-10-for-x86_64" "rhel-9-for-x86_64")

    for cv in "${cvs[@]}"; do
        log "Publishing content view: ${cv}"
        h content-view publish \
            --organization "$ORG" \
            --name "$cv" \
            --description "Published by hammer_time.sh on $(date -u '+%Y-%m-%d %H:%M UTC')" \
            --async 2>/dev/null \
            || warn "Could not publish ${cv} — may already be publishing or up to date."
        ok "content-view published (async): ${cv}"
    done
}

# =============================================================================
# STEP: installation_media
# Mirror: roles/installation_media/tasks/ensure_installation_medium.yml
# Registers kickstart installation media for RHEL 9 and RHEL 10.
# Satellite auto-creates these when kickstart-tree repo sets are synced, but
# this step forces the correct Pulp content URL and org/location scoping.
# =============================================================================
step_installation_media() {
    log "=== installation_media ==="
    local sat_host="${SAT_HOSTNAME:-satellite.${DOMAIN}}"

    # Format: "name|pulp_path|os_family"
    # $basearch is a yum variable — escape the $ so hammer passes it literally
    local -a media=(
        "RHEL 9 Kickstart|http://${sat_host}/pulp/content/${ORG}/Library/content/dist/rhel9/9/\$basearch/kickstart/|Redhat"
        "RHEL 10 Kickstart|http://${sat_host}/pulp/content/${ORG}/Library/content/dist/rhel10/10/\$basearch/kickstart/|Redhat"
    )

    for entry in "${media[@]}"; do
        IFS='|' read -r med_name med_path med_family <<< "$entry"
        log "  Ensuring installation medium: ${med_name}"
        if [ "$DRY_RUN" -eq 1 ]; then
            log "  [DRY-RUN] hammer medium create --name '${med_name}' --path '${med_path}'"
            continue
        fi
        h medium create \
            --name "$med_name" \
            --path "$med_path" \
            --os-family "$med_family" \
            --organizations "$ORG" \
            --locations "$LOC" 2>/dev/null \
            || h medium update \
                --name "$med_name" \
                --path "$med_path" \
                --os-family "$med_family" 2>/dev/null \
            || warn "medium ${med_name} — could not create or update."
        ok "medium ${med_name}"
    done
}

# =============================================================================
# STEP: partition_tables
# Mirror: roles/partition_tables/tasks/ensure_ptable.yml
# Ensures built-in RHEL kickstart partition tables are scoped to the org/loc.
# Custom tables require Jinja2 template files — use the Ansible role for those.
# =============================================================================
step_partition_tables() {
    log "=== partition_tables ==="
    # These ship with every Satellite installation.
    local -a ptables=(
        "Kickstart default"
        "Kickstart default oVirt"
        "Kickstart BIOS Grub2"
        "Kickstart default thin"
    )
    for ptable in "${ptables[@]}"; do
        log "  Scoping partition table: ${ptable}"
        h partition-table update \
            --name "$ptable" \
            --organizations "$ORG" \
            --locations "$LOC" 2>/dev/null \
            || warn "partition-table '${ptable}' not found — may not exist on this version."
        ok "partition-table ${ptable}"
    done
}

# =============================================================================
# STEP: provisioning_templates
# Mirror: roles/provisioning_templates/tasks/ensure_provisioning_template.yml
# Scopes and locks built-in PXE (BIOS), Grub2 (UEFI), iPXE, and kickstart
# templates to the RHIS org/location.
# Custom templates (file-based): use the Ansible role instead.
# =============================================================================
step_provisioning_templates() {
    log "=== provisioning_templates ==="

    # Built-in templates relevant to kickstart + PXE/UEFI/iPXE provisioning
    local -a templates=(
        "Kickstart default"
        "Kickstart default PXELinux"
        "Kickstart default PXEGrub2"
        "Kickstart default iPXE"
        "Kickstart default user data"
        "Foreman Discovery"
        "PXELinux global default"
        "iPXE global default"
        "Grub2 default PXEBoot"
    )

    for tmpl in "${templates[@]}"; do
        log "  Scoping template: ${tmpl}"
        h template update \
            --name "$tmpl" \
            --organizations "$ORG" \
            --locations "$LOC" \
            --locked yes 2>/dev/null \
            || warn "template '${tmpl}' not found — may not exist on this Satellite version."
        ok "template ${tmpl}"
    done
}

# =============================================================================
# STEP: activation_keys
# Mirror: roles/activation_keys/tasks/ensure_activation_key.yml
# Creates per-lifecycle activation keys for RHEL 9 and RHEL 10
# =============================================================================
step_activation_keys() {
    log "=== activation_keys ==="

    # Format: "key_name|lifecycle_env|content_view"
    local -a keys=(
        "DEV_RHEL_10_x86_64|DEV_RHEL_10_x86_64|rhel-10-for-x86_64"
        "TEST_RHEL_10_x86_64|TEST_RHEL_10_x86_64|rhel-10-for-x86_64"
        "PROD_RHEL_10_x86_64|PROD_RHEL_10_x86_64|rhel-10-for-x86_64"
        "DEV_RHEL_9_x86_64|DEV_RHEL_9_x86_64|rhel-9-for-x86_64"
        "TEST_RHEL_9_x86_64|TEST_RHEL_9_x86_64|rhel-9-for-x86_64"
        "PROD_RHEL_9_x86_64|PROD_RHEL_9_x86_64|rhel-9-for-x86_64"
    )

    for entry in "${keys[@]}"; do
        IFS='|' read -r key_name lc cv <<< "$entry"
        log "Ensuring activation key: ${key_name}"
        h activation-key create \
            --organization "$ORG" \
            --name "$key_name" \
            --lifecycle-environment "$lc" \
            --content-view "$cv" \
            --unlimited-hosts 2>/dev/null \
            || h activation-key update \
                --organization "$ORG" \
                --name "$key_name" \
                --lifecycle-environment "$lc" \
                --content-view "$cv" \
                --unlimited-hosts 2>/dev/null \
            || warn "activation-key ${key_name} — update also failed; may need manual review."

        # Enable the insights-client content label so nodes get the package
        # This sets the override to enabled=1 for the insights-client repo
        h activation-key content-override \
            --organization "$ORG" \
            --name "$key_name" \
            --content-label "insights-client" \
            --value 1 2>/dev/null \
            || warn "Could not enable insights-client content on key ${key_name} — may not be entitled yet."

        ok "activation-key ${key_name}"
    done
}

# =============================================================================
# STEP: operating_systems
# Mirror: roles/operating_systems/tasks/ensure_operating_system.yml
# Registers RHEL 9 and RHEL 10 OS records with Kickstart family, major/minor,
# and links them to the partition tables and provisioning templates that
# satellite-installer creates automatically.
# =============================================================================
step_operating_systems() {
    log "=== operating_systems ==="

    # Format: "name|family|major|minor|description|password_hash"
    local -a oses=(
        "RedHat|Redhat|9|0|Red Hat Enterprise Linux 9|SHA256"
        "RedHat|Redhat|10|0|Red Hat Enterprise Linux 10|SHA256"
    )

    for entry in "${oses[@]}"; do
        IFS='|' read -r os_name os_family os_major os_minor os_desc os_hash <<< "$entry"
        log "Ensuring OS: ${os_desc} (${os_family} ${os_major}.${os_minor})"
        h os create \
            --name "$os_name" \
            --family "$os_family" \
            --major "$os_major" \
            --minor "$os_minor" \
            --description "$os_desc" \
            --password-hash "$os_hash" 2>/dev/null \
            || warn "OS ${os_desc} may already exist — continuing."
        ok "operating_system ${os_desc}"
    done
}

# =============================================================================
# STEP: smart_proxy
# Mirror: tasks/ensure_local_tftp_proxy.yml
# Refreshes the local Satellite smart proxy's feature list and ensures TFTP,
# DNS, DHCP, and HTTPBoot (UEFI) features are registered in Foreman.
# When features are missing, runs satellite-installer to enable them (idempotent).
# =============================================================================
step_smart_proxy() {
    log "=== smart_proxy ==="
    local sat_host="${SAT_HOSTNAME:-satellite.${DOMAIN}}"

    local proxy_id
    proxy_id="$(h proxy list --fields Id,Name,Url 2>/dev/null \
        | awk -F'|' -v h="$sat_host" 'tolower($3) ~ tolower(h) {gsub(/ /,"",$1); print $1}' \
        | head -1 || true)"

    if [ -z "$proxy_id" ]; then
        warn "No local smart proxy found matching '${sat_host}'."
        warn "  Run: hammer proxy list  — verify FQDN matches SAT_HOSTNAME."
        return 0
    fi

    log "  Local proxy ID: ${proxy_id} — refreshing features"
    h proxy refresh-features --id "$proxy_id" 2>/dev/null \
        || warn "proxy refresh-features failed (non-fatal)."

    local proxy_features
    proxy_features="$(h proxy info --id "$proxy_id" 2>/dev/null || true)"
    log "  Current features: $(printf '%s' "$proxy_features" | grep -i 'features' | head -3 || echo '(see above)')"

    # Determine which features still need to be enabled
    local need_tftp=0 need_dns=0 need_dhcp=0 need_httpboot=0 need_discovery=0
    printf '%s\n' "$proxy_features" | grep -qi 'TFTP'      || need_tftp=1
    printf '%s\n' "$proxy_features" | grep -qi 'DNS'       || need_dns=1
    printf '%s\n' "$proxy_features" | grep -qi 'DHCP'      || need_dhcp=1
    printf '%s\n' "$proxy_features" | grep -qi 'HTTPBoot'  || need_httpboot=1
    printf '%s\n' "$proxy_features" | grep -qi 'Discovery' || need_discovery=1

    local installer_args=()
    [ "$need_tftp" -eq 1 ]      && installer_args+=(--foreman-proxy-tftp true --foreman-proxy-tftp-managed true)
    [ "$need_dns"  -eq 1 ]      && installer_args+=(--foreman-proxy-dns true --foreman-proxy-dns-managed true)
    [ "$need_dhcp" -eq 1 ]      && installer_args+=(--foreman-proxy-dhcp true --foreman-proxy-dhcp-managed true)
    [ "$need_httpboot" -eq 1 ]  && installer_args+=(--enable-foreman-proxy-plugin-discovery)
    [ "$need_discovery" -eq 1 ] && installer_args+=(--enable-foreman-proxy-plugin-discovery)

    if [ "${#installer_args[@]}" -gt 0 ]; then
        if [ "$DRY_RUN" -eq 1 ]; then
            log "  [DRY-RUN] satellite-installer --scenario satellite ${installer_args[*]}"
        else
            log "  Enabling missing proxy features via satellite-installer (this takes a few minutes)"
            satellite-installer --scenario satellite "${installer_args[@]}" 2>&1 | tail -10 \
                || warn "satellite-installer returned errors — check /var/log/foreman-installer/satellite.log"
            h proxy refresh-features --id "$proxy_id" 2>/dev/null || true
        fi
    else
        log "  All required proxy features are already registered."
    fi
    ok "smart_proxy"
}

# =============================================================================
# STEP: pxe_setup
# Mirror: tasks/ensure_pxe_prereqs.yml + tasks/build_pxe_linux_defaults.yml
# Installs TFTP/DHCP/BIND packages, starts required services, and builds the
# PXE (BIOS) and Grub2 (UEFI) default boot menus so discovered/unbooted hosts
# PXE-boot to the Foreman Discovery image instead of timing out to local disk.
# =============================================================================
step_pxe_setup() {
    log "=== pxe_setup ==="

    if [ "$DRY_RUN" -eq 1 ]; then
        log "  [DRY-RUN] Would install: syslinux tftp-server dhcp-server bind"
        log "  [DRY-RUN] Would enable: named dhcpd tftp.socket"
        log "  [DRY-RUN] Would run: hammer template build-pxe-default"
        return 0
    fi

    # Unlock foreman-maintain package locks so we can install freely
    command -v foreman-maintain &>/dev/null \
        && foreman-maintain packages unlock 2>/dev/null || true

    log "  Installing PXE prerequisite packages"
    dnf install -y syslinux tftp-server 2>&1 | tail -3 \
        || warn "syslinux/tftp-server install failed — PXE may not work."

    # DHCP and BIND are best-effort (may be managed externally)
    dnf install -y dhcp-server bind 2>&1 | tail -2 || warn "dhcp-server/bind install failed (non-fatal)."

    log "  Enabling and starting network services"
    for svc in tftp.socket named dhcpd; do
        systemctl enable --now "$svc" 2>/dev/null \
            || warn "Could not start ${svc} — may be managed externally."
    done

    # Ensure TFTP tree root directories exist
    mkdir -p /var/lib/tftpboot/pxelinux.cfg
    mkdir -p /var/lib/tftpboot/grub2
    chmod 0755 /var/lib/tftpboot

    # Build PXELinux (BIOS) and Grub2 (UEFI) default menus
    log "  Building PXE default menus (hammer template build-pxe-default)"
    h template build-pxe-default 2>/dev/null \
        || warn "build-pxe-default failed — ensure TFTP smart proxy is registered first (run smart_proxy step)."

    # Make PXELinux default boot to Foreman Discovery image on timeout
    if [ -f /var/lib/tftpboot/pxelinux.cfg/default ]; then
        sed -i 's/ONTIMEOUT local/ONTIMEOUT discovery/g' \
            /var/lib/tftpboot/pxelinux.cfg/default 2>/dev/null || true
        log "  Set PXELinux ONTIMEOUT → discovery"
    fi

    # Make Grub2 default boot to Discovery as well
    if [ -f /var/lib/tftpboot/grub2/grub.cfg ]; then
        grep -q 'set default=0' /var/lib/tftpboot/grub2/grub.cfg \
            && log "  Grub2 grub.cfg already set to default entry 0." \
            || true
    fi

    ok "pxe_setup"
}

# =============================================================================
# STEP: realms
# Mirror: roles/realms/tasks/ensure_realm.yml
# Registers the IdM/Kerberos realm with Satellite so enrolled hosts auto-join.
# Requires: IdM is already installed and the Satellite capsule has
# realm-proxy configured (satellite-installer --foreman-proxy-realm true).
# Skipped automatically when IDM_HOSTNAME is unset.
# =============================================================================
step_realms() {
    log "=== realms ==="
    if [ -z "${IDM_FQDN:-}" ]; then
        warn "IDM_HOSTNAME / idm_hostname is not set — skipping realm configuration."
        return 0
    fi

    local realm_name
    realm_name="${REALM:-$(printf '%s' "${DOMAIN}" | tr '[:lower:]' '[:upper:]')}"
    local sat_fqdn="${SAT_HOSTNAME:-satellite.${DOMAIN}}"

    log "Ensuring Kerberos realm: ${realm_name} (capsule: ${sat_fqdn})"
    h realm create \
        --name "$realm_name" \
        --realm-type "FreeIPA" \
        --realm-proxy "$sat_fqdn" \
        --organization "$ORG" \
        --location "$LOC" 2>/dev/null \
        || h realm update \
            --name "$realm_name" \
            --realm-proxy "$sat_fqdn" 2>/dev/null \
        || warn "realm ${realm_name} — could not create or update."
    ok "realm ${realm_name}"
}

# =============================================================================
# STEP: domains
# Mirror: roles/domains/tasks/ensure_domain.yml
# =============================================================================
step_domains() {
    log "=== domains ==="
    local dns_capsule="${SAT_HOSTNAME:-satellite.${DOMAIN}}"
    log "Ensuring DNS domain: ${DNS_ZONE}"
    h domain create \
        --name "$DNS_ZONE" \
        --description "RHIS production domain" \
        --dns "${dns_capsule}" 2>/dev/null \
        || h domain update \
            --name "$DNS_ZONE" \
            --description "RHIS production domain" \
            --dns "${dns_capsule}" 2>/dev/null \
        || warn "domain ${DNS_ZONE} — could not create or update."

    h domain add-organization --name "$DNS_ZONE" --organization "$ORG" 2>/dev/null || true
    h domain add-location      --name "$DNS_ZONE" --location "$LOC"    2>/dev/null || true
    ok "domain ${DNS_ZONE}"
}

# =============================================================================
# STEP: subnets
# Mirror: roles/subnets/tasks/ensure_subnet.yml
# =============================================================================
step_subnets() {
    log "=== subnets ==="
    local subnet_name="RHIS_Provisioning"
    log "Ensuring subnet: ${subnet_name} (${PROV_SUBNET}/${PROV_NETMASK})"
    local sat_proxy="${SAT_HOSTNAME:-satellite.${DOMAIN}}"
    h subnet create \
        --name "$subnet_name" \
        --network "$PROV_SUBNET" \
        --mask "$PROV_NETMASK" \
        --gateway "$PROV_GW" \
        --from "$PROV_DHCP_START" \
        --to "$PROV_DHCP_END" \
        --dns-primary "$PROV_DNS_PRIMARY" \
        --dns-secondary "$PROV_DNS_SECONDARY" \
        --domain "$DNS_ZONE" \
        --boot-mode DHCP \
        --ipam DHCP \
        --dhcp "$sat_proxy" \
        --dns  "$sat_proxy" \
        --tftp "$sat_proxy" \
        --httpboot "$sat_proxy" \
        --template "$sat_proxy" \
        --discovery "$sat_proxy" \
        --organizations "$ORG" \
        --locations "$LOC" 2>/dev/null \
        || h subnet update \
            --name "$subnet_name" \
            --network "$PROV_SUBNET" \
            --mask "$PROV_NETMASK" \
            --gateway "$PROV_GW" \
            --from "$PROV_DHCP_START" \
            --to "$PROV_DHCP_END" \
            --dns-primary "$PROV_DNS_PRIMARY" \
            --dns-secondary "$PROV_DNS_SECONDARY" \
            --boot-mode DHCP \
            --ipam DHCP \
            --dhcp "$sat_proxy" \
            --dns  "$sat_proxy" \
            --tftp "$sat_proxy" \
            --httpboot "$sat_proxy" \
            --template "$sat_proxy" \
            --discovery "$sat_proxy" 2>/dev/null \
        || warn "subnet ${subnet_name} — update also failed; check Satellite UI."
    ok "subnet ${subnet_name}"
}

# =============================================================================
# STEP: compute_resources
# Mirror: roles/compute_resources/tasks/ensure_compute_resource.yml
# Registers a libvirt compute resource pointing at the KVM host.
# Uses LIBVIRT_URI from env.yml (default: qemu+ssh://<host_int_ip>/system).
# Override: COMPUTE_RESOURCE_URL, COMPUTE_RESOURCE_USER
# =============================================================================
step_compute_resources() {
    log "=== compute_resources ==="
    local cr_name="RHIS_Compute"
    local host_ip="${HOST_INT_IP:-${INTERNAL_GW:-192.168.122.1}}"
    local libvirt_uri="${LIBVIRT_URI:-qemu+ssh://${host_ip}/system}"
    local cr_user="${COMPUTE_RESOURCE_USER:-${SAT_USER}}"

    log "Ensuring compute resource: ${cr_name} (${libvirt_uri})"
    h compute-resource create \
        --name "$cr_name" \
        --provider Libvirt \
        --url "$libvirt_uri" \
        --organization "$ORG" \
        --location "$LOC" \
        --description "RHIS KVM/libvirt compute resource" 2>/dev/null \
        || h compute-resource update \
            --name "$cr_name" \
            --url "$libvirt_uri" 2>/dev/null \
        || warn "compute-resource ${cr_name} — could not create or update."
    ok "compute-resource ${cr_name}"
}

# =============================================================================
# STEP: compute_resource_images
# Mirror: roles/compute_resources/tasks/ensure_compute_resource.yml (image block)
# Registers libvirt base images for image-based provisioning (no PXE required).
# The UUID is the volume name (filename) inside the libvirt storage pool.
# Set LIBVIRT_RHEL9_IMAGE and/or LIBVIRT_RHEL10_IMAGE to activate this step.
# Image-based provisioning clones the base image then runs user-data/cloud-init.
# =============================================================================
step_compute_resource_images() {
    log "=== compute_resource_images ==="
    local cr_name="RHIS_Compute"

    if [ -z "${LIBVIRT_RHEL9_IMAGE:-}" ] && [ -z "${LIBVIRT_RHEL10_IMAGE:-}" ]; then
        warn "LIBVIRT_RHEL9_IMAGE and LIBVIRT_RHEL10_IMAGE are not set."
        warn "  Set these vars (or add to env.yml) to enable image-based provisioning."
        warn "  Example — in env.yml add:"
        warn "    libvirt_rhel9_image: rhel9-base.qcow2"
        warn "    libvirt_rhel10_image: rhel10-base.qcow2"
        return 0
    fi

    # Format: "image_name|os_title|arch|login_user|uuid|user_data"
    local -a images=()
    [ -n "${LIBVIRT_RHEL9_IMAGE:-}" ] && \
        images+=("RHEL 9 Base|RedHat 9.0|x86_64|cloud-user|${LIBVIRT_RHEL9_IMAGE}|yes")
    [ -n "${LIBVIRT_RHEL10_IMAGE:-}" ] && \
        images+=("RHEL 10 Base|RedHat 10.0|x86_64|cloud-user|${LIBVIRT_RHEL10_IMAGE}|yes")

    for entry in "${images[@]}"; do
        IFS='|' read -r img_name os_title arch img_user uuid user_data <<< "$entry"
        log "  Ensuring compute image: ${img_name} (uuid/volume: ${uuid})"
        if [ "$DRY_RUN" -eq 1 ]; then
            log "  [DRY-RUN] hammer compute-resource image create --name '${img_name}' --uuid '${uuid}'"
            continue
        fi
        h compute-resource image create \
            --name "$img_name" \
            --compute-resource "$cr_name" \
            --operatingsystem "$os_title" \
            --architecture "$arch" \
            --username "$img_user" \
            --user-data "$user_data" \
            --uuid "$uuid" 2>/dev/null \
            || h compute-resource image update \
                --name "$img_name" \
                --compute-resource "$cr_name" \
                --uuid "$uuid" 2>/dev/null \
            || warn "compute-resource image ${img_name} — could not create or update."
        ok "compute-resource image ${img_name}"
    done
}

# =============================================================================
# STEP: compute_profiles
# Mirror: roles/compute_profiles/tasks/ensure_compute_profile.yml
# Creates the RHIS_Standard compute profile and RHIS_Demo profile.
# Attributes reference the RHIS_Compute compute resource.
# =============================================================================
step_compute_profiles() {
    log "=== compute_profiles ==="
    local cr_name="RHIS_Compute"
    local storage_pool="${LIBVIRT_STORAGE_POOL:-default}"
    local network="${LIBVIRT_NETWORK:-default}"

    # Format: "profile_name|cpus|memory_mb|disk_gb"
    local -a profiles=(
        "RHIS_Standard|4|8192|100"
        "RHIS_Demo|2|4096|60"
    )

    for entry in "${profiles[@]}"; do
        IFS='|' read -r pname cpus mem_mb disk_gb <<< "$entry"
        log "Ensuring compute profile: ${pname} (${cpus} vCPU / ${mem_mb}MB / ${disk_gb}GB)"
        h compute-profile create \
            --name "$pname" 2>/dev/null \
            || warn "compute-profile ${pname} may already exist — continuing."

        # Set compute attributes on the profile for the libvirt CR
        h compute-profile values create \
            --compute-profile "$pname" \
            --compute-resource "$cr_name" \
            --interface "type=bridge,bridge=${network}" \
            --volume "pool_name=${storage_pool},capacity=${disk_gb}G,format_type=qcow2" \
            --compute-attributes "cpus=${cpus},memory=${mem_mb}" 2>/dev/null \
            || warn "compute-profile values for ${pname} may already be set — continuing."
        ok "compute-profile ${pname}"
    done
}

# =============================================================================
# STEP: settings
# Mirror: satellite_content_profile.yml → settings_general / settings_remote_execution / settings_rhcloud
# =============================================================================
step_settings() {
    log "=== settings ==="

    # Format: "name|value"
    local -a sat_settings=(
        "unregister_delete_host|true"
        "default_download_policy|on_demand"
        "content_view_solve_dependencies|true"
        "query_local_nameservers|true"
        "login_text|AUTHORIZED USE ONLY. Access to this system is monitored and logged."
        "remote_execution_ssh_user|root"
        "remote_execution_by_default|true"
        "ansible_ssh_private_key_file|/root/.ssh/id_rsa"
        # --------------- Red Hat Insights / RH Cloud ---------------
        "insights_sync|true"                    # sync Insights inventory to Satellite
        "allow_auto_inventory_upload|true"      # allow automatic host inventory sync
        "obfuscate_inventory_ips|false"         # keep IPs visible in cloud inventory
        "exclude_installed_packages|false"      # include package data in cloud reports
        # --------------- Remote Execution pull mode ----------------
        "remote_execution_global_proxy|true"    # use global REX proxy (set on subnet too)
    )

    for entry in "${sat_settings[@]}"; do
        local sname sval
        sname="${entry%%|*}"
        sval="${entry##*|}"
        log "  Setting ${sname} = ${sval}"
        h settings set \
            --name "$sname" \
            --value "$sval" 2>/dev/null \
            || warn "Could not set ${sname} — may require a later Satellite version."
    done
    ok "settings applied"
}

# =============================================================================
# STEP: global_parameters
# Mirror: roles/global_parameters/tasks/ensure_global_parameter.yml
# =============================================================================
step_global_parameters() {
    log "=== global_parameters ==="

    # Format: "name|value|type"
    local -a params=(
        "rhis_org|${ORG}|string"
        "rhis_location|${LOC}|string"
        # Insights + RHC enabled for every host registered through Satellite
        "host_registration_insights|true|boolean"
        "host_registration_remote_execution|true|boolean"
    )

    for entry in "${params[@]}"; do
        IFS='|' read -r pname pval ptype <<< "$entry"
        log "  Global parameter: ${pname} = ${pval}"
        h global-parameter set \
            --name "$pname" \
            --value "$pval" \
            --parameter-type "$ptype" 2>/dev/null \
            || warn "Could not set global parameter ${pname}."
    done
    ok "global_parameters applied"
}

# =============================================================================
# STEP: hostgroups
# Mirror: roles/hostgroups/tasks/ensure_hostgroup.yml
# satellite_content_profile.yml: satellite_hostgroups
# =============================================================================
step_hostgroups() {
    log "=== hostgroups ==="

    # Format: "name|lc_env|content_view|ak"
    local -a hgroups=(
        "RHEL9|PROD_RHEL_9_x86_64|rhel-9-for-x86_64|PROD_RHEL_9_x86_64"
        "RHEL10|PROD_RHEL_10_x86_64|rhel-10-for-x86_64|PROD_RHEL_10_x86_64"
    )

    for entry in "${hgroups[@]}"; do
        IFS='|' read -r hg_name lc cv ak <<< "$entry"
        log "Ensuring hostgroup: ${hg_name}"
        h hostgroup create \
            --name "$hg_name" \
            --description "RHEL ${hg_name} production hosts" \
            --organization "$ORG" \
            --lifecycle-environment "$lc" \
            --content-view "$cv" \
            --content-source "${SAT_HOSTNAME:-satellite.${DOMAIN}}" \
            --activation-keys "$ak" 2>/dev/null \
            || h hostgroup update \
                --name "$hg_name" \
                --lifecycle-environment "$lc" \
                --content-view "$cv" \
                --activation-keys "$ak" 2>/dev/null \
            || warn "hostgroup ${hg_name} — update also failed; check Satellite UI."
        ok "hostgroup ${hg_name}"
    done
}

# =============================================================================
# STEP: discovery_rules
# Mirror: roles/discovery_rules/tasks/ensure_discovery_rule.yml
# Creates auto-provisioning rules that match discovered (PXE-booted) hosts to
# hostgroups based on hardware facts. Requires the Foreman Discovery plugin
# (installed by satellite-installer --enable-foreman-proxy-plugin-discovery).
# =============================================================================
step_discovery_rules() {
    log "=== discovery_rules ==="

    # Format: "rule_name|search_expression|hostgroup|hostname_pattern|priority"
    # search_expression uses Foreman Discovery facts (facts.* namespace).
    local -a rules=(
        "RHEL 10 Auto|facts.memorysize_mb > 4096|RHEL10|rhel10-<%= @host.facts['ipaddress'].gsub('.', '-') %>|100"
        "RHEL 9 Auto|facts.memorysize_mb > 1024|RHEL9|rhel9-<%= @host.facts['ipaddress'].gsub('.', '-') %>|200"
    )

    for entry in "${rules[@]}"; do
        IFS='|' read -r rule_name search hg hostname_pattern priority <<< "$entry"
        log "  Ensuring discovery rule: ${rule_name} → hostgroup ${hg}"
        h discovery-rule create \
            --name "$rule_name" \
            --search "$search" \
            --hostgroup "$hg" \
            --hostname "$hostname_pattern" \
            --priority "$priority" \
            --enabled yes \
            --organizations "$ORG" \
            --locations "$LOC" 2>/dev/null \
            || h discovery-rule update \
                --name "$rule_name" \
                --search "$search" \
                --hostgroup "$hg" 2>/dev/null \
            || warn "discovery-rule ${rule_name} — could not create or update."
        ok "discovery-rule ${rule_name}"
    done
}

# =============================================================================
# STEP: user_roles
# Mirror: roles/user_roles/tasks/ensure_user_role.yml
# Creates RBAC roles for RHIS use cases. Satellite ships built-in roles;
# we just ensure the key ones exist and are linked to the org/location.
# =============================================================================
step_user_roles() {
    log "=== user_roles ==="
    # These built-in roles should already exist; this just protects against
    # future Satellite version changes and confirms they are scoped correctly.
    local -a roles=(
        "Organization admin"
        "Viewer"
        "Manager"
        "Site manager"
    )
    for role in "${roles[@]}"; do
        log "  Verifying role: ${role}"
        h role info --name "$role" >/dev/null 2>&1 \
            || warn "Built-in role '${role}' not found — may have a different name on this version."
    done
    ok "user_roles verified"
}

# =============================================================================
# STEP: user_groups
# Mirror: roles/user_groups/tasks/ensure_user_group.yml
# Creates Satellite user groups that mirror the IdM groups defined in
# satellite_content_profile.yml (rhis-admins, content-managers, etc.)
# =============================================================================
step_user_groups() {
    log "=== user_groups ==="
    local -a groups=(
        "rhis-admins|Manager"
        "content-managers|Manager"
        "automation-engineers|Viewer"
        "system-services|Viewer"
    )
    for entry in "${groups[@]}"; do
        local grp_name role
        grp_name="${entry%%|*}"
        role="${entry##*|}"
        log "  Ensuring user group: ${grp_name} (role: ${role})"
        h user-group create \
            --name "$grp_name" \
            --roles "$role" 2>/dev/null \
            || h user-group update \
                --name "$grp_name" \
                --roles "$role" 2>/dev/null \
            || warn "user-group ${grp_name} — could not create or update."
        ok "user-group ${grp_name}"
    done
}

# =============================================================================
# STEP: user_groups_external
# Mirror: roles/user_groups_external/tasks/ensure_user_group_external.yml
# Maps Satellite user groups to IdM LDAP groups so IdM users inherit roles.
# Requires IdM auth source to be configured (done by Satellite during install
# when satellite_pre_use_idm=true). Skipped when IDM_HOSTNAME is unset.
# =============================================================================
step_user_groups_external() {
    log "=== user_groups_external ==="
    if [ -z "${IDM_FQDN:-}" ]; then
        warn "IDM_HOSTNAME not set — skipping external user group mapping."
        return 0
    fi

    # Find the IdM auth source ID (Satellite names it after the LDAP server)
    local auth_source_id
    auth_source_id="$(hammer auth-source ldap list 2>/dev/null \
        | grep -i 'idm\|freeipa\|ipa' \
        | awk '{print $1}' | head -1 || true)"

    if [ -z "$auth_source_id" ]; then
        warn "No IdM LDAP auth source found in Satellite — configure it first via"
        warn "  Administer → Authentication Sources → New LDAP Source"
        warn "Skipping external group mapping."
        return 0
    fi

    # Format: "satellite_group|external_ipa_group_name"
    local -a ext_groups=(
        "rhis-admins|rhis-admins"
        "content-managers|content-managers"
        "automation-engineers|automation-engineers"
        "system-services|system-services"
    )
    for entry in "${ext_groups[@]}"; do
        local sat_grp ext_grp
        sat_grp="${entry%%|*}"
        ext_grp="${entry##*|}"
        log "  Linking ${sat_grp} → IdM group ${ext_grp}"
        h user-group external create \
            --name "$ext_grp" \
            --user-group "$sat_grp" \
            --auth-source-id "$auth_source_id" 2>/dev/null \
            || warn "external group ${ext_grp} for ${sat_grp} may already be mapped."
        ok "external group ${sat_grp} → ${ext_grp}"
    done
}

# =============================================================================
# STEP: users
# Mirror: satellite_content_profile.yml → satellite_users
# Ensures the admin Satellite user account
# =============================================================================
step_users() {
    log "=== users ==="
    log "Ensuring Satellite admin user account"
    h user update \
        --login "$SAT_USER" \
        --mail "admin@${DOMAIN}" \
        --firstname "Admin" \
        --lastname "User" \
        --timezone "Mountain Time (US & Canada)" \
        --default-organization "$ORG" \
        --default-location "$LOC" 2>/dev/null \
        || warn "Could not update user ${SAT_USER} — may be newly installed."
    ok "user ${SAT_USER}"
}

# =============================================================================
# STEP: insights_satellite
# Registers the Satellite host itself to Red Hat Insights via rhc (Red Hat
# Connect daemon). rhc replaces the older insights-client manual registration
# and also enables remote configuration / remediations from cloud.redhat.com.
#
# What this step does:
#   1. Installs insights-client, rhc, and rhc-worker-playbook packages
#   2. Runs `rhc connect` to register with Red Hat Console (requires org_id +
#      activation key OR an existing rhsm registration with entitlements)
#   3. Verifies the connection and enables the rhcd service
#   4. Triggers an initial insights-client collection so the host appears in
#      the Insights inventory immediately
#
# Pre-reqs: Satellite must already be registered to subscription-manager
#   (handled by the satellite_pre Ansible role / MiniRHIS install phase).
# =============================================================================
step_insights_satellite() {
    log "=== insights_satellite ==="

    if [ "$DRY_RUN" -eq 1 ]; then
        log "  [DRY-RUN] Would install: insights-client rhc rhc-worker-playbook"
        log "  [DRY-RUN] Would run: rhc connect --organization <org_id> --activation-key <key>"
        log "  [DRY-RUN] Would run: insights-client --register"
        return 0
    fi

    # Install packages (requires active RHSM subscription on the Satellite host)
    log "  Installing Insights and RHC packages on Satellite host"
    if command -v foreman-maintain &>/dev/null; then
        foreman-maintain packages unlock 2>/dev/null || true
    fi
    dnf install -y insights-client rhc rhc-worker-playbook 2>&1 | tail -5 \
        || warn "Package install failed — ensure Satellite has active RHSM subscription."

    # Connect via rhc — uses the existing rhsm registration (no extra creds needed
    # when the host is already subscribed via subscription-manager).
    log "  Connecting to Red Hat Console via rhc"
    if rhc status 2>/dev/null | grep -qi 'connected'; then
        log "  rhc is already connected — skipping connect."
    else
        rhc connect 2>&1 | tail -5 \
            || warn "rhc connect failed — check subscription status with: subscription-manager status"
    fi

    # Enable and start rhcd (Red Hat Connect daemon)
    systemctl enable --now rhcd 2>/dev/null \
        || warn "Could not enable rhcd — Insights remediations may not work."

    # Run initial Insights data collection
    log "  Running insights-client --register (initial collection)"
    insights-client --register 2>&1 | tail -10 \
        || warn "insights-client --register failed — check /var/log/insights-client/insights-client.log"

    # Force an immediate inventory upload to the Satellite / cloud
    log "  Triggering inventory upload (foreman_rh_cloud sync)"
    h settings set --name insights_sync --value true 2>/dev/null || true

    ok "insights_satellite"
}

# =============================================================================
# STEP: insights_nodes
# Configures Red Hat Insights and RHC on nodes that will be provisioned from
# Satellite. Works on two levels:
#
#   A. Satellite-side configuration (run once):
#      - Ensures the insights-client content is enabled on all activation keys
#      - Enables global parameters host_registration_insights=true and
#        host_registration_remote_execution=true so Satellite's generated
#        registration command installs and registers the agent automatically
#      - Adds insights-client + rhc + rhc-worker-playbook to the kickstart
#        %post packages list via a global parameter (foreman_scap_client skips
#        if the packages are delivered through activation key content overrides)
#
#   B. Existing registered hosts (rex job):
#      - Runs a Remote Execution job template on all hosts in the org that
#        don't yet have Insights registered, installing the required packages
#        and calling `rhc connect` + `insights-client --register`
#
# The rex job is submitted async — use the Satellite UI or
#   hammer job-invocation info --id <id>
# to monitor progress.
# =============================================================================
step_insights_nodes() {
    log "=== insights_nodes ==="

    # ── A. Satellite-side: global parameters ──────────────────────────────────
    log "  Setting host_registration_insights and host_registration_remote_execution"
    h global-parameter set \
        --name "host_registration_insights" \
        --value "true" \
        --parameter-type "boolean" 2>/dev/null \
        || warn "Could not set host_registration_insights global parameter."

    h global-parameter set \
        --name "host_registration_remote_execution" \
        --value "true" \
        --parameter-type "boolean" 2>/dev/null \
        || warn "Could not set host_registration_remote_execution global parameter."

    # ── A. Activation key: enable insights-client content override ────────────
    local -a ak_names=(
        "DEV_RHEL_10_x86_64" "TEST_RHEL_10_x86_64" "PROD_RHEL_10_x86_64"
        "DEV_RHEL_9_x86_64"  "TEST_RHEL_9_x86_64"  "PROD_RHEL_9_x86_64"
    )
    for ak in "${ak_names[@]}"; do
        h activation-key content-override \
            --organization "$ORG" \
            --name "$ak" \
            --content-label "insights-client" \
            --value 1 2>/dev/null \
            || warn "Could not enable insights-client on activation key ${ak}."
    done
    log "  Activation keys updated with insights-client content override."

    # ── B. Rex job on existing hosts ──────────────────────────────────────────
    if [ "$DRY_RUN" -eq 1 ]; then
        log "  [DRY-RUN] Would submit rex job: Install and Register to Insights / rhc"
        log "  [DRY-RUN]   Target: all hosts in org ${ORG} where insights-status != connected"
        return 0
    fi

    log "  Submitting REX job to install Insights + RHC on all registered hosts"
    local job_id
    job_id="$(h job-invocation create \
        --job-template "Install and Register to Insights" \
        --search-query "organization = ${ORG}" \
        --async 2>/dev/null \
        | grep -oP '(?<=Job invocation )\d+' | head -1 || true)"

    if [ -n "$job_id" ]; then
        log "  Rex job submitted: ID ${job_id}"
        log "  Monitor: hammer job-invocation info --id ${job_id}"
        log "           or Satellite UI → Monitor → Jobs"
    else
        # Fallback: use the Run Command template to install packages manually
        warn "Built-in 'Install and Register to Insights' template not found."
        warn "Submitting generic package install + rhc connect as fallback."
        h job-invocation create \
            --job-template "Run Command - Script Default" \
            --search-query "organization = ${ORG}" \
            --async \
            --inputs \
"command=dnf install -y insights-client rhc rhc-worker-playbook && rhc connect && insights-client --register" \
            2>/dev/null \
            || warn "Fallback rex job also failed — run manually on each host."
    fi

    ok "insights_nodes"
}

# =============================================================================
# Main — run steps in order, skipping those not in SELECTED_STEPS
# =============================================================================
log "hammer_time.sh — SAT_URL=${SAT_URL}  ORG=${ORG}  LOC=${LOC}"
[ "$DRY_RUN" -eq 1 ] && log "(DRY-RUN mode — no changes will be made)"

for step in "${ALL_STEPS[@]}"; do
    run_step "$step" || continue
    "step_${step}"
done

log "Done."
