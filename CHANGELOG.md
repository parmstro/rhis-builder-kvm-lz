# RHIS Change Log

This file tracks repository changes from this point forward.

## Entry format

- **Timestamp:** `YYYY-MM-DD HH:MM:SS TZ`
- **Area:** file(s) or component(s)
- **Summary:** short description of what changed
- **Reason:** why the change was made

---

## 2026-03-24 11:45:08 MDT

### 2026-03-24 11:45:08 MDT — Kickstart creator baseline integration

- **Area:** `rhis_install.sh`
- **Summary:**
  - Added `kickstart_creator_baseline_block()` to centralize creator/automation prerequisites in kickstart `%post`.
  - Baseline now installs common creator tools (`sudo`, `openssh-clients`, `rsync`, `jq`), enables `chronyd`, and creates `/etc/rhis/creator.env` metadata on provisioned nodes.
  - Injected creator baseline into all three generated kickstarts: Satellite, AAP, and IdM.
  - Metadata written per node includes role, hostname, IP, and bootstrap source/version for downstream creator workflows.
- **Reason:** Ensure every kickstarted node has a consistent creator-ready baseline and machine-readable node metadata for post-provisioning automation.

---

## 2026-03-24 11:13:51 MDT

### 2026-03-24 11:13:51 MDT — Agnostic/idempotent script hardening

- **Area:** `rhis_install.sh`
- **Summary:**
  - Removed baked-in default values for `RH_ISO_URL`, `RH9_ISO_URL`, and `AAP_BUNDLE_URL` so the script no longer depends on stale/expired environment-specific download links.
  - Removed the hard-coded fallback `ADMIN_PASS` value and preserved explicit `ROOT_PASS`, `SAT_ADMIN_PASS`, `AAP_ADMIN_PASS`, and `IDM_ADMIN_PASS` overrides instead of forcibly replacing them with the shared admin password.
  - Added `write_file_if_changed()` to make generated artifacts converge only when content changes instead of being rewritten on every run.
  - Added `vault_plaintext_matches_existing()` so `write_ansible_env_file()` skips re-encrypting `env.yml` when the plaintext content is unchanged.
  - Updated `generate_rhis_ansible_cfg()` to write through a temp file and only replace the live config when the rendered content changes.
  - Updated `generate_env_template()` to be idempotent (no forced overwrite prompt/rewrite when content is unchanged).
  - Updated Satellite/AAP/IdM kickstart generation to stop deleting/reinstalling kickstarts on every run; files now update only when the rendered content changes.
  - Updated Satellite OEMDRV packaging to skip rebuilding the ISO when the underlying kickstart is unchanged and the ISO already exists.
  - Removed the eager `cleanup_generated_kickstart_artifacts` call from `write_kickstarts()` so normal reruns preserve stable artifacts rather than deleting them first.
- **Reason:** Make RHIS safer to re-run on different hosts/environments with fewer hidden assumptions, less artifact churn, and more declarative/idempotent behavior.

---

## 2026-03-24 10:50:00 MDT

### 2026-03-24 10:50:00 MDT — Merge headless helper files into rhis_install.sh

- **Area:** `rhis_install.sh` (new functions), `rhis-headless-validate.sh` (removed), `rhis-headless.env.template` (removed)
- **Summary:**
  - Merged standalone `rhis-headless-validate.sh` into `rhis_install.sh` as `validate_headless_config()` function.
  - Merged `rhis-headless.env.template` into `rhis_install.sh` as `generate_env_template()` function (heredoc).
  - Added `--validate` / `--preflight` CLI flag: runs pre-flight checks (required vars per menu-choice, Linux/root/sudo, required commands, SSH keys, IP format, FQDN format, storage ≥300 GB, memory ≥64 GB, Red Hat CDN and DNS reachability) then exits.
  - Added `--generate-env [path]` CLI flag: writes a commented headless env-file template to the specified path (default `./rhis-headless.env.template`) then exits.
  - Added `CLI_VALIDATE` and `CLI_GENERATE_ENV` global flag variables.
  - Updated `apply_cli_overrides()` to set `NONINTERACTIVE=1 RUN_ONCE=1` for both new flags.
  - Updated `print_usage()` with documentation for both new flags.
  - Removed `rhis-headless-validate.sh` and `rhis-headless.env.template` from repository (functionality now in `rhis_install.sh`).
