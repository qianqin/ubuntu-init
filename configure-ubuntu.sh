#!/bin/bash
set -euo pipefail

# Ubuntu Auto-Configuration Script
# Configures sudo nopasswd for sudo group and sets up unattended-upgrades

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Check if running as root or with sudo
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Error: This script must be run as root or with sudo${NC}"
    exit 1
fi

# Detect the actual user (who invoked sudo)
ACTUAL_USER="${SUDO_USER:-${USER:-}}"
if [ -z "$ACTUAL_USER" ] || [ "$ACTUAL_USER" = "root" ]; then
    # Try to get the user from who am i or last command
    ACTUAL_USER=$(who am i | awk '{print $1}' || echo "")
fi

echo -e "${GREEN}Starting Ubuntu auto-configuration...${NC}"

# Function to backup file if it exists
backup_file() {
    local file="$1"
    if [ -f "$file" ]; then
        cp "$file" "${file}.bak.$(date +%Y%m%d_%H%M%S)"
        echo -e "${YELLOW}Backed up $file${NC}"
    fi
}

# Configure sudo nopasswd for sudo group
echo -e "${GREEN}Configuring sudo nopasswd for sudo group...${NC}"
MAIN_SUDOERS="/etc/sudoers"
SUDOERS_DROPIN="/etc/sudoers.d/99-sudo-group-nopasswd"
SUDOERS_LINE="%sudo ALL=(ALL:ALL) NOPASSWD: ALL"

# Function to validate sudoers file
validate_sudoers() {
    local file="$1"
    if command -v visudo >/dev/null 2>&1; then
        visudo -cf "$file" >/dev/null 2>&1
    else
        # Fallback: basic syntax check
        grep -q "^%sudo" "$file" 2>/dev/null
    fi
}

# Check if NOPASSWD is already configured in main sudoers file
if grep -qE "^%sudo.*NOPASSWD.*ALL" "$MAIN_SUDOERS" 2>/dev/null; then
    echo -e "${YELLOW}✓ Sudo nopasswd configuration already exists in $MAIN_SUDOERS${NC}"
# Check if sudo group line exists in main sudoers (without NOPASSWD)
elif grep -qE "^%sudo[[:space:]]+ALL=\(ALL:ALL\)[[:space:]]+ALL" "$MAIN_SUDOERS" 2>/dev/null; then
    # Modify the existing line in main sudoers file
    backup_file "$MAIN_SUDOERS"
    
    # Replace the sudo group line to add NOPASSWD
    sed -i 's/^%sudo[[:space:]]*ALL=(ALL:ALL)[[:space:]]*ALL/%sudo ALL=(ALL:ALL) NOPASSWD: ALL/' "$MAIN_SUDOERS"
    
    # Validate the change
    if validate_sudoers "$MAIN_SUDOERS"; then
        echo -e "${GREEN}✓ Modified sudo group line in $MAIN_SUDOERS to enable nopasswd${NC}"
    else
        echo -e "${RED}Error: sudoers file validation failed. Restoring backup...${NC}"
        # Find the most recent backup and restore it
        LATEST_BACKUP=$(ls -t "${MAIN_SUDOERS}.bak."* 2>/dev/null | head -n1)
        if [ -n "$LATEST_BACKUP" ] && [ -f "$LATEST_BACKUP" ]; then
            mv "$LATEST_BACKUP" "$MAIN_SUDOERS"
            echo -e "${YELLOW}Backup restored. Please check sudoers file manually.${NC}"
        fi
        exit 1
    fi
# Check if already configured in drop-in file
elif [ -f "$SUDOERS_DROPIN" ] && grep -qE "^%sudo.*NOPASSWD.*ALL" "$SUDOERS_DROPIN" 2>/dev/null; then
    echo -e "${YELLOW}✓ Sudo nopasswd configuration already exists in $SUDOERS_DROPIN${NC}"
