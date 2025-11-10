package database

import (
	"fmt"
	"os/exec"
	"strings"
)

// ExecMySQL executes a MySQL query using kubectl exec
func ExecMySQL(namespace, podName, password, database, query string) (string, error) {
	// Use sh -c to properly handle the query with backticks and special characters
	sqlCmd := fmt.Sprintf("USE %s; %s", database, query)

	cmd := exec.Command("kubectl", "exec", "-n", namespace, podName, "--",
		"sh", "-c",
		fmt.Sprintf("mysql -u root -p%s -e %q 2>/dev/null", password, sqlCmd))

	output, err := cmd.CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("mysql query failed: %w", err)
	}

	return string(output), nil
}

// QueryTable executes a query and returns output
func QueryTable(namespace, podName, password, database, query string) error {
	output, err := ExecMySQL(namespace, podName, password, database, query)
	if err != nil {
		return err
	}

	for _, line := range strings.Split(strings.TrimSpace(output), "\n") {
		fmt.Println(line)
	}
	return nil
}
