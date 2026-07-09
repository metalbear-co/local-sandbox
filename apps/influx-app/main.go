// Test app for GENERIC db branching with InfluxDB 2.x - the RFC's canonical example.
// Talks to InfluxDB over its plain HTTP API (stdlib only, no client lib).
//
// Connection env:
//   - INFLUXDB_URL     full URL ("http://host:8086") -> mirrord rewrites ONLY the host/port
//     fragments via value_pattern; the scheme and shape stay intact.
//   - INFLUXDB_TOKEN   from a Kubernetes Secret -> mirrord leaves it untouched; the branch is
//     bootstrapped with the same token via DOCKER_INFLUXDB_INIT_ADMIN_TOKEN.
//   - INFLUXDB_ORG / INFLUXDB_BUCKET -> untouched; the branch's setup mode creates the same
//     org and bucket, so the app's values stay valid.
package main

import (
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"strings"
	"time"
)

var (
	baseURL, token, org, bucket string
	client                      = &http.Client{Timeout: 10 * time.Second}
)

func main() {
	baseURL = getenv("INFLUXDB_URL", "http://influxdb-main:8086")
	token = os.Getenv("INFLUXDB_TOKEN")
	org = getenv("INFLUXDB_ORG", "metalbear")
	bucket = getenv("INFLUXDB_BUCKET", "metrics")

	log.Printf("Connecting to InfluxDB at %s (org=%s bucket=%s)", baseURL, org, bucket)

	http.HandleFunc("/", handleRoot)
	http.HandleFunc("/info", handleInfo)
	http.HandleFunc("/write", handleWrite)
	http.HandleFunc("/query", handleQuery)
	http.HandleFunc("/health", handleHealth)

	port := getenv("PORT", "8080")
	log.Printf("Server starting on :%s", port)
	log.Fatal(http.ListenAndServe(":"+port, nil))
}

func getenv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func handleRoot(w http.ResponseWriter, r *http.Request) {
	fmt.Fprintf(w, "InfluxDB Generic-Branching Test App\n\n")
	fmt.Fprintf(w, "Endpoints:\n")
	fmt.Fprintf(w, "  GET /info             - Which InfluxDB this app talks to\n")
	fmt.Fprintf(w, "  GET /write?value=<n>  - Write a point to the 'sandbox' measurement\n")
	fmt.Fprintf(w, "  GET /query            - Read back points from the last hour\n")
	fmt.Fprintf(w, "  GET /health           - InfluxDB health check\n")
}

func handleInfo(w http.ResponseWriter, r *http.Request) {
	fmt.Fprintf(w, "INFLUXDB_URL    = %s\n", baseURL)
	fmt.Fprintf(w, "INFLUXDB_ORG    = %s (never rewritten by mirrord)\n", org)
	fmt.Fprintf(w, "INFLUXDB_BUCKET = %s (never rewritten by mirrord)\n", bucket)
	fmt.Fprintf(w, "token set: %v (never rewritten by mirrord)\n", token != "")
}

func handleWrite(w http.ResponseWriter, r *http.Request) {
	value := r.URL.Query().Get("value")
	if value == "" {
		value = "1"
	}

	line := fmt.Sprintf("sandbox,writer=local value=%s", value)
	url := fmt.Sprintf("%s/api/v2/write?org=%s&bucket=%s&precision=s", baseURL, org, bucket)

	req, _ := http.NewRequest(http.MethodPost, url, strings.NewReader(line))
	req.Header.Set("Authorization", "Token "+token)

	resp, err := client.Do(req)
	if err != nil {
		http.Error(w, fmt.Sprintf("write failed: %v", err), http.StatusBadGateway)
		return
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode >= 300 {
		http.Error(w, fmt.Sprintf("write failed (%d): %s", resp.StatusCode, body), http.StatusBadGateway)
		return
	}

	fmt.Fprintf(w, "Wrote: %s\n", line)
}

func handleQuery(w http.ResponseWriter, r *http.Request) {
	flux := fmt.Sprintf(`from(bucket:"%s") |> range(start:-1h)`, bucket)
	url := fmt.Sprintf("%s/api/v2/query?org=%s", baseURL, org)

	req, _ := http.NewRequest(http.MethodPost, url, strings.NewReader(flux))
	req.Header.Set("Authorization", "Token "+token)
	req.Header.Set("Content-Type", "application/vnd.flux")

	resp, err := client.Do(req)
	if err != nil {
		http.Error(w, fmt.Sprintf("query failed: %v", err), http.StatusBadGateway)
		return
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode >= 300 {
		http.Error(w, fmt.Sprintf("query failed (%d): %s", resp.StatusCode, body), http.StatusBadGateway)
		return
	}

	if strings.TrimSpace(string(body)) == "" {
		fmt.Fprintf(w, "No points found (empty branch?)\n")
		return
	}
	w.Write(body)
}

func handleHealth(w http.ResponseWriter, r *http.Request) {
	resp, err := client.Get(baseURL + "/health")
	if err != nil {
		w.WriteHeader(http.StatusServiceUnavailable)
		fmt.Fprintf(w, "unhealthy: %v\n", err)
		return
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	fmt.Fprintf(w, "influxdb (%d): %s\n", resp.StatusCode, body)
}
