# VPS Deployment Guide

Complete guide to deploying the high-concurrency Go server to a VPS (Ubuntu/Debian).

## 📋 Prerequisites

- VPS with Ubuntu 20.04+ or Debian 11+
- Root or sudo access
- Domain name (optional, for SSL)
- Minimum 1GB RAM, 1 CPU core (2GB+ recommended for 60K connections)

## 🚀 Quick Deploy (Automated)

Use the automated deployment script:

```bash
# On your VPS
curl -sSL https://raw.githubusercontent.com/YOUR_REPO/deploy.sh | sudo bash
```

Or follow the manual steps below.

## 📝 Manual Deployment Steps

### Step 1: Initial Server Setup

```bash
# Update system
sudo apt update && sudo apt upgrade -y

# Install essential tools
sudo apt install -y curl wget git build-essential

# Create application user (security best practice)
sudo useradd -m -s /bin/bash appuser
sudo usermod -aG sudo appuser

# Set up firewall
sudo ufw allow 22/tcp     # SSH
sudo ufw allow 80/tcp     # HTTP
sudo ufw allow 443/tcp    # HTTPS
sudo ufw allow 8080/tcp   # Application (or use reverse proxy)
sudo ufw --force enable
```

### Step 2: Install Go

```bash
# Download and install Go 1.21+
cd /tmp
wget https://go.dev/dl/go1.21.6.linux-amd64.tar.gz
sudo rm -rf /usr/local/go
sudo tar -C /usr/local -xzf go1.21.6.linux-amd64.tar.gz

# Add Go to PATH
echo 'export PATH=$PATH:/usr/local/go/bin' | sudo tee -a /etc/profile
echo 'export GOPATH=$HOME/go' | sudo tee -a /etc/profile
echo 'export PATH=$PATH:$GOPATH/bin' | sudo tee -a /etc/profile
source /etc/profile

# Verify installation
go version
```

### Step 3: System Limits Configuration

```bash
# Increase file descriptor limits
cat <<EOF | sudo tee -a /etc/security/limits.conf
* soft nofile 1000000
* hard nofile 1000000
appuser soft nofile 1000000
appuser hard nofile 1000000
EOF

# Increase TCP settings
cat <<EOF | sudo tee -a /etc/sysctl.conf
# TCP performance tuning
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_max_syn_backlog = 8192
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 8192

# Port range for high concurrency
net.ipv4.ip_local_port_range = 1024 65535

# Connection tracking
net.netfilter.nf_conntrack_max = 1000000
net.nf_conntrack_max = 1000000
EOF

# Apply settings
sudo sysctl -p

# Verify limits
ulimit -n
```

### Step 4: Deploy Application

#### Option A: Deploy from Git Repository

```bash
# Switch to app user
sudo su - appuser

# Clone repository
cd ~
git clone https://github.com/YOUR_USERNAME/highconcurrency-server.git
cd highconcurrency-server

# Build application
go mod download
CGO_ENABLED=0 go build -ldflags="-w -s" -o server main.go

# Create necessary directories
sudo mkdir -p /opt/highconcurrency-server
sudo mkdir -p /var/log/highconcurrency-server

# Move binary
sudo cp server /opt/highconcurrency-server/
sudo chown -R appuser:appuser /opt/highconcurrency-server
sudo chown -R appuser:appuser /var/log/highconcurrency-server
```

#### Option B: Upload Pre-built Binary

```bash
# On your local machine
make build
scp server user@your-vps-ip:/tmp/

# On VPS
sudo mkdir -p /opt/highconcurrency-server
sudo mv /tmp/server /opt/highconcurrency-server/
sudo chown -R appuser:appuser /opt/highconcurrency-server
sudo chmod +x /opt/highconcurrency-server/server
```

### Step 5: Configure Systemd Service

