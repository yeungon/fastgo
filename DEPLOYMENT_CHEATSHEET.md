# VPS Deployment Quick Reference

## 🚀 One-Line Deploy

```bash
curl -sSL https://raw.githubusercontent.com/YOUR_REPO/deploy.sh | sudo bash
```

## 📋 Manual Deploy Commands

### 1. Initial Setup
```bash
# Update system
sudo apt update && sudo apt upgrade -y

# Install Go
wget https://go.dev/dl/go1.21.6.linux-amd64.tar.gz
sudo tar -C /usr/local -xzf go1.21.6.linux-amd64.tar.gz
echo 'export PATH=$PATH:/usr/local/go/bin' | sudo tee -a /etc/profile

# Configure limits
sudo tee -a /etc/security/limits.conf <<EOF
* soft nofile 1000000
* hard nofile 1000000
EOF

sudo tee -a /etc/sysctl.conf <<EOF
net.ipv4.ip_local_port_range = 1024 65535
net.core.somaxconn = 65535
EOF
sudo sysctl -p
```

### 2. Deploy App
```bash
# Create user and directories
sudo useradd -m -s /bin/bash appuser
sudo mkdir -p /opt/highconcurrency-server
sudo mkdir -p /var/log/highconcurrency-server

# Build and deploy
git clone YOUR_REPO
cd highconcurrency-server
go build -o server main.go
sudo cp server /opt/highconcurrency-server/
sudo chown -R appuser:appuser /opt/highconcurrency-server
```

### 3. Create Service
```bash
# Create systemd service
sudo nano /etc/systemd/system/highconcurrency-server.service
# (Paste service file content from VPS_DEPLOYMENT.md)

# Enable and start
sudo systemctl daemon-reload
sudo systemctl enable highconcurrency-server
sudo systemctl start highconcurrency-server
```

### 4. Setup Nginx (Optional)
```bash
sudo apt install -y nginx
sudo nano /etc/nginx/sites-available/highconcurrency-server
# (Paste nginx config from VPS_DEPLOYMENT.md)

sudo ln -s /etc/nginx/sites-available/highconcurrency-server /etc/nginx/sites-enabled/
sudo nginx -t
sudo systemctl restart nginx
```

### 5. SSL with Let's Encrypt
```bash
sudo apt install -y certbot python3-certbot-nginx
sudo certbot --nginx -d your-domain.com
```

## 🔧 Common Operations

### Service Management
```bash
sudo systemctl start highconcurrency-server     # Start
sudo systemctl stop highconcurrency-server      # Stop
sudo systemctl restart highconcurrency-server   # Restart
sudo systemctl status highconcurrency-server    # Status
```

### Logs
```bash
sudo journalctl -u highconcurrency-server -f    # Follow logs
sudo journalctl -u highconcurrency-server -n 100  # Last 100 lines
```

### Monitoring
```bash
curl http://localhost:8080/health               # Health check
curl http://localhost:8080/metrics | jq         # Metrics
htop                                            # System resources
netstat -tlnp | grep :8080                      # Check port
```

### Updates
```bash
# Build new binary
cd ~/highconcurrency-server
git pull
go build -o server main.go

# Deploy
sudo cp server /opt/highconcurrency-server/
sudo systemctl restart highconcurrency-server
```

## 🔒 Security Checklist
- [ ] UFW firewall enabled
- [ ] SSH key authentication (disable password)
- [ ] Non-root user for application
- [ ] Fail2ban installed
- [ ] SSL certificate installed
- [ ] Regular updates enabled

## 📊 Performance Tuning

### Adjust Workers
```bash
# Edit environment
sudo nano /opt/highconcurrency-server/.env
# Set: WORKERS=16

sudo systemctl restart highconcurrency-server
```

### Monitor Performance
```bash
# CPU usage
top -bn1 | grep "Cpu(s)"

# Memory usage
free -h

# Active connections
netstat -an | grep :8080 | grep ESTABLISHED | wc -l

# File descriptors
lsof -p $(pgrof -x server) | wc -l
```

## 🚨 Troubleshooting

### Service won't start
```bash
sudo systemctl status highconcurrency-server
sudo journalctl -u highconcurrency-server -n 100
```

### Port already in use
```bash
sudo lsof -i :8080
sudo kill -9 PID
```

### Out of file descriptors
```bash
ulimit -n
# Should show 1000000
# If not, reboot or check /etc/security/limits.conf
```

### High memory usage
```bash
# Reduce max connections
sudo nano /opt/highconcurrency-server/.env
# Set: MAX_CONNECTIONS=50000
sudo systemctl restart highconcurrency-server
```

## 📡 Cloud Provider Quick Starts

### DigitalOcean
```bash
# Create droplet (Ubuntu 22.04, 2GB RAM minimum)
# SSH into droplet
curl -sSL https://YOUR_DEPLOY_SCRIPT | sudo bash
```

### AWS EC2
```bash
# Launch t3.small or larger
# Security Group: Allow 22, 80, 443
# SSH into instance
curl -sSL https://YOUR_DEPLOY_SCRIPT | sudo bash
```

### Linode
```bash
# Create Linode (2GB RAM minimum)
# SSH into server
curl -sSL https://YOUR_DEPLOY_SCRIPT | sudo bash
```

### Vultr
```bash
# Deploy instance (Ubuntu 22.04, $12/mo minimum)
# SSH into server
curl -sSL https://YOUR_DEPLOY_SCRIPT | sudo bash
```

## 🎯 Load Testing

### Quick Test
```bash
# Install ab
sudo apt install apache2-utils

# Run test
ab -n 10000 -c 1000 http://localhost:8080/
```

### Heavy Test (60K concurrent)
```bash
# Build client
cd client
go build -o client client.go

# Run heavy test
./client -requests=60000 -concurrency=5000
```

## 💾 Backup & Recovery

### Backup
```bash
# Create backup
sudo cp /opt/highconcurrency-server/server /root/server.backup
sudo cp /opt/highconcurrency-server/.env /root/.env.backup
```

### Restore
```bash
# Restore from backup
sudo cp /root/server.backup /opt/highconcurrency-server/server
sudo cp /root/.env.backup /opt/highconcurrency-server/.env
sudo systemctl restart highconcurrency-server
```

## 📞 Support Resources

- Documentation: See VPS_DEPLOYMENT.md
- Advanced Patterns: See ADVANCED_PATTERNS.md
- GitHub Issues: YOUR_REPO/issues
- Server Status: `curl http://localhost:8080/metrics`
