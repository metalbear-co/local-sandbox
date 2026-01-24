package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"math/rand"
	"os"
	"strconv"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/credentials"
	"github.com/aws/aws-sdk-go-v2/service/sqs"
	"github.com/aws/aws-sdk-go-v2/service/sqs/types"
)

// Message represents the order message body
type Message struct {
	OrderID   string `json:"order_id"`
	Tenant    string `json:"tenant"`
	Type      string `json:"type"`
	Amount    int    `json:"amount"`
	Timestamp string `json:"timestamp"`
}

var tenants = []string{"alice", "bob", "charlie", "diana", "eve", "frank"}

func main() {
	ctx := context.Background()
	rand.Seed(time.Now().UnixNano())

	// Parse arguments: <filtered_count> <unfiltered_count>
	// Filtered = type=premium (goes to local app with mirrord filter)
	// Unfiltered = type=basic (goes to remote consumer)
	filteredCount := 5
	unfilteredCount := 5

	if len(os.Args) >= 2 {
		if n, err := strconv.Atoi(os.Args[1]); err == nil {
			filteredCount = n
		}
	}
	if len(os.Args) >= 3 {
		if n, err := strconv.Atoi(os.Args[2]); err == nil {
			unfilteredCount = n
		}
	}

	queueName := getEnv("QUEUE_NAME", "test-queue")
	sqsEndpoint := getEnv("SQS_ENDPOINT", "")

	log.Printf("Sending %d filtered (type=premium) + %d unfiltered (type=basic) = %d total", filteredCount, unfilteredCount, filteredCount+unfilteredCount)
	log.Printf("Queue: %s", queueName)

	// Configure AWS SDK
	var cfg aws.Config
	var err error

	if sqsEndpoint != "" {
		cfg, err = config.LoadDefaultConfig(ctx,
			config.WithRegion("us-east-1"),
			config.WithCredentialsProvider(credentials.NewStaticCredentialsProvider("test", "test", "")),
		)
	} else {
		cfg, err = config.LoadDefaultConfig(ctx)
	}

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

	// Create queue if needed
	if sqsEndpoint != "" {
		client.CreateQueue(ctx, &sqs.CreateQueueInput{QueueName: aws.String(queueName)})
	}

	// Get queue URL
	urlResp, err := client.GetQueueUrl(ctx, &sqs.GetQueueUrlInput{QueueName: aws.String(queueName)})
	if err != nil {
		log.Fatalf("Failed to get queue URL: %v", err)
	}
	queueURL := *urlResp.QueueUrl

	// Send filtered messages (type=premium -> goes to local app)
	log.Println("")
	log.Println("--- FILTERED (type=premium) -> local app with mirrord ---")
	for i := 1; i <= filteredCount; i++ {
		sendMessage(ctx, client, queueURL, i, "premium")
	}

	// Send unfiltered messages (type=basic -> goes to remote consumer)
	log.Println("")
	log.Println("--- UNFILTERED (type=basic) -> remote consumer ---")
	for i := 1; i <= unfilteredCount; i++ {
		sendMessage(ctx, client, queueURL, filteredCount+i, "basic")
	}

	log.Println("")
	log.Printf("Done. Sent %d messages total.", filteredCount+unfilteredCount)
}

func sendMessage(ctx context.Context, client *sqs.Client, queueURL string, num int, msgType string) {
	tenant := tenants[rand.Intn(len(tenants))]
	amount := 10 + rand.Intn(491)
	orderID := fmt.Sprintf("ORD-%04d", rand.Intn(10000))

	msg := Message{
		OrderID:   orderID,
		Tenant:    tenant,
		Type:      msgType,
		Amount:    amount,
		Timestamp: time.Now().Format(time.RFC3339),
	}

	body, _ := json.Marshal(msg)

	_, err := client.SendMessage(ctx, &sqs.SendMessageInput{
		QueueUrl:    aws.String(queueURL),
		MessageBody: aws.String(string(body)),
		MessageAttributes: map[string]types.MessageAttributeValue{
			"tenant": {DataType: aws.String("String"), StringValue: aws.String(tenant)},
			"type":   {DataType: aws.String("String"), StringValue: aws.String(msgType)},
		},
	})

	if err != nil {
		log.Printf("  [%d] FAILED: %v", num, err)
	} else {
		log.Printf("  [%d] %s tenant=%-8s type=%-7s amount=$%d", num, orderID, tenant, msgType, amount)
	}
}

func getEnv(key, fallback string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return fallback
}
