# Integration Tests

Clean test harness for mirrord operator

## Prerequisites

- **minikube** - https://minikube.sigs.k8s.io/docs/start/
- **task** - https://taskfile.dev/installation/
- **kubectl** - https://kubernetes.io/docs/tasks/tools/
- **helm** - https://helm.sh/docs/intro/install/
- **docker** - https://docs.docker.com/get-docker/
- **go** - https://golang.org/dl/

## Quick Start 
1.  create .env and modify it, "MIRRORD_BIN" is the only required one
2. Run:
```bash
# Generate license (first time only)
task license:generate

# Run tests
task test:sqs:clean         # SQS + LocalStack
task test:kafka:clean       # Kafka
task test:mysql:cleand      # MySQL

task --list                 # List all tasks
```

## Tips

- Use `-nobuild` variants to skip operator rebuild (faster iteration)
- ServiceAccount tests verify RBAC configurations
- MySQL branches auto-delete after TTL (600s = 10 minutes)
- Kafka message filtering uses headers (not keys)
- Default test data: MySQL has `Alice` and `Bob` users
