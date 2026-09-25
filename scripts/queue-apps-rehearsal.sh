#!/usr/bin/env bash
#
# Local rehearsal of the STAGING QUEUE-APPS PLAYGROUND on the sandbox minikube,
# one broker at a time, so a small cluster never has to hold all eight stacks.
#
# Deploys what Argo CD deploys to staging, from the same files in
# ../operator/argocd/services/queue-apps/, with the apps image built locally
# from ../mirrord/tests/e2e.Dockerfile (deployable-apps stage). Picking a
# broker deploys only its infra + consumer, then smoke-tests it: the consumer
# runs under mirrord with the checked-in .mirrord/queue-<broker>.yaml, a
# matching message must print locally and a non-matching one must reach the
# deployed consumer.
#
# Usage:
#   scripts/queue-apps-rehearsal.sh              interactive (gum menu)
#   BROKER=sqs scripts/queue-apps-rehearsal.sh   deploy + smoke one broker
#   scripts/queue-apps-rehearsal.sh clean        remove everything it deployed
#
# Env overrides:
#   CLUSTER_NAME   minikube profile                     (default: bearkube)
#   OPERATOR_REPO  operator checkout                    (default: sibling of sandbox)
#   MIRRORD_REPO   mirrord checkout                     (default: sibling of sandbox)
#   MIRRORD_BIN    mirrord CLI                          (default: mirrord)
#   KEY            session key / message filter value   (default: $USER-rehearsal)
#   SKIP_BUILD=1   reuse the existing local apps image

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SANDBOX_ROOT="$(dirname "$SCRIPT_DIR")"

CLUSTER_NAME="${CLUSTER_NAME:-bearkube}"
OPERATOR_REPO="${OPERATOR_REPO:-$SANDBOX_ROOT/../operator}"
MIRRORD_REPO="${MIRRORD_REPO:-$SANDBOX_ROOT/../mirrord}"
MIRRORD_BIN="${MIRRORD_BIN:-mirrord}"
KEY="${KEY:-${USER}-rehearsal}"
APPS_IMAGE="mirrord-e2e-apps:local"
UPSTREAM_IMAGE="ghcr.io/metalbear-co/mirrord-e2e-apps:latest"
QUEUE_APPS_DIR="$OPERATOR_REPO/argocd/services/queue-apps"

DEPLOY_BROKERS=(sqs kafka rmq nats gcp-pubsub redis-pubsub bullmq temporal azure-servicebus)
SMOKE_BROKERS=(sqs kafka rmq nats gcp-pubsub redis-pubsub bullmq temporal azure-servicebus)

say()  { gum style --foreground 212 "$1"; }
ok()   { gum style --foreground 82  "  PASS  $1"; }
bad()  { gum style --foreground 196 "  FAIL  $1"; }
info() { gum style --foreground 245 "  $1"; }
warn() { gum style --foreground 214 "  WARN  $1"; WARNINGS+=("$1"); }
WARNINGS=()

# Long builds stream unfiltered in the foreground so they can be watched live.
stream() {
    say "$1"
    bash -c "$2" || { bad "step failed: $1"; return 1; }
}

# Short steps get a spinner on a TTY; their output goes to a file whose path is
# printed first (tail -f it to watch live) and is dumped in full on failure.
spin() {
    local out
    out="$(mktemp -t queue-apps-step)"
    if [ -t 1 ]; then
        info "$1  (log: $out)"
        if ! gum spin --title "$1" -- bash -c "$2 >'$out' 2>&1"; then
            bad "step failed: $1"
            cat "$out"
            return 1
        fi
    else
        info "$1"
        bash -c "$2" 2>&1 | tee "$out" || { bad "step failed: $1"; return 1; }
    fi
}

command -v gum >/dev/null || { echo "gum is required (brew install gum)"; exit 1; }

