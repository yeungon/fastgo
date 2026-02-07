package main

import (
	"bufio"
	"context"
	"embed"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"os/signal"
	"runtime"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/valyala/fasthttp"
)

//go:embed static/*
var staticFiles embed.FS

// Configuration holds server settings
type Configuration struct {
	Port            string
	ReadTimeout     time.Duration
	WriteTimeout    time.Duration
	IdleTimeout     time.Duration
	MaxWorkers      int
	WorkerQueueSize int
	ShutdownTimeout time.Duration
	EnableMetrics   bool
	MaxConnections  int
}

// Metrics tracks server statistics
type Metrics struct {
	activeConnections int64
	totalRequests     int64
	completedRequests int64
	errorCount        int64
	startTime         time.Time
	mu                sync.RWMutex
}

// WorkerPool manages concurrent request processing
type WorkerPool struct {
	workers  int
	jobQueue chan Job
	wg       sync.WaitGroup
	ctx      context.Context
	cancel   context.CancelFunc
}

// Job represents a unit of work
type Job struct {
	RequestID string
	Data      interface{}
	ResultCh  chan JobResult
}

// JobResult contains the job execution result
type JobResult struct {
	Data  interface{}
	Error error
}

// Server encapsulates the HTTP server with worker pool
type Server struct {
	config     *Configuration
	metrics    *Metrics
	workerPool *WorkerPool
}

// NewConfiguration creates default configuration
func NewConfiguration() *Configuration {
	return &Configuration{
		Port:            ":8080",
		ReadTimeout:     15 * time.Second,
		WriteTimeout:    15 * time.Second,
		IdleTimeout:     60 * time.Second,
		MaxWorkers:      runtime.NumCPU() * 2, // 2x CPU cores
		WorkerQueueSize: 10000,
		ShutdownTimeout: 30 * time.Second,
		EnableMetrics:   true,
		MaxConnections:  100000,
	}
}

// NewMetrics initializes metrics
func NewMetrics() *Metrics {
	return &Metrics{
		startTime: time.Now(),
	}
}

// IncrementActive atomically increments active connections
func (m *Metrics) IncrementActive() {
	atomic.AddInt64(&m.activeConnections, 1)
	atomic.AddInt64(&m.totalRequests, 1)
}

// DecrementActive atomically decrements active connections
func (m *Metrics) DecrementActive() {
	atomic.AddInt64(&m.activeConnections, -1)
	atomic.AddInt64(&m.completedRequests, 1)
}

// IncrementErrors atomically increments error count
func (m *Metrics) IncrementErrors() {
	atomic.AddInt64(&m.errorCount, 1)
}

// GetStats returns current metrics snapshot
func (m *Metrics) GetStats() map[string]interface{} {
	uptime := time.Since(m.startTime).Seconds()
	completed := atomic.LoadInt64(&m.completedRequests)

	var memStats runtime.MemStats
	runtime.ReadMemStats(&memStats)

	return map[string]interface{}{
		"active_connections": atomic.LoadInt64(&m.activeConnections),
		"total_requests":     atomic.LoadInt64(&m.totalRequests),
		"completed_requests": completed,
		"error_count":        atomic.LoadInt64(&m.errorCount),
		"uptime_seconds":     uptime,
		"requests_per_sec":   float64(completed) / uptime,
		"memory_alloc_mb":    memStats.Alloc / 1024 / 1024,
		"memory_sys_mb":      memStats.Sys / 1024 / 1024,
		"num_goroutines":     runtime.NumGoroutine(),
		"num_gc":             memStats.NumGC,
	}
}

// NewWorkerPool creates a new worker pool
func NewWorkerPool(ctx context.Context, workers, queueSize int) *WorkerPool {
	poolCtx, cancel := context.WithCancel(ctx)

	pool := &WorkerPool{
		workers:  workers,
		jobQueue: make(chan Job, queueSize),
		ctx:      poolCtx,
		cancel:   cancel,
	}

	pool.start()
	return pool
}

// start initializes and starts worker goroutines
func (wp *WorkerPool) start() {
	for i := 0; i < wp.workers; i++ {
		wp.wg.Add(1)
		go wp.worker(i)
	}
	log.Printf("Started %d workers", wp.workers)
}

// worker processes jobs from the queue
func (wp *WorkerPool) worker(id int) {
	defer wp.wg.Done()

	log.Printf("Worker %d started", id)

	for {
		select {
		case <-wp.ctx.Done():
			log.Printf("Worker %d shutting down", id)
			return
		case job, ok := <-wp.jobQueue:
			if !ok {
				log.Printf("Worker %d: job queue closed", id)
				return
			}

			// Process the job
			result := wp.processJob(job)

			// Send result back if channel is provided
			if job.ResultCh != nil {
				select {
				case job.ResultCh <- result:
				case <-wp.ctx.Done():
					return
				}
			}
		}
	}
}

