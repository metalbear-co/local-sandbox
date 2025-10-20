package main

import (
	"context"
	"log"
	"os"
	"os/signal"
	"syscall"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/sqs"
)

func main() {
	ctx := context.Background()
	queueName := getEnv("QUEUE_NAME", "TestQueue")

	log.Printf("Starting SQS consumer for queue: %s", queueName)

	cfg, err := config.LoadDefaultConfig(ctx)
	if err != nil {
		log.Fatalf("Failed to load config: %v", err)
	}

	client := sqs.NewFromConfig(cfg)

	// Get queue URL
	urlResp, err := client.GetQueueUrl(ctx, &sqs.GetQueueUrlInput{
		QueueName: aws.String(queueName),
	})
	if err != nil {
		log.Fatalf("Failed to get queue URL: %v", err)
	}

	queueURL := *urlResp.QueueUrl
	log.Printf("Queue URL: %s", queueURL)

	// Setup signal handling
	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)

	// Poll loop
	for {
		select {
		case <-sigChan:
			log.Println("Shutting down...")
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
		log.Printf("=== Message Received ===")
		log.Printf("ID: %s", *msg.MessageId)
		log.Printf("Body: %s", *msg.Body)
		
		if len(msg.MessageAttributes) > 0 {
			log.Printf("Attributes:")
			for k, v := range msg.MessageAttributes {
				log.Printf("  %s: %s", k, *v.StringValue)
			}
		}

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

func getEnv(key, fallback string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return fallback
}

