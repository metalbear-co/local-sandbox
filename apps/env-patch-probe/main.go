package main

import (
	"fmt"
	"os"
	"sort"
	"strings"
	"time"
)

// A tiny diagnostic app for queue splitting: it prints environment variables on
// a loop so you can watch whether mirrord changes a variable during a session,
// even when the deployment never declared it.
//
// The interesting case for Azure Service Bus is a subscription whose name lives
// only in appsettings.json (so it is not a real pod env var). The split config
// gives the operator the name through `fallback`, and the operator is expected
// to add the env var when it patches the workload. Run this as the target and
// you can see the variable go from <unset> to the operator's rewritten value.
func main() {
	// Comma-separated names to follow. Defaults to the variables used by the
	// sample split config in this module.
	watch := os.Getenv("WATCH_ENV")
	if watch == "" {
		watch = "Service__ServiceName,SERVICEBUS_SUBSCRIPTION_NAME,SERVICEBUS_TOPIC_NAME,TOPIC"
	}
	names := strings.Split(watch, ",")

	// Dump everything once so the starting state is on the record before any
	// patch happens.
	fmt.Println("=== full environment at startup ===")
	startup := os.Environ()
	sort.Strings(startup)
	for _, kv := range startup {
		fmt.Println(kv)
	}
	fmt.Printf("=== watching: %s ===\n", watch)
	fmt.Println("READY")

	for {
		now := time.Now().Format("15:04:05")
		var parts []string
		for _, name := range names {
			name = strings.TrimSpace(name)
			if name == "" {
				continue
			}
			if value, ok := os.LookupEnv(name); ok {
				parts = append(parts, fmt.Sprintf("%s=%q", name, value))
			} else {
				parts = append(parts, fmt.Sprintf("%s=<unset>", name))
			}
		}
		fmt.Printf("[%s] %s\n", now, strings.Join(parts, "  "))
		time.Sleep(3 * time.Second)
	}
}
