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
}

var metrics = &Metrics{
	startTime: time.Now(),
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

func (m *Metrics) GetStats() map[string]interface{} {
	uptime := time.Since(m.startTime).Seconds()
	completed := atomic.LoadInt64(&m.completedRequests)

	var memStats runtime.MemStats
	runtime.ReadMemStats(&memStats)

	return map[string]interface{}{
		"server_type":        "chi-web",
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
			log.Printf("[CHI-WEB] Active=%d, Total=%d, Completed=%d, RPS=%.2f, Mem=%dMB, Goroutines=%d",
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
