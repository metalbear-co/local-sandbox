# mirrord Operator Test Sandbox

Local testing environment for mirrord operator features.

## Prerequisites

- minikube, task, kubectl, helm, docker

## Quick Start

### Full automated tests
Run complete test cycles from a clean cluster:

```bash
# Generate license once
task license:generate

# Run tests from clean cluster (deletes + recreates cluster each time)
task mysql:test:mysql:complete:clean
task mysql:test:mariadb:complete:clean
task postgres:test:postgres:complete:clean
task sqs:test:clean
task kafka:test:clean
```

### Manual workflow
More control over each step:

```bash
# Setup cluster
task license:generate
task cluster:create

# Run tests
task mysql:test:mysql:complete
task mysql:test:mariadb:complete
task postgres:test:postgres:complete
task sqs:test
task kafka:test

# Verify branches work correctly
task mysql:verify:mysql:branches
task mysql:verify:mariadb:branches
task postgres:verify:postgres:branches

# Cleanup
task mysql:clean:mysql:complete
task mysql:clean:mariadb:complete
task postgres:clean:postgres:complete
task sqs:clean
task kafka:clean
```


---

## MySQL Tests

### Complete Tests
Simple all-in-one test files:

```bash
# MySQL complete test
task mysql:test:mysql:complete
task mysql:verify:mysql:branches
task mysql:clean:mysql:complete

# MariaDB complete test (tests MySQL operator compatibility)
task mysql:test:mariadb:complete
task mysql:verify:mariadb:branches
task mysql:clean:mariadb:complete
```

### Modular Tests
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

** Custom queries and debugging**
```bash
# Custom queries
task mysql:query:source QUERY="SELECT * FROM users WHERE name='Alice';"
task mysql:query:branch SCENARIO=env-val QUERY="SELECT COUNT(*) FROM orders;"

# Interactive shell
task mysql:shell:branch SCENARIO=env-val
# mysql> SELECT * FROM users;
# mysql> INSERT INTO users (name, email, age) VALUES ('Test', 'test@example.com', 25);

# Debug
task mysql:branches              # Check status
task mysql:logs:branch SCENARIO=env-val
```

---

## PostgreSQL Tests

### Complete Tests
Simple all-in-one test file:

```bash
# PostgreSQL complete test
task postgres:test:postgres:complete
task postgres:verify:postgres:branches
task postgres:clean:postgres:complete
```

### Modular Tests
```bash
# Full modular test
task postgres:test:modular

# Deploy and verify
task postgres:deploy:modular
task postgres:verify:all

# Debug
task postgres:branches           # Check status
task postgres:logs:job SCENARIO=env-val
task postgres:shell:branch SCENARIO=env-val

# Cleanup
task postgres:clean:modular
```

**Test Scenarios:**
- `env-val` - Full 1:1 copy (all objects + data)
- `secret-ref` - Filtered copy (full schema + filtered data: age > 18, amount > 50)
- `echo` - Empty database

## branch
# Find branch database
kubectl get pods -n test-mirrord -l db-owner-name=pg-test-branch-env-val
# Query branch database
kubectl exec -n test-mirrord mirrord-postgres-branch-db-pod-hfgj6 -- psql -U postgres -d secret-ref-branch -c "SELECT * FROM users"

** Custom queries and debugging**
```bash
# Custom queries
task postgres:query:source QUERY="SELECT * FROM users WHERE age > 18;"
task postgres:query:branch SCENARIO=env-val QUERY="SELECT COUNT(*) FROM products;"

# Interactive shell
task postgres:shell:branch SCENARIO=env-val
# postgres=# SELECT * FROM users;
# postgres=# INSERT INTO users (name, email, age) VALUES ('Test', 'test@example.com', 25);

# Debug
task postgres:branches           # Check status
task postgres:logs:job SCENARIO=env-val
```

---

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
