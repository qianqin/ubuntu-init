#!/bin/bash
# Disable any aliases that might interfere with commands
unalias sed 2>/dev/null || true
unalias grep 2>/dev/null || true
set -euo pipefail

# Ubuntu Auto-Configuration Script
# Configures sudo nopasswd for sudo group and sets up unattended-upgrades

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Detect the actual user running the script
ACTUAL_USER="${SUDO_USER:-${USER:-}}"
if [ -z "$ACTUAL_USER" ] || [ "$ACTUAL_USER" = "root" ]; then
    # Try to get the user from who am i or environment
    ACTUAL_USER=$(who am i 2>/dev/null | awk '{print $1}' || echo "${USER:-}")
fi

# If running as root directly, try to find the actual user
if [ "$EUID" -eq 0 ] && [ -z "$SUDO_USER" ]; then
    # Check if we can determine the user from login session
    ACTUAL_USER=$(logname 2>/dev/null || echo "")
    if [ -z "$ACTUAL_USER" ] || [ "$ACTUAL_USER" = "root" ]; then
        # Try last logged in user
        ACTUAL_USER=$(last -w 2>/dev/null | head -n1 | awk '{print $1}' || echo "")
    fi
fi

# Check if we need sudo access
NEED_SUDO=false
if [ "$EUID" -ne 0 ]; then
    NEED_SUDO=true
    # Test if we have sudo access (will prompt for password if needed)
    if ! sudo -n true 2>/dev/null; then
        echo -e "${YELLOW}This script requires sudo access. Please enter your password:${NC}"
        sudo -v || {
            echo -e "${RED}Error: Sudo access required${NC}"
            exit 1
        }
    fi
fi

# Function to run commands with or without sudo
run_as_root() {
    if [ "$NEED_SUDO" = true ]; then
        sudo "$@"
    else
        "$@"
    fi
}

echo -e "${GREEN}Starting Ubuntu auto-configuration...${NC}"

# Function to backup file if it exists
backup_file() {
    local file="$1"
    if run_as_root [ -f "$file" ]; then
        run_as_root cp "$file" "${file}.bak.$(date +%Y%m%d_%H%M%S)"
        echo -e "${YELLOW}Backed up $file${NC}"
    fi
}

# Configure sudo nopasswd for sudo group FIRST (so subsequent sudo commands don't need password)
echo -e "${GREEN}Configuring sudo nopasswd for sudo group...${NC}"
MAIN_SUDOERS="/etc/sudoers"
SUDOERS_DROPIN="/etc/sudoers.d/99-sudo-group-nopasswd"
SUDOERS_LINE="%sudo ALL=(ALL:ALL) NOPASSWD: ALL"

# Function to validate sudoers file
validate_sudoers() {
    local file="$1"
    if command -v visudo >/dev/null 2>&1; then
        run_as_root visudo -cf "$file" >/dev/null 2>&1
    else
        # Fallback: basic syntax check
        run_as_root grep -q "^%sudo" "$file" 2>/dev/null
    fi
}

# Check if NOPASSWD is already configured in main sudoers file
if run_as_root grep -qE "^%sudo.*NOPASSWD.*ALL" "$MAIN_SUDOERS" 2>/dev/null; then
    echo -e "${YELLOW}✓ Sudo nopasswd configuration already exists in $MAIN_SUDOERS${NC}"
# Check if sudo group line exists in main sudoers (without NOPASSWD)
elif run_as_root grep -qE "^%sudo[[:space:]]+ALL=\(ALL:ALL\)[[:space:]]+ALL" "$MAIN_SUDOERS" 2>/dev/null; then
    # Modify the existing line in main sudoers file
    run_as_root cp "$MAIN_SUDOERS" "${MAIN_SUDOERS}.bak.$(date +%Y%m%d_%H%M%S)"
    echo -e "${YELLOW}Backed up $MAIN_SUDOERS${NC}"
    
    # Replace the sudo group line to add NOPASSWD
    run_as_root sed -i 's/^%sudo[[:space:]]*ALL=(ALL:ALL)[[:space:]]*ALL/%sudo ALL=(ALL:ALL) NOPASSWD: ALL/' "$MAIN_SUDOERS"
    
    # Validate the change
    if validate_sudoers "$MAIN_SUDOERS"; then
        echo -e "${GREEN}✓ Modified sudo group line in $MAIN_SUDOERS to enable nopasswd${NC}"
        # Refresh sudo credentials so subsequent commands don't need password
        if [ "$NEED_SUDO" = true ]; then
            sudo -v
        fi
    else
        echo -e "${RED}Error: sudoers file validation failed. Restoring backup...${NC}"
        # Find the most recent backup and restore it
        LATEST_BACKUP=$(run_as_root ls -t "${MAIN_SUDOERS}.bak."* 2>/dev/null | head -n1)
        if [ -n "$LATEST_BACKUP" ] && run_as_root [ -f "$LATEST_BACKUP" ]; then
            run_as_root mv "$LATEST_BACKUP" "$MAIN_SUDOERS"
            echo -e "${YELLOW}Backup restored. Please check sudoers file manually.${NC}"
        fi
        exit 1
    fi
