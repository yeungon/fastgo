.PHONY: help build build-web build-fiber build-all run run-both run-all run-compare test clean docker docker-run benchmark install-deps setup-limits deploy update k6-vps

# Variables
BINARY_NAME=server
WEB_BINARY=web-server
FIBER_BINARY=fiber-server
CLIENT_BINARY=client
DOCKER_IMAGE=highconcurrency-server
PORT?=8080
WEB_PORT?=8081
FIBER_PORT?=8082
WORKERS?=8

# VPS Deployment Configuration (customize these)
VPS_USER?=root
VPS_HOST?=your-vps-ip
VPS_APP_DIR?=/opt/highconcurrency-server
SERVICE_NAME?=highconcurrency-server

help: ## Show this help message
	@echo 'Usage: make [target]'
	@echo ''
	@echo 'Available targets:'
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "  %-15s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

install-deps: ## Install Go dependencies
	go mod download
	go mod verify

build: ## Build the worker pool server (fasthttp)
	@echo "Building worker pool server..."
	CGO_ENABLED=0 go build -ldflags="-w -s" -o $(BINARY_NAME) main.go
	@echo "Build complete: $(BINARY_NAME)"

build-web: ## Build the chi web server (net/http)
	@echo "Building chi web server..."
	CGO_ENABLED=0 go build -ldflags="-w -s" -o $(WEB_BINARY) ./cmd/web/main.go
	@echo "Build complete: $(WEB_BINARY)"

build-fiber: ## Build the Fiber server (fasthttp)
	@echo "Building Fiber server..."
	CGO_ENABLED=0 go build -ldflags="-w -s" -o $(FIBER_BINARY) ./cmd/fiber/main.go
	@echo "Build complete: $(FIBER_BINARY)"

build-all: build build-web build-fiber ## Build all three servers
	@echo "All servers built!"

build-client: ## Build the test client
	@echo "Building client..."
	cd client && CGO_ENABLED=0 go build -ldflags="-w -s" -o $(CLIENT_BINARY) client.go
	@echo "Build complete: client/$(CLIENT_BINARY)"

run: build ## Build and run the worker pool server
	./$(BINARY_NAME)

run-web: build-web ## Build and run the chi web server
	PORT=$(WEB_PORT) ./$(WEB_BINARY)

run-fiber: build-fiber ## Build and run the Fiber server
	./$(FIBER_BINARY)

run-both: build build-web ## Run Worker Pool + Chi servers for comparison
	@echo "Starting Worker Pool server on port 8080..."
	./$(BINARY_NAME) &
	@sleep 1
	@echo "Starting Chi Web server on port 8081..."
	PORT=8081 ./$(WEB_BINARY) &
	@echo ""
	@echo "Both servers running!"
	@echo "  Worker Pool: http://localhost:8080"
	@echo "  Chi Web:     http://localhost:8081"
	@echo "  Compare:     http://localhost:8080/compare"
	@echo ""
	@echo "Press Ctrl+C to stop"
	@wait

run-all: build-all ## Run all three servers for comparison
	@echo "Starting Worker Pool server on port 8080..."
	./$(BINARY_NAME) &
	@sleep 1
	@echo "Starting Chi Web server on port 8081..."
	PORT=8081 ./$(WEB_BINARY) &
	@sleep 1
	@echo "Starting Fiber server on port 8082..."
	./$(FIBER_BINARY) &
	@echo ""
	@echo "All three servers running!"
	@echo "  Worker Pool: http://localhost:8080"
	@echo "  Chi Web:     http://localhost:8081"
	@echo "  Fiber:       http://localhost:8082"
	@echo "  Compare (2): http://localhost:8080/compare"
	@echo "  Compare (3): http://localhost:8080/compare3"
	@echo ""
	@echo "Press Ctrl+C to stop"
	@wait

run-compare: run-both ## Alias for run-both (2-server comparison)

run-compare3: run-all ## Alias for run-all (3-server comparison)

