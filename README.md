# rhis-builder-kvm-lz
A landing zone configuration project for bootstrapping a KVM Infrastructure Deployment with Ansible.

The initial work of this project is to demonstrate the automated deployment of RHEL 9 KVM hypervisor infrastructure on Dell servers using Ansible, iDRAC virtual media, and kickstart provisioning.

## Overview

This project provides a complete automation stack for deploying KVM hypervisor infrastructure:

1. **Bare Metal Provisioning**: Deploy RHEL 9 on Dell servers via iDRAC virtual media
2. **Infrastructure Configuration**: Configure RAID storage, libvirt networking, and storage pools
3. **VM Deployment**: Deploy virtual machines across the hypervisor cluster

### Key Features

- **Dell BOSS Auto-Detection**: Kickstart automatically detects and uses Dell BOSS devices for OS installation
- **Dell DC NVMe Auto-Detection**: RAID setup automatically identifies Dell DC NVMe SSDs using disk/by-id paths
- **NVMe RAID 10**: Automated mdadm RAID 10 configuration with auto-detected or configured NVMe disks
- **Compliance-Focused**: Partitioning scheme meets DISA-STIG, CIS, PCI-DSS requirements
- **Disk-by-ID Naming**: Stable device references using `/dev/disk/by-id/`
- **Bridge Networking**: Libvirt bridge mode on secondary NIC with active link detection
- **Performance Tuned**: virtio-scsi, IO threads, direct I/O for VM storage

## Prerequisites

### Control Node (Ansible Host)

- Ansible 2.9+
- Python 3.6+
- Network access to Dell iDRAC interfaces
- HTTP server for hosting installation media

### Target Servers

- Dell PowerEdge servers with iDRAC 9+
- Recommended: Dell BOSS device for OS boot
- Recommended: Dell DC NVMe SSDs for VM storage
- Minimum 4 NVMe disks for RAID 10 array
- Dual network interfaces (one for management, one for VM bridge)
- Red Hat Enterprise Linux 9 subscription or activation key

## Quick Start

### 1. Install Requirements

```bash
# Install Ansible collections
ansible-galaxy collection install -r requirements.yml

# Install Python dependencies
pip install -r requirements.txt
```

### 2. Configure Inventory

Edit inventory files with your server details:

```bash
# Main inventory
vim inventory/hosts.yml

# Group variables (shared settings)
vim inventory/group_vars/infra_servers.yml

# Host-specific variables
vim inventory/host_vars/infra1.yml
vim inventory/host_vars/infra2.yml
vim inventory/host_vars/infra3.yml
```

**Key configurations:**
- iDRAC credentials
- Network settings (IP, MAC addresses)
- Disk paths (disk-by-id):
  - `boot_disk` and `root_disk`: Fallback if Dell BOSS not detected
  - `additional_disks`: NVMe devices for RAID 10 (use disk-by-id paths)
  - Note: Kickstart auto-detects Dell BOSS and Dell DC NVMe devices
- Red Hat subscription details
- SSH keys and passwords (use `ansible-vault` for production)

### 3. Prepare Installation Media

Place RHEL 9 ISO in the location specified in `inventory/group_vars/infra_servers.yml`:

```yaml
local_iso_path: "/path/to/rhel-9.7-x86_64-dvd.iso"
```

Ensure HTTP server is configured and accessible:

```yaml
remote_http_host: "provisioner.domain.test"
remote_http_docroot: "/var/www/html/provision"
```

**HTTP server directory structure created:**
```
/var/www/html/provision/
├── iso/
│   └── rhel-9.7-x86_64-dvd.iso          # Shared across all hosts
└── image/
    ├── infra1/
    │   └── oemdrv.img                   # Host-specific kickstart image
    ├── infra2/
    │   └── oemdrv.img
    └── infra3/
        └── oemdrv.img
```

### 4. Deploy Infrastructure

#### Phase 1: Bare Metal OS Installation

```bash
# Prepare and mount virtual media
ansible-playbook playbooks/bare_metal_deploy_prep.yml

# Boot servers and install OS (waits for installation to complete)
ansible-playbook playbooks/bare_metal_deploy_install.yml
```

