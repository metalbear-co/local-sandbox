// Test app for GENERIC db branching: talks to Valkey (Redis-compatible, but a different
// image than mirrord's built-in Redis dialect assumes - exactly the RFC's use case).
//
// Reads its connection from:
//   - VALKEY_ADDR      composite "host:port" var -> mirrord rewrites host/port fragments
//     in place via value_pattern, so this app never knows it was redirected.
//   - VALKEY_PASSWORD  from a Kubernetes Secret -> mirrord leaves it UNTOUCHED; the branch
//     was bootstrapped (via $(MIRRORD_PARAM_PASSWORD) in args) to accept this same password.
package main

import (
	"context"
	"fmt"
	"log"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/redis/go-redis/v9"
)

var rdb *redis.Client
var ctx = context.Background()
var addr, sourceAddr, password, cacheName string

func main() {
	addr = os.Getenv("VALKEY_ADDR")
	if addr == "" {
		addr = "valkey-main:6379"
	}
	// Same value in the pod spec, but NOT declared in the mirrord config, so mirrord never
	// rewrites it: under mirrord this stays the ORIGINAL (source) address while VALKEY_ADDR
	// gets rewritten to the branch.
	sourceAddr = os.Getenv("VALKEY_SOURCE_ADDR")
	password = os.Getenv("VALKEY_PASSWORD")
	cacheName = os.Getenv("CACHE_NAME")

	log.Printf("Connecting to Valkey at %s (source addr: %s, cache name: %s)", addr, sourceAddr, cacheName)

	rdb = redis.NewClient(&redis.Options{
		Addr:     addr,
		Password: password,
	})

	if err := rdb.Ping(ctx).Err(); err != nil {
		log.Printf("Warning: Valkey ping failed: %v", err)
	} else {
		log.Printf("Valkey connection successful!")
	}

	http.HandleFunc("/", handleRoot)
	http.HandleFunc("/get", handleGet)
	http.HandleFunc("/set", handleSet)
	http.HandleFunc("/keys", handleKeys)
	http.HandleFunc("/info", handleInfo)
	http.HandleFunc("/health", handleHealth)

	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	log.Printf("Server starting on :%s", port)
	log.Fatal(http.ListenAndServe(":"+port, nil))
}

func handleRoot(w http.ResponseWriter, r *http.Request) {
	fmt.Fprintf(w, "Valkey Generic-Branching Test App\n\n")
	fmt.Fprintf(w, "Endpoints:\n")
	fmt.Fprintf(w, "  GET /get?key=<key>       - Get value\n")
	fmt.Fprintf(w, "  GET /set?key=<k>&val=<v> - Set value\n")
	fmt.Fprintf(w, "  GET /keys                - List all keys\n")
	fmt.Fprintf(w, "  GET /info                - Show which Valkey this app talks to\n")
	fmt.Fprintf(w, "  GET /health              - Health check\n")
}

// Extracts a field like "run_id" from valkey `INFO server` output.
func infoField(info, field string) string {
	for _, line := range strings.Split(info, "\n") {
		if v, ok := strings.CutPrefix(strings.TrimSpace(line), field+":"); ok {
			return v
		}
	}
	return "?"
}

// Shows the real (source) address next to the connected one, so you can see the
// value_pattern rewrite in action: under mirrord the host/port fragments of VALKEY_ADDR
// point at the branch pod while VALKEY_SOURCE_ADDR stays untouched. It then dials BOTH
// servers and compares their run_ids (unique per server process) for definitive proof.
func handleInfo(w http.ResponseWriter, r *http.Request) {
	fmt.Fprintf(w, "VALKEY_SOURCE_ADDR (real, untouched)   = %s\n", sourceAddr)
	fmt.Fprintf(w, "VALKEY_ADDR        (connected)         = %s\n", addr)
	fmt.Fprintf(w, "CACHE_NAME  = %s\n", cacheName)
	fmt.Fprintf(w, "password set: %v (never rewritten by mirrord)\n", password != "")
	fmt.Fprintf(w, "\n")

	connectedInfo, err := rdb.Info(ctx, "server").Result()
	if err != nil {
		fmt.Fprintf(w, "INFO server on connected (%s) failed: %v\n", addr, err)
		return
	}
	connectedRunID := infoField(connectedInfo, "run_id")
	fmt.Fprintf(w, "connected server run_id = %s\n", connectedRunID)

	if sourceAddr == "" {
		fmt.Fprintf(w, "source server run_id    = ? (VALKEY_SOURCE_ADDR not set)\n")
		return
	}

	// Dial the source directly (through mirrord's outgoing proxy when running under mirrord).
	srcCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	src := redis.NewClient(&redis.Options{Addr: sourceAddr, Password: password})
	defer src.Close()
	sourceInfo, err := src.Info(srcCtx, "server").Result()
	if err != nil {
		fmt.Fprintf(w, "source server run_id    = ? (INFO on %s failed: %v)\n", sourceAddr, err)
		return
	}
	sourceRunID := infoField(sourceInfo, "run_id")
	fmt.Fprintf(w, "source server run_id    = %s\n", sourceRunID)
	fmt.Fprintf(w, "\n")

	switch {
	case addr == sourceAddr:
		fmt.Fprintf(w, "REDIRECTED: no - VALKEY_ADDR was not rewritten (not running under mirrord with a branch?)\n")
	case connectedRunID != "?" && connectedRunID == sourceRunID:
		fmt.Fprintf(w, "REDIRECTED: NO! - address differs but it is the SAME server process as the source\n")
	default:
		fmt.Fprintf(w, "REDIRECTED: yes - connected to a DIFFERENT server (the branch) than the source\n")
	}
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
		http.Error(w, fmt.Sprintf("Valkey error: %v", err), http.StatusInternalServerError)
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
		http.Error(w, fmt.Sprintf("Valkey error: %v", err), http.StatusInternalServerError)
		return
	}

	fmt.Fprintf(w, "Set %s = %s\n", key, val)
}

func handleKeys(w http.ResponseWriter, r *http.Request) {
	keys, err := rdb.Keys(ctx, "*").Result()
	if err != nil {
		http.Error(w, fmt.Sprintf("Valkey error: %v", err), http.StatusInternalServerError)
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

	fmt.Fprintf(w, "healthy (valkey latency: %v)\n", latency)
}
