#!/bin/bash

#############################################
# High-Concurrency Go Server - VPS Deploy Script
# Automated deployment for Ubuntu/Debian
#############################################

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
APP_NAME="highconcurrency-server"
APP_USER="appuser"
APP_DIR="/opt/${APP_NAME}"
LOG_DIR="/var/log/${APP_NAME}"
GO_VERSION="1.21.6"
PORT="${PORT:-8080}"
WORKERS="${WORKERS:-$(nproc --all)}"

# Functions
print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_error() {
    echo -e "${RED}✗ $1${NC}"
}

print_info() {
    echo -e "${YELLOW}ℹ $1${NC}"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "This script must be run as root (use sudo)"
        exit 1
    fi
}

detect_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS=$ID
        VER=$VERSION_ID
    else
        print_error "Cannot detect OS"
        exit 1
    fi
    
    print_info "Detected OS: $OS $VER"
}

update_system() {
    print_info "Updating system packages..."
    apt update && apt upgrade -y
    apt install -y curl wget git build-essential jq htop
    print_success "System updated"
}

install_go() {
    if command -v go &> /dev/null; then
        CURRENT_GO=$(go version | awk '{print $3}' | sed 's/go//')
        print_info "Go $CURRENT_GO already installed"
        
        if [[ "$CURRENT_GO" < "1.21" ]]; then
            print_info "Upgrading Go to $GO_VERSION..."
        else
            print_success "Go version is sufficient"
            return
        fi
    fi
    
    print_info "Installing Go $GO_VERSION..."
    cd /tmp
    wget -q https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz
    rm -rf /usr/local/go
    tar -C /usr/local -xzf go${GO_VERSION}.linux-amd64.tar.gz
    
    # Add to PATH
    if ! grep -q "/usr/local/go/bin" /etc/profile; then
        echo 'export PATH=$PATH:/usr/local/go/bin' >> /etc/profile
        echo 'export GOPATH=$HOME/go' >> /etc/profile
        echo 'export PATH=$PATH:$GOPATH/bin' >> /etc/profile
    fi
    
    export PATH=$PATH:/usr/local/go/bin
    print_success "Go installed: $(go version)"
}

create_app_user() {
    if id "$APP_USER" &>/dev/null; then
        print_info "User $APP_USER already exists"
    else
        print_info "Creating application user: $APP_USER"
        useradd -m -s /bin/bash $APP_USER
        print_success "User created"
    fi
}

configure_system_limits() {
    print_info "Configuring system limits for high concurrency..."
    
    # File descriptor limits
    cat >> /etc/security/limits.conf <<EOF

# High Concurrency Server Limits
* soft nofile 1000000
* hard nofile 1000000
$APP_USER soft nofile 1000000
$APP_USER hard nofile 1000000
EOF
    
    # TCP/IP tuning
    cat >> /etc/sysctl.conf <<EOF

# High Concurrency Server - Network Tuning
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_max_syn_backlog = 8192
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 8192
net.ipv4.ip_local_port_range = 1024 65535
EOF
    
    # Check if conntrack module is available
    if lsmod | grep -q nf_conntrack; then
        cat >> /etc/sysctl.conf <<EOF
net.netfilter.nf_conntrack_max = 1000000
net.nf_conntrack_max = 1000000
EOF
    fi
    
    sysctl -p > /dev/null 2>&1
    print_success "System limits configured"
}

setup_directories() {
    print_info "Setting up directories..."
    mkdir -p $APP_DIR
    mkdir -p $LOG_DIR
    chown -R $APP_USER:$APP_USER $APP_DIR
    chown -R $APP_USER:$APP_USER $LOG_DIR
    print_success "Directories created"
}

