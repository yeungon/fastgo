.PHONY: help build run test clean docker docker-run benchmark install-deps setup-limits

# Variables
BINARY_NAME=server
CLIENT_BINARY=client
DOCKER_IMAGE=highconcurrency-server
PORT?=8080
WORKERS?=8

help: ## Show this help message
	@echo 'Usage: make [target]'
	@echo ''
	@echo 'Available targets:'
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "  %-15s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

install-deps: ## Install Go dependencies
	go mod download
	go mod verify

build: ## Build the server binary
	@echo "Building server..."
	CGO_ENABLED=0 go build -ldflags="-w -s" -o $(BINARY_NAME) main.go
	@echo "Build complete: $(BINARY_NAME)"

build-client: ## Build the test client
	@echo "Building client..."
	cd client && CGO_ENABLED=0 go build -ldflags="-w -s" -o $(CLIENT_BINARY) client.go
	@echo "Build complete: client/$(CLIENT_BINARY)"

run: build ## Build and run the server
	./$(BINARY_NAME)

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
