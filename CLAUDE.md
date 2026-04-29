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
    - RAID array partitioned based on VM volume_mode requirements
    - **Filesystem Pool** (volume_mode: filesystem): 1TB LVM partition with XFS, mounted at `/mnt/{{ raid_name }}/libvirt/filesystem`, libvirt pool type `dir`
    - **Block Pool** (volume_mode: block): 1TB LVM volume group, libvirt pool type `logical` for direct block access
    - VM definitions in `vars/vm_vars.yml` determine which pools are created
    - Each pool created only if corresponding volume_mode is defined in VM disks
- **Network Configuration**:
  - Primary NIC: Configured during kickstart (identified by MAC address)
  - Libvirt bridge: Configured on second NIC with active link
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
      name_server1: "<DNS1>"
      name_server2: "<DNS2>"
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
    redhat:
      org: "<organization_id>"                      # Red Hat organization ID
      activation_key: "<activation_key_name>"       # Red Hat activation key
```

Each VM is assigned to a specific hypervisor host via the `target_host` field. The deployment playbook filters VMs per host, allowing targeted deployment across the cluster.

**Authentication and Subscription**: VM credentials and subscription details are defined per-VM in `vars/vm_vars.yml` using Ansible vault variables for sensitive data. Common credentials can be referenced from `inventory/group_vars/infra_servers.yml` using vault variable syntax (e.g., `{{ encrypted_root_pass_vault }}`).

**Filesystem Layout**: The `fs` section defines compliance-focused LVM partitioning with separate volumes for system directories. Setting `lv_var_mb: 1` allocates remaining space to `/var`.

### Performance Tuning

- **SCSI controller**: virtio-scsi with queues matching vCPU count
- **IO threads**: Enabled for SCSI disks
- **Cache mode**: `none` (direct I/O)
- **IO mode**: `native` (kernel async I/O)
- **Discard**: `unmap` enabled for thin provisioning

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
│   │   ├── all.yml                              # Variables shared across all hosts
│   │   └── infra_servers.yml                    # Group variables for KVM hosts
│   └── host_vars/
│       ├── localhost.yml                        # Localhost-specific variables
│       ├── infra1.yml                           # Host-specific variables
│       ├── infra2.yml
│       └── infra3.yml
├── playbooks/
│   ├── bare_metal_deploy_prep.yml               # Phase 1: Prepare iDRAC virtual media
│   ├── bare_metal_deploy_install.yml            # Phase 2: Boot and install OS
│   ├── kvm_host_configure.yml                   # Phase 3: Configure RAID/libvirt/ISO
│   └── deploy_vm.yml                            # Phase 4: Deploy VMs with kickstart
├── tasks/
│   ├── bare_metal_deploy_prep_subtasks1.yml     # Per-host kickstart/image generation
│   ├── setup_raid.yml                           # RAID 10 configuration tasks
│   ├── setup_libvirt.yml                        # Libvirt infrastructure tasks
│   ├── distribute_iso.yml                       # RHEL ISO distribution to hypervisors
│   ├── vm_kickstart_prep.yml                    # VM kickstart config and USB image generation
│   └── vm_deploy_task.yml                       # VM deployment tasks
├── vars/
│   └── vm_vars.yml                              # VM definitions with network config
└── template/
    ├── ks.cfg.j2                                # Kickstart template (bare metal)
    ├── vm_ks.cfg.j2                             # Kickstart template (VMs)
    ├── vm_definition.xml.j2                     # Libvirt VM XML template (with install media)
    └── vm_definition_clean.xml.j2               # Libvirt VM XML template (post-install)
```

## Deployment Workflow

### Phase 1: Bare Metal Provisioning (Dell iDRAC)

1. Update `inventory/host_vars/*.yml` with host-specific configuration
2. Update shared variables:
   - `inventory/group_vars/all.yml`: Shared across all hosts
     - `iso_filename`: RHEL ISO filename (e.g., `rhel-9.7-x86_64-dvd.iso`)
     - `img_filename`: OEMDRV image filename (e.g., `oemdrv.img`)
     - `http_server_base_url`: Base URL for HTTP server (e.g., `http://provisioner.domain.test/provision`)
     - `remote_http_docroot`: HTTP server document root path (e.g., `/var/www/html/provision`)
   - `inventory/host_vars/localhost.yml`: Localhost orchestration variables
     - `local_workspace`: Local workspace directory (e.g., `/tmp/kickstart`)
     - `local_iso_path`: Directory containing RHEL ISO (e.g., `/home/user/iso`)
     - `remote_http_host`: Provisioner server hostname for hosting installation media
     - `remote_http_user`: SSH user for accessing provisioner server
3. Validate syntax: `ansible-lint playbooks/bare_metal_deploy_prep.yml`
4. Prepare virtual media: `ansible-playbook playbooks/bare_metal_deploy_prep.yml`
   - Executes on localhost with orchestration pattern
   - Loops over `groups['infra_servers']` for per-host artifacts
   - Transfers files via rsync to http_servers and infra_servers
5. Install OS: `ansible-playbook playbooks/bare_metal_deploy_install.yml`

### Phase 2: KVM Host Configuration

1. Configure RAID and libvirt: `ansible-playbook playbooks/kvm_host_configure.yml`
   - Auto-detects Dell DC NVMe devices and populates `host.additional_disks` if not defined
   - Verifies minimum 4 disks available (fails fast if insufficient)
   - Creates mdadm RAID 10 on additional NVMe disks
   - Loads VM definitions from `vars/vm_vars.yml` to detect storage requirements
   - Partitions RAID array and creates LVM infrastructure based on volume_mode requirements:
     - Filesystem pool (if any VM uses volume_mode: filesystem)
     - Block pool (if any VM uses volume_mode: block)
   - Configures libvirt bridge network
   - Creates appropriate libvirt storage pools
   - Installs required packages for VM kickstart (dosfstools, mtools, qemu-img)
   - Distributes RHEL ISO to each hypervisor's filesystem pool (`/mnt/md0/libvirt/filesystem/iso/`)

### Phase 3: VM Deployment

1. Define VMs in `vars/vm_vars.yml` with `target_host` assignments and network configuration
2. Validate syntax: `ansible-lint playbooks/deploy_vm.yml`
3. Check mode test: `ansible-playbook playbooks/deploy_vm.yml --check`
4. Deploy VMs: `ansible-playbook playbooks/deploy_vm.yml`
   - Playbook runs on all `infra_servers`
   - Each host deploys only VMs with matching `target_host`
   - Can deploy to specific host: `ansible-playbook playbooks/deploy_vm.yml --limit infra1`

**Automated Kickstart Installation Workflow:**
1. Create disk volumes (qemu-img for filesystem mode, LVM for block mode)
2. Generate per-VM kickstart configuration from template (`vm_ks.cfg.j2`)
3. Create FAT32 USB image with OEMDRV label containing kickstart file
4. Define VM with CD-ROM (RHEL ISO) and USB (kickstart image) devices
5. Start VM with boot order: CD-ROM first, then HDD
6. VM boots from ISO and auto-detects kickstart from USB OEMDRV label
7. Automated OS installation with static network, compliance LVM layout, and provisioner user
8. Wait for SSH availability (timeout: 60 minutes)
9. Shutdown VM and redefine without installation media
10. Restart VM with autostart enabled for production use

## Additional Context

_This section will be expanded as the project evolves. More details to come._

## Notes for Claude

- The approach used in the current codebase is solid - continue with similar patterns
- Monitor user feedback and update this document as preferences evolve
- Always run `ansible-lint` before marking tasks complete