- **Reason:** Consolidate headless deployment tooling into a single script so users do not need external helper files; headless validation and env-file generation are available as first-class CLI operations.

---

## 2026-03-24 09:51:57 MDT

### 2026-03-24 09:51:57 MDT — Emergency recovery: Missing provisioner templates

- **Area:** `RECOVERY_PROCEDURES.md`, `QUICK_RECOVERY.md`, (provisioner container patches applied)
- **Summary:**
  - Diagnosed config-as-code phase failures: IdM/Satellite playbooks failed due to missing `chrony.j2` template in provisioner container.
  - Root cause: Provisioner container image (`quay.io/parmstro/rhis-provisioner-9-2.5:latest`) missing rhis-builder roles/templates.
  - Applied emergency hotfix: Injected fallback chrony.j2 templates into running provisioner container for both IdM and Satellite roles via `podman cp`.
  - Created comprehensive recovery procedures documentation with 4 recovery options (retry phases, full restart, manual execution, isolated testing).
  - Created quick reference recovery guide for immediate phase re-execution with step-by-step instructions.
  - Verified templates now in place; ready for playbook retry.
- **Reason:** Unblock failed deployment; provide clear recovery path for user without full infrastructure rebuild.

---

## 2026-03-23 17:39:04 MDT

### 2026-03-23 17:39:04 MDT — Script hardening and orchestration updates

- **Area:** `rhis_install.sh`
- **Summary:**
  - Added container playbook hotfix preflight with verify/fail-fast controls.
  - Added/remediated IdM update task patching (`disable_gpg_check`, firmware exclusion) and Satellite pre-task non-fatal handling.
  - Added/normalized `SATELLITE_PRE_USE_IDM` handling and injected IdM integration vars for Satellite flows.
  - Added startup installer-host collection visibility check and unified required collection source list.
  - Added AAP callback wait progress monitor (heartbeat, % progress, remaining time, stage transitions, fail-fast stall detection).
  - Improved manual rerun guidance with container prerequisite checks and root-auth fallback template.
  - Enforced VM build creation order: `IdM -> Satellite -> AAP`.
- **Reason:** Improve reliability, visibility, and deterministic dependency order while reducing repeated operator troubleshooting.

### 2026-03-23 17:39:04 MDT — Documentation alignment

- **Area:** `README.md`, `CHECKLIST.md`, `Doc/README.md`, `host_vars/README.md`, `inventory/README.md`
- **Summary:**
  - Updated docs to match current runtime behavior and dependency order.
  - Documented AAP callback progress/fail-fast controls and collection preflight behavior.
  - Updated manual rerun notes to include container availability prerequisite.
- **Reason:** Keep operator documentation synchronized with script behavior.

## 2026-03-24 07:28:21 MDT

### 2026-03-24 07:28:21 MDT — SSH mesh fallback hardening

- **Area:** `rhis_install.sh`
- **Summary:**
  - Added installer-user + passwordless `sudo` fallback for root SSH key bootstrap on RHIS nodes.
  - Added installer-user + `sudo` fallback when collecting root public keys.
  - Added installer-user + `sudo` fallback when distributing root trust keys.
- **Reason:** Prevent RHIS from aborting when direct `root@<node>` SSH is not ready yet but the installer/admin account is already available.

### 2026-03-24 07:35:18 MDT — Managed container patch persistence

- **Area:** `rhis_install.sh`
- **Summary:**
  - Added top-level RHIS-managed container patch functions for Satellite and IdM playbook component fixes.
  - Container startup/reuse now automatically reapplies and verifies these patches on every deployment or restart of `rhis-provisioner`.
  - Current managed patches include the Satellite `chrony.j2` fallback, non-fatal foreman service check patch, and IdM update-task GPG/firmware guard patch.