**What happens:**
1. Generates per-host kickstart files from template
2. Creates per-host OEMDRV FAT32 images with embedded kickstart
3. Copies ISO to HTTP server (shared: `iso/rhel-9.4-x86_64-dvd.iso`)
4. Copies OEMDRV images to host-specific directories (`image/{{ hostname }}/oemdrv.img`)
5. Mounts virtual media via iDRAC (ISO + host-specific OEMDRV)
6. Configures boot override to Virtual CD
7. Reboots servers
8. Kickstart %pre phase detects Dell BOSS device for OS installation (if present)
9. Dynamically generates partition commands based on detected hardware
10. Waits for OS installation and SSH availability (up to 60 minutes)

#### Phase 2: KVM Host Configuration

```bash
# Configure RAID, libvirt, networking, and prepare for VM deployment
ansible-playbook playbooks/kvm_host_configure.yml
```

**What happens:**
1. Auto-detects Dell DC NVMe SSD devices and populates `host.additional_disks` if not defined
2. Verifies minimum 4 disks available for RAID 10 (fails fast if insufficient)
3. Creates mdadm RAID 10 on detected/configured NVMe disks
4. Loads VM definitions from `vars/vm_vars.yml` to detect storage requirements
5. Partitions RAID array based on volume_mode requirements:
   - Partition 1 (1TB): Filesystem pool (if any VM uses `volume_mode: filesystem`)
   - Partition 2 (1TB): Block pool (if any VM uses `volume_mode: block`)
6. Creates LVM infrastructure and libvirt storage pools:
   - **Filesystem pool**: XFS on LVM, mounted at `/mnt/{{ raid_name }}/libvirt/filesystem`, pool type `dir`
   - **Block pool**: LVM volume group, pool type `logical` for direct block device access
7. Detects secondary NIC and creates bridge
8. Configures libvirt bridge-mode network
9. Enables firewall rules and IP forwarding
10. Installs required packages for VM kickstart (dosfstools, mtools, qemu-img)
11. Distributes RHEL ISO to each hypervisor's filesystem pool at `/mnt/md0/libvirt/filesystem/iso/`

**Run specific sections:**
```bash
# Only configure RAID
ansible-playbook playbooks/kvm_host_configure.yml --tags raid

# Only configure libvirt
ansible-playbook playbooks/kvm_host_configure.yml --tags libvirt

# Only distribute ISO
ansible-playbook playbooks/kvm_host_configure.yml --tags iso

# Single host only
ansible-playbook playbooks/kvm_host_configure.yml --limit infra1
```

#### Phase 3: VM Deployment

```bash
# Define VMs in vars/vm_vars.yml with network configuration
vim vars/vm_vars.yml

# Deploy VMs to cluster with automated kickstart installation
ansible-playbook playbooks/deploy_vm.yml
```

**What happens:**
1. Each hypervisor filters VMs by `target_host`
2. Creates disk volumes (qemu-img for filesystem mode, LVM for block mode)
3. Generates per-VM kickstart configuration from template
4. Creates FAT32 USB image (10MB) with OEMDRV label containing kickstart file
5. Stores kickstart artifacts in filesystem pool: `/mnt/md0/libvirt/filesystem/kickstart/`
6. Templates libvirt XML with:
   - CD-ROM device pointing to RHEL ISO
   - USB disk device pointing to kickstart image
   - Boot order: CD-ROM first, then HDD
   - Performance tuning (virtio-scsi, IO threads)
   - Network interface with specified MAC address
7. Defines and starts VM for installation
8. VM boots from CD-ROM, auto-detects kickstart from USB OEMDRV label
9. Automated OS installation proceeds:
   - Static network configuration
   - Compliance-focused LVM partitioning
   - Provisioner user creation
   - Red Hat subscription registration
   - System updates
10. Waits for SSH availability (timeout: 60 minutes)
11. Shuts down VM and redefines without installation media
12. Restarts VM with autostart enabled for production use

**Monitor installation progress:**
```bash
# Watch VM console during installation
ssh infra1 "virsh console idm1.domain.test"

# Check installation logs after completion
ssh ansiblerunner@10.10.10.100 "cat /root/install.post.log"
```

