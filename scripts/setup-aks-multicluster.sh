#!/usr/bin/env bash
#
# Sets up two AKS clusters for testing AKS Workload Identity multi-cluster auth.
# Idempotent - safe to rerun. Only creates/updates resources that are missing or changed.
#
# What it creates:
#   - Resource group
#   - Azure Container Registry (ACR) for pushing operator images
#   - Two AKS clusters (primary + remote) with Workload Identity + OIDC enabled
#   - User-Assigned Managed Identity
#   - Federated Identity Credential (links primary SA to the identity)
#   - Role assignment (grants identity access to the remote cluster)
#
# Prerequisites:
#   - Build the operator image first: cd local-sandbox && task build:operator
#   - The image "mirrord-operator:custom" should exist in your local Docker daemon
#
# Usage:
#   ./setup-aks-multicluster.sh                # full setup + push image + deploy
#   ./setup-aks-multicluster.sh --push         # only rebuild/push image + redeploy (skip infra)
#   ./setup-aks-multicluster.sh --fast         # full setup with token refresh every 2 min (for testing)
#   ./setup-aks-multicluster.sh --push --fast  # push + redeploy with fast refresh
#   ./setup-aks-multicluster.sh --destroy
#
# To tear down everything:
#   ./setup-aks-multicluster.sh --destroy

set -euo pipefail

# ──────────────────────────────────────────────
# Configuration - change these to match your setup
# ──────────────────────────────────────────────
RESOURCE_GROUP="${AKS_RG:-mirrord-mc-test}"
LOCATION="${AKS_LOCATION:-eastus}"
PRIMARY_CLUSTER="${AKS_PRIMARY:-mirrord-primary}"
REMOTE_CLUSTER="${AKS_REMOTE:-mirrord-remote}"
IDENTITY_NAME="${AKS_IDENTITY:-mirrord-operator-mc}"
FEDERATION_NAME="mirrord-operator-federation"
OPERATOR_NAMESPACE="mirrord"
OPERATOR_SA="mirrord-operator"
NODE_COUNT="${AKS_NODE_COUNT:-1}"
NODE_VM_SIZE="${AKS_VM_SIZE:-Standard_DC2ads_v5}"
ACR_NAME="${AKS_ACR:-mirrordmctest}"

# Local image built by "task build:operator" / "task operator:update"
LOCAL_IMAGE="${OPERATOR_IMAGE:-mirrord-operator:custom}"

# Helm chart - defaults to local chart so your template changes are included
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELM_CHART="${MIRRORD_HELM_CHART:-${SCRIPT_DIR}/../../operator/public/charts/mirrord-operator}"

# ──────────────────────────────────────────────
# Helpers
# ──────────────────────────────────────────────
log()  { echo "[$(date +%H:%M:%S)] $*"; }
ok()   { echo "[$(date +%H:%M:%S)] ✓ $*"; }
skip() { echo "[$(date +%H:%M:%S)] - $* (already exists)"; }

az_exists() {
    # Run an az command and return 0 if it succeeds (resource exists), 1 otherwise.
    "$@" &>/dev/null
}

# ──────────────────────────────────────────────
# Parse flags
# ──────────────────────────────────────────────
PUSH_ONLY=false
FAST_MODE=false
# With --fast, AKS tokens pretend to expire after this many seconds.
# Halfway refresh kicks in at half this value (e.g. 600 -> refresh at ~5 min).
FAST_TOKEN_LIFETIME="${MIRRORD_AKS_TOKEN_LIFETIME_SECS:-600}"

for arg in "$@"; do
    case "$arg" in
        --push) PUSH_ONLY=true ;;
        --fast) FAST_MODE=true ;;
        --destroy) ;; # handled below
        *) echo "Unknown argument: $arg" >&2; exit 1 ;;
    esac
done

