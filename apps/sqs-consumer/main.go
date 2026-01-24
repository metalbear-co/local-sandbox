package main

import (
	"context"
	"encoding/json"
	"log"
	"os"
	"os/signal"
	"syscall"
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

var (
	appName      string
	messageCount int
)

func main() {
	ctx := context.Background()
	queueName := getEnv("QUEUE_NAME", "test-queue")
	sqsEndpoint := getEnv("SQS_ENDPOINT", "")
	appName = getEnv("APP_NAME", "sqs-consumer")
	clusterName := getEnv("CLUSTER_NAME", "unknown")

	log.Println("SQS Consumer starting...")
	log.Printf("  App:      %s", appName)
	log.Printf("  Cluster:  %s", clusterName)
	log.Printf("  Queue:    %s", queueName)
	log.Printf("  Endpoint: %s", sqsEndpoint)

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

	// Get queue URL with retry
	var queueURL string
	for i := 0; i < 30; i++ {
		urlResp, err := client.GetQueueUrl(ctx, &sqs.GetQueueUrlInput{
			QueueName: aws.String(queueName),
		})
		if err != nil {
			log.Printf("Waiting for queue '%s' (attempt %d/30)", queueName, i+1)
			time.Sleep(2 * time.Second)
			continue
		}
		queueURL = *urlResp.QueueUrl
		break
	}

	if queueURL == "" {
		log.Fatalf("Failed to get queue URL after 30 attempts")
	}

	log.Printf("Connected: %s", queueURL)
	log.Println("Listening for messages...")

	// Setup signal handling
	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)

	// Poll loop
	for {
		select {
		case <-sigChan:
			log.Printf("Shutting down (processed %d messages)", messageCount)
			return
		default:
			receiveMessages(ctx, client, queueURL)
		}
	}
}

func receiveMessages(ctx context.Context, client *sqs.Client, queueURL string) {
	resp, err := client.ReceiveMessage(ctx, &sqs.ReceiveMessageInput{
		QueueUrl:              aws.String(queueURL),
		MaxNumberOfMessages:   10,
		WaitTimeSeconds:       20,
		MessageAttributeNames: []string{"All"},
	})
	if err != nil {
		log.Printf("Receive error: %v", err)
		return
	}

	for _, msg := range resp.Messages {
		messageCount++
		processMessage(msg, messageCount)

		// Delete message
		_, err := client.DeleteMessage(ctx, &sqs.DeleteMessageInput{
			QueueUrl:      aws.String(queueURL),
			ReceiptHandle: msg.ReceiptHandle,
		})
		if err != nil {
			log.Printf("Delete error: %v", err)
		}
	}
}

func processMessage(msg types.Message, count int) {
	// Parse message body
	var parsedMsg Message
	if err := json.Unmarshal([]byte(*msg.Body), &parsedMsg); err != nil {
		// If not JSON, just show raw body
		log.Printf("[MSG #%d] app=%s body=%s", count, appName, *msg.Body)
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

	log.Printf("[MSG #%d] app=%s order=%s tenant=%s type=%s amount=$%d",
		count, appName, parsedMsg.OrderID, tenant, msgType, parsedMsg.Amount)
}

func getEnv(key, fallback string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return fallback
}