**Deploy to specific host:**
```bash
ansible-playbook playbooks/deploy_vm.yml --limit infra2
```

**Verify deployment:**
```bash
# Check VM status
ssh infra1 "virsh list --all"

# Verify kickstart artifacts
ssh infra1 "ls -lh /mnt/md0/libvirt/filesystem/kickstart/"

# Test SSH connectivity
ansible-playbook -i "10.10.10.100," -u ansiblerunner -m ping all
```

## Configuration Details

### Network Configuration

**Primary NIC:**
- Configured during kickstart via MAC address
- Used for management traffic
- Static IP assignment

**Secondary NIC:**
- Auto-detected (second NIC with active link)
- Configured as libvirt bridge (`br1`)
- Used for VM networking

**Libvirt Network:**
- Name: `libvirt_net1` (incremental for future expansion)
- Mode: Bridge
- Bridge device: `br1`

### Storage Configuration

**Disk Detection:**
- **Dell BOSS (Kickstart)**: Auto-detected during kickstart for OS installation
  - Detection result stored in `/tmp/bootdisk.cfg`
  - Fallback to `host.boot_disk` and `host.root_disk` from host_vars if not found
- **Dell DC NVMe (RAID Setup)**: Auto-detected during RAID configuration
  - Uses `/dev/disk/by-id/*Dell_DC_NVMe*` paths
  - Fallback to `host.additional_disks` from host_vars if not found

**OS Storage:**
- Installed to Dell BOSS device (auto-detected) or configured disk
- Compliance-focused LVM layout:
  - `/boot`: 1024 MB (ext4)
  - `/boot/efi`: 600 MB (EFI)
  - `/` (root): 20 GB
  - `/home`: 10 GB
  - `/tmp`: 10 GB
  - `/var/tmp`: 10 GB
  - `/var/log`: 20 GB
  - `/var/log/audit`: 10 GB
  - `/var` (grows): 20+ GB

**VM Storage (Post-Install - RAID Setup):**
- Auto-detects Dell DC NVMe devices using `/dev/disk/by-id/nvme-Dell_DC_NVMe*`
- Detection happens early in `kvm_host_configure.yml` before RAID setup
- Falls back to `host.additional_disks` from host_vars if no Dell DC NVMe found or if already defined
- Requires minimum 4 disks; playbook fails fast if insufficient
- mdadm RAID 10 array on 4+ NVMe disks (auto-detected or configured)
- Dual LVM-based storage pools (created based on VM requirements):
  - **Filesystem Pool** (`nvme_pool_fs`):
    - 1TB GPT partition on RAID array
    - LVM physical volume and volume group (`vg_nvme_fs`)
    - 100% LVM logical volume formatted with XFS
    - Mounted at `/mnt/{{ raid_name }}/libvirt/filesystem`
    - Libvirt pool type: `dir`
    - SELinux context: `virt_image_t`
    - Used for VMs with `volume_mode: filesystem`
  - **Block Pool** (`nvme_pool_block`):
    - 1TB GPT partition on RAID array
    - LVM physical volume and volume group (`vg_nvme_block`)
    - Libvirt pool type: `logical`
    - Direct block device access for VM disks
    - Used for VMs with `volume_mode: block`
- VM definitions in `vars/vm_vars.yml` determine which pools are created
- mdmonitor service enabled for RAID monitoring

### VM Definitions

Example `vars/vm_vars.yml`:

