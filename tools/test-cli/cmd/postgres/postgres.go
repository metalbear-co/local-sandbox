package postgres

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
		return fmt.Errorf("usage: test-cli postgres <command> [arguments]")
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
		return fmt.Errorf("unknown postgres command: %s", command)
	}
}

func VerifyScenario(ctx context.Context, args []string) error {
	if len(args) < 6 {
		return fmt.Errorf("usage: verify-scenario <namespace> <scenario> <expected_users> <expected_orders> <expected_products> <mode>")
	}

	namespace := args[0]
	scenario := args[1]
	expectedUsers := args[2]
	expectedOrders := args[3]
	expectedProducts := args[4]
	mode := args[5]

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

	branchSelector := fmt.Sprintf("db-owner-name=pg-test-branch-%s", scenario)
	branchPod, err := client.GetPod(ctx, namespace, branchSelector)
	if err != nil {
		fmt.Println("Status: Branch database not ready yet")
		return fmt.Errorf("branch database not ready")
	}

	fmt.Println("Status: Branch database ready")

	// Use the branch database name based on scenario
	branchDB := fmt.Sprintf("mirrord_pg_test_%s_branch", strings.ReplaceAll(scenario, "-", "_"))
	query := "SELECT 'users' as tbl, COUNT(*) as cnt FROM users UNION SELECT 'orders', COUNT(*) FROM orders UNION SELECT 'products', COUNT(*) FROM products;"
	output, err := database.ExecPostgres(namespace, branchPod.Name, branchDB, query)
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
	actualUsers, actualOrders, actualProducts := parseCountResults(output)
	
	fmt.Printf("Expected: users=%s, orders=%s, products=%s\n", expectedUsers, expectedOrders, expectedProducts)
	fmt.Printf("Actual: users=%s, orders=%s, products=%s\n", actualUsers, actualOrders, actualProducts)

	if actualUsers != expectedUsers || actualOrders != expectedOrders || actualProducts != expectedProducts {
		fmt.Println("Result: FAILED")
		return fmt.Errorf("verification failed: expected users=%s orders=%s products=%s, got users=%s orders=%s products=%s", 
			expectedUsers, expectedOrders, expectedProducts, actualUsers, actualOrders, actualProducts)
	}

	fmt.Println("Result: PASSED")
	return nil
}

// parseCountResults parses PostgreSQL count query output
func parseCountResults(output string) (users, orders, products string) {
	users, orders, products = "?", "?", "?"
	lines := strings.Split(output, "\n")
	
	for _, line := range lines {
		fields := strings.Fields(line)
		if len(fields) >= 2 {
			if fields[0] == "users" {
				users = fields[2] // PostgreSQL has extra separators
			} else if fields[0] == "orders" {
				orders = fields[2]
			} else if fields[0] == "products" {
				products = fields[2]
			}
		}
	}
	
	return users, orders, products
}

func QuerySource(ctx context.Context, args []string) error {
	if len(args) < 2 {
		return fmt.Errorf("usage: query-source <namespace> <query>")
	}

	namespace := args[0]
	query := args[1]

	return database.QueryTablePostgres(namespace, "postgres-test", "userdb", query)
}

func QueryBranch(ctx context.Context, args []string) error {
	if len(args) < 3 {
		return fmt.Errorf("usage: query-branch <namespace> <scenario> <query>")
	}

	namespace := args[0]
	scenario := args[1]
	query := args[2]

	client, err := k8s.NewClient()
	if err != nil {
		return fmt.Errorf("failed to create k8s client: %w", err)
	}

	branchSelector := fmt.Sprintf("db-owner-name=pg-test-branch-%s", scenario)
	branchPod, err := client.GetPod(ctx, namespace, branchSelector)
	if err != nil {
		return fmt.Errorf("branch database pod not found for scenario %s: %w", scenario, err)
	}

	branchDB := fmt.Sprintf("mirrord_pg_test_%s_branch", strings.ReplaceAll(scenario, "-", "_"))
	output, err := database.ExecPostgres(namespace, branchPod.Name, branchDB, query)
	if err != nil {
		return fmt.Errorf("query failed: %w", err)
	}

	fmt.Print(output)
	return nil
}

func WaitSource(ctx context.Context, args []string) error {
	if len(args) < 1 {
		return fmt.Errorf("usage: wait-source <namespace>")
	}

	namespace := args[0]

	return wait.ForPostgresDatabase(namespace, "postgres-test", "userdb", 30)
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