# ──────────────────────────────────────────────
# Destroy mode
# ──────────────────────────────────────────────
if [[ " $* " == *" --destroy "* ]]; then
    log "Destroying resource group $RESOURCE_GROUP and everything in it..."
    az group delete --name "$RESOURCE_GROUP" --yes --no-wait 2>/dev/null || true
    log "Delete initiated (runs in background). Run 'az group show -n $RESOURCE_GROUP' to check status."

    # Clean up kubeconfig contexts
    for cluster in "$PRIMARY_CLUSTER" "$REMOTE_CLUSTER"; do
        kubectl config delete-context "$cluster" 2>/dev/null || true
        kubectl config delete-cluster "$cluster" 2>/dev/null || true
        kubectl config delete-user "clusterUser_${RESOURCE_GROUP}_${cluster}" 2>/dev/null || true
    done
    ok "Local kubeconfig contexts cleaned up"
    exit 0
fi

if [[ "$FAST_MODE" == true ]]; then
    log "FAST MODE: AKS tokens will pretend to expire after ${FAST_TOKEN_LIFETIME}s (refresh at ~$((FAST_TOKEN_LIFETIME / 2))s)"
fi

# ──────────────────────────────────────────────
# Preflight checks
# ──────────────────────────────────────────────
log "Checking prerequisites..."
for cmd in az kubectl helm; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "ERROR: $cmd is required but not found in PATH" >&2
        exit 1
    fi
done

# Check Azure login
if ! az account show &>/dev/null; then
    echo "ERROR: Not logged in to Azure. Run 'az login' first." >&2
    exit 1
fi

SUBSCRIPTION=$(az account show --query id -o tsv)
log "Using subscription: $SUBSCRIPTION"
log "Resource group: $RESOURCE_GROUP"
log "Location: $LOCATION"
log "Primary cluster: $PRIMARY_CLUSTER"
log "Remote cluster: $REMOTE_CLUSTER"
echo ""

# ──────────────────────────────────────────────
# 1. Resource Group
# ──────────────────────────────────────────────
if az_exists az group show --name "$RESOURCE_GROUP"; then
    skip "Resource group $RESOURCE_GROUP"
else
    log "Creating resource group $RESOURCE_GROUP..."
    az group create --name "$RESOURCE_GROUP" --location "$LOCATION" -o none
    ok "Resource group created"
fi

# ──────────────────────────────────────────────
# 2. Azure Container Registry
# ──────────────────────────────────────────────
if az_exists az acr show --name "$ACR_NAME" --resource-group "$RESOURCE_GROUP"; then
    skip "Container Registry $ACR_NAME"
else
    log "Creating Azure Container Registry $ACR_NAME..."
    az acr create \
        --name "$ACR_NAME" \
        --resource-group "$RESOURCE_GROUP" \
        --sku Basic \
        --location "$LOCATION" \
        -o none
    ok "ACR created"
fi

ACR_LOGIN_SERVER=$(az acr show --name "$ACR_NAME" --resource-group "$RESOURCE_GROUP" \
    --query loginServer -o tsv)
REMOTE_IMAGE="${ACR_LOGIN_SERVER}/mirrord-operator:dev"

# ──────────────────────────────────────────────
# Push operator image to ACR
# ──────────────────────────────────────────────
push_image() {
    log "Building operator image (linux/amd64) and pushing to ACR..."

    SCRIPT_DIR_ABS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    OPERATOR_DIR="${SCRIPT_DIR_ABS}/../../operator"
    LICENSE_KEY="$(cat "${SCRIPT_DIR_ABS}/license-issuer.pem" 2>/dev/null || echo "")"

    cd "${OPERATOR_DIR}/.." && docker build \
        --platform linux/amd64 \
        --provenance=false \
        -f operator/public/operator/Dockerfile \
        --build-arg OPERATOR_LICENSE_ISSUER_PUBLIC_KEY="$LICENSE_KEY" \
        -t "$LOCAL_IMAGE" \
        operator

    az acr login --name "$ACR_NAME" -o none
    docker tag "$LOCAL_IMAGE" "$REMOTE_IMAGE"
    docker push "$REMOTE_IMAGE"

    ok "Image built (amd64) and pushed to $REMOTE_IMAGE"
}

push_image

