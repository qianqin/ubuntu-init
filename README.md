# Ubuntu Auto-Configuration

A one-liner script to configure a fresh Ubuntu installation with automatic updates, security hardening, and system maintenance settings.

## Quick Start

Copy and paste this command into your terminal:

```bash
curl -sSL https://raw.githubusercontent.com/qianqin/ubuntu-init/main/configure-ubuntu.sh | bash
```

**Note:** The script will prompt for your sudo password once at the beginning. After configuring passwordless sudo, all subsequent commands will run without password prompts.

## Prerequisites

- Ubuntu system (tested on Ubuntu 20.04+)
- Root or sudo access
- Internet connection

## What This Script Configures

### 1. Sudo Configuration
- Configures passwordless sudo for all users in the `sudo` group
- Modifies the existing `%sudo` line in `/etc/sudoers` to add `NOPASSWD`
- If no sudo group line exists, creates `/etc/sudoers.d/99-sudo-group-nopasswd`
- Validates sudoers syntax after changes using `visudo`
- Allows members of the sudo group to run commands without entering a password

### 2. Unattended-Upgrades
- **Installs** `unattended-upgrades` package if not already present
- **Enables** automatic installation of:
  - Security updates (`${distro_codename}-security`)
  - Regular updates (`${distro_codename}-updates`)
- **Configures** automatic cleanup:
  - Removes unused dependencies after upgrades
  - Removes old unused kernel packages
  - Runs automatic cleanup every 7 days
- **Enables** automatic reboots:
  - Reboots automatically when required (e.g., after kernel updates)
  - Reboots at 3:00 AM to minimize disruption
  - Reboots even if users are logged in

### 3. Automatic Maintenance
- Daily automatic package list updates
- Daily automatic download of upgradeable packages
- Weekly automatic cleanup of package cache
- Automatic removal of unused packages

### 4. SSH Key Management
- Checks if the current user has SSH authorized keys configured
- If no keys are found, prompts you to paste a public SSH key
- Automatically disables password authentication for SSH when keys are present
- Ensures public key authentication is enabled

## Security Note

⚠️ **Warning:** Running scripts directly from the internet can be a security risk. Before running this command, you should:

1. Review the script contents by visiting the raw URL in your browser
2. Verify the repository is from a trusted source
3. Understand what the script does (see "What This Script Configures" above)

Alternatively, you can download and review the script first:

```bash
curl -sSL https://raw.githubusercontent.com/qianqin/ubuntu-init/main/configure-ubuntu.sh -o configure-ubuntu.sh
cat configure-ubuntu.sh  # Review the script
bash configure-ubuntu.sh  # Run it after review
```

## Idempotency

This script is idempotent, meaning it can be safely run multiple times. It will:
- Skip configurations that are already in place
- Backup existing configuration files before modification
- Not duplicate configurations

## What Happens After Configuration

- The system will automatically check for updates daily
- Security and regular updates will be installed automatically
- The system will reboot automatically at 3:00 AM when kernel updates require it
- Old kernels and unused packages will be automatically removed
- Users in the sudo group can run sudo commands without entering passwords
- SSH password authentication is disabled if SSH keys are configured

## Manual Verification

After running the script, you can verify the configuration:

```bash
# Check sudo configuration (check main file first, then drop-in)
sudo grep "^%sudo" /etc/sudoers
sudo cat /etc/sudoers.d/99-sudo-group-nopasswd 2>/dev/null || echo "No drop-in file (using main sudoers)"

# Check unattended-upgrades configuration
sudo cat /etc/apt/apt.conf.d/50unattended-upgrades | grep -E "(Automatic-Reboot|Remove-Unused|Origins-Pattern)"

# Check automatic upgrades configuration
sudo cat /etc/apt/apt.conf.d/20auto-upgrades

# Check service status
sudo systemctl status unattended-upgrades

# Check SSH configuration
sudo grep -E "^PasswordAuthentication|^PubkeyAuthentication" /etc/ssh/sshd_config

# Check SSH authorized keys (replace USERNAME with your username)
cat ~/.ssh/authorized_keys
```

## License

MIT License - see [LICENSE](LICENSE) file for details.

