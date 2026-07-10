// Test app for GENERIC db branching with Aerospike (community edition, no auth).
//
//   - AEROSPIKE_ADDR        composite "host:port" -> mirrord rewrites host/port via patterns.
//   - AEROSPIKE_SOURCE_ADDR untouched twin for the isolation checks.
//
// Uses the native Aerospike client (binary wire protocol - proves generic branching isn't
// limited to HTTP/SQL protocols). Identity: each Aerospike node generates a unique node ID.
// Records go into the CE image's default in-memory `test` namespace.
package main

import (
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"strconv"

	as "github.com/aerospike/aerospike-client-go/v7"
)

var addr, sourceAddr string

func main() {
	addr = getenv("AEROSPIKE_ADDR", "aerospike-main:3000")
	sourceAddr = os.Getenv("AEROSPIKE_SOURCE_ADDR")

	log.Printf("Connecting to Aerospike at %s (source addr: %s)", addr, sourceAddr)

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

func connect(target string) (*as.Client, error) {
	host, portStr, err := net.SplitHostPort(target)
	if err != nil {
		return nil, err
	}
	port, _ := strconv.Atoi(portStr)
	return as.NewClient(host, port)
}

func handleRoot(w http.ResponseWriter, r *http.Request) {
	fmt.Fprintf(w, "Aerospike Generic-Branching Test App\n\n")
	fmt.Fprintf(w, "  GET /info             - node ID proof (branch vs source)\n")
	fmt.Fprintf(w, "  GET /write?msg=<text> - put a record into test/sandbox/msg\n")
	fmt.Fprintf(w, "  GET /read             - get the record back\n")
	fmt.Fprintf(w, "  GET /health           - cluster connected check\n")
}

func nodeID(target string) string {
	client, err := connect(target)
	if err != nil {
		return "? (" + err.Error() + ")"
	}
	defer client.Close()
	names := client.GetNodeNames()
	if len(names) == 0 {
		return "?"
	}
	return names[0]
}

func handleInfo(w http.ResponseWriter, r *http.Request) {
	fmt.Fprintf(w, "AEROSPIKE_SOURCE_ADDR (real, untouched) = %s\n", sourceAddr)
	fmt.Fprintf(w, "AEROSPIKE_ADDR        (connected)       = %s\n", addr)
	fmt.Fprintf(w, "\n")

	connected := nodeID(addr)
	fmt.Fprintf(w, "connected node id = %s\n", connected)

	if sourceAddr == "" {
		fmt.Fprintf(w, "source node id    = ? (AEROSPIKE_SOURCE_ADDR not set)\n")
		return
	}
	source := nodeID(sourceAddr)
	fmt.Fprintf(w, "source node id    = %s\n", source)
	fmt.Fprintf(w, "\n")

	switch {
	case addr == sourceAddr:
		fmt.Fprintf(w, "REDIRECTED: no - AEROSPIKE_ADDR was not rewritten (not running under mirrord with a branch?)\n")
	case connected != "" && connected[0] != '?' && connected == source:
		fmt.Fprintf(w, "REDIRECTED: NO! - address differs but it is the SAME node as the source\n")
	default:
		fmt.Fprintf(w, "REDIRECTED: yes - connected to a DIFFERENT Aerospike node (the branch) than the source\n")
	}
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

	client, err := connect(addr)
	if err != nil {
		http.Error(w, fmt.Sprintf("connect failed: %v", err), http.StatusBadGateway)
		return
	}
	defer client.Close()

	key, _ := as.NewKey("test", "sandbox", "msg")
	bins := as.BinMap{"writer": writer, "msg": msg}
	if err := client.Put(nil, key, bins); err != nil {
		http.Error(w, fmt.Sprintf("put failed: %v", err), http.StatusBadGateway)
		return
	}
	fmt.Fprintf(w, "Put test/sandbox/msg: writer=%s msg=%s\n", writer, msg)
}

func handleRead(w http.ResponseWriter, r *http.Request) {
	client, err := connect(addr)
	if err != nil {
		http.Error(w, fmt.Sprintf("connect failed: %v", err), http.StatusBadGateway)
		return
	}
	defer client.Close()

	key, _ := as.NewKey("test", "sandbox", "msg")
	record, err := client.Get(nil, key)
	if err != nil || record == nil {
		fmt.Fprintf(w, "No record at test/sandbox/msg (empty branch?)\n")
		return
	}
	fmt.Fprintf(w, "  writer=%v msg=%v\n", record.Bins["writer"], record.Bins["msg"])
}

func handleHealth(w http.ResponseWriter, r *http.Request) {
	client, err := connect(addr)
	if err != nil {
		w.WriteHeader(http.StatusServiceUnavailable)
		fmt.Fprintf(w, "unhealthy: %v\n", err)
		return
	}
	defer client.Close()
	fmt.Fprintf(w, "healthy (connected: %v)\n", client.IsConnected())
}