deploy_application() {
    print_info "Choose deployment method:"
    echo "1) Build from GitHub repository"
    echo "2) Build from local source"
    echo "3) Skip (binary already in place)"
    read -p "Enter choice [1-3]: " choice
    
    case $choice in
        1)
            read -p "Enter GitHub repository URL: " REPO_URL
            print_info "Cloning repository..."
            cd /tmp
            rm -rf $APP_NAME
            git clone $REPO_URL $APP_NAME
            cd $APP_NAME
            
            print_info "Building application..."
            /usr/local/go/bin/go mod download
            CGO_ENABLED=0 /usr/local/go/bin/go build -ldflags="-w -s" -o server main.go
            
            cp server $APP_DIR/
            chown $APP_USER:$APP_USER $APP_DIR/server
            chmod +x $APP_DIR/server
            print_success "Application built and deployed"
            ;;
        2)
            read -p "Enter path to source directory: " SOURCE_DIR
            if [[ ! -d "$SOURCE_DIR" ]]; then
                print_error "Directory not found: $SOURCE_DIR"
                exit 1
            fi
            
            print_info "Building application..."
            cd $SOURCE_DIR
            /usr/local/go/bin/go mod download
            CGO_ENABLED=0 /usr/local/go/bin/go build -ldflags="-w -s" -o server main.go
            
            cp server $APP_DIR/
            chown $APP_USER:$APP_USER $APP_DIR/server
            chmod +x $APP_DIR/server
            print_success "Application built and deployed"
            ;;
        3)
            if [[ ! -f "$APP_DIR/server" ]]; then
                print_error "Binary not found at $APP_DIR/server"
                exit 1
            fi
            print_success "Using existing binary"
            ;;
        *)
            print_error "Invalid choice"
            exit 1
            ;;
    esac
}

create_env_file() {
    print_info "Creating environment configuration..."
    cat > $APP_DIR/.env <<EOF
PORT=$PORT
WORKERS=$WORKERS
MAX_CONNECTIONS=100000
WORKER_QUEUE_SIZE=10000
EOF
    
    chown $APP_USER:$APP_USER $APP_DIR/.env
    print_success "Environment file created"
}

create_systemd_service() {
    print_info "Creating systemd service..."
    cat > /etc/systemd/system/${APP_NAME}.service <<'EOF'
[Unit]
Description=High Concurrency Go HTTP Server
After=network.target
Wants=network-online.target

[Service]
Type=simple
User=appuser
Group=appuser

WorkingDirectory=/opt/highconcurrency-server
ExecStart=/opt/highconcurrency-server/server

EnvironmentFile=/opt/highconcurrency-server/.env

Restart=always
RestartSec=5s

LimitNOFILE=1000000
LimitNPROC=500000

NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/opt/highconcurrency-server /var/log/highconcurrency-server

StandardOutput=journal
StandardError=journal
SyslogIdentifier=highconcurrency-server

TimeoutStopSec=30s
KillMode=mixed
KillSignal=SIGTERM

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload
    systemctl enable ${APP_NAME}
    print_success "Systemd service created and enabled"
}

setup_firewall() {
    print_info "Configuring firewall..."
    
    if ! command -v ufw &> /dev/null; then
        apt install -y ufw
    fi
    
    ufw --force reset
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow 22/tcp comment 'SSH'
    ufw allow 80/tcp comment 'HTTP'
    ufw allow 443/tcp comment 'HTTPS'
    
    read -p "Allow direct access to app port $PORT? (y/N): " allow_app
    if [[ $allow_app =~ ^[Yy]$ ]]; then
        ufw allow $PORT/tcp comment 'Application'
    fi
    
    ufw --force enable
    print_success "Firewall configured"
}

setup_nginx() {
    read -p "Install and configure Nginx reverse proxy? (y/N): " install_nginx
    if [[ ! $install_nginx =~ ^[Yy]$ ]]; then
        return
    fi
    
    print_info "Installing Nginx..."
    apt install -y nginx
    
    read -p "Enter domain name (or press enter to use IP): " DOMAIN
    if [[ -z "$DOMAIN" ]]; then
        DOMAIN="_"
    fi
    
    cat > /etc/nginx/sites-available/${APP_NAME} <<EOF
upstream app_server {
    server 127.0.0.1:${PORT};
    keepalive 256;
}

server {
    listen 80;
    server_name ${DOMAIN};

    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;

    access_log /var/log/nginx/${APP_NAME}_access.log;
    error_log /var/log/nginx/${APP_NAME}_error.log;

    proxy_connect_timeout 60s;
    proxy_send_timeout 60s;
    proxy_read_timeout 60s;

    location / {
        proxy_pass http://app_server;
        proxy_http_version 1.1;
        
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Connection "";
        
        proxy_buffering off;
    }

    location /health {
        proxy_pass http://app_server/health;
        access_log off;
    }

    location /metrics {
        proxy_pass http://app_server/metrics;
        allow 127.0.0.1;
        deny all;
    }
}
EOF
    
    ln -sf /etc/nginx/sites-available/${APP_NAME} /etc/nginx/sites-enabled/
    rm -f /etc/nginx/sites-enabled/default
    
    nginx -t
    systemctl restart nginx
    systemctl enable nginx
    
    print_success "Nginx configured"
    
    if [[ "$DOMAIN" != "_" ]]; then
        read -p "Install SSL certificate with Let's Encrypt? (y/N): " install_ssl
        if [[ $install_ssl =~ ^[Yy]$ ]]; then
            setup_ssl "$DOMAIN"
        fi
    fi
}