```yaml
---
vms:
  - vmname: idm1.domain.test
    target_host: infra1                          # Deploy to this hypervisor
    vcpu: 2
    memory: 8192                                 # MB
    network:
      hostname: "idm1"                           # Short hostname (without domain)
      domain: "domain.test"                      # DNS domain name
      mac: "52:54:00:aa:bb:01"                   # Use libvirt MAC range: 52:54:00:XX:XX:XX
      ipv4_address: "10.10.10.100"
      ipv4_netmask: "255.255.255.0"
      ipv4_gateway: "10.10.10.1"
      name_server1: "8.8.8.8"
      name_server2: "8.8.4.4"
    root_enc_pass: "{{ encrypted_root_pass_vault }}"
    grub_enc_pass: "{{ encrypted_grub_pass_vault }}"
    username: "ansiblerunner"
    user_enc_pass: "{{ encrypted_user_pass_vault }}"
    user_sudoer_policy: "{{ user_sudoer_policy_vault }}"
    ssh_pub_key: "{{ ssh_pub_key_vault }}"
    fs:
      filesystem: "xfs"
      boot_mb: 1024
      boot_efi_mb: 2048
      lv_root_mb: 65536                          # 64GB for root
      lv_home_mb: 20480                          # 20GB for /home
      lv_tmp_mb: 6144                            # 6GB for /tmp
      lv_var_tmp_mb: 6144                        # 6GB for /var/tmp
      lv_var_log_mb: 6144                        # 6GB for /var/log
      lv_var_log_audit_mb: 6144                  # 6GB for /var/log/audit
      lv_var_mb: 1                               # Use remaining space for /var
    disks:
      - name: idm1_os
        disk:
          capacity: 100                          # GB
          bus: virtio
          volume_mode: filesystem                # Raw file on XFS
      - name: idm1_data
        disk:
          capacity: 500
          bus: scsi                              # Uses virtio-scsi with IO threads
          volume_mode: block                     # Direct block access to NVMe
    redhat:
      org: "12345678"
      activation_key: "redhat-activation-keyname"
```

**Network Configuration:**
- `hostname`: Short hostname without domain suffix
- `domain`: DNS domain name (combined with hostname for FQDN)
- `mac`: MAC address for VM NIC (use libvirt range: `52:54:00:XX:XX:XX` to avoid conflicts)
- `ipv4_address`: Static IP address for VM
- `ipv4_netmask`: Network mask
- `ipv4_gateway`: Default gateway
- `name_server1`, `name_server2`: DNS servers

**Authentication and Subscription:**
Credentials and subscription details are defined per-VM using Ansible vault variables:
- `root_enc_pass`: Encrypted root password (reference vault variable)
- `grub_enc_pass`: Encrypted GRUB bootloader password (optional)
- `username`, `user_enc_pass`, `ssh_pub_key`: Provisioner user credentials (reference vault variables)
- `user_sudoer_policy`: Sudoer policy for provisioner user
- `redhat.org`, `redhat.activation_key`: Red Hat subscription details

Define vault variables in `inventory/group_vars/infra_servers.yml` or use Ansible Vault for sensitive data.

**Filesystem Layout:**
The `fs` section defines compliance-focused LVM partitioning with separate volumes for critical system directories. Setting `lv_var_mb: 1` allocates all remaining space to `/var`.

**Disk Bus Types:**
- `virtio`: Best for general purpose, uses virtio-blk
- `scsi`: virtio-scsi with queue matching vCPU count, IO threads enabled

**Volume Modes:**
- `filesystem`: Uses raw files in `nvme_pool_fs` directory-based storage pool (stored in filesystem pool)
- `block`: Direct LVM volume access from `nvme_pool_block` logical storage pool

**Storage Pool Selection:**
The appropriate storage pool is automatically created during `kvm_host_configure.yml` based on the `volume_mode` values defined in VM disks. Both pools can coexist if VMs use both modes.

## Project Structure

```
.
├── README.md                            # This file
├── CLAUDE.md                            # Project documentation for Claude AI
├── ansible.cfg                          # Ansible configuration
├── requirements.yml                     # Ansible collection requirements
├── requirements.txt                     # Python package requirements
├── inventory/
│   ├── hosts.yml                        # Inventory definition
│   ├── group_vars/
│   │   └── infra_servers.yml            # Group variables
│   └── host_vars/
│       ├── infra1.yml                   # Host-specific variables
│       ├── infra2.yml
│       └── infra3.yml
├── playbooks/
│   ├── bare_metal_deploy_prep.yml       # Phase 1a: Prepare virtual media
│   ├── bare_metal_deploy_install.yml    # Phase 1b: Boot and install OS
│   ├── kvm_host_configure.yml           # Phase 2: Configure RAID/libvirt/ISO
│   └── deploy_vm.yml                    # Phase 3: Deploy VMs with kickstart
├── tasks/
│   ├── setup_raid.yml                   # RAID 10 configuration
│   ├── setup_libvirt.yml                # Libvirt infrastructure
│   ├── distribute_iso.yml               # RHEL ISO distribution
│   ├── vm_kickstart_prep.yml            # VM kickstart generation
│   └── vm_deploy_task.yml               # Individual VM deployment
├── vars/
│   └── vm_vars.yml                      # VM definitions with network config
└── template/
    ├── ks.cfg.j2                        # Kickstart template (bare metal)
    ├── vm_ks.cfg.j2                     # Kickstart template (VMs)
    ├── vm_definition.xml.j2             # Libvirt VM XML (with install media)
    └── vm_definition_clean.xml.j2       # Libvirt VM XML (post-install)
```

