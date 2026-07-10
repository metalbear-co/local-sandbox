// Test app for GENERIC db branching with CockroachDB (insecure single-node dev mode).
//
// This is the MINIMAL generic config case: no credentials at all - the branch only needs
// the image, the SQL port, and `args: ["start-single-node", "--insecure"]`. The only
// declared connection params are host/port, extracted from the postgres-style URL:
//
//	COCKROACH_URL        = postgresql://root@cockroach-main:26257/defaultdb?sslmode=disable
//	COCKROACH_SOURCE_URL = same value, NOT declared in the mirrord config -> untouched.
//
// Identity: every CockroachDB cluster gets a unique cluster id (crdb_internal.cluster_id()).
package main

import (
	"database/sql"
	"fmt"
	"log"
	"net/http"
	"os"
	"time"

	_ "github.com/lib/pq"
)

var baseURL, sourceURL string

func main() {
	baseURL = getenv("COCKROACH_URL", "postgresql://root@cockroach-main:26257/defaultdb?sslmode=disable")
	sourceURL = os.Getenv("COCKROACH_SOURCE_URL")

	log.Printf("Connecting to CockroachDB at %s (source url: %s)", baseURL, sourceURL)

	http.HandleFunc("/", handleRoot)
	http.HandleFunc("/info", handleInfo)
	http.HandleFunc("/write", handleWrite)
	http.HandleFunc("/rows", handleRows)
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

func open(url string) (*sql.DB, error) {
	db, err := sql.Open("postgres", url)
	if err != nil {
		return nil, err
	}
	db.SetConnMaxLifetime(time.Minute)
	return db, nil
}

func handleRoot(w http.ResponseWriter, r *http.Request) {
	fmt.Fprintf(w, "CockroachDB Generic-Branching Test App\n\n")
	fmt.Fprintf(w, "Endpoints:\n")
	fmt.Fprintf(w, "  GET /info             - Which CockroachDB this app talks to (cluster id proof)\n")
	fmt.Fprintf(w, "  GET /write?msg=<text> - Insert a row into the 'sandbox' table\n")
	fmt.Fprintf(w, "  GET /rows             - List rows in the 'sandbox' table\n")
	fmt.Fprintf(w, "  GET /health           - SELECT 1\n")
}

func clusterID(url string) string {
	db, err := open(url)
	if err != nil {
		return "? (" + err.Error() + ")"
	}
	defer db.Close()
	var id string
	if err := db.QueryRow("SELECT crdb_internal.cluster_id()").Scan(&id); err != nil {
		return "? (" + err.Error() + ")"
	}
	return id
}

func handleInfo(w http.ResponseWriter, r *http.Request) {
	fmt.Fprintf(w, "COCKROACH_SOURCE_URL (real, untouched) = %s\n", sourceURL)
	fmt.Fprintf(w, "COCKROACH_URL        (connected)       = %s\n", baseURL)
	fmt.Fprintf(w, "\n")

	connected := clusterID(baseURL)
	fmt.Fprintf(w, "connected cluster id = %s\n", connected)

	if sourceURL == "" {
		fmt.Fprintf(w, "source cluster id    = ? (COCKROACH_SOURCE_URL not set)\n")
		return
	}
	source := clusterID(sourceURL)
	fmt.Fprintf(w, "source cluster id    = %s\n", source)
	fmt.Fprintf(w, "\n")

	switch {
	case baseURL == sourceURL:
		fmt.Fprintf(w, "REDIRECTED: no - COCKROACH_URL was not rewritten (not running under mirrord with a branch?)\n")
	case connected != "" && connected[0] != '?' && connected == source:
		fmt.Fprintf(w, "REDIRECTED: NO! - URL differs but it is the SAME cluster as the source\n")
	default:
		fmt.Fprintf(w, "REDIRECTED: yes - connected to a DIFFERENT CockroachDB cluster (the branch) than the source\n")
	}
}

func handleWrite(w http.ResponseWriter, r *http.Request) {
	msg := r.URL.Query().Get("msg")
	if msg == "" {
		msg = "hello-from-local"
	}

	db, err := open(baseURL)
	if err != nil {
		http.Error(w, fmt.Sprintf("open failed: %v", err), http.StatusBadGateway)
		return
	}
	defer db.Close()

	if _, err := db.Exec(
		"CREATE TABLE IF NOT EXISTS sandbox (id SERIAL PRIMARY KEY, writer STRING, msg STRING, ts TIMESTAMPTZ DEFAULT now())",
	); err != nil {
		http.Error(w, fmt.Sprintf("create table failed: %v", err), http.StatusBadGateway)
		return
	}
	if _, err := db.Exec("INSERT INTO sandbox (writer, msg) VALUES ('local', $1)", msg); err != nil {
		http.Error(w, fmt.Sprintf("insert failed: %v", err), http.StatusBadGateway)
		return
	}
	fmt.Fprintf(w, "Inserted into sandbox: writer=local msg=%s\n", msg)
}

func handleRows(w http.ResponseWriter, r *http.Request) {
	db, err := open(baseURL)
	if err != nil {
		http.Error(w, fmt.Sprintf("open failed: %v", err), http.StatusBadGateway)
		return
	}
	defer db.Close()

	rows, err := db.Query("SELECT writer, msg, ts FROM sandbox ORDER BY ts")
	if err != nil {
		fmt.Fprintf(w, "No 'sandbox' table yet (empty branch?): %v\n", err)
		return
	}
	defer rows.Close()

	count := 0
	for rows.Next() {
		var writer, msg string
		var ts time.Time
		if err := rows.Scan(&writer, &msg, &ts); err != nil {
			http.Error(w, fmt.Sprintf("scan failed: %v", err), http.StatusInternalServerError)
			return
		}
		fmt.Fprintf(w, "  writer=%s msg=%q ts=%s\n", writer, msg, ts.Format(time.RFC3339))
		count++
	}
	if count == 0 {
		fmt.Fprintf(w, "(no rows)\n")
	}
}

func handleHealth(w http.ResponseWriter, r *http.Request) {
	db, err := open(baseURL)
	if err == nil {
		defer db.Close()
		var one int
		err = db.QueryRow("SELECT 1").Scan(&one)
	}
	if err != nil {
		w.WriteHeader(http.StatusServiceUnavailable)
		fmt.Fprintf(w, "unhealthy: %v\n", err)
		return
	}
	fmt.Fprintf(w, "healthy\n")
}
