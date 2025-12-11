package main

import (
	"database/sql"
	"fmt"
	"log"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	_ "github.com/go-sql-driver/mysql"
)

func main() {
	log.Println("Starting MySQL app...")

	dbURL := os.Getenv("MYSQL_CONNECTION_URL")
	if dbURL == "" {
		log.Fatal("MYSQL_CONNECTION_URL environment variable is not set")
	}

	log.Printf("Connecting to database: %s", maskPassword(dbURL))

	// Parse MySQL URL (mysql://user:pass@host:port/db) to DSN format
	dsn := parseMySQLURL(dbURL)
	log.Printf("Using DSN: %s", maskPassword(dsn))

	// Connect to MySQL
	db, err := sql.Open("mysql", dsn)
	if err != nil {
		log.Fatalf("Failed to open database connection: %v", err)
	}
	defer db.Close()

	// Test connection with retries (branch databases may take a few seconds to be ready)
	maxRetries := 10
	var pingErr error
	for i := 0; i < maxRetries; i++ {
		pingErr = db.Ping()
		if pingErr == nil {
			break
		}
		if i < maxRetries-1 {
			log.Printf("Waiting for database to be ready (attempt %d/%d)...", i+1, maxRetries)
			time.Sleep(3 * time.Second)
		}
	}
	if pingErr != nil {
		log.Fatalf("Failed to connect to database after %d attempts: %v", maxRetries, pingErr)
	}

	log.Println("Connected to MySQL database")

	// Create table
	createTableQuery := `
		CREATE TABLE IF NOT EXISTS app_users (
			id INT AUTO_INCREMENT PRIMARY KEY,
			name VARCHAR(255) NOT NULL,
			created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
		)
	`

	if _, err := db.Exec(createTableQuery); err != nil {
		log.Fatalf("Failed to create table: %v", err)
	}

	log.Println("Created/verified app_users table")

	// Insert default test users if table is empty
	var count int
	err = db.QueryRow("SELECT COUNT(*) FROM app_users").Scan(&count)
	if err != nil {
		log.Fatalf("Failed to count users: %v", err)
	}

	if count == 0 {
		log.Println("Table is empty, inserting default test users...")
		defaultUsers := []string{"Alice", "Bob"}
		for _, name := range defaultUsers {
			_, err := db.Exec("INSERT INTO app_users (name) VALUES (?)", name)
			if err != nil {
				log.Printf("Warning: Failed to insert default user %s: %v", name, err)
			} else {
				log.Printf("Inserted default user: %s", name)
			}
		}
	}

	// Query all users
	rows, err := db.Query("SELECT id, name, created_at FROM app_users")
	if err != nil {
		log.Fatalf("Failed to query users: %v", err)
	}
	defer rows.Close()

	log.Println("Current users in database:")
	count = 0
	for rows.Next() {
		var id int
		var name string
		var createdAt time.Time
		if err := rows.Scan(&id, &name, &createdAt); err != nil {
			log.Printf("Error scanning row: %v", err)
			continue
		}
		count++
		log.Printf("  - ID: %d, Name: %s, Created: %s", id, name, createdAt.Format(time.RFC3339))
	}
	log.Printf("Total users: %d", count)

	// Setup signal handling
	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)

	log.Println("App is running (press Ctrl+C to stop)...")

	// Keep running
	<-sigChan
	log.Println("Shutting down...")
}

func parseMySQLURL(urlStr string) string {
	// Handle both formats:
	// - mysql://user:pass@host:port/db?params (URL format)
	// - user:pass@tcp(host:port)/db?params (DSN format)

	// If already in DSN format (contains @tcp), return as-is
	if strings.Contains(urlStr, "@tcp(") {
		return urlStr
	}

	// If not mysql:// URL, return as-is
	if !strings.HasPrefix(urlStr, "mysql://") {
		return urlStr
	}

	// Remove mysql:// prefix
	urlStr = strings.TrimPrefix(urlStr, "mysql://")

	// Split by @ to separate credentials from host/db
	atIdx := strings.Index(urlStr, "@")
	if atIdx == -1 {
		log.Printf("Warning: Invalid MySQL URL format (no @), using as-is")
		return urlStr
	}

	userPass := urlStr[:atIdx]
	rest := urlStr[atIdx+1:]

	// Find the first / to separate host:port from /db
	slashIdx := strings.Index(rest, "/")
	if slashIdx == -1 {
		log.Printf("Warning: Invalid MySQL URL format (no database), using as-is")
		return urlStr
	}

	hostPort := rest[:slashIdx]
	dbAndParams := rest[slashIdx+1:]

	// Build DSN format: user:pass@tcp(host:port)/db?params
	dsn := fmt.Sprintf("%s@tcp(%s)/%s", userPass, hostPort, dbAndParams)
	return dsn
}

func maskPassword(dsn string) string {
	// Simple password masking for logs
	masked := ""
	inPassword := false
	for i, c := range dsn {
		if c == ':' && i > 0 && dsn[i-1] != '/' {
			inPassword = true
			masked += ":"
			continue
		}
		if inPassword && (c == '@' || c == '/') {
			masked += "****" + string(c)
			inPassword = false
			continue
		}
		if !inPassword {
			masked += string(c)
		}
	}
	return masked
}