## Security Considerations

⚠️ **IMPORTANT**: This repository contains placeholder credentials that **MUST** be replaced before production use.

**See [SECURITY.md](SECURITY.md) for comprehensive security guidelines including:**
- Ansible Vault usage and best practices
- Gitleaks configuration and secret detection
- Password hash generation
- SSH key management
- Incident response procedures

### Quick Security Checklist

Before deploying to production:

- [ ] Replace `idrac_password` with vaulted credential
- [ ] Generate real password hashes (replace `$YourSaltHere$YourHashHere`)
- [ ] Verify Red Hat activation key is vaulted (if real)
- [ ] Run `gitleaks detect` to check for credential leaks
- [ ] Use strong, unique passwords for all accounts
- [ ] Restrict iDRAC credentials to least privilege
- [ ] Configure SSH key-based authentication
- [ ] Review `.gitleaks.toml` allowlist configuration

### Quick Start: Securing Credentials

```bash
# Install gitleaks for secret detection
brew install gitleaks  # or download from GitHub releases

# Scan repository for leaked secrets
gitleaks detect --config .gitleaks.toml --verbose

# Encrypt iDRAC password with Ansible Vault
ansible-vault encrypt_string 'your-secret-password' --name 'idrac_password'

# Generate secure password hash for kickstart
python3 -c 'import crypt; print(crypt.crypt("YourPassword", crypt.mksalt(crypt.METHOD_SHA512)))'

# Run playbook with vault password
ansible-playbook playbooks/bare_metal_deploy_prep.yml --ask-vault-pass
```

For detailed instructions, see [SECURITY.md](SECURITY.md).

## Troubleshooting

### Kickstart Installation Fails

**Check kickstart syntax:**
```bash
# Generate kickstart locally
ansible-playbook playbooks/bare_metal_deploy_prep.yml --tags never

# Validate generated kickstart
ksvalidator /tmp/kickstart/ks-infra1.cfg
```

**View installation logs:**
- iDRAC virtual console shows installation progress
- Post-install logs: `/root/install.post.log` and `/root/install.postnochroot.log`
- Dell BOSS detection log: `/tmp/bootdisk.cfg` (available during installation)

**Check detected hardware:**
```bash
# During installation (Alt+F2 for shell access)
find /dev/disk/by-id -name "*Dell_BOSS*"
cat /tmp/bootdisk.cfg   # Shows BOSS device (if found)
cat /tmp/partitions.cfg # Shows generated partition commands

# After installation, verify NVMe devices exist for RAID
ls -la /dev/disk/by-id/nvme-Dell_DC_NVMe*
```

### RAID Array Won't Create

**Check disk availability:**
```bash
# On target host - verify NVMe devices exist
ls -la /dev/disk/by-id/nvme-*

# Check for Dell DC NVMe specifically (auto-detected)
ls -la /dev/disk/by-id/nvme-Dell_DC_NVMe*

# Verify disk paths
lsblk -o NAME,SIZE,MODEL,SERIAL
```

**Check disk detection and RAID setup:**
```bash
# Run with verbose output to see detection results
ansible-playbook playbooks/kvm_host_configure.yml -v

# The playbook will show:
# - "Disk source: Auto-detected Dell DC NVMe" or "Configured from host_vars"
# - Device count and list
# - Assertion results (minimum 4 disks required)
# - Storage requirements: "Filesystem volume_mode required" and "Block volume_mode required"
```