setup_ssl() {
    local domain=$1
    print_info "Installing Certbot..."
    apt install -y certbot python3-certbot-nginx
    
    print_info "Obtaining SSL certificate..."
    certbot --nginx -d $domain --non-interactive --agree-tos --register-unsafely-without-email
    
    systemctl reload nginx
    print_success "SSL certificate installed"
}

setup_monitoring() {
    read -p "Set up basic monitoring scripts? (y/N): " setup_mon
    if [[ ! $setup_mon =~ ^[Yy]$ ]]; then
        return
    fi
    
    print_info "Creating monitoring scripts..."
    
    # Status check script
    cat > /usr/local/bin/${APP_NAME}-status <<'EOF'
#!/bin/bash
echo "=== Service Status ==="
systemctl status highconcurrency-server --no-pager | head -20

echo -e "\n=== Metrics ==="
curl -s http://localhost:8080/metrics | jq '.' 2>/dev/null || echo "Metrics unavailable"

echo -e "\n=== System Resources ==="
free -h
echo ""
top -bn1 | head -20

echo -e "\n=== Active Connections ==="
netstat -an | grep :8080 | grep ESTABLISHED | wc -l
EOF
    
    chmod +x /usr/local/bin/${APP_NAME}-status
    
    print_success "Monitoring scripts created"
    print_info "Run: ${APP_NAME}-status"
}

start_service() {
    print_info "Starting service..."
    systemctl start ${APP_NAME}
    sleep 2
    
    if systemctl is-active --quiet ${APP_NAME}; then
        print_success "Service started successfully"
        systemctl status ${APP_NAME} --no-pager | head -10
    else
        print_error "Service failed to start"
        journalctl -u ${APP_NAME} -n 50 --no-pager
        exit 1
    fi
}

run_health_check() {
    print_info "Running health check..."
    sleep 2
    
    if curl -sf http://localhost:${PORT}/health > /dev/null; then
        print_success "Health check passed"
        curl -s http://localhost:${PORT}/health | jq '.'
    else
        print_error "Health check failed"
        exit 1
    fi
}

print_summary() {
    echo ""
    echo "========================================="
    echo "  Deployment Complete! 🎉"
    echo "========================================="
    echo ""
    echo "Service Status:"
    echo "  sudo systemctl status ${APP_NAME}"
    echo ""
    echo "View Logs:"
    echo "  sudo journalctl -u ${APP_NAME} -f"
    echo ""
    echo "Check Health:"
    echo "  curl http://localhost:${PORT}/health"
    echo ""
    echo "View Metrics:"
    echo "  curl http://localhost:${PORT}/metrics | jq"
    echo ""
    echo "Quick Status:"
    echo "  ${APP_NAME}-status"
    echo ""
    echo "Configuration:"
    echo "  Application: $APP_DIR"
    echo "  Config: $APP_DIR/.env"
    echo "  Logs: $LOG_DIR"
    echo "  Port: $PORT"
    echo "  Workers: $WORKERS"
    echo ""
    
    IP=$(curl -s ifconfig.me)
    echo "Access your server at:"
    echo "  http://${IP}:${PORT}"
    
    if [[ -f /etc/nginx/sites-enabled/${APP_NAME} ]]; then
        echo "  (or via Nginx on port 80/443)"
    fi
    echo ""
    echo "========================================="
}

# Main deployment flow
main() {
    clear
    echo "========================================="
    echo "  High-Concurrency Go Server Deployment"
    echo "========================================="
    echo ""
    
    check_root
    detect_os
    
    echo ""
    read -p "Continue with deployment? (y/N): " confirm
    if [[ ! $confirm =~ ^[Yy]$ ]]; then
        print_info "Deployment cancelled"
        exit 0
    fi
    
    update_system
    install_go
    create_app_user
    configure_system_limits
    setup_directories
    deploy_application
    create_env_file
    create_systemd_service
    setup_firewall
    setup_nginx
    setup_monitoring
    start_service
    run_health_check
    print_summary
}

# Run main function
main "$@"