else
    # No sudo group line found - create drop-in file
    if [ -f "$SUDOERS_DROPIN" ]; then
        backup_file "$SUDOERS_DROPIN"
        # Remove any existing sudo group line
        sed -i '/^%sudo.*ALL=/d' "$SUDOERS_DROPIN"
    else
        touch "$SUDOERS_DROPIN"
    fi
    
    # Add our line to drop-in file
    echo "$SUDOERS_LINE" >> "$SUDOERS_DROPIN"
    chmod 0440 "$SUDOERS_DROPIN"
    
    # Validate the drop-in file
    if validate_sudoers "$SUDOERS_DROPIN"; then
        echo -e "${GREEN}✓ Created sudo nopasswd configuration in $SUDOERS_DROPIN${NC}"
    else
        echo -e "${RED}Error: sudoers drop-in file validation failed. Removing...${NC}"
        rm -f "$SUDOERS_DROPIN"
        exit 1
    fi
fi

# Install unattended-upgrades if not present
if ! command -v unattended-upgrade &> /dev/null; then
    echo -e "${GREEN}Installing unattended-upgrades...${NC}"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq unattended-upgrades
    echo -e "${GREEN}✓ Installed unattended-upgrades${NC}"
else
    echo -e "${YELLOW}✓ unattended-upgrades already installed${NC}"
fi

# Function to set config value in apt config file
# Note: Caller should backup the file before calling this function
set_apt_config() {
    local file="$1"
    local key="$2"
    local value="$3"
    local comment="${4:-}"
    
    # Create file if it doesn't exist
    if [ ! -f "$file" ]; then
        touch "$file"
    fi
    
    # Remove existing line (including commented ones that match)
    sed -i "/^[[:space:]]*\(//[[:space:]]*\)\?${key}/d" "$file"
    
    # Add the new setting
    if [ -n "$comment" ]; then
        echo "// ${comment}" >> "$file"
    fi
    echo "${key} \"${value}\";" >> "$file"
}

# Function to ensure Origins-Pattern includes updates
ensure_origins_pattern() {
    local file="$1"
    
    # Create basic file structure if it doesn't exist
    if [ ! -f "$file" ]; then
        cat > "$file" << 'EOFORIGINS'
Unattended-Upgrade::Origins-Pattern {
    "${distro_id}:${distro_codename}";
    "${distro_id}:${distro_codename}-security";
    "${distro_id}:${distro_codename}-updates";
};
EOFORIGINS
        return
    fi
    
    # Note: Backup should be done by caller before calling this function
    
    # Check if updates is already in Origins-Pattern (check for the pattern, not literal variable)
    if grep -q '\${distro_id}:\${distro_codename}-updates' "$file"; then
        return  # Already configured
    fi
    
    # Check if Origins-Pattern block exists
    if grep -q "Unattended-Upgrade::Origins-Pattern" "$file"; then
        # Find the security line and add updates after it
        # Use a temporary file for safer editing
        local temp_file=$(mktemp)
        local in_block=false
        local added=false
        
        while IFS= read -r line; do
            if echo "$line" | grep -q "Unattended-Upgrade::Origins-Pattern"; then
                in_block=true
            fi
            
            if [ "$in_block" = true ] && [ "$added" = false ]; then
                # Check if this line contains the security pattern
                if echo "$line" | grep -q '\${distro_codename}-security'; then
                    echo "$line" >> "$temp_file"
                    echo '    "${distro_id}:${distro_codename}-updates";' >> "$temp_file"
                    added=true
                    continue
                fi
                
                # Check if we hit the closing brace before finding security
                if echo "$line" | grep -q "^};"; then
                    if [ "$added" = false ]; then
                        # Add updates before closing brace
                        echo '    "${distro_id}:${distro_codename}-updates";' >> "$temp_file"
                        added=true
                    fi
                    in_block=false
                fi
            fi
            
            echo "$line" >> "$temp_file"
        done < "$file"
        
        mv "$temp_file" "$file"
    else
        # Add Origins-Pattern block at the end
        echo "" >> "$file"
        echo "Unattended-Upgrade::Origins-Pattern {" >> "$file"
        echo '    "${distro_id}:${distro_codename}";' >> "$file"
        echo '    "${distro_id}:${distro_codename}-security";' >> "$file"
        echo '    "${distro_id}:${distro_codename}-updates";' >> "$file"
        echo "};" >> "$file"
    fi
}

