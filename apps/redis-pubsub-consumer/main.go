package main

import (
	"context"
	"fmt"
	"log"
	"os"
	"os/signal"
	"syscall"

	"github.com/redis/go-redis/v9"
)

func main() {
	channel := os.Getenv("REDIS_CHANNEL")
	if channel == "" {
		log.Fatal("REDIS_CHANNEL must be set")
	}

	redisURL := os.Getenv("REDIS_URL")
	if redisURL == "" {
		redisURL = "redis://redis-main.redis-test.svc.cluster.local:6379"
	}

	subscribeMode := os.Getenv("REDIS_SUBSCRIBE_MODE")
	if subscribeMode == "" {
		subscribeMode = "exact"
	}

	opts, err := redis.ParseURL(redisURL)
	if err != nil {
		log.Fatalf("Failed to parse REDIS_URL: %v", err)
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	client := redis.NewClient(opts)
	defer client.Close()

	fmt.Fprintf(os.Stderr, "redis-pubsub-consumer starting channel=%s url=%s mode=%s\n", channel, redisURL, subscribeMode)

	var pubsub *redis.PubSub
	switch subscribeMode {
	case "pattern":
		pubsub = client.PSubscribe(ctx, channel)
	case "sharded":
		pubsub = client.SSubscribe(ctx, channel)
	default:
		pubsub = client.Subscribe(ctx, channel)
	}
	defer pubsub.Close()

	if _, err := pubsub.Receive(ctx); err != nil {
		log.Fatalf("Subscribe failed: %v", err)
	}

	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		<-sigChan
		cancel()
	}()

	for msg := range pubsub.Channel() {
		fmt.Printf("1:%s\n", msg.Payload)
	}
}
