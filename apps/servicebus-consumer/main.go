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
	"github.com/Azure/azure-sdk-for-go/sdk/messaging/azservicebus/admin"
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
	if os.Getenv("LIST_MODE") == "true" {
		listSubscriptions()
		return
	}
	if os.Getenv("CLEAN_MODE") == "true" {
		cleanSubscriptions()
		return
	}
	consumeMessages()
}

// cleanSubscriptions resets the topics in SERVICEBUS_TOPICS to a pristine
// pre-split state: every mirrord-* subscription is deleted (session leftovers,
// ingest subscriptions, auto-provisioned orphans), and on the remaining app
// subscriptions any mirrord-main rule is removed and the $Default match-all
// rule restored - a killed session can leave an app subscription with only
// mirrord-main, which blackholes the deployed consumer.
func cleanSubscriptions() {
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()

	adminClient, err := admin.NewClientFromConnectionString(mustEnv("SERVICEBUS_CONNECTION_STRING"), nil)
	if err != nil {
		log.Fatalf("Failed to create admin client: %v", err)
	}

	for _, topic := range strings.Split(mustEnv("SERVICEBUS_TOPICS"), ",") {
		topic = strings.TrimSpace(topic)
		if topic == "" {
			continue
		}
		var appSubs []string
		subsPager := adminClient.NewListSubscriptionsPager(topic, nil)
		for subsPager.More() {
			page, err := subsPager.NextPage(ctx)
			if err != nil {
				fmt.Printf("clean: failed to list %s: %v\n", topic, err)
				break
			}
			for _, sub := range page.Subscriptions {
				if strings.HasPrefix(sub.SubscriptionName, "mirrord-") {
					if _, err := adminClient.DeleteSubscription(ctx, topic, sub.SubscriptionName, nil); err != nil {
						fmt.Printf("clean: delete %s/%s failed: %v\n", topic, sub.SubscriptionName, err)
					} else {
						fmt.Printf("clean: deleted leftover %s/%s\n", topic, sub.SubscriptionName)
					}
				} else {
					appSubs = append(appSubs, sub.SubscriptionName)
				}
			}
		}

		for _, sub := range appSubs {
			hasDefault := false
			var mirrordRules []string
			rulesPager := adminClient.NewListRulesPager(topic, sub, nil)
			for rulesPager.More() {
				rulePage, err := rulesPager.NextPage(ctx)
				if err != nil {
					break
				}
				for _, rule := range rulePage.Rules {
					if rule.Name == "$Default" {
						hasDefault = true
					}
					if strings.HasPrefix(rule.Name, "mirrord") {
						mirrordRules = append(mirrordRules, rule.Name)
					}
				}
			}
			for _, rule := range mirrordRules {
				if _, err := adminClient.DeleteRule(ctx, topic, sub, rule, nil); err != nil {
					fmt.Printf("clean: delete rule %s on %s/%s failed: %v\n", rule, topic, sub, err)
				} else {
					fmt.Printf("clean: removed leftover rule %s on %s/%s\n", rule, topic, sub)
				}
			}
			if !hasDefault {
				name := "$Default"
				_, err := adminClient.CreateRule(ctx, topic, sub, &admin.CreateRuleOptions{
					Name:   &name,
					Filter: &admin.TrueFilter{},
				})
				if err != nil {
					fmt.Printf("clean: restore $Default on %s/%s failed: %v\n", topic, sub, err)
				} else {
					fmt.Printf("clean: restored $Default rule on %s/%s\n", topic, sub)
				}
			}
		}
	}
	fmt.Println("clean: done")
}

