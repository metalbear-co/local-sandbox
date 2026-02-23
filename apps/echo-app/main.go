package main

import (
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"sync/atomic"
	"time"
)

var (
	clusterID    string
	requestCount uint64
)

// RequestLog represents a logged request for multi-cluster testing
type RequestLog struct {
	Timestamp  string            `json:"timestamp"`
	Method     string            `json:"method"`
	Path       string            `json:"path"`
	RemoteAddr string            `json:"remote_addr"`
	ClusterID  string            `json:"cluster_id"`
	Headers    map[string]string `json:"headers"`
	Body       string            `json:"body,omitempty"`
	RequestNum uint64            `json:"request_num"`
}

func main() {
	clusterID = os.Getenv("CLUSTER_ID")
	if clusterID == "" {
		clusterID = "unknown"
	}

	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	http.HandleFunc("/", handleRequest)
	http.HandleFunc("/health", handleHealth)
	http.HandleFunc("/echo", handleEcho)
	http.HandleFunc("/info", handleInfo)

	log.Printf("[%s] Echo server starting on :%s", clusterID, port)
	log.Fatal(http.ListenAndServe(":"+port, nil))
}

func handleRequest(w http.ResponseWriter, r *http.Request) {
	reqNum := atomic.AddUint64(&requestCount, 1)

	// Read body if present
	var body string
	if r.Body != nil {
		bodyBytes, _ := io.ReadAll(r.Body)
		body = string(bodyBytes)
	}

	// Extract headers
	headers := make(map[string]string)
	for key, values := range r.Header {
		if len(values) > 0 {
			headers[key] = values[0]
		}
	}

	reqLog := RequestLog{
		Timestamp:  time.Now().Format(time.RFC3339Nano),
		Method:     r.Method,
		Path:       r.URL.Path,
		RemoteAddr: r.RemoteAddr,
		ClusterID:  clusterID,
		Headers:    headers,
		Body:       body,
		RequestNum: reqNum,
	}

	// Log to stdout in JSON for easy parsing
	logJSON, _ := json.Marshal(reqLog)
	log.Printf("REQUEST: %s", logJSON)

	// Respond with cluster info
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("X-Cluster-ID", clusterID)

	response := map[string]interface{}{
		"message":     fmt.Sprintf("Hello from %s", clusterID),
		"cluster_id":  clusterID,
		"request_num": reqNum,
		"path":        r.URL.Path,
		"method":      r.Method,
		"timestamp":   reqLog.Timestamp,
	}

	json.NewEncoder(w).Encode(response)
}

func handleHealth(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]interface{}{
		"status":     "healthy",
		"cluster_id": clusterID,
		"requests":   atomic.LoadUint64(&requestCount),
	})
}

func handleEcho(w http.ResponseWriter, r *http.Request) {
	reqNum := atomic.AddUint64(&requestCount, 1)

	// Echo back the request with cluster info
	body, _ := io.ReadAll(r.Body)

	// Check for filter header (for HTTP filter testing)
	filterHeader := r.Header.Get("X-My-Header")

	// Print formatted multi-line log
	log.Printf("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
	log.Printf("[%s] ECHO #%d", clusterID, reqNum)
	log.Printf("  Method:  %s %s", r.Method, r.URL.Path)
	if r.URL.RawQuery != "" {
		log.Printf("  Query:   %s", r.URL.RawQuery)
	}
	if filterHeader != "" {
		log.Printf("  Filter:  X-My-Header = %s ", filterHeader)
	}
	if len(body) > 0 {
		if len(body) > 100 {
			log.Printf("  Body:    (%d bytes) %s...", len(body), string(body[:100]))
		} else {
			log.Printf("  Body:    %s", string(body))
		}
	}
	// Print other interesting headers
	for _, h := range []string{"Content-Type", "User-Agent", "X-Request-Id"} {
		if v := r.Header.Get(h); v != "" {
			log.Printf("  %s: %s", h, v)
		}
	}

	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("X-Cluster-ID", clusterID)

	// Collect all headers for response
	headers := make(map[string]string)
	for key, values := range r.Header {
		if len(values) > 0 {
			headers[key] = values[0]
		}
	}

	response := map[string]interface{}{
		"cluster_id":    clusterID,
		"request_num":   reqNum,
		"filter_header": filterHeader,
		"echo_body":     string(body),
		"echo_path":     r.URL.Path,
		"echo_method":   r.Method,
		"echo_query":    r.URL.RawQuery,
		"headers":       headers,
	}

	json.NewEncoder(w).Encode(response)
}

func handleInfo(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")

	hostname, _ := os.Hostname()

	response := map[string]interface{}{
		"cluster_id":     clusterID,
		"hostname":       hostname,
		"total_requests": atomic.LoadUint64(&requestCount),
		"env": map[string]string{
			"CLUSTER_ID": clusterID,
			"PORT":       os.Getenv("PORT"),
		},
	}

	json.NewEncoder(w).Encode(response)
}