# Handle --push mode: skip infra setup, just redeploy
if [[ "$PUSH_ONLY" == true ]]; then
    log "Push-only mode: redeploying operator on primary cluster..."
    kubectl config use-context "$PRIMARY_CLUSTER" >/dev/null

    if [[ "$FAST_MODE" == true ]]; then
        # Helm upgrade to inject/update the test env var
        helm upgrade mirrord-operator "$HELM_CHART" \
            --namespace "$OPERATOR_NAMESPACE" --reuse-values \
            --set "operator.extraEnv.MIRRORD_AKS_TOKEN_LIFETIME_SECS=${FAST_TOKEN_LIFETIME}"
    fi

    kubectl rollout restart deploy/mirrord-operator -n "$OPERATOR_NAMESPACE"
    kubectl rollout status deploy/mirrord-operator -n "$OPERATOR_NAMESPACE" --timeout=120s
    ok "Operator redeployed with new image"
    exit 0
fi

# ──────────────────────────────────────────────
# 3. AKS Clusters
# ──────────────────────────────────────────────
create_aks_cluster() {
    local name="$1"

    if az_exists az aks show --name "$name" --resource-group "$RESOURCE_GROUP"; then
        # Cluster exists - make sure OIDC + Workload Identity are enabled
        local oidc_enabled
        oidc_enabled=$(az aks show --name "$name" --resource-group "$RESOURCE_GROUP" \
            --query "oidcIssuerProfile.enabled" -o tsv 2>/dev/null || echo "false")

        if [[ "$oidc_enabled" != "true" ]]; then
            log "Enabling OIDC + Workload Identity on $name..."
            az aks update --name "$name" --resource-group "$RESOURCE_GROUP" \
                --enable-oidc-issuer --enable-workload-identity -o none
            ok "$name updated with OIDC + Workload Identity"
        else
            skip "AKS cluster $name (OIDC already enabled)"
        fi
    else
        log "Creating AKS cluster $name (this takes a few minutes)..."
        az aks create \
            --name "$name" \
            --resource-group "$RESOURCE_GROUP" \
            --location "$LOCATION" \
            --node-count "$NODE_COUNT" \
            --node-vm-size "$NODE_VM_SIZE" \
            --enable-oidc-issuer \
            --enable-workload-identity \
            --enable-aad \
            --attach-acr "$ACR_NAME" \
            --generate-ssh-keys \
            -o none
        ok "AKS cluster $name created"
    fi

    # Make sure cluster can pull from our ACR
    local acr_attached
    acr_attached=$(az aks check-acr --name "$name" --resource-group "$RESOURCE_GROUP" \
        --acr "$ACR_LOGIN_SERVER" 2>/dev/null | grep -c "SUCCEEDED" || echo "0")
    if [[ "$acr_attached" == "0" ]]; then
        log "Attaching ACR to $name..."
        az aks update --name "$name" --resource-group "$RESOURCE_GROUP" \
            --attach-acr "$ACR_NAME" -o none 2>/dev/null || true
    fi

    # Get admin credentials (bypasses AAD RBAC for script management).
    # --admin creates context as "{name}-admin", so we rename it to match
    # what the rest of the script expects.
    log "Getting credentials for $name..."
    kubectl config delete-context "$name" 2>/dev/null || true
    az aks get-credentials \
        --name "$name" \
        --resource-group "$RESOURCE_GROUP" \
        --overwrite-existing \
        --admin \
        -o none
    kubectl config rename-context "${name}-admin" "$name" 2>/dev/null || true
    ok "kubeconfig context '$name' ready"
}

create_aks_cluster "$PRIMARY_CLUSTER"
create_aks_cluster "$REMOTE_CLUSTER"

# ──────────────────────────────────────────────
# 3. Managed Identity
# ──────────────────────────────────────────────
if az_exists az identity show --name "$IDENTITY_NAME" --resource-group "$RESOURCE_GROUP"; then
    skip "Managed Identity $IDENTITY_NAME"
