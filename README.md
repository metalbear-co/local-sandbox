# mirrord Operator Local Sandbox

Local testing environment for mirrord operator features: queue splitting,
database branching, preview environments, multicluster.

Run `task` with no arguments for the cheatsheet, `task check` for a health
check, `task --list` for every core task.

## Docs

| Doc | What's in it |
|---|---|
| [docs/operator-dev.md](docs/operator-dev.md) | Operator dev loop without docker builds: `operator:use` / `crds` / `dev`, feature flags, isolation marker, agent image |
| [docs/queue-splitting.md](docs/queue-splitting.md) | The queue module pattern (sqs, kafka, rmq, pubsub, servicebus, redis-pubsub, temporal, bullmq) + real Azure Service Bus |
| [docs/db-branching.md](docs/db-branching.md) | The DB module pattern (postgres, mysql, mongodb, mssql, spanner, redis, generic) + per-DB query examples |
| [docs/multicluster.md](docs/multicluster.md) | Two local clusters + real Azure Service Bus topics, operator:dev per cluster |
| [docs/legacy.md](docs/legacy.md) | The entire pre-refactor task set (`task legacy:...`) — back-compat testing, per-module deep dives, UX helpers |

## Task layout

- **Core** — `Taskfile.yml` + `taskfiles/*.yml`: the curated day-to-day flows.
  Every queue module shares one verb set (`deploy` / `run:local` /
  `send:match` / `send:nomatch`), every DB module shares another (`deploy` /
  `run:local` / `query:source` / `query:branch`).
- **Legacy** — `Taskfile.legacy.yml` + `tasks/*.yml`: everything that existed
  before, unchanged, behind the `legacy:` prefix. `task legacy` lists it all;
  pass variables after `--` (`task legacy:operator:load -- TAG=my-branch`).

## Prerequisites

- minikube, docker (or podman), kubectl, helm, task (go-task), fzf
- Sibling repos: `../operator` and `../mirrord` (paths overridable in `.env`)
- `RELEASE_LICENSE_KEY` in `.env` for released operators
  (get one at https://app.metalbear.co)

## Setup

```bash
cp .env.example .env      # then edit
task check                # verify tools, cluster, operator, agent image
task cluster:create       # create/start the minikube cluster
```

## Quick start

```bash
# operator: released image in the cluster, your code on top via mirrord
task operator:use                     # VERSION=latest|x.y.z|pick
task operator:dev                     # local operator-service, stealing traffic

# queue splitting (same verbs for every queue module)
task sqs:deploy
task sqs:run:local                    # local consumer under mirrord
task sqs:send:match MESSAGE="hi"      # -> your local session
task sqs:send:nomatch                 # -> cluster consumer

# database branching (same verbs for every DB module)
task postgres:deploy
task postgres:run:local               # creates a branch DB
task postgres:query:source QUERY="SELECT * FROM users;"
task postgres:query:branch QUERY="SELECT count(*) FROM users;"

# multicluster (2 local clusters + real Azure Service Bus topics)
task multicluster:up
task multicluster:operator:primary    # your operator vs the primary cluster
```

## Directory structure

```
Taskfile.yml          core entrypoint (includes taskfiles/*.yml)
Taskfile.legacy.yml   old entrypoint, proxied as `task legacy:...`
taskfiles/            core modules: operator, mirrord, cluster, multicluster,
                      8 queue modules, 7 DB modules
tasks/                legacy module taskfiles
.mirrord/             operator-dev.yaml (mirrord config for operator:dev)
apps/                 test workloads (consumers, producers, DB apps)
k8s/                  kustomize bases + overlays per scenario
multicluster/         legacy multicluster operator values
scripts/              licenses, AKS setup, test scripts
.versions/            cached released operator images/charts + mirrord CLIs
docs/                 documentation (see table above)
```
