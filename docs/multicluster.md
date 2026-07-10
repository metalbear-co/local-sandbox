# Multicluster — local clusters, real Azure Service Bus

Two local minikube clusters running **released** operators (no docker builds):

- `mirrord-primary` — `multiCluster.enabled`, proxies sessions to the remote
  (its default cluster)
- `mirrord-remote-1` — standard operator, `multiClusterMember`

The only cloud dependency is a real Azure Service Bus **topic**. Cluster
wiring (apiserver cert SANs, docker network cross-connect, hostNetwork /
hostAliases patches, bearer-token credential secrets) is proxied to the proven
legacy tasks in `tasks/Taskfile.multicluster.yml`.

## Setup

```bash
task multicluster:up                 # agent image (auto-built if missing) + 2 clusters
                                     # + released operators (VERSION=latest|x.y.z)
task multicluster:crds               # local-chart CRDs on both clusters
task multicluster:status             # operators, remote connectivity, split sessions
```

## Operator dev against either cluster

```bash
task multicluster:operator:primary   # YOUR local operator, stealing from the primary
task multicluster:operator:remote-1  # ...or from the remote
# equivalent to: task operator:dev CLUSTER=<kube-context>
```

Each cluster has its own mirrord config, picked automatically by name:

- `.mirrord/operator-dev.mirrord-primary.yaml` — envoy-focused logs
- `.mirrord/operator-dev.mirrord-remote-1.yaml` — splitting-focused logs

**Both sessions can run at the same time** — and for multicluster dev they
generally MUST both be local: the isolation marker means a deployed operator
and a local one live in different worlds and cannot hand a multi-cluster
session across (mixed mode fails with `Multi-cluster session ... not found`).
Each config binds a distinct local port (3443/3444, mapped back to the pod's
443) and sets `OPERATOR_ADVERTISED_API_PORT=443` so dynamically registered
webhooks keep pointing at the Service's real port. That env var is an
operator-service option added on the `vladr/asb-sub-test` branch
(`services/operator-service/src/config.rs`) — without it, the webhook
advertises the bind port and admission breaks. Start the two sessions one
after the other (the first `cargo build` holds the target-dir lock).

Edit them independently (log levels, `OPERATOR_*` feature flags); `CONFIG=<path>`
overrides both. Feature flags and the isolation marker work exactly as in the
single-cluster flow — see [operator-dev.md](operator-dev.md).

## Azure Service Bus topic test

The consumer runs on the **remote** cluster; your mirrord session connects
through the **primary** operator, which proxies it over. Filter:
`tenant=^test` on subscription split `test-topic-sub`.

Set `AZURE_SB_RG` + `AZURE_SB_NAMESPACE` in `.env` (with `az login`) and the
secret is created automatically — the connection string is fetched from the
namespace's `RootManageSharedAccessKey` policy and the `test-topic`/`test-sub`
entities are created if missing. Without az, pass it manually:
`task multicluster:servicebus:secret CONN='<Primary Connection String>'`
(Azure Portal → Service Bus namespace → Shared access policies →
RootManageSharedAccessKey).

```bash
task multicluster:servicebus:deploy         # topic consumer -> remote cluster (creates secret if missing)
task multicluster:servicebus:run:local      # local consumer via the primary operator
task multicluster:servicebus:send:match     # tenant=test-user -> your local session
task multicluster:servicebus:send:nomatch   # tenant=other     -> remote consumer
task multicluster:servicebus:logs / clean
```

## How the clusters are wired

None of this lives in the `.mirrord/` configs — it's helm values + secrets,
applied by `multicluster:up` through the legacy install tasks
(`tasks/Taskfile.multicluster.yml` → `operator:install:primary` / `:remote`):

| Piece | Where it's defined | What it becomes in the cluster |
|---|---|---|
| Primary MC config (`clusterName`, `defaultCluster: mirrord-remote-1`, `managementOnly`, per-cluster `authType: bearerToken`) | [multicluster/operator-values-multicluster-2-clusters.yaml](../multicluster/operator-values-multicluster-2-clusters.yaml) | ConfigMap mounted at `/mirrord-config/multicluster-config.yaml` + `clusters-config.yaml` (env `MIRRORD_MULTICLUSTER_CONFIG` / `MIRRORD_CLUSTERS_CONFIG`) |
| Remote server URL + CA (`clusters.mirrord-remote-1.server/caData`) | set dynamically at install: `--set ...server=https://mirrord-remote-1:8443 --set ...caData=<from kubeconfig>` | same ConfigMap |
| Envoy RBAC on the remote (`multiClusterMember: true`) | [multicluster/operator-values-remote.yaml](../multicluster/operator-values-remote.yaml) | `mirrord-operator-envoy` ServiceAccount + ClusterRole/bindings on the remote |
| Bearer token (the actual credential) | legacy `multicluster:secrets:create`: `kubectl --context mirrord-remote-1 create token mirrord-operator-envoy` | Secret `mirrord-cluster-mirrord-remote-1` on the **primary**, labeled `operator.metalbear.co/remote-cluster-credentials=true` |
| Network path (`https://mirrord-remote-1:8443` resolvable from the primary pod) | legacy `network:connect` + install patches | docker network cross-connect + `hostNetwork` + `hostAliases` on the operator deployment |