else
    log "Creating Managed Identity $IDENTITY_NAME..."
    az identity create \
        --name "$IDENTITY_NAME" \
        --resource-group "$RESOURCE_GROUP" \
        --location "$LOCATION" \
        -o none
    ok "Managed Identity created"
fi

CLIENT_ID=$(az identity show --name "$IDENTITY_NAME" --resource-group "$RESOURCE_GROUP" \
    --query clientId -o tsv)
PRINCIPAL_ID=$(az identity show --name "$IDENTITY_NAME" --resource-group "$RESOURCE_GROUP" \
    --query principalId -o tsv)
log "Identity Client ID: $CLIENT_ID"
log "Identity Principal ID: $PRINCIPAL_ID"

# ──────────────────────────────────────────────
# 4. Federated Identity Credential
# ──────────────────────────────────────────────
OIDC_ISSUER=$(az aks show --name "$PRIMARY_CLUSTER" --resource-group "$RESOURCE_GROUP" \
    --query "oidcIssuerProfile.issuerUrl" -o tsv)
EXPECTED_SUBJECT="system:serviceaccount:${OPERATOR_NAMESPACE}:${OPERATOR_SA}"

if az_exists az identity federated-credential show \
    --name "$FEDERATION_NAME" \
    --identity-name "$IDENTITY_NAME" \
    --resource-group "$RESOURCE_GROUP"; then

    # Verify the issuer and subject match (in case the primary cluster was recreated)
    current_issuer=$(az identity federated-credential show \
        --name "$FEDERATION_NAME" \
        --identity-name "$IDENTITY_NAME" \
        --resource-group "$RESOURCE_GROUP" \
        --query "issuer" -o tsv)

    if [[ "$current_issuer" != "$OIDC_ISSUER" ]]; then
        log "Federated credential exists but issuer changed. Recreating..."
        az identity federated-credential delete \
            --name "$FEDERATION_NAME" \
            --identity-name "$IDENTITY_NAME" \
            --resource-group "$RESOURCE_GROUP" \
            --yes
        az identity federated-credential create \
            --name "$FEDERATION_NAME" \
            --identity-name "$IDENTITY_NAME" \
            --resource-group "$RESOURCE_GROUP" \
            --issuer "$OIDC_ISSUER" \
            --subject "$EXPECTED_SUBJECT" \
            --audiences "api://AzureADTokenExchange" \
            -o none
        ok "Federated credential recreated with new issuer"
    else
        skip "Federated Identity Credential $FEDERATION_NAME"
    fi
else
    log "Creating Federated Identity Credential..."
    az identity federated-credential create \
        --name "$FEDERATION_NAME" \
        --identity-name "$IDENTITY_NAME" \
        --resource-group "$RESOURCE_GROUP" \
        --issuer "$OIDC_ISSUER" \
        --subject "$EXPECTED_SUBJECT" \
        --audiences "api://AzureADTokenExchange" \
        -o none
    ok "Federated Identity Credential created"
fi

# ──────────────────────────────────────────────
# 5. Role Assignment on Remote Cluster
# ──────────────────────────────────────────────
REMOTE_CLUSTER_ID=$(az aks show --name "$REMOTE_CLUSTER" --resource-group "$RESOURCE_GROUP" \
    --query id -o tsv)

existing_assignment=$(az role assignment list \
    --assignee "$PRINCIPAL_ID" \
    --role "Azure Kubernetes Service Cluster User Role" \
    --scope "$REMOTE_CLUSTER_ID" \
    --query "[0].id" -o tsv 2>/dev/null || echo "")

if [[ -n "$existing_assignment" ]]; then
    skip "Role assignment on $REMOTE_CLUSTER"
else
    log "Granting identity access to $REMOTE_CLUSTER..."
    az role assignment create \
        --assignee "$PRINCIPAL_ID" \
        --role "Azure Kubernetes Service Cluster User Role" \
        --scope "$REMOTE_CLUSTER_ID" \
        -o none
    ok "Role assignment created"
fi