```bash
# Create systemd service file
sudo tee /etc/systemd/system/highconcurrency-server.service > /dev/null <<'EOF'
[Unit]
Description=High Concurrency Go HTTP Server
After=network.target
Wants=network-online.target

[Service]
Type=simple
User=appuser
Group=appuser

# Working directory
WorkingDirectory=/opt/highconcurrency-server

# Binary location
ExecStart=/opt/highconcurrency-server/server

# Environment variables
Environment="PORT=8080"
Environment="WORKERS=16"

# Restart policy
Restart=always
RestartSec=5s

# Resource limits
LimitNOFILE=1000000
LimitNPROC=500000

# Security hardening
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/opt/highconcurrency-server /var/log/highconcurrency-server

# Logging
StandardOutput=journal
StandardError=journal
SyslogIdentifier=highconcurrency-server

# Graceful shutdown
TimeoutStopSec=30s
KillMode=mixed
KillSignal=SIGTERM

[Install]
WantedBy=multi-user.target
EOF

# Reload systemd
sudo systemctl daemon-reload

# Enable and start service
sudo systemctl enable highconcurrency-server
sudo systemctl start highconcurrency-server

# Check status
sudo systemctl status highconcurrency-server

# View logs
sudo journalctl -u highconcurrency-server -f
```

### Step 6: Set Up Nginx Reverse Proxy (Recommended)

```bash
# Install Nginx
sudo apt install -y nginx

# Create Nginx configuration
sudo tee /etc/nginx/sites-available/highconcurrency-server > /dev/null <<'EOF'
upstream app_server {
    server 127.0.0.1:8080;
    keepalive 256;
}

server {
    listen 80;
    server_name your-domain.com www.your-domain.com;

    # Security headers
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;

    # Logging
    access_log /var/log/nginx/app_access.log;
    error_log /var/log/nginx/app_error.log;

    # Increase timeouts for long-polling requests
    proxy_connect_timeout 60s;
    proxy_send_timeout 60s;
    proxy_read_timeout 60s;

    location / {
        proxy_pass http://app_server;
        proxy_http_version 1.1;
        
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Connection "";
        
        # Disable buffering for real-time responses
        proxy_buffering off;
    }

    # Health check endpoint
    location /health {
        proxy_pass http://app_server/health;
        access_log off;
    }

    # Metrics endpoint (restrict access)
    location /metrics {
        proxy_pass http://app_server/metrics;
        allow 127.0.0.1;
        deny all;
    }
}
EOF

# Enable site
sudo ln -s /etc/nginx/sites-available/highconcurrency-server /etc/nginx/sites-enabled/

# Test configuration
sudo nginx -t

# Reload Nginx
sudo systemctl reload nginx
```

### Step 7: SSL with Let's Encrypt (Optional but Recommended)

```bash
# Install Certbot
sudo apt install -y certbot python3-certbot-nginx

# Obtain certificate
sudo certbot --nginx -d your-domain.com -d www.your-domain.com

# Certbot will automatically update Nginx config
# Test auto-renewal
sudo certbot renew --dry-run
```

## 🔧 Configuration Management

### Environment Variables

Create a configuration file:

```bash
sudo tee /opt/highconcurrency-server/.env > /dev/null <<EOF
PORT=8080
WORKERS=16
MAX_CONNECTIONS=100000
WORKER_QUEUE_SIZE=10000
EOF

# Update systemd service to use env file
sudo sed -i '/Environment=/d' /etc/systemd/system/highconcurrency-server.service
sudo sed -i '/ExecStart=/i EnvironmentFile=/opt/highconcurrency-server/.env' /etc/systemd/system/highconcurrency-server.service

sudo systemctl daemon-reload
sudo systemctl restart highconcurrency-server
```

### Worker Count Tuning

```bash
# Check CPU cores
nproc

# Set workers to 2x CPU cores
CORES=$(nproc)
WORKERS=$((CORES * 2))
sudo sed -i "s/WORKERS=.*/WORKERS=$WORKERS/" /opt/highconcurrency-server/.env

sudo systemctl restart highconcurrency-server
```

## 📊 Monitoring Setup

### Basic Monitoring with systemd

```bash
# Watch service status
watch -n 2 'systemctl status highconcurrency-server'

# Monitor logs in real-time
sudo journalctl -u highconcurrency-server -f

# Check resource usage
sudo systemctl status highconcurrency-server | grep -A 10 "Memory\|CPU"

# View metrics
curl http://localhost:8080/metrics | jq
```

### Advanced Monitoring with Prometheus & Grafana

