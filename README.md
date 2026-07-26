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
```

## Operator setup (`op:` — start here)

The `op:` tasks are the one place to stand up clusters and pick an operator, so
you don't have to remember the build/load/install steps. Two choices each time:

1. **How many clusters** — `task op:clusters N=1` (single) or `N=2` / `N=3`
   (multicluster).
2. **Which operator** — your local build or a real released one:

```bash
task op:custom                     # YOUR docker build (mirrord-operator:custom)
task op:released VERSION=latest    # a released operator (latest | x.y.z | pick)
```

`op:custom` and `op:released` detect single-vs-multi from the running clusters
and **always load the agent image first**, building it if it is missing — so a
fresh cluster never fails with "agent image not found". They also build the
operator image on demand.

Rebuild a piece only when you actually want to:

```bash
task op:build           # rebuild the operator image only
task op:agent:rebuild   # rebuild the agent image and reload it into the clusters
task op:status          # topology + deployed operator image + agent state
```

Common flows:

```bash
# single cluster, your build
task op:clusters N=1 && task op:custom

# 3 clusters, released latest
task op:clusters N=3 && task op:released VERSION=latest

# swap a running multicluster to your build
task op:custom
```

Every `op:` task prints the relevant follow-up commands when it finishes.

## Quick start

```bash
# operator: cluster + operator (see "Operator setup" above), your code on top via mirrord
task op:clusters N=1 && task op:released VERSION=latest   # or: task op:custom
task operator:dev                     # local operator-service, stealing traffic

# queue splitting (same verbs for every queue module)
task sqs:deploy
task sqs:run:local                    # local consumer under mirrord
task sqs:send:match MESSAGE="hi"      # -> your local session
task sqs:send:nomatch                 # -> cluster consumer

# Azure Service Bus multi-topic preview (real Azure; needs `az login`,
# AZURE_SB_RG + AZURE_SB_NAMESPACE in .env, or pass CONN='Endpoint=sb://...')
task servicebus:multi:deploy                        # deploy consumer + create secret from az
task servicebus:multi:preview:start NAME=prev-1     # start preview, session key prev-1
task servicebus:multi:send TOPIC=test-topic KEY=prev-1   # -> preview 'prev-1' (omit KEY -> cluster)
task servicebus:multi:preview:stop NAME=prev-1      # stop the preview

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
