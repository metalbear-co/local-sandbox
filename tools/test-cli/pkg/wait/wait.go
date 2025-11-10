package wait

import (
	"fmt"
	"strings"
	"time"

	"github.com/metalbear-co/test-cli/pkg/database"
)

// ForDatabase waits for a database to be ready by attempting connections
func ForDatabase(namespace, podName, password string, maxAttempts int) error {
	fmt.Println("Waiting for database initialization...")
	time.Sleep(5 * time.Second)

	for i := 1; i <= maxAttempts; i++ {
		_, err := database.ExecMySQL(namespace, podName, password, "", "SELECT 1")
		if err == nil {
			fmt.Println("Database is ready")
			return nil
		}

		fmt.Printf("Still initializing... (%d/%d)\n", i, maxAttempts)
		time.Sleep(2 * time.Second)
	}

	return fmt.Errorf("timeout waiting for database to be ready")
}

// ForDatabaseWithCheck waits and verifies database contains expected data
func ForDatabaseWithCheck(namespace, podName, password, expectedDB string) error {
	time.Sleep(2 * time.Second)

	output, err := database.ExecMySQL(namespace, podName, password, "", "SHOW DATABASES")
	if err != nil || !strings.Contains(output, expectedDB) {
		fmt.Println("Status: Database still initializing...")
		return fmt.Errorf("database not ready")
	}

	fmt.Println("Status: Ready")
	return nil
}

// ForPostgresDatabase waits for a Postgres database to be ready
func ForPostgresDatabase(namespace, podName, dbName string, maxAttempts int) error {
	fmt.Println("Waiting for database initialization...")
	time.Sleep(5 * time.Second)

	for i := 1; i <= maxAttempts; i++ {
		_, err := database.ExecPostgres(namespace, podName, dbName, "SELECT 1")
		if err == nil {
			fmt.Println("Database is ready")
			return nil
		}

		fmt.Printf("Still initializing... (%d/%d)\n", i, maxAttempts)
		time.Sleep(2 * time.Second)
	}

	return fmt.Errorf("timeout waiting for database to be ready")
}

