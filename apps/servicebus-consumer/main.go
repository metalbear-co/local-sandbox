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
	"time"

	"github.com/Azure/azure-sdk-for-go/sdk/messaging/azservicebus"
)

type Message struct {
	OrderID string `json:"order_id"`
	Tenant  string `json:"tenant"`
	Type    string `json:"type"`
	Amount  int    `json:"amount"`
}

var messageCount atomic.Int64

func main() {
	if os.Getenv("SEND_MODE") == "true" {
		sendMessage()
		return
	}
	consumeMessages()
}

func sendMessage() {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	connStr := mustEnv("SERVICEBUS_CONNECTION_STRING")
	queue := os.Getenv("SEND_QUEUE")
	topic := os.Getenv("SEND_TOPIC")
	body := getEnv("MESSAGE_BODY", `{"order_id":"ORD-001","tenant":"test-user","type":"standard","amount":100}`)
	propsRaw := os.Getenv("MESSAGE_PROPERTIES")

	client, err := azservicebus.NewClientFromConnectionString(connStr, nil)
	if err != nil {
		log.Fatalf("Failed to create client: %v", err)
	}
	defer client.Close(ctx)

	target := queue
	if topic != "" {
		target = topic
	}
	if target == "" {
		log.Fatal("Set SEND_QUEUE or SEND_TOPIC")
	}

	sender, err := client.NewSender(target, nil)
	if err != nil {
		log.Fatalf("Failed to create sender for %s: %v", target, err)
	}
	defer sender.Close(ctx)

	msg := &azservicebus.Message{
		Body: []byte(body),
	}

	if propsRaw != "" {
		props := make(map[string]interface{})
		for _, kv := range strings.Split(propsRaw, ",") {
			parts := strings.SplitN(kv, "=", 2)
			if len(parts) == 2 {
				props[strings.TrimSpace(parts[0])] = strings.TrimSpace(parts[1])
			}
		}
		msg.ApplicationProperties = props
	}

	if err := sender.SendMessage(ctx, msg, nil); err != nil {
		log.Fatalf("Failed to send message: %v", err)
	}
	log.Printf("Sent to %s: body=%s props=%s", target, body, propsRaw)
}

func consumeMessages() {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	connStr := mustEnv("SERVICEBUS_CONNECTION_STRING")
	appName := getEnv("APP_NAME", "servicebus-consumer")

	queues := collectQueues()
	topicSubs := collectTopicSubscriptions()

	if len(queues) == 0 && len(topicSubs) == 0 {
		log.Fatal("No queues or topic subscriptions configured. " +
			"Set SERVICEBUS_QUEUE_NAME, SERVICEBUS_QUEUES, QUEUE_A/QUEUE_B, " +
			"SERVICEBUS_ORDERS_QUEUE/SERVICEBUS_NOTIFICATIONS_QUEUE, " +
			"or SERVICEBUS_TOPIC_NAME + SERVICEBUS_SUBSCRIPTION_NAME.")
	}

	log.Println("Service Bus Consumer starting...")
	log.Printf("  App: %s", appName)
	for label, q := range queues {
		log.Printf("  Queue: %s = %s", label, q)
	}
	for label, ts := range topicSubs {
		log.Printf("  TopicSub: %s = %s", label, ts)
	}

	client, err := azservicebus.NewClientFromConnectionString(connStr, nil)
	if err != nil {
		log.Fatalf("Failed to create client: %v", err)
	}
	defer client.Close(ctx)

	log.Println("Listening for messages...")

	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)

	go func() {
		<-sigChan
		log.Printf("Shutting down (processed %d messages)", messageCount.Load())
		cancel()
	}()

	var wg sync.WaitGroup

	for label, queueName := range queues {
		wg.Add(1)
		go func(label, queueName string) {
			defer wg.Done()
			receiver, err := client.NewReceiverForQueue(queueName, nil)
			if err != nil {
				log.Printf("Failed to create receiver for queue %s: %v", queueName, err)
				return
			}
			defer receiver.Close(ctx)
			receiveLoop(ctx, appName, label, receiver)
		}(label, queueName)
	}

	for label, ts := range topicSubs {
		parts := strings.SplitN(ts, "/", 2)
		if len(parts) != 2 {
			log.Printf("Invalid topic/subscription format for %s: %s", label, ts)
			continue
		}
		topicName, subName := parts[0], parts[1]
		wg.Add(1)
		go func(label, topicName, subName string) {
			defer wg.Done()
			receiver, err := client.NewReceiverForSubscription(topicName, subName, nil)
			if err != nil {
				log.Printf("Failed to create receiver for %s/%s: %v", topicName, subName, err)
				return
			}
			defer receiver.Close(ctx)
			receiveLoop(ctx, appName, label, receiver)
		}(label, topicName, subName)
	}

	wg.Wait()
}