# ──────────────────────────────────────────────
# 6. License
# ──────────────────────────────────────────────
LICENSE_FILE="${SCRIPT_DIR}/company-license.pem"
if [[ ! -f "$LICENSE_FILE" ]]; then
    log "Generating license..."
    (cd "$SCRIPT_DIR" && ./generate-license.sh)
    ok "License generated"
else
    skip "License file"
fi

# Helper: create license secret in a cluster context
create_license_secret() {
    local context="$1"
    kubectl --context "$context" create namespace "$OPERATOR_NAMESPACE" \
        --dry-run=client -o yaml | kubectl --context "$context" apply -f - >/dev/null
    kubectl --context "$context" create secret generic mirrord-operator-license-pem \
        --from-file=license.pem="$LICENSE_FILE" \
        -n "$OPERATOR_NAMESPACE" --dry-run=client -o yaml | \
        kubectl --context "$context" apply -f - >/dev/null
}

# ──────────────────────────────────────────────
# 7. Install operator on remote cluster
# ──────────────────────────────────────────────
log "Installing operator on remote cluster ($REMOTE_CLUSTER)..."
kubectl config use-context "$REMOTE_CLUSTER" >/dev/null

create_license_secret "$REMOTE_CLUSTER"

helm upgrade --install mirrord-operator "$HELM_CHART" \
    --namespace "$OPERATOR_NAMESPACE" \
    --set operator.image="${ACR_LOGIN_SERVER}/mirrord-operator" \
    --set operator.imageTag="dev" \
    --set operator.imagePullPolicy="Always" \
    --set operator.multiClusterMember=true \
    --set operator.multiClusterMemberAzureGroup=mirrord-operator-envoy \
    --set license.pemRef=mirrord-operator-license-pem \
    --set createNamespace=false
ok "Operator installed/upgraded on $REMOTE_CLUSTER"

# Bind the Managed Identity directly (by object ID) so it can access the remote cluster.
# The Helm chart creates group-based bindings, but for a simple setup without Azure AD groups
# we bind the identity's principalId as a user subject.
IDENTITY_OID=$(az identity show --name "$IDENTITY_NAME" --resource-group "$RESOURCE_GROUP" \
    --query principalId -o tsv)
log "Binding Managed Identity ($IDENTITY_OID) to remote cluster roles..."
kubectl --context "$REMOTE_CLUSTER" create clusterrolebinding mirrord-operator-envoy-identity \
    --clusterrole=mirrord-operator-envoy --user="$IDENTITY_OID" \
    --dry-run=client -o yaml | kubectl --context "$REMOTE_CLUSTER" apply -f - >/dev/null
kubectl --context "$REMOTE_CLUSTER" create clusterrolebinding mirrord-operator-envoy-remote-identity \
    --clusterrole=mirrord-operator-envoy-remote --user="$IDENTITY_OID" \
    --dry-run=client -o yaml | kubectl --context "$REMOTE_CLUSTER" apply -f - >/dev/null
ok "Identity RBAC bindings applied"

# ──────────────────────────────────────────────
# 8. Install operator on primary cluster
# ──────────────────────────────────────────────
REMOTE_SERVER=$(az aks show --name "$REMOTE_CLUSTER" --resource-group "$RESOURCE_GROUP" \
    --query "fqdn" -o tsv)
REMOTE_SERVER="https://${REMOTE_SERVER}:443"

# Get the remote cluster's CA certificate (AKS uses per-cluster self-signed CAs)
log "Fetching remote cluster CA certificate..."
TMPKUBE=$(mktemp)
az aks get-credentials --name "$REMOTE_CLUSTER" --resource-group "$RESOURCE_GROUP" \
    --admin --file "$TMPKUBE" -o none 2>/dev/null
REMOTE_CA_DATA=$(grep certificate-authority-data "$TMPKUBE" | awk '{print $2}')
rm -f "$TMPKUBE"

log "Installing operator on primary cluster ($PRIMARY_CLUSTER)..."
kubectl config use-context "$PRIMARY_CLUSTER" >/dev/null

create_license_secret "$PRIMARY_CLUSTER"

