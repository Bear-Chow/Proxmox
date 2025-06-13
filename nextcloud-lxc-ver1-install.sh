#!/usr/bin/env bash
set -eEuo pipefail

############################################################
### NEXTCLOUD LXC CONTAINER INSTALLER FOR PROXMOX VE     ###
### Features:                                            ###
### - Storage selection compatible with all setups        ###
### - Supports both MariaDB and MySQL                    ###
### - Automatic network configuration                    ###
### - Validates all prerequisites                        ###
### - Secure default configuration                       ###
############################################################

# Message formatting functions
msg_info() { echo -e "\e[36m[INFO]\e[0m $1"; }
msg_ok() { echo -e "\e[32m[OK]\e[0m $1"; }
msg_error() { echo -e "\e[91m[ERROR]\e[0m $1"; }

# Error handler for trapping and cleaning up failed operations
error_handler() {
  local exit_code=$?
  echo -e "\n\e[91m[ERROR]\e[0m ${BASH_SOURCE[1]}: Line ${BASH_LINENO[0]}: Command '${BASH_COMMAND}' exited with status ${exit_code}."
  [[ -n "${CTID:-}" ]] && cleanup_ctid
  exit $exit_code
}

cleanup_ctid() {
  if pct status "$CTID" &>/dev/null; then
    msg_info "Cleaning up container $CTID due to error"
    pct destroy "$CTID" --force
  fi
}

trap error_handler ERR

# Validate network bridge exists
validate_bridge() {
  if ! grep -q "^iface ${1} inet" /etc/network/interfaces && ! grep -q "^auto ${1}" /etc/network/interfaces; then
    msg_error "Network bridge $1 not found in /etc/network/interfaces"
    return 1
  fi
}

# Validate storage pool exists and has space
validate_storage() {
  if ! pvesm status | grep -q "^${1}\s"; then
    msg_error "Storage pool $1 not found"
    return 1
  fi
  local available_space=$(pvesm status -storage "$1" | awk 'NR>1{print $5}' | sed 's/[^0-9]//g')
  if [[ "$available_space" -lt "$var_disk_size" ]]; then
    msg_error "Insufficient space in storage pool $1 (needs ${var_disk_size}G, has ${available_space}G)"
    return 1
  fi
}

# Validate template exists in repository
validate_template() {
  if ! pveam available | awk '$2 ~ /^debian-12/ && $2 !~ /turnkey/ {print $2}' | grep -q "$1"; then
    msg_error "Template $1 not available in repository"
    return 1
  fi
}

############################################################
### SYSTEM PREPARATION                                   ###
############################################################

ARCH=$(uname -m)
[[ "$ARCH" == "x86_64" ]] && ARCH="amd64"
msg_info "Detected system architecture: $ARCH"

whiptail --title "Nextcloud LXC" --yesno "This will create a new LXC for Nextcloud. Proceed?" 10 60 || exit 0

############################################################
### STORAGE CONFIGURATION (robust/portable)              ###
############################################################

# Portable, user-friendly storage selection (works everywhere)
STORAGE=$(pvesm status | awk '$2 == "active" {print $1, "\""$1" storage\""}' | xargs whiptail --title "Storage" --menu "Select storage pool:" 14 60 6 3>&1 1>&2 2>&3)
validate_storage "$STORAGE" || exit 1

# Determine where to store templates
if ! pvesm status -storage "$STORAGE" | grep -q 'vztmpl'; then
  msg_info "Switching template download to local storage"
  TEMPLATE_STORAGE="local"
else
  TEMPLATE_STORAGE="$STORAGE"
fi

############################################################
### NETWORK CONFIGURATION                                ###
############################################################

var_network_bridge="vmbr0"
validate_bridge "$var_network_bridge" || exit 1

NETWORK_METHOD=$(whiptail --title "Network Configuration" --menu "Select network type:" 12 60 2 \
  "dhcp" "Automatic (DHCP)" \
  "static" "Static IP" 3>&1 1>&2 2>&3)

if [[ "$NETWORK_METHOD" == "static" ]]; then
  var_network_type="manual"
  var_network_ip=$(whiptail --title "Static IP" --inputbox "Enter static IP address with CIDR (e.g., 10.0.0.50/24):" 10 60 3>&1 1>&2 2>&3)
  [[ -z "$var_network_ip" ]] && { msg_error "IP address cannot be empty"; exit 1; }
  GATEWAY=$(whiptail --title "Gateway" --inputbox "Enter gateway address:" 10 60 3>&1 1>&2 2>&3)
  [[ -z "$GATEWAY" ]] && { msg_error "Gateway cannot be empty"; exit 1; }
else
  var_network_type="dhcp"
fi

############################################################
### CONTAINER CONFIGURATION                              ###
############################################################

APP="Nextcloud"
var_disk_size="16"
var_cpu_cores="2"
var_ram_size="2048"
var_hostname="nextcloud"

# Database config defaults
DB_USER="ncuser"
DB_PASS=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 16)
DB_NAME="nextcloud"
DB_CHARSET="utf8mb4"
DB_COLLATION="utf8mb4_general_ci"

# Select and validate template
TEMPLATE=$(pveam available | awk '$2 ~ /^debian-12/ && $2 !~ /turnkey/ {print $2}' | sort -V | tail -1)
validate_template "$TEMPLATE" || exit 1

msg_info "Downloading template $TEMPLATE"
pveam download "$TEMPLATE_STORAGE" "$TEMPLATE" || { msg_error "Template download failed"; exit 1; }

CTID=$(pvesh get /cluster/nextid)
msg_info "Creating LXC container (ID: $CTID)"