**If auto-detection failed:**
- Auto-detection only sets `host.additional_disks` if the variable is not already defined
- If no Dell DC NVMe devices found, playbook will fail at assertion unless `host.additional_disks` is defined in host_vars
- Manually configure `host.additional_disks` in host_vars with correct disk-by-id paths
- Ensure paths don't include partition numbers or `_1` suffix
- Re-run: `ansible-playbook playbooks/kvm_host_configure.yml`

**Check storage pool creation:**
```bash
# Verify partitions were created
parted -s /dev/md0 print

# Verify LVM infrastructure
pvdisplay
vgdisplay
lvdisplay

# Verify libvirt pools
virsh pool-list --all
virsh pool-info nvme_pool_fs     # If filesystem mode used
virsh pool-info nvme_pool_block  # If block mode used
```

**Force recreation:**
```bash
ansible-playbook playbooks/kvm_host_configure.yml -e force_raid_recreate=true
```

### Libvirt Bridge Not Created

**Check interface detection:**
```bash
# View active interfaces
ip -o link show | grep 'state UP'

# Manually verify second NIC
nmcli device status
```

**Set interface manually:**
```yaml
# inventory/group_vars/infra_servers.yml
libvirt_physical_interface: "eno2"  # Override auto-detection
```

### VM Deployment Fails

**Check libvirt network:**
```bash
virsh net-list --all
virsh net-info libvirt_net1
```

**Check storage pools:**
```bash
virsh pool-list --all
virsh pool-info nvme_pool_fs
virsh pool-info nvme_pool_block
```

**Check RHEL ISO is available:**
```bash
ssh infra1 "ls -lh /mnt/md0/libvirt/filesystem/iso/"
ssh infra1 "file /mnt/md0/libvirt/filesystem/iso/rhel-9.4-x86_64-dvd.iso"
```

**Validate XML template:**
```bash
# Generate XML locally
ansible localhost -m template \
  -a "src=template/vm_definition.xml.j2 dest=/tmp/test.xml" \
  -e vmname=test -e vcpu=2 -e memory=4096 -e disks=[]

# Validate with virsh
virsh define /tmp/test.xml --validate
```

### VM Installation Hangs or Fails

**Monitor installation progress:**
```bash
# Connect to VM console
ssh infra1 "virsh console idm1.domain.test"

# Check VM status
ssh infra1 "virsh list --all"

# View VM boot log
ssh infra1 "virsh dumpxml idm1.domain.test | grep -A 5 boot"
```

**Check kickstart artifacts:**
```bash
# Verify kickstart files exist
ssh infra1 "ls -lh /mnt/md0/libvirt/filesystem/kickstart/"

# Verify USB image contents
ssh infra1 "mdir -i /mnt/md0/libvirt/filesystem/kickstart/idm1.domain.test-ks.img"

# Check kickstart config syntax
ssh infra1 "cat /mnt/md0/libvirt/filesystem/kickstart/idm1.domain.test-ks.cfg"
```

**Common issues:**
- **SSH timeout**: Installation may take longer than 60 minutes on slow systems
  - Check VM console for progress: `virsh console <vmname>`
  - Verify network connectivity from VM
  - Check firewall rules on hypervisor
- **Kickstart not found**: USB OEMDRV image may not be properly attached
  - Verify USB controller in XML: `virsh dumpxml <vmname> | grep -A 3 usb`
  - Check USB disk device: `virsh dumpxml <vmname> | grep -A 5 'bus.*usb'`
- **Boot from HDD instead of CD-ROM**: Boot order may be incorrect
  - Check boot order: `virsh dumpxml <vmname> | grep boot`
  - Should show `<boot dev='cdrom'/>` before `<boot dev='hd'/>`
- **Network configuration fails**: MAC address conflicts or incorrect network settings
  - Verify unique MAC addresses in `vars/vm_vars.yml`
  - Check libvirt network: `virsh net-dumpxml libvirt_net1`
  - Verify bridge configuration: `ip addr show br1`

## Advanced Usage

### Understanding Disk Detection Workflow

**Kickstart Phase (OS Installation):**
1. `%pre` script searches for Dell BOSS device in `/dev`
2. If BOSS found: uses for `/boot`, `/boot/efi`, root LVM
3. If no BOSS: uses `host.boot_disk` from host_vars
4. Detection result logged to `/tmp/bootdisk.cfg`
5. Dell DC NVMe devices **not detected** during kickstart