# Check if already configured in drop-in file
elif run_as_root [ -f "$SUDOERS_DROPIN" ] && run_as_root grep -qE "^%sudo.*NOPASSWD.*ALL" "$SUDOERS_DROPIN" 2>/dev/null; then
    echo -e "${YELLOW}✓ Sudo nopasswd configuration already exists in $SUDOERS_DROPIN${NC}"
else
    # No sudo group line found - create drop-in file
    if run_as_root [ -f "$SUDOERS_DROPIN" ]; then
        run_as_root cp "$SUDOERS_DROPIN" "${SUDOERS_DROPIN}.bak.$(date +%Y%m%d_%H%M%S)"
        echo -e "${YELLOW}Backed up $SUDOERS_DROPIN${NC}"
        # Remove any existing sudo group line
        run_as_root sed -i '/^%sudo.*ALL=/d' "$SUDOERS_DROPIN"
    else
        run_as_root touch "$SUDOERS_DROPIN"
    fi
    
    # Add our line to drop-in file
    echo "$SUDOERS_LINE" | run_as_root tee -a "$SUDOERS_DROPIN" > /dev/null
    run_as_root chmod 0440 "$SUDOERS_DROPIN"
    
    # Validate the drop-in file
    if validate_sudoers "$SUDOERS_DROPIN"; then
        echo -e "${GREEN}✓ Created sudo nopasswd configuration in $SUDOERS_DROPIN${NC}"
        # Refresh sudo credentials so subsequent commands don't need password
        if [ "$NEED_SUDO" = true ]; then
            sudo -v
        fi
    else
        echo -e "${RED}Error: sudoers drop-in file validation failed. Removing...${NC}"
        run_as_root rm -f "$SUDOERS_DROPIN"
        exit 1
    fi
fi

# Install unattended-upgrades if not present
if ! command -v unattended-upgrade &> /dev/null; then
    echo -e "${GREEN}Installing unattended-upgrades...${NC}"
    export DEBIAN_FRONTEND=noninteractive
    run_as_root apt-get update -qq
    run_as_root apt-get install -y -qq unattended-upgrades
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
    if ! run_as_root [ -f "$file" ]; then
        run_as_root touch "$file"
    fi
    
    # Create temporary file for safer editing (in user's temp directory)
    local temp_file=$(mktemp)
    
    # Remove existing lines that match the key (including commented ones)
    # Use simple string matching to avoid regex escaping issues
    while IFS= read -r line || [ -n "$line" ]; do
        # Skip lines that contain the key
        # Use parameter expansion to remove leading whitespace (more portable than sed)
        local temp_line="$line"
        # Remove leading whitespace using parameter expansion
        temp_line="${temp_line#"${temp_line%%[![:space:]]*}"}"
        # Check if it starts with // comment and remove it
        if [ "${temp_line#//}" != "$temp_line" ]; then
            # Line starts with //, remove // and any following whitespace
            temp_line="${temp_line#//}"
            temp_line="${temp_line#"${temp_line%%[![:space:]]*}"}"
        fi
        # Check if the cleaned line starts with our key
        case "$temp_line" in
            "${key}"*)
                continue
                ;;
        esac
        echo "$line" >> "$temp_file"
    done < <(run_as_root cat "$file")
    
    # Add the new setting
    if [ -n "$comment" ]; then
        echo "// ${comment}" >> "$temp_file"
    fi
    echo "${key} \"${value}\";" >> "$temp_file"
    
    # Replace original file with temp file
    run_as_root cp "$temp_file" "$file"
    rm -f "$temp_file"
}