// processJob executes the actual job logic
func (wp *WorkerPool) processJob(job Job) JobResult {
	// Simulate CPU-intensive work (like the article's hash computation)
	// In production, this would be your actual business logic:
	// - Database queries
	// - API calls
	// - Data processing
	// - etc.

	time.Sleep(100 * time.Millisecond) // Simulate work

	return JobResult{
		Data: map[string]interface{}{
			"request_id": job.RequestID,
			"processed":  true,
			"timestamp":  time.Now().Unix(),
		},
		Error: nil,
	}
}

// Submit adds a job to the worker pool
func (wp *WorkerPool) Submit(job Job) error {
	select {
	case wp.jobQueue <- job:
		return nil
	case <-wp.ctx.Done():
		return fmt.Errorf("worker pool is shutting down")
	default:
		return fmt.Errorf("worker queue is full")
	}
}

// Shutdown gracefully stops the worker pool
func (wp *WorkerPool) Shutdown() {
	log.Println("Shutting down worker pool...")
	wp.cancel()
	close(wp.jobQueue)
	wp.wg.Wait()
	log.Println("Worker pool shutdown complete")
}

// NewServer creates a new server instance
func NewServer(config *Configuration) *Server {
	return &Server{
		config:  config,
		metrics: NewMetrics(),
	}
}

// handleRequest processes incoming HTTP requests using fasthttp
func (s *Server) handleRequest(ctx *fasthttp.RequestCtx) {
	s.metrics.IncrementActive()
	defer s.metrics.DecrementActive()

	// Extract request ID
	requestID := string(ctx.Request.Header.Peek("X-Request-ID"))
	if requestID == "" {
		requestID = fmt.Sprintf("%d", time.Now().UnixNano())
	}

	// Create result channel
	resultCh := make(chan JobResult, 1)

	// Submit job to worker pool
	job := Job{
		RequestID: requestID,
		Data:      string(ctx.Request.Body()),
		ResultCh:  resultCh,
	}

	err := s.workerPool.Submit(job)
	if err != nil {
		s.metrics.IncrementErrors()
		ctx.Error("Server overloaded", fasthttp.StatusServiceUnavailable)
		return
	}

	// Wait for result with timeout
	select {
	case result := <-resultCh:
		if result.Error != nil {
			s.metrics.IncrementErrors()
			ctx.Error(result.Error.Error(), fasthttp.StatusInternalServerError)
			return
		}

		// Send JSON response
		ctx.Response.Header.Set("Content-Type", "application/json")
		json.NewEncoder(ctx).Encode(result.Data)

	case <-time.After(30 * time.Second):
		s.metrics.IncrementErrors()
		ctx.Error("Request timeout", fasthttp.StatusRequestTimeout)
	}
}

// handleMetrics serves metrics endpoint
func (s *Server) handleMetrics(ctx *fasthttp.RequestCtx) {
	stats := s.metrics.GetStats()
	ctx.Response.Header.Set("Content-Type", "application/json")
	json.NewEncoder(ctx).Encode(stats)
}

// handleHealth serves health check endpoint
func (s *Server) handleHealth(ctx *fasthttp.RequestCtx) {
	ctx.Response.Header.Set("Content-Type", "application/json")
	json.NewEncoder(ctx).Encode(map[string]string{
		"status": "healthy",
		"time":   time.Now().Format(time.RFC3339),
	})
}

// handleDashboard serves the monitoring dashboard
func (s *Server) handleDashboard(ctx *fasthttp.RequestCtx) {
	content, err := staticFiles.ReadFile("static/dashboard.html")
	if err != nil {
		ctx.Error("Dashboard not found", fasthttp.StatusNotFound)
		return
	}
	ctx.Response.Header.Set("Content-Type", "text/html; charset=utf-8")
	ctx.Write(content)
}

// handleCompare serves the comparison dashboard (both servers)
func (s *Server) handleCompare(ctx *fasthttp.RequestCtx) {
	content, err := staticFiles.ReadFile("static/compare.html")
	if err != nil {
		ctx.Error("Compare dashboard not found", fasthttp.StatusNotFound)
		return
	}
	ctx.Response.Header.Set("Content-Type", "text/html; charset=utf-8")
	ctx.Write(content)
}

