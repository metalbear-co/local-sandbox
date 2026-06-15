package main

import (
	"context"
	"encoding/json"
	"errors"
	"log"
	"os"
	"os/signal"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/credentials"
	"github.com/aws/aws-sdk-go-v2/service/sqs"
	"github.com/aws/aws-sdk-go-v2/service/sqs/types"
	"github.com/aws/smithy-go"
)

// Message represents the order message body
type Message struct {
	OrderID   string `json:"order_id"`
	Tenant    string `json:"tenant"`
	Type      string `json:"type"`
	Amount    int    `json:"amount"`
	Timestamp string `json:"timestamp"`
}

// queueConfig is one queue the consumer reads. `label` is the env var the name
// came from (e.g. QUEUE_NAME, ORDERS_QUEUE_NAME) and is shown in logs so it is
// obvious which logical queue a message arrived on. `name` is the resolved SQS
// queue name, which under a mirrord split is the patched temp queue.
type queueConfig struct {
	label string
	name  string
}

var (
	appName      string
	messageCount atomic.Int64
)

func main() {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	sqsEndpoint := getEnv("SQS_ENDPOINT", "")
	appName = getEnv("APP_NAME", "sqs-consumer")
	clusterName := getEnv("CLUSTER_NAME", "unknown")

	queues := resolveQueues()

	log.Println("SQS Consumer starting...")
	log.Printf("  App:      %s", appName)
	log.Printf("  Cluster:  %s", clusterName)
	for _, q := range queues {
		log.Printf("  Queue:    %s (from %s)", q.name, q.label)
	}
	log.Printf("  Endpoint: %s", sqsEndpoint)
	log.Printf("  AWS_REGION: %s", getEnv("AWS_REGION", "NOT SET"))

	// Check if using IRSA (web identity token)
	if tokenFile := os.Getenv("AWS_WEB_IDENTITY_TOKEN_FILE"); tokenFile != "" {
		log.Printf("  Using IRSA (token file: %s)", tokenFile)
	} else if accessKey := os.Getenv("AWS_ACCESS_KEY_ID"); accessKey != "" {
		log.Printf("  Using static credentials (key: %s...)", accessKey[:min(10, len(accessKey))])
	} else {
		log.Println("  No explicit credentials - using default chain")
	}

	// Configure AWS SDK
	var cfg aws.Config
	var err error

	if sqsEndpoint != "" {
		cfg, err = config.LoadDefaultConfig(ctx,
			config.WithRegion("us-east-1"),
			config.WithCredentialsProvider(credentials.NewStaticCredentialsProvider("test", "test", "")),
		)
	} else {
		// Explicitly set region from env var
		region := getEnv("AWS_REGION", getEnv("AWS_DEFAULT_REGION", "us-east-1"))
		log.Printf("Using AWS region: %s", region)
		cfg, err = config.LoadDefaultConfig(ctx, config.WithRegion(region))
	}

	log.Printf("AWS Config region: %s", cfg.Region)

	if err != nil {
		log.Fatalf("Failed to load config: %v", err)
	}

	// Create SQS client
	var client *sqs.Client
	if sqsEndpoint != "" {
		client = sqs.NewFromConfig(cfg, func(o *sqs.Options) {
			o.BaseEndpoint = aws.String(sqsEndpoint)
		})
	} else {
		client = sqs.NewFromConfig(cfg)
	}

	// Resolve every queue's URL before starting to read, so a typo or missing
	// queue fails fast instead of silently consuming only some of them.
	type liveQueue struct {
		label string
		url   string
	}
	var live []liveQueue
	for _, q := range queues {
		url := resolveQueueURL(ctx, client, q.name)
		if url == "" {
			log.Fatalf("Failed to get URL for queue '%s' (from %s) after retries", q.name, q.label)
		}
		log.Printf("Connected: %s", url)
		live = append(live, liveQueue{label: q.label, url: url})
	}
	log.Println("Listening for messages...")

	// Setup signal handling
	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		<-sigChan
		cancel()
	}()

	// One poll loop per queue. They share the client and a global message
	// counter; ctx cancellation from the signal handler stops them all.
	var wg sync.WaitGroup
	for _, q := range live {
		wg.Add(1)
		go func(label, url string) {
			defer wg.Done()
			for {
				select {
				case <-ctx.Done():
					return
				default:
					receiveMessages(ctx, client, label, url)
				}
			}
		}(q.label, q.url)
	}

	wg.Wait()
	log.Printf("Shutting down (processed %d messages)", messageCount.Load())
}

