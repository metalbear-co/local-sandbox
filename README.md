# mirrord Operator Test Sandbox

Local testing environment for mirrord operator features.

## Prerequisites

- minikube, task, kubectl, helm, docker

## Quick Start

```bash
# Setup
task license:generate
task cluster:create

# Run tests
task test:mysql
task test:postgres
```

## MySQL Tests

### Modular Tests (component-based)
```bash
# Full modular test
task mysql:test:modular

# Quick test (reuse cluster)
task mysql:test:modular:quick

# Verify
task mysql:verify:all

# Debug
task mysql:branches              # Check status
task mysql:logs:branch SCENARIO=env-val
task mysql:shell:branch SCENARIO=env-val

# Cleanup
task mysql:clean:modular
```

**Test Scenarios:**
- `env-val` - Full copy (all tables + data)
- `secret-ref` - Filtered copy (schema + filtered data: age ≥ 18, amount > 50)

**Query branches:**
```bash
# Query source database
task mysql:query:source

# Query branch database
task mysql:query:branch SCENARIO=env-val
task mysql:query:branch SCENARIO=secret-ref

# Interactive shell
task mysql:shell:branch SCENARIO=env-val
# mysql> SELECT * FROM users;
# mysql> INSERT INTO users (name, email, age) VALUES ('Test', 'test@example.com', 25);
```

### Complete Tests (single-file)
Simple all-in-one test files for quick testing:

```bash
# MySQL complete test
task mysql:test:mysql:complete
task mysql:clean:mysql:complete

# MariaDB complete test (drop-in replacement for MySQL)
task mysql:test:mariadb:complete
task mysql:clean:mariadb:complete
```

## PostgreSQL Tests

```bash
# Full test (clean cluster)
task test:postgres:clean

# Deploy and verify
task postgres:deploy
task postgres:verify:all

# Debug
task postgres:branches           # Check status
task postgres:logs:job SCENARIO=env-val
task postgres:shell:branch SCENARIO=env-val

# Cleanup
task postgres:clean
```

**Test Scenarios:**
- `env-val` - Full 1:1 copy (all objects + data)
- `secret-ref` - Filtered copy (full schema + filtered data: age > 18, amount > 50)
- `echo` - Empty database

**Query branches:**
```bash
# Query source database
kubectl exec -n test-mirrord postgres-test -- psql -U postgres -d source_db -c "SELECT * FROM users;"

# Query branch database
task postgres:shell:branch SCENARIO=env-val
# postgres=# \c branch_db
# postgres=# SELECT * FROM users;
# postgres=# INSERT INTO users (name, email, age) VALUES ('Test', 'test@example.com', 25);

## branch
# Find branch database
kubectl get pods -n test-mirrord -l db-owner-name=pg-test-branch-env-val
# Query branch database
kubectl exec -n test-mirrord mirrord-postgres-branch-db-pod-hfgj6 -- psql -U postgres -d secret-ref-branch -c "SELECT * FROM users"

```

## Development

```bash
# Rebuild operator
task build:operator
task operator:update         # Fast update (no cluster rebuild)

# Logs
kubectl logs -n mirrord -l app=mirrord-operator --tail=50 -f

# List all commands
task --list
```