render_dir() {
    local dir="$1" f
    for f in "$QUEUE_APPS_DIR/staging/$dir"/*.yaml; do
        sed "s|$UPSTREAM_IMAGE|$APPS_IMAGE|g" "$f"
        printf '\n---\n'
    done
}

clean_all() {
    say "Removing the queue-apps rehearsal"
    local dir
    for dir in sqs kafka rabbitmq nats gcp-pubsub azure-servicebus temporal redis; do
        render_dir "$dir" | kubectl delete --ignore-not-found --wait=false -f - 2>/dev/null || true
    done
    helm uninstall localstack -n localstack 2>/dev/null || true
    helm uninstall strimzi-cluster-operator -n kafka 2>/dev/null || true
    kubectl delete pvc --all -n kafka --ignore-not-found 2>/dev/null || true
    kubectl delete ns queue-splitting localstack kafka --ignore-not-found --wait=false
}

if [ "${1:-}" = "clean" ]; then
    clean_all
    exit 0
fi

# ── preflight ────────────────────────────────────────────────────────────────

say "Preflight"
for tool in docker kubectl helm minikube "$MIRRORD_BIN"; do
    command -v "$tool" >/dev/null || { bad "$tool not found"; exit 1; }
done
[ -f "$QUEUE_APPS_DIR/staging/kustomization.yaml" ] \
    || { bad "queue-apps manifests not found at $QUEUE_APPS_DIR (set OPERATOR_REPO)"; exit 1; }
[ -f "$MIRRORD_REPO/tests/e2e.Dockerfile" ] \
    || { bad "mirrord checkout not found at $MIRRORD_REPO (set MIRRORD_REPO)"; exit 1; }
mk_status="$(minikube -p "$CLUSTER_NAME" status 2>&1 || true)"
# With the docker driver the node shares the Docker Desktop VM disk, so a full
# disk here is fixed on the HOST, not in the node. Checked before the running
# check: InsufficientStorage replaces "Running" in the host field.
if grep -q "InsufficientStorage" <<< "$mk_status"; then
    bad "minikube reports InsufficientStorage (the Docker Desktop VM disk is full)"
    info "free host docker space first: docker builder prune -af && docker image prune -f"
    info "a full image build regenerates ~30G of build cache; prefer SKIP_BUILD=1 reruns"
    exit 1
fi
grep -q "host: Running" <<< "$mk_status" \
    || { bad "minikube profile '$CLUSTER_NAME' is not running (task cluster:create)"; exit 1; }
node_free_gb="$(minikube -p "$CLUSTER_NAME" ssh -- "df -BG --output=avail / | tail -1" 2>/dev/null | tr -dc '0-9' || echo 0)"
if [ "${node_free_gb:-0}" -lt 10 ]; then
    warn "only ${node_free_gb}G free on the node; the image build + load needs ~6G (docker builder prune -af frees the most)"
fi
context="$(kubectl config current-context)"
[ "$context" = "$CLUSTER_NAME" ] || warn "kubectl context is '$context', expected '$CLUSTER_NAME'"

if ! kubectl get deploy mirrord-operator -n mirrord >/dev/null 2>&1; then
    warn "no mirrord-operator in ns mirrord: split configs will not apply and smoke tests cannot run"
    info "install one first, e.g.: task operator:use   or   task op:custom"
    gum confirm "Continue with infra + manifests only?" || exit 1
fi
operator_env="$(kubectl get deploy mirrord-operator -n mirrord \
    -o jsonpath='{range .spec.template.spec.containers[0].env[*]}{.name}={.value}{"\n"}{end}' 2>/dev/null || true)"

# ── apps image ───────────────────────────────────────────────────────────────

node_image_created() {
    minikube -p "$CLUSTER_NAME" ssh -- \
        "docker image inspect '$APPS_IMAGE' --format '{{.Created}}'" 2>/dev/null | tr -d '\r' || true
}

# Builds the image unless SKIP_BUILD reuses it, and loads it into the node only
# when the node's copy differs. `minikube image load` silently keeps an existing
# same-tag image, so staleness is checked by creation timestamp, and a held
# reference (running pods) is surfaced instead of silently ignored.
ensure_image() {
    say "Apps image ($APPS_IMAGE)"
    if [ -n "${SKIP_BUILD:-}" ] && docker image inspect "$APPS_IMAGE" >/dev/null 2>&1; then
        info "reusing existing image (SKIP_BUILD)"
    else
        stream "building deployable-apps from tests/e2e.Dockerfile (slow on first run)" \
            "cd '$MIRRORD_REPO' && docker build -f tests/e2e.Dockerfile --target deployable-apps -t '$APPS_IMAGE' ."
    fi

    local host_created node_created
    host_created="$(docker image inspect "$APPS_IMAGE" --format '{{.Created}}')"
    node_created="$(node_image_created)"
    if [ "$node_created" = "$host_created" ]; then
        info "node already has this image"
        return 0
    fi
    if [ -n "$node_created" ]; then
        minikube -p "$CLUSTER_NAME" ssh -- "docker rmi -f '$APPS_IMAGE'" >/dev/null 2>&1 \
            || warn "could not remove the old image from the node (pods hold it); scale consumers to 0 and rerun"
    fi
    spin "loading image into minikube" "minikube -p '$CLUSTER_NAME' image load '$APPS_IMAGE'"
    node_created="$(node_image_created)"
    [ "$node_created" = "$host_created" ] \
        || warn "the node still runs an older image; scale the consumers to 0 and rerun to replace it"
}

# ── per-broker deploy ────────────────────────────────────────────────────────

wait_rollout() {
    local ns="$1" name="$2" timeout="${3:-240s}"
    if kubectl rollout status "deploy/$name" -n "$ns" --timeout="$timeout" >/dev/null 2>&1; then
        ok "$ns/$name ready"
    else
        warn "$ns/$name not ready within $timeout"
    fi
}

apply_dir() {
    spin "applying staging/$1 (image -> $APPS_IMAGE)" \
        "kubectl create ns queue-splitting --dry-run=client -o yaml | kubectl apply -f - >/dev/null; true"
    render_dir "$1" | kubectl apply -f -
}

deploy_broker() {
    local broker="$1"
    say "Deploy: $broker"
    case "$broker" in
        sqs)
            if ! helm status localstack -n localstack >/dev/null 2>&1; then
                spin "installing localstack 0.7.0" \
                    "helm repo add localstack https://localstack.github.io/helm-charts >/dev/null 2>&1 || true; \
                     helm install localstack localstack/localstack --version 0.7.0 \
                         -f '$QUEUE_APPS_DIR/localstack/values.yaml' \
                         --create-namespace -n localstack"
            fi
            apply_dir sqs
            wait_rollout localstack localstack
            wait_rollout queue-splitting sqs-consumer
            ;;
        kafka)
            if ! helm status strimzi-cluster-operator -n kafka >/dev/null 2>&1; then
                spin "installing strimzi 1.1.0 (waits for the operator)" \
                    "helm repo add strimzi https://strimzi.io/charts/ >/dev/null 2>&1 || true; \
                     helm install strimzi-cluster-operator strimzi/strimzi-kafka-operator --version 1.1.0 \
                         --create-namespace -n kafka --wait --timeout 300s"
            fi
            apply_dir kafka
            if kubectl wait kafka/my-cluster -n kafka --for=condition=Ready --timeout=300s >/dev/null 2>&1; then
                ok "kafka/my-cluster ready"
            else
                warn "kafka cluster not ready within 300s"
            fi
            wait_rollout queue-splitting kafka-consumer
            ;;
        rmq)
            apply_dir rabbitmq
            wait_rollout rabbitmq rabbitmq
            wait_rollout queue-splitting rmq-consumer
            ;;
        nats)
            apply_dir nats
            wait_rollout nats nats 120s
            wait_rollout queue-splitting nats-consumer
            ;;
        gcp-pubsub)
            apply_dir gcp-pubsub
            wait_rollout pubsub-emulator pubsub-emulator
            wait_rollout queue-splitting pubsub-consumer
            ;;
        azure-servicebus)
            apply_dir azure-servicebus
            # amd64-only emulator pair: slow (or broken) on arm nodes, tolerated.
            wait_rollout servicebus-emulator azure-sql-edge 300s
            wait_rollout servicebus-emulator servicebus-emulator 300s
            wait_rollout queue-splitting servicebus-consumer
            ;;
        temporal)
            apply_dir temporal
            wait_rollout temporal temporal-postgres
            wait_rollout temporal temporal 300s
            wait_rollout queue-splitting temporal-worker
            ;;
        redis-pubsub|bullmq)
            apply_dir redis
            wait_rollout queue-splitting redis
            wait_rollout queue-splitting redis-pubsub-consumer
            wait_rollout queue-splitting bullmq-consumer
            ;;
        *) bad "unknown broker $broker"; return 1 ;;
    esac
}

# ── smoke ────────────────────────────────────────────────────────────────────

require_operator_flag() {
    local flag="OPERATOR_$1_SPLITTING"
    if ! grep -q "^$flag=true$" <<< "$operator_env"; then
        warn "operator env $flag is not 'true'; enable it via the chart before this broker can split"
        return 1
    fi
}

send_message() {
    local broker="$1" value="$2" body="$3"
    case "$broker" in
        sqs)
            kubectl exec -n localstack deploy/localstack -- awslocal sqs send-message \
                --queue-url http://localhost:4566/000000000000/staging-sqs --region eu-north-1 \
                --message-body "$body" \
                --message-attributes "mirrord-user={DataType=String,StringValue=$value}" >/dev/null
            ;;
        kafka)
            printf 'mirrord-user:%s\t%s\n' "$value" "$body" \
                | kubectl exec -i -n kafka my-cluster-dual-role-0 -- \
                    /opt/kafka/bin/kafka-console-producer.sh --bootstrap-server localhost:9092 \
                    --topic staging-topic --property parse.headers=true >/dev/null
            ;;
        rmq)
            kubectl exec -n rabbitmq deploy/rabbitmq -- rabbitmqadmin -u e2e -p e2e-test-password \
                publish routing_key=staging-orders payload="$body" \
                properties="{\"headers\":{\"mirrord-user\":\"$value\"}}" >/dev/null
            ;;
        nats)
            kubectl -n nats run "nats-pub-$RANDOM" --rm -i --image=natsio/nats-box:0.14.5 \
                --restart=Never -- nats --server nats://nats:4222 \
                pub staging.test "$body" -H "mirrord-user:$value" >/dev/null 2>&1
            ;;
        gcp-pubsub)
            local data
            data="$(printf '%s' "$body" | base64)"
            kubectl exec -n pubsub-emulator deploy/pubsub-emulator -- curl -sS -X POST \
                http://localhost:8085/v1/projects/staging-project/topics/staging-topic:publish \
                -H 'content-type: application/json' \
                -d "{\"messages\":[{\"data\":\"$data\",\"attributes\":{\"mirrord-user\":\"$value\"}}]}" >/dev/null
            ;;
        redis-pubsub)
            kubectl exec -n queue-splitting deploy/redis -- redis-cli publish staging-channel \
                "{\"mirrord-user\":\"$value\",\"msg\":\"$body\"}" >/dev/null
            ;;
        temporal)
            # The filter is on the workflow id prefix, so the "value" is the id prefix.
            kubectl exec -n queue-splitting deploy/temporal-worker -- \
                env WORKFLOW_IDS="$value-$body" /apps/temporal-starter >/dev/null 2>&1
            ;;
        bullmq)
            # A BullMQ job is plain Redis state: counter, data hash, wait list entry.
            kubectl exec -n queue-splitting deploy/redis -- sh -c \
                "id=\$(redis-cli INCR bull:staging-jobs:id) && \
                 redis-cli HSET bull:staging-jobs:\$id data '{\"mirrord-user\":\"$value\",\"msg\":\"$body\"}' >/dev/null && \
                 redis-cli RPUSH bull:staging-jobs:wait \$id" >/dev/null
            ;;
        azure-servicebus)
            # The sender app ships in the apps image and inherits the pod's env.
            kubectl exec -n queue-splitting deploy/servicebus-consumer -- \
                env "SEND_USER=$value" "SEND_BODY=$body" /apps/go-azure-servicebus-sender >/dev/null 2>&1
            ;;
    esac
}

# On macOS the mirrord CLI exec-chains into the user binary keeping the same
# pid, and the binary does not always die on SIGINT, so the stop escalates
# instead of waiting forever.
stop_session() {
    local pid="$1"
    kill -INT "$pid" 2>/dev/null || true
    for _ in $(seq 1 10); do kill -0 "$pid" 2>/dev/null || return 0; sleep 1; done
    kill -TERM "$pid" 2>/dev/null || true
    for _ in $(seq 1 5); do kill -0 "$pid" 2>/dev/null || return 0; sleep 1; done
    kill -KILL "$pid" 2>/dev/null || true
}

smoke() {
    local broker="$1" app_dir lang consumer flag
    case "$broker" in
        sqs)          app_dir=rust-sqs-printer;         lang=rust; consumer=sqs-consumer;          flag=SQS ;;
        kafka)        app_dir=kafka-consumer;           lang=rust; consumer=kafka-consumer;        flag=KAFKA ;;
        rmq)          app_dir=go-rmq-consumer;          lang=go;   consumer=rmq-consumer;          flag=RMQ ;;
        nats)         app_dir=go-nats-consumer;         lang=go;   consumer=nats-consumer;         flag=NATS ;;
        gcp-pubsub)   app_dir=go-gcp-pubsub-consumer;   lang=go;   consumer=pubsub-consumer;       flag=GCP_PUBSUB ;;
        redis-pubsub) app_dir=go-redis-pubsub-consumer; lang=go;   consumer=redis-pubsub-consumer; flag=REDIS_PUBSUB ;;
        temporal)     app_dir=temporal-worker;          lang=go;   consumer=temporal-worker;       flag=TEMPORAL ;;
        bullmq)       app_dir=go-bullmq-consumer;       lang=go;   consumer=bullmq-consumer;       flag=BULLMQ ;;
        azure-servicebus) app_dir=go-azure-servicebus-queue-consumer; lang=go; consumer=servicebus-consumer; flag=AZURE_SERVICE_BUS ;;
        *) bad "unknown broker $broker"; return 1 ;;
    esac

    say "Smoke: $broker"
    require_operator_flag "$flag" || return 1
    if [ "$broker" = sqs ] && ! grep -q "AWS_ENDPOINT_URL=http://localstack.localstack" <<< "$operator_env"; then
        warn "operator AWS_ENDPOINT_URL does not point at localstack.localstack.svc; SQS splitting will misbehave"
    fi

    # Built before the mirrord session, then the binary runs under mirrord.
    # Compiling under `mirrord exec` injects the layer into build scripts and
    # cc, which aborts on macOS; same reason `run-app-staging` builds first.
    local bin
    if [ "$lang" = rust ]; then
        stream "building $app_dir" "cd '$MIRRORD_REPO/tests/$app_dir' && cargo build" || return 1
        bin="$MIRRORD_REPO/target/debug/$app_dir"
    else
        bin="/tmp/queue-apps-$app_dir"
        stream "building $app_dir" "cd '$MIRRORD_REPO/tests/$app_dir' && go build -o '$bin' ." || return 1
    fi

    local log body="match-$RANDOM" nomatch_body="nomatch-$RANDOM"
    log="$(mktemp -t "queue-apps-$broker")"
    info "consumer log: $log  (tail -f it to watch)"
    (
        cd "$MIRRORD_REPO/tests/$app_dir" \
            && exec "$MIRRORD_BIN" exec -f "$OPERATOR_REPO/.mirrord/queue-$broker.yaml" \
                --key "$KEY" -- "$bin"
    ) >"$log" 2>&1 &
    local pid=$!
    trap 'stop_session '"$pid" RETURN

    # The split needs a moment to patch the workload and start forwarding, so keep
    # re-sending the matching message until it lands in the local consumer's output.
    local matched=""
    for _ in $(seq 1 15); do
        kill -0 "$pid" 2>/dev/null || { bad "$broker: consumer exited early, see $log"; return 1; }
        send_message "$broker" "$KEY" "$body" || true
        sleep 8
        if grep -q "$body" "$log"; then matched=1; break; fi
    done
    if [ -n "$matched" ]; then
        ok "$broker: matching message reached the local consumer"
    else
        bad "$broker: matching message never reached the local consumer, see $log"
    fi

    send_message "$broker" "not-$KEY" "$nomatch_body" || true
    local routed=""
    for _ in $(seq 1 8); do
        sleep 5
        if kubectl logs -n queue-splitting "deploy/$consumer" --since=10m 2>/dev/null \
                | grep -q "$nomatch_body"; then
            routed=1; break
        fi
    done
    if [ -n "$routed" ]; then
        ok "$broker: non-matching message reached the deployed consumer"
    else
        bad "$broker: non-matching message not seen in the deployed consumer logs"
    fi

    stop_session "$pid"
    wait "$pid" 2>/dev/null || true
    trap - RETURN
    info "session closed; the operator drains the temporary queues"
}

run_e2e() {
    local filter
    filter="$(gum input --placeholder "nextest filter, e.g. queue_splitting::rmq::filtering")"
    [ -n "$filter" ] || return 0
    say "cargo nextest ($filter) - streaming output"
    (cd "$OPERATOR_REPO" && cargo nextest run -p tests "$filter" --run-ignored=all --test-threads=1)
}

# ── main ─────────────────────────────────────────────────────────────────────

if [ -n "${BROKER:-}" ]; then
    ensure_image
    deploy_broker "$BROKER"
    smoke "$BROKER"
else
    image_ready=""
    while true; do
        choice="$(gum choose --header "Queue-apps rehearsal - deploy + smoke one broker at a time" \
            "${DEPLOY_BROKERS[@]}" "all" "e2e test (nextest)" "clean" "quit")"
        case "$choice" in
            "quit"|"") break ;;
            "clean") clean_all ;;
            "e2e test (nextest)") run_e2e ;;
            "all")
                [ -n "$image_ready" ] || { ensure_image; image_ready=1; }
                for b in "${DEPLOY_BROKERS[@]}"; do deploy_broker "$b" || true; done
                for b in "${SMOKE_BROKERS[@]}"; do smoke "$b" || true; done
                ;;
            *)
                [ -n "$image_ready" ] || { ensure_image; image_ready=1; }
                deploy_broker "$choice" || true
                smoke "$choice" || true
                ;;
        esac
    done
fi

if [ "${#WARNINGS[@]}" -gt 0 ]; then
    say "Warnings"
    for w in "${WARNINGS[@]}"; do info "$w"; done
fi
say "Done. Clean up with: task queue-apps:clean"
