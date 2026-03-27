# mirrord Operator Local Sandbox

Local testing environment for mirrord operator features.

## Prerequisites

- minikube
- docker (or podman)
- kubectl
- helm
- task (go-task)

## Setup

1. Copy and configure environment:

```bash
cp .env.example .env
# Edit .env with your settings
```

1. Generate license and create cluster:

```bash
task license:generate
task cluster:create
```

## Running Tests

Each module follows the same pattern:

| Command | Description |
|---------|-------------|
| `task <module>:test` | Full test (deploy + verify) |
| `task <module>:test:quick` | Verify only (no deploy) |
| `task <module>:deploy` | Deploy resources |
| `task <module>:verify` | Verify results |
| `task <module>:run:local` | Run app locally with mirrord |
| `task <module>:logs` | View logs |
| `task <module>:shell` | Shell into pod |
| `task <module>:status` | Show status |
| `task <module>:clean` | Cleanup |

### Quick Examples

```bash
# MySQL branching
task test:mysql
task mysql:verify
task mysql:run:local

# PostgreSQL branching
task test:postgres
task postgres:shell:branch SCENARIO=env-val

# Kafka message splitting
task test:kafka
task kafka:send MESSAGE="hello" USER_ID="123"

# SQS (LocalStack)
task test:sqs
task sqs:run:local
```

### Clean Tests (Fresh Cluster)

```bash
task test:mysql:clean
task test:postgres:clean
task test:kafka:clean
task test:sqs:clean
```

### Skip Operator Build

For faster iteration when operator is unchanged:

```bash
task test:mysql:clean:nobuild
task test:postgres:clean:nobuild
```

## Development

```bash
# Rebuild and update operator
task operator:update

# View operator logs
task logs:operator

# Delete cluster
task cluster:delete

# List all tasks
task --list

# List module-specific tasks
task --list | grep mysql
task --list | grep postgres
```

## Directory Structure

The tasks expect this standard layout (no configuration needed):

```
your-workspace/
├── charts/mirrord-operator/
├── local-sandbox/          ← run tasks from here
├── mirrord/
└── operator/
```

If your layout differs, override paths in `.env`:

```bash
OPERATOR_DIR=/path/to/operator
CHARTS_DIR=/path/to/charts/mirrord-operator
MIRRORD_DIR=/path/to/mirrord
```

## PostgreSQL Testing

```bash
# Full test (deploy + verify)
task test:postgres

# Deploy only
task postgres:deploy

# Verify branch data
task postgres:verify

# Query databases
task postgres:query:source QUERY="SELECT * FROM users"
task postgres:query:branch SCENARIO=env-val QUERY="SELECT * FROM users"

# Interactive shells
task postgres:shell              # Source DB
task postgres:shell:branch SCENARIO=env-val

# View logs
task postgres:logs               # App logs
task postgres:logs:source        # Source DB logs

# Local branch (Docker)
task postgres:branch:local              # Schema only
task postgres:branch:local:full         # Full data copy
task postgres:branch:local:shell        # Connect to local branch
task postgres:branch:local:stop         # Stop container

# Run app locally with mirrord
task postgres:run:local

# Status and cleanup
task postgres:status
task postgres:branches
task postgres:clean
```

## Redis Testing

```bash
# Full test (deploy + seed + run)
task test:redis

# Deploy Redis to cluster
task redis:deploy

# Build the test app
task redis:build

# Seed test data
task redis:seed

# Run app locally
task redis:run:local     # Uses local Redis (outgoing filter)
task redis:run:cluster   # Connects to cluster Redis

# View logs
task redis:logs          # App logs
task redis:logs:redis    # Redis server logs

# Interactive access
task redis:shell         # Shell into app pod
task redis:shell:redis   # Redis CLI

# Status and cleanup
task redis:status
task redis:clean
```

## Other Modules

### MySQL

```bash
task mysql:branches
task mysql:query:source
task mysql:query:branch SCENARIO=env-val
```

### RabbitMQ Queue Splitting

```bash
# Fresh cluster with RabbitMQ from scratch
task test:rmq:clean

# Open the RabbitMQ management UI (http://localhost:15672)
task rmq:management

# Show RabbitMQ connection credentials
task rmq:credentials

# List mirrord temp queues left in the broker
task rmq:queues:mirrord

# Delete all mirrord temp queues from the broker
task rmq:queues:mirrord:delete

# Publish a test message with a tenant header
task rmq:send QUEUE="orders" TENANT="a" MESSAGE="hello"

# Run the e2e tests (from the operator/ directory)
cargo test -p tests -- --ignored rmq_queue_splitting --nocapture
```

### SQS/Kafka

```bash
task sqs:send MESSAGE="test" TENANT="Avi.Test"
task kafka:send MESSAGE="hello" USER_ID="123"
task kafka:topics:list
```

### AWS RDS

```bash
task postgres:deploy:aws      # Deploy target app
task postgres:run:local:aws   # Run with mirrord
task postgres:status:aws      # Check status
task postgres:logs:aws:branch # View branch logs
task postgres:clean:aws       # Clean up
```

```bash
task postgres:deploy:aws
task postgres:run:local:aws
```

### GCP Cloud SQL

```bash
task postgres:deploy:gcp      # Deploy target app
task postgres:run:local:gcp   # Run with mirrord
task postgres:status:gcp      # Check status
task postgres:logs:gcp:branch # View branch logs
task postgres:clean:gcp       # Clean up
```

```bash
task postgres:deploy:gcp
task postgres:run:local:gcp
```