- **Reason:** Ensure all container component fixes are maintained by the script itself and are consistently re-applied whenever a new provisioner container is deployed through RHIS.

### 2026-03-24 07:51:02 MDT — Per-run installer logging under /var/log/rhis

- **Area:** `rhis_install.sh`
- **Summary:**
  - Added run-log configuration and startup log initialization for each script invocation.
  - Script now ensures `/var/log/rhis` exists and writes a timestamped per-run logfile.
  - Added output mirroring (`tee`) so each RHIS run is captured while still printing live to console.
  - Added/updated `latest.log` symlink in `/var/log/rhis` for quick access to most recent run.
- **Reason:** Provide durable, per-run operational logs for troubleshooting and auditability of each `rhis_install.sh` execution.

### 2026-03-24 07:54:03 MDT — Automatic run-log retention/pruning

- **Area:** `rhis_install.sh`
- **Summary:**
  - Added `RHIS_RUN_LOG_KEEP_COUNT` (default `30`) to control retained per-run installer logs.
  - Added automatic pruning of old `/var/log/rhis/rhis_install_*.log` files after logging initialization.
  - Retention keeps newest logs by mtime and removes older files beyond the configured count.
- **Reason:** Prevent unbounded growth of `/var/log/rhis` while preserving recent execution history.

### 2026-03-24 08:09:44 MDT — Root SSH mesh defaults to best-effort

- **Area:** `rhis_install.sh`
- **Summary:**
  - Added `RHIS_REQUIRE_ROOT_SSH_MESH` (default `0`) to control whether root mesh failures are fatal.
  - Updated `setup_rhis_ssh_mesh()` so installer-user mesh remains mandatory, while root-key bootstrap/collection/distribution failures warn-and-continue by default.
  - Added runtime summary output for `RHIS_REQUIRE_ROOT_SSH_MESH`.
- **Reason:** Avoid aborting full workflow when root key auth is not fully ready on one node (for example IdM), while still allowing strict enforcement when explicitly required.

### 2026-03-24 08:15:26 MDT — SSH key/known_hosts stability hardening for rebuilt RHIS nodes

- **Area:** `rhis_install.sh`
- **Summary:**
  - Added dedicated persistent installer-host RHIS SSH key path (`RHIS_INSTALLER_SSH_KEY_DIR`) so RHIS mesh operations no longer depend on/churn default `~/.ssh/id_rsa`.
  - Updated SSH mesh bootstrap/copy-id paths to use the dedicated RHIS installer key.
  - Added known_hosts refresh for RHIS node IPs/hostnames (`RHIS_REFRESH_KNOWN_HOSTS`, default enabled) to remove stale host keys and reseed current keys after VM rebuild cycles.
  - Added runtime/help visibility for these new SSH stability controls.
- **Reason:** Prevent recurring host-key-change breakage and avoid impacting the static installer host’s primary SSH identity during repeated RHIS rebuild/install cycles.

### 2026-03-24 08:45:25 MDT — Config-only auth resilience preflight

- **Area:** `rhis_install.sh`
- **Summary:**
  - Added config-as-code preflight call to refresh SSH trust baseline (`setup_rhis_ssh_mesh`) before phase playbooks (best-effort in this path).
  - Added config-as-code preflight root password normalization (`fix_vm_root_passwords`) before phase execution to improve root fallback reliability.
- **Reason:** Reduce repeated phase failures in container config-only/rerun workflows caused by SSH trust drift and root password mismatch between current vault values and guest state.

### 2026-03-24 09:17:24 MDT — /etc/hosts sync for RHIS external interfaces

- **Area:** `rhis_install.sh`
- **Summary:**
  - Added `sync_rhis_external_hosts_entries()` to discover RHIS VM external/NAT interface IPs via `virsh domifaddr` and write them to a managed `/etc/hosts` block.
  - Added managed markers (`# BEGIN RHIS EXTERNAL HOSTS` / `# END RHIS EXTERNAL HOSTS`) so reruns replace/update entries cleanly instead of duplicating lines.
  - Wired sync calls into VM settle flow (`create_rhis_vms`) and config-as-code preflight (`run_rhis_config_as_code`) for recurring refresh.