func receiveLoop(ctx context.Context, appName, label string, receiver *azservicebus.Receiver) {
	for {
		messages, err := receiver.ReceiveMessages(ctx, 10, nil)
		if err != nil {
			if ctx.Err() != nil {
				return
			}
			log.Printf("Receive error on %s: %v", label, err)
			return
		}
		for _, msg := range messages {
			count := messageCount.Add(1)
			processMessage(appName, label, count, msg)
			if err := receiver.CompleteMessage(ctx, msg, nil); err != nil {
				log.Printf("Failed to complete message on %s: %v", label, err)
			}
		}
	}
}

// collectQueues gathers queue names from environment variables.
// Priority: SERVICEBUS_QUEUES (CSV) > SERVICEBUS_QUEUE_NAME (single) > named vars.
func collectQueues() map[string]string {
	result := make(map[string]string)

	if csv := os.Getenv("SERVICEBUS_QUEUES"); csv != "" {
		for _, q := range strings.Split(csv, ",") {
			q = strings.TrimSpace(q)
			if q != "" {
				result[q] = q
			}
		}
		return result
	}

	if q := os.Getenv("SERVICEBUS_QUEUE_NAME"); q != "" {
		result["SERVICEBUS_QUEUE_NAME"] = q
		return result
	}

	for _, envVar := range []string{
		"SERVICEBUS_ORDERS_QUEUE",
		"SERVICEBUS_NOTIFICATIONS_QUEUE",
		"QUEUE_A", "QUEUE_B", "QUEUE_C", "QUEUE_D",
	} {
		if q := os.Getenv(envVar); q != "" {
			result[envVar] = q
		}
	}

	return result
}

func collectTopicSubscriptions() map[string]string {
	result := make(map[string]string)

	topic := os.Getenv("SERVICEBUS_TOPIC_NAME")
	sub := os.Getenv("SERVICEBUS_SUBSCRIPTION_NAME")
	if topic != "" && sub != "" {
		result["SERVICEBUS_TOPIC/SUBSCRIPTION"] = topic + "/" + sub
	}

	return result
}

func processMessage(appName, label string, count int64, msg *azservicebus.ReceivedMessage) {
	props := formatProperties(msg.ApplicationProperties)

	var parsed Message
	if err := json.Unmarshal(msg.Body, &parsed); err != nil {
		log.Printf("[MSG #%d] app=%s source=%s body=%s props={%s}", count, appName, label, string(msg.Body), props)
		return
	}

	log.Printf("[MSG #%d] app=%s source=%s order=%s tenant=%s type=%s amount=$%d props={%s}",
		count, appName, label, parsed.OrderID, parsed.Tenant, parsed.Type, parsed.Amount, props)
}

func formatProperties(props map[string]interface{}) string {
	if len(props) == 0 {
		return ""
	}
	keys := make([]string, 0, len(props))
	for k := range props {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	parts := make([]string, len(keys))
	for i, k := range keys {
		parts[i] = fmt.Sprintf("%s=%v", k, props[k])
	}
	return strings.Join(parts, ", ")
}

func mustEnv(key string) string {
	val := os.Getenv(key)
	if val == "" {
		log.Fatalf("Required environment variable %s is not set", key)
	}
	return val
}

func getEnv(key, fallback string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return fallback
}