# Configure unattended-upgrades
echo -e "${GREEN}Configuring unattended-upgrades...${NC}"
UNATTENDED_FILE="/etc/apt/apt.conf.d/50unattended-upgrades"

# Backup once before making any changes
if [ -f "$UNATTENDED_FILE" ]; then
    backup_file "$UNATTENDED_FILE"
fi

# Ensure Origins-Pattern includes updates
ensure_origins_pattern "$UNATTENDED_FILE"

# Set specific configuration values (only what we need to change)
set_apt_config "$UNATTENDED_FILE" "Unattended-Upgrade::Remove-Unused-Dependencies" "true" "Do automatic removal of new unused dependencies after the upgrade"
set_apt_config "$UNATTENDED_FILE" "Unattended-Upgrade::Automatic-Reboot" "true" "Automatically reboot if reboot-required exists after upgrade"
set_apt_config "$UNATTENDED_FILE" "Unattended-Upgrade::Automatic-Reboot-WithUsers" "true" "Automatically reboot even if users are logged in"
set_apt_config "$UNATTENDED_FILE" "Unattended-Upgrade::Automatic-Reboot-Time" "03:00" "Reboot at specific time instead of immediately"
set_apt_config "$UNATTENDED_FILE" "Unattended-Upgrade::Remove-Unused-Kernel-Packages" "true" "Remove unused kernel packages"

echo -e "${GREEN}✓ Configured unattended-upgrades${NC}"

# Configure automatic upgrades
echo -e "${GREEN}Configuring automatic upgrades...${NC}"
AUTO_UPGRADES_FILE="/etc/apt/apt.conf.d/20auto-upgrades"

# Backup once before making any changes
if [ -f "$AUTO_UPGRADES_FILE" ]; then
    backup_file "$AUTO_UPGRADES_FILE"
fi

# Set specific configuration values (only what we need)
set_apt_config "$AUTO_UPGRADES_FILE" "APT::Periodic::Update-Package-Lists" "1" "Update package lists daily"
set_apt_config "$AUTO_UPGRADES_FILE" "APT::Periodic::Download-Upgradeable-Packages" "1" "Download upgradeable packages daily"
set_apt_config "$AUTO_UPGRADES_FILE" "APT::Periodic::AutocleanInterval" "7" "Clean package cache every 7 days"
set_apt_config "$AUTO_UPGRADES_FILE" "APT::Periodic::Unattended-Upgrade" "1" "Run unattended-upgrade daily"

echo -e "${GREEN}✓ Configured automatic upgrades${NC}"

# Enable and start unattended-upgrades service
echo -e "${GREEN}Enabling unattended-upgrades service...${NC}"
systemctl enable unattended-upgrades
systemctl restart unattended-upgrades
echo -e "${GREEN}✓ Enabled and started unattended-upgrades service${NC}"

# Run initial cleanup
echo -e "${GREEN}Running initial cleanup...${NC}"
apt-get autoremove -y -qq
apt-get autoclean -qq
echo -e "${GREEN}✓ Completed initial cleanup${NC}"

