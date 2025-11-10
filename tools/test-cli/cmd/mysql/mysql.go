package mysql

import (
	"context"
	"fmt"
	"strings"
	"time"

	"github.com/metalbear-co/test-cli/pkg/database"
	"github.com/metalbear-co/test-cli/pkg/k8s"
	"github.com/metalbear-co/test-cli/pkg/wait"
)

func Handle(ctx context.Context, args []string) error {
	if len(args) < 1 {
		return fmt.Errorf("usage: test-cli mysql <command> [arguments]")
	}

	command := args[0]
	cmdArgs := args[1:]

	switch command {
	case "verify-scenario":
		return VerifyScenario(ctx, cmdArgs)
	case "query-source":
		return QuerySource(ctx, cmdArgs)
	case "query-branch":
		return QueryBranch(ctx, cmdArgs)
	case "wait-source":
		return WaitSource(ctx, cmdArgs)
	case "wait-namespace-deletion":
		return WaitNamespaceDeletion(ctx, cmdArgs)
	default:
		return fmt.Errorf("unknown mysql command: %s", command)
	}
}

func VerifyScenario(ctx context.Context, args []string) error {
	if len(args) < 6 {
		return fmt.Errorf("usage: verify-scenario <namespace> <scenario> <expected_users> <expected_orders> <mode> <password>")
	}

	namespace := args[0]
	scenario := args[1]
	expectedUsers := args[2]
	expectedOrders := args[3]
	mode := args[4]
	password := args[5]

	client, err := k8s.NewClient()
	if err != nil {
		return fmt.Errorf("failed to create k8s client: %w", err)
	}

	if mode != "" {
		fmt.Printf("Scenario: %s (%s)\n", scenario, mode)
	} else {
		fmt.Printf("Scenario: %s\n", scenario)
	}

	scenarioSelector := fmt.Sprintf("test-scenario=%s", scenario)
	_, err = client.GetPod(ctx, namespace, scenarioSelector)
	if err != nil {
		fmt.Println("WARNING: Scenario pod not found")
		return fmt.Errorf("scenario pod not found")
	}

	branchSelector := fmt.Sprintf("db-owner-name=mysql-test-branch-%s", scenario)
	branchPod, err := client.GetPod(ctx, namespace, branchSelector)
	if err != nil {
		fmt.Println("Status: Branch database not ready yet")
		return fmt.Errorf("branch database not ready")
	}

	fmt.Println("Status: Branch database ready")

	query := "SELECT 'users' as tbl, COUNT(*) as cnt FROM users UNION SELECT 'orders', COUNT(*) FROM orders"
	output, err := database.ExecMySQL(namespace, branchPod.Name, password, "user", query)
	if err != nil {
		fmt.Println("WARNING: Query failed")
		return fmt.Errorf("query failed: %w", err)
	}

	// Print results
	lines := strings.Split(strings.TrimSpace(output), "\n")
	for _, line := range lines {
		fmt.Println(line)
	}

	// Parse results and verify
	actualUsers, actualOrders := parseCountResults(output)

	fmt.Printf("Expected: users=%s, orders=%s\n", expectedUsers, expectedOrders)
	fmt.Printf("Actual: users=%s, orders=%s\n", actualUsers, actualOrders)

	if actualUsers != expectedUsers || actualOrders != expectedOrders {
		fmt.Println("Result: FAILED")
		return fmt.Errorf("verification failed: expected users=%s orders=%s, got users=%s orders=%s",
			expectedUsers, expectedOrders, actualUsers, actualOrders)
	}

	fmt.Println("Result: PASSED")
	return nil
}

// parseCountResults parses MySQL count query output
func parseCountResults(output string) (users, orders string) {
	users, orders = "?", "?"
	lines := strings.Split(output, "\n")

	for _, line := range lines {
		fields := strings.Fields(line)
		if len(fields) >= 2 {
			if fields[0] == "users" {
				users = fields[1]
			} else if fields[0] == "orders" {
				orders = fields[1]
			}
		}
	}

	return users, orders
}

func QuerySource(ctx context.Context, args []string) error {
	if len(args) < 3 {
		return fmt.Errorf("usage: query-source <namespace> <query> <password>")
	}

	namespace := args[0]
	query := args[1]
	password := args[2]

	if err := wait.ForDatabaseWithCheck(namespace, "mysql-test", password, "user"); err != nil {
		return nil
	}

	return database.QueryTable(namespace, "mysql-test", password, "user", query)
}

func QueryBranch(ctx context.Context, args []string) error {
	if len(args) < 4 {
		return fmt.Errorf("usage: query-branch <namespace> <scenario> <query> <password>")
	}

	namespace := args[0]
	scenario := args[1]
	query := args[2]
	password := args[3]

	client, err := k8s.NewClient()
	if err != nil {
		return fmt.Errorf("failed to create k8s client: %w", err)
	}

	branchSelector := fmt.Sprintf("db-owner-name=mysql-test-branch-%s", scenario)
	branchPod, err := client.GetPod(ctx, namespace, branchSelector)
	if err != nil {
		return fmt.Errorf("branch database pod not found for scenario %s: %w", scenario, err)
	}

	output, err := database.ExecMySQL(namespace, branchPod.Name, password, "user", query)
	if err != nil {
		return fmt.Errorf("query failed: %w", err)
	}

	fmt.Print(output)
	return nil
}

func WaitSource(ctx context.Context, args []string) error {
	if len(args) < 2 {
		return fmt.Errorf("usage: wait-source <namespace> <password>")
	}

	namespace := args[0]
	password := args[1]

	return wait.ForDatabase(namespace, "mysql-test", password, 30)
}

func WaitNamespaceDeletion(ctx context.Context, args []string) error {
	if len(args) < 1 {
		return fmt.Errorf("usage: wait-namespace-deletion <namespace>")
	}

	namespace := args[0]

	client, err := k8s.NewClient()
	if err != nil {
		return fmt.Errorf("failed to create k8s client: %w", err)
	}

	if err := client.WaitForNamespaceDeletion(ctx, namespace, 120*time.Second); err != nil {
		return err
	}

	fmt.Println("Namespace deleted")
	return nil
}
