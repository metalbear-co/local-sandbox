# mirrord Operator Local Sandbox

Local testing environment for mirrord operator features.

## Quick Start

### First Time

```bash
task check          # verify prerequisites, install missing tools
task license:generate
task cluster:create
```

### Day-to-Day

| Command | What it does |
|---------|-------------|
| `task menu` | Fuzzy-search all tasks -- type fragments, pick with arrow keys |
| `task menu:module` | Pick a module first (postgres, sqs, ...), then pick a task |
| `task up` | Interactive test setup -- pick module, fresh cluster?, build? |
| `task dashboard` | See everything: cluster, operator, all CRDs, problem pods |
| `task recent` | Re-run a past task (shows name + args + "2h ago") |
| `task check` | Validate env, offer to install missing tools |

### Examples

```bash
task menu                              # forgot the command? fuzzy search
task up                                # interactive: pick postgres, fresh=no, build=yes
task up MODULE=postgres                # skip module picker
task dashboard                         # what's running right now?
task recent                            # re-run something from earlier
```

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

# GCP Pub/Sub splitting
task test:pubsub
task pubsub:run:local
task pubsub:send:match
```

### Clean Tests (Fresh Cluster)

```bash
task test:mysql:clean
task test:postgres:clean
task test:kafka:clean
task test:sqs:clean
task test:pubsub:clean
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

## Preview Environments

Config: `apps/echo-app/mirrord-preview.json` - targets `deploy/echo-app`, steals traffic
matching `X-Preview: <key>`. The preview pod uses the `echo-app:latest` image by default
(loaded into minikube, so `image_pull_policy: "IfNotPresent"` is set in local values).

### Single-cluster test

Creates the PreviewSession directly on remote-1. The local operator handles it.

```bash
task multicluster:preview:start:single-cluster PREVIEW_KEY=my-sc-preview

# Terminal 2 - traffic with header goes to preview pod
task multicluster:preview:test:traffic PREVIEW_KEY=my-sc-preview

# Terminal 3 - traffic without header goes to original echo-app
task multicluster:preview:test:traffic:no-header

task multicluster:preview:stop:single-cluster PREVIEW_KEY=my-sc-preview
```

### Multi-cluster test

Creates the PreviewSession on the primary cluster. The `PreviewSessionSyncController`
syncs it to the default cluster (remote-1) where the preview pod runs.

```bash
task multicluster:preview:start PREVIEW_KEY=my-mc-preview

# Verify the CR exists on BOTH clusters (proves sync controller works)
task multicluster:preview:list

# Traffic is generated on remote-1 where the echo-app service lives
task multicluster:preview:test:traffic PREVIEW_KEY=my-mc-preview

task multicluster:preview:stop PREVIEW_KEY=my-mc-preview
```

### What to look for

- `preview:list` should show the PreviewSession on both `mirrord-primary` and `mirrord-remote-1`
  for multi-cluster, or only on `mirrord-remote-1` for single-cluster
