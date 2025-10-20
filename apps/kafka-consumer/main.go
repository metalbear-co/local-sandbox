package main

import (
	"context"
	"log"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/IBM/sarama"
)

func main() {
	ctx := context.Background()
	bootstrapServers := getEnv("KAFKA_BOOTSTRAP_SERVERS", "kafka-cluster.test-mirrord.svc.cluster.local:9092")
	topicName := getEnv("KAFKA_TOPIC_NAME", "test-topic")
	groupID := getEnv("KAFKA_GROUP_ID", "test-consumer-group")

	log.Printf("Starting Kafka consumer")
	log.Printf("Bootstrap servers: %s", bootstrapServers)
	log.Printf("Topic: %s", topicName)
	log.Printf("Group ID: %s", groupID)

	// Configure Sarama
	config := sarama.NewConfig()
	config.Version = sarama.V3_0_0_0
	config.Consumer.Return.Errors = true
	config.Consumer.Offsets.Initial = sarama.OffsetOldest
	config.Consumer.Group.Rebalance.Strategy = sarama.NewBalanceStrategyRoundRobin()

	// Create consumer group
	brokers := strings.Split(bootstrapServers, ",")
	consumerGroup, err := sarama.NewConsumerGroup(brokers, groupID, config)
	if err != nil {
		log.Fatalf("Failed to create consumer group: %v", err)
	}
	defer consumerGroup.Close()

	// Setup signal handling
	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)

	consumer := &Consumer{
		ready: make(chan bool),
	}

	go func() {
		for {
			// Consume should be called inside an infinite loop
			// When a server-side rebalance happens, the consumer session will need to be recreated
			if err := consumerGroup.Consume(ctx, []string{topicName}, consumer); err != nil {
				log.Printf("Error from consumer: %v", err)
			}
			// Check if context was cancelled, signaling that the consumer should stop
			if ctx.Err() != nil {
				return
			}
			consumer.ready = make(chan bool)
		}
	}()

	<-consumer.ready // Wait till consumer is ready
	log.Println("Kafka consumer is ready and running")

	// Handle errors
	go func() {
		for err := range consumerGroup.Errors() {
			log.Printf("Consumer error: %v", err)
		}
	}()

	// Wait for termination signal
	<-sigChan
	log.Println("Shutting down consumer...")
}

// Consumer represents a Sarama consumer group consumer
type Consumer struct {
	ready chan bool
}

// Setup is run at the beginning of a new session, before ConsumeClaim
func (consumer *Consumer) Setup(sarama.ConsumerGroupSession) error {
	close(consumer.ready)
	return nil
}

// Cleanup is run at the end of a session, once all ConsumeClaim goroutines have exited
func (consumer *Consumer) Cleanup(sarama.ConsumerGroupSession) error {
	return nil
}

// ConsumeClaim must start a consumer loop of ConsumerGroupClaim's Messages()
func (consumer *Consumer) ConsumeClaim(session sarama.ConsumerGroupSession, claim sarama.ConsumerGroupClaim) error {
	for {
		select {
		case message := <-claim.Messages():
			if message == nil {
				return nil
			}
			log.Printf("=== Message Received ===")
			log.Printf("Topic: %s", message.Topic)
			log.Printf("Partition: %d", message.Partition)
			log.Printf("Offset: %d", message.Offset)
			log.Printf("Key: %s", string(message.Key))
			log.Printf("Value: %s", string(message.Value))
			log.Printf("Timestamp: %s", message.Timestamp.Format(time.RFC3339))

			if len(message.Headers) > 0 {
				log.Printf("Headers:")
				for _, header := range message.Headers {
					log.Printf("  %s: %s", string(header.Key), string(header.Value))
				}
			}

			// Mark message as processed
			session.MarkMessage(message, "")

		case <-session.Context().Done():
			return nil
		}
	}
}

func getEnv(key, fallback string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return fallback
}

