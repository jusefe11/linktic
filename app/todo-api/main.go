// todo-api: REST CRUD service for tasks, backed by PostgreSQL (CloudNativePG).
// Exposes /healthz (liveness), /readyz (readiness, checks DB), /metrics (Prometheus),
// and /tasks CRUD. Propagates Istio B3 tracing headers on any outbound call so Jaeger
// can correlate the full request path.
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

var (
	pool *pgxpool.Pool

	httpRequests = promauto.NewCounterVec(prometheus.CounterOpts{
		Name: "todo_api_http_requests_total",
		Help: "Total HTTP requests by method, path and status.",
	}, []string{"method", "path", "status"})

	httpDuration = promauto.NewHistogramVec(prometheus.HistogramOpts{
		Name:    "todo_api_http_request_duration_seconds",
		Help:    "HTTP request duration in seconds.",
		Buckets: prometheus.DefBuckets,
	}, []string{"method", "path"})
)

// B3 / Istio tracing headers we propagate on outbound calls.
var traceHeaders = []string{
	"x-request-id", "x-b3-traceid", "x-b3-spanid", "x-b3-parentspanid",
	"x-b3-sampled", "x-b3-flags", "b3", "traceparent", "tracestate",
}

type Task struct {
	ID    int    `json:"id"`
	Title string `json:"title"`
	Done  bool   `json:"done"`
}

func env(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func main() {
	dsn := fmt.Sprintf("postgres://%s:%s@%s:%s/%s?sslmode=%s",
		env("DB_USER", "todo"), env("DB_PASSWORD", ""),
		env("DB_HOST", "localhost"), env("DB_PORT", "5432"),
		env("DB_NAME", "tododb"), env("DB_SSLMODE", "require"))

	cfg, err := pgxpool.ParseConfig(dsn)
	if err != nil {
		log.Fatalf("invalid DSN: %v", err)
	}
	cfg.MaxConns = 8
	pool, err = pgxpool.NewWithConfig(context.Background(), cfg)
	if err != nil {
		log.Fatalf("cannot create pool: %v", err)
	}
	defer pool.Close()

	// Best-effort schema init (retries until the DB is reachable).
	go initSchema()

	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", health)
	mux.HandleFunc("/readyz", ready)
	mux.Handle("/metrics", promhttp.Handler())
	mux.HandleFunc("/tasks", instrument("/tasks", tasksHandler))
	mux.HandleFunc("/tasks/", instrument("/tasks/{id}", taskByIDHandler))

	addr := ":" + env("PORT", "8080")
	log.Printf("todo-api listening on %s", addr)
	log.Fatal(http.ListenAndServe(addr, cors(mux)))
}

func initSchema() {
	const ddl = `CREATE TABLE IF NOT EXISTS tasks (
		id SERIAL PRIMARY KEY,
		title TEXT NOT NULL,
		done BOOLEAN NOT NULL DEFAULT false
	)`
	for {
		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		_, err := pool.Exec(ctx, ddl)
		cancel()
		if err == nil {
			log.Println("schema ready")
			return
		}
		log.Printf("waiting for DB to init schema: %v", err)
		time.Sleep(3 * time.Second)
	}
}

// instrument wraps a handler with Prometheus metrics and a status recorder.
func instrument(path string, h http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		rec := &statusRecorder{ResponseWriter: w, status: 200}
		h(rec, r)
		httpDuration.WithLabelValues(r.Method, path).Observe(time.Since(start).Seconds())
		httpRequests.WithLabelValues(r.Method, path, strconv.Itoa(rec.status)).Inc()
	}
}

type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (s *statusRecorder) WriteHeader(code int) {
	s.status = code
	s.ResponseWriter.WriteHeader(code)
}

// cors allows the browser SPA (served on a different *.local host) to call the API.
func cors(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS")
		w.Header().Set("Access-Control-Allow-Headers", "Content-Type")
		if r.Method == http.MethodOptions {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		next.ServeHTTP(w, r)
	})
}

