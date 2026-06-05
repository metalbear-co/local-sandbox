package main

import (
	"context"
	"log"
	"os"
	"os/signal"
	"syscall"
	"time"

	"go.temporal.io/sdk/activity"
	"go.temporal.io/sdk/client"
	"go.temporal.io/sdk/worker"
	"go.temporal.io/sdk/workflow"
)

const (
	workflowType = "CheckoutWorkflow"
	activityType = "ProcessOrder"
)

func CheckoutWorkflow(ctx workflow.Context, orderID string) (string, error) {
	info := workflow.GetInfo(ctx)
	log.Printf("[WORKFLOW] workflow_id=%s workflow_type=%s order_id=%s",
		info.WorkflowExecution.ID, info.WorkflowType.Name, orderID)

	ao := workflow.ActivityOptions{StartToCloseTimeout: time.Minute}
	ctx = workflow.WithActivityOptions(ctx, ao)

	var result string
	if err := workflow.ExecuteActivity(ctx, ProcessOrder, orderID).Get(ctx, &result); err != nil {
		return "", err
	}
	return result, nil
}

func ProcessOrder(ctx context.Context, orderID string) (string, error) {
	info := activity.GetInfo(ctx)
	log.Printf("[ACTIVITY] workflow_id=%s activity_type=%s order_id=%s",
		info.WorkflowExecution.ID, info.ActivityType.Name, orderID)
	return "processed:" + orderID, nil
}

func main() {
	appName := getEnv("APP_NAME", "temporal-worker")
	address := getEnv("TEMPORAL_ADDRESS", "localhost:7233")
	namespace := getEnv("TEMPORAL_NAMESPACE", "temporal")
	taskQueue := getEnv("TEMPORAL_TASK_QUEUE", "order-checkout")

	log.Printf("Temporal worker starting")
	log.Printf("  App:        %s", appName)
	log.Printf("  Address:    %s", address)
	log.Printf("  Namespace:  %s", namespace)
	log.Printf("  Task queue: %s", taskQueue)

	c, err := client.Dial(client.Options{
		HostPort:  address,
		Namespace: namespace,
	})
	if err != nil {
		log.Fatalf("Failed to create Temporal client: %v", err)
	}
	defer c.Close()

	w := worker.New(c, taskQueue, worker.Options{})
	w.RegisterWorkflowWithOptions(CheckoutWorkflow, workflow.RegisterOptions{Name: workflowType})
	w.RegisterActivityWithOptions(ProcessOrder, activity.RegisterOptions{Name: activityType})

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	errCh := make(chan error, 1)
	go func() {
		errCh <- w.Run(worker.InterruptCh())
	}()

	select {
	case <-ctx.Done():
		log.Println("Shutting down worker...")
		w.Stop()
		<-errCh
	case err := <-errCh:
		if err != nil {
			log.Fatalf("Worker failed: %v", err)
		}
	}
}

func getEnv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
