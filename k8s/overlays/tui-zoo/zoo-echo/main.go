// The zoo's echo app: answers every request with its own name and the
// hostname serving it, so a response instantly shows whether it came from
// the cluster pod or a local mirrord stand-in.
//
// The same file serves both sides: the zoo workloads `go run` it from a
// ConfigMap, and `task tui:local` builds it into the binary you point the
// TUI's Command field at. `-listen` must match the target workload's port
// (zoo-web :5678, zoo-sidecar :5679, zoo-sts :5680, zoo-pod :5681).
package main

import (
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"
)

func main() {
	listen := flag.String("listen", ":5678", "address to serve on")
	flag.Parse()

	name := os.Getenv("ZOO_NAME")
	if name == "" {
		name = "zoo-echo"
	}
	hostname, _ := os.Hostname()

	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		log.Printf("%s: %s %s from %s", name, r.Method, r.URL.Path, r.RemoteAddr)
		fmt.Fprintf(w, "%s on %s: %s %s\n", name, hostname, r.Method, r.URL.Path)
	})
	log.Printf("%s listening on %s", name, *listen)
	log.Fatal(http.ListenAndServe(*listen, nil))
}
