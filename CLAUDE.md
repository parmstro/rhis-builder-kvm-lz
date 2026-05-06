# KVM VM Deployment with Ansible

This project manages KVM virtual machine deployments using Ansible playbooks with NVMe-backed storage optimization.

## Code Standards

This project follows the [Red Hat COP Automation Good Practices](https://redhat-cop.github.io/automation-good-practices/) with specific preferences outlined below.

### YAML Formatting

- **Indentation**: 2 spaces
- **File extension**: Use `.yml` (not `.yaml`)
- **Line length**: 120 characters maximum (soft limit)
- **String quoting**: Double quotes for YAML strings; single quotes for Jinja2 expressions
- **Booleans**: Use `true`/`false` (not `yes`/`no`)
- **Comments**: Comments are acceptable and encouraged for clarity
- **Document markers**: All YAML files must start with `---` and end with `...`

### Ansible Module Usage

- **FQCN Required**: Always use fully qualified collection names
  - ✅ `ansible.builtin.template`
  - ❌ `template`
- **Prefer ansible.builtin prefix**: Even though other FQCN formats are valid, use `ansible.builtin.*` for core modules
- **Prefer collection-specific modules**: Use dedicated collection modules over generic API calls
  - ✅ `dellemc.openmanage.idrac_boot` for boot configuration
  - ❌ `ansible.builtin.uri` with manual Redfish API calls
  - Rationale: Better idempotency, error handling, and maintainability
- **YAML syntax**: Use YAML dictionary format, not `key=value` format

### Variable Management

- **Prefer vars_files over inline vars**: Extract variable definitions to separate YAML files
- **Naming convention**: Use `snake_case` for all variables
- **Descriptive names**: Use mnemonic, human-readable names

### Task Guidelines

- **Name all tasks**: Use descriptive imperative form
  - ✅ "Template libvirt XML definition for {{ vm.vmname }}"
  - ❌ "template task"
- **Idempotency**: Ensure all tasks can run repeatedly without side effects
- **changed_when**: Set explicitly for command/shell tasks that don't modify state

### Quality Checks

- **ansible-lint**: Always validate playbooks with `ansible-lint` before completion
  - Note: `ansible-lint` must be installed separately (`pip install ansible-lint`)
- **Syntax validation**: Run `ansible-playbook --syntax-check` before testing
- **Check mode**: Test with `ansible-playbook --check` when possible

## Project Environment

### Infrastructure

- **Platform**: RHEL 9 KVM hypervisor on Dell servers
- **Provisioning**: Dell iDRAC virtual media with kickstart
- **Storage Architecture**:
  - Boot/Root: Auto-detected Dell BOSS device (or fallback to configured disk) with compliance-focused LVM layout
  - Kickstart dynamically detects Dell BOSS for OS installation
    - Partition commands generated dynamically based on detected hardware
    - Fallback to `host.boot_disk` and `host.root_disk` from host_vars if no Dell BOSS found
  - VM Storage: mdadm RAID 10 array on 4+ NVMe disks
    - Auto-detects Dell DC NVMe SSDs using disk/by-id paths in main playbook before RAID setup
    - Populates `host.additional_disks` if not already defined in host_vars
    - Fallback to `host.additional_disks` from host_vars if no Dell DC NVMe found or variable already set
    - Playbook fails fast if fewer than 4 disks available
  - Dual Storage Pool Architecture:
    - RAID array partitioned using percentage-based allocation (both pools always created)
    - **Filesystem Pool** (volume_mode: filesystem): Percentage-based LVM partition with XFS, mounted at `/mnt/{{ raid_name }}/libvirt/filesystem`, libvirt pool type `dir`
    - **Block Pool** (volume_mode: block): Percentage-based LVM volume group, libvirt pool type `logical` for direct block access
    - Partition allocation percentages configured in `inventory/group_vars/infra_servers.yml`:
      - `lvm_vg_filesystem_percent`: Percentage of RAID for filesystem pool (default: 15%)
      - `lvm_vg_block_percent`: Percentage of RAID for block pool (default: 80%)
      - `lvm_overhead_percent`: Reserved for LVM metadata overhead (default: 5%)
      - `lvm_snapshot_reserve_percent`: Unallocated space within each VG for snapshots (default: 15%)
    - Validation ensures `filesystem_percent + block_percent + overhead_percent ≤ 100%`
    - Partition sizes calculated dynamically from RAID size at deployment time
    - Snapshot reserve: Filesystem pool LV uses `(100 - lvm_snapshot_reserve_percent)%VG`, block pool leaves space for individual VM disk LVs
- **Network Configuration**:
  - Primary NIC: Configured during kickstart (identified by MAC address)
  - Libvirt bridge: Configured on second NIC with active link
    - Existing connections removed (including DHCP) before bridging
    - Bridge configured with no IP address (IPv4/IPv6 disabled)
  - Network naming: `libvirt_net1` (incremental naming for future expansion)
- **Disk Naming**: Uses `/dev/disk/by-id/` for stable device references

### VM Configuration

VMs are defined in `vars/vm_vars.yml` with the following structure:

```yaml
vms:
  - vmname: <fqdn>
    target_host: <inventory_hostname>  # Which hypervisor to deploy on (e.g., infra1, infra2, infra3)
    vcpu: <count>
    memory: <MiB>
    network:
      hostname: "<short_hostname>"       # Short hostname (without domain)
      domain: "<domain>"                 # DNS domain name
      mac: "<MAC_address>"               # MAC address for VM NIC (use libvirt range: 52:54:00:XX:XX:XX)
      ipv4_address: "<IP>"
      ipv4_netmask: "<netmask>"
      ipv4_gateway: "<gateway>"
      name_servers:
        - "<DNS1>"
        - "<DNS2>"
    root_enc_pass: "<encrypted_password>"           # Root account password (use ansible-vault)
    grub_enc_pass: "<encrypted_password>"           # GRUB bootloader password (optional, use ansible-vault)
    username: "<provisioner_username>"              # Provisioner user account name
    user_enc_pass: "<encrypted_password>"           # Provisioner user password (use ansible-vault)
    user_sudoer_policy: "<sudoer_policy>"           # Sudoer policy (e.g., ALL=(ALL) NOPASSWD: ALL)
    ssh_pub_key: "<ssh_public_key>"                 # SSH public key for provisioner user
    fs:                                             # Filesystem layout configuration
      filesystem: "xfs"                             # Root filesystem type
      boot_mb: 1024                                 # /boot partition size (MB)
      boot_efi_mb: 2048                             # /boot/efi partition size (MB)
      lv_root_mb: 65536                             # / LV size (MB)
      lv_home_mb: 20480                             # /home LV size (MB)
      lv_tmp_mb: 6144                               # /tmp LV size (MB)
      lv_var_tmp_mb: 6144                           # /var/tmp LV size (MB)
      lv_var_log_mb: 6144                           # /var/log LV size (MB)
      lv_var_log_audit_mb: 6144                     # /var/log/audit LV size (MB)
      lv_var_mb: 1                                  # /var LV size (1 = use remaining space)
    disks:
      - name: <disk_name>
        disk:
          capacity: <GB>
          bus: virtio|scsi
          volume_mode: filesystem|block
    performance:                                    # Optional: Performance tuning parameters
      hugepages: true|false                         # Enable huge pages backing (default: true)
      network_queues: <count>                       # virtio network queues (default: 2, max: vcpu count)
      iothread_count: <count>                       # Number of I/O threads (default: 1, max: vcpu count)
      vcpu_max: <count>                             # Maximum vCPUs for dynamic hotplug (optional, enables CPU hotplug)
      iommu_passthrough: true|false                 # Enable guest IOMMU passthrough (default: false, use for NVMe passthrough)
      guest_kernel_params: "<params>"               # Additional kernel parameters for guest (optional)
    redhat:
      org: "<organization_id>"                      # Red Hat organization ID
      activation_key: "<activation_key_name>"       # Red Hat activation key
```

Each VM is assigned to a specific hypervisor host via the `target_host` field. The deployment playbook filters VMs per host, allowing targeted deployment across the cluster.

**Performance Tuning**: The optional `performance` section enables fine-grained control over VM performance characteristics based on IBM KVM best practices. All parameters have sensible defaults and can be omitted for standard configurations.

**Authentication and Subscription**: VM credentials and subscription details are defined per-VM in `vars/vm_vars.yml` using Ansible vault variables for sensitive data. Common credentials can be referenced from `inventory/group_vars/infra_servers.yml` using vault variable syntax (e.g., `{{ encrypted_root_pass_vault }}`).

**Filesystem Layout**: The `fs` section defines compliance-focused LVM partitioning with separate volumes for system directories. Setting `lv_var_mb: 1` allocates remaining space to `/var`.

**Performance Parameters**:
- `hugepages` (default: true): Backs VM memory with huge pages on the host for improved memory performance. Disable if host paging or IBM Secure Execution is required.
- `network_queues` (default: 2): Number of virtio network queues for parallel packet processing. Set to at least 2 for VMs with multiple vCPUs. Do not exceed vCPU count.
- `iothread_count` (default: 1): Number of I/O threads for disk devices. Start with 1; increase for high-I/O workloads. Do not exceed vCPU count or configure idle threads.
- `vcpu_max` (optional): Maximum vCPUs for dynamic hotplug. If specified, VM starts with `vcpu` count and can scale up to `vcpu_max`. Enables CPU hotplug capability.
- `iommu_passthrough` (default: false): Enables guest IOMMU passthrough for improved PCI passthrough performance of NVMe/network devices. Note: Disables memory over-commitment.
- `guest_kernel_params` (optional): Additional kernel parameters appended to GRUB_CMDLINE_LINUX in guest. Useful for specialized tuning.

### Performance Tuning

This project implements IBM KVM performance best practices at both the hypervisor and VM levels.

**Hypervisor-Level Tuning** (configured in `playbooks/kvm_host_configure.yml`):
- **tuned profile**: `virtual-host` profile optimized for KVM hypervisors
- **Huge pages**: Automatically reserved based on available memory (70% of total memory)
- **KVM module parameters**:
  - `hpage=1`: Enables huge page support for VMs
  - `halt_poll_ns`: Configurable idle vCPU polling period (default: 50000ns)
- **CPU scheduler**: Configurable migration cost (kernel.sched_migration_cost_ns, default: 500000ns)
- **cgroup controller**: cpuset disabled for CPU hotplug support (cgroups v1 only)
- **Libvirt configuration**: Optimized for KVM workloads

**VM-Level Tuning** (configured per-VM in `vars/vm_vars.yml`):
- **Memory backing**: Huge pages enabled by default for all VMs
- **Memory balloon**: Disabled (model='none') to reduce overhead
- **Network interface**:
  - virtio driver with vhost backend
  - Multi-queue support (default: 2 queues, configurable up to vCPU count)
- **Storage**:
  - virtio-scsi controller with queues matching vCPU count
  - I/O threads enabled for SCSI disks (configurable count, distributed across disks)
  - Cache mode: `none` (direct I/O, caching done by guest)
  - IO mode: `native` (kernel async I/O)
  - Discard: `unmap` enabled for thin provisioning
- **CPU**: Dynamic vCPU hotplug support (optional)
- **Guest kernel**: IOMMU passthrough for PCI passthrough performance (optional)

**Configurable Parameters** (via `inventory/group_vars/infra_servers.yml`):
- `hugepages_count`: Override automatic huge pages calculation
- `kvm_halt_poll_ns`: Tune idle vCPU polling (50000ns default, 0 for low CPU usage, 80000ns for low latency)
- `sched_migration_cost_ns`: Tune CPU migration algorithm (500000ns default)

## File Structure

```
.
├── CLAUDE.md                                    # Project documentation
├── ansible.cfg                                  # Ansible configuration
├── requirements.yml                             # Ansible collection requirements
├── requirements.txt                             # Python package requirements
├── inventory/
│   ├── hosts.yml                                # Inventory file
│   ├── group_vars/
│   │   ├── all/
│   │   │   └── all.yml                          # Variables shared across all hosts
│   │   ├── http_servers.yml                     # Group variables for HTTP servers
│   │   └── infra_servers.yml                    # Group variables for KVM hosts
│   └── host_vars/
│       ├── localhost.yml                        # Empty (reserved for localhost overrides)
│       ├── infra1.yml                           # Host-specific variables
│       ├── infra2.yml
│       └── infra3.yml
├── playbooks/
│   ├── bare_metal_deploy_prep.yml               # Phase 1: Prepare iDRAC virtual media
│   ├── bare_metal_deploy_install.yml            # Phase 2: Boot and install OS
│   ├── kvm_host_configure.yml                   # Phase 3: Configure RAID/libvirt/ISO
│   ├── verify_raid_capability.yml               # Standalone: Verify RAID capability
│   ├── deploy_vm.yml                            # Phase 4: Deploy VMs in parallel (orchestrator)
│   ├── deploy_single_vm.yml                     # Phase 4: Deploy single VM (worker)
│   ├── remove_vm.yml                            # Utility: Remove VMs and storage (all or single)
│   ├── bare_metal_wipe_prep.yml                 # Utility: Transfer Live ISO and mount via iDRAC
│   └── bare_metal_wipe_exec.yml                 # Utility: Boot Live ISO and execute disk wipe
├── tasks/
│   ├── bare_metal_deploy_prep_subtasks1.yml     # Per-host kickstart/image generation
│   ├── detect_nvme_raid_devices.yml             # NVMe device auto-detection and RAID verification
│   ├── detect_wipe_targets.yml                  # Disk detection for wipe operations (BOSS and NVMe)
│   ├── setup_raid.yml                           # RAID 10 configuration tasks
│   ├── setup_libvirt.yml                        # Libvirt infrastructure tasks
│   ├── setup_performance_tuning.yml             # KVM hypervisor performance tuning tasks
│   ├── distribute_iso.yml                       # RHEL ISO distribution to hypervisors
│   ├── validate_os_disk.yml                     # OS disk capacity validation against filesystem layout
│   ├── vm_deploy_task.yml                       # VM deployment tasks (includes kickstart prep)
│   ├── vm_remove_task.yml                       # VM removal tasks (cleanup storage)
│   └── wipe_disk.yml                            # Disk wipe operations (zero/shred/blkdiscard/nvme-format)
├── vars/
│   └── vm_vars.yml                              # VM definitions with network config
├── logs/                                        # VM deployment logs (auto-created, gitignored)
│   └── rhis_builder_kvm_lz_demo_<vmname>_prov.txt
└── template/
    ├── ks.cfg.j2                                # Kickstart template (bare metal)
    ├── vm_ks.cfg.j2                             # Kickstart template (VMs) - uses reboot --eject
    ├── vm_definition.xml.j2                     # Libvirt VM XML template (with install media)
    └── vm_definition_clean.xml.j2               # Libvirt VM XML template (reference only, not actively used)
```

## Deployment Workflow

### Phase 1: Bare Metal Provisioning (Dell iDRAC)

1. Update `inventory/hosts.yml` with inventory configuration:
   - Per-host `ansible_host`: Production network IP for OS access
   - Per-host `idrac_ip`: Out-of-band management network IP for iDRAC operations
   - Per-host `idrac_user` and `idrac_password`: iDRAC credentials (use ansible-vault for production)
2. Update `inventory/host_vars/*.yml` with host-specific configuration
3. Update shared variables:
   - `inventory/group_vars/all/all.yml`: Shared across all hosts
     - `iso_filename`: RHEL ISO filename (e.g., `rhel-9.7-x86_64-dvd.iso`)
     - `img_filename`: OEMDRV image filename (e.g., `oemdrv.img`)
     - `local_workspace`: Local workspace directory (e.g., `/tmp/kickstart`)
     - `http_server_base_url`: Base URL for HTTP server (e.g., `http://provisioner.domain.test/provision`)
     - `remote_http_docroot`: HTTP server document root path (e.g., `/var/www/html/provision`)
   - `inventory/group_vars/http_servers.yml`: HTTP server group variables
     - `local_iso_path`: Directory containing RHEL ISO (e.g., `/home/user/iso`)
     - `remote_http_host`: Provisioner server hostname for hosting installation media
     - `remote_http_user`: SSH user for accessing provisioner server
4. Validate syntax: `ansible-lint playbooks/bare_metal_deploy_prep.yml`
5. Prepare virtual media: `ansible-playbook playbooks/bare_metal_deploy_prep.yml`
   - Single localhost play orchestrates the entire workflow
   - Loops over `groups['infra_servers']` for per-host artifacts
   - Delegates http_servers tasks as needed
   - Transfers files via rsync to http_servers
6. Install OS: `ansible-playbook playbooks/bare_metal_deploy_install.yml`
   - Configures boot override to Virtual CD using `dellemc.openmanage.idrac_boot` module
   - Boot once enabled (reverts to HDD after installation)
   - Power cycles servers via `dellemc.openmanage.redfish_powerstate` module
   - Waits for SSH availability (timeout: 60 minutes)
   - Uses `idrac_ip` for out-of-band iDRAC access (not `ansible_host`)

### Phase 2: KVM Host Configuration

1. Configure RAID and libvirt: `ansible-playbook playbooks/kvm_host_configure.yml`
   - Registers systems with Red Hat Subscription Manager using `host.org` and `host.activation_key`
   - Installs virtualization packages via `@virtualization-host-environment` group
   - Auto-detects Dell DC NVMe devices and populates `host.additional_disks` if not defined
   - Verifies minimum 4 disks available (fails fast if insufficient)
   - Creates mdadm RAID 10 on additional NVMe disks
   - Loads VM definitions from `vars/vm_vars.yml` to detect storage requirements
   - Partitions RAID array (using TiB units) and creates LVM infrastructure based on volume_mode requirements:
     - Filesystem pool (if any VM uses volume_mode: filesystem)
     - Block pool (if any VM uses volume_mode: block)
   - Configures libvirt bridge network on second NIC:
     - Removes existing connections (including DHCP) from physical interface
     - Creates bridge with IPv4/IPv6 disabled (no IP address)
     - Adds physical interface as bridge slave using modern NetworkManager syntax
   - Creates appropriate libvirt storage pools with autostart enabled
   - Installs required packages for VM kickstart (dosfstools, mtools, qemu-img)
   - Downloads RHEL ISO from HTTP server to each hypervisor's filesystem pool (`/mnt/md0/libvirt/filesystem/iso/`)
   - Configures performance tuning (IBM KVM best practices):
     - Sets tuned profile to `virtual-host`
     - Configures KVM module parameters (hpage=1, halt_poll_ns)
     - Reserves huge pages for VM memory backing
     - Tunes CPU scheduler migration cost (if available on kernel)
     - Disables cpuset cgroup controller (cgroups v1 only, enables CPU hotplug)

### Phase 3: VM Deployment

1. Define VMs in `vars/vm_vars.yml` with `target_host` assignments and network configuration
2. Validate syntax: `ansible-lint playbooks/deploy_vm.yml`
3. Deploy VMs: `ansible-playbook playbooks/deploy_vm.yml`
   - Playbook runs on all `infra_servers`
   - Each host deploys only VMs with matching `target_host`
   - **VMs deploy in parallel on each hypervisor** (up to 2 hour timeout per VM)
   - Can deploy to specific host: `ansible-playbook playbooks/deploy_vm.yml --limit infra1`

**Pre-Deployment Validation:**

The playbook performs automatic validation before deployment begins:

- **OS Disk Capacity Check**: For disks named with `_os` pattern (e.g., `idm1_os1`), validates that disk capacity is sufficient for the defined filesystem layout
- **Calculation**: Sums all filesystem sizes from `fs` section (boot, boot_efi, LV sizes), adds 5% LVM overhead, converts to GB
- **Special handling**: `lv_var_mb: 1` (use remaining space) is treated as 0 for validation purposes
- **Fail-fast**: If capacity is insufficient, playbook exits with detailed error message showing:
  - Current disk capacity vs. required capacity
  - Breakdown of all filesystem allocations
  - Specific action needed (increase disk or reduce filesystems)

**Automated Kickstart Installation Workflow:**
1. Create disk volumes (qemu-img for filesystem mode, LVM for block mode)
2. Generate per-VM kickstart configuration from template (`vm_ks.cfg.j2`)
3. Create FAT32 USB image with OEMDRV label containing kickstart file
4. Define VM with CD-ROM (RHEL ISO) and USB (kickstart image) devices
5. Start VM with boot order: HDD first (order='1'), CD-ROM second (order='2')
   - Ensures VM boots from HDD after installation regardless of CD-ROM eject status
   - Provides hardware-level safeguard against boot loops
6. VM boots from ISO on first boot (HDD empty, falls through to CD-ROM)
7. Auto-detects kickstart from USB OEMDRV label
8. Automated OS installation with static network, compliance LVM layout, and provisioner user
9. Kickstart completes with `reboot --eject`, ejecting CD-ROM before reboot
10. VM reboots and boots from HDD (CD-ROM ejected, boot order ensures HDD priority)
11. Wait for SSH availability (timeout: 60 minutes)
12. Enable autostart for production use
13. Deployment logs written to `logs/rhis_builder_kvm_lz_demo_<vmname>_prov.txt`

**Monitoring Parallel Deployments:**

Since VMs deploy in parallel, you can monitor individual deployment progress via log files:

```bash
# Monitor specific VM deployment in real-time
tail -f logs/rhis_builder_kvm_lz_demo_idm1.flightpath.test_prov.txt

# Check status of all VM deployments
ls -lht logs/

# Search for errors across all deployments
grep -i error logs/*.txt

# View deployment completion summary (displayed at end of playbook run)
# Lists all deployed VMs and their log file paths
```

After deployment completes, the playbook displays a summary showing:
- Total VMs deployed on each hypervisor
- Each VM name with its specific log file path
- Copy-paste ready tail commands for log viewing

### VM Removal (Development/Troubleshooting)

For rapid iteration during development or troubleshooting deployment issues:

1. Validate syntax: `ansible-lint playbooks/remove_vm.yml`
2. Remove VMs: `ansible-playbook playbooks/remove_vm.yml`
   - Runs on all `infra_servers`
   - Each host removes only VMs with matching `target_host`
   - Can remove from specific host: `ansible-playbook playbooks/remove_vm.yml --limit infra1`
   - Can remove a single VM: `ansible-playbook playbooks/remove_vm.yml -e target_host=infra1 -e vm_to_remove=idm1.flightpath.test`

**Removal Operations (in order):**
1. Check VM state and destroy if running (forced shutdown)
2. Undefine VM from libvirt
3. Remove filesystem-mode disk images (`.img` files)
4. Remove block-mode logical volumes from `{{ lvm_vg_block_name }}`
5. Remove kickstart configuration and USB image files
6. Clean up temporary XML definition files

**Notes:**
- All operations are idempotent - safe to run even if VM doesn't exist
- No confirmation prompts - playbook execution is the confirmation
- Storage is permanently deleted - use with caution in production
- When `vm_to_remove` is specified, the playbook asserts the VM exists on `target_host` and fails fast with a clear message if not found

### VM Lifecycle: Delete and Redeploy (Symmetric Workflow)

`remove_vm.yml` and `deploy_single_vm.yml` are designed to be symmetric counterparts.
Both accept `target_host` and a VM name extra var, enabling a clean delete + fresh install cycle:

```bash
# Step 1: Remove a single VM and its storage
ansible-playbook playbooks/remove_vm.yml \
  -e target_host=infra1 \
  -e vm_to_remove=idm1.flightpath.test

# Step 2: Redeploy a fresh install of the same VM
ansible-playbook playbooks/deploy_single_vm.yml \
  -e target_host=infra1 \
  -e vm_to_deploy=idm1.flightpath.test
```

The VM definition in `vars/vm_vars.yml` is the single source of truth for both operations — no configuration changes needed between steps.

### Bare Metal Disk Wipe (Live ISO Utility)

The bare metal wipe workflow uses the CentOS Stream 10 Live ISO (`CentOS-Stream-MIN-Live-Automation.x86_64-10.iso`) — a minimal live image that boots entirely in memory with an `ansible` user, Python3, and SSH pre-configured. This enables Ansible-driven disk operations without touching the installed OS.

**Use cases:** Pre-reprovisioning storage wipe, NVMe secure erase, RAID teardown preparation.

**Supported wipe methods** (configured via `wipe_method` in `inventory/group_vars/infra_servers.yml`):

| Method | Tool | Package | Notes |
|--------|------|---------|-------|
| `blkdiscard` | blkdiscard | util-linux | Default — SSD TRIM/UNMAP, near-instant |
| `zero` | dd | coreutils | Fast zero-write, not DoD-compliant |
| `shred` | shred | coreutils | DoD 3-pass overwrite, slow |
| `nvme-format` | nvme | nvme-cli | NVMe hardware secure erase, fastest |

**Disk targeting** (configured in `inventory/group_vars/infra_servers.yml`):
- `wipe_boss_devices: true` — targets Dell BOSS devices
- `wipe_nvme_devices: true` — targets Dell DC NVMe devices

**Workflow:**

```bash
# Step 1: Transfer Live ISO to HTTP server and mount via iDRAC
ansible-playbook playbooks/bare_metal_wipe_prep.yml

# Step 2: Boot to Live ISO, detect disks, wipe, power off
ansible-playbook playbooks/bare_metal_wipe_exec.yml

# Optional: target a specific host
ansible-playbook playbooks/bare_metal_wipe_exec.yml --limit infra1
```

Wipe logs are fetched to the controller at `logs/wipe_<hostname>_<timestamp>.log` before the post-wipe power action executes.

## Additional Context

### Performance Tuning Implementation Notes

**Host-Level Changes That Require Reboot or Reload:**
- **KVM module parameters** (`/etc/modprobe.d/kvm.conf`): Require stopping all VMs and reloading the KVM module:
  ```bash
  # Stop all VMs first
  systemctl stop libvirtd
  rmmod kvm_intel kvm  # or kvm_amd on AMD systems
  modprobe kvm
  systemctl start libvirtd
  ```
- **libvirt cgroup controller** (`/etc/libvirt/qemu.conf`): Requires restarting libvirtd:
  ```bash
  # Stop all VMs first
  systemctl restart libvirtd
  ```
- **Huge pages and CPU scheduler**: Applied immediately via sysctl
- **tuned profile**: Applied immediately

**VM-Level Performance Features:**
- Huge pages, multi-queue networking, I/O threads, and memory balloon exclusion are configured in VM XML during deployment
- Dynamic vCPU hotplug requires the VM to be defined with `vcpu_max` parameter
- Guest kernel parameters (iommu.passthrough) are configured during kickstart installation

**Libvirt Infrastructure:**
- Storage pools and networks require explicit `virsh pool-autostart` / `virsh net-autostart` commands for autostart
- The `community.libvirt.virt_pool` and `community.libvirt.virt_net` modules' `autostart: true` parameter doesn't reliably apply to existing resources
- Autostart is configured separately after pool/network activation to ensure reliability

**Important Considerations:**
- **Memory over-commitment**: Not possible with `iommu.passthrough=1` enabled on guest
- **Huge pages**: Reduces available memory for host; ensure adequate RAM for host OS
- **I/O threads**: More is not always better; start with 1 and increase only for high-I/O workloads
- **Network queues**: Should not exceed vCPU count; 2 is optimal for most workloads
- **CPU scheduler tuning**: The `kernel.sched_migration_cost_ns` parameter is optional and may not exist on all kernel versions; playbook handles gracefully
- **Partition sizes**: Calculated dynamically from percentage allocation; parted uses GiB units (binary, 1024-based)
- **ISO distribution**: Large ISO files (9.9 GB) are downloaded directly from HTTP server to avoid Ansible temp directory space issues

**References:**
- IBM KVM Performance Hints and Tips Summary (Last Updated: 2026-04-23)
- Red Hat Virtualization Tuning and Optimization Guide
- KVM Network Performance - Best Practices and Tuning Recommendations

## Notes for Claude

- The approach used in the current codebase is solid - continue with similar patterns
- Monitor user feedback and update this document as preferences evolve
- Always run `ansible-lint` before marking tasks complete
