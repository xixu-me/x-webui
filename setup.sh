#!/bin/bash

# ==============================================================================
# Setup Script for x-webui
# ==============================================================================

# Exit immediately if a command exits with a non-zero status
set -euo pipefail

# ------------------------------------------------------------------------------
# Constants and Variables
# ------------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_DIR="$SCRIPT_DIR/src/config"
HTML_DIR="$SCRIPT_DIR/src/www"

# ------------------------------------------------------------------------------
# Helper Functions
# ------------------------------------------------------------------------------

log_info() {
    echo -e "${GREEN}[INFO] $(date '+%Y-%m-%d %H:%M:%S'): $1${NC}"
}

log_warn() {
    echo -e "${YELLOW}[WARN] $(date '+%Y-%m-%d %H:%M:%S'): $1${NC}"
}

log_error() {
    echo -e "${RED}[ERROR] $(date '+%Y-%m-%d %H:%M:%S'): $1${NC}"
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        log_error "Please run as root (use sudo)"
        exit 1
    fi
}

install_dependencies() {
    log_info "Installing required packages..."
    apt-get update -y
    apt-get install -y cron nginx ca-certificates curl gnupg lsb-release gettext-base
}

configure_nginx_initial() {
    log_info "Configuring Nginx (Initial)..."
    
    # Clean up default
    if [ -f /var/www/html/index.nginx-debian.html ]; then
        rm /var/www/html/index.nginx-debian.html
    fi
    
    # Set permissions
    chown -R "$USERNAME:$USERNAME" /var/www
    
    # Generate index.html from template
    log_info "Generating portfolio for user: $USERNAME"
    sed "s/{{USERNAME}}/$USERNAME/g" "$HTML_DIR/index.html" > /var/www/html/index.html
    
    # Generate Nginx config
    export DOMAIN
    envsubst '${DOMAIN}' < "$TEMPLATE_DIR/nginx.conf.template" > /etc/nginx/nginx.conf
    
    systemctl reload nginx
}

setup_acme() {
    log_info "Setting up ACME for SSL..."
    
    if [ ! -d "/home/$USERNAME/.acme.sh" ]; then
        curl https://get.acme.sh | sh
    fi
    
    # Access as the user
    sudo -u "$USERNAME" /home/$USERNAME/.acme.sh/acme.sh --upgrade --auto-upgrade
    sudo -u "$USERNAME" /home/$USERNAME/.acme.sh/acme.sh --set-default-ca --server letsencrypt
    sudo -u "$USERNAME" /home/$USERNAME/.acme.sh/acme.sh --issue -d "$DOMAIN" -w /var/www/html --keylength ec-256 --force
}

install_docker() {
    log_info "Installing Docker..."
    
    install -m 0755 -d /etc/apt/keyrings
    if [ ! -f /etc/apt/keyrings/docker.asc ]; then
        curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
        chmod a+r /etc/apt/keyrings/docker.asc
    fi

    echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian \
    $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
    tee /etc/apt/sources.list.d/docker.list > /dev/null
    
    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

install_open_webui() {
    log_info "Installing Open WebUI..."
    docker pull ghcr.io/open-webui/open-webui:main
    
    # Check if container exists
    if [ "$(docker ps -aq -f name=open-webui)" ]; then
        docker rm -f open-webui
    fi
    
    docker run -d -p 8888:8080 -v open-webui:/app/backend/data --name open-webui ghcr.io/open-webui/open-webui:main
    docker update --restart=unless-stopped open-webui
}

install_xray() {
    log_info "Installing Xray..."
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
}

setup_certificates() {
    log_info "Setting up certificates..."
    
    CERT_DIR="/home/$USERNAME/cert"
    sudo -u "$USERNAME" mkdir -p "$CERT_DIR"
    
    sudo -u "$USERNAME" /home/$USERNAME/.acme.sh/acme.sh --install-cert -d "$DOMAIN" --ecc --fullchain-file "$CERT_DIR/x.crt" --key-file "$CERT_DIR/x.key"
    chmod +r "$CERT_DIR/x.key"
    
    # Create renewal script
    cat > "$CERT_DIR/cert-renew.sh" <<EOF
#!/bin/bash
/home/$USERNAME/.acme.sh/acme.sh --install-cert -d $DOMAIN --ecc --fullchain-file $CERT_DIR/x.crt --key-file $CERT_DIR/x.key
echo "X Certificates Renewed"
chmod +r $CERT_DIR/x.key
echo "Read Permission Granted for Private Key"
systemctl restart xray
echo "X Restarted"
EOF
    
    chmod +x "$CERT_DIR/cert-renew.sh"
    chown "$USERNAME:$USERNAME" "$CERT_DIR/cert-renew.sh"
    
    # Cron job
    (crontab -l 2>/dev/null; echo "0 1 1 * * bash $CERT_DIR/cert-renew.sh") | crontab -
}

configure_xray() {
    log_info "Configuring Xray..."
    
    export ID
    export USERNAME
    envsubst '${ID} ${USERNAME}' < "$TEMPLATE_DIR/xray.json.template" > /usr/local/etc/xray/config.json
    
    systemctl start xray
    systemctl enable xray
}

configure_system() {
    log_info "Optimizing system settings..."
    cat > /etc/sysctl.d/99-custom.conf <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
    sysctl --system
}

configure_nginx_final() {
    log_info "Finalizing Nginx configuration..."
    export DOMAIN
    envsubst '${DOMAIN}' < "$TEMPLATE_DIR/nginx_final.conf.template" > /etc/nginx/nginx.conf
    
    systemctl restart nginx
}

# ------------------------------------------------------------------------------
# Main Execution
# ------------------------------------------------------------------------------

# Check arguments
if [ "$#" -ne 3 ]; then
    echo "Usage: $0 <username> <domain> <id>"
    exit 1
fi

USERNAME="$1"
DOMAIN="$2"
ID="$3"

check_root
install_dependencies
configure_nginx_initial
setup_acme
install_docker
install_open_webui
install_xray
setup_certificates
configure_xray
configure_system
configure_nginx_final

log_info "Setup complete! The system will now reboot."
reboot
