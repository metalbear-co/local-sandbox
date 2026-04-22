package main

import (
	"context"
	"encoding/json"
	"errors"
	"log"
	"os"
	"os/signal"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/credentials"
	"github.com/aws/aws-sdk-go-v2/service/sqs"
	"github.com/aws/smithy-go"
)

type Message struct {
	OrderID string `json:"order_id"`
	Type    string `json:"type"`
	Amount  int    `json:"amount"`
}

var messageCount atomic.Int64

func main() {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	sqsEndpoint := getEnv("SQS_ENDPOINT", "")
	appName := getEnv("APP_NAME", "sqs-multi-consumer")

	log.Println("SQS Multi-Consumer starting...")
	log.Printf("  App: %s", appName)

	// The queue registry maps QUEUE_A, QUEUE_B, QUEUE_C to the original
	// queue names. The mirrord layer overrides them to user temp queues,
	// and the workload patch overrides them to main temp queues.
	queues := []struct {
		envVar   string
		fallback string
	}{
		{"QUEUE_A", "queue-a"},
		{"QUEUE_B", "queue-b"},
		{"QUEUE_C", "queue-c"},
	}

	for _, q := range queues {
		log.Printf("  %s: %s", q.envVar, getEnv(q.envVar, q.fallback))
	}
	log.Printf("  Endpoint: %s", sqsEndpoint)
	log.Printf("  AWS_REGION: %s", getEnv("AWS_REGION", "NOT SET"))

	if accessKey := os.Getenv("AWS_ACCESS_KEY_ID"); accessKey != "" {
		log.Printf("  Using static credentials (key: %s...)", accessKey[:min(10, len(accessKey))])
	} else {
		log.Println("  No explicit credentials - using default chain")
	}

	var cfg aws.Config
	var err error

	if sqsEndpoint != "" {
		cfg, err = config.LoadDefaultConfig(ctx,
			config.WithRegion("us-east-1"),
			config.WithCredentialsProvider(credentials.NewStaticCredentialsProvider("test", "test", "")),
		)
	} else {
		region := getEnv("AWS_REGION", getEnv("AWS_DEFAULT_REGION", "us-east-1"))
		cfg, err = config.LoadDefaultConfig(ctx, config.WithRegion(region))
	}
	if err != nil {
		log.Fatalf("Failed to load config: %v", err)
	}

	var client *sqs.Client
	if sqsEndpoint != "" {
		client = sqs.NewFromConfig(cfg, func(o *sqs.Options) {
			o.BaseEndpoint = aws.String(sqsEndpoint)
		})
	} else {
		client = sqs.NewFromConfig(cfg)
	}

	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)

	var wg sync.WaitGroup

	for _, q := range queues {
		queueName := getEnv(q.envVar, q.fallback)
		label := q.envVar
		wg.Add(1)
		go func() {
			defer wg.Done()
			pollQueue(ctx, client, queueName, label, appName)
		}()
	}

	log.Println("Listening for messages on all queues...")

	<-sigChan
	log.Printf("Shutting down (processed %d messages)", messageCount.Load())
	cancel()
	wg.Wait()
}

func pollQueue(ctx context.Context, client *sqs.Client, queueName, label, appName string) {
	var queueURL string
	for i := 0; i < 30; i++ {
		urlResp, err := client.GetQueueUrl(ctx, &sqs.GetQueueUrlInput{
			QueueName: aws.String(queueName),
		})
		if err != nil {
			if ctx.Err() != nil {
				return
			}
			var ae smithy.APIError
			if errors.As(err, &ae) {
				log.Printf("[%s] Waiting for queue '%s' (attempt %d/30): code=%s message=%s",
					label, queueName, i+1, ae.ErrorCode(), ae.ErrorMessage())
			} else {
				log.Printf("[%s] Waiting for queue '%s' (attempt %d/30): %+v",
					label, queueName, i+1, err)
			}
			time.Sleep(2 * time.Second)
			continue
		}
		queueURL = *urlResp.QueueUrl
		break
	}

	if queueURL == "" {
		log.Printf("[%s] Failed to get queue URL for '%s' after 30 attempts", label, queueName)
		return
	}

	log.Printf("[%s] Connected: %s", label, queueURL)

	for {
		if ctx.Err() != nil {
			return
		}

		resp, err := client.ReceiveMessage(ctx, &sqs.ReceiveMessageInput{
			QueueUrl:              aws.String(queueURL),
			MaxNumberOfMessages:   10,
			WaitTimeSeconds:       5,
			MessageAttributeNames: []string{"All"},
		})
		if err != nil {
			if ctx.Err() != nil {
				return
			}
			log.Printf("[%s] Receive error: %v", label, err)
			continue
		}

		for _, msg := range resp.Messages {
			count := messageCount.Add(1)

			var parsedMsg Message
			if err := json.Unmarshal([]byte(*msg.Body), &parsedMsg); err != nil {
				log.Printf("[MSG #%d] queue=%s app=%s body=%s", count, label, appName, *msg.Body)
			} else {
				msgType := ""
				if v, ok := msg.MessageAttributes["type"]; ok && v.StringValue != nil {
					msgType = *v.StringValue
				}
				log.Printf("[MSG #%d] queue=%s app=%s order=%s type=%s amount=$%d",
					count, label, appName, parsedMsg.OrderID, msgType, parsedMsg.Amount)
			}

			_, err := client.DeleteMessage(ctx, &sqs.DeleteMessageInput{
				QueueUrl:      aws.String(queueURL),
				ReceiptHandle: msg.ReceiptHandle,
			})
			if err != nil {
				log.Printf("[%s] Delete error: %v", label, err)
			}
		}
	}
}

func getEnv(key, fallback string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return fallback
}
