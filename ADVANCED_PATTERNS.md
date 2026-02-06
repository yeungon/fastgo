# Advanced Go Concurrency Patterns for Web Servers

This document provides advanced examples building on the main server implementation.

## Pattern 1: Priority Queue Worker Pool

Handle urgent requests faster than regular ones.

```go
package main

import (
	"container/heap"
	"sync"
	"time"
)

// PriorityJob wraps a job with priority
type PriorityJob struct {
	Job      Job
	Priority int
	Index    int
}

// PriorityQueue implements heap.Interface
type PriorityQueue []*PriorityJob

func (pq PriorityQueue) Len() int { return len(pq) }
func (pq PriorityQueue) Less(i, j int) bool {
	return pq[i].Priority > pq[j].Priority // Higher priority first
}
func (pq PriorityQueue) Swap(i, j int) {
	pq[i], pq[j] = pq[j], pq[i]
	pq[i].Index = i
	pq[j].Index = j
}
func (pq *PriorityQueue) Push(x interface{}) {
	n := len(*pq)
	item := x.(*PriorityJob)
	item.Index = n
	*pq = append(*pq, item)
}
func (pq *PriorityQueue) Pop() interface{} {
	old := *pq
	n := len(old)
	item := old[n-1]
	old[n-1] = nil
	item.Index = -1
	*pq = old[0 : n-1]
	return item
}

// PriorityWorkerPool processes jobs by priority
type PriorityWorkerPool struct {
	workers  int
	queue    PriorityQueue
	mu       sync.Mutex
	notEmpty *sync.Cond
	closed   bool
	wg       sync.WaitGroup
}

func NewPriorityWorkerPool(workers int) *PriorityWorkerPool {
	pool := &PriorityWorkerPool{
		workers: workers,
		queue:   make(PriorityQueue, 0),
	}
	pool.notEmpty = sync.NewCond(&pool.mu)
	heap.Init(&pool.queue)
	
	for i := 0; i < workers; i++ {
		pool.wg.Add(1)
		go pool.worker()
	}
	
	return pool
}

func (p *PriorityWorkerPool) Submit(job Job, priority int) {
	p.mu.Lock()
	defer p.mu.Unlock()
	
	if p.closed {
		return
	}
	
	heap.Push(&p.queue, &PriorityJob{
		Job:      job,
		Priority: priority,
	})
	p.notEmpty.Signal()
}

func (p *PriorityWorkerPool) worker() {
	defer p.wg.Done()
	
	for {
		p.mu.Lock()
		for p.queue.Len() == 0 && !p.closed {
			p.notEmpty.Wait()
		}
		
		if p.closed && p.queue.Len() == 0 {
			p.mu.Unlock()
			return
		}
		
		priorityJob := heap.Pop(&p.queue).(*PriorityJob)
		p.mu.Unlock()
		
		// Process the job
		result := processJob(priorityJob.Job)
		if priorityJob.Job.ResultCh != nil {
			priorityJob.Job.ResultCh <- result
		}
	}
}

func (p *PriorityWorkerPool) Close() {
	p.mu.Lock()
	p.closed = true
	p.notEmpty.Broadcast()
	p.mu.Unlock()
	p.wg.Wait()
}

func processJob(job Job) JobResult {
	// Your processing logic
	time.Sleep(100 * time.Millisecond)
	return JobResult{Data: "processed", Error: nil}
}
```

## Pattern 2: Rate-Limited Worker Pool

Prevent overwhelming downstream services.

