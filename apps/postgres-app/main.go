package main

import (
	"database/sql"
	"log"
	"net/url"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	_ "github.com/lib/pq"
)

func main() {
	log.Println("Starting PostgreSQL app...")

	dbURL := os.Getenv("DATABASE_URL")
	if dbURL == "" {
		// Params-style scenarios (e.g. the roles scenario) carry the connection as
		// individual DB_* vars, like apps that build their own connection string.
		host := os.Getenv("DB_HOST")
		if host == "" {
			log.Fatal("Neither DATABASE_URL nor DB_HOST environment variables are set")
		}
		dbURL = "postgres://" + url.UserPassword(os.Getenv("DB_USER"), os.Getenv("DB_PASSWORD")).String() +
			"@" + host + ":" + os.Getenv("DB_PORT") + "/" + os.Getenv("DB_NAME")
		log.Println("DATABASE_URL not set, built connection string from DB_* variables")
	}

	// Add sslmode=disable to the connection string if not already present
	if !strings.Contains(dbURL, "sslmode=") {
		if strings.Contains(dbURL, "?") {
			dbURL += "&sslmode=disable"
		} else {
			dbURL += "?sslmode=disable"
		}
	}

	log.Printf("Connecting to database: %s", maskPassword(dbURL))

	// Connect to PostgreSQL
	db, err := sql.Open("postgres", dbURL)
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

	log.Println("Connected to PostgreSQL database")

	// Show which role this session actually runs as - the visible difference between
	// the roles modes (branch superuser vs the app's own role).
	var currentUser string
	var isSuperuser bool
	if err := db.QueryRow(
		"SELECT current_user, rolsuper FROM pg_roles WHERE rolname = current_user",
	).Scan(&currentUser, &isSuperuser); err != nil {
		log.Printf("Warning: failed to read session identity: %v", err)
	} else {
		log.Printf("Session identity: user=%s superuser=%t", currentUser, isSuperuser)
	}

	// Create table
	createTableQuery := `
		CREATE TABLE IF NOT EXISTS app_users (
			id SERIAL PRIMARY KEY,
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
		defaultUsers := []string{"Alice", "Bob", "Charlie"}
		for _, name := range defaultUsers {
			_, err := db.Exec("INSERT INTO app_users (name) VALUES ($1)", name)
			if err != nil {
				log.Printf("Warning: Failed to insert default user %s: %v", name, err)
			} else {
				log.Printf("Inserted default user: %s", name)
			}
		}
	}

	// Query all users
	rows, err := db.Query("SELECT id, name, created_at FROM app_users ORDER BY id")
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

func maskPassword(dsn string) string {
	// Simple password masking for logs
	// For postgresql://user:password@host:port/db
	// or postgres://user:password@host:port/db

	masked := ""
	inPassword := false

	for i, c := range dsn {
		if c == ':' && i > 0 && strings.HasPrefix(dsn[:i+1], "postgres") {
			// This is the protocol separator (postgres://), not password
			masked += string(c)
			continue
		}

		if c == ':' && i > 0 && !inPassword {
			// Start of password
			inPassword = true
			masked += ":"
			continue
		}

		if inPassword && c == '@' {
			// End of password
			masked += "****@"
			inPassword = false
			continue
		}

		if !inPassword {
			masked += string(c)
		}
	}

	return masked
}
