#! /bin/bash

### DESCRIPTION: This script checks that the system is ready, then changes 
### the SSH port in sshd_config, SELinux, and firewalld.

### SECTION 1
### Checking system readiness and provided port

# Reassign variable name so easier to read
NEW_PORT=$1

# Check if port argument is provided
if [[ -z $NEW_PORT ]]; then
  echo -e "\tMissing argument"
  echo -e "\tSyntax: ./change_ssh_port.sh <port number>"
  exit 1
else
  echo -e "Performing checks..."
fi

# Check if user is root or using sudo
if [[ $EUID -ne 0 ]]; then
  echo -e "\tThis script requires root privileges"
  exit 1
else
  echo -e "\tAppropriate privileges"
fi 

# Check if policycoreutils-python-utils is installed
if dnf list installed -q policycoreutils-python-utils > /dev/null 2>&1; then
  echo -e "\tDependencies are installed"
else
  echo -e "\tMissing dependency. Please install policycoreutils-python-utils"
  exit 1
fi

# Check if port number is in appropriate range
if [[ "$NEW_PORT" -gt 0 && "$NEW_PORT" -lt 65536 ]]; then
  echo -e "\tAppropriate port number ($NEW_PORT)"
else
  echo -e "\tPort $NEW_PORT is invalid (range 1-65535)"
  exit 1
fi

# Check if port is available
USED_PORTS=$(ss -lntH | \
             sed 's/.*:\([0-9]\{1,5\}\).*/\1/' | \
             uniq)

for USED_PORT in $USED_PORTS; do
  if [[ "$NEW_PORT" -eq "$USED_PORT" ]]; then
    echo -e "\tPort selected ($NEW_PORT) is already in use for another service"
    exit 1
  fi
done

echo -e "\tPort $NEW_PORT is available and not being used by a service"

# Check if port is already assigned in SELinux policy (first 10,000 port range)
ASSIGNED_PORTS=$(semanage port -l | \
                 tr -dc "0-9,\n-" | \
                 tr ",-" "\n" | \
                 sed -E '/^[0-9]{5,}/d')

for ASSIGNED_PORT in $ASSIGNED_PORTS; do
  if [[ "$NEW_PORT" -eq "ASSIGNED_PORT" ]]; then
    echo -e "\tPort ($NEW_PORT) is already assigned in SELinux. Please use another"
    exit 1
  fi
done

echo -e "\tPort $NEW_PORT is also available in SELinux"


# Confirm with user before actual changes are made
read -p "No issues detected. Configure port $NEW_PORT for SSH? (y/n) " CONFIRM
case "$CONFIRM" in
  y|Y ) 
    echo -e "Resuming the script"
  ;;
  n|N )
    echo -e "Terminating the script"
    exit 0
  ;;
  * )
    echo -e "Unrecognized input. Terminating the script"
    exit 1
  ;;
esac


### SECTION 2
### Back up existing sshd configuration

echo -e "Backing up current sshd configuration..."

# Define these variables so we don't repeat ourselves
CONFIG_PATH="/etc/ssh/sshd_config"
BACKUP_DIR=".sshd_backups"
BACKUP_NAME="$(date +"%m_%d_%y_%H%M%S").bak"

# If directory doesn't exist, make it. If it exists, use it
if [[ ! -d $HOME/$BACKUP_DIR ]]; then
  mkdir -p "$HOME"/"$BACKUP_DIR"
  echo -e "\tBackup directory not found. Creating $HOME/$BACKUP_DIR"
else
  echo -e "\tBackup directory found. Saving current config to $HOME/$BACKUP_DIR"
fi

# Copy sshd_config, make sure we copied it, and make sure the contents match
echo -e "\tBacking up current config to $HOME/$BACKUP_DIR/$BACKUP_NAME"

cp "$CONFIG_PATH" "$HOME"/"$BACKUP_DIR"/"$BACKUP_NAME"

if [[ ! -e $HOME/$BACKUP_DIR/$BACKUP_NAME ]]; then
  echo -e "\tError creating backup file. Exiting"
  exit 1
else
  echo -e "\tBackup file created, checking contents"
  if cmp -s "$CONFIG_PATH" "$HOME/$BACKUP_DIR/$BACKUP_NAME"; then
    echo -e "\tBackup ($BACKUP_NAME) matches current sshd_config file"
  else
    echo -e "\tBackup ($BACKUP_NAME) damaged. Exiting"
    exit 1
  fi
fi

### SECTION 3
### Updating configuration

# Define old ssh port as variable and enumerate current SELinux ssh_port_t ports
OLD_PORT=$(sudo sed -nE "s/^#?Port\s+([[:digit:]]{1,5}).*$/\1/p" "$CONFIG_PATH")
SSH_PORT_T_PORTS=$(sudo semanage port -l | grep ^ssh_port_t | tr -dc '0-9,'| tr ',' '\n')

# Use sed to modify the SSH port inline (-i)
echo -e "Updating system configurations..."
echo -e "\tChanging port in $CONFIG_PATH: $OLD_PORT => $NEW_PORT"
sed -i -E "s/^#?Port\s+([[:digit:]]{1,5}).*$/Port ${NEW_PORT}/" "$CONFIG_PATH"

# Remove any residual SELinux ssh_port_t bindings that we can
echo -e "\tRemoving stale SELinux port bindings for sshd"
for SSH_PORT in $SSH_PORT_T_PORTS; do
  if [[ $SSH_PORT -eq "22" ]]; then
    echo -e "\t    => Skipping port 22; can't be removed"
  else
    echo -e "\t    => Removing port $SSH_PORT from SELinux policy"
    semanage port -d -t ssh_port_t -p tcp "$SSH_PORT"
  fi
done

# Add the SELinux ssh_port_t binding for the new port
echo -e "\tAdding new SELinux port binding for port $NEW_PORT"
if semanage port -a -t ssh_port_t -p tcp "$NEW_PORT" > /dev/null 2>&1; then
  echo -e "\tAdded new SELinux binding for $NEW_PORT successfully"
else
  echo -e "\tFailed to add SELinux binding. Please restore most recent SSHD config"
  exit 1
fi

# If firewalld is active, remove old SSH port and SSH service, and add new port
if systemctl is-active --quiet firewalld; then
  echo -e "\tDetected firewalld as active; removing previous firewall rules"
  
  # Remove old SSH port if detected
  if firewall-cmd --list-ports | grep -q "$OLD_PORT"/tcp; then
    echo -e "\t    => Detected old SSH port ($OLD_PORT); removing"
    firewall-cmd --quiet --remove-port "$OLD_PORT"/tcp --permanent
  fi

  # Remove SSH service entry if detected
  if firewall-cmd --list-services | grep -q ssh; then
    echo -e "\t    => Detected SSH service; removing" 
    firewall-cmd --quiet --remove-service ssh --permanent
  fi

  # If new port is present, move on. Otherwise, allow the new port
  if firewall-cmd --list-ports | grep -q "$NEW_PORT"/tcp; then
    echo -e "\t    => Detected new SSH port ($NEW_PORT); skipping"
  else
    echo -e "\t    => Adding new SSH port ($NEW_PORT)"
    firewall-cmd --quiet --add-port "$NEW_PORT"/tcp --permanent
  fi

  echo -e "\tReloading firewalld"
  firewall-cmd --quiet --reload
fi

# Finally, restart sshd for the new config to take effect
echo -e "\tRestarting sshd"
systemctl restart sshd
echo -e "Done!" 
