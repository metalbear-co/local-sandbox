# AWS EKS Multi-Cluster Setup

Step-by-step deployment of mirrord operator in multi-cluster mode across 3 AWS EKS clusters.

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                    MANAGEMENT CLUSTER                            │
│                    (eks-management)                              │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │  Primary Operator (Envoy)                                 │   │
│  │  - Orchestrates remote clusters                          │   │
│  │  - No workloads (managementOnly: true)                   │   │
│  └──────────────────────────────────────────────────────────┘   │
└──────────────────────────┬───────────────────────────────────────┘
                           │
           ┌───────────────┴───────────────┐
           ▼                               ▼
┌──────────────────────┐       ┌──────────────────────┐
│   REMOTE CLUSTER 1   │       │   REMOTE CLUSTER 2   │
│   (eks-remote-1)     │       │   (eks-remote-2)     │
│   [DEFAULT CLUSTER]  │       │                      │
│                      │       │                      │
│  ┌────────────────┐  │       │  ┌────────────────┐  │
│  │ Remote Operator│  │       │  │ Remote Operator│  │
│  └────────────────┘  │       │  └────────────────┘  │
│                      │       │                      │
│  ┌────────────────┐  │       │                      │
│  │  PostgreSQL DB │  │       │                      │
│  └────────────────┘  │       │                      │
│                      │       │                      │
│  ┌────────────────┐  │       │  ┌────────────────┐  │
│  │  Test Apps     │  │       │  │  Test Apps     │  │
│  └────────────────┘  │       │  └────────────────┘  │
└──────────────────────┘       └──────────────────────┘
```

## Prerequisites

1. **AWS CLI** configured with access to all 3 EKS clusters
2. **kubectl** configured with contexts for all clusters
3. **Helm 3** installed
4. **Task** (go-task) installed

## Configuration

Set your cluster context names:

```bash
export MANAGEMENT_CLUSTER="your-management-cluster-context"
export REMOTE_CLUSTER_1="your-remote-1-context"
export REMOTE_CLUSTER_2="your-remote-2-context"
```

Verify access:

```bash
kubectl --context $MANAGEMENT_CLUSTER get nodes
kubectl --context $REMOTE_CLUSTER_1 get nodes
kubectl --context $REMOTE_CLUSTER_2 get nodes
```

## Step-by-Step Deployment

### Step 1: Create Namespaces

```bash
task eks:namespaces:create
```

### Step 2: Setup Cross-Cluster Credentials

```bash
task eks:credentials:create
```

This creates service accounts on remote clusters and stores tokens as secrets on the management cluster.

### Step 3: Install Operators

```bash
# Install on all clusters at once
task eks:operator:install:all

# Or individually:
task eks:operator:install:remotes   # Both remotes first
task eks:operator:install:primary   # Then primary
```

### Step 4: Deploy PostgreSQL (remote-1 only for DB branching)

```bash
task eks:postgres:deploy:remote1

# Check status
task eks:postgres:status
```

### Step 5: Deploy Test Apps

Deploy apps individually or in batches:

```bash
# Deploy all apps to a specific cluster
task eks:apps:deploy:remote1
task eks:apps:deploy:remote2

# Or deploy individual apps
task eks:app:echo:deploy:remote1      # Traffic app
task eks:app:postgres:deploy:remote1  # Postgres consumer app
task eks:app:sqs:deploy:remote1       # SQS consumer app
```

## Available Tasks

### Status & Monitoring

```bash
task eks:status              # Overall cluster status
task eks:apps:list           # List all deployed apps
task eks:postgres:status     # PostgreSQL status

task eks:operator:logs:primary   # Tail primary operator logs
task eks:operator:logs:remote1   # Tail remote-1 operator logs
task eks:operator:logs:remote2   # Tail remote-2 operator logs
```

### PostgreSQL Database

```bash
# Deploy (to any cluster)
task eks:postgres:deploy CLUSTER=eks-remote-1
task eks:postgres:deploy:remote1
task eks:postgres:deploy:remote2

