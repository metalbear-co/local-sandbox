#!/bin/bash
set -euo pipefail

# =============================================================================
# Deploy mirrord operator to EKS multi-cluster setup (3 clusters)
#
# Clusters:
#   dev1 (primary/management) — orchestrates remote clusters
#   dev2 (remote)             — bearer token auth (default cluster)
#   dev3 (remote)             — EKS IAM auth
#
# Usage:
#   ./deploy.sh                 # uses default image tag
#   ./deploy.sh sha-abc123      # override image tag
# =============================================================================

CHART_PATH="/Users/vladislavrashkov/Projects/MetalBear/charts/mirrord-operator"
VALUES_DIR="/Users/vladislavrashkov/Projects/MetalBear/local-sandbox/eks-multicluster"
REGION="eu-north-1"

# Cluster contexts
export MANAGEMENT_CLUSTER="arn:aws:eks:${REGION}:526936346962:cluster/multi-cluster-dev1"
export REMOTE_CLUSTER_1="arn:aws:eks:${REGION}:526936346962:cluster/multi-cluster-dev2"
export REMOTE_CLUSTER_2="arn:aws:eks:${REGION}:526936346962:cluster/multi-cluster-dev3"

# Image — update this tag for each release
IMAGE="ghcr.io/metalbear-co/operator-staging"
IMAGE_TAG="${1:-sha-95722d3}"

# IAM role for IRSA:
#   dev1 (primary) — EKS IAM auth to dev3
#   dev2 (remote)  — SQS queue creation (workload cluster)
#   dev3 (remote)  — SQS queue creation (workload cluster)
IAM_ROLE_ARN="arn:aws:iam::526936346962:role/mirrord-operator-role"

echo "=== Deploying with image: ${IMAGE}:${IMAGE_TAG} ==="

# ── Fetch remote cluster endpoints and CA data ──
echo ""
echo "=== Fetching cluster info ==="
REMOTE1_SERVER=$(kubectl config view --raw -o jsonpath="{.clusters[?(@.name==\"$REMOTE_CLUSTER_1\")].cluster.server}")
REMOTE2_SERVER=$(kubectl config view --raw -o jsonpath="{.clusters[?(@.name==\"$REMOTE_CLUSTER_2\")].cluster.server}")

# EKS uses a private CA (CN=kubernetes) — caData is required
REMOTE1_CA=$(aws eks describe-cluster --name multi-cluster-dev2 --region "$REGION" --query 'cluster.certificateAuthority.data' --output text)
REMOTE2_CA=$(aws eks describe-cluster --name multi-cluster-dev3 --region "$REGION" --query 'cluster.certificateAuthority.data' --output text)

echo "Remote 1 (dev2, bearer): $REMOTE1_SERVER"
echo "Remote 2 (dev3, IAM):    $REMOTE2_SERVER"
echo "CA data fetched for both clusters"

# ── 1. Upgrade PRIMARY (management) cluster ──
echo ""
echo "=== 1/3 Upgrading PRIMARY (dev1) ==="
helm upgrade --install mirrord-operator "$CHART_PATH" \
  --kube-context "$MANAGEMENT_CLUSTER" \
  --namespace mirrord \
  -f "$VALUES_DIR/operator-values-primary.yaml" \
  --set operator.image="$IMAGE" \
  --set operator.imageTag="$IMAGE_TAG" \
  --set "operator.multiCluster.clusters.multi-cluster-dev2.server=$REMOTE1_SERVER" \
  --set "operator.multiCluster.clusters.multi-cluster-dev2.caData=$REMOTE1_CA" \
  --set "operator.multiCluster.clusters.multi-cluster-dev3.server=$REMOTE2_SERVER" \
  --set "operator.multiCluster.clusters.multi-cluster-dev3.caData=$REMOTE2_CA" \
  --wait

# ── 2. Upgrade REMOTE-1 (dev2) — bearer token auth ──
echo ""
echo "=== 2/3 Upgrading REMOTE-1 (dev2, bearer token) ==="
helm upgrade --install mirrord-operator "$CHART_PATH" \
  --kube-context "$REMOTE_CLUSTER_1" \
  --namespace mirrord \
  -f "$VALUES_DIR/operator-values-remote.yaml" \
  --set operator.image="$IMAGE" \
  --set operator.imageTag="$IMAGE_TAG" \
  --wait

