// Test app for GENERIC db branching with Couchbase.
//
// Couchbase is special in two ways:
//
//  1. MULTI-PORT: the app talks to the management API (8091) and the query service (8093)
//     on the same host. mirrord redirects only ONE port - so instead of declaring host+port,
//     only a HOST param is declared (COUCHBASE_HOST holds a bare hostname), and the app
//     builds the :8091/:8093 URLs from it. Since all ports live on the same branch pod,
//     rewriting just the host redirects everything.
//
//  2. NO ENV BOOTSTRAP: the image has no first-boot env mechanism - the branch config uses a
//     `command` wrapper that starts the server and runs `couchbase-cli cluster-init` +
//     `bucket-create` with $MIRRORD_PARAM_PASSWORD (plain shell env - the params are just
//     env vars on the branch container).
//
// Identity: each initialized Couchbase cluster gets a unique uuid (GET /pools).
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
	host, sourceHost, user, password string
	client                           = &http.Client{Timeout: 15 * time.Second}
)

func main() {
	host = getenv("COUCHBASE_HOST", "couchbase-main")
	sourceHost = os.Getenv("COUCHBASE_SOURCE_HOST")
	user = getenv("COUCHBASE_USER", "Administrator")
	password = os.Getenv("COUCHBASE_PASSWORD")

	log.Printf("Connecting to Couchbase at %s (source host: %s, user=%s)", host, sourceHost, user)

	http.HandleFunc("/", handleRoot)
	http.HandleFunc("/info", handleInfo)
	http.HandleFunc("/write", handleWrite)
	http.HandleFunc("/read", handleRead)
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

func request(method, url, contentType, body string) (*http.Response, error) {
	var reader io.Reader
	if body != "" {
		reader = strings.NewReader(body)
	}
	req, err := http.NewRequest(method, url, reader)
	if err != nil {
		return nil, err
	}
	req.SetBasicAuth(user, password)
	if contentType != "" {
		req.Header.Set("Content-Type", contentType)
	}
	return client.Do(req)
}

func handleRoot(w http.ResponseWriter, r *http.Request) {
	fmt.Fprintf(w, "Couchbase Generic-Branching Test App\n\n")
	fmt.Fprintf(w, "  GET /info             - cluster uuid proof (branch vs source)\n")
	fmt.Fprintf(w, "  GET /write?msg=<text> - upsert doc 'k1' into the sandbox bucket (N1QL)\n")
	fmt.Fprintf(w, "  GET /read             - fetch doc 'k1' back (N1QL USE KEYS - no index needed)\n")
	fmt.Fprintf(w, "  GET /health           - management API check\n")
}

func clusterUUID(h string) string {
	resp, err := request(http.MethodGet, fmt.Sprintf("http://%s:8091/pools", h), "", "")
	if err != nil {
		return "? (" + err.Error() + ")"
	}
	defer resp.Body.Close()
	var parsed struct {
		UUID string `json:"uuid"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&parsed); err != nil || parsed.UUID == "" {
		return "?"
	}
	return parsed.UUID
}

func handleInfo(w http.ResponseWriter, r *http.Request) {
	fmt.Fprintf(w, "COUCHBASE_SOURCE_HOST (real, untouched) = %s\n", sourceHost)
	fmt.Fprintf(w, "COUCHBASE_HOST        (connected)       = %s\n", host)
	fmt.Fprintf(w, "password set: %v (never rewritten by mirrord)\n", password != "")
	fmt.Fprintf(w, "\n")

	connected := clusterUUID(host)
	fmt.Fprintf(w, "connected cluster uuid = %s\n", connected)

	if sourceHost == "" {
		fmt.Fprintf(w, "source cluster uuid    = ? (COUCHBASE_SOURCE_HOST not set)\n")
		return
	}
	source := clusterUUID(sourceHost)
	fmt.Fprintf(w, "source cluster uuid    = %s\n", source)
	fmt.Fprintf(w, "\n")

	switch {
	case host == sourceHost:
		fmt.Fprintf(w, "REDIRECTED: no - COUCHBASE_HOST was not rewritten (not running under mirrord with a branch?)\n")
	case !strings.HasPrefix(connected, "?") && connected == source:
		fmt.Fprintf(w, "REDIRECTED: NO! - host differs but it is the SAME cluster as the source\n")
	default:
		fmt.Fprintf(w, "REDIRECTED: yes - connected to a DIFFERENT Couchbase cluster (the branch) than the source\n")
	}
}

// n1ql runs a statement on the query service. USE KEYS statements need no index, so the
// sandbox bucket works without creating one.
func n1ql(h, statement string) (string, error) {
	payload, _ := json.Marshal(map[string]string{"statement": statement})
	resp, err := request(http.MethodPost, fmt.Sprintf("http://%s:8093/query/service", h),
		"application/json", string(payload))
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode >= 300 {
		return "", fmt.Errorf("query returned %d: %s", resp.StatusCode, body)
	}
	return string(body), nil
}

func handleWrite(w http.ResponseWriter, r *http.Request) {
	msg := r.URL.Query().Get("msg")
	if msg == "" {
		msg = "hello-from-local"
	}
	writer := r.URL.Query().Get("writer")
	if writer == "" {
		writer = "local"
	}

	stmt := fmt.Sprintf(
		"UPSERT INTO `sandbox` (KEY, VALUE) VALUES (\"k1\", {\"writer\": %q, \"msg\": %q, \"ts\": %q})",
		writer, msg, time.Now().Format(time.RFC3339))
	if _, err := n1ql(host, stmt); err != nil {
		http.Error(w, fmt.Sprintf("upsert failed: %v", err), http.StatusBadGateway)
		return
	}
	fmt.Fprintf(w, "Upserted sandbox/k1: writer=%s msg=%s\n", writer, msg)
}

func handleRead(w http.ResponseWriter, r *http.Request) {
	result, err := n1ql(host, "SELECT sandbox.* FROM `sandbox` USE KEYS [\"k1\"]")
	if err != nil {
		fmt.Fprintf(w, "No doc yet (empty branch?): %v\n", err)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	fmt.Fprintf(w, "%s\n", result)
}

func handleHealth(w http.ResponseWriter, r *http.Request) {
	resp, err := request(http.MethodGet, fmt.Sprintf("http://%s:8091/pools/default", host), "", "")
	if err != nil {
		w.WriteHeader(http.StatusServiceUnavailable)
		fmt.Fprintf(w, "unhealthy: %v\n", err)
		return
	}
	defer resp.Body.Close()
	fmt.Fprintf(w, "couchbase management API: %d\n", resp.StatusCode)
}