// listSubscriptions prints every subscription (with its rule names) on the
// topics in SERVICEBUS_TOPICS. Uses the data-plane management API, so it works
// against the emulator too (where `az servicebus` cannot go).
func listSubscriptions() {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	adminClient, err := admin.NewClientFromConnectionString(mustEnv("SERVICEBUS_CONNECTION_STRING"), nil)
	if err != nil {
		log.Fatalf("Failed to create admin client: %v", err)
	}

	for _, topic := range strings.Split(mustEnv("SERVICEBUS_TOPICS"), ",") {
		topic = strings.TrimSpace(topic)
		if topic == "" {
			continue
		}
		fmt.Printf("=== topic %s ===\n", topic)
		subsPager := adminClient.NewListSubscriptionsPager(topic, nil)
		for subsPager.More() {
			page, err := subsPager.NextPage(ctx)
			if err != nil {
				fmt.Printf("  (failed to list: %v)\n", err)
				break
			}
			for _, sub := range page.Subscriptions {
				var rules []string
				rulesPager := adminClient.NewListRulesPager(topic, sub.SubscriptionName, nil)
				for rulesPager.More() {
					rulePage, err := rulesPager.NextPage(ctx)
					if err != nil {
						break
					}
					for _, rule := range rulePage.Rules {
						// The rule NAME alone is misleading: the operator keeps
						// the name $Default but swaps in a routing filter, while
						// an auto-created sub's $Default is a true match-all.
						desc := rule.Name
						switch f := rule.Filter.(type) {
						case *admin.SQLFilter:
							desc = fmt.Sprintf("%s{SQL: %s}", rule.Name, f.Expression)
						case *admin.TrueFilter:
							desc = rule.Name + "{match-all}"
						case *admin.CorrelationFilter:
							desc = fmt.Sprintf("%s{corr: %v}", rule.Name, f.ApplicationProperties)
						}
						rules = append(rules, desc)
					}
				}
				fmt.Printf("  %s  [rules: %s]\n", sub.SubscriptionName, strings.Join(rules, ", "))
			}
		}
	}
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

	if os.Getenv("SERVICEBUS_AUTO_PROVISION") == "true" {
		autoProvisionSubscriptions(ctx, connStr, topicSubs)
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

// collectTopicSubscriptions gathers topic/subscription pairs the app listens on.
// Three input shapes, all merged:
//   - Indexed pairs SERVICEBUS_TOPIC_N + SERVICEBUS_SUBSCRIPTION_N (N = 1..9).
//     Each subscription lives in its own env var so queue splitting can rewrite
//     just that var to point the pod at its per-session subscription. This is
//     what the multi-topic repro uses.
//   - SERVICEBUS_TOPIC_SUBSCRIPTIONS, a CSV of `topic/subscription` pairs.
//   - The single SERVICEBUS_TOPIC_NAME/SERVICEBUS_SUBSCRIPTION_NAME pair.
func collectTopicSubscriptions() map[string]string {
	result := make(map[string]string)

	// Scan a fixed small range instead of stopping at the first gap so a missing
	// index does not silently drop later topics.
	for i := 1; i <= 9; i++ {
		topic := os.Getenv(fmt.Sprintf("SERVICEBUS_TOPIC_%d", i))
		sub := os.Getenv(fmt.Sprintf("SERVICEBUS_SUBSCRIPTION_%d", i))
		if topic == "" && sub == "" {
			continue
		}
		if topic == "" || sub == "" {
			log.Printf("Ignoring incomplete indexed pair %d (topic=%q sub=%q)", i, topic, sub)
			continue
		}
		result[topic+"/"+sub] = topic + "/" + sub
	}

	if csv := os.Getenv("SERVICEBUS_TOPIC_SUBSCRIPTIONS"); csv != "" {
		for _, pair := range strings.Split(csv, ",") {
			pair = strings.TrimSpace(pair)
			if pair == "" {
				continue
			}
			if !strings.Contains(pair, "/") {
				log.Printf("Ignoring malformed topic/subscription pair (want topic/sub): %s", pair)
				continue
			}
			result[pair] = pair
		}
	}

	topic := os.Getenv("SERVICEBUS_TOPIC_NAME")
	sub := os.Getenv("SERVICEBUS_SUBSCRIPTION_NAME")
	if topic != "" && sub != "" {
		result[topic+"/"+sub] = topic + "/" + sub
	}

	// Service-name mode: ONE subscription name, used on EVERY topic - how
	// NServiceBus/MassTransit endpoints work (the endpoint/service name is the
	// subscription name everywhere). This is the shape that breaks queue
	// splitting when a split config binds all queues to this single env var.
	topics := os.Getenv("SERVICEBUS_TOPICS")
	serviceName := os.Getenv("SERVICEBUS_SERVICE_NAME")
	if topics != "" && serviceName != "" {
		log.Printf("ServiceName mode: subscription %q on every topic (NServiceBus-style)", serviceName)
		for _, topic := range strings.Split(topics, ",") {
			topic = strings.TrimSpace(topic)
			if topic != "" {
				result[topic+"/"+serviceName] = topic + "/" + serviceName
			}
		}
	}

	return result
}

// autoProvisionSubscriptions creates each topic/subscription pair that does not
// exist yet, the way NServiceBus/MassTransit endpoint installers do on startup.
// Auto-created subscriptions get the broker's default match-everything rule -
// exactly what turns a half-redirected service name into an unfiltered orphan.
func autoProvisionSubscriptions(ctx context.Context, connStr string, topicSubs map[string]string) {
	adminClient, err := admin.NewClientFromConnectionString(connStr, nil)
	if err != nil {
		log.Printf("Auto-provision: failed to create admin client: %v", err)
		return
	}
	for _, ts := range topicSubs {
		parts := strings.SplitN(ts, "/", 2)
		if len(parts) != 2 {
			continue
		}
		topic, sub := parts[0], parts[1]
		existing, err := adminClient.GetSubscription(ctx, topic, sub, nil)
		if err != nil {
			log.Printf("Auto-provision: lookup %s/%s failed: %v", topic, sub, err)
			continue
		}
		if existing != nil {
			log.Printf("Auto-provision: %s/%s already exists", topic, sub)
			continue
		}
		if _, err := adminClient.CreateSubscription(ctx, topic, sub, nil); err != nil {
			log.Printf("Auto-provision: create %s/%s failed: %v", topic, sub, err)
			continue
		}
		log.Printf("Auto-provision: CREATED %s/%s (default match-everything rule)", topic, sub)
	}
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
