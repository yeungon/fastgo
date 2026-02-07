// Fiber Web Server - FastHTTP-based (same HTTP layer as Worker Pool)
// This provides a fair comparison: same FastHTTP library, different patterns

package main

import (
	"bufio"
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

	"github.com/gofiber/fiber/v2"
	"github.com/gofiber/fiber/v2/middleware/cors"
	"github.com/gofiber/fiber/v2/middleware/logger"
)

// Metrics tracks server performance
type Metrics struct {
	activeConnections int64
	totalRequests     int64
	completedRequests int64
	errorCount        int64
	startTime         time.Time
	mu                sync.RWMutex
}

var metrics = &Metrics{
	startTime: time.Now(),
}

// getCPUUsage calculates approximate CPU usage based on goroutines vs available CPUs
func getCPUUsage() float64 {
	numCPU := runtime.NumCPU()
	numGoroutines := runtime.NumGoroutine()

	// Approximate CPU usage based on goroutines vs available CPUs
	usage := float64(numGoroutines) / float64(numCPU*10) * 100
	if usage > 100 {
		usage = 100
	}
	return usage
}

// GetStats returns current metrics as a map
func (m *Metrics) GetStats() map[string]interface{} {
	var memStats runtime.MemStats
	runtime.ReadMemStats(&memStats)

	active := atomic.LoadInt64(&m.activeConnections)
	total := atomic.LoadInt64(&m.totalRequests)
	completed := atomic.LoadInt64(&m.completedRequests)
	errors := atomic.LoadInt64(&m.errorCount)

	uptime := time.Since(m.startTime).Seconds()
	rps := float64(completed) / uptime

	var errorRate float64
	if total > 0 {
		errorRate = float64(errors) / float64(total) * 100
	}

	cpuUsage := getCPUUsage()

	return map[string]interface{}{
		"server_type":         "fiber",
		"num_cpu":             runtime.NumCPU(),
		"active_connections":  active,
		"total_requests":      total,
		"completed_requests":  completed,
		"error_count":         errors,
		"error_rate_percent":  errorRate,
		"uptime_seconds":      uptime,
		"requests_per_sec":    rps,
		"cpu_usage_percent":   cpuUsage,
		"memory_alloc_mb":     float64(memStats.Alloc) / 1024 / 1024,
		"memory_sys_mb":       float64(memStats.Sys) / 1024 / 1024,
		"memory_heap_mb":      float64(memStats.HeapAlloc) / 1024 / 1024,
		"memory_stack_mb":     float64(memStats.StackInuse) / 1024 / 1024,
		"memory_heap_objects": memStats.HeapObjects,
		"num_gc":              memStats.NumGC,
		"gc_pause_total_ms":   float64(memStats.PauseTotalNs) / 1e6,
		"gc_pause_last_ms":    float64(memStats.PauseNs[(memStats.NumGC+255)%256]) / 1e6,
		"num_goroutines":      runtime.NumGoroutine(),
	}
}

func main() {
	port := os.Getenv("PORT")
	if port == "" {
		port = "8082"
	}

	// Create Fiber app with FastHTTP configuration
	app := fiber.New(fiber.Config{
		ServerHeader:          "Fiber-FastHTTP",
		DisableStartupMessage: true,
		Prefork:               false, // Single process for fair comparison
		ReadTimeout:           30 * time.Second,
		WriteTimeout:          30 * time.Second,
		IdleTimeout:           120 * time.Second,
	})

	// CORS middleware
	app.Use(cors.New(cors.Config{
		AllowOrigins: "*",
		AllowHeaders: "Origin, Content-Type, Accept",
	}))

	// Request counter middleware
	app.Use(func(c *fiber.Ctx) error {
		atomic.AddInt64(&metrics.activeConnections, 1)
		atomic.AddInt64(&metrics.totalRequests, 1)

		err := c.Next()

		atomic.AddInt64(&metrics.activeConnections, -1)
		atomic.AddInt64(&metrics.completedRequests, 1)

		if err != nil {
			atomic.AddInt64(&metrics.errorCount, 1)
		}

		return err
	})

	// Logger middleware (optional, can be commented out for max performance)
	app.Use(logger.New(logger.Config{
		Format:     "${time} \"${method} ${url} ${protocol}\" from ${ip} - ${status} ${bytesSent}B in ${latency}\n",
		TimeFormat: "2006/01/02 15:04:05",
		Output:     os.Stdout,
	}))

	// Routes
	app.Get("/", handleRoot)
	app.Get("/health", handleHealth)
	app.Get("/metrics", handleMetrics)
	app.Get("/sse/metrics", handleSSE)

	// Serve static files
	app.Static("/static", "./static")

	// Start metrics logging
	go func() {
		ticker := time.NewTicker(5 * time.Second)
		defer ticker.Stop()
		for range ticker.C {
			stats := metrics.GetStats()
			log.Printf("[FIBER] Active=%d, Total=%d, Completed=%d, RPS=%.2f, Mem=%.0fMB, Goroutines=%d",
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
		sigChan := make(chan os.Signal, 1)
		signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)
		<-sigChan
		log.Println("[FIBER] Shutting down...")
		app.Shutdown()
	}()

	log.Printf("[FIBER] Server starting on :%s (FastHTTP-based)", port)
	if err := app.Listen(":" + port); err != nil {
		log.Fatal(err)
	}
}

func handleRoot(c *fiber.Ctx) error {
	// Simulate 10ms work like other servers
	time.Sleep(10 * time.Millisecond)
	return c.JSON(fiber.Map{
		"message":     "Hello from Fiber (FastHTTP)!",
		"server_type": "fiber",
	})
}

func handleHealth(c *fiber.Ctx) error {
	stats := metrics.GetStats()
	return c.JSON(fiber.Map{
		"status":      "healthy",
		"server_type": "fiber",
		"uptime":      stats["uptime_seconds"],
	})
}

func handleMetrics(c *fiber.Ctx) error {
	return c.JSON(metrics.GetStats())
}

// handleSSE sends Server-Sent Events for real-time metrics
func handleSSE(c *fiber.Ctx) error {
	c.Set("Content-Type", "text/event-stream")
	c.Set("Cache-Control", "no-cache")
	c.Set("Connection", "keep-alive")
	c.Set("Access-Control-Allow-Origin", "*")

	c.Context().SetBodyStreamWriter(func(w *bufio.Writer) {
		ticker := time.NewTicker(1 * time.Second)
		defer ticker.Stop()

		for i := 0; i < 60; i++ { // 60 seconds max per SSE connection
			select {
			case <-ticker.C:
				data, _ := json.Marshal(metrics.GetStats())
				fmt.Fprintf(w, "data: %s\n\n", data)
				w.Flush()
			}
		}
	})

	return nil
}