func health(w http.ResponseWriter, r *http.Request) {
    w.Header().Set("Content-Type", "text/plain")
    w.WriteHeader(http.StatusOK)
    w.Write([]byte("Backend Demo GitOps v2"))
}

func ready(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
	defer cancel()
	if err := pool.Ping(ctx); err != nil {
		http.Error(w, "db not ready", http.StatusServiceUnavailable)
		return
	}
	w.WriteHeader(http.StatusOK)
}

func tasksHandler(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodGet:
		listTasks(w, r)
	case http.MethodPost:
		createTask(w, r)
	default:
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
	}
}

func taskByIDHandler(w http.ResponseWriter, r *http.Request) {
	idStr := strings.TrimPrefix(r.URL.Path, "/tasks/")
	id, err := strconv.Atoi(idStr)
	if err != nil {
		http.Error(w, "invalid id", http.StatusBadRequest)
		return
	}
	switch r.Method {
	case http.MethodGet:
		getTask(w, r, id)
	case http.MethodPut:
		updateTask(w, r, id)
	case http.MethodDelete:
		deleteTask(w, r, id)
	default:
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
	}
}

func listTasks(w http.ResponseWriter, r *http.Request) {
	rows, err := pool.Query(r.Context(), "SELECT id, title, done FROM tasks ORDER BY id")
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	defer rows.Close()
	tasks := []Task{}
	for rows.Next() {
		var t Task
		if err := rows.Scan(&t.ID, &t.Title, &t.Done); err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		tasks = append(tasks, t)
	}
	writeJSON(w, http.StatusOK, tasks)
}

func createTask(w http.ResponseWriter, r *http.Request) {
	var t Task
	if err := json.NewDecoder(r.Body).Decode(&t); err != nil || strings.TrimSpace(t.Title) == "" {
		http.Error(w, "title is required", http.StatusBadRequest)
		return
	}
	err := pool.QueryRow(r.Context(),
		"INSERT INTO tasks (title, done) VALUES ($1, $2) RETURNING id", t.Title, t.Done).Scan(&t.ID)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	writeJSON(w, http.StatusCreated, t)
}

func getTask(w http.ResponseWriter, r *http.Request, id int) {
	var t Task
	err := pool.QueryRow(r.Context(), "SELECT id, title, done FROM tasks WHERE id=$1", id).
		Scan(&t.ID, &t.Title, &t.Done)
	if err != nil {
		http.Error(w, "not found", http.StatusNotFound)
		return
	}
	writeJSON(w, http.StatusOK, t)
}

func updateTask(w http.ResponseWriter, r *http.Request, id int) {
	var t Task
	if err := json.NewDecoder(r.Body).Decode(&t); err != nil {
		http.Error(w, "invalid body", http.StatusBadRequest)
		return
	}
	ct, err := pool.Exec(r.Context(),
		"UPDATE tasks SET title=$1, done=$2 WHERE id=$3", t.Title, t.Done, id)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	if ct.RowsAffected() == 0 {
		http.Error(w, "not found", http.StatusNotFound)
		return
	}
	t.ID = id
	writeJSON(w, http.StatusOK, t)
}

func deleteTask(w http.ResponseWriter, r *http.Request, id int) {
	ct, err := pool.Exec(r.Context(), "DELETE FROM tasks WHERE id=$1", id)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	if ct.RowsAffected() == 0 {
		http.Error(w, "not found", http.StatusNotFound)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(v)
}

// propagateTrace copies B3/trace headers from an inbound request to an outbound one
// (used when todo-api makes downstream HTTP calls, so Jaeger keeps one trace).
func propagateTrace(dst *http.Request, src *http.Request) {
	for _, h := range traceHeaders {
		if v := src.Header.Get(h); v != "" {
			dst.Header.Set(h, v)
		}
	}
}