// resolveQueues reads the queue names the consumer should listen on. The env
// var QUEUE_ENV_VARS lists which env vars hold queue names (mirrord patches
// those same vars when splitting). Vars that are unset are skipped, so the
// single-queue setup keeps working while the multi-queue test can add more.
func resolveQueues() []queueConfig {
	envList := getEnv("QUEUE_ENV_VARS", "QUEUE_NAME,ORDERS_QUEUE_NAME")

	var queues []queueConfig
	seen := make(map[string]bool)
	for _, label := range strings.Split(envList, ",") {
		label = strings.TrimSpace(label)
		if label == "" {
			continue
		}
		name := os.Getenv(label)
		if name == "" || seen[name] {
			continue
		}
		seen[name] = true
		queues = append(queues, queueConfig{label: label, name: name})
	}

	// Backward-compatible default: if nothing was configured, fall back to the
	// single QUEUE_NAME the app has always used.
	if len(queues) == 0 {
		queues = append(queues, queueConfig{label: "QUEUE_NAME", name: getEnv("QUEUE_NAME", "test-queue")})
	}
	return queues
}

func resolveQueueURL(ctx context.Context, client *sqs.Client, queueName string) string {
	for i := 0; i < 30; i++ {
		urlResp, err := client.GetQueueUrl(ctx, &sqs.GetQueueUrlInput{
			QueueName: aws.String(queueName),
		})
		if err != nil {
			var ae smithy.APIError
			if errors.As(err, &ae) {
				log.Printf("Waiting for queue '%s' (attempt %d/30): code=%s message=%s", queueName, i+1, ae.ErrorCode(), ae.ErrorMessage())
			} else {
				log.Printf("Waiting for queue '%s' (attempt %d/30): %+v", queueName, i+1, err)
			}
			time.Sleep(2 * time.Second)
			continue
		}
		return *urlResp.QueueUrl
	}
	return ""
}

func receiveMessages(ctx context.Context, client *sqs.Client, label, queueURL string) {
	resp, err := client.ReceiveMessage(ctx, &sqs.ReceiveMessageInput{
		QueueUrl:              aws.String(queueURL),
		MaxNumberOfMessages:   10,
		WaitTimeSeconds:       20,
		MessageAttributeNames: []string{"All"},
	})
	if err != nil {
		// A cancelled context is the normal shutdown path, not an error.
		if ctx.Err() != nil {
			return
		}
		log.Printf("[%s] Receive error: %v", label, err)
		return
	}

	for _, msg := range resp.Messages {
		count := messageCount.Add(1)
		processMessage(label, msg, count)

		// Delete message
		_, err := client.DeleteMessage(ctx, &sqs.DeleteMessageInput{
			QueueUrl:      aws.String(queueURL),
			ReceiptHandle: msg.ReceiptHandle,
		})
		if err != nil {
			log.Printf("[%s] Delete error: %v", label, err)
		}
	}
}

func processMessage(label string, msg types.Message, count int64) {
	// Parse message body
	var parsedMsg Message
	if err := json.Unmarshal([]byte(*msg.Body), &parsedMsg); err != nil {
		// If not JSON, just show raw body
		log.Printf("[%s][MSG #%d] app=%s body=%s", label, count, appName, *msg.Body)
		return
	}

	// Get attributes
	tenant := ""
	msgType := ""
	if v, ok := msg.MessageAttributes["tenant"]; ok && v.StringValue != nil {
		tenant = *v.StringValue
	}
	if v, ok := msg.MessageAttributes["type"]; ok && v.StringValue != nil {
		msgType = *v.StringValue
	}

	log.Printf("[%s][MSG #%d] app=%s order=%s tenant=%s type=%s amount=$%d",
		label, count, appName, parsedMsg.OrderID, tenant, msgType, parsedMsg.Amount)
}

func getEnv(key, fallback string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return fallback
}
