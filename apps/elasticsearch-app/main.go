// Test app for GENERIC db branching with Elasticsearch 8.x.
//
// Connection env:
//   - ELASTICSEARCH_URL        full URL -> mirrord rewrites ONLY host/port via value_pattern.
//   - ELASTICSEARCH_PASSWORD   from a Kubernetes Secret -> untouched; the branch is
//     bootstrapped with the same password via ELASTIC_PASSWORD=$(MIRRORD_PARAM_PASSWORD)
//     (the elastic user's bootstrap password mechanism of the official image).
//   - ELASTICSEARCH_SOURCE_URL untouched twin of the URL, for the isolation checks.
//
// Identity: every Elasticsearch cluster generates a unique cluster_uuid at bootstrap.
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
	baseURL, sourceURL, user, password string
	client                             = &http.Client{Timeout: 15 * time.Second}
)

func main() {
	baseURL = getenv("ELASTICSEARCH_URL", "http://elasticsearch-main:9200")
	sourceURL = os.Getenv("ELASTICSEARCH_SOURCE_URL")
	user = getenv("ELASTICSEARCH_USER", "elastic")
	password = os.Getenv("ELASTICSEARCH_PASSWORD")

	log.Printf("Connecting to Elasticsearch at %s (source url: %s, user=%s)", baseURL, sourceURL, user)

	http.HandleFunc("/", handleRoot)
	http.HandleFunc("/info", handleInfo)
	http.HandleFunc("/write", handleWrite)
	http.HandleFunc("/search", handleSearch)
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

func request(method, url string, body string) (*http.Response, error) {
	var reader io.Reader
	if body != "" {
		reader = strings.NewReader(body)
	}
	req, err := http.NewRequest(method, url, reader)
	if err != nil {
		return nil, err
	}
	req.SetBasicAuth(user, password)
	if body != "" {
		req.Header.Set("Content-Type", "application/json")
	}
	return client.Do(req)
}

func handleRoot(w http.ResponseWriter, r *http.Request) {
	fmt.Fprintf(w, "Elasticsearch Generic-Branching Test App\n\n")
	fmt.Fprintf(w, "Endpoints:\n")
	fmt.Fprintf(w, "  GET /info             - Which Elasticsearch this app talks to (cluster_uuid proof)\n")
	fmt.Fprintf(w, "  GET /write?msg=<text> - Index a doc into the 'sandbox' index\n")
	fmt.Fprintf(w, "  GET /search           - List docs in the 'sandbox' index\n")
	fmt.Fprintf(w, "  GET /health           - Cluster health\n")
}

func clusterUUID(base string) string {
	resp, err := request(http.MethodGet, base+"/", "")
	if err != nil {
		return "? (" + err.Error() + ")"
	}
	defer resp.Body.Close()
	var parsed struct {
		ClusterUUID string `json:"cluster_uuid"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&parsed); err != nil || parsed.ClusterUUID == "" {
		return "?"
	}
	return parsed.ClusterUUID
}

func handleInfo(w http.ResponseWriter, r *http.Request) {
	fmt.Fprintf(w, "ELASTICSEARCH_SOURCE_URL (real, untouched) = %s\n", sourceURL)
	fmt.Fprintf(w, "ELASTICSEARCH_URL        (connected)       = %s\n", baseURL)
	fmt.Fprintf(w, "password set: %v (never rewritten by mirrord)\n", password != "")
	fmt.Fprintf(w, "\n")

	connected := clusterUUID(baseURL)
	fmt.Fprintf(w, "connected cluster_uuid = %s\n", connected)

	if sourceURL == "" {
		fmt.Fprintf(w, "source cluster_uuid    = ? (ELASTICSEARCH_SOURCE_URL not set)\n")
		return
	}
	source := clusterUUID(sourceURL)
	fmt.Fprintf(w, "source cluster_uuid    = %s\n", source)
	fmt.Fprintf(w, "\n")

	switch {
	case baseURL == sourceURL:
		fmt.Fprintf(w, "REDIRECTED: no - ELASTICSEARCH_URL was not rewritten (not running under mirrord with a branch?)\n")
	case !strings.HasPrefix(connected, "?") && connected == source:
		fmt.Fprintf(w, "REDIRECTED: NO! - URL differs but it is the SAME cluster as the source\n")
	default:
		fmt.Fprintf(w, "REDIRECTED: yes - connected to a DIFFERENT Elasticsearch cluster (the branch) than the source\n")
	}
}

func handleWrite(w http.ResponseWriter, r *http.Request) {
	msg := r.URL.Query().Get("msg")
	if msg == "" {
		msg = "hello-from-local"
	}

	doc := fmt.Sprintf(`{"writer":"local","msg":%q,"ts":%q}`, msg, time.Now().Format(time.RFC3339))
	resp, err := request(http.MethodPost, baseURL+"/sandbox/_doc?refresh=true", doc)
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
	fmt.Fprintf(w, "Indexed into 'sandbox': %s\n", doc)
}

func handleSearch(w http.ResponseWriter, r *http.Request) {
	resp, err := request(http.MethodGet, baseURL+"/sandbox/_search?q=*&size=50", "")
	if err != nil {
		http.Error(w, fmt.Sprintf("search failed: %v", err), http.StatusBadGateway)
		return
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode == http.StatusNotFound {
		fmt.Fprintf(w, "No 'sandbox' index yet (empty branch?)\n")
		return
	}
	if resp.StatusCode >= 300 {
		http.Error(w, fmt.Sprintf("search failed (%d): %s", resp.StatusCode, body), http.StatusBadGateway)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.Write(body)
}

func handleHealth(w http.ResponseWriter, r *http.Request) {
	resp, err := request(http.MethodGet, baseURL+"/_cluster/health", "")
	if err != nil {
		w.WriteHeader(http.StatusServiceUnavailable)
		fmt.Fprintf(w, "unhealthy: %v\n", err)
		return
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	fmt.Fprintf(w, "elasticsearch (%d): %s\n", resp.StatusCode, body)
}