The operator matches secrets to clusters by naming convention
(`mirrord-cluster-<clusterName>`). Inspect the wiring:

```bash
kubectl --context mirrord-primary get configmap -n mirrord -o yaml | grep -A10 multicluster-config
kubectl --context mirrord-primary get secrets -n mirrord -l operator.metalbear.co/remote-cluster-credentials=true
kubectl --context mirrord-primary get mirrordoperators operator -o yaml   # connectivity status
```

Your local `operator:dev` process inherits all of it through mirrord: the env
vars from the deployed pod, the ConfigMap + service-account token through
`fs mode: read` — so it talks to the remote exactly like the deployed primary
does, with zero extra config in `.mirrord/operator-dev.*.yaml`.

## Preview environment (Azure SB topics)

Same topology, but instead of running the consumer locally, the operator spins
up a **preview pod** from an image on the remote cluster and routes
filter-matching messages to it — nothing runs on your machine:

```bash
task multicluster:servicebus:deploy              # target consumer first
task multicluster:servicebus:preview:start       # preview pod on the remote (PREVIEW_KEY/IMAGE/TIMEOUT overridable)
task multicluster:servicebus:preview:logs        # watch the preview pod receive...
task multicluster:servicebus:send:match          # ...tenant=test-user -> preview pod
task multicluster:servicebus:send:nomatch        # tenant=other -> deployed consumer
task multicluster:servicebus:preview:status      # sessions + pods on both clusters
task multicluster:servicebus:preview:stop        # tear down the session
task multicluster:servicebus:preview:clean       # nuke all preview sessions/pods
```

The session goes through the primary (`MIRRORD_KUBE_CONTEXT`), which resolves
the target on the remote; the preview image defaults to
`servicebus-consumer:local` (already loaded into the remote by `servicebus:deploy`,
`preview.image_pull_policy: IfNotPresent`). The isolation-marker rule applies
here too: with `operator:dev` running, preview sessions are labeled `local-dev`
so your local operator manages them.

### Multiple named previews

`NAME=` gives each preview its **own split filter** (`tenant: ^<NAME>`) and its
own session key, so several previews coexist and each receives only its own
messages:

```bash
task multicluster:servicebus:preview:start NAME=prev-1   # filter tenant=^prev-1
task multicluster:servicebus:preview:start NAME=prev-2   # filter tenant=^prev-2

task multicluster:servicebus:send:to NAME=prev-1         # -> only prev-1's pod
task multicluster:servicebus:send:to NAME=prev-2 MESSAGE="hi"
task multicluster:servicebus:send:nomatch                # -> deployed consumer

task multicluster:servicebus:preview:status              # all sessions/pods
task multicluster:servicebus:preview:stop NAME=prev-1
task multicluster:servicebus:preview:clean               # nuke everything
```

The generated configs land in `/tmp/mirrord-preview-<NAME>.json`. `send:to`
sends `tenant=<NAME>-user`, which matches only that preview's `^<NAME>` filter.

## Gotchas

- **hostNetwork vs operator:dev**: the legacy installer puts both operators on
  hostNetwork. On a single-node cluster that makes apiserver→operator traffic
  ride loopback, which **bypasses the mirrord steal** — local operator:dev
  sessions receive nothing while the deployed operators silently serve
  everything. `multicluster:up` / `operator:apply` therefore finish with
  `multicluster:operator:podnetwork`, which moves the operators to the pod
  network (hostAliases + NAT keep cross-cluster reachability, the chart
  sysctl is restored so 443 binds as non-root). If operators ever end up on
  hostNetwork again, rerun `task multicluster:operator:podnetwork`.


- Remote-cluster bearer tokens are short-lived (10m default). If remote
  connectivity drops: `task multicluster:secrets:refresh`.
- The legacy multicluster values files predate Service Bus splitting;
  `multicluster:up` flips `operator.azureServiceBusSplitting=true` on both
  operators after install.
- Teardown: `task multicluster:destroy`.
- The deeper legacy suites (3-cluster, SQS/pubsub multicluster, session churn
  tests) live under `task legacy:multicluster:...` — see
  [legacy.md](legacy.md).
