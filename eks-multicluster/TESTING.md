# Testing Apps with mirrord (AWS EKS)

This guide explains how to test the mirrord multi-cluster setup with the three test applications.

## Prerequisites

### 1. Install mirrord CLI

```bash
# Option A: Install from script
curl -fsSL https://raw.githubusercontent.com/metalbear-co/mirrord/main/scripts/install.sh | bash

# Option B: Build from source (matches your operator version)
cd /Users/vladislavrashkov/Projects/MetalBear/mirrord
cargo build --release -p mirrord
# Binary at: target/release/mirrord
```

### 2. Set cluster contexts

```bash
# Remote cluster (where apps are deployed)
export REMOTE_CLUSTER="arn:aws:eks:eu-north-1:526936346962:cluster/multi-cluster-dev2"

# Primary/management cluster (for multi-cluster mode)
export PRIMARY_CLUSTER="arn:aws:eks:eu-north-1:526936346962:cluster/multi-cluster-dev1"

# Verify access
kubectl --context "$REMOTE_CLUSTER" get pods -n test-multicluster
```

### 3. Pull and extract test apps

Run this script to get all three apps:

```bash
#!/bin/bash
set -e

echo "=== Pulling and extracting test apps ==="

# Echo app
echo "Pulling echo-app..."
docker pull --platform linux/amd64 vladrbg/mc-echo-app:latest
docker create --platform linux/amd64 --name temp-echo vladrbg/mc-echo-app:latest
docker cp temp-echo:/app/echo-app ./echo-app
docker rm temp-echo
chmod +x ./echo-app
echo "✓ echo-app ready"

# Postgres app (binary is named 'app' in container)
echo "Pulling postgres-app..."
docker pull --platform linux/amd64 vladrbg/mc-postgres-app:latest
docker create --platform linux/amd64 --name temp-pg vladrbg/mc-postgres-app:latest
docker cp temp-pg:/app/app ./postgres-app
docker rm temp-pg
chmod +x ./postgres-app
echo "✓ postgres-app ready"

# SQS consumer (binary is named 'consumer' in container)
echo "Pulling sqs-consumer..."
docker pull --platform linux/amd64 vladrbg/mc-sqs-consumer:latest
docker create --platform linux/amd64 --name temp-sqs vladrbg/mc-sqs-consumer:latest
docker cp temp-sqs:/app/consumer ./sqs-consumer
docker rm temp-sqs
chmod +x ./sqs-consumer
echo "✓ sqs-consumer ready"

echo ""
echo "=== All apps ready! ==="
```

---

## 1. Echo App (Traffic Mirroring/Stealing)

Tests HTTP traffic mirroring and stealing functionality.

### mirrord config (`mirrord-echo.json`)

```json
{
  "target": {
    "path": "deployment/echo-app",
    "namespace": "test-multicluster"
  },
  "feature": {
    "network": {
      "incoming": "steal",
      "outgoing": true
    },
    "fs": "local",
    "env": true
  },
  "operator": true
}
```

### Run with mirrord

```bash
mirrord exec -c mirrord-echo.json -- ./echo-app
```

### Send test traffic

In another terminal:

```bash
# Basic request
kubectl --context "$REMOTE_CLUSTER" \
  run curl-test --rm -it --image=curlimages/curl -n test-multicluster -- \
  curl -s http://echo-app:80/echo

# With filter header (for filtered stealing)
kubectl --context "$REMOTE_CLUSTER" \
  run curl-test --rm -it --image=curlimages/curl -n test-multicluster -- \
  curl -s -H "X-My-Header: filtered-data" http://echo-app:80/echo
```

### Expected result

Your local echo-app receives the request and logs it, instead of the remote pod.

---

## 2. Postgres App (Database Branching)

Tests PostgreSQL database branching - creates an isolated database branch for local development.

### mirrord config (`mirrord-postgres.json`)

```json
{
  "target": {
    "path": "pod/postgres-test",
    "namespace": "test-multicluster"
  },
  "feature": {
    "db_branches": [
      {
        "id": "pg-test-branch",
        "type": "pg",
        "version": "17",
        "name": "source_db",
        "ttl_secs": 60,
        "creation_timeout_secs": 90,
        "connection": {
          "url": {
            "type": "env",
            "variable": "DATABASE_URL"
          }
        },
        "copy": {
          "mode": "schema",
          "tables": {
            "users": {
              "filter": "age >= 18"
            }
          }
        }
      }
    ],
    "env": true,
    "fs": "local"
  },
  "operator": true
}
```

### Run with mirrord

```bash
# For multi-cluster, target the primary cluster
mirrord exec --context "$PRIMARY_CLUSTER" -c mirrord-postgres.json -- ./postgres-app
```

### Verify database operations

In another terminal:

