// Test app for GENERIC db branching with Apache Cassandra (CQL, gocql client).
//
//   - CASSANDRA_ADDR        composite "host:port" -> mirrord rewrites host/port via patterns.
//   - CASSANDRA_SOURCE_ADDR untouched twin for the isolation checks.
//
// Cassandra's default config has no authentication, so like CockroachDB this is a
// no-credentials branch; the JVM heap is tuned via the image's MAX_HEAP_SIZE env.
// Identity: system.local's host_id is unique per node/bootstrap.
package main

import (
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"strconv"
	"time"

	"github.com/gocql/gocql"
)

var addr, sourceAddr string

func main() {
	addr = getenv("CASSANDRA_ADDR", "cassandra-main:9042")
	sourceAddr = os.Getenv("CASSANDRA_SOURCE_ADDR")

	log.Printf("Connecting to Cassandra at %s (source addr: %s)", addr, sourceAddr)

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

func session(target string) (*gocql.Session, error) {
	host, portStr, err := net.SplitHostPort(target)
	if err != nil {
		return nil, err
	}
	port, _ := strconv.Atoi(portStr)
	cluster := gocql.NewCluster(host)
	cluster.Port = port
	cluster.Timeout = 10 * time.Second
	cluster.ConnectTimeout = 10 * time.Second
	// Single-node branch/source: don't chase peer-advertised addresses.
	cluster.DisableInitialHostLookup = true
	return cluster.CreateSession()
}

func handleRoot(w http.ResponseWriter, r *http.Request) {
	fmt.Fprintf(w, "Cassandra Generic-Branching Test App\n\n")
	fmt.Fprintf(w, "  GET /info             - host_id proof (branch vs source)\n")
	fmt.Fprintf(w, "  GET /write?msg=<text> - insert a row into sandbox.msgs\n")
	fmt.Fprintf(w, "  GET /rows             - list rows in sandbox.msgs\n")
	fmt.Fprintf(w, "  GET /health           - SELECT now()\n")
}

func hostID(target string) string {
	s, err := session(target)
	if err != nil {
		return "? (" + err.Error() + ")"
	}
	defer s.Close()
	var id gocql.UUID
	var clusterName string
	if err := s.Query("SELECT host_id, cluster_name FROM system.local").Scan(&id, &clusterName); err != nil {
		return "? (" + err.Error() + ")"
	}
	return id.String()
}

func handleInfo(w http.ResponseWriter, r *http.Request) {
	fmt.Fprintf(w, "CASSANDRA_SOURCE_ADDR (real, untouched) = %s\n", sourceAddr)
	fmt.Fprintf(w, "CASSANDRA_ADDR        (connected)       = %s\n", addr)
	fmt.Fprintf(w, "\n")

	connected := hostID(addr)
	fmt.Fprintf(w, "connected host_id = %s\n", connected)

	if sourceAddr == "" {
		fmt.Fprintf(w, "source host_id    = ? (CASSANDRA_SOURCE_ADDR not set)\n")
		return
	}
	source := hostID(sourceAddr)
	fmt.Fprintf(w, "source host_id    = %s\n", source)
	fmt.Fprintf(w, "\n")

	switch {
	case addr == sourceAddr:
		fmt.Fprintf(w, "REDIRECTED: no - CASSANDRA_ADDR was not rewritten (not running under mirrord with a branch?)\n")
	case connected != "" && connected[0] != '?' && connected == source:
		fmt.Fprintf(w, "REDIRECTED: NO! - address differs but it is the SAME node as the source\n")
	default:
		fmt.Fprintf(w, "REDIRECTED: yes - connected to a DIFFERENT Cassandra node (the branch) than the source\n")
	}
}

func ensureSchema(s *gocql.Session) error {
	if err := s.Query(`CREATE KEYSPACE IF NOT EXISTS sandbox
		WITH replication = {'class': 'SimpleStrategy', 'replication_factor': 1}`).Exec(); err != nil {
		return err
	}
	return s.Query(`CREATE TABLE IF NOT EXISTS sandbox.msgs
		(id uuid PRIMARY KEY, writer text, msg text, ts timestamp)`).Exec()
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

	s, err := session(addr)
	if err != nil {
		http.Error(w, fmt.Sprintf("connect failed: %v", err), http.StatusBadGateway)
		return
	}
	defer s.Close()

	if err := ensureSchema(s); err != nil {
		http.Error(w, fmt.Sprintf("schema failed: %v", err), http.StatusBadGateway)
		return
	}
	if err := s.Query("INSERT INTO sandbox.msgs (id, writer, msg, ts) VALUES (?, ?, ?, ?)",
		gocql.TimeUUID(), writer, msg, time.Now()).Exec(); err != nil {
		http.Error(w, fmt.Sprintf("insert failed: %v", err), http.StatusBadGateway)
		return
	}
	fmt.Fprintf(w, "Inserted into sandbox.msgs: writer=%s msg=%s\n", writer, msg)
}

func handleRows(w http.ResponseWriter, r *http.Request) {
	s, err := session(addr)
	if err != nil {
		http.Error(w, fmt.Sprintf("connect failed: %v", err), http.StatusBadGateway)
		return
	}
	defer s.Close()

	iter := s.Query("SELECT writer, msg, ts FROM sandbox.msgs").Iter()
	var writer, msg string
	var ts time.Time
	count := 0
	for iter.Scan(&writer, &msg, &ts) {
		fmt.Fprintf(w, "  writer=%s msg=%q ts=%s\n", writer, msg, ts.Format(time.RFC3339))
		count++
	}
	if err := iter.Close(); err != nil {
		fmt.Fprintf(w, "No sandbox.msgs table yet (empty branch?): %v\n", err)
		return
	}
	if count == 0 {
		fmt.Fprintf(w, "(no rows)\n")
	}
}

func handleHealth(w http.ResponseWriter, r *http.Request) {
	s, err := session(addr)
	if err == nil {
		defer s.Close()
		err = s.Query("SELECT now() FROM system.local").Exec()
	}
	if err != nil {
		w.WriteHeader(http.StatusServiceUnavailable)
		fmt.Fprintf(w, "unhealthy: %v\n", err)
		return
	}
	fmt.Fprintf(w, "healthy\n")
}
