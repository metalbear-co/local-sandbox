package main

import (
	"context"
	"errors"
	"fmt"
	"log"
	"os"
	"os/signal"
	"sort"
	"strings"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/nats-io/nats.go"
	"github.com/nats-io/nats.go/jetstream"
)

// Subject space the sandbox stream captures, overridable with NATS_SUBJECTS
// so a second sandbox stream (the config-file scenario's) does not overlap
// this one - JetStream rejects two streams capturing the same subjects. Only
// used when this app has to create the stream itself; a stream that already
// exists (including the operator-made mirrord-tmp-* streams a split session
// points us at) is left untouched.
var streamSubjects = getEnv("NATS_SUBJECTS", "orders.>")

var messageCount atomic.Int64

func main() {
	url := getEnv("NATS_URL", nats.DefaultURL)
	streamName := getEnv("NATS_STREAM", "ORDERS")
	consumerName := getEnv("NATS_CONSUMER", "orders-app")
	appName := getEnv("APP_NAME", "nats-consumer")

	// The config-file mode of real apps: names come from a mounted YAML file
	// instead of env vars. Under mirrord the read goes through the operator's
	// file-content override, so a split session sees its temporary names here.
	namesSource := "env"
	if cfgPath := os.Getenv("NATS_CONFIG_FILE"); cfgPath != "" {
		fileStream, fileConsumer, err := readNamesFromFile(cfgPath)
		if err != nil {
			log.Fatalf("Failed to read NATS_CONFIG_FILE %s: %v", cfgPath, err)
		}
		streamName, consumerName = fileStream, fileConsumer
		namesSource = cfgPath
	}

	log.Println("NATS consumer starting...")
	log.Printf("  App:      %s", appName)
	log.Printf("  URL:      %s", url)
	log.Printf("  Names:    from %s", namesSource)
	log.Printf("  Stream:   %s", streamName)
	log.Printf("  Consumer: %s", consumerName)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		<-sigChan
		log.Printf("Shutting down (processed %d messages)", messageCount.Load())
		cancel()
	}()

	nc, err := connectWithRetry(ctx, url)
	if err != nil {
		log.Fatalf("Failed to connect to NATS at %s: %v", url, err)
	}
	defer nc.Close()

	// Core pub/sub mode: NATS_SUBJECT switches the app from JetStream to a
	// plain subject subscription (the shape NATS pub/sub splitting rewrites).
	if subject := os.Getenv("NATS_SUBJECT"); subject != "" {
		log.Printf("  Subject:  %s (core pub/sub mode)", subject)
		consumePubsub(ctx, nc, subject)
		return
	}

	js, err := jetstream.New(nc)
	if err != nil {
		log.Fatalf("Failed to create JetStream context: %v", err)
	}

	cons, err := ensureConsumer(ctx, js, streamName, consumerName)
	if err != nil {
		log.Fatalf("Failed to set up stream %s / consumer %s: %v", streamName, consumerName, err)
	}

	log.Println("Listening for messages...")
	for ctx.Err() == nil {
		batch, err := cons.Fetch(10, jetstream.FetchMaxWait(5*time.Second))
		if err != nil {
			if ctx.Err() != nil {
				break
			}
			log.Printf("Fetch error: %v", err)
			time.Sleep(time.Second)
			continue
		}
		for msg := range batch.Messages() {
			count := messageCount.Add(1)
			log.Printf("received: %s (subject=%s headers={%s}) [#%d]",
				string(msg.Data()), msg.Subject(), formatHeaders(msg.Headers()), count)
			if err := msg.Ack(); err != nil {
				log.Printf("Ack failed: %v", err)
			}
		}
		if err := batch.Error(); err != nil && ctx.Err() == nil {
			log.Printf("Batch error: %v", err)
		}
	}
}