```bash
# Connect to PostgreSQL source database
kubectl --context "$REMOTE_CLUSTER" exec -it -n test-multicluster postgres-test -- \
  psql -U postgres -d source_db -c "SELECT * FROM users;"

# Check PgBranchDatabase CRDs
kubectl --context "$REMOTE_CLUSTER" get pgbranchdatabases -n test-multicluster
```

### Expected result

- A database branch is created for your session
- Your local app connects to the branch (isolated from production)
- Changes in your branch don't affect the source database
- Branch is deleted when session ends (TTL)

---

## 3. SQS Consumer App (Queue Splitting)

Tests SQS queue splitting - routes specific messages to your local consumer.

### mirrord config (`mirrord-sqs.json`)

```json
{
  "target": {
    "path": "deployment/sqs-consumer",
    "namespace": "test-multicluster"
  },
  "operator": true,
  "feature": {
    "split_queues": {
      "test-queue": {
        "queue_type": "SQS",
        "message_filter": {
          "type": "^premium$"
        }
      }
    },
    "env": true,
    "fs": "local"
  }
}
```

### Run with mirrord

```bash
mirrord exec -c mirrord-sqs.json -- ./sqs-consumer
```

### Send test messages

In another terminal:

```bash
# Filtered message (type=premium) - goes to YOUR local app
aws sqs send-message \
  --queue-url https://sqs.eu-north-1.amazonaws.com/526936346962/test-queue \
  --message-body '{"order": "ORD-001", "amount": 100, "customer": "premium-user"}' \
  --message-attributes '{"type":{"DataType":"String","StringValue":"premium"}}' \
  --region eu-north-1

# Unfiltered message (type=basic) - stays with REMOTE consumer
aws sqs send-message \
  --queue-url https://sqs.eu-north-1.amazonaws.com/526936346962/test-queue \
  --message-body '{"order": "ORD-002", "amount": 50, "customer": "basic-user"}' \
  --message-attributes '{"type":{"DataType":"String","StringValue":"basic"}}' \
  --region eu-north-1
```

### Expected result

- Messages with `type=premium` are routed to your local consumer
- Messages with other types stay with the remote consumer
- Both consumers process messages in parallel

---

## Multi-Cluster Mode

For testing the primary operator orchestrating remote clusters:

1. Point kubectl to the **primary** cluster:

   ```bash
   kubectl config use-context "$PRIMARY_CLUSTER"
   ```

2. Use `--context` flag with mirrord:

   ```bash
   mirrord exec --context "$PRIMARY_CLUSTER" -c mirrord-echo.json -- ./echo-app
   ```

3. The primary operator will route the session to the appropriate remote cluster based on the `defaultCluster` configuration.

---

## Troubleshooting

### Check operator is running

```bash
kubectl --context "$REMOTE_CLUSTER" get pods -n mirrord
kubectl --context "$REMOTE_CLUSTER" logs -n mirrord deploy/mirrord-operator
```

### Check target app is running

```bash
kubectl --context "$REMOTE_CLUSTER" get pods -n test-multicluster
```

### Check mirrord session

```bash
# List active sessions
kubectl --context "$REMOTE_CLUSTER" get mirrordclustersessions -n mirrord
```

### Verbose mirrord output

```bash
RUST_LOG=mirrord=debug mirrord exec -c mirrord-echo.json -- ./echo-app
```

---

## Docker Hub Images

| App | Image |
|-----|-------|
| Echo App | `vladrbg/mc-echo-app:latest` |
| Postgres App | `vladrbg/mc-postgres-app:latest` |
| SQS Consumer | `vladrbg/mc-sqs-consumer:latest` |

---

## Quick Test Checklist

- [ ] Operator running on target cluster(s)
- [ ] Target app deployed (echo-app, postgres-app, sqs-consumer)
- [ ] mirrord CLI installed
- [ ] kubectl context pointing to correct cluster
- [ ] mirrord config file created
- [ ] Local app binary extracted from Docker image

```sh
export MANAGEMENT_CLUSTER="arn:aws:eks:eu-north-1:526936346962:cluster/multi-cluster-dev1"
export REMOTE_CLUSTER_1="arn:aws:eks:eu-north-1:526936346962:cluster/multi-cluster-dev2"
export REMOTE_CLUSTER_2="arn:aws:eks:eu-north-1:526936346962:cluster/multi-cluster-dev3"
task eks:test:echo:multi-cluster
```

```sh
export MANAGEMENT_CLUSTER="arn:aws:eks:eu-north-1:526936346962:cluster/multi-cluster-dev1"
export REMOTE_CLUSTER_1="arn:aws:eks:eu-north-1:526936346962:cluster/multi-cluster-dev2"
export REMOTE_CLUSTER_2="arn:aws:eks:eu-north-1:526936346962:cluster/multi-cluster-dev3"
task eks:test:echo:send
```