- Traffic with the `X-Preview` header should return a response from the preview pod
  (different from the original echo-app's `cluster_id` JSON)
- Traffic without the header should return normal echo-app responses

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

### GCP Pub/Sub Queue Splitting

#### Basic Setup

```bash
# Fresh cluster with Pub/Sub from scratch
task test:pubsub:clean

# Deploy emulator + consumer + CRDs (operator must be installed)
task pubsub:deploy

# Deploy only the emulator (for E2E tests)
task pubsub:deploy:emulator

# Build the Go consumer image and load into minikube
task pubsub:build
```

#### Running Local Consumers

```bash
# Single session (tenant=^test filter)
task pubsub:run:local

# Second session (tenant=^beta filter)
task pubsub:run:local:user-b

# Third session (tenant=^gamma filter)
task pubsub:run:local:user-c

# Multi-attribute filter (tenant=^test AND type=^premium$)
task pubsub:run:local:multi-attr

# JQ body filter (type=premium in JSON body)
task pubsub:run:local:jq
```

#### Sending Messages

```bash
# Single messages
task pubsub:send:match             # tenant=test-user (matched by user A)
task pubsub:send:nomatch           # tenant=other (goes to target pod)
task pubsub:send:beta              # tenant=beta (matched by user B)
task pubsub:send:gamma             # tenant=gamma (matched by user C)
task pubsub:send TENANT="custom"   # custom tenant value

# Multi-tenant
task pubsub:send:all-tenants       # one per tenant (test-user, beta, gamma, other)
task pubsub:send:both              # test-user + other + beta

# Batch send
task pubsub:test:split:send MATCHED=5 UNMATCHED=3

# Flood test (random tenants)
task pubsub:send:flood COUNT=30
```

#### Multi-Queue Setup (Orders + Notifications)

Two independent topics/subscriptions on the same workload.

```bash
# Deploy with two queues
task pubsub:deploy:multi-queue

# Split only orders queue
task pubsub:run:local:orders-only

# Split only notifications queue
task pubsub:run:local:notifications-only

# Split both queues at once
task pubsub:run:local:both-queues

# Send to specific queues
task pubsub:send:orders TENANT=test-user
task pubsub:send:notifications TENANT=test-user
task pubsub:send:multi-queue:all   # mixed to both queues

# Logs for multi-queue consumer
task pubsub:logs:multi-queue
```

#### Logs and Inspection

```bash
task pubsub:logs                   # Target pod logs
task pubsub:logs:emulator          # Emulator logs
task pubsub:topics:list            # All topics
task pubsub:subscriptions:list     # All subscriptions
task pubsub:test:split:status      # Sessions, configs, external resources, topics, subs
task pubsub:status                 # Quick pod/config overview
```

#### Automated Tests

```bash
# Reconnect test (start session, kill it, start new, verify messages route correctly)
task pubsub:test:reconnect

# Session churn (5 rapid start/stop cycles)
task pubsub:test:session-churn

# Cleanup sessions and temp resources only
task pubsub:test:split:cleanup

# Full cleanup
task pubsub:clean
```

#### E2E Tests

```bash
# From the operator/ directory
cargo test -p tests -- --ignored gcp_pubsub --nocapture
```

#### Interactive Testing Scenarios

All scenarios below require `task pubsub:deploy` (or `deploy:multi-queue`) to have been run first, and assume you have separate terminal windows open.

**Scenario 1: Single user split (basic)**

| Window | Command | Shows |
|--------|---------|-------|
| 1 | `task pubsub:run:local` | Local consumer (tenant=^test) |
| 2 | `task pubsub:logs` | Target pod (unfiltered) |
| 3 | `task logs:operator` | Operator activity |
| 4 | `task pubsub:send:match` / `send:nomatch` | Send and inspect |

**Scenario 2: Two users, same queue, different filters**

| Window | Command | Shows |
|--------|---------|-------|
| 1 | `task pubsub:run:local` | User A (tenant=^test) |
| 2 | `task pubsub:run:local:user-b` | User B (tenant=^beta) |
| 3 | `task pubsub:logs` | Target pod (unfiltered) |
| 4 | `task pubsub:send:both` | Send test-user + beta + other |

**Scenario 3: Three users, same queue** (`task pubsub:test:three-sessions` prints these)

| Window | Command | Shows |
|--------|---------|-------|
| 1 | `task pubsub:run:local` | User A (tenant=^test) |
| 2 | `task pubsub:run:local:user-b` | User B (tenant=^beta) |
| 3 | `task pubsub:run:local:user-c` | User C (tenant=^gamma) |
| 4 | `task pubsub:logs` | Target pod (unfiltered) |
| 5 | `task logs:operator` | Operator activity |
| 6 | `task pubsub:send:all-tenants` / `send:flood COUNT=30` | Send and inspect |

**Scenario 4: Multi-queue, one user per queue** (`task pubsub:test:multi-queue:two-users`)

Requires `task pubsub:deploy:multi-queue` instead of `pubsub:deploy`.

| Window | Command | Shows |
|--------|---------|-------|
| 1 | `task pubsub:run:local:orders-only` | User A splits orders |
| 2 | `task pubsub:run:local:notifications-only` | User B splits notifications |
| 3 | `task pubsub:logs:multi-queue` | Target pod |
| 4 | `task pubsub:send:multi-queue:all` | Send to both queues |

User A should only receive order messages with tenant=test-user. User B should only receive notification messages with tenant=test-user. The target pod gets everything else.

**Scenario 5: Multi-queue, one user splits both queues**

| Window | Command | Shows |
|--------|---------|-------|
| 1 | `task pubsub:run:local:both-queues` | User splits both queues |
| 2 | `task pubsub:logs:multi-queue` | Target pod |
| 3 | `task pubsub:send:multi-queue:all` | Send to both queues |

**Scenario 6: Filter type comparison** (`task pubsub:test:filter-types` prints these)

Test attribute filters vs. multi-attribute filters vs. JQ body filters on the same queue.

| Filter | Command | Matches |
|--------|---------|---------|
| Single attribute | `task pubsub:run:local` | tenant=test-user |
| Multi-attribute | `task pubsub:run:local:multi-attr` | tenant=test-user AND type=premium |
| JQ body | `task pubsub:run:local:jq` | body JSON has type=premium |

**Scenario 7: Stress and recovery**

```bash
# Session churn: 5 rapid start/stop cycles, verifies each session receives messages
task pubsub:test:session-churn

# Reconnect: start session, kill it, start new, verify messages still route
task pubsub:test:reconnect

# Flood: send many random-tenant messages while sessions are running
task pubsub:send:flood COUNT=50
```

### Multi-Cluster GCP Pub/Sub Queue Splitting

Multi-cluster Pub/Sub splitting runs across a primary (management) cluster and one or two
workload clusters. The developer connects to the primary cluster, which orchestrates
the split on all workload clusters. A single GCP Pub/Sub emulator is shared by all clusters
via NodePort.

#### Setup

```bash
# Clean setup from scratch (creates clusters, installs operators, deploys emulator + consumer + CRDs)
task multicluster:setup:all:with-pubsub:clean

# Or add pubsub to an existing multi-cluster setup
task multicluster:pubsub:setup
```

#### Single Session

```bash
task multicluster:pubsub:test:split
```

This runs a single `mirrord exec` session targeting `deploy/pubsub-consumer` on all workload
clusters with a `tenant=^test$` filter. The mirrord config looks like:

```json
{
  "operator": true,
  "target": "deploy/pubsub-consumer",
  "feature": {
    "split_queues": {
      "test-subscription": {
        "queue_type": "GcpPubSub",
        "message_filter": {
          "tenant": "^test"
        }
      }
    }
  }
}
```

`test-subscription` is the queue ID matching the `MirrordSplitConfig` on each cluster.
`message_filter` tells the forwarder to route messages whose `tenant` attribute matches
`^test` to this session's temporary subscription. Everything else goes to the original app.

#### Running Multiple Sessions

Each session needs its own terminal because `mirrord exec` is a long-running process.
The test tasks below print instructions showing which command to run in each terminal.

```bash
# Print instructions for 2 sessions with different filters
task multicluster:pubsub:test:two-sessions

# Print instructions for 3 sessions (2 share the same filter, 1 different)
task multicluster:pubsub:test:three-sessions

# Print instructions for 3 sessions with all different filters
task multicluster:pubsub:test:three-sessions:all-different
```

You can also launch individual sessions directly with any filter:

```bash
# Terminal 1
task multicluster:pubsub:test:split:session TENANT_FILTER='^test' SESSION_LABEL=session-a

# Terminal 2
task multicluster:pubsub:test:split:session TENANT_FILTER='^beta' SESSION_LABEL=session-b

# Terminal 3 (same filter as session-a - they compete for matching messages)
task multicluster:pubsub:test:split:session TENANT_FILTER='^test' SESSION_LABEL=session-c
```

When two sessions share the same filter, GCP Pub/Sub delivers each matching message to
exactly one of them (load-balanced). This is expected behavior.

#### Sending Messages

Messages are published to the shared topic with a `tenant` attribute. The forwarder on
each cluster matches this attribute against each session's filter regex and routes accordingly.

```bash
# Target a specific session by matching its filter
task multicluster:pubsub:send TENANT=test-user   # matches ^test -> session-a
task multicluster:pubsub:send TENANT=beta         # matches ^beta -> session-b
task multicluster:pubsub:send TENANT=gamma        # matches ^gamma -> session-c (if running)
task multicluster:pubsub:send TENANT=other        # no match -> original app

# Shortcuts
task multicluster:pubsub:send:match       # tenant=test-user
task multicluster:pubsub:send:nomatch     # tenant=other
task multicluster:pubsub:send:beta        # tenant=beta
task multicluster:pubsub:send:gamma       # tenant=gamma

# Send one message per tenant
task multicluster:pubsub:send:all-tenants

# Random flood
task multicluster:pubsub:send:flood COUNT=30
```

#### Logs and Status

```bash
# Consumer logs per cluster
kubectl --context mirrord-remote-1 logs -n test-multicluster -l app=pubsub-consumer -f
kubectl --context mirrord-remote-2 logs -n test-multicluster -l app=pubsub-consumer -f

# Split sessions, CRDs, external resources
task multicluster:pubsub:status

# Operator logs
task multicluster:logs:operator
```

#### Interactive Testing Scenarios

All scenarios assume `task multicluster:setup:all:with-pubsub` (or the `:clean` variant)
has been run. Open a separate terminal window for each step.

**Scenario 1: Two sessions, different filters**

| Terminal | Command | Receives |
|----------|---------|----------|
| 1 | `task multicluster:pubsub:test:split:session TENANT_FILTER='^test' SESSION_LABEL=session-a` | tenant=test-user |
| 2 | `task multicluster:pubsub:test:split:session TENANT_FILTER='^beta' SESSION_LABEL=session-b` | tenant=beta |
| 3 | `task multicluster:pubsub:send:all-tenants` | - |

Original app receives tenant=gamma, other, unknown.

**Scenario 2: Three sessions, all different filters**

| Terminal | Command | Receives |
|----------|---------|----------|
| 1 | `task multicluster:pubsub:test:split:session TENANT_FILTER='^test' SESSION_LABEL=session-a` | tenant=test-user |
| 2 | `task multicluster:pubsub:test:split:session TENANT_FILTER='^beta' SESSION_LABEL=session-b` | tenant=beta |
| 3 | `task multicluster:pubsub:test:split:session TENANT_FILTER='^gamma' SESSION_LABEL=session-c` | tenant=gamma |
| 4 | `task multicluster:pubsub:send:all-tenants` | - |

Original app receives tenant=other, unknown.

**Scenario 3: Three sessions, two share the same filter**

| Terminal | Command | Receives |
|----------|---------|----------|
| 1 | `task multicluster:pubsub:test:split:session TENANT_FILTER='^test' SESSION_LABEL=session-a` | some tenant=test-user |
| 2 | `task multicluster:pubsub:test:split:session TENANT_FILTER='^beta' SESSION_LABEL=session-b` | tenant=beta |
| 3 | `task multicluster:pubsub:test:split:session TENANT_FILTER='^test' SESSION_LABEL=session-c` | some tenant=test-user |
| 4 | `task multicluster:pubsub:send:flood COUNT=30` | - |

Sessions A and C compete for `tenant=test-user` messages. Each gets some but not all
(GCP Pub/Sub load-balances across consumers on the same subscription).

#### Cleanup

```bash
# Remove split sessions and temp resources only
task multicluster:pubsub:clean

# Full teardown (clusters and all)
task multicluster:teardown:all
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

