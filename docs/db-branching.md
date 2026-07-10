# Database branching

One verb set for every DB module — `postgres`, `mysql`, `mongodb`, `mssql`,
`spanner`, `redis`, `generic` (Valkey + Influx, RFC 0008):

```bash
task <mod>:deploy                    # source DB into the cluster
task <mod>:run:local                 # run the app under mirrord -> creates a branch DB
task <mod>:query:source QUERY="..."  # query the source (cluster) database
task <mod>:query:branch QUERY="..."  # query the branch database
task <mod>:shell:source / shell:branch    # interactive DB shells
task <mod>:branches / logs / logs:branch / status / clean
```

`query:branch` finds the newest running branch pod via the `db-owner-name`
label (`BRANCH=<name>` picks a specific one) and lists existing branch CRDs
when none is running.

## Query examples per DB

Each module header has copy-pasteable examples; the short version:

```bash
# postgres (psql)
task postgres:query:source QUERY="INSERT INTO users (name, email, age) VALUES ('dev', 'dev@example.com', 30);"
task postgres:query:branch QUERY="SELECT count(*) FROM users;"

# mysql (mysql client)
task mysql:query:source QUERY="INSERT INTO users (name, email) VALUES ('dev', 'dev@example.com');"
task mysql:query:branch QUERY="SHOW TABLES;"

# mongodb (mongosh)
task mongodb:query:source QUERY="db.users.insertOne({name: 'dev'})"
task mongodb:query:branch QUERY="db.getCollectionNames()"

# mssql (sqlcmd)
task mssql:query:source QUERY="INSERT INTO users (name, email) VALUES ('dev', 'dev@example.com');"
task mssql:query:branch QUERY="SELECT name FROM sys.tables;"

# spanner (emulator REST)
task spanner:query:source QUERY="SELECT * FROM Users"

# redis / generic valkey (redis-cli / valkey-cli)
task redis:query:source QUERY="SET greeting 'hello from source'"
task redis:query:branch QUERY="GET greeting"
task generic:query:branch QUERY="KEYS *"
```

## generic (RFC 0008) extras

```bash
task generic:seed             # seed the source Valkey
task generic:verify           # branch checks: MIRRORD_PARAM_* env + secretKeyRef passthrough
task generic:verify:params
task generic:influx:run:local / influx:seed / influx:query:source / influx:query:branch
```

## Working with operator:dev

When `operator:dev` is running, `run:local` automatically exports
`OPERATOR_ISOLATION_MARKER=local-dev` so **your** operator reconciles the
branch (see [operator-dev.md](operator-dev.md#isolation-marker-two-operators-one-cluster)).

The mirrord CLI warning *"Custom branch ID does not contain the session key"*
is expected: branch ids are static on purpose so `query:branch`/`verify` can
find the CRD by `spec.id`.