- **Reason:** Ensure installer-host name resolution has up-to-date external interface mappings after VM reprovision/re-IP events.

### 2026-03-24 09:21:37 MDT — Fix missing IdM chrony.j2 template during idm_pre

- **Area:** `rhis_install.sh`
- **Summary:**
  - Added managed container hotfix creation for `/rhis/rhis-builder-idm/roles/idm_pre/templates/chrony.j2` (fallback template) alongside existing Satellite chrony fallback.
  - Extended container hotfix verification checks to require both Satellite and IdM `chrony.j2` template files.
  - Added IdM chrony template preflight application in config-as-code hotfix path and before IdM phase/fallback playbook execution.
- **Reason:** Prevent `TASK [idm_pre : Configure time servers]` failures caused by missing `chrony.j2` in the IdM role templates.

### 2026-03-24 09:28:18 MDT — IdM Web UI readiness gate + diagnostics

- **Area:** `rhis_install.sh`
- **Summary:**
  - Added IdM Web UI readiness controls (`RHIS_IDM_WEB_UI_TIMEOUT`, `RHIS_IDM_WEB_UI_INTERVAL`) and runtime config visibility.
  - Added automated post-IdM remediation/start checks for key services (`ipa`, `httpd`, `pki-tomcatd@pki-tomcat`) with `/ipa/ui` HTTPS readiness probing.
  - Added focused IdM Web UI diagnostics (service state, listener ports, local curl status) and integrated them into IdM failure handling.
  - IdM phase now marks status as failed when web UI readiness does not converge, instead of reporting a false-success state.
- **Reason:** Ensure the workflow only reports IdM success when the actual IdM web UI is reachable and healthy.

### 2026-03-24 16:35:00 MDT — Fix container SSH auth for Ansible (admin user key distribution)

- **Area:** `rhis_install.sh`
- **Summary:**
  - Root cause: `setup_rhis_ssh_mesh()` was distributing the RHIS installer key only to `installer_user` (sgallego) and root on each VM — not to `ADMIN_USER` (admin), which is the `ansible_user` in the inventory and the account Ansible actually connects as.
  - Added explicit installer-key push to `ADMIN_USER@node` in the key distribution loop when `ADMIN_USER != installer_user`.
  - Added `RHIS_INSTALLER_SSH_KEY_CONTAINER_DIR`/`RHIS_INSTALLER_SSH_KEY_CONTAINER_PATH` constants for the container-side SSH key mount path.
  - Mounted `RHIS_INSTALLER_SSH_KEY_DIR` into the provisioner container as `/rhis/vars/ssh` (read-only) so Ansible inside the container has access to the RHIS installer private key.
  - Added `-i ${RHIS_INSTALLER_SSH_KEY_CONTAINER_PATH}` to `ssh_args` in the generated `ansible.cfg` so all Ansible SSH connections use the RHIS installer key by default.
- **Reason:** Ansible connections from the provisioner container were failing with `Permission denied (publickey,...)` on all nodes because the container had no SSH private key available and the Ansible inventory user (`admin`) did not have a trusted key path configured.

### 2026-03-24 09:43:07 MDT — Cross-component post-install healthcheck/remediation framework

- **Area:** `rhis_install.sh`
- **Summary:**
  - Added post-install healthcheck controls: `RHIS_ENABLE_POST_HEALTHCHECK`, `RHIS_HEALTHCHECK_AUTOFIX`, `RHIS_HEALTHCHECK_RERUN_COMPONENT`.
  - Added healthcheck stage after phase execution/retries to validate IdM, Satellite, and AAP service/web readiness.
  - Added automatic remediation attempts for failed checks and optional targeted component playbook reruns when remediation is insufficient.
  - Wired all healthcheck activity into existing log stream (`/var/log/rhis/...`) so failures, fixes, and final status are captured in the RHIS install log.
- **Reason:** Provide after-the-fact validation that role-delivered functionality is actually operational, with auto-fix and component-level rerun fallback when possible.