# Delete
task eks:postgres:delete CLUSTER=eks-remote-1
task eks:postgres:delete:remote1
task eks:postgres:delete:remote2
```

### Echo App (Traffic Mirroring/Stealing)

```bash
# Deploy
task eks:app:echo:deploy CLUSTER=eks-remote-1
task eks:app:echo:deploy:remote1
task eks:app:echo:deploy:remote2

# Delete
task eks:app:echo:delete CLUSTER=eks-remote-1
task eks:app:echo:delete:remote1
task eks:app:echo:delete:remote2
```

### Postgres App (Database Branching Consumer)

```bash
# Deploy
task eks:app:postgres:deploy CLUSTER=eks-remote-1
task eks:app:postgres:deploy:remote1
task eks:app:postgres:deploy:remote2

# Delete
task eks:app:postgres:delete CLUSTER=eks-remote-1
task eks:app:postgres:delete:remote1
task eks:app:postgres:delete:remote2
```

### SQS Consumer App (Queue Splitting)

```bash
# Deploy
task eks:app:sqs:deploy CLUSTER=eks-remote-1
task eks:app:sqs:deploy:remote1
task eks:app:sqs:deploy:remote2

# Delete
task eks:app:sqs:delete CLUSTER=eks-remote-1
task eks:app:sqs:delete:remote1
task eks:app:sqs:delete:remote2
```

### Batch Operations

```bash
# Deploy all apps to a cluster
task eks:apps:deploy CLUSTER=eks-remote-1
task eks:apps:deploy:remote1
task eks:apps:deploy:remote2
task eks:apps:deploy:all          # Both clusters

# Delete all apps from a cluster
task eks:apps:delete CLUSTER=eks-remote-1
task eks:apps:delete:remote1
task eks:apps:delete:remote2
task eks:apps:delete:all          # Both clusters
```

### Cleanup

```bash
# Cleanup specific cluster
task eks:cleanup:cluster CLUSTER=eks-remote-1

# Cleanup everything
task eks:cleanup:all
```

## Operator Configuration

### Custom Images

```bash
export OPERATOR_IMAGE="123456789.dkr.ecr.us-east-1.amazonaws.com/mirrord-operator:v1.0.0"
export AGENT_IMAGE="123456789.dkr.ecr.us-east-1.amazonaws.com/mirrord-agent:v1.0.0"
task eks:operator:install:all
```

### License File

```bash
export LICENSE_FILE="/path/to/your/license.pem"
```

### AWS Credentials for SQS

Edit `eks-multicluster/operator-values-primary.yaml` and `operator-values-remote.yaml`:

```yaml
operator:
  extraEnv:
    AWS_REGION: "us-east-1"
    AWS_ACCESS_KEY_ID: "your-key"
    AWS_SECRET_ACCESS_KEY: "your-secret"
```

Or use IRSA (recommended):

```yaml
serviceAccount:
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::123456789:role/mirrord-operator-role
```

## Token Refresh

EKS service account tokens should be refreshed periodically:

```bash
task eks:credentials:refresh
task eks:operator:restart:primary
```

## Testing with mirrord

See [TESTING.md](TESTING.md) for detailed instructions on:

- Pulling and running test apps locally
- mirrord configuration for each app type
- Traffic mirroring/stealing (echo-app)
- Database branching (postgres-app)
- SQS queue splitting (sqs-consumer)

## Troubleshooting

### Check operator connectivity

```bash
# View credential secrets
kubectl --context $MANAGEMENT_CLUSTER get secrets -n mirrord \
  -l operator.metalbear.co/remote-cluster-credentials=true

# Check operator logs
task eks:operator:logs:primary
```

### Check app status

```bash
kubectl --context $REMOTE_CLUSTER_1 get pods -n test-multicluster
kubectl --context $REMOTE_CLUSTER_1 describe pod <pod-name> -n test-multicluster
```
