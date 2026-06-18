package main

import (
	"fmt"
	"log"
	"os"
	"os/signal"
	"sync"
	"syscall"
	"time"

	amqp "github.com/rabbitmq/amqp091-go"
)

func consumeQueue(conn *amqp.Connection, queueName string, queueNum int, printHeaders bool, wg *sync.WaitGroup) {
	defer wg.Done()

	ch, err := conn.Channel()
	if err != nil {
		fmt.Fprintf(os.Stderr, "Failed to open channel for queue %s: %v\n", queueName, err)
		return
	}
	defer ch.Close()

	msgs, err := ch.Consume(
		queueName,
		"",    // consumer tag
		true,  // auto-ack
		false, // exclusive
		false, // no-local
		false, // no-wait
		nil,   // args
	)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Failed to start consuming from queue %s: %v\n", queueName, err)
		return
	}

	fmt.Fprintf(os.Stderr, "Consuming from queue %s (%d)\n", queueName, queueNum)

	for msg := range msgs {
		fmt.Printf("%d:%s\n", queueNum, string(msg.Body))
		if printHeaders {
			for key, val := range msg.Headers {
				fmt.Printf("%d:header:%s=%v\n", queueNum, key, val)
			}
		}
	}
}

// runSession connects, starts one consumer per queue, and blocks until either
// the connection drops or a shutdown is requested. It returns true only when
// shutdown was requested, so the caller knows to stop instead of reconnecting.
func runSession(amqpURL, q1Name, q2Name string, printHeaders bool, shutdown <-chan struct{}) bool {
	conn, err := amqp.Dial(amqpURL)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Failed to connect to RabbitMQ at %s: %v\n", amqpURL, err)
		return false
	}
	defer conn.Close()

	fmt.Fprintf(os.Stderr, "Connected to RabbitMQ at %s\n", amqpURL)

	var wg sync.WaitGroup
	wg.Add(1)
	go consumeQueue(conn, q1Name, 1, printHeaders, &wg)
	if q2Name != "" {
		wg.Add(1)
		go consumeQueue(conn, q2Name, 2, printHeaders, &wg)
	}

	// mirrord tunnels this connection through the session agent. When the
	// operator is upgraded the agent is recreated, which tears the tunnel down
	// and closes this connection. Watch for that so we can redial and keep
	// draining the same per-session queues across the upgrade.
	closed := conn.NotifyClose(make(chan *amqp.Error, 1))

	select {
	case <-shutdown:
		conn.Close()
		wg.Wait()
		return true
	case err := <-closed:
		fmt.Fprintf(os.Stderr, "RabbitMQ connection closed (%v), reconnecting...\n", err)
		wg.Wait()
		return false
	}
}

func main() {
	amqpURL := os.Getenv("RABBIT_MQ_URL")
	if amqpURL == "" {
		amqpURL = "amqp://guest:guest@localhost:5672/"
	}

	q1Name := os.Getenv("RABBIT_MQ_INVENTORY_QUEUE")
	q2Name := os.Getenv("RABBIT_MQ_ORDERS_QUEUE")

	if q1Name == "" {
		log.Fatal("RABBIT_MQ_INVENTORY_QUEUE must be set")
	}

	_, printHeaders := os.LookupEnv("RMQ_TEST_PRINT_HEADERS")

	shutdown := make(chan struct{})
	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		<-sigChan
		fmt.Fprintln(os.Stderr, "Received shutdown signal")
		close(shutdown)
	}()

	for {
		if runSession(amqpURL, q1Name, q2Name, printHeaders, shutdown) {
			return
		}
		select {
		case <-shutdown:
			return
		case <-time.After(2 * time.Second):
		}
	}
}
