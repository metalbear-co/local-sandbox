# Operator development — no docker builds

The operator image is never built locally. A **released** image runs in the
cluster; your local code runs on top of it under mirrord.

```bash
task operator:use              # released operator into the cluster (VERSION=latest|x.y.z|pick)
task operator:crds             # apply CRDs from your local ../operator chart
task operator:dev              # run local operator-service under mirrord (steals traffic)
```

- `operator:use` needs `RELEASE_LICENSE_KEY` in `.env` (released images use the
  production license issuer). It caches images/charts under `.versions/` and
  automatically (re)loads the mirrord agent image `test` into minikube.
- `operator:dev` applies `operator:crds` first, cargo-builds `operator-service`,
  codesigns it, and runs it under mirrord (full steal from
  `deployment/mirrord-operator`).
- `CLUSTER=<kube-context>` on `operator:dev` / `operator:crds` targets another
  cluster (used by [multicluster](multicluster.md)).
- The old build-an-image flow still exists: `task legacy:operator:update`.

### Config resolution

`operator:dev` picks its mirrord config in this order:

1. `CONFIG=<path>` — explicit override (relative paths resolve from the repo root)
2. `.mirrord/operator-dev.<CLUSTER>.yaml` — per-cluster config, when
   `CLUSTER=` is set and the file exists (e.g.
   `operator-dev.mirrord-primary.yaml`, `operator-dev.mirrord-remote-1.yaml`)
3. [.mirrord/operator-dev.yaml](../.mirrord/operator-dev.yaml) — the base config

Per-cluster files are self-contained copies — set different log levels,
feature flags, or a `kube_context` per cluster without touching the base.

## Feature flags

Operator features are clap flags read from `OPERATOR_*` env vars
(`operator/crates/operator-proxy/src/config.rs`). Under mirrord the local
process inherits the **deployed** pod's env, so a flag the deployed (released)
chart doesn't render — e.g. a feature you're developing — must be forced in
`.mirrord/operator-dev.yaml`:

```yaml
feature:
  env:
    override:
      OPERATOR_GENERIC_BRANCHING: "true"
      # OPERATOR_REDIS_BRANCHING: "true"
```

## Isolation marker (two operators, one cluster)

`operator:dev` runs with `OPERATOR_ISOLATION_MARKER=local-dev`:

- your **local** operator reconciles only resources labeled `local-dev`;
- the **deployed** operator takes everything unlabeled;
- the mirrord CLI stamps the label only when the same env var is set in the
  **app session's** environment.

The DB modules' `run:local` tasks detect a locally running
`target/debug/operator-service` and export the marker automatically. Without
it, resources your app creates (e.g. a BranchDatabase) go to the deployed
operator — which may not support the feature — and the session hangs at
"waiting for readiness".

## Support verbs

```bash
task operator:status     # image, helm release, pods, CRDs in cluster
task operator:logs       # tail operator logs
task operator:restart    # force-restart pod + clear leader lease
task operator:versions   # cached releases under .versions/
task operator:uninstall
```

## mirrord agent image

The cluster runs agent image `test` with `pullPolicy: Never`, so it must live
inside minikube. `operator:use` keeps it loaded; manually:

```bash
task mirrord:agent:build    # build from ../mirrord and load into minikube
task mirrord:agent:load     # (re)load the docker image into minikube
task mirrord:agent:status   # where is the image?
```