create_params=(
  "$CTID"
  "$TEMPLATE_STORAGE:vztmpl/$TEMPLATE"
  -arch "$ARCH"
  -cores "$var_cpu_cores"
  -hostname "$var_hostname"
  -memory "$var_ram_size"
  -ostype debian
  -rootfs "$STORAGE:${var_disk_size}"
  -features nesting=1
  -unprivileged 1
)

if [[ "$var_network_type" == "manual" ]]; then
  create_params+=(-net0 "name=eth0,bridge=$var_network_bridge,ip=$var_network_ip,gw=$GATEWAY")
else
  create_params+=(-net0 "name=eth0,bridge=$var_network_bridge,ip=dhcp")
fi

pct create "${create_params[@]}" || { msg_error "Container creation failed"; exit 1; }
msg_ok "Container $CTID created"

############################################################
### CONTAINER INITIALIZATION                             ###
############################################################

msg_info "Starting LXC container"
pct start "$CTID"
sleep 5

IP=""
max_attempts=10
attempt=0
msg_info "Waiting for IP address assignment..."
while [[ $attempt -lt $max_attempts ]]; do
  if [[ "$var_network_type" == "dhcp" ]]; then
    IP=$(pct exec "$CTID" -- ip -4 -o addr show dev eth0 2>/dev/null | awk '{print $4}' | cut -d/ -f1)
  else
    IP="${var_network_ip%%/*}"
  fi
  [[ -n "$IP" ]] && break
  sleep 2
  echo -n "."
  ((attempt++))
done

if [[ -z "$IP" ]]; then
  msg_error "Container did not acquire an IP address"
  exit 1
fi

msg_ok "Container IP: $IP"

############################################################
### SYSTEM PREPARATION                                   ###
############################################################

msg_info "Updating container and installing dependencies"
pct exec "$CTID" -- bash -c "apt-get update && apt-get upgrade -y"
pct exec "$CTID" -- bash -c "apt-get install -y apache2 mariadb-server libapache2-mod-php php php-mysql php-zip php-dom php-curl php-gd php-xml php-mbstring php-bcmath php-gmp php-intl php-imagick unzip curl"

############################################################
### DATABASE CONFIGURATION (MariaDB/MySQL)               ###
############################################################

msg_info "Configuring MariaDB/MySQL database"
pct exec "$CTID" -- bash -c "mysql -e \"
CREATE DATABASE IF NOT EXISTS $DB_NAME CHARACTER SET $DB_CHARSET COLLATE $DB_COLLATION;
CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';
GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_USER'@'localhost';
FLUSH PRIVILEGES;\""
msg_ok "Database configuration completed"

############################################################
### NEXTCLOUD INSTALLATION                               ###
############################################################

msg_info "Downloading and installing Nextcloud"
pct exec "$CTID" -- bash -c "curl -fsSL https://download.nextcloud.com/server/releases/latest.zip -o /tmp/nextcloud.zip"
pct exec "$CTID" -- bash -c "unzip -q /tmp/nextcloud.zip -d /var/www/ && rm /tmp/nextcloud.zip"
pct exec "$CTID" -- bash -c "chown -R www-data:www-data /var/www/nextcloud"

############################################################
### APACHE CONFIGURATION                                 ###
############################################################

msg_info "Configuring Apache web server"
pct exec "$CTID" -- bash -c "echo '<VirtualHost *:80>
  ServerName $var_hostname
  DocumentRoot /var/www/nextcloud
  <Directory /var/www/nextcloud/>
    Require all granted
    AllowOverride All
    Options FollowSymLinks MultiViews
    <IfModule mod_dav.c>
      Dav off
    </IfModule>
  </Directory>
</VirtualHost>' > /etc/apache2/sites-available/nextcloud.conf"

pct exec "$CTID" -- bash -c "a2dissite 000-default"
pct exec "$CTID" -- bash -c "a2ensite nextcloud"
pct exec "$CTID" -- bash -c "a2enmod rewrite headers env dir mime setenvif ssl"
pct exec "$CTID" -- bash -c "systemctl restart apache2"

############################################################
### PHP OPTIMIZATION                                     ###
############################################################

msg_info "Optimizing PHP settings for Nextcloud"
pct exec "$CTID" -- bash -c "for config in /etc/php/*/apache2/php.ini; do
  sed -i \"s/^memory_limit = .*/memory_limit = 512M/\" \$config
  sed -i \"s/^upload_max_filesize = .*/upload_max_filesize = 512M/\" \$config
  sed -i \"s/^post_max_size = .*/post_max_size = 512M/\" \$config
  sed -i \"s/^max_execution_time = .*/max_execution_time = 300/\" \$config
  sed -i \"s/^max_input_time = .*/max_input_time = 300/\" \$config
done"

pct exec "$CTID" -- bash -c "systemctl restart apache2"
msg_ok "PHP optimization completed"

############################################################
### INSTALLATION COMPLETE                                ###
############################################################

echo -e "\n\e[32mNEXTCLOUD INSTALLATION COMPLETE!\e[0m"
echo -e "Access your instance at: \e[34mhttp://$IP/\e[0m"
echo -e "\n\e[33mIMPORTANT CREDENTIALS:\e[0m"
echo -e "Database Name: $DB_NAME"
echo -e "Database User: $DB_USER"
echo -e "Database Password: $DB_PASS \e[31m(change this immediately!)\e[0m"
echo -e "\n\e[33mRECOMMENDED NEXT STEPS:\e[0m"
echo -e "1. Complete the Nextcloud web setup wizard"
echo -e "2. Set up SSL/TLS encryption (HTTPS)"
echo -e "3. Change database credentials"
echo -e "4. Configure regular backups"
echo -e "5. Set up proper file permissions"
echo -e "6. Configure memory caching (APCu/Redis)"