stop-all: ## Stop all servers
	@pkill -f "$(BINARY_NAME)" 2>/dev/null || true
	@pkill -f "$(WEB_BINARY)" 2>/dev/null || true
	@pkill -f "$(FIBER_BINARY)" 2>/dev/null || true
	@echo "All servers stopped"

stop-both: stop-all ## Alias for stop-all

run-dev: ## Run with race detector for development
	go run -race main.go

test: ## Run tests
	go test -v -race -cover ./...

benchmark: build build-client ## Run benchmark test
	@echo "Starting server in background..."
	./$(BINARY_NAME) &
	@sleep 2
	@echo "Running benchmark..."
	cd client && ./$(CLIENT_BINARY) -requests=10000 -concurrency=1000
	@echo "Stopping server..."
	@pkill -SIGTERM $(BINARY_NAME) || true

benchmark-heavy: build build-client ## Run heavy benchmark (60K requests)
	@echo "Starting server in background..."
	./$(BINARY_NAME) &
	@sleep 2
	@echo "Running heavy benchmark (this will take a while)..."
	cd client && ./$(CLIENT_BINARY) -requests=60000 -concurrency=5000
	@echo "Stopping server..."
	@pkill -SIGTERM $(BINARY_NAME) || true

docker: ## Build Docker image
	docker build -t $(DOCKER_IMAGE):latest .

docker-run: docker ## Build and run Docker container
	docker run -p $(PORT):8080 \
		-e WORKERS=$(WORKERS) \
		--ulimit nofile=1000000:1000000 \
		$(DOCKER_IMAGE):latest

docker-compose-up: ## Start with docker-compose
	docker-compose up --build

docker-compose-down: ## Stop docker-compose services
	docker-compose down

clean: ## Clean build artifacts
	rm -f $(BINARY_NAME)
	rm -f $(WEB_BINARY)
	rm -f $(FIBER_BINARY)
	rm -f $(BINARY_NAME)-linux
	rm -f $(WEB_BINARY)-linux
	rm -f $(FIBER_BINARY)-linux
	rm -f client/$(CLIENT_BINARY)
	go clean

setup-limits: ## Setup system limits (requires sudo)
	@echo "Setting up system limits..."
	@echo "Current file descriptor limit:"
	@ulimit -n
	@echo ""
	@echo "To increase limits, add the following to /etc/security/limits.conf:"
	@echo "* soft nofile 1000000"
	@echo "* hard nofile 1000000"
	@echo ""
	@echo "For TCP port range, add to /etc/sysctl.conf:"
	@echo "net.ipv4.ip_local_port_range = 1024 65535"
	@echo ""
	@echo "Then run: sudo sysctl -p"

setup-limits-macos: ## Setup macOS limits (requires sudo)
	@echo "Setting up macOS limits..."
	sudo sysctl -w kern.maxfiles=1000000
	sudo sysctl -w kern.maxfilesperproc=1000000
	ulimit -S -n 1000000
	sudo sysctl -w net.inet.ip.portrange.first=1024
	sudo sysctl -w net.inet.ip.portrange.hifirst=1024
	@echo "Limits updated (temporary until reboot)"

install-systemd: build ## Install as systemd service (requires sudo)
	@echo "Installing systemd service..."
	sudo mkdir -p /opt/highconcurrency-server
	sudo cp $(BINARY_NAME) /opt/highconcurrency-server/
	sudo cp highconcurrency-server.service /etc/systemd/system/
	sudo systemctl daemon-reload
	@echo "Service installed. Use:"
	@echo "  sudo systemctl start highconcurrency-server"
	@echo "  sudo systemctl enable highconcurrency-server"

profile-cpu: ## Run with CPU profiling
	go build -o $(BINARY_NAME) main.go
	@echo "Starting server with profiling on :6060..."
	@echo "Access at http://localhost:6060/debug/pprof"
	./$(BINARY_NAME)

profile-mem: build build-client ## Profile memory usage
	@echo "Starting server..."
	./$(BINARY_NAME) &
	@sleep 2
	@echo "Running load test..."
	cd client && ./$(CLIENT_BINARY) -requests=10000 -concurrency=1000 &
	@sleep 5
	@echo "Taking heap snapshot..."
	go tool pprof -http=:8081 http://localhost:6060/debug/pprof/heap
	@pkill -SIGTERM $(BINARY_NAME) || true

