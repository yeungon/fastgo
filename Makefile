.PHONY: help build build-web build-all run run-both run-compare test clean docker docker-run benchmark install-deps setup-limits deploy update

# Variables
BINARY_NAME=server
WEB_BINARY=web-server
CLIENT_BINARY=client
DOCKER_IMAGE=highconcurrency-server
PORT?=8080
WEB_PORT?=8081
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

build-all: build build-web ## Build both servers
	@echo "Both servers built!"

build-client: ## Build the test client
	@echo "Building client..."
	cd client && CGO_ENABLED=0 go build -ldflags="-w -s" -o $(CLIENT_BINARY) client.go
	@echo "Build complete: client/$(CLIENT_BINARY)"

run: build ## Build and run the worker pool server
	./$(BINARY_NAME)

run-web: build-web ## Build and run the chi web server
	PORT=$(WEB_PORT) ./$(WEB_BINARY)

run-both: build-all ## Run both servers for comparison
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

run-compare: run-both ## Alias for run-both

stop-both: ## Stop both servers
	@pkill -f "$(BINARY_NAME)" 2>/dev/null || true
	@pkill -f "$(WEB_BINARY)" 2>/dev/null || true
	@echo "Servers stopped"

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
	rm -f $(BINARY_NAME)-linux
	rm -f $(WEB_BINARY)-linux
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

build-linux: ## Build binary for Linux (cross-compile)
	@echo "Building for Linux amd64..."
	CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -ldflags="-w -s" -o $(BINARY_NAME)-linux main.go
	@echo "Build complete: $(BINARY_NAME)-linux"

deploy: build-linux ## Deploy to VPS (first time setup)
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

update: build-linux ## Update existing VPS deployment (quick update)
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

update-from-git: ## Update VPS by pulling from git (run on VPS)
	@echo "Updating from git repository..."
	ssh $(VPS_USER)@$(VPS_HOST) '\
		cd ~/highconcurrency-server && \
		git pull origin main && \
		go build -ldflags="-w -s" -o server main.go && \
		sudo cp server $(VPS_APP_DIR)/ && \
		sudo systemctl restart $(SERVICE_NAME) && \
		echo "Update complete!"'

vps-status: ## Check VPS service status
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

vps-restart: ## Restart VPS service
	@ssh $(VPS_USER)@$(VPS_HOST) 'sudo systemctl restart $(SERVICE_NAME)'
	@echo "Service restarted"

vps-stop: ## Stop VPS service
	@ssh $(VPS_USER)@$(VPS_HOST) 'sudo systemctl stop $(SERVICE_NAME)'
	@echo "Service stopped"