```go
package main

import (
	"context"
	"golang.org/x/time/rate"
	"sync"
)

// RateLimitedWorkerPool limits request rate
type RateLimitedWorkerPool struct {
	workers   int
	limiter   *rate.Limiter
	jobQueue  chan Job
	wg        sync.WaitGroup
	ctx       context.Context
	cancel    context.CancelFunc
}

func NewRateLimitedWorkerPool(workers int, requestsPerSecond float64) *RateLimitedWorkerPool {
	ctx, cancel := context.WithCancel(context.Background())
	
	pool := &RateLimitedWorkerPool{
		workers:  workers,
		limiter:  rate.NewLimiter(rate.Limit(requestsPerSecond), int(requestsPerSecond)),
		jobQueue: make(chan Job, workers*100),
		ctx:      ctx,
		cancel:   cancel,
	}
	
	for i := 0; i < workers; i++ {
		pool.wg.Add(1)
		go pool.worker()
	}
	
	return pool
}

func (p *RateLimitedWorkerPool) worker() {
	defer p.wg.Done()
	
	for {
		select {
		case <-p.ctx.Done():
			return
		case job := <-p.jobQueue:
			// Wait for rate limiter
			if err := p.limiter.Wait(p.ctx); err != nil {
				if job.ResultCh != nil {
					job.ResultCh <- JobResult{Error: err}
				}
				continue
			}
			
			// Process job
			result := processJob(job)
			if job.ResultCh != nil {
				job.ResultCh <- result
			}
		}
	}
}

func (p *RateLimitedWorkerPool) Submit(job Job) error {
	select {
	case p.jobQueue <- job:
		return nil
	case <-p.ctx.Done():
		return p.ctx.Err()
	}
}

func (p *RateLimitedWorkerPool) Close() {
	p.cancel()
	close(p.jobQueue)
	p.wg.Wait()
}
```

## Pattern 3: Circuit Breaker Pattern

Prevent cascading failures when downstream services fail.

```go
package main

import (
	"errors"
	"sync"
	"time"
)

type CircuitState int

const (
	StateClosed CircuitState = iota
	StateOpen
	StateHalfOpen
)

// CircuitBreaker implements the circuit breaker pattern
type CircuitBreaker struct {
	maxFailures   int
	resetTimeout  time.Duration
	state         CircuitState
	failures      int
	lastFailTime  time.Time
	mu            sync.RWMutex
}

func NewCircuitBreaker(maxFailures int, resetTimeout time.Duration) *CircuitBreaker {
	return &CircuitBreaker{
		maxFailures:  maxFailures,
		resetTimeout: resetTimeout,
		state:        StateClosed,
	}
}

func (cb *CircuitBreaker) Execute(fn func() error) error {
	cb.mu.Lock()
	
	// Check if we should transition from Open to HalfOpen
	if cb.state == StateOpen {
		if time.Since(cb.lastFailTime) > cb.resetTimeout {
			cb.state = StateHalfOpen
			cb.failures = 0
		} else {
			cb.mu.Unlock()
			return errors.New("circuit breaker is open")
		}
	}
	
	cb.mu.Unlock()
	
	// Execute the function
	err := fn()
	
	cb.mu.Lock()
	defer cb.mu.Unlock()
	
	if err != nil {
		cb.failures++
		cb.lastFailTime = time.Now()
		
		if cb.failures >= cb.maxFailures {
			cb.state = StateOpen
		}
		return err
	}
	
	// Success - reset circuit breaker
	if cb.state == StateHalfOpen {
		cb.state = StateClosed
	}
	cb.failures = 0
	
	return nil
}

func (cb *CircuitBreaker) GetState() CircuitState {
	cb.mu.RLock()
	defer cb.mu.RUnlock()
	return cb.state
}

// Usage in worker pool
type ResilientWorkerPool struct {
	*WorkerPool
	circuitBreaker *CircuitBreaker
}

func (p *ResilientWorkerPool) processJobWithCircuitBreaker(job Job) JobResult {
	var result JobResult
	
	err := p.circuitBreaker.Execute(func() error {
		result = processJob(job)
		return result.Error
	})
	
	if err != nil {
		return JobResult{Error: err}
	}
	
	return result
}
```

## Pattern 4: Adaptive Worker Pool

Dynamically adjust worker count based on load.