**Post-Install Phase (RAID Configuration):**
1. `kvm_host_configure.yml` searches for Dell DC NVMe devices using `/dev/disk/by-id`
2. If Dell DC NVMe found and `host.additional_disks` not defined: sets `host.additional_disks` from auto-detection
3. If no Dell DC NVMe or `host.additional_disks` already defined: uses `host.additional_disks` from host_vars
4. Verifies minimum 4 disks available (fails fast if insufficient)
5. `setup_raid.yml` creates mdadm RAID 10 array using `host.additional_disks` paths
6. Loads VM definitions from `vars/vm_vars.yml` to detect volume_mode requirements
7. Partitions RAID array with GPT partition table (1TB per pool type)
8. Creates LVM infrastructure:
   - For filesystem mode: PV → VG (`vg_nvme_fs`) → LV → XFS → mount → dir pool
   - For block mode: PV → VG (`vg_nvme_block`) → logical pool
9. Configures libvirt storage pools for each mode in use

**Key Points:**
- **Dell BOSS detection** is fully automatic during kickstart - used for OS installation
- **Dell DC NVMe detection** is fully automatic during RAID setup - used for VM storage
- Both have fallback to host_vars if auto-detection finds no Dell devices
- `host.additional_disks` only needed if you don't have Dell DC NVMe devices
- Auto-detection prefers Dell-branded devices for consistent identification

### Custom Disk Layouts

Modify LVM sizing in `inventory/host_vars/*.yml`:

```yaml
host:
  lv_root_mb: 40960      # 40 GB root
  lv_var_mb: 102400      # 100 GB var (for container images)
```

### Multiple Libvirt Networks

Add additional networks by incrementing name:

```yaml
# inventory/group_vars/infra_servers.yml
libvirt_network_name: "libvirt_net2"
libvirt_bridge_name: "br2"
```

Update `tasks/setup_libvirt.yml` to detect different NIC.

### Parallel Deployment

Deploy all phases in parallel across hosts:

```bash
# Use Ansible forks
ansible-playbook playbooks/kvm_host_configure.yml -f 10
```

## Quick Reference: Disk Detection and Usage

| Device Type | Detection Phase | Detection Method | Usage Phase | Purpose |
|-------------|----------------|------------------|-------------|---------|
| Dell BOSS | Kickstart %pre | Auto-detect `/dev/*Dell_BOSS*` | Kickstart install | OS boot disk (`/boot`, `/boot/efi`, root LVM) |
| Dell DC NVMe | KVM host configure playbook | Auto-detect `/dev/disk/by-id/*Dell_DC_NVMe*` | RAID configuration | mdadm RAID 10 array for VM storage |
| Configured Boot Disk | N/A | `host.boot_disk` in host_vars | Kickstart install (fallback) | Used if no BOSS device detected |
| Configured NVMe Disks | N/A | `host.additional_disks` in host_vars | RAID configuration (fallback) | Used if no Dell DC NVMe detected or as override |

**Important Notes:**
- Dell BOSS detection is **automatic** during kickstart (fallback to host_vars if not found)
- Dell DC NVMe detection is **automatic** in `kvm_host_configure.yml` before RAID setup (fallback to host_vars if not found)
- Auto-detection only populates `host.additional_disks` if the variable is not already defined in host_vars
- Both auto-detections work without manual configuration on Dell hardware
- `host.boot_disk` and `host.additional_disks` only needed for non-Dell hardware or as overrides
- Playbook fails fast with clear error if fewer than 4 disks available for RAID 10

## References

- [Red Hat COP Automation Good Practices](https://redhat-cop.github.io/automation-good-practices/)
- [Dell OpenManage Ansible Modules](https://github.com/dell/dellemc-openmanage-ansible-modules)
- [Kickstart Documentation](https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/9/html/performing_an_advanced_rhel_9_installation/kickstart-commands-and-options-reference_installing-rhel-as-an-experienced-user)
- [libvirt Documentation](https://libvirt.org/docs.html)

## Contributing

See `CLAUDE.md` for code standards and project conventions.

## License

Internal infrastructure automation. Modify as needed for your environment.
