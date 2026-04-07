# Migration to API-First (Hammer Fallback) — RHIS

This document summarizes recent changes and gives step-by-step validation instructions.

## What Changed

- Introduced `tools/hammer_api_fallback.sh`: API-first wrapper that queries Satellite API and falls back to `hammer` when the resource is missing or API unreachable.
- Created Ansible include/role in `container/roles/rhis_tools` and `rhis_tools_role` (include tasks `hammer_api_fallback.yml`) to call the wrapper from playbooks.
- Converted many `hammer` call sites in `MiniRHIS.sh` and `MiniRHIS.py` to use the wrapper (subnet create, lifecycle envs, content view attach/publish, compute resource, activation keys, etc.).
- Converted multiple Ansible tasks to use API modules (HTTP API via `ansible.builtin.uri` or `redhat.satellite` modules) and provided a `hammer` fallback via the include for missing API compatibility.
- Added sample vaulted env file: `.ansible/conf/env.yml.SAMPLE` — copy this to `~/.ansible/conf/env.yml` and encrypt with Ansible Vault to provide credentials to the wrapper.
- Created `reports/hammer_remaining.md` summarizing the remaining intentional hammer fallbacks.

## Prerequisites for Validation

- A test Satellite 2.18 instance accessible from your environment (or adjust `SAT_URL`/`SAT_IP` in `~/.ansible/conf/env.yml`).
- Ansible and required collections installed. Recommended versions:
  - ansible-core >= 2.16.14
  - ansible >= 8.x (compatible with collections used)
  - `redhat.satellite` collection (install via `ansible-galaxy collection install redhat.satellite`)
- Python 3.8+ for wrapper scripts.

## Vault Setup

Local setup required for full validation.

1. Copy sample:

   cp .ansible/conf/env.yml.SAMPLE ~/.ansible/conf/env.yml

2. Edit `~/.ansible/conf/env.yml` and set `satellite_url`/`admin_user`/`admin_pass` (or `SAT_IP`).
3. Encrypt with Ansible Vault (optional but recommended):

   ansible-vault encrypt ~/.ansible/conf/env.yml

Notes: The wrapper reads `~/.ansible/conf/env.yml` (un/vaulted) to obtain `ADMIN_USER`/`ADMIN_PASS` or `HAMMER_USERNAME`/`HAMMER_PASSWORD`.

## Validation Checks

- Shell and Python syntax checks:

  bash -n MiniRHIS.sh
  python3 -m py_compile MiniRHIS.py

- Ansible syntax checks (example for core roles):

  ansible-playbook --syntax-check container/configure_minirhis_builder.yml -i localhost,

- Linting: (ensure ansible-core version compatibility first)

  ansible-lint container/configure_minirhis_builder.yml

## Targeted Dry Run

Run this once vault credentials are present.

- Run with `--check` and `--diff` against a non-production Satellite. Example (using `container/satellite_site.yml`):

  ansible-playbook -i inventory/hosts container/satellite_site.yml --check --diff --extra-vars "@~/.ansible/conf/env.yml"

- Start with specific tags to limit scope (recommended):

  ansible-playbook -i inventory/hosts container/satellite_site.yml --tags rhis_sat_config --check --diff --extra-vars "@~/.ansible/conf/env.yml"

## Next Recommended Steps

1. Finish converting remaining `MiniRHIS.sh` raw hammer lines (if any).
2. Replace fallback `hammer_cmd` strings with module/API calls where possible (content views, repo attach, product sync).
3. Consolidate `rhis_tools` and `rhis_tools_role` into a single well-documented role with defaults and examples.
4. Expand GitHub Actions coverage to include targeted Satellite role validation, not just the top-level builder playbook.
5. Prepare a short-run validation plan to execute against a test Satellite 2.18/IdM5/AAP2.6 stack.

If you want, I can start running the targeted dry-run commands next (requires vaulted `~/.ansible/conf/env.yml`).
