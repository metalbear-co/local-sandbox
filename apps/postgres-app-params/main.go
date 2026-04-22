package main

import (
	"database/sql"
	"fmt"
	"log"
	"os"
	"os/signal"
	"syscall"
	"time"

	_ "github.com/lib/pq"
)

// Reads each connection parameter from its own env var. Used to test the
// db_branches "literal value" config form: the target pod is intentionally
// deployed WITHOUT DB_PASSWORD, and the mirrord config provides the password
// via { "env_var_name": "DB_PASSWORD", "value": "postgres" }. The app should
// then see DB_PASSWORD in its environment (resolved through the credential
// Secret created by the operator) and connect successfully to the branch.
func main() {
	log.Println("Starting PostgreSQL params app...")

	host := mustGetEnv("DB_HOST")
	port := mustGetEnv("DB_PORT")
	user := mustGetEnv("DB_USER")
	password := mustGetEnv("DB_PASSWORD")
	database := mustGetEnv("DB_NAME")

	log.Printf("DB_HOST=%s DB_PORT=%s DB_USER=%s DB_NAME=%s DB_PASSWORD=%s",
		host, port, user, database, mask(password))

	dsn := fmt.Sprintf(
		"host=%s port=%s user=%s password=%s dbname=%s sslmode=disable",
		host, port, user, password, database,
	)

	db, err := sql.Open("postgres", dsn)
	if err != nil {
		log.Fatalf("sql.Open failed: %v", err)
	}
	defer db.Close()

	var pingErr error
	for i := 0; i < 10; i++ {
		pingErr = db.Ping()
		if pingErr == nil {
			break
		}
		log.Printf("Waiting for database (attempt %d/10): %v", i+1, pingErr)
		time.Sleep(3 * time.Second)
	}
	if pingErr != nil {
		log.Fatalf("Failed to connect: %v", pingErr)
	}
	log.Println("Connected to PostgreSQL branch")

	var version string
	if err := db.QueryRow("SELECT version()").Scan(&version); err != nil {
		log.Fatalf("SELECT version() failed: %v", err)
	}
	log.Printf("Server version: %s", version)

	rows, err := db.Query("SELECT id, name FROM users ORDER BY id LIMIT 5")
	if err != nil {
		log.Fatalf("SELECT users failed: %v", err)
	}
	defer rows.Close()

	count := 0
	for rows.Next() {
		var id int
		var name string
		if err := rows.Scan(&id, &name); err != nil {
			log.Printf("scan error: %v", err)
			continue
		}
		log.Printf("user %d: %s", id, name)
		count++
	}
	log.Printf("Read %d rows from users (literal-value flow worked)", count)

	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)
	log.Println("Running. Press Ctrl+C to exit.")
	<-sigChan
	log.Println("Shutting down.")
}

func mustGetEnv(name string) string {
	v := os.Getenv(name)
	if v == "" {
		log.Fatalf("required env var %s is not set", name)
	}
	return v
}

func mask(s string) string {
	if len(s) <= 2 {
		return "***"
	}
	return s[:1] + "***" + s[len(s)-1:]
}
