package main

import (
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"runtime"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/go-chi/chi/v5/middleware"
)

// Metrics tracks server statistics for normal web server
type Metrics struct {
	activeConnections int64
	totalRequests     int64
	completedRequests int64
	errorCount        int64
	startTime         time.Time
	lastCPUTime       time.Time
	lastCPUUsage      float64
}

var metrics = &Metrics{
	startTime:   time.Now(),
	lastCPUTime: time.Now(),
}

func (m *Metrics) IncrementActive() {
	atomic.AddInt64(&m.activeConnections, 1)
	atomic.AddInt64(&m.totalRequests, 1)
}

func (m *Metrics) DecrementActive() {
	atomic.AddInt64(&m.activeConnections, -1)
	atomic.AddInt64(&m.completedRequests, 1)
}

func (m *Metrics) IncrementErrors() {
	atomic.AddInt64(&m.errorCount, 1)
}

// getCPUUsage calculates approximate CPU usage based on goroutines and work
func getCPUUsage() float64 {
	numCPU := runtime.NumCPU()
	numGoroutines := runtime.NumGoroutine()

	// Approximate CPU usage based on goroutines vs available CPUs
	// This is a rough estimate - real CPU monitoring would require OS-level tools
	usage := float64(numGoroutines) / float64(numCPU*10) * 100
	if usage > 100 {
		usage = 100
	}
	return usage
}

func (m *Metrics) GetStats() map[string]interface{} {
	uptime := time.Since(m.startTime).Seconds()
	completed := atomic.LoadInt64(&m.completedRequests)
	active := atomic.LoadInt64(&m.activeConnections)
	total := atomic.LoadInt64(&m.totalRequests)
	errors := atomic.LoadInt64(&m.errorCount)

	var memStats runtime.MemStats
	runtime.ReadMemStats(&memStats)

	// Calculate requests per second (recent)
	rps := float64(0)
	if uptime > 0 {
		rps = float64(completed) / uptime
	}

	// Calculate error rate
	errorRate := float64(0)
	if total > 0 {
		errorRate = float64(errors) / float64(total) * 100
	}

	// Get CPU usage estimate
	cpuUsage := getCPUUsage()

	return map[string]interface{}{
		// Server info
		"server_type": "chi-web",
		"num_cpu":     runtime.NumCPU(),

		// Request metrics
		"active_connections": active,
		"total_requests":     total,
		"completed_requests": completed,
		"error_count":        errors,
		"error_rate_percent": errorRate,

		// Performance metrics
		"uptime_seconds":    uptime,
		"requests_per_sec":  rps,
		"cpu_usage_percent": cpuUsage,

		// Memory metrics (in MB for easier reading)
		"memory_alloc_mb":     float64(memStats.Alloc) / 1024 / 1024,
		"memory_sys_mb":       float64(memStats.Sys) / 1024 / 1024,
		"memory_heap_mb":      float64(memStats.HeapAlloc) / 1024 / 1024,
		"memory_stack_mb":     float64(memStats.StackInuse) / 1024 / 1024,
		"memory_heap_objects": memStats.HeapObjects,

		// GC metrics
		"num_gc":            memStats.NumGC,
		"gc_pause_total_ms": float64(memStats.PauseTotalNs) / 1e6,
		"gc_pause_last_ms":  float64(memStats.PauseNs[(memStats.NumGC+255)%256]) / 1e6,

		// Goroutine metrics
		"num_goroutines": runtime.NumGoroutine(),
	}
}

// metricsMiddleware tracks request metrics
func metricsMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// Skip metrics tracking for internal endpoints
		if r.URL.Path == "/metrics" || r.URL.Path == "/health" || r.URL.Path == "/sse/metrics" {
			next.ServeHTTP(w, r)
			return
		}

		metrics.IncrementActive()
		defer metrics.DecrementActive()

		next.ServeHTTP(w, r)
	})
}

// handleRoot handles the main endpoint - simulates normal web response (no worker pool)
func handleRoot(w http.ResponseWriter, r *http.Request) {
	// Simulate some processing (much lighter than worker pool version)
	// This represents typical web handler - direct response
	time.Sleep(10 * time.Millisecond) // Light processing

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]interface{}{
		"message":   "Hello from Chi Web Server",
		"timestamp": time.Now().Unix(),
		"type":      "normal-web",
	})
}

// handleHealth returns server health status
func handleHealth(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]string{
		"status": "healthy",
		"server": "chi-web",
		"time":   time.Now().Format(time.RFC3339),
	})
}

// handleMetrics returns current server metrics
func handleMetrics(w http.ResponseWriter, r *http.Request) {
	stats := metrics.GetStats()
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(stats)
}

// handleSSEMetrics streams metrics via Server-Sent Events
func handleSSEMetrics(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")
	w.Header().Set("Access-Control-Allow-Origin", "*")

	flusher, ok := w.(http.Flusher)
	if !ok {
		http.Error(w, "SSE not supported", http.StatusInternalServerError)
		return
	}

	ticker := time.NewTicker(1 * time.Second)
	defer ticker.Stop()

	for {
		select {
		case <-r.Context().Done():
			return
		case <-ticker.C:
			stats := metrics.GetStats()
			data, err := json.Marshal(stats)
			if err != nil {
				continue
			}
			fmt.Fprintf(w, "data: %s\n\n", data)
			flusher.Flush()
		}
	}
}

func main() {
	port := os.Getenv("PORT")
	if port == "" {
		port = "8081"
	}

	r := chi.NewRouter()

	// Middleware
	r.Use(middleware.Logger)
	r.Use(middleware.Recoverer)
	r.Use(middleware.RealIP)
	r.Use(metricsMiddleware)

	// Routes
	r.Get("/", handleRoot)
	r.Get("/health", handleHealth)
	r.Get("/metrics", handleMetrics)
	r.Get("/sse/metrics", handleSSEMetrics)

	// Start metrics logger
	go func() {
		ticker := time.NewTicker(5 * time.Second)
		defer ticker.Stop()
		for range ticker.C {
			stats := metrics.GetStats()
			log.Printf("[CHI-WEB] Active=%d, Total=%d, Completed=%d, RPS=%.2f, Mem=%.0fMB, Goroutines=%d",
				stats["active_connections"],
				stats["total_requests"],
				stats["completed_requests"],
				stats["requests_per_sec"],
				stats["memory_alloc_mb"],
				stats["num_goroutines"])
		}
	}()

	// Graceful shutdown
	go func() {
		sigCh := make(chan os.Signal, 1)
		signal.Notify(sigCh, os.Interrupt, syscall.SIGTERM)
		<-sigCh
		log.Println("[CHI-WEB] Shutting down...")
		os.Exit(0)
	}()

	log.Printf("[CHI-WEB] Server starting on :%s (no worker pool - direct handlers)", port)
	if err := http.ListenAndServe(":"+port, r); err != nil {
		log.Fatalf("[CHI-WEB] Server error: %v", err)
	}
}
