# Torq "no live mirrord-agents" - diagnostics and fix experiments

Everything here runs on **your own** cluster, is low-risk, and needs no MetalBear
infrastructure. The read-only checks (§1) are safe on shared staging any time.
The two config experiments (§2) each touch only the operator Deployment and are
reversible in one command.

## Working hypothesis (what we believe is happening)

The operator stays healthy while its **kube-apiserver watch streams go silently
stale**. On GKE the operator talks to its linkerd-proxy sidecar over localhost
(always healthy, answers keepalives), while the sidecar's upstream connection to
the apiserver is what the GKE master path silently drops after an idle period -
no TCP reset. So the operator's client never notices, keeps serving from a stale
cache, and:

- new agents become Ready but the operator's pod-watch never sees it -> the
  router counts zero live agents and aborts at 60s ("no live mirrord-agents");
- sessions whose clients have died stay listed in `mirrord operator status`
  (served from the stale cache) while `kubectl get mirrordclustersessions` shows
  they are already gone -> your "9 leaked sessions".

We reproduced the *operator-stays-healthy-with-dead-watches* half locally; the
silent-drop trigger is specific to a cloud LB + meshed sidecar, which is why it
shows on your GKE cluster and not on a laptop. §1 confirms it on yours; §2 is the
fix.

## 1. Read-only confirmation (safe on shared staging)

### 1a. Prove the watch cache is stale (the smoking gun)

Run during or right after a failure window:

```bash
echo "operator status sessions:"; mirrord operator status | grep -cE '^\| [0-9A-F]{16}'
echo "actual session CRs:";       kubectl get mirrordclustersessions -A --no-headers | grep -cv CLOSED
```

If the first number is larger than the second, the operator is serving a stale
cache - the watch feeding its in-memory store has stopped receiving updates.
That single discrepancy is the core bug; capture it with a timestamp.

### 1b. Check the operator's linkerd-proxy upstream to the apiserver

```bash
OP=$(kubectl get pod -n mirrord -l app=mirrord-operator -o name | head -1)
# Connection-level errors / closes on the sidecar's outbound path:
linkerd diagnostics proxy-metrics -n mirrord "$OP" \
  | grep -E 'tcp_close_total|tcp_connection_duration|outbound.*(6443|443)' | head -40
# And the sidecar's own log for reset/timeout to the control plane:
kubectl logs -n mirrord "${OP#pod/}" -c linkerd-proxy --tail=500 \
  | grep -iE 'apiserver|kube-api|reset|timeout|failed|EOF' | tail -40
```

Rising `tcp_close_total` with `errno`/reset on the outbound apiserver authority,
while the operator container logs no reconnects, is direct evidence of the
sidecar-masking mechanism.

### 1c. Watch a single stream go stale in real time

```bash
# Compare the operator's view against the apiserver every 15s.
watch -n15 'echo status=$(mirrord operator status | grep -cE "^\| [0-9A-F]{16}") \
  crs=$(kubectl get mirrordclustersessions -A --no-headers | grep -cv CLOSED)'
```

If `status` diverges from `crs` and stays diverged, the store is stale until the
operator reconnects (or is restarted).

## 2. Fix experiments (reversible, operator Deployment only)

### 2a. Take the operator OUT of the mesh (strongest, simplest)

mirrord keeps its **agents** out of the mesh by design; the operator does not
need mesh membership for anything it does (it terminates client TLS itself and
talks to the apiserver directly). Removing the sidecar removes the masking layer
entirely.

```bash
kubectl -n mirrord patch deploy mirrord-operator --type=merge \
  -p '{"spec":{"template":{"metadata":{"annotations":{"linkerd.io/inject":"disabled"}}}}}'
# operator rolls; confirm the pod has no linkerd-proxy:
kubectl get pod -n mirrord -l app=mirrord-operator \
  -o jsonpath='{.items[0].spec.containers[*].name}{"\n"}'
```

Revert: set the annotation back to `enabled` (or remove it) and let it roll.

If your operator is Helm/ArgoCD-managed, set this in values instead of patching
live, so ArgoCD doesn't revert it - the pod-annotation field is
`operator.podAnnotations` (or the chart's pod-template annotations block).

### 2b. Keep the operator meshed, but skip the apiserver port (surgical middle-ground)

If policy requires the operator to stay meshed, exclude only its apiserver
traffic from the sidecar so watches ride a direct connection while everything
else stays meshed:

```bash
kubectl -n mirrord patch deploy mirrord-operator --type=merge \
  -p '{"spec":{"template":{"metadata":{"annotations":{"config.linkerd.io/skip-outbound-ports":"443,6443"}}}}}'
```

443 is the in-cluster apiserver Service; 6443 covers clusters that dial the
master endpoint directly. Adjust to whichever your operator actually uses (see
the destination in §1b).

### 2c. Version bump (already in flight)

Operator 3.191.0+ carries the session-expiry fixes that stop short/short-lived
sessions lingering, and moves agents to 3.245.0 (higher default CPU, TCP_NODELAY).
Bumping to latest is worth doing regardless, but on its own it does **not**
address the stale-watch mechanism - pair it with 2a or 2b.

## 3. What to send back

- The §1a numbers with a timestamp (status count vs CR count during a failure).
- §1b output: the sidecar's outbound-to-apiserver close/reset metrics and any
  matching linkerd-proxy log lines.
- After trying 2a (or 2b): the same back-to-back attempt series you ran before
  (success rate + whether ghost sessions still accumulate).

If un-meshing the operator ends the failures and the leaked sessions, that
confirms the mechanism and is the recommended standing configuration.