// consumePubsub subscribes to a plain (non-JetStream) subject and logs each
// message in the same format as the JetStream loop, so the test scripts grep
// both modes identically.
func consumePubsub(ctx context.Context, nc *nats.Conn, subject string) {
	messages := make(chan *nats.Msg, 64)
	sub, err := nc.ChanSubscribe(subject, messages)
	if err != nil {
		log.Fatalf("Failed to subscribe to %s: %v", subject, err)
	}
	defer func() {
		_ = sub.Unsubscribe()
	}()

	log.Println("Listening for messages...")
	for {
		select {
		case <-ctx.Done():
			return
		case msg := <-messages:
			count := messageCount.Add(1)
			log.Printf("received: %s (subject=%s headers={%s}) [#%d]",
				string(msg.Data), msg.Subject, formatHeaders(msg.Header), count)
		}
	}
}

// connectWithRetry keeps dialing until the server answers; the sandbox app can
// start before the NATS pod is ready.
func connectWithRetry(ctx context.Context, url string) (*nats.Conn, error) {
	for {
		nc, err := nats.Connect(url, nats.MaxReconnects(-1))
		if err == nil {
			return nc, nil
		}
		log.Printf("NATS not reachable yet (%v), retrying in 2s...", err)
		select {
		case <-ctx.Done():
			return nil, err
		case <-time.After(2 * time.Second):
		}
	}
}

// ensureConsumer looks up the stream and durable pull consumer, creating each
// one only when it is missing. Existing ones (in particular the temporary
// stream+consumer a mirrord split session injects via env) are used as-is.
func ensureConsumer(
	ctx context.Context,
	js jetstream.JetStream,
	streamName string,
	consumerName string,
) (jetstream.Consumer, error) {
	stream, err := js.Stream(ctx, streamName)
	if errors.Is(err, jetstream.ErrStreamNotFound) {
		log.Printf("Stream %s not found, creating it (subjects: %s)", streamName, streamSubjects)
		stream, err = js.CreateStream(ctx, jetstream.StreamConfig{
			Name:     streamName,
			Subjects: []string{streamSubjects},
		})
	}
	if err != nil {
		return nil, fmt.Errorf("stream %s: %w", streamName, err)
	}

	cons, err := stream.Consumer(ctx, consumerName)
	if errors.Is(err, jetstream.ErrConsumerNotFound) {
		log.Printf("Consumer %s not found, creating it (durable pull)", consumerName)
		cons, err = stream.CreateConsumer(ctx, jetstream.ConsumerConfig{
			Durable:   consumerName,
			AckPolicy: jetstream.AckExplicitPolicy,
		})
	}
	if err != nil {
		return nil, fmt.Errorf("consumer %s: %w", consumerName, err)
	}
	return cons, nil
}

func formatHeaders(headers nats.Header) string {
	if len(headers) == 0 {
		return ""
	}
	keys := make([]string, 0, len(headers))
	for k := range headers {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	parts := make([]string, len(keys))
	for i, k := range keys {
		parts[i] = fmt.Sprintf("%s=%s", k, strings.Join(headers[k], ","))
	}
	return strings.Join(parts, ", ")
}

func getEnv(key, fallback string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return fallback
}

// Parses the two `stream:` / `consumer:` lines out of the mounted YAML file.
// Deliberately not a YAML parser: the sandbox file is flat, and hand-matching
// keeps the app dependency-free.
func readNamesFromFile(path string) (string, string, error) {
	content, err := os.ReadFile(path)
	if err != nil {
		return "", "", err
	}
	var stream, consumer string
	for _, line := range strings.Split(string(content), "\n") {
		if value, found := strings.CutPrefix(strings.TrimSpace(line), "stream:"); found {
			stream = strings.TrimSpace(value)
		} else if value, found := strings.CutPrefix(strings.TrimSpace(line), "consumer:"); found {
			consumer = strings.TrimSpace(value)
		}
	}
	if stream == "" || consumer == "" {
		return "", "", fmt.Errorf("missing stream/consumer in %s: %q", path, string(content))
	}
	return stream, consumer, nil
}