# ── 3. Upgrade REMOTE-2 (dev3) — EKS IAM auth ──
echo ""
echo "=== 3/3 Upgrading REMOTE-2 (dev3, EKS IAM) ==="
helm upgrade --install mirrord-operator "$CHART_PATH" \
  --kube-context "$REMOTE_CLUSTER_2" \
  --namespace mirrord \
  -f "$VALUES_DIR/operator-values-remote.yaml" \
  --set operator.image="$IMAGE" \
  --set operator.imageTag="$IMAGE_TAG" \
  --set operator.multiClusterMemberIamGroup=mirrord-operator-envoy \
  --wait
  # --set sa.roleArn="$IAM_ROLE_ARN" \
# ── 4. Generate fresh bearer token for dev2 ──
# After Helm recreates the ServiceAccount on dev2, the old token in the Secret
# is invalid. Generate a fresh one and update the Secret on the primary cluster.
echo ""
echo "=== Generating fresh bearer token for dev2 ==="
NEW_TOKEN=$(kubectl --context "$REMOTE_CLUSTER_1" create token mirrord-operator-envoy -n mirrord --duration=87600h)
TOKEN_B64=$(echo -n "$NEW_TOKEN" | base64 | tr -d '\n')

# Create or update the Secret on primary
kubectl --context "$MANAGEMENT_CLUSTER" get secret mirrord-cluster-multi-cluster-dev2 -n mirrord &>/dev/null 2>&1 && {
  kubectl --context "$MANAGEMENT_CLUSTER" patch secret mirrord-cluster-multi-cluster-dev2 -n mirrord \
    --type='json' -p="[{\"op\":\"replace\",\"path\":\"/data/bearerToken\",\"value\":\"$TOKEN_B64\"}]"
  echo "Secret updated with fresh token"
} || {
  kubectl --context "$MANAGEMENT_CLUSTER" create secret generic mirrord-cluster-multi-cluster-dev2 \
    -n mirrord --from-literal=bearerToken="$NEW_TOKEN"
  kubectl --context "$MANAGEMENT_CLUSTER" label secret mirrord-cluster-multi-cluster-dev2 \
    -n mirrord operator.metalbear.co/remote-cluster-credentials=true
  echo "Secret created with fresh token"
}

# ── 5. Delete stale leases and restart operators ──
echo ""
echo "=== Deleting stale leases ==="
kubectl delete lease mirrord-operator-leader -n mirrord \
  --context "$MANAGEMENT_CLUSTER" --ignore-not-found
kubectl delete lease mirrord-operator-leader -n mirrord \
  --context "$REMOTE_CLUSTER_1" --ignore-not-found
kubectl delete lease mirrord-operator-leader -n mirrord \
  --context "$REMOTE_CLUSTER_2" --ignore-not-found

echo ""
echo "=== Force restarting operator pods ==="
kubectl delete pods -n mirrord -l app.kubernetes.io/name=mirrord-operator \
  --context "$MANAGEMENT_CLUSTER" --force --grace-period=0
kubectl delete pods -n mirrord -l app.kubernetes.io/name=mirrord-operator \
  --context "$REMOTE_CLUSTER_1" --force --grace-period=0
kubectl delete pods -n mirrord -l app.kubernetes.io/name=mirrord-operator \
  --context "$REMOTE_CLUSTER_2" --force --grace-period=0

echo ""
echo "=== Waiting for pods to restart ==="
sleep 10

# ── 6. Verify ──
echo ""
echo "=== Verifying deployments ==="
echo "--- Primary (dev1) ---"
kubectl get pods -n mirrord --context "$MANAGEMENT_CLUSTER"
echo "--- Remote 1 (dev2, bearer) ---"
kubectl get pods -n mirrord --context "$REMOTE_CLUSTER_1"
echo "--- Remote 2 (dev3, IAM) ---"
kubectl get pods -n mirrord --context "$REMOTE_CLUSTER_2"

echo ""
echo "=== Checking rollout status ==="
kubectl --context "$MANAGEMENT_CLUSTER" rollout status deployment/mirrord-operator -n mirrord
kubectl --context "$REMOTE_CLUSTER_1" rollout status deployment/mirrord-operator -n mirrord
kubectl --context "$REMOTE_CLUSTER_2" rollout status deployment/mirrord-operator -n mirrord

echo ""
echo "=== Checking operator status ==="
sleep 5
kubectl --context "$MANAGEMENT_CLUSTER" get mirrordoperators operator -o jsonpath='{.status.connected_clusters}' -n mirrord | jq .

echo ""
echo "=== Deploy complete! ==="
