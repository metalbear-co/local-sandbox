package main

import (
	"database/sql"
	"fmt"
	"log"
	"net/url"
	"os"
	"os/signal"
	"syscall"
	"time"

	_ "github.com/microsoft/go-mssqldb"
)

func main() {
	log.Println("Starting MSSQL app...")

	dbURL := os.Getenv("DATABASE_URL")
	if dbURL == "" {
		log.Fatal("DATABASE_URL environment variable is not set")
	}

	log.Printf("Connecting to database: %s", maskPassword(dbURL))

	connStr := toSQLServerURL(dbURL)

	db, err := sql.Open("sqlserver", connStr)
	if err != nil {
		log.Fatalf("Failed to open database connection: %v", err)
	}
	defer db.Close()

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

	log.Println("Connected to MSSQL database")

	createTableQuery := `
		IF NOT EXISTS (SELECT * FROM sys.tables WHERE name = 'app_users')
		CREATE TABLE app_users (
			id INT IDENTITY(1,1) PRIMARY KEY,
			name NVARCHAR(255) NOT NULL,
			created_at DATETIME2 DEFAULT GETDATE()
		)
	`
	if _, err := db.Exec(createTableQuery); err != nil {
		log.Fatalf("Failed to create table: %v", err)
	}

	log.Println("Created/verified app_users table")

	var count int
	err = db.QueryRow("SELECT COUNT(*) FROM app_users").Scan(&count)
	if err != nil {
		log.Fatalf("Failed to count users: %v", err)
	}

	if count == 0 {
		log.Println("Table is empty, inserting default test users...")
		defaultUsers := []string{"Alice", "Bob"}
		for _, name := range defaultUsers {
			_, err := db.Exec("INSERT INTO app_users (name) VALUES (@p1)", name)
			if err != nil {
				log.Printf("Warning: Failed to insert default user %s: %v", name, err)
			} else {
				log.Printf("Inserted default user: %s", name)
			}
		}
	}

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

	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)

	log.Println("App is running (press Ctrl+C to stop)...")
	<-sigChan
	log.Println("Shutting down...")
}

// toSQLServerURL converts mssql:// URLs to sqlserver:// which is what the
// go-mssqldb driver expects. If the URL is already sqlserver://, it's
// returned as-is.
func toSQLServerURL(rawURL string) string {
	parsed, err := url.Parse(rawURL)
	if err != nil {
		log.Printf("Warning: could not parse URL, using as-is: %v", err)
		return rawURL
	}

	if parsed.Scheme == "mssql" {
		parsed.Scheme = "sqlserver"
	}

	// go-mssqldb wants the database name as a query param, not as a path
	if parsed.Path != "" && parsed.Path != "/" {
		dbName := parsed.Path[1:]
		q := parsed.Query()
		if q.Get("database") == "" {
			q.Set("database", dbName)
		}
		parsed.RawQuery = q.Encode()
		parsed.Path = ""
	}

	return parsed.String()
}

func maskPassword(dsn string) string {
	parsed, err := url.Parse(dsn)
	if err != nil {
		return dsn
	}
	if parsed.User != nil {
		if _, hasPass := parsed.User.Password(); hasPass {
			parsed.User = url.UserPassword(parsed.User.Username(), "****")
		}
	}
	return fmt.Sprintf("%s://%s@%s%s", parsed.Scheme, parsed.User, parsed.Host, parsed.Path)
}