```go
package main

import (
	"context"
	"sync"
	"sync/atomic"
	"time"
)

// AdaptiveWorkerPool dynamically scales workers
type AdaptiveWorkerPool struct {
	minWorkers    int
	maxWorkers    int
	currentWorkers int32
	jobQueue      chan Job
	metrics       struct {
		queueDepth    int64
		processedJobs int64
	}
	workers       map[int]*worker
	workersMu     sync.RWMutex
	ctx           context.Context
	cancel        context.CancelFunc
	wg            sync.WaitGroup
}

type worker struct {
	id     int
	cancel context.CancelFunc
}

func NewAdaptiveWorkerPool(minWorkers, maxWorkers, queueSize int) *AdaptiveWorkerPool {
	ctx, cancel := context.WithCancel(context.Background())
	
	pool := &AdaptiveWorkerPool{
		minWorkers:     minWorkers,
		maxWorkers:     maxWorkers,
		currentWorkers: int32(minWorkers),
		jobQueue:       make(chan Job, queueSize),
		workers:        make(map[int]*worker),
		ctx:            ctx,
		cancel:         cancel,
	}
	
	// Start minimum workers
	for i := 0; i < minWorkers; i++ {
		pool.addWorker(i)
	}
	
	// Start scaling monitor
	go pool.scaleMonitor()
	
	return pool
}

func (p *AdaptiveWorkerPool) addWorker(id int) {
	workerCtx, workerCancel := context.WithCancel(p.ctx)
	
	w := &worker{
		id:     id,
		cancel: workerCancel,
	}
	
	p.workersMu.Lock()
	p.workers[id] = w
	p.workersMu.Unlock()
	
	p.wg.Add(1)
	go p.workerLoop(workerCtx, id)
	
	atomic.AddInt32(&p.currentWorkers, 1)
}

func (p *AdaptiveWorkerPool) removeWorker() {
	p.workersMu.Lock()
	defer p.workersMu.Unlock()
	
	// Find a worker to remove (simple: pick first one)
	for id, w := range p.workers {
		w.cancel()
		delete(p.workers, id)
		atomic.AddInt32(&p.currentWorkers, -1)
		return
	}
}

func (p *AdaptiveWorkerPool) workerLoop(ctx context.Context, id int) {
	defer p.wg.Done()
	
	for {
		select {
		case <-ctx.Done():
			return
		case job := <-p.jobQueue:
			result := processJob(job)
			atomic.AddInt64(&p.metrics.processedJobs, 1)
			
			if job.ResultCh != nil {
				job.ResultCh <- result
			}
		}
	}
}

func (p *AdaptiveWorkerPool) scaleMonitor() {
	ticker := time.NewTicker(5 * time.Second)
	defer ticker.Stop()
	
	for {
		select {
		case <-p.ctx.Done():
			return
		case <-ticker.C:
			queueDepth := len(p.jobQueue)
			currentWorkers := int(atomic.LoadInt32(&p.currentWorkers))
			
			// Scale up if queue is filling
			if queueDepth > currentWorkers*10 && currentWorkers < p.maxWorkers {
				nextID := currentWorkers
				p.addWorker(nextID)
				log.Printf("Scaled up to %d workers (queue depth: %d)", 
					currentWorkers+1, queueDepth)
			}
			
			// Scale down if queue is mostly empty
			if queueDepth < currentWorkers*2 && currentWorkers > p.minWorkers {
				p.removeWorker()
				log.Printf("Scaled down to %d workers (queue depth: %d)", 
					currentWorkers-1, queueDepth)
			}
		}
	}
}

func (p *AdaptiveWorkerPool) Submit(job Job) error {
	select {
	case p.jobQueue <- job:
		return nil
	case <-p.ctx.Done():
		return p.ctx.Err()
	}
}

func (p *AdaptiveWorkerPool) Close() {
	p.cancel()
	close(p.jobQueue)
	p.wg.Wait()
}
```

## Pattern 5: Batching Worker Pool

Process multiple jobs together for efficiency.