FAST_HELM_ARGS=()
if [[ "$FAST_MODE" == true ]]; then
    FAST_HELM_ARGS+=(--set "operator.extraEnv.MIRRORD_AKS_TOKEN_LIFETIME_SECS=${FAST_TOKEN_LIFETIME}")
fi

helm upgrade --install mirrord-operator "$HELM_CHART" \
    --namespace "$OPERATOR_NAMESPACE" \
    --set operator.image="${ACR_LOGIN_SERVER}/mirrord-operator" \
    --set operator.imageTag="dev" \
    --set operator.imagePullPolicy="Always" \
    --set operator.logLevel="debug" \
    --set operator.jsonLog=true \
    --set sa.azureClientId="$CLIENT_ID" \
    --set operator.multiCluster.enabled=true \
    --set operator.multiCluster.defaultCluster="$REMOTE_CLUSTER" \
    --set "operator.multiCluster.clusters.${REMOTE_CLUSTER}.authType=aks" \
    --set "operator.multiCluster.clusters.${REMOTE_CLUSTER}.server=${REMOTE_SERVER}" \
    --set "operator.multiCluster.clusters.${REMOTE_CLUSTER}.caData=${REMOTE_CA_DATA}" \
    --set license.pemRef=mirrord-operator-license-pem \
    --set createNamespace=false \
    "${FAST_HELM_ARGS[@]}"
ok "Operator installed/upgraded on $PRIMARY_CLUSTER"

# Force pod restart so it pulls the latest image (tag doesn't change)
kubectl --context "$PRIMARY_CLUSTER" rollout restart deploy/mirrord-operator -n "$OPERATOR_NAMESPACE"

# ──────────────────────────────────────────────
# 9. Verify
# ──────────────────────────────────────────────
echo ""
log "Waiting for operator pod to be ready on $PRIMARY_CLUSTER..."
kubectl --context "$PRIMARY_CLUSTER" wait \
    --for=condition=ready pod \
    -l app=mirrord-operator \
    -n "$OPERATOR_NAMESPACE" \
    --timeout=120s 2>/dev/null || true

echo ""
log "Checking Azure env vars in operator pod..."
AZURE_VARS=$(kubectl --context "$PRIMARY_CLUSTER" exec -n "$OPERATOR_NAMESPACE" \
    deploy/mirrord-operator -- env 2>/dev/null | grep "^AZURE_" || echo "(none found)")
echo "$AZURE_VARS"

echo ""
log "Recent operator logs (AKS-related):"
kubectl --context "$PRIMARY_CLUSTER" logs -n "$OPERATOR_NAMESPACE" \
    deploy/mirrord-operator --tail=50 2>/dev/null | grep -i "aks\|azure\|workload" || echo "(no AKS logs yet)"

echo ""
echo "=============================="
echo "Setup complete!"
echo "=============================="
echo ""
echo "Primary cluster context:  $PRIMARY_CLUSTER"
echo "Remote cluster context:   $REMOTE_CLUSTER"
echo "Identity Client ID:       $CLIENT_ID"
echo "Remote server:            $REMOTE_SERVER"
if [[ "$FAST_MODE" == true ]]; then
    echo "Fast mode:                token lifetime=${FAST_TOKEN_LIFETIME}s, refresh at ~$((FAST_TOKEN_LIFETIME / 2))s"
fi
echo ""
echo "To check cluster connectivity:"
echo "  kubectl --context $PRIMARY_CLUSTER get mirrordoperators operator -o yaml"
echo ""
echo "To view operator logs:"
echo "  kubectl --context $PRIMARY_CLUSTER logs -n $OPERATOR_NAMESPACE deploy/mirrord-operator -f"
echo ""
echo "After code changes, rebuild and redeploy:"
echo "  cd local-sandbox && task build:operator && ./scripts/setup-aks-multicluster.sh --push"
echo "  cd local-sandbox && task build:operator && ./scripts/setup-aks-multicluster.sh --push --fast  # with fast refresh"
echo ""
echo "To tear down everything:"
echo "  $0 --destroy"
