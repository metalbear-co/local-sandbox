// preview-probe is a single test app that exercises every preview feature and
// logs which cluster handled what, so a multicluster preview replica can be
// proven end-to-end from the app's own perspective (not just the plumbing).
//
// It is BOTH the deployed workload and the preview image. Every log line and
// HTTP response is prefixed with CLUSTER_ID so you can see which cluster's
// replica served a request / consumed a message / talked to the branch.
//
// HTTP (always on, port 80):
//
//	GET /                  -> "probe <cluster>: GET" (+ log). Plain requests hit
//	                          the deployed app; baggage-tagged ones hit the replica.
//	GET /log/<msg>         -> echoes <msg> and logs it (HTTP-steal locality proof).
//	GET /whoami           -> JSON {cluster, db_host, queue}.
//
// DB (active when DATABASE_URL is set) - proves the APP reaches the branch:
//
//	GET /db/insert/<val>   -> INSERT (val, cluster) into table `probe`, returns ok.
//	GET /db/select         -> SELECT val, cluster, ts FROM probe (newest first).
//	GET /db/host           -> the host:port the app is actually connected to
//	                          (the branch proxy Service, for a replica).
//
// SQS (active when QUEUE_NAME + AWS_* are set): a background consumer logs each
// message as `type=<attr> cluster=<cluster>` and INSERTs it into `probe` too, so
// split messages are visible both in logs and via /db/select.
package main

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"net/url"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	awsconfig "github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/credentials"
	"github.com/aws/aws-sdk-go-v2/service/sqs"
	"github.com/aws/aws-sdk-go-v2/service/sqs/types"
	_ "github.com/lib/pq"
)

var (
	cluster  = envOr("CLUSTER_ID", "unknown")
	dbMu     sync.RWMutex
	db       *sql.DB // guarded by dbMu; connected in the background so HTTP serves immediately
	dbHost   = "none"
	sqsCount atomic.Int64 // messages this pod has consumed, so each one prints a running number
)

func getDB() *sql.DB {
	dbMu.RLock()
	defer dbMu.RUnlock()
	return db
}

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func logf(format string, args ...any) {
	log.Printf("[cluster=%s] "+format, append([]any{cluster}, args...)...)
}

func main() {
	log.SetFlags(log.LstdFlags | log.Lmicroseconds)
	// Connect in the background so the HTTP server (and /health) come up immediately, even
	// before the branch / proxy chain is reachable.
	go setupDB()
	go consumeSQS()

	http.HandleFunc("/", handleRoot)
	http.HandleFunc("/log/", handleLog)
	http.HandleFunc("/whoami", handleWhoami)
	http.HandleFunc("/db/insert/", handleInsert)
	http.HandleFunc("/db/select", handleSelect)
	http.HandleFunc("/db/host", handleDBHost)
	http.HandleFunc("/health", func(w http.ResponseWriter, _ *http.Request) { fmt.Fprintln(w, "ok") })

	logf("preview-probe listening on :80 (db_host=%s queue=%s)", dbHost, envOr("QUEUE_NAME", "none"))
	if err := http.ListenAndServe(":80", nil); err != nil {
		log.Fatalf("server failed: %v", err)
	}
}

// ---- HTTP handlers -------------------------------------------------------

func handleRoot(w http.ResponseWriter, r *http.Request) {
	logf("GET %s from %s", r.URL.Path, r.RemoteAddr)
	fmt.Fprintf(w, "probe %s: GET\n", cluster)
}

func handleLog(w http.ResponseWriter, r *http.Request) {
	msg := strings.TrimPrefix(r.URL.Path, "/log/")
	logf("HTTP marker %s", msg)
	fmt.Fprint(w, msg)
}

func handleWhoami(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, map[string]string{
		"cluster": cluster,
		"db_host": dbHost,
		"queue":   envOr("QUEUE_NAME", ""),
	})
}

func handleInsert(w http.ResponseWriter, r *http.Request) {
	conn := getDB()
	if conn == nil {
		http.Error(w, "database not connected yet", http.StatusServiceUnavailable)
		return
	}
	val := strings.TrimPrefix(r.URL.Path, "/db/insert/")
	if _, err := conn.Exec(`INSERT INTO probe (val, cluster) VALUES ($1, $2)`, val, cluster); err != nil {
		logf("DB insert %q FAILED: %v", val, err)
		http.Error(w, err.Error(), http.StatusBadGateway)
		return
	}
	logf("DB insert %q -> branch via %s", val, dbHost)
	fmt.Fprintf(w, "inserted %q on %s (db_host=%s)\n", val, cluster, dbHost)
}

