# rhis_tools

Ansible role that provides a single, documented interface to run the API-first
hammer fallback wrapper used across the repository.

Usage
- Include the role's task when you want to run the API-first check with
  hammer fallback. The original include file (`tasks/hammer_api_fallback.yml`) is
  preserved and compatible with existing callers.

Interface variables (provided by caller)
- `api_path` (string): API resource path, e.g. `content_views`, `products`.
- `search_expr` (string): search expression passed to the Satellite API.
- `hammer_cmd` (string): full hammer command to run if the API lookup fails.
- `fallback_wrapper_path` (string, optional): path to the `hammer_api_fallback.sh` wrapper. Defaults to `{{ playbook_dir }}/tools/hammer_api_fallback.sh`.

Examples
- Include the wrapper directly:

  - ansible.builtin.include_tasks: "{{ playbook_dir }}/container/roles/rhis_tools/tasks/hammer_api_fallback.yml"
    vars:
      api_path: "content_views"
      search_expr: "name=\"rhel-9-for-x86_64\""
      hammer_cmd: "hammer content-view publish --name='rhel-9-for-x86_64'"

Notes
- This role consolidates the previously duplicated `rhis_tools` and
  `rhis_tools_role` helpers. Existing include paths remain valid to avoid
  mass-changes; use this role when writing new tasks.
