package main

import (
	"context"
	"fmt"
	"log"
	"net/http"
	"os"
	"time"

	"github.com/redis/go-redis/v9"
)

var rdb *redis.Client
var ctx = context.Background()

func main() {
	redisAddr := os.Getenv("REDIS_ADDR")
	if redisAddr == "" {
		redisAddr = "redis-main:6379"
	}

	log.Printf("Connecting to Redis at %s", redisAddr)

	rdb = redis.NewClient(&redis.Options{
		Addr: redisAddr,
	})

	// Test connection
	if err := rdb.Ping(ctx).Err(); err != nil {
		log.Printf("Warning: Redis ping failed: %v", err)
	} else {
		log.Printf("Redis connection successful!")
	}

	http.HandleFunc("/", handleRoot)
	http.HandleFunc("/get", handleGet)
	http.HandleFunc("/set", handleSet)
	http.HandleFunc("/keys", handleKeys)
	http.HandleFunc("/health", handleHealth)

	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	log.Printf("Server starting on :%s", port)
	log.Fatal(http.ListenAndServe(":"+port, nil))
}

func handleRoot(w http.ResponseWriter, r *http.Request) {
	fmt.Fprintf(w, "Redis Test App\n\n")
	fmt.Fprintf(w, "Endpoints:\n")
	fmt.Fprintf(w, "  GET /get?key=<key>     - Get value\n")
	fmt.Fprintf(w, "  GET /set?key=<k>&val=<v> - Set value\n")
	fmt.Fprintf(w, "  GET /keys              - List all keys\n")
	fmt.Fprintf(w, "  GET /health            - Health check\n")
}

func handleGet(w http.ResponseWriter, r *http.Request) {
	key := r.URL.Query().Get("key")
	if key == "" {
		http.Error(w, "key parameter required", http.StatusBadRequest)
		return
	}

	val, err := rdb.Get(ctx, key).Result()
	if err == redis.Nil {
		fmt.Fprintf(w, "Key '%s' not found\n", key)
		return
	} else if err != nil {
		http.Error(w, fmt.Sprintf("Redis error: %v", err), http.StatusInternalServerError)
		return
	}

	fmt.Fprintf(w, "%s = %s\n", key, val)
}

func handleSet(w http.ResponseWriter, r *http.Request) {
	key := r.URL.Query().Get("key")
	val := r.URL.Query().Get("val")

	if key == "" || val == "" {
		http.Error(w, "key and val parameters required", http.StatusBadRequest)
		return
	}

	err := rdb.Set(ctx, key, val, 0).Err()
	if err != nil {
		http.Error(w, fmt.Sprintf("Redis error: %v", err), http.StatusInternalServerError)
		return
	}

	fmt.Fprintf(w, "Set %s = %s\n", key, val)
}

func handleKeys(w http.ResponseWriter, r *http.Request) {
	keys, err := rdb.Keys(ctx, "*").Result()
	if err != nil {
		http.Error(w, fmt.Sprintf("Redis error: %v", err), http.StatusInternalServerError)
		return
	}

	if len(keys) == 0 {
		fmt.Fprintf(w, "No keys found\n")
		return
	}

	fmt.Fprintf(w, "Keys (%d):\n", len(keys))
	for _, key := range keys {
		val, _ := rdb.Get(ctx, key).Result()
		fmt.Fprintf(w, "  %s = %s\n", key, val)
	}
}

func handleHealth(w http.ResponseWriter, r *http.Request) {
	start := time.Now()
	err := rdb.Ping(ctx).Err()
	latency := time.Since(start)

	if err != nil {
		w.WriteHeader(http.StatusServiceUnavailable)
		fmt.Fprintf(w, "unhealthy: %v\n", err)
		return
	}

	fmt.Fprintf(w, "healthy (redis latency: %v)\n", latency)
}
