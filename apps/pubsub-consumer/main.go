package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"os/signal"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"

	"cloud.google.com/go/pubsub"
)

type Message struct {
	OrderID string `json:"order_id"`
	Tenant  string `json:"tenant"`
	Type    string `json:"type"`
	Amount  int    `json:"amount"`
}

var messageCount atomic.Int64

func main() {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	projectID := getEnv("PUBSUB_PROJECT_ID", "test-project")
	appName := getEnv("APP_NAME", "pubsub-consumer")

	// Collect subscriptions from env vars. If PUBSUB_SUBSCRIPTIONS is set
	// (comma-separated), use that. Otherwise check PUBSUB_SUBSCRIPTION,
	// then fall back to looking for SUBSCRIPTION_A, SUBSCRIPTION_B, etc.
	subs := collectSubscriptions()
	if len(subs) == 0 {
		log.Fatal("No subscriptions found. Set PUBSUB_SUBSCRIPTION, PUBSUB_SUBSCRIPTIONS, or SUBSCRIPTION_A/SUBSCRIPTION_B env vars.")
	}

	log.Println("Pub/Sub Consumer starting...")
	log.Printf("  App:           %s", appName)
	log.Printf("  Project:       %s", projectID)
	for label, subID := range subs {
		log.Printf("  Subscription:  %s = %s", label, subID)
	}

	if emulatorHost := os.Getenv("PUBSUB_EMULATOR_HOST"); emulatorHost != "" {
		log.Printf("  Emulator:      %s", emulatorHost)
	}

	client, err := pubsub.NewClient(ctx, projectID)
	if err != nil {
		log.Fatalf("Failed to create Pub/Sub client: %v", err)
	}
	defer client.Close()

	for label, subID := range subs {
		sub := client.Subscription(subID)
		exists, err := sub.Exists(ctx)
		if err != nil {
			log.Fatalf("Failed to check subscription %s: %v", subID, err)
		}
		if !exists {
			log.Fatalf("Subscription %s (%s) does not exist in project %s", subID, label, projectID)
		}
	}

	log.Println("Listening for messages...")

	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)

	go func() {
		<-sigChan
		log.Printf("Shutting down (processed %d messages)", messageCount.Load())
		cancel()
	}()

	var wg sync.WaitGroup
	for label, subID := range subs {
		wg.Add(1)
		go func(label, subID string) {
			defer wg.Done()
			sub := client.Subscription(subID)
			err := sub.Receive(ctx, func(_ context.Context, msg *pubsub.Message) {
				count := messageCount.Add(1)
				processMessage(appName, label, count, msg)
				msg.Ack()
			})
			if err != nil && ctx.Err() == nil {
				log.Printf("Receive error on %s (%s): %v", subID, label, err)
			}
		}(label, subID)
	}
	wg.Wait()
}

// collectSubscriptions returns a map of label -> subscription ID from env vars.
func collectSubscriptions() map[string]string {
	result := make(map[string]string)

	if csv := os.Getenv("PUBSUB_SUBSCRIPTIONS"); csv != "" {
		for _, s := range strings.Split(csv, ",") {
			s = strings.TrimSpace(s)
			if s != "" {
				result[s] = s
			}
		}
		return result
	}

	if s := os.Getenv("PUBSUB_SUBSCRIPTION"); s != "" {
		result["PUBSUB_SUBSCRIPTION"] = s
		return result
	}

	for _, envVar := range []string{"SUBSCRIPTION_A", "SUBSCRIPTION_B", "SUBSCRIPTION_C", "SUBSCRIPTION_D"} {
		if s := os.Getenv(envVar); s != "" {
			result[envVar] = s
		}
	}
	return result
}

func processMessage(appName, label string, count int64, msg *pubsub.Message) {
	attrs := formatAttributes(msg.Attributes)

	var parsed Message
	if err := json.Unmarshal(msg.Data, &parsed); err != nil {
		log.Printf("[MSG #%d] app=%s sub=%s body=%s attrs={%s}", count, appName, label, string(msg.Data), attrs)
		return
	}

	log.Printf("[MSG #%d] app=%s sub=%s order=%s tenant=%s type=%s amount=$%d attrs={%s}",
		count, appName, label, parsed.OrderID, parsed.Tenant, parsed.Type, parsed.Amount, attrs)
}

func formatAttributes(attrs map[string]string) string {
	if len(attrs) == 0 {
		return ""
	}
	keys := make([]string, 0, len(attrs))
	for k := range attrs {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	parts := make([]string, len(keys))
	for i, k := range keys {
		parts[i] = fmt.Sprintf("%s=%s", k, attrs[k])
	}
	return strings.Join(parts, ", ")
}

func getEnv(key, fallback string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return fallback
}