lint: ## Run linter
	golangci-lint run ./...

fmt: ## Format code
	go fmt ./...
	goimports -w .

vet: ## Run go vet
	go vet ./...

all: fmt vet build test ## Run fmt, vet, build and test

watch: ## Watch for changes and rebuild (requires entr)
	find . -name '*.go' | entr -r make run

# ============================================
# VPS Deployment Commands
# ============================================

build-linux: ## Build main server for Linux (cross-compile)
	@echo "Building main server for Linux amd64..."
	CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -ldflags="-w -s" -o $(BINARY_NAME)-linux main.go
	@echo "Build complete: $(BINARY_NAME)-linux"

build-linux-all: ## Build all 3 servers for Linux (cross-compile)
	@echo "Building all servers for Linux amd64..."
	CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -ldflags="-w -s" -o $(BINARY_NAME)-linux main.go
	CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -ldflags="-w -s" -o $(WEB_BINARY)-linux ./cmd/web/main.go
	CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -ldflags="-w -s" -o $(FIBER_BINARY)-linux ./cmd/fiber/main.go
	@echo "Build complete: $(BINARY_NAME)-linux, $(WEB_BINARY)-linux, $(FIBER_BINARY)-linux"

deploy: build-linux ## Deploy main server to VPS (first time setup)
	@echo "Deploying to $(VPS_USER)@$(VPS_HOST)..."
	@echo "1. Uploading binary..."
	scp $(BINARY_NAME)-linux $(VPS_USER)@$(VPS_HOST):/tmp/$(BINARY_NAME)
	@echo "2. Setting up on VPS..."
	ssh $(VPS_USER)@$(VPS_HOST) '\
		sudo mkdir -p $(VPS_APP_DIR) && \
		sudo mv /tmp/$(BINARY_NAME) $(VPS_APP_DIR)/$(BINARY_NAME) && \
		sudo chmod +x $(VPS_APP_DIR)/$(BINARY_NAME) && \
		sudo chown -R appuser:appuser $(VPS_APP_DIR) 2>/dev/null || true && \
		(sudo systemctl restart $(SERVICE_NAME) 2>/dev/null || echo "Service not configured yet") && \
		echo "Deployment complete!"'
	@echo "✅ Deploy finished! Access: http://$(VPS_HOST):8080/dashboard"

