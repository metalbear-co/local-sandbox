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
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"strings"
	"time"
)

var (
	baseURL, sourceURL, token, org, bucket string
	client                                 = &http.Client{Timeout: 10 * time.Second}
)

func main() {
	baseURL = getenv("INFLUXDB_URL", "http://influxdb-main:8086")
	// Same value in the pod spec, but NOT declared in the mirrord config, so mirrord never
	// rewrites it: under mirrord this stays the ORIGINAL (source) URL while INFLUXDB_URL
	// gets its host/port rewritten to the branch.
	sourceURL = os.Getenv("INFLUXDB_SOURCE_URL")
	token = os.Getenv("INFLUXDB_TOKEN")
	org = getenv("INFLUXDB_ORG", "metalbear")
	bucket = getenv("INFLUXDB_BUCKET", "metrics")

	log.Printf("Connecting to InfluxDB at %s (source url: %s, org=%s bucket=%s)", baseURL, sourceURL, org, bucket)

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

// The org ID is generated per InfluxDB instance during setup, so branch and source both
// have an org named `org` but with DIFFERENT ids - a per-instance identity like Valkey's
// run_id.
func orgID(base string) string {
	req, _ := http.NewRequest(http.MethodGet, fmt.Sprintf("%s/api/v2/orgs?org=%s", base, org), nil)
	req.Header.Set("Authorization", "Token "+token)
	resp, err := client.Do(req)
	if err != nil {
		return "? (" + err.Error() + ")"
	}
	defer resp.Body.Close()
	var parsed struct {
		Orgs []struct {
			ID string `json:"id"`
		} `json:"orgs"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&parsed); err != nil || len(parsed.Orgs) == 0 {
		return "?"
	}
	return parsed.Orgs[0].ID
}

func handleInfo(w http.ResponseWriter, r *http.Request) {
	fmt.Fprintf(w, "INFLUXDB_SOURCE_URL (real, untouched) = %s\n", sourceURL)
	fmt.Fprintf(w, "INFLUXDB_URL        (connected)       = %s\n", baseURL)
	fmt.Fprintf(w, "INFLUXDB_ORG    = %s (never rewritten by mirrord)\n", org)
	fmt.Fprintf(w, "INFLUXDB_BUCKET = %s (never rewritten by mirrord)\n", bucket)
	fmt.Fprintf(w, "token set: %v (never rewritten by mirrord)\n", token != "")
	fmt.Fprintf(w, "\n")

	connectedOrg := orgID(baseURL)
	fmt.Fprintf(w, "connected org id = %s\n", connectedOrg)

	if sourceURL == "" {
		fmt.Fprintf(w, "source org id    = ? (INFLUXDB_SOURCE_URL not set)\n")
		return
	}
	sourceOrg := orgID(sourceURL)
	fmt.Fprintf(w, "source org id    = %s\n", sourceOrg)
	fmt.Fprintf(w, "\n")

	switch {
	case baseURL == sourceURL:
		fmt.Fprintf(w, "REDIRECTED: no - INFLUXDB_URL was not rewritten (not running under mirrord with a branch?)\n")
	case !strings.HasPrefix(connectedOrg, "?") && connectedOrg == sourceOrg:
		fmt.Fprintf(w, "REDIRECTED: NO! - URL differs but it is the SAME InfluxDB instance as the source\n")
	default:
		fmt.Fprintf(w, "REDIRECTED: yes - connected to a DIFFERENT InfluxDB instance (the branch) than the source\n")
	}
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
