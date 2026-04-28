# Security Guidelines

## Secrets Management

This project uses **Ansible Vault** for encrypting sensitive data and **Gitleaks** for detecting credential leaks.

### Current Security Status

⚠️ **WARNING**: This repository currently contains placeholder credentials that must be replaced before production use:

1. **iDRAC Password** (`inventory/hosts.yml`) - Currently plaintext, must be vaulted
2. **Password Hashes** (`inventory/host_vars/*.yml`) - Placeholder hashes must be replaced with real values
3. **Red Hat Activation Key** - Verify if this is a real key and vault if needed

### Using Ansible Vault

#### Encrypting Individual Values (Recommended)

Encrypt sensitive values inline while keeping the rest of the file readable:

```bash
# Encrypt a password
ansible-vault encrypt_string 'your-secret-password' --name 'idrac_password'

# Encrypt an activation key
ansible-vault encrypt_string 'rhel9-kvm-hosts' --name 'activation_key'
```

Copy the output (including the `!vault |` header) into your YAML files:

```yaml
idrac_password: !vault |
  $ANSIBLE_VAULT;1.1;AES256
  66386439653765336...
```

#### Encrypting Entire Files

For files containing only secrets:

```bash
# Create a vaulted variables file
ansible-vault create group_vars/all/vault.yml

# Edit an existing vaulted file
ansible-vault edit group_vars/all/vault.yml

# Encrypt an existing file
ansible-vault encrypt inventory/hosts.yml
```

#### Running Playbooks with Vaulted Data

```bash
# Prompt for vault password
ansible-playbook playbooks/deploy_vm.yml --ask-vault-pass

# Use a password file
ansible-playbook playbooks/deploy_vm.yml --vault-password-file ~/.vault_pass

# Use multiple vault IDs
ansible-playbook playbooks/deploy_vm.yml --vault-id dev@prompt --vault-id prod@~/.vault_pass_prod
```

### Generating Secure Password Hashes

Replace placeholder password hashes in `inventory/host_vars/*.yml`:

```bash
# Generate SHA-512 password hash for root user
python3 -c 'import crypt; print(crypt.crypt("YourSecurePassword", crypt.mksalt(crypt.METHOD_SHA512)))'
```

The output should replace values like:
```yaml
root_enc_pass: "$6$rounds=656000$YourSaltHere$YourHashHere"
```

### Using Gitleaks for Secret Detection

#### Installation

```bash
# Using Homebrew (macOS/Linux)
brew install gitleaks

# Using Go
go install github.com/gitleaks/gitleaks/v8@latest

# Download binary from GitHub
wget https://github.com/gitleaks/gitleaks/releases/download/v8.18.2/gitleaks_8.18.2_linux_x64.tar.gz
tar -xzf gitleaks_8.18.2_linux_x64.tar.gz
sudo mv gitleaks /usr/local/bin/
```

#### Running Gitleaks

```bash
# Scan uncommitted changes
gitleaks detect --config .gitleaks.toml --no-git --verbose

# Scan entire git history
gitleaks detect --config .gitleaks.toml --verbose

# Scan specific files
gitleaks detect --config .gitleaks.toml --no-git -f inventory/hosts.yml
```

#### Pre-commit Hook (Recommended)

Add to `.git/hooks/pre-commit`:

```bash
#!/bin/bash
gitleaks protect --config .gitleaks.toml --staged --verbose
if [ $? -eq 1 ]; then
  echo "Warning: Gitleaks detected secrets!"
  exit 1
fi
```

Make it executable:
```bash
chmod +x .git/hooks/pre-commit
```

### Gitleaks Configuration

The `.gitleaks.toml` configuration uses **rule-specific allowlisting**:

- **Detects**: Plaintext passwords, API keys, SSH private keys, AWS/GCP credentials
- **Allows**: Encrypted password hashes (`$6$rounds=...`), Ansible variable references (`{{ var }}`), placeholder values (`YourPasswordHere`)
- **Path exclusions**: Example files, test files, documentation

#### What Gets Detected

✅ **WILL BE DETECTED** (these should be vaulted):
- `idrac_password: "funkychunkymonkey"`
- `api_key: "sk-1234567890abcdef"`
- `activation_key: "rhel9-real-key-12345"`

✅ **WILL BE ALLOWED** (safe to commit):
- `root_enc_pass: "$6$rounds=656000$..."`  (encrypted hash)
- `password: "{{ vault_password }}"`  (variable reference)
- `# Example: password: "changeme"`  (documentation placeholder)

### Best Practices

1. **Never commit plaintext secrets** to version control
2. **Use Ansible Vault** for all sensitive data (passwords, keys, tokens)
3. **Store vault passwords securely** (use password manager, not in repository)
4. **Rotate credentials regularly**, especially after team changes
5. **Run gitleaks** before every commit to catch accidental leaks
6. **Use different credentials** for dev/staging/production environments
7. **Generate strong passwords** using a password manager
8. **Document which values need to be replaced** for new deployments

### Incident Response

If you accidentally commit a secret:

1. **Immediately rotate the credential** (change password, revoke key)
2. **Remove from git history**:
   ```bash
   # Using git-filter-repo (recommended)
   git filter-repo --path inventory/hosts.yml --invert-paths

   # Or using BFG Repo-Cleaner
   bfg --replace-text passwords.txt
   ```
3. **Force push** (coordinate with team):
   ```bash
   git push --force-with-lease
   ```
4. **Notify security team** if the secret had access to production systems

### Additional Resources

- [Ansible Vault Documentation](https://docs.ansible.com/ansible/latest/vault_guide/index.html)
- [Gitleaks Documentation](https://github.com/gitleaks/gitleaks)
- [Red Hat Automation Good Practices](https://redhat-cop.github.io/automation-good-practices/)
- [OWASP Secrets Management Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Secrets_Management_Cheat_Sheet.html)