deploy-all: build-linux-all ## Deploy all 3 servers to VPS
	@echo "🚀 Deploying all servers to $(VPS_USER)@$(VPS_HOST)..."
	@echo "📦 Uploading binaries..."
	scp $(BINARY_NAME)-linux $(WEB_BINARY)-linux $(FIBER_BINARY)-linux $(VPS_USER)@$(VPS_HOST):$(VPS_APP_DIR)/
	@echo "📁 Uploading static files..."
	ssh $(VPS_USER)@$(VPS_HOST) 'mkdir -p $(VPS_APP_DIR)/static'
	scp static/*.html $(VPS_USER)@$(VPS_HOST):$(VPS_APP_DIR)/static/
	@echo "✅ Deploy complete!"
	@echo ""
	@echo "To start all servers on VPS, run:"
	@echo "  make vps-start-all VPS_HOST=$(VPS_HOST)"

update: build-linux ## Update main server on VPS (quick update)
	@echo "🚀 Updating $(VPS_USER)@$(VPS_HOST)..."
	@echo "📦 Uploading new binary..."
	scp $(BINARY_NAME)-linux $(VPS_USER)@$(VPS_HOST):/tmp/$(BINARY_NAME)
	@echo "🔄 Restarting service..."
	ssh $(VPS_USER)@$(VPS_HOST) '\
		sudo mv /tmp/$(BINARY_NAME) $(VPS_APP_DIR)/$(BINARY_NAME) && \
		sudo chmod +x $(VPS_APP_DIR)/$(BINARY_NAME) && \
		sudo systemctl restart $(SERVICE_NAME) && \
		sleep 2 && \
		sudo systemctl status $(SERVICE_NAME) --no-pager | head -10'
	@echo ""
	@echo "✅ Update complete! Dashboard: http://$(VPS_HOST):8080/dashboard"

update-all: build-linux-all ## Update all 3 servers on VPS
	@echo "🚀 Updating all servers on $(VPS_USER)@$(VPS_HOST)..."
	@echo "📦 Uploading binaries..."
	scp $(BINARY_NAME)-linux $(WEB_BINARY)-linux $(FIBER_BINARY)-linux $(VPS_USER)@$(VPS_HOST):$(VPS_APP_DIR)/
	scp static/*.html $(VPS_USER)@$(VPS_HOST):$(VPS_APP_DIR)/static/
	@echo "🔄 Restarting servers..."
	ssh $(VPS_USER)@$(VPS_HOST) '\
		pkill -f "$(BINARY_NAME)-linux" || true && \
		pkill -f "$(WEB_BINARY)-linux" || true && \
		pkill -f "$(FIBER_BINARY)-linux" || true && \
		sleep 1 && \
		cd $(VPS_APP_DIR) && \
		nohup ./$(BINARY_NAME)-linux > server.log 2>&1 & \
		sleep 1 && \
		PORT=8081 nohup ./$(WEB_BINARY)-linux > web-server.log 2>&1 & \
		sleep 1 && \
		nohup ./$(FIBER_BINARY)-linux > fiber-server.log 2>&1 & \
		sleep 2 && \
		echo "Servers started!" && \
		curl -s localhost:8080/health && echo " - Worker Pool OK" && \
		curl -s localhost:8081/health && echo " - Chi Web OK" && \
		curl -s localhost:8082/health && echo " - Fiber OK"'
	@echo ""
	@echo "✅ Update complete!"
	@echo "  Dashboard: http://$(VPS_HOST):8080/compare3"

vps-build-all: ## Build all servers directly on VPS (requires Go on VPS)
	@echo "🔨 Building all servers on VPS..."
	ssh $(VPS_USER)@$(VPS_HOST) '\
		cd $(VPS_APP_DIR) && \
		git pull 2>/dev/null || true && \
		go build -ldflags="-w -s" -o $(BINARY_NAME) main.go && \
		go build -ldflags="-w -s" -o $(WEB_BINARY) ./cmd/web/main.go && \
		go build -ldflags="-w -s" -o $(FIBER_BINARY) ./cmd/fiber/main.go && \
		echo "Build complete!"'

vps-start-all: ## Start all 3 servers on VPS
	@echo "🚀 Starting all servers on VPS..."
	ssh $(VPS_USER)@$(VPS_HOST) '\
		cd $(VPS_APP_DIR) && \
		pkill -f "$(BINARY_NAME)" 2>/dev/null || true && \
		pkill -f "$(WEB_BINARY)" 2>/dev/null || true && \
		pkill -f "$(FIBER_BINARY)" 2>/dev/null || true && \
		sleep 1 && \
		nohup ./$(BINARY_NAME)-linux > server.log 2>&1 & \
		sleep 1 && \
		PORT=8081 nohup ./$(WEB_BINARY)-linux > web-server.log 2>&1 & \
		sleep 1 && \
		nohup ./$(FIBER_BINARY)-linux > fiber-server.log 2>&1 & \
		sleep 2 && \
		ufw allow 8081/tcp 2>/dev/null || true && \
		ufw allow 8082/tcp 2>/dev/null || true && \
		echo "" && \
		echo "=== Server Health ===" && \
		curl -s localhost:8080/health && echo " - Worker Pool (8080) OK" && \
		curl -s localhost:8081/health && echo " - Chi Web (8081) OK" && \
		curl -s localhost:8082/health && echo " - Fiber (8082) OK"'
	@echo ""
	@echo "✅ All servers started!"
	@echo "  Compare Dashboard: http://$(VPS_HOST):8080/compare3"

vps-stop-all: ## Stop all 3 servers on VPS
	@echo "🛑 Stopping all servers on VPS..."
	ssh $(VPS_USER)@$(VPS_HOST) '\
		pkill -f "$(BINARY_NAME)" 2>/dev/null || true && \
		pkill -f "$(WEB_BINARY)" 2>/dev/null || true && \
		pkill -f "$(FIBER_BINARY)" 2>/dev/null || true && \
		echo "All servers stopped"'

vps-status-all: ## Check status of all 3 servers on VPS
	@ssh $(VPS_USER)@$(VPS_HOST) '\
		echo "=== Process Status ===" && \
		ps aux | grep -E "(server|web-server|fiber-server)" | grep -v grep || echo "No servers running" && \
		echo "" && \
		echo "=== Health Checks ===" && \
		(curl -s localhost:8080/health 2>/dev/null && echo " - Worker Pool (8080) OK") || echo "❌ Worker Pool (8080) DOWN" && \
		(curl -s localhost:8081/health 2>/dev/null && echo " - Chi Web (8081) OK") || echo "❌ Chi Web (8081) DOWN" && \
		(curl -s localhost:8082/health 2>/dev/null && echo " - Fiber (8082) OK") || echo "❌ Fiber (8082) DOWN"'

update-from-git: ## Update VPS by pulling from git (run on VPS)
	@echo "Updating from git repository..."
	ssh $(VPS_USER)@$(VPS_HOST) '\
		cd ~/highconcurrency-server && \
		git pull origin main && \
		go build -ldflags="-w -s" -o server main.go && \
		sudo cp server $(VPS_APP_DIR)/ && \
		sudo systemctl restart $(SERVICE_NAME) && \
		echo "Update complete!"'

vps-status: ## Check VPS service status (systemd)
	@ssh $(VPS_USER)@$(VPS_HOST) '\
		echo "=== Service Status ===" && \
		sudo systemctl status $(SERVICE_NAME) --no-pager | head -15 && \
		echo "" && \
		echo "=== Health Check ===" && \
		curl -s http://localhost:8080/health && \
		echo "" && \
		echo "" && \
		echo "=== Metrics ===" && \
		curl -s http://localhost:8080/metrics | head -c 500'

vps-logs: ## View VPS service logs
	@ssh $(VPS_USER)@$(VPS_HOST) 'sudo journalctl -u $(SERVICE_NAME) -f'

vps-logs-all: ## View logs of all 3 servers on VPS
	@ssh $(VPS_USER)@$(VPS_HOST) '\
		cd $(VPS_APP_DIR) && \
		echo "=== Worker Pool Log (last 20 lines) ===" && \
		tail -20 server.log 2>/dev/null || echo "No log file" && \
		echo "" && \
		echo "=== Chi Web Log (last 20 lines) ===" && \
		tail -20 web-server.log 2>/dev/null || echo "No log file" && \
		echo "" && \
		echo "=== Fiber Log (last 20 lines) ===" && \
		tail -20 fiber-server.log 2>/dev/null || echo "No log file"'

vps-restart: ## Restart VPS service
	@ssh $(VPS_USER)@$(VPS_HOST) 'sudo systemctl restart $(SERVICE_NAME)'
	@echo "Service restarted"

vps-stop: ## Stop VPS service
	@ssh $(VPS_USER)@$(VPS_HOST) 'sudo systemctl stop $(SERVICE_NAME)'
	@echo "Service stopped"

vps-firewall: ## Open firewall ports 8080, 8081, 8082 on VPS
	@echo "Opening firewall ports..."
	ssh $(VPS_USER)@$(VPS_HOST) '\
		ufw allow 8080/tcp && \
		ufw allow 8081/tcp && \
		ufw allow 8082/tcp && \
		ufw status | grep -E "8080|8081|8082"'
	@echo "Firewall configured"

# ============================================
# K6 Load Testing Commands (from localhost to VPS)
# ============================================

k6-vps: ## Run k6 load test against VPS (all 3 servers simultaneously)
	@echo "🚀 Running k6 load tests against VPS..."
	@echo "   Target: $(VPS_HOST)"
	@echo "   Duration: 30s, VUs: 100"
	@echo ""
	k6 run --duration 30s --vus 100 loadtest/k6-quick.js --env TARGET_URL=http://$(VPS_HOST):8080 &
	k6 run --duration 30s --vus 100 loadtest/k6-quick.js --env TARGET_URL=http://$(VPS_HOST):8081 &
	k6 run --duration 30s --vus 100 loadtest/k6-quick.js --env TARGET_URL=http://$(VPS_HOST):8082 &
	@echo ""
	@echo "📊 View dashboard: http://$(VPS_HOST):8080/compare3"

k6-vps-stress: ## Run k6 stress test against VPS (500 VUs)
	@echo "🔥 Running k6 STRESS tests against VPS..."
	@echo "   Target: $(VPS_HOST)"
	@echo "   Duration: 60s, VUs: 500"
	@echo ""
	k6 run --duration 60s --vus 500 loadtest/k6-quick.js --env TARGET_URL=http://$(VPS_HOST):8080 &
	k6 run --duration 60s --vus 500 loadtest/k6-quick.js --env TARGET_URL=http://$(VPS_HOST):8081 &
	k6 run --duration 60s --vus 500 loadtest/k6-quick.js --env TARGET_URL=http://$(VPS_HOST):8082 &
	@echo ""
	@echo "📊 View dashboard: http://$(VPS_HOST):8080/compare3"

k6-vps-1000: ## Run k6 test with 1000 concurrent connections
	@echo "🔥 Running k6 with 1000 VUs against VPS..."
	@echo "   Target: $(VPS_HOST)"
	@echo "   Duration: 60s, VUs: 1000"
	@echo ""
	k6 run --duration 60s --vus 1000 loadtest/k6-quick.js --env TARGET_URL=http://$(VPS_HOST):8080 &
	k6 run --duration 60s --vus 1000 loadtest/k6-quick.js --env TARGET_URL=http://$(VPS_HOST):8081 &
	k6 run --duration 60s --vus 1000 loadtest/k6-quick.js --env TARGET_URL=http://$(VPS_HOST):8082 &
	@echo ""
	@echo "📊 View dashboard: http://$(VPS_HOST):8080/compare3"

k6-vps-2000: ## Run k6 test with 2000 concurrent connections (student registration simulation)
	@echo "🔥 Running k6 with 2000 VUs against VPS..."
	@echo "   Target: $(VPS_HOST)"
	@echo "   Duration: 120s, VUs: 2000"
	@echo ""
	k6 run --duration 120s --vus 2000 loadtest/k6-quick.js --env TARGET_URL=http://$(VPS_HOST):8080 &
	k6 run --duration 120s --vus 2000 loadtest/k6-quick.js --env TARGET_URL=http://$(VPS_HOST):8081 &
	k6 run --duration 120s --vus 2000 loadtest/k6-quick.js --env TARGET_URL=http://$(VPS_HOST):8082 &
	@echo ""
	@echo "📊 View dashboard: http://$(VPS_HOST):8080/compare3"

k6-vps-single: ## Run k6 test against VPS (single server - Worker Pool only)
	@echo "🚀 Running k6 load test against VPS Worker Pool..."
	k6 run --duration 30s --vus 100 loadtest/k6-quick.js --env TARGET_URL=http://$(VPS_HOST):8080

k6-vps-custom: ## Run k6 with custom VUs and duration (VUS=100 DURATION=30s make k6-vps-custom)
	@echo "🚀 Running custom k6 load test against VPS..."
	@echo "   VUS=$(VUS) DURATION=$(DURATION)"
	k6 run --duration $(DURATION) --vus $(VUS) loadtest/k6-quick.js --env TARGET_URL=http://$(VPS_HOST):8080 &
	k6 run --duration $(DURATION) --vus $(VUS) loadtest/k6-quick.js --env TARGET_URL=http://$(VPS_HOST):8081 &
	k6 run --duration $(DURATION) --vus $(VUS) loadtest/k6-quick.js --env TARGET_URL=http://$(VPS_HOST):8082 &