```go
package main

import (
	"context"
	"sync"
	"time"
)

// BatchJob represents a batch of jobs
type BatchJob struct {
	Jobs    []Job
	Results []JobResult
}

// BatchingWorkerPool processes jobs in batches
type BatchingWorkerPool struct {
	workers      int
	batchSize    int
	batchTimeout time.Duration
	jobQueue     chan Job
	batchQueue   chan BatchJob
	wg           sync.WaitGroup
	ctx          context.Context
	cancel       context.CancelFunc
}

func NewBatchingWorkerPool(workers, batchSize int, batchTimeout time.Duration) *BatchingWorkerPool {
	ctx, cancel := context.WithCancel(context.Background())
	
	pool := &BatchingWorkerPool{
		workers:      workers,
		batchSize:    batchSize,
		batchTimeout: batchTimeout,
		jobQueue:     make(chan Job, workers*batchSize*2),
		batchQueue:   make(chan BatchJob, workers*2),
		ctx:          ctx,
		cancel:       cancel,
	}
	
	// Start batcher
	go pool.batcher()
	
	// Start workers
	for i := 0; i < workers; i++ {
		pool.wg.Add(1)
		go pool.worker()
	}
	
	return pool
}

func (p *BatchingWorkerPool) batcher() {
	var batch []Job
	timer := time.NewTimer(p.batchTimeout)
	
	for {
		select {
		case <-p.ctx.Done():
			// Process remaining batch
			if len(batch) > 0 {
				p.batchQueue <- BatchJob{Jobs: batch}
			}
			close(p.batchQueue)
			return
			
		case job := <-p.jobQueue:
			batch = append(batch, job)
			
			if len(batch) >= p.batchSize {
				p.batchQueue <- BatchJob{Jobs: batch}
				batch = nil
				timer.Reset(p.batchTimeout)
			}
			
		case <-timer.C:
			if len(batch) > 0 {
				p.batchQueue <- BatchJob{Jobs: batch}
				batch = nil
			}
			timer.Reset(p.batchTimeout)
		}
	}
}

func (p *BatchingWorkerPool) worker() {
	defer p.wg.Done()
	
	for batch := range p.batchQueue {
		// Process batch together (e.g., bulk database insert)
		results := p.processBatch(batch.Jobs)
		
		// Send results back to individual job channels
		for i, result := range results {
			if batch.Jobs[i].ResultCh != nil {
				batch.Jobs[i].ResultCh <- result
			}
		}
	}
}

func (p *BatchingWorkerPool) processBatch(jobs []Job) []JobResult {
	// Process all jobs together (more efficient for some operations)
	results := make([]JobResult, len(jobs))
	
	// Example: batch database operation
	for i, job := range jobs {
		results[i] = processJob(job)
	}
	
	return results
}

func (p *BatchingWorkerPool) Submit(job Job) error {
	select {
	case p.jobQueue <- job:
		return nil
	case <-p.ctx.Done():
		return p.ctx.Err()
	}
}

func (p *BatchingWorkerPool) Close() {
	p.cancel()
	close(p.jobQueue)
	p.wg.Wait()
}
```

## Performance Comparison

| Pattern | Use Case | Pros | Cons |
|---------|----------|------|------|
| **Basic Worker Pool** | General purpose | Simple, predictable | No prioritization |
| **Priority Queue** | Mixed urgency | Fair handling | Overhead for sorting |
| **Rate Limited** | API rate limits | Prevents overwhelming | May slow processing |
| **Circuit Breaker** | Unreliable services | Fail fast | Requires tuning |
| **Adaptive** | Variable load | Auto-scales | Complex logic |
| **Batching** | Bulk operations | Efficient for DB | Higher latency |

## When to Use Each Pattern

1. **Basic Worker Pool**: Start here for most applications
2. **Priority Queue**: When you have VIP/premium users
3. **Rate Limited**: When calling external APIs with rate limits
4. **Circuit Breaker**: When integrating with unreliable services
5. **Adaptive**: When load varies significantly throughout the day
6. **Batching**: When processing database bulk inserts/updates

## Combining Patterns

You can combine patterns for more sophisticated systems:

```go
// Example: Rate-limited + Circuit Breaker + Adaptive
type AdvancedWorkerPool struct {
	*AdaptiveWorkerPool
	rateLimiter     *rate.Limiter
	circuitBreaker  *CircuitBreaker
}
```

Choose patterns based on your specific requirements and constraints!