# Function to ensure Origins-Pattern includes updates
ensure_origins_pattern() {
    local file="$1"
    
    # Create basic file structure if it doesn't exist
    if ! run_as_root [ -f "$file" ]; then
        run_as_root tee "$file" > /dev/null << 'EOFORIGINS'
Unattended-Upgrade::Origins-Pattern {
    "${distro_id}:${distro_codename}";
    "${distro_id}:${distro_codename}-security";
    "${distro_id}:${distro_codename}-updates";
};
EOFORIGINS
        return 0
    fi
    
    # Note: Backup should be done by caller before calling this function
    
    # Check if updates is already in Origins-Pattern (check for the pattern, not literal variable)
    if run_as_root grep -q '\${distro_id}:\${distro_codename}-updates' "$file" 2>/dev/null; then
        return 0  # Already configured
    fi
    
    # Check if Origins-Pattern block exists
    if run_as_root grep -q "Unattended-Upgrade::Origins-Pattern" "$file" 2>/dev/null; then
        # Find the security line and add updates after it
        # Use a temporary file for safer editing
        local temp_file=$(mktemp)
        local in_block=false
        local added=false
        
        # Read file line by line, handling files that don't end with newline
        while IFS= read -r line || [ -n "$line" ]; do
            if echo "$line" | grep -q "Unattended-Upgrade::Origins-Pattern" 2>/dev/null; then
                in_block=true
            fi
            
            if [ "$in_block" = true ] && [ "$added" = false ]; then
                # Check if this line contains the security pattern
                if echo "$line" | grep -q '\${distro_codename}-security' 2>/dev/null; then
                    echo "$line" >> "$temp_file"
                    echo '    "${distro_id}:${distro_codename}-updates";' >> "$temp_file"
                    added=true
                    continue
                fi
                
                # Check if we hit the closing brace before finding security
                if echo "$line" | grep -q "^};" 2>/dev/null; then
                    if [ "$added" = false ]; then
                        # Add updates before closing brace
                        echo '    "${distro_id}:${distro_codename}-updates";' >> "$temp_file"
                        added=true
                    fi
                    in_block=false
                fi
            fi
            
            echo "$line" >> "$temp_file"
        done < <(run_as_root cat "$file")
        
        run_as_root cp "$temp_file" "$file"
        rm -f "$temp_file"
        return 0
    else
        # Add Origins-Pattern block at the end
        {
            echo ""
            echo "Unattended-Upgrade::Origins-Pattern {"
            echo '    "${distro_id}:${distro_codename}";'
            echo '    "${distro_id}:${distro_codename}-security";'
            echo '    "${distro_id}:${distro_codename}-updates";'
            echo "};"
        } | run_as_root tee -a "$file" > /dev/null
        return 0
    fi
}

# Configure unattended-upgrades
echo -e "${GREEN}Configuring unattended-upgrades...${NC}"
UNATTENDED_FILE="/etc/apt/apt.conf.d/50unattended-upgrades"

# Backup once before making any changes
if run_as_root [ -f "$UNATTENDED_FILE" ]; then
    backup_file "$UNATTENDED_FILE"
fi

# Ensure Origins-Pattern includes updates
set +e  # Temporarily disable exit on error to catch the issue
ensure_origins_pattern "$UNATTENDED_FILE"
ORIGINS_EXIT=$?
set -e  # Re-enable exit on error
if [ $ORIGINS_EXIT -ne 0 ]; then
    echo -e "${RED}Error in ensure_origins_pattern. Exit code: $ORIGINS_EXIT${NC}"
    exit 1
fi

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
if run_as_root [ -f "$AUTO_UPGRADES_FILE" ]; then
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
run_as_root systemctl enable unattended-upgrades
run_as_root systemctl restart unattended-upgrades
echo -e "${GREEN}✓ Enabled and started unattended-upgrades service${NC}"

# Run initial cleanup
echo -e "${GREEN}Running initial cleanup...${NC}"
run_as_root apt-get autoremove -y -qq
run_as_root apt-get autoclean -qq
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
        # chown only needed if we're running as root
        if [ "$EUID" -eq 0 ]; then
            chown "$ACTUAL_USER:$ACTUAL_USER" "$SSH_DIR"
        fi
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
                # chown only needed if we're running as root
                if [ "$EUID" -eq 0 ]; then
                    chown "$ACTUAL_USER:$ACTUAL_USER" "$AUTHORIZED_KEYS"
                fi
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
            if run_as_root grep -qE "^PasswordAuthentication" "$SSHD_CONFIG"; then
                # Update existing setting
                run_as_root sed -i 's/^PasswordAuthentication.*/PasswordAuthentication no/' "$SSHD_CONFIG"
            else
                # Add new setting at the end
                {
                    echo ""
                    echo "# Disable password authentication (configured by ubuntu-init)"
                    echo "PasswordAuthentication no"
                } | run_as_root tee -a "$SSHD_CONFIG" > /dev/null
            fi
            
            # Also ensure PubkeyAuthentication is enabled (should be default, but be explicit)
            if ! run_as_root grep -qE "^PubkeyAuthentication" "$SSHD_CONFIG"; then
                echo "PubkeyAuthentication yes" | run_as_root tee -a "$SSHD_CONFIG" > /dev/null
            fi
            
            # Restart SSH service
            if run_as_root systemctl is-active --quiet sshd 2>/dev/null || run_as_root systemctl is-active --quiet ssh 2>/dev/null; then
                run_as_root systemctl restart sshd 2>/dev/null || run_as_root systemctl restart ssh 2>/dev/null || true
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

