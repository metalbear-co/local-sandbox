package main

import (
	"context"
	"fmt"
	"os"
	"time"

	"github.com/metalbear-co/test-cli/cmd/mysql"
	"github.com/metalbear-co/test-cli/cmd/postgres"
)

const version = "0.2.0"

func main() {
	if len(os.Args) < 2 {
		printUsage()
		os.Exit(1)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
	defer cancel()

	command := os.Args[1]
	args := os.Args[2:]

	var err error
	switch command {
	case "mysql":
		err = mysql.Handle(ctx, args)
	case "postgres":
		err = postgres.Handle(ctx, args)
	case "version":
		fmt.Printf("test-cli version %s\n", version)
		return
	case "help", "-h", "--help":
		printUsage()
		return
	default:
		fmt.Fprintf(os.Stderr, "Unknown command: %s\n\n", command)
		printUsage()
		os.Exit(1)
	}

	if err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		os.Exit(1)
	}
}

func printUsage() {
	fmt.Println(`test-cli - Database Branching Test Helper

Usage:
  test-cli <database> <command> [arguments]

Databases:
  mysql       MySQL database operations
  postgres    PostgreSQL database operations

MySQL Commands:
  test-cli mysql verify-scenario <namespace> <scenario> <users> <orders> <mode> <password>
  test-cli mysql query-source <namespace> <query> <password>
  test-cli mysql query-branch <namespace> <scenario> <query> <password>
  test-cli mysql wait-source <namespace> <password>

PostgreSQL Commands:
  test-cli postgres verify-scenario <namespace> <scenario> <users> <orders> <products> <mode>
  test-cli postgres query-source <namespace> <query>
  test-cli postgres query-branch <namespace> <scenario> <query>
  test-cli postgres wait-source <namespace>

Global Commands:
  version     Print version information
  help        Show this help message

Examples:
  test-cli mysql verify-scenario test-mirrord env-val 2 4 "full copy" password123
  test-cli postgres verify-scenario test-mirrord env-val 5 5 4 "full copy"
`)
}

