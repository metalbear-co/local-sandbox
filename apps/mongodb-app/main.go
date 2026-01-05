package main

import (
	"context"
	"log"
	"os"
	"os/signal"
	"syscall"
	"time"

	"go.mongodb.org/mongo-driver/bson"
	"go.mongodb.org/mongo-driver/mongo"
	"go.mongodb.org/mongo-driver/mongo/options"
)

type User struct {
	ID    int    `bson:"id"`
	Name  string `bson:"name"`
	Email string `bson:"email"`
	Age   int    `bson:"age"`
}

type Order struct {
	ID     int     `bson:"id"`
	UserID int     `bson:"user_id"`
	Amount float64 `bson:"amount"`
	Status string  `bson:"status"`
}

type Product struct {
	ID    int     `bson:"id"`
	Name  string  `bson:"name"`
	Price float64 `bson:"price"`
}

func main() {
	log.Println("Starting MongoDB app...")

	dbURL := os.Getenv("DATABASE_URL")
	if dbURL == "" {
		log.Fatal("DATABASE_URL environment variable is not set")
	}

	log.Printf("Connecting to database: %s", maskPassword(dbURL))

	// Connect to MongoDB with retries
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	clientOptions := options.Client().ApplyURI(dbURL)
	var client *mongo.Client
	var err error

	maxRetries := 10
	for i := 0; i < maxRetries; i++ {
		client, err = mongo.Connect(ctx, clientOptions)
		if err == nil {
			err = client.Ping(ctx, nil)
			if err == nil {
				break
			}
		}
		if i < maxRetries-1 {
			log.Printf("Waiting for database to be ready (attempt %d/%d): %v", i+1, maxRetries, err)
			time.Sleep(3 * time.Second)
		}
	}
	if err != nil {
		log.Fatalf("Failed to connect to MongoDB after %d attempts: %v", maxRetries, err)
	}
	defer client.Disconnect(context.Background())

	log.Println("Connected to MongoDB database")

	// Get database name from URL or use default
	dbName := os.Getenv("MONGODB_DATABASE")
	if dbName == "" {
		dbName = "source_db"
	}
	db := client.Database(dbName)

	// List collections
	collections, err := db.ListCollectionNames(ctx, bson.M{})
	if err != nil {
		log.Printf("Warning: Failed to list collections: %v", err)
	} else {
		log.Printf("Collections in database: %v", collections)
	}

	// Query users
	usersCol := db.Collection("users")
	cursor, err := usersCol.Find(ctx, bson.M{})
	if err != nil {
		log.Printf("Warning: Failed to query users: %v", err)
	} else {
		var users []User
		if err := cursor.All(ctx, &users); err != nil {
			log.Printf("Warning: Failed to decode users: %v", err)
		} else {
			log.Printf("Found %d users:", len(users))
			for _, u := range users {
				log.Printf("  - ID: %d, Name: %s, Email: %s, Age: %d", u.ID, u.Name, u.Email, u.Age)
			}
		}
	}

	// Query orders
	ordersCol := db.Collection("orders")
	orderCursor, err := ordersCol.Find(ctx, bson.M{})
	if err != nil {
		log.Printf("Warning: Failed to query orders: %v", err)
	} else {
		var orders []Order
		if err := orderCursor.All(ctx, &orders); err != nil {
			log.Printf("Warning: Failed to decode orders: %v", err)
		} else {
			log.Printf("Found %d orders:", len(orders))
			for _, o := range orders {
				log.Printf("  - ID: %d, UserID: %d, Amount: %.2f, Status: %s", o.ID, o.UserID, o.Amount, o.Status)
			}
		}
	}

	// Query products
	productsCol := db.Collection("products")
	productCursor, err := productsCol.Find(ctx, bson.M{})
	if err != nil {
		log.Printf("Warning: Failed to query products: %v", err)
	} else {
		var products []Product
		if err := productCursor.All(ctx, &products); err != nil {
			log.Printf("Warning: Failed to decode products: %v", err)
		} else {
			log.Printf("Found %d products:", len(products))
			for _, p := range products {
				log.Printf("  - ID: %d, Name: %s, Price: %.2f", p.ID, p.Name, p.Price)
			}
		}
	}

	// Setup signal handling
	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)

	log.Println("App is running (press Ctrl+C to stop)...")

	// Keep running
	<-sigChan
	log.Println("Shutting down...")
}

func maskPassword(uri string) string {
	// Simple password masking for logs
	masked := ""
	inPassword := false
	colonCount := 0

	for _, c := range uri {
		if c == ':' {
			colonCount++
			if colonCount == 3 {
				// After mongodb://user: comes the password
				inPassword = true
				masked += ":"
				continue
			}
		}

		if inPassword && c == '@' {
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
