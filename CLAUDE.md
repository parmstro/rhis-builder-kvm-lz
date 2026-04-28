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
    disks:
      - name: <disk_name>
        disk:
          capacity: <GB>
          bus: virtio|scsi
          volume_mode: filesystem|block
```

Each VM is assigned to a specific hypervisor host via the `target_host` field. The deployment playbook filters VMs per host, allowing targeted deployment across the cluster.

### Performance Tuning

- **SCSI controller**: virtio-scsi with queues matching vCPU count
- **IO threads**: Enabled for SCSI disks
- **Cache mode**: `none` (direct I/O)
- **IO mode**: `native` (kernel async I/O)
- **Discard**: `unmap` enabled for thin provisioning

## File Structure

```
.
├── CLAUDE.md                            # Project documentation
├── ansible.cfg                          # Ansible configuration
├── requirements.yml                     # Ansible collection requirements
├── requirements.txt                     # Python package requirements
├── inventory/
│   ├── hosts.yml                        # Inventory file
│   ├── group_vars/
│   │   └── infra_servers.yml            # Group variables for KVM hosts
│   └── host_vars/
│       ├── infra1.yml                   # Host-specific variables
│       ├── infra2.yml
│       └── infra3.yml
├── playbooks/
│   ├── bare_metal_deploy_prep.yml       # Phase 1: Prepare iDRAC virtual media
│   ├── bare_metal_deploy_install.yml    # Phase 2: Boot and install OS
│   ├── kvm_host_configure.yml           # Phase 3: Configure RAID/libvirt
│   └── deploy_vm.yml                    # Phase 4: Deploy VMs
├── tasks/
│   ├── setup_raid.yml                   # RAID 10 configuration tasks
│   ├── setup_libvirt.yml                # Libvirt infrastructure tasks
│   └── vm_deploy_task.yml               # VM deployment tasks
├── vars/
│   └── vm_vars.yml                      # VM definitions
└── template/
    ├── ks.cfg.j2                        # Kickstart template
    └── vm_definition.xml.j2             # Libvirt VM XML template
```

## Deployment Workflow

### Phase 1: Bare Metal Provisioning (Dell iDRAC)

1. Update `inventory/host_vars/*.yml` with host-specific configuration
2. Update `inventory/group_vars/infra_servers.yml` with shared settings
3. Validate syntax: `ansible-lint playbooks/bare_metal_deploy_prep.yml`
4. Prepare virtual media: `ansible-playbook playbooks/bare_metal_deploy_prep.yml`
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

### Phase 3: VM Deployment

1. Define VMs in `vars/vm_vars.yml` with `target_host` assignments
2. Validate syntax: `ansible-lint playbooks/deploy_vm.yml`
3. Check mode test: `ansible-playbook playbooks/deploy_vm.yml --check`
4. Deploy VMs: `ansible-playbook playbooks/deploy_vm.yml`
   - Playbook runs on all `infra_servers`
   - Each host deploys only VMs with matching `target_host`
   - Can deploy to specific host: `ansible-playbook playbooks/deploy_vm.yml --limit infra1`

## Additional Context

_This section will be expanded as the project evolves. More details to come._

## Notes for Claude

- The approach used in the current codebase is solid - continue with similar patterns
- Monitor user feedback and update this document as preferences evolve
- Always run `ansible-lint` before marking tasks complete