# SSH Key Management
echo -e "${GREEN}Configuring SSH keys...${NC}"
if [ -n "$ACTUAL_USER" ] && [ "$ACTUAL_USER" != "root" ]; then
    USER_HOME=$(getent passwd "$ACTUAL_USER" | cut -d: -f6)
    SSH_DIR="$USER_HOME/.ssh"
    AUTHORIZED_KEYS="$SSH_DIR/authorized_keys"
    
    # Create .ssh directory if it doesn't exist
    if [ ! -d "$SSH_DIR" ]; then
        mkdir -p "$SSH_DIR"
        chown "$ACTUAL_USER:$ACTUAL_USER" "$SSH_DIR"
        chmod 700 "$SSH_DIR"
    fi
    
    # Check if authorized_keys exists and is empty or doesn't exist
    if [ ! -f "$AUTHORIZED_KEYS" ] || [ ! -s "$AUTHORIZED_KEYS" ]; then
        echo -e "${YELLOW}No SSH authorized keys found for user $ACTUAL_USER${NC}"
        echo -e "${BLUE}Please paste your public SSH key (will be added to $AUTHORIZED_KEYS):${NC}"
        
        # Read from terminal (not stdin, which is the piped script)
        # Use /dev/tty to read from the actual terminal even when script is piped
        PUB_KEY=""
        if [ -c /dev/tty ]; then
            read -r PUB_KEY < /dev/tty 2>/dev/null || true
        fi
        
        # If still empty and we have a TTY, try reading normally
        if [ -z "$PUB_KEY" ] && [ -t 0 ]; then
            read -r PUB_KEY || true
        fi
        
        if [ -n "$PUB_KEY" ]; then
            # Validate it looks like an SSH public key (basic check)
            if echo "$PUB_KEY" | grep -qE "^(ssh-rsa|ssh-ed25519|ecdsa-sha2|ssh-dss) "; then
                echo "$PUB_KEY" >> "$AUTHORIZED_KEYS"
                chown "$ACTUAL_USER:$ACTUAL_USER" "$AUTHORIZED_KEYS"
                chmod 600 "$AUTHORIZED_KEYS"
                echo -e "${GREEN}✓ Added SSH public key for user $ACTUAL_USER${NC}"
            else
                echo -e "${RED}Warning: The input doesn't appear to be a valid SSH public key. Skipping.${NC}"
            fi
        else
            echo -e "${YELLOW}No key provided. Skipping SSH key configuration.${NC}"
        fi
    else
        echo -e "${YELLOW}✓ SSH authorized keys already exist for user $ACTUAL_USER${NC}"
    fi
    
    # Check if authorized_keys has at least one key, then disable password auth
    if [ -f "$AUTHORIZED_KEYS" ] && [ -s "$AUTHORIZED_KEYS" ]; then
        # Count non-empty, non-comment lines
        KEY_COUNT=$(grep -vE "^\s*#" "$AUTHORIZED_KEYS" | grep -vE "^\s*$" | wc -l)
        
        if [ "$KEY_COUNT" -gt 0 ]; then
            echo -e "${GREEN}Found $KEY_COUNT SSH key(s). Disabling password authentication for SSH...${NC}"
            SSHD_CONFIG="/etc/ssh/sshd_config"
            
            # Backup SSH config
            backup_file "$SSHD_CONFIG"
            
            # Check if PasswordAuthentication is already configured
            if grep -qE "^PasswordAuthentication" "$SSHD_CONFIG"; then
                # Update existing setting
                sed -i 's/^PasswordAuthentication.*/PasswordAuthentication no/' "$SSHD_CONFIG"
            else
                # Add new setting at the end
                echo "" >> "$SSHD_CONFIG"
                echo "# Disable password authentication (configured by ubuntu-init)" >> "$SSHD_CONFIG"
                echo "PasswordAuthentication no" >> "$SSHD_CONFIG"
            fi
            
            # Also ensure PubkeyAuthentication is enabled (should be default, but be explicit)
            if ! grep -qE "^PubkeyAuthentication" "$SSHD_CONFIG"; then
                echo "PubkeyAuthentication yes" >> "$SSHD_CONFIG"
            fi
            
            # Restart SSH service
            if systemctl is-active --quiet sshd || systemctl is-active --quiet ssh; then
                systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || true
                echo -e "${GREEN}✓ Disabled password authentication for SSH and restarted SSH service${NC}"
                echo -e "${YELLOW}⚠️  Important: Make sure you can SSH in with your key before closing this session!${NC}"
            else
                echo -e "${YELLOW}⚠️  SSH service not running. Password authentication will be disabled when SSH is started.${NC}"
            fi
        fi
    fi
else
    echo -e "${YELLOW}⚠️  Could not determine actual user. Skipping SSH key configuration.${NC}"
fi

echo -e "${GREEN}✓ Ubuntu auto-configuration completed successfully!${NC}"
echo -e "${YELLOW}Note: Automatic reboots will occur at 3:00 AM when required.${NC}"