func handleSelect(w http.ResponseWriter, _ *http.Request) {
	conn := getDB()
	if conn == nil {
		http.Error(w, "database not connected yet", http.StatusServiceUnavailable)
		return
	}
	rows, err := conn.Query(`SELECT val, cluster, ts FROM probe ORDER BY ts DESC`)
	if err != nil {
		logf("DB select FAILED: %v", err)
		http.Error(w, err.Error(), http.StatusBadGateway)
		return
	}
	defer rows.Close()

	var out []map[string]string
	for rows.Next() {
		var val, cl string
		var ts time.Time
		if err := rows.Scan(&val, &cl, &ts); err != nil {
			http.Error(w, err.Error(), http.StatusBadGateway)
			return
		}
		out = append(out, map[string]string{"val": val, "cluster": cl, "ts": ts.Format(time.RFC3339)})
	}
	logf("DB select -> %d row(s) from branch via %s", len(out), dbHost)
	writeJSON(w, out)
}

func handleDBHost(w http.ResponseWriter, _ *http.Request) {
	fmt.Fprintln(w, dbHost)
}

func writeJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(v)
}

// ---- DB setup ------------------------------------------------------------

func setupDB() {
	dbURL := os.Getenv("DATABASE_URL")
	if dbURL == "" {
		logf("no DATABASE_URL - DB endpoints disabled")
		return
	}
	if u, err := url.Parse(dbURL); err == nil && u.Host != "" {
		dbHost = u.Host
	}
	// Force plaintext + bounded connect/handshake time. Without connect_timeout, lib/pq's Ping
	// can block forever if the TCP connection establishes (through the proxy) but the postgres
	// handshake stalls, which would silently disable the DB endpoints.
	for _, p := range []string{"sslmode=disable", "connect_timeout=10"} {
		if !strings.Contains(dbURL, strings.SplitN(p, "=", 2)[0]+"=") {
			sep := "?"
			if strings.Contains(dbURL, "?") {
				sep = "&"
			}
			dbURL += sep + p
		}
	}

	conn, err := sql.Open("postgres", dbURL)
	if err != nil {
		logf("DB open failed: %v", err)
		return
	}

	// Retry FOREVER: for a replica the branch + proxy chain (and its RBAC) may take a while to
	// become reachable, and giving up would permanently disable the DB endpoints.
	for attempt := 1; ; attempt++ {
		if err = conn.Ping(); err == nil {
			break
		}
		logf("waiting for DB at %s (attempt %d): %v", dbHost, attempt, err)
		time.Sleep(3 * time.Second)
	}
	if _, err := conn.Exec(`CREATE TABLE IF NOT EXISTS probe (
		id SERIAL PRIMARY KEY, val TEXT, cluster TEXT, ts TIMESTAMP DEFAULT now())`); err != nil {
		logf("DB create table failed: %v", err)
		return
	}
	dbMu.Lock()
	db = conn
	dbMu.Unlock()
	logf("connected to DB at %s (branch)", dbHost)
}

// ---- SQS consumer --------------------------------------------------------

func consumeSQS() {
	queue := os.Getenv("QUEUE_NAME")
	if queue == "" {
		return
	}
	endpoint := os.Getenv("AWS_ENDPOINT_URL")
	region := envOr("AWS_REGION", "us-east-1")

	cfg, err := awsconfig.LoadDefaultConfig(context.Background(),
		awsconfig.WithRegion(region),
		awsconfig.WithCredentialsProvider(credentials.NewStaticCredentialsProvider(
			envOr("AWS_ACCESS_KEY_ID", "test"), envOr("AWS_SECRET_ACCESS_KEY", "test"), "")),
	)
	if err != nil {
		logf("SQS config failed: %v", err)
		return
	}
	client := sqs.NewFromConfig(cfg, func(o *sqs.Options) {
		if endpoint != "" {
			o.BaseEndpoint = aws.String(endpoint)
		}
	})

	urlOut, err := client.GetQueueUrl(context.Background(), &sqs.GetQueueUrlInput{QueueName: aws.String(queue)})
	if err != nil {
		logf("SQS resolve %q failed: %v", queue, err)
		return
	}
	logf("SQS consuming %s", queue)

	for {
		out, err := client.ReceiveMessage(context.Background(), &sqs.ReceiveMessageInput{
			QueueUrl:              urlOut.QueueUrl,
			MaxNumberOfMessages:   10,
			WaitTimeSeconds:       5,
			MessageAttributeNames: []string{"All"},
		})
		if err != nil {
			logf("SQS receive failed: %v", err)
			time.Sleep(2 * time.Second)
			continue
		}
		for _, m := range out.Messages {
			typ := "?"
			if a, ok := m.MessageAttributes["type"]; ok && a.StringValue != nil {
				typ = *a.StringValue
			}
			logf("SQS #%d type=%s body=%s", sqsCount.Add(1), typ, aws.ToString(m.Body))
			if conn := getDB(); conn != nil {
				_, _ = conn.Exec(`INSERT INTO probe (val, cluster) VALUES ($1, $2)`, "sqs:"+typ, cluster)
			}
			_, _ = client.DeleteMessage(context.Background(), &sqs.DeleteMessageInput{
				QueueUrl: urlOut.QueueUrl, ReceiptHandle: m.ReceiptHandle,
			})
		}
	}
}

var _ = types.Message{}
