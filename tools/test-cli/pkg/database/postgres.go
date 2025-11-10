package database

import (
	"fmt"
	"os/exec"
	"strings"
)

// ExecPostgres executes a PostgreSQL query using kubectl exec
func ExecPostgres(namespace, podName, database, query string) (string, error) {
	cmd := exec.Command("kubectl", "exec", "-n", namespace, podName, "--",
		"psql", "-U", "postgres", "-d", database,
		"-c", query)

	output, err := cmd.CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("postgres query failed: %w\nOutput: %s", err, string(output))
	}

	return string(output), nil
}

// QueryTablePostgres executes a query and returns output
func QueryTablePostgres(namespace, podName, database, query string) error {
	output, err := ExecPostgres(namespace, podName, database, query)
	if err != nil {
		return err
	}

	for _, line := range strings.Split(strings.TrimSpace(output), "\n") {
		fmt.Println(line)
	}
	return nil
}