```bash
# Install Docker and Docker Compose
curl -fsSL https://get.docker.com -o get-docker.sh
sudo sh get-docker.sh
sudo usermod -aG docker $USER

# Create monitoring stack
mkdir -p ~/monitoring
cd ~/monitoring

# Create docker-compose.yml
cat > docker-compose.yml <<'EOF'
version: '3.8'

services:
  prometheus:
    image: prom/prometheus:latest
    ports:
      - "9090:9090"
    volumes:
      - ./prometheus.yml:/etc/prometheus/prometheus.yml
      - prometheus_data:/prometheus
    command:
      - '--config.file=/etc/prometheus/prometheus.yml'
      - '--storage.tsdb.path=/prometheus'
    restart: unless-stopped

  grafana:
    image: grafana/grafana:latest
    ports:
      - "3000:3000"
    environment:
      - GF_SECURITY_ADMIN_PASSWORD=admin
    volumes:
      - grafana_data:/var/lib/grafana
    depends_on:
      - prometheus
    restart: unless-stopped

  node-exporter:
    image: prom/node-exporter:latest
    ports:
      - "9100:9100"
    restart: unless-stopped

volumes:
  prometheus_data:
  grafana_data:
EOF

# Create Prometheus config
cat > prometheus.yml <<'EOF'
global:
  scrape_interval: 15s

scrape_configs:
  - job_name: 'highconcurrency-server'
    static_configs:
      - targets: ['host.docker.internal:8080']
    metrics_path: '/metrics'

  - job_name: 'node-exporter'
    static_configs:
      - targets: ['node-exporter:9100']
EOF

# Start monitoring stack
docker-compose up -d

# Access Grafana at http://your-vps-ip:3000
# Default login: admin/admin
```

## 🔄 Deployment Automation

### CI/CD with GitHub Actions

Create `.github/workflows/deploy.yml`:

```yaml
name: Deploy to VPS

on:
  push:
    branches: [ main ]

jobs:
  deploy:
    runs-on: ubuntu-latest
    
    steps:
    - uses: actions/checkout@v3
    
    - name: Set up Go
      uses: actions/setup-go@v4
      with:
        go-version: '1.21'
    
    - name: Build
      run: |
        CGO_ENABLED=0 GOOS=linux go build -ldflags="-w -s" -o server main.go
    
    - name: Deploy to VPS
      uses: appleboy/scp-action@master
      with:
        host: ${{ secrets.VPS_HOST }}
        username: ${{ secrets.VPS_USER }}
        key: ${{ secrets.VPS_SSH_KEY }}
        source: "server"
        target: "/tmp/"
    
    - name: Restart Service
      uses: appleboy/ssh-action@master
      with:
        host: ${{ secrets.VPS_HOST }}
        username: ${{ secrets.VPS_USER }}
        key: ${{ secrets.VPS_SSH_KEY }}
        script: |
          sudo mv /tmp/server /opt/highconcurrency-server/
          sudo chown appuser:appuser /opt/highconcurrency-server/server
          sudo chmod +x /opt/highconcurrency-server/server
          sudo systemctl restart highconcurrency-server
          sleep 2
          sudo systemctl status highconcurrency-server
```

## 🧪 Testing Deployment

### Health Check

```bash
# Test health endpoint
curl http://your-vps-ip:8080/health

# With domain and SSL
curl https://your-domain.com/health
```

### Load Test

```bash
# Install ApacheBench
sudo apt install -y apache2-utils

# Run load test
ab -n 10000 -c 1000 http://your-vps-ip:8080/

# Or use the custom client
cd client
go build -o client client.go
./client -url=http://your-vps-ip:8080/ -requests=10000 -concurrency=1000
```

### Monitor During Load

```bash
# Terminal 1: Watch metrics
watch -n 1 'curl -s http://localhost:8080/metrics | jq'

# Terminal 2: Watch system resources
htop

# Terminal 3: Watch connections
watch -n 1 'netstat -an | grep :8080 | grep ESTABLISHED | wc -l'

# Terminal 4: Watch logs
sudo journalctl -u highconcurrency-server -f
```

## 🔒 Security Hardening

### Firewall Configuration

```bash
# Only allow necessary ports
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow 22/tcp
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw enable

# If using direct access to app (not recommended in production)
sudo ufw allow from YOUR_IP to any port 8080
```