// handleSSEMetrics streams metrics via Server-Sent Events
func (s *Server) handleSSEMetrics(ctx *fasthttp.RequestCtx) {
	ctx.Response.Header.Set("Content-Type", "text/event-stream")
	ctx.Response.Header.Set("Cache-Control", "no-cache")
	ctx.Response.Header.Set("Connection", "keep-alive")
	ctx.Response.Header.Set("Access-Control-Allow-Origin", "*")

	// Set streaming mode
	ctx.SetBodyStreamWriter(func(w *bufio.Writer) {
		ticker := time.NewTicker(1 * time.Second)
		defer ticker.Stop()

		for {
			select {
			case <-ticker.C:
				stats := s.metrics.GetStats()
				data, err := json.Marshal(stats)
				if err != nil {
					continue
				}

				// Write SSE format
				fmt.Fprintf(w, "data: %s\n\n", data)
				if err := w.Flush(); err != nil {
					// Client disconnected
					return
				}
			}
		}
	})
}

// router handles request routing
func (s *Server) router(ctx *fasthttp.RequestCtx) {
	path := string(ctx.Path())

	switch path {
	case "/":
		s.handleRequest(ctx)
	case "/dashboard":
		s.handleDashboard(ctx)
	case "/compare":
		s.handleCompare(ctx)
	case "/sse/metrics":
		s.handleSSEMetrics(ctx)
	case "/metrics":
		s.handleMetrics(ctx)
	case "/health":
		s.handleHealth(ctx)
	default:
		ctx.Error("Not found", fasthttp.StatusNotFound)
	}
}

// Start begins the HTTP server
func (s *Server) Start(ctx context.Context) error {
	// Initialize worker pool
	s.workerPool = NewWorkerPool(ctx, s.config.MaxWorkers, s.config.WorkerQueueSize)

	// Configure fasthttp server
	server := &fasthttp.Server{
		Handler:      s.router,
		ReadTimeout:  s.config.ReadTimeout,
		WriteTimeout: s.config.WriteTimeout,
		IdleTimeout:  s.config.IdleTimeout,
		Concurrency:  s.config.MaxConnections,
		Name:         "HighConcurrencyServer/1.0",
	}

	// Start metrics logger
	if s.config.EnableMetrics {
		go s.logMetrics(ctx)
	}

	log.Printf("Server starting on %s", s.config.Port)
	log.Printf("Workers: %d, Queue size: %d, Max connections: %d",
		s.config.MaxWorkers, s.config.WorkerQueueSize, s.config.MaxConnections)

	// Start server in goroutine
	errCh := make(chan error, 1)
	go func() {
		if err := server.ListenAndServe(s.config.Port); err != nil {
			errCh <- err
		}
	}()

	// Wait for shutdown signal or error
	select {
	case err := <-errCh:
		return err
	case <-ctx.Done():
		log.Println("Shutdown signal received")

		// Graceful shutdown
		shutdownCtx, cancel := context.WithTimeout(context.Background(), s.config.ShutdownTimeout)
		defer cancel()

		if err := server.ShutdownWithContext(shutdownCtx); err != nil {
			log.Printf("Server shutdown error: %v", err)
		}

		s.workerPool.Shutdown()
		log.Println("Server stopped gracefully")
		return nil
	}
}

// logMetrics periodically logs server metrics
func (s *Server) logMetrics(ctx context.Context) {
	ticker := time.NewTicker(5 * time.Second)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			stats := s.metrics.GetStats()
			log.Printf("METRICS: Active=%d, Total=%d, Completed=%d, RPS=%.2f, Mem=%dMB, Goroutines=%d",
				stats["active_connections"],
				stats["total_requests"],
				stats["completed_requests"],
				stats["requests_per_sec"],
				stats["memory_alloc_mb"],
				stats["num_goroutines"])
		}
	}
}

func main() {
	// Create configuration
	config := NewConfiguration()

	// Override from environment variables if needed
	if port := os.Getenv("PORT"); port != "" {
		config.Port = ":" + port
	}
	if workers := os.Getenv("WORKERS"); workers != "" {
		fmt.Sscanf(workers, "%d", &config.MaxWorkers)
	}

	// Create server
	server := NewServer(config)

	// Setup graceful shutdown
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	// Handle shutdown signals
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, os.Interrupt, syscall.SIGTERM)

	go func() {
		<-sigCh
		log.Println("Received shutdown signal")
		cancel()
	}()

	// Start server
	if err := server.Start(ctx); err != nil {
		log.Fatalf("Server error: %v", err)
	}
}
