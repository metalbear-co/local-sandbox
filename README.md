# mirrord Operator Test Sandbox

Local testing environment for mirrord operator features.

## Prerequisites

- minikube, task, kubectl, helm, docker

## Quick Start

```bash
# Setup
task license:generate
task cluster:create
task operator:install

# Run tests
task test:mysql
task test:postgres
```

## MySQL Tests

```bash
# Full test
task test:mysql

# Quick test (no cluster rebuild)
task test:mysql:quick

# Verify results
task mysql:verify:all

# Check status
task mysql:status
task mysql:branches
```

## Postgres Tests

```bash
task test:postgres
task postgres:verify:all
task postgres:status
```

## Other Tests

```bash
task test:sqs
task test:kafka
```

## Development

```bash
# Rebuild operator
task build:operator
task operator:install

# Build test CLI
task cli:build

# List all commands
task --list
```