### Fail2Ban for SSH Protection

```bash
sudo apt install -y fail2ban

sudo tee /etc/fail2ban/jail.local > /dev/null <<EOF
[sshd]
enabled = true
port = 22
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
bantime = 3600
EOF

sudo systemctl restart fail2ban
```

### Regular Updates

```bash
# Enable automatic security updates
sudo apt install -y unattended-upgrades
sudo dpkg-reconfigure --priority=low unattended-upgrades
```

## 📦 Backup Strategy

```bash
# Create backup script
sudo tee /usr/local/bin/backup-app.sh > /dev/null <<'EOF'
#!/bin/bash
BACKUP_DIR="/var/backups/highconcurrency-server"
DATE=$(date +%Y%m%d_%H%M%S)

mkdir -p $BACKUP_DIR

# Backup binary
cp /opt/highconcurrency-server/server $BACKUP_DIR/server_$DATE

# Backup config
cp /opt/highconcurrency-server/.env $BACKUP_DIR/.env_$DATE 2>/dev/null || true

# Keep only last 7 days
find $BACKUP_DIR -type f -mtime +7 -delete

echo "Backup completed: $DATE"
EOF

sudo chmod +x /usr/local/bin/backup-app.sh

# Add to crontab (daily at 2am)
(crontab -l 2>/dev/null; echo "0 2 * * * /usr/local/bin/backup-app.sh") | crontab -
```

## 🚨 Troubleshooting

### Service won't start

```bash
# Check service status
sudo systemctl status highconcurrency-server

# View detailed logs
sudo journalctl -u highconcurrency-server -n 100 --no-pager

# Check if port is already in use
sudo netstat -tlnp | grep :8080

# Check file permissions
ls -la /opt/highconcurrency-server/
```

### High memory usage

```bash
# Check current memory
free -h

# Monitor per-process memory
top -o %MEM

# Reduce max connections in .env
sudo nano /opt/highconcurrency-server/.env
# Set MAX_CONNECTIONS=50000

sudo systemctl restart highconcurrency-server
```

### Connection timeouts

```bash
# Check system limits
ulimit -n

# Check if limits are applied
cat /proc/$(pgrof -x server)/limits | grep "open files"

# Increase Nginx timeouts
sudo nano /etc/nginx/sites-available/highconcurrency-server
# Increase proxy_*_timeout values

sudo systemctl reload nginx
```

## 📚 Common Commands Reference

```bash
# Service Management
sudo systemctl start highconcurrency-server
sudo systemctl stop highconcurrency-server
sudo systemctl restart highconcurrency-server
sudo systemctl status highconcurrency-server
sudo systemctl reload highconcurrency-server  # If supported

# Logs
sudo journalctl -u highconcurrency-server -f          # Follow logs
sudo journalctl -u highconcurrency-server -n 100      # Last 100 lines
sudo journalctl -u highconcurrency-server --since today

# Nginx
sudo nginx -t                    # Test config
sudo systemctl reload nginx      # Reload config
sudo systemctl restart nginx     # Full restart

# Monitoring
curl http://localhost:8080/health
curl http://localhost:8080/metrics | jq
htop
netstat -tlnp | grep :8080
```

## 🎯 Production Checklist

- [ ] System limits configured (`ulimit -n`, `sysctl.conf`)
- [ ] Application user created (not running as root)
- [ ] Systemd service configured and enabled
- [ ] Nginx reverse proxy set up
- [ ] SSL certificate installed (Let's Encrypt)
- [ ] Firewall configured (UFW)
- [ ] Monitoring set up (logs, metrics, alerts)
- [ ] Backups automated
- [ ] Fail2Ban configured for SSH
- [ ] Load tested
- [ ] Health checks working
- [ ] Domain DNS configured
- [ ] Documentation updated

## 🚀 Scaling Beyond Single VPS

When you need more than one server:

1. **Horizontal Scaling**: Add more VPS instances behind a load balancer
2. **Load Balancer**: Use Nginx, HAProxy, or cloud load balancers
3. **Database**: Move to separate database server
4. **Session Storage**: Use Redis for shared sessions
5. **Container Orchestration**: Consider Kubernetes for managing multiple instances

You're ready for production! 🎉
