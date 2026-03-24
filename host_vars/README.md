# host_vars/

This directory is bind-mounted into the `rhis-provisioner` container at  
`/rhis/vars/host_vars/`.

## Setup

Copy each `*.SAMPLE` file to its actual name (removing `.SAMPLE`) and fill in  
real values before running any rhis-builder playbook:

```text
host_vars/satellite.yml   — Satellite VM connection + org/location vars
host_vars/satellite_content_profile.yml — persistent Satellite content/lifecycle/CV/AK profile
host_vars/aap.yml         — AAP admin credentials
host_vars/idm.yml         — IdM realm/domain overrides
host_vars/installer.yml   — Controller/installer host SSH settings
```

## Secrets

Sensitive values (passwords, tokens) **must not** be stored in plain text.  
Reference them from your Ansible vault instead:

```yaml
ansible_password: "{{ global_admin_password | default('') }}"
```

Store the vault at `~/.ansible/conf/env.yml` (encrypted with `ansible-vault`).  
See `CHECKLIST.md` in the repo root for the full secret checklist.

## Runtime behavior note

`rhis_install.sh` regenerates `host_vars/*.yml` during config-as-code startup.
Treat these files as generated runtime artifacts; if you need persistent changes,
set values in the vaulted env source (`~/.ansible/conf/env.yml`) instead of editing
generated files directly.

Current generated Satellite host_vars defaults include:

- `satellite_pre_use_idm` (default-safe behavior is `false` unless explicitly enabled)
- `ipa_client_dns_servers`
- `ipa_server_fqdn`
- fixed Satellite/Foreman/Hammer username: `admin`
- Satellite password sourced from vaulted `sat_admin_pass` / `global_admin_password`

The supplemental file `satellite_content_profile.yml` is intended for persistent
Satellite content configuration that should survive generator reruns, such as:

- lifecycle environments
- content views
- activation keys
- repository intent/profile settings

RHIS dependency order remains:

- Build/create: `IdM -> Satellite -> AAP`
- Config-as-code: `IdM -> Satellite -> AAP`
