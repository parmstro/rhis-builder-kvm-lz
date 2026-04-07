mini_rhis_installer role

Purpose

- Apply small runtime hotfixes into the running provisioner container used by MiniRHIS (formerly rhis_installer.sh).

Usage

- This role is designed to be invoked from a local playbook that runs on the installer host (localhost).
- Example playbook (container/roles/mini_rhis_installer/run.yml):

  - hosts: localhost
    connection: local
    gather_facts: no
    roles:
    - role: mini_rhis_installer
        vars:
          rhis_container_name: rhis-provisioner
          demo_admin_password: bj8H7ndC7$

Notes

- The role uses `podman exec` to run small Python patchers inside the container. Ensure `podman` is available on the installer host and the target container is running.
- The default demo password is intentionally set for offline/demo usage; change it in production.
